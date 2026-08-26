-- ============================================================
-- 038_quote_engine_components.sql
--
-- Capa aditiva para cotizar desde costos versionados.
--
-- DECISION DE ARQUITECTURA
-- - precio_producto queda como tarifa comercial publicada opcional.
-- - resolve_price() solo resuelve tarifas publicadas exactas.
-- - fn_calculate_quote_components() calcula desde costo_producto,
--   producto_tecnica y una politica de margen versionada.
-- - cotizacion_componente permite reconstruir por que una cotizacion
--   se calculo con esos valores sin recalcular historicos.
--
-- Las retenciones NO inflan el precio cotizado; se proyectan aparte en
-- una capa financiera posterior. IVA/impuestos se tratan fuera de este
-- MVP salvo que la tarifa publicada indique lo contrario.
-- ============================================================

CREATE TABLE producto_tecnica (
    id_producto_tecnica        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_producto                UUID        NOT NULL REFERENCES producto(id_producto),
    id_variante                UUID        REFERENCES variante_producto(id_variante),
    id_tecnica                 UUID        NOT NULL REFERENCES tecnica_marcacion(id_tecnica),
    permitida                  BOOLEAN     NOT NULL DEFAULT true,
    cantidad_minima_tecnica    INTEGER     NOT NULL DEFAULT 1 CHECK (cantidad_minima_tecnica > 0),
    cantidad_recomendada       INTEGER     CHECK (
                                           cantidad_recomendada IS NULL
                                           OR cantidad_recomendada >= cantidad_minima_tecnica
                                       ),
    configuracion_estandar     JSONB       NOT NULL DEFAULT '{}',
    merma_pct                  NUMERIC(7,4) NOT NULL DEFAULT 0 CHECK (merma_pct >= 0),
    notas                      TEXT,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE producto_tecnica ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON producto_tecnica
    AS RESTRICTIVE FOR ALL USING (false);

CREATE UNIQUE INDEX uq_producto_tecnica_scope
    ON producto_tecnica (
        id_producto,
        COALESCE(id_variante, '00000000-0000-0000-0000-000000000000'::uuid),
        id_tecnica
    );

CREATE INDEX idx_producto_tecnica_lookup
    ON producto_tecnica (id_producto, id_tecnica, permitida);

CREATE TRIGGER trg_producto_tecnica_updated_at
    BEFORE UPDATE ON producto_tecnica
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE margin_policy_version (
    id_margin_policy_version   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo                     TEXT        NOT NULL,
    version_label              TEXT        NOT NULL,
    estado                     TEXT        NOT NULL DEFAULT 'DRAFT'
                                       CHECK (estado IN ('DRAFT', 'ACTIVE', 'RETIRED')),
    rounding_rule              TEXT        NOT NULL DEFAULT 'UP_100'
                                       CHECK (rounding_rule IN (
                                           'NONE',
                                           'NEAREST_50',
                                           'NEAREST_100',
                                           'UP_50',
                                           'UP_100'
                                       )),
    vigencia                   TSTZRANGE   NOT NULL DEFAULT tstzrange(now(), NULL, '[)'),
    notas                      TEXT,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_margin_policy_version UNIQUE (codigo, version_label)
);

ALTER TABLE margin_policy_version ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON margin_policy_version
    AS RESTRICTIVE FOR ALL USING (false);

CREATE UNIQUE INDEX uq_margin_policy_active
    ON margin_policy_version (codigo)
    WHERE estado = 'ACTIVE';

CREATE TABLE margin_policy_component (
    id_margin_policy_component UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_margin_policy_version   UUID        NOT NULL REFERENCES margin_policy_version(id_margin_policy_version)
                                           ON DELETE CASCADE,
    tipo_componente            TEXT        NOT NULL CHECK (tipo_componente IN (
                                           'PRODUCTO',
                                           'MARCACION',
                                           'PREPARACION',
                                           'EMPAQUE',
                                           'TRANSPORTE',
                                           'IMPUESTO',
                                           'OTRO'
                                       )),
    pricing_method             TEXT        NOT NULL DEFAULT 'MARGIN'
                                       CHECK (pricing_method IN ('MARGIN', 'MARKUP', 'PASS_THROUGH')),
    target_pct                 NUMERIC(7,4) NOT NULL DEFAULT 0 CHECK (target_pct >= 0 AND target_pct < 100),
    minimum_pct                NUMERIC(7,4) NOT NULL DEFAULT 0 CHECK (minimum_pct >= 0 AND minimum_pct < 100),
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_margin_policy_component UNIQUE (id_margin_policy_version, tipo_componente),
    CONSTRAINT chk_margin_min_le_target CHECK (minimum_pct <= target_pct)
);

ALTER TABLE margin_policy_component ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON margin_policy_component
    AS RESTRICTIVE FOR ALL USING (false);

CREATE TABLE cotizacion_componente (
    id_cotizacion_componente   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cotizacion_item         UUID        NOT NULL REFERENCES cotizacion_item(id_cotizacion_item)
                                           ON DELETE CASCADE,
    tipo_componente            TEXT        NOT NULL CHECK (tipo_componente IN (
                                           'PRODUCTO',
                                           'MARCACION',
                                           'PREPARACION',
                                           'EMPAQUE',
                                           'TRANSPORTE',
                                           'IMPUESTO',
                                           'OTRO'
                                       )),
    descripcion                TEXT        NOT NULL,
    cantidad                   NUMERIC(14,4) NOT NULL CHECK (cantidad >= 0),
    costo_unitario             NUMERIC(14,4) NOT NULL CHECK (costo_unitario >= 0),
    costo_total                NUMERIC(14,2) NOT NULL CHECK (costo_total >= 0),
    pricing_method             TEXT        NOT NULL CHECK (pricing_method IN ('MARGIN', 'MARKUP', 'PASS_THROUGH')),
    margen_aplicado_pct        NUMERIC(7,4) NOT NULL DEFAULT 0,
    precio_resultante          NUMERIC(14,2) NOT NULL CHECK (precio_resultante >= 0),
    source_type                TEXT        NOT NULL CHECK (source_type IN (
                                           'COSTO_PRODUCTO',
                                           'PRECIO_PROVEEDOR_SNAPSHOT',
                                           'PRECIO_TECNICA_SNAPSHOT',
                                           'PRECIO_PRODUCTO',
                                           'MARGIN_POLICY',
                                           'MANUAL',
                                           'NONE'
                                       )),
    source_snapshot_id         UUID,
    metadata                   JSONB       NOT NULL DEFAULT '{}',
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE cotizacion_componente ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON cotizacion_componente AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON cotizacion_componente AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON cotizacion_componente AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON cotizacion_componente
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON cotizacion_componente
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

CREATE INDEX idx_cotizacion_componente_item
    ON cotizacion_componente (id_cotizacion_item, tipo_componente);

REVOKE ALL ON producto_tecnica FROM anon, authenticated;
REVOKE ALL ON margin_policy_version FROM anon, authenticated;
REVOKE ALL ON margin_policy_component FROM anon, authenticated;
REVOKE ALL ON cotizacion_componente FROM anon, authenticated;
GRANT SELECT ON cotizacion_componente TO authenticated;

CREATE OR REPLACE FUNCTION fn_quote_round(
    p_value NUMERIC,
    p_rounding_rule TEXT DEFAULT 'UP_100'
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_increment NUMERIC;
BEGIN
    IF p_value IS NULL THEN
        RETURN NULL;
    END IF;

    IF p_rounding_rule = 'NONE' THEN
        RETURN round(p_value, 2);
    ELSIF p_rounding_rule = 'NEAREST_50' THEN
        v_increment := 50;
        RETURN round(p_value / v_increment) * v_increment;
    ELSIF p_rounding_rule = 'NEAREST_100' THEN
        v_increment := 100;
        RETURN round(p_value / v_increment) * v_increment;
    ELSIF p_rounding_rule = 'UP_50' THEN
        v_increment := 50;
        RETURN ceil(p_value / v_increment) * v_increment;
    ELSIF p_rounding_rule = 'UP_100' THEN
        v_increment := 100;
        RETURN ceil(p_value / v_increment) * v_increment;
    END IF;

    RAISE EXCEPTION 'Unsupported rounding rule: %', p_rounding_rule;
END;
$$;

CREATE OR REPLACE FUNCTION fn_quote_apply_margin(
    p_cost NUMERIC,
    p_pricing_method TEXT,
    p_pct NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_cost IS NULL THEN
        RETURN NULL;
    END IF;

    IF p_pricing_method = 'PASS_THROUGH' THEN
        RETURN p_cost;
    ELSIF p_pricing_method = 'MARKUP' THEN
        RETURN p_cost * (1 + (p_pct / 100));
    ELSIF p_pricing_method = 'MARGIN' THEN
        IF p_pct >= 100 THEN
            RAISE EXCEPTION 'Margin percentage must be lower than 100.';
        END IF;
        RETURN p_cost / (1 - (p_pct / 100));
    END IF;

    RAISE EXCEPTION 'Unsupported pricing method: %', p_pricing_method;
END;
$$;

CREATE OR REPLACE FUNCTION fn_resolve_margin_policy_version(
    p_policy_code TEXT DEFAULT 'MVP_DEFAULT',
    p_at TIMESTAMPTZ DEFAULT now()
)
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
    SELECT mpv.id_margin_policy_version
    FROM margin_policy_version mpv
    WHERE mpv.codigo = p_policy_code
      AND mpv.estado = 'ACTIVE'
      AND mpv.vigencia @> p_at
    ORDER BY lower(mpv.vigencia) DESC
    LIMIT 1
$$;

CREATE OR REPLACE FUNCTION fn_calculate_quote_components(
    p_id_producto UUID,
    p_id_variante UUID DEFAULT NULL,
    p_cantidad INTEGER DEFAULT 1,
    p_id_tecnica UUID DEFAULT NULL,
    p_numero_preparaciones INTEGER DEFAULT 1,
    p_transporte_total NUMERIC DEFAULT 0,
    p_policy_code TEXT DEFAULT 'MVP_DEFAULT',
    p_at TIMESTAMPTZ DEFAULT now(),
    p_moneda TEXT DEFAULT 'COP'
)
RETURNS TABLE (
    tipo_componente TEXT,
    descripcion TEXT,
    cantidad NUMERIC,
    costo_unitario NUMERIC,
    costo_total NUMERIC,
    pricing_method TEXT,
    margen_aplicado_pct NUMERIC,
    precio_resultante NUMERIC,
    source_type TEXT,
    source_snapshot_id UUID,
    metadata JSONB,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id_policy UUID;
    v_rounding_rule TEXT;
    v_cost RECORD;
    v_producto_tecnica RECORD;
    v_qty_produccion INTEGER;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Cantidad invalida'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            '{}'::JSONB, 'INVALID_QUANTITY'::TEXT;
        RETURN;
    END IF;

    SELECT mpv.id_margin_policy_version, mpv.rounding_rule
      INTO v_id_policy, v_rounding_rule
      FROM margin_policy_version mpv
     WHERE mpv.codigo = p_policy_code
       AND mpv.estado = 'ACTIVE'
       AND mpv.vigencia @> p_at
     ORDER BY lower(mpv.vigencia) DESC
     LIMIT 1;

    IF v_id_policy IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Politica de margen no encontrada'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('policy_code', p_policy_code), 'MARGIN_POLICY_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    SELECT *
      INTO v_producto_tecnica
      FROM producto_tecnica pt
     WHERE pt.id_producto = p_id_producto
       AND COALESCE(pt.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
       AND (p_id_tecnica IS NULL OR pt.id_tecnica = p_id_tecnica)
       AND pt.permitida
     ORDER BY (pt.id_variante IS NOT NULL) DESC, pt.created_at DESC
     LIMIT 1;

    IF p_id_tecnica IS NOT NULL AND v_producto_tecnica.id_producto_tecnica IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Tecnica no permitida/configurada para producto'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('id_tecnica', p_id_tecnica), 'PRODUCT_TECHNIQUE_NOT_CONFIGURED'::TEXT;
        RETURN;
    END IF;

    IF v_producto_tecnica.id_producto_tecnica IS NOT NULL
       AND p_cantidad < v_producto_tecnica.cantidad_minima_tecnica THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Cantidad inferior al minimo tecnico'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            jsonb_build_object(
                'cantidad_minima_tecnica', v_producto_tecnica.cantidad_minima_tecnica,
                'id_producto_tecnica', v_producto_tecnica.id_producto_tecnica
            ), 'BELOW_TECHNIQUE_MINIMUM'::TEXT;
        RETURN;
    END IF;

    v_qty_produccion := CEIL(p_cantidad * (1 + COALESCE(v_producto_tecnica.merma_pct, 0) / 100.0));

    SELECT cp.*
      INTO v_cost
      FROM costo_producto cp
     WHERE cp.id_producto = p_id_producto
       AND COALESCE(cp.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
       AND cp.vigencia @> p_at
       AND cp.moneda = p_moneda
     ORDER BY (cp.id_variante IS NOT NULL) DESC, lower(cp.vigencia) DESC
     LIMIT 1;

    IF v_cost.id_costo IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Costo vigente no encontrado'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('moneda', p_moneda), 'COST_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    WITH policy AS (
        SELECT mpc.*
        FROM margin_policy_component mpc
        WHERE mpc.id_margin_policy_version = v_id_policy
    ),
    raw_components AS (
        SELECT
            'PRODUCTO'::TEXT AS tipo_componente,
            'Producto base con merma de produccion'::TEXT AS descripcion,
            v_qty_produccion::NUMERIC AS cantidad,
            v_cost.costo_base::NUMERIC AS costo_unitario,
            (v_cost.costo_base * v_qty_produccion)::NUMERIC AS costo_total,
            'COSTO_PRODUCTO'::TEXT AS source_type,
            v_cost.id_costo AS source_snapshot_id,
            jsonb_build_object(
                'cantidad_cliente', p_cantidad,
                'cantidad_produccion', v_qty_produccion,
                'merma_pct', COALESCE(v_producto_tecnica.merma_pct, 0)
            ) AS metadata
        WHERE v_cost.costo_base > 0

        UNION ALL
        SELECT
            'MARCACION',
            'Marcacion/personalizacion',
            p_cantidad::NUMERIC,
            v_cost.costo_personalizacion::NUMERIC,
            (v_cost.costo_personalizacion * p_cantidad)::NUMERIC,
            'COSTO_PRODUCTO',
            v_cost.id_costo,
            jsonb_build_object(
                'id_tecnica', p_id_tecnica,
                'numero_preparaciones', p_numero_preparaciones,
                'producto_tecnica', v_producto_tecnica.id_producto_tecnica
            )
        WHERE v_cost.costo_personalizacion > 0

        UNION ALL
        SELECT
            'EMPAQUE',
            'Empaque',
            p_cantidad::NUMERIC,
            v_cost.costo_empaque::NUMERIC,
            (v_cost.costo_empaque * p_cantidad)::NUMERIC,
            'COSTO_PRODUCTO',
            v_cost.id_costo,
            '{}'::JSONB
        WHERE v_cost.costo_empaque > 0

        UNION ALL
        SELECT
            'OTRO',
            'Otros costos',
            p_cantidad::NUMERIC,
            v_cost.otros_costos::NUMERIC,
            (v_cost.otros_costos * p_cantidad)::NUMERIC,
            'COSTO_PRODUCTO',
            v_cost.id_costo,
            '{}'::JSONB
        WHERE v_cost.otros_costos > 0

        UNION ALL
        SELECT
            'TRANSPORTE',
            'Transporte',
            1::NUMERIC,
            p_transporte_total::NUMERIC,
            p_transporte_total::NUMERIC,
            'MANUAL',
            NULL::UUID,
            '{}'::JSONB
        WHERE COALESCE(p_transporte_total, 0) > 0
    )
    SELECT
        rc.tipo_componente,
        rc.descripcion,
        rc.cantidad,
        round(rc.costo_unitario, 4) AS costo_unitario,
        round(rc.costo_total, 2) AS costo_total,
        COALESCE(p.pricing_method, 'MARGIN') AS pricing_method,
        COALESCE(p.target_pct, 0) AS margen_aplicado_pct,
        round(fn_quote_apply_margin(
            rc.costo_total,
            COALESCE(p.pricing_method, 'MARGIN'),
            COALESCE(p.target_pct, 0)
        ), 2) AS precio_resultante,
        rc.source_type,
        rc.source_snapshot_id,
        rc.metadata || jsonb_build_object(
            'policy_id', v_id_policy,
            'rounding_rule', v_rounding_rule,
            'minimum_pct', COALESCE(p.minimum_pct, 0)
        ) AS metadata,
        'OK'::TEXT AS status
    FROM raw_components rc
    LEFT JOIN policy p ON p.tipo_componente = rc.tipo_componente
    ORDER BY CASE rc.tipo_componente
        WHEN 'PRODUCTO' THEN 1
        WHEN 'MARCACION' THEN 2
        WHEN 'PREPARACION' THEN 3
        WHEN 'EMPAQUE' THEN 4
        WHEN 'TRANSPORTE' THEN 5
        ELSE 9
    END;
END;
$$;

CREATE OR REPLACE VIEW vw_calculated_quote_summary
WITH (security_invoker = on) AS
SELECT
    NULL::UUID AS id_producto,
    NULL::UUID AS id_variante,
    NULL::INTEGER AS cantidad,
    NULL::TEXT AS nota
WHERE false;

CREATE OR REPLACE VIEW vw_published_price_health
WITH (security_invoker = on) AS
WITH active_policy AS (
    SELECT mpv.id_margin_policy_version
    FROM margin_policy_version mpv
    WHERE mpv.codigo = 'MVP_DEFAULT'
      AND mpv.estado = 'ACTIVE'
      AND mpv.vigencia @> now()
    ORDER BY lower(mpv.vigencia) DESC
    LIMIT 1
),
product_margin AS (
    SELECT COALESCE(mpc.minimum_pct, 0) AS minimum_pct,
           COALESCE(mpc.target_pct, 0) AS target_pct
    FROM margin_policy_component mpc
    JOIN active_policy ap ON ap.id_margin_policy_version = mpc.id_margin_policy_version
    WHERE mpc.tipo_componente = 'PRODUCTO'
)
SELECT
    pp.id_precio,
    pp.id_producto,
    pp.id_variante,
    p.sku,
    pp.quantity_range,
    pp.validity,
    pp.precio_unitario,
    pp.moneda,
    cp.id_costo,
    (cp.costo_base + cp.costo_personalizacion + cp.costo_empaque + cp.otros_costos) AS costo_unitario_actual,
    CASE
        WHEN cp.id_costo IS NULL THEN NULL
        ELSE round(
            ((pp.precio_unitario - (cp.costo_base + cp.costo_personalizacion + cp.costo_empaque + cp.otros_costos))
             / NULLIF(pp.precio_unitario, 0)) * 100,
            2
        )
    END AS margen_actual_pct,
    CASE
        WHEN cp.id_costo IS NULL THEN 'STALE_COST'
        WHEN pp.precio_unitario < (cp.costo_base + cp.costo_personalizacion + cp.costo_empaque + cp.otros_costos)
            THEN 'NEGATIVE_MARGIN'
        WHEN (
            ((pp.precio_unitario - (cp.costo_base + cp.costo_personalizacion + cp.costo_empaque + cp.otros_costos))
             / NULLIF(pp.precio_unitario, 0)) * 100
        ) < (SELECT minimum_pct FROM product_margin)
            THEN 'LOW_MARGIN'
        WHEN NOT (pp.validity @> now())
            THEN 'STALE_PRICE'
        ELSE 'HEALTHY'
    END AS health_status
FROM precio_producto pp
JOIN producto p ON p.id_producto = pp.id_producto
LEFT JOIN LATERAL (
    SELECT cp.*
    FROM costo_producto cp
    WHERE cp.id_producto = pp.id_producto
      AND COALESCE(cp.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
          = COALESCE(pp.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
      AND cp.moneda = pp.moneda
      AND cp.vigencia @> now()
    ORDER BY (cp.id_variante IS NOT NULL) DESC, lower(cp.vigencia) DESC
    LIMIT 1
) cp ON true;

REVOKE ALL ON FUNCTION fn_quote_round(NUMERIC, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_quote_apply_margin(NUMERIC, TEXT, NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_resolve_margin_policy_version(TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION fn_quote_round(NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_quote_apply_margin(NUMERIC, TEXT, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_resolve_margin_policy_version(TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) TO authenticated;

REVOKE ALL ON vw_published_price_health FROM anon, authenticated;
REVOKE ALL ON vw_calculated_quote_summary FROM anon, authenticated;

-- Politica comercial interna inicial. Estos porcentajes son configuracion de
-- trabajo, no promesa al cliente; deben versionarse cuando cambie la politica.
INSERT INTO margin_policy_version (
    id_margin_policy_version, codigo, version_label, estado, rounding_rule, vigencia, notas
) VALUES (
    '00000000-0000-4000-f000-000000000001',
    'MVP_DEFAULT',
    '2026-08-internal',
    'ACTIVE',
    'UP_100',
    '[2026-08-01 00:00:00+00,)'::TSTZRANGE,
    'Politica interna MVP: calcular desde costos, redondear unitario hacia arriba a $100 y no incluir retenciones.'
) ON CONFLICT (codigo, version_label) DO NOTHING;

INSERT INTO margin_policy_component (
    id_margin_policy_component,
    id_margin_policy_version,
    tipo_componente,
    pricing_method,
    target_pct,
    minimum_pct
) VALUES
    ('00000000-0000-4000-f000-000000000011', '00000000-0000-4000-f000-000000000001', 'PRODUCTO', 'MARGIN', 30, 20),
    ('00000000-0000-4000-f000-000000000012', '00000000-0000-4000-f000-000000000001', 'MARCACION', 'MARGIN', 45, 30),
    ('00000000-0000-4000-f000-000000000013', '00000000-0000-4000-f000-000000000001', 'PREPARACION', 'MARGIN', 35, 20),
    ('00000000-0000-4000-f000-000000000014', '00000000-0000-4000-f000-000000000001', 'EMPAQUE', 'MARGIN', 20, 10),
    ('00000000-0000-4000-f000-000000000015', '00000000-0000-4000-f000-000000000001', 'TRANSPORTE', 'PASS_THROUGH', 0, 0),
    ('00000000-0000-4000-f000-000000000016', '00000000-0000-4000-f000-000000000001', 'OTRO', 'MARGIN', 20, 10)
ON CONFLICT (id_margin_policy_version, tipo_componente) DO NOTHING;

COMMENT ON TABLE producto_tecnica IS
    'Relacion producto/variante x tecnica. Define configuracion estandar, minimo tecnico, cantidad recomendada y merma.';

COMMENT ON TABLE margin_policy_version IS
    'Versiones de politica comercial de margen/redondeo. Las cotizaciones deben guardar la version usada.';

COMMENT ON TABLE margin_policy_component IS
    'Margen o markup por componente de costo. Transporte puede pasar sin margen.';

COMMENT ON TABLE cotizacion_componente IS
    'Snapshot de componentes de una cotizacion emitida. Permite explicar costos, margen y fuente sin recalcular historicos.';

COMMENT ON VIEW vw_published_price_health IS
    'Control de salud para tarifas publicadas en precio_producto contra costos vigentes.';

