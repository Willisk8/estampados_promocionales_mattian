-- La comprobacion DNS/buzon pertenece a una direccion concreta, no al canal eterno.
CREATE OR REPLACE FUNCTION public.fn_reset_changed_email_verification()
RETURNS trigger
LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp
AS $$
BEGIN
 IF NEW.tipo IS DISTINCT FROM OLD.tipo
    OR NEW.valor_normalizado IS DISTINCT FROM OLD.valor_normalizado
    OR NEW.valor_original IS DISTINCT FROM OLD.valor_original THEN
   NEW.email_dominio_estado := NULL;
   NEW.email_dominio_verificado_en := NULL;
   NEW.email_buzon_estado := CASE WHEN NEW.tipo='EMAIL' THEN 'NO_VERIFICADO' END;
 END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_reset_changed_email_verification() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_reset_changed_email_verification
BEFORE UPDATE OF tipo,valor_original,valor_normalizado ON public.canal_contacto
FOR EACH ROW EXECUTE FUNCTION public.fn_reset_changed_email_verification();
