-- database/tests/test_transporte_idempotency_non_passthrough.sql
--
-- Regresion para el hallazgo Important de la revision final de
-- cotizador-calculado (068): fn_quote_calculated_payload_matches comparaba
-- transporte_total/numero_preparaciones contra valores POST-margen
-- reconstruidos de cotizacion_componente, en vez del payload crudo
-- enviado. Solo parecia funcionar porque MVP_DEFAULT usa PASS_THROUGH 0%
-- para TRANSPORTE. Esta prueba usa una politica con TRANSPORTE en MARKUP
-- 20% para exponer el bug real (rompia en ambos sentidos: retry identico
-- daba CONFLICT, payload distinto daba OK con la cotizacion vieja).
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fd10-000000000001', 'admin-i2@prueba.local');
INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fd10-000000000001', 'admin-i2@prueba.local', 'ADMIN', true);

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fd10-000000000003', 'TEST-I2', 'Producto test I2', 'ACTIVE');

INSERT INTO costo_producto (id_costo, id_producto, id_variante, costo_base, costo_personalizacion, costo_empaque, otros_costos, moneda, vigencia)
VALUES ('00000000-0000-4000-fd10-000000000004', '00000000-0000-4000-fd10-000000000003', NULL, 2000, 0, 200, 0, 'COP', '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE);

-- Politica con TRANSPORTE en MARKUP 20% (no PASS_THROUGH) para reproducir el bug real.
INSERT INTO margin_policy_version (id_margin_policy_version, codigo, version_label, estado, vigencia, rounding_rule)
VALUES ('00000000-0000-4000-fd10-000000000005', 'TEST_I2_POLICY', 'v1', 'ACTIVE', '[2026-01-01 00:00:00+00,)'::TSTZRANGE, 'NONE');

INSERT INTO margin_policy_component (id_margin_policy_version, tipo_componente, pricing_method, target_pct, minimum_pct) VALUES
    ('00000000-0000-4000-fd10-000000000005', 'PRODUCTO', 'MARGIN', 30, 20),
    ('00000000-0000-4000-fd10-000000000005', 'EMPAQUE', 'MARGIN', 30, 20),
    ('00000000-0000-4000-fd10-000000000005', 'TRANSPORTE', 'MARKUP', 20, 0);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd10-000000000001"}', true);
SET LOCAL ROLE authenticated;

-- Retry identico (misma key, mismo transporte_total=10000) debe dar OK, no CONFLICT.
DO $$
DECLARE r1 RECORD; r2 RECORD;
BEGIN
    SELECT * INTO r1 FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd10-000000000003',
        p_cantidad => 10,
        p_transporte_total => 10000,
        p_policy_code => 'TEST_I2_POLICY',
        p_idempotency_key => 'i2-retry-key'
    );
    ASSERT r1.status = 'OK', format('primera llamada debe ser OK, obtuve %s', r1.status);

    SELECT * INTO r2 FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd10-000000000003',
        p_cantidad => 10,
        p_transporte_total => 10000,
        p_policy_code => 'TEST_I2_POLICY',
        p_idempotency_key => 'i2-retry-key'
    );
    ASSERT r2.status = 'OK', format('retry identico debe ser OK (idempotente), obtuve %s - este es exactamente el bug reportado', r2.status);
    ASSERT r2.id_cotizacion = r1.id_cotizacion, 'retry identico debe devolver la MISMA cotizacion';
    RAISE NOTICE 'PASSED - retry identico con TRANSPORTE markup 20%% es idempotente (OK, no CONFLICT)';
END;
$$;

-- Payload realmente distinto (transporte_total cambia) bajo la MISMA key debe dar CONFLICT.
DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd10-000000000003',
        p_cantidad => 10,
        p_transporte_total => 99999,
        p_policy_code => 'TEST_I2_POLICY',
        p_idempotency_key => 'i2-retry-key'
    );
    ASSERT r.status = 'CONFLICT', format('transporte_total distinto bajo la misma key debe dar CONFLICT, obtuve %s - este es el otro lado del bug reportado', r.status);
    RAISE NOTICE 'PASSED - payload con transporte_total distinto bajo la misma key da CONFLICT (no OK con la cotizacion vieja)';
END;
$$;

RESET ROLE;
ROLLBACK;
