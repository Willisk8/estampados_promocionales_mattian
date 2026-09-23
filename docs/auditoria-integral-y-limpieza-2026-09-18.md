# Auditoría integral y limpieza

Informe cerrado el 18 de septiembre de 2026 con ejecuciones del 17 de septiembre (hora Colombia).

## Entornos

La web se ejecuta localmente y consume el proyecto real Supabase `psereyjwjpyakkmnabgm`. El nombre `.env.staging` no garantiza aislamiento: este proyecto es el entorno remoto principal utilizado por la aplicación. Las pruebas SQL de esta revisión se ejecutaron exclusivamente en PostgreSQL local, base `estampados_audit_final`, con rollback. La revisión remota de esta entrega fue de solo lectura. No se desplegó la web ni se eliminaron registros remotos.

## Limpieza efectuada

Se eliminaron 51 archivos, 734.696 bytes, en 12 directorios de caché Python/pytest. Antes de eliminarlos se comprobó que las rutas resueltas pertenecían al proyecto y no contenían archivos versionados. Son regenerables y no contienen lógica funcional. Manifiesto: `outputs/auditoria-integral-20260917/limpieza.json`.

Se conservaron migraciones, pruebas, originales, respaldos, evidencias de QA, dependencias, bases locales, worktrees y compilaciones que podrían estar en uso. Un archivo no versionado no es necesariamente basura. No se certifica que todo archivo restante sea indispensable: no se eliminó código por una mera ausencia de referencias textuales.

## Datos remotos

El nuevo auditor `scripts/data_quality/audit_public_tables.py` examinó 51 tablas públicas, 85.029 filas y sus columnas de texto, con una transacción de solo lectura y snapshot consistente. Genera conteos sin exportar valores personales. Evidencia: `outputs/auditoria-integral-20260917/public-tables.json`.

Todas las tablas públicas tenían RLS habilitado y no había restricciones marcadas como no validadas. Esto no demuestra por sí solo que todas las políticas sean correctas: esa conclusión requiere pruebas de acceso por rol. Esta ejecución no repitió toda la auditoría de permisos HTTP anterior.

Hallazgos adicionales:

- Organizaciones/clientes: 5.639 registros, sin grupos de NIT duplicados. Se detectaron caracteres perdidos en 15 siglas y 25 direcciones. El examen textual genérico detecta solo patrones fuertes y no sustituye la comparación con fuentes oficiales.
- Catálogo interno: dos nombres de producto, dos descripciones y dos nombres de variante contienen caracteres de reemplazo. No se reconstruyeron por intuición.
- Contactos: 16.211 registros. Hay 4.248 teléfonos/WhatsApp en revisión, 52 teléfonos inválidos y 58 emails en revisión. Tres teléfonos actualmente ACTIVE corresponden a numeración de servicio y requieren contraste con SIGRI; no son automáticamente números inexistentes. Sus identificadores están en `active-phones-review.json`. No se encontraron diferencias adicionales con las reglas de normalización usadas para emails y websites activos.
- Proveedores: ocho registros, uno sin ciudad. La tabla no tiene campo NIT: la identidad fiscal y la deduplicación por NIT no pueden auditarse con este modelo. Conservar nombres de marca con mayúsculas, tildes y puntuación no constituye un error.

La auditoría específica previa, del mismo día, dejó 19 nombres de organización y 160 nombres de persona pendientes de fuente, siete ubicaciones incompletas y 898 ofertas actuales sin unidad de compra verificada. Sus conteos son más amplios que el detector genérico nuevo. Se conservan en `outputs/calidad-viva-20260917-final/pendientes-verificables.csv`; este nuevo escaneo no volvió a ejecutar el contraste completo con las fuentes. Las 696 correcciones anteriores tienen trazabilidad en ese mismo directorio.

## Archivos de importación

Se volvió a ejecutar `audit_datasets.py` sobre seis familias locales: 5.639 organizaciones, 935 productos promocionales, 12 técnicas, 65 precios de técnicas, 8.342 conjuntos residenciales y 18 proveedores de fuentes. No son los mismos conteos ni necesariamente el mismo estado de los datos cargados en Supabase.

El resultado contiene 11.761 incidencias: 11.658 de revisión y 103 errores, con 81 filas de organizaciones clasificadas INVALID. Incluye formatos de teléfono/email, DV, territorios e inferencias que deben conservar trazabilidad. Muchas revisiones corresponden a fechas sin zona o indicativos inferidos. Los originales no se sobrescribieron. Evidencia: `outputs/data_quality_cleanup_20260917/resumen_calidad.json` e `incidencias_calidad.csv`.

## Fallo corregido

`normalize_url` podía lanzar una excepción con puertos no numéricos/fuera de rango o nombres de host incompatibles con IDNA. Ahora devuelve INVALID_FORMAT y permite continuar la auditoría. Se añadió regresión con puertos inválidos, hostname demasiado largo y una URL válida como control.

## Pruebas verificadas

| Capa | Ejecución y resultado |
|---|---|
| Python | 39 pruebas del directorio tests y nueve de scraping residencial: pasan |
| Backend SQL | 30 archivos de pruebas sobre PostgreSQL local: pasan; evidencia sql-tests.json |
| Frontend | npm test: cuatro scripts de verificaciones; pasan |
| TypeScript | npm run lint (tsc --noEmit): pasa |
| Claves privilegiadas | npm run check:privilegios: pasa |
| Repositorio | audit_change.py --all: sin hallazgos dentro de sus reglas; diff --check sin errores |

La salida de un test Python incluye deliberadamente un resultado `ok: false` para una fuente vacía: el test valida ese rechazo y la suite termina OK.

CI configura Python, migraciones y tests SQL, evals, verificaciones del frontend y build. Existen scripts E2E y `npm run test:ui`, pero no están integrados en CI. Esta entrega no ejecutó de nuevo una suite visual completa, un build ni todas las pruebas HTTP remotas; tampoco midió cobertura de código. No debe interpretarse como certificación de todos los flujos de usuario.

## Pendientes materiales

Resolver nombres/direcciones dañados con fuente verificable; completar ciudad e identidad fiscal de proveedores; validar los tres números de servicio activos; documentar unidad/alcance de las ofertas antes de usarlas; integrar regresiones visuales en un entorno aislado; y separar inequívocamente un Supabase de pruebas del proyecto principal antes de ampliar pruebas con escrituras.

La auditoría estructural no inspeccionó contenido dentro de JSON, archivos de Storage, vigencia real de contactos ni todos los escenarios funcionales. No se considera toda la base normalizada ni todo el proyecto libre de fallos.
