# Scraping de entidades solidarias de Colombia

Pipeline reproducible para consolidar y enriquecer datos públicos de fondos de
empleados, cooperativas y otras organizaciones vigiladas por Supersolidaria.

## Qué produce

- `data/processed/entidades_actuales.csv`: una fila por entidad, elegida desde la
  API oficial según la carga técnica más reciente, la fecha de reporte y la
  completitud del registro.
- `data/processed/entidades_2023-10.csv`: corte histórico normalizado del Excel
  suministrado.
- `data/processed/cambios_contacto_2023_vs_actual.csv`: comparación por NIT de
  teléfonos, correo, dirección y representante legal.
- `data/web/evidencia_web.csv`: cada correo, teléfono, WhatsApp o número de
  asociados encontrado en sitios públicos, acompañado por URL, fecha de consulta
  y estado de coincidencia con NIT, sigla o nombre de la entidad.
  encontrado, acompañado por URL, fecha de consulta y estado de coincidencia
  con NIT, sigla o nombre de la entidad.
- `data/web/base_consolidada_contactos.csv`: una sola fila por entidad actual,
  sin representante legal, con correo y teléfono preferidos, WhatsApp público,
  número de asociados cuando se encuentra en un sitio validado, sitio oficial,
  fuentes, fecha de consulta y nivel de confianza.
- `data/web/errores_web.csv`: URLs no accesibles o bloqueadas por `robots.txt`.

La presencia o ausencia en una tabla **no equivale** por sí sola a determinar el
estado jurídico activo/inactivo de una entidad.

## Fuentes

1. Datos Abiertos Colombia / Supersolidaria: `kg2d-yfyg`. La API expone NIT,
   ubicación, teléfono, correo y representante legal, además de metadatos de
   creación/actualización por fila. Este listado no publica número de asociados.
2. Excel de entidades vigiladas de octubre de 2023, publicado por
   Supersolidaria y entregado como referencia del proyecto.
3. Sitios institucionales públicos descubiertos desde el dominio de un correo
   corporativo o registrados manualmente en `data/manual/websites.csv`. De allí
   se extraen correos, teléfonos, WhatsApp y menciones públicas tipo
   "más de 1.000 asociados".
4. RUES puede servir para validaciones individuales de representación legal,
   pero no se automatiza aquí: puede requerir controles de acceso y sus términos
   deben respetarse.

## Instalación

Python 3.11 o superior:

```powershell
cd scraping
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

## Uso

Configure un `User-Agent` con un correo real antes de hacer rastreo amplio:

```powershell
Copy-Item config.example.json config.json
python scrape.py fetch
python scrape.py build
python scrape.py verify
python scrape.py crawl --config config.json --limit 20
```

Para entidades concretas:

```powershell
python scrape.py crawl --config config.json --nits 860013476,800210714
```

Cuando el correo sea Gmail, Hotmail u otro proveedor público, agregue el sitio
oficial confirmado en `data/manual/websites.csv`. El campo `source_url` debe
explicar de dónde salió esa asociación.

Un dominio inferido desde el correo puede pertenecer a la empresa empleadora y
no al fondo. Por eso `evidencia_web.csv` conserva todos los hallazgos, pero
`entidades_enriquecidas.csv` solo agrega automáticamente los marcados como
`manual_confirmed`, `nit_match`, `acronym_match` o `full_name_match`. Los casos
`unverified_domain_inference` requieren revisión humana.

La base consolidada solo incorpora hallazgos web cuando la página coincide con
el NIT, la sigla o el nombre de la entidad, o cuando el sitio fue confirmado
manualmente. Para completar el universo, conserva como respaldo los datos del
registro oficial actual y, si faltan allí, los del corte de 2023. Un WhatsApp
solo se registra cuando existe un enlace público de WhatsApp en el sitio.

El campo `numero_asociados` se considera una estimación pública de sitio web,
no un reporte oficial fila por fila de Supersolidaria. Se acompaña con
`fuente_numero_asociados`, `contexto_numero_asociados` y
`confianza_numero_asociados` para revisión comercial.

## Regla temporal

El proyecto conserva dos capas: el corte histórico de octubre de 2023 y el
registro actual deduplicado de la API. Además, cada evidencia web lleva
`fetched_at`, `Last-Modified` cuando el servidor lo entrega y una pista de año
visible en la página. Una pista de año no demuestra por sí sola la vigencia del
dato; la URL y el contexto deben revisarse para decisiones sensibles.

## Uso responsable

- Solo recolectar información institucional publicada abiertamente.
- Respetar `robots.txt`, términos del sitio, límites de velocidad y la Ley 1581
  de 2012 sobre protección de datos personales.
- No evadir CAPTCHA, autenticación ni restricciones técnicas.
- No usar nombres o datos personales para contacto masivo sin base jurídica.
- Conservar URL, fecha y contexto para permitir auditoría y correcciones.
