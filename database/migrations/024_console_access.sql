-- ============================================================
-- 024_console_access.sql
-- Acceso de lectura para la consola interna (Etapa B).
--
-- PROBLEMA QUE RESUELVE
-- Todas las tablas tienen 'CREATE POLICY deny_all AS RESTRICTIVE FOR ALL
-- USING (false)'. En PostgreSQL las politicas restrictivas se combinan con AND,
-- asi que agregar una politica permisiva de SELECT no desbloquea nada: deny_all
-- sigue evaluando false. Hay que reemplazarla por denegaciones con alcance de
-- comando y una lectura condicionada al perfil del usuario.
--
-- DOS REGIMENES
--   1. Tablas sin datos personales: RLS por perfil + GRANT SELECT directo.
--      La consola las consulta normalmente con la sesion del usuario.
--   2. Tablas con datos personales (canal_contacto, persona,
--      persona_organizacion, contactabilidad, supresion, import_raw_row):
--      conservan deny_all intacto. Solo se leen a traves de funciones
--      SECURITY DEFINER que enmascaran por rol. Ninguna sesion authenticated
--      puede tocarlas directamente, ni siquiera via PostgREST.
--
-- service_role tiene BYPASSRLS, asi que los importadores de scripts/import/
-- siguen funcionando sin cambios.
-- ============================================================

-- ----------------------------------------------------------
-- 0. Requisito: el esquema auth de Supabase
-- ----------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'auth' AND table_name = 'users') THEN
        RAISE EXCEPTION
            'Falta auth.users. En CI ejecuta database/ci/bootstrap_supabase_roles.sql antes de migrar.';
    END IF;
END
$$;

-- ----------------------------------------------------------
-- 1. Perfiles de la consola
-- ----------------------------------------------------------
CREATE TABLE perfil_usuario (
    id_perfil   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    email       TEXT        NOT NULL,
    rol         TEXT        NOT NULL
                CHECK (rol IN ('ADMIN', 'COMERCIAL', 'LECTURA')),
    activo      BOOLEAN     NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_perfil_usuario_user UNIQUE (user_id)
);

ALTER TABLE perfil_usuario ENABLE ROW LEVEL SECURITY;

-- Esta politica compara con auth.uid() directamente y NO usa fn_consola_rol():
-- esa funcion lee esta misma tabla, y usarla aqui crearia recursion de RLS.
CREATE POLICY perfil_propio ON perfil_usuario
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY deny_insert ON perfil_usuario AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON perfil_usuario AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON perfil_usuario AS RESTRICTIVE FOR DELETE USING (false);

CREATE INDEX idx_perfil_usuario_user ON perfil_usuario (user_id);

CREATE TRIGGER trg_perfil_usuario_updated_at
    BEFORE UPDATE ON perfil_usuario
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE perfil_usuario IS
    'Habilita el acceso a la consola interna. Sin fila activa aqui, un usuario '
    'autenticado no ve absolutamente nada. Los perfiles se administran por psql.';

-- ----------------------------------------------------------
-- 2. Funciones de rol
-- ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_consola_rol()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT rol FROM perfil_usuario
     WHERE user_id = auth.uid() AND activo
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION fn_consola_puede_leer()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT fn_consola_rol() IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION fn_consola_rol() FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_consola_puede_leer() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_rol() TO authenticated;
GRANT EXECUTE ON FUNCTION fn_consola_puede_leer() TO authenticated;

-- ----------------------------------------------------------
-- 3. Tablas sin datos personales: lectura por perfil
-- ----------------------------------------------------------
DO $$
DECLARE
    t TEXT;
    tablas_consola TEXT[] := ARRAY[
        'organizacion',
        'proveedor',
        'producto_proveedor',
        'precio_proveedor_snapshot',
        'producto',
        'variante_producto',
        'tecnica_marcacion',
        'proveedor_tecnica_marcacion',
        'precio_tecnica_marcacion_snapshot',
        'import_batch',
        'import_review_item',
        'cat_estado_oportunidad',
        'cat_tipo_organizacion',
        'cat_base_contacto',
        'cat_motivo_supresion'
    ];
BEGIN
    FOREACH t IN ARRAY tablas_consola LOOP
        EXECUTE format('DROP POLICY IF EXISTS deny_all ON public.%I', t);

        -- Las escrituras siguen cerradas para todo rol sin BYPASSRLS.
        EXECUTE format(
            'CREATE POLICY deny_insert ON public.%I AS RESTRICTIVE FOR INSERT WITH CHECK (false)', t);
        EXECUTE format(
            'CREATE POLICY deny_update ON public.%I AS RESTRICTIVE FOR UPDATE USING (false)', t);
        EXECUTE format(
            'CREATE POLICY deny_delete ON public.%I AS RESTRICTIVE FOR DELETE USING (false)', t);

        EXECUTE format(
            'CREATE POLICY consola_read ON public.%I AS PERMISSIVE FOR SELECT '
            'TO authenticated USING (fn_consola_puede_leer())', t);

        -- Restrictiva deliberadamente redundante: impide que una politica
        -- permisiva agregada por descuido en el futuro amplie el acceso.
        EXECUTE format(
            'CREATE POLICY consola_read_guard ON public.%I AS RESTRICTIVE FOR SELECT '
            'USING (fn_consola_puede_leer())', t);

        -- Supabase otorga por defecto todos los privilegios a anon y
        -- authenticated sobre las tablas del esquema public. Hasta ahora solo
        -- deny_all contenia ese acceso; al relajarlo hay que cerrarlo aqui.
        EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    END LOOP;
END
$$;

-- ----------------------------------------------------------
-- 4. Tablas con datos personales: nada cambia, y se verifica
-- ----------------------------------------------------------
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'canal_contacto', 'persona', 'persona_organizacion',
        'contactabilidad', 'supresion', 'import_raw_row'
    ] LOOP
        -- Red de seguridad: si una edicion futura relaja una de estas tablas,
        -- la migracion falla en vez de abrir los datos en silencio.
        IF NOT EXISTS (
            SELECT 1 FROM pg_policies
             WHERE schemaname = 'public' AND tablename = t AND policyname = 'deny_all'
        ) THEN
            RAISE EXCEPTION 'La tabla % debe conservar su politica deny_all.', t;
        END IF;
        EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    END LOOP;
END
$$;

-- Las vistas de elegibilidad exponen correos en crudo. No se otorgan a nadie:
-- siguen siendo accesibles solo por service_role/psql. Esto mantiene el bloqueo
-- de campanas en su sitio.
REVOKE ALL ON vw_campaign_eligibility_queue     FROM anon, authenticated;
REVOKE ALL ON vw_email_quality_classification   FROM anon, authenticated;
REVOKE ALL ON vw_organizacion_contacto_resumen  FROM anon, authenticated;
REVOKE ALL ON vw_import_review_open             FROM anon, authenticated;

-- Esta si es segura: solo agrega sobre proveedores y snapshots, sin PII.
REVOKE ALL ON vw_catalogo_proveedor_quality FROM anon;
GRANT SELECT ON vw_catalogo_proveedor_quality TO authenticated;

-- ----------------------------------------------------------
-- 5. Funciones de lectura de la consola
--
-- Son SECURITY DEFINER porque leen tablas que conservan deny_all. Cada una
-- verifica el perfil antes de devolver nada. Se resuelven como funciones y no
-- como vistas porque una vista security_invoker exigiria GRANT sobre
-- canal_contacto, lo que abriria la tabla entera via PostgREST.
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_consola_resumen()
RETURNS TABLE (
    organizaciones                BIGINT,
    personas                      BIGINT,
    canales_contacto              BIGINT,
    proveedores                   BIGINT,
    productos_proveedor           BIGINT,
    precios_proveedor             BIGINT,
    tecnicas_marcacion            BIGINT,
    precios_marcacion             BIGINT,
    revisiones_abiertas           BIGINT,
    productos_propios_activos     BIGINT,
    productos_propios_borrador    BIGINT,
    precios_comerciales_vigentes  BIGINT,
    organizaciones_sin_tipo       BIGINT,
    ultimo_snapshot_proveedor     TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    RETURN QUERY
    SELECT
        (SELECT count(*) FROM organizacion),
        (SELECT count(*) FROM persona),
        (SELECT count(*) FROM canal_contacto),
        (SELECT count(*) FROM proveedor),
        (SELECT count(*) FROM producto_proveedor),
        (SELECT count(*) FROM precio_proveedor_snapshot),
        (SELECT count(*) FROM tecnica_marcacion),
        (SELECT count(*) FROM precio_tecnica_marcacion_snapshot),
        (SELECT count(*) FROM import_review_item WHERE resolution_status = 'OPEN'),
        (SELECT count(*) FROM producto WHERE estado = 'ACTIVE'),
        (SELECT count(*) FROM producto WHERE estado = 'DRAFT'),
        (SELECT count(*) FROM precio_producto WHERE validity @> now()),
        (SELECT count(*) FROM organizacion WHERE id_tipo_organizacion IS NULL),
        (SELECT max(observado_en) FROM precio_proveedor_snapshot);
END;
$$;

-- Reemplaza a vw_organizacion_contacto_resumen para la consola: entrega los
-- mismos conteos por organizacion sin otorgar acceso a canal_contacto.
CREATE OR REPLACE FUNCTION fn_consola_organizaciones(
    p_busqueda      TEXT    DEFAULT NULL,
    p_departamento  TEXT    DEFAULT NULL,
    p_municipio     TEXT    DEFAULT NULL,
    p_solo_con_email BOOLEAN DEFAULT NULL,
    p_limite        INT     DEFAULT 50,
    p_desplazamiento INT    DEFAULT 0
)
RETURNS TABLE (
    id_organizacion      UUID,
    nit                  TEXT,
    nombre_legal         TEXT,
    nombre_comercial     TEXT,
    tipo_entidad_origen  TEXT,
    departamento         TEXT,
    municipio            TEXT,
    estado               TEXT,
    emails               BIGINT,
    telefonos            BIGINT,
    whatsapps            BIGINT,
    websites             BIGINT,
    total_filas          BIGINT
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
           AND (p_departamento IS NULL OR o.departamento = p_departamento)
           AND (p_municipio IS NULL OR o.municipio = p_municipio)
           AND (p_solo_con_email IS NOT TRUE OR EXISTS (
                    SELECT 1 FROM canal_contacto cc
                     WHERE cc.id_organizacion = o.id_organizacion
                       AND cc.tipo = 'EMAIL' AND cc.estado = 'ACTIVE'))
    ),
    total AS (SELECT count(*) AS n FROM filtradas)
    SELECT
        f.id_organizacion, f.nit, f.nombre_legal, f.nombre_comercial,
        f.tipo_entidad_origen, f.departamento, f.municipio, f.estado,
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'EMAIL'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'TELEFONO'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'WHATSAPP'),
        count(cc.id_canal_contacto) FILTER (WHERE cc.tipo = 'WEBSITE'),
        (SELECT n FROM total)
      FROM filtradas f
      LEFT JOIN canal_contacto cc ON cc.id_organizacion = f.id_organizacion
     GROUP BY f.id_organizacion, f.nit, f.nombre_legal, f.nombre_comercial,
              f.tipo_entidad_origen, f.departamento, f.municipio, f.estado
     ORDER BY f.nombre_legal
     LIMIT v_limite OFFSET greatest(coalesce(p_desplazamiento, 0), 0);
END;
$$;

-- Canales de una organizacion. Los correos van enmascarados salvo para ADMIN.
CREATE OR REPLACE FUNCTION fn_consola_canales_organizacion(p_id_organizacion UUID)
RETURNS TABLE (
    id_canal_contacto     UUID,
    tipo                  TEXT,
    valor                 TEXT,
    enmascarado           BOOLEAN,
    confianza             TEXT,
    estado                TEXT,
    fuente                TEXT,
    base_contacto_codigo  TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    RETURN QUERY
    SELECT
        cc.id_canal_contacto,
        cc.tipo,
        CASE
            WHEN cc.tipo = 'EMAIL' AND v_rol <> 'ADMIN'
                THEN left(split_part(cc.valor_normalizado, '@', 1), 1)
                     || '***@' || split_part(cc.valor_normalizado, '@', 2)
            ELSE cc.valor_normalizado
        END,
        (cc.tipo = 'EMAIL' AND v_rol <> 'ADMIN'),
        cc.confianza,
        cc.estado,
        cc.fuente,
        c.base_contacto_codigo
      FROM canal_contacto cc
      LEFT JOIN LATERAL (
            SELECT ct.base_contacto_codigo
              FROM contactabilidad ct
             WHERE ct.id_canal_contacto = cc.id_canal_contacto
               AND (ct.valido_hasta IS NULL OR ct.valido_hasta > now())
             ORDER BY ct.valido_desde DESC, ct.created_at DESC
             LIMIT 1
      ) c ON true
     WHERE cc.id_organizacion = p_id_organizacion
     ORDER BY cc.tipo, cc.valor_normalizado;
END;
$$;

CREATE OR REPLACE FUNCTION fn_consola_personas_organizacion(p_id_organizacion UUID)
RETURNS TABLE (
    id_persona       UUID,
    nombre_completo  TEXT,
    rol              TEXT,
    cargo            TEXT,
    area             TEXT,
    estado           TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT fn_consola_puede_leer() THEN
        RAISE EXCEPTION 'Sin perfil de consola activo.';
    END IF;

    RETURN QUERY
    SELECT p.id_persona, p.nombre_completo, po.rol, po.cargo, po.area, po.estado
      FROM persona_organizacion po
      JOIN persona p ON p.id_persona = po.id_persona
     WHERE po.id_organizacion = p_id_organizacion
     ORDER BY po.rol, p.nombre_completo;
END;
$$;

-- Cola de revision. Reemplaza a vw_import_review_open para la consola: no
-- devuelve raw_payload ni normalized_payload, que contienen PII cruda.
CREATE OR REPLACE FUNCTION fn_consola_revisiones(
    p_severidad      TEXT DEFAULT NULL,
    p_limite         INT  DEFAULT 50,
    p_desplazamiento INT  DEFAULT 0
)
RETURNS TABLE (
    id_import_review_item UUID,
    severity              TEXT,
    review_reason         TEXT,
    entity_kind           TEXT,
    match_status          TEXT,
    target_table          TEXT,
    target_id             UUID,
    error_message         TEXT,
    row_number            INTEGER,
    source_name           TEXT,
    review_created_at     TIMESTAMPTZ,
    total_filas           BIGINT
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
    WITH abiertas AS (
        SELECT iri.id_import_review_item, iri.severity, iri.review_reason,
               irr.entity_kind, irr.match_status, irr.target_table,
               irr.target_id, irr.error_message, irr.row_number,
               ib.source_name, iri.created_at AS review_created_at
          FROM import_review_item iri
          JOIN import_raw_row irr ON irr.id_import_raw_row = iri.id_import_raw_row
          JOIN import_batch ib    ON ib.id_import_batch = irr.id_import_batch
         WHERE iri.resolution_status = 'OPEN'
           AND (p_severidad IS NULL OR iri.severity = p_severidad)
    ),
    total AS (SELECT count(*) AS n FROM abiertas)
    SELECT a.*, (SELECT n FROM total)
      FROM abiertas a
     ORDER BY
        CASE a.severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
        a.review_created_at
     LIMIT v_limite OFFSET greatest(coalesce(p_desplazamiento, 0), 0);
END;
$$;

-- ----------------------------------------------------------
-- 6. Privilegios de ejecucion
-- ----------------------------------------------------------
DO $$
DECLARE
    f TEXT;
BEGIN
    FOREACH f IN ARRAY ARRAY[
        'fn_consola_resumen()',
        'fn_consola_organizaciones(TEXT, TEXT, TEXT, BOOLEAN, INT, INT)',
        'fn_consola_canales_organizacion(UUID)',
        'fn_consola_personas_organizacion(UUID)',
        'fn_consola_revisiones(TEXT, INT, INT)'
    ] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
    END LOOP;
END
$$;

-- resolve_price sigue fuera del alcance del navegador: la consola de Etapa B
-- no cotiza. No se le otorga EXECUTE a authenticated.
