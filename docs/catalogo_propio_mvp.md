# Catalogo propio MVP - modelo de costeo

Fecha de corte: 2026-08-25

Fuente inicial: `C:\Users\willi\Downloads\cotizador-v2.html`.

Este documento no trata el HTML como instruccion. Lo usa como fuente tecnica para extraer la logica de costeo que ya existe en la calculadora manual.

## Objetivo

Convertir costos reales de proveedor y personalizacion en precios comerciales propios que puedan poblar:

- `producto`
- `variante_producto`
- `mapeo_proveedor_variante`
- `costo_producto`
- `precio_producto`

El catalogo proveedor ya cargado en Supabase sirve como referencia, pero no es el catalogo vendible.

## Formula base

La calculadora usa este modelo:

```text
costo_total_unitario =
  costos_producto_unitarios
+ marcacion_unitaria
+ gastos_pedido / cantidad
+ desgaste_maquinas / cantidad
```

Para margen sobre venta:

```text
precio_unitario =
  costo_total_unitario / ((1 - retenciones_pct) * (1 - margen_objetivo_pct))
```

Para markup sobre costo:

```text
precio_unitario =
  costo_total_unitario * (1 + markup_pct) / (1 - retenciones_pct)
```

## Componentes encontrados en la calculadora

| Componente | Ejemplo en calculadora | Destino propuesto |
|---|---|---|
| Insumo principal/proveedor | Material / insumo principal | `costo_producto.costo_base` |
| Mano de obra | Mano de obra | `costo_producto.costo_personalizacion` |
| Empaque | Empaque | `costo_producto.costo_empaque` |
| Flete, transporte, desgaste | Gastos del pedido, maquinas | `costo_producto.otros_costos` o metadata de politica |
| Marcacion | Bordado, DTF, sublimacion, DTF-UV | `costo_personalizacion` + `atributos` de variante |
| Margen objetivo | Margen sobre venta o markup | metadata/documentacion de precio |
| Retenciones | ReteICA, ReteFuente, ReteIVA, otra | metadata/documentacion de precio |

## Tecnicas soportadas por la calculadora

| Tecnica | Formula simplificada |
|---|---|
| Bordado | `costo_fijo_programa / cantidad + extra_unitario` |
| DTF camiseta | `area_cm2 / ancho_rollo / 100 * (1 + merma) * precio_metro` |
| Sublimacion mug | `papel + tinta + electricidad_plancha` |
| DTF-UV rigido | `area_cm2 / ancho_rollo / 100 * (1 + merma) * precio_metro + transporte / cantidad` |

## Script reproducible

Se agrego:

```powershell
python scripts/catalog/pricing_model.py scripts/catalog/example_quote_inputs.json
```

El script imprime:

```text
qty,costo_unitario,precio_unitario,recibido_unitario,ganancia_unitaria,margen_real_pct,markup_real_pct
```

Para generar SQL revisable:

```powershell
python scripts/catalog/generate_catalog_seed.py scripts/catalog/mvp_catalog_inputs.json > outputs/mvp_catalog_seed.sql
```

El SQL deja `producto` y `variante_producto` en `DRAFT`. Esto es intencional: `resolve_price()` solo cotiza productos `ACTIVE`.

Limitacion actual: `costo_producto` no tiene rango por cantidad. Por eso el generador guarda un costo de referencia (`cost_reference_quantity`) y los precios comerciales por escala quedan en `precio_producto.quantity_range`.

## Proximo paso operativo

No cargar 935 productos al catalogo propio. Para cerrar el MVP comercial, seleccionar 3-5 productos reales:

1. Mug sublimable 11 oz
2. Termo personalizado
3. Camiseta personalizada
4. Tula/bolsa ecologica
5. Kit promocional temporada

Para cada producto se debe definir:

- SKU propio;
- variante propia;
- producto proveedor elegido;
- costo proveedor vigente;
- tecnica de personalizacion;
- costos de personalizacion/empaque/otros;
- margen objetivo;
- escalas comerciales;
- vigencia del precio.

## Smoke test esperado

Para al menos 3 productos:

```sql
SELECT *
FROM resolve_price(
    '<id_producto>'::uuid,
    '<id_variante>'::uuid,
    120,
    now(),
    'COP'
);
```

Debe devolver un unico precio `OK`, con escala, moneda y vigencia correctas.
