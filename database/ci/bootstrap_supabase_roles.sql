-- ============================================================
-- bootstrap_supabase_roles.sql
--
-- Crea los objetos que Supabase provee de fabrica y que un contenedor
-- postgres limpio no tiene: los roles anon/authenticated/service_role y un
-- esquema auth minimo.
--
-- POR QUE EXISTE
-- Las migraciones 011, 018, 019 y 020 ejecutan
--   REVOKE ... FROM anon, authenticated;
-- sin guarda de existencia, y la migracion de acceso a la consola referencia
-- auth.users y auth.uid(). Sobre un postgres limpio esas sentencias fallan con
-- 'role "anon" does not exist'. En Supabase todo eso ya existe.
--
-- ESTO NO ES UNA MIGRACION.
-- Vive fuera de database/migrations/ para que apply_pending_migrations.ps1 no
-- lo recoja. Solo debe ejecutarse en CI, antes de aplicar las migraciones.
-- El bloque de seguridad de abajo aborta si detecta un Supabase real.
-- ============================================================

-- ----------------------------------------------------------
-- 0. Guarda: negarse a correr sobre una instancia de Supabase
-- ----------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault')
       OR (SELECT count(*) FROM information_schema.tables
           WHERE table_schema = 'auth') > 3
    THEN
        RAISE EXCEPTION
            'Este bootstrap es solo para CI. La base destino ya parece ser Supabase.';
    END IF;
END
$$;

-- ----------------------------------------------------------
-- 1. Roles
-- ----------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN NOINHERIT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN NOINHERIT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
        -- BYPASSRLS reproduce el comportamiento real de Supabase: es lo que
        -- permite que los importadores escriban con las politicas deny-all.
        CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- ----------------------------------------------------------
-- 2. Esquema auth minimo
-- ----------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
    id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT
);

-- Misma semantica que la funcion de Supabase: lee el 'sub' del JWT que la
-- sesion declara. Los tests fijan request.jwt.claims con SET LOCAL.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(
        nullif(current_setting('request.jwt.claim.sub', true), ''),
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(
        nullif(current_setting('request.jwt.claim.role', true), ''),
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
    );
$$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated, service_role;
