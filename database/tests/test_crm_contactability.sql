-- ============================================================
-- test_crm_contactability.sql
-- Basic integrity tests for CRM/contactability migrations.
-- Run in STAGING inside a transaction.
-- ============================================================

BEGIN;

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, sigla, tipo_entidad_origen
) VALUES (
    '00000000-0000-4000-b000-000000000001',
    '999000001',
    'ORGANIZACION SINTETICA DE PRUEBA CRM',
    'TESTCRM',
    'Fixture sintetico'
);

INSERT INTO persona (
    id_persona, nombre_completo
) VALUES (
    '00000000-0000-4000-b000-000000000002',
    'PERSONA SINTETICA DE PRUEBA'
);

INSERT INTO persona_organizacion (
    id_persona_organizacion, id_persona, id_organizacion, rol, cargo, fuente
) VALUES (
    '00000000-0000-4000-b000-000000000003',
    '00000000-0000-4000-b000-000000000002',
    '00000000-0000-4000-b000-000000000001',
    'REPRESENTANTE_LEGAL',
    'Representante legal',
    'fixture'
);

INSERT INTO canal_contacto (
    id_canal_contacto, id_organizacion, tipo, valor_original,
    valor_normalizado, email_hash, fuente, confianza
) VALUES (
    '00000000-0000-4000-b000-000000000004',
    '00000000-0000-4000-b000-000000000001',
    'EMAIL',
    'Contacto@Testcrm.example',
    'contacto@testcrm.example',
    'hash-fixture-contacto-testcrm',
    'fixture',
    'HIGH'
);

DO $$
BEGIN
    BEGIN
        INSERT INTO canal_contacto (
            id_persona, id_organizacion, tipo, valor_original, valor_normalizado
        ) VALUES (
            '00000000-0000-4000-b000-000000000002',
            '00000000-0000-4000-b000-000000000001',
            'EMAIL',
            'bad@example.com',
            'bad@example.com'
        );
        RAISE EXCEPTION 'owner constraint should have rejected two owners';
    EXCEPTION
        WHEN check_violation THEN
            RAISE NOTICE 'PASSED - canal_contacto rejects two owners';
    END;
END;
$$;

INSERT INTO contactabilidad (
    id_contactabilidad, id_canal_contacto, base_contacto_codigo, evidencia,
    valido_desde
) VALUES (
    '00000000-0000-4000-b000-000000000005',
    '00000000-0000-4000-b000-000000000004',
    'DESCONOCIDA',
    'Public registry import: do not assume campaign permission',
    now() - interval '10 minutes'
);

-- Agregar historial cerrado no debe multiplicar el canal en la vista operativa.
INSERT INTO contactabilidad (
    id_contactabilidad, id_canal_contacto, base_contacto_codigo,
    evidencia, valido_desde, valido_hasta
) VALUES (
    '00000000-0000-4000-b000-000000000006',
    '00000000-0000-4000-b000-000000000004',
    'CONSENTIMIENTO_EXPRESO',
    'Fixture historico cerrado',
    now() - interval '2 days',
    now() - interval '1 day'
);

DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM vw_campaign_eligibility_queue
    WHERE id_canal_contacto = '00000000-0000-4000-b000-000000000004';
    ASSERT v_count = 1,
        'campaign eligibility debe devolver una fila por canal, obtuvo: ' || v_count;
    RAISE NOTICE 'PASSED - campaign eligibility no duplica historial';
END;
$$;

DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r FROM fn_email_eligible_for_campaign('00000000-0000-4000-b000-000000000004'::uuid);
    ASSERT r.eligible = false, 'unknown contactability should not be eligible';
    ASSERT r.reason = 'CONTACTABILITY_NOT_CONFIRMED',
        'expected CONTACTABILITY_NOT_CONFIRMED, got ' || COALESCE(r.reason, 'NULL');
    RAISE NOTICE 'PASSED - unknown contactability is not campaign eligible';
END;
$$;

-- Un consentimiento futuro no debe ser efectivo ni aparecer como base vigente.
INSERT INTO contactabilidad (
    id_contactabilidad, id_canal_contacto, base_contacto_codigo,
    evidencia, valido_desde, valido_hasta
) VALUES (
    '00000000-0000-4000-b000-000000000007',
    '00000000-0000-4000-b000-000000000004',
    'CONSENTIMIENTO_EXPRESO',
    'Fixture consentimiento futuro',
    now() + interval '1 day',
    NULL
);

DO $$
DECLARE
    r RECORD;
    v_base TEXT;
BEGIN
    SELECT * INTO r FROM fn_email_eligible_for_campaign('00000000-0000-4000-b000-000000000004'::uuid);
    ASSERT r.eligible = false, 'future consent should not be eligible';
    ASSERT r.reason = 'CONTACTABILITY_NOT_CONFIRMED',
        'expected CONTACTABILITY_NOT_CONFIRMED for future consent, got ' || COALESCE(r.reason, 'NULL');

    SELECT base_contacto_codigo INTO v_base
    FROM vw_campaign_eligibility_queue
    WHERE id_canal_contacto = '00000000-0000-4000-b000-000000000004';
    ASSERT v_base = 'DESCONOCIDA',
        'future consent should not be shown as current contactability, got ' || COALESCE(v_base, 'NULL');
    RAISE NOTICE 'PASSED - future contactability is not effective';
END;
$$;

-- Un canal email sin HMAC no puede ser elegible aunque tenga consentimiento:
-- no se podria comprobar contra supresion global.
INSERT INTO canal_contacto (
    id_canal_contacto, id_organizacion, tipo, valor_original,
    valor_normalizado, email_hash, fuente, confianza
) VALUES (
    '00000000-0000-4000-b000-000000000013',
    '00000000-0000-4000-b000-000000000001',
    'EMAIL',
    'SinHash@Testcrm.example',
    'sinhash@testcrm.example',
    NULL,
    'fixture',
    'HIGH'
);

INSERT INTO contactabilidad (
    id_contactabilidad, id_canal_contacto, base_contacto_codigo,
    evidencia, valido_desde, valido_hasta
) VALUES (
    '00000000-0000-4000-b000-000000000014',
    '00000000-0000-4000-b000-000000000013',
    'CONSENTIMIENTO_EXPRESO',
    'Fixture consentimiento con hash nulo',
    now(),
    NULL
);

DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r
    FROM fn_email_eligible_for_campaign('00000000-0000-4000-b000-000000000013'::uuid);
    ASSERT r.eligible = false, 'email without HMAC hash should not be eligible';
    ASSERT r.reason = 'EMAIL_HASH_REQUIRED',
        'expected EMAIL_HASH_REQUIRED for null email_hash, got ' || COALESCE(r.reason, 'NULL');
    RAISE NOTICE 'PASSED - null email_hash fails closed';
END;
$$;

-- La fila efectiva mas reciente debe gobernar la vista y la elegibilidad.
-- Un NO_CONTACTAR vigente debe vencer un consentimiento previo que siga abierto.
INSERT INTO contactabilidad (
    id_contactabilidad, id_canal_contacto, base_contacto_codigo,
    evidencia, valido_desde, valido_hasta
) VALUES (
    '00000000-0000-4000-b000-000000000008',
    '00000000-0000-4000-b000-000000000004',
    'CONSENTIMIENTO_EXPRESO',
    'Fixture consentimiento efectivo previo',
    now() - interval '2 minutes',
    NULL
);

DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r FROM fn_email_eligible_for_campaign('00000000-0000-4000-b000-000000000004'::uuid);
    ASSERT r.eligible = true, 'effective consent should be eligible before NO_CONTACTAR';
    ASSERT r.reason = 'ELIGIBLE',
        'expected ELIGIBLE before NO_CONTACTAR, got ' || COALESCE(r.reason, 'NULL');
    RAISE NOTICE 'PASSED - effective consent is eligible before opt-out';
END;
$$;

INSERT INTO contactabilidad (
    id_contactabilidad, id_canal_contacto, base_contacto_codigo,
    evidencia, valido_desde, valido_hasta
) VALUES (
    '00000000-0000-4000-b000-000000000009',
    '00000000-0000-4000-b000-000000000004',
    'NO_CONTACTAR',
    'Fixture no contactar vigente',
    now(),
    NULL
);

DO $$
DECLARE
    r RECORD;
    v_base TEXT;
BEGIN
    SELECT * INTO r FROM fn_email_eligible_for_campaign('00000000-0000-4000-b000-000000000004'::uuid);
    ASSERT r.eligible = false, 'NO_CONTACTAR should win over older open consent';
    ASSERT r.reason = 'CONTACTABILITY_NOT_CONFIRMED',
        'expected CONTACTABILITY_NOT_CONFIRMED after NO_CONTACTAR, got ' || COALESCE(r.reason, 'NULL');

    SELECT base_contacto_codigo INTO v_base
    FROM vw_campaign_eligibility_queue
    WHERE id_canal_contacto = '00000000-0000-4000-b000-000000000004';
    ASSERT v_base = 'NO_CONTACTAR',
        'view should show latest effective NO_CONTACTAR, got ' || COALESCE(v_base, 'NULL');
    RAISE NOTICE 'PASSED - NO_CONTACTAR wins over older open consent';
END;
$$;

-- Dos canales pueden compartir email_hash. La elegibilidad debe aislarse por
-- id_canal_contacto; el consentimiento de un canal no habilita otro canal con
-- NO_CONTACTAR o DESCONOCIDA. La supresion sí sigue siendo global por hash.
INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, sigla, tipo_entidad_origen
) VALUES (
    '00000000-0000-4000-b000-000000000010',
    '999000002',
    'ORGANIZACION SINTETICA DUPLICADO EMAIL',
    'TESTCRM2',
    'Fixture sintetico'
);

INSERT INTO canal_contacto (
    id_canal_contacto, id_organizacion, tipo, valor_original,
    valor_normalizado, email_hash, fuente, confianza
) VALUES (
    '00000000-0000-4000-b000-000000000011',
    '00000000-0000-4000-b000-000000000010',
    'EMAIL',
    'Contacto@Testcrm.example',
    'contacto@testcrm.example',
    'hash-fixture-contacto-testcrm',
    'fixture',
    'HIGH'
);

INSERT INTO contactabilidad (
    id_contactabilidad, id_canal_contacto, base_contacto_codigo,
    evidencia, valido_desde, valido_hasta
) VALUES (
    '00000000-0000-4000-b000-000000000012',
    '00000000-0000-4000-b000-000000000011',
    'CONSENTIMIENTO_EXPRESO',
    'Fixture consentimiento en otro canal con mismo hash',
    now(),
    NULL
);

DO $$
DECLARE
    r_no_contactar RECORD;
    r_consentido RECORD;
    v_eligible_count INTEGER;
BEGIN
    SELECT * INTO r_no_contactar
    FROM fn_email_eligible_for_campaign('00000000-0000-4000-b000-000000000004'::uuid);
    SELECT * INTO r_consentido
    FROM fn_email_eligible_for_campaign('00000000-0000-4000-b000-000000000011'::uuid);

    ASSERT r_no_contactar.eligible = false,
        'NO_CONTACTAR channel must not inherit consent from duplicated hash';
    ASSERT r_consentido.eligible = true,
        'consented duplicated channel should be eligible before global suppression';

    SELECT COUNT(*) INTO v_eligible_count
    FROM vw_campaign_eligibility_queue
    WHERE email_hash = 'hash-fixture-contacto-testcrm'
      AND eligible = true;
    ASSERT v_eligible_count = 1,
        'duplicated hash should have exactly one eligible channel, got ' || v_eligible_count;

    RAISE NOTICE 'PASSED - eligibility is scoped by channel, not duplicated email_hash';
END;
$$;

INSERT INTO supresion (
    tipo, valor_hash, motivo_codigo, fuente
) VALUES (
    'EMAIL',
    'hash-fixture-contacto-testcrm',
    'UNSUBSCRIBE',
    'fixture'
);

DO $$
DECLARE
    r RECORD;
BEGIN
    SELECT * INTO r FROM fn_email_eligible_for_campaign('00000000-0000-4000-b000-000000000011'::uuid);
    ASSERT r.eligible = false, 'suppressed email should not be eligible';
    ASSERT r.reason = 'SUPPRESSED',
        'expected SUPPRESSED, got ' || COALESCE(r.reason, 'NULL');
    RAISE NOTICE 'PASSED - suppression wins over contactability';
END;
$$;

INSERT INTO import_batch (
    id_import_batch, source_name, source_path, source_sha256,
    source_row_count, import_status, started_at, finished_at, created_at
) VALUES (
    '00000000-0000-4000-b000-000000000013',
    'fixture_retention',
    'fixture.csv',
    'fixture-retention-sha',
    1,
    'COMPLETED',
    now() - interval '120 days',
    now() - interval '120 days',
    now() - interval '120 days'
);

INSERT INTO import_raw_row (
    id_import_raw_row, id_import_batch, row_number, raw_payload,
    normalized_payload, entity_kind, match_status, target_table, target_id,
    created_at
) VALUES (
    '00000000-0000-4000-b000-000000000014',
    '00000000-0000-4000-b000-000000000013',
    1,
    '{"email":"persona@example.com","telefono":"3001234567"}'::jsonb,
    '{"email":"persona@example.com"}'::jsonb,
    'OTHER',
    'IMPORTED',
    'canal_contacto',
    '00000000-0000-4000-b000-000000000011',
    now() - interval '120 days'
);

DO $$
DECLARE
    v_count INTEGER;
    v_raw JSONB;
    v_target UUID;
BEGIN
    SELECT fn_anonymize_import_raw_rows(90, true) INTO v_count;
    ASSERT v_count >= 1, 'dry-run should count at least one old raw row';

    SELECT fn_anonymize_import_raw_rows(90, false) INTO v_count;
    ASSERT v_count >= 1, 'apply should anonymize at least one old raw row';

    SELECT raw_payload, target_id
      INTO v_raw, v_target
      FROM import_raw_row
     WHERE id_import_raw_row = '00000000-0000-4000-b000-000000000014';

    ASSERT v_raw->>'_anonymized' = 'true', 'raw_payload should be anonymized';
    ASSERT v_target = '00000000-0000-4000-b000-000000000011'::uuid,
        'target_id lineage should be preserved';
    RAISE NOTICE 'PASSED - import_raw_row retention anonymizes PII payloads and preserves lineage';
END;
$$;

ROLLBACK;
