-- ============================================================
-- 030_distinguish_missing_contactability_reason.sql
-- Observabilidad de elegibilidad: diferenciar ausencia de registro efectivo
-- vs. registro efectivo con base no permitida.
-- ============================================================

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

    IF v_effective_base IS NULL THEN
        RETURN QUERY SELECT false, 'NO_CONTACTABILITY_RECORD';
        RETURN;
    END IF;

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

REVOKE ALL ON FUNCTION fn_email_eligible_for_campaign(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_email_eligible_for_campaign(UUID) FROM anon, authenticated;

COMMENT ON FUNCTION fn_email_eligible_for_campaign(UUID) IS
    'Evalua elegibilidad por canal; exige email_hash para supresion global y distingue ausencia de contactabilidad efectiva.';
