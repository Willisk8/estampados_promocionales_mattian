BEGIN;
DO $$
DECLARE v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY['fn_precio_tecnica_snap_no_update_delete',
    'fn_quote_round','fn_quote_apply_margin','fn_resolve_margin_policy_version',
    'fn_classify_precio_tecnica_marcacion'] LOOP
    ASSERT NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname=v_name
        AND NOT COALESCE(p.proconfig @> ARRAY['search_path=public, pg_temp'],false)),
      format('search_path debe ser fijo: %s',v_name);
  END LOOP;
  ASSERT NOT has_table_privilege('authenticated','public.vw_catalogo_proveedor_quality','UPDATE'),
    'La vista de calidad no debe conceder UPDATE';
  ASSERT (SELECT n.nspname='extensions' FROM pg_extension e
    JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='btree_gist'),
    'btree_gist debe estar fuera del esquema expuesto public';
  ASSERT public.fn_quote_round(101,'UP_100')=200;
  ASSERT public.fn_quote_apply_margin(6000,'MARGIN',40)=10000;
END;
$$;
ROLLBACK;
