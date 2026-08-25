-- ============================================================
-- 017_supplier_price_purchase_terms.sql
-- Enriquece snapshots de proveedor con condiciones de compra.
--
-- Los precios de proveedor pueden cambiar diaria/mensualmente y
-- ademas dependen del formato: unidad, caja, metro, 50 cm, 15 cm,
-- minimo de compra, etc. Esta migracion es no destructiva.
-- ============================================================

ALTER TABLE precio_proveedor_snapshot
    ADD COLUMN unidad_compra TEXT CHECK (
        unidad_compra IS NULL OR unidad_compra IN (
            'UNIT',       -- precio por unidad
            'PACK',       -- precio por caja/paquete
            'METER',      -- precio por metro lineal
            'CENTIMETER', -- precio por centimetro lineal
            'SHEET',      -- precio por pliego/formato
            'CUSTOM'      -- otro formato documentado en formato_compra
        )
    ),
    ADD COLUMN cantidad_pack NUMERIC(12,4) CHECK (cantidad_pack IS NULL OR cantidad_pack > 0),
    ADD COLUMN ancho_cm NUMERIC(12,4) CHECK (ancho_cm IS NULL OR ancho_cm > 0),
    ADD COLUMN alto_cm NUMERIC(12,4) CHECK (alto_cm IS NULL OR alto_cm > 0),
    ADD COLUMN minimo_compra NUMERIC(12,4) CHECK (minimo_compra IS NULL OR minimo_compra > 0),
    ADD COLUMN incremento_compra NUMERIC(12,4) CHECK (incremento_compra IS NULL OR incremento_compra > 0),
    ADD COLUMN formato_compra JSONB NOT NULL DEFAULT '{}',
    ADD COLUMN precio_vigencia TSTZRANGE,
    ADD COLUMN notas_costeo TEXT;

COMMENT ON COLUMN precio_proveedor_snapshot.unidad_compra IS
    'Unidad comercial observada: UNIT, PACK, METER, CENTIMETER, SHEET o CUSTOM.';

COMMENT ON COLUMN precio_proveedor_snapshot.cantidad_pack IS
    'Cantidad de unidades incluidas cuando unidad_compra = PACK. Ej: caja mug x36.';

COMMENT ON COLUMN precio_proveedor_snapshot.ancho_cm IS
    'Ancho util del formato cuando aplica. Ej: DTF textil 58 cm.';

COMMENT ON COLUMN precio_proveedor_snapshot.alto_cm IS
    'Alto/largo util del formato cuando aplica. Ej: 30, 50, 100 cm.';

COMMENT ON COLUMN precio_proveedor_snapshot.minimo_compra IS
    'Minimo comercial de compra en la unidad indicada.';

COMMENT ON COLUMN precio_proveedor_snapshot.incremento_compra IS
    'Incremento comercial de compra despues del minimo.';

COMMENT ON COLUMN precio_proveedor_snapshot.formato_compra IS
    'Metadata flexible del formato/proveedor: fuente, ciudad, calidad, notas de lista, etc.';

COMMENT ON COLUMN precio_proveedor_snapshot.precio_vigencia IS
    'Vigencia declarada por el proveedor si existe. El historico real sigue siendo observado_en.';

COMMENT ON COLUMN precio_proveedor_snapshot.notas_costeo IS
    'Notas humanas para explicar como usar este snapshot en el motor de costeo.';

