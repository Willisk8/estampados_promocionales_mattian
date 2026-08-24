-- ============================================================
-- 002_products.sql
-- Catálogo de productos propio de Estampados
-- (NO productos de proveedor — ver 004_supplier_catalog.sql)
-- ============================================================

CREATE TABLE producto (
    id_producto     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sku             TEXT        NOT NULL,
    nombre          TEXT        NOT NULL,
    categoria       TEXT,
    descripcion     TEXT,
    estado          TEXT        NOT NULL DEFAULT 'DRAFT'
                    CHECK (estado IN ('DRAFT','REVIEW_REQUIRED','REVIEWED','ACTIVE','INACTIVE')),
    activo          BOOLEAN     NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_producto_sku UNIQUE (sku)
);

ALTER TABLE producto ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON producto
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_producto_sku    ON producto (sku);
CREATE INDEX idx_producto_estado ON producto (estado);

-- Trigger para auto-actualizar updated_at
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_producto_updated_at
    BEFORE UPDATE ON producto
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
