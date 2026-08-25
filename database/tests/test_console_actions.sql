-- ============================================================
-- test_console_actions.sql
-- Verifica acciones controladas de la consola agregadas en 029.
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-d000-000000000001', 'lectura-acciones@prueba.local'),
    ('00000000-0000-4000-d000-000000000002', 'comercial-acciones@prueba.local'),
    ('00000000-0000-4000-d000-000000000003', 'admin-acciones@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-d000-000000000001', 'lectura-acciones@prueba.local', 'LECTURA', true),
    ('00000000-0000-4000-d000-000000000002', 'comercial-acciones@prueba.local', 'COMERCIAL', true),
    ('00000000-0000-4000-d000-000000000003', 'admin-acciones@prueba.local', 'ADMIN', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-d000-000000000010',
    '900123456',
    'ORGANIZACION ACCIONES CONSOLA',
    'Fondos de empleados',
    'Bogota, D.C.',
    'Bogota, D.C.'
);

INSERT INTO import_batch (
    id_import_batch, source_name, source_path, source_sha256, source_row_count, import_status
) VALUES (
    '00000000-0000-4000-d000-000000000020',
    'fixture acciones',
    'fixture.csv',
    repeat('a', 64),
    1,
    'COMPLETED'
);

INSERT INTO import_raw_row (
    id_import_raw_row, id_import_batch, row_number, raw_payload, normalized_payload
) VALUES (
    '00000000-0000-4000-d000-000000000021',
    '00000000-0000-4000-d000-000000000020',
    1,
    '{"nombre":"fixture"}',
    '{"nombre":"fixture"}'
);

INSERT INTO import_review_item (
    id_import_review_item, id_import_raw_row, review_reason, severity
) VALUES (
    '00000000-0000-4000-d000-000000000022',
    '00000000-0000-4000-d000-000000000021',
    'Fixture pendiente',
    'MEDIUM'
);

-- ----------------------------------------------------------
-- LECTURA no puede ejecutar acciones
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d000-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_resolver_revision(
            '00000000-0000-4000-d000-000000000022', 'IGNORED', 'lectura');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'LECTURA no debe resolver revisiones';
    RAISE NOTICE 'PASSED - LECTURA no ejecuta acciones de revision';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- COMERCIAL resuelve revision y deja auditoria
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d000-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_estado TEXT; v_auditoria INT;
BEGIN
    PERFORM * FROM fn_consola_resolver_revision(
        '00000000-0000-4000-d000-000000000022',
        'IGNORED',
        'No afecta carga final'
    );

    SELECT resolution_status INTO v_estado
      FROM import_review_item
     WHERE id_import_review_item = '00000000-0000-4000-d000-000000000022';
    ASSERT v_estado = 'IGNORED', format('estado inesperado: %s', v_estado);

    SELECT count(*) INTO v_auditoria
      FROM auditoria_revision_importacion
     WHERE id_import_review_item = '00000000-0000-4000-d000-000000000022'
       AND estado_anterior = 'OPEN'
       AND estado_nuevo = 'IGNORED'
       AND rol_consola = 'COMERCIAL';
    ASSERT v_auditoria = 1, 'debe existir auditoria de resolucion';

    RAISE NOTICE 'PASSED - COMERCIAL resuelve revision con auditoria';
END;
$$;

DO $$
DECLARE v_estado TEXT; v_prioridad TEXT;
BEGIN
    PERFORM * FROM fn_consola_actualizar_estado_comercial(
        '00000000-0000-4000-d000-000000000010',
        'CLIENTE',
        'ALTA',
        'Cliente piloto'
    );

    SELECT estado_comercial, prioridad INTO v_estado, v_prioridad
      FROM relacion_comercial_organizacion
     WHERE id_organizacion = '00000000-0000-4000-d000-000000000010';
    ASSERT v_estado = 'CLIENTE', 'estado comercial debe ser CLIENTE';
    ASSERT v_prioridad = 'ALTA', 'prioridad debe ser ALTA';

    RAISE NOTICE 'PASSED - estado comercial separado funciona';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- ADMIN clasifica tipo de organizacion con auditoria
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-d000-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_codigo TEXT; v_auditoria INT;
BEGIN
    PERFORM * FROM fn_consola_clasificar_tipo_organizacion(
        '00000000-0000-4000-d000-000000000010',
        'FONDO_EMPLEADOS',
        'TIPO_ORIGEN'
    );

    SELECT c.codigo INTO v_codigo
      FROM organizacion o
      JOIN cat_tipo_organizacion c ON c.id = o.id_tipo_organizacion
     WHERE o.id_organizacion = '00000000-0000-4000-d000-000000000010';
    ASSERT v_codigo = 'FONDO_EMPLEADOS', 'tipo normalizado incorrecto';

    SELECT count(*) INTO v_auditoria
      FROM auditoria_tipo_organizacion
     WHERE id_organizacion = '00000000-0000-4000-d000-000000000010'
       AND criterio = 'TIPO_ORIGEN'
       AND rol_consola = 'ADMIN';
    ASSERT v_auditoria = 1, 'debe existir auditoria de clasificacion';

    RAISE NOTICE 'PASSED - clasificacion de tipo auditada funciona';
END;
$$;

-- resolve_price sigue cerrado directo para authenticated.
DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM resolve_price(
            '00000000-0000-4000-d000-000000000010'::uuid, NULL, 1, now(), 'COP');
    EXCEPTION WHEN insufficient_privilege THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'authenticated no debe ejecutar resolve_price directo';
    RAISE NOTICE 'PASSED - resolve_price permanece cerrado';
END;
$$;

RESET ROLE;

ROLLBACK;
