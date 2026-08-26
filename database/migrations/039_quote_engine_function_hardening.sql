-- ============================================================
-- 039_quote_engine_function_hardening.sql
--
-- Endurece fn_calculate_quote_components() para que las rutas de error
-- usen ROWTYPE explícito y siempre devuelvan estados controlados cuando
-- falte producto_tecnica o costo_producto.
--
-- Tambien elimina la vista placeholder vw_calculated_quote_summary creada
-- en 038; el resumen final debe salir de una vista/funcion real cuando se
-- escriba la cotizacion calculada completa.
-- ============================================================

DROP VIEW IF EXISTS vw_calculated_quote_summary;

CREATE OR REPLACE FUNCTION fn_calculate_quote_components(
    p_id_producto UUID,
    p_id_variante UUID DEFAULT NULL,
    p_cantidad INTEGER DEFAULT 1,
    p_id_tecnica UUID DEFAULT NULL,
    p_numero_preparaciones INTEGER DEFAULT 1,
    p_transporte_total NUMERIC DEFAULT 0,
    p_policy_code TEXT DEFAULT 'MVP_DEFAULT',
    p_at TIMESTAMPTZ DEFAULT now(),
    p_moneda TEXT DEFAULT 'COP'
)
RETURNS TABLE (
    tipo_componente TEXT,
    descripcion TEXT,
    cantidad NUMERIC,
    costo_unitario NUMERIC,
    costo_total NUMERIC,
    pricing_method TEXT,
    margen_aplicado_pct NUMERIC,
    precio_resultante NUMERIC,
    source_type TEXT,
    source_snapshot_id UUID,
    metadata JSONB,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id_policy UUID;
    v_rounding_rule TEXT;
    v_cost costo_producto%ROWTYPE;
    v_producto_tecnica producto_tecnica%ROWTYPE;
    v_qty_produccion INTEGER;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Cantidad invalida'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            '{}'::JSONB, 'INVALID_QUANTITY'::TEXT;
        RETURN;
    END IF;

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
            NULL::TEXT, 'Politica de margen no encontrada'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('policy_code', p_policy_code), 'MARGIN_POLICY_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    SELECT pt.*
      INTO v_producto_tecnica
      FROM producto_tecnica pt
     WHERE pt.id_producto = p_id_producto
       AND COALESCE(pt.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
       AND (p_id_tecnica IS NULL OR pt.id_tecnica = p_id_tecnica)
       AND pt.permitida
     ORDER BY (pt.id_variante IS NOT NULL) DESC, pt.created_at DESC
     LIMIT 1;

    IF p_id_tecnica IS NOT NULL AND v_producto_tecnica.id_producto_tecnica IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Tecnica no permitida/configurada para producto'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('id_tecnica', p_id_tecnica), 'PRODUCT_TECHNIQUE_NOT_CONFIGURED'::TEXT;
        RETURN;
    END IF;

    IF v_producto_tecnica.id_producto_tecnica IS NOT NULL
       AND p_cantidad < v_producto_tecnica.cantidad_minima_tecnica THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Cantidad inferior al minimo tecnico'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            jsonb_build_object(
                'cantidad_minima_tecnica', v_producto_tecnica.cantidad_minima_tecnica,
                'id_producto_tecnica', v_producto_tecnica.id_producto_tecnica
            ), 'BELOW_TECHNIQUE_MINIMUM'::TEXT;
        RETURN;
    END IF;

    v_qty_produccion := CEIL(p_cantidad * (1 + COALESCE(v_producto_tecnica.merma_pct, 0) / 100.0));

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
            NULL::TEXT, 'Costo vigente no encontrado'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('moneda', p_moneda), 'COST_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    WITH policy AS (
        SELECT mpc.*
        FROM margin_policy_component mpc
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
                'cantidad_cliente', p_cantidad,
                'cantidad_produccion', v_qty_produccion,
                'merma_pct', COALESCE(v_producto_tecnica.merma_pct, 0)
            ) AS metadata
        WHERE v_cost.costo_base > 0

        UNION ALL
        SELECT
            'MARCACION',
            'Marcacion/personalizacion',
            p_cantidad::NUMERIC,
            v_cost.costo_personalizacion::NUMERIC,
            (v_cost.costo_personalizacion * p_cantidad)::NUMERIC,
            'COSTO_PRODUCTO',
            v_cost.id_costo,
            jsonb_build_object(
                'id_tecnica', p_id_tecnica,
                'numero_preparaciones', p_numero_preparaciones,
                'producto_tecnica', v_producto_tecnica.id_producto_tecnica
            )
        WHERE v_cost.costo_personalizacion > 0

        UNION ALL
        SELECT
            'EMPAQUE',
            'Empaque',
            p_cantidad::NUMERIC,
            v_cost.costo_empaque::NUMERIC,
            (v_cost.costo_empaque * p_cantidad)::NUMERIC,
            'COSTO_PRODUCTO',
            v_cost.id_costo,
            '{}'::JSONB
        WHERE v_cost.costo_empaque > 0

        UNION ALL
        SELECT
            'OTRO',
            'Otros costos',
            p_cantidad::NUMERIC,
            v_cost.otros_costos::NUMERIC,
            (v_cost.otros_costos * p_cantidad)::NUMERIC,
            'COSTO_PRODUCTO',
            v_cost.id_costo,
            '{}'::JSONB
        WHERE v_cost.otros_costos > 0

        UNION ALL
        SELECT
            'TRANSPORTE',
            'Transporte',
            1::NUMERIC,
            p_transporte_total::NUMERIC,
            p_transporte_total::NUMERIC,
            'MANUAL',
            NULL::UUID,
            '{}'::JSONB
        WHERE COALESCE(p_transporte_total, 0) > 0
    )
    SELECT
        rc.tipo_componente,
        rc.descripcion,
        rc.cantidad,
        round(rc.costo_unitario, 4) AS costo_unitario,
        round(rc.costo_total, 2) AS costo_total,
        COALESCE(p.pricing_method, 'MARGIN') AS pricing_method,
        COALESCE(p.target_pct, 0) AS margen_aplicado_pct,
        round(fn_quote_apply_margin(
            rc.costo_total,
            COALESCE(p.pricing_method, 'MARGIN'),
            COALESCE(p.target_pct, 0)
        ), 2) AS precio_resultante,
        rc.source_type,
        rc.source_snapshot_id,
        rc.metadata || jsonb_build_object(
            'policy_id', v_id_policy,
            'rounding_rule', v_rounding_rule,
            'minimum_pct', COALESCE(p.minimum_pct, 0)
        ) AS metadata,
        'OK'::TEXT AS status
    FROM raw_components rc
    LEFT JOIN policy p ON p.tipo_componente = rc.tipo_componente
    ORDER BY CASE rc.tipo_componente
        WHEN 'PRODUCTO' THEN 1
        WHEN 'MARCACION' THEN 2
        WHEN 'PREPARACION' THEN 3
        WHEN 'EMPAQUE' THEN 4
        WHEN 'TRANSPORTE' THEN 5
        ELSE 9
    END;
END;
$$;

REVOKE ALL ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) TO authenticated;

