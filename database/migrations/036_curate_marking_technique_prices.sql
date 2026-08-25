-- ============================================================
-- 036_curate_marking_technique_prices.sql
--
-- Curacion operativa de snapshots de costos de tecnicas de marcacion.
-- No modifica precio_tecnica_marcacion_snapshot porque esa tabla es
-- append-only. La decision de uso vive en una tabla separada.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_classify_precio_tecnica_marcacion(
    p_codigo TEXT,
    p_verification_status TEXT,
    p_price_scope TEXT,
    p_service_component TEXT,
    p_billing_unit TEXT
)
RETURNS TABLE (
    usage_status TEXT,
    formula_code TEXT,
    usage_notes TEXT
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_codigo TEXT := lower(coalesce(p_codigo, ''));
    v_verification TEXT := upper(coalesce(p_verification_status, ''));
    v_scope TEXT := lower(coalesce(p_price_scope, ''));
    v_component TEXT := lower(coalesce(p_service_component, ''));
    v_unit TEXT := lower(coalesce(p_billing_unit, ''));
BEGIN
    IF v_verification <> 'VERIFIED_PUBLIC_PRICE' THEN
        IF v_verification = 'NEEDS_REVIEW_UNIT' THEN
            RETURN QUERY SELECT
                'NEEDS_REVIEW',
                'unit_requires_manual_validation',
                'La fuente publica valor sin unidad/alcance claro; no usar en calculo automatico.';
            RETURN;
        END IF;

        RETURN QUERY SELECT
            'NEEDS_REVIEW',
            'verification_required',
            'Snapshot sin verificacion publica suficiente para costeo automatico.';
        RETURN;
    END IF;

    IF v_scope = 'producto_personalizado' THEN
        RETURN QUERY SELECT
            'REFERENCE_ONLY',
            'market_benchmark',
            'Incluye producto personalizado completo; sirve como benchmark de mercado, no como costo interno.';
        RETURN;
    END IF;

    IF v_codigo = 'dtf_textil'
       AND v_scope IN ('solo_marcacion', 'solo_servicio')
       AND v_unit IN ('unidad', 'metro lineal') THEN
        RETURN QUERY SELECT
            'AUTOMATIC_PRICING',
            CASE WHEN v_unit = 'metro lineal' THEN 'dtf_textil_meter' ELSE 'dtf_textil_size_qty' END,
            'Apto para calculo automatico por area/formato/cantidad, sujeto a revision comercial de proveedor vigente.';
        RETURN;
    END IF;

    IF v_codigo = 'dtf_uv'
       AND v_scope IN ('solo_marcacion', 'solo_servicio')
       AND v_unit IN ('unidad', 'metro lineal') THEN
        RETURN QUERY SELECT
            'AUTOMATIC_PRICING',
            CASE WHEN v_unit = 'metro lineal' THEN 'dtf_uv_meter' ELSE 'dtf_uv_unit_area' END,
            'Apto para calculo automatico con cautela; validar area, aplicacion e IVA antes de cliente.';
        RETURN;
    END IF;

    IF v_codigo = 'sublimacion'
       AND v_scope = 'solo_marcacion'
       AND v_unit IN ('impresion a4', 'hoja', 'unidad') THEN
        RETURN QUERY SELECT
            'AUTOMATIC_PRICING',
            'sublimacion_sheet',
            'Apto para calculo automatico por hoja/formato; separar benchmarks de producto personalizado.';
        RETURN;
    END IF;

    IF v_codigo IN ('tampografia', 'serigrafia') THEN
        RETURN QUERY SELECT
            'NEEDS_REVIEW',
            'setup_unit_missing',
            'Falta separar setup, unidad, tintas/posiciones y minimo de pedido.';
        RETURN;
    END IF;

    IF v_codigo IN ('bordado', 'grabado_laser') THEN
        RETURN QUERY SELECT
            'REFERENCE_ONLY',
            'partial_cost_reference',
            'Referencia parcial; falta regla completa por puntadas, area, material, tiempo o setup.';
        RETURN;
    END IF;

    IF v_codigo IN ('vinilo_alta_densidad', 'vinilo_textil', 'escudo_tpu', 'acabado_agenda_multitecnica') THEN
        RETURN QUERY SELECT
            'REFERENCE_ONLY',
            'non_mvp_reference',
            'Referencia verificable o benchmark fuera del flujo automatico MVP actual.';
        RETURN;
    END IF;

    RETURN QUERY SELECT
        'NEEDS_REVIEW',
        'manual_classification_required',
        'Tecnica o formato no clasificado para calculo automatico.';
END;
$$;

CREATE TABLE IF NOT EXISTS curacion_precio_tecnica_marcacion (
    id_snapshot         UUID        PRIMARY KEY REFERENCES precio_tecnica_marcacion_snapshot(id_snapshot),
    usage_status        TEXT        NOT NULL CHECK (usage_status IN (
                            'AUTOMATIC_PRICING',
                            'REFERENCE_ONLY',
                            'NEEDS_REVIEW',
                            'DO_NOT_USE'
                        )),
    formula_code        TEXT        NOT NULL,
    usage_notes         TEXT        NOT NULL,
    curated_by          TEXT        NOT NULL DEFAULT 'system_rule_036',
    curated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE curacion_precio_tecnica_marcacion ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS deny_all ON curacion_precio_tecnica_marcacion;
CREATE POLICY deny_all ON curacion_precio_tecnica_marcacion
    AS RESTRICTIVE FOR ALL USING (false);

INSERT INTO curacion_precio_tecnica_marcacion (
    id_snapshot, usage_status, formula_code, usage_notes
)
SELECT
    pts.id_snapshot,
    c.usage_status,
    c.formula_code,
    c.usage_notes
FROM precio_tecnica_marcacion_snapshot pts
JOIN tecnica_marcacion tm ON tm.id_tecnica = pts.id_tecnica
CROSS JOIN LATERAL fn_classify_precio_tecnica_marcacion(
    tm.codigo,
    pts.verification_status,
    pts.price_scope,
    pts.service_component,
    pts.billing_unit
) c
ON CONFLICT (id_snapshot) DO UPDATE
SET usage_status = EXCLUDED.usage_status,
    formula_code = EXCLUDED.formula_code,
    usage_notes = EXCLUDED.usage_notes,
    curated_by = 'system_rule_036',
    curated_at = now();

CREATE OR REPLACE VIEW vw_precio_tecnica_marcacion_curado
WITH (security_invoker = on) AS
SELECT
    pts.id_snapshot,
    tm.codigo AS tecnica_codigo,
    ptm.nombre AS proveedor_nombre,
    pts.service_component,
    pts.price_scope,
    pts.size_label,
    pts.width_cm,
    pts.height_cm,
    pts.quantity_min,
    pts.quantity_max,
    pts.billing_unit,
    pts.currency,
    pts.price_value,
    pts.price_min,
    pts.price_max,
    pts.tax_status,
    pts.verification_status,
    c.usage_status,
    c.formula_code,
    c.usage_notes,
    pts.source_url,
    pts.fetched_at
FROM precio_tecnica_marcacion_snapshot pts
JOIN tecnica_marcacion tm ON tm.id_tecnica = pts.id_tecnica
JOIN proveedor_tecnica_marcacion ptm ON ptm.id_proveedor_tecnica = pts.id_proveedor_tecnica
JOIN curacion_precio_tecnica_marcacion c ON c.id_snapshot = pts.id_snapshot;

COMMENT ON TABLE curacion_precio_tecnica_marcacion IS
    'Curacion operativa de snapshots de precios de tecnicas: separa costos automaticos, referencias y pendientes sin modificar la tabla append-only.';

COMMENT ON VIEW vw_precio_tecnica_marcacion_curado IS
    'Vista de costos de tecnicas con clasificacion de uso para calculadora y revision comercial.';

COMMENT ON FUNCTION fn_classify_precio_tecnica_marcacion(TEXT, TEXT, TEXT, TEXT, TEXT) IS
    'Clasifica un snapshot de tecnica de marcacion segun tecnica, scope, unidad y estado de verificacion.';
