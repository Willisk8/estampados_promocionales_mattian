-- ============================================================
-- test_close_authenticated_default_grant_on_ai_helpers.sql
-- Verifica que los ayudantes internos de la Fase 5 ya no sean invocables
-- directo por authenticated (047).
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-f800-000000000001', 'cualquiera-047@prueba.local');

-- Ni siquiera necesita perfil_usuario: cualquier authenticated bastaba
-- para explotar el hueco que corrige esta migracion.
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f800-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM fn_ai_resolver_sesion(NULL, 'ROL_INVENTADO');
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'authenticated no debe poder llamar fn_ai_resolver_sesion directo';
    RAISE NOTICE 'PASSED - fn_ai_resolver_sesion cerrada a authenticated';
END;
$$;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM fn_ai_registrar_llamada(gen_random_uuid(), 'fabricada', '{}'::jsonb, 'OK', 0);
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'authenticated no debe poder llamar fn_ai_registrar_llamada directo';
    RAISE NOTICE 'PASSED - fn_ai_registrar_llamada cerrada a authenticated';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- Regresion: las fn_ai_* publicas siguen funcionando (llaman a los
-- ayudantes por dentro, con privilegio de owner, no de authenticated).
-- ----------------------------------------------------------
INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-f800-000000000010',
    '900999444',
    'ORGANIZACION 047',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f800-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_id_sesion UUID; v_status TEXT;
BEGIN
    SELECT id_ia_sesion, status INTO v_id_sesion, v_status
      FROM fn_ai_cliente_resumen('00000000-0000-4000-f800-000000000010');
    ASSERT v_status = 'FORBIDDEN', 'sin perfil sigue devolviendo FORBIDDEN, no una excepcion';
    ASSERT v_id_sesion IS NOT NULL, 'fn_ai_cliente_resumen debe seguir pudiendo abrir sesion por dentro';
    RAISE NOTICE 'PASSED - fn_ai_cliente_resumen sigue funcionando, usa los ayudantes por dentro';
END;
$$;

RESET ROLE;

ROLLBACK;
