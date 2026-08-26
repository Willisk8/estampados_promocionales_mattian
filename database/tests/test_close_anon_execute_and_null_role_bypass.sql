-- ============================================================
-- test_close_anon_execute_and_null_role_bypass.sql
-- Verifica el cierre del bypass de escritura sin autenticar (046).
-- ============================================================

BEGIN;

-- Usuario autenticado SIN fila en perfil_usuario: fn_consola_rol() = NULL
-- para el, exactamente el caso que explotaba la guardia vieja.
INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-f700-000000000001', 'sin-perfil-bypass@prueba.local'),
    ('00000000-0000-4000-f700-000000000002', 'comercial-bypass@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-f700-000000000002', 'comercial-bypass@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-f700-000000000010',
    '900888333',
    'ORGANIZACION BYPASS',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

-- ----------------------------------------------------------
-- Parte A: anon ya no puede ejecutar NINGUNA fn_*, ni de lectura ni de
-- escritura. Antes de 046 esto tenia exito.
-- ----------------------------------------------------------
SET LOCAL ROLE anon;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM fn_consola_rol();
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'anon no debe poder ejecutar fn_consola_rol tras 046';
    RAISE NOTICE 'PASSED - anon bloqueado en fn_consola_rol';
END;
$$;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_actualizar_estado_comercial(
            '00000000-0000-4000-f700-000000000010', 'CLIENTE', 'ALTA', NULL);
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'anon no debe poder ejecutar fn_consola_actualizar_estado_comercial tras 046';
    RAISE NOTICE 'PASSED - anon bloqueado en una funcion de escritura';
END;
$$;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_ai_cliente_resumen('00000000-0000-4000-f700-000000000010');
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'anon no debe poder ejecutar fn_ai_cliente_resumen tras 046';
    RAISE NOTICE 'PASSED - anon bloqueado en una funcion fn_ai_*';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- Parte B: un usuario AUTENTICADO sin perfil_usuario (v_rol NULL) ya no
-- pasa de largo por la guardia. Antes de 046, cada una de estas llamadas
-- tenia exito silenciosamente.
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f700-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_actualizar_estado_comercial(
            '00000000-0000-4000-f700-000000000010', 'CLIENTE', 'ALTA', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'un usuario sin perfil no debe poder actualizar estado comercial (era el bypass)';
    RAISE NOTICE 'PASSED - fn_consola_actualizar_estado_comercial ya no bypassea con v_rol NULL';
END;
$$;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_registrar_interaccion(
            '00000000-0000-4000-f700-000000000010', 'LLAMADA', 'OUTBOUND', 'SEGUIMIENTO');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'un usuario sin perfil no debe poder registrar interacciones (era el bypass)';
    RAISE NOTICE 'PASSED - fn_consola_registrar_interaccion ya no bypassea con v_rol NULL';
END;
$$;

DO $$
DECLARE v_id_cot UUID; v_bloqueada BOOLEAN := false;
BEGIN
    -- fn_consola_crear_cotizacion_simple exige rol antes de tocar
    -- resolve_price; con v_rol NULL el bypass viejo habria intentado crear
    -- la cotizacion igual.
    BEGIN
        PERFORM * FROM fn_consola_crear_cotizacion_simple(
            '00000000-0000-4000-f700-000000000010', gen_random_uuid(), NULL, 1, 'COP', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'un usuario sin perfil no debe poder crear cotizaciones (era el bypass)';
    RAISE NOTICE 'PASSED - fn_consola_crear_cotizacion_simple ya no bypassea con v_rol NULL';
END;
$$;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_aprobar_accion_ia(gen_random_uuid(), true, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'un usuario sin perfil no debe poder aprobar propuestas de IA (era el bypass)';
    RAISE NOTICE 'PASSED - fn_consola_aprobar_accion_ia ya no bypassea con v_rol NULL';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- Regresion: COMERCIAL (rol real) sigue funcionando con normalidad
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f700-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_estado TEXT;
BEGIN
    SELECT estado_comercial INTO v_estado FROM fn_consola_actualizar_estado_comercial(
        '00000000-0000-4000-f700-000000000010', 'CLIENTE', 'ALTA', 'prueba de regresion');
    ASSERT v_estado = 'CLIENTE', 'COMERCIAL debe seguir pudiendo actualizar estado comercial';
    RAISE NOTICE 'PASSED - COMERCIAL sigue funcionando tras la correccion';
END;
$$;

RESET ROLE;

ROLLBACK;
