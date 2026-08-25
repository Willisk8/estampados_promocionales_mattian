# Precios variables de proveedor y recalculo comercial

Fecha de corte: 2026-08-25

## Principio

Los costos de proveedor no son constantes. Pueden cambiar por:

- fecha;
- proveedor;
- ciudad;
- disponibilidad;
- negociacion directa;
- formato de compra: unidad, docena, caja, medio metro, metro, minimo tecnico.

Por eso no deben quedar como una verdad permanente dentro de `precio_producto`.
`precio_producto` representa el precio propio de venta para una vigencia concreta.
Cuando cambian los costos de proveedor, se debe crear una nueva version de costos
y precios con una nueva vigencia.

## Donde vive cada dato

| Dato | Tabla actual | Regla |
|---|---|---|
| Proveedor | `proveedor` | Una fila por proveedor: Surtimundo, Surtivinilos, Etanol, proveedor de mugs, etc. |
| Producto/insumo del proveedor | `producto_proveedor` | Una fila por insumo vendible: DTF textil 58x100, DTFV 58x15, camiseta Etanol, caja mug x36. |
| Precio observado proveedor | `precio_proveedor_snapshot` | Append-only. Insertar nueva fila cuando cambie el precio; nunca actualizar historico. Desde `017_supplier_price_purchase_terms.sql` puede guardar unidad/formato/minimos. |
| Mapeo a producto propio | `mapeo_proveedor_variante` | Relaciona insumos/proveedores con una variante vendible propia. |
| Costo propio calculado | `costo_producto` | Costo consolidado usado para una vigencia. No reemplaza el historico proveedor. |
| Precio de venta propio | `precio_producto` | Precio final por rango de cantidad y vigencia. Lo consulta `resolve_price()`. |

## Brecha actual

El esquema original guardaba snapshots simples de proveedor con `precio_publicado`.
La migracion `017_supplier_price_purchase_terms.sql` agrega campos para modelar:

- unidad de compra (`unidad`, `caja`, `metro`, `centimetro`);
- dimensiones utiles (`width_cm`, `height_cm`);
- cantidad por pack (`pack_qty`);
- precio por escala o formato;
- minimo/incremento de compra.

Para el MVP, esos datos tambien viven en `scripts/catalog/mvp_catalog_inputs.json` bajo:

- `product_costs[].tiers`
- `marking.purchase_options`

Esto permite calcular correctamente ya. El siguiente paso maduro es que los
scripts lean esas condiciones desde `precio_proveedor_snapshot` en vez de
mantenerlas manualmente en JSON.

## Regla operativa

1. Registrar el nuevo precio proveedor como snapshot.
2. Recalcular el catálogo propio con la calculadora.
3. Crear nuevas filas en `costo_producto` y `precio_producto` con nueva vigencia.
4. Mantener productos/precios en `DRAFT` hasta revision humana.
5. Activar solo cuando la tabla de precios este aprobada.

## Ejemplos actuales del MVP

DTF textil Surtimundo/Surtivinilos:

| Formato | Precio |
|---|---:|
| 58 x 30 cm | 8.000 COP |
| 58 x 50 cm | 13.000 COP |
| 58 x 100 cm | 26.000 COP |

DTFV / DTF UV Surtimundo/Surtivinilos:

| Formato | Precio |
|---|---:|
| 58 x 15 cm | 15.000 COP |
| 58 x 50 cm | 32.500 COP |
| 58 x 100 cm | 65.000 COP |

Mug blanco 11 oz:

| Modo compra | Regla |
|---|---|
| Unidad | costo unitario para pedidos pequenos |
| Caja x36 | `pack_price / 36` para pedidos de docena o caja |

Camiseta Etanol:

| Cantidad | Regla |
|---|---|
| 1+ | costo unitario proveedor |
| 12+ | escala proveedor |
| 50+ | escala proveedor mayorista |
