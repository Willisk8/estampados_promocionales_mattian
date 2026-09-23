-- Cierra lecturas directas de costos y archivos historicos entre roles.
-- Los consumidores comerciales usan las RPC que enmascaran resultados.
DROP POLICY IF EXISTS consola_read ON public.cotizacion_item;
DROP POLICY IF EXISTS consola_read_guard ON public.cotizacion_item;
CREATE POLICY consola_read_admin ON public.cotizacion_item
    FOR SELECT TO authenticated USING (public.fn_consola_rol() = 'ADMIN');
CREATE POLICY consola_read_guard ON public.cotizacion_item AS RESTRICTIVE
    FOR SELECT USING (public.fn_consola_rol() = 'ADMIN');

-- Los eventos de creacion tambien contienen costos y margenes en metadata.
DROP POLICY IF EXISTS consola_read ON public.cotizacion_evento;
DROP POLICY IF EXISTS consola_read_guard ON public.cotizacion_evento;
CREATE POLICY consola_read_admin ON public.cotizacion_evento
    FOR SELECT TO authenticated USING (public.fn_consola_rol() = 'ADMIN');
CREATE POLICY consola_read_guard ON public.cotizacion_evento AS RESTRICTIVE
    FOR SELECT USING (public.fn_consola_rol() = 'ADMIN');

-- Archivos previos de ADMIN contienen correos completos: no pueden firmarse
-- por COMERCIAL/LECTURA. Se aplica en Storage, no solo en la interfaz.
DROP POLICY IF EXISTS consola_read ON public.cotizacion_documento;
DROP POLICY IF EXISTS consola_read_guard ON public.cotizacion_documento;
CREATE POLICY consola_read ON public.cotizacion_documento FOR SELECT TO authenticated
    USING (public.fn_consola_puede_leer() AND
      (public.fn_consola_rol() = 'ADMIN' OR rol_consola <> 'ADMIN'));
CREATE POLICY consola_read_guard ON public.cotizacion_documento AS RESTRICTIVE FOR SELECT
    USING (public.fn_consola_puede_leer() AND
      (public.fn_consola_rol() = 'ADMIN' OR rol_consola <> 'ADMIN'));

DROP POLICY IF EXISTS consola_lee_cotizaciones_pdf ON storage.objects;
-- SECURITY DEFINER consulta tambien registros de ADMIN que la RLS oculta
-- al lector: un archivo oculto nunca debe confundirse con un huerfano.
CREATE OR REPLACE FUNCTION public.fn_quote_pdf_archivo_propio_sin_registro(p_path text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT fn_consola_rol() IN ('ADMIN','COMERCIAL')
      AND split_part(p_path,'/',3) = auth.uid()::text
      AND NOT EXISTS (SELECT 1 FROM cotizacion_documento d WHERE d.storage_path = p_path);
$$;
REVOKE ALL ON FUNCTION public.fn_quote_pdf_archivo_propio_sin_registro(TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fn_quote_pdf_archivo_propio_sin_registro(TEXT) TO authenticated;

CREATE POLICY consola_lee_cotizaciones_pdf ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'cotizaciones-pdf' AND public.fn_consola_puede_leer() AND
      (public.fn_consola_rol() = 'ADMIN' OR public.fn_quote_pdf_archivo_propio_sin_registro(name) OR EXISTS (
        SELECT 1 FROM public.cotizacion_documento d
        WHERE d.storage_path = storage.objects.name AND d.rol_consola <> 'ADMIN'
      )));

-- Cada generacion es un objeto nuevo. Ningun usuario de consola puede
-- reemplazar los bytes de una generacion ya registrada.
DROP POLICY IF EXISTS consola_escribe_cotizaciones_pdf ON storage.objects;
CREATE POLICY consola_escribe_cotizaciones_pdf ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'cotizaciones-pdf'
      AND public.fn_consola_rol() IN ('ADMIN', 'COMERCIAL')
      AND split_part(name, '/', 1) = 'cotizaciones'
      AND split_part(name, '/', 3) = auth.uid()::text
      AND EXISTS (SELECT 1 FROM public.cotizacion c WHERE c.id_cotizacion::text = split_part(name, '/', 2)));
DROP POLICY IF EXISTS consola_actualiza_cotizaciones_pdf ON storage.objects;
CREATE POLICY cotizaciones_pdf_inmutables ON storage.objects AS RESTRICTIVE
    FOR UPDATE TO authenticated
    USING (bucket_id <> 'cotizaciones-pdf') WITH CHECK (bucket_id <> 'cotizaciones-pdf');

CREATE POLICY cotizaciones_pdf_limpieza_fallidos ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'cotizaciones-pdf'
      AND public.fn_quote_pdf_archivo_propio_sin_registro(name));

-- Un documento no puede apuntar a otro archivo ni registrar uno inexistente.
CREATE OR REPLACE FUNCTION public.fn_quote_documento_validar_archivo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
    IF NEW.storage_path NOT LIKE 'cotizaciones/' || NEW.id_cotizacion::text || '/%'
       OR NOT EXISTS (SELECT 1 FROM storage.objects o
                      WHERE o.bucket_id = 'cotizaciones-pdf' AND o.name = NEW.storage_path) THEN
        RAISE EXCEPTION 'El documento requiere un archivo existente de esta cotizacion.';
    END IF;
    IF NEW.tipo_documento = 'PDF_GENERADO'
       AND split_part(NEW.storage_path, '/', 3) IS DISTINCT FROM auth.uid()::text THEN
        RAISE EXCEPTION 'Solo puedes registrar una generacion propia.';
    END IF;
    IF NEW.tipo_documento = 'PDF_ENVIADO' AND NOT EXISTS (
        SELECT 1 FROM cotizacion_documento d WHERE d.storage_path = NEW.storage_path
          AND d.tipo_documento = 'PDF_GENERADO'
          AND (fn_consola_rol() = 'ADMIN' OR d.rol_consola <> 'ADMIN')
    ) THEN
        RAISE EXCEPTION 'No tienes acceso a esta generacion del documento.';
    END IF;
    IF EXISTS (SELECT 1 FROM cotizacion_documento d
               WHERE d.storage_path = NEW.storage_path
                 AND d.tipo_documento = 'PDF_GENERADO')
       AND NEW.tipo_documento = 'PDF_GENERADO' THEN
        RAISE EXCEPTION 'Este archivo ya esta registrado.';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_quote_documento_validar_archivo() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_quote_documento_validar_archivo BEFORE INSERT ON public.cotizacion_documento
    FOR EACH ROW EXECUTE FUNCTION public.fn_quote_documento_validar_archivo();
