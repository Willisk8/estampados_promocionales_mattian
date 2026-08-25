# Costos de técnicas de marcación

Fecha de corte: 2026-08-25

Fuente local:
`scraping/personalization_techniques/outputs/01a0394c-b6b4-7d11-bb54-d4001c6bd0fb/`

## Conclusión operativa

La investigación confirma que la calculadora no debe depender de números
quemados por producto. Los costos de personalización deben vivir como snapshots
históricos por técnica/proveedor/formato, igual que los precios de proveedor.

Se agregan tablas para:

- catálogo de técnicas (`tecnica_marcacion`);
- proveedores de servicios de marcación (`proveedor_tecnica_marcacion`);
- snapshots append-only de precios (`precio_tecnica_marcacion_snapshot`).

Carga inicial en STAGING:

- 14 técnicas de marcación;
- 12 proveedores/fuentes de marcación;
- 65 snapshots de precio.

Dos técnicas (`acabado_agenda_multitecnica` y `vinilo_alta_densidad`) fueron
derivadas desde observaciones de precio porque no venían en el catálogo curado.
Quedan en `PENDING_REVIEW` hasta que se confirme su semántica comercial.

La migración `036_curate_marking_technique_prices.sql` agrega la curación
operativa sin modificar los snapshots append-only:

- `AUTOMATIC_PRICING`: puede alimentar calculadora interna.
- `REFERENCE_ONLY`: benchmark o referencia parcial.
- `NEEDS_REVIEW`: requiere validación de unidad, setup, mínimo o alcance.
- `DO_NOT_USE`: reservado para observaciones descartadas.

Vista de consumo:

```sql
SELECT *
FROM vw_precio_tecnica_marcacion_curado
WHERE usage_status = 'AUTOMATIC_PRICING';
```

## Calidad de datos de la investigación

| Técnica | Uso recomendado hoy | Motivo |
|---|---|---|
| `dtf_textil` | Costeo automático permitido con revisión | Tiene precios por tamaño y cantidad, y también metro lineal verificado. |
| `dtf_uv` | Costeo automático con cautela | Hay precio por metro lineal verificado y una referencia por unidad 7×10 cm. |
| `sublimacion` | Costeo automático solo con filas `solo_marcacion` verificadas | A4 a $3.500 sirve como base; precios de mug personalizado son benchmark, no costo interno. |
| `bordado` | Solo referencia parcial | Hay costo de programa/digitalización, falta costo por puntadas o tamaño. |
| `grabado_laser` | Solo referencia parcial | Hay rango por 100 unidades, falta regla por material/tiempo/área. |
| `tampografia` | No usar automático todavía | La fuente publica valor sin unidad clara (`NEEDS_REVIEW_UNIT`). |
| `serigrafia` | No usar automático todavía | La fuente publica valor sin unidad clara (`NEEDS_REVIEW_UNIT`). |
| `vinilo_alta_densidad` | Referencia verificable, pendiente de curación | Aparece en precios como formato/pliego; falta decidir si es técnica separada o variante de vinilo. |
| `acabado_agenda_multitecnica` | Benchmark, no costo automático | Es paquete de acabados de agenda; útil para referencia, no para cálculo unitario directo. |

## Reglas para la calculadora

1. Usar automáticamente solo snapshots con `verification_status = 'VERIFIED_PUBLIC_PRICE'`.
2. Distinguir `price_scope`:
   - `solo_marcacion` / `solo_servicio`: útil como costo de personalización.
   - `producto_personalizado`: usar como benchmark de mercado, no como costo interno.
3. Para DTF/DTFV, calcular por área requerida y comprar el formato mínimo más barato.
4. Para sublimación, calcular por hoja/formato:
   - mug 11 oz: hasta 3 imágenes por A4/carta según plantilla;
   - tula: normalmente 1 impresión grande por A4 o formato superior, pendiente de material compatible.
5. Para tampografía/serigrafía/láser, no generar precios automáticos hasta capturar:
   - setup/montaje;
   - costo por unidad;
   - número de tintas/posiciones;
   - área máxima;
   - mínimo de pedido.

## Implicación para productos MVP

### Tula

La tula puede costearse con DTF textil como caso inicial:

- área de marca inicial: 15×20 cm;
- una cara;
- formatos DTF textil existentes: 58×30, 58×50, 58×100 cm;
- `machine_wear_policy.min_amortization_qty = 12`.

La sublimación de tula queda pendiente hasta confirmar material compatible y
formato real de impresión. No debe asumirse que rinde igual que mug: un mug
puede compartir hoja con otros diseños; una tula grande puede consumir una hoja
completa o requerir formato mayor.

### Esfero

El esfero ecológico puede entrar al MVP con costo de producto proveedor y costo
de marcación fijo provisional. Sin embargo, tampografía/UV deben quedar
marcadas como `por_confirmar` hasta tener precio por unidad y setup verificable.

## Carga a STAGING

```powershell
python scripts/import/import_tecnicas_marcacion.py `
  --dir scraping/personalization_techniques/outputs/01a0394c-b6b4-7d11-bb54-d4001c6bd0fb
```

El importador registra trazabilidad en `import_batch` e `import_raw_row`.

## Export para calculadora

```powershell
python scripts/catalog/export_marking_cost_inputs.py > outputs/marking_cost_inputs.json
```

Este export lee solamente snapshots curados como `AUTOMATIC_PRICING`. La
calculadora sigue pudiendo usar `mvp_catalog_inputs.json`, pero este archivo ya
permite auditar o reemplazar manualmente los costos de DTF, DTF UV y
sublimación con datos versionados de STAGING.
