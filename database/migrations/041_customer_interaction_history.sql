-- ============================================================
-- 041_customer_interaction_history.sql
--
-- Etapa C, Fase 1 — timeline consolidado e interacciones comerciales.
-- Plan: docs/plan_ia.md
--
-- DECISIONES DE ARQUITECTURA
--
-- 1. cliente_evento es la columna vertebral que leera la IA en Fase 5. Se
--    llena por triggers AFTER INSERT sobre cada tabla fuente, no por las
--    funciones fn_consola_*. Razon: service_role tiene BYPASSRLS y los
--    scripts de importacion lo usan; si el llenado dependiera de la
--    funcion de escritura, una fila insertada por otra via dejaria un
--    hueco silencioso en el historial que la IA nunca detectaria.
--
-- 2. interaccion_cliente y cliente_evento son PII (id_persona, resumenes de
--    conversaciones): nacen con deny_all, igual que persona/canal_contacto
--    en 008. Se leen solo por fn_consola_timeline_cliente.
--
-- 3. Solo se guarda resumen, nunca el cuerpo completo de una conversacion.
--    El texto original queda en el proveedor (WhatsApp, correo); aqui solo
--    su referencia va en metadata. Evita crear una obligacion de retencion
--    que hoy nadie opera (Gate 4 ya tiene un pendiente asi, sin resolver
--    desde la migracion 022).
--
-- 4. cotizacion_evento (040) recibe aqui su trigger hacia cliente_evento.
--    No es editar una migracion aplicada: es anadir un trigger nuevo sobre
--    una tabla existente, igual que 016/019 reemplazaron funciones creadas
--    en migraciones previas.
-- ============================================================

-- ----------------------------------------------------------
-- 1. cliente_evento — timeline consolidado, append-only
-- ----------------------------------------------------------
CREATE TABLE cliente_evento (
    id_evento       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_organizacion UUID        NOT NULL REFERENCES organizacion(id_organizacion),
    id_persona      UUID        REFERENCES persona(id_persona),
    categoria       TEXT        NOT NULL
                    CHECK (categoria IN ('MARKETING', 'COTIZACION', 'PEDIDO', 'INTERACCION', 'IA')),
    tipo_evento     TEXT        NOT NULL,
    canal           TEXT,
    source_table    TEXT        NOT NULL,
    source_id       UUID        NOT NULL,
    resumen         TEXT        NOT NULL,
    occurred_at     TIMESTAMPTZ NOT NULL,
    metadata        JSONB       NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Hace los triggers de origen idempotentes: un AFTER INSERT que se
    -- reintente (o un backfill manual) no duplica el evento.
    CONSTRAINT uq_cliente_evento_origen UNIQUE (source_table, source_id)
);

ALTER TABLE cliente_evento ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON cliente_evento
    AS RESTRICTIVE FOR ALL USING (false);

-- Defensa en profundidad: aunque deny_all ya bloquea todo por RLS, se
-- revocan tambien los privilegios de tabla que Supabase concede por
-- defecto. Mismo estandar que 025_revoke_residual_anon_grants.
REVOKE ALL ON cliente_evento FROM anon, authenticated;

CREATE INDEX idx_cliente_evento_organizacion
    ON cliente_evento (id_organizacion, occurred_at DESC);
CREATE INDEX idx_cliente_evento_categoria
    ON cliente_evento (id_organizacion, categoria, occurred_at DESC);

-- Append-only al nivel del motor: service_role tiene BYPASSRLS y sin este
-- trigger podria reescribir el historial. Mismo patron que
-- fn_precio_snap_no_update (004) y fn_cotizacion_evento_no_update (040).
CREATE OR REPLACE FUNCTION fn_cliente_evento_no_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'cliente_evento es append-only: se llena solo por triggers de origen, nunca se edita directamente';
END;
$$;

CREATE TRIGGER trg_cliente_evento_no_update
    BEFORE UPDATE ON cliente_evento
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_evento_no_update();

CREATE TRIGGER trg_cliente_evento_no_delete
    BEFORE DELETE ON cliente_evento
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_evento_no_update();

-- ----------------------------------------------------------
-- 2. interaccion_cliente
-- ----------------------------------------------------------
CREATE TABLE interaccion_cliente (
    id_interaccion       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_organizacion      UUID        NOT NULL REFERENCES organizacion(id_organizacion),
    id_persona           UUID        REFERENCES persona(id_persona),
    id_canal_contacto    UUID        REFERENCES canal_contacto(id_canal_contacto),
    tipo_interaccion     TEXT        NOT NULL
                         CHECK (tipo_interaccion IN (
                             'EMAIL_INDIVIDUAL', 'WHATSAPP', 'LLAMADA', 'VISITA',
                             'REUNION', 'NOTA_INTERNA', 'RESPUESTA_ENTRANTE'
                         )),
    direccion            TEXT        NOT NULL CHECK (direccion IN ('INBOUND', 'OUTBOUND')),
    motivo               TEXT        NOT NULL
                         CHECK (motivo IN (
                             'MARKETING', 'COTIZACION', 'PEDIDO', 'SOPORTE', 'SEGUIMIENTO', 'OTRO'
                         )),
    -- PROGRAMADA cubre una visita o llamada agendada que aun no ocurre.
    -- No hay transicion PROGRAMADA -> REALIZADA en esta fase: se agrega
    -- cuando la UI (Fase 7) lo necesite. Registrar de nuevo si cambia.
    estado               TEXT        NOT NULL DEFAULT 'REALIZADA'
                         CHECK (estado IN ('PROGRAMADA', 'REALIZADA', 'CANCELADA')),
    asunto               TEXT,
    -- Solo resumen. El cuerpo completo de la conversacion se queda en el
    -- proveedor (WhatsApp, correo); su referencia va en metadata si aplica.
    resumen              TEXT,
    resultado            TEXT
                         CHECK (resultado IS NULL OR resultado IN (
                             'SIN_RESPUESTA', 'RESPONDIO', 'INTERESADO',
                             'NO_INTERESADO', 'COMPRA', 'REAGENDAR'
                         )),
    actor_tipo           TEXT        NOT NULL DEFAULT 'HUMANO'
                         CHECK (actor_tipo IN ('HUMANO', 'IA', 'SISTEMA', 'CLIENTE', 'PROVEEDOR')),
    actor_id             UUID        REFERENCES auth.users(id),
    actor_ref            TEXT,
    relacionado_con_tipo TEXT        CHECK (relacionado_con_tipo IS NULL OR relacionado_con_tipo IN (
                             'COTIZACION', 'PEDIDO', 'CAMPANIA'
                         )),
    relacionado_con_id   UUID,
    occurred_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata             JSONB       NOT NULL DEFAULT '{}',
    fts                  TSVECTOR    GENERATED ALWAYS AS (
                             to_tsvector('spanish', coalesce(asunto, '') || ' ' || coalesce(resumen, ''))
                         ) STORED,
    -- Un actor HUMANO sin identidad hace la auditoria inservible; para el
    -- resto (IA, SISTEMA, CLIENTE, PROVEEDOR) la referencia va en actor_ref.
    CONSTRAINT ck_interaccion_actor_humano
        CHECK (actor_tipo <> 'HUMANO' OR actor_id IS NOT NULL)
);

ALTER TABLE interaccion_cliente ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON interaccion_cliente
    AS RESTRICTIVE FOR ALL USING (false);

REVOKE ALL ON interaccion_cliente FROM anon, authenticated;

CREATE INDEX idx_interaccion_cliente_organizacion
    ON interaccion_cliente (id_organizacion, occurred_at DESC);
CREATE INDEX idx_interaccion_cliente_fts
    ON interaccion_cliente USING GIN (fts);

-- ----------------------------------------------------------
-- 3. Triggers que alimentan cliente_evento
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_cliente_evento_desde_interaccion()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO cliente_evento (
        id_organizacion, id_persona, categoria, tipo_evento, canal,
        source_table, source_id, resumen, occurred_at, metadata
    )
    VALUES (
        NEW.id_organizacion,
        NEW.id_persona,
        'INTERACCION',
        NEW.motivo,
        NEW.tipo_interaccion,
        'interaccion_cliente',
        NEW.id_interaccion,
        coalesce(NEW.asunto, initcap(replace(lower(NEW.tipo_interaccion), '_', ' '))),
        NEW.occurred_at,
        jsonb_build_object('direccion', NEW.direccion, 'estado', NEW.estado)
    )
    ON CONFLICT (source_table, source_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_interaccion_cliente_evento
    AFTER INSERT ON interaccion_cliente
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_evento_desde_interaccion();

CREATE OR REPLACE FUNCTION fn_cliente_evento_desde_cotizacion()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id_organizacion UUID;
    v_numero          BIGINT;
    v_resumen         TEXT;
BEGIN
    SELECT c.id_organizacion, c.numero
      INTO v_id_organizacion, v_numero
      FROM cotizacion c
     WHERE c.id_cotizacion = NEW.id_cotizacion;

    -- Una cotizacion sin organizacion (id_organizacion nullable en 029) no
    -- pertenece a ningun timeline de cliente.
    IF v_id_organizacion IS NULL THEN
        RETURN NEW;
    END IF;

    v_resumen := CASE
        WHEN NEW.tipo_evento = 'TRANSICION_ESTADO' THEN
            'Cotizacion #' || v_numero || ' paso de ' || NEW.estado_anterior || ' a ' || NEW.estado_nuevo
        WHEN NEW.tipo_evento = 'CREADA' THEN
            'Cotizacion #' || v_numero || ' creada'
        ELSE
            'Cotizacion #' || v_numero || ': ' || NEW.tipo_evento
    END;

    INSERT INTO cliente_evento (
        id_organizacion, categoria, tipo_evento, source_table, source_id,
        resumen, occurred_at, metadata
    )
    VALUES (
        v_id_organizacion, 'COTIZACION', NEW.tipo_evento, 'cotizacion_evento', NEW.id_cotizacion_evento,
        v_resumen, NEW.occurred_at,
        jsonb_build_object('id_cotizacion', NEW.id_cotizacion, 'numero', v_numero)
    )
    ON CONFLICT (source_table, source_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cotizacion_evento_cliente_evento
    AFTER INSERT ON cotizacion_evento
    FOR EACH ROW EXECUTE FUNCTION fn_cliente_evento_desde_cotizacion();

-- ----------------------------------------------------------
-- 4. Escritura y lectura para la consola
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_consola_registrar_interaccion(
    p_id_organizacion UUID,
    p_tipo_interaccion TEXT,
    p_direccion TEXT,
    p_motivo TEXT,
    p_asunto TEXT DEFAULT NULL,
    p_resumen TEXT DEFAULT NULL,
    p_resultado TEXT DEFAULT NULL,
    p_estado TEXT DEFAULT 'REALIZADA',
    p_id_persona UUID DEFAULT NULL,
    p_id_canal_contacto UUID DEFAULT NULL,
    p_relacionado_con_tipo TEXT DEFAULT NULL,
    p_relacionado_con_id UUID DEFAULT NULL,
    p_occurred_at TIMESTAMPTZ DEFAULT now()
)
RETURNS TABLE (
    id_interaccion UUID,
    estado         TEXT,
    occurred_at    TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_id  UUID;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden registrar interacciones.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    IF p_id_persona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM persona WHERE id_persona = p_id_persona) THEN
        RAISE EXCEPTION 'Persona no encontrada.';
    END IF;

    INSERT INTO interaccion_cliente (
        id_organizacion, id_persona, id_canal_contacto, tipo_interaccion,
        direccion, motivo, estado, asunto, resumen, resultado,
        actor_tipo, actor_id, relacionado_con_tipo, relacionado_con_id, occurred_at
    )
    VALUES (
        p_id_organizacion, p_id_persona, p_id_canal_contacto, p_tipo_interaccion,
        p_direccion, p_motivo, coalesce(p_estado, 'REALIZADA'),
        nullif(btrim(p_asunto), ''), nullif(btrim(p_resumen), ''), p_resultado,
        'HUMANO', auth.uid(), p_relacionado_con_tipo, p_relacionado_con_id,
        coalesce(p_occurred_at, now())
    )
    RETURNING interaccion_cliente.id_interaccion INTO v_id;

    RETURN QUERY
    SELECT ic.id_interaccion, ic.estado, ic.occurred_at
      FROM interaccion_cliente ic
     WHERE ic.id_interaccion = v_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_registrar_interaccion(
    UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_registrar_interaccion(
    UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, UUID, TIMESTAMPTZ
) TO authenticated;

-- Lee cliente_evento, no las tablas fuente: es el punto unico de lectura
-- del timeline que en Fase 5 reutilizara fn_ai_cliente_timeline.
CREATE OR REPLACE FUNCTION fn_consola_timeline_cliente(
    p_id_organizacion UUID,
    p_desde TIMESTAMPTZ DEFAULT NULL,
    p_limite INT DEFAULT 50
)
RETURNS TABLE (
    id_evento      UUID,
    categoria      TEXT,
    tipo_evento    TEXT,
    canal          TEXT,
    resumen        TEXT,
    persona_nombre TEXT,
    occurred_at    TIMESTAMPTZ,
    hay_mas        BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    -- Tope duro del lado del servidor: ninguna sesion puede pedir mas de
    -- 200 filas de una vez, sin importar que valor mande p_limite.
    v_limite INT := LEAST(GREATEST(coalesce(p_limite, 50), 1), 200);
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    RETURN QUERY
    WITH pagina AS (
        SELECT ce.*
          FROM cliente_evento ce
         WHERE ce.id_organizacion = p_id_organizacion
           AND (p_desde IS NULL OR ce.occurred_at >= p_desde)
         ORDER BY ce.occurred_at DESC
         LIMIT v_limite + 1
    )
    SELECT
        p.id_evento, p.categoria, p.tipo_evento, p.canal, p.resumen,
        per.nombre_completo,
        p.occurred_at,
        (count(*) OVER () > v_limite) AS hay_mas
      FROM pagina p
      LEFT JOIN persona per ON per.id_persona = p.id_persona
     ORDER BY p.occurred_at DESC
     LIMIT v_limite;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_timeline_cliente(UUID, TIMESTAMPTZ, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_timeline_cliente(UUID, TIMESTAMPTZ, INT) TO authenticated;

-- ----------------------------------------------------------
-- 5. Documentacion
-- ----------------------------------------------------------
COMMENT ON TABLE cliente_evento IS
    'Timeline consolidado append-only. Se llena por triggers AFTER INSERT sobre las tablas fuente (interaccion_cliente, cotizacion_evento, y las que se agreguen en fases posteriores). No reemplaza las tablas especificas: las resume para lectura unica.';

COMMENT ON TABLE interaccion_cliente IS
    'Todo contacto con un cliente sin importar el canal. resumen es el unico texto libre: el cuerpo completo de la conversacion se queda en el proveedor. PII: deny_all, se lee solo por fn_consola_timeline_cliente.';

COMMENT ON COLUMN interaccion_cliente.estado IS
    'PROGRAMADA cubre una visita o llamada agendada. No hay funcion de transicion PROGRAMADA->REALIZADA en esta fase; se agrega cuando la UI lo necesite.';

COMMENT ON FUNCTION fn_consola_timeline_cliente(UUID, TIMESTAMPTZ, INT) IS
    'Unica funcion de lectura del timeline de cliente. Tope duro de 200 filas por llamada; usar p_desde para paginar hacia atras en el tiempo.';
