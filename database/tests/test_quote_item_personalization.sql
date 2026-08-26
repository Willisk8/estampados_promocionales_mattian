-- ============================================================
-- test_quote_item_personalization.sql
-- Verifica que tecnica y personalizacion sobrevivan de cotizacion a
-- pedido (050).
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fa00-000000000001', 'comercial-personalizacion@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fa00-000000000001', 'comercial-personalizacion@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-fa00-000000000010',
    '900222888',
    'ORGANIZACION PERSONALIZACION',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

INSERT INTO tecnica_marcacion (id_tecnica, codigo, verification_status)
VALUES ('00000000-0000-4000-fa00-000000000002', 'fixture_personalizacion', 'TECHNICAL_REFERENCE');

-- Producto y precio propios del fixture: fn_consola_crear_cotizacion_simple
-- llama a resolve_price() por dentro, que exige una tarifa publicada
-- vigente. No se depende del catalogo real de STAGING.
INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fa00-000000000003', 'TEST-PERSONALIZACION', 'Producto test personalizacion', 'ACTIVE');

INSERT INTO precio_producto (id_precio, id_producto, quantity_range, validity, precio_unitario, moneda)
VALUES (
    '00000000-0000-4000-fa00-000000000004',
    '00000000-0000-4000-fa00-000000000003',
    '[1,)'::INT4RANGE,
    '[2026-01-01 00:00:00+00,)'::TSTZRANGE,
    9000,
    'COP'
);

SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-fa00-000000000001"}', true);
SET LOCAL ROLE authenticated;

-- ----------------------------------------------------------
-- Cotizacion CON tecnica y personalizacion
-- ----------------------------------------------------------
DO $$
DECLARE v_id_cotizacion UUID; v_status TEXT; v_id_producto UUID;
BEGIN
    v_id_producto := '00000000-0000-4000-fa00-000000000003';

    SELECT id_cotizacion, status INTO v_id_cotizacion, v_status
      FROM fn_consola_crear_cotizacion_simple(
        p_id_organizacion  => '00000000-0000-4000-fa00-000000000010',
        p_id_producto      => v_id_producto,
        p_id_variante      => NULL,
        p_cantidad         => 10,
        p_id_tecnica       => '00000000-0000-4000-fa00-000000000002',
        p_personalizacion  => jsonb_build_object('color', 'azul', 'texto', 'Bienvenido')
      );
    ASSERT v_status = 'OK', format('esperaba OK, obtuve %s', v_status);

    PERFORM set_config('app.id_cotizacion_personalizada', v_id_cotizacion::text, false);

    PERFORM 1 FROM cotizacion_item ci
     WHERE ci.id_cotizacion = v_id_cotizacion
       AND ci.id_tecnica = '00000000-0000-4000-fa00-000000000002'
       AND ci.personalizacion = jsonb_build_object('color', 'azul', 'texto', 'Bienvenido');
    ASSERT FOUND, 'cotizacion_item debe guardar id_tecnica y personalizacion';

    RAISE NOTICE 'PASSED - cotizacion_item captura tecnica y personalizacion';
END;
$$;

-- Una tecnica inexistente se rechaza, no se guarda un id inventado.
DO $$
DECLARE v_bloqueada BOOLEAN := false; v_id_producto UUID;
BEGIN
    v_id_producto := '00000000-0000-4000-fa00-000000000003';
    BEGIN
        PERFORM * FROM fn_consola_crear_cotizacion_simple(
            '00000000-0000-4000-fa00-000000000010', v_id_producto, NULL, 5, 'COP', NULL,
            gen_random_uuid()
        );
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'una tecnica inexistente debe rechazarse';
    RAISE NOTICE 'PASSED - tecnica inexistente rechazada';
END;
$$;

-- Compatibilidad hacia atras: sin los parametros nuevos, sigue funcionando
-- exactamente igual que antes de 050.
DO $$
DECLARE v_status TEXT; v_id_producto UUID;
BEGIN
    v_id_producto := '00000000-0000-4000-fa00-000000000003';
    SELECT status INTO v_status FROM fn_consola_crear_cotizacion_simple(
        '00000000-0000-4000-fa00-000000000010', v_id_producto, NULL, 3
    );
    ASSERT v_status = 'OK', 'debe seguir funcionando sin los parametros nuevos (compatibilidad)';
    RAISE NOTICE 'PASSED - compatibilidad con llamadas anteriores a 050';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- Aceptar y convertir: la tecnica y personalizacion deben sobrevivir
-- ----------------------------------------------------------
UPDATE cotizacion SET estado = 'ACEPTADA'
 WHERE id_cotizacion = current_setting('app.id_cotizacion_personalizada')::uuid;

SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-fa00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    v_id_cotizacion UUID := current_setting('app.id_cotizacion_personalizada')::uuid;
    v_status TEXT;
    v_id_tecnica_pedido UUID;
    v_personalizacion_pedido JSONB;
BEGIN
    SELECT status INTO v_status
      FROM fn_consola_convertir_cotizacion_en_pedido(v_id_cotizacion);
    ASSERT v_status = 'OK', format('esperaba OK, obtuve %s', v_status);

    SELECT pi.id_tecnica, pi.personalizacion
      INTO v_id_tecnica_pedido, v_personalizacion_pedido
      FROM pedido_item pi
      JOIN pedido p ON p.id_pedido = pi.id_pedido
     WHERE p.id_cotizacion = v_id_cotizacion;

    ASSERT v_id_tecnica_pedido = '00000000-0000-4000-fa00-000000000002',
        'la tecnica debe sobrevivir de cotizacion_item a pedido_item';
    ASSERT v_personalizacion_pedido = jsonb_build_object('color', 'azul', 'texto', 'Bienvenido'),
        'la personalizacion debe sobrevivir de cotizacion_item a pedido_item';

    RAISE NOTICE 'PASSED - tecnica y personalizacion sobreviven a la conversion';
END;
$$;

RESET ROLE;

ROLLBACK;
