-- ============================================================
-- 051_gate_pii_anonymization_to_admin.sql
--
-- Corrige un hallazgo critico de auditoria externa (sesion willi-eb),
-- verificado de forma independiente antes de escribir esta correccion.
--
-- HALLAZGO
-- fn_anonymize_import_raw_rows (022) es SECURITY DEFINER y hace un UPDATE
-- destructivo e IRREVERSIBLE que borra el PII crudo (raw_payload,
-- normalized_payload) de import_raw_row cuando p_dry_run=false. No tiene
-- NINGUN chequeo de rol -ni siquiera el patron roto "v_rol NOT IN(...)"
-- que tenian las 14 funciones de 046-: nunca llama a fn_consola_rol().
--
-- Solo tenia REVOKE ALL ... FROM PUBLIC (022). El REVOKE EXECUTE ON ALL
-- FUNCTIONS ... FROM anon de 046 fue retroactivo y SI la alcanzo
-- (confirmado: anon ya no tiene EXECUTE). Pero authenticated no estaba
-- cubierto por ningun REVOKE explicito de 022, y el ALTER DEFAULT
-- PRIVILEGES de 047 (que revoco el default de authenticated) solo aplica
-- a funciones creadas DESPUES de esa fecha, no retroactivamente a esta.
--
-- Confirmado en vivo antes de corregir: has_function_privilege('authenticated', ..., 'EXECUTE') = true.
--
-- Efecto: cualquier cuenta autenticada -incluida una recien creada, sin
-- fila en perfil_usuario- podia llamar fn_anonymize_import_raw_rows(90, false)
-- directo y destruir de forma irreversible el lineage de PII de
-- import_raw_row, sin dejar ningun rastro de quien lo hizo.
--
-- CORRECCION
-- Guardia ADMIN como primer chequeo (esta es una operacion de retencion/
-- cumplimiento, no una accion comercial: mismo nivel que "costos del
-- catalogo propio" en docs/consola_acceso.md, no ADMIN+COMERCIAL). Se
-- mantiene el modo dry_run por defecto (true) sin cambios. Se revoca
-- authenticated explicitamente -el REVOKE de PUBLIC en 022 nunca lo cubrio-
-- y se vuelve a otorgar via GRANT explicito, para que solo ADMIN (que si
-- es authenticated) pueda seguir invocandola, con el filtro ahora dentro
-- de la funcion.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_anonymize_import_raw_rows(
    p_retention_days INTEGER DEFAULT 90,
    p_dry_run BOOLEAN DEFAULT true
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cutoff TIMESTAMPTZ;
    v_count INTEGER;
BEGIN
    -- Operacion de retencion/cumplimiento sobre PII, destructiva e
    -- irreversible cuando p_dry_run=false: mismo nivel de acceso que
    -- "costos del catalogo propio" (solo ADMIN, no COMERCIAL).
    IF fn_consola_rol() IS DISTINCT FROM 'ADMIN' THEN
        RAISE EXCEPTION 'Solo ADMIN puede ejecutar la anonimizacion de import_raw_row.';
    END IF;

    IF p_retention_days IS NULL OR p_retention_days <= 0 THEN
        RAISE EXCEPTION 'p_retention_days debe ser mayor que cero';
    END IF;

    v_cutoff := now() - make_interval(days => p_retention_days);

    SELECT COUNT(*)
      INTO v_count
      FROM import_raw_row
     WHERE created_at < v_cutoff
       AND anonymized_at IS NULL;

    IF p_dry_run THEN
        RETURN v_count;
    END IF;

    UPDATE import_raw_row
       SET raw_payload = jsonb_build_object(
               '_anonymized', true,
               '_anonymized_at', now(),
               '_retention_days', p_retention_days,
               '_note', 'Payload crudo anonimizado por politica de retencion; linaje minimo conservado en columnas estructuradas.'
           ),
           normalized_payload = jsonb_build_object(
               '_anonymized', true,
               '_anonymized_at', now(),
               '_retention_days', p_retention_days,
               '_note', 'Payload normalizado anonimizado por politica de retencion; linaje minimo conservado en columnas estructuradas.'
           ),
           anonymized_at = now()
     WHERE created_at < v_cutoff
       AND anonymized_at IS NULL;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- El REVOKE de PUBLIC en 022 nunca cubrio a authenticated explicitamente;
-- solo tenia acceso por el default privilege previo a 047, que no aplica
-- retroactivamente. Se cierra aqui y se reabre solo para que ADMIN (que
-- es authenticated) pueda seguir usando la funcion, ya filtrada por dentro.
REVOKE ALL ON FUNCTION fn_anonymize_import_raw_rows(INTEGER, BOOLEAN) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION fn_anonymize_import_raw_rows(INTEGER, BOOLEAN) TO authenticated;

COMMENT ON FUNCTION fn_anonymize_import_raw_rows(INTEGER, BOOLEAN) IS
    'Anonimiza payloads PII crudos/normalizados de import_raw_row mas antiguos que p_retention_days. Exige rol ADMIN desde 051 (antes no verificaba ningun rol: cualquier authenticated podia destruir PII de forma irreversible). Por defecto p_dry_run=true solo cuenta filas candidatas.';
