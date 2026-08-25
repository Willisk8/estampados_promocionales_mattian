-- ============================================================
-- post_load_checks.sql
-- Verificaciones operativas despues de cargas en Supabase STAGING.
-- Ejecutar con psql "$DATABASE_URL" -f scripts/analytics/post_load_checks.sql
-- ============================================================

-- Conteos principales
SELECT 'organizacion' AS tabla, COUNT(*) AS filas FROM organizacion
UNION ALL SELECT 'persona', COUNT(*) FROM persona
UNION ALL SELECT 'persona_organizacion', COUNT(*) FROM persona_organizacion
UNION ALL SELECT 'canal_contacto', COUNT(*) FROM canal_contacto
UNION ALL SELECT 'contactabilidad', COUNT(*) FROM contactabilidad
UNION ALL SELECT 'proveedor', COUNT(*) FROM proveedor
UNION ALL SELECT 'producto_proveedor', COUNT(*) FROM producto_proveedor
UNION ALL SELECT 'precio_proveedor_snapshot', COUNT(*) FROM precio_proveedor_snapshot
UNION ALL SELECT 'import_batch', COUNT(*) FROM import_batch
UNION ALL SELECT 'import_raw_row', COUNT(*) FROM import_raw_row
UNION ALL SELECT 'import_review_item_open', COUNT(*) FROM import_review_item WHERE resolution_status = 'OPEN'
ORDER BY tabla;

-- Batches
SELECT
    source_name,
    import_status,
    source_row_count,
    created_at,
    finished_at
FROM import_batch
ORDER BY created_at;

-- Trazabilidad por tabla destino
SELECT
    target_table,
    COUNT(*) AS filas_raw
FROM import_raw_row
GROUP BY target_table
ORDER BY target_table;

-- Canales sin contactabilidad: debe ser 0
SELECT
    COUNT(*) AS canales_sin_contactabilidad
FROM canal_contacto cc
LEFT JOIN contactabilidad c
  ON c.id_canal_contacto = cc.id_canal_contacto
WHERE c.id_contactabilidad IS NULL;

-- Emails sin hash: debe ser 0 despues de importacion real
SELECT
    COUNT(*) AS emails_sin_hash
FROM canal_contacto
WHERE tipo = 'EMAIL'
  AND email_hash IS NULL;

-- Contactos elegibles para campana: debe ser 0 hasta confirmar base legal
SELECT
    COUNT(*) AS contactos_elegibles_sin_confirmacion
FROM contactabilidad
WHERE base_contacto_codigo IN (
    'CONSENTIMIENTO_EXPRESO',
    'RELACION_COMERCIAL_PREVIA',
    'SOLICITUD_DEL_TITULAR'
);

-- Revisiones abiertas por motivo
SELECT
    review_reason,
    COUNT(*) AS abiertos
FROM import_review_item
WHERE resolution_status = 'OPEN'
GROUP BY review_reason
ORDER BY abiertos DESC, review_reason;

-- Calidad catalogo proveedor
SELECT
    p.nombre AS proveedor,
    COUNT(pp.id_producto_proveedor) AS productos,
    COUNT(pps.id_snapshot) AS snapshots,
    COUNT(pp.id_producto_proveedor) - COUNT(pps.id_snapshot) AS productos_sin_snapshot,
    MIN(pps.precio_publicado) AS precio_min,
    MAX(pps.precio_publicado) AS precio_max
FROM proveedor p
LEFT JOIN producto_proveedor pp
  ON pp.id_proveedor = p.id_proveedor
LEFT JOIN precio_proveedor_snapshot pps
  ON pps.id_producto_proveedor = pp.id_producto_proveedor
GROUP BY p.nombre
ORDER BY productos DESC;

-- Vistas operativas creadas en 013_operational_views.sql
SELECT 'vw_organizacion_contacto_resumen' AS vista, COUNT(*) AS filas
FROM vw_organizacion_contacto_resumen
UNION ALL
SELECT 'vw_import_review_open', COUNT(*)
FROM vw_import_review_open
UNION ALL
SELECT 'vw_catalogo_proveedor_quality', COUNT(*)
FROM vw_catalogo_proveedor_quality
UNION ALL
SELECT 'vw_campaign_eligibility_queue', COUNT(*)
FROM vw_campaign_eligibility_queue
ORDER BY vista;
