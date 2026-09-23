# Márgenes, filtros y calidad de datos — 17 de septiembre de 2026

Los cambios están en el checkout local y en el proyecto Supabase
`psereyjwjpyakkmnabgm`. No se desplegó la aplicación web en un servidor remoto.

## Márgenes para cualquier cantidad

La calculadora permite agregar, eliminar y editar tanto el inicio de cada tramo
como su porcentaje. Los valores 12/30/50 son ejemplos iniciales editables, no
límites del motor. Los tramos se configuran **para el pedido abierto**; no son una
política global guardada entre sesiones.

1. Activa **Aplicar márgenes por volumen**.
2. Escribe la cantidad inicial y el margen de cada tramo; agrega los necesarios.
3. Introduce la cantidad del producto y valida el precio final antes de emitir.

Cada tramo incluye su cantidad inicial y termina antes del siguiente. El último
no tiene límite superior. Antes del primero se aplica el margen base. Una regla
desde 1.100 cubre 1.150 cuando la siguiente empieza en 1.200. Los márgenes no
pueden aumentar al avanzar de tramo; se rechazan cantidades repetidas, negativas,
fraccionarias y porcentajes fuera de rango. Sin tramos se usa el margen base.
La comparación muestra la cantidad actual y los límites configurados.

Pruebas cubren 1, 100, 110, 1.000, 1.100, 1.150, 1.200 y cantidades superiores.
En navegador autenticado, 1.150 unidades con costo de prueba de $1.000 y tramo
desde 1.100 al 30% produjeron $1.642.857 estimados. Agregar y eliminar tramos
funcionó; un límite duplicado mostró error. No se emitieron cotizaciones de esa
prueba visual. La cantidad de un producto PACK sigue expresándose en paquetes;
los tramos usan sus unidades internas.

## Departamento y ciudad

Los dos selectores de Organizaciones envían automáticamente el formulario,
conservan los otros filtros y reinician la página. Cambiar el departamento limpia
la ciudad anterior. El menú de ciudades contiene las ubicaciones disponibles en
la base para ese departamento. Sin departamento se puede elegir solo ciudad.

Comprobado visualmente: Cundinamarca → Soacha (8 organizaciones), cambio a Bogotá
con limpieza de Soacha y selección de Bogotá sin departamento. La RPC ahora usa
igualdad normalizada; Santander no incorpora Norte de Santander. Las etiquetas
territoriales se contrastaron con el catálogo oficial
[DANE MGN 2025](https://geoportal.dane.gov.co/mparcgis/rest/services/Divipola/Serv_DIVIPOLA_MGN_2025/FeatureServer/317).

## Correcciones efectivamente aplicadas

Se corrigieron **696 campos de 687 registros**:

| Campo | Cambios |
| --- | ---: |
| Municipio de organización | 356 |
| Departamento de organización | 64 |
| Nombre legal de organización | 80 |
| Nombre completo de persona | 196 |

Cada lote tuvo respaldo, vista previa, ensayo con rollback y verificación de
valores antes de confirmar. Se conservaron identificadores, vínculos y snapshots
de precios. Las razones sociales mantienen mayúsculas uniformes, tildes y signos
significativos. No se impuso formato de título a marcas, siglas o nombres propios.

La recuperación de caracteres perdidos se apoyó en el NIT y en la coincidencia
del resto del nombre, usando el
[directorio público de Supersolidaria](https://www.datos.gov.co/resource/kg2d-yfyg.json)
y su [archivo oficial histórico](https://www.supersolidaria.gov.co/sites/default/files/entidades/20231205_listado_entidades_vigiladas_oct_2023.xlsx).
El XLSX fue descargado nuevamente; SHA256
`35824ed306657973c2dc34a502668c9fdcfd594356e9d8e4435952a3d4438356`.
Su fecha histórica no certifica vigencia actual de entidades ni cargos.

## Ofertas e históricos

934 de 972 snapshots históricos no declaran unidad de compra. Entre las ofertas
más recientes revisadas hay 898 sin unidad: 32 además contienen multiplicidades
en el título y 866 carecen de ese indicio. Un título o embalaje no basta para
decidir si el importe es por pieza o por paquete. Por ejemplo, la
[ficha del esfero x50](https://tiendafla.com/producto/2363/esfero-de-lujo-azul-x-50-unds)
describe una caja de 50 y también muestra una etiqueta de precio unitario.

La calculadora y el servidor bloquean **nuevas emisiones con una oferta sin
unidad declarada**. El selector mantiene unidad y costo unitario como desconocidos;
no transforma NULL en UNIT. Esto limita temporalmente los productos cotizables
hasta registrar una nueva observación verificada. Los documentos históricos
permanecen disponibles y sus importes no fueron recalculados.

Para resolver una oferta: comprobar con su fuente precio, moneda, presentación,
cantidad por paquete y condiciones de compra; registrar una nueva observación
con esos datos y URL/fecha; volver a seleccionar el producto y validar. No editar
el snapshot histórico ni dividir automáticamente por un número del título.

## Pendientes con evidencia insuficiente

La auditoría posterior encuentra cero correcciones automáticas adicionales:

- 19 nombres legales de organizaciones sin correspondencia suficiente.
- 160 nombres de personas sin una variante oficial compatible.
- 7 organizaciones sin departamento ni municipio informado.
- Las 898 ofertas recientes sin unidad requieren verificación comercial.

No se eliminaron estos registros ni se inventaron sus valores. La lista por ID,
campo, valor original y motivo está en
`outputs/calidad-viva-20260917-final/pendientes-verificables.csv`.
Las correcciones individuales están en `correcciones-aplicadas.csv` y las copias
actuales de las cinco tablas auditadas en el mismo directorio.

## Verificación técnica

- `npm test` y `npm run lint`: aprobados.
- `npm run verificar`: compilación de producción aprobada.
- 30 archivos SQL locales: aprobados, incluyendo cantidades arbitrarias,
  paquetes, filtros exactos y rechazo de unidad desconocida.
- 5 pruebas Python de recuperación: aprobadas.
- Auditoría estática y `git diff --check`: sin errores.
- Supabase: migraciones 000–082, 83 en total, sin pendientes ni diferencias de
  checksum. Las 209 políticas se conservan.
- Inventario: `outputs/supabase-audit-20260917T225100Z/`.
- Respaldo, planes y comprobantes de cada lote: carpetas
  `outputs/calidad-viva-20260917*`.

Las pruebas visuales de filtros y márgenes se completaron antes del último
ajuste del selector; este último fue validado con SQL local y RPC remota. El
navegador dejó de estar disponible al cierre, por lo que no se atribuye una
segunda comprobación visual a ese ajuste.
