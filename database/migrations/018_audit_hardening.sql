-- ============================================================
-- 018_audit_hardening.sql
-- Cierra hallazgos de cotizacion y evita duplicados por historial CRM.
-- ============================================================

CREATE OR REPLACE FUNCTION resolve_price(
    p_product_id UUID,
    p_variant_id UUID,
    p_quantity INT,
    p_at TIMESTAMPTZ DEFAULT now(),
    p_currency TEXT DEFAULT 'COP'
)
RETURNS TABLE (
    precio_unitario NUMERIC(12,2),
    moneda TEXT,
    id_precio UUID,
    nivel TEXT,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_count INT;
BEGIN
    IF p_currency NOT IN ('COP', 'USD') THEN
        RETURN QUERY SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                            NULL::TEXT, 'CURRENCY_NOT_SUPPORTED'::TEXT;
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM producto
        WHERE id_producto = p_product_id AND estado = 'ACTIVE'
    ) THEN
        RETURN QUERY SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                            NULL::TEXT, 'PRICE_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    -- Una variante indicada debe existir, pertenecer al producto y estar activa.
    -- No se permite caer silenciosamente al precio generico si esta inactiva.
    IF p_variant_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM variante_producto
        WHERE id_variante = p_variant_id
          AND id_producto = p_product_id
          AND estado = 'ACTIVE'
    ) THEN
        RETURN QUERY SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                            'VARIANTE'::TEXT, 'PRICE_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    IF p_variant_id IS NOT NULL THEN
        SELECT COUNT(*) INTO v_count
        FROM precio_producto pp
        WHERE pp.id_producto = p_product_id
          AND pp.id_variante = p_variant_id
          AND pp.quantity_range @> p_quantity
          AND pp.validity @> p_at
          AND pp.moneda = p_currency;

        IF v_count > 1 THEN
            RETURN QUERY SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                                'VARIANTE'::TEXT, 'PRICE_CONFIGURATION_ERROR'::TEXT;
            RETURN;
        ELSIF v_count = 1 THEN
            RETURN QUERY
                SELECT pp.precio_unitario, pp.moneda, pp.id_precio,
                       'VARIANTE'::TEXT, 'OK'::TEXT
                FROM precio_producto pp
                WHERE pp.id_producto = p_product_id
                  AND pp.id_variante = p_variant_id
                  AND pp.quantity_range @> p_quantity
                  AND pp.validity @> p_at
                  AND pp.moneda = p_currency;
            RETURN;
        END IF;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM precio_producto pp
    WHERE pp.id_producto = p_product_id
      AND pp.id_variante IS NULL
      AND pp.quantity_range @> p_quantity
      AND pp.validity @> p_at
      AND pp.moneda = p_currency;

    IF v_count > 1 THEN
        RETURN QUERY SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                            'PRODUCTO'::TEXT, 'PRICE_CONFIGURATION_ERROR'::TEXT;
        RETURN;
    ELSIF v_count = 1 THEN
        RETURN QUERY
            SELECT pp.precio_unitario, pp.moneda, pp.id_precio,
                   'PRODUCTO'::TEXT, 'OK'::TEXT
            FROM precio_producto pp
            WHERE pp.id_producto = p_product_id
              AND pp.id_variante IS NULL
              AND pp.quantity_range @> p_quantity
              AND pp.validity @> p_at
              AND pp.moneda = p_currency;
        RETURN;
    END IF;

    RETURN QUERY SELECT NULL::NUMERIC(12,2), p_currency, NULL::UUID,
                        NULL::TEXT, 'PRICE_NOT_FOUND'::TEXT;
END;
$$;

REVOKE ALL ON FUNCTION resolve_price(UUID, UUID, INT, TIMESTAMPTZ, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION resolve_price(UUID, UUID, INT, TIMESTAMPTZ, TEXT) FROM anon, authenticated;

CREATE OR REPLACE VIEW vw_campaign_eligibility_queue
WITH (security_invoker = on) AS
WITH contactabilidad_actual AS (
    SELECT DISTINCT ON (id_canal_contacto)
        id_canal_contacto,
        base_contacto_codigo,
        evidencia
    FROM contactabilidad
    WHERE valido_hasta IS NULL OR valido_hasta > now()
    ORDER BY id_canal_contacto, valido_desde DESC, created_at DESC
)
SELECT
    cc.id_canal_contacto,
    cc.id_organizacion,
    o.nit,
    o.nombre_legal,
    o.tipo_entidad_origen,
    o.departamento,
    o.municipio,
    cc.valor_normalizado AS email,
    cc.email_hash,
    cc.confianza,
    cc.estado AS estado_canal,
    c.base_contacto_codigo,
    c.evidencia,
    e.eligible,
    e.reason AS eligibility_reason
FROM canal_contacto cc
JOIN organizacion o ON o.id_organizacion = cc.id_organizacion
LEFT JOIN contactabilidad_actual c ON c.id_canal_contacto = cc.id_canal_contacto
CROSS JOIN LATERAL fn_email_eligible_for_campaign(cc.email_hash) e
WHERE cc.tipo = 'EMAIL';

COMMENT ON VIEW vw_campaign_eligibility_queue IS
    'Elegibilidad de emails usando solo la contactabilidad vigente mas reciente por canal.';
