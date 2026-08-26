-- ============================================================
-- 037_revoke_curacion_tecnica_grants.sql
--
-- Cierra los privilegios que Supabase otorga por defecto a anon y
-- authenticated sobre los objetos creados en la migracion 036, exactamente el
-- mismo problema que cerro la migracion 025 para otras tablas.
--
-- POR QUE IMPORTA
-- La 036 creo curacion_precio_tecnica_marcacion y
-- vw_precio_tecnica_marcacion_curado sin el REVOKE ALL FROM anon,
-- authenticated que el resto de tablas nuevas de este proyecto ya trae. En
-- STAGING, el rol anonimo (sin iniciar sesion) tenia INSERT/UPDATE/DELETE/
-- SELECT/TRUNCATE sobre ambos objetos; solo la politica deny_all de la tabla
-- lo contenia, y la vista no tenia ninguna RLS que la protegiera en absoluto.
--
-- Lo detecto scripts/audit_change.py al auditar el repositorio completo, no
-- una revision manual: es la regla "grant-por-defecto" agregada tras
-- encontrar el mismo problema en la migracion 024.
-- ============================================================

REVOKE ALL ON curacion_precio_tecnica_marcacion  FROM anon, authenticated;
REVOKE ALL ON vw_precio_tecnica_marcacion_curado FROM anon, authenticated;

DO $$
DECLARE
    v_restantes TEXT;
BEGIN
    SELECT string_agg(DISTINCT table_name, ', ' ORDER BY table_name)
      INTO v_restantes
      FROM information_schema.role_table_grants
     WHERE grantee = 'anon'
       AND table_schema = 'public';

    IF v_restantes IS NOT NULL THEN
        RAISE EXCEPTION
            'El rol anon conserva privilegios sobre: %. Revocalos antes de continuar.',
            v_restantes;
    END IF;
END
$$;
