-- ============================================================
-- 016_fix_security_invoker_views.sql
-- Corrige vistas que Supabase detecta como SECURITY DEFINER.
--
-- Por defecto en PostgreSQL las vistas heredan los permisos del
-- creador (owner), no del usuario que consulta. Esto bypasea RLS
-- y genera la alerta "security_definer_view" del linter de Supabase.
--
-- Fix: security_invoker = on hace que la vista evalúe RLS y permisos
-- del usuario que ejecuta la consulta, no del owner.
-- ============================================================

ALTER VIEW vw_organizacion_contacto_resumen    SET (security_invoker = on);
ALTER VIEW vw_import_review_open               SET (security_invoker = on);
ALTER VIEW vw_catalogo_proveedor_quality       SET (security_invoker = on);
ALTER VIEW vw_campaign_eligibility_queue       SET (security_invoker = on);
ALTER VIEW vw_email_quality_classification     SET (security_invoker = on);
