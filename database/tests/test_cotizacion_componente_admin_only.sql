-- database/tests/test_cotizacion_componente_admin_only.sql
--
-- Regresion para el hallazgo Critical de la revision final de
-- cotizador-calculado (067): antes de este fix, cotizacion_componente
-- filtraba costo/margen real a COMERCIAL/LECTURA via lectura directa de
-- tabla (RLS gateada solo en fn_consola_puede_leer(), true para cualquier
-- rol activo), aunque las RPCs enmascaradas (061, 065) ya ocultaban esos
-- mismos datos correctamente.
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fc00-000000000001', 'admin-c1@prueba.local'),
    ('00000000-0000-4000-fc00-000000000002', 'comercial-c1@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fc00-000000000001', 'admin-c1@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fc00-000000000002', 'comercial-c1@prueba.local', 'COMERCIAL', true);

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fc00-000000000003', 'TEST-C1', 'Producto test C1', 'ACTIVE');

INSERT INTO costo_producto (id_costo, id_producto, id_variante, costo_base, costo_personalizacion, costo_empaque, otros_costos, moneda, vigencia)
VALUES ('00000000-0000-4000-fc00-000000000004', '00000000-0000-4000-fc00-000000000003', NULL, 2000, 0, 200, 0, 'COP', '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fc00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD; v_count INTEGER;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fc00-000000000003',
        p_cantidad => 10
    );
    ASSERT r.status = 'OK', format('COMERCIAL debe poder crear, obtuve %s', r.status);

    SELECT COUNT(*) INTO v_count
      FROM cotizacion_componente cc
      JOIN cotizacion_item ci ON ci.id_cotizacion_item = cc.id_cotizacion_item
     WHERE ci.id_cotizacion = r.id_cotizacion;
    ASSERT v_count = 0, format('COMERCIAL no debe poder leer cotizacion_componente directo, obtuve %s filas', v_count);
    RAISE NOTICE 'PASSED - COMERCIAL bloqueado de lectura directa de cotizacion_componente';
END;
$$;

RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fc00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM cotizacion_componente;
    ASSERT v_count > 0, 'ADMIN debe poder leer cotizacion_componente directo';
    RAISE NOTICE 'PASSED - ADMIN sigue pudiendo leer cotizacion_componente directo (% filas)', v_count;
END;
$$;

RESET ROLE;
ROLLBACK;
