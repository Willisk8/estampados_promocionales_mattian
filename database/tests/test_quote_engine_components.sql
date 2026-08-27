-- ============================================================
-- test_quote_engine_components.sql
-- Pruebas del motor aditivo de cotizacion por componentes.
--
-- Desde 049, fn_calculate_quote_components exige rol ADMIN: las llamadas
-- de este archivo corren con un perfil ADMIN activo, no como owner sin rol.
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-f200-000000000001', 'admin-quote-engine@prueba.local'),
    ('00000000-0000-4000-f200-000000000002', 'comercial-quote-engine@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-f200-000000000001', 'admin-quote-engine@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-f200-000000000002', 'comercial-quote-engine@prueba.local', 'COMERCIAL', true);

DO $$
BEGIN
    ASSERT fn_quote_round(7483.33, 'UP_100') = 7500,
        'UP_100 debe redondear hacia arriba a 7500';
    ASSERT fn_quote_round(7483.33, 'NEAREST_100') = 7500,
        'NEAREST_100 debe redondear al centenar mas cercano';
    ASSERT round(fn_quote_apply_margin(7000, 'MARGIN', 30), 2) = 10000.00,
        'Margen 30% debe ser costo / (1 - margen)';
    ASSERT round(fn_quote_apply_margin(7000, 'MARKUP', 30), 2) = 9100.00,
        'Markup 30% debe ser costo * 1.30';
    ASSERT fn_quote_apply_margin(7000, 'PASS_THROUGH', 99) = 7000,
        'PASS_THROUGH no debe aplicar margen';

    RAISE NOTICE 'PASSED - rounding and margin helpers';
END;
$$;

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES (
    '00000000-0000-4000-f100-000000000001',
    'TEST-QUOTE-MUG',
    'Producto test quote engine',
    'ACTIVE'
);

INSERT INTO tecnica_marcacion (
    id_tecnica, codigo, verification_status
) VALUES (
    '00000000-0000-4000-f100-000000000002',
    'fixture_sublimacion_quote',
    'TECHNICAL_REFERENCE'
);

INSERT INTO proveedor_tecnica_marcacion (
    id_proveedor_tecnica, source_id, nombre
) VALUES (
    '00000000-0000-4000-f100-000000000006',
    'fixture_quote_tech_provider',
    'Proveedor tecnica quote fixture'
);

INSERT INTO precio_tecnica_marcacion_snapshot (
    id_snapshot, id_tecnica, id_proveedor_tecnica, observation_id,
    service_component, price_scope, billing_unit, currency, price_value,
    quantity_min, quantity_max, fetched_at, verification_status
) VALUES (
    '00000000-0000-4000-f100-000000000007',
    '00000000-0000-4000-f100-000000000002',
    '00000000-0000-4000-f100-000000000006',
    'fixture-quote-sublimacion-unit-2026-08-15',
    'marcacion',
    'solo_marcacion',
    'unidad',
    'COP',
    3500,
    1,
    999,
    '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
    'VERIFIED_PUBLIC_PRICE'
);

INSERT INTO curacion_precio_tecnica_marcacion (
    id_snapshot, usage_status, formula_code, usage_notes
) VALUES (
    '00000000-0000-4000-f100-000000000007',
    'AUTOMATIC_PRICING',
    'unit_fixture',
    'Fixture automatico unitario para quote engine'
);

INSERT INTO costo_producto (
    id_costo, id_producto, id_variante, costo_base, costo_personalizacion,
    costo_empaque, otros_costos, moneda, vigencia
) VALUES (
    '00000000-0000-4000-f100-000000000003',
    '00000000-0000-4000-f100-000000000001',
    NULL,
    7000,
    1200,
    500,
    300,
    'COP',
    '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE
);

INSERT INTO producto_tecnica (
    id_producto_tecnica, id_producto, id_variante, id_tecnica,
    cantidad_minima_tecnica, cantidad_recomendada, configuracion_estandar,
    merma_pct, costo_preparacion, moneda_preparacion
) VALUES (
    '00000000-0000-4000-f100-000000000004',
    '00000000-0000-4000-f100-000000000001',
    NULL,
    '00000000-0000-4000-f100-000000000002',
    1,
    12,
    '{"tecnica":"sublimacion","caras":1,"disenos":1,"transporte":false}'::JSONB,
    3,
    200,
    'COP'
);

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES (
    '00000000-0000-4000-f100-000000000008',
    'TEST-QUOTE-ROUNDING',
    'Producto test quote rounding',
    'ACTIVE'
);

INSERT INTO costo_producto (
    id_costo, id_producto, id_variante, costo_base, costo_personalizacion,
    costo_empaque, otros_costos, moneda, vigencia
) VALUES (
    '00000000-0000-4000-f100-000000000009',
    '00000000-0000-4000-f100-000000000008',
    NULL,
    101,
    0,
    0,
    0,
    'COP',
    '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE
);

-- ----------------------------------------------------------
-- COMERCIAL no puede consultar costos/margenes (049): FORBIDDEN, no un
-- resultado con cifras.
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f200-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_status TEXT;
BEGIN
    SELECT status INTO v_status
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001', NULL, 100,
          '00000000-0000-4000-f100-000000000002', 1, 25000, 'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ, 'COP'
      )
      LIMIT 1;
    ASSERT v_status = 'FORBIDDEN', format('COMERCIAL no debe ver costos, esperaba FORBIDDEN, obtuve %s', v_status);
    RAISE NOTICE 'PASSED - COMERCIAL bloqueado de costos y margenes';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- ADMIN si puede: el resto de las aserciones originales corren con perfil
-- ADMIN activo.
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f200-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    v_producto_component RECORD;
    v_marcacion_component RECORD;
    v_preparacion_component RECORD;
    v_transporte_component RECORD;
    v_components INTEGER;
BEGIN
    SELECT *
      INTO v_producto_component
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          '00000000-0000-4000-f100-000000000002',
          1,
          25000,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE tipo_componente = 'PRODUCTO';

    ASSERT v_producto_component.status = 'OK',
        'Producto debe calcular OK';
    ASSERT v_producto_component.cantidad = 103,
        'Merma 3% sobre 100 debe producir cantidad de produccion 103';
    ASSERT v_producto_component.costo_total = 721000,
        'Costo producto con merma esperado 721000';
    ASSERT v_producto_component.precio_resultante = 1030000,
        'Margen 30% sobre 721000 esperado 1030000';

    SELECT *
      INTO v_marcacion_component
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          '00000000-0000-4000-f100-000000000002',
          1,
          25000,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE tipo_componente = 'MARCACION';

    ASSERT v_marcacion_component.costo_unitario = 3500,
        'Marcacion debe usar costo unitario curado 3500, obtuvo ' || v_marcacion_component.costo_unitario::TEXT;
    ASSERT v_marcacion_component.source_type = 'PRECIO_TECNICA_SNAPSHOT',
        'Marcacion debe trazar PRECIO_TECNICA_SNAPSHOT, obtuvo ' || COALESCE(v_marcacion_component.source_type, 'NULL');
    ASSERT v_marcacion_component.source_snapshot_id = '00000000-0000-4000-f100-000000000007',
        'Marcacion debe trazar el snapshot curado';

    SELECT *
      INTO v_preparacion_component
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          '00000000-0000-4000-f100-000000000002',
          5,
          25000,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE tipo_componente = 'PREPARACION';

    ASSERT v_preparacion_component.cantidad = 5,
        'Preparacion debe multiplicar por numero_preparaciones';
    ASSERT v_preparacion_component.costo_total = 1000,
        'Cinco preparaciones x 200 deben costar 1000';

    SELECT *
      INTO v_transporte_component
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          '00000000-0000-4000-f100-000000000002',
          1,
          25000,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE tipo_componente = 'TRANSPORTE';

    ASSERT v_transporte_component.precio_resultante = 25000,
        'Transporte debe pasar sin margen';

    SELECT COUNT(*) INTO v_components
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          '00000000-0000-4000-f100-000000000002',
          1,
          25000,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE status = 'OK';

    ASSERT v_components = 6,
        'Debe devolver PRODUCTO, MARCACION, PREPARACION, EMPAQUE, OTRO y TRANSPORTE';

    RAISE NOTICE 'PASSED - quote component calculation';
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v_preparacion_component RECORD;
BEGIN
    SELECT *
      INTO v_preparacion_component
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          '00000000-0000-4000-f100-000000000002',
          5,
          25000,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE tipo_componente = 'PREPARACION';

    INSERT INTO cotizacion (
        id_cotizacion, id_organizacion, estado, moneda, total, creada_por, rol_consola
    ) VALUES (
        '00000000-0000-4000-f100-000000000010',
        NULL,
        'EMITIDA',
        'COP',
        1,
        '00000000-0000-4000-f200-000000000001',
        'ADMIN'
    );

    INSERT INTO cotizacion_item (
        id_cotizacion_item, id_cotizacion, id_producto, id_variante, producto_snapshot,
        cantidad, precio_unitario, subtotal, moneda
    ) VALUES (
        '00000000-0000-4000-f100-000000000011',
        '00000000-0000-4000-f100-000000000010',
        '00000000-0000-4000-f100-000000000001',
        NULL,
        '{}'::JSONB,
        1,
        1,
        1,
        'COP'
    );

    INSERT INTO cotizacion_componente (
        id_cotizacion_item, tipo_componente, descripcion, cantidad,
        costo_unitario, costo_total, pricing_method, margen_aplicado_pct,
        precio_resultante, source_type, source_snapshot_id, metadata
    )
    VALUES (
        '00000000-0000-4000-f100-000000000011',
        v_preparacion_component.tipo_componente,
        v_preparacion_component.descripcion,
        v_preparacion_component.cantidad,
        v_preparacion_component.costo_unitario,
        v_preparacion_component.costo_total,
        v_preparacion_component.pricing_method,
        v_preparacion_component.margen_aplicado_pct,
        v_preparacion_component.precio_resultante,
        v_preparacion_component.source_type,
        v_preparacion_component.source_snapshot_id,
        v_preparacion_component.metadata
    );

    ASSERT FOUND, 'Debe poder persistir PREPARACION con source_type PRODUCTO_TECNICA';
    RAISE NOTICE 'PASSED - PREPARACION persistible como PRODUCTO_TECNICA';
END;
$$;

SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f200-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    v_producto_component RECORD;
    v_preparacion_component RECORD;
    v_status TEXT;
BEGIN
    SELECT *
      INTO v_producto_component
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          NULL,
          5,
          0,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE tipo_componente = 'PRODUCTO';

    ASSERT v_producto_component.cantidad = 100,
        'Sin tecnica explicita no debe heredar merma de producto_tecnica; cantidad esperada 100';
    ASSERT (v_producto_component.metadata ->> 'merma_pct')::NUMERIC = 0,
        'Sin tecnica explicita metadata.merma_pct debe ser 0';

    SELECT *
      INTO v_preparacion_component
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          NULL,
          5,
          0,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE tipo_componente = 'PREPARACION';

    ASSERT v_preparacion_component IS NULL,
        'Sin tecnica explicita no debe materializar PREPARACION de una tecnica cualquiera';

    SELECT *
      INTO v_producto_component
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000008',
          NULL,
          1,
          NULL,
          0,
          0,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      )
      WHERE tipo_componente = 'PRODUCTO';

    ASSERT v_producto_component.precio_resultante = 200,
        'UP_100 debe redondear producto 101 con margen 30% de 144.29 a 200';

    SELECT status
      INTO v_status
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          '00000000-0000-4000-f100-000000000002',
          -3,
          0,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      );

    ASSERT v_status = 'INVALID_PREPARATION_COUNT',
        'Preparaciones negativas deben devolver INVALID_PREPARATION_COUNT';

    RAISE NOTICE 'PASSED - rounding and preparation validation regressions';
END;
$$;

DO $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status
      INTO v_status
      FROM fn_calculate_quote_components(
          '00000000-0000-4000-f100-000000000001',
          NULL,
          100,
          '00000000-0000-4000-f100-000000000099',
          1,
          0,
          'MVP_DEFAULT',
          '2026-08-15 00:00:00+00'::TIMESTAMPTZ,
          'COP'
      );

    ASSERT v_status = 'PRODUCT_TECHNIQUE_NOT_CONFIGURED',
        'Tecnica no configurada debe devolver estado controlado';

    RAISE NOTICE 'PASSED - unconfigured technique fails closed';
END;
$$;

RESET ROLE;

-- vw_published_price_health se revoca de anon/authenticated desde 038:
-- solo el owner la lee, por eso el resto de este archivo corre sin rol.
INSERT INTO precio_producto (
    id_precio, id_producto, id_variante, quantity_range, validity,
    precio_unitario, moneda
) VALUES (
    '00000000-0000-4000-f100-000000000005',
    '00000000-0000-4000-f100-000000000001',
    NULL,
    '[1, 999)'::INT4RANGE,
    '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE,
    12000,
    'COP'
);

DO $$
DECLARE
    v_health RECORD;
BEGIN
    SELECT *
      INTO v_health
      FROM vw_published_price_health
      WHERE id_precio = '00000000-0000-4000-f100-000000000005';

    ASSERT v_health.health_status = 'HEALTHY',
        'La tarifa publicada del fixture debe estar saludable';
    ASSERT v_health.margen_actual_pct = 25.00,
        'Margen actual esperado: (12000 - 9000) / 12000 = 25%';

    RAISE NOTICE 'PASSED - published price health view';
END;
$$;

ROLLBACK;
