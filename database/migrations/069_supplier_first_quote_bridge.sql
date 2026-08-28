-- ============================================================
-- 069_supplier_first_quote_bridge.sql
--
-- Puente proveedor-first para el cotizador.
--
-- El cotizador anterior exige producto propio ACTIVE y costo_producto.
-- Este puente permite cotizar directamente desde producto_proveedor y
-- precio_proveedor_snapshot, conservando snapshots auditables. No reemplaza
-- resolve_price() ni fn_consola_crear_cotizacion_calculada(); agrega un
-- camino paralelo para el flujo real de compra a proveedores.
-- ============================================================

ALTER TABLE cotizacion_item
    ALTER COLUMN id_producto DROP NOT NULL,
    ADD COLUMN IF NOT EXISTS source_mode TEXT NOT NULL DEFAULT 'OWN_PRODUCT',
    ADD COLUMN IF NOT EXISTS id_producto_proveedor UUID REFERENCES producto_proveedor(id_producto_proveedor),
    ADD COLUMN IF NOT EXISTS id_precio_proveedor_snapshot UUID REFERENCES precio_proveedor_snapshot(id_snapshot),
    ADD COLUMN IF NOT EXISTS proveedor_snapshot JSONB NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS nombre_item_snapshot TEXT,
    ADD COLUMN IF NOT EXISTS sku_proveedor_snapshot TEXT,
    ADD COLUMN IF NOT EXISTS costo_compra_unitario_snapshot NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS unidad_compra_snapshot TEXT,
    ADD COLUMN IF NOT EXISTS cantidad_pack_snapshot NUMERIC(12,4),
    ADD COLUMN IF NOT EXISTS cantidad_comprada NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS cantidad_usada NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS cantidad_sobrante NUMERIC(14,4),
    ADD COLUMN IF NOT EXISTS metadata_costeo JSONB NOT NULL DEFAULT '{}';

ALTER TABLE cotizacion_item
    DROP CONSTRAINT IF EXISTS cotizacion_item_source_mode_check,
    ADD CONSTRAINT cotizacion_item_source_mode_check
        CHECK (source_mode IN ('OWN_PRODUCT', 'SUPPLIER_PRODUCT', 'MANUAL')),
    DROP CONSTRAINT IF EXISTS cotizacion_item_fuente_check,
    ADD CONSTRAINT cotizacion_item_fuente_check
        CHECK (
            (source_mode = 'OWN_PRODUCT' AND id_producto IS NOT NULL)
            OR (source_mode = 'SUPPLIER_PRODUCT'
                AND id_producto_proveedor IS NOT NULL
                AND id_precio_proveedor_snapshot IS NOT NULL)
            OR source_mode = 'MANUAL'
        ),
    DROP CONSTRAINT IF EXISTS cotizacion_item_compra_cantidades_check,
    ADD CONSTRAINT cotizacion_item_compra_cantidades_check
        CHECK (
            cantidad_comprada IS NULL OR cantidad_usada IS NULL
            OR (
                cantidad_comprada >= 0
                AND cantidad_usada >= 0
                AND COALESCE(cantidad_sobrante, 0) >= 0
                AND cantidad_comprada >= cantidad_usada
            )
        );

CREATE INDEX IF NOT EXISTS idx_cotizacion_item_source_mode
    ON cotizacion_item (source_mode);

CREATE INDEX IF NOT EXISTS idx_cotizacion_item_producto_proveedor
    ON cotizacion_item (id_producto_proveedor);

CREATE INDEX IF NOT EXISTS idx_cotizacion_item_precio_proveedor_snapshot
    ON cotizacion_item (id_precio_proveedor_snapshot);

COMMENT ON COLUMN cotizacion_item.source_mode IS
    'Origen comercial del item: producto propio, producto de proveedor o item manual.';
COMMENT ON COLUMN cotizacion_item.id_producto_proveedor IS
    'Producto observado en catalogo de proveedor usado para esta cotizacion proveedor-first.';
COMMENT ON COLUMN cotizacion_item.id_precio_proveedor_snapshot IS
    'Snapshot append-only del costo proveedor usado para congelar el calculo.';
COMMENT ON COLUMN cotizacion_item.metadata_costeo IS
    'Detalle auditable del criterio de compra: pack, unidades usadas/sobrantes, origen manual, formula, etc.';

CREATE OR REPLACE FUNCTION public.fn_quote_supplier_payload_matches(
    p_id_cotizacion uuid,
    p_id_organizacion uuid,
    p_id_precio_proveedor_snapshot uuid,
    p_cantidad integer,
    p_marking_lines jsonb,
    p_transporte_total numeric,
    p_transport_mode text,
    p_policy_code text,
    p_margen_override_pct numeric
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(bool_and(
        c.id_organizacion IS NOT DISTINCT FROM p_id_organizacion
        AND ci.id_precio_proveedor_snapshot IS NOT DISTINCT FROM p_id_precio_proveedor_snapshot
        AND ci.cantidad IS NOT DISTINCT FROM p_cantidad
        AND COALESCE(ev.metadata->'marking_lines', '[]'::jsonb) IS NOT DISTINCT FROM COALESCE(p_marking_lines, '[]'::jsonb)
        AND COALESCE((ev.metadata->>'transporte_total')::numeric, 0) IS NOT DISTINCT FROM COALESCE(p_transporte_total, 0)
        AND COALESCE(ev.metadata->>'transport_mode', 'SEPARATE_LINE') IS NOT DISTINCT FROM COALESCE(p_transport_mode, 'SEPARATE_LINE')
        AND COALESCE(ev.metadata->>'policy_code', 'MVP_DEFAULT') IS NOT DISTINCT FROM COALESCE(p_policy_code, 'MVP_DEFAULT')
        AND (ev.metadata->>'margen_override_pct')::numeric IS NOT DISTINCT FROM p_margen_override_pct
    ), false)
      FROM cotizacion c
      JOIN cotizacion_item ci ON ci.id_cotizacion = c.id_cotizacion
      LEFT JOIN LATERAL (
          SELECT ce.metadata
            FROM cotizacion_evento ce
           WHERE ce.id_cotizacion = c.id_cotizacion
             AND ce.tipo_evento = 'CREADA'
           ORDER BY ce.occurred_at ASC
           LIMIT 1
      ) ev ON true
     WHERE c.id_cotizacion = p_id_cotizacion
       AND ci.source_mode = 'SUPPLIER_PRODUCT';
$function$;

REVOKE ALL ON FUNCTION fn_quote_supplier_payload_matches(UUID, UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC) FROM PUBLIC, authenticated;

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

    v_unidad := COALESCE(v_snapshot.unidad_compra, 'UNIT');
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
        RETURN QUERY SELECT NULL::TEXT, 'No autorizado'::TEXT, 0::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
            NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
            'NONE'::TEXT, NULL::UUID, '{}'::JSONB, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        c.tipo_componente,
        c.descripcion,
        c.cantidad,
        CASE WHEN v_rol = 'ADMIN' THEN c.costo_unitario ELSE NULL::NUMERIC END,
        CASE WHEN v_rol = 'ADMIN' THEN c.costo_total ELSE NULL::NUMERIC END,
        c.pricing_method,
        CASE WHEN v_rol = 'ADMIN' THEN c.margen_aplicado_pct ELSE NULL::NUMERIC END,
        CASE WHEN v_rol = 'ADMIN' THEN c.minimum_pct ELSE NULL::NUMERIC END,
        c.precio_resultante,
        c.source_type,
        c.source_snapshot_id,
        c.metadata,
        c.status
      FROM fn_quote_calculate_supplier_components_core(
        p_id_precio_proveedor_snapshot,
        p_cantidad,
        p_marking_lines,
        p_transporte_total,
        p_transport_mode,
        p_policy_code,
        now(),
        'COP',
        p_margen_override_pct
      ) c;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_previsualizar_cotizacion_proveedor(UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_previsualizar_cotizacion_proveedor(UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC) TO authenticated;

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
    v_uid UUID := auth.uid();
    v_key TEXT := NULLIF(btrim(p_idempotency_key), '');
    v_existing UUID;
    v_numero BIGINT;
    v_total NUMERIC;
    v_status TEXT;
    v_id_cotizacion UUID;
    v_id_item UUID;
    v_snapshot RECORD;
    v_component RECORD;
    v_id_policy UUID;
    v_unit_cost NUMERIC;
    v_unidad TEXT;
    v_pack_qty NUMERIC;
    v_qty_comprada NUMERIC;
    v_qty_sobrante NUMERIC;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear cotizaciones.';
    END IF;

    IF p_id_organizacion IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    IF v_key IS NOT NULL THEN
        SELECT c.id_cotizacion
          INTO v_existing
          FROM cotizacion c
         WHERE c.creada_por = v_uid
           AND c.idempotency_key = v_key
         LIMIT 1;

        IF v_existing IS NOT NULL THEN
            IF fn_quote_supplier_payload_matches(
                v_existing, p_id_organizacion, p_id_precio_proveedor_snapshot,
                p_cantidad, COALESCE(p_marking_lines, '[]'::jsonb),
                p_transporte_total, p_transport_mode, p_policy_code,
                p_margen_override_pct
            ) THEN
                SELECT c.numero, c.total INTO v_numero, v_total
                  FROM cotizacion c
                 WHERE c.id_cotizacion = v_existing;
                RETURN QUERY SELECT v_existing, v_numero, v_total, 'OK'::TEXT;
            ELSE
                RETURN QUERY SELECT v_existing, NULL::BIGINT, NULL::NUMERIC, 'CONFLICT'::TEXT;
            END IF;
            RETURN;
        END IF;
    END IF;

    DROP TABLE IF EXISTS pg_temp.tmp_supplier_quote_result;
    CREATE TEMP TABLE tmp_supplier_quote_result ON COMMIT DROP AS
    SELECT *
      FROM fn_quote_calculate_supplier_components_core(
        p_id_precio_proveedor_snapshot,
        p_cantidad,
        COALESCE(p_marking_lines, '[]'::jsonb),
        p_transporte_total,
        COALESCE(p_transport_mode, 'SEPARATE_LINE'),
        COALESCE(p_policy_code, 'MVP_DEFAULT'),
        now(),
        'COP',
        p_margen_override_pct
      );

    SELECT t.status INTO v_status
      FROM tmp_supplier_quote_result t
     WHERE t.status <> 'OK'
     LIMIT 1;

    IF v_status IS NOT NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_status;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tmp_supplier_quote_result) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'NO_COMPONENTS'::TEXT;
        RETURN;
    END IF;

    IF v_rol <> 'ADMIN'
       AND EXISTS (
           SELECT 1 FROM tmp_supplier_quote_result
            WHERE COALESCE(margen_aplicado_pct, 0) < COALESCE(minimum_pct, 0)
       ) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'MARGIN_BELOW_MINIMUM'::TEXT;
        RETURN;
    END IF;

    SELECT
        pps.id_snapshot,
        pps.id_producto_proveedor,
        pps.precio_publicado,
        pps.moneda,
        pps.unidad_compra,
        pps.cantidad_pack,
        pps.url_fuente,
        pps.observado_en,
        pp.nombre_original,
        pp.sku_proveedor,
        pp.categoria,
        pp.atributos,
        pr.id_proveedor,
        pr.nombre AS proveedor_nombre
      INTO v_snapshot
      FROM precio_proveedor_snapshot pps
      JOIN producto_proveedor pp ON pp.id_producto_proveedor = pps.id_producto_proveedor
      JOIN proveedor pr ON pr.id_proveedor = pp.id_proveedor
     WHERE pps.id_snapshot = p_id_precio_proveedor_snapshot;

    SELECT (metadata->>'policy_id')::UUID
      INTO v_id_policy
      FROM tmp_supplier_quote_result
     LIMIT 1;

    SELECT SUM(precio_resultante) INTO v_total
      FROM tmp_supplier_quote_result;

    v_unidad := COALESCE(v_snapshot.unidad_compra, 'UNIT');
    v_pack_qty := CASE WHEN v_unidad = 'PACK' THEN COALESCE(v_snapshot.cantidad_pack, 0) ELSE 1 END;
    v_unit_cost := CASE WHEN v_unidad = 'PACK' THEN v_snapshot.precio_publicado / v_pack_qty ELSE v_snapshot.precio_publicado END;
    v_qty_comprada := CASE WHEN v_unidad = 'PACK' THEN CEIL(p_cantidad::NUMERIC / v_pack_qty) * v_pack_qty ELSE p_cantidad END;
    v_qty_sobrante := GREATEST(v_qty_comprada - p_cantidad, 0);

    INSERT INTO cotizacion (
        id_organizacion, estado, moneda, total, creada_por, rol_consola, notas,
        metodo_precio, id_margin_policy_version, fecha_emision, origen, canal_origen,
        idempotency_key
    )
    VALUES (
        p_id_organizacion, 'EMITIDA', 'COP', v_total, v_uid, v_rol, p_notas,
        'CALCULO_COMPONENTES', v_id_policy, now(), 'CONSOLA', 'COTIZADOR_PROVEEDOR',
        v_key
    )
    RETURNING cotizacion.id_cotizacion, cotizacion.numero INTO v_id_cotizacion, v_numero;

    INSERT INTO cotizacion_item (
        id_cotizacion, id_producto, id_variante, id_precio, producto_snapshot,
        cantidad, precio_unitario, subtotal, moneda, id_tecnica, personalizacion,
        source_mode, id_producto_proveedor, id_precio_proveedor_snapshot,
        proveedor_snapshot, nombre_item_snapshot, sku_proveedor_snapshot,
        costo_compra_unitario_snapshot, unidad_compra_snapshot, cantidad_pack_snapshot,
        cantidad_comprada, cantidad_usada, cantidad_sobrante, metadata_costeo
    )
    VALUES (
        v_id_cotizacion, NULL, NULL, NULL,
        jsonb_build_object(
            'source_mode', 'SUPPLIER_PRODUCT',
            'id_producto_proveedor', v_snapshot.id_producto_proveedor,
            'id_precio_proveedor_snapshot', v_snapshot.id_snapshot,
            'proveedor', v_snapshot.proveedor_nombre,
            'nombre_original', v_snapshot.nombre_original,
            'sku_proveedor', v_snapshot.sku_proveedor,
            'categoria', v_snapshot.categoria,
            'atributos', v_snapshot.atributos,
            'url_fuente', v_snapshot.url_fuente,
            'observado_en', v_snapshot.observado_en
        ),
        p_cantidad, round(v_total / p_cantidad, 2), v_total, 'COP', NULL,
        jsonb_build_object('marking_lines', COALESCE(p_marking_lines, '[]'::jsonb)),
        'SUPPLIER_PRODUCT', v_snapshot.id_producto_proveedor, v_snapshot.id_snapshot,
        jsonb_build_object('id_proveedor', v_snapshot.id_proveedor, 'nombre', v_snapshot.proveedor_nombre),
        v_snapshot.nombre_original, v_snapshot.sku_proveedor,
        v_unit_cost, v_unidad, v_snapshot.cantidad_pack,
        v_qty_comprada, p_cantidad, v_qty_sobrante,
        jsonb_build_object(
            'cantidad_comprada', v_qty_comprada,
            'cantidad_usada', p_cantidad,
            'cantidad_sobrante', v_qty_sobrante,
            'transport_mode', COALESCE(p_transport_mode, 'SEPARATE_LINE')
        )
    )
    RETURNING cotizacion_item.id_cotizacion_item INTO v_id_item;

    FOR v_component IN SELECT * FROM tmp_supplier_quote_result LOOP
        INSERT INTO cotizacion_componente (
            id_cotizacion_item, tipo_componente, descripcion, cantidad,
            costo_unitario, costo_total, pricing_method, margen_aplicado_pct,
            precio_resultante, source_type, source_snapshot_id, metadata
        )
        VALUES (
            v_id_item, v_component.tipo_componente, v_component.descripcion,
            v_component.cantidad, v_component.costo_unitario, v_component.costo_total,
            v_component.pricing_method, v_component.margen_aplicado_pct,
            v_component.precio_resultante, v_component.source_type,
            v_component.source_snapshot_id, v_component.metadata
        );
    END LOOP;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, estado_anterior, estado_nuevo,
        actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        v_id_cotizacion, 'CREADA', NULL, 'EMITIDA',
        'HUMANO', v_uid, v_rol,
        jsonb_build_object(
            'metodo_precio', 'CALCULO_COMPONENTES',
            'source_mode', 'SUPPLIER_PRODUCT',
            'id_precio_proveedor_snapshot', p_id_precio_proveedor_snapshot,
            'marking_lines', COALESCE(p_marking_lines, '[]'::jsonb),
            'transporte_total', COALESCE(p_transporte_total, 0),
            'transport_mode', COALESCE(p_transport_mode, 'SEPARATE_LINE'),
            'policy_code', COALESCE(p_policy_code, 'MVP_DEFAULT'),
            'margen_override_pct', p_margen_override_pct,
            'idempotency_key', v_key
        )
    );

    RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total, 'OK'::TEXT;
EXCEPTION WHEN unique_violation THEN
    IF v_key IS NULL THEN
        RAISE;
    END IF;

    SELECT c.id_cotizacion
      INTO v_existing
      FROM cotizacion c
     WHERE c.creada_por = v_uid
       AND c.idempotency_key = v_key
     LIMIT 1;

    IF v_existing IS NOT NULL
       AND fn_quote_supplier_payload_matches(
            v_existing, p_id_organizacion, p_id_precio_proveedor_snapshot,
            p_cantidad, COALESCE(p_marking_lines, '[]'::jsonb),
            p_transporte_total, p_transport_mode, p_policy_code,
            p_margen_override_pct
       ) THEN
        SELECT c.numero, c.total INTO v_numero, v_total
          FROM cotizacion c
         WHERE c.id_cotizacion = v_existing;
        RETURN QUERY SELECT v_existing, v_numero, v_total, 'OK'::TEXT;
    END IF;

    RETURN QUERY SELECT v_existing, NULL::BIGINT, NULL::NUMERIC, 'CONFLICT'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_cotizacion_proveedor(UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_cotizacion_proveedor(UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_cotizacion_proveedor(UUID, UUID, INTEGER, JSONB, NUMERIC, TEXT, TEXT, NUMERIC, TEXT, TEXT) IS
    'Crea una cotizacion proveedor-first desde producto_proveedor/precio_proveedor_snapshot, con componentes persistidos y snapshots congelados. No requiere producto propio ACTIVE.';
