# Scraping de artículos promocionales en Colombia

Módulo independiente del pipeline de entidades solidarias. Reúne productos
publicados por proveedores de Bogotá y, como respaldo, de otras ciudades de
Colombia. No crea un subdominio: una subcarpeta es la separación correcta porque
este repositorio contiene pipelines de datos, no un servidor web.

## Fuentes iniciales

- Tienda FLA (Bogotá): categorías públicas de promocionales y ficha individual.
- Esferos.com / Botón Promo (Bogotá): colecciones públicas de Shopify.
- Colorisa Studio, Verona Studio, NaturalGraphic y MacBrand (Bogotá): páginas
  públicas con precios o fichas visibles.
- INGenios (Villavicencio): respaldo nacional mediante la API pública de tienda.

Las fuentes, ubicación y colecciones se editan en `sources.json`. Los adaptadores
están separados por plataforma para poder agregar otros catálogos sin copiar el
pipeline completo.

## Uso

Desde esta carpeta:

```powershell
python scraper.py run
python scraper.py verify
```

Para una ejecución rápida sin abrir cada ficha de Tienda FLA:

```powershell
python scraper.py run --no-details
```

Para fuentes concretas:

```powershell
python scraper.py run --sources tienda_fla,esferos_com
```

Para actualizar solo algunas fuentes sin borrar las demás de la última salida:

```powershell
python scraper.py run --sources esferos_com --append
```

## Salidas

- `outputs/catalogo_promocionales_colombia.csv`: tabla maestra para Excel/BI.
- `outputs/catalogo_promocionales_colombia.jsonl`: una ficha JSON por línea.
- `outputs/resumen.json`: cobertura por fuente y completitud.
- `outputs/errores.csv`: bloqueos, fallas de red o estructura.

Los precios son una captura del valor publicado al momento de consulta; no son
una cotización y pueden excluir IVA, marcación, flete o mínimos de compra. Cada
fila conserva su URL y fecha. El scraper respeta `robots.txt`, usa pausas por
dominio y no evade autenticación, CAPTCHA ni restricciones técnicas.
