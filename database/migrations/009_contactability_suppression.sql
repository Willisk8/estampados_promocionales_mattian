-- ============================================================
-- 009_contactability_suppression.sql
-- Contactability and suppression controls.
-- ============================================================

CREATE TABLE contactabilidad (
    id_contactabilidad     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_canal_contacto      UUID        NOT NULL REFERENCES canal_contacto(id_canal_contacto),
    id_base_contacto       UUID        REFERENCES cat_base_contacto(id),
    base_contacto_codigo   TEXT        NOT NULL DEFAULT 'DESCONOCIDA'
                           CHECK (base_contacto_codigo IN (
                               'CONSENTIMIENTO_EXPRESO','RELACION_COMERCIAL_PREVIA',
                               'DATO_CORPORATIVO','SOLICITUD_DEL_TITULAR',
                               'DESCONOCIDA','NO_CONTACTAR'
                           )),
    evidencia              TEXT,
    texto_autorizacion_version TEXT,
    valido_desde           TIMESTAMPTZ NOT NULL DEFAULT now(),
    valido_hasta           TIMESTAMPTZ,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_contactabilidad_fechas
        CHECK (valido_hasta IS NULL OR valido_hasta >= valido_desde)
);

ALTER TABLE contactabilidad ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON contactabilidad
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_contactabilidad_canal ON contactabilidad (id_canal_contacto);
CREATE INDEX idx_contactabilidad_base  ON contactabilidad (base_contacto_codigo);
CREATE INDEX idx_contactabilidad_vig   ON contactabilidad (valido_desde, valido_hasta);

CREATE TABLE supresion (
    id_supresion           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tipo                   TEXT        NOT NULL DEFAULT 'EMAIL'
                           CHECK (tipo IN ('EMAIL','TELEFONO','WHATSAPP')),
    valor_hash             TEXT        NOT NULL,
    hash_algorithm         TEXT        NOT NULL DEFAULT 'HMAC-SHA256',
    id_motivo_supresion    UUID        REFERENCES cat_motivo_supresion(id),
    motivo_codigo          TEXT        NOT NULL
                           CHECK (motivo_codigo IN (
                               'UNSUBSCRIBE','SPAM_COMPLAINT','HARD_BOUNCE',
                               'SOLICITUD_SUPRESION','BLOQUEO_MANUAL'
                           )),
    fuente                 TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_supresion_tipo_hash UNIQUE (tipo, valor_hash)
);

ALTER TABLE supresion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON supresion
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_supresion_hash ON supresion (valor_hash);

CREATE OR REPLACE FUNCTION fn_email_eligible_for_campaign(
    p_email_hash TEXT
)
RETURNS TABLE (
    eligible BOOLEAN,
    reason   TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_has_suppression BOOLEAN;
    v_has_allowed_base BOOLEAN;
BEGIN
    IF p_email_hash IS NULL OR btrim(p_email_hash) = '' THEN
        RETURN QUERY SELECT false, 'EMAIL_HASH_REQUIRED';
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM supresion s
        WHERE s.tipo = 'EMAIL'
          AND s.valor_hash = p_email_hash
    ) INTO v_has_suppression;

    IF v_has_suppression THEN
        RETURN QUERY SELECT false, 'SUPPRESSED';
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM canal_contacto cc
        JOIN contactabilidad c
          ON c.id_canal_contacto = cc.id_canal_contacto
        WHERE cc.tipo = 'EMAIL'
          AND cc.email_hash = p_email_hash
          AND cc.estado = 'ACTIVE'
          AND c.base_contacto_codigo IN (
              'CONSENTIMIENTO_EXPRESO',
              'RELACION_COMERCIAL_PREVIA',
              'SOLICITUD_DEL_TITULAR'
          )
          AND (c.valido_hasta IS NULL OR c.valido_hasta > now())
    ) INTO v_has_allowed_base;

    IF v_has_allowed_base THEN
        RETURN QUERY SELECT true, 'ELIGIBLE';
        RETURN;
    END IF;

    RETURN QUERY SELECT false, 'CONTACTABILITY_NOT_CONFIRMED';
END;
$$;
