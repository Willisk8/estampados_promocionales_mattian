-- ============================================================
-- 073_block_margin_override_for_non_admin.sql
--
-- Cierra H-073-001: margen_override_pct no puede depender de la UI.
-- COMERCIAL puede cotizar con la politica vigente, pero no puede inyectar
-- un margen manual por URL/FormData ni en preview ni en emision.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_quote_supplier_marking_lines_usable(p_marking_lines jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line JSONB;
    v_snapshot_text TEXT;
    v_snapshot UUID;
    v_usage_status TEXT;
BEGIN
    IF p_marking_lines IS NULL OR p_marking_lines = 'null'::JSONB THEN
        RETURN true;
    END IF;

    IF jsonb_typeof(p_marking_lines) <> 'array' THEN
        RETURN false;
    END IF;

    FOR v_line IN SELECT value FROM jsonb_array_elements(p_marking_lines) LOOP
        v_snapshot_text := NULLIF(btrim(COALESCE(v_line->>'id_snapshot', '')), '');
        IF v_snapshot_text IS NULL THEN
            CONTINUE;
        END IF;

        IF v_snapshot_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RETURN false;
        END IF;

        v_snapshot := v_snapshot_text::UUID;

        SELECT c.usage_status
          INTO v_usage_status
          FROM curacion_precio_tecnica_marcacion c
         WHERE c.id_snapshot = v_snapshot
         ORDER BY c.curated_at DESC NULLS LAST
         LIMIT 1;

        IF v_usage_status = 'DO_NOT_USE' THEN
            RETURN false;
        END IF;
    END LOOP;

    RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_quote_supplier_marking_lines_usable(JSONB) FROM PUBLIC, authenticated;

ALTER FUNCTION public.fn_consola_previsualizar_cotizacion_calculada(
    UUID, INTEGER, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC
) RENAME TO fn_consola_previsualizar_cotizacion_calculada__unsafe_margin_override_073;

REVOKE ALL ON FUNCTION public.fn_consola_previsualizar_cotizacion_calculada__unsafe_margin_override_073(
    UUID, INTEGER, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC
) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_previsualizar_cotizacion_calculada(
    p_id_producto uuid,
    p_cantidad integer,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_margen_override_pct numeric DEFAULT NULL::numeric
)
RETURNS TABLE(
    tipo_componente text,
    descripcion text,
    cantidad numeric,
    costo_unitario numeric,
    costo_total numeric,
    margen_aplicado_pct numeric,
    minimum_pct numeric,
    precio_resultante numeric,
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
        RETURN QUERY SELECT
            NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
            NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF v_rol <> 'ADMIN' AND p_margen_override_pct IS NOT NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Margen manual solo permitido para ADMIN'::TEXT,
            0::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
            NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
            'MARGIN_OVERRIDE_FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT *
      FROM public.fn_consola_previsualizar_cotizacion_calculada__unsafe_margin_override_073(
        p_id_producto, p_cantidad, p_id_variante, p_id_tecnica,
        p_numero_preparaciones, p_transporte_total, p_policy_code,
        p_margen_override_pct
      );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_consola_previsualizar_cotizacion_calculada(
    UUID, INTEGER, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_consola_previsualizar_cotizacion_calculada(
    UUID, INTEGER, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC
) TO authenticated;

ALTER FUNCTION public.fn_consola_crear_cotizacion_calculada(
    UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT
) RENAME TO fn_consola_crear_cotizacion_calculada__unsafe_margin_override_073;

REVOKE ALL ON FUNCTION public.fn_consola_crear_cotizacion_calculada__unsafe_margin_override_073(
    UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT
) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_crear_cotizacion_calculada(
    p_id_producto uuid,
    p_cantidad integer,
    p_id_organizacion uuid DEFAULT NULL::uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_margen_override_pct numeric DEFAULT NULL::numeric,
    p_notas text DEFAULT NULL::text,
    p_idempotency_key text DEFAULT NULL::text
)
RETURNS TABLE(id_cotizacion uuid, numero bigint, total numeric, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear cotizaciones calculadas.';
    END IF;

    IF v_rol <> 'ADMIN' AND p_margen_override_pct IS NOT NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'MARGIN_OVERRIDE_FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT *
      FROM public.fn_consola_crear_cotizacion_calculada__unsafe_margin_override_073(
        p_id_producto, p_cantidad, p_id_organizacion, p_id_variante,
        p_id_tecnica, p_numero_preparaciones, p_transporte_total,
        p_policy_code, p_margen_override_pct, p_notas, p_idempotency_key
      );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_consola_crear_cotizacion_calculada(
    UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_consola_crear_cotizacion_calculada(
    UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT
) TO authenticated;

ALTER FUNCTION public.fn_consola_previsualizar_cotizacion_proveedor(
    UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC
) RENAME TO fn_consola_previsualizar_cotizacion_proveedor__unsafe_margin_override_073;

REVOKE ALL ON FUNCTION public.fn_consola_previsualizar_cotizacion_proveedor__unsafe_margin_override_073(
    UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC
) FROM PUBLIC, authenticated;

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
      );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_consola_previsualizar_cotizacion_proveedor(
    UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_consola_previsualizar_cotizacion_proveedor(
    UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC
) TO authenticated;

ALTER FUNCTION public.fn_consola_crear_cotizacion_proveedor(
    UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, TEXT
) RENAME TO fn_consola_crear_cotizacion_proveedor__unsafe_margin_override_073;

REVOKE ALL ON FUNCTION public.fn_consola_crear_cotizacion_proveedor__unsafe_margin_override_073(
    UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, TEXT
) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_crear_cotizacion_proveedor(
    p_id_organizacion uuid,
    p_id_precio_proveedor_snapshot uuid,
    p_cantidad integer,
    p_marking_lines jsonb DEFAULT '[]'::jsonb,
    p_transporte_total numeric DEFAULT 0,
    p_transport_mode text DEFAULT 'SEPARATE_LINE',
    p_policy_code text DEFAULT 'MVP_DEFAULT',
    p_margen_override_pct numeric DEFAULT NULL,
    p_notas text DEFAULT NULL,
    p_idempotency_key text DEFAULT NULL
)
RETURNS TABLE(
    id_cotizacion uuid,
    numero bigint,
    total numeric,
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
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF v_rol <> 'ADMIN' AND p_margen_override_pct IS NOT NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'MARGIN_OVERRIDE_FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF NOT public.fn_quote_supplier_marking_lines_usable(p_marking_lines) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'MARKING_COST_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT *
      FROM public.fn_consola_crear_cotizacion_proveedor__unsafe_margin_override_073(
        p_id_organizacion, p_id_precio_proveedor_snapshot, p_cantidad,
        p_marking_lines, p_transporte_total, p_transport_mode, p_policy_code,
        p_margen_override_pct, p_notas, p_idempotency_key
      );
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_consola_crear_cotizacion_proveedor(
    UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_consola_crear_cotizacion_proveedor(
    UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, TEXT
) TO authenticated;

COMMENT ON FUNCTION public.fn_consola_previsualizar_cotizacion_calculada(
    UUID, INTEGER, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC
) IS 'Preview calculado con enforcement servidor: margen_override_pct solo ADMIN.';

COMMENT ON FUNCTION public.fn_consola_crear_cotizacion_calculada(
    UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT
) IS 'Crea cotizacion calculada con enforcement servidor: margen_override_pct solo ADMIN.';

COMMENT ON FUNCTION public.fn_consola_previsualizar_cotizacion_proveedor(
    UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC
) IS 'Preview proveedor-first con enforcement servidor: margen_override_pct solo ADMIN.';

COMMENT ON FUNCTION public.fn_consola_crear_cotizacion_proveedor(
    UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, TEXT
) IS 'Crea cotizacion proveedor-first con enforcement servidor: margen_override_pct solo ADMIN.';
