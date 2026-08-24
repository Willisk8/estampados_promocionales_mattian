-- ============================================================
-- 008_crm_organizations_people.sql
-- CRM base: organizations, people, relationships and channels.
-- ============================================================

CREATE TABLE organizacion (
    id_organizacion        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    nit                    TEXT,
    nombre_legal           TEXT        NOT NULL,
    nombre_comercial       TEXT,
    sigla                  TEXT,
    id_tipo_organizacion   UUID        REFERENCES cat_tipo_organizacion(id),
    tipo_entidad_origen    TEXT,
    departamento           TEXT,
    municipio              TEXT,
    direccion              TEXT,
    fuente_registro        TEXT,
    fecha_reporte_oficial  TIMESTAMPTZ,
    estado                 TEXT        NOT NULL DEFAULT 'ACTIVE'
                           CHECK (estado IN ('ACTIVE','INACTIVE','MERGED','REVIEW_REQUIRED')),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_organizacion_nit_digits
        CHECK (nit IS NULL OR nit ~ '^[0-9]{5,15}$'),
    CONSTRAINT uq_organizacion_nit UNIQUE (nit)
);

ALTER TABLE organizacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON organizacion
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_organizacion_nombre_legal ON organizacion (nombre_legal);
CREATE INDEX idx_organizacion_tipo         ON organizacion (id_tipo_organizacion);
CREATE INDEX idx_organizacion_municipio    ON organizacion (departamento, municipio);

CREATE TRIGGER trg_organizacion_updated_at
    BEFORE UPDATE ON organizacion
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE persona (
    id_persona             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    nombres                TEXT,
    apellidos              TEXT,
    nombre_completo        TEXT        NOT NULL,
    tipo_documento         TEXT,
    numero_documento_hash  TEXT,
    estado                 TEXT        NOT NULL DEFAULT 'ACTIVE'
                           CHECK (estado IN ('ACTIVE','INACTIVE','MERGED','REVIEW_REQUIRED')),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE persona ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON persona
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_persona_nombre_completo ON persona (nombre_completo);
CREATE UNIQUE INDEX uq_persona_documento_hash
    ON persona (tipo_documento, numero_documento_hash)
    WHERE numero_documento_hash IS NOT NULL;

CREATE TRIGGER trg_persona_updated_at
    BEFORE UPDATE ON persona
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE persona_organizacion (
    id_persona_organizacion UUID       PRIMARY KEY DEFAULT gen_random_uuid(),
    id_persona              UUID       NOT NULL REFERENCES persona(id_persona),
    id_organizacion         UUID       NOT NULL REFERENCES organizacion(id_organizacion),
    rol                     TEXT       NOT NULL DEFAULT 'CONTACTO'
                              CHECK (rol IN (
                                  'REPRESENTANTE_LEGAL','CONTACTO','COMPRAS',
                                  'GERENCIA','MERCADEO','OTRO'
                              )),
    cargo                   TEXT,
    area                    TEXT,
    fecha_inicio            DATE,
    fecha_fin               DATE,
    fuente                  TEXT,
    estado                  TEXT       NOT NULL DEFAULT 'ACTIVE'
                              CHECK (estado IN ('ACTIVE','INACTIVE','REVIEW_REQUIRED')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_persona_org_fechas
        CHECK (fecha_fin IS NULL OR fecha_inicio IS NULL OR fecha_fin >= fecha_inicio),
    CONSTRAINT uq_persona_org_rol_inicio
        UNIQUE (id_persona, id_organizacion, rol, fecha_inicio)
);

ALTER TABLE persona_organizacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON persona_organizacion
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_persona_org_persona      ON persona_organizacion (id_persona);
CREATE INDEX idx_persona_org_organizacion ON persona_organizacion (id_organizacion);
CREATE INDEX idx_persona_org_rol          ON persona_organizacion (rol);

CREATE TABLE canal_contacto (
    id_canal_contacto      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_persona             UUID        REFERENCES persona(id_persona),
    id_organizacion        UUID        REFERENCES organizacion(id_organizacion),
    tipo                   TEXT        NOT NULL
                           CHECK (tipo IN ('EMAIL','TELEFONO','WHATSAPP','WEBSITE')),
    valor_original         TEXT        NOT NULL,
    valor_normalizado      TEXT        NOT NULL,
    email_hash             TEXT,
    fuente                 TEXT,
    confianza              TEXT        NOT NULL DEFAULT 'UNKNOWN'
                           CHECK (confianza IN ('HIGH','MEDIUM','LOW','UNKNOWN')),
    estado                 TEXT        NOT NULL DEFAULT 'ACTIVE'
                           CHECK (estado IN ('ACTIVE','INVALID','BOUNCED','SUPPRESSED','REVIEW_REQUIRED')),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_canal_exactly_one_owner
        CHECK (
            (id_persona IS NOT NULL AND id_organizacion IS NULL)
            OR
            (id_persona IS NULL AND id_organizacion IS NOT NULL)
        ),
    CONSTRAINT ck_canal_email_hash_only_email
        CHECK (email_hash IS NULL OR tipo = 'EMAIL')
);

ALTER TABLE canal_contacto ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON canal_contacto
    AS RESTRICTIVE FOR ALL USING (false);

CREATE UNIQUE INDEX uq_canal_persona_tipo_valor
    ON canal_contacto (id_persona, tipo, valor_normalizado)
    WHERE id_persona IS NOT NULL;

CREATE UNIQUE INDEX uq_canal_organizacion_tipo_valor
    ON canal_contacto (id_organizacion, tipo, valor_normalizado)
    WHERE id_organizacion IS NOT NULL;

CREATE INDEX idx_canal_tipo_valor      ON canal_contacto (tipo, valor_normalizado);
CREATE INDEX idx_canal_email_hash      ON canal_contacto (email_hash) WHERE email_hash IS NOT NULL;
CREATE INDEX idx_canal_organizacion    ON canal_contacto (id_organizacion);
CREATE INDEX idx_canal_persona         ON canal_contacto (id_persona);

CREATE TRIGGER trg_canal_contacto_updated_at
    BEFORE UPDATE ON canal_contacto
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
