-- ============================================================
-- 019_channel_scoped_campaign_eligibility.sql
-- Corrige STAGING cuando 018 ya fue aplicada antes del fix AUD-005.
--
-- La elegibilidad comercial se evalua por id_canal_contacto.
-- email_hash solo se usa para supresion global; no debe propagar
-- consentimiento entre organizaciones/canales que comparten correo.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_email_eligible_for_campaign(
    p_email_hash TEXT
)
RETURNS TABLE (
    eligible BOOLEAN,
    reason   TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_email_hash IS NULL OR btrim(p_email_hash) = '' THEN
        RETURN QUERY SELECT false, 'EMAIL_HASH_REQUIRED';
        RETURN;
    END IF;

    -- Deprecated intentionally: campaign eligibility is scoped to
    -- canal_contacto, while email_hash is only global for supresion.
    -- Using only the hash can leak consent from one organization/channel to
    -- another duplicated email. Call fn_email_eligible_for_campaign(UUID).
    RETURN QUERY SELECT false, 'EMAIL_HASH_LOOKUP_DEPRECATED';
END;
$$;

CREATE OR REPLACE FUNCTION fn_email_eligible_for_campaign(
    p_id_canal_contacto UUID
)
RETURNS TABLE (
    eligible BOOLEAN,
    reason   TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_email_hash TEXT;
    v_channel_estado TEXT;
    v_channel_tipo TEXT;
    v_has_suppression BOOLEAN;
    v_effective_base TEXT;
BEGIN
    IF p_id_canal_contacto IS NULL THEN
        RETURN QUERY SELECT false, 'CHANNEL_REQUIRED';
        RETURN;
    END IF;

    SELECT cc.email_hash, cc.estado, cc.tipo
      INTO v_email_hash, v_channel_estado, v_channel_tipo
    FROM canal_contacto cc
    WHERE cc.id_canal_contacto = p_id_canal_contacto;

    IF NOT FOUND OR v_channel_tipo <> 'EMAIL' THEN
        RETURN QUERY SELECT false, 'EMAIL_CHANNEL_NOT_FOUND';
        RETURN;
    END IF;

    IF v_channel_estado <> 'ACTIVE' THEN
        RETURN QUERY SELECT false, 'CHANNEL_NOT_ACTIVE';
        RETURN;
    END IF;

    IF v_email_hash IS NULL OR btrim(v_email_hash) = '' THEN
        RETURN QUERY SELECT false, 'EMAIL_HASH_REQUIRED';
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM supresion s
        WHERE s.tipo = 'EMAIL'
          AND s.valor_hash = v_email_hash
    ) INTO v_has_suppression;

    IF v_has_suppression THEN
        RETURN QUERY SELECT false, 'SUPPRESSED';
        RETURN;
    END IF;

    SELECT c.base_contacto_codigo
      INTO v_effective_base
    FROM contactabilidad c
    WHERE c.id_canal_contacto = p_id_canal_contacto
      AND c.valido_desde <= now()
      AND (c.valido_hasta IS NULL OR c.valido_hasta > now())
    ORDER BY c.valido_desde DESC, c.created_at DESC
    LIMIT 1;

    IF v_effective_base IN (
        'CONSENTIMIENTO_EXPRESO',
        'RELACION_COMERCIAL_PREVIA',
        'SOLICITUD_DEL_TITULAR'
    ) THEN
        RETURN QUERY SELECT true, 'ELIGIBLE';
        RETURN;
    END IF;

    RETURN QUERY SELECT false, 'CONTACTABILITY_NOT_CONFIRMED';
END;
$$;

REVOKE ALL ON FUNCTION fn_email_eligible_for_campaign(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_email_eligible_for_campaign(TEXT) FROM anon, authenticated;
REVOKE ALL ON FUNCTION fn_email_eligible_for_campaign(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_email_eligible_for_campaign(UUID) FROM anon, authenticated;

COMMENT ON FUNCTION fn_email_eligible_for_campaign(TEXT) IS
    'DEPRECATED: no usar para campanas; email_hash solo sirve para supresion global.';

COMMENT ON FUNCTION fn_email_eligible_for_campaign(UUID) IS
    'Evalua elegibilidad de campana por canal de contacto; usa email_hash solo para supresion global.';

CREATE OR REPLACE VIEW vw_campaign_eligibility_queue
WITH (security_invoker = on) AS
WITH contactabilidad_actual AS (
    SELECT DISTINCT ON (id_canal_contacto)
        id_canal_contacto,
        base_contacto_codigo,
        evidencia
    FROM contactabilidad
    WHERE valido_desde <= now()
      AND (valido_hasta IS NULL OR valido_hasta > now())
    ORDER BY id_canal_contacto, valido_desde DESC, created_at DESC
)
SELECT
    cc.id_canal_contacto,
    cc.id_organizacion,
    o.nit,
    o.nombre_legal,
    o.tipo_entidad_origen,
    o.departamento,
    o.municipio,
    cc.valor_normalizado AS email,
    cc.email_hash,
    cc.confianza,
    cc.estado AS estado_canal,
    c.base_contacto_codigo,
    c.evidencia,
    e.eligible,
    e.reason AS eligibility_reason
FROM canal_contacto cc
JOIN organizacion o ON o.id_organizacion = cc.id_organizacion
LEFT JOIN contactabilidad_actual c ON c.id_canal_contacto = cc.id_canal_contacto
CROSS JOIN LATERAL fn_email_eligible_for_campaign(cc.id_canal_contacto) e
WHERE cc.tipo = 'EMAIL';

COMMENT ON VIEW vw_campaign_eligibility_queue IS
    'Elegibilidad de emails por canal; no propaga consentimiento entre email_hash duplicados.';

CREATE OR REPLACE VIEW vw_email_quality_classification
WITH (security_invoker = on) AS
WITH contactabilidad_actual AS (
    SELECT DISTINCT ON (id_canal_contacto)
        id_canal_contacto,
        base_contacto_codigo
    FROM contactabilidad
    WHERE valido_desde <= now()
      AND (valido_hasta IS NULL OR valido_hasta > now())
    ORDER BY id_canal_contacto, valido_desde DESC, created_at DESC
),
email_base AS (
    SELECT
        cc.id_canal_contacto,
        cc.id_organizacion,
        cc.id_persona,
        cc.valor_normalizado AS email,
        lower(split_part(cc.valor_normalizado, '@', 1)) AS local_part,
        lower(split_part(cc.valor_normalizado, '@', 2)) AS domain,
        cc.estado,
        cc.confianza,
        c.base_contacto_codigo,
        e.eligible,
        e.reason AS eligibility_reason
    FROM canal_contacto cc
    LEFT JOIN contactabilidad_actual c
      ON c.id_canal_contacto = cc.id_canal_contacto
    CROSS JOIN LATERAL fn_email_eligible_for_campaign(cc.id_canal_contacto) e
    WHERE cc.tipo = 'EMAIL'
      AND cc.valor_normalizado LIKE '%@%'
)
SELECT
    eb.*,
    CASE
        WHEN eb.domain IN (
            -- SYNC CON: scripts/import/import_entidades.py MALFORMED_EMAIL_DOMAINS,
            -- database/migrations/014_quarantine_malformed_email_domains.sql y
            -- database/migrations/018_audit_hardening.sql.
            'coomservi.combogot',
            'colegiocoomeva.edu.codocente',
            'fbcsena.comauxiliar'
        )
            THEN 'MALFORMADO_CUARENTENA'
        WHEN eb.domain IN (
            'gmail.com','hotmail.com','yahoo.com','outlook.com',
            'live.com','icloud.com','hotmail.es','yahoo.es',
            'gmail.es','aol.com','msn.com','me.com'
        )
        AND eb.local_part ~ (
            '(^|[._-])(' ||
            'info|contacto|contact|admin|administracion|gerencia|secretaria|' ||
            'contabilidad|compras|ventas|comercial|director|presidencia|' ||
            'tesorero|tesoreria|cartera|servicio|servicios|atencion|soporte|' ||
            'correspondencia|comunicaciones|recursos|fondo|fondos|empleados|' ||
            'cooperativa|coop' ||
            ')([._-]|$)'
        )
            THEN 'ROL_ENTIDAD_DOMINIO_GRATUITO'
        WHEN eb.domain IN (
            'gmail.com','hotmail.com','yahoo.com','outlook.com',
            'live.com','icloud.com','hotmail.es','yahoo.es',
            'gmail.es','aol.com','msn.com','me.com'
        )
            THEN 'PERSONAL_PROBABLE'
        WHEN eb.local_part ~ (
            '^(' ||
            'info|contacto|contact|admin|administracion|gerencia|secretaria|' ||
            'contabilidad|compras|ventas|comercial|director|presidencia|' ||
            'tesorero|tesoreria|cartera|servicio|servicios|atencion|soporte|' ||
            'correspondencia|comunicaciones|recursos' ||
            ')$'
        )
            THEN 'ROL_DOMINIO_PROPIO'
        ELSE 'CORPORATIVO_DOMINIO_PROPIO'
    END AS email_segmento,
    CASE
        WHEN eb.domain IN (
            -- SYNC CON: scripts/import/import_entidades.py MALFORMED_EMAIL_DOMAINS,
            -- database/migrations/014_quarantine_malformed_email_domains.sql y
            -- database/migrations/018_audit_hardening.sql.
            'coomservi.combogot',
            'colegiocoomeva.edu.codocente',
            'fbcsena.comauxiliar'
        )
            THEN 'Corregir dominio o marcar INVALID antes de cualquier uso.'
        WHEN eb.domain IN (
            'gmail.com','hotmail.com','yahoo.com','outlook.com',
            'live.com','icloud.com','hotmail.es','yahoo.es',
            'gmail.es','aol.com','msn.com','me.com'
        )
        AND eb.local_part ~ (
            '(^|[._-])(' ||
            'info|contacto|contact|admin|administracion|gerencia|secretaria|' ||
            'contabilidad|compras|ventas|comercial|director|presidencia|' ||
            'tesorero|tesoreria|cartera|servicio|servicios|atencion|soporte|' ||
            'correspondencia|comunicaciones|recursos|fondo|fondos|empleados|' ||
            'cooperativa|coop' ||
            ')([._-]|$)'
        )
            THEN 'Cuenta gratuita con senales de rol/entidad; requiere revision legal y validacion de buzon.'
        WHEN eb.domain IN (
            'gmail.com','hotmail.com','yahoo.com','outlook.com',
            'live.com','icloud.com','hotmail.es','yahoo.es',
            'gmail.es','aol.com','msn.com','me.com'
        )
            THEN 'Cuenta personal probable; no usar en marketing sin consentimiento/base legal documentada.'
        WHEN eb.local_part ~ (
            '^(' ||
            'info|contacto|contact|admin|administracion|gerencia|secretaria|' ||
            'contabilidad|compras|ventas|comercial|director|presidencia|' ||
            'tesorero|tesoreria|cartera|servicio|servicios|atencion|soporte|' ||
            'correspondencia|comunicaciones|recursos' ||
            ')$'
        )
            THEN 'Canal de rol con dominio propio; priorizar para revision de contactabilidad.'
        ELSE 'Dominio propio no clasificado como rol; revisar vigencia/contactabilidad antes de campana.'
    END AS recomendacion_uso
FROM email_base eb;

COMMENT ON VIEW vw_email_quality_classification IS
    'Clasificacion de emails y elegibilidad por canal, sin propagar consentimiento entre emails duplicados.';
