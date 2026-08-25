-- ============================================================
-- 031_fix_console_action_ambiguous_columns.sql
--
-- Corrige referencias ambiguas en funciones de 029: los nombres de columnas
-- de retorno de RETURNS TABLE existen como variables PL/pgSQL, asi que las
-- columnas reales deben ir calificadas con alias de tabla.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_consola_actualizar_estado_comercial(
    p_id_organizacion UUID,
    p_estado_comercial TEXT,
    p_prioridad TEXT DEFAULT 'MEDIA',
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_organizacion UUID,
    estado_comercial TEXT,
    prioridad TEXT,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden actualizar estado comercial.';
    END IF;

    IF p_estado_comercial NOT IN ('PROSPECTO', 'CLIENTE', 'DESCARTADO', 'INACTIVO') THEN
        RAISE EXCEPTION 'Estado comercial invalido: %', p_estado_comercial;
    END IF;

    IF coalesce(p_prioridad, 'MEDIA') NOT IN ('ALTA', 'MEDIA', 'BAJA') THEN
        RAISE EXCEPTION 'Prioridad invalida: %', p_prioridad;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM organizacion o
         WHERE o.id_organizacion = p_id_organizacion
    ) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    INSERT INTO relacion_comercial_organizacion (
        id_organizacion, estado_comercial, prioridad, notas, actualizado_por
    )
    VALUES (
        p_id_organizacion, p_estado_comercial, coalesce(p_prioridad, 'MEDIA'),
        nullif(btrim(p_notas), ''), auth.uid()
    )
    ON CONFLICT (id_organizacion) DO UPDATE
       SET estado_comercial = EXCLUDED.estado_comercial,
           prioridad = EXCLUDED.prioridad,
           notas = EXCLUDED.notas,
           actualizado_por = EXCLUDED.actualizado_por,
           updated_at = now();

    RETURN QUERY
    SELECT r.id_organizacion, r.estado_comercial, r.prioridad, r.updated_at
      FROM relacion_comercial_organizacion r
     WHERE r.id_organizacion = p_id_organizacion;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_actualizar_estado_comercial(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_actualizar_estado_comercial(UUID, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_consola_crear_cotizacion_simple(
    p_id_organizacion UUID,
    p_id_producto UUID,
    p_id_variante UUID,
    p_cantidad INT,
    p_moneda TEXT DEFAULT 'COP',
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_cotizacion UUID,
    numero BIGINT,
    total NUMERIC,
    status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_precio NUMERIC(12,2);
    v_moneda TEXT;
    v_id_precio UUID;
    v_status TEXT;
    v_id_cotizacion UUID;
    v_numero BIGINT;
    v_snapshot JSONB;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear cotizaciones.';
    END IF;

    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor que cero.';
    END IF;

    IF p_id_organizacion IS NOT NULL
       AND NOT EXISTS (
            SELECT 1
              FROM organizacion o
             WHERE o.id_organizacion = p_id_organizacion
       ) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    SELECT rp.precio_unitario, rp.moneda, rp.id_precio, rp.status
      INTO v_precio, v_moneda, v_id_precio, v_status
      FROM resolve_price(
          p_id_producto, p_id_variante, p_cantidad, now(), coalesce(p_moneda, 'COP')
      ) rp;

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

    INSERT INTO cotizacion (
        id_organizacion, estado, moneda, total, creada_por, rol_consola, notas
    )
    VALUES (
        p_id_organizacion, 'EMITIDA', v_moneda, v_precio * p_cantidad,
        auth.uid(), v_rol, nullif(btrim(p_notas), '')
    )
    RETURNING cotizacion.id_cotizacion, cotizacion.numero
      INTO v_id_cotizacion, v_numero;

    INSERT INTO cotizacion_item (
        id_cotizacion, id_producto, id_variante, id_precio, producto_snapshot,
        cantidad, precio_unitario, subtotal, moneda
    )
    VALUES (
        v_id_cotizacion, p_id_producto, p_id_variante, v_id_precio, v_snapshot,
        p_cantidad, v_precio, v_precio * p_cantidad, v_moneda
    );

    RETURN QUERY SELECT v_id_cotizacion, v_numero, v_precio * p_cantidad, 'OK'::TEXT;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INT, TEXT, TEXT) TO authenticated;
