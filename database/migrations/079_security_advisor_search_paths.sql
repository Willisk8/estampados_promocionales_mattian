-- Hallazgos del inventario remoto y Security Advisor, 2026-09-11.
-- Conserva cuerpos, firmas y autorizaciones de las funciones existentes.
ALTER FUNCTION public.fn_precio_tecnica_snap_no_update_delete()
  SET search_path = public, pg_temp;
ALTER FUNCTION public.fn_quote_round(numeric, text)
  SET search_path = public, pg_temp;
ALTER FUNCTION public.fn_quote_apply_margin(numeric, text, numeric)
  SET search_path = public, pg_temp;
ALTER FUNCTION public.fn_resolve_margin_policy_version(text, timestamptz)
  SET search_path = public, pg_temp;
ALTER FUNCTION public.fn_classify_precio_tecnica_marcacion(text, text, text, text, text)
  SET search_path = public, pg_temp;

-- El catalogo de calidad es una vista de lectura. Supabase habia conservado
-- grants de escritura predeterminados aunque la migracion 024 solo agrego SELECT.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.vw_catalogo_proveedor_quality FROM PUBLIC, anon, authenticated;

-- btree_gist es relocatable; mover su esquema conserva OIDs y dependencias
-- de los indices/constraints existentes. No recrea tablas ni cambia datos.
CREATE SCHEMA IF NOT EXISTS extensions;
ALTER EXTENSION btree_gist SET SCHEMA extensions;
