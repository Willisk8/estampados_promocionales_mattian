-- ============================================================
-- 001_producto_fixture_base.sql
--
-- Siembra el producto minimo que los tests y los evals dan por sentado.
--
-- POR QUE EXISTE
-- test_orders.sql, test_customer_360.sql y scripts/evals/run_evals.py arman
-- sus fixtures con:
--     INSERT INTO cotizacion_item (...) SELECT ... FROM producto p LIMIT 1;
-- Ninguna migracion siembra productos, asi que sobre una base recien migrada
-- (el contenedor postgres:16 del CI, o un Postgres local) la tabla producto
-- esta vacia, esas consultas insertan 0 filas y los tests fallan con
-- QUOTE_WITHOUT_ITEMS y "No hay ningun producto en la base".
--
-- No alcanza con que otro test siembre un producto: todos los tests corren
-- dentro de BEGIN ... ROLLBACK, asi que ninguno deja filas para el siguiente.
-- Hace falta una fila commiteada antes de ejecutar la suite.
--
-- ESTO NO ES UNA MIGRACION.
-- Vive fuera de database/migrations/ para que apply_pending_migrations.ps1 no
-- lo recoja. Se aplica en CI y en entornos locales, despues de las
-- migraciones y antes de los tests.
-- ============================================================

-- ----------------------------------------------------------
-- 0. Guarda: negarse a correr sobre una instancia de Supabase
--    Misma verificacion que database/ci/bootstrap_supabase_roles.sql.
-- ----------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault')
       OR (SELECT count(*) FROM information_schema.tables
           WHERE table_schema = 'auth') > 3
    THEN
        RAISE EXCEPTION
            'Esta semilla es solo para CI y entornos locales. La base destino ya parece ser Supabase.';
    END IF;
END
$$;

-- ----------------------------------------------------------
-- 1. Producto base
--    Nace en DRAFT, no en ACTIVE: ningun producto del catalogo propio nace
--    activo, y ni los tests ni los evals filtran por estado — todos hacen
--    SELECT ... FROM producto LIMIT 1 — asi que DRAFT alcanza para el fixture.
--    Idempotente: no hace nada si la tabla ya tiene algun producto, para no
--    alterar el conteo que verifican los tests ni duplicar el fixture al
--    re-aplicar la semilla.
-- ----------------------------------------------------------
INSERT INTO producto (id_producto, sku, nombre, categoria, estado, activo)
SELECT
    '00000000-0000-4000-9000-000000000001',
    'PRD-FIXTURE-BASE',
    'Producto base para fixtures de test',
    'PROMOCIONAL',
    'DRAFT',
    true
WHERE NOT EXISTS (SELECT 1 FROM producto);

DO $$
DECLARE v_total INT;
BEGIN
    SELECT count(*) INTO v_total FROM producto;
    ASSERT v_total >= 1, 'la semilla debe dejar al menos un producto en la base';
    RAISE NOTICE 'Semilla aplicada: % producto(s) en la base.', v_total;
END
$$;
