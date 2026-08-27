-- database/tests/test_tecnicas_disponibles.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES ('00000000-0000-4000-fe00-000000000001', 'admin-tecdisp@prueba.local');
INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES ('00000000-0000-4000-fe00-000000000001', 'admin-tecdisp@prueba.local', 'ADMIN', true);

INSERT INTO producto (id_producto, sku, nombre, estado) VALUES ('00000000-0000-4000-fe00-000000000003', 'TEST-TECDISP', 'Producto test tecnicas', 'ACTIVE');

INSERT INTO tecnica_marcacion (id_tecnica, codigo) VALUES
    ('00000000-0000-4000-fe00-000000000010', 'con_snapshot'),
    ('00000000-0000-4000-fe00-000000000011', 'sin_snapshot');

INSERT INTO producto_tecnica (id_producto_tecnica, id_producto, id_variante, id_tecnica, cantidad_minima_tecnica, cantidad_recomendada, configuracion_estandar, merma_pct, permitida) VALUES
    ('00000000-0000-4000-fe00-000000000020', '00000000-0000-4000-fe00-000000000003', NULL, '00000000-0000-4000-fe00-000000000010', 1, 1, '{}'::jsonb, 0, true),
    ('00000000-0000-4000-fe00-000000000021', '00000000-0000-4000-fe00-000000000003', NULL, '00000000-0000-4000-fe00-000000000011', 1, 1, '{}'::jsonb, 0, true);

INSERT INTO proveedor_tecnica_marcacion (id_proveedor_tecnica, source_id, nombre)
VALUES ('00000000-0000-4000-fe00-000000000030', 'fixture_tecdisp_provider', 'Proveedor test tecdisp');

INSERT INTO precio_tecnica_marcacion_snapshot (id_snapshot, id_tecnica, id_proveedor_tecnica, observation_id, service_component, price_scope, billing_unit, currency, price_value, fetched_at, verification_status)
VALUES ('00000000-0000-4000-fe00-000000000040', '00000000-0000-4000-fe00-000000000010', '00000000-0000-4000-fe00-000000000030', 'fixture-tecdisp-2026', 'marcacion', 'solo_marcacion', 'unidad', 'COP', 1000, now(), 'VERIFIED_PUBLIC_PRICE');

INSERT INTO curacion_precio_tecnica_marcacion (id_snapshot, usage_status, formula_code, usage_notes)
VALUES ('00000000-0000-4000-fe00-000000000040', 'AUTOMATIC_PRICING', 'unit_fixture', 'fixture curacion');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM fn_consola_tecnicas_disponibles_producto('00000000-0000-4000-fe00-000000000003')
     WHERE id_tecnica = '00000000-0000-4000-fe00-000000000010';
    ASSERT v_count = 1, 'la tecnica con snapshot curado debe aparecer';

    SELECT COUNT(*) INTO v_count FROM fn_consola_tecnicas_disponibles_producto('00000000-0000-4000-fe00-000000000003')
     WHERE id_tecnica = '00000000-0000-4000-fe00-000000000011';
    ASSERT v_count = 0, 'la tecnica sin snapshot curado NO debe aparecer';

    RAISE NOTICE 'PASSED - solo se ofrecen tecnicas con snapshot curado vigente';
END;
$$;

RESET ROLE;
ROLLBACK;
