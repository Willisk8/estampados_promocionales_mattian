-- ============================================================
-- 032_fix_commercial_state_upsert_conflict.sql
--
-- Evita ambiguedad PL/pgSQL en el UPSERT de estado comercial. En funciones
-- RETURNS TABLE, id_organizacion tambien existe como variable de salida, asi
-- que ON CONFLICT (id_organizacion) puede ser ambiguo.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_consola_actualizar_estado_comercial(
    p_id_organizacion UUID,
    p_estado_comercial TEXT,
    p_prioridad TEXT DEFAULT 'MEDIA',
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_organizacion UUID,
    estado_comercial TEXT,
    prioridad TEXT,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden actualizar estado comercial.';
    END IF;

    IF p_estado_comercial NOT IN ('PROSPECTO', 'CLIENTE', 'DESCARTADO', 'INACTIVO') THEN
        RAISE EXCEPTION 'Estado comercial invalido: %', p_estado_comercial;
    END IF;

    IF coalesce(p_prioridad, 'MEDIA') NOT IN ('ALTA', 'MEDIA', 'BAJA') THEN
        RAISE EXCEPTION 'Prioridad invalida: %', p_prioridad;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM organizacion o
         WHERE o.id_organizacion = p_id_organizacion
    ) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    INSERT INTO relacion_comercial_organizacion (
        id_organizacion, estado_comercial, prioridad, notas, actualizado_por
    )
    VALUES (
        p_id_organizacion, p_estado_comercial, coalesce(p_prioridad, 'MEDIA'),
        nullif(btrim(p_notas), ''), auth.uid()
    )
    ON CONFLICT ON CONSTRAINT relacion_comercial_organizacion_pkey DO UPDATE
       SET estado_comercial = EXCLUDED.estado_comercial,
           prioridad = EXCLUDED.prioridad,
           notas = EXCLUDED.notas,
           actualizado_por = EXCLUDED.actualizado_por,
           updated_at = now();

    RETURN QUERY
    SELECT r.id_organizacion, r.estado_comercial, r.prioridad, r.updated_at
      FROM relacion_comercial_organizacion r
     WHERE r.id_organizacion = p_id_organizacion;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_actualizar_estado_comercial(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_actualizar_estado_comercial(UUID, TEXT, TEXT, TEXT) TO authenticated;
