-- ============================================================
-- 071_supplier_first_marking_selectors.sql
--
-- Selector de costos de marcacion para el cotizador proveedor-first. Devuelve
-- snapshots utilizables por la UI sin exponer costos/margenes internos de la
-- cotizacion.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_buscar_snapshots_tecnica_marcacion(
    p_q text DEFAULT NULL,
    p_cantidad integer DEFAULT NULL,
    p_moneda text DEFAULT 'COP',
    p_limit integer DEFAULT 80
)
RETURNS TABLE(
    id_snapshot uuid,
    id_tecnica uuid,
    tecnica_codigo text,
    id_proveedor_tecnica uuid,
    proveedor_tecnica text,
    billing_unit text,
    price_value numeric,
    width_cm numeric,
    height_cm numeric,
    quantity_min integer,
    quantity_max integer,
    verification_status text,
    size_label text,
    source_url text,
    fetched_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_q TEXT := lower(btrim(COALESCE(p_q, '')));
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        pts.id_snapshot,
        tm.id_tecnica,
        tm.codigo,
        ptm.id_proveedor_tecnica,
        ptm.nombre,
        pts.billing_unit,
        pts.price_value,
        pts.width_cm,
        pts.height_cm,
        pts.quantity_min,
        pts.quantity_max,
        pts.verification_status,
        pts.size_label,
        pts.source_url,
        pts.fetched_at
      FROM precio_tecnica_marcacion_snapshot pts
      JOIN tecnica_marcacion tm ON tm.id_tecnica = pts.id_tecnica
      JOIN proveedor_tecnica_marcacion ptm ON ptm.id_proveedor_tecnica = pts.id_proveedor_tecnica
      LEFT JOIN curacion_precio_tecnica_marcacion c ON c.id_snapshot = pts.id_snapshot
     WHERE pts.currency = p_moneda
       AND pts.price_value IS NOT NULL
       AND pts.verification_status IN ('VERIFIED_PUBLIC_PRICE', 'PENDING_REVIEW')
       AND COALESCE(c.usage_status, 'NEEDS_REVIEW') <> 'DO_NOT_USE'
       AND (p_cantidad IS NULL OR pts.quantity_min IS NULL OR pts.quantity_min <= p_cantidad)
       AND (p_cantidad IS NULL OR pts.quantity_max IS NULL OR pts.quantity_max >= p_cantidad)
       AND (
           v_q = ''
           OR lower(tm.codigo) LIKE '%' || v_q || '%'
           OR lower(ptm.nombre) LIKE '%' || v_q || '%'
           OR lower(COALESCE(pts.size_label, '')) LIKE '%' || v_q || '%'
           OR lower(COALESCE(pts.billing_unit, '')) LIKE '%' || v_q || '%'
       )
     ORDER BY
        CASE pts.verification_status WHEN 'VERIFIED_PUBLIC_PRICE' THEN 0 ELSE 1 END,
        pts.fetched_at DESC NULLS LAST,
        pts.created_at DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 80), 1), 150);
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_buscar_snapshots_tecnica_marcacion(TEXT, INTEGER, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_buscar_snapshots_tecnica_marcacion(TEXT, INTEGER, TEXT, INTEGER) TO authenticated;

COMMENT ON FUNCTION fn_consola_buscar_snapshots_tecnica_marcacion(TEXT, INTEGER, TEXT, INTEGER) IS
    'Selector controlado de snapshots de tecnica de marcacion para el cotizador proveedor-first.';
