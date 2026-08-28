-- ============================================================
-- 070_supplier_first_quote_selectors.sql
--
-- RPCs de lectura para la UI proveedor-first del cotizador. Devuelven datos
-- preparados sin exponer tablas sensibles ni exigir que el frontend conozca
-- reglas de packs/snapshots.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_buscar_proveedores_producto(
    p_q text DEFAULT NULL,
    p_limit integer DEFAULT 50
)
RETURNS TABLE(
    id_proveedor uuid,
    nombre text,
    ciudad text,
    productos bigint
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
    SELECT pr.id_proveedor, pr.nombre, pr.ciudad, COUNT(pp.id_producto_proveedor)::BIGINT
      FROM proveedor pr
      LEFT JOIN producto_proveedor pp ON pp.id_proveedor = pr.id_proveedor
     WHERE pr.activo
       AND (
           v_q = ''
           OR lower(pr.nombre) LIKE '%' || v_q || '%'
           OR lower(COALESCE(pr.ciudad, '')) LIKE '%' || v_q || '%'
       )
     GROUP BY pr.id_proveedor, pr.nombre, pr.ciudad
     ORDER BY pr.nombre
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_buscar_proveedores_producto(TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_buscar_proveedores_producto(TEXT, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_buscar_productos_proveedor(
    p_id_proveedor uuid,
    p_q text DEFAULT NULL,
    p_limit integer DEFAULT 100
)
RETURNS TABLE(
    id_producto_proveedor uuid,
    sku_proveedor text,
    nombre_original text,
    categoria text,
    estado_calidad text,
    ultimo_precio numeric,
    moneda text,
    unidad_compra text,
    cantidad_pack numeric,
    observado_en timestamptz
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
        pp.id_producto_proveedor,
        pp.sku_proveedor,
        pp.nombre_original,
        pp.categoria,
        pp.estado_calidad,
        s.precio_publicado,
        s.moneda,
        s.unidad_compra,
        s.cantidad_pack,
        s.observado_en
      FROM producto_proveedor pp
      LEFT JOIN LATERAL (
          SELECT pps.precio_publicado, pps.moneda, pps.unidad_compra, pps.cantidad_pack, pps.observado_en
            FROM precio_proveedor_snapshot pps
           WHERE pps.id_producto_proveedor = pp.id_producto_proveedor
           ORDER BY pps.observado_en DESC, pps.created_at DESC
           LIMIT 1
      ) s ON true
     WHERE pp.id_proveedor = p_id_proveedor
       AND pp.estado_calidad <> 'REJECTED'
       AND (
           v_q = ''
           OR lower(pp.nombre_original) LIKE '%' || v_q || '%'
           OR lower(COALESCE(pp.sku_proveedor, '')) LIKE '%' || v_q || '%'
           OR lower(COALESCE(pp.categoria, '')) LIKE '%' || v_q || '%'
       )
     ORDER BY pp.nombre_original
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_buscar_productos_proveedor(UUID, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_buscar_productos_proveedor(UUID, TEXT, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_ofertas_producto_proveedor(
    p_id_producto_proveedor uuid,
    p_cantidad integer DEFAULT NULL,
    p_at timestamptz DEFAULT now(),
    p_moneda text DEFAULT 'COP'
)
RETURNS TABLE(
    id_snapshot uuid,
    precio_publicado numeric,
    moneda text,
    unidad_compra text,
    cantidad_pack numeric,
    costo_unitario_estimado numeric,
    cantidad_comprada numeric,
    cantidad_sobrante numeric,
    minimo_compra numeric,
    incremento_compra numeric,
    precio_texto_original text,
    url_fuente text,
    observado_en timestamptz,
    vigente boolean,
    notas_costeo text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_qty NUMERIC := GREATEST(COALESCE(p_cantidad, 1), 1);
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        pps.id_snapshot,
        pps.precio_publicado,
        pps.moneda,
        COALESCE(pps.unidad_compra, 'UNIT') AS unidad_compra,
        pps.cantidad_pack,
        CASE
            WHEN COALESCE(pps.unidad_compra, 'UNIT') = 'PACK' AND pps.cantidad_pack > 0
                THEN round(pps.precio_publicado / pps.cantidad_pack, 4)
            ELSE pps.precio_publicado
        END AS costo_unitario_estimado,
        CASE
            WHEN COALESCE(pps.unidad_compra, 'UNIT') = 'PACK' AND pps.cantidad_pack > 0
                THEN CEIL(v_qty / pps.cantidad_pack) * pps.cantidad_pack
            ELSE v_qty
        END AS cantidad_comprada,
        CASE
            WHEN COALESCE(pps.unidad_compra, 'UNIT') = 'PACK' AND pps.cantidad_pack > 0
                THEN GREATEST(CEIL(v_qty / pps.cantidad_pack) * pps.cantidad_pack - v_qty, 0)
            ELSE 0
        END AS cantidad_sobrante,
        pps.minimo_compra,
        pps.incremento_compra,
        pps.precio_texto_original,
        pps.url_fuente,
        pps.observado_en,
        (pps.precio_vigencia IS NULL OR pps.precio_vigencia @> p_at) AS vigente,
        pps.notas_costeo
      FROM precio_proveedor_snapshot pps
     WHERE pps.id_producto_proveedor = p_id_producto_proveedor
       AND pps.moneda = p_moneda
     ORDER BY
        (pps.precio_vigencia IS NULL OR pps.precio_vigencia @> p_at) DESC,
        pps.observado_en DESC,
        pps.created_at DESC
     LIMIT 20;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_ofertas_producto_proveedor(UUID, INTEGER, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_ofertas_producto_proveedor(UUID, INTEGER, TIMESTAMPTZ, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_buscar_proveedores_producto(TEXT, INTEGER) IS
    'Selector controlado para proveedores de productos en el cotizador proveedor-first.';
COMMENT ON FUNCTION fn_consola_buscar_productos_proveedor(UUID, TEXT, INTEGER) IS
    'Selector controlado para productos de un proveedor en el cotizador proveedor-first.';
COMMENT ON FUNCTION fn_consola_ofertas_producto_proveedor(UUID, INTEGER, TIMESTAMPTZ, TEXT) IS
    'Devuelve snapshots de precio de proveedor preparados para cotizar: costo unitario estimado, pack, sobrantes y vigencia.';
