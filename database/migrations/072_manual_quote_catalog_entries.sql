-- ============================================================
-- 072_manual_quote_catalog_entries.sql
--
-- Alta manual auditada desde el cotizador proveedor-first.
-- Los datos se pueden usar en la cotizacion actual, pero nacen en revision
-- y no sustituyen snapshots historicos ni datos curados.
-- ============================================================

ALTER TABLE proveedor_tecnica_marcacion
    ADD COLUMN IF NOT EXISTS id_proveedor UUID REFERENCES proveedor(id_proveedor);

CREATE INDEX IF NOT EXISTS idx_proveedor_tecnica_id_proveedor
    ON proveedor_tecnica_marcacion (id_proveedor);

COMMENT ON COLUMN proveedor_tecnica_marcacion.id_proveedor IS
    'Vinculo opcional al proveedor maestro cuando la misma empresa tambien vende productos.';

CREATE OR REPLACE FUNCTION public.fn_quote_normalize_code(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT lower(regexp_replace(btrim(COALESCE(p_value, '')), '[^a-zA-Z0-9]+', '_', 'g'));
$function$;

REVOKE ALL ON FUNCTION fn_quote_normalize_code(TEXT) FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_crear_producto_proveedor_manual(
    p_id_proveedor uuid DEFAULT NULL,
    p_nombre_proveedor text DEFAULT NULL,
    p_nombre_producto text DEFAULT NULL,
    p_sku_proveedor text DEFAULT NULL,
    p_categoria text DEFAULT NULL,
    p_precio numeric DEFAULT NULL,
    p_moneda text DEFAULT 'COP',
    p_unidad_compra text DEFAULT 'UNIT',
    p_cantidad_pack numeric DEFAULT NULL,
    p_minimo_compra numeric DEFAULT NULL,
    p_incremento_compra numeric DEFAULT NULL,
    p_url_fuente text DEFAULT NULL,
    p_notas text DEFAULT NULL
)
RETURNS TABLE(
    id_proveedor uuid,
    id_producto_proveedor uuid,
    id_precio_proveedor_snapshot uuid,
    status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_id_proveedor UUID := p_id_proveedor;
    v_id_producto UUID;
    v_id_snapshot UUID;
    v_nombre_proveedor TEXT := NULLIF(btrim(COALESCE(p_nombre_proveedor, '')), '');
    v_nombre_producto TEXT := NULLIF(btrim(COALESCE(p_nombre_producto, '')), '');
    v_unidad TEXT := upper(NULLIF(btrim(COALESCE(p_unidad_compra, 'UNIT')), ''));
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF v_nombre_producto IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'PRODUCT_NAME_REQUIRED'::TEXT;
        RETURN;
    END IF;

    IF p_precio IS NULL OR p_precio <= 0 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'PRICE_REQUIRED'::TEXT;
        RETURN;
    END IF;

    IF v_unidad NOT IN ('UNIT', 'PACK', 'METER', 'CENTIMETER', 'SHEET', 'CUSTOM') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'INVALID_PURCHASE_UNIT'::TEXT;
        RETURN;
    END IF;

    IF v_unidad = 'PACK' AND (p_cantidad_pack IS NULL OR p_cantidad_pack <= 0) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'PACK_QUANTITY_REQUIRED'::TEXT;
        RETURN;
    END IF;

    IF v_id_proveedor IS NULL THEN
        IF v_nombre_proveedor IS NULL THEN
            RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'SUPPLIER_REQUIRED'::TEXT;
            RETURN;
        END IF;

        INSERT INTO proveedor (source_id, nombre, activo)
        VALUES ('manual_cotizador:' || gen_random_uuid()::text, v_nombre_proveedor, true)
        RETURNING proveedor.id_proveedor INTO v_id_proveedor;
    ELSIF NOT EXISTS (SELECT 1 FROM proveedor pr WHERE pr.id_proveedor = v_id_proveedor AND pr.activo) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'SUPPLIER_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    INSERT INTO producto_proveedor (
        id_proveedor, sku_proveedor, nombre_original, categoria, estado_calidad,
        motivo_revision, atributos
    )
    VALUES (
        v_id_proveedor, NULLIF(btrim(COALESCE(p_sku_proveedor, '')), ''),
        v_nombre_producto, NULLIF(btrim(COALESCE(p_categoria, '')), ''),
        'PENDING_REVIEW',
        'Creado manualmente desde cotizador; requiere revision antes de seleccion automatica.',
        jsonb_build_object('origen', 'MANUAL_COTIZADOR', 'creado_por', auth.uid(), 'rol_consola', v_rol)
    )
    RETURNING producto_proveedor.id_producto_proveedor INTO v_id_producto;

    INSERT INTO precio_proveedor_snapshot (
        id_producto_proveedor, precio_publicado, moneda, precio_texto_original,
        visibilidad, disponibilidad, url_fuente, observado_en, unidad_compra,
        cantidad_pack, minimo_compra, incremento_compra, formato_compra,
        precio_vigencia, notas_costeo
    )
    VALUES (
        v_id_producto, p_precio, COALESCE(NULLIF(upper(p_moneda), ''), 'COP'),
        p_precio::text || ' ' || COALESCE(NULLIF(upper(p_moneda), ''), 'COP'),
        'MANUAL_COTIZADOR', 'PENDING_REVIEW', NULLIF(btrim(COALESCE(p_url_fuente, '')), ''),
        now(), v_unidad, p_cantidad_pack, p_minimo_compra, p_incremento_compra,
        jsonb_build_object('origen', 'MANUAL_COTIZADOR', 'creado_por', auth.uid(), 'rol_consola', v_rol),
        tstzrange(now(), NULL, '[)'), NULLIF(btrim(COALESCE(p_notas, '')), '')
    )
    RETURNING precio_proveedor_snapshot.id_snapshot INTO v_id_snapshot;

    RETURN QUERY SELECT v_id_proveedor, v_id_producto, v_id_snapshot, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_producto_proveedor_manual(UUID, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_producto_proveedor_manual(UUID, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_crear_snapshot_tecnica_manual(
    p_id_proveedor_tecnica uuid DEFAULT NULL,
    p_nombre_proveedor_tecnica text DEFAULT NULL,
    p_codigo_tecnica text DEFAULT NULL,
    p_precio numeric DEFAULT NULL,
    p_moneda text DEFAULT 'COP',
    p_billing_unit text DEFAULT 'unidad',
    p_width_cm numeric DEFAULT NULL,
    p_height_cm numeric DEFAULT NULL,
    p_quantity_min integer DEFAULT NULL,
    p_quantity_max integer DEFAULT NULL,
    p_size_label text DEFAULT NULL,
    p_source_url text DEFAULT NULL,
    p_notas text DEFAULT NULL
)
RETURNS TABLE(
    id_tecnica uuid,
    id_proveedor_tecnica uuid,
    id_snapshot uuid,
    status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_codigo TEXT := fn_quote_normalize_code(p_codigo_tecnica);
    v_id_tecnica UUID;
    v_id_proveedor_tecnica UUID := p_id_proveedor_tecnica;
    v_id_snapshot UUID;
    v_nombre_proveedor TEXT := NULLIF(btrim(COALESCE(p_nombre_proveedor_tecnica, '')), '');
    v_unit TEXT := NULLIF(btrim(COALESCE(p_billing_unit, 'unidad')), '');
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF v_codigo IS NULL OR v_codigo = '' THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'TECHNIQUE_CODE_REQUIRED'::TEXT;
        RETURN;
    END IF;

    IF p_precio IS NULL OR p_precio <= 0 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'PRICE_REQUIRED'::TEXT;
        RETURN;
    END IF;

    IF p_quantity_min IS NOT NULL AND p_quantity_min <= 0 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'INVALID_QUANTITY_RANGE'::TEXT;
        RETURN;
    END IF;

    IF p_quantity_max IS NOT NULL AND p_quantity_min IS NOT NULL AND p_quantity_max < p_quantity_min THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'INVALID_QUANTITY_RANGE'::TEXT;
        RETURN;
    END IF;

    INSERT INTO tecnica_marcacion (codigo, verification_status)
    VALUES (v_codigo, 'PENDING_REVIEW')
    ON CONFLICT (codigo) DO UPDATE
        SET verification_status = tecnica_marcacion.verification_status
    RETURNING tecnica_marcacion.id_tecnica INTO v_id_tecnica;

    IF v_id_proveedor_tecnica IS NULL THEN
        IF v_nombre_proveedor IS NULL THEN
            RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'MARKING_SUPPLIER_REQUIRED'::TEXT;
            RETURN;
        END IF;

        INSERT INTO proveedor_tecnica_marcacion (source_id, nombre, activo)
        VALUES ('manual_cotizador:' || gen_random_uuid()::text, v_nombre_proveedor, true)
        RETURNING proveedor_tecnica_marcacion.id_proveedor_tecnica INTO v_id_proveedor_tecnica;
    ELSIF NOT EXISTS (
        SELECT 1 FROM proveedor_tecnica_marcacion ptm
         WHERE ptm.id_proveedor_tecnica = v_id_proveedor_tecnica
           AND ptm.activo
    ) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::UUID, NULL::UUID, 'MARKING_SUPPLIER_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    INSERT INTO precio_tecnica_marcacion_snapshot (
        id_tecnica, id_proveedor_tecnica, observation_id, service_component,
        price_scope, size_label, width_cm, height_cm, quantity_min,
        quantity_max, billing_unit, currency, price_value, condiciones,
        evidence_text, source_url, fetched_at, verification_status,
        formato_costeo
    )
    VALUES (
        v_id_tecnica, v_id_proveedor_tecnica, 'manual_cotizador:' || gen_random_uuid()::text,
        'MANUAL_COTIZADOR', 'solo_marcacion', NULLIF(btrim(COALESCE(p_size_label, '')), ''),
        p_width_cm, p_height_cm, p_quantity_min, p_quantity_max,
        v_unit, COALESCE(NULLIF(upper(p_moneda), ''), 'COP'), p_precio,
        NULLIF(btrim(COALESCE(p_notas, '')), ''),
        NULLIF(btrim(COALESCE(p_notas, '')), ''),
        NULLIF(btrim(COALESCE(p_source_url, '')), ''),
        now(), 'PENDING_REVIEW',
        jsonb_build_object('origen', 'MANUAL_COTIZADOR', 'creado_por', auth.uid(), 'rol_consola', v_rol)
    )
    RETURNING precio_tecnica_marcacion_snapshot.id_snapshot INTO v_id_snapshot;

    INSERT INTO curacion_precio_tecnica_marcacion (
        id_snapshot, usage_status, formula_code, usage_notes, curated_by
    )
    VALUES (
        v_id_snapshot,
        'NEEDS_REVIEW',
        'manual_quote_only',
        'Creado manualmente desde cotizador. Usable en la cotizacion actual si el usuario lo selecciona; requiere aprobacion ADMIN para uso automatico futuro.',
        'manual_cotizador'
    );

    RETURN QUERY SELECT v_id_tecnica, v_id_proveedor_tecnica, v_id_snapshot, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_snapshot_tecnica_manual(UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_snapshot_tecnica_manual(UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER, INTEGER, TEXT, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_producto_proveedor_manual(UUID, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT) IS
    'Crea proveedor/producto/precio proveedor desde cotizador como MANUAL_COTIZADOR/PENDING_REVIEW. El snapshot puede usarse en la cotizacion actual, pero requiere revision para seleccion automatica futura.';

COMMENT ON FUNCTION fn_consola_crear_snapshot_tecnica_manual(UUID, TEXT, TEXT, NUMERIC, TEXT, TEXT, NUMERIC, NUMERIC, INTEGER, INTEGER, TEXT, TEXT, TEXT) IS
    'Crea tecnica/proveedor/snapshot de marcacion desde cotizador como MANUAL_COTIZADOR/PENDING_REVIEW y curacion NEEDS_REVIEW.';
