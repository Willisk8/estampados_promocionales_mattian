# Precios de técnicas de personalización en Colombia

Módulo independiente para capturar precios públicos de servicios de marcación y
personalización. No mezcla los costos del servicio con el catálogo de productos.

## Principios

- Solo conserva valores presentes en páginas públicas; no estima precios faltantes.
- Cada observación incluye URL, fecha UTC, evidencia textual, unidad y condición.
- Diferencia `solo_marcacion`, `solo_servicio`, `producto_personalizado` y
  `cotizador_referencial` para evitar comparar costos de alcance distinto.
- Respeta `robots.txt`, aplica pausas y no evade CAPTCHA, autenticación ni bloqueos.
- Los precios son capturas de mercado, no cotizaciones. IVA, transporte, aplicación,
  diseño y mínimos pueden no estar incluidos si la fuente no lo especifica.

## Uso

```powershell
python scraper.py run --output-dir outputs\<id-ejecucion>
python scraper.py verify --output-dir outputs\<id-ejecucion>
```

También se puede limitar la ejecución:

```powershell
python scraper.py run --sources expresa_tus_ideas,mugnifico_sublimacion
```

## Salidas

- `precios_tecnicas_personalizacion.csv`: observaciones de precios auditables.
- `catalogo_tecnicas.csv`: compatibilidad, usos, limitaciones y factores de costo.
- `errores.csv`: fuentes bloqueadas, caídas o cambios de estructura.
- `resumen.json`: cobertura y controles de la ejecución.
- El generador de Excel crea `tecnicas_personalizacion_colombia.xlsx` con resumen,
  precios, catálogo, fuentes y errores.

## Interpretación importante

Un polo bordado de $32.900 y un bordado de $X no son el mismo dato: el primero
incluye la prenda. Para modelar `costo_personalizacion` en Supabase deben usarse
preferentemente filas de alcance `solo_marcacion` o `solo_servicio`; los paquetes
sirven como referencia comercial y requieren descomposición o cotización.
