-- Telefonos separados; dominio de correo no equivale a buzon existente.
-- CRC Circular 127/2020, marcacion nacional 2021; RFC 5321 y 7505.
CREATE OR REPLACE FUNCTION fn_normalize_colombian_phone(p_value TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_digits TEXT := regexp_replace(regexp_replace(coalesce(p_value, ''), '(ext\.?|extension|x)\s*[0-9]{1,8}\s*$', '', 'i'), '[^0-9]', '', 'g');
BEGIN
    IF length(v_digits) = 14 AND v_digits LIKE '0057%' THEN
        RETURN substr(v_digits, 5);
    END IF;
    IF length(v_digits) = 12 AND v_digits LIKE '57%' THEN
        RETURN substr(v_digits, 3);
    END IF;
    IF length(v_digits) = 12
       AND v_digits LIKE '03%'
       AND substr(v_digits, 3, 3) ~ '^(30[0-5]|31[0-9]|32[0-4]|333|35[0-2]|308)$' THEN
        RETURN substr(v_digits, 3);
    END IF;
    IF v_digits ~ '^060[1245678][0-9]{7}$' THEN
        RETURN substr(v_digits, 2);
    END IF;
    RETURN v_digits;
END;
$$;


CREATE OR REPLACE FUNCTION fn_sanitize_canal_contacto()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
    NEW.tipo := upper(btrim(NEW.tipo));

    IF NEW.tipo IN ('TELEFONO', 'WHATSAPP') THEN
        NEW.valor_normalizado := fn_normalize_colombian_phone(
            coalesce(NEW.valor_original, NEW.valor_normalizado)
        );
        NEW.telefono_clasificacion := fn_classify_colombian_phone(NEW.valor_normalizado);

        IF NEW.telefono_clasificacion = 'FIJO' THEN
            NEW.telefono_codigo_area := left(NEW.valor_normalizado, 3);
            NEW.telefono_numero_local := substr(NEW.valor_normalizado, 4);
        ELSE
            NEW.telefono_codigo_area := NULL;
            NEW.telefono_numero_local := NULL;
        END IF;

        IF NEW.telefono_clasificacion = 'INVALIDO' AND NEW.estado = 'ACTIVE' THEN
            NEW.estado := 'INVALID';
        ELSIF NEW.telefono_clasificacion IN (
            'RANGO_NO_ATRIBUIDO', 'FIJO_LOCAL_SIN_INDICATIVO',
            'MOVIL_TRUNKING', 'MOVIL_SATELITAL', 'SERVICIO_COBRO_REVERTIDO'
        ) AND NEW.estado = 'ACTIVE' THEN
            NEW.estado := 'REVIEW_REQUIRED';
        END IF;
    ELSE
        NEW.telefono_clasificacion := NULL;
        NEW.telefono_codigo_area := NULL;
        NEW.telefono_numero_local := NULL;

        IF NEW.tipo = 'EMAIL' THEN
            NEW.valor_normalizado := fn_normalize_email(
                coalesce(NEW.valor_normalizado, NEW.valor_original)
            );
        ELSE
            NEW.valor_normalizado := fn_sanitize_visible_text(
                coalesce(NEW.valor_normalizado, NEW.valor_original)
            );
        END IF;
    END IF;

    NEW.fuente := fn_sanitize_visible_text(NEW.fuente);
    RETURN NEW;
END;
$$;

ALTER TABLE public.canal_contacto
 ADD COLUMN telefono_indicativo_contexto TEXT CHECK (telefono_indicativo_contexto IN ('601','602','604','605','606','607','608')),
 ADD COLUMN telefono_celular TEXT GENERATED ALWAYS AS (
   CASE WHEN tipo IN ('TELEFONO','WHATSAPP') AND telefono_clasificacion IN ('CELULAR','MOVIL_TRUNKING') THEN valor_normalizado END
 ) STORED,
 ADD COLUMN telefono_fijo TEXT GENERATED ALWAYS AS (
   CASE WHEN tipo IN ('TELEFONO','WHATSAPP') AND telefono_clasificacion='FIJO' THEN valor_normalizado
        WHEN tipo IN ('TELEFONO','WHATSAPP') AND telefono_clasificacion='FIJO_LOCAL_SIN_INDICATIVO'
          AND telefono_indicativo_contexto IS NOT NULL THEN telefono_indicativo_contexto || valor_normalizado END
 ) STORED,
 ADD COLUMN email_dominio_estado TEXT CHECK (email_dominio_estado IN ('MX','ADDRESS_FALLBACK','NULL_MX','NXDOMAIN','NO_MAIL','UNKNOWN','INVALID_FORMAT')),
 ADD COLUMN email_dominio_verificado_en TIMESTAMPTZ,
 ADD COLUMN email_buzon_estado TEXT CHECK (email_buzon_estado IN ('NO_VERIFICADO','CONFIRMADO','REBOTADO'));

COMMENT ON COLUMN public.canal_contacto.telefono_indicativo_contexto IS
 'Indicativo inferido del departamento documentado. No demuestra linea activa; conservar REVIEW_REQUIRED.';
COMMENT ON COLUMN public.canal_contacto.email_dominio_estado IS
 'DNS del dominio, nunca evidencia de existencia del buzon. Dominios gratuitos se aceptan.';

CREATE OR REPLACE FUNCTION public.fn_consola_canales_detalle(p_id_organizacion UUID)
RETURNS TABLE (
 id_canal_contacto UUID,tipo TEXT,valor TEXT,enmascarado BOOLEAN,confianza TEXT,
 estado TEXT,fuente TEXT,base_contacto_codigo TEXT,celular TEXT,fijo TEXT,
 indicativo TEXT,numero_local TEXT,indicativo_inferido BOOLEAN,dominio_estado TEXT,buzon_estado TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp
AS $$
BEGIN
 IF NOT public.fn_consola_puede_leer() THEN RAISE EXCEPTION 'Sin perfil de consola activo.'; END IF;
 RETURN QUERY SELECT b.*,cc.telefono_celular,cc.telefono_fijo,
   coalesce(cc.telefono_codigo_area,cc.telefono_indicativo_contexto),
   CASE WHEN cc.telefono_clasificacion='FIJO_LOCAL_SIN_INDICATIVO' THEN cc.valor_normalizado ELSE cc.telefono_numero_local END,
   cc.telefono_clasificacion='FIJO_LOCAL_SIN_INDICATIVO' AND cc.telefono_indicativo_contexto IS NOT NULL,
   cc.email_dominio_estado,cc.email_buzon_estado
 FROM public.fn_consola_canales_organizacion(p_id_organizacion) b
 JOIN public.canal_contacto cc USING(id_canal_contacto);
END;
$$;
REVOKE ALL ON FUNCTION public.fn_consola_canales_detalle(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fn_consola_canales_detalle(UUID) TO authenticated;
