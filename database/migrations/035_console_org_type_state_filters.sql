-- ============================================================
-- 035_console_org_type_state_filters.sql
--
-- Cierra el paso 6 y el punto "Clientes/Prospectos" del plan de consola
-- operativa:
--   1. fn_consola_organizaciones gana filtro por tipo normalizado y por
--      estado comercial.
--   2. fn_consola_clientes_prospectos: pantalla separada que solo muestra
--      organizaciones con relacion comercial explicita (join interno contra
--      relacion_comercial_organizacion), no las 5.639 organizaciones. Es la
--      diferencia entre "toda la base de prospectos" y "lo que el equipo
--      comercial ya esta trabajando activamente".
-- ============================================================

DROP FUNCTION IF EXISTS fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT);

CREATE FUNCTION fn_consola_organizaciones(
    p_busqueda         TEXT    DEFAULT NULL,
    p_departamento     TEXT    DEFAULT NULL,
    p_municipio        TEXT    DEFAULT NULL,
    p_solo_con_email   BOOLEAN DEFAULT NULL,
    p_limite           INT     DEFAULT 50,
    p_desplazamiento   INT     DEFAULT 0,
    p_tipo_codigo      TEXT    DEFAULT NULL,
    p_estado_comercial TEXT    DEFAULT NULL
)
RETURNS TABLE (
    id_organizacion        UUID,
    nit                    TEXT,
    nombre_legal           TEXT,
    nombre_comercial       TEXT,
    tipo_entidad_origen    TEXT,
    tipo_codigo            TEXT,
    tipo_descripcion       TEXT,
    estado_comercial       TEXT,
    prioridad_comercial    TEXT,
    departamento           TEXT,
    municipio              TEXT,
    estado                 TEXT,
    fecha_reporte_oficial  TIMESTAMPTZ,
    anios_desde_reporte    INT,
    emails                 BIGINT,
    telefonos              BIGINT,
    whatsapps              BIGINT,
    websites               BIGINT,
    total_filas            BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_limite INT := least(greatest(coalesce(p_limite, 50), 1), 200);
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    RETURN QUERY
    WITH filtradas AS (
        SELECT o.*, c.codigo AS tipo_codigo_o, r.estado_comercial AS estado_comercial_o,
               r.prioridad AS prioridad_o
          FROM organizacion o
          LEFT JOIN cat_tipo_organizacion c ON c.id = o.id_tipo_organizacion
          LEFT JOIN relacion_comercial_organizacion r ON r.id_organizacion = o.id_organizacion
         WHERE (p_busqueda IS NULL
                OR o.nombre_legal ILIKE '%' || p_busqueda || '%'
                OR o.nombre_comercial ILIKE '%' || p_busqueda || '%'
                OR o.nit = p_busqueda)
           AND (p_departamento IS NULL OR o.departamento ILIKE '%' || p_departamento || '%')
           AND (p_municipio IS NULL OR o.municipio ILIKE '%' || p_municipio || '%')
           AND (p_solo_con_email IS NOT TRUE OR EXISTS (
                    SELECT 1 FROM canal_contacto cc
                     WHERE cc.id_organizacion = o.id_organizacion
                       AND cc.tipo = 'EMAIL' AND cc.estado = 'ACTIVE'))
           AND (p_tipo_codigo IS NULL OR c.codigo = p_tipo_codigo)
           AND (
                p_estado_comercial IS NULL
                OR coalesce(r.estado_comercial, 'PROSPECTO') = p_estado_comercial
           )
    ),
    total AS (SELECT count(*) AS n FROM filtradas)
    SELECT
        f.id_organizacion, f.nit, f.nombre_legal, f.nombre_comercial,
        f.tipo_entidad_origen, f.tipo_codigo_o, tc.descripcion,
        coalesce(f.estado_comercial_o, 'PROSPECTO'),
        coalesce(f.prioridad_o, 'MEDIA'),
        f.departamento, f.municipio, f.estado,
        f.fecha_reporte_oficial,
        CASE
            WHEN f.fecha_reporte_oficial IS NULL THEN NULL
            ELSE date_part('year', age(now(), f.fecha_reporte_oficial))::INT
        END,
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'EMAIL'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'TELEFONO'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'WHATSAPP'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'WEBSITE'),
        (SELECT n FROM total)
      FROM filtradas f
      LEFT JOIN cat_tipo_organizacion tc ON tc.codigo = f.tipo_codigo_o
      LEFT JOIN canal_contacto cc ON cc.id_organizacion = f.id_organizacion
     GROUP BY f.id_organizacion, f.nit, f.nombre_legal, f.nombre_comercial,
              f.tipo_entidad_origen, f.tipo_codigo_o, tc.descripcion,
              f.estado_comercial_o, f.prioridad_o, f.departamento, f.municipio,
              f.estado, f.fecha_reporte_oficial
     ORDER BY f.nombre_legal
     LIMIT v_limite OFFSET greatest(coalesce(p_desplazamiento, 0), 0);
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT, TEXT, TEXT) TO authenticated;

-- ----------------------------------------------------------
-- Pantalla Clientes/Prospectos: solo organizaciones con relacion comercial
-- explicita. INNER JOIN, no LEFT: la tabla completa de organizaciones sigue
-- viviendo en /organizaciones.
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_consola_clientes_prospectos(
    p_estado_comercial TEXT DEFAULT NULL,
    p_prioridad        TEXT DEFAULT NULL,
    p_limite           INT  DEFAULT 50,
    p_desplazamiento   INT  DEFAULT 0
)
RETURNS TABLE (
    id_organizacion     UUID,
    nit                 TEXT,
    nombre_legal        TEXT,
    tipo_codigo         TEXT,
    departamento        TEXT,
    municipio           TEXT,
    estado_comercial    TEXT,
    prioridad           TEXT,
    notas               TEXT,
    actualizado_en       TIMESTAMPTZ,
    total_filas         BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_limite INT := least(greatest(coalesce(p_limite, 50), 1), 200);
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    RETURN QUERY
    WITH filtradas AS (
        SELECT r.*, o.nombre_legal, o.nit, o.departamento, o.municipio, c.codigo AS tipo_codigo
          FROM relacion_comercial_organizacion r
          JOIN organizacion o ON o.id_organizacion = r.id_organizacion
          LEFT JOIN cat_tipo_organizacion c ON c.id = o.id_tipo_organizacion
         WHERE (p_estado_comercial IS NULL OR r.estado_comercial = p_estado_comercial)
           AND (p_prioridad IS NULL OR r.prioridad = p_prioridad)
    ),
    total AS (SELECT count(*) AS n FROM filtradas)
    SELECT
        f.id_organizacion, f.nit, f.nombre_legal, f.tipo_codigo,
        f.departamento, f.municipio, f.estado_comercial, f.prioridad, f.notas,
        f.updated_at, (SELECT n FROM total)
      FROM filtradas f
     ORDER BY
        CASE f.prioridad WHEN 'ALTA' THEN 1 WHEN 'MEDIA' THEN 2 ELSE 3 END,
        f.updated_at DESC
     LIMIT v_limite OFFSET greatest(coalesce(p_desplazamiento, 0), 0);
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_clientes_prospectos(TEXT, TEXT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_clientes_prospectos(TEXT, TEXT, INT, INT) TO authenticated;
