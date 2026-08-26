-- ============================================================
-- test_quote_lifecycle.sql
-- Verifica el cimiento del ciclo de vida de cotizacion (migracion 040).
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-e000-000000000001', 'lectura-ciclo@prueba.local'),
    ('00000000-0000-4000-e000-000000000002', 'comercial-ciclo@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-e000-000000000001', 'lectura-ciclo@prueba.local', 'LECTURA', true),
    ('00000000-0000-4000-e000-000000000002', 'comercial-ciclo@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-e000-000000000010',
    '900987654',
    'ORGANIZACION CICLO COTIZACION',
    'Fondos de empleados',
    'Bogota, D.C.',
    'Bogota, D.C.'
);

INSERT INTO cotizacion (
    id_cotizacion, id_organizacion, estado, moneda, total,
    creada_por, rol_consola, metodo_precio, fecha_emision
) VALUES (
    '00000000-0000-4000-e000-000000000020',
    '00000000-0000-4000-e000-000000000010',
    'EMITIDA', 'COP', 100000,
    '00000000-0000-4000-e000-000000000002', 'COMERCIAL',
    'TARIFA_PUBLICADA', now()
);

-- ----------------------------------------------------------
-- El CHECK de margen versionado protege la auditabilidad del precio
-- ----------------------------------------------------------
DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        INSERT INTO cotizacion (
            id_organizacion, estado, moneda, total, creada_por, rol_consola,
            metodo_precio, id_margin_policy_version
        ) VALUES (
            '00000000-0000-4000-e000-000000000010', 'BORRADOR', 'COP', 1,
            '00000000-0000-4000-e000-000000000002', 'COMERCIAL',
            'CALCULO_COMPONENTES', NULL
        );
    EXCEPTION WHEN check_violation THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'CALCULO_COMPONENTES sin id_margin_policy_version debe rechazarse';
    RAISE NOTICE 'PASSED - margen calculado exige version de politica';
END;
$$;

-- ----------------------------------------------------------
-- cotizacion_evento es append-only incluso para un rol privilegiado
-- ----------------------------------------------------------
INSERT INTO cotizacion_evento (
    id_cotizacion_evento, id_cotizacion, tipo_evento, estado_nuevo,
    actor_tipo, actor_id, rol_consola
) VALUES (
    '00000000-0000-4000-e000-000000000030',
    '00000000-0000-4000-e000-000000000020',
    'CREADA', 'EMITIDA', 'HUMANO',
    '00000000-0000-4000-e000-000000000002', 'COMERCIAL'
);

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        UPDATE cotizacion_evento
           SET notas = 'reescritura del historial'
         WHERE id_cotizacion_evento = '00000000-0000-4000-e000-000000000030';
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'cotizacion_evento no debe permitir UPDATE ni al owner';
    RAISE NOTICE 'PASSED - cotizacion_evento append-only';
END;
$$;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        DELETE FROM cotizacion_evento
         WHERE id_cotizacion_evento = '00000000-0000-4000-e000-000000000030';
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'cotizacion_evento no debe permitir DELETE ni al owner';
    RAISE NOTICE 'PASSED - cotizacion_evento sin borrado';
END;
$$;

-- ----------------------------------------------------------
-- La maquina de estados declara terminales correctamente
-- ----------------------------------------------------------
DO $$
BEGIN
    ASSERT fn_cotizacion_transiciones_validas('ANULADA') = ARRAY[]::TEXT[],
        'ANULADA debe ser terminal';
    ASSERT fn_cotizacion_transiciones_validas('CONVERTIDA_A_PEDIDO') = ARRAY[]::TEXT[],
        'CONVERTIDA_A_PEDIDO debe ser terminal';
    ASSERT fn_cotizacion_transiciones_validas('INVENTADO') IS NULL,
        'un estado desconocido debe devolver NULL, no un array vacio';
    ASSERT 'ENVIADA' = ANY (fn_cotizacion_transiciones_validas('EMITIDA')),
        'EMITIDA debe poder pasar a ENVIADA';
    RAISE NOTICE 'PASSED - maquina de estados coherente';
END;
$$;

-- ----------------------------------------------------------
-- LECTURA no puede transicionar
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-e000-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_transicionar_cotizacion(
            '00000000-0000-4000-e000-000000000020', 'ENVIADA', 'intento de lectura');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'LECTURA no debe transicionar cotizaciones';
    RAISE NOTICE 'PASSED - LECTURA bloqueada en transicion';
END;
$$;

-- UPDATE directo sigue cerrado: sin GRANT de UPDATE y con deny_update.
DO $$
DECLARE v_bloqueada BOOLEAN := false; v_afectadas INT;
BEGIN
    BEGIN
        UPDATE cotizacion SET estado = 'ACEPTADA'
         WHERE id_cotizacion = '00000000-0000-4000-e000-000000000020';
        GET DIAGNOSTICS v_afectadas = ROW_COUNT;
        v_bloqueada := (v_afectadas = 0);
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'authenticated no debe poder hacer UPDATE directo sobre cotizacion';
    RAISE NOTICE 'PASSED - UPDATE directo sobre cotizacion sigue bloqueado';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- COMERCIAL transiciona, sella la fecha y deja evento
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-e000-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    v_estado TEXT;
    v_fecha_envio TIMESTAMPTZ;
    v_eventos INT;
BEGIN
    PERFORM * FROM fn_consola_transicionar_cotizacion(
        '00000000-0000-4000-e000-000000000020', 'ENVIADA', 'enviada al cliente');

    SELECT c.estado, c.fecha_envio INTO v_estado, v_fecha_envio
      FROM cotizacion c
     WHERE c.id_cotizacion = '00000000-0000-4000-e000-000000000020';

    ASSERT v_estado = 'ENVIADA', 'la cotizacion debe quedar en ENVIADA';
    ASSERT v_fecha_envio IS NOT NULL, 'la transicion a ENVIADA debe sellar fecha_envio';

    SELECT count(*) INTO v_eventos
      FROM cotizacion_evento e
     WHERE e.id_cotizacion = '00000000-0000-4000-e000-000000000020'
       AND e.tipo_evento = 'TRANSICION_ESTADO'
       AND e.estado_anterior = 'EMITIDA'
       AND e.estado_nuevo = 'ENVIADA'
       AND e.rol_consola = 'COMERCIAL';
    ASSERT v_eventos = 1, 'la transicion debe dejar exactamente un evento';

    RAISE NOTICE 'PASSED - transicion valida sella fecha y registra evento';
END;
$$;

-- ----------------------------------------------------------
-- Transicion invalida se rechaza
-- ----------------------------------------------------------
DO $$
DECLARE v_bloqueada BOOLEAN := false; v_estado TEXT;
BEGIN
    BEGIN
        -- ENVIADA no puede volver a BORRADOR.
        PERFORM * FROM fn_consola_transicionar_cotizacion(
            '00000000-0000-4000-e000-000000000020', 'BORRADOR', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'ENVIADA -> BORRADOR debe rechazarse';

    SELECT c.estado INTO v_estado
      FROM cotizacion c
     WHERE c.id_cotizacion = '00000000-0000-4000-e000-000000000020';
    ASSERT v_estado = 'ENVIADA', 'una transicion rechazada no debe cambiar el estado';

    RAISE NOTICE 'PASSED - transicion invalida rechazada sin efectos';
END;
$$;

-- ----------------------------------------------------------
-- El rechazo guarda el motivo
-- ----------------------------------------------------------
DO $$
DECLARE v_motivo TEXT; v_fecha TIMESTAMPTZ;
BEGIN
    PERFORM * FROM fn_consola_transicionar_cotizacion(
        '00000000-0000-4000-e000-000000000020', 'RECHAZADA', 'precio por encima del presupuesto');

    SELECT c.motivo_rechazo, c.fecha_rechazo INTO v_motivo, v_fecha
      FROM cotizacion c
     WHERE c.id_cotizacion = '00000000-0000-4000-e000-000000000020';

    ASSERT v_motivo = 'precio por encima del presupuesto', 'p_notas debe copiarse a motivo_rechazo';
    ASSERT v_fecha IS NOT NULL, 'RECHAZADA debe sellar fecha_rechazo';
    RAISE NOTICE 'PASSED - rechazo guarda motivo y fecha';
END;
$$;

RESET ROLE;

ROLLBACK;
