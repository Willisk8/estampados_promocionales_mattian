-- ============================================================
-- 027_console_org_filters.sql
--
-- Mejora los filtros de organizaciones en la consola:
--   1. Devuelve fecha_reporte_oficial, para ver que tan viejo es el dato.
--   2. Filtro por municipio, que la funcion aceptaba pero nadie usaba.
--   3. Departamento y municipio comparan sin distinguir mayusculas ni acentos
--      parciales: los valores estan en mayuscula con tilde ('BOGOTA, D.C.',
--      'ATLANTICO'), y exigir coincidencia exacta hacia el filtro inservible.
--   4. Lista de departamentos y municipios para poblar los desplegables.
--
-- POR QUE IMPORTA LA FECHA
-- 1.209 de las 5.639 organizaciones tienen su ultimo reporte oficial entre 2017
-- y 2022. Una entidad reportada en 2017 puede haberse liquidado. Sin esa fecha
-- a la vista, la consola presenta como equivalentes un dato de este ano y uno
-- de hace nueve.
-- ============================================================

-- El tipo de retorno cambia, asi que hay que soltar la firma anterior.
DROP FUNCTION IF EXISTS fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT);

CREATE FUNCTION fn_consola_organizaciones(
    p_busqueda       TEXT    DEFAULT NULL,
    p_departamento   TEXT    DEFAULT NULL,
    p_municipio      TEXT    DEFAULT NULL,
    p_solo_con_email BOOLEAN DEFAULT NULL,
    p_limite         INT     DEFAULT 50,
    p_desplazamiento INT     DEFAULT 0
)
RETURNS TABLE (
    id_organizacion        UUID,
    nit                    TEXT,
    nombre_legal           TEXT,
    nombre_comercial       TEXT,
    tipo_entidad_origen    TEXT,
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
        SELECT o.*
          FROM organizacion o
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
    ),
    total AS (SELECT count(*) AS n FROM filtradas)
    SELECT
        f.id_organizacion, f.nit, f.nombre_legal, f.nombre_comercial,
        f.tipo_entidad_origen, f.departamento, f.municipio, f.estado,
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
      LEFT JOIN canal_contacto cc ON cc.id_organizacion = f.id_organizacion
     GROUP BY f.id_organizacion, f.nit, f.nombre_legal, f.nombre_comercial,
              f.tipo_entidad_origen, f.departamento, f.municipio, f.estado,
              f.fecha_reporte_oficial
     ORDER BY f.nombre_legal
     LIMIT v_limite OFFSET greatest(coalesce(p_desplazamiento, 0), 0);
END;
$$;

-- ----------------------------------------------------------
-- Ubicaciones para los desplegables
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_consola_ubicaciones(p_departamento TEXT DEFAULT NULL)
RETURNS TABLE (
    departamento  TEXT,
    municipio     TEXT,
    organizaciones BIGINT
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
    SELECT o.departamento, o.municipio, count(*)
      FROM organizacion o
     WHERE o.departamento IS NOT NULL
       AND (p_departamento IS NULL OR o.departamento ILIKE '%' || p_departamento || '%')
     GROUP BY o.departamento, o.municipio
     ORDER BY o.departamento, o.municipio;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT) TO authenticated;

REVOKE ALL ON FUNCTION fn_consola_ubicaciones(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_ubicaciones(TEXT) TO authenticated;
