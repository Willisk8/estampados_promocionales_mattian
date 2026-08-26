-- ============================================================
-- 052_sanitize_crm_data_and_validate_colombian_phones.sql
-- Saneamiento visible del CRM y validacion de telefonos de Colombia.
-- Conserva valor_original y los payloads crudos como evidencia.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_sanitize_visible_text(p_value TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_text TEXT;
BEGIN
    v_text := btrim(regexp_replace(coalesce(p_value, ''), '[[:space:][:cntrl:]]+', ' ', 'g'));
    IF char_length(v_text) >= 2 AND (
        (left(v_text, 1) = '"' AND right(v_text, 1) = '"') OR
        (left(v_text, 1) = '''' AND right(v_text, 1) = '''') OR
        (left(v_text, 1) = '“' AND right(v_text, 1) = '”') OR
        (left(v_text, 1) = '‘' AND right(v_text, 1) = '’')
    ) THEN
        v_text := btrim(substr(v_text, 2, char_length(v_text) - 2));
    END IF;
    RETURN v_text;
END;
$$;

CREATE OR REPLACE FUNCTION fn_text_search_key(p_value TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT btrim(
        regexp_replace(
            lower(translate(
                public.fn_sanitize_visible_text(p_value),
                'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç',
                'AAAAAEEEEIIIIOOOOOUUUUNCaaaaaeeeeiiiiooooouuuunc'
            )),
            '[^a-z0-9]+', '_', 'g'
        ),
        '_'
    );
$$;

CREATE OR REPLACE FUNCTION fn_normalize_email(p_value TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
    v_email TEXT := fn_sanitize_visible_text(p_value);
BEGIN
    IF v_email ~ '^[^[:space:]@]+@[^[:space:]@]+$' THEN
        RETURN split_part(v_email, '@', 1) || '@' || lower(split_part(v_email, '@', 2));
    END IF;
    RETURN v_email;
END;
$$;

CREATE OR REPLACE FUNCTION fn_normalize_colombian_phone(p_value TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_digits TEXT := regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g');
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
    RETURN v_digits;
END;
$$;

CREATE OR REPLACE FUNCTION fn_classify_colombian_phone(p_value TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE
        WHEN public.fn_normalize_colombian_phone(p_value) ~ '^60[1245678][0-9]{7}$' THEN 'FIJO'
        WHEN public.fn_normalize_colombian_phone(p_value) ~ '^(30[0-5]|31[0-9]|32[0-4]|333)[0-9]{7}$' THEN 'CELULAR'
        WHEN public.fn_normalize_colombian_phone(p_value) ~ '^35[0-2][0-9]{7}$' THEN 'MOVIL_TRUNKING'
        WHEN public.fn_normalize_colombian_phone(p_value) ~ '^308[0-9]{7}$' THEN 'MOVIL_SATELITAL'
        WHEN public.fn_normalize_colombian_phone(p_value) ~ '^3[0-9]{9}$' THEN 'RANGO_NO_ATRIBUIDO'
        WHEN public.fn_normalize_colombian_phone(p_value) ~ '^01800[0-9]+$' THEN 'SERVICIO_COBRO_REVERTIDO'
        WHEN public.fn_normalize_colombian_phone(p_value) ~ '^[0-9]{7}$' THEN 'FIJO_LOCAL_SIN_INDICATIVO'
        ELSE 'INVALIDO'
    END;
$$;

ALTER TABLE canal_contacto
    ADD COLUMN telefono_clasificacion TEXT,
    ADD COLUMN telefono_codigo_area TEXT,
    ADD COLUMN telefono_numero_local TEXT;

ALTER TABLE organizacion
    ADD COLUMN nombre_legal_busqueda TEXT,
    ADD COLUMN nombre_comercial_busqueda TEXT;

ALTER TABLE persona
    ADD COLUMN nombre_completo_busqueda TEXT;

ALTER TABLE canal_contacto
    ADD CONSTRAINT ck_canal_telefono_clasificacion
        CHECK (
            (tipo NOT IN ('TELEFONO', 'WHATSAPP')
                AND telefono_clasificacion IS NULL
                AND telefono_codigo_area IS NULL
                AND telefono_numero_local IS NULL)
            OR
            (tipo IN ('TELEFONO', 'WHATSAPP')
                AND telefono_clasificacion IN (
                    'FIJO', 'CELULAR', 'MOVIL_TRUNKING', 'MOVIL_SATELITAL',
                    'RANGO_NO_ATRIBUIDO', 'SERVICIO_COBRO_REVERTIDO',
                    'FIJO_LOCAL_SIN_INDICATIVO', 'INVALIDO'
                ))
        );

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
            'MOVIL_TRUNKING', 'MOVIL_SATELITAL'
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

CREATE TRIGGER trg_sanitize_canal_contacto
    BEFORE INSERT OR UPDATE OF tipo, valor_original, valor_normalizado, fuente, estado
    ON canal_contacto
    FOR EACH ROW EXECUTE FUNCTION fn_sanitize_canal_contacto();

CREATE OR REPLACE FUNCTION fn_sanitize_organizacion()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
    NEW.nombre_legal := fn_sanitize_visible_text(NEW.nombre_legal);
    NEW.nombre_comercial := fn_sanitize_visible_text(NEW.nombre_comercial);
    NEW.sigla := fn_sanitize_visible_text(NEW.sigla);
    NEW.tipo_entidad_origen := fn_sanitize_visible_text(NEW.tipo_entidad_origen);
    NEW.departamento := fn_sanitize_visible_text(NEW.departamento);
    NEW.municipio := fn_sanitize_visible_text(NEW.municipio);
    NEW.direccion := fn_sanitize_visible_text(NEW.direccion);
    NEW.fuente_registro := fn_sanitize_visible_text(NEW.fuente_registro);
    NEW.nombre_legal_busqueda := fn_text_search_key(NEW.nombre_legal);
    NEW.nombre_comercial_busqueda := fn_text_search_key(NEW.nombre_comercial);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sanitize_organizacion
    BEFORE INSERT OR UPDATE ON organizacion
    FOR EACH ROW EXECUTE FUNCTION fn_sanitize_organizacion();

CREATE OR REPLACE FUNCTION fn_sanitize_persona()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
    NEW.nombres := fn_sanitize_visible_text(NEW.nombres);
    NEW.apellidos := fn_sanitize_visible_text(NEW.apellidos);
    NEW.nombre_completo := fn_sanitize_visible_text(NEW.nombre_completo);
    NEW.tipo_documento := fn_sanitize_visible_text(NEW.tipo_documento);
    NEW.nombre_completo_busqueda := fn_text_search_key(NEW.nombre_completo);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sanitize_persona
    BEFORE INSERT OR UPDATE ON persona
    FOR EACH ROW EXECUTE FUNCTION fn_sanitize_persona();

CREATE OR REPLACE FUNCTION fn_sanitize_persona_organizacion()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
    NEW.cargo := fn_sanitize_visible_text(NEW.cargo);
    NEW.area := fn_sanitize_visible_text(NEW.area);
    NEW.fuente := fn_sanitize_visible_text(NEW.fuente);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sanitize_persona_organizacion
    BEFORE INSERT OR UPDATE ON persona_organizacion
    FOR EACH ROW EXECUTE FUNCTION fn_sanitize_persona_organizacion();

-- Calcula primero los valores propuestos para poder consolidar formatos
-- duplicados antes de tocar los indices unicos existentes.
CREATE TEMP TABLE tmp_canal_contacto_saneado ON COMMIT DROP AS
SELECT
    cc.id_canal_contacto,
    CASE
        WHEN cc.tipo IN ('TELEFONO', 'WHATSAPP')
            THEN fn_normalize_colombian_phone(coalesce(cc.valor_original, cc.valor_normalizado))
        WHEN cc.tipo = 'EMAIL'
            THEN fn_normalize_email(coalesce(cc.valor_normalizado, cc.valor_original))
        ELSE fn_sanitize_visible_text(coalesce(cc.valor_normalizado, cc.valor_original))
    END AS valor_saneado,
    row_number() OVER (
        PARTITION BY
            cc.id_persona,
            cc.id_organizacion,
            cc.tipo,
            CASE
                WHEN cc.tipo IN ('TELEFONO', 'WHATSAPP')
                    THEN fn_normalize_colombian_phone(coalesce(cc.valor_original, cc.valor_normalizado))
                WHEN cc.tipo = 'EMAIL'
                    THEN fn_normalize_email(coalesce(cc.valor_normalizado, cc.valor_original))
                ELSE fn_sanitize_visible_text(coalesce(cc.valor_normalizado, cc.valor_original))
            END
        ORDER BY cc.created_at, cc.id_canal_contacto
    ) AS orden,
    first_value(cc.id_canal_contacto) OVER (
        PARTITION BY
            cc.id_persona,
            cc.id_organizacion,
            cc.tipo,
            CASE
                WHEN cc.tipo IN ('TELEFONO', 'WHATSAPP')
                    THEN fn_normalize_colombian_phone(coalesce(cc.valor_original, cc.valor_normalizado))
                WHEN cc.tipo = 'EMAIL'
                    THEN fn_normalize_email(coalesce(cc.valor_normalizado, cc.valor_original))
                ELSE fn_sanitize_visible_text(coalesce(cc.valor_normalizado, cc.valor_original))
            END
        ORDER BY cc.created_at, cc.id_canal_contacto
    ) AS id_conservado
FROM canal_contacto cc;

-- Las tres tablas son las FK conocidas hacia canal_contacto al crear esta
-- migracion. Se reasignan antes de eliminar el duplicado de formato.
UPDATE contactabilidad c
   SET id_canal_contacto = t.id_conservado
  FROM tmp_canal_contacto_saneado t
 WHERE t.orden > 1
   AND c.id_canal_contacto = t.id_canal_contacto;

UPDATE interaccion_cliente i
   SET id_canal_contacto = t.id_conservado
  FROM tmp_canal_contacto_saneado t
 WHERE t.orden > 1
   AND i.id_canal_contacto = t.id_canal_contacto;

UPDATE cotizacion_documento d
   SET id_canal_contacto = t.id_conservado
  FROM tmp_canal_contacto_saneado t
 WHERE t.orden > 1
   AND d.id_canal_contacto = t.id_canal_contacto;

DELETE FROM canal_contacto cc
USING tmp_canal_contacto_saneado t
WHERE t.orden > 1
  AND cc.id_canal_contacto = t.id_canal_contacto;

UPDATE organizacion SET nombre_legal = nombre_legal;
UPDATE persona SET nombre_completo = nombre_completo;
UPDATE persona_organizacion SET cargo = cargo;
UPDATE canal_contacto SET valor_normalizado = valor_normalizado;

COMMENT ON COLUMN canal_contacto.telefono_clasificacion IS
    'Clasificacion estructural CRC: fijos geograficos, moviles atribuidos/especiales, servicios y casos de revision.';
COMMENT ON COLUMN canal_contacto.telefono_codigo_area IS
    'Prefijo geografico colombiano de tres digitos (601 a 608), solo para telefonos fijos validos.';
COMMENT ON COLUMN canal_contacto.telefono_numero_local IS
    'Los siete digitos locales de un telefono fijo colombiano valido.';
COMMENT ON FUNCTION fn_sanitize_visible_text(TEXT) IS
    'Conserva Unicode/tildes; quita controles, saltos, espacios repetidos y comillas que envuelven todo el valor.';
COMMENT ON FUNCTION fn_normalize_colombian_phone(TEXT) IS
    'Conserva solo digitos y retira 57, 0057 o el prefijo movil legado 03 cuando corresponde.';

REVOKE ALL ON FUNCTION fn_sanitize_canal_contacto() FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_sanitize_organizacion() FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_sanitize_persona() FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_sanitize_persona_organizacion() FROM PUBLIC;
