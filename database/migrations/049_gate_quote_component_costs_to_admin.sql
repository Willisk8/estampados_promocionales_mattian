-- ============================================================
-- 049_gate_quote_component_costs_to_admin.sql
--
-- Corrige un hallazgo real (P1) de revision de codigo externa sobre
-- fn_calculate_quote_components (038/039, anterior a la Etapa C).
--
-- HALLAZGO
-- La funcion es SECURITY DEFINER, otorgada a authenticated, y no
-- verificaba fn_consola_rol() en absoluto. Cualquier usuario autenticado
-- -incluso uno SIN fila en perfil_usuario- podia invocarla directo y
-- recibir costo_unitario, costo_total y margen_aplicado_pct reales para
-- cualquier producto: exactamente los "costos del catalogo propio" que
-- docs/consola_acceso.md documenta como exclusivos de ADMIN
-- ("Costos del catalogo propio | no | no | si").
--
-- Verificado antes de corregir: proacl mostraba EXECUTE para
-- authenticated, y pg_get_functiondef confirmo cero referencias a
-- fn_consola_rol o v_rol en el cuerpo de la funcion.
--
-- CORRECCION
-- Guardia de rol como PRIMER chequeo, devolviendo status='FORBIDDEN' -no
-- RAISE EXCEPTION- para no romper el contrato de la funcion, que en
-- todas sus demas rutas de fallo (INVALID_QUANTITY, COST_NOT_FOUND, etc.)
-- ya devuelve un estado controlado en vez de lanzar.
--
-- No se toca el GRANT a authenticated: la funcion sigue siendo invocable
-- por cualquier sesion con perfil activo, pero solo ADMIN recibe datos;
-- el resto recibe FORBIDDEN. Mismo patron que las fn_ai_*.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_calculate_quote_components(p_id_producto uuid, p_id_variante uuid DEFAULT NULL::uuid, p_cantidad integer DEFAULT 1, p_id_tecnica uuid DEFAULT NULL::uuid, p_numero_preparaciones integer DEFAULT 1, p_transporte_total numeric DEFAULT 0, p_policy_code text DEFAULT 'MVP_DEFAULT'::text, p_at timestamp with time zone DEFAULT now(), p_moneda text DEFAULT 'COP'::text)
 RETURNS TABLE(tipo_componente text, descripcion text, cantidad numeric, costo_unitario numeric, costo_total numeric, pricing_method text, margen_aplicado_pct numeric, precio_resultante numeric, source_type text, source_snapshot_id uuid, metadata jsonb, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_id_policy UUID;
    v_rounding_rule TEXT;
    v_cost costo_producto%ROWTYPE;
    v_producto_tecnica producto_tecnica%ROWTYPE;
    v_qty_produccion INTEGER;
BEGIN
    -- Costos y margenes internos: mismo nivel de acceso que
    -- "costos del catalogo propio" en docs/consola_acceso.md (solo ADMIN,
    -- ni COMERCIAL ni LECTURA). Antes de esta correccion, cualquier
    -- authenticated -incluso sin fila en perfil_usuario- podia llamarla y
    -- recibir costo_unitario/costo_total/margen_aplicado_pct reales.
    IF v_rol IS DISTINCT FROM 'ADMIN' THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Solo ADMIN puede consultar costos y margenes'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            '{}'::JSONB, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

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
$function$;

COMMENT ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) IS
    'Corregido en 049: exige rol ADMIN (antes no verificaba ningun rol). Expone costos y margenes internos, mismo nivel que "costos del catalogo propio" en docs/consola_acceso.md.';
