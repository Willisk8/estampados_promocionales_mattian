-- ============================================================
-- 014_quarantine_malformed_email_domains.sql
-- Cuarentena auditable para dominios de email malformados.
--
-- Los canales NO se eliminan ni se corrigen automaticamente.
-- Se marcan REVIEW_REQUIRED y se abre un item de revision enlazado
-- a import_raw_row para conservar trazabilidad al archivo/fila origen.
-- ============================================================

DO $$
DECLARE
    v_target_count INTEGER;
    v_with_raw_count INTEGER;
BEGIN
    WITH malformed_domains(domain) AS (
        VALUES
            ('coomservi.combogot'),
            ('colegiocoomeva.edu.codocente'),
            ('fbcsena.comauxiliar')
    ),
    targets AS (
        SELECT
            cc.id_canal_contacto
        FROM canal_contacto cc
        JOIN malformed_domains md
          ON lower(split_part(cc.valor_normalizado, '@', 2)) = md.domain
        WHERE cc.tipo = 'EMAIL'
    )
    SELECT
        COUNT(*),
        COUNT(irr.id_import_raw_row)
    INTO
        v_target_count,
        v_with_raw_count
    FROM targets t
    LEFT JOIN import_raw_row irr
      ON irr.target_table = 'canal_contacto'
     AND irr.target_id = t.id_canal_contacto;

    IF v_target_count <> 58 THEN
        RAISE EXCEPTION
            'Expected 58 malformed email channels, found %. Review quarantine migration before applying.',
            v_target_count;
    END IF;

    IF v_with_raw_count <> v_target_count THEN
        RAISE EXCEPTION
            'Malformed email channels without import_raw_row traceability: %',
            v_target_count - v_with_raw_count;
    END IF;
END $$;

WITH malformed_domains(domain) AS (
    VALUES
        ('coomservi.combogot'),
        ('colegiocoomeva.edu.codocente'),
        ('fbcsena.comauxiliar')
),
targets AS (
    SELECT
        cc.id_canal_contacto,
        cc.valor_normalizado,
        lower(split_part(cc.valor_normalizado, '@', 2)) AS malformed_domain,
        irr.id_import_raw_row
    FROM canal_contacto cc
    JOIN malformed_domains md
      ON lower(split_part(cc.valor_normalizado, '@', 2)) = md.domain
    JOIN import_raw_row irr
      ON irr.target_table = 'canal_contacto'
     AND irr.target_id = cc.id_canal_contacto
    WHERE cc.tipo = 'EMAIL'
),
updated_channels AS (
    UPDATE canal_contacto cc
       SET estado = 'REVIEW_REQUIRED',
           updated_at = now()
    FROM targets t
    WHERE cc.id_canal_contacto = t.id_canal_contacto
      AND cc.estado <> 'REVIEW_REQUIRED'
    RETURNING cc.id_canal_contacto
)
INSERT INTO import_review_item (
    id_import_raw_row,
    review_reason,
    severity,
    resolution_status,
    resolution_notes
)
SELECT
    t.id_import_raw_row,
    'email dominio malformado por posible concatenacion: ' || t.malformed_domain,
    'HIGH',
    'OPEN',
    'Canal marcado REVIEW_REQUIRED por migracion 014_quarantine_malformed_email_domains.sql. Revisar valor_normalizado=' || t.valor_normalizado
FROM targets t
WHERE NOT EXISTS (
    SELECT 1
    FROM import_review_item iri
    WHERE iri.id_import_raw_row = t.id_import_raw_row
      AND iri.review_reason = 'email dominio malformado por posible concatenacion: ' || t.malformed_domain
);
