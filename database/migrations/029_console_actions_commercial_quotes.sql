-- ============================================================
-- 029_console_actions_commercial_quotes.sql
--
-- Acciones controladas para pasar la consola de observacion a operacion
-- interna: resolver revisiones, marcar estado comercial, clasificar tipo de
-- organizacion y emitir cotizaciones con snapshot inmutable.
-- ============================================================

-- ----------------------------------------------------------
-- 1. Auditoria para items de revision
-- ----------------------------------------------------------
CREATE TABLE auditoria_revision_importacion (
    id_auditoria            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_import_review_item   UUID        NOT NULL REFERENCES import_review_item(id_import_review_item),
    estado_anterior         TEXT        NOT NULL,
    estado_nuevo            TEXT        NOT NULL,
    notas                   TEXT,
    resuelto_por            UUID        NOT NULL REFERENCES auth.users(id),
    rol_consola             TEXT        NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE auditoria_revision_importacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON auditoria_revision_importacion AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON auditoria_revision_importacion AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON auditoria_revision_importacion AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON auditoria_revision_importacion
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON auditoria_revision_importacion
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON auditoria_revision_importacion FROM anon, authenticated;
GRANT SELECT ON auditoria_revision_importacion TO authenticated;

CREATE INDEX idx_auditoria_revision_item
    ON auditoria_revision_importacion (id_import_review_item, created_at DESC);

CREATE OR REPLACE FUNCTION fn_consola_resolver_revision(
    p_id_import_review_item UUID,
    p_resolution_status TEXT,
    p_resolution_notes TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_import_review_item UUID,
    resolution_status TEXT,
    resolved_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_user UUID := auth.uid();
    v_estado_anterior TEXT;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden resolver revisiones.';
    END IF;

    IF p_resolution_status NOT IN ('APPROVED', 'REJECTED', 'MERGED', 'IGNORED') THEN
        RAISE EXCEPTION 'Estado de resolucion invalido: %', p_resolution_status;
    END IF;

    SELECT iri.resolution_status
      INTO v_estado_anterior
      FROM import_review_item iri
     WHERE iri.id_import_review_item = p_id_import_review_item
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item de revision no encontrado.';
    END IF;

    IF v_estado_anterior <> 'OPEN' THEN
        RAISE EXCEPTION 'Solo se pueden resolver items OPEN. Estado actual: %', v_estado_anterior;
    END IF;

    UPDATE import_review_item iri
       SET resolution_status = p_resolution_status,
           resolution_notes = nullif(btrim(p_resolution_notes), ''),
           resolved_at = now()
     WHERE iri.id_import_review_item = p_id_import_review_item;

    INSERT INTO auditoria_revision_importacion (
        id_import_review_item, estado_anterior, estado_nuevo, notas,
        resuelto_por, rol_consola
    )
    VALUES (
        p_id_import_review_item, v_estado_anterior, p_resolution_status,
        nullif(btrim(p_resolution_notes), ''), v_user, v_rol
    );

    RETURN QUERY
    SELECT iri.id_import_review_item, iri.resolution_status, iri.resolved_at
      FROM import_review_item iri
     WHERE iri.id_import_review_item = p_id_import_review_item;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_resolver_revision(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_resolver_revision(UUID, TEXT, TEXT) TO authenticated;

-- ----------------------------------------------------------
-- 2. Estado comercial separado de organizacion
-- ----------------------------------------------------------
CREATE TABLE relacion_comercial_organizacion (
    id_organizacion     UUID        PRIMARY KEY REFERENCES organizacion(id_organizacion) ON DELETE CASCADE,
    estado_comercial    TEXT        NOT NULL DEFAULT 'PROSPECTO'
                        CHECK (estado_comercial IN ('PROSPECTO', 'CLIENTE', 'DESCARTADO', 'INACTIVO')),
    prioridad           TEXT        NOT NULL DEFAULT 'MEDIA'
                        CHECK (prioridad IN ('ALTA', 'MEDIA', 'BAJA')),
    notas               TEXT,
    actualizado_por     UUID        REFERENCES auth.users(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE relacion_comercial_organizacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON relacion_comercial_organizacion AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON relacion_comercial_organizacion AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON relacion_comercial_organizacion AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON relacion_comercial_organizacion
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON relacion_comercial_organizacion
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON relacion_comercial_organizacion FROM anon, authenticated;
GRANT SELECT ON relacion_comercial_organizacion TO authenticated;

CREATE TRIGGER trg_relacion_comercial_updated_at
    BEFORE UPDATE ON relacion_comercial_organizacion
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

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

    IF NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
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

-- ----------------------------------------------------------
-- 3. Clasificacion auditable de tipo de organizacion
-- ----------------------------------------------------------
CREATE TABLE auditoria_tipo_organizacion (
    id_auditoria            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_organizacion         UUID        NOT NULL REFERENCES organizacion(id_organizacion) ON DELETE CASCADE,
    id_tipo_anterior        UUID,
    id_tipo_nuevo           UUID        NOT NULL REFERENCES cat_tipo_organizacion(id),
    tipo_entidad_origen     TEXT,
    criterio                TEXT        NOT NULL DEFAULT 'MANUAL',
    clasificado_por         UUID        NOT NULL REFERENCES auth.users(id),
    rol_consola             TEXT        NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE auditoria_tipo_organizacion ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON auditoria_tipo_organizacion AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON auditoria_tipo_organizacion AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON auditoria_tipo_organizacion AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON auditoria_tipo_organizacion
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON auditoria_tipo_organizacion
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON auditoria_tipo_organizacion FROM anon, authenticated;
GRANT SELECT ON auditoria_tipo_organizacion TO authenticated;

CREATE INDEX idx_auditoria_tipo_org
    ON auditoria_tipo_organizacion (id_organizacion, created_at DESC);

CREATE OR REPLACE FUNCTION fn_consola_clasificar_tipo_organizacion(
    p_id_organizacion UUID,
    p_tipo_codigo TEXT,
    p_criterio TEXT DEFAULT 'MANUAL'
)
RETURNS TABLE (
    id_organizacion UUID,
    tipo_codigo TEXT,
    tipo_descripcion TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_tipo_nuevo UUID;
    v_tipo_anterior UUID;
    v_origen TEXT;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden clasificar organizaciones.';
    END IF;

    SELECT id INTO v_tipo_nuevo
      FROM cat_tipo_organizacion
     WHERE codigo = p_tipo_codigo;

    IF v_tipo_nuevo IS NULL THEN
        RAISE EXCEPTION 'Tipo de organizacion invalido: %', p_tipo_codigo;
    END IF;

    SELECT id_tipo_organizacion, tipo_entidad_origen
      INTO v_tipo_anterior, v_origen
      FROM organizacion
     WHERE id_organizacion = p_id_organizacion
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    UPDATE organizacion
       SET id_tipo_organizacion = v_tipo_nuevo
     WHERE id_organizacion = p_id_organizacion;

    INSERT INTO auditoria_tipo_organizacion (
        id_organizacion, id_tipo_anterior, id_tipo_nuevo, tipo_entidad_origen,
        criterio, clasificado_por, rol_consola
    )
    VALUES (
        p_id_organizacion, v_tipo_anterior, v_tipo_nuevo, v_origen,
        coalesce(nullif(btrim(p_criterio), ''), 'MANUAL'), auth.uid(), v_rol
    );

    RETURN QUERY
    SELECT o.id_organizacion, c.codigo, c.descripcion
      FROM organizacion o
      JOIN cat_tipo_organizacion c ON c.id = o.id_tipo_organizacion
     WHERE o.id_organizacion = p_id_organizacion;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_clasificar_tipo_organizacion(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_clasificar_tipo_organizacion(UUID, TEXT, TEXT) TO authenticated;

-- ----------------------------------------------------------
-- 4. Cotizaciones con snapshot inmutable
-- ----------------------------------------------------------
CREATE TABLE cotizacion (
    id_cotizacion       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    numero              BIGSERIAL   UNIQUE,
    id_organizacion     UUID        REFERENCES organizacion(id_organizacion),
    estado              TEXT        NOT NULL DEFAULT 'BORRADOR'
                        CHECK (estado IN ('BORRADOR', 'EMITIDA', 'ANULADA')),
    moneda              TEXT        NOT NULL DEFAULT 'COP',
    total               NUMERIC(14,2) NOT NULL DEFAULT 0,
    creada_por          UUID        NOT NULL REFERENCES auth.users(id),
    rol_consola         TEXT        NOT NULL,
    notas               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cotizacion_item (
    id_cotizacion_item      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cotizacion           UUID        NOT NULL REFERENCES cotizacion(id_cotizacion) ON DELETE CASCADE,
    id_producto             UUID        NOT NULL REFERENCES producto(id_producto),
    id_variante             UUID        REFERENCES variante_producto(id_variante),
    id_precio               UUID        REFERENCES precio_producto(id_precio),
    producto_snapshot       JSONB       NOT NULL,
    cantidad                INTEGER     NOT NULL CHECK (cantidad > 0),
    precio_unitario         NUMERIC(12,2) NOT NULL CHECK (precio_unitario > 0),
    subtotal                NUMERIC(14,2) NOT NULL CHECK (subtotal > 0),
    moneda                  TEXT        NOT NULL DEFAULT 'COP',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE cotizacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE cotizacion_item ENABLE ROW LEVEL SECURITY;

CREATE POLICY deny_insert ON cotizacion AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON cotizacion AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON cotizacion AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON cotizacion
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON cotizacion
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

CREATE POLICY deny_insert ON cotizacion_item AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON cotizacion_item AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON cotizacion_item AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON cotizacion_item
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON cotizacion_item
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON cotizacion FROM anon, authenticated;
REVOKE ALL ON cotizacion_item FROM anon, authenticated;
GRANT SELECT ON cotizacion TO authenticated;
GRANT SELECT ON cotizacion_item TO authenticated;

CREATE INDEX idx_cotizacion_org ON cotizacion (id_organizacion, created_at DESC);
CREATE INDEX idx_cotizacion_item_cotizacion ON cotizacion_item (id_cotizacion);

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
       AND NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    SELECT precio_unitario, moneda, id_precio, status
      INTO v_precio, v_moneda, v_id_precio, v_status
      FROM resolve_price(p_id_producto, p_id_variante, p_cantidad, now(), coalesce(p_moneda, 'COP'));

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

-- ----------------------------------------------------------
-- 5. Reexponer organizaciones con tipo y estado comercial legibles
-- ----------------------------------------------------------
DROP FUNCTION IF EXISTS fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT);

CREATE FUNCTION fn_consola_organizaciones(
    p_busqueda       TEXT    DEFAULT NULL,
    p_departamento   TEXT    DEFAULT NULL,
    p_municipio      TEXT    DEFAULT NULL,
    p_solo_con_email BOOLEAN DEFAULT NULL,
    p_limite         INT     DEFAULT 50,
    p_desplazamiento INT     DEFAULT 0
)
RETURNS TABLE (
    id_organizacion        UUID,
    nit                    TEXT,
    nombre_legal           TEXT,
    nombre_comercial       TEXT,
    tipo_entidad_origen    TEXT,
    tipo_codigo            TEXT,
    tipo_descripcion       TEXT,
    estado_comercial       TEXT,
    prioridad_comercial    TEXT,
    departamento           TEXT,
    municipio              TEXT,
    estado                 TEXT,
    fecha_reporte_oficial  TIMESTAMPTZ,
    anios_desde_reporte    INT,
    emails                 BIGINT,
    telefonos              BIGINT,
    whatsapps              BIGINT,
    websites               BIGINT,
    total_filas            BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_limite INT := least(greatest(coalesce(p_limite, 50), 1), 200);
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    RETURN QUERY
    WITH filtradas AS (
        SELECT o.*
          FROM organizacion o
         WHERE (p_busqueda IS NULL
                OR o.nombre_legal ILIKE '%' || p_busqueda || '%'
                OR o.nombre_comercial ILIKE '%' || p_busqueda || '%'
                OR o.nit = p_busqueda)
           AND (p_departamento IS NULL OR o.departamento ILIKE '%' || p_departamento || '%')
           AND (p_municipio IS NULL OR o.municipio ILIKE '%' || p_municipio || '%')
           AND (p_solo_con_email IS NOT TRUE OR EXISTS (
                    SELECT 1 FROM canal_contacto cc
                     WHERE cc.id_organizacion = o.id_organizacion
                       AND cc.tipo = 'EMAIL' AND cc.estado = 'ACTIVE'))
    ),
    total AS (SELECT count(*) AS n FROM filtradas)
    SELECT
        f.id_organizacion, f.nit, f.nombre_legal, f.nombre_comercial,
        f.tipo_entidad_origen, c.codigo, c.descripcion,
        coalesce(r.estado_comercial, 'PROSPECTO'),
        coalesce(r.prioridad, 'MEDIA'),
        f.departamento, f.municipio, f.estado,
        f.fecha_reporte_oficial,
        CASE
            WHEN f.fecha_reporte_oficial IS NULL THEN NULL
            ELSE date_part('year', age(now(), f.fecha_reporte_oficial))::INT
        END,
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'EMAIL'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'TELEFONO'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'WHATSAPP'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'WEBSITE'),
        (SELECT n FROM total)
      FROM filtradas f
      LEFT JOIN cat_tipo_organizacion c ON c.id = f.id_tipo_organizacion
      LEFT JOIN relacion_comercial_organizacion r ON r.id_organizacion = f.id_organizacion
      LEFT JOIN canal_contacto cc ON cc.id_organizacion = f.id_organizacion
     GROUP BY f.id_organizacion, f.nit, f.nombre_legal, f.nombre_comercial,
              f.tipo_entidad_origen, c.codigo, c.descripcion,
              r.estado_comercial, r.prioridad, f.departamento, f.municipio,
              f.estado, f.fecha_reporte_oficial
     ORDER BY f.nombre_legal
     LIMIT v_limite OFFSET greatest(coalesce(p_desplazamiento, 0), 0);
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT) TO authenticated;
