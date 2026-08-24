-- ============================================================
-- 007_price_resolution.sql
-- Función resolve_price: fuente única de verdad para precios.
--
-- Status posibles:
--   OK                        — precio encontrado sin ambigüedad
--   PRICE_NOT_FOUND           — ningún precio aplica para los parámetros
--   PRICE_CONFIGURATION_ERROR — múltiples precios solapados (datos corruptos)
--   CURRENCY_NOT_SUPPORTED    — moneda no soportada
-- ============================================================

CREATE OR REPLACE FUNCTION resolve_price(
    p_product_id    UUID,
    p_variant_id    UUID,           -- NULL para precio genérico del producto
    p_quantity      INT,
    p_at            TIMESTAMPTZ DEFAULT now(),
    p_currency      TEXT        DEFAULT 'COP'
)
RETURNS TABLE (
    precio_unitario NUMERIC(12,2),
    moneda          TEXT,
    id_precio       UUID,
    nivel           TEXT,   -- 'VARIANTE' | 'PRODUCTO'
    status          TEXT    -- 'OK' | 'PRICE_NOT_FOUND' | 'PRICE_CONFIGURATION_ERROR' | 'CURRENCY_NOT_SUPPORTED'
)
LANGUAGE plpgsql
-- SECURITY DEFINER: la función se ejecuta con los permisos del owner,
-- no del caller. Esto permite bypassear RLS para leer precio_producto
-- de forma controlada. Solo debe ser invocada por roles de backend;
-- nunca exponer directamente en el frontend.
SECURITY DEFINER
AS $$
DECLARE
    v_count INT;
BEGIN
    -- Validar currency básica
    IF p_currency NOT IN ('COP', 'USD') THEN
        RETURN QUERY
            SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                   NULL::TEXT, 'CURRENCY_NOT_SUPPORTED'::TEXT;
        RETURN;
    END IF;

    -- Verificar que el producto exista y esté en estado ACTIVE.
    -- Productos en DRAFT/REVIEW_REQUIRED/REVIEWED no son cotizables.
    IF NOT EXISTS (
        SELECT 1 FROM producto
        WHERE id_producto = p_product_id AND estado = 'ACTIVE'
    ) THEN
        RETURN QUERY
            SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                   NULL::TEXT, 'PRICE_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    -- Buscar precio específico de variante primero (si se proporcionó variante)
    IF p_variant_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_count
        FROM precio_producto pp
        WHERE pp.id_producto     = p_product_id
          AND pp.id_variante     = p_variant_id
          AND pp.quantity_range @> p_quantity
          AND pp.validity       @> p_at
          AND pp.moneda          = p_currency;

        IF v_count > 1 THEN
            RETURN QUERY
                SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                       'VARIANTE'::TEXT, 'PRICE_CONFIGURATION_ERROR'::TEXT;
            RETURN;
        END IF;

        IF v_count = 1 THEN
            RETURN QUERY
                SELECT pp.precio_unitario, pp.moneda, pp.id_precio,
                       'VARIANTE'::TEXT, 'OK'::TEXT
                FROM precio_producto pp
                WHERE pp.id_producto     = p_product_id
                  AND pp.id_variante     = p_variant_id
                  AND pp.quantity_range @> p_quantity
                  AND pp.validity       @> p_at
                  AND pp.moneda          = p_currency;
            RETURN;
        END IF;
    END IF;

    -- Buscar precio genérico del producto (id_variante IS NULL)
    SELECT COUNT(*) INTO v_count
    FROM precio_producto pp
    WHERE pp.id_producto     = p_product_id
      AND pp.id_variante    IS NULL
      AND pp.quantity_range @> p_quantity
      AND pp.validity       @> p_at
      AND pp.moneda          = p_currency;

    IF v_count > 1 THEN
        RETURN QUERY
            SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                   'PRODUCTO'::TEXT, 'PRICE_CONFIGURATION_ERROR'::TEXT;
        RETURN;
    END IF;

    IF v_count = 1 THEN
        RETURN QUERY
            SELECT pp.precio_unitario, pp.moneda, pp.id_precio,
                   'PRODUCTO'::TEXT, 'OK'::TEXT
            FROM precio_producto pp
            WHERE pp.id_producto     = p_product_id
              AND pp.id_variante    IS NULL
              AND pp.quantity_range @> p_quantity
              AND pp.validity       @> p_at
              AND pp.moneda          = p_currency;
        RETURN;
    END IF;

    -- Ningún precio encontrado
    RETURN QUERY
        SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
               NULL::TEXT, 'PRICE_NOT_FOUND'::TEXT;
END;
$$;
