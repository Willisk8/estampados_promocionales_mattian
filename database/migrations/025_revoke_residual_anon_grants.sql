-- ============================================================
-- 025_revoke_residual_anon_grants.sql
--
-- Cierra los privilegios que Supabase otorga por defecto a anon y a
-- authenticated sobre las tablas del esquema public y que la migracion 024
-- no alcanzo.
--
-- POR QUE IMPORTA
-- Supabase concede ALL PRIVILEGES a anon y authenticated sobre las tablas de
-- public. Hasta la 024, lo unico que contenia ese acceso era la politica RLS
-- deny_all. Eso deja la seguridad apoyada en una sola capa: si una politica se
-- relaja por error, el privilegio ya estaba concedido y los datos quedan
-- abiertos al rol anonimo, que no requiere ni siquiera iniciar sesion.
--
-- La 024 cubrio las 15 tablas de la consola y las 6 con PII. Faltaban estas.
-- ============================================================

-- Catalogo propio de costos y precios. La consola de Etapa B no cotiza, asi
-- que no necesita leerlas: conservan deny_all y quedan sin privilegios.
REVOKE ALL ON costo_producto           FROM anon, authenticated;
REVOKE ALL ON precio_producto          FROM anon, authenticated;
REVOKE ALL ON mapeo_proveedor_variante FROM anon, authenticated;

-- Metadatos del ejecutor de migraciones. Nadie que no sea backend los toca.
REVOKE ALL ON public.schema_migrations FROM anon, authenticated;

-- perfil_usuario se creo en la 024 y heredo los privilegios por defecto.
-- authenticated necesita SELECT para que la politica perfil_propio le deje ver
-- su propia fila; todo lo demas sobra, y anon no pinta nada aqui.
REVOKE ALL   ON perfil_usuario FROM anon, authenticated;
GRANT SELECT ON perfil_usuario TO authenticated;

-- Comprobacion: despues de esta migracion, anon no debe conservar ningun
-- privilegio sobre el esquema public. Si queda alguno, la migracion falla en
-- vez de dejar la brecha abierta en silencio.
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
