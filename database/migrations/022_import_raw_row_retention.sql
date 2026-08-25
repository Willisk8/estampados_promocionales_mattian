-- ============================================================
-- 022_import_raw_row_retention.sql
-- Politica operativa de retencion/anonymizacion de PII cruda.
--
-- Mantiene linaje minimo de importacion (batch, fila, tabla/target/status),
-- pero permite anonimizar payloads crudos/normalizados despues de una ventana
-- de retencion. Por defecto la funcion corre en dry-run.
-- ============================================================

ALTER TABLE import_raw_row
    ADD COLUMN IF NOT EXISTS anonymized_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_import_raw_anonymized
    ON import_raw_row (created_at, anonymized_at);

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

COMMENT ON COLUMN import_raw_row.anonymized_at IS
    'Fecha en que raw_payload y normalized_payload fueron anonimizados por politica de retencion.';

COMMENT ON FUNCTION fn_anonymize_import_raw_rows(INTEGER, BOOLEAN) IS
    'Anonimiza payloads PII crudos/normalizados de import_raw_row mas antiguos que p_retention_days. Por defecto p_dry_run=true solo cuenta filas candidatas.';

REVOKE ALL ON FUNCTION fn_anonymize_import_raw_rows(INTEGER, BOOLEAN) FROM PUBLIC;
