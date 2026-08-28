-- ============================================================
-- 074_fix_supplier_preview_wrapper_alias.sql
--
-- Corrige el wrapper de preview proveedor-first agregado en 073: la consulta
-- que sanitiza metadata necesitaba alias para referenciar columnas.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_previsualizar_cotizacion_proveedor(
    p_id_precio_proveedor_snapshot uuid,
    p_cantidad integer,
    p_marking_lines jsonb DEFAULT '[]'::jsonb,
    p_transporte_total numeric DEFAULT 0,
    p_transport_mode text DEFAULT 'SEPARATE_LINE',
    p_policy_code text DEFAULT 'MVP_DEFAULT',
    p_margen_override_pct numeric DEFAULT NULL
)
RETURNS TABLE(
    tipo_componente text,
    descripcion text,
    cantidad numeric,
    costo_unitario numeric,
    costo_total numeric,
    pricing_method text,
    margen_aplicado_pct numeric,
    minimum_pct numeric,
    precio_resultante numeric,
    source_type text,
    source_snapshot_id uuid,
    metadata jsonb,
    status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RETURN QUERY SELECT NULL::TEXT, 'No autorizado'::TEXT, 0::NUMERIC,
            NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT, NULL::NUMERIC,
            NULL::NUMERIC, NULL::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            '{}'::JSONB, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF v_rol <> 'ADMIN' AND p_margen_override_pct IS NOT NULL THEN
        RETURN QUERY SELECT NULL::TEXT, 'Margen manual solo permitido para ADMIN'::TEXT,
            0::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT,
            NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, 'NONE'::TEXT,
            NULL::UUID, '{}'::JSONB, 'MARGIN_OVERRIDE_FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF NOT public.fn_quote_supplier_marking_lines_usable(p_marking_lines) THEN
        RETURN QUERY SELECT NULL::TEXT, 'Tecnica no disponible para cotizacion'::TEXT,
            0::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT,
            NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, 'NONE'::TEXT,
            NULL::UUID, '{}'::JSONB, 'MARKING_COST_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        c.tipo_componente,
        c.descripcion,
        c.cantidad,
        c.costo_unitario,
        c.costo_total,
        c.pricing_method,
        c.margen_aplicado_pct,
        c.minimum_pct,
        c.precio_resultante,
        c.source_type,
        c.source_snapshot_id,
        CASE WHEN v_rol = 'ADMIN' THEN c.metadata ELSE '{}'::JSONB END,
        c.status
      FROM public.fn_consola_previsualizar_cotizacion_proveedor__unsafe_margin_override_073(
        p_id_precio_proveedor_snapshot, p_cantidad, p_marking_lines,
        p_transporte_total, p_transport_mode, p_policy_code,
        p_margen_override_pct
      ) AS c;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_consola_previsualizar_cotizacion_proveedor(
    UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_consola_previsualizar_cotizacion_proveedor(
    UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC
) TO authenticated;
