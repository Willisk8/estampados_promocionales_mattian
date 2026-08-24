-- ============================================================
-- 004_supplier_catalog.sql
-- Catálogo de proveedores: datos observados del scraping
-- Separado del catálogo propio (002/003).
--
-- IMPORTANTE: precio_proveedor_snapshot es append-only.
-- NUNCA ejecutar UPDATE sobre esta tabla.
-- ============================================================

-- ----------------------------------------------------------
-- proveedor
-- ----------------------------------------------------------
CREATE TABLE proveedor (
    id_proveedor    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id       TEXT        NOT NULL,  -- coincide con catalogo_promocionales_colombia.csv
    nombre          TEXT        NOT NULL,
    ciudad          TEXT,
    pais            TEXT        NOT NULL DEFAULT 'CO',
    activo          BOOLEAN     NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_proveedor_source UNIQUE (source_id)
);

ALTER TABLE proveedor ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON proveedor
    AS RESTRICTIVE FOR ALL USING (false);

-- ----------------------------------------------------------
-- producto_proveedor
-- Producto tal como lo publica el proveedor.
-- ----------------------------------------------------------
CREATE TABLE producto_proveedor (
    id_producto_proveedor   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_proveedor            UUID        NOT NULL REFERENCES proveedor(id_proveedor),
    sku_proveedor           TEXT,
    nombre_original         TEXT        NOT NULL,
    categoria               TEXT,
    tags                    TEXT[],
    descripcion             TEXT,
    atributos               JSONB       NOT NULL DEFAULT '{}',
    url_producto            TEXT,
    estado_calidad          TEXT        NOT NULL DEFAULT 'PENDING_REVIEW'
                            CHECK (estado_calidad IN (
                                'PENDING_REVIEW','VALID','NEEDS_REVIEW','REJECTED'
                            )),
    motivo_revision         TEXT,       -- razón si estado_calidad = NEEDS_REVIEW / REJECTED
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE producto_proveedor ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON producto_proveedor
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_prod_proveedor_id        ON producto_proveedor (id_proveedor);
CREATE INDEX idx_prod_proveedor_calidad   ON producto_proveedor (estado_calidad);

-- ----------------------------------------------------------
-- precio_proveedor_snapshot
-- Observaciones históricas de precio del proveedor.
-- APPEND-ONLY: registrar nuevas filas, NUNCA actualizar.
-- ----------------------------------------------------------
CREATE TABLE precio_proveedor_snapshot (
    id_snapshot             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_producto_proveedor   UUID        NOT NULL REFERENCES producto_proveedor(id_producto_proveedor),
    precio_publicado        NUMERIC(12,2) NOT NULL,
    moneda                  TEXT        NOT NULL DEFAULT 'COP',
    precio_texto_original   TEXT,
    visibilidad             TEXT,
    disponibilidad          TEXT,
    url_fuente              TEXT,
    observado_en            TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- IMPORTANTE: esta tabla es append-only. No usar UPDATE.
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE precio_proveedor_snapshot ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON precio_proveedor_snapshot
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_snap_producto_proveedor ON precio_proveedor_snapshot (id_producto_proveedor);
CREATE INDEX idx_snap_observado_en       ON precio_proveedor_snapshot (observado_en DESC);
