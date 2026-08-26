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
    cantidad_minima_tecnica, cantidad_recomendada, configuracion_estandar, merma_pct
) VALUES (
    '00000000-0000-4000-f100-000000000004',
    '00000000-0000-4000-f100-000000000001',
    NULL,
    '00000000-0000-4000-f100-000000000002',
    1,
    12,
    '{"tecnica":"sublimacion","caras":1,"disenos":1,"transporte":false}'::JSONB,
    3
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

    ASSERT v_components = 5,
        'Debe devolver PRODUCTO, MARCACION, EMPAQUE, OTRO y TRANSPORTE';

    RAISE NOTICE 'PASSED - quote component calculation';
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
