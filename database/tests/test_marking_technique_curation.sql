-- ============================================================
-- test_marking_technique_curation.sql
-- Verifica reglas de curacion de costos de tecnicas de marcacion.
-- ============================================================

BEGIN;

DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r
    FROM fn_classify_precio_tecnica_marcacion(
        'dtf_textil',
        'VERIFIED_PUBLIC_PRICE',
        'solo_servicio',
        'impresion',
        'metro lineal'
    );
    ASSERT r.usage_status = 'AUTOMATIC_PRICING',
        'dtf_textil metro should be automatic, got ' || COALESCE(r.usage_status, 'NULL');
    ASSERT r.formula_code = 'dtf_textil_meter',
        'unexpected formula for dtf_textil meter: ' || COALESCE(r.formula_code, 'NULL');

    SELECT * INTO r
    FROM fn_classify_precio_tecnica_marcacion(
        'sublimacion',
        'VERIFIED_PUBLIC_PRICE',
        'producto_personalizado',
        'producto_mas_personalizacion',
        'unidad'
    );
    ASSERT r.usage_status = 'REFERENCE_ONLY',
        'producto_personalizado should be reference only, got ' || COALESCE(r.usage_status, 'NULL');

    SELECT * INTO r
    FROM fn_classify_precio_tecnica_marcacion(
        'tampografia',
        'NEEDS_REVIEW_UNIT',
        'solo_marcacion',
        'marcacion',
        'unidad_configuracion_web'
    );
    ASSERT r.usage_status = 'NEEDS_REVIEW',
        'tampografia with unclear unit should need review, got ' || COALESCE(r.usage_status, 'NULL');

    RAISE NOTICE 'PASSED - marking technique classification rules';
END;
$$;

INSERT INTO tecnica_marcacion (
    id_tecnica, codigo, verification_status
) VALUES (
    '00000000-0000-4000-e000-000000000001',
    'fixture_dtf_uv',
    'TECHNICAL_REFERENCE'
);

INSERT INTO proveedor_tecnica_marcacion (
    id_proveedor_tecnica, source_id, nombre
) VALUES (
    '00000000-0000-4000-e000-000000000002',
    'fixture_tecnica',
    'Proveedor tecnica fixture'
);

INSERT INTO precio_tecnica_marcacion_snapshot (
    id_snapshot, id_tecnica, id_proveedor_tecnica, observation_id,
    service_component, price_scope, billing_unit, currency,
    price_value, verification_status
) VALUES (
    '00000000-0000-4000-e000-000000000003',
    '00000000-0000-4000-e000-000000000001',
    '00000000-0000-4000-e000-000000000002',
    'fixture-dtf-uv-meter',
    'impresion',
    'solo_servicio',
    'metro lineal',
    'COP',
    70000,
    'VERIFIED_PUBLIC_PRICE'
);

INSERT INTO curacion_precio_tecnica_marcacion (
    id_snapshot, usage_status, formula_code, usage_notes
)
VALUES (
    '00000000-0000-4000-e000-000000000003',
    'AUTOMATIC_PRICING',
    'dtf_uv_meter',
    'Fixture de vista curada'
);

DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM vw_precio_tecnica_marcacion_curado
    WHERE id_snapshot = '00000000-0000-4000-e000-000000000003'
      AND usage_status = 'AUTOMATIC_PRICING'
      AND formula_code = 'dtf_uv_meter';

    ASSERT v_count = 1,
        'curated view should expose automatic DTF UV fixture, got ' || v_count;
    RAISE NOTICE 'PASSED - curated marking technique view';
END;
$$;

ROLLBACK;
