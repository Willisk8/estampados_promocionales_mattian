-- ============================================================
-- 067_cotizacion_componente_admin_only_read.sql
--
-- CRITICAL fix from the final whole-branch review of cotizador-calculado:
-- cotizacion_componente (038) has always had `consola_read`/`consola_read_guard`
-- policies gated on fn_consola_puede_leer() (true for ANY active role), not
-- fn_consola_rol() = 'ADMIN' like its sibling costo_producto (026). That was
-- a dormant misconfiguration while nothing ever wrote real rows into the
-- table. This branch is the first code that actually populates it with
-- real cotizacion_componente rows (fn_consola_crear_cotizacion_calculada,
-- 062) - so the misconfiguration became a live leak: any COMERCIAL or
-- LECTURA session can SELECT costo_unitario/costo_total/margen_aplicado_pct/
-- minimum_pct straight from the table over PostgREST, bypassing the
-- masking that fn_consola_componentes_cotizacion (061) and
-- fn_consola_previsualizar_cotizacion_calculada (065) exist specifically to
-- enforce. Reproduced live during review: masked RPC returned NULL costs,
-- a direct table read on the same row returned the real numbers.
--
-- Fix: same pattern as costo_producto (026) - RLS restricted to
-- fn_consola_rol() = 'ADMIN', GRANT SELECT TO authenticated kept (RLS does
-- the narrowing, same as every other ADMIN-only table in this schema).
-- No consumer breaks: no frontend code queries cotizacion_componente
-- directly (confirmed in the same review) - everything goes through the
-- masked RPCs, which are SECURITY DEFINER and unaffected by this table's
-- RLS.
-- ============================================================

DROP POLICY IF EXISTS consola_read ON cotizacion_componente;
DROP POLICY IF EXISTS consola_read_guard ON cotizacion_componente;

CREATE POLICY consola_read_admin ON cotizacion_componente
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_rol() = 'ADMIN');

CREATE POLICY consola_read_guard ON cotizacion_componente
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_rol() = 'ADMIN');

COMMENT ON TABLE cotizacion_componente IS
    'Desglose de costo/margen por componente de una cotizacion calculada. Legible directamente solo por ADMIN (mismo patron que costo_producto, 026) - COMERCIAL y LECTURA deben leer el precio final via fn_consola_componentes_cotizacion o fn_consola_previsualizar_cotizacion_calculada, que enmascaran costo/margen server-side.';
