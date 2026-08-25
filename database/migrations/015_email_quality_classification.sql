-- ============================================================
-- 015_email_quality_classification.sql
-- Clasificacion operativa de emails para segmentacion pre-piloto.
--
-- No habilita campanas. Solo distingue:
-- - dominio propio corporativo;
-- - rol en dominio propio;
-- - rol/entidad en dominio gratuito;
-- - personal probable;
-- - malformado en cuarentena.
-- ============================================================

CREATE OR REPLACE VIEW vw_email_quality_classification WITH (security_invoker = on) AS
WITH email_base AS (
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
    LEFT JOIN contactabilidad c
      ON c.id_canal_contacto = cc.id_canal_contacto
    CROSS JOIN LATERAL fn_email_eligible_for_campaign(cc.email_hash) e
    WHERE cc.tipo = 'EMAIL'
      AND cc.valor_normalizado LIKE '%@%'
)
SELECT
    eb.*,
    CASE
        WHEN eb.domain IN (
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
    'Clasificacion de emails para separar personales probables de roles/entidades en dominios gratuitos antes del piloto.';
