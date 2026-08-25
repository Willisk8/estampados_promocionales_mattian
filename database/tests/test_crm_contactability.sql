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
    'CONSENTIMIENTO',
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
    SELECT * INTO r FROM fn_email_eligible_for_campaign('hash-fixture-contacto-testcrm');
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
    SELECT * INTO r FROM fn_email_eligible_for_campaign('hash-fixture-contacto-testcrm');
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
    SELECT * INTO r FROM fn_email_eligible_for_campaign('hash-fixture-contacto-testcrm');
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
    SELECT * INTO r FROM fn_email_eligible_for_campaign('hash-fixture-contacto-testcrm');
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
    SELECT * INTO r FROM fn_email_eligible_for_campaign('hash-fixture-contacto-testcrm');
    ASSERT r.eligible = false, 'suppressed email should not be eligible';
    ASSERT r.reason = 'SUPPRESSED',
        'expected SUPPRESSED, got ' || COALESCE(r.reason, 'NULL');
    RAISE NOTICE 'PASSED - suppression wins over contactability';
END;
$$;

ROLLBACK;
