-- ============================================================
-- 076_quote_pdf_storage_bucket.sql
--
-- Persistir el PDF de una cotizacion para poder VOLVER A VERLO.
--
-- EL PROBLEMA
--   /cotizador/[id]/pdf renderiza el PDF al vuelo en cada request y lo
--   devuelve como descarga. No queda en ningun lado: quien vuelve a la
--   cotizacion mas tarde no tiene forma de recuperar el documento que ya
--   genero, solo de generar otro a ciegas.
--
-- LO QUE YA EXISTIA (y por eso esta migracion es chica)
--   cotizacion_documento (042) ya tiene el diseno correcto: id_cotizacion,
--   tipo_documento, storage_path, id_canal_contacto, generado_por,
--   rol_consola, metadata. Su RLS ya niega INSERT/UPDATE/DELETE directo y
--   permite SELECT a cualquier perfil de consola activo.
--   fn_consola_registrar_documento_cotizacion (042, endurecida en 046)
--   TAMBIEN ya existe y ya inserta con auth.uid() y fn_consola_rol().
--   Nunca se conecto a ningun flujo real, pero la funcion estaba.
--
-- LO QUE FALTABA DE VERDAD
--   1. El bucket de Storage donde poner el archivo. No existia ninguno para
--      cotizaciones; el unico bucket del proyecto es 'catalogo-proveedor'.
--   2. Poder guardar metadata (numero de cotizacion, bytes, total) junto al
--      documento. La columna metadata existe desde 042 pero la funcion nunca
--      la escribia: quedaba siempre en '{}'.
--
-- POR QUE p_metadata VA AL FINAL Y NO EN CUARTA POSICION
--   La firma vigente es (uuid, text, text, p_id_canal_contacto uuid). Meter
--   p_metadata como cuarto parametro obligaria a mover id_canal_contacto y
--   romperia las llamadas posicionales de database/tests/test_quote_documents.sql,
--   ademas de dejar ambiguo cualquier CALL de 4 argumentos. Agregandolo como
--   QUINTO parametro con default, todas las llamadas existentes siguen
--   resolviendo igual y PostgREST -que invoca por nombre- puede pasar
--   p_metadata sin importar el orden. Se usa DROP + CREATE porque
--   CREATE OR REPLACE no puede agregar parametros: dejaria dos sobrecargas
--   y las llamadas de 3 y 4 argumentos quedarian ambiguas.
--
-- POR QUE EL BUCKET SE CREA EN UNA MIGRACION
--   Es el patron ya establecido en 028 para 'catalogo-proveedor': el bucket y
--   sus policies son parte del esquema, se aplican con el mismo runner y
--   quedan versionados. No hay -ni hace falta- un script aparte que hable con
--   la Admin API de Supabase.
-- ============================================================

-- ----------------------------------------------------------
-- 1. Bucket privado para los PDF de cotizacion
-- ----------------------------------------------------------
-- Privado igual que 'catalogo-proveedor': el PDF lleva precios y datos del
-- cliente, se sirve solo con URL firmada de vida corta desde el servidor.
-- Nunca publico.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'cotizaciones-pdf',
    'cotizaciones-pdf',
    false,
    20971520,                        -- 20 MB por archivo
    ARRAY['application/pdf']
)
ON CONFLICT (id) DO NOTHING;

-- Lectura: cualquier perfil de consola activo. Es lo que habilita firmar la
-- URL de descarga desde el servidor con la sesion del usuario.
DROP POLICY IF EXISTS consola_lee_cotizaciones_pdf ON storage.objects;
CREATE POLICY consola_lee_cotizaciones_pdf ON storage.objects
    FOR SELECT TO authenticated
    USING (bucket_id = 'cotizaciones-pdf' AND public.fn_consola_puede_leer());

-- Escritura: solo quien puede emitir cotizaciones. Mismo par ADMIN/COMERCIAL
-- que fn_consola_registrar_documento_cotizacion, para que no exista el caso
-- de subir el archivo y no poder registrarlo (o al reves).
DROP POLICY IF EXISTS consola_escribe_cotizaciones_pdf ON storage.objects;
CREATE POLICY consola_escribe_cotizaciones_pdf ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'cotizaciones-pdf'
        AND public.fn_consola_rol() IN ('ADMIN', 'COMERCIAL')
    );

-- UPDATE por la misma razon que 053: el cliente de Storage usa upsert para
-- que un reintento no falle a mitad de camino.
DROP POLICY IF EXISTS consola_actualiza_cotizaciones_pdf ON storage.objects;
CREATE POLICY consola_actualiza_cotizaciones_pdf ON storage.objects
    FOR UPDATE TO authenticated
    USING (
        bucket_id = 'cotizaciones-pdf'
        AND public.fn_consola_rol() IN ('ADMIN', 'COMERCIAL')
    )
    WITH CHECK (
        bucket_id = 'cotizaciones-pdf'
        AND public.fn_consola_rol() IN ('ADMIN', 'COMERCIAL')
    );

-- ----------------------------------------------------------
-- 2. metadata en el registro del documento
-- ----------------------------------------------------------
DROP FUNCTION IF EXISTS public.fn_consola_registrar_documento_cotizacion(UUID, TEXT, TEXT, UUID);

CREATE FUNCTION public.fn_consola_registrar_documento_cotizacion(
    p_id_cotizacion    UUID,
    p_tipo_documento   TEXT,
    p_storage_path     TEXT,
    p_id_canal_contacto UUID  DEFAULT NULL,
    p_metadata         JSONB DEFAULT '{}'::jsonb
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
    v_rol      TEXT  := fn_consola_rol();
    v_metadata JSONB := coalesce(p_metadata, '{}'::jsonb);
    v_id       UUID;
BEGIN
    -- v_rol IS NULL cubre la sesion autenticada sin perfil de consola (046).
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
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

    -- Un objeto de jsonb, no un array ni un escalar: metadata se lee despues
    -- por clave y un '[]' o un '3' romperia a quien la consulte.
    IF jsonb_typeof(v_metadata) <> 'object' THEN
        RAISE EXCEPTION 'metadata debe ser un objeto jsonb.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = p_id_cotizacion) THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    INSERT INTO cotizacion_documento (
        id_cotizacion, tipo_documento, storage_path, id_canal_contacto,
        generado_por, rol_consola, metadata
    )
    VALUES (
        p_id_cotizacion, p_tipo_documento, btrim(p_storage_path), p_id_canal_contacto,
        auth.uid(), v_rol, v_metadata
    )
    RETURNING cotizacion_documento.id_cotizacion_documento INTO v_id;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        p_id_cotizacion, p_tipo_documento, 'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('id_cotizacion_documento', v_id) || v_metadata
    );

    RETURN QUERY
    SELECT cd.id_cotizacion_documento, cd.created_at
      FROM cotizacion_documento cd
     WHERE cd.id_cotizacion_documento = v_id;
END;
$$;

REVOKE ALL   ON FUNCTION public.fn_consola_registrar_documento_cotizacion(UUID, TEXT, TEXT, UUID, JSONB) FROM PUBLIC;
REVOKE ALL   ON FUNCTION public.fn_consola_registrar_documento_cotizacion(UUID, TEXT, TEXT, UUID, JSONB) FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_consola_registrar_documento_cotizacion(UUID, TEXT, TEXT, UUID, JSONB) TO authenticated;

COMMENT ON FUNCTION public.fn_consola_registrar_documento_cotizacion(UUID, TEXT, TEXT, UUID, JSONB) IS
    'Registra un PDF de cotizacion ya subido a Storage. Solo ADMIN/COMERCIAL. '
    'Guarda la ruta del bucket cotizaciones-pdf, nunca el contenido. '
    'p_metadata es el ultimo parametro para no romper las llamadas posicionales previas a 076.';
