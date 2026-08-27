-- ============================================================
-- 056_quote_simple_idempotency_concurrency.sql
--
-- Completa QA-QUOTE-004: 055 hacia idempotente el retry secuencial, pero
-- una carrera concurrente podia disparar unique_violation entre el SELECT
-- previo y el INSERT. Esta version conserva compatibilidad y devuelve la
-- cotizacion existente cuando el conflicto corresponde a la misma clave.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_crear_cotizacion_simple(
    p_id_organizacion uuid,
    p_id_producto uuid,
    p_id_variante uuid,
    p_cantidad integer,
    p_moneda text DEFAULT 'COP'::text,
    p_notas text DEFAULT NULL::text,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_personalizacion jsonb DEFAULT '{}'::jsonb,
    p_idempotency_key text DEFAULT NULL::text
)
RETURNS TABLE(id_cotizacion uuid, numero bigint, total numeric, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_precio NUMERIC(12,2);
    v_moneda TEXT;
    v_id_precio UUID;
    v_status TEXT;
    v_id_cotizacion UUID;
    v_numero BIGINT;
    v_total NUMERIC(14,2);
    v_snapshot JSONB;
    v_key TEXT := NULLIF(btrim(p_idempotency_key), '');
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear cotizaciones.';
    END IF;

    IF v_key IS NOT NULL THEN
        SELECT c.id_cotizacion, c.numero, c.total
          INTO v_id_cotizacion, v_numero, v_total
          FROM cotizacion c
         WHERE c.creada_por = auth.uid()
           AND c.idempotency_key = v_key
         LIMIT 1;

        IF FOUND THEN
            RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total, 'OK'::TEXT;
            RETURN;
        END IF;
    END IF;

    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor que cero.';
    END IF;

    IF p_id_organizacion IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    IF p_id_tecnica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM tecnica_marcacion WHERE id_tecnica = p_id_tecnica) THEN
        RAISE EXCEPTION 'Tecnica de marcacion no encontrada.';
    END IF;

    SELECT rp.precio_unitario, rp.moneda, rp.id_precio, rp.status
      INTO v_precio, v_moneda, v_id_precio, v_status
      FROM resolve_price(p_id_producto, p_id_variante, p_cantidad, now(), coalesce(p_moneda, 'COP')) AS rp;

    IF v_status <> 'OK' THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_status;
        RETURN;
    END IF;

    SELECT jsonb_build_object(
        'id_producto', p.id_producto,
        'sku', p.sku,
        'producto', p.nombre,
        'estado_producto', p.estado,
        'id_variante', v.id_variante,
        'sku_variante', v.sku_variante,
        'variante', v.nombre,
        'estado_variante', v.estado,
        'id_precio', v_id_precio,
        'cantidad', p_cantidad,
        'moneda', v_moneda,
        'precio_unitario', v_precio,
        'capturado_en', now()
    )
      INTO v_snapshot
      FROM producto p
      LEFT JOIN variante_producto v ON v.id_variante = p_id_variante
     WHERE p.id_producto = p_id_producto;

    BEGIN
        INSERT INTO cotizacion (
            id_organizacion, estado, moneda, total, creada_por, rol_consola, notas,
            metodo_precio, fecha_emision, origen, canal_origen, idempotency_key
        )
        VALUES (
            p_id_organizacion, 'EMITIDA', v_moneda, v_precio * p_cantidad,
            auth.uid(), v_rol, nullif(btrim(p_notas), ''),
            'TARIFA_PUBLICADA', now(), 'CONSOLA', 'INTERNO', v_key
        )
        RETURNING cotizacion.id_cotizacion, cotizacion.numero, cotizacion.total
          INTO v_id_cotizacion, v_numero, v_total;
    EXCEPTION WHEN unique_violation THEN
        IF v_key IS NULL THEN
            RAISE;
        END IF;

        SELECT c.id_cotizacion, c.numero, c.total
          INTO v_id_cotizacion, v_numero, v_total
          FROM cotizacion c
         WHERE c.creada_por = auth.uid()
           AND c.idempotency_key = v_key
         LIMIT 1;

        IF FOUND THEN
            RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total, 'OK'::TEXT;
            RETURN;
        END IF;

        RAISE;
    END;

    INSERT INTO cotizacion_item (
        id_cotizacion, id_producto, id_variante, id_precio, producto_snapshot,
        cantidad, precio_unitario, subtotal, moneda, id_tecnica, personalizacion
    )
    VALUES (
        v_id_cotizacion, p_id_producto, p_id_variante, v_id_precio, v_snapshot,
        p_cantidad, v_precio, v_precio * p_cantidad, v_moneda, p_id_tecnica,
        coalesce(p_personalizacion, '{}'::jsonb)
    );

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, estado_anterior, estado_nuevo,
        actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        v_id_cotizacion, 'CREADA', NULL, 'EMITIDA',
        'HUMANO', auth.uid(), v_rol,
        jsonb_build_object(
            'metodo_precio', 'TARIFA_PUBLICADA',
            'id_precio', v_id_precio,
            'idempotency_key', v_key
        )
    );

    RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INTEGER, TEXT, TEXT, UUID, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INTEGER, TEXT, TEXT, UUID, JSONB, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INTEGER, TEXT, TEXT, UUID, JSONB, TEXT) IS
    'Crea cotizacion simple por tarifa publicada. Desde 056 captura carreras concurrentes de idempotency_key y devuelve la cotizacion existente.';

