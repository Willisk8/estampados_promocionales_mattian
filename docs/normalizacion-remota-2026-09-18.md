# Normalización aplicada en Supabase

Proyecto: `psereyjwjpyakkmnabgm`. Autorización: solicitud del usuario de normalizar los registros de la base remota. No se trata de cambios sobre la base local de pruebas.

## Cobertura y procedimiento

Se respaldaron las filas de las 51 tablas públicas (85.029 registros) en JSON. Se recorrieron todos los registros, incluidos valores anidados en JSON, para detectar caracteres perdidos y formas Unicode no canónicas. No se inspeccionaron ni modificaron contraseñas de Auth, objetos de Storage ni otras bases no identificadas en este proyecto.

Se prepararon planes separados de original/normalizado, con fuentes y hashes de los respaldos. Cada lote se ensayó en una transacción revertida antes de aplicarlo; las actualizaciones exigen que el valor original siga siendo el mismo y verifican el resultado. No se eliminaron ni fusionaron entidades, ni se cambiaron identificadores, precios, consentimientos o relaciones.

## Cambios guardados

| Campo | Correcciones |
|---|---:|
| Siglas de organizaciones | 13 |
| Direcciones de organizaciones | 21 |
| Nombres de organizaciones | 4 |
| Nombres y descripciones de productos propios | 4 |
| Nombres de variantes | 2 |
| Teléfonos ACTIVE pasados a REVIEW_REQUIRED | 3 |
| Total de campos | 47 |

Las direcciones conservan el mismo texto salvo los caracteres recuperados: no se sustituyeron por domicilios distintos de otra fecha. Los teléfonos son numeración de servicio pendiente de validación adicional; sus valores originales se conservaron.

Se recuperaron textos del catálogo propio por SKU desde `scripts/catalog/mvp_catalog_inputs.json`. Siglas y direcciones se contrastaron por NIT con el XLSX oficial de Supersolidaria conservado. También se contrastaron los registros originales de importación y todas las cargas del CSV histórico disponible; solo se aceptaron candidatos únicos compatibles con el texto completo.

Los cuatro nombres adicionales se verificaron mediante NIT en fuentes públicas:

- [Coombo: estados financieros](https://coombo.co/wp-content/uploads/2022/04/2_estados_financieros_2021.pdf).
- [Cooperativa Nuestra Unión: sitio oficial](https://www.nuestraunion.coop/vision/).
- [Fondo de Empleados Compañía de Jesús Nariño: resolución de Supersolidaria](https://www.supersolidaria.gov.co/sites/default/files/data/20240423_resolucion_2024430002695_22_abril_2024_0.pdf).
- [UNILAC: resolución de CORNARE](https://www.cornare.gov.co/boletin_oficial/2018/mayo/res/r131-0576-2018.pdf).

Estos documentos respaldan la recuperación de caracteres; no certifican vigencia actual de representantes, precios o estados legales.

## Pendientes que no se pueden reconstruir automáticamente

Quedan 319 campos de texto señalados para revisión: 15 nombres de organización, 160 nombres de persona, seis siglas, 133 direcciones y cinco descripciones de productos de proveedor. El indicador incluye signos de interrogación: no todos representan un error confirmado, especialmente en descripciones o direcciones. Las fuentes disponibles no permiten una sustitución inequívoca.

Continúan además los pendientes ya documentados de ubicaciones incompletas, identidad fiscal de proveedores y unidades de compra sin verificar. La limpieza textual no resuelve esos datos ausentes. No se inventaron nombres, NIT, ciudades ni unidades.

Los originales de importación, precios históricos y documentos emitidos se preservan como evidencia. Alterarlos para ocultar diferencias destruiría su trazabilidad; la normalización se aplica al registro operativo que corresponde, no a una reescritura del pasado.

## Evidencia y pruebas

- `outputs/normalizacion-remota-20260918/`: respaldo inicial, hashes, plan de 43 cambios, resultado de aplicación y verificación final remota.
- `outputs/normalizacion-remota-20260918-fuentes/`: respaldo previo al segundo lote, fuentes públicas, cuatro cambios adicionales y 319 pendientes identificados por tabla/ID/campo.
- `scripts/data_quality/normalize_remote_records.py`: procedimiento reproducible; impide reutilizar un respaldo ya aplicado.
- 43 pruebas Python del directorio `tests` pasaron, incluidas regresiones de recuperación por fuente, rechazo de candidatos ambiguos y conservación de puntuación.

La revisión final abre una conexión independiente de solo lectura, comprueba los 47 valores guardados, compara los conteos de todas las tablas con el respaldo y comprueba las claves de búsqueda de organizaciones. Esta entrega no equivale a afirmar que todos los datos sean correctos o que todas las fuentes externas estén vigentes.
