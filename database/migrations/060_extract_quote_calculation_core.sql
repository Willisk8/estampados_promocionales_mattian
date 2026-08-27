-- ============================================================
-- 060_extract_quote_calculation_core.sql
--
-- Extrae el cuerpo de calculo de fn_calculate_quote_components (058) a una
-- funcion interna sin guardia de rol, para que la Task 3
-- (fn_consola_crear_cotizacion_calculada, accesible a ADMIN y COMERCIAL)
-- pueda reutilizar el mismo calculo sin heredar el guardia ADMIN-only del
-- simulador. Mismo patron que fn_ai_resolver_sesion (046): SECURITY
-- DEFINER, REVOKE ALL FROM PUBLIC/authenticated, solo alcanzable por
-- llamada anidada desde otra funcion SECURITY DEFINER.
--
-- Agrega minimum_pct a la salida (no estaba en 058) porque la Task 3 la
-- necesita para bloquear un override de margen que caiga bajo el minimo.
-- Agrega p_margen_override_pct: si viene, reemplaza target_pct de forma
-- uniforme para todos los componentes de esta llamada puntual.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_quote_calculate_components_core(
    p_id_producto uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_cantidad integer DEFAULT 1,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_at timestamp with time zone DEFAULT now(),
    p_moneda text DEFAULT 'COP'::text,
    p_margen_override_pct numeric DEFAULT NULL::numeric
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
    v_id_policy UUID;
    v_rounding_rule TEXT;
    v_cost costo_producto%ROWTYPE;
    v_producto_tecnica producto_tecnica%ROWTYPE;
    v_marking_snapshot RECORD;
    v_qty_produccion INTEGER;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Cantidad invalida'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, '{}'::JSONB, 'INVALID_QUANTITY'::TEXT;
        RETURN;
    END IF;

    IF p_numero_preparaciones IS NULL OR p_numero_preparaciones < 0 THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Numero de preparaciones invalido'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('numero_preparaciones', p_numero_preparaciones),
            'INVALID_PREPARATION_COUNT'::TEXT;
        RETURN;
    END IF;

    SELECT
        NULL::UUID AS id_snapshot,
        NULL::NUMERIC AS price_value,
        NULL::TEXT AS billing_unit,
        NULL::INTEGER AS quantity_min,
        NULL::INTEGER AS quantity_max,
        NULL::TEXT AS formula_code,
        NULL::TIMESTAMPTZ AS fetched_at
      INTO v_marking_snapshot;

    SELECT mpv.id_margin_policy_version, mpv.rounding_rule
      INTO v_id_policy, v_rounding_rule
      FROM margin_policy_version mpv
     WHERE mpv.codigo = p_policy_code
       AND mpv.estado = 'ACTIVE'
       AND mpv.vigencia @> p_at
     ORDER BY lower(mpv.vigencia) DESC
     LIMIT 1;

    IF v_id_policy IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Politica de margen no encontrada'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('policy_code', p_policy_code),
            'MARGIN_POLICY_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    IF p_id_tecnica IS NOT NULL THEN
        SELECT pt.*
          INTO v_producto_tecnica
          FROM producto_tecnica pt
         WHERE pt.id_producto = p_id_producto
           AND COALESCE(pt.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
               = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           AND pt.id_tecnica = p_id_tecnica
           AND pt.permitida
         ORDER BY (pt.id_variante IS NOT NULL) DESC, pt.created_at DESC
         LIMIT 1;
    END IF;

    IF p_id_tecnica IS NOT NULL AND v_producto_tecnica.id_producto_tecnica IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Tecnica no permitida/configurada para producto'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('id_tecnica', p_id_tecnica),
            'PRODUCT_TECHNIQUE_NOT_CONFIGURED'::TEXT;
        RETURN;
    END IF;

    IF v_producto_tecnica.id_producto_tecnica IS NOT NULL
       AND p_cantidad < v_producto_tecnica.cantidad_minima_tecnica THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Cantidad inferior al minimo tecnico'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object(
                'cantidad_minima_tecnica', v_producto_tecnica.cantidad_minima_tecnica,
                'id_producto_tecnica', v_producto_tecnica.id_producto_tecnica
            ),
            'BELOW_TECHNIQUE_MINIMUM'::TEXT;
        RETURN;
    END IF;

    IF p_id_tecnica IS NOT NULL THEN
        SELECT
            pts.id_snapshot, pts.price_value, pts.billing_unit,
            pts.quantity_min, pts.quantity_max, c.formula_code, pts.fetched_at
          INTO v_marking_snapshot
          FROM precio_tecnica_marcacion_snapshot pts
          JOIN curacion_precio_tecnica_marcacion c ON c.id_snapshot = pts.id_snapshot
         WHERE pts.id_tecnica = p_id_tecnica
           AND c.usage_status = 'AUTOMATIC_PRICING'
           AND pts.verification_status = 'VERIFIED_PUBLIC_PRICE'
           AND pts.currency = p_moneda
           AND pts.price_value IS NOT NULL
           AND lower(COALESCE(pts.billing_unit, '')) = 'unidad'
           AND (pts.quantity_min IS NULL OR pts.quantity_min <= p_cantidad)
           AND (pts.quantity_max IS NULL OR pts.quantity_max >= p_cantidad)
           AND (pts.fetched_at IS NULL OR pts.fetched_at <= p_at)
         ORDER BY pts.fetched_at DESC NULLS LAST, pts.created_at DESC
         LIMIT 1;

        IF v_marking_snapshot.id_snapshot IS NULL THEN
            RETURN QUERY SELECT
                NULL::TEXT, 'Costo de marcacion curado no encontrado para tecnica/cantidad/moneda'::TEXT,
                0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, NULL::UUID,
                jsonb_build_object(
                    'id_tecnica', p_id_tecnica, 'cantidad', p_cantidad,
                    'moneda', p_moneda, 'billing_unit_requerida', 'unidad'
                ),
                'MARKING_COST_NOT_FOUND'::TEXT;
            RETURN;
        END IF;

        IF p_numero_preparaciones > 0
           AND COALESCE(v_producto_tecnica.costo_preparacion, 0) <= 0 THEN
            RETURN QUERY SELECT
                NULL::TEXT, 'Costo de preparacion no configurado para producto/tecnica'::TEXT,
                0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, NULL::UUID,
                jsonb_build_object(
                    'id_producto_tecnica', v_producto_tecnica.id_producto_tecnica,
                    'numero_preparaciones', p_numero_preparaciones
                ),
                'PREPARATION_COST_NOT_CONFIGURED'::TEXT;
            RETURN;
        END IF;

        IF p_numero_preparaciones > 0
           AND v_producto_tecnica.moneda_preparacion <> p_moneda THEN
            RETURN QUERY SELECT
                NULL::TEXT, 'Moneda de preparacion no coincide con cotizacion'::TEXT,
                0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, NULL::UUID,
                jsonb_build_object(
                    'moneda_preparacion', v_producto_tecnica.moneda_preparacion,
                    'moneda_cotizacion', p_moneda
                ),
                'PREPARATION_CURRENCY_MISMATCH'::TEXT;
            RETURN;
        END IF;
    END IF;

    IF p_id_tecnica IS NULL THEN
        v_qty_produccion := p_cantidad;
    ELSE
        v_qty_produccion := CEIL(p_cantidad * (1 + COALESCE(v_producto_tecnica.merma_pct, 0) / 100.0));
    END IF;

    SELECT cp.*
      INTO v_cost
      FROM costo_producto cp
     WHERE cp.id_producto = p_id_producto
       AND COALESCE(cp.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
       AND cp.vigencia @> p_at
       AND cp.moneda = p_moneda
     ORDER BY (cp.id_variante IS NOT NULL) DESC, lower(cp.vigencia) DESC
     LIMIT 1;

    IF v_cost.id_costo IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Costo vigente no encontrado'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('moneda', p_moneda),
            'COST_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    WITH policy AS (
        SELECT mpc.* FROM margin_policy_component mpc
        WHERE mpc.id_margin_policy_version = v_id_policy
    ),
    raw_components AS (
        SELECT
            'PRODUCTO'::TEXT AS tipo_componente,
            'Producto base con merma de produccion'::TEXT AS descripcion,
            v_qty_produccion::NUMERIC AS cantidad,
            v_cost.costo_base::NUMERIC AS costo_unitario,
            (v_cost.costo_base * v_qty_produccion)::NUMERIC AS costo_total,
            'COSTO_PRODUCTO'::TEXT AS source_type,
            v_cost.id_costo AS source_snapshot_id,
            jsonb_build_object(
                'cantidad_cliente', p_cantidad, 'cantidad_produccion', v_qty_produccion,
                'merma_pct', CASE WHEN p_id_tecnica IS NULL THEN 0 ELSE COALESCE(v_producto_tecnica.merma_pct, 0) END
            ) AS metadata
        WHERE v_cost.costo_base > 0

        UNION ALL
        SELECT 'MARCACION', 'Marcacion/personalizacion desde snapshot curado',
            p_cantidad::NUMERIC, v_marking_snapshot.price_value::NUMERIC,
            (v_marking_snapshot.price_value * p_cantidad)::NUMERIC,
            'PRECIO_TECNICA_SNAPSHOT', v_marking_snapshot.id_snapshot,
            jsonb_build_object(
                'id_tecnica', p_id_tecnica, 'producto_tecnica', v_producto_tecnica.id_producto_tecnica,
                'billing_unit', v_marking_snapshot.billing_unit, 'formula_code', v_marking_snapshot.formula_code,
                'quantity_min', v_marking_snapshot.quantity_min, 'quantity_max', v_marking_snapshot.quantity_max
            )
        WHERE p_id_tecnica IS NOT NULL

        UNION ALL
        SELECT 'MARCACION', 'Marcacion/personalizacion desde costo_producto',
            p_cantidad::NUMERIC, v_cost.costo_personalizacion::NUMERIC,
            (v_cost.costo_personalizacion * p_cantidad)::NUMERIC,
            'COSTO_PRODUCTO', v_cost.id_costo, jsonb_build_object('id_tecnica', p_id_tecnica)
        WHERE p_id_tecnica IS NULL AND v_cost.costo_personalizacion > 0

        UNION ALL
        SELECT 'PREPARACION', 'Preparacion/setup',
            p_numero_preparaciones::NUMERIC, v_producto_tecnica.costo_preparacion::NUMERIC,
            (v_producto_tecnica.costo_preparacion * p_numero_preparaciones)::NUMERIC,
            'PRODUCTO_TECNICA', v_producto_tecnica.id_producto_tecnica,
            jsonb_build_object('id_tecnica', p_id_tecnica, 'moneda_preparacion', v_producto_tecnica.moneda_preparacion)
        WHERE p_id_tecnica IS NOT NULL AND p_numero_preparaciones > 0

        UNION ALL
        SELECT 'EMPAQUE', 'Empaque', p_cantidad::NUMERIC, v_cost.costo_empaque::NUMERIC,
            (v_cost.costo_empaque * p_cantidad)::NUMERIC, 'COSTO_PRODUCTO', v_cost.id_costo, '{}'::JSONB
        WHERE v_cost.costo_empaque > 0

        UNION ALL
        SELECT 'OTRO', 'Otros costos', p_cantidad::NUMERIC, v_cost.otros_costos::NUMERIC,
            (v_cost.otros_costos * p_cantidad)::NUMERIC, 'COSTO_PRODUCTO', v_cost.id_costo, '{}'::JSONB
        WHERE v_cost.otros_costos > 0

        UNION ALL
        SELECT 'TRANSPORTE', 'Transporte', 1::NUMERIC, p_transporte_total::NUMERIC,
            p_transporte_total::NUMERIC, 'MANUAL', NULL::UUID, '{}'::JSONB
        WHERE COALESCE(p_transporte_total, 0) > 0
    )
    SELECT
        rc.tipo_componente, rc.descripcion, rc.cantidad,
        round(rc.costo_unitario, 4) AS costo_unitario,
        round(rc.costo_total, 2) AS costo_total,
        COALESCE(p.pricing_method, 'MARGIN') AS pricing_method,
        COALESCE(p_margen_override_pct, p.target_pct, 0) AS margen_aplicado_pct,
        COALESCE(p.minimum_pct, 0) AS minimum_pct,
        CASE
            WHEN COALESCE(p.pricing_method, 'MARGIN') = 'PASS_THROUGH'
                THEN round(fn_quote_apply_margin(rc.costo_total, COALESCE(p.pricing_method, 'MARGIN'), COALESCE(p_margen_override_pct, p.target_pct, 0)), 2)
            ELSE fn_quote_round(fn_quote_apply_margin(rc.costo_total, COALESCE(p.pricing_method, 'MARGIN'), COALESCE(p_margen_override_pct, p.target_pct, 0)), v_rounding_rule)
        END AS precio_resultante,
        rc.source_type, rc.source_snapshot_id,
        rc.metadata || jsonb_build_object('policy_id', v_id_policy, 'rounding_rule', v_rounding_rule, 'minimum_pct', COALESCE(p.minimum_pct, 0)) AS metadata,
        'OK'::TEXT AS status
    FROM raw_components rc
    LEFT JOIN policy p ON p.tipo_componente = rc.tipo_componente
    ORDER BY CASE rc.tipo_componente
        WHEN 'PRODUCTO' THEN 1 WHEN 'MARCACION' THEN 2 WHEN 'PREPARACION' THEN 3
        WHEN 'EMPAQUE' THEN 4 WHEN 'TRANSPORTE' THEN 5 ELSE 9
    END;
END;
$function$;

REVOKE ALL ON FUNCTION fn_quote_calculate_components_core(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, NUMERIC) FROM PUBLIC, authenticated;

COMMENT ON FUNCTION fn_quote_calculate_components_core(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, NUMERIC) IS
    'Nucleo de calculo sin guardia de rol, extraido de fn_calculate_quote_components (058) en 060. Solo alcanzable por llamada anidada desde otra funcion SECURITY DEFINER (fn_calculate_quote_components o fn_consola_crear_cotizacion_calculada) - nunca otorgada a authenticated directamente.';

-- fn_calculate_quote_components pasa a ser un envoltorio delgado: guardia
-- ADMIN + llamada al nucleo, sin margen override (el simulador no lo ofrece).
CREATE OR REPLACE FUNCTION public.fn_calculate_quote_components(
    p_id_producto uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_cantidad integer DEFAULT 1,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_at timestamp with time zone DEFAULT now(),
    p_moneda text DEFAULT 'COP'::text
)
RETURNS TABLE(
    tipo_componente text, descripcion text, cantidad numeric, costo_unitario numeric,
    costo_total numeric, pricing_method text, margen_aplicado_pct numeric,
    precio_resultante numeric, source_type text, source_snapshot_id uuid,
    metadata jsonb, status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS DISTINCT FROM 'ADMIN' THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Solo ADMIN puede consultar costos y margenes'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC, 'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, '{}'::JSONB, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT c.tipo_componente, c.descripcion, c.cantidad, c.costo_unitario, c.costo_total,
           c.pricing_method, c.margen_aplicado_pct, c.precio_resultante, c.source_type,
           c.source_snapshot_id, c.metadata, c.status
      FROM fn_quote_calculate_components_core(
          p_id_producto, p_id_variante, p_cantidad, p_id_tecnica, p_numero_preparaciones,
          p_transporte_total, p_policy_code, p_at, p_moneda, NULL
      ) c;
END;
$function$;

REVOKE ALL ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) IS
    'Simulador ADMIN-only. Desde 060 es un envoltorio delgado sobre fn_quote_calculate_components_core; el calculo real vive ahi para compartirse con fn_consola_crear_cotizacion_calculada.';
