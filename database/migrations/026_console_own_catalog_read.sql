-- ============================================================
-- 026_console_own_catalog_read.sql
--
-- Abre a la consola la lectura del catalogo propio: precios comerciales por
-- escala, costos y el mapeo hacia el producto de proveedor.
--
-- POR QUE NO ESTABAN
-- La migracion 024 solo abrio lo necesario para observar CRM y catalogo de
-- proveedor. La 025 revoco los privilegios por defecto de estas tres tablas.
-- Faltaba la pantalla de productos propios, que es justo donde se ve el
-- resultado del modelo de costeo.
--
-- Leer un precio no es cotizar. El cotizador sigue deshabilitado y
-- resolve_price sigue sin EXECUTE para authenticated: esta migracion habilita
-- observar, no emitir.
--
-- DIFERENCIA POR ROL
-- Los precios de venta los ve cualquier perfil. Los costos y margenes solo
-- ADMIN: son la estructura de rentabilidad del negocio y no todo el que
-- consulta el catalogo tiene por que verla.
-- ============================================================

-- ----------------------------------------------------------
-- 1. Precios comerciales y mapeo: cualquier perfil de consola
-- ----------------------------------------------------------
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['precio_producto', 'mapeo_proveedor_variante'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS deny_all ON public.%I', t);

        EXECUTE format(
            'CREATE POLICY deny_insert ON public.%I AS RESTRICTIVE FOR INSERT WITH CHECK (false)', t);
        EXECUTE format(
            'CREATE POLICY deny_update ON public.%I AS RESTRICTIVE FOR UPDATE USING (false)', t);
        EXECUTE format(
            'CREATE POLICY deny_delete ON public.%I AS RESTRICTIVE FOR DELETE USING (false)', t);

        EXECUTE format(
            'CREATE POLICY consola_read ON public.%I AS PERMISSIVE FOR SELECT '
            'TO authenticated USING (fn_consola_puede_leer())', t);
        EXECUTE format(
            'CREATE POLICY consola_read_guard ON public.%I AS RESTRICTIVE FOR SELECT '
            'USING (fn_consola_puede_leer())', t);

        EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
        EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    END LOOP;
END
$$;

-- ----------------------------------------------------------
-- 2. Costos: solo ADMIN
-- ----------------------------------------------------------
DROP POLICY IF EXISTS deny_all ON costo_producto;

CREATE POLICY deny_insert ON costo_producto AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON costo_producto AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON costo_producto AS RESTRICTIVE FOR DELETE USING (false);

CREATE POLICY consola_read_admin ON costo_producto
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_rol() = 'ADMIN');

CREATE POLICY consola_read_guard ON costo_producto
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_rol() = 'ADMIN');

REVOKE ALL   ON costo_producto FROM anon, authenticated;
GRANT SELECT ON costo_producto TO authenticated;

COMMENT ON TABLE costo_producto IS
    'Estructura de costo del catalogo propio. Legible solo por perfiles ADMIN '
    'de la consola: contiene la base sobre la que se calcula el margen.';

-- ----------------------------------------------------------
-- 3. anon sigue sin nada
-- ----------------------------------------------------------
DO $$
DECLARE
    v_restantes TEXT;
BEGIN
    SELECT string_agg(DISTINCT table_name, ', ' ORDER BY table_name)
      INTO v_restantes
      FROM information_schema.role_table_grants
     WHERE grantee = 'anon' AND table_schema = 'public';

    IF v_restantes IS NOT NULL THEN
        RAISE EXCEPTION 'El rol anon conserva privilegios sobre: %.', v_restantes;
    END IF;
END
$$;
