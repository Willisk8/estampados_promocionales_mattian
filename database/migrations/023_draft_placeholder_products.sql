-- ============================================================
-- 023_draft_placeholder_products.sql
--
-- Devuelve a DRAFT los productos propios cuyos costos siguen siendo
-- placeholder sin confirmar.
--
-- POR QUE
-- El seed del catalogo MVP dejo PRD-TULA-ECO y PRD-ESFERO-ECO en estado
-- ACTIVE, con lo que resolve_price() los cotiza. Pero sus atributos declaran
-- estado_costos = 'placeholder_por_confirmar', y docs/plan_trabajo_cierre_mvp.md
-- los describe como productos con costos por confirmar. Un precio calculado
-- sobre costos sin confirmar no debe poder salir a un cliente.
--
-- Esto no borra precios ni costos: solo cierra la puerta de cotizacion. Cuando
-- los costos se confirmen, una migracion posterior los devuelve a ACTIVE y los
-- 35 precios por escala siguen ahi.
-- ============================================================

UPDATE producto
   SET estado = 'DRAFT'
 WHERE sku IN ('PRD-TULA-ECO', 'PRD-ESFERO-ECO')
   AND estado = 'ACTIVE';

-- Las variantes acompanan al producto: resolve_price() exige que la variante
-- indicada este ACTIVE, y una variante activa de un producto en DRAFT seria
-- un estado incoherente.
UPDATE variante_producto
   SET estado = 'DRAFT'
 WHERE estado = 'ACTIVE'
   AND id_producto IN (
       SELECT id_producto
         FROM producto
        WHERE sku IN ('PRD-TULA-ECO', 'PRD-ESFERO-ECO')
   );

-- Deja constancia del motivo en la propia base, para que no haya que leer
-- esta migracion para entender por que estos dos productos no se cotizan.
COMMENT ON TABLE producto IS
    'Catalogo propio vendible. Solo los productos en estado ACTIVE son cotizables '
    'por resolve_price(). PRD-TULA-ECO y PRD-ESFERO-ECO quedaron en DRAFT en la '
    'migracion 023 por tener costos placeholder sin confirmar.';
