-- ============================================================
-- 005_supplier_product_mapping.sql
-- Relación entre producto del proveedor y variante propia.
-- Requiere aprobación humana (estado_mapeo = PENDING_REVIEW
-- hasta que un operador confirme o rechace el mapeo).
-- ============================================================

CREATE TABLE mapeo_proveedor_variante (
    id_mapeo                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_variante             UUID        NOT NULL REFERENCES variante_producto(id_variante),
    id_producto_proveedor   UUID        NOT NULL REFERENCES producto_proveedor(id_producto_proveedor),
    estado_mapeo            TEXT        NOT NULL DEFAULT 'PENDING_REVIEW'
                            CHECK (estado_mapeo IN ('PENDING_REVIEW','CONFIRMED','REJECTED')),
    confirmado_en           TIMESTAMPTZ,
    notas                   TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_mapeo UNIQUE (id_variante, id_producto_proveedor)
);

ALTER TABLE mapeo_proveedor_variante ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON mapeo_proveedor_variante
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_mapeo_variante          ON mapeo_proveedor_variante (id_variante);
CREATE INDEX idx_mapeo_producto_prov     ON mapeo_proveedor_variante (id_producto_proveedor);
CREATE INDEX idx_mapeo_estado            ON mapeo_proveedor_variante (estado_mapeo);
