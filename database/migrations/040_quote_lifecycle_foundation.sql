-- ============================================================
-- 040_quote_lifecycle_foundation.sql
--
-- Etapa C, Fase 0 — cimiento del ciclo de vida de cotizacion.
-- Plan: docs/plan_ia.md
--
-- DECISIONES DE ARQUITECTURA
--
-- 1. cotizacion sigue siendo inmutable por RLS. La policy deny_update de
--    029 NO se toca. Toda transicion pasa por
--    fn_consola_transicionar_cotizacion(), SECURITY DEFINER con validacion
--    de rol y de maquina de estados. Ninguna sesion authenticated puede
--    hacer UPDATE directo, ni siquiera via PostgREST.
--
-- 2. La cotizacion registra de donde salio su precio. 038 dejo escrito que
--    "las cotizaciones deben guardar la version usada" y no se cumplia:
--    hay dos caminos de precio (resolve_price sobre tarifa publicada, y
--    fn_calculate_quote_components sobre costos + politica de margen) y la
--    fila no decia cual se uso. metodo_precio + id_margin_policy_version lo
--    cierran, con un CHECK que obliga a la version cuando el metodo es
--    CALCULO_COMPONENTES.
--
-- 3. cotizacion_evento nace aqui, no mas adelante, porque la funcion de
--    transicion la necesita desde su primera linea.
--
-- Precondicion verificada en STAGING antes de escribir esta migracion:
-- cotizacion contiene 2 filas, ambas EMITIDA, luego ampliar el CHECK de
-- estado no invalida datos existentes.
-- ============================================================

-- ----------------------------------------------------------
-- 1. Ampliar cotizacion
-- ----------------------------------------------------------
ALTER TABLE cotizacion
    ADD COLUMN updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN metodo_precio            TEXT        NOT NULL DEFAULT 'TARIFA_PUBLICADA',
    ADD COLUMN id_margin_policy_version UUID        REFERENCES margin_policy_version(id_margin_policy_version),
    ADD COLUMN fecha_emision            TIMESTAMPTZ,
    ADD COLUMN fecha_envio              TIMESTAMPTZ,
    ADD COLUMN fecha_vista              TIMESTAMPTZ,
    ADD COLUMN fecha_vencimiento        TIMESTAMPTZ,
    ADD COLUMN fecha_aceptacion         TIMESTAMPTZ,
    ADD COLUMN fecha_rechazo            TIMESTAMPTZ,
    ADD COLUMN fecha_anulacion          TIMESTAMPTZ,
    ADD COLUMN origen                   TEXT,
    ADD COLUMN canal_origen             TEXT,
    ADD COLUMN motivo_rechazo           TEXT;

ALTER TABLE cotizacion
    ADD CONSTRAINT ck_cotizacion_metodo_precio
        CHECK (metodo_precio IN ('TARIFA_PUBLICADA', 'CALCULO_COMPONENTES', 'MANUAL')),
    -- Un margen sin la version de politica que lo produjo no es auditable,
    -- y es justo el numero que la consola y la IA le citaran a un cliente.
    ADD CONSTRAINT ck_cotizacion_margen_versionado
        CHECK (
            metodo_precio <> 'CALCULO_COMPONENTES'
            OR id_margin_policy_version IS NOT NULL
        );

ALTER TABLE cotizacion DROP CONSTRAINT cotizacion_estado_check;

ALTER TABLE cotizacion
    ADD CONSTRAINT cotizacion_estado_check
        CHECK (estado IN (
            'BORRADOR',
            'CALCULADA',
            'PENDIENTE_APROBACION',
            'APROBADA_INTERNAMENTE',
            'EMITIDA',
            'ENVIADA',
            'VISTA',
            'EN_SEGUIMIENTO',
            'ACEPTADA',
            'RECHAZADA',
            'VENCIDA',
            'ANULADA',
            'CONVERTIDA_A_PEDIDO'
        ));

CREATE TRIGGER trg_cotizacion_updated_at
    BEFORE UPDATE ON cotizacion
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ONE-TIME BACKFILL: las cotizaciones emitidas antes de esta migracion no
-- tienen fecha de emision. Sin esto, el timeline y las metricas de Fase 4
-- las verian como si nunca se hubieran emitido.
UPDATE cotizacion
   SET fecha_emision = created_at
 WHERE estado = 'EMITIDA'
   AND fecha_emision IS NULL;

CREATE INDEX idx_cotizacion_estado_vencimiento
    ON cotizacion (estado, fecha_vencimiento)
    WHERE fecha_vencimiento IS NOT NULL;

-- ----------------------------------------------------------
-- 2. cotizacion_evento — historial append-only
-- ----------------------------------------------------------
CREATE TABLE cotizacion_evento (
    id_cotizacion_evento UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cotizacion        UUID        NOT NULL REFERENCES cotizacion(id_cotizacion) ON DELETE CASCADE,
    tipo_evento          TEXT        NOT NULL
                         CHECK (tipo_evento IN (
                             'CREADA',
                             'TRANSICION_ESTADO',
                             'PDF_GENERADO',
                             'PDF_ENVIADO',
                             'SEGUIMIENTO_PROGRAMADO',
                             'SEGUIMIENTO_REALIZADO',
                             'VENCIMIENTO',
                             'NOTA'
                         )),
    estado_anterior      TEXT,
    estado_nuevo         TEXT,
    notas                TEXT,
    actor_tipo           TEXT        NOT NULL DEFAULT 'HUMANO'
                         CHECK (actor_tipo IN ('HUMANO', 'IA', 'SISTEMA')),
    actor_id             UUID        REFERENCES auth.users(id),
    rol_consola          TEXT,
    metadata             JSONB       NOT NULL DEFAULT '{}',
    occurred_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Un actor HUMANO sin identidad hace la auditoria inservible.
    CONSTRAINT ck_cotizacion_evento_actor_humano
        CHECK (actor_tipo <> 'HUMANO' OR actor_id IS NOT NULL)
);

ALTER TABLE cotizacion_evento ENABLE ROW LEVEL SECURITY;

CREATE POLICY deny_insert ON cotizacion_evento AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON cotizacion_evento AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON cotizacion_evento AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON cotizacion_evento
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON cotizacion_evento
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON cotizacion_evento FROM anon, authenticated;
GRANT SELECT ON cotizacion_evento TO authenticated;

CREATE INDEX idx_cotizacion_evento_cotizacion
    ON cotizacion_evento (id_cotizacion, occurred_at DESC);

-- Guarda append-only al nivel del motor, no de la policy: service_role
-- tiene BYPASSRLS y sin este trigger podria reescribir el historial.
-- Mismo patron que fn_precio_snap_no_update (004).
CREATE OR REPLACE FUNCTION fn_cotizacion_evento_no_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'cotizacion_evento es append-only: registra un evento nuevo, nunca modifiques uno existente';
END;
$$;

CREATE TRIGGER trg_cotizacion_evento_no_update
    BEFORE UPDATE ON cotizacion_evento
    FOR EACH ROW EXECUTE FUNCTION fn_cotizacion_evento_no_update();

CREATE TRIGGER trg_cotizacion_evento_no_delete
    BEFORE DELETE ON cotizacion_evento
    FOR EACH ROW EXECUTE FUNCTION fn_cotizacion_evento_no_update();

-- ----------------------------------------------------------
-- 3. Maquina de estados
-- ----------------------------------------------------------
-- Se declara en una funcion propia para que exista un solo lugar donde
-- leer el ciclo de vida completo. ANULADA y CONVERTIDA_A_PEDIDO son
-- terminales: devuelven el array vacio.
CREATE OR REPLACE FUNCTION fn_cotizacion_transiciones_validas(p_estado TEXT)
RETURNS TEXT[]
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT CASE p_estado
        WHEN 'BORRADOR'              THEN ARRAY['CALCULADA','EMITIDA','ANULADA']
        WHEN 'CALCULADA'             THEN ARRAY['PENDIENTE_APROBACION','APROBADA_INTERNAMENTE','EMITIDA','BORRADOR','ANULADA']
        WHEN 'PENDIENTE_APROBACION'  THEN ARRAY['APROBADA_INTERNAMENTE','RECHAZADA','BORRADOR','ANULADA']
        WHEN 'APROBADA_INTERNAMENTE' THEN ARRAY['EMITIDA','ANULADA']
        WHEN 'EMITIDA'               THEN ARRAY['ENVIADA','VENCIDA','ANULADA']
        WHEN 'ENVIADA'               THEN ARRAY['VISTA','EN_SEGUIMIENTO','ACEPTADA','RECHAZADA','VENCIDA','ANULADA']
        WHEN 'VISTA'                 THEN ARRAY['EN_SEGUIMIENTO','ACEPTADA','RECHAZADA','VENCIDA','ANULADA']
        WHEN 'EN_SEGUIMIENTO'        THEN ARRAY['ACEPTADA','RECHAZADA','VENCIDA','ANULADA']
        WHEN 'ACEPTADA'              THEN ARRAY['CONVERTIDA_A_PEDIDO','ANULADA']
        WHEN 'RECHAZADA'             THEN ARRAY['ANULADA']
        WHEN 'VENCIDA'               THEN ARRAY['EN_SEGUIMIENTO','ANULADA']
        WHEN 'ANULADA'               THEN ARRAY[]::TEXT[]
        WHEN 'CONVERTIDA_A_PEDIDO'   THEN ARRAY[]::TEXT[]
        ELSE NULL
    END;
$$;

-- ----------------------------------------------------------
-- 4. La unica via de escritura sobre cotizacion
-- ----------------------------------------------------------
-- p_notas cumple doble papel: queda en el evento siempre, y ademas se copia
-- a cotizacion.motivo_rechazo cuando la transicion es a RECHAZADA.
CREATE OR REPLACE FUNCTION fn_consola_transicionar_cotizacion(
    p_id_cotizacion UUID,
    p_estado_nuevo TEXT,
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_cotizacion   UUID,
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
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden transicionar cotizaciones.';
    END IF;

    SELECT c.estado
      INTO v_estado_anterior
      FROM cotizacion c
     WHERE c.id_cotizacion = p_id_cotizacion
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    v_validas := fn_cotizacion_transiciones_validas(v_estado_anterior);

    IF v_validas IS NULL THEN
        RAISE EXCEPTION 'Estado actual desconocido: %', v_estado_anterior;
    END IF;

    IF NOT (p_estado_nuevo = ANY (v_validas)) THEN
        RAISE EXCEPTION 'Transicion invalida: % -> %. Validas desde %: %',
            v_estado_anterior, p_estado_nuevo, v_estado_anterior,
            coalesce(array_to_string(v_validas, ', '), '(estado terminal)');
    END IF;

    UPDATE cotizacion c
       SET estado           = p_estado_nuevo,
           fecha_emision    = CASE WHEN p_estado_nuevo = 'EMITIDA'    THEN coalesce(c.fecha_emision, now())    ELSE c.fecha_emision    END,
           fecha_envio      = CASE WHEN p_estado_nuevo = 'ENVIADA'    THEN coalesce(c.fecha_envio, now())      ELSE c.fecha_envio      END,
           fecha_vista      = CASE WHEN p_estado_nuevo = 'VISTA'      THEN coalesce(c.fecha_vista, now())      ELSE c.fecha_vista      END,
           fecha_aceptacion = CASE WHEN p_estado_nuevo = 'ACEPTADA'   THEN coalesce(c.fecha_aceptacion, now()) ELSE c.fecha_aceptacion END,
           fecha_rechazo    = CASE WHEN p_estado_nuevo = 'RECHAZADA'  THEN coalesce(c.fecha_rechazo, now())    ELSE c.fecha_rechazo    END,
           fecha_anulacion  = CASE WHEN p_estado_nuevo = 'ANULADA'    THEN coalesce(c.fecha_anulacion, now())  ELSE c.fecha_anulacion  END,
           motivo_rechazo   = CASE WHEN p_estado_nuevo = 'RECHAZADA'  THEN coalesce(v_notas, c.motivo_rechazo) ELSE c.motivo_rechazo   END
     WHERE c.id_cotizacion = p_id_cotizacion;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, estado_anterior, estado_nuevo,
        notas, actor_tipo, actor_id, rol_consola
    )
    VALUES (
        p_id_cotizacion, 'TRANSICION_ESTADO', v_estado_anterior, p_estado_nuevo,
        v_notas, 'HUMANO', v_user, v_rol
    );

    RETURN QUERY
    SELECT c.id_cotizacion, v_estado_anterior, c.estado, c.updated_at
      FROM cotizacion c
     WHERE c.id_cotizacion = p_id_cotizacion;
END;
$$;

REVOKE ALL ON FUNCTION fn_cotizacion_transiciones_validas(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_consola_transicionar_cotizacion(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_cotizacion_transiciones_validas(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_consola_transicionar_cotizacion(UUID, TEXT, TEXT) TO authenticated;

-- ----------------------------------------------------------
-- 5. La creacion registra la procedencia del precio
-- ----------------------------------------------------------
-- Reemplaza la version de 029. Unico cambio de comportamiento: fija
-- metodo_precio = 'TARIFA_PUBLICADA' (esta funcion resuelve por
-- resolve_price, no por politica de margen), sella fecha_emision y deja
-- el evento CREADA en el historial.
CREATE OR REPLACE FUNCTION fn_consola_crear_cotizacion_simple(
    p_id_organizacion UUID,
    p_id_producto UUID,
    p_id_variante UUID,
    p_cantidad INT,
    p_moneda TEXT DEFAULT 'COP',
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_cotizacion UUID,
    numero BIGINT,
    total NUMERIC,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_precio NUMERIC(12,2);
    v_moneda TEXT;
    v_id_precio UUID;
    v_status TEXT;
    v_id_cotizacion UUID;
    v_numero BIGINT;
    v_snapshot JSONB;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear cotizaciones.';
    END IF;

    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor que cero.';
    END IF;

    IF p_id_organizacion IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    SELECT precio_unitario, moneda, id_precio, status
      INTO v_precio, v_moneda, v_id_precio, v_status
      FROM resolve_price(p_id_producto, p_id_variante, p_cantidad, now(), coalesce(p_moneda, 'COP'));

    IF v_status <> 'OK' THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_status;
        RETURN;
    END IF;

    SELECT jsonb_build_object(
        'id_producto', p.id_producto,
        'sku', p.sku,
        'producto', p.nombre,
        'estado_producto', p.estado,
        'id_variante', v.id_variante,
        'sku_variante', v.sku_variante,
        'variante', v.nombre,
        'estado_variante', v.estado,
        'id_precio', v_id_precio,
        'cantidad', p_cantidad,
        'moneda', v_moneda,
        'precio_unitario', v_precio,
        'capturado_en', now()
    )
      INTO v_snapshot
      FROM producto p
      LEFT JOIN variante_producto v ON v.id_variante = p_id_variante
     WHERE p.id_producto = p_id_producto;

    INSERT INTO cotizacion (
        id_organizacion, estado, moneda, total, creada_por, rol_consola, notas,
        metodo_precio, fecha_emision, origen, canal_origen
    )
    VALUES (
        p_id_organizacion, 'EMITIDA', v_moneda, v_precio * p_cantidad,
        auth.uid(), v_rol, nullif(btrim(p_notas), ''),
        'TARIFA_PUBLICADA', now(), 'CONSOLA', 'INTERNO'
    )
    RETURNING cotizacion.id_cotizacion, cotizacion.numero
      INTO v_id_cotizacion, v_numero;

    INSERT INTO cotizacion_item (
        id_cotizacion, id_producto, id_variante, id_precio, producto_snapshot,
        cantidad, precio_unitario, subtotal, moneda
    )
    VALUES (
        v_id_cotizacion, p_id_producto, p_id_variante, v_id_precio, v_snapshot,
        p_cantidad, v_precio, v_precio * p_cantidad, v_moneda
    );

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, estado_anterior, estado_nuevo,
        actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        v_id_cotizacion, 'CREADA', NULL, 'EMITIDA',
        'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('metodo_precio', 'TARIFA_PUBLICADA', 'id_precio', v_id_precio)
    );

    RETURN QUERY SELECT v_id_cotizacion, v_numero, v_precio * p_cantidad, 'OK'::TEXT;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INT, TEXT, TEXT) TO authenticated;

-- ----------------------------------------------------------
-- 6. Documentacion
-- ----------------------------------------------------------
COMMENT ON COLUMN cotizacion.metodo_precio IS
    'De donde salio el precio: TARIFA_PUBLICADA (resolve_price), CALCULO_COMPONENTES (fn_calculate_quote_components) o MANUAL.';

COMMENT ON COLUMN cotizacion.id_margin_policy_version IS
    'Version de politica de margen usada. Obligatoria cuando metodo_precio = CALCULO_COMPONENTES: un margen sin su version no es auditable.';

COMMENT ON TABLE cotizacion_evento IS
    'Historial append-only de la cotizacion. Fuente del timeline comercial; en Fase 1 alimenta cliente_evento por trigger.';

COMMENT ON FUNCTION fn_cotizacion_transiciones_validas(TEXT) IS
    'Maquina de estados de cotizacion en un solo lugar. Array vacio = estado terminal, NULL = estado desconocido.';

COMMENT ON FUNCTION fn_consola_transicionar_cotizacion(UUID, TEXT, TEXT) IS
    'Unica via de escritura sobre cotizacion.estado. Valida rol y transicion, sella la fecha correspondiente y registra el evento. p_notas se copia a motivo_rechazo cuando la transicion es a RECHAZADA.';
