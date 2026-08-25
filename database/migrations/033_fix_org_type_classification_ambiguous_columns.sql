-- ============================================================
-- 033_fix_org_type_classification_ambiguous_columns.sql
--
-- Corrige referencias ambiguas en la clasificacion de tipo de organizacion.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_consola_clasificar_tipo_organizacion(
    p_id_organizacion UUID,
    p_tipo_codigo TEXT,
    p_criterio TEXT DEFAULT 'MANUAL'
)
RETURNS TABLE (
    id_organizacion UUID,
    tipo_codigo TEXT,
    tipo_descripcion TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_tipo_nuevo UUID;
    v_tipo_anterior UUID;
    v_origen TEXT;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden clasificar organizaciones.';
    END IF;

    SELECT c.id INTO v_tipo_nuevo
      FROM cat_tipo_organizacion c
     WHERE c.codigo = p_tipo_codigo;

    IF v_tipo_nuevo IS NULL THEN
        RAISE EXCEPTION 'Tipo de organizacion invalido: %', p_tipo_codigo;
    END IF;

    SELECT o.id_tipo_organizacion, o.tipo_entidad_origen
      INTO v_tipo_anterior, v_origen
      FROM organizacion o
     WHERE o.id_organizacion = p_id_organizacion
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    UPDATE organizacion o
       SET id_tipo_organizacion = v_tipo_nuevo
     WHERE o.id_organizacion = p_id_organizacion;

    INSERT INTO auditoria_tipo_organizacion (
        id_organizacion, id_tipo_anterior, id_tipo_nuevo, tipo_entidad_origen,
        criterio, clasificado_por, rol_consola
    )
    VALUES (
        p_id_organizacion, v_tipo_anterior, v_tipo_nuevo, v_origen,
        coalesce(nullif(btrim(p_criterio), ''), 'MANUAL'), auth.uid(), v_rol
    );

    RETURN QUERY
    SELECT o.id_organizacion, c.codigo, c.descripcion
      FROM organizacion o
      JOIN cat_tipo_organizacion c ON c.id = o.id_tipo_organizacion
     WHERE o.id_organizacion = p_id_organizacion;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_clasificar_tipo_organizacion(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_clasificar_tipo_organizacion(UUID, TEXT, TEXT) TO authenticated;
