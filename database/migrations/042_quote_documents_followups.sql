-- ============================================================
-- 042_quote_documents_followups.sql
--
-- Etapa C, Fase 2 — documentos, seguimiento y versionado de cotizacion.
-- Plan: docs/plan_ia.md
--
-- DECISIONES DE ARQUITECTURA
--
-- 1. cotizacion_documento guarda solo la ruta de Supabase Storage, nunca el
--    contenido del PDF. El envio va ligado a id_canal_contacto (no a un
--    correo en texto plano): asi no se crea una superficie de PII nueva
--    fuera de canal_contacto, que es la unica tabla pensada para eso.
--
-- 2. cotizacion_followup es una tabla de trabajo con estado mutable
--    (PENDIENTE/REALIZADO/CANCELADO), no append-only: se actualiza via
--    SECURITY DEFINER, igual que relacion_comercial_organizacion (029).
--    proximo_seguimiento_at NO se guarda en cotizacion: se consulta (mas
--    abajo, vw_cotizacion_vencimiento cubre vencimiento; el proximo
--    seguimiento pendiente se deriva de esta tabla en Fase 4).
--
-- 3. cotizacion_version es un snapshot JSONB de cotizacion + sus items en
--    el momento de revisar, no una fila nueva en cotizacion. cotizacion.numero
--    es BIGSERIAL UNIQUE (029): dos versiones de la MISMA cotizacion no
--    pueden compartir numero como filas separadas sin reabrir esa decision
--    ya aplicada. version_num distingue la version dentro de un mismo
--    id_cotizacion; el numero visible al cliente no cambia entre versiones.
--
-- 4. El vencimiento se expone como vista (vw_cotizacion_vencimiento), no
--    como job. No hay cron en el proyecto (Gate 4 lo tiene pendiente desde
--    022); introducir uno aqui seria una dependencia que nadie opera.
--    Fase 4 (vw_cotizaciones_activas) se apoya en esta vista en vez de
--    recalcular la misma condicion dos veces.
-- ============================================================

-- ----------------------------------------------------------
-- 1. Ampliar el vocabulario de cotizacion_evento
-- ----------------------------------------------------------
ALTER TABLE cotizacion_evento DROP CONSTRAINT cotizacion_evento_tipo_evento_check;

ALTER TABLE cotizacion_evento
    ADD CONSTRAINT cotizacion_evento_tipo_evento_check
        CHECK (tipo_evento IN (
            'CREADA',
            'TRANSICION_ESTADO',
            'PDF_GENERADO',
            'PDF_ENVIADO',
            'SEGUIMIENTO_PROGRAMADO',
            'SEGUIMIENTO_REALIZADO',
            'VENCIMIENTO',
            'VERSION_ARCHIVADA',
            'NOTA'
        ));

-- ----------------------------------------------------------
-- 2. cotizacion_documento
-- ----------------------------------------------------------
CREATE TABLE cotizacion_documento (
    id_cotizacion_documento UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cotizacion           UUID        NOT NULL REFERENCES cotizacion(id_cotizacion) ON DELETE CASCADE,
    tipo_documento          TEXT        NOT NULL CHECK (tipo_documento IN ('PDF_GENERADO', 'PDF_ENVIADO')),
    -- Ruta en Supabase Storage. Nunca el contenido del archivo.
    storage_path            TEXT        NOT NULL,
    -- Solo tiene sentido cuando tipo_documento = PDF_ENVIADO. Se referencia
    -- el canal, no un correo en texto plano: canal_contacto es la unica
    -- tabla pensada para guardar datos de contacto.
    id_canal_contacto       UUID        REFERENCES canal_contacto(id_canal_contacto),
    generado_por            UUID        NOT NULL REFERENCES auth.users(id),
    rol_consola             TEXT        NOT NULL,
    metadata                JSONB       NOT NULL DEFAULT '{}',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_documento_enviado_requiere_canal
        CHECK (tipo_documento <> 'PDF_ENVIADO' OR id_canal_contacto IS NOT NULL)
);

ALTER TABLE cotizacion_documento ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON cotizacion_documento AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON cotizacion_documento AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON cotizacion_documento AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON cotizacion_documento
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON cotizacion_documento
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON cotizacion_documento FROM anon, authenticated;
GRANT SELECT ON cotizacion_documento TO authenticated;

CREATE INDEX idx_cotizacion_documento_cotizacion
    ON cotizacion_documento (id_cotizacion, created_at DESC);

-- ----------------------------------------------------------
-- 3. cotizacion_followup — tabla de trabajo, no append-only
-- ----------------------------------------------------------
CREATE TABLE cotizacion_followup (
    id_cotizacion_followup UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cotizacion          UUID        NOT NULL REFERENCES cotizacion(id_cotizacion) ON DELETE CASCADE,
    fecha_programada       TIMESTAMPTZ NOT NULL,
    estado                 TEXT        NOT NULL DEFAULT 'PENDIENTE'
                          CHECK (estado IN ('PENDIENTE', 'REALIZADO', 'CANCELADO')),
    notas                  TEXT,
    realizado_at           TIMESTAMPTZ,
    programado_por         UUID        NOT NULL REFERENCES auth.users(id),
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE cotizacion_followup ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON cotizacion_followup AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON cotizacion_followup AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON cotizacion_followup AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON cotizacion_followup
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON cotizacion_followup
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON cotizacion_followup FROM anon, authenticated;
GRANT SELECT ON cotizacion_followup TO authenticated;

CREATE INDEX idx_cotizacion_followup_pendientes
    ON cotizacion_followup (fecha_programada)
    WHERE estado = 'PENDIENTE';
CREATE INDEX idx_cotizacion_followup_cotizacion
    ON cotizacion_followup (id_cotizacion, created_at DESC);

CREATE TRIGGER trg_cotizacion_followup_updated_at
    BEFORE UPDATE ON cotizacion_followup
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ----------------------------------------------------------
-- 4. cotizacion_version — snapshot append-only
-- ----------------------------------------------------------
CREATE TABLE cotizacion_version (
    id_cotizacion_version UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cotizacion         UUID        NOT NULL REFERENCES cotizacion(id_cotizacion) ON DELETE CASCADE,
    version_num           INTEGER     NOT NULL CHECK (version_num > 0),
    -- Snapshot completo de cotizacion + cotizacion_item en el momento de
    -- versionar. No se recalcula: es el registro de como se veia entonces.
    snapshot              JSONB       NOT NULL,
    motivo                TEXT,
    creado_por            UUID        NOT NULL REFERENCES auth.users(id),
    rol_consola           TEXT        NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_cotizacion_version UNIQUE (id_cotizacion, version_num)
);

ALTER TABLE cotizacion_version ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_insert ON cotizacion_version AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON cotizacion_version AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON cotizacion_version AS RESTRICTIVE FOR DELETE USING (false);
CREATE POLICY consola_read ON cotizacion_version
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());
CREATE POLICY consola_read_guard ON cotizacion_version
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL ON cotizacion_version FROM anon, authenticated;
GRANT SELECT ON cotizacion_version TO authenticated;

CREATE INDEX idx_cotizacion_version_cotizacion
    ON cotizacion_version (id_cotizacion, version_num DESC);

-- Append-only al nivel del motor, igual que cotizacion_evento (040).
CREATE OR REPLACE FUNCTION fn_cotizacion_version_no_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'cotizacion_version es append-only: crea una version nueva, nunca modifiques una existente';
END;
$$;

CREATE TRIGGER trg_cotizacion_version_no_update
    BEFORE UPDATE ON cotizacion_version
    FOR EACH ROW EXECUTE FUNCTION fn_cotizacion_version_no_update();

CREATE TRIGGER trg_cotizacion_version_no_delete
    BEFORE DELETE ON cotizacion_version
    FOR EACH ROW EXECUTE FUNCTION fn_cotizacion_version_no_update();

-- ----------------------------------------------------------
-- 5. Vencimiento consultable (sin cron)
-- ----------------------------------------------------------
CREATE OR REPLACE VIEW vw_cotizacion_vencimiento
WITH (security_invoker = on) AS
SELECT
    c.id_cotizacion,
    c.numero,
    c.id_organizacion,
    c.estado,
    c.fecha_vencimiento,
    (
        c.fecha_vencimiento IS NOT NULL
        AND c.fecha_vencimiento < now()
        AND c.estado NOT IN ('ACEPTADA', 'RECHAZADA', 'ANULADA', 'CONVERTIDA_A_PEDIDO')
    ) AS esta_vencida
FROM cotizacion c;

REVOKE ALL ON vw_cotizacion_vencimiento FROM anon, authenticated;
GRANT SELECT ON vw_cotizacion_vencimiento TO authenticated;

-- ----------------------------------------------------------
-- 6. Funciones de escritura
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_consola_registrar_documento_cotizacion(
    p_id_cotizacion UUID,
    p_tipo_documento TEXT,
    p_storage_path TEXT,
    p_id_canal_contacto UUID DEFAULT NULL
)
RETURNS TABLE (
    id_cotizacion_documento UUID,
    created_at              TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_id  UUID;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden registrar documentos de cotizacion.';
    END IF;

    IF p_tipo_documento NOT IN ('PDF_GENERADO', 'PDF_ENVIADO') THEN
        RAISE EXCEPTION 'Tipo de documento invalido: %', p_tipo_documento;
    END IF;

    IF p_tipo_documento = 'PDF_ENVIADO' AND p_id_canal_contacto IS NULL THEN
        RAISE EXCEPTION 'PDF_ENVIADO requiere id_canal_contacto.';
    END IF;

    IF nullif(btrim(p_storage_path), '') IS NULL THEN
        RAISE EXCEPTION 'storage_path no puede estar vacio.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = p_id_cotizacion) THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    INSERT INTO cotizacion_documento (
        id_cotizacion, tipo_documento, storage_path, id_canal_contacto,
        generado_por, rol_consola
    )
    VALUES (
        p_id_cotizacion, p_tipo_documento, btrim(p_storage_path), p_id_canal_contacto,
        auth.uid(), v_rol
    )
    RETURNING cotizacion_documento.id_cotizacion_documento INTO v_id;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        p_id_cotizacion, p_tipo_documento, 'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('id_cotizacion_documento', v_id)
    );

    RETURN QUERY
    SELECT cd.id_cotizacion_documento, cd.created_at
      FROM cotizacion_documento cd
     WHERE cd.id_cotizacion_documento = v_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_registrar_documento_cotizacion(UUID, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_registrar_documento_cotizacion(UUID, TEXT, TEXT, UUID) TO authenticated;

CREATE OR REPLACE FUNCTION fn_consola_programar_seguimiento(
    p_id_cotizacion UUID,
    p_fecha_programada TIMESTAMPTZ,
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_cotizacion_followup UUID,
    fecha_programada       TIMESTAMPTZ,
    estado                 TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_id  UUID;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden programar seguimientos.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = p_id_cotizacion) THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    IF p_fecha_programada IS NULL THEN
        RAISE EXCEPTION 'fecha_programada es obligatoria.';
    END IF;

    INSERT INTO cotizacion_followup (
        id_cotizacion, fecha_programada, notas, programado_por
    )
    VALUES (
        p_id_cotizacion, p_fecha_programada, nullif(btrim(p_notas), ''), auth.uid()
    )
    RETURNING cotizacion_followup.id_cotizacion_followup INTO v_id;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, notas, actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        p_id_cotizacion, 'SEGUIMIENTO_PROGRAMADO', nullif(btrim(p_notas), ''),
        'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('id_cotizacion_followup', v_id, 'fecha_programada', p_fecha_programada)
    );

    RETURN QUERY
    SELECT cf.id_cotizacion_followup, cf.fecha_programada, cf.estado
      FROM cotizacion_followup cf
     WHERE cf.id_cotizacion_followup = v_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_programar_seguimiento(UUID, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_programar_seguimiento(UUID, TIMESTAMPTZ, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION fn_consola_completar_seguimiento(
    p_id_cotizacion_followup UUID,
    p_notas TEXT DEFAULT NULL,
    p_cancelado BOOLEAN DEFAULT false
)
RETURNS TABLE (
    id_cotizacion_followup UUID,
    estado                 TEXT,
    realizado_at           TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol           TEXT := fn_consola_rol();
    v_id_cotizacion UUID;
    v_estado_actual TEXT;
    v_estado_nuevo  TEXT := CASE WHEN p_cancelado THEN 'CANCELADO' ELSE 'REALIZADO' END;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden completar seguimientos.';
    END IF;

    SELECT cf.id_cotizacion, cf.estado
      INTO v_id_cotizacion, v_estado_actual
      FROM cotizacion_followup cf
     WHERE cf.id_cotizacion_followup = p_id_cotizacion_followup
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Seguimiento no encontrado.';
    END IF;

    IF v_estado_actual <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'Solo se puede completar un seguimiento PENDIENTE. Estado actual: %', v_estado_actual;
    END IF;

    UPDATE cotizacion_followup cf
       SET estado       = v_estado_nuevo,
           realizado_at = now(),
           notas        = coalesce(nullif(btrim(p_notas), ''), cf.notas)
     WHERE cf.id_cotizacion_followup = p_id_cotizacion_followup;

    IF NOT p_cancelado THEN
        INSERT INTO cotizacion_evento (
            id_cotizacion, tipo_evento, notas, actor_tipo, actor_id, rol_consola, metadata
        )
        VALUES (
            v_id_cotizacion, 'SEGUIMIENTO_REALIZADO', nullif(btrim(p_notas), ''),
            'HUMANO', auth.uid(), v_rol,
            jsonb_build_object('id_cotizacion_followup', p_id_cotizacion_followup)
        );
    END IF;

    RETURN QUERY
    SELECT cf.id_cotizacion_followup, cf.estado, cf.realizado_at
      FROM cotizacion_followup cf
     WHERE cf.id_cotizacion_followup = p_id_cotizacion_followup;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_completar_seguimiento(UUID, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_completar_seguimiento(UUID, TEXT, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION fn_consola_versionar_cotizacion(
    p_id_cotizacion UUID,
    p_motivo TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_cotizacion_version UUID,
    version_num           INTEGER,
    created_at            TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol          TEXT := fn_consola_rol();
    v_snapshot     JSONB;
    v_version_num  INTEGER;
    v_id           UUID;
BEGIN
    IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden versionar cotizaciones.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = p_id_cotizacion) THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    SELECT coalesce(max(cv.version_num), 0) + 1
      INTO v_version_num
      FROM cotizacion_version cv
     WHERE cv.id_cotizacion = p_id_cotizacion;

    SELECT jsonb_build_object(
        'cotizacion', to_jsonb(c.*),
        'items', coalesce(jsonb_agg(to_jsonb(ci.*)) FILTER (WHERE ci.id_cotizacion_item IS NOT NULL), '[]'::jsonb)
    )
      INTO v_snapshot
      FROM cotizacion c
      LEFT JOIN cotizacion_item ci ON ci.id_cotizacion = c.id_cotizacion
     WHERE c.id_cotizacion = p_id_cotizacion
     GROUP BY c.id_cotizacion;

    INSERT INTO cotizacion_version (
        id_cotizacion, version_num, snapshot, motivo, creado_por, rol_consola
    )
    VALUES (
        p_id_cotizacion, v_version_num, v_snapshot, nullif(btrim(p_motivo), ''), auth.uid(), v_rol
    )
    RETURNING cotizacion_version.id_cotizacion_version INTO v_id;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, notas, actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        p_id_cotizacion, 'VERSION_ARCHIVADA', nullif(btrim(p_motivo), ''),
        'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('id_cotizacion_version', v_id, 'version_num', v_version_num)
    );

    RETURN QUERY
    SELECT cv.id_cotizacion_version, cv.version_num, cv.created_at
      FROM cotizacion_version cv
     WHERE cv.id_cotizacion_version = v_id;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_versionar_cotizacion(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_versionar_cotizacion(UUID, TEXT) TO authenticated;

-- ----------------------------------------------------------
-- 7. Documentacion
-- ----------------------------------------------------------
COMMENT ON TABLE cotizacion_documento IS
    'Registro de PDFs generados/enviados. Guarda la ruta en Supabase Storage, nunca el contenido. El envio se referencia por id_canal_contacto, no por correo en texto plano.';

COMMENT ON TABLE cotizacion_followup IS
    'Seguimientos programados sobre una cotizacion. Tabla de trabajo (no append-only): estado transiciona via fn_consola_completar_seguimiento.';

COMMENT ON TABLE cotizacion_version IS
    'Snapshot append-only de cotizacion + cotizacion_item en el momento de revisar. version_num distingue versiones del mismo id_cotizacion; el numero visible al cliente (cotizacion.numero) no cambia entre versiones.';

COMMENT ON VIEW vw_cotizacion_vencimiento IS
    'Vencimiento consultable, no automatico: no hay cron en el proyecto. Fase 4 (vw_cotizaciones_activas) se apoya en esta vista en vez de recalcular la condicion.';
