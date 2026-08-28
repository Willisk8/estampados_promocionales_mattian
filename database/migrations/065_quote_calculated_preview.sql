-- ============================================================
-- 065_quote_calculated_preview.sql
--
-- fn_consola_previsualizar_cotizacion_calculada: calcula el desglose de una
-- cotizacion SIN persistir nada, para que ADMIN y COMERCIAL puedan ver el
-- precio final antes de confirmar la emision real.
--
-- Por que existe: el flujo de dos pasos agregado en 062/064 emite la
-- cotizacion real apenas se elige tecnica, sin mostrar el precio antes. Eso
-- evito un defecto real del plan original -su paso de previsualizacion
-- llamaba a fn_calculate_quote_components (058), que es ADMIN-only y habria
-- devuelto FORBIDDEN a COMERCIAL- pero elimino la vista previa por completo,
-- incluso para ADMIN. Esta funcion la restaura sin reintroducir el defecto:
-- envuelve fn_quote_calculate_components_core (060) directamente, con el
-- mismo enmascaramiento por rol que fn_consola_componentes_cotizacion (061)
-- en vez del guardia ADMIN-only de 058.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_previsualizar_cotizacion_calculada(
    p_id_producto uuid,
    p_cantidad integer,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_margen_override_pct numeric DEFAULT NULL::numeric
)
RETURNS TABLE(
    tipo_componente text,
    descripcion text,
    cantidad numeric,
    costo_unitario numeric,
    costo_total numeric,
    margen_aplicado_pct numeric,
    minimum_pct numeric,
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
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RETURN QUERY SELECT
            NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
            NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        tc.tipo_componente,
        tc.descripcion,
        tc.cantidad,
        CASE WHEN v_rol = 'ADMIN' THEN tc.costo_unitario ELSE NULL END,
        CASE WHEN v_rol = 'ADMIN' THEN tc.costo_total ELSE NULL END,
        CASE WHEN v_rol = 'ADMIN' THEN tc.margen_aplicado_pct ELSE NULL END,
        CASE WHEN v_rol = 'ADMIN' THEN tc.minimum_pct ELSE NULL END,
        tc.precio_resultante,
        tc.status
      FROM fn_quote_calculate_components_core(
          p_id_producto, p_id_variante, p_cantidad, p_id_tecnica, p_numero_preparaciones,
          p_transporte_total, p_policy_code, now(), 'COP', p_margen_override_pct
      ) tc
     ORDER BY CASE tc.tipo_componente
        WHEN 'PRODUCTO' THEN 1 WHEN 'MARCACION' THEN 2 WHEN 'PREPARACION' THEN 3
        WHEN 'EMPAQUE' THEN 4 WHEN 'TRANSPORTE' THEN 5 ELSE 9
     END;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_previsualizar_cotizacion_calculada(UUID, INTEGER, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_previsualizar_cotizacion_calculada(UUID, INTEGER, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC) TO authenticated;

COMMENT ON FUNCTION fn_consola_previsualizar_cotizacion_calculada(UUID, INTEGER, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC) IS
    'Calcula el desglose de una cotizacion sin persistir nada, enmascarado por rol igual que fn_consola_componentes_cotizacion. Sin perfil ADMIN/COMERCIAL devuelve FORBIDDEN, no excepcion. Usa el mismo nucleo (fn_quote_calculate_components_core) que fn_consola_crear_cotizacion_calculada para que el precio previsualizado coincida exactamente con el que se persiste despues.';
