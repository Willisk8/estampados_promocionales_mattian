-- database/tests/test_quote_calculada.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fd00-000000000001', 'admin-calc@prueba.local'),
    ('00000000-0000-4000-fd00-000000000002', 'comercial-calc@prueba.local'),
    ('00000000-0000-4000-fd00-000000000003', 'lectura-calc@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fd00-000000000001', 'admin-calc@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fd00-000000000002', 'comercial-calc@prueba.local', 'COMERCIAL', true),
    ('00000000-0000-4000-fd00-000000000003', 'lectura-calc@prueba.local', 'LECTURA', true);

INSERT INTO organizacion (id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio)
VALUES ('00000000-0000-4000-fd00-000000000010', '900666222', 'ORG CALC TEST', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.');

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fd00-000000000003', 'TEST-CALC', 'Producto test calculado', 'ACTIVE');

INSERT INTO costo_producto (id_costo, id_producto, id_variante, costo_base, costo_personalizacion, costo_empaque, otros_costos, moneda, vigencia)
VALUES ('00000000-0000-4000-fd00-000000000004', '00000000-0000-4000-fd00-000000000003', NULL, 2000, 0, 200, 0, 'COP', '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

-- ADMIN crea, ve costo/margen real
DO $$
DECLARE r RECORD; det RECORD; v_count_componentes INTEGER;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 10
    );
    ASSERT r.status = 'OK', format('ADMIN debe crear OK, obtuve %s', r.status);
    PERFORM set_config('app.id_cot_admin', r.id_cotizacion::text, false);

    SELECT COUNT(*) INTO v_count_componentes FROM cotizacion_componente cc
      JOIN cotizacion_item ci ON ci.id_cotizacion_item = cc.id_cotizacion_item
     WHERE ci.id_cotizacion = r.id_cotizacion;
    ASSERT v_count_componentes >= 2, format('debe persistir PRODUCTO y EMPAQUE al menos, obtuve %s filas', v_count_componentes);

    SELECT * INTO det FROM fn_consola_componentes_cotizacion(r.id_cotizacion) WHERE tipo_componente = 'PRODUCTO';
    ASSERT det.costo_unitario = 2000, 'ADMIN debe ver costo_unitario real en la cotizacion recien creada';

    RAISE NOTICE 'PASSED - ADMIN crea cotizacion calculada con componentes persistidos';
END;
$$;

RESET ROLE;

-- COMERCIAL crea, no ve costo/margen
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD; det RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 5
    );
    ASSERT r.status = 'OK', format('COMERCIAL debe poder crear, obtuve %s', r.status);

    SELECT * INTO det FROM fn_consola_componentes_cotizacion(r.id_cotizacion) WHERE tipo_componente = 'PRODUCTO';
    ASSERT det.costo_unitario IS NULL, 'COMERCIAL no debe ver costo_unitario ni siquiera de su propia cotizacion';
    ASSERT det.precio_resultante IS NOT NULL, 'COMERCIAL si ve el precio final';

    RAISE NOTICE 'PASSED - COMERCIAL crea cotizacion, ve precio sin costo/margen';
END;
$$;

RESET ROLE;

-- LECTURA no puede crear
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueado BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_crear_cotizacion_calculada(
            p_id_producto => '00000000-0000-4000-fd00-000000000003',
            p_cantidad => 1
        );
    EXCEPTION WHEN OTHERS THEN
        v_bloqueado := true;
    END;
    ASSERT v_bloqueado, 'LECTURA no debe poder crear cotizaciones calculadas';
    RAISE NOTICE 'PASSED - LECTURA bloqueada';
END;
$$;

RESET ROLE;

-- Tecnica sin snapshot curado: no crea nada.
-- Fixtures (tecnica_marcacion, producto_tecnica) se insertan como
-- superusuario, ANTES de cambiar de rol: ambas tablas tienen RLS deny_all
-- y REVOKE ALL FROM anon, authenticated (038); intentar insertarlas ya
-- bajo SET LOCAL ROLE authenticated falla con permission denied, igual
-- que le pasaria a margin_policy_version/margin_policy_component mas
-- abajo si se insertaran despues del cambio de rol.
INSERT INTO tecnica_marcacion (id_tecnica, codigo) VALUES ('00000000-0000-4000-fd00-000000000005', 'sin_snapshot_test');
INSERT INTO producto_tecnica (id_producto_tecnica, id_producto, id_variante, id_tecnica, cantidad_minima_tecnica, cantidad_recomendada, configuracion_estandar, merma_pct, permitida)
VALUES ('00000000-0000-4000-fd00-000000000006', '00000000-0000-4000-fd00-000000000003', NULL, '00000000-0000-4000-fd00-000000000005', 1, 1, '{}'::jsonb, 0, true);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD; v_count_antes INTEGER; v_count_despues INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count_antes FROM cotizacion;

    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 10,
        p_id_tecnica => '00000000-0000-4000-fd00-000000000005'
    );
    ASSERT r.status = 'MARKING_COST_NOT_FOUND', format('esperaba MARKING_COST_NOT_FOUND, obtuve %s', r.status);

    SELECT COUNT(*) INTO v_count_despues FROM cotizacion;
    ASSERT v_count_despues = v_count_antes, 'un status distinto de OK no debe crear cotizacion';

    RAISE NOTICE 'PASSED - tecnica sin snapshot no crea nada';
END;
$$;

RESET ROLE;

-- Producto con todos los costos en su default de 0 (permitido por el
-- esquema de costo_producto, 006), sin tecnica ni transporte: el nucleo
-- de calculo no genera ninguna fila de componente pese a que politica y
-- costo vigente si se resolvieron. Cubre la guarda NO_COMPONENTS agregada
-- en 062 mas alla del brief original (self-review): sin este test, un
-- cambio futuro que renombrara la clave 'policy_id' dentro de metadata
-- podria romper esa guarda en silencio.
INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fd00-000000000008', 'TEST-CALC-ZERO', 'Producto costo cero', 'ACTIVE');

INSERT INTO costo_producto (id_costo, id_producto, id_variante, costo_base, costo_personalizacion, costo_empaque, otros_costos, moneda, vigencia)
VALUES ('00000000-0000-4000-fd00-000000000009', '00000000-0000-4000-fd00-000000000008', NULL, 0, 0, 0, 0, 'COP', '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD; v_count_antes INTEGER; v_count_despues INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count_antes FROM cotizacion;

    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000008',
        p_cantidad => 10
    );
    ASSERT r.status = 'NO_COMPONENTS', format('esperaba NO_COMPONENTS, obtuve %s', r.status);

    SELECT COUNT(*) INTO v_count_despues FROM cotizacion;
    ASSERT v_count_despues = v_count_antes, 'NO_COMPONENTS no debe crear cotizacion';

    RAISE NOTICE 'PASSED - producto con costos en cero devuelve NO_COMPONENTS sin crear nada';
END;
$$;

RESET ROLE;

-- Override de margen debajo del minimo: COMERCIAL bloqueado, ADMIN permitido.
-- Mismo motivo que arriba: estas dos tablas tambien son RLS deny_all +
-- REVOKE ALL FROM authenticated, asi que se insertan en rol superusuario.
INSERT INTO margin_policy_version (id_margin_policy_version, codigo, version_label, estado, vigencia, rounding_rule)
VALUES ('00000000-0000-4000-fd00-000000000007', 'TEST_CALC_POLICY', 'v1-test', 'ACTIVE', '[2026-01-01 00:00:00+00,)'::tstzrange, 'NEAREST_100');
INSERT INTO margin_policy_component (id_margin_policy_version, tipo_componente, pricing_method, target_pct, minimum_pct)
VALUES ('00000000-0000-4000-fd00-000000000007', 'PRODUCTO', 'MARGIN', 30, 15);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 10,
        p_policy_code => 'TEST_CALC_POLICY',
        p_margen_override_pct => 5
    );
    ASSERT r.status = 'OK', format('ADMIN debe poder bajar del minimo, obtuve %s', r.status);
    RAISE NOTICE 'PASSED - ADMIN puede cotizar bajo el margen minimo';
END;
$$;

RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 10,
        p_policy_code => 'TEST_CALC_POLICY',
        p_margen_override_pct => 5
    );
    ASSERT r.status = 'MARGIN_BELOW_MINIMUM', format('COMERCIAL debe bloquearse bajo el minimo, obtuve %s', r.status);
    RAISE NOTICE 'PASSED - COMERCIAL bloqueado bajo el margen minimo';
END;
$$;

RESET ROLE;

-- Idempotencia: mismo payload misma cotizacion, payload distinto CONFLICT
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r1 RECORD; r2 RECORD; r3 RECORD;
BEGIN
    SELECT * INTO r1 FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003', p_cantidad => 20,
        p_idempotency_key => 'fixture-key-calc-idem'
    );
    SELECT * INTO r2 FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003', p_cantidad => 20,
        p_idempotency_key => 'fixture-key-calc-idem'
    );
    ASSERT r1.id_cotizacion = r2.id_cotizacion, 'mismo payload + misma clave debe devolver la misma cotizacion';

    SELECT * INTO r3 FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003', p_cantidad => 999,
        p_idempotency_key => 'fixture-key-calc-idem'
    );
    ASSERT r3.status = 'CONFLICT', format('payload distinto misma clave debe dar CONFLICT, obtuve %s', r3.status);
    RAISE NOTICE 'PASSED - idempotencia igual que 059';
END;
$$;

RESET ROLE;

ROLLBACK;
