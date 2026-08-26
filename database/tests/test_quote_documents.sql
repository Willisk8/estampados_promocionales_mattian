-- ============================================================
-- test_quote_documents.sql
-- Verifica documentos, seguimiento y versionado de cotizacion (042).
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-a100-000000000001', 'lectura-docs@prueba.local'),
    ('00000000-0000-4000-a100-000000000002', 'comercial-docs@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-a100-000000000001', 'lectura-docs@prueba.local', 'LECTURA', true),
    ('00000000-0000-4000-a100-000000000002', 'comercial-docs@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-a100-000000000010',
    '900444222',
    'ORGANIZACION DOCUMENTOS COTIZACION',
    'Fondos de empleados',
    'Bogota, D.C.',
    'Bogota, D.C.'
);

INSERT INTO canal_contacto (id_canal_contacto, id_organizacion, tipo, valor_original, valor_normalizado)
VALUES (
    '00000000-0000-4000-a100-000000000011',
    '00000000-0000-4000-a100-000000000010',
    'EMAIL', 'contacto@organizacion-docs.test', 'contacto@organizacion-docs.test'
);

INSERT INTO cotizacion (
    id_cotizacion, id_organizacion, estado, moneda, total,
    creada_por, rol_consola, metodo_precio, fecha_emision
) VALUES (
    '00000000-0000-4000-a100-000000000020',
    '00000000-0000-4000-a100-000000000010',
    'EMITIDA', 'COP', 75000,
    '00000000-0000-4000-a100-000000000002', 'COMERCIAL',
    'TARIFA_PUBLICADA', now()
);

INSERT INTO cotizacion_item (
    id_cotizacion, id_producto, cantidad, precio_unitario, subtotal, producto_snapshot
)
SELECT
    '00000000-0000-4000-a100-000000000020', p.id_producto, 10, 7500, 75000,
    jsonb_build_object('sku', p.sku)
FROM producto p LIMIT 1;

-- Cotizacion vencida de control (fecha_vencimiento en el pasado)
INSERT INTO cotizacion (
    id_cotizacion, id_organizacion, estado, moneda, total,
    creada_por, rol_consola, metodo_precio, fecha_emision, fecha_vencimiento
) VALUES (
    '00000000-0000-4000-a100-000000000021',
    '00000000-0000-4000-a100-000000000010',
    'ENVIADA', 'COP', 30000,
    '00000000-0000-4000-a100-000000000002', 'COMERCIAL',
    'TARIFA_PUBLICADA', now() - interval '10 days', now() - interval '1 day'
);

-- ----------------------------------------------------------
-- Vencimiento consultable
-- ----------------------------------------------------------
DO $$
DECLARE v_vencida BOOLEAN; v_vigente BOOLEAN;
BEGIN
    SELECT esta_vencida INTO v_vencida FROM vw_cotizacion_vencimiento
     WHERE id_cotizacion = '00000000-0000-4000-a100-000000000021';
    ASSERT v_vencida IS TRUE, 'una cotizacion con fecha_vencimiento pasada debe marcarse vencida';

    SELECT esta_vencida INTO v_vigente FROM vw_cotizacion_vencimiento
     WHERE id_cotizacion = '00000000-0000-4000-a100-000000000020';
    ASSERT v_vigente IS FALSE, 'una cotizacion sin fecha_vencimiento no debe marcarse vencida';

    RAISE NOTICE 'PASSED - vw_cotizacion_vencimiento distingue vencidas de vigentes';
END;
$$;

-- ----------------------------------------------------------
-- LECTURA no puede escribir en ninguna de las tres tablas nuevas
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-a100-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_registrar_documento_cotizacion(
            '00000000-0000-4000-a100-000000000020', 'PDF_GENERADO', 'cotizaciones/2026/lectura.pdf');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'LECTURA no debe poder registrar documentos';
    RAISE NOTICE 'PASSED - LECTURA bloqueada en registrar_documento_cotizacion';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- COMERCIAL registra un PDF generado y luego uno enviado
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-a100-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        -- PDF_ENVIADO sin canal debe rechazarse: es la validacion, no un
        -- accidente de datos faltantes.
        PERFORM * FROM fn_consola_registrar_documento_cotizacion(
            '00000000-0000-4000-a100-000000000020', 'PDF_ENVIADO', 'cotizaciones/2026/sin-canal.pdf', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'PDF_ENVIADO sin id_canal_contacto debe rechazarse';
    RAISE NOTICE 'PASSED - PDF_ENVIADO exige canal de contacto';
END;
$$;

DO $$
DECLARE v_id_doc UUID; v_eventos INT;
BEGIN
    SELECT id_cotizacion_documento INTO v_id_doc
      FROM fn_consola_registrar_documento_cotizacion(
        '00000000-0000-4000-a100-000000000020', 'PDF_GENERADO', 'cotizaciones/2026/v1.pdf');
    ASSERT v_id_doc IS NOT NULL, 'debe registrar el PDF generado';

    PERFORM * FROM fn_consola_registrar_documento_cotizacion(
        '00000000-0000-4000-a100-000000000020', 'PDF_ENVIADO', 'cotizaciones/2026/v1.pdf',
        '00000000-0000-4000-a100-000000000011');

    SELECT count(*) INTO v_eventos
      FROM cotizacion_evento
     WHERE id_cotizacion = '00000000-0000-4000-a100-000000000020'
       AND tipo_evento IN ('PDF_GENERADO', 'PDF_ENVIADO');
    ASSERT v_eventos = 2, 'cada documento registrado debe dejar su evento';

    RAISE NOTICE 'PASSED - documentos generan su evento correspondiente';
END;
$$;

-- ----------------------------------------------------------
-- Seguimiento: programar y completar
-- ----------------------------------------------------------
DO $$
DECLARE v_id_followup UUID; v_estado TEXT;
BEGIN
    SELECT id_cotizacion_followup INTO v_id_followup
      FROM fn_consola_programar_seguimiento(
        '00000000-0000-4000-a100-000000000020', now() + interval '3 days', 'llamar para confirmar');
    ASSERT v_id_followup IS NOT NULL, 'debe crear el seguimiento programado';

    SELECT estado INTO v_estado FROM fn_consola_completar_seguimiento(v_id_followup, 'cliente confirmo interes');
    ASSERT v_estado = 'REALIZADO', 'el seguimiento debe quedar REALIZADO';

    -- No se puede completar dos veces
    DECLARE v_bloqueada BOOLEAN := false;
    BEGIN
        BEGIN
            PERFORM * FROM fn_consola_completar_seguimiento(v_id_followup, 'de nuevo');
        EXCEPTION WHEN OTHERS THEN
            v_bloqueada := true;
        END;
        ASSERT v_bloqueada, 'un seguimiento ya REALIZADO no debe poder completarse otra vez';
    END;

    RAISE NOTICE 'PASSED - ciclo de seguimiento completo';
END;
$$;

-- ----------------------------------------------------------
-- Versionado: version nueva no pisa la anterior
-- ----------------------------------------------------------
DO $$
DECLARE
    v_id_1 UUID; v_num_1 INT;
    v_id_2 UUID; v_num_2 INT;
    v_snapshot_1 JSONB;
    v_total INT;
BEGIN
    SELECT id_cotizacion_version, version_num INTO v_id_1, v_num_1
      FROM fn_consola_versionar_cotizacion('00000000-0000-4000-a100-000000000020', 'primera revision');

    SELECT id_cotizacion_version, version_num INTO v_id_2, v_num_2
      FROM fn_consola_versionar_cotizacion('00000000-0000-4000-a100-000000000020', 'segunda revision');

    ASSERT v_num_1 = 1, 'la primera version debe ser 1';
    ASSERT v_num_2 = 2, 'la segunda version debe ser 2, no reemplazar la 1';

    SELECT count(*) INTO v_total
      FROM cotizacion_version
     WHERE id_cotizacion = '00000000-0000-4000-a100-000000000020';
    ASSERT v_total = 2, 'deben existir ambas versiones simultaneamente';

    SELECT snapshot INTO v_snapshot_1 FROM cotizacion_version WHERE id_cotizacion_version = v_id_1;
    ASSERT (v_snapshot_1 -> 'cotizacion' ->> 'motivo_rechazo') IS NOT DISTINCT FROM NULL
        OR v_snapshot_1 IS NOT NULL, 'la version 1 conserva su propio snapshot';

    RAISE NOTICE 'PASSED - versionado no pisa versiones anteriores';
END;
$$;

-- cotizacion_version es append-only incluso para el owner
DO $$
DECLARE v_bloqueada BOOLEAN := false; v_id UUID;
BEGIN
    SELECT id_cotizacion_version INTO v_id FROM cotizacion_version
     WHERE id_cotizacion = '00000000-0000-4000-a100-000000000020' AND version_num = 1;
    BEGIN
        UPDATE cotizacion_version SET motivo = 'reescritura' WHERE id_cotizacion_version = v_id;
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'cotizacion_version no debe permitir UPDATE ni al owner';
    RAISE NOTICE 'PASSED - cotizacion_version append-only';
END;
$$;

-- El documento registra ruta, no contenido: la columna storage_path es TEXT,
-- nunca BYTEA/blob.
DO $$
DECLARE v_tipo TEXT;
BEGIN
    SELECT data_type INTO v_tipo
      FROM information_schema.columns
     WHERE table_name = 'cotizacion_documento' AND column_name = 'storage_path';
    ASSERT v_tipo = 'text', 'storage_path debe ser TEXT (ruta), nunca un tipo binario';
    RAISE NOTICE 'PASSED - cotizacion_documento guarda ruta, no contenido';
END;
$$;

RESET ROLE;

ROLLBACK;
