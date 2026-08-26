-- ============================================================
-- 045_ai_customer_context.sql
--
-- Etapa C, Fase 5 — capa de IA: delegacion, contrato de estados, auditoria.
-- Plan: docs/plan_ia.md
--
-- DECISIONES DE ARQUITECTURA
--
-- 1. Delegacion, no rol de servicio. Cada fn_ai_* empieza leyendo
--    fn_consola_rol() del usuario que la invoca. Sin perfil activo, status
--    = FORBIDDEN. El agente nunca ve mas que el humano que lo invoco. No
--    hay trabajos programados sin humano en esta fase (fuera de alcance,
--    documentado en el plan): eso requeriria una identidad de servicio
--    que se descarto deliberadamente.
--
-- 2. Contrato de estados, nunca excepcion. OK / NOT_FOUND / INVALID_INPUT /
--    FORBIDDEN. TOO_LARGE queda reservado sin uso: los limites de pagina se
--    acotan en silencio (mismo criterio que fn_consola_timeline_cliente en
--    041), no se rechazan con un codigo aparte.
--
-- 3. Dos ayudantes internos evitan repetir el mismo preambulo en cada
--    fn_ai_*: fn_ai_resolver_sesion (crea o reutiliza ia_sesion) y
--    fn_ai_registrar_llamada (escribe la auditoria). Ninguno se otorga a
--    authenticated: solo se alcanzan por llamada anidada desde otra
--    funcion SECURITY DEFINER, que se ejecuta con el rol propietario. Si
--    se otorgaran directo, cualquier sesion podria insertar auditoria
--    falsa bajo el id de otra sesion.
--
-- 4. fn_ai_cliente_timeline pagina con cursor real (occurred_at <
--    p_antes_de), no con el filtro "desde" de fn_consola_timeline_cliente
--    (041). Son necesidades distintas: la consola quiere una ventana desde
--    una fecha fija; el agente necesita caminar hacia atras en el tiempo
--    sin perder ni repetir eventos.
--
-- 5. fn_ai_senales_cliente devuelve hechos, no una recomendacion. Una
--    funcion SQL no puede ejecutar un LLM; la recomendacion la redacta el
--    modelo a partir de estos hechos y se guarda despues con
--    fn_ai_registrar_recomendacion.
--
-- 6. ia_sesion / ia_llamada_herramienta / ia_recomendacion /
--    ia_accion_propuesta usan el patron consola_read (no deny_all): no
--    referencian persona ni contienen texto de conversaciones de cliente,
--    son auditoria de STAFF que ADMIN debe poder revisar.
--
-- 7. fn_ai_proponer_accion crea una propuesta con expira_at obligatorio.
--    Aprobarla o rechazarla es fn_consola_aprobar_accion_ia -un HUMANO la
--    invoca, por eso lleva el prefijo fn_consola_, no fn_ai_. Ninguna
--    funcion de esta migracion escribe sobre cotizacion/pedido/campania:
--    la IA propone, nunca ejecuta.
-- ============================================================

-- ----------------------------------------------------------
-- 1. Tablas de auditoria
-- ----------------------------------------------------------
CREATE TABLE ia_sesion (
    id_ia_sesion   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Nullable: incluso un intento sin identidad (auth.uid() nulo) debe
    -- quedar auditado, no reventar con una violacion de NOT NULL.
    id_usuario     UUID        REFERENCES auth.users(id),
    rol_consola    TEXT,
    iniciada_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata       JSONB       NOT NULL DEFAULT '{}'
);

ALTER TABLE ia_sesion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON ia_sesion AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON ia_sesion AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON ia_sesion AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON ia_sesion
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON ia_sesion
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON ia_sesion FROM anon, authenticated;
GRANT SELECT ON ia_sesion TO authenticated;

CREATE INDEX idx_ia_sesion_usuario ON ia_sesion (id_usuario, iniciada_at DESC);

CREATE TABLE ia_llamada_herramienta (
    id_ia_llamada_herramienta UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_ia_sesion              UUID        NOT NULL REFERENCES ia_sesion(id_ia_sesion) ON DELETE CASCADE,
    herramienta               TEXT        NOT NULL,
    argumentos                JSONB       NOT NULL DEFAULT '{}',
    status                    TEXT        NOT NULL
                              CHECK (status IN ('OK', 'NOT_FOUND', 'INVALID_INPUT', 'FORBIDDEN', 'TOO_LARGE')),
    filas_devueltas           INTEGER,
    ocurrido_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE ia_llamada_herramienta ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON ia_llamada_herramienta AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON ia_llamada_herramienta AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON ia_llamada_herramienta AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON ia_llamada_herramienta
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON ia_llamada_herramienta
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON ia_llamada_herramienta FROM anon, authenticated;
GRANT SELECT ON ia_llamada_herramienta TO authenticated;

CREATE INDEX idx_ia_llamada_sesion ON ia_llamada_herramienta (id_ia_sesion, ocurrido_at DESC);

-- Append-only al nivel del motor, mismo patron que 040/041/043.
CREATE OR REPLACE FUNCTION fn_ia_llamada_no_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'ia_llamada_herramienta es append-only: la auditoria de IA nunca se edita';
END;
$$;

CREATE TRIGGER trg_ia_llamada_no_update
    BEFORE UPDATE ON ia_llamada_herramienta
    FOR EACH ROW EXECUTE FUNCTION fn_ia_llamada_no_update();

CREATE TRIGGER trg_ia_llamada_no_delete
    BEFORE DELETE ON ia_llamada_herramienta
    FOR EACH ROW EXECUTE FUNCTION fn_ia_llamada_no_update();

CREATE TABLE ia_recomendacion (
    id_ia_recomendacion UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_ia_sesion         UUID        NOT NULL REFERENCES ia_sesion(id_ia_sesion),
    id_organizacion      UUID        NOT NULL REFERENCES organizacion(id_organizacion),
    -- Texto redactado por el modelo a partir de fn_ai_senales_cliente.
    -- Ninguna funcion de esta migracion genera este texto: lo trae el
    -- agente y esta funcion solo lo audita.
    texto                TEXT        NOT NULL,
    basada_en            JSONB       NOT NULL DEFAULT '{}',
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE ia_recomendacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON ia_recomendacion AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON ia_recomendacion AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON ia_recomendacion AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON ia_recomendacion
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON ia_recomendacion
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON ia_recomendacion FROM anon, authenticated;
GRANT SELECT ON ia_recomendacion TO authenticated;

CREATE INDEX idx_ia_recomendacion_organizacion ON ia_recomendacion (id_organizacion, created_at DESC);

CREATE TABLE ia_accion_propuesta (
    id_ia_accion_propuesta UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_ia_sesion            UUID        NOT NULL REFERENCES ia_sesion(id_ia_sesion),
    id_organizacion         UUID        NOT NULL REFERENCES organizacion(id_organizacion),
    -- Vocabulario deliberadamente acotado a lo que ya existe en el
    -- esquema. Fases posteriores (campanas) lo amplian con ALTER, no
    -- editando esta migracion.
    tipo_accion             TEXT        NOT NULL
                            CHECK (tipo_accion IN (
                                'PROGRAMAR_SEGUIMIENTO', 'REGISTRAR_INTERACCION',
                                'ACTUALIZAR_PREFERENCIA', 'OTRO'
                            )),
    payload                 JSONB       NOT NULL DEFAULT '{}',
    justificacion           TEXT        NOT NULL,
    estado                  TEXT        NOT NULL DEFAULT 'PENDIENTE'
                            CHECK (estado IN ('PENDIENTE', 'APROBADA', 'RECHAZADA', 'EJECUTADA', 'EXPIRADA')),
    aprobada_por            UUID        REFERENCES auth.users(id),
    aprobada_at             TIMESTAMPTZ,
    ejecutada_at            TIMESTAMPTZ,
    resultado               JSONB,
    -- Obligatorio: una propuesta sin vencimiento aprobada semanas despues
    -- se ejecutaria sobre un mundo distinto al que la genero.
    expira_at               TIMESTAMPTZ NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE ia_accion_propuesta ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON ia_accion_propuesta AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON ia_accion_propuesta AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON ia_accion_propuesta AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON ia_accion_propuesta
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON ia_accion_propuesta
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON ia_accion_propuesta FROM anon, authenticated;
GRANT SELECT ON ia_accion_propuesta TO authenticated;

CREATE INDEX idx_ia_accion_propuesta_pendientes
    ON ia_accion_propuesta (id_organizacion, created_at DESC)
    WHERE estado = 'PENDIENTE';

-- ----------------------------------------------------------
-- 2. Ayudantes internos (no se otorgan a authenticated)
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_ai_resolver_sesion(
    p_id_ia_sesion UUID,
    p_rol TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id     UUID;
    v_dueño UUID;
BEGIN
    IF p_id_ia_sesion IS NOT NULL THEN
        SELECT s.id_ia_sesion, s.id_usuario INTO v_id, v_dueño
          FROM ia_sesion s
         WHERE s.id_ia_sesion = p_id_ia_sesion;

        IF FOUND AND v_dueño IS NOT DISTINCT FROM auth.uid() THEN
            RETURN v_id;
        END IF;
        -- Sesion inexistente o de otro usuario: se abre una nueva en vez
        -- de fallar. fn_ai_* nunca lanza excepcion.
    END IF;

    INSERT INTO ia_sesion (id_usuario, rol_consola)
    VALUES (auth.uid(), p_rol)
    RETURNING id_ia_sesion INTO v_id;

    RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_resolver_sesion(UUID, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION fn_ai_registrar_llamada(
    p_id_ia_sesion UUID,
    p_herramienta TEXT,
    p_argumentos JSONB,
    p_status TEXT,
    p_filas_devueltas INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO ia_llamada_herramienta (
        id_ia_sesion, herramienta, argumentos, status, filas_devueltas
    )
    VALUES (
        p_id_ia_sesion, p_herramienta, coalesce(p_argumentos, '{}'::jsonb), p_status, p_filas_devueltas
    );
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_registrar_llamada(UUID, TEXT, JSONB, TEXT, INTEGER) FROM PUBLIC;

-- ----------------------------------------------------------
-- 3. fn_ai_cliente_resumen — tarjeta compacta (reusa fn_consola_cliente_360)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ai_cliente_resumen(
    p_id_organizacion UUID,
    p_id_ia_sesion UUID DEFAULT NULL
)
RETURNS TABLE (
    id_ia_sesion              UUID,
    status                     TEXT,
    nombre_legal                TEXT,
    nit                          TEXT,
    estado_comercial             TEXT,
    temperatura                  TEXT,
    canal_preferido              TEXT,
    cotizaciones_abiertas        INTEGER,
    total_pedidos                INTEGER,
    valor_total_cotizado         NUMERIC,
    valor_total_vendido          NUMERIC,
    fecha_ultima_interaccion     TIMESTAMPTZ,
    dias_desde_ultima_gestion    INTEGER,
    producto_mas_cotizado        TEXT,
    producto_mas_comprado        TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol       TEXT := fn_consola_rol();
    v_id_sesion UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
    v_360       RECORD;
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_resumen', jsonb_build_object('id_organizacion', p_id_organizacion), 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::INTEGER, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    IF p_id_organizacion IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_resumen', '{}'::jsonb, 'INVALID_INPUT', 0);
        RETURN QUERY SELECT v_id_sesion, 'INVALID_INPUT'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::INTEGER, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_resumen', jsonb_build_object('id_organizacion', p_id_organizacion), 'NOT_FOUND', 0);
        RETURN QUERY SELECT v_id_sesion, 'NOT_FOUND'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::INTEGER, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    SELECT * INTO v_360 FROM fn_consola_cliente_360(p_id_organizacion);

    PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_resumen', jsonb_build_object('id_organizacion', p_id_organizacion), 'OK', 1);

    RETURN QUERY SELECT
        v_id_sesion, 'OK'::TEXT,
        v_360.nombre_legal, v_360.nit, v_360.estado_comercial, v_360.temperatura, v_360.canal_preferido,
        v_360.cotizaciones_abiertas, v_360.total_pedidos, v_360.valor_total_cotizado, v_360.valor_total_vendido,
        v_360.fecha_ultima_interaccion, v_360.dias_desde_ultima_gestion,
        v_360.producto_mas_cotizado, v_360.producto_mas_comprado;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_cliente_resumen(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_cliente_resumen(UUID, UUID) TO authenticated;

-- ----------------------------------------------------------
-- 4. fn_ai_cliente_timeline — cursor real, tope duro
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ai_cliente_timeline(
    p_id_organizacion UUID,
    p_antes_de TIMESTAMPTZ DEFAULT NULL,
    p_limite INTEGER DEFAULT 20,
    p_id_ia_sesion UUID DEFAULT NULL
)
RETURNS TABLE (
    id_ia_sesion     UUID,
    status            TEXT,
    id_evento         UUID,
    categoria         TEXT,
    tipo_evento       TEXT,
    canal             TEXT,
    resumen           TEXT,
    occurred_at       TIMESTAMPTZ,
    hay_mas           BOOLEAN,
    siguiente_cursor  TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol       TEXT := fn_consola_rol();
    v_id_sesion UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
    -- Tope duro: mismo criterio que fn_consola_timeline_cliente (041).
    v_limite    INT  := LEAST(GREATEST(coalesce(p_limite, 20), 1), 200);
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_timeline', jsonb_build_object('id_organizacion', p_id_organizacion), 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::BOOLEAN, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF p_id_organizacion IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_timeline', '{}'::jsonb, 'INVALID_INPUT', 0);
        RETURN QUERY SELECT v_id_sesion, 'INVALID_INPUT'::TEXT, NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::BOOLEAN, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_timeline', jsonb_build_object('id_organizacion', p_id_organizacion), 'NOT_FOUND', 0);
        RETURN QUERY SELECT v_id_sesion, 'NOT_FOUND'::TEXT, NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ, NULL::BOOLEAN, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    PERFORM fn_ai_registrar_llamada(
        v_id_sesion, 'fn_ai_cliente_timeline',
        jsonb_build_object('id_organizacion', p_id_organizacion, 'antes_de', p_antes_de, 'limite', v_limite),
        'OK', NULL
    );

    RETURN QUERY
    WITH candidatos AS (
        SELECT ce.*
          FROM cliente_evento ce
         WHERE ce.id_organizacion = p_id_organizacion
           AND (p_antes_de IS NULL OR ce.occurred_at < p_antes_de)
         ORDER BY ce.occurred_at DESC
         LIMIT v_limite + 1
    ),
    pagina AS (
        SELECT * FROM candidatos ORDER BY occurred_at DESC LIMIT v_limite
    ),
    resumen_pagina AS (
        SELECT
            (SELECT count(*) FROM candidatos) > v_limite AS hay_mas,
            -- Calificado con el alias de la CTE: occurred_at tambien es el
            -- nombre de una columna de salida de esta funcion (RETURNS
            -- TABLE), y PL/pgSQL la trae al alcance como variable, lo que
            -- vuelve ambiguo el nombre sin calificar.
            (SELECT min(pagina.occurred_at) FROM pagina) AS siguiente_cursor
    )
    SELECT
        v_id_sesion, 'OK'::TEXT,
        p.id_evento, p.categoria, p.tipo_evento, p.canal, p.resumen, p.occurred_at,
        rp.hay_mas, rp.siguiente_cursor
      FROM pagina p
      CROSS JOIN resumen_pagina rp
     ORDER BY p.occurred_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_cliente_timeline(UUID, TIMESTAMPTZ, INTEGER, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_cliente_timeline(UUID, TIMESTAMPTZ, INTEGER, UUID) TO authenticated;

-- ----------------------------------------------------------
-- 5. fn_ai_cliente_metricas — detalle completo (reusa fn_consola_cliente_metricas)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ai_cliente_metricas(
    p_id_organizacion UUID,
    p_id_ia_sesion UUID DEFAULT NULL
)
RETURNS TABLE (
    id_ia_sesion                  UUID,
    status                         TEXT,
    total_interacciones            INTEGER,
    total_llamadas                  INTEGER,
    total_whatsapp                  INTEGER,
    total_visitas                   INTEGER,
    total_emails_marketing          INTEGER,
    total_cotizaciones              INTEGER,
    total_cotizaciones_aceptadas    INTEGER,
    total_pedidos                   INTEGER,
    valor_total_cotizado            NUMERIC,
    valor_total_vendido             NUMERIC,
    fecha_ultima_interaccion        TIMESTAMPTZ,
    fecha_ultima_cotizacion         TIMESTAMPTZ,
    fecha_ultimo_pedido             TIMESTAMPTZ,
    producto_mas_cotizado           TEXT,
    producto_mas_comprado           TEXT,
    dias_desde_ultima_gestion       INTEGER,
    score_engagement                 INTEGER,
    score_compra                     NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol       TEXT := fn_consola_rol();
    v_id_sesion UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
    v_m         RECORD;
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_metricas', jsonb_build_object('id_organizacion', p_id_organizacion), 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TEXT, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC;
        RETURN;
    END IF;

    IF p_id_organizacion IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_metricas', '{}'::jsonb, 'INVALID_INPUT', 0);
        RETURN QUERY SELECT v_id_sesion, 'INVALID_INPUT'::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TEXT, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_metricas', jsonb_build_object('id_organizacion', p_id_organizacion), 'NOT_FOUND', 0);
        RETURN QUERY SELECT v_id_sesion, 'NOT_FOUND'::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TEXT, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::NUMERIC;
        RETURN;
    END IF;

    SELECT * INTO v_m FROM fn_consola_cliente_metricas(p_id_organizacion);

    PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cliente_metricas', jsonb_build_object('id_organizacion', p_id_organizacion), 'OK', 1);

    RETURN QUERY SELECT
        v_id_sesion, 'OK'::TEXT,
        v_m.total_interacciones, v_m.total_llamadas, v_m.total_whatsapp, v_m.total_visitas, v_m.total_emails_marketing,
        v_m.total_cotizaciones, v_m.total_cotizaciones_aceptadas, v_m.total_pedidos,
        v_m.valor_total_cotizado, v_m.valor_total_vendido,
        v_m.fecha_ultima_interaccion, v_m.fecha_ultima_cotizacion, v_m.fecha_ultimo_pedido,
        v_m.producto_mas_cotizado, v_m.producto_mas_comprado, v_m.dias_desde_ultima_gestion,
        v_m.score_engagement, v_m.score_compra;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_cliente_metricas(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_cliente_metricas(UUID, UUID) TO authenticated;

-- ----------------------------------------------------------
-- 6. fn_ai_cotizaciones_activas
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ai_cotizaciones_activas(
    p_id_organizacion UUID,
    p_id_ia_sesion UUID DEFAULT NULL
)
RETURNS TABLE (
    id_ia_sesion       UUID,
    status              TEXT,
    numero               BIGINT,
    estado               TEXT,
    total                NUMERIC,
    fecha_emision        TIMESTAMPTZ,
    fecha_vencimiento    TIMESTAMPTZ,
    esta_vencida         BOOLEAN,
    dias_activa          INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol            TEXT := fn_consola_rol();
    v_id_sesion      UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
    v_limite CONSTANT INTEGER := 50;
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cotizaciones_activas', jsonb_build_object('id_organizacion', p_id_organizacion), 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::BIGINT, NULL::TEXT, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::BOOLEAN, NULL::INTEGER;
        RETURN;
    END IF;

    IF p_id_organizacion IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cotizaciones_activas', '{}'::jsonb, 'INVALID_INPUT', 0);
        RETURN QUERY SELECT v_id_sesion, 'INVALID_INPUT'::TEXT, NULL::BIGINT, NULL::TEXT, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::BOOLEAN, NULL::INTEGER;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cotizaciones_activas', jsonb_build_object('id_organizacion', p_id_organizacion), 'NOT_FOUND', 0);
        RETURN QUERY SELECT v_id_sesion, 'NOT_FOUND'::TEXT, NULL::BIGINT, NULL::TEXT, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::BOOLEAN, NULL::INTEGER;
        RETURN;
    END IF;

    PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_cotizaciones_activas', jsonb_build_object('id_organizacion', p_id_organizacion), 'OK',
        (SELECT count(*)::INTEGER FROM vw_cotizaciones_activas va WHERE va.id_organizacion = p_id_organizacion));

    RETURN QUERY
    SELECT v_id_sesion, 'OK'::TEXT, va.numero, va.estado, va.total, va.fecha_emision, va.fecha_vencimiento, va.esta_vencida, va.dias_activa
      FROM vw_cotizaciones_activas va
     WHERE va.id_organizacion = p_id_organizacion
     ORDER BY va.fecha_emision DESC NULLS LAST
     LIMIT v_limite;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_cotizaciones_activas(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_cotizaciones_activas(UUID, UUID) TO authenticated;

-- ----------------------------------------------------------
-- 7. fn_ai_pedidos_cliente
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ai_pedidos_cliente(
    p_id_organizacion UUID,
    p_id_ia_sesion UUID DEFAULT NULL
)
RETURNS TABLE (
    id_ia_sesion              UUID,
    status                     TEXT,
    numero                      BIGINT,
    estado                      TEXT,
    estado_pago                 TEXT,
    total                       NUMERIC,
    saldo                       NUMERIC,
    fecha_pedido                TIMESTAMPTZ,
    fecha_prometida_entrega     TIMESTAMPTZ,
    fecha_entrega_real          TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol            TEXT := fn_consola_rol();
    v_id_sesion      UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
    v_limite CONSTANT INTEGER := 50;
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_pedidos_cliente', jsonb_build_object('id_organizacion', p_id_organizacion), 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF p_id_organizacion IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_pedidos_cliente', '{}'::jsonb, 'INVALID_INPUT', 0);
        RETURN QUERY SELECT v_id_sesion, 'INVALID_INPUT'::TEXT, NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_pedidos_cliente', jsonb_build_object('id_organizacion', p_id_organizacion), 'NOT_FOUND', 0);
        RETURN QUERY SELECT v_id_sesion, 'NOT_FOUND'::TEXT, NULL::BIGINT, NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_pedidos_cliente', jsonb_build_object('id_organizacion', p_id_organizacion), 'OK',
        (SELECT count(*)::INTEGER FROM pedido p WHERE p.id_organizacion = p_id_organizacion));

    RETURN QUERY
    SELECT v_id_sesion, 'OK'::TEXT, p.numero, p.estado, p.estado_pago, p.total, p.saldo,
           p.fecha_pedido, p.fecha_prometida_entrega, p.fecha_entrega_real
      FROM pedido p
     WHERE p.id_organizacion = p_id_organizacion
     ORDER BY p.fecha_pedido DESC
     LIMIT v_limite;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_pedidos_cliente(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_pedidos_cliente(UUID, UUID) TO authenticated;

-- ----------------------------------------------------------
-- 8. fn_ai_senales_cliente — hechos, no recomendacion
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ai_senales_cliente(
    p_id_organizacion UUID,
    p_id_ia_sesion UUID DEFAULT NULL
)
RETURNS TABLE (
    id_ia_sesion               UUID,
    status                      TEXT,
    temperatura                  TEXT,
    dias_desde_ultima_gestion    INTEGER,
    estado_comercial              TEXT,
    cotizaciones_abiertas         INTEGER,
    cotizaciones_vencidas         INTEGER,
    seguimientos_pendientes       INTEGER,
    proximo_seguimiento_at        TIMESTAMPTZ,
    producto_mas_cotizado         TEXT,
    producto_mas_comprado         TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol       TEXT := fn_consola_rol();
    v_id_sesion UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
    v_360       RECORD;
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_senales_cliente', jsonb_build_object('id_organizacion', p_id_organizacion), 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::TEXT, NULL::INTEGER, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::TIMESTAMPTZ, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    IF p_id_organizacion IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_senales_cliente', '{}'::jsonb, 'INVALID_INPUT', 0);
        RETURN QUERY SELECT v_id_sesion, 'INVALID_INPUT'::TEXT, NULL::TEXT, NULL::INTEGER, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::TIMESTAMPTZ, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_senales_cliente', jsonb_build_object('id_organizacion', p_id_organizacion), 'NOT_FOUND', 0);
        RETURN QUERY SELECT v_id_sesion, 'NOT_FOUND'::TEXT, NULL::TEXT, NULL::INTEGER, NULL::TEXT, NULL::INTEGER, NULL::INTEGER, NULL::INTEGER, NULL::TIMESTAMPTZ, NULL::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    SELECT * INTO v_360 FROM fn_consola_cliente_360(p_id_organizacion);

    PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_senales_cliente', jsonb_build_object('id_organizacion', p_id_organizacion), 'OK', 1);

    RETURN QUERY
    SELECT
        v_id_sesion, 'OK'::TEXT,
        v_360.temperatura, v_360.dias_desde_ultima_gestion, v_360.estado_comercial,
        v_360.cotizaciones_abiertas,
        (SELECT count(*)::INTEGER FROM vw_cotizacion_vencimiento vv
           WHERE vv.id_organizacion = p_id_organizacion AND vv.esta_vencida),
        (SELECT count(*)::INTEGER FROM vw_clientes_para_followup vf
           WHERE vf.id_organizacion = p_id_organizacion),
        (SELECT min(vf.fecha_programada) FROM vw_clientes_para_followup vf
           WHERE vf.id_organizacion = p_id_organizacion),
        v_360.producto_mas_cotizado, v_360.producto_mas_comprado;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_senales_cliente(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_senales_cliente(UUID, UUID) TO authenticated;

-- ----------------------------------------------------------
-- 9. fn_ai_vocabulario — enums descubribles
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ai_vocabulario(
    p_id_ia_sesion UUID DEFAULT NULL
)
RETURNS TABLE (
    id_ia_sesion UUID,
    status        TEXT,
    entidad        TEXT,
    campo          TEXT,
    valores        TEXT[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol       TEXT := fn_consola_rol();
    v_id_sesion UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_vocabulario', '{}'::jsonb, 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT[];
        RETURN;
    END IF;

    PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_vocabulario', '{}'::jsonb, 'OK', 12);

    RETURN QUERY
    SELECT v_id_sesion, 'OK'::TEXT, x.entidad, x.campo, x.valores
      FROM (VALUES
        ('cotizacion', 'estado', ARRAY['BORRADOR','CALCULADA','PENDIENTE_APROBACION','APROBADA_INTERNAMENTE','EMITIDA','ENVIADA','VISTA','EN_SEGUIMIENTO','ACEPTADA','RECHAZADA','VENCIDA','ANULADA','CONVERTIDA_A_PEDIDO']),
        ('cotizacion', 'metodo_precio', ARRAY['TARIFA_PUBLICADA','CALCULO_COMPONENTES','MANUAL']),
        ('pedido', 'estado', ARRAY['RECIBIDO','EN_DISENO','PENDIENTE_APROBACION_ARTE','EN_PRODUCCION','LISTO_ENTREGA','ENTREGADO','FACTURADO','CERRADO','CANCELADO']),
        ('pedido', 'estado_pago', ARRAY['PENDIENTE','ANTICIPO_PAGADO','PAGADO','VENCIDO']),
        ('interaccion_cliente', 'tipo_interaccion', ARRAY['EMAIL_INDIVIDUAL','WHATSAPP','LLAMADA','VISITA','REUNION','NOTA_INTERNA','RESPUESTA_ENTRANTE']),
        ('interaccion_cliente', 'direccion', ARRAY['INBOUND','OUTBOUND']),
        ('interaccion_cliente', 'motivo', ARRAY['MARKETING','COTIZACION','PEDIDO','SOPORTE','SEGUIMIENTO','OTRO']),
        ('interaccion_cliente', 'resultado', ARRAY['SIN_RESPUESTA','RESPONDIO','INTERESADO','NO_INTERESADO','COMPRA','REAGENDAR']),
        ('cliente', 'temperatura', ARRAY['FRIO','ACTIVO','EN_NEGOCIACION','PERDIDO']),
        ('cliente', 'estado_comercial', ARRAY['PROSPECTO','CLIENTE','DESCARTADO','INACTIVO']),
        ('cliente_preferencia', 'sensibilidad_precio', ARRAY['ALTA','MEDIA','BAJA']),
        ('ia_accion_propuesta', 'tipo_accion', ARRAY['PROGRAMAR_SEGUIMIENTO','REGISTRAR_INTERACCION','ACTUALIZAR_PREFERENCIA','OTRO'])
      ) AS x(entidad, campo, valores);
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_vocabulario(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_vocabulario(UUID) TO authenticated;

-- ----------------------------------------------------------
-- 10. Recomendaciones y propuestas (la IA audita, no ejecuta)
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_ai_registrar_recomendacion(
    p_id_organizacion UUID,
    p_texto TEXT,
    p_basada_en JSONB DEFAULT '{}',
    p_id_ia_sesion UUID DEFAULT NULL
)
RETURNS TABLE (
    id_ia_sesion         UUID,
    status                TEXT,
    id_ia_recomendacion   UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol       TEXT := fn_consola_rol();
    v_id_sesion UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
    v_id        UUID;
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_registrar_recomendacion', jsonb_build_object('id_organizacion', p_id_organizacion), 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::UUID;
        RETURN;
    END IF;

    IF p_id_organizacion IS NULL OR nullif(btrim(coalesce(p_texto, '')), '') IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_registrar_recomendacion', '{}'::jsonb, 'INVALID_INPUT', 0);
        RETURN QUERY SELECT v_id_sesion, 'INVALID_INPUT'::TEXT, NULL::UUID;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_registrar_recomendacion', jsonb_build_object('id_organizacion', p_id_organizacion), 'NOT_FOUND', 0);
        RETURN QUERY SELECT v_id_sesion, 'NOT_FOUND'::TEXT, NULL::UUID;
        RETURN;
    END IF;

    INSERT INTO ia_recomendacion (id_ia_sesion, id_organizacion, texto, basada_en)
    VALUES (v_id_sesion, p_id_organizacion, btrim(p_texto), coalesce(p_basada_en, '{}'))
    RETURNING ia_recomendacion.id_ia_recomendacion INTO v_id;

    PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_registrar_recomendacion', jsonb_build_object('id_organizacion', p_id_organizacion), 'OK', 1);

    RETURN QUERY SELECT v_id_sesion, 'OK'::TEXT, v_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_registrar_recomendacion(UUID, TEXT, JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_registrar_recomendacion(UUID, TEXT, JSONB, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_ai_proponer_accion(
    p_id_organizacion UUID,
    p_tipo_accion TEXT,
    p_payload JSONB,
    p_justificacion TEXT,
    p_id_ia_sesion UUID DEFAULT NULL,
    p_vigencia_horas INTEGER DEFAULT 72
)
RETURNS TABLE (
    id_ia_sesion            UUID,
    status                   TEXT,
    id_ia_accion_propuesta   UUID,
    expira_at                TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol       TEXT := fn_consola_rol();
    v_id_sesion UUID := fn_ai_resolver_sesion(p_id_ia_sesion, v_rol);
    v_id        UUID;
    v_expira    TIMESTAMPTZ;
BEGIN
    IF v_rol IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_proponer_accion', jsonb_build_object('id_organizacion', p_id_organizacion), 'FORBIDDEN', 0);
        RETURN QUERY SELECT v_id_sesion, 'FORBIDDEN'::TEXT, NULL::UUID, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF p_id_organizacion IS NULL
       OR p_tipo_accion IS NULL
       OR p_tipo_accion NOT IN ('PROGRAMAR_SEGUIMIENTO', 'REGISTRAR_INTERACCION', 'ACTUALIZAR_PREFERENCIA', 'OTRO')
       OR nullif(btrim(coalesce(p_justificacion, '')), '') IS NULL THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_proponer_accion', '{}'::jsonb, 'INVALID_INPUT', 0);
        RETURN QUERY SELECT v_id_sesion, 'INVALID_INPUT'::TEXT, NULL::UUID, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_proponer_accion', jsonb_build_object('id_organizacion', p_id_organizacion), 'NOT_FOUND', 0);
        RETURN QUERY SELECT v_id_sesion, 'NOT_FOUND'::TEXT, NULL::UUID, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    v_expira := now() + make_interval(hours => coalesce(p_vigencia_horas, 72));

    INSERT INTO ia_accion_propuesta (
        id_ia_sesion, id_organizacion, tipo_accion, payload, justificacion, expira_at
    )
    VALUES (
        v_id_sesion, p_id_organizacion, p_tipo_accion, coalesce(p_payload, '{}'), btrim(p_justificacion), v_expira
    )
    RETURNING ia_accion_propuesta.id_ia_accion_propuesta INTO v_id;

    PERFORM fn_ai_registrar_llamada(v_id_sesion, 'fn_ai_proponer_accion', jsonb_build_object('id_organizacion', p_id_organizacion, 'tipo_accion', p_tipo_accion), 'OK', 1);

    RETURN QUERY SELECT v_id_sesion, 'OK'::TEXT, v_id, v_expira;
END;
$$;

REVOKE ALL ON FUNCTION fn_ai_proponer_accion(UUID, TEXT, JSONB, TEXT, UUID, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_ai_proponer_accion(UUID, TEXT, JSONB, TEXT, UUID, INTEGER) TO authenticated;

-- Un HUMANO aprueba o rechaza: prefijo fn_consola_, no fn_ai_.
CREATE OR REPLACE FUNCTION fn_consola_aprobar_accion_ia(
    p_id_ia_accion_propuesta UUID,
    p_aprobar BOOLEAN,
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_ia_accion_propuesta UUID,
    estado                  TEXT,
    aprobada_at             TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol           TEXT := fn_consola_rol();
    v_estado_actual TEXT;
    v_expira_at     TIMESTAMPTZ;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden aprobar o rechazar propuestas de IA.';
    END IF;

    SELECT iap.estado, iap.expira_at
      INTO v_estado_actual, v_expira_at
      FROM ia_accion_propuesta iap
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Propuesta no encontrada.';
    END IF;

    IF v_estado_actual <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'Solo se puede resolver una propuesta PENDIENTE. Estado actual: %', v_estado_actual;
    END IF;

    IF now() > v_expira_at THEN
        UPDATE ia_accion_propuesta SET estado = 'EXPIRADA'
         WHERE id_ia_accion_propuesta = p_id_ia_accion_propuesta;
        RAISE EXCEPTION 'La propuesta expiro el % y no puede aprobarse ni rechazarse.', v_expira_at;
    END IF;

    UPDATE ia_accion_propuesta iap
       SET estado       = CASE WHEN p_aprobar THEN 'APROBADA' ELSE 'RECHAZADA' END,
           aprobada_por = auth.uid(),
           aprobada_at  = now(),
           resultado    = CASE WHEN nullif(btrim(p_notas), '') IS NOT NULL
                                THEN jsonb_build_object('notas', btrim(p_notas))
                                ELSE iap.resultado END
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta;

    RETURN QUERY
    SELECT iap.id_ia_accion_propuesta, iap.estado, iap.aprobada_at
      FROM ia_accion_propuesta iap
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_aprobar_accion_ia(UUID, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_aprobar_accion_ia(UUID, BOOLEAN, TEXT) TO authenticated;

-- ----------------------------------------------------------
-- 11. Documentacion
-- ----------------------------------------------------------
COMMENT ON TABLE ia_sesion IS
    'Una sesion por conversacion con el agente. id_usuario delega en quien invoco, nunca una identidad de servicio propia (decision: sin trabajos programados sin humano en esta fase).';

COMMENT ON TABLE ia_llamada_herramienta IS
    'Auditoria append-only de cada fn_ai_* invocada. La escriben las propias funciones fn_ai_*, nunca el cliente: si el cliente pudiera escribirla, seria falsificable.';

COMMENT ON TABLE ia_accion_propuesta IS
    'Acciones que la IA propone y un humano aprueba o rechaza via fn_consola_aprobar_accion_ia. expira_at es obligatorio: una aprobacion tardia se ejecutaria sobre un mundo distinto al que la genero. Ninguna fn_ai_* de esta migracion escribe sobre cotizacion/pedido: la IA propone, nunca ejecuta.';

COMMENT ON FUNCTION fn_ai_senales_cliente(UUID, UUID) IS
    'Hechos para que el modelo redacte una recomendacion, no la recomendacion en si. Guardarla despues con fn_ai_registrar_recomendacion.';
