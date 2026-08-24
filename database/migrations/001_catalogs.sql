-- ============================================================
-- 001_catalogs.sql
-- Catálogos/enums de dominio estables
-- Usa CHECK constraints (no ENUM de PostgreSQL) para facilitar
-- migraciones futuras sin bloquear la tabla.
-- ============================================================

-- ----------------------------------------------------------
-- cat_estado_oportunidad
-- ----------------------------------------------------------
CREATE TABLE cat_estado_oportunidad (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo      TEXT        NOT NULL
                CHECK (codigo IN (
                    'NUEVA','CONTACTADA','INTERESADA','COTIZANDO',
                    'NEGOCIACION','GANADA','PERDIDA'
                )),
    descripcion TEXT,
    activo      BOOLEAN     NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_cat_estado_oportunidad_codigo UNIQUE (codigo)
);

ALTER TABLE cat_estado_oportunidad ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON cat_estado_oportunidad
    AS RESTRICTIVE FOR ALL USING (false);

-- ----------------------------------------------------------
-- cat_tipo_organizacion
-- ----------------------------------------------------------
CREATE TABLE cat_tipo_organizacion (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo      TEXT        NOT NULL
                CHECK (codigo IN (
                    'FONDO_EMPLEADOS','CONJUNTO_RESIDENCIAL','COOPERATIVA',
                    'MUTUAL','EMPRESA','OTRO'
                )),
    descripcion TEXT,
    activo      BOOLEAN     NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_cat_tipo_organizacion_codigo UNIQUE (codigo)
);

ALTER TABLE cat_tipo_organizacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON cat_tipo_organizacion
    AS RESTRICTIVE FOR ALL USING (false);

-- ----------------------------------------------------------
-- cat_base_contacto
-- ----------------------------------------------------------
CREATE TABLE cat_base_contacto (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo      TEXT        NOT NULL
                CHECK (codigo IN (
                    'CONSENTIMIENTO_EXPRESO','RELACION_COMERCIAL_PREVIA',
                    'DATO_CORPORATIVO','SOLICITUD_DEL_TITULAR',
                    'DESCONOCIDA','NO_CONTACTAR'
                )),
    descripcion TEXT,
    activo      BOOLEAN     NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_cat_base_contacto_codigo UNIQUE (codigo)
);

ALTER TABLE cat_base_contacto ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON cat_base_contacto
    AS RESTRICTIVE FOR ALL USING (false);

-- ----------------------------------------------------------
-- cat_motivo_supresion
-- ----------------------------------------------------------
CREATE TABLE cat_motivo_supresion (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo      TEXT        NOT NULL
                CHECK (codigo IN (
                    'UNSUBSCRIBE','SPAM_COMPLAINT','HARD_BOUNCE',
                    'SOLICITUD_SUPRESION','BLOQUEO_MANUAL'
                )),
    descripcion TEXT,
    activo      BOOLEAN     NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_cat_motivo_supresion_codigo UNIQUE (codigo)
);

ALTER TABLE cat_motivo_supresion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON cat_motivo_supresion
    AS RESTRICTIVE FOR ALL USING (false);

-- ----------------------------------------------------------
-- Seed inicial de catálogos
-- ----------------------------------------------------------
INSERT INTO cat_estado_oportunidad (codigo, descripcion) VALUES
    ('NUEVA',        'Oportunidad recién identificada'),
    ('CONTACTADA',   'Se realizó primer contacto'),
    ('INTERESADA',   'Organización mostró interés'),
    ('COTIZANDO',    'Cotización en proceso'),
    ('NEGOCIACION',  'En negociación activa'),
    ('GANADA',       'Negocio cerrado exitosamente'),
    ('PERDIDA',      'Oportunidad no convertida');

INSERT INTO cat_tipo_organizacion (codigo, descripcion) VALUES
    ('FONDO_EMPLEADOS',       'Fondo de empleados'),
    ('CONJUNTO_RESIDENCIAL',  'Conjunto residencial o propiedad horizontal'),
    ('COOPERATIVA',           'Cooperativa'),
    ('MUTUAL',                'Mutual'),
    ('EMPRESA',               'Empresa del sector solidario u otro'),
    ('OTRO',                  'Otro tipo de organización');

INSERT INTO cat_base_contacto (codigo, descripcion) VALUES
    ('CONSENTIMIENTO_EXPRESO',    'El titular otorgó consentimiento expreso'),
    ('RELACION_COMERCIAL_PREVIA', 'Existía relación comercial previa'),
    ('DATO_CORPORATIVO',          'Dato público corporativo'),
    ('SOLICITUD_DEL_TITULAR',     'Solicitud iniciada por el titular'),
    ('DESCONOCIDA',               'Base legal no determinada'),
    ('NO_CONTACTAR',              'Titular solicitó no ser contactado');

INSERT INTO cat_motivo_supresion (codigo, descripcion) VALUES
    ('UNSUBSCRIBE',         'Solicitud de baja del titular'),
    ('SPAM_COMPLAINT',      'Reporte de spam'),
    ('HARD_BOUNCE',         'Correo inválido o inexistente'),
    ('SOLICITUD_SUPRESION', 'Solicitud formal de supresión (Ley 1581)'),
    ('BLOQUEO_MANUAL',      'Bloqueo manual por operador');
