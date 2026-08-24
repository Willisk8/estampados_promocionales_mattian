-- ============================================================
-- 012_revoke_public_execute.sql
-- Las funciones SECURITY DEFINER tienen EXECUTE otorgado a
-- PUBLIC por defecto en PostgreSQL. Revocar de PUBLIC elimina
-- el acceso de anon y authenticated (que heredan de PUBLIC).
-- Solo service_role (backend) puede invocarlas.
-- ============================================================

REVOKE EXECUTE ON FUNCTION resolve_price(UUID, UUID, INT, TIMESTAMPTZ, TEXT)
    FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION fn_email_eligible_for_campaign(TEXT)
    FROM PUBLIC;
