-- database/tests/test_quote_calculada_preview.sql
--
-- fn_consola_previsualizar_cotizacion_calculada (065): calcula sin persistir,
-- enmascarado por rol igual que fn_consola_componentes_cotizacion, y el total
-- que muestra debe coincidir exactamente con el que persiste
-- fn_consola_crear_cotizacion_calculada para el mismo input.
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fe00-000000000001', 'admin-prev@prueba.local'),
    ('00000000-0000-4000-fe00-000000000002', 'comercial-prev@prueba.local'),
    ('00000000-0000-4000-fe00-000000000003', 'lectura-prev@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fe00-000000000001', 'admin-prev@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fe00-000000000002', 'comercial-prev@prueba.local', 'COMERCIAL', true),
    ('00000000-0000-4000-fe00-000000000003', 'lectura-prev@prueba.local', 'LECTURA', true);

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fe00-000000000003', 'TEST-PREVIEW', 'Producto test preview', 'ACTIVE');

INSERT INTO costo_producto (id_costo, id_producto, id_variante, costo_base, costo_personalizacion, costo_empaque, otros_costos, moneda, vigencia)
VALUES ('00000000-0000-4000-fe00-000000000004', '00000000-0000-4000-fe00-000000000003', NULL, 2000, 0, 200, 0, 'COP', '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE);

-- ADMIN: preview debe mostrar costo real
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE det RECORD; v_total_preview NUMERIC;
BEGIN
    SELECT * INTO det FROM fn_consola_previsualizar_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fe00-000000000003',
        p_cantidad => 10
    ) WHERE tipo_componente = 'PRODUCTO';
    ASSERT det.status = 'OK', format('ADMIN preview PRODUCTO debe ser OK, obtuve %s', det.status);
    ASSERT det.costo_unitario = 2000, format('ADMIN debe ver costo_unitario real en preview, obtuve %s', det.costo_unitario);

    SELECT SUM(precio_resultante) INTO v_total_preview
      FROM fn_consola_previsualizar_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fe00-000000000003',
        p_cantidad => 10
      );
    PERFORM set_config('app.total_preview_admin', v_total_preview::text, false);
    RAISE NOTICE 'PASSED - ADMIN ve costo real en preview (total previsualizado: %)', v_total_preview;
END;
$$;

-- Paridad: el total previsualizado debe coincidir con el total que persiste
-- fn_consola_crear_cotizacion_calculada para el MISMO input.
DO $$
DECLARE r RECORD; v_total_preview NUMERIC := current_setting('app.total_preview_admin')::numeric;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fe00-000000000003',
        p_cantidad => 10
    );
    ASSERT r.status = 'OK', format('creacion real debe ser OK, obtuve %s', r.status);
    ASSERT r.total = v_total_preview,
        format('el total previsualizado (%s) debe coincidir con el total persistido (%s)', v_total_preview, r.total);
    RAISE NOTICE 'PASSED - total previsualizado coincide exactamente con el total persistido (%)', r.total;
END;
$$;

RESET ROLE;

-- COMERCIAL: preview enmascara costo/margen pero muestra precio final
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE det RECORD;
BEGIN
    SELECT * INTO det FROM fn_consola_previsualizar_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fe00-000000000003',
        p_cantidad => 10
    ) WHERE tipo_componente = 'PRODUCTO';
    ASSERT det.costo_unitario IS NULL, 'COMERCIAL no debe ver costo_unitario en preview';
    ASSERT det.margen_aplicado_pct IS NULL, 'COMERCIAL no debe ver margen en preview';
    ASSERT det.minimum_pct IS NULL, 'COMERCIAL no debe ver minimum_pct en preview';
    ASSERT det.precio_resultante IS NOT NULL, 'COMERCIAL si debe ver el precio final en preview';
    RAISE NOTICE 'PASSED - COMERCIAL ve precio enmascarado en preview';
END;
$$;

DO $$
DECLARE det RECORD;
BEGIN
    SELECT * INTO det FROM fn_consola_previsualizar_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fe00-000000000003',
        p_cantidad => 10,
        p_margen_override_pct => 40
    );
    ASSERT det.status = 'MARGIN_OVERRIDE_FORBIDDEN',
        format('COMERCIAL no debe inyectar margen manual en preview, obtuvo %s', det.status);
    RAISE NOTICE 'PASSED - COMERCIAL no puede inyectar margen manual en preview';
END;
$$;

RESET ROLE;

-- LECTURA: FORBIDDEN, no excepcion
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE det RECORD;
BEGIN
    SELECT * INTO det FROM fn_consola_previsualizar_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fe00-000000000003',
        p_cantidad => 10
    );
    ASSERT det.status = 'FORBIDDEN', format('LECTURA debe recibir FORBIDDEN, obtuve %s', det.status);
    RAISE NOTICE 'PASSED - LECTURA recibe FORBIDDEN sin excepcion';
END;
$$;

RESET ROLE;

-- Sin perfil activo: FORBIDDEN
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000099"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE det RECORD;
BEGIN
    SELECT * INTO det FROM fn_consola_previsualizar_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fe00-000000000003',
        p_cantidad => 10
    );
    ASSERT det.status = 'FORBIDDEN', format('sin perfil debe recibir FORBIDDEN, obtuve %s', det.status);
    RAISE NOTICE 'PASSED - sin perfil activo recibe FORBIDDEN';
END;
$$;

RESET ROLE;

ROLLBACK;
