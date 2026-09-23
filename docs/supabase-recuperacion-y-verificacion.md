# Recuperar y verificar Supabase de Estampados

## Actualización del 16 de septiembre de 2026

El proyecto fue reanudado y ya está operativo. Las migraciones 000–079 están
aplicadas y sus checksums coinciden; se verificaron 209 políticas y el flujo HTTP
con PDF y Storage reales. Se rotó la contraseña de la cuenta QA existente.
Consulta [el cierre y sus límites](cierre-supabase-2026-09-16.md).
La sección siguiente conserva el diagnóstico inicial; sus fallos de conexión
ya quedaron resueltos. No hace falta reemplazar las URL ni crear otro proyecto.

## Situación comprobada el 11 de septiembre de 2026

`.env.staging` y `web/.env.local` apuntan al mismo proyecto: `psereyjwjpyakkmnabgm`.
El dominio de su API no resuelve. El dominio del pooler sí resuelve, pero eso no
demuestra que este proyecto esté activo ni que la conexión sea válida.
El navegador disponible abre la pantalla de inicio de sesión de Supabase.
Todavía no se ha consultado ni modificado el esquema remoto en esta recuperación.

La base local de auditoría tiene migraciones 000–078. No es una copia de los
datos de Supabase ni demuestra qué migraciones están aplicadas allí.

## 1. Entrar en la cuenta

Abre [Supabase Dashboard](https://supabase.com/dashboard) e inicia sesión con el
método que ya utilizabas. No crees otra cuenta para resolver un problema de acceso.
Si aparece un código de verificación, complétalo directamente en el navegador.
No pegues contraseñas ni claves secretas en el chat.

Selecciona la organización que contiene Estampados. Comprueba el identificador
del proyecto en la URL del panel y compáralo con `psereyjwjpyakkmnabgm`. El nombre
visible por sí solo no identifica un proyecto de manera inequívoca.

## 2. Recuperar el proyecto existente

- Si está activo, abre el proyecto y consulta su estado antes de editar variables.
- Si aparece pausado, utiliza la opción de reanudar que muestre Supabase para ese
  proyecto y espera a que vuelva a estar operativo.
- Si no aparece, verifica la cuenta y la organización. No crees un proyecto vacío
  suponiendo que reemplaza al anterior: no recuperaría sus datos.
- Si el panel solo ofrece descargar una copia o muestra un error de recuperación,
  guarda esa evidencia y prepara una restauración desde el respaldo disponible.
  No reemplaces una base existente sin verificar qué datos contiene.

La disponibilidad de restauración depende del estado y antigüedad de la pausa;
consulta la [documentación oficial de pausas](https://supabase.com/docs/guides/platform/free-project-pausing)
y la opción que realmente muestre el panel.

## 3. Comparar la configuración

En las opciones de conexión y API del proyecto confirmado, localiza la URL,
la clave publicable o `anon` y la conexión de PostgreSQL. Los nombres y posiciones
del menú pueden variar. Usa los valores mostrados por ese proyecto.

| Valor del proyecto | Archivo local y variable |
|---|---|
| URL de API | `.env.staging`: `SUPABASE_URL` |
| Misma URL | `web/.env.local`: `NEXT_PUBLIC_SUPABASE_URL` |
| Clave publicable o `anon` | `.env.staging`: `SUPABASE_ANON_KEY` |
| Misma clave pública | `web/.env.local`: `NEXT_PUBLIC_SUPABASE_ANON_KEY` |
| URI PostgreSQL | `.env.staging`: `DATABASE_URL` |

La clave `service_role` o `sb_secret_…` nunca se coloca en una variable
`NEXT_PUBLIC_…`. La consola usa la sesión del usuario y RLS. Los scripts de
importación pueden necesitar su clave de servidor por separado.

Conserva el secreto HMAC actual: generar otro arbitrariamente puede romper las
comparaciones de hashes existentes. Si cambia una contraseña, introdúcela en el
gestor o archivo correspondiente sin publicarla en logs ni mensajes.

Los dos archivos de entorno están ignorados por Git. Después de un ajuste,
ejecuta `python scripts/check_env.py` y reinicia Next.js. Ese chequeo valida la
forma de la configuración, no la conectividad: hay que probar también DNS,
autenticación y acceso a la base real.

## 4. Inventariar sin modificar datos

En SQL Editor, ejecuta primero:

```sql
BEGIN READ ONLY;
SELECT current_database(), current_user, version();
SELECT to_regclass('public.schema_migrations') AS registro_migraciones;
ROLLBACK;
```

Si existe `public.schema_migrations`, consulta sus filas de forma compatible con
versiones antiguas del registro:

```sql
BEGIN READ ONLY;
SELECT to_jsonb(m) AS migracion
FROM public.schema_migrations m
ORDER BY m.filename;
ROLLBACK;
```

Compáralas con `database/migrations/CHECKSUMS.txt`, normalizando BOM y CRLF como
hace `scripts/apply_pending_migrations.ps1`. Un checksum ausente o reconstruido
no prueba que las definiciones coincidan. Una diferencia debe investigarse antes
de aplicar nuevas migraciones; no se corrige falsificando el checksum remoto.

Ejecuta `database/diagnostics/supabase_security_inventory.sql`. Produce una celda
JSON con esquemas, tablas, vistas, columnas, políticas, funciones, constraints,
triggers, roles, permisos por defecto y extensiones. Exporta el resultado completo,
no una captura truncada. No lee filas de clientes, usuarios ni secretos; las
definiciones internas se conservan en archivos locales de auditoría.

Este diagnóstico ya se ejecutó en la base local: 209 políticas, 64 relaciones y
338 funciones. Son cifras de referencia local, no cifras del proyecto remoto.
Los objetos administrados por Supabase pueden diferir del bootstrap local;
se distinguen de los objetos de negocio antes de proponer cambios.

## 5. Verificar políticas y comportamiento

Revisa también Security Advisor y Performance Advisor del proyecto. Sus avisos
son pistas, no una orden de aplicar automáticamente todas las sugerencias.
Consulta [Advisors](https://supabase.com/docs/guides/observability/advisors).

La revisión debe comprobar RLS, grants, políticas permisivas y restrictivas,
funciones `SECURITY DEFINER`, `search_path`, ejecución de RPC, vistas y Storage.
Una consulta ejecutada como `postgres` o con una clave privilegiada no demuestra
que un usuario ordinario tenga los mismos límites. RLS y permisos de operación
se verifican conjuntamente: [documentación oficial](https://supabase.com/docs/guides/database/postgres/row-level-security).

Prueba el comportamiento esperado con perfiles de prueba y sesiones reales:

| Perfil | Verificación esencial |
|---|---|
| Anónimo | Sin acceso a los datos internos del CRM ni RPC privilegiadas. |
| LECTURA | Lecturas permitidas y datos enmascarados; sin edición, costos internos ni PDF de ADMIN. |
| COMERCIAL | Operaciones comerciales autorizadas; sin ajuste interno de márgenes/costos ni acceso a PDF de ADMIN. |
| ADMIN | Costeo y ajustes autorizados; PDF registrado e inmutable. |
| Perfil inactivo | Sin acceso a consola y operaciones protegidas. |

El detalle de cada tabla se compara con la política del repositorio. La matriz
anterior no concede permisos nuevos. Para Storage hay que probar subida,
registro, descarga, intento de sobrescritura, acceso por otro rol y limpieza de
archivos sin registro. Consultar `pg_policies` por sí solo no basta.

## 6. Corregir y aplicar únicamente lo pendiente

Antes de modificar el destino, confirma su identidad, guarda el esquema previo y
verifica un respaldo recuperable. El respaldo de PostgreSQL no incluye los bytes
de los objetos de Storage: estos requieren su propio respaldo.

No ejecutes el bootstrap de `database/ci/` en Supabase: es exclusivo de la base
aislada. No cargues los seeds de auditoría sobre datos reales. No vuelvas a
ejecutar todas las migraciones desde cero sobre un proyecto existente.

Con la URI del destino ya verificada en `DATABASE_URL`, el runner es:

```powershell
./scripts/apply_pending_migrations.ps1
```

El runner escribe en la base. Se utiliza después de comparar el inventario y los
checksums. Si hay diferencias en migraciones ya aplicadas, prepara una migración
correctiva nueva en lugar de editar el historial. No ejecutes la suite completa
de fixtures sobre un entorno real sin revisar su aislamiento y efectos.

## 7. Comprobar la aplicación y cerrar pendientes

Reinicia el servicio local tras actualizar su configuración. Prueba login y salida,
navegación, búsqueda de clientes, selección de productos y cotizaciones de 1, 12,
30 y 50 unidades. Comprueba que los costos fijos no se multiplican, que los cambios
invalidan la previsualización y que el total emitido coincide con el validado.
Genera, archiva y descarga el PDF; verifica el importe y las restricciones por rol.

La contraseña incrustada que se retiró de scripts QA debe rotarse si continúa
vigente. La rotación y la actualización del secreto de QA se completan sin
volver a guardar credenciales en los scripts.

Registra por separado los resultados locales, las migraciones realmente
aplicadas en Supabase y las pruebas con la API real. Un login correcto no cierra
por sí solo la auditoría de seguridad.
