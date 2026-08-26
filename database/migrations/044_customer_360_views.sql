-- ============================================================
-- 044_customer_360_views.sql
--
-- Etapa C, Fase 4 — Cliente 360 y metricas.
-- Plan: docs/plan_ia.md
--
-- DECISIONES DE ARQUITECTURA
--
-- 1. vw_cliente_metricas, vw_cliente_360 y vw_clientes_sin_gestion del plan
--    original se implementan como FUNCIONES, no como vistas. Necesitan leer
--    cliente_evento/interaccion_cliente, que tienen deny_all por ser PII
--    (decision de Fase 1). Una vista con security_invoker=on hereda el RLS
--    de quien consulta y fallaria con "permission denied" para authenticated
--    -- es exactamente el error que se vio al escribir el test de pedidos.
--    El patron de este repo para agregar sobre una tabla PII es una funcion
--    SECURITY DEFINER que expone solo el agregado seguro (conteos, sumas,
--    fechas), nunca la fila cruda. La alternativa -una vista sin
--    security_invoker que haga bypass de RLS como owner- existe en el
--    repo (vw_campaign_eligibility_queue) pero esta reservada para vistas
--    que JAMAS se otorgan a authenticated. No es el caso aqui.
--
-- 2. vw_cliente_timeline del plan original NO se crea. Ya existe
--    fn_consola_timeline_cliente (041), que ademas resuelve tope duro,
--    cursor de paginacion y nombre de persona -algo que una vista no puede
--    parametrizar sin volverse una funcion de todas formas. Crear una
--    vista adicional habria sido una segunda puerta al mismo dato con
--    reglas potencialmente distintas.
--
-- 3. vw_cotizaciones_activas y vw_clientes_para_followup SI son vistas
--    normales: leen cotizacion/cotizacion_item/cotizacion_followup, que
--    tienen policy consola_read (no deny_all). No hay PII involucrada.
--
-- 4. Temperatura derivada, no almacenada. Umbral de "frio" como constante
--    unica (60 dias) dentro de fn_consola_cliente_metricas.
--
-- 5. score_engagement y score_compra son heuristicas MVP explicitas, no un
--    modelo: conteo de eventos en 90 dias, y proporcion vendido/cotizado.
--    Documentadas asi para que nadie las confunda con un score entrenado.
--
-- 6. No incluye "ultima campana" ni "proxima accion recomendada":
--    campanas no existen hasta Fase 8 (CREATE OR REPLACE FUNCTION las
--    anadira ahi, de forma aditiva); la recomendacion la redacta el modelo
--    en Fase 5 a partir de fn_ai_senales_cliente, no una funcion SQL.
--
-- 7. cliente_preferencia no es PII (no referencia persona ni contiene
--    texto de conversaciones): usa el mismo patron consola_read que
--    cotizacion/pedido, no deny_all.
-- ============================================================

-- ----------------------------------------------------------
-- 1. cliente_preferencia
-- ----------------------------------------------------------
CREATE TABLE cliente_preferencia (
    id_organizacion              UUID        PRIMARY KEY REFERENCES organizacion(id_organizacion) ON DELETE CASCADE,
    canal_preferido               TEXT        CHECK (canal_preferido IS NULL OR canal_preferido IN ('EMAIL', 'TELEFONO', 'WHATSAPP')),
    horario_preferido             TEXT,
    -- Informativa: lo que el cliente declaro. El limite que se APLICA vive
    -- en cliente_contact_policy (Fase 8). No configurar ambas por separado
    -- sin saber cual manda.
    frecuencia_contacto_preferida TEXT,
    -- Referencias sueltas a producto.id_producto, sin FK: un id obsoleto
    -- aqui es una preferencia desactualizada, no una inconsistencia de
    -- integridad que valga la pena imponer con un trigger.
    productos_interes             UUID[]      NOT NULL DEFAULT '{}',
    productos_no_interes          UUID[]      NOT NULL DEFAULT '{}',
    sensibilidad_precio           TEXT        DEFAULT 'MEDIA'
                                  CHECK (sensibilidad_precio IN ('ALTA', 'MEDIA', 'BAJA')),
    notas_comerciales             TEXT,
    actualizado_por               UUID        REFERENCES auth.users(id),
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON COLUMN cliente_preferencia.frecuencia_contacto_preferida IS
    'Informativa (lo que el cliente declaro). El limite que se aplica vive en cliente_contact_policy (Fase 8), no aqui.';

ALTER TABLE cliente_preferencia ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON cliente_preferencia AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON cliente_preferencia AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON cliente_preferencia AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON cliente_preferencia
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON cliente_preferencia
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON cliente_preferencia FROM anon, authenticated;
GRANT SELECT ON cliente_preferencia TO authenticated;

CREATE TRIGGER trg_cliente_preferencia_updated_at
    BEFORE UPDATE ON cliente_preferencia
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE OR REPLACE FUNCTION fn_consola_actualizar_preferencia_cliente(
    p_id_organizacion UUID,
    p_canal_preferido TEXT DEFAULT NULL,
    p_horario_preferido TEXT DEFAULT NULL,
    p_frecuencia_contacto_preferida TEXT DEFAULT NULL,
    p_productos_interes UUID[] DEFAULT NULL,
    p_productos_no_interes UUID[] DEFAULT NULL,
    p_sensibilidad_precio TEXT DEFAULT NULL,
    p_notas_comerciales TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_organizacion UUID,
    updated_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden actualizar preferencias de cliente.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    INSERT INTO cliente_preferencia (
        id_organizacion, canal_preferido, horario_preferido, frecuencia_contacto_preferida,
        productos_interes, productos_no_interes, sensibilidad_precio, notas_comerciales,
        actualizado_por
    )
    VALUES (
        p_id_organizacion, p_canal_preferido, p_horario_preferido, p_frecuencia_contacto_preferida,
        coalesce(p_productos_interes, '{}'), coalesce(p_productos_no_interes, '{}'),
        coalesce(p_sensibilidad_precio, 'MEDIA'), nullif(btrim(p_notas_comerciales), ''),
        auth.uid()
    )
    ON CONFLICT (id_organizacion) DO UPDATE
       SET canal_preferido               = EXCLUDED.canal_preferido,
           horario_preferido             = EXCLUDED.horario_preferido,
           frecuencia_contacto_preferida = EXCLUDED.frecuencia_contacto_preferida,
           productos_interes             = EXCLUDED.productos_interes,
           productos_no_interes          = EXCLUDED.productos_no_interes,
           sensibilidad_precio           = EXCLUDED.sensibilidad_precio,
           notas_comerciales             = EXCLUDED.notas_comerciales,
           actualizado_por               = EXCLUDED.actualizado_por,
           updated_at                    = now();

    RETURN QUERY
    SELECT cp.id_organizacion, cp.updated_at
      FROM cliente_preferencia cp
     WHERE cp.id_organizacion = p_id_organizacion;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_actualizar_preferencia_cliente(
    UUID, TEXT, TEXT, TEXT, UUID[], UUID[], TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_actualizar_preferencia_cliente(
    UUID, TEXT, TEXT, TEXT, UUID[], UUID[], TEXT, TEXT
) TO authenticated;

-- ----------------------------------------------------------
-- 2. Vistas normales (sin PII involucrada)
-- ----------------------------------------------------------

CREATE OR REPLACE VIEW vw_cotizaciones_activas
WITH (security_invoker = on) AS
SELECT
    c.id_cotizacion,
    c.numero,
    c.id_organizacion,
    c.estado,
    c.moneda,
    c.total,
    c.fecha_emision,
    c.fecha_vencimiento,
    v.esta_vencida,
    EXTRACT(day FROM now() - coalesce(c.fecha_emision, c.created_at))::INTEGER AS dias_activa
FROM cotizacion c
LEFT JOIN vw_cotizacion_vencimiento v ON v.id_cotizacion = c.id_cotizacion
WHERE c.estado NOT IN ('ANULADA', 'RECHAZADA', 'CONVERTIDA_A_PEDIDO');

REVOKE ALL ON vw_cotizaciones_activas FROM anon, authenticated;
GRANT SELECT ON vw_cotizaciones_activas TO authenticated;

CREATE OR REPLACE VIEW vw_clientes_para_followup
WITH (security_invoker = on) AS
SELECT
    cf.id_cotizacion_followup,
    cf.id_cotizacion,
    c.id_organizacion,
    c.numero AS numero_cotizacion,
    cf.fecha_programada,
    cf.notas,
    (cf.fecha_programada < now()) AS esta_atrasado
FROM cotizacion_followup cf
JOIN cotizacion c ON c.id_cotizacion = cf.id_cotizacion
WHERE cf.estado = 'PENDIENTE';

REVOKE ALL ON vw_clientes_para_followup FROM anon, authenticated;
GRANT SELECT ON vw_clientes_para_followup TO authenticated;

-- ----------------------------------------------------------
-- 3. Metricas de cliente (funcion: agrega sobre cliente_evento/PII)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_consola_cliente_metricas(
    p_id_organizacion UUID
)
RETURNS TABLE (
    total_interacciones          INTEGER,
    total_llamadas                INTEGER,
    total_whatsapp                INTEGER,
    total_visitas                 INTEGER,
    total_emails_marketing        INTEGER,
    total_cotizaciones            INTEGER,
    total_cotizaciones_aceptadas  INTEGER,
    total_pedidos                 INTEGER,
    valor_total_cotizado          NUMERIC,
    valor_total_vendido           NUMERIC,
    fecha_ultima_interaccion      TIMESTAMPTZ,
    fecha_ultima_cotizacion       TIMESTAMPTZ,
    fecha_ultimo_pedido           TIMESTAMPTZ,
    producto_mas_cotizado         TEXT,
    producto_mas_comprado         TEXT,
    dias_desde_ultima_gestion     INTEGER,
    -- Heuristicas MVP explicitas, no un modelo entrenado.
    score_engagement               INTEGER,
    score_compra                   NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_fecha_ultima_gestion TIMESTAMPTZ;
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    SELECT max(ce.occurred_at) INTO v_fecha_ultima_gestion
      FROM cliente_evento ce
     WHERE ce.id_organizacion = p_id_organizacion;

    RETURN QUERY
    WITH eventos AS (
        SELECT ce.* FROM cliente_evento ce WHERE ce.id_organizacion = p_id_organizacion
    ),
    cotizaciones AS (
        SELECT c.* FROM cotizacion c WHERE c.id_organizacion = p_id_organizacion
    ),
    pedidos AS (
        SELECT p.* FROM pedido p WHERE p.id_organizacion = p_id_organizacion
    ),
    top_cotizado AS (
        SELECT pr.nombre, sum(ci.cantidad) AS total_cantidad
          FROM cotizacion_item ci
          JOIN cotizaciones c ON c.id_cotizacion = ci.id_cotizacion
          JOIN producto pr ON pr.id_producto = ci.id_producto
         GROUP BY pr.nombre
         ORDER BY total_cantidad DESC
         LIMIT 1
    ),
    top_comprado AS (
        SELECT pr.nombre, sum(pi.cantidad) AS total_cantidad
          FROM pedido_item pi
          JOIN pedidos p ON p.id_pedido = pi.id_pedido
          JOIN producto pr ON pr.id_producto = pi.id_producto
         GROUP BY pr.nombre
         ORDER BY total_cantidad DESC
         LIMIT 1
    )
    SELECT
        (SELECT count(*) FROM eventos WHERE categoria = 'INTERACCION')::INTEGER,
        (SELECT count(*) FROM eventos WHERE categoria = 'INTERACCION' AND canal = 'LLAMADA')::INTEGER,
        (SELECT count(*) FROM eventos WHERE categoria = 'INTERACCION' AND canal = 'WHATSAPP')::INTEGER,
        (SELECT count(*) FROM eventos WHERE categoria = 'INTERACCION' AND canal = 'VISITA')::INTEGER,
        -- Cuenta interacciones de marketing hoy y eventos de campana cuando
        -- Fase 8 empiece a escribir categoria='MARKETING' en cliente_evento,
        -- sin tener que tocar esta funcion de nuevo.
        (SELECT count(*) FROM eventos
          WHERE categoria = 'MARKETING'
             OR (categoria = 'INTERACCION' AND tipo_evento = 'MARKETING'))::INTEGER,
        (SELECT count(*) FROM cotizaciones)::INTEGER,
        (SELECT count(*) FROM cotizaciones WHERE estado IN ('ACEPTADA', 'CONVERTIDA_A_PEDIDO'))::INTEGER,
        (SELECT count(*) FROM pedidos)::INTEGER,
        (SELECT coalesce(sum(total), 0) FROM cotizaciones),
        (SELECT coalesce(sum(total), 0) FROM pedidos),
        (SELECT max(occurred_at) FROM eventos WHERE categoria = 'INTERACCION'),
        (SELECT max(coalesce(fecha_emision, created_at)) FROM cotizaciones),
        (SELECT max(fecha_pedido) FROM pedidos),
        (SELECT nombre FROM top_cotizado),
        (SELECT nombre FROM top_comprado),
        CASE WHEN v_fecha_ultima_gestion IS NULL THEN NULL
             ELSE EXTRACT(day FROM now() - v_fecha_ultima_gestion)::INTEGER
        END,
        (SELECT count(*) FROM eventos WHERE occurred_at > now() - interval '90 days')::INTEGER,
        CASE
            WHEN (SELECT coalesce(sum(total), 0) FROM cotizaciones) = 0 THEN NULL
            ELSE round(
                (SELECT coalesce(sum(total), 0) FROM pedidos)
                / (SELECT sum(total) FROM cotizaciones),
                4
            )
        END;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_cliente_metricas(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_cliente_metricas(UUID) TO authenticated;

-- ----------------------------------------------------------
-- 4. Cliente 360 (funcion: reusa metricas, anade temperatura)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_consola_cliente_360(
    p_id_organizacion UUID
)
RETURNS TABLE (
    id_organizacion              UUID,
    nombre_legal                  TEXT,
    nit                            TEXT,
    departamento                   TEXT,
    municipio                      TEXT,
    estado_comercial               TEXT,
    prioridad                      TEXT,
    canal_preferido                TEXT,
    temperatura                    TEXT,
    cotizaciones_abiertas          INTEGER,
    -- Columnas planas de fn_consola_cliente_metricas, no un tipo anidado:
    -- ningun otro consumidor de este esquema devuelve registros compuestos.
    total_interacciones            INTEGER,
    total_cotizaciones             INTEGER,
    total_cotizaciones_aceptadas   INTEGER,
    total_pedidos                  INTEGER,
    valor_total_cotizado           NUMERIC,
    valor_total_vendido            NUMERIC,
    fecha_ultima_interaccion       TIMESTAMPTZ,
    fecha_ultima_cotizacion        TIMESTAMPTZ,
    fecha_ultimo_pedido            TIMESTAMPTZ,
    producto_mas_cotizado          TEXT,
    producto_mas_comprado          TEXT,
    dias_desde_ultima_gestion      INTEGER,
    score_engagement                INTEGER,
    score_compra                    NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    -- Umbral unico de "frio": ajustar solo aqui.
    v_dias_frio CONSTANT INTEGER := 60;
    v_estado_comercial TEXT;
    v_en_negociacion    BOOLEAN;
    v_metricas          RECORD;
    v_temperatura       TEXT;
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion o WHERE o.id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    SELECT r.estado_comercial INTO v_estado_comercial
      FROM relacion_comercial_organizacion r
     WHERE r.id_organizacion = p_id_organizacion;

    SELECT EXISTS (
        SELECT 1 FROM cotizacion c
         WHERE c.id_organizacion = p_id_organizacion
           AND c.estado IN ('ENVIADA', 'VISTA', 'EN_SEGUIMIENTO')
    ) INTO v_en_negociacion;

    SELECT * INTO v_metricas FROM fn_consola_cliente_metricas(p_id_organizacion);

    -- Precedencia explicita: una decision humana (DESCARTADO) siempre gana
    -- sobre cualquier senal derivada.
    v_temperatura := CASE
        WHEN v_estado_comercial = 'DESCARTADO' THEN 'PERDIDO'
        WHEN v_en_negociacion THEN 'EN_NEGOCIACION'
        WHEN v_metricas.dias_desde_ultima_gestion IS NULL
             OR v_metricas.dias_desde_ultima_gestion > v_dias_frio THEN 'FRIO'
        ELSE 'ACTIVO'
    END;

    RETURN QUERY
    SELECT
        o.id_organizacion, o.nombre_legal, o.nit, o.departamento, o.municipio,
        coalesce(v_estado_comercial, 'PROSPECTO'),
        coalesce(r.prioridad, 'MEDIA'),
        cp.canal_preferido,
        v_temperatura,
        (SELECT count(*)::INTEGER FROM vw_cotizaciones_activas va WHERE va.id_organizacion = p_id_organizacion),
        v_metricas.total_interacciones,
        v_metricas.total_cotizaciones,
        v_metricas.total_cotizaciones_aceptadas,
        v_metricas.total_pedidos,
        v_metricas.valor_total_cotizado,
        v_metricas.valor_total_vendido,
        v_metricas.fecha_ultima_interaccion,
        v_metricas.fecha_ultima_cotizacion,
        v_metricas.fecha_ultimo_pedido,
        v_metricas.producto_mas_cotizado,
        v_metricas.producto_mas_comprado,
        v_metricas.dias_desde_ultima_gestion,
        v_metricas.score_engagement,
        v_metricas.score_compra
      FROM organizacion o
      LEFT JOIN relacion_comercial_organizacion r ON r.id_organizacion = o.id_organizacion
      LEFT JOIN cliente_preferencia cp ON cp.id_organizacion = o.id_organizacion
     WHERE o.id_organizacion = p_id_organizacion;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_cliente_360(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_cliente_360(UUID) TO authenticated;

-- ----------------------------------------------------------
-- 5. Clientes sin gestion (funcion: agrega sobre cliente_evento)
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_consola_clientes_sin_gestion(
    p_dias_umbral INTEGER DEFAULT 30
)
RETURNS TABLE (
    id_organizacion       UUID,
    nombre_legal           TEXT,
    estado_comercial        TEXT,
    fecha_ultima_gestion    TIMESTAMPTZ,
    dias_sin_gestion        INTEGER
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    RETURN QUERY
    WITH ultima_gestion AS (
        SELECT ce.id_organizacion, max(ce.occurred_at) AS fecha_ultima_gestion
          FROM cliente_evento ce
         GROUP BY ce.id_organizacion
    )
    SELECT
        o.id_organizacion,
        o.nombre_legal,
        coalesce(r.estado_comercial, 'PROSPECTO'),
        ug.fecha_ultima_gestion,
        CASE WHEN ug.fecha_ultima_gestion IS NULL THEN NULL
             ELSE EXTRACT(day FROM now() - ug.fecha_ultima_gestion)::INTEGER
        END
      FROM organizacion o
      LEFT JOIN relacion_comercial_organizacion r ON r.id_organizacion = o.id_organizacion
      LEFT JOIN ultima_gestion ug ON ug.id_organizacion = o.id_organizacion
     WHERE coalesce(r.estado_comercial, 'PROSPECTO') NOT IN ('DESCARTADO', 'INACTIVO')
       AND (
            ug.fecha_ultima_gestion IS NULL
            OR ug.fecha_ultima_gestion < now() - make_interval(days => p_dias_umbral)
       )
     ORDER BY ug.fecha_ultima_gestion ASC NULLS FIRST;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_clientes_sin_gestion(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_clientes_sin_gestion(INTEGER) TO authenticated;

-- ----------------------------------------------------------
-- 6. cat_estado_oportunidad: documentar que no se usa
-- ----------------------------------------------------------
COMMENT ON TABLE cat_estado_oportunidad IS
    'NO USADA. Ninguna tabla la referencia. El estado comercial vive en relacion_comercial_organizacion.estado_comercial (fuente unica); la temperatura del cliente (frio/activo/en_negociacion/perdido) se deriva en fn_consola_cliente_360, no se almacena. No activar esta tabla sin retirar antes esa decision: un tercer vocabulario de estado se desincroniza con los otros dos.';

-- ----------------------------------------------------------
-- 7. Documentacion
-- ----------------------------------------------------------
COMMENT ON FUNCTION fn_consola_cliente_metricas(UUID) IS
    'Agregados de un cliente. Lee cliente_evento (PII, deny_all) por eso es funcion y no vista. score_engagement = eventos en 90 dias; score_compra = vendido/cotizado. Heuristicas MVP, no un modelo.';

COMMENT ON FUNCTION fn_consola_cliente_360(UUID) IS
    'Vista 360 de un cliente. Reusa fn_consola_cliente_metricas. No incluye ultima campana (Fase 8) ni proxima accion recomendada (Fase 5 + modelo). Temperatura: DESCARTADO humano > EN_NEGOCIACION (cotizacion activa) > FRIO (>60 dias sin gestion) > ACTIVO.';

COMMENT ON FUNCTION fn_consola_clientes_sin_gestion(INTEGER) IS
    'Organizaciones sin evento en cliente_evento en los ultimos p_dias_umbral dias. Excluye DESCARTADO/INACTIVO.';
