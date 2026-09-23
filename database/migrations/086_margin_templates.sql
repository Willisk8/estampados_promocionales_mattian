-- Versioned commercial margin templates. No commercial defaults are seeded.
CREATE TABLE public.plantilla_margen_version (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 codigo TEXT NOT NULL CHECK (codigo ~ '^[A-Z0-9][A-Z0-9_-]{0,63}$'),
 version INTEGER NOT NULL CHECK(version>0),
 estado TEXT NOT NULL DEFAULT 'DRAFT' CHECK(estado IN ('DRAFT','ACTIVE','RETIRED')),
 margen_base NUMERIC NOT NULL CHECK(margen_base>=0 AND margen_base<100),
 tramos JSONB NOT NULL DEFAULT '[]'::jsonb,
 creado_por UUID NOT NULL REFERENCES auth.users(id),
 creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
 publicado_en TIMESTAMPTZ,
 UNIQUE(codigo,version)
);
CREATE UNIQUE INDEX plantilla_margen_un_activo ON public.plantilla_margen_version(codigo) WHERE estado='ACTIVE';
ALTER TABLE public.plantilla_margen_version ENABLE ROW LEVEL SECURITY;
CREATE POLICY deny_all ON public.plantilla_margen_version FOR ALL USING (false) WITH CHECK (false);
REVOKE ALL ON public.plantilla_margen_version FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.fn_validar_plantilla_margen()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE t JSONB; anterior NUMERIC:=0; margen NUMERIC:=NEW.margen_base; cantidad NUMERIC;
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.id<>OLD.id OR NEW.codigo<>OLD.codigo OR NEW.version<>OLD.version OR
     NEW.creado_por<>OLD.creado_por OR NEW.creado_en<>OLD.creado_en THEN
   RAISE EXCEPTION 'La identidad y autoria de la version son inmutables'; END IF;
  IF OLD.estado<>'DRAFT' AND (NEW.margen_base IS DISTINCT FROM OLD.margen_base OR
     NEW.tramos IS DISTINCT FROM OLD.tramos OR NEW.publicado_en IS DISTINCT FROM OLD.publicado_en OR
     NOT (NEW.estado=OLD.estado OR (OLD.estado='ACTIVE' AND NEW.estado='RETIRED'))) THEN
   RAISE EXCEPTION 'Una version publicada es inmutable'; END IF;
 END IF;
 IF NEW.margen_base IS NULL OR NOT (NEW.margen_base>=0 AND NEW.margen_base<100) OR
    jsonb_typeof(NEW.tramos) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Margen o tramos invalidos'; END IF;
 FOR t IN SELECT value FROM jsonb_array_elements(NEW.tramos) LOOP
  IF jsonb_typeof(t) IS DISTINCT FROM 'object' OR jsonb_typeof(t->'desde') IS DISTINCT FROM 'number' OR
     jsonb_typeof(t->'margen') IS DISTINCT FROM 'number' THEN RAISE EXCEPTION 'Cada tramo requiere desde y margen numericos'; END IF;
  cantidad:=(t->>'desde')::numeric;
  IF cantidad<>trunc(cantidad) OR cantidad<=anterior OR cantidad>2147483647 OR
     NOT ((t->>'margen')::numeric>=0 AND (t->>'margen')::numeric<100 AND (t->>'margen')::numeric<=margen) THEN
   RAISE EXCEPTION 'Tramos ascendentes unicos y margenes no crecientes requeridos'; END IF;
  anterior:=cantidad; margen:=(t->>'margen')::numeric;
 END LOOP;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.fn_validar_plantilla_margen() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER validar_plantilla_margen BEFORE INSERT OR UPDATE ON public.plantilla_margen_version
FOR EACH ROW EXECUTE FUNCTION public.fn_validar_plantilla_margen();

CREATE FUNCTION public.fn_consola_plantillas_margen()
RETURNS SETOF public.plantilla_margen_version LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 IF NOT coalesce(public.fn_consola_puede_leer(),false) THEN RAISE EXCEPTION 'Sin acceso'; END IF;
 RETURN QUERY SELECT * FROM public.plantilla_margen_version p
 WHERE public.fn_consola_rol()='ADMIN' OR p.estado IN ('ACTIVE','RETIRED') ORDER BY p.codigo,p.version DESC;
END $$;

CREATE FUNCTION public.fn_consola_guardar_plantilla_margen(p_codigo TEXT,p_margen_base NUMERIC,p_tramos JSONB,p_id UUID DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE resultado UUID; codigo_normal TEXT:=upper(btrim(p_codigo));
BEGIN
 IF public.fn_consola_rol() IS DISTINCT FROM 'ADMIN' THEN RAISE EXCEPTION 'Solo ADMIN puede guardar plantillas'; END IF;
 IF codigo_normal IS NULL OR codigo_normal !~ '^[A-Z0-9][A-Z0-9_-]{0,63}$' THEN RAISE EXCEPTION 'Codigo invalido'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('plantilla_margen:'||codigo_normal,0));
 IF p_id IS NULL THEN
  INSERT INTO public.plantilla_margen_version(codigo,version,margen_base,tramos,creado_por)
  SELECT codigo_normal,coalesce(max(version),0)+1,p_margen_base,p_tramos,auth.uid()
  FROM public.plantilla_margen_version WHERE codigo=codigo_normal RETURNING id INTO resultado;
 ELSE
  UPDATE public.plantilla_margen_version SET margen_base=p_margen_base,tramos=p_tramos
  WHERE id=p_id AND codigo=codigo_normal AND estado='DRAFT' RETURNING id INTO resultado;
  IF resultado IS NULL THEN RAISE EXCEPTION 'Borrador no encontrado; crea una nueva version'; END IF;
 END IF;
 RETURN resultado;
END $$;

CREATE FUNCTION public.fn_consola_publicar_plantilla_margen(p_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE p public.plantilla_margen_version;
BEGIN
 IF public.fn_consola_rol() IS DISTINCT FROM 'ADMIN' THEN RAISE EXCEPTION 'Solo ADMIN puede publicar plantillas'; END IF;
 SELECT * INTO p FROM public.plantilla_margen_version WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Version no encontrada'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('plantilla_margen:'||p.codigo,0));
 SELECT * INTO p FROM public.plantilla_margen_version WHERE id=p_id FOR UPDATE;
 IF p.estado<>'DRAFT' THEN RAISE EXCEPTION 'Solo se publica un borrador'; END IF;
 UPDATE public.plantilla_margen_version SET estado='RETIRED' WHERE codigo=p.codigo AND estado='ACTIVE';
 UPDATE public.plantilla_margen_version SET estado='ACTIVE',publicado_en=now() WHERE id=p_id;
 RETURN p_id;
END $$;
REVOKE ALL ON FUNCTION public.fn_consola_plantillas_margen() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.fn_consola_guardar_plantilla_margen(TEXT,NUMERIC,JSONB,UUID) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.fn_consola_publicar_plantilla_margen(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fn_consola_plantillas_margen() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_consola_guardar_plantilla_margen(TEXT,NUMERIC,JSONB,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_consola_publicar_plantilla_margen(UUID) TO authenticated;
