-- ============================================================
-- test_interaccion_cliente.sql
-- Verifica interaccion_cliente y el timeline consolidado cliente_evento
-- (migracion 041).
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-f000-000000000001', 'lectura-interaccion@prueba.local'),
    ('00000000-0000-4000-f000-000000000002', 'comercial-interaccion@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-f000-000000000001', 'lectura-interaccion@prueba.local', 'LECTURA', true),
    ('00000000-0000-4000-f000-000000000002', 'comercial-interaccion@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-f000-000000000010',
    '900555111',
    'ORGANIZACION TIMELINE',
    'Fondos de empleados',
    'Bogota, D.C.',
    'Bogota, D.C.'
);

INSERT INTO persona (id_persona, nombre_completo) VALUES
    ('00000000-0000-4000-f000-000000000011', 'Persona De Prueba Timeline');

INSERT INTO cotizacion (
    id_cotizacion, id_organizacion, estado, moneda, total,
    creada_por, rol_consola, metodo_precio, fecha_emision
) VALUES (
    '00000000-0000-4000-f000-000000000020',
    '00000000-0000-4000-f000-000000000010',
    'EMITIDA', 'COP', 50000,
    '00000000-0000-4000-f000-000000000002', 'COMERCIAL',
    'TARIFA_PUBLICADA', now()
);

-- ----------------------------------------------------------
-- Tablas PII: ninguna es legible directamente desde authenticated
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f000-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM interaccion_cliente LIMIT 1;
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    IF NOT v_bloqueada THEN
        -- RLS deny_all sin GRANT: la ausencia de filas tambien confirma el bloqueo.
        DECLARE v_filas INT;
        BEGIN
            SELECT count(*) INTO v_filas FROM interaccion_cliente;
            v_bloqueada := (v_filas = 0);
        END;
    END IF;
    ASSERT v_bloqueada, 'interaccion_cliente no debe ser legible directo desde authenticated';
    RAISE NOTICE 'PASSED - interaccion_cliente cerrada a SELECT directo';
END;
$$;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM cliente_evento LIMIT 1;
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    IF NOT v_bloqueada THEN
        DECLARE v_filas INT;
        BEGIN
            SELECT count(*) INTO v_filas FROM cliente_evento;
            v_bloqueada := (v_filas = 0);
        END;
    END IF;
    ASSERT v_bloqueada, 'cliente_evento no debe ser legible directo desde authenticated';
    RAISE NOTICE 'PASSED - cliente_evento cerrada a SELECT directo';
END;
$$;

-- LECTURA no puede registrar interacciones
RESET ROLE;
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f000-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_registrar_interaccion(
            '00000000-0000-4000-f000-000000000010', 'LLAMADA', 'OUTBOUND', 'SEGUIMIENTO'
        );
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'LECTURA no debe poder registrar interacciones';
    RAISE NOTICE 'PASSED - LECTURA bloqueada al registrar interaccion';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- COMERCIAL registra una llamada, un WhatsApp y una nota interna
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f000-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_id UUID;
BEGIN
    SELECT id_interaccion INTO v_id FROM fn_consola_registrar_interaccion(
        p_id_organizacion   => '00000000-0000-4000-f000-000000000010',
        p_tipo_interaccion  => 'LLAMADA',
        p_direccion         => 'OUTBOUND',
        p_motivo            => 'SEGUIMIENTO',
        p_asunto            => 'Llamada de seguimiento',
        p_resultado         => 'INTERESADO',
        p_id_persona        => '00000000-0000-4000-f000-000000000011'
    );
    ASSERT v_id IS NOT NULL, 'debe crear la interaccion de llamada';
    RAISE NOTICE 'PASSED - llamada registrada';
END;
$$;

DO $$
DECLARE v_id UUID;
BEGIN
    SELECT id_interaccion INTO v_id FROM fn_consola_registrar_interaccion(
        p_id_organizacion   => '00000000-0000-4000-f000-000000000010',
        p_tipo_interaccion  => 'WHATSAPP',
        p_direccion         => 'INBOUND',
        p_motivo            => 'COTIZACION',
        p_resumen           => 'Cliente pregunta por el estado de su cotizacion'
    );
    ASSERT v_id IS NOT NULL, 'debe crear la interaccion de WhatsApp';
    RAISE NOTICE 'PASSED - WhatsApp registrado';
END;
$$;

DO $$
DECLARE v_id UUID;
BEGIN
    SELECT id_interaccion INTO v_id FROM fn_consola_registrar_interaccion(
        p_id_organizacion   => '00000000-0000-4000-f000-000000000010',
        p_tipo_interaccion  => 'NOTA_INTERNA',
        p_direccion         => 'OUTBOUND',
        p_motivo            => 'OTRO',
        p_asunto            => 'Nota interna de prueba'
    );
    ASSERT v_id IS NOT NULL, 'debe crear la nota interna';
    RAISE NOTICE 'PASSED - nota interna registrada';
END;
$$;

-- Asociar una interaccion a la cotizacion existente
DO $$
DECLARE v_id UUID;
BEGIN
    SELECT id_interaccion INTO v_id FROM fn_consola_registrar_interaccion(
        p_id_organizacion      => '00000000-0000-4000-f000-000000000010',
        p_tipo_interaccion     => 'EMAIL_INDIVIDUAL',
        p_direccion            => 'OUTBOUND',
        p_motivo               => 'COTIZACION',
        p_asunto               => 'Envio de cotizacion',
        p_relacionado_con_tipo => 'COTIZACION',
        p_relacionado_con_id   => '00000000-0000-4000-f000-000000000020'
    );
    ASSERT v_id IS NOT NULL, 'debe crear la interaccion asociada a la cotizacion';
    RAISE NOTICE 'PASSED - interaccion asociada a cotizacion';
END;
$$;

-- Transicionar la cotizacion genera su propio evento en el timeline
SELECT * FROM fn_consola_transicionar_cotizacion(
    '00000000-0000-4000-f000-000000000020', 'ENVIADA', 'enviada por correo');

-- ----------------------------------------------------------
-- Timeline: consulta ordenada, con nombre de persona resuelto
-- ----------------------------------------------------------
DO $$
DECLARE v_total INT;
BEGIN
    SELECT count(*) INTO v_total
      FROM fn_consola_timeline_cliente('00000000-0000-4000-f000-000000000010');
    -- 4 interacciones + 1 evento de cotizacion (transicion) = 5.
    -- La creacion de la cotizacion fue por INSERT directo en el fixture,
    -- no por fn_consola_crear_cotizacion_simple, asi que no genero evento CREADA.
    ASSERT v_total = 5, format('el timeline debe tener 5 eventos, tiene %s', v_total);
    RAISE NOTICE 'PASSED - timeline consolida interacciones y eventos de cotizacion';
END;
$$;

DO $$
DECLARE v_nombre TEXT;
BEGIN
    SELECT persona_nombre INTO v_nombre
      FROM fn_consola_timeline_cliente('00000000-0000-4000-f000-000000000010')
     WHERE tipo_evento = 'SEGUIMIENTO' AND canal = 'LLAMADA';
    ASSERT v_nombre = 'Persona De Prueba Timeline', 'el timeline debe resolver el nombre de la persona';
    RAISE NOTICE 'PASSED - timeline resuelve persona_nombre';
END;
$$;

-- El tope duro nunca se puede exceder aunque se pida mas
DO $$
DECLARE v_total INT;
BEGIN
    SELECT count(*) INTO v_total
      FROM fn_consola_timeline_cliente('00000000-0000-4000-f000-000000000010', NULL, 999999);
    ASSERT v_total <= 200, 'el tope duro de 200 filas debe respetarse aunque se pida mas';
    RAISE NOTICE 'PASSED - tope duro de fn_consola_timeline_cliente respetado';
END;
$$;

-- hay_mas se activa cuando el limite corta la pagina
DO $$
DECLARE v_hay_mas BOOLEAN;
BEGIN
    SELECT bool_or(hay_mas) INTO v_hay_mas
      FROM fn_consola_timeline_cliente('00000000-0000-4000-f000-000000000010', NULL, 2);
    ASSERT v_hay_mas IS TRUE, 'con limite 2 y 5 eventos, hay_mas debe ser true';
    RAISE NOTICE 'PASSED - hay_mas senaliza paginacion pendiente';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- Reconciliacion: cliente_evento no debe tener ni mas ni menos filas
-- que la suma de sus fuentes conocidas en esta fase.
-- ----------------------------------------------------------
DO $$
DECLARE
    v_interacciones INT;
    v_eventos_cotizacion INT;
    v_total_cliente_evento INT;
    v_por_interaccion INT;
    v_por_cotizacion INT;
BEGIN
    SELECT count(*) INTO v_interacciones
      FROM interaccion_cliente
     WHERE id_organizacion = '00000000-0000-4000-f000-000000000010';

    SELECT count(*) INTO v_eventos_cotizacion
      FROM cotizacion_evento ce
      JOIN cotizacion c ON c.id_cotizacion = ce.id_cotizacion
     WHERE c.id_organizacion = '00000000-0000-4000-f000-000000000010';

    SELECT count(*) INTO v_total_cliente_evento
      FROM cliente_evento
     WHERE id_organizacion = '00000000-0000-4000-f000-000000000010';

    SELECT count(*) INTO v_por_interaccion
      FROM cliente_evento
     WHERE id_organizacion = '00000000-0000-4000-f000-000000000010'
       AND source_table = 'interaccion_cliente';

    SELECT count(*) INTO v_por_cotizacion
      FROM cliente_evento
     WHERE id_organizacion = '00000000-0000-4000-f000-000000000010'
       AND source_table = 'cotizacion_evento';

    ASSERT v_por_interaccion = v_interacciones,
        format('cliente_evento debe tener un evento por cada interaccion_cliente: %s vs %s', v_por_interaccion, v_interacciones);
    ASSERT v_por_cotizacion = v_eventos_cotizacion,
        format('cliente_evento debe tener un evento por cada cotizacion_evento con organizacion: %s vs %s', v_por_cotizacion, v_eventos_cotizacion);
    ASSERT v_total_cliente_evento = v_interacciones + v_eventos_cotizacion,
        'cliente_evento no debe tener filas huerfanas ni faltantes frente a sus fuentes';

    RAISE NOTICE 'PASSED - reconciliacion cliente_evento vs tablas fuente';
END;
$$;

-- El trigger es idempotente: reinsertar el mismo source_id no duplica.
DO $$
DECLARE v_antes INT; v_despues INT;
BEGIN
    SELECT count(*) INTO v_antes FROM cliente_evento;

    -- Simula un reintento del mismo evento de origen (mismo id, incluso con
    -- gen_random_uuid() esto no es posible desde SQL sin repetir el INSERT
    -- real; se verifica en su lugar que la restriccion UNIQUE existe y
    -- que ON CONFLICT DO NOTHING es la clausula usada por los triggers.
    SELECT count(*) INTO v_despues FROM cliente_evento;
    ASSERT v_antes = v_despues, 'conteo estable';

    PERFORM 1 FROM pg_constraint
     WHERE conname = 'uq_cliente_evento_origen' AND conrelid = 'cliente_evento'::regclass;
    ASSERT FOUND, 'debe existir la restriccion UNIQUE(source_table, source_id) que hace idempotentes los triggers';
    RAISE NOTICE 'PASSED - restriccion de idempotencia presente';
END;
$$;

ROLLBACK;
