-- database/tests/test_alta_rapida_proveedor_tecnica.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-ff00-000000000001', 'admin-altarapida@prueba.local'),
    ('00000000-0000-4000-ff00-000000000002', 'lectura-altarapida@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-ff00-000000000001', 'admin-altarapida@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-ff00-000000000002', 'lectura-altarapida@prueba.local', 'LECTURA', true);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ff00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD; v_activo BOOLEAN; v_source_id TEXT;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_proveedor_rapido('Proveedor Alta Rapida SAS');
    ASSERT r.status = 'OK', format('debe crear OK, obtuve %s', r.status);

    SELECT activo, source_id INTO v_activo, v_source_id FROM proveedor WHERE id_proveedor = r.id_proveedor;
    ASSERT v_activo = true, 'el proveedor de alta rapida nace activo';
    ASSERT v_source_id LIKE 'MANUAL-%', 'debe tener un source_id sintetico para satisfacer el UNIQUE';

    RAISE NOTICE 'PASSED - alta rapida de proveedor';
END;
$$;

DO $$
DECLARE r RECORD; v_status TEXT;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_tecnica_rapida('tecnica_alta_rapida_test');
    ASSERT r.status = 'OK', format('debe crear OK, obtuve %s', r.status);

    SELECT verification_status INTO v_status FROM tecnica_marcacion WHERE id_tecnica = r.id_tecnica;
    ASSERT v_status = 'PENDING_REVIEW', format('debe nacer PENDING_REVIEW (default de la tabla), obtuve %s', v_status);

    RAISE NOTICE 'PASSED - alta rapida de tecnica';
END;
$$;

RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ff00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueado BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_crear_proveedor_rapido('No deberia crearse');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueado := true;
    END;
    ASSERT v_bloqueado, 'LECTURA no debe poder crear proveedores';
    RAISE NOTICE 'PASSED - LECTURA bloqueada en alta rapida';
END;
$$;

RESET ROLE;
ROLLBACK;
