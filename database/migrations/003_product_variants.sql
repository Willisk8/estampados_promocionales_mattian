-- ============================================================
-- 003_product_variants.sql
-- Variantes del catálogo propio de Estampados
-- ============================================================

CREATE TABLE variante_producto (
    id_variante     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_producto     UUID        NOT NULL REFERENCES producto(id_producto),
    sku_variante    TEXT        NOT NULL,
    nombre          TEXT        NOT NULL,
    atributos       JSONB       NOT NULL DEFAULT '{}',  -- color, talla, material, etc.
    estado          TEXT        NOT NULL DEFAULT 'DRAFT'
                    CHECK (estado IN ('DRAFT','REVIEW_REQUIRED','REVIEWED','ACTIVE','INACTIVE')),
    activo          BOOLEAN     NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_variante_sku UNIQUE (id_producto, sku_variante)
);

ALTER TABLE variante_producto ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON variante_producto
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_variante_producto_id ON variante_producto (id_producto);
CREATE INDEX idx_variante_estado       ON variante_producto (estado);

-- Reutiliza fn_set_updated_at() definida en 002_products.sql
CREATE TRIGGER trg_variante_updated_at
    BEFORE UPDATE ON variante_producto
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
