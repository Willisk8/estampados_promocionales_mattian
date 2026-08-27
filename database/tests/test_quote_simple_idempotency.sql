-- ============================================================
-- test_quote_simple_idempotency.sql
-- Verifica que fn_consola_crear_cotizacion_simple sea idempotente cuando
-- recibe la misma clave del mismo usuario (055), que un payload distinto
-- bajo la misma clave marque conflicto (059), que dos usuarios con la
-- misma clave no se pisen, y que una clave en blanco no active idempotencia.
-- Cablea QA-QUOTE-006 (docs/qa_findings.md): estos casos ya se habian
-- probado a mano una vez y no quedaban en la suite.
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fb00-000000000001', 'comercial-idempotencia@prueba.local'),
    ('00000000-0000-4000-fb00-000000000002', 'comercial-idempotencia-2@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fb00-000000000001', 'comercial-idempotencia@prueba.local', 'COMERCIAL', true),
    ('00000000-0000-4000-fb00-000000000002', 'comercial-idempotencia-2@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-fb00-000000000010',
    '900333777',
    'ORGANIZACION IDEMPOTENCIA',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES (
    '00000000-0000-4000-fb00-000000000003',
    'TEST-IDEMPOTENCIA',
    'Producto test idempotencia',
    'ACTIVE'
);

INSERT INTO precio_producto (id_precio, id_producto, quantity_range, validity, precio_unitario, moneda)
VALUES (
    '00000000-0000-4000-fb00-000000000004',
    '00000000-0000-4000-fb00-000000000003',
    '[1,)'::INT4RANGE,
    '[2026-01-01 00:00:00+00,)'::TSTZRANGE,
    11000,
    'COP'
);

SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-fb00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    r1 RECORD;
    r2 RECORD;
    v_count_cotizaciones INTEGER;
    v_count_items INTEGER;
    v_count_eventos INTEGER;
BEGIN
    SELECT * INTO r1
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion => '00000000-0000-4000-fb00-000000000010',
        p_id_producto => '00000000-0000-4000-fb00-000000000003',
        p_id_variante => NULL,
        p_cantidad => 7,
        p_idempotency_key => 'fixture-key-quote-idempotente'
      );

    SELECT * INTO r2
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion => '00000000-0000-4000-fb00-000000000010',
        p_id_producto => '00000000-0000-4000-fb00-000000000003',
        p_id_variante => NULL,
        p_cantidad => 7,
        p_idempotency_key => 'fixture-key-quote-idempotente'
      );

    ASSERT r1.status = 'OK' AND r2.status = 'OK',
        'Ambas llamadas deben devolver OK';
    ASSERT r1.id_cotizacion = r2.id_cotizacion,
        'Retry con misma idempotency key debe devolver la misma cotizacion';
    ASSERT r1.numero = r2.numero,
        'Retry con misma idempotency key debe devolver el mismo numero';

    SELECT COUNT(*) INTO v_count_cotizaciones
      FROM cotizacion
     WHERE creada_por = '00000000-0000-4000-fb00-000000000001'
       AND idempotency_key = 'fixture-key-quote-idempotente';

    SELECT COUNT(*) INTO v_count_items
      FROM cotizacion_item
     WHERE id_cotizacion = r1.id_cotizacion;

    SELECT COUNT(*) INTO v_count_eventos
      FROM cotizacion_evento
     WHERE id_cotizacion = r1.id_cotizacion
       AND tipo_evento = 'CREADA';

    ASSERT v_count_cotizaciones = 1,
        'Debe existir una sola cotizacion para la misma clave';
    ASSERT v_count_items = 1,
        'Debe existir un solo item; el retry no duplica detalle';
    ASSERT v_count_eventos = 1,
        'Debe existir un solo evento CREADA; el retry no duplica eventos';

    RAISE NOTICE 'PASSED - cotizacion simple idempotente';
END;
$$;

-- ----------------------------------------------------------
-- Payload distinto bajo la misma clave: debe marcar CONFLICT, no
-- devolver la cotizacion vieja en silencio (059 / QA-QUOTE-005).
-- ----------------------------------------------------------
DO $$
DECLARE
    r1 RECORD;
    r2 RECORD;
    v_count_cotizaciones INTEGER;
BEGIN
    SELECT * INTO r1
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion => '00000000-0000-4000-fb00-000000000010',
        p_id_producto => '00000000-0000-4000-fb00-000000000003',
        p_id_variante => NULL,
        p_cantidad => 5,
        p_idempotency_key => 'fixture-key-quote-conflicto'
      );
    ASSERT r1.status = 'OK', 'la primera llamada debe crear la cotizacion';

    SELECT * INTO r2
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion => '00000000-0000-4000-fb00-000000000010',
        p_id_producto => '00000000-0000-4000-fb00-000000000003',
        p_id_variante => NULL,
        p_cantidad => 999,
        p_idempotency_key => 'fixture-key-quote-conflicto'
      );

    ASSERT r2.status = 'CONFLICT',
        format('cantidad distinta bajo la misma clave debe devolver CONFLICT, obtuve %s', r2.status);
    ASSERT r2.id_cotizacion = r1.id_cotizacion,
        'CONFLICT debe referenciar la cotizacion original, no una nueva';
    ASSERT r2.total = r1.total,
        'CONFLICT no debe exponer un total recalculado con la cantidad nueva';

    SELECT COUNT(*) INTO v_count_cotizaciones
      FROM cotizacion
     WHERE creada_por = '00000000-0000-4000-fb00-000000000001'
       AND idempotency_key = 'fixture-key-quote-conflicto';
    ASSERT v_count_cotizaciones = 1,
        'un CONFLICT no debe crear una segunda cotizacion';

    RAISE NOTICE 'PASSED - payload distinto bajo la misma clave marca CONFLICT';
END;
$$;

-- ----------------------------------------------------------
-- Aislamiento por usuario: la misma clave para dos usuarios distintos
-- no debe pisarse (el indice unico es sobre creada_por + idempotency_key).
-- ----------------------------------------------------------
DO $$
DECLARE
    r1 RECORD;
    r2 RECORD;
BEGIN
    SELECT * INTO r1
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion => '00000000-0000-4000-fb00-000000000010',
        p_id_producto => '00000000-0000-4000-fb00-000000000003',
        p_id_variante => NULL,
        p_cantidad => 3,
        p_idempotency_key => 'fixture-key-quote-compartida'
      );
    ASSERT r1.status = 'OK', 'usuario 1 debe crear su cotizacion';

    RESET ROLE;
    PERFORM set_config('request.jwt.claims',
                      '{"sub":"00000000-0000-4000-fb00-000000000002"}', true);
    SET LOCAL ROLE authenticated;

    SELECT * INTO r2
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion => '00000000-0000-4000-fb00-000000000010',
        p_id_producto => '00000000-0000-4000-fb00-000000000003',
        p_id_variante => NULL,
        p_cantidad => 3,
        p_idempotency_key => 'fixture-key-quote-compartida'
      );
    ASSERT r2.status = 'OK', 'usuario 2 debe crear su propia cotizacion con la misma clave';
    ASSERT r2.id_cotizacion <> r1.id_cotizacion,
        'la clave es por usuario: dos usuarios con la misma clave deben tener cotizaciones distintas';

    RESET ROLE;
    PERFORM set_config('request.jwt.claims',
                      '{"sub":"00000000-0000-4000-fb00-000000000001"}', true);
    SET LOCAL ROLE authenticated;

    RAISE NOTICE 'PASSED - la idempotencia es por usuario, no global';
END;
$$;

-- ----------------------------------------------------------
-- Clave en blanco: no debe activar idempotencia (btrim + NULLIF la
-- normaliza a NULL), cada llamada crea una cotizacion nueva.
-- ----------------------------------------------------------
DO $$
DECLARE
    r1 RECORD;
    r2 RECORD;
BEGIN
    SELECT * INTO r1
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion => '00000000-0000-4000-fb00-000000000010',
        p_id_producto => '00000000-0000-4000-fb00-000000000003',
        p_id_variante => NULL,
        p_cantidad => 2,
        p_idempotency_key => '   '
      );

    SELECT * INTO r2
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion => '00000000-0000-4000-fb00-000000000010',
        p_id_producto => '00000000-0000-4000-fb00-000000000003',
        p_id_variante => NULL,
        p_cantidad => 2,
        p_idempotency_key => '   '
      );

    ASSERT r1.status = 'OK' AND r2.status = 'OK', 'ambas deben crear su cotizacion';
    ASSERT r1.id_cotizacion <> r2.id_cotizacion,
        'una clave en blanco no debe activar idempotencia entre llamadas distintas';

    RAISE NOTICE 'PASSED - clave en blanco no activa idempotencia';
END;
$$;

RESET ROLE;

ROLLBACK;
