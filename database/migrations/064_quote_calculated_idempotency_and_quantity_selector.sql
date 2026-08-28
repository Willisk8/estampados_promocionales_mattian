-- ============================================================
-- 064_quote_calculated_idempotency_and_quantity_selector.sql
--
-- Corrige QA-CALC-001 y QA-CALC-002:
-- 1. La idempotencia de cotizacion calculada compara tambien los parametros
--    que alteran calculo/persistencia comercial: preparaciones, transporte,
--    politica de margen y margen override.
-- 2. El selector de tecnicas acepta cantidad y filtra quantity_min/max igual
--    que el nucleo de calculo.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_quote_calculated_payload_matches(
    p_id_cotizacion uuid,
    p_id_organizacion uuid,
    p_id_producto uuid,
    p_id_variante uuid,
    p_cantidad integer,
    p_id_tecnica uuid,
    p_numero_preparaciones integer,
    p_transporte_total numeric,
    p_policy_code text,
    p_margen_override_pct numeric
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(bool_and(
        c.id_organizacion IS NOT DISTINCT FROM p_id_organizacion
        AND ci.id_producto IS NOT DISTINCT FROM p_id_producto
        AND ci.id_variante IS NOT DISTINCT FROM p_id_variante
        AND ci.cantidad IS NOT DISTINCT FROM p_cantidad
        AND ci.id_tecnica IS NOT DISTINCT FROM p_id_tecnica
        AND mpv.codigo IS NOT DISTINCT FROM COALESCE(p_policy_code, 'MVP_DEFAULT')
        AND COALESCE(t.transporte_total, 0) IS NOT DISTINCT FROM COALESCE(p_transporte_total, 0)
        AND COALESCE(prep.numero_preparaciones, 0) IS NOT DISTINCT FROM
            CASE WHEN p_id_tecnica IS NULL THEN 0 ELSE COALESCE(p_numero_preparaciones, 1) END
        AND (ev.metadata->>'margen_override_pct')::numeric IS NOT DISTINCT FROM p_margen_override_pct
    ), false)
      FROM cotizacion c
      JOIN cotizacion_item ci ON ci.id_cotizacion = c.id_cotizacion
      LEFT JOIN margin_policy_version mpv ON mpv.id_margin_policy_version = c.id_margin_policy_version
      LEFT JOIN LATERAL (
          SELECT SUM(cc.precio_resultante) AS transporte_total
            FROM cotizacion_componente cc
           WHERE cc.id_cotizacion_item = ci.id_cotizacion_item
             AND cc.tipo_componente = 'TRANSPORTE'
      ) t ON true
      LEFT JOIN LATERAL (
          SELECT SUM(cc.cantidad)::integer AS numero_preparaciones
            FROM cotizacion_componente cc
           WHERE cc.id_cotizacion_item = ci.id_cotizacion_item
             AND cc.tipo_componente = 'PREPARACION'
      ) prep ON true
      LEFT JOIN LATERAL (
          SELECT ce.metadata
            FROM cotizacion_evento ce
           WHERE ce.id_cotizacion = c.id_cotizacion
             AND ce.tipo_evento = 'CREADA'
           ORDER BY ce.occurred_at ASC
           LIMIT 1
      ) ev ON true
     WHERE c.id_cotizacion = p_id_cotizacion;
$function$;

REVOKE ALL ON FUNCTION fn_quote_calculated_payload_matches(UUID, UUID, UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, NUMERIC)
    FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION fn_quote_calculated_payload_matches(UUID, UUID, UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, NUMERIC) IS
    'Helper interno para idempotencia de cotizacion calculada: compara el payload comercial completo persistido contra el retry. No se otorga a authenticated.';

CREATE OR REPLACE FUNCTION public.fn_consola_crear_cotizacion_calculada(
    p_id_producto uuid,
    p_cantidad integer,
    p_id_organizacion uuid DEFAULT NULL::uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_margen_override_pct numeric DEFAULT NULL::numeric,
    p_notas text DEFAULT NULL::text,
    p_idempotency_key text DEFAULT NULL::text
)
RETURNS TABLE(id_cotizacion uuid, numero bigint, total numeric, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_key TEXT := NULLIF(btrim(p_idempotency_key), '');
    v_id_cotizacion UUID;
    v_numero BIGINT;
    v_total NUMERIC(14,2);
    v_id_item UUID;
    v_comp RECORD;
    v_id_policy UUID;
    v_max_minimum NUMERIC := 0;
    v_below_minimum BOOLEAN := false;
    v_payload_coincide BOOLEAN;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear cotizaciones calculadas.';
    END IF;

    IF v_key IS NOT NULL THEN
        SELECT c.id_cotizacion, c.numero, c.total,
               fn_quote_calculated_payload_matches(
                   c.id_cotizacion, p_id_organizacion, p_id_producto,
                   p_id_variante, p_cantidad, p_id_tecnica,
                   p_numero_preparaciones, p_transporte_total,
                   p_policy_code, p_margen_override_pct
               )
          INTO v_id_cotizacion, v_numero, v_total, v_payload_coincide
          FROM cotizacion c
         WHERE c.creada_por = auth.uid()
           AND c.idempotency_key = v_key
         LIMIT 1;

        IF FOUND THEN
            RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total,
                (CASE WHEN v_payload_coincide THEN 'OK' ELSE 'CONFLICT' END)::TEXT;
            RETURN;
        END IF;
    END IF;

    DROP TABLE IF EXISTS tmp_componentes_calculados;

    CREATE TEMPORARY TABLE tmp_componentes_calculados ON COMMIT DROP AS
    SELECT * FROM fn_quote_calculate_components_core(
        p_id_producto, p_id_variante, p_cantidad, p_id_tecnica, p_numero_preparaciones,
        p_transporte_total, p_policy_code, now(), 'COP', p_margen_override_pct
    );

    IF EXISTS (SELECT 1 FROM tmp_componentes_calculados tc WHERE tc.status <> 'OK') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC,
            (SELECT tc.status FROM tmp_componentes_calculados tc WHERE tc.status <> 'OK' LIMIT 1);
        RETURN;
    END IF;

    SELECT (metadata->>'policy_id')::UUID INTO v_id_policy
      FROM tmp_componentes_calculados
     LIMIT 1;

    IF v_id_policy IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'NO_COMPONENTS'::TEXT;
        RETURN;
    END IF;

    IF p_margen_override_pct IS NOT NULL THEN
        SELECT MAX(minimum_pct) INTO v_max_minimum FROM tmp_componentes_calculados;
        v_below_minimum := p_margen_override_pct < v_max_minimum;

        IF v_below_minimum AND v_rol <> 'ADMIN' THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'MARGIN_BELOW_MINIMUM'::TEXT;
            RETURN;
        END IF;
    END IF;

    SELECT SUM(precio_resultante) INTO v_total FROM tmp_componentes_calculados;

    BEGIN
        INSERT INTO cotizacion (
            id_organizacion, estado, moneda, total, creada_por, rol_consola, notas,
            metodo_precio, id_margin_policy_version, fecha_emision, origen, canal_origen,
            idempotency_key
        )
        VALUES (
            p_id_organizacion, 'EMITIDA', 'COP', v_total,
            auth.uid(), v_rol, nullif(btrim(p_notas), ''),
            'CALCULO_COMPONENTES', v_id_policy, now(), 'CONSOLA', 'INTERNO', v_key
        )
        RETURNING cotizacion.id_cotizacion, cotizacion.numero, cotizacion.total
          INTO v_id_cotizacion, v_numero, v_total;
    EXCEPTION WHEN unique_violation THEN
        IF v_key IS NULL THEN
            RAISE;
        END IF;

        SELECT c.id_cotizacion, c.numero, c.total,
               fn_quote_calculated_payload_matches(
                   c.id_cotizacion, p_id_organizacion, p_id_producto,
                   p_id_variante, p_cantidad, p_id_tecnica,
                   p_numero_preparaciones, p_transporte_total,
                   p_policy_code, p_margen_override_pct
               )
          INTO v_id_cotizacion, v_numero, v_total, v_payload_coincide
          FROM cotizacion c
         WHERE c.creada_por = auth.uid()
           AND c.idempotency_key = v_key
         LIMIT 1;

        IF FOUND THEN
            RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total,
                (CASE WHEN v_payload_coincide THEN 'OK' ELSE 'CONFLICT' END)::TEXT;
            RETURN;
        END IF;

        RAISE;
    END;

    INSERT INTO cotizacion_item (
        id_cotizacion, id_producto, id_variante, cantidad, precio_unitario, subtotal,
        producto_snapshot, id_tecnica
    )
    VALUES (
        v_id_cotizacion, p_id_producto, p_id_variante, p_cantidad,
        round(v_total / p_cantidad, 2), v_total,
        jsonb_build_object('id_producto', p_id_producto, 'capturado_en', now()),
        p_id_tecnica
    )
    RETURNING cotizacion_item.id_cotizacion_item INTO v_id_item;

    FOR v_comp IN SELECT * FROM tmp_componentes_calculados LOOP
        INSERT INTO cotizacion_componente (
            id_cotizacion_item, tipo_componente, descripcion, cantidad, costo_unitario,
            costo_total, pricing_method, margen_aplicado_pct, precio_resultante,
            source_type, source_snapshot_id, metadata
        )
        VALUES (
            v_id_item, v_comp.tipo_componente, v_comp.descripcion, v_comp.cantidad,
            v_comp.costo_unitario, v_comp.costo_total, v_comp.pricing_method,
            v_comp.margen_aplicado_pct, v_comp.precio_resultante,
            v_comp.source_type, v_comp.source_snapshot_id, v_comp.metadata
        );
    END LOOP;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, estado_anterior, estado_nuevo,
        actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        v_id_cotizacion, 'CREADA', NULL, 'EMITIDA',
        'HUMANO', auth.uid(), v_rol,
        jsonb_build_object(
            'metodo_precio', 'CALCULO_COMPONENTES',
            'margen_override_pct', p_margen_override_pct,
            'policy_code', p_policy_code,
            'transporte_total', p_transporte_total,
            'numero_preparaciones', p_numero_preparaciones,
            'idempotency_key', v_key
        )
    );

    RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) IS
    'Crea cotizacion calculada desde costos versionados. Desde 064, reusar idempotency_key con payload distinto en preparaciones/transporte/politica/margen devuelve CONFLICT.';

DROP FUNCTION IF EXISTS fn_consola_tecnicas_disponibles_producto(UUID, UUID);

CREATE OR REPLACE FUNCTION public.fn_consola_tecnicas_disponibles_producto(
    p_id_producto uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_cantidad integer DEFAULT NULL::integer
)
RETURNS TABLE(id_tecnica uuid, codigo text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL', 'LECTURA') THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT DISTINCT tm.id_tecnica, tm.codigo
      FROM producto_tecnica pt
      JOIN tecnica_marcacion tm ON tm.id_tecnica = pt.id_tecnica
      JOIN precio_tecnica_marcacion_snapshot pts ON pts.id_tecnica = pt.id_tecnica
      JOIN curacion_precio_tecnica_marcacion c ON c.id_snapshot = pts.id_snapshot
     WHERE pt.id_producto = p_id_producto
       AND COALESCE(pt.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
       AND pt.permitida
       AND c.usage_status = 'AUTOMATIC_PRICING'
       AND pts.verification_status = 'VERIFIED_PUBLIC_PRICE'
       AND pts.currency = 'COP'
       AND pts.price_value IS NOT NULL
       AND lower(COALESCE(pts.billing_unit, '')) = 'unidad'
       AND (pts.fetched_at IS NULL OR pts.fetched_at <= now())
       AND (p_cantidad IS NULL OR pts.quantity_min IS NULL OR pts.quantity_min <= p_cantidad)
       AND (p_cantidad IS NULL OR pts.quantity_max IS NULL OR pts.quantity_max >= p_cantidad)
     ORDER BY tm.codigo;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID, INTEGER) TO authenticated;

COMMENT ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID, INTEGER) IS
    'Lista tecnicas permitidas para un producto con snapshot curado vigente. Si p_cantidad viene informado, filtra quantity_min/max igual que el nucleo de calculo para evitar MARKING_COST_NOT_FOUND.';

