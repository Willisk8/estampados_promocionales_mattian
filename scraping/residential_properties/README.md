# Scraping de conjuntos residenciales y propiedad horizontal en Colombia

Pipeline reproducible para consolidar registros **oficiales y municipales** de
propiedad horizontal publicados en Datos Abiertos Colombia.

## Alcance real

Colombia no tiene hoy una API nacional abierta y exhaustiva de propiedades
horizontales. La inscripción y la certificación de existencia y representación
legal se gestionan territorialmente. Por eso esta base cubre únicamente los
municipios incluidos en `sources.json` y no debe describirse como “todos los
conjuntos de Colombia”.

El campo `legal_representative` significa **representante o administrador según
la fecha de actualización de la fuente**, no una certificación de que continúa
vigente hoy. `representative_temporal_status` obliga a distinguir fuentes
recientes de las que requieren validación individual. En Bogotá, la consulta
RUA es apropiada para validar casos concretos, pero no se automatiza ni se
intentan eludir sus restricciones de acceso.

El archivo distrital de Bogotá publica `Nombre Persona Contacto`, que se conserva
separado como `contact_person`: no se presume que esa persona sea representante
legal. La fuente de Bogotá está fechada en marzo de 2023 y requiere validación
actual antes de cualquier uso sensible.

## Uso

```powershell
cd scraping/residential_properties
python scraper.py run --user-agent "EstampadosData/1.0 (correo@dominio.co)"
python scraper.py verify
```

Para probar una sola fuente:

```powershell
python scraper.py run --sources a9yz-vh6j
```

## Salidas

- `outputs/propiedades_horizontales_colombia.csv`: universo publicado por las
  fuentes configuradas, incluyendo uso no determinado.
- `outputs/conjuntos_residenciales_colombia.csv`: subconjunto clasificado como
  residencial confirmado o probable por los campos/nombre de la fuente.
- `outputs/propiedades_horizontales_colombia.jsonl`: salida auditable por fila.
- `outputs/resumen.json`: cobertura, fechas y completitud por municipio.
- `outputs/errores.csv`: fuentes que fallaron sin detener las demás.

Cada registro conserva URL, ID de fuente, fecha de la fuente y fecha de
consulta. Se guardan únicamente correos y teléfonos publicados por la entidad
territorial como contacto de la copropiedad. Un dato publicado puede pertenecer
al administrador y debe revisarse antes de activarlo comercialmente. No se
recolectan cédulas, datos de residentes ni números descubiertos en fuentes no
institucionales.

## Calidad y actualización

Las etiquetas `RESIDENCIAL_CONFIRMADO`, `RESIDENCIAL_PROBABLE`,
`NO_RESIDENCIAL` y `USO_NO_DETERMINADO` son una clasificación operativa, no una
decisión jurídica. No conviene descartar `USO_NO_DETERMINADO` antes de una
revisión, porque varios municipios no publican el uso del inmueble.

Antes de usar un representante para una gestión sensible, obtenga o consulte el
certificado vigente ante la alcaldía competente. Para contacto comercial, use
preferentemente buzones institucionales y documente la base jurídica, la
finalidad, la política de tratamiento y el mecanismo de exclusión.
