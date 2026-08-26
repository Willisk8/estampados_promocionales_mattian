-- ============================================================
-- test_ai_context.sql
-- Verifica la capa de IA: delegacion, contrato de estados, auditoria (045).
-- ============================================================

BEGIN;

-- Usuario SIN perfil de consola: existe en auth.users pero no en
-- perfil_usuario. Debe recibir FORBIDDEN, nunca una excepcion.
INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-d400-000000000001', 'sin-perfil-ia@prueba.local'),
    ('00000000-0000-4000-d400-000000000002', 'lectura-ia@prueba.local'),
    ('00000000-0000-4000-d400-000000000003', 'comercial-ia@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-d400-000000000002', 'lectura-ia@prueba.local', 'LECTURA', true),
    ('00000000-0000-4000-d400-000000000003', 'comercial-ia@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-d400-000000000010',
    '900777222',
    'ORGANIZACION CONTEXTO IA',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

-- ----------------------------------------------------------
-- Sin perfil activo: FORBIDDEN, no excepcion
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d400-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_status TEXT; v_id_sesion UUID; v_excepcion BOOLEAN := false;
BEGIN
    BEGIN
        SELECT status, id_ia_sesion INTO v_status, v_id_sesion
          FROM fn_ai_cliente_resumen('00000000-0000-4000-d400-000000000010');
    EXCEPTION WHEN OTHERS THEN
        v_excepcion := true;
    END;
    ASSERT NOT v_excepcion, 'fn_ai_cliente_resumen nunca debe lanzar excepcion, ni sin perfil';
    ASSERT v_status = 'FORBIDDEN', format('esperaba FORBIDDEN, obtuve %s', v_status);
    ASSERT v_id_sesion IS NOT NULL, 'incluso sin perfil debe devolver una sesion para auditar el intento';
    RAISE NOTICE 'PASSED - sin perfil activo devuelve FORBIDDEN sin excepcion';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- LECTURA: organizacion inexistente devuelve NOT_FOUND
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d400-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_status TEXT;
BEGIN
    SELECT status INTO v_status
      FROM fn_ai_cliente_resumen('00000000-0000-0000-0000-000000000000');
    ASSERT v_status = 'NOT_FOUND', format('esperaba NOT_FOUND, obtuve %s', v_status);
    RAISE NOTICE 'PASSED - organizacion inexistente devuelve NOT_FOUND';
END;
$$;

-- INVALID_INPUT: organizacion nula
DO $$
DECLARE v_status TEXT;
BEGIN
    SELECT status INTO v_status FROM fn_ai_cliente_resumen(NULL);
    ASSERT v_status = 'INVALID_INPUT', format('esperaba INVALID_INPUT, obtuve %s', v_status);
    RAISE NOTICE 'PASSED - id_organizacion nulo devuelve INVALID_INPUT';
END;
$$;

-- ----------------------------------------------------------
-- La sesion se crea y se reutiliza (no se duplica)
-- ----------------------------------------------------------
DO $$
DECLARE v_id_sesion_1 UUID; v_id_sesion_2 UUID; v_total_sesiones INT;
BEGIN
    SELECT id_ia_sesion INTO v_id_sesion_1
      FROM fn_ai_cliente_resumen('00000000-0000-4000-d400-000000000010');
    ASSERT v_id_sesion_1 IS NOT NULL, 'debe crear una sesion nueva';

    SELECT id_ia_sesion INTO v_id_sesion_2
      FROM fn_ai_cliente_resumen('00000000-0000-4000-d400-000000000010', v_id_sesion_1);
    ASSERT v_id_sesion_2 = v_id_sesion_1, 'pasar el mismo id_ia_sesion debe reutilizarla, no crear otra';

    SELECT count(*) INTO v_total_sesiones FROM ia_sesion WHERE id_ia_sesion = v_id_sesion_1;
    ASSERT v_total_sesiones = 1, 'debe existir exactamente una fila de sesion';

    RAISE NOTICE 'PASSED - la sesion se crea una vez y se reutiliza';
END;
$$;

-- Una sesion inexistente/ajena no rompe nada: se abre una nueva
DO $$
DECLARE v_id_sesion UUID; v_status TEXT;
BEGIN
    SELECT id_ia_sesion, status INTO v_id_sesion, v_status
      FROM fn_ai_cliente_resumen('00000000-0000-4000-d400-000000000010', gen_random_uuid());
    ASSERT v_status = 'OK', 'un id_ia_sesion inexistente no debe impedir la llamada';
    ASSERT v_id_sesion IS NOT NULL, 'debe abrir una sesion nueva en vez de fallar';
    RAISE NOTICE 'PASSED - un id_ia_sesion invalido abre una sesion nueva sin fallar';
END;
$$;

-- ----------------------------------------------------------
-- La llamada queda registrada en ia_llamada_herramienta
-- ----------------------------------------------------------
DO $$
DECLARE v_id_sesion UUID; v_registros INT;
BEGIN
    SELECT id_ia_sesion INTO v_id_sesion
      FROM fn_ai_cliente_resumen('00000000-0000-4000-d400-000000000010');

    SELECT count(*) INTO v_registros
      FROM ia_llamada_herramienta
     WHERE id_ia_sesion = v_id_sesion
       AND herramienta = 'fn_ai_cliente_resumen'
       AND status = 'OK';
    ASSERT v_registros = 1, 'cada llamada exitosa debe dejar su registro de auditoria';

    RAISE NOTICE 'PASSED - la llamada queda registrada en ia_llamada_herramienta';
END;
$$;

-- ----------------------------------------------------------
-- fn_ai_cliente_timeline: tope duro y cursor
-- ----------------------------------------------------------
-- Crear las interacciones de fixture requiere ADMIN/COMERCIAL; se cambia
-- de rol solo para esto y se vuelve a LECTURA para seguir probando lectura.
RESET ROLE;
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d400-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    i INT;
BEGIN
    -- Cinco interacciones para tener paginacion real.
    FOR i IN 1..5 LOOP
        PERFORM * FROM fn_consola_registrar_interaccion(
            '00000000-0000-4000-d400-000000000010', 'LLAMADA', 'OUTBOUND', 'SEGUIMIENTO',
            p_occurred_at => now() - (i || ' hours')::interval
        );
    END LOOP;
END;
$$;

RESET ROLE;
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d400-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_total INT; v_hay_mas BOOLEAN; v_cursor TIMESTAMPTZ;
BEGIN
    SELECT count(*), bool_or(hay_mas) INTO v_total, v_hay_mas
      FROM fn_ai_cliente_timeline('00000000-0000-4000-d400-000000000010', NULL, 2);
    ASSERT v_total = 2, 'debe respetar el limite pedido';
    ASSERT v_hay_mas IS TRUE, 'con 5 eventos y limite 2 debe indicar que hay mas';

    SELECT min(occurred_at) INTO v_cursor
      FROM fn_ai_cliente_timeline('00000000-0000-4000-d400-000000000010', NULL, 2);

    -- Paginar con el cursor no debe repetir eventos ya vistos.
    SELECT count(*) INTO v_total
      FROM fn_ai_cliente_timeline('00000000-0000-4000-d400-000000000010', v_cursor, 2)
     WHERE occurred_at >= v_cursor;
    ASSERT v_total = 0, 'el cursor debe excluir el evento ya devuelto, no repetirlo';

    RAISE NOTICE 'PASSED - fn_ai_cliente_timeline respeta tope duro y cursor sin repetir eventos';
END;
$$;

-- El tope duro nunca se excede aunque se pida un limite absurdo
DO $$
DECLARE v_total INT;
BEGIN
    SELECT count(*) INTO v_total
      FROM fn_ai_cliente_timeline('00000000-0000-4000-d400-000000000010', NULL, 999999);
    ASSERT v_total <= 200, 'el tope duro de 200 debe respetarse aunque se pida mas';
    RAISE NOTICE 'PASSED - tope duro de fn_ai_cliente_timeline respetado';
END;
$$;

-- ----------------------------------------------------------
-- Ninguna funcion de esta fase expone un correo sin enmascarar
-- ----------------------------------------------------------
DO $$
DECLARE v_texto TEXT;
BEGIN
    SELECT string_agg(coalesce(resumen, '') || coalesce(canal, ''), ' ')
      INTO v_texto
      FROM fn_ai_cliente_timeline('00000000-0000-4000-d400-000000000010', NULL, 50);
    ASSERT v_texto !~ '@', 'fn_ai_cliente_timeline no debe exponer ningun correo';

    SELECT nombre_legal || coalesce(canal_preferido, '')
      INTO v_texto
      FROM fn_ai_cliente_resumen('00000000-0000-4000-d400-000000000010');
    ASSERT v_texto !~ '@', 'fn_ai_cliente_resumen no debe exponer ningun correo';

    RAISE NOTICE 'PASSED - la capa de IA no expone correos en ninguna funcion de lectura';
END;
$$;

-- ----------------------------------------------------------
-- fn_ai_vocabulario: descubrible, no requiere organizacion
-- ----------------------------------------------------------
DO $$
DECLARE v_valores TEXT[];
BEGIN
    SELECT valores INTO v_valores FROM fn_ai_vocabulario()
     WHERE entidad = 'pedido' AND campo = 'estado';
    ASSERT 'RECIBIDO' = ANY(v_valores), 'el vocabulario de pedido.estado debe incluir RECIBIDO';
    RAISE NOTICE 'PASSED - fn_ai_vocabulario expone los enums del esquema';
END;
$$;

-- ----------------------------------------------------------
-- fn_ai_senales_cliente: hechos, no texto de recomendacion
-- ----------------------------------------------------------
DO $$
DECLARE v_temp TEXT; v_seguimientos INT;
BEGIN
    SELECT temperatura, seguimientos_pendientes INTO v_temp, v_seguimientos
      FROM fn_ai_senales_cliente('00000000-0000-4000-d400-000000000010');
    ASSERT v_temp IS NOT NULL, 'fn_ai_senales_cliente debe devolver temperatura';
    ASSERT v_seguimientos = 0, 'sin seguimientos programados debe ser 0, no NULL';
    RAISE NOTICE 'PASSED - fn_ai_senales_cliente devuelve hechos calculables';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- COMERCIAL: recomendacion y propuesta quedan auditadas
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d400-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_id_rec UUID; v_status TEXT;
BEGIN
    SELECT id_ia_recomendacion, status INTO v_id_rec, v_status
      FROM fn_ai_registrar_recomendacion(
        '00000000-0000-4000-d400-000000000010',
        'Cliente sin gestion hace mas de 60 dias, sugerir llamada de seguimiento.',
        jsonb_build_object('temperatura', 'FRIO')
      );
    ASSERT v_status = 'OK', 'debe registrar la recomendacion';
    ASSERT v_id_rec IS NOT NULL, 'debe devolver el id de la recomendacion creada';
    RAISE NOTICE 'PASSED - la recomendacion queda auditada';
END;
$$;

DO $$
DECLARE v_id_propuesta UUID; v_status TEXT; v_expira TIMESTAMPTZ;
BEGIN
    SELECT id_ia_accion_propuesta, status, expira_at INTO v_id_propuesta, v_status, v_expira
      FROM fn_ai_proponer_accion(
        '00000000-0000-4000-d400-000000000010',
        'PROGRAMAR_SEGUIMIENTO',
        jsonb_build_object('fecha_sugerida', now() + interval '3 days'),
        'Cliente frio, sin gestion en 60+ dias.'
      );
    ASSERT v_status = 'OK', 'debe crear la propuesta';
    ASSERT v_id_propuesta IS NOT NULL, 'debe devolver el id de la propuesta';
    ASSERT v_expira IS NOT NULL AND v_expira > now(), 'expira_at debe quedar establecido en el futuro';

    RAISE NOTICE 'PASSED - la propuesta de accion queda auditada con expira_at obligatorio';
END;
$$;

-- Tipo de accion invalido: INVALID_INPUT, no excepcion
DO $$
DECLARE v_status TEXT;
BEGIN
    SELECT status INTO v_status FROM fn_ai_proponer_accion(
        '00000000-0000-4000-d400-000000000010', 'ENVIAR_DESCUENTO_50_POR_CIENTO',
        '{}'::jsonb, 'intento fuera de vocabulario'
    );
    ASSERT v_status = 'INVALID_INPUT', 'un tipo_accion fuera del vocabulario debe rechazarse sin excepcion';
    RAISE NOTICE 'PASSED - tipo_accion invalido devuelve INVALID_INPUT';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- La aprobacion es humana: LECTURA no puede aprobar
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d400-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_id_propuesta UUID;
BEGIN
    SELECT id_ia_accion_propuesta INTO v_id_propuesta
      FROM fn_ai_proponer_accion(
        '00000000-0000-4000-d400-000000000010', 'REGISTRAR_INTERACCION', '{}'::jsonb, 'segunda propuesta de control'
      );
    PERFORM set_config('app.id_propuesta_control', v_id_propuesta::text, false);
END;
$$;

RESET ROLE;
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d400-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false; v_id_propuesta UUID := current_setting('app.id_propuesta_control')::uuid;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_aprobar_accion_ia(v_id_propuesta, true, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'LECTURA no debe poder aprobar propuestas de IA';
    RAISE NOTICE 'PASSED - LECTURA bloqueada al aprobar una propuesta';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- COMERCIAL aprueba; una propuesta ya resuelta no se vuelve a aprobar
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d400-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    v_id_propuesta UUID := current_setting('app.id_propuesta_control')::uuid;
    v_estado TEXT;
    v_bloqueada BOOLEAN := false;
BEGIN
    SELECT estado INTO v_estado FROM fn_consola_aprobar_accion_ia(v_id_propuesta, true, 'aprobado en prueba');
    ASSERT v_estado = 'APROBADA', 'la propuesta debe quedar APROBADA';

    BEGIN
        PERFORM * FROM fn_consola_aprobar_accion_ia(v_id_propuesta, true, 'segundo intento');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'una propuesta ya resuelta no debe poder aprobarse de nuevo';

    RAISE NOTICE 'PASSED - la propuesta se aprueba una sola vez';
END;
$$;

RESET ROLE;

ROLLBACK;
