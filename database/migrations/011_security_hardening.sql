-- ============================================================
-- 011_security_hardening.sql
-- Correcciones de seguridad detectadas por Supabase Advisor:
--   1. Fijar search_path en todas las funciones públicas
--      para prevenir ataques de search_path injection.
--   2. Revocar EXECUTE en funciones SECURITY DEFINER
--      a roles anon y authenticated — solo service_role
--      (backend) puede invocarlas.
-- ============================================================

-- ----------------------------------------------------------
-- 1. Fijar search_path en todas las funciones
-- ----------------------------------------------------------
ALTER FUNCTION fn_set_updated_at()
    SET search_path = public, pg_temp;

ALTER FUNCTION fn_precio_snap_no_update()
    SET search_path = public, pg_temp;

ALTER FUNCTION resolve_price(UUID, UUID, INT, TIMESTAMPTZ, TEXT)
    SET search_path = public, pg_temp;

ALTER FUNCTION fn_email_eligible_for_campaign(TEXT)
    SET search_path = public, pg_temp;

-- ----------------------------------------------------------
-- 2. Revocar EXECUTE en funciones SECURITY DEFINER
--    a roles públicos — solo service_role puede llamarlas
-- ----------------------------------------------------------
REVOKE EXECUTE ON FUNCTION resolve_price(UUID, UUID, INT, TIMESTAMPTZ, TEXT)
    FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION fn_email_eligible_for_campaign(TEXT)
    FROM anon, authenticated;
