-- Una unidad ausente no prueba que el precio sea unitario.
-- Conserva snapshots historicos; exige nueva observacion con unidad confirmada.
CREATE OR REPLACE FUNCTION public.fn_quote_calculate_supplier_components_core(
    p_id_precio_proveedor_snapshot uuid,
    p_cantidad integer,
    p_marking_lines jsonb DEFAULT '[]'::jsonb,
    p_transporte_total numeric DEFAULT 0,
    p_transport_mode text DEFAULT 'SEPARATE_LINE',
    p_policy_code text DEFAULT 'MVP_DEFAULT',
    p_at timestamp with time zone DEFAULT now(),
    p_moneda text DEFAULT 'COP',
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
    v_id_policy UUID;
    v_rounding_rule TEXT;
    v_snapshot RECORD;
    v_unit_cost NUMERIC;
    v_unidad TEXT;
    v_pack_qty NUMERIC;
    v_qty_comprada NUMERIC;
    v_qty_sobrante NUMERIC;
    v_line JSONB;
    v_tech_snapshot RECORD;
    v_line_qty NUMERIC;
    v_line_width NUMERIC;
    v_line_height NUMERIC;
    v_line_waste NUMERIC;
    v_line_setup NUMERIC;
    v_line_cost NUMERIC;
    v_line_unit_cost NUMERIC;
    v_line_billing_unit TEXT;
    v_line_desc TEXT;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RETURN QUERY SELECT NULL::TEXT, 'Cantidad invalida'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, '{}'::JSONB, 'INVALID_QUANTITY'::TEXT;
        RETURN;
    END IF;

    IF COALESCE(p_transport_mode, 'SEPARATE_LINE') NOT IN ('SEPARATE_LINE', 'DISTRIBUTED') THEN
        RETURN QUERY SELECT NULL::TEXT, 'Modo de transporte invalido'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, jsonb_build_object('transport_mode', p_transport_mode), 'INVALID_TRANSPORT_MODE'::TEXT;
        RETURN;
    END IF;

    IF jsonb_typeof(COALESCE(p_marking_lines, '[]'::jsonb)) <> 'array' THEN
        RETURN QUERY SELECT NULL::TEXT, 'Las lineas de marcacion deben ser arreglo JSON'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, '{}'::JSONB, 'INVALID_MARKING_LINES'::TEXT;
        RETURN;
    END IF;

    SELECT mpv.id_margin_policy_version, mpv.rounding_rule
      INTO v_id_policy, v_rounding_rule
      FROM margin_policy_version mpv
     WHERE mpv.codigo = COALESCE(p_policy_code, 'MVP_DEFAULT')
       AND mpv.estado = 'ACTIVE'
       AND mpv.vigencia @> p_at
     ORDER BY lower(mpv.vigencia) DESC
     LIMIT 1;

    IF v_id_policy IS NULL THEN
        RETURN QUERY SELECT NULL::TEXT, 'Politica de margen no encontrada'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, jsonb_build_object('policy_code', p_policy_code), 'MARGIN_POLICY_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    SELECT
        pps.id_snapshot,
        pps.id_producto_proveedor,
        pps.precio_publicado,
        pps.moneda,
        pps.unidad_compra,
        pps.cantidad_pack,
        pps.minimo_compra,
        pps.incremento_compra,
        pps.formato_compra,
        pps.precio_vigencia,
        pps.url_fuente,
        pps.observado_en,
        pp.nombre_original,
        pp.sku_proveedor,
        pp.categoria,
        pr.id_proveedor,
        pr.nombre AS proveedor_nombre
      INTO v_snapshot
      FROM precio_proveedor_snapshot pps
      JOIN producto_proveedor pp ON pp.id_producto_proveedor = pps.id_producto_proveedor
      JOIN proveedor pr ON pr.id_proveedor = pp.id_proveedor
     WHERE pps.id_snapshot = p_id_precio_proveedor_snapshot
       AND pps.moneda = p_moneda
       AND pp.estado_calidad <> 'REJECTED'
       AND pr.activo
       AND (pps.precio_vigencia IS NULL OR pps.precio_vigencia @> p_at)
     LIMIT 1;

    IF v_snapshot.id_snapshot IS NULL THEN
        RETURN QUERY SELECT NULL::TEXT, 'Snapshot de proveedor no encontrado o no vigente'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, jsonb_build_object('id_snapshot', p_id_precio_proveedor_snapshot), 'SUPPLIER_PRICE_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    IF v_snapshot.unidad_compra IS NULL THEN
        RETURN QUERY SELECT NULL::TEXT, 'Confirma la unidad de compra con una nueva observacion de precio'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, v_snapshot.id_snapshot, '{}'::JSONB, 'PURCHASE_UNIT_UNVERIFIED'::TEXT;
        RETURN;
    END IF;
    v_unidad := v_snapshot.unidad_compra;
    v_pack_qty := CASE WHEN v_unidad = 'PACK' THEN COALESCE(v_snapshot.cantidad_pack, 0) ELSE 1 END;

    IF v_unidad = 'PACK' AND v_pack_qty <= 0 THEN
        RETURN QUERY SELECT NULL::TEXT, 'Pack sin cantidad_pack valida'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, v_snapshot.id_snapshot, '{}'::JSONB, 'INVALID_PACK_QUANTITY'::TEXT;
        RETURN;
    END IF;

    v_unit_cost := CASE
        WHEN v_unidad = 'PACK' THEN v_snapshot.precio_publicado / v_pack_qty
        ELSE v_snapshot.precio_publicado
    END;
    v_qty_comprada := CASE
        WHEN v_unidad = 'PACK' THEN CEIL(p_cantidad::NUMERIC / v_pack_qty) * v_pack_qty
        ELSE p_cantidad
    END;
    v_qty_sobrante := GREATEST(v_qty_comprada - p_cantidad, 0);

    DROP TABLE IF EXISTS pg_temp.tmp_quote_supplier_components;
    CREATE TEMP TABLE tmp_quote_supplier_components (
        tipo_componente TEXT,
        descripcion TEXT,
        cantidad NUMERIC,
        costo_unitario NUMERIC,
        costo_total NUMERIC,
        source_type TEXT,
        source_snapshot_id UUID,
        metadata JSONB
    ) ON COMMIT DROP;

    INSERT INTO tmp_quote_supplier_components
    VALUES (
        'PRODUCTO',
        'Producto proveedor: ' || v_snapshot.nombre_original,
        p_cantidad,
        v_unit_cost,
        v_unit_cost * p_cantidad,
        'PRECIO_PROVEEDOR_SNAPSHOT',
        v_snapshot.id_snapshot,
        jsonb_build_object(
            'id_producto_proveedor', v_snapshot.id_producto_proveedor,
            'id_proveedor', v_snapshot.id_proveedor,
            'proveedor', v_snapshot.proveedor_nombre,
            'sku_proveedor', v_snapshot.sku_proveedor,
            'unidad_compra', v_unidad,
            'cantidad_pack', v_snapshot.cantidad_pack,
            'precio_publicado', v_snapshot.precio_publicado,
            'cantidad_comprada', v_qty_comprada,
            'cantidad_usada', p_cantidad,
            'cantidad_sobrante', v_qty_sobrante,
            'url_fuente', v_snapshot.url_fuente,
            'observado_en', v_snapshot.observado_en
        )
    );

    FOR v_line IN SELECT value FROM jsonb_array_elements(COALESCE(p_marking_lines, '[]'::jsonb))
    LOOP
        IF COALESCE(v_line->>'id_snapshot', '') = '' THEN
            RETURN QUERY SELECT NULL::TEXT, 'Linea de marcacion sin snapshot'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, NULL::UUID, v_line, 'MARKING_SNAPSHOT_REQUIRED'::TEXT;
            RETURN;
        END IF;

        SELECT
            pts.id_snapshot, pts.id_tecnica, pts.id_proveedor_tecnica, pts.billing_unit,
            pts.price_value, pts.width_cm, pts.height_cm, pts.quantity_min, pts.quantity_max,
            pts.currency, pts.size_label, pts.formato_costeo, pts.source_url,
            tm.codigo AS tecnica_codigo, ptm.nombre AS proveedor_tecnica_nombre
          INTO v_tech_snapshot
          FROM precio_tecnica_marcacion_snapshot pts
          JOIN tecnica_marcacion tm ON tm.id_tecnica = pts.id_tecnica
          JOIN proveedor_tecnica_marcacion ptm ON ptm.id_proveedor_tecnica = pts.id_proveedor_tecnica
         WHERE pts.id_snapshot = (v_line->>'id_snapshot')::uuid
           AND pts.currency = p_moneda
           AND pts.price_value IS NOT NULL
           AND pts.verification_status IN ('VERIFIED_PUBLIC_PRICE', 'PENDING_REVIEW')
           AND (pts.quantity_min IS NULL OR pts.quantity_min <= p_cantidad)
           AND (pts.quantity_max IS NULL OR pts.quantity_max >= p_cantidad)
         LIMIT 1;

        IF v_tech_snapshot.id_snapshot IS NULL THEN
            RETURN QUERY SELECT NULL::TEXT, 'Snapshot de tecnica no aplicable'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, NULL::UUID, v_line, 'MARKING_COST_NOT_FOUND'::TEXT;
            RETURN;
        END IF;

        v_line_qty := COALESCE(NULLIF(v_line->>'cantidad', '')::NUMERIC, p_cantidad);
        v_line_width := NULLIF(v_line->>'ancho_cm', '')::NUMERIC;
        v_line_height := NULLIF(v_line->>'alto_cm', '')::NUMERIC;
        v_line_waste := COALESCE(NULLIF(v_line->>'merma_pct', '')::NUMERIC, 0);
        v_line_setup := COALESCE(NULLIF(v_line->>'costo_preparacion', '')::NUMERIC, 0);
        v_line_billing_unit := lower(COALESCE(v_tech_snapshot.billing_unit, 'unidad'));
        v_line_desc := COALESCE(NULLIF(v_line->>'descripcion', ''), 'Marcacion ' || v_tech_snapshot.tecnica_codigo);

        v_line_unit_cost := CASE
            WHEN v_line_billing_unit IN ('unidad', 'unit', 'und') THEN v_tech_snapshot.price_value
            WHEN v_line_billing_unit IN ('metro', 'metro_lineal', 'm') THEN
                CASE
                    WHEN COALESCE(v_line_width, v_tech_snapshot.width_cm) IS NULL OR v_line_height IS NULL THEN NULL
                    ELSE (
                        (COALESCE(v_line_width, v_tech_snapshot.width_cm) * v_line_height)
                        / NULLIF(COALESCE(v_tech_snapshot.width_cm, COALESCE(v_line_width, v_tech_snapshot.width_cm)), 0)
                        / 100.0
                        * (1 + v_line_waste / 100.0)
                        * v_tech_snapshot.price_value
                    )
                END
            WHEN v_line_billing_unit IN ('hoja', 'sheet') THEN
                v_tech_snapshot.price_value / GREATEST(COALESCE(NULLIF(v_line->>'unidades_por_hoja', '')::NUMERIC, 1), 1)
            ELSE v_tech_snapshot.price_value
        END;

        IF v_line_unit_cost IS NULL THEN
            RETURN QUERY SELECT NULL::TEXT, 'Linea de marcacion sin dimensiones suficientes'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, v_tech_snapshot.id_snapshot, v_line, 'MARKING_DIMENSIONS_REQUIRED'::TEXT;
            RETURN;
        END IF;

        v_line_cost := v_line_unit_cost * v_line_qty;

        INSERT INTO tmp_quote_supplier_components
        VALUES (
            'MARCACION',
            v_line_desc,
            v_line_qty,
            v_line_unit_cost,
            v_line_cost,
            'PRECIO_TECNICA_SNAPSHOT',
            v_tech_snapshot.id_snapshot,
            v_line || jsonb_build_object(
                'id_tecnica', v_tech_snapshot.id_tecnica,
                'tecnica', v_tech_snapshot.tecnica_codigo,
                'id_proveedor_tecnica', v_tech_snapshot.id_proveedor_tecnica,
                'proveedor_tecnica', v_tech_snapshot.proveedor_tecnica_nombre,
                'billing_unit', v_tech_snapshot.billing_unit,
                'price_value', v_tech_snapshot.price_value,
                'line_unit_cost', v_line_unit_cost,
                'source_url', v_tech_snapshot.source_url
            )
        );

        IF v_line_setup > 0 THEN
            INSERT INTO tmp_quote_supplier_components
            VALUES (
                'PREPARACION',
                'Preparacion/setup: ' || v_line_desc,
                COALESCE(NULLIF(v_line->>'numero_preparaciones', '')::NUMERIC, 1),
                v_line_setup,
                v_line_setup * COALESCE(NULLIF(v_line->>'numero_preparaciones', '')::NUMERIC, 1),
                'MANUAL',
                NULL::UUID,
                v_line || jsonb_build_object('id_snapshot_tecnica', v_tech_snapshot.id_snapshot)
            );
        END IF;
    END LOOP;

    IF COALESCE(p_transporte_total, 0) > 0 THEN
        INSERT INTO tmp_quote_supplier_components
        VALUES (
            'TRANSPORTE',
            CASE WHEN p_transport_mode = 'DISTRIBUTED' THEN 'Transporte distribuido' ELSE 'Transporte' END,
            CASE WHEN p_transport_mode = 'DISTRIBUTED' THEN p_cantidad ELSE 1 END,
            CASE WHEN p_transport_mode = 'DISTRIBUTED' THEN p_transporte_total / p_cantidad ELSE p_transporte_total END,
            p_transporte_total,
            'MANUAL',
            NULL::UUID,
            jsonb_build_object('transport_mode', COALESCE(p_transport_mode, 'SEPARATE_LINE'))
        );
    END IF;

    RETURN QUERY
    WITH policy AS (
        SELECT mpc.*
          FROM margin_policy_component mpc
         WHERE mpc.id_margin_policy_version = v_id_policy
    )
    SELECT
        rc.tipo_componente,
        rc.descripcion,
        round(rc.cantidad, 4),
        round(rc.costo_unitario, 4),
        round(rc.costo_total, 2),
        COALESCE(p.pricing_method, 'MARGIN'),
        COALESCE(p_margen_override_pct, p.target_pct, 0),
        COALESCE(p.minimum_pct, 0),
        CASE
            WHEN COALESCE(p.pricing_method, 'MARGIN') = 'PASS_THROUGH'
                THEN round(fn_quote_apply_margin(rc.costo_total, COALESCE(p.pricing_method, 'MARGIN'), COALESCE(p_margen_override_pct, p.target_pct, 0)), 2)
            ELSE fn_quote_round(fn_quote_apply_margin(rc.costo_total, COALESCE(p.pricing_method, 'MARGIN'), COALESCE(p_margen_override_pct, p.target_pct, 0)), v_rounding_rule)
        END,
        rc.source_type,
        rc.source_snapshot_id,
        rc.metadata || jsonb_build_object('policy_id', v_id_policy, 'rounding_rule', v_rounding_rule, 'minimum_pct', COALESCE(p.minimum_pct, 0)),
        'OK'::TEXT
      FROM tmp_quote_supplier_components rc
      LEFT JOIN policy p ON p.tipo_componente = rc.tipo_componente
     ORDER BY CASE rc.tipo_componente
        WHEN 'PRODUCTO' THEN 1 WHEN 'MARCACION' THEN 2 WHEN 'PREPARACION' THEN 3
        WHEN 'EMPAQUE' THEN 4 WHEN 'TRANSPORTE' THEN 5 ELSE 9 END;
END;
$function$;

REVOKE ALL ON FUNCTION fn_quote_calculate_supplier_components_core(UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, TIMESTAMPTZ, TEXT, NUMERIC) FROM PUBLIC, authenticated;

