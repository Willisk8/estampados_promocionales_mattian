-- ============================================================
-- 006_prices_costs.sql
-- Motor de precios propio (trabaja sobre catálogo propio).
-- NO trabaja directamente sobre precios de proveedor.
-- ============================================================

-- ----------------------------------------------------------
-- costo_producto
-- Costo del producto propio (puede originarse de proveedor u
-- otro insumo). Registra costos históricos via TSTZRANGE.
-- ----------------------------------------------------------
CREATE TABLE costo_producto (
    id_costo                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_producto             UUID        NOT NULL REFERENCES producto(id_producto),
    id_variante             UUID        REFERENCES variante_producto(id_variante),
    -- NULL en id_variante = costo aplica a todo el producto
    costo_base              NUMERIC(12,2) NOT NULL DEFAULT 0,
    costo_personalizacion   NUMERIC(12,2) NOT NULL DEFAULT 0,
    costo_empaque           NUMERIC(12,2) NOT NULL DEFAULT 0,
    otros_costos            NUMERIC(12,2) NOT NULL DEFAULT 0,
    moneda                  TEXT        NOT NULL DEFAULT 'COP',
    vigencia                TSTZRANGE   NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE costo_producto ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON costo_producto
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_costo_producto_id   ON costo_producto (id_producto);
CREATE INDEX idx_costo_variante_id   ON costo_producto (id_variante);

-- ----------------------------------------------------------
-- precio_producto
-- Precio de venta propio con escalas por cantidad.
-- INT4RANGE para rangos de cantidad, TSTZRANGE para vigencia.
-- Constraint de exclusión evita precios solapados para la
-- misma variante/producto en el mismo período y rango de qty.
-- ----------------------------------------------------------
CREATE TABLE precio_producto (
    id_precio               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_producto             UUID        NOT NULL REFERENCES producto(id_producto),
    id_variante             UUID        REFERENCES variante_producto(id_variante),
    -- NULL en id_variante = precio aplica a todo el producto
    quantity_range          INT4RANGE   NOT NULL,
    validity                TSTZRANGE   NOT NULL,
    precio_unitario         NUMERIC(12,2) NOT NULL CHECK (precio_unitario > 0),
    moneda                  TEXT        NOT NULL DEFAULT 'COP',
    incluye_impuestos       BOOLEAN     NOT NULL DEFAULT false,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Exclusion constraint:
    -- Mismo producto/variante no puede tener rangos solapados en el mismo período.
    -- COALESCE sobre id_variante: cuando es NULL se reemplaza por un UUID centinela
    -- para que la comparación WITH = funcione correctamente.
    CONSTRAINT no_solapamiento_precio EXCLUDE USING GIST (
        COALESCE(id_variante, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
        id_producto WITH =,
        quantity_range WITH &&,
        validity WITH &&
    )
);

ALTER TABLE precio_producto ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON precio_producto
    AS RESTRICTIVE FOR ALL USING (false);

CREATE INDEX idx_precio_producto_id  ON precio_producto (id_producto);
CREATE INDEX idx_precio_variante_id  ON precio_producto (id_variante);
