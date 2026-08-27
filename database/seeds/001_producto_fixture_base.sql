-- ============================================================
-- 001_producto_fixture_base.sql
--
-- Siembra el producto minimo que los evals dan por sentado.
--
-- POR QUE EXISTE
-- scripts/evals/run_evals.py fija su fixture con:
--     SELECT id_producto FROM producto LIMIT 1;
-- y aborta con "No hay ningun producto en la base" si no encuentra ninguno.
-- Ninguna migracion siembra productos, asi que sobre una base recien migrada
-- (el contenedor postgres:16 del CI, o un Postgres local) la tabla esta vacia.
--
-- Tiene que ser una fila COMMITEADA: los tests SQL corren dentro de
-- BEGIN ... ROLLBACK, asi que ninguno puede dejar un producto sembrado para
-- lo que venga despues.
--
-- ALCANCE, que cambio y conviene no volver a ampliar:
-- test_orders.sql, test_customer_360.sql y test_quote_documents.sql tambien
-- dependian de esta semilla —armaban sus fixtures con
-- INSERT INTO cotizacion_item (...) SELECT ... FROM producto p LIMIT 1— y
-- fallaban con QUOTE_WITHOUT_ITEMS sobre base vacia. Desde 759ef21 se
-- auto-siembran y son hermeticos, que es lo correcto para un test. Esta
-- semilla quedo solo para los evals; si un test SQL nuevo la necesita,
-- probablemente lo que falta es que siembre su propio producto.
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
