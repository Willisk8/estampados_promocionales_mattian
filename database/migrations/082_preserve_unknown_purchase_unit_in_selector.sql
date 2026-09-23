-- El selector conserva la ausencia de unidad y no inventa un costo por pieza.
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
        pps.unidad_compra AS unidad_compra,
        pps.cantidad_pack,
        CASE
            WHEN pps.unidad_compra IS NULL THEN NULL::numeric
            WHEN pps.unidad_compra = 'PACK' AND pps.cantidad_pack > 0
                THEN round(pps.precio_publicado / pps.cantidad_pack, 4)
            ELSE pps.precio_publicado
        END AS costo_unitario_estimado,
        CASE
            WHEN pps.unidad_compra IS NULL THEN NULL::numeric
            WHEN pps.unidad_compra = 'PACK' AND pps.cantidad_pack > 0
                THEN CEIL(v_qty / pps.cantidad_pack) * pps.cantidad_pack
            ELSE v_qty
        END AS cantidad_comprada,
        CASE
            WHEN pps.unidad_compra IS NULL THEN NULL::numeric
            WHEN pps.unidad_compra = 'PACK' AND pps.cantidad_pack > 0
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

