-- ============================================================
-- 063_tecnicas_disponibles_producto.sql
--
-- Selector para el formulario del cotizador: solo ofrece tecnicas que de
-- verdad se pueden cotizar automatico (mismo filtro que usa
-- fn_quote_calculate_components_core para MARKING_COST_NOT_FOUND), para
-- que el usuario no llene todo el formulario y se encuentre con el error
-- al final.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_tecnicas_disponibles_producto(
    p_id_producto uuid,
    p_id_variante uuid DEFAULT NULL::uuid
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
     ORDER BY tm.codigo;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID) TO authenticated;

COMMENT ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID) IS
    'Lista tecnicas permitidas para un producto que ademas tienen snapshot curado vigente (AUTOMATIC_PRICING + VERIFIED_PUBLIC_PRICE) - para que el selector del cotizador no ofrezca una tecnica que despues fallaria con MARKING_COST_NOT_FOUND.';
