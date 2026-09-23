> Actualización del 17 de septiembre: ver [márgenes, territorio y calidad](margenes-territorio-calidad-2026-09-17.md). Incluye tramos editables, correcciones de datos y bloqueo de ofertas sin unidad declarada.

# Recuperación y verificación de Supabase — cierre del 16 de septiembre de 2026

## Resultado

El proyecto `psereyjwjpyakkmnabgm` (`estampados_promocionales_mattian`) estaba
pausado. Se reanudó con autorización explícita, conservando su identidad, datos
y configuración. La API, PostgreSQL, autenticación y Storage volvieron a funcionar.
No fue necesario cambiar la URL ni las claves de conexión del proyecto.

El servicio local está disponible en http://127.0.0.1:3000. El frontend sigue local;
no se hizo un despliegue web remoto, un push ni un commit. El directorio de trabajo
mantiene los cambios anteriores y las correcciones de esta tarea.

## Cambios aplicados al proyecto remoto

Se confirmó que las migraciones 000–076 ya estaban aplicadas y coincidían con los
archivos locales. Antes de modificar el esquema se guardaron el inventario de
seguridad y un respaldo PostgreSQL de `public`, con datos, en:

`outputs/supabase-audit-20260911T204448Z/public-before.dump`

El respaldo terminó correctamente, tiene 7.520.039 bytes y su índice pudo leerse
con `pg_restore`. Es un respaldo de `public`, no una copia de los bytes de Storage
ni de todos los esquemas administrados por Supabase.

Se aplicaron y registraron en transacciones:

- **077:** cierre de costos y eventos internos por RLS; documentos ADMIN aislados;
  archivos PDF inmutables; registro de archivos propios y limpieza de huérfanos.
- **078:** previsualización y emisión con el mismo motor; márgenes por línea,
  costos editados, retenciones y rechazo de un total distinto al validado.
- **079:** `search_path` fijo en cinco funciones; eliminación de permisos de
  escritura innecesarios en la vista de calidad; traslado de `btree_gist` a
  `extensions`, preservando las dependencias de los índices.

Verificación posterior: **80 migraciones (000–079), cero pendientes y cero
diferencias de checksum**. Los checksums de 000–023 figuran como reconstruidos
históricamente; por eso también se compararon definiciones y políticas, sin
tratar el checksum como única prueba.

## Políticas y avisos

- Las **209 políticas** del inventario remoto coinciden con las políticas de la
  base local corregida.
- Todas las tablas de negocio en `public` tienen RLS habilitado.
- Ninguna función de `public` conserva un `search_path` mutable.
- Ninguna función `SECURITY DEFINER` de `public` tiene ejecución para `anon`.
- Se probaron ADMIN, COMERCIAL, LECTURA y perfil inactivo en el motor real. Los
  cambios temporales del perfil QA se revirtieron y se comprobó su rol original.

Security Advisor muestra **0 errores y 58 advertencias**:

- **57** corresponden a RPC `SECURITY DEFINER` ejecutables por usuarios
  autenticados. Son la interfaz de operaciones controladas de la consola. Se
  conservan las autorizaciones y sus controles internos de rol; dos wrappers
  delegan la validación al núcleo protegido. No se revocaron a ciegas para
  ocultar avisos ni se marcaron como ignorados. El inventario no sustituye una
  prueba exhaustiva de todas las combinaciones de argumentos de cada RPC.
- **1** corresponde a protección contra contraseñas filtradas. El panel indica
  que está disponible únicamente en **Pro o superior**. Sigue desactivada: no se
  contrató un plan ni se autorizaron cargos. Este es un límite pendiente del plan.

## Pruebas con el servicio real

**22 comprobaciones HTTP satisfactorias**, con la cuenta COMERCIAL de QA existente:

- Login real y renderizado autenticado del inicio, clientes, cotizador y detalle.
- Imposibilidad de leer costos/eventos directamente o documentos ADMIN.
- Denegación de firma de descarga de un PDF ADMIN.
- Generación, subida, registro y descarga del PDF de la cotización QA existente
  #154. Los bytes descargados de Storage coinciden con los entregados por la ruta.
- Rechazo de sobrescritura y `upsert`; intento de borrado sin pérdida del PDF.
- Subida y limpieza únicamente de un objeto temporal propio sin registrar.
- Rechazo de acceso anónimo al PDF.

Se conservan dos nuevas generaciones del PDF de prueba en el historial de #154:
la primera comprobación y la regeneración posterior a corregir la razón social.
No se creó un pedido, no se envió un correo ni se emitió una factura.

**40 comprobaciones SQL satisfactorias**, dentro de una transacción revertida:
escenarios de 1, 12, 30 y 50 unidades; costo fijo; margen; precio unitario
decreciente; rechazo de totales alterados; emisión igual a previsualización;
restricciones de perfiles y comprobación del rollback. Las cuatro cotizaciones
temporales no quedaron guardadas. Las secuencias PostgreSQL pueden consumir
números al probar emisiones aunque las filas se reviertan.

Ejemplo controlado con costo de $1.000/unidad y $6.000 fijos, sin retenciones:

| Unidades | Margen | Total validado y emitido en la prueba |
|---:|---:|---:|
| 1 | 40% | $11.700 |
| 12 | 35% | $27.800 |
| 30 | 30% | $51.500 |
| 50 | 25% | $74.700 |

Son costos de prueba, no precios de mercado. Los márgenes por cantidad son
configurables por ADMIN y la opción se activa expresamente en el cotizador.

El PDF se renderizó y se comprobó su lectura: una página, número #154 y total
$213.400 coincidente con la base. El correo aparece enmascarado para COMERCIAL.
Se detectaron signos `?` y comillas duplicadas en la razón social del cliente de
esa cotización: estaban en `organizacion.nombre_legal`, no los introducía el PDF.
Se contrastó el NIT con la [ficha oficial de Bogotá Jurídica](https://www.bogotajuridica.gov.co/SPJ/ver_Entidad.jsp?eid=919770),
se conservaron los bytes originales (ISO-8859-1), se respaldó la fila y se ensayó
la corrección con rollback. Después se corrigió únicamente `nombre_legal` por su
ID y NIT, conservando el valor anterior y la fuente en
`outputs/supabase-http-final/correccion-nombre-aplicada.json`. Es una recuperación
de codificación verificada, no una certificación actual de vigencia de la entidad.
Se volvió a generar el PDF como documento nuevo; el archivo histórico permanece.

La habilidad de calidad de datos también produjo copias normalizadas e incidencias
de los CSV locales en `outputs/data_quality_20260916_recovery/`. No se cargaron
esas normalizaciones masivas en Supabase ni se modificaron otras organizaciones.

## Credencial QA

Se rotó únicamente la contraseña de la cuenta de pruebas identificada por
`.qa_test_account_user_id`, con rol COMERCIAL y dominio `prueba.local`.
La contraseña anterior fue rechazada, la nueva permitió iniciar sesión y se
revocaron las sesiones de QA. La nueva contraseña quedó en
`.qa_test_account_password`, ignorado por Git. No se modificaron cuentas personales
ni claves API del proyecto. Los scripts ya no contienen contraseñas literales.

## Evidencias y repetición

- Inventario final: `outputs/supabase-audit-20260917T042729Z/` (marca UTC; fecha local 16).
- Pruebas HTTP: `outputs/supabase-http-final/resultado.json`.
- Pruebas SQL: `outputs/supabase-http-final/resultado-sql.json`.
- PDF y comprobación de contenido: el mismo directorio de resultados HTTP.
- Rotación sin incluir la contraseña: `credential-rotation.json` en ese directorio.
- Historial de aplicación: `outputs/supabase-audit-20260911T204448Z/applied-migrations.log`.

Para comprobar únicamente el esquema, sin mutaciones:

```powershell
python scripts/inspect_supabase.py --expected-project psereyjwjpyakkmnabgm
```

`scripts/verify_supabase_quote.py` prueba emisiones con rollback y puede consumir
números de secuencia. `web/scripts/qa-supabase-http.mjs` requiere las variables QA
y crea una generación PDF real; no es un chequeo de solo lectura.

La guía para recuperar el proyecto si vuelve a pausarse está en
[supabase-recuperacion-y-verificacion.md](supabase-recuperacion-y-verificacion.md).
### Comprobación visual autenticada — 17 de septiembre

Se reinició el servicio local y se navegó con la sesión ADMIN existente desde
Resumen hasta Cotizador, conectado al proyecto remoto. Se seleccionó el producto
Boiler New Gym Policarbonato 500ml de Tienda FLA y, únicamente en la vista previa,
se configuró costo unitario de prueba de $1.000, costo fijo de línea de $6.000,
sin marcación ni retenciones. No se alteró la oferta del proveedor.

| Unidades | Margen | Total validado por servidor |
| --- | --- | --- |
| 12 | 35% | $27.800 |
| 30 | 30% | $51.500 |
| 50 | 25% | $74.700 |
| 50 | 20% configurado manualmente | $70.000 |

Cambiar cantidad o margen eliminó la validación anterior y deshabilitó la
emisión hasta volver a validar. La captura de la pantalla de validación mostró
el total y controles legibles. No se emitieron cotizaciones en esta prueba
visual; se recargó la página para eliminar el escenario de prueba y se dejó
abierto el cotizador. La emisión y PDF están cubiertos por las pruebas HTTP/SQL
descritas arriba; esto no constituye una prueba visual de todos los flujos.

Persisten pendientes de calidad de datos históricos: el resumen muestra 882
revisiones abiertas y 5.639 organizaciones sin tipo normalizado. Hay nombres con
caracteres dañados y ofertas con títulos que mencionan paquetes pero aparecen
como precio por unidad (por ejemplo, Esfero De Lujo Azul X 50 Unds). Requieren
contrastar la oferta y su unidad con la fuente antes de cotizar esos productos;
no se corrigieron por inferencia a partir del título. La corrección puntual de
GM-BANK descrita arriba no equivale a una limpieza completa del catálogo/CRM.
