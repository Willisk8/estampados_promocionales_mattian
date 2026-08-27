-- database/tests/test_quote_componentes_masking.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fc00-000000000001', 'admin-mask@prueba.local'),
    ('00000000-0000-4000-fc00-000000000002', 'comercial-mask@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fc00-000000000001', 'admin-mask@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fc00-000000000002', 'comercial-mask@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio)
VALUES ('00000000-0000-4000-fc00-000000000010', '900555111', 'ORG MASK TEST', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.');

INSERT INTO cotizacion (id_cotizacion, id_organizacion, estado, moneda, total, creada_por, rol_consola, metodo_precio, id_margin_policy_version, fecha_emision)
VALUES ('00000000-0000-4000-fc00-000000000020', '00000000-0000-4000-fc00-000000000010', 'EMITIDA', 'COP', 50000, '00000000-0000-4000-fc00-000000000001', 'ADMIN', 'CALCULO_COMPONENTES', '00000000-0000-4000-f000-000000000001', now());

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fc00-000000000003', 'TEST-MASK', 'Producto test mask', 'ACTIVE');

INSERT INTO cotizacion_item (id_cotizacion_item, id_cotizacion, id_producto, cantidad, precio_unitario, subtotal, producto_snapshot)
VALUES ('00000000-0000-4000-fc00-000000000030', '00000000-0000-4000-fc00-000000000020', '00000000-0000-4000-fc00-000000000003', 10, 5000, 50000, '{}'::jsonb);

INSERT INTO cotizacion_componente (id_cotizacion_item, tipo_componente, descripcion, cantidad, costo_unitario, costo_total, pricing_method, margen_aplicado_pct, precio_resultante, source_type)
VALUES ('00000000-0000-4000-fc00-000000000030', 'PRODUCTO', 'Producto base', 10, 3000, 30000, 'MARGIN', 25, 50000, 'COSTO_PRODUCTO');

-- ADMIN ve el desglose completo
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fc00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_componentes_cotizacion('00000000-0000-4000-fc00-000000000020') LIMIT 1;
    ASSERT r.costo_unitario = 3000, format('ADMIN debe ver costo_unitario real, obtuve %s', r.costo_unitario);
    ASSERT r.margen_aplicado_pct = 25, 'ADMIN debe ver margen real';
    ASSERT r.precio_resultante = 50000, 'precio_resultante siempre visible';
    RAISE NOTICE 'PASSED - ADMIN ve desglose completo';
END;
$$;

RESET ROLE;

-- COMERCIAL ve costo/margen en NULL
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fc00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_componentes_cotizacion('00000000-0000-4000-fc00-000000000020') LIMIT 1;
    ASSERT r.costo_unitario IS NULL, 'COMERCIAL no debe ver costo_unitario';
    ASSERT r.costo_total IS NULL, 'COMERCIAL no debe ver costo_total';
    ASSERT r.margen_aplicado_pct IS NULL, 'COMERCIAL no debe ver margen_aplicado_pct';
    ASSERT r.precio_resultante = 50000, 'COMERCIAL SI debe ver el precio final';
    RAISE NOTICE 'PASSED - COMERCIAL ve precio sin costo/margen';
END;
$$;

RESET ROLE;

-- Sin perfil activo: FORBIDDEN, no una excepcion
INSERT INTO auth.users (id, email) VALUES ('00000000-0000-4000-fc00-000000000099', 'sin-perfil-mask@prueba.local');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fc00-000000000099"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_componentes_cotizacion('00000000-0000-4000-fc00-000000000020') LIMIT 1;
    ASSERT r.status = 'FORBIDDEN', format('sin perfil debe devolver FORBIDDEN, obtuve %s', r.status);
    RAISE NOTICE 'PASSED - sin perfil activo devuelve FORBIDDEN sin excepcion';
END;
$$;

RESET ROLE;

ROLLBACK;
