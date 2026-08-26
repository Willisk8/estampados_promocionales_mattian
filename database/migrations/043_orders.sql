-- ============================================================
-- 043_orders.sql
--
-- Etapa C, Fase 3 — pedidos y conversion desde cotizacion aceptada.
-- Plan: docs/plan_ia.md
--
-- DECISIONES DE ARQUITECTURA
--
-- 1. Un solo eje de estado, no dos. El plan original listaba `estado` y
--    `estado_produccion` como columnas separadas, pero RECIBIDO -> EN_DISENO
--    -> PENDIENTE_APROBACION_ARTE -> EN_PRODUCCION -> LISTO_ENTREGA ->
--    ENTREGADO -> FACTURADO -> CERRADO es una sola tuberia lineal, no dos
--    ejes independientes (a diferencia de estado_pago, que si es
--    genuinamente independiente: un pedido puede estar ENTREGADO con pago
--    PENDIENTE). Duplicar el eje habria repetido el mismo error que ya se
--    corrigio para la temperatura del cliente en Fase 4: dos vocabularios
--    para un mismo hecho que hay que mantener sincronizados a mano.
--
-- 2. saldo es columna generada (total - anticipo), no se escribe. Sigue la
--    regla del plan original: "las metricas deben derivarse de eventos, no
--    escribirse manualmente".
--
-- 3. cotizacion no tiene desglose de impuestos en el encabezado (el IVA
--    quedo fuera del MVP por decision de 038_quote_engine_components). La
--    conversion copia subtotal desde la suma de cotizacion_item y deja
--    impuestos_total en 0, sin inventar un calculo que nadie pidio.
--
-- 4. id_producto vive como columna propia en pedido_item (no solo dentro de
--    producto_snapshot JSONB), para que las metricas de Fase 4 puedan
--    agrupar por producto sin atravesar JSONB.
--
-- 5. pedido_evento alimenta cliente_evento por trigger, igual que
--    cotizacion_evento en 041. Reutiliza fn_consola_transicionar_cotizacion
--    para marcar CONVERTIDA_A_PEDIDO en vez de un UPDATE directo.
--
-- 6. No se crea una funcion de alta manual de pedidos en esta fase: el
--    plan solo pide que el esquema lo permita ("origen = 'MANUAL', sin
--    id_cotizacion"). Una UI/funcion dedicada es trabajo de Fase 7 si se
--    necesita; mientras tanto, un pedido manual se inserta con
--    service_role igual que hoy se hace con las importaciones.
-- ============================================================

-- ----------------------------------------------------------
-- 1. pedido
-- ----------------------------------------------------------
CREATE TABLE pedido (
    id_pedido               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    numero                  BIGSERIAL   UNIQUE,
    id_organizacion         UUID        NOT NULL REFERENCES organizacion(id_organizacion),
    id_cotizacion           UUID        REFERENCES cotizacion(id_cotizacion),
    origen                  TEXT        NOT NULL DEFAULT 'COTIZACION'
                            CHECK (origen IN ('COTIZACION', 'MANUAL')),
    estado                  TEXT        NOT NULL DEFAULT 'RECIBIDO'
                            CHECK (estado IN (
                                'RECIBIDO', 'EN_DISENO', 'PENDIENTE_APROBACION_ARTE',
                                'EN_PRODUCCION', 'LISTO_ENTREGA', 'ENTREGADO',
                                'FACTURADO', 'CERRADO', 'CANCELADO'
                            )),
    estado_pago             TEXT        NOT NULL DEFAULT 'PENDIENTE'
                            CHECK (estado_pago IN ('PENDIENTE', 'ANTICIPO_PAGADO', 'PAGADO', 'VENCIDO')),
    moneda                  TEXT        NOT NULL DEFAULT 'COP',
    subtotal                NUMERIC(14,2) NOT NULL CHECK (subtotal >= 0),
    impuestos_total         NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (impuestos_total >= 0),
    total                   NUMERIC(14,2) NOT NULL CHECK (total >= 0),
    anticipo                NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (anticipo >= 0 AND anticipo <= total),
    -- Derivado, nunca escrito a mano.
    saldo                   NUMERIC(14,2) GENERATED ALWAYS AS (total - anticipo) STORED,
    fecha_pedido            TIMESTAMPTZ NOT NULL DEFAULT now(),
    fecha_requerida_cliente TIMESTAMPTZ,
    fecha_prometida_entrega TIMESTAMPTZ,
    fecha_entrega_real      TIMESTAMPTZ,
    creado_por              UUID        NOT NULL REFERENCES auth.users(id),
    rol_consola             TEXT        NOT NULL,
    notas                   TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_pedido_origen_cotizacion CHECK (
        (origen = 'COTIZACION' AND id_cotizacion IS NOT NULL)
        OR (origen = 'MANUAL' AND id_cotizacion IS NULL)
    ),
    -- Una cotizacion se convierte en pedido una sola vez.
    CONSTRAINT uq_pedido_cotizacion UNIQUE (id_cotizacion)
);

ALTER TABLE pedido ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON pedido AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON pedido AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON pedido AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON pedido
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON pedido
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON pedido FROM anon, authenticated;
GRANT SELECT ON pedido TO authenticated;

CREATE INDEX idx_pedido_organizacion ON pedido (id_organizacion, created_at DESC);
CREATE INDEX idx_pedido_estado ON pedido (estado);

CREATE TRIGGER trg_pedido_updated_at
    BEFORE UPDATE ON pedido
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ----------------------------------------------------------
-- 2. pedido_item
-- ----------------------------------------------------------
CREATE TABLE pedido_item (
    id_pedido_item    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_pedido         UUID        NOT NULL REFERENCES pedido(id_pedido) ON DELETE CASCADE,
    -- Columna propia ademas del snapshot: las metricas de Fase 4 agrupan
    -- por producto sin atravesar JSONB.
    id_producto       UUID        NOT NULL REFERENCES producto(id_producto),
    id_variante       UUID        REFERENCES variante_producto(id_variante),
    id_tecnica        UUID        REFERENCES tecnica_marcacion(id_tecnica),
    producto_snapshot JSONB       NOT NULL,
    cantidad          INTEGER     NOT NULL CHECK (cantidad > 0),
    precio_unitario   NUMERIC(12,2) NOT NULL CHECK (precio_unitario >= 0),
    subtotal          NUMERIC(14,2) NOT NULL CHECK (subtotal >= 0),
    personalizacion   JSONB       NOT NULL DEFAULT '{}',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE pedido_item ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON pedido_item AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON pedido_item AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON pedido_item AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON pedido_item
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON pedido_item
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON pedido_item FROM anon, authenticated;
GRANT SELECT ON pedido_item TO authenticated;

CREATE INDEX idx_pedido_item_pedido ON pedido_item (id_pedido);
CREATE INDEX idx_pedido_item_producto ON pedido_item (id_producto);

-- ----------------------------------------------------------
-- 3. pedido_evento — historial append-only, mismo patron que 040
-- ----------------------------------------------------------
CREATE TABLE pedido_evento (
    id_pedido_evento UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_pedido        UUID        NOT NULL REFERENCES pedido(id_pedido) ON DELETE CASCADE,
    tipo_evento      TEXT        NOT NULL
                     CHECK (tipo_evento IN ('CREADO', 'TRANSICION_ESTADO', 'PAGO_REGISTRADO', 'NOTA')),
    estado_anterior  TEXT,
    estado_nuevo     TEXT,
    notas            TEXT,
    actor_tipo       TEXT        NOT NULL DEFAULT 'HUMANO'
                     CHECK (actor_tipo IN ('HUMANO', 'IA', 'SISTEMA')),
    actor_id         UUID        REFERENCES auth.users(id),
    rol_consola      TEXT,
    metadata         JSONB       NOT NULL DEFAULT '{}',
    occurred_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_pedido_evento_actor_humano
        CHECK (actor_tipo <> 'HUMANO' OR actor_id IS NOT NULL)
);

ALTER TABLE pedido_evento ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON pedido_evento AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON pedido_evento AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON pedido_evento AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON pedido_evento
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON pedido_evento
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON pedido_evento FROM anon, authenticated;
GRANT SELECT ON pedido_evento TO authenticated;

CREATE INDEX idx_pedido_evento_pedido ON pedido_evento (id_pedido, occurred_at DESC);

CREATE OR REPLACE FUNCTION fn_pedido_evento_no_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'pedido_evento es append-only: registra un evento nuevo, nunca modifiques uno existente';
END;
$$;

CREATE TRIGGER trg_pedido_evento_no_update
    BEFORE UPDATE ON pedido_evento
    FOR EACH ROW EXECUTE FUNCTION fn_pedido_evento_no_update();

CREATE TRIGGER trg_pedido_evento_no_delete
    BEFORE DELETE ON pedido_evento
    FOR EACH ROW EXECUTE FUNCTION fn_pedido_evento_no_update();

-- Alimenta cliente_evento, igual que cotizacion_evento en 041.
CREATE OR REPLACE FUNCTION fn_cliente_evento_desde_pedido()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id_organizacion UUID;
    v_numero          BIGINT;
    v_resumen         TEXT;
BEGIN
    SELECT p.id_organizacion, p.numero
      INTO v_id_organizacion, v_numero
      FROM pedido p
     WHERE p.id_pedido = NEW.id_pedido;

    IF v_id_organizacion IS NULL THEN
        RETURN NEW;
    END IF;

    v_resumen := CASE
        WHEN NEW.tipo_evento = 'TRANSICION_ESTADO' THEN
            'Pedido #' || v_numero || ' paso de ' || NEW.estado_anterior || ' a ' || NEW.estado_nuevo
        WHEN NEW.tipo_evento = 'CREADO' THEN
            'Pedido #' || v_numero || ' creado'
        ELSE
            'Pedido #' || v_numero || ': ' || NEW.tipo_evento
    END;

    INSERT INTO cliente_evento (
        id_organizacion, categoria, tipo_evento, source_table, source_id,
        resumen, occurred_at, metadata
    )
    VALUES (
        v_id_organizacion, 'PEDIDO', NEW.tipo_evento, 'pedido_evento', NEW.id_pedido_evento,
        v_resumen, NEW.occurred_at,
        jsonb_build_object('id_pedido', NEW.id_pedido, 'numero', v_numero)
    )
    ON CONFLICT (source_table, source_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pedido_evento_cliente_evento
    AFTER INSERT ON pedido_evento
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_evento_desde_pedido();

-- ----------------------------------------------------------
-- 4. Maquina de estados de pedido
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pedido_transiciones_validas(p_estado TEXT)
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT CASE p_estado
        WHEN 'RECIBIDO'                  THEN ARRAY['EN_DISENO','CANCELADO']
        WHEN 'EN_DISENO'                 THEN ARRAY['PENDIENTE_APROBACION_ARTE','CANCELADO']
        -- El arte puede rechazarse y volver a diseno.
        WHEN 'PENDIENTE_APROBACION_ARTE'  THEN ARRAY['EN_PRODUCCION','EN_DISENO','CANCELADO']
        WHEN 'EN_PRODUCCION'             THEN ARRAY['LISTO_ENTREGA','CANCELADO']
        WHEN 'LISTO_ENTREGA'             THEN ARRAY['ENTREGADO','CANCELADO']
        -- Ya entregado no se cancela.
        WHEN 'ENTREGADO'                 THEN ARRAY['FACTURADO']
        WHEN 'FACTURADO'                 THEN ARRAY['CERRADO']
        WHEN 'CERRADO'                   THEN ARRAY[]::TEXT[]
        WHEN 'CANCELADO'                 THEN ARRAY[]::TEXT[]
        ELSE NULL
    END;
$$;

REVOKE ALL ON FUNCTION fn_pedido_transiciones_validas(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_pedido_transiciones_validas(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_consola_transicionar_pedido(
    p_id_pedido UUID,
    p_estado_nuevo TEXT,
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_pedido       UUID,
    estado_anterior TEXT,
    estado_nuevo    TEXT,
    updated_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol             TEXT := fn_consola_rol();
    v_user            UUID := auth.uid();
    v_estado_anterior TEXT;
    v_validas         TEXT[];
    v_notas           TEXT := nullif(btrim(p_notas), '');
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden transicionar pedidos.';
    END IF;

    SELECT p.estado
      INTO v_estado_anterior
      FROM pedido p
     WHERE p.id_pedido = p_id_pedido
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pedido no encontrado.';
    END IF;

    v_validas := fn_pedido_transiciones_validas(v_estado_anterior);

    IF v_validas IS NULL THEN
        RAISE EXCEPTION 'Estado actual desconocido: %', v_estado_anterior;
    END IF;

    IF NOT (p_estado_nuevo = ANY (v_validas)) THEN
        RAISE EXCEPTION 'Transicion invalida: % -> %. Validas desde %: %',
            v_estado_anterior, p_estado_nuevo, v_estado_anterior,
            coalesce(array_to_string(v_validas, ', '), '(estado terminal)');
    END IF;

    UPDATE pedido p
       SET estado             = p_estado_nuevo,
           fecha_entrega_real = CASE WHEN p_estado_nuevo = 'ENTREGADO' THEN coalesce(p.fecha_entrega_real, now()) ELSE p.fecha_entrega_real END
     WHERE p.id_pedido = p_id_pedido;

    INSERT INTO pedido_evento (
        id_pedido, tipo_evento, estado_anterior, estado_nuevo,
        notas, actor_tipo, actor_id, rol_consola
    )
    VALUES (
        p_id_pedido, 'TRANSICION_ESTADO', v_estado_anterior, p_estado_nuevo,
        v_notas, 'HUMANO', v_user, v_rol
    );

    RETURN QUERY
    SELECT p.id_pedido, v_estado_anterior, p.estado, p.updated_at
      FROM pedido p
     WHERE p.id_pedido = p_id_pedido;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_transicionar_pedido(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_transicionar_pedido(UUID, TEXT, TEXT) TO authenticated;

-- ----------------------------------------------------------
-- 5. Conversion de cotizacion aceptada en pedido
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_consola_convertir_cotizacion_en_pedido(
    p_id_cotizacion UUID
)
RETURNS TABLE (
    id_pedido UUID,
    numero    BIGINT,
    total     NUMERIC,
    status    TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol            TEXT := fn_consola_rol();
    v_id_organizacion UUID;
    v_estado         TEXT;
    v_moneda         TEXT;
    v_subtotal       NUMERIC(14,2);
    v_id_pedido      UUID;
    v_numero         BIGINT;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden convertir cotizaciones en pedidos.';
    END IF;

    SELECT c.id_organizacion, c.estado, c.moneda
      INTO v_id_organizacion, v_estado, v_moneda
      FROM cotizacion c
     WHERE c.id_cotizacion = p_id_cotizacion
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'QUOTE_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    IF v_estado <> 'ACEPTADA' THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'QUOTE_NOT_ACCEPTED'::TEXT;
        RETURN;
    END IF;

    IF v_id_organizacion IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'QUOTE_WITHOUT_ORGANIZATION'::TEXT;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM pedido WHERE id_cotizacion = p_id_cotizacion) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'ALREADY_CONVERTED'::TEXT;
        RETURN;
    END IF;

    SELECT coalesce(sum(ci.subtotal), 0)
      INTO v_subtotal
      FROM cotizacion_item ci
     WHERE ci.id_cotizacion = p_id_cotizacion;

    IF v_subtotal <= 0 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'QUOTE_WITHOUT_ITEMS'::TEXT;
        RETURN;
    END IF;

    -- impuestos_total en 0: el IVA quedo fuera del MVP (038). No se inventa
    -- un calculo que nadie pidio.
    INSERT INTO pedido (
        id_organizacion, id_cotizacion, origen, moneda,
        subtotal, impuestos_total, total, creado_por, rol_consola
    )
    VALUES (
        v_id_organizacion, p_id_cotizacion, 'COTIZACION', v_moneda,
        v_subtotal, 0, v_subtotal, auth.uid(), v_rol
    )
    RETURNING pedido.id_pedido, pedido.numero INTO v_id_pedido, v_numero;

    -- Precios congelados: se copian tal como quedaron en cotizacion_item,
    -- nunca se vuelve a resolver el precio actual.
    INSERT INTO pedido_item (
        id_pedido, id_producto, id_variante, producto_snapshot,
        cantidad, precio_unitario, subtotal
    )
    SELECT
        v_id_pedido, ci.id_producto, ci.id_variante, ci.producto_snapshot,
        ci.cantidad, ci.precio_unitario, ci.subtotal
      FROM cotizacion_item ci
     WHERE ci.id_cotizacion = p_id_cotizacion;

    INSERT INTO pedido_evento (id_pedido, tipo_evento, estado_nuevo, actor_tipo, actor_id, rol_consola)
    VALUES (v_id_pedido, 'CREADO', 'RECIBIDO', 'HUMANO', auth.uid(), v_rol);

    -- Reusa la maquina de estados de la cotizacion (040) en vez de un
    -- UPDATE directo: deja su propio evento en cotizacion_evento.
    PERFORM fn_consola_transicionar_cotizacion(
        p_id_cotizacion, 'CONVERTIDA_A_PEDIDO', 'Convertida a pedido #' || v_numero);

    RETURN QUERY SELECT v_id_pedido, v_numero, v_subtotal, 'OK'::TEXT;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_convertir_cotizacion_en_pedido(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_convertir_cotizacion_en_pedido(UUID) TO authenticated;

-- ----------------------------------------------------------
-- 6. Documentacion
-- ----------------------------------------------------------
COMMENT ON TABLE pedido IS
    'Pedido nacido de una cotizacion ACEPTADA (origen=COTIZACION) o cargado manualmente (origen=MANUAL, sin id_cotizacion). saldo se deriva, nunca se escribe.';

COMMENT ON COLUMN pedido.estado IS
    'Un solo eje para el ciclo completo (recepcion -> diseno -> produccion -> entrega -> facturacion -> cierre). No existe estado_produccion aparte: dos vocabularios para el mismo hecho se sincronizan mal.';

COMMENT ON TABLE pedido_item IS
    'id_producto es columna propia ademas de producto_snapshot: las metricas de cliente agrupan por producto sin atravesar JSONB.';

COMMENT ON FUNCTION fn_consola_convertir_cotizacion_en_pedido(UUID) IS
    'Unica via para crear un pedido desde cotizacion. Copia precios congelados de cotizacion_item, nunca resuelve el precio actual. Requiere cotizacion en estado ACEPTADA con organizacion e items.';
