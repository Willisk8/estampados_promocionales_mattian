-- ============================================================
-- 061_quote_components_masked_read.sql
--
-- fn_consola_componentes_cotizacion: lectura del desglose de una
-- cotizacion calculada, enmascarada por rol. COMERCIAL puede ver y enviar
-- la cotizacion pero no el costo/margen real -mismo principio que el
-- enmascaramiento de correos para LECTURA (024)-. Nunca confia en el
-- frontend para ocultar el dato: el propio backend devuelve NULL.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_componentes_cotizacion(
    p_id_cotizacion uuid
)
RETURNS TABLE(
    tipo_componente text,
    descripcion text,
    cantidad numeric,
    costo_unitario numeric,
    costo_total numeric,
    margen_aplicado_pct numeric,
    precio_resultante numeric,
    status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL', 'LECTURA') THEN
        RETURN QUERY SELECT
            NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
            NULL::NUMERIC, NULL::NUMERIC, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        cc.tipo_componente,
        cc.descripcion,
        cc.cantidad,
        CASE WHEN v_rol = 'ADMIN' THEN cc.costo_unitario ELSE NULL END,
        CASE WHEN v_rol = 'ADMIN' THEN cc.costo_total ELSE NULL END,
        CASE WHEN v_rol = 'ADMIN' THEN cc.margen_aplicado_pct ELSE NULL END,
        cc.precio_resultante,
        'OK'::TEXT
      FROM cotizacion_componente cc
      JOIN cotizacion_item ci ON ci.id_cotizacion_item = cc.id_cotizacion_item
     WHERE ci.id_cotizacion = p_id_cotizacion
     ORDER BY CASE cc.tipo_componente
        WHEN 'PRODUCTO' THEN 1 WHEN 'MARCACION' THEN 2 WHEN 'PREPARACION' THEN 3
        WHEN 'EMPAQUE' THEN 4 WHEN 'TRANSPORTE' THEN 5 ELSE 9
     END;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_componentes_cotizacion(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_componentes_cotizacion(UUID) TO authenticated;

COMMENT ON FUNCTION fn_consola_componentes_cotizacion(UUID) IS
    'Desglose de una cotizacion calculada, enmascarado por rol: ADMIN ve costo/margen real, COMERCIAL y LECTURA solo ven el precio final. Sin perfil activo devuelve FORBIDDEN, no excepcion.';
