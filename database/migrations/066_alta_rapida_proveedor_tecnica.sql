-- ============================================================
-- 066_alta_rapida_proveedor_tecnica.sql
--
-- Alta minima de proveedor/tecnica desde el cotizador, sin interrumpir el
-- flujo de armar una cotizacion. No se agrega vocabulario de verificacion
-- nuevo: proveedor no tiene columna de estado (solo `activo`, que ya nace
-- true para cualquier proveedor) y tecnica_marcacion ya tiene
-- verification_status DEFAULT 'PENDING_REVIEW' desde 021 - el registro
-- creado aqui simplemente hereda ese default. La revision humana pasa por
-- /proveedores y /tecnicas, igual que cualquier otro registro.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_crear_proveedor_rapido(
    p_nombre text
)
RETURNS TABLE(id_proveedor uuid, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_nombre TEXT := NULLIF(btrim(p_nombre), '');
    v_id UUID;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear proveedores.';
    END IF;

    IF v_nombre IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, 'INVALID_INPUT'::TEXT;
        RETURN;
    END IF;

    INSERT INTO proveedor (nombre, source_id, activo)
    VALUES (v_nombre, 'MANUAL-' || gen_random_uuid()::text, true)
    RETURNING proveedor.id_proveedor INTO v_id;

    RETURN QUERY SELECT v_id, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_proveedor_rapido(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_proveedor_rapido(TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_proveedor_rapido(TEXT) IS
    'Alta minima de proveedor desde el cotizador. Nace activo, sin columna de verificacion (no existe en el esquema) - la revision pasa por /proveedores.';

CREATE OR REPLACE FUNCTION public.fn_consola_crear_tecnica_rapida(
    p_codigo text
)
RETURNS TABLE(id_tecnica uuid, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_codigo TEXT := NULLIF(btrim(p_codigo), '');
    v_id UUID;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear tecnicas.';
    END IF;

    IF v_codigo IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, 'INVALID_INPUT'::TEXT;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM tecnica_marcacion WHERE codigo = v_codigo) THEN
        RETURN QUERY SELECT NULL::UUID, 'DUPLICATE_CODE'::TEXT;
        RETURN;
    END IF;

    INSERT INTO tecnica_marcacion (codigo)
    VALUES (v_codigo)
    RETURNING tecnica_marcacion.id_tecnica INTO v_id;

    RETURN QUERY SELECT v_id, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_tecnica_rapida(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_tecnica_rapida(TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_tecnica_rapida(TEXT) IS
    'Alta minima de tecnica de marcacion desde el cotizador. verification_status queda en su default (PENDING_REVIEW, 021) - sin snapshot curado, fn_consola_tecnicas_disponibles_producto no la ofrecera hasta que alguien cargue un precio verificado.';
