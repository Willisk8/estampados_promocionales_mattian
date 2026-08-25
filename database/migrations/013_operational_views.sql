-- ============================================================
-- 013_operational_views.sql
-- Vistas operativas para CRM, curacion de datos y calidad de catalogo.
-- No activa campanas ni cambia contactabilidad.
-- ============================================================

CREATE OR REPLACE VIEW vw_organizacion_contacto_resumen WITH (security_invoker = on) AS
WITH contactabilidad_actual AS (
    SELECT DISTINCT ON (id_canal_contacto)
        id_canal_contacto,
        base_contacto_codigo
    FROM contactabilidad
    WHERE valido_hasta IS NULL OR valido_hasta > now()
    ORDER BY id_canal_contacto, valido_desde DESC, created_at DESC
)
SELECT
    o.id_organizacion,
    o.nit,
    o.nombre_legal,
    o.nombre_comercial,
    o.sigla,
    o.tipo_entidad_origen,
    o.departamento,
    o.municipio,
    o.estado,
    COUNT(DISTINCT cc.id_canal_contacto) AS total_canales,
    COUNT(DISTINCT cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'EMAIL') AS emails,
    COUNT(DISTINCT cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'TELEFONO') AS telefonos,
    COUNT(DISTINCT cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'WHATSAPP') AS whatsapps,
    COUNT(DISTINCT cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'WEBSITE') AS websites,
    COUNT(DISTINCT cc.id_canal_contacto) FILTER (
        WHERE cc.tipo = 'EMAIL'
          AND cc.estado = 'ACTIVE'
          AND c.base_contacto_codigo <> 'DESCONOCIDA'
    ) AS emails_con_base_confirmada,
    COUNT(DISTINCT cc.id_canal_contacto) FILTER (
        WHERE cc.tipo = 'EMAIL'
          AND cc.estado = 'ACTIVE'
          AND c.base_contacto_codigo = 'DESCONOCIDA'
    ) AS emails_sin_base_confirmada,
    COALESCE(BOOL_OR(cc.tipo = 'EMAIL'), false) AS tiene_email,
    COALESCE(BOOL_OR(cc.tipo = 'TELEFONO'), false) AS tiene_telefono,
    COALESCE(BOOL_OR(cc.tipo = 'WHATSAPP'), false) AS tiene_whatsapp,
    COALESCE(BOOL_OR(cc.tipo = 'WEBSITE'), false) AS tiene_website,
    MAX(cc.updated_at) AS ultimo_contacto_actualizado_en
FROM organizacion o
LEFT JOIN canal_contacto cc
  ON cc.id_organizacion = o.id_organizacion
LEFT JOIN contactabilidad_actual c
  ON c.id_canal_contacto = cc.id_canal_contacto
GROUP BY
    o.id_organizacion,
    o.nit,
    o.nombre_legal,
    o.nombre_comercial,
    o.sigla,
    o.tipo_entidad_origen,
    o.departamento,
    o.municipio,
    o.estado;

CREATE OR REPLACE VIEW vw_import_review_open WITH (security_invoker = on) AS
SELECT
    iri.id_import_review_item,
    iri.severity,
    iri.review_reason,
    iri.resolution_status,
    iri.created_at AS review_created_at,
    irr.id_import_raw_row,
    irr.row_number,
    irr.entity_kind,
    irr.match_status,
    irr.target_table,
    irr.target_id,
    irr.error_message,
    ib.source_name,
    ib.source_path,
    ib.source_sha256,
    ib.import_status,
    ib.created_at AS batch_created_at
FROM import_review_item iri
JOIN import_raw_row irr
  ON irr.id_import_raw_row = iri.id_import_raw_row
JOIN import_batch ib
  ON ib.id_import_batch = irr.id_import_batch
WHERE iri.resolution_status = 'OPEN';

CREATE OR REPLACE VIEW vw_catalogo_proveedor_quality WITH (security_invoker = on) AS
SELECT
    p.id_proveedor,
    p.source_id,
    p.nombre AS proveedor,
    p.ciudad,
    p.activo,
    COUNT(DISTINCT pp.id_producto_proveedor) AS productos,
    COUNT(DISTINCT pp.id_producto_proveedor) FILTER (WHERE pp.estado_calidad = 'VALID') AS productos_validos,
    COUNT(DISTINCT pp.id_producto_proveedor) FILTER (WHERE pp.estado_calidad = 'PENDING_REVIEW') AS productos_pendientes,
    COUNT(DISTINCT pp.id_producto_proveedor) FILTER (WHERE pp.estado_calidad = 'NEEDS_REVIEW') AS productos_en_revision,
    COUNT(DISTINCT pp.id_producto_proveedor) FILTER (WHERE pp.estado_calidad = 'REJECTED') AS productos_rechazados,
    COUNT(DISTINCT pps.id_snapshot) AS snapshots,
    COUNT(DISTINCT pp.id_producto_proveedor) FILTER (WHERE pps.id_snapshot IS NULL) AS productos_sin_snapshot,
    MIN(pps.precio_publicado) AS precio_min,
    ROUND(AVG(pps.precio_publicado)::numeric, 2) AS precio_promedio,
    MAX(pps.precio_publicado) AS precio_max,
    BOOL_OR(pps.precio_publicado <= 100) AS tiene_precio_sospechosamente_bajo,
    BOOL_OR(pps.precio_publicado >= 500000) AS tiene_precio_sospechosamente_alto
FROM proveedor p
LEFT JOIN producto_proveedor pp
  ON pp.id_proveedor = p.id_proveedor
LEFT JOIN precio_proveedor_snapshot pps
  ON pps.id_producto_proveedor = pp.id_producto_proveedor
GROUP BY
    p.id_proveedor,
    p.source_id,
    p.nombre,
    p.ciudad,
    p.activo;

CREATE OR REPLACE VIEW vw_campaign_eligibility_queue WITH (security_invoker = on) AS
SELECT
    cc.id_canal_contacto,
    cc.id_organizacion,
    o.nit,
    o.nombre_legal,
    o.tipo_entidad_origen,
    o.departamento,
    o.municipio,
    cc.valor_normalizado AS email,
    cc.email_hash,
    cc.confianza,
    cc.estado AS estado_canal,
    c.base_contacto_codigo,
    c.evidencia,
    e.eligible,
    e.reason AS eligibility_reason
FROM canal_contacto cc
JOIN organizacion o
  ON o.id_organizacion = cc.id_organizacion
LEFT JOIN contactabilidad c
  ON c.id_canal_contacto = cc.id_canal_contacto
CROSS JOIN LATERAL fn_email_eligible_for_campaign(cc.email_hash) e
WHERE cc.tipo = 'EMAIL';

COMMENT ON VIEW vw_organizacion_contacto_resumen IS
    'Resumen por organizacion para CRM y priorizacion de limpieza de contactos.';

COMMENT ON VIEW vw_import_review_open IS
    'Cola de revision humana de items abiertos del pipeline de importacion.';

COMMENT ON VIEW vw_catalogo_proveedor_quality IS
    'Indicadores de calidad del catalogo de proveedores y snapshots de precio.';

COMMENT ON VIEW vw_campaign_eligibility_queue IS
    'Vista de elegibilidad de emails; no activa envios y respeta contactabilidad/supresion.';
