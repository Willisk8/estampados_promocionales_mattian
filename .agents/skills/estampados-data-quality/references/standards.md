# Estándares transversales

## Texto

- Codificación: UTF-8.
- Forma canónica: Unicode NFC. No quitar tildes del nombre canónico.
- Limpieza segura: quitar BOM, controles y saltos; colapsar espacios; retirar solo comillas que envuelven todo el valor.
- Matching: clave NFKD/ASCII minúscula separada. Nunca sustituye el texto visible.
- Fuente: https://www.unicode.org/reports/tr15/

## Identificadores colombianos

- NIT base y dígito de verificación son campos separados. El DV no integra el NIT base; no usar puntos, guiones ni letras en el campo base.
- Validar el DV algorítmicamente solo como control de digitación; no prueba existencia ni vigencia ante DIAN/RUT.
- Fuente: https://normograma.dian.gov.co/dian/compilacion/docs/resolucion_dian_0004_2019.htm

## Territorio

- Usar código DIVIPOLA de cinco dígitos como identificador de municipio/distrito/área no municipalizada.
- Conservar etiquetas oficiales de departamento y municipio. Los alias o coincidencias difusas quedan en revisión.
- Fuente: https://www.dane.gov.co/index.php/sistema-estadistico-nacional-sen/normas-y-estandares/nomenclaturas-y-clasificaciones/nomenclaturas/codificacion-de-la-division-politico-administrativa-de-colombia-divipola

## Telefonía colombiana

- Número nacional fijo: 10 dígitos con NDC `601`, `602`, `604`, `605`, `606`, `607` o `608`, más siete dígitos. `603` no es geográfico.
- Móvil terrestre: NDC `300–305`, `310–324` o `333`. `350–352` es móvil/trunking; `308` es satelital; otros `3XX` pueden estar reservados.
- Retirar `+57`, `57` o `0057` solo cuando quede un número nacional reconocido. El antiguo `03` se puede retirar de un móvil reconocido, dejando incidencia.
- Un fijo de siete dígitos necesita el indicativo regional; se puede completar con DIVIPOLA dejando trazabilidad.
- `01800/018000` es numeración de servicio y se valida aparte, idealmente contra SIGRI.
- La forma no prueba que la línea exista, esté activa o pertenezca a un operador; la portabilidad impide inferir operador actual por prefijo.
- Fuente: https://normograma.crcom.gov.co/crc/compilacion/docs/circular_crc_0127_2020.htm

## Email, URLs y fechas

- Email: preservar el `local-part`; pasar solo el dominio a minúscula. La forma RFC no confirma que el buzón exista.
- Fuente email: https://www.rfc-editor.org/info/rfc5321/
- URL: exigir HTTP/HTTPS, host válido, esquema y host en minúscula; retirar fragmento para identidad si no es relevante.
- Fecha: `YYYY-MM-DD`; timestamp RFC 3339/ISO 8601 con `Z` u offset. Una fecha sin zona queda en revisión.
- Fuente fecha: https://www.iso.org/iso-8601-date-and-time-format.html

## Productos y unidades

- SKU es identificador interno del proveedor y se conserva como texto.
- GTIN solo se marca válido si pasa longitud/check digit y fue asignado; no inventarlo desde el SKU.
- Fuente GTIN: https://gs1co.org/soluciones/identificacion/numeros-globales-de-identificacion-de-productos-gtin
- UNSPSC es clasificación opcional para interoperabilidad/contratación; no sustituye categorías comerciales internas.
- Fuente UNSPSC: https://operaciones.colombiacompra.gov.co/clasificador-de-bienes-y-Servicios
- Moneda en ISO 4217 (`COP`); importes como decimal, nunca texto con símbolos. Unidad y alcance del precio son obligatorios para cálculo.
