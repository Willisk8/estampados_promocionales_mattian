-- ============================================================
-- 021_marking_technique_costs.sql
-- Costos de técnicas de marcación observados en proveedores.
--
-- Estos datos alimentan la calculadora de costos de personalización.
-- Los precios son snapshots append-only: insertar nuevas observaciones
-- cuando cambian los precios; nunca actualizar histórico.
-- ============================================================

CREATE TABLE tecnica_marcacion (
    id_tecnica              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo                  TEXT        NOT NULL,
    aliases                 TEXT[],
    productos_compatibles   TEXT,
    materiales_compatibles  TEXT,
    mejor_para              TEXT,
    limitaciones            TEXT,
    drivers_costo           TEXT,
    source_url              TEXT,
    fetched_at              TIMESTAMPTZ,
    verification_status     TEXT        NOT NULL DEFAULT 'PENDING_REVIEW',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_tecnica_marcacion_codigo UNIQUE (codigo)
);

ALTER TABLE tecnica_marcacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON tecnica_marcacion
    AS RESTRICTIVE FOR ALL USING (false);

CREATE TABLE proveedor_tecnica_marcacion (
    id_proveedor_tecnica    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id               TEXT        NOT NULL,
    nombre                  TEXT        NOT NULL,
    ciudad                  TEXT,
    pais                    TEXT        NOT NULL DEFAULT 'CO',
    source_url              TEXT,
    activo                  BOOLEAN     NOT NULL DEFAULT true,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_proveedor_tecnica_source UNIQUE (source_id)
);

ALTER TABLE proveedor_tecnica_marcacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON proveedor_tecnica_marcacion
    AS RESTRICTIVE FOR ALL USING (false);

CREATE TABLE precio_tecnica_marcacion_snapshot (
    id_snapshot                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_tecnica                  UUID        NOT NULL REFERENCES tecnica_marcacion(id_tecnica),
    id_proveedor_tecnica        UUID        NOT NULL REFERENCES proveedor_tecnica_marcacion(id_proveedor_tecnica),
    observation_id              TEXT        NOT NULL,
    service_component           TEXT,
    price_scope                 TEXT        NOT NULL,
    productos_compatibles       TEXT,
    materiales_compatibles      TEXT,
    size_label                  TEXT,
    width_cm                    NUMERIC(12,4) CHECK (width_cm IS NULL OR width_cm > 0),
    height_cm                   NUMERIC(12,4) CHECK (height_cm IS NULL OR height_cm > 0),
    quantity_min                INTEGER CHECK (quantity_min IS NULL OR quantity_min > 0),
    quantity_max                INTEGER CHECK (quantity_max IS NULL OR quantity_max >= quantity_min),
    billing_unit                TEXT,
    currency                    TEXT        NOT NULL DEFAULT 'COP',
    price_value                 NUMERIC(12,2) CHECK (price_value IS NULL OR price_value >= 0),
    price_min                   NUMERIC(12,2) CHECK (price_min IS NULL OR price_min >= 0),
    price_max                   NUMERIC(12,2) CHECK (price_max IS NULL OR price_max >= 0),
    tax_status                  TEXT,
    condiciones                 TEXT,
    evidence_text               TEXT,
    source_url                  TEXT,
    fetched_at                  TIMESTAMPTZ,
    http_status                 INTEGER,
    verification_status         TEXT        NOT NULL DEFAULT 'PENDING_REVIEW',
    formato_costeo              JSONB       NOT NULL DEFAULT '{}',
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_precio_tecnica_observation UNIQUE (observation_id)
);

ALTER TABLE precio_tecnica_marcacion_snapshot ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON precio_tecnica_marcacion_snapshot
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_precio_tecnica_lookup
    ON precio_tecnica_marcacion_snapshot (id_tecnica, price_scope, verification_status);

CREATE INDEX idx_precio_tecnica_qty
    ON precio_tecnica_marcacion_snapshot (id_tecnica, quantity_min, quantity_max);

CREATE INDEX idx_precio_tecnica_fetched
    ON precio_tecnica_marcacion_snapshot (fetched_at DESC);

CREATE OR REPLACE FUNCTION fn_precio_tecnica_snap_no_update_delete()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'precio_tecnica_marcacion_snapshot is append-only — INSERT new rows for new observations, never UPDATE/DELETE existing rows';
END;
$$;

CREATE TRIGGER trg_precio_tecnica_snap_no_update
    BEFORE UPDATE ON precio_tecnica_marcacion_snapshot
    FOR EACH ROW EXECUTE FUNCTION fn_precio_tecnica_snap_no_update_delete();

CREATE TRIGGER trg_precio_tecnica_snap_no_delete
    BEFORE DELETE ON precio_tecnica_marcacion_snapshot
    FOR EACH ROW EXECUTE FUNCTION fn_precio_tecnica_snap_no_update_delete();

COMMENT ON TABLE tecnica_marcacion IS
    'Catalogo de tecnicas de personalizacion/marcacion: DTF, sublimacion, tampografia, serigrafia, laser, etc.';

COMMENT ON TABLE proveedor_tecnica_marcacion IS
    'Proveedores que publican servicios o costos de tecnicas de marcacion.';

COMMENT ON TABLE precio_tecnica_marcacion_snapshot IS
    'Snapshots append-only de precios de tecnicas de marcacion. Usar solo precios VERIFIED_PUBLIC_PRICE para costeo automatico.';
