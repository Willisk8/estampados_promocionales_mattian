-- ============================================================
-- test_console_access.sql
-- Verifica el acceso de la consola interna (migracion 024).
--
-- Lo que debe quedar demostrado:
--   1. Sin perfil activo, un usuario autenticado no ve nada.
--   2. Con perfil activo ve las tablas sin datos personales.
--   3. No puede escribir en ninguna de ellas.
--   4. No puede tocar las tablas con PII ni las vistas de campana.
--   5. Los correos van enmascarados salvo para ADMIN.
--
-- Corre dentro de una transaccion y termina en ROLLBACK.
-- ============================================================

BEGIN;

-- ----------------------------------------------------------
-- Fixtures
-- ----------------------------------------------------------
INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-c000-000000000001', 'lectura@prueba.local'),
    ('00000000-0000-4000-c000-000000000002', 'admin@prueba.local'),
    ('00000000-0000-4000-c000-000000000003', 'sinperfil@prueba.local'),
    ('00000000-0000-4000-c000-000000000004', 'inactivo@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-c000-000000000001', 'lectura@prueba.local', 'LECTURA',  true),
    ('00000000-0000-4000-c000-000000000002', 'admin@prueba.local',   'ADMIN',    true),
    ('00000000-0000-4000-c000-000000000004', 'inactivo@prueba.local','COMERCIAL', false);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-c000-000000000010',
    '999000777',
    'ORGANIZACION SINTETICA CONSOLA',
    'Fixture sintetico',
    'Antioquia',
    'Medellin'
);

INSERT INTO canal_contacto (
    id_canal_contacto, id_organizacion, tipo, valor_original, valor_normalizado
) VALUES (
    '00000000-0000-4000-c000-000000000011',
    '00000000-0000-4000-c000-000000000010',
    'EMAIL',
    'Contacto@Sintetica.Test',
    'contacto@sintetica.test'
);

-- ----------------------------------------------------------
-- 1. Usuario autenticado SIN perfil: no ve nada
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-c000-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_filas INT;
BEGIN
    ASSERT fn_consola_rol() IS NULL, 'un usuario sin perfil no debe tener rol';

    SELECT count(*) INTO v_filas FROM organizacion;
    ASSERT v_filas = 0,
        format('sin perfil no debe ver organizaciones, vio %s', v_filas);

    SELECT count(*) INTO v_filas FROM proveedor;
    ASSERT v_filas = 0, 'sin perfil no debe ver proveedores';

    RAISE NOTICE 'PASSED - usuario autenticado sin perfil no ve datos';
END;
$$;

DO $$
DECLARE v_falla BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_resumen();
    EXCEPTION WHEN OTHERS THEN
        v_falla := true;
    END;
    ASSERT v_falla, 'fn_consola_resumen debe rechazar a quien no tiene perfil';
    RAISE NOTICE 'PASSED - las funciones de consola rechazan sin perfil';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- 2. Perfil INACTIVO: tampoco ve nada
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-c000-000000000004"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_filas INT;
BEGIN
    ASSERT fn_consola_rol() IS NULL, 'un perfil inactivo no debe otorgar rol';
    SELECT count(*) INTO v_filas FROM organizacion;
    ASSERT v_filas = 0, 'un perfil inactivo no debe ver organizaciones';
    RAISE NOTICE 'PASSED - perfil inactivo no ve datos';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- 3. Perfil LECTURA: ve las tablas sin datos personales
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-c000-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_filas INT;
BEGIN
    ASSERT fn_consola_rol() = 'LECTURA', 'el rol debe resolverse como LECTURA';

    SELECT count(*) INTO v_filas FROM organizacion
     WHERE id_organizacion = '00000000-0000-4000-c000-000000000010';
    ASSERT v_filas = 1, 'con perfil activo debe ver la organizacion fixture';

    SELECT count(*) INTO v_filas FROM perfil_usuario;
    ASSERT v_filas = 1,
        format('solo debe ver su propio perfil, vio %s', v_filas);

    RAISE NOTICE 'PASSED - perfil activo ve datos no personales y solo su perfil';
END;
$$;

-- ----------------------------------------------------------
-- 4. Ninguna escritura es posible
-- ----------------------------------------------------------
DO $$
DECLARE
    v_insert BOOLEAN := false;
    v_update BOOLEAN := false;
    v_delete BOOLEAN := false;
BEGIN
    BEGIN
        INSERT INTO organizacion (nombre_legal) VALUES ('INTENTO DE ESCRITURA');
    EXCEPTION WHEN OTHERS THEN v_insert := true;
    END;

    BEGIN
        UPDATE organizacion SET nombre_legal = 'CAMBIADO'
         WHERE id_organizacion = '00000000-0000-4000-c000-000000000010';
        IF NOT FOUND THEN v_update := true; END IF;
    EXCEPTION WHEN OTHERS THEN v_update := true;
    END;

    BEGIN
        DELETE FROM organizacion
         WHERE id_organizacion = '00000000-0000-4000-c000-000000000010';
        IF NOT FOUND THEN v_delete := true; END IF;
    EXCEPTION WHEN OTHERS THEN v_delete := true;
    END;

    ASSERT v_insert, 'INSERT en organizacion debe fallar';
    ASSERT v_update, 'UPDATE en organizacion no debe afectar filas';
    ASSERT v_delete, 'DELETE en organizacion no debe afectar filas';
    RAISE NOTICE 'PASSED - la consola no puede escribir en organizacion';
END;
$$;

-- ----------------------------------------------------------
-- 5. Las tablas con PII siguen fuera de alcance
-- ----------------------------------------------------------
DO $$
DECLARE
    t TEXT;
    v_bloqueada BOOLEAN;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'canal_contacto', 'persona', 'persona_organizacion',
        'contactabilidad', 'supresion', 'import_raw_row'
    ] LOOP
        v_bloqueada := false;
        BEGIN
            EXECUTE format('SELECT 1 FROM public.%I LIMIT 1', t);
        EXCEPTION WHEN insufficient_privilege THEN
            v_bloqueada := true;
        END;
        ASSERT v_bloqueada,
            format('la tabla %s no debe ser legible por authenticated', t);
    END LOOP;
    RAISE NOTICE 'PASSED - las 6 tablas con PII son inaccesibles directamente';
END;
$$;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM 1 FROM vw_campaign_eligibility_queue LIMIT 1;
    EXCEPTION WHEN insufficient_privilege THEN v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'la vista de elegibilidad de campana no debe ser legible';

    v_bloqueada := false;
    BEGIN
        PERFORM 1 FROM vw_email_quality_classification LIMIT 1;
    EXCEPTION WHEN insufficient_privilege THEN v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'la vista de calidad de correos no debe ser legible';

    RAISE NOTICE 'PASSED - las vistas que exponen correos siguen cerradas';
END;
$$;

-- ----------------------------------------------------------
-- 6. Enmascaramiento de correos segun rol
-- ----------------------------------------------------------
DO $$
DECLARE v_valor TEXT; v_masked BOOLEAN;
BEGIN
    SELECT valor, enmascarado INTO v_valor, v_masked
      FROM fn_consola_canales_organizacion('00000000-0000-4000-c000-000000000010')
     WHERE tipo = 'EMAIL';

    ASSERT v_masked, 'para LECTURA el correo debe venir enmascarado';
    ASSERT v_valor = 'c***@sintetica.test',
        format('enmascaramiento inesperado: %s', v_valor);
    ASSERT v_valor NOT LIKE '%contacto@%', 'el correo completo no debe filtrarse';
    RAISE NOTICE 'PASSED - LECTURA recibe el correo enmascarado';
END;
$$;

RESET ROLE;

SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-c000-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_valor TEXT; v_masked BOOLEAN;
BEGIN
    ASSERT fn_consola_rol() = 'ADMIN', 'el rol debe resolverse como ADMIN';

    SELECT valor, enmascarado INTO v_valor, v_masked
      FROM fn_consola_canales_organizacion('00000000-0000-4000-c000-000000000010')
     WHERE tipo = 'EMAIL';

    ASSERT NOT v_masked, 'para ADMIN el correo no debe venir enmascarado';
    ASSERT v_valor = 'contacto@sintetica.test',
        format('ADMIN deberia ver el correo completo, vio: %s', v_valor);
    RAISE NOTICE 'PASSED - ADMIN recibe el correo completo';
END;
$$;

-- ----------------------------------------------------------
-- 7. El resumen responde y cuenta lo que hay
-- ----------------------------------------------------------
DO $$
DECLARE v_orgs BIGINT; v_canales BIGINT;
BEGIN
    SELECT organizaciones, canales_contacto INTO v_orgs, v_canales
      FROM fn_consola_resumen();
    ASSERT v_orgs >= 1, 'el resumen debe contar al menos la organizacion fixture';
    ASSERT v_canales >= 1, 'el resumen debe contar canales sin exponerlos';
    RAISE NOTICE 'PASSED - fn_consola_resumen responde con perfil activo';
END;
$$;

-- ----------------------------------------------------------
-- 8. resolve_price sigue fuera del alcance del navegador
-- ----------------------------------------------------------
DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM resolve_price(
            '00000000-0000-4000-c000-000000000010'::uuid, NULL, 1, now(), 'COP');
    EXCEPTION WHEN insufficient_privilege THEN v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'authenticated no debe poder ejecutar resolve_price';
    RAISE NOTICE 'PASSED - resolve_price sigue cerrado para la consola';
END;
$$;

RESET ROLE;

ROLLBACK;
