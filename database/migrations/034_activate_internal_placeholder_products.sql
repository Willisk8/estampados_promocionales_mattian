-- ============================================================
-- 034_activate_internal_placeholder_products.sql
--
-- Activa PRD-TULA-ECO y PRD-ESFERO-ECO solo para pruebas internas.
--
-- AUTORIZACION
-- El usuario autorizo activar estos precios como provisionales internos,
-- sabiendo que no deben usarse con cliente todavia.
--
-- Estos productos conservan en atributos:
--   estado_costos = 'placeholder_por_confirmar'
-- para que las vistas/consumidores puedan distinguirlos de productos con
-- costos confirmados.
-- ============================================================

UPDATE producto
   SET estado = 'ACTIVE'
 WHERE sku IN ('PRD-TULA-ECO', 'PRD-ESFERO-ECO');

UPDATE variante_producto
   SET estado = 'ACTIVE'
 WHERE sku_variante IN ('PRD-TULA-ECO-DTF', 'PRD-ESFERO-ECO-1TINTA');

COMMENT ON TABLE producto IS
    'Catalogo propio vendible. PRD-TULA-ECO y PRD-ESFERO-ECO pueden estar ACTIVE '
    'solo para pruebas internas mientras atributos->>estado_costos = placeholder_por_confirmar; '
    'no usar esos precios con cliente hasta confirmar costos.';
