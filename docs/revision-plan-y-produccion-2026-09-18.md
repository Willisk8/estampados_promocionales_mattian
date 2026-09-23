# Revisión del plan y preparación para producción

Fecha: 2026-09-18. Dictamen: arquitectura viable para continuar; MVP comercial parcialmente cerrado; promoción a producción todavía no aprobada por la evidencia disponible.

> Aclaración posterior del usuario: el objetivo es cotizar por cliente desde cualquier
> proveedor, sin exigir cinco productos propios. Las recomendaciones de ese requisito
> en este informe quedan sustituidas por el [plan vigente](plan-cotizador-por-cliente-2026-09-19.md).

## Alcance y limitación

El enlace compartido de ChatGPT `https://chatgpt.com/share/6aad3f25-4f74-83e9-8f63-82ea8c3feeaf` inicialmente falló, pero en el siguiente intento sí abrió con el título **Validar idea Alibaba**. Se leyó el texto visible y se expandió el mensaje largo. Los archivos adjuntos aparecen como «Archivo cargado»; su contenido no quedó disponible en esta lectura. La matriz siguiente contrasta los planes versionados `plan_trabajo_cierre_mvp.md`, `pre_pilot_gates.md` y `staging_prod_separation_plan.md` y aún debe ampliarse con la verificación detallada del plan recuperado.

El acuerdo final visible del chat propone un único motor de cotización desde costos versionados, tarifas publicadas opcionales con coincidencia exacta de configuración, relación producto/técnica/sustrato, preparaciones separadas de diseños, merma, margen por componente y políticas versionadas, redondeo consistente, histórico congelado, control de salud de tarifas y aprobación/bloqueo por margen. Exige escenarios de los cinco productos y pruebas en los límites de escala. Son requisitos a contrastar con código y pruebas, no evidencia de que ya estén implementados. Los precios y porcentajes del chat son ejemplos, no costos comerciales verificados.

## Entornos y conexiones comprobados

- Supabase MCP conectado: proyecto `psereyjwjpyakkmnabgm`, estado `ACTIVE_HEALTHY`, PostgreSQL 17.6.1.155.
- GitHub conectado como `Willisk8`, acceso confirmado a `Willisk8/estampados_promocionales_mattian`.
- La aplicación corre localmente y utiliza la base remota real. Las pruebas SQL/visuales automatizadas usan una base PostgreSQL local aislada. Son dos contextos distintos.
- Los nombres `.env.staging` y la antigua etiqueta visual STAGING no garantizan aislamiento. Se retiró la etiqueta fija de la interfaz para evitar esa afirmación.
- GitHub `master` apunta a `0a35d809b0848bbd5d6b2841472e7ffd0c58e8d9`; el checkout local está 12 commits por delante de origin/master, además de cambios sin commit.
- Últimos CI y Deploy Staging remotos consultados: 2026-08-28, satisfactorios para ese SHA antiguo. **No prueban los cambios actuales.** No se hizo push ni despliegue web.
- La API de GitHub devuelve `protected=false` para master. La protección prevista por el plan sigue pendiente.

## Cumplimiento del plan versionado

| Objetivo | Evidencia actual | Dictamen |
|---|---|---|
| Sincronizar GitHub, staging y base | GitHub permanece en agosto; Supabase registra 85 migraciones y el checkout incluye 000–084 | Pendiente; existe divergencia real |
| CRM y trazabilidad | 13.589 organizaciones, 17.503 canales; importación residencial con originales y cola de revisión | Implementado, con calidad pendiente |
| Cinco productos propios | Consulta remota confirma 5 ACTIVE | Existencia cumplida; ACTIVE no certifica costos comerciales |
| Costos proveedor y marcación confiables | Guardas 081–082 bloquean unidades de compra desconocidas; auditoría previa de esta tarea encontró 898 ofertas recientes sin unidad suficientemente confirmada | Pendiente curación; no quitar la guarda para aparentar operatividad |
| Cálculo reproducible y por volumen | Previsualización SQL, emisión verificada, costos fijos por pedido, escalas editables y pruebas de cantidades arbitrarias | Funcional en escenarios probados |
| Políticas mayoristas reutilizables | Escalas configurables durante la cotización | Parcial: falta administración persistente y versionada de políticas globales |
| Histórico y documentos | Snapshots, componentes, versiones y PDF persistente en la implementación; pruebas específicas existentes | Implementado con cobertura parcial; completar recorrido integral en entorno de release |
| Datos territoriales | Filtros dependientes y coincidencias exactas; alias El Espinal resuelto contra DIVIPOLA 73268 | Implementado; no inventar ubicaciones ausentes |
| Propiedad horizontal | Importador idempotente; 7.950 organizaciones cargadas; 392 candidatas ambiguas conservadas en staging de importación | Importación cumplida; revisión pendiente |
| Validación de correos | Formato y DNS persistidos para 8.433; todos los buzones siguen NO_VERIFICADO | Parcial; DNS no demuestra existencia del buzón |
| Pruebas visuales en CI | Workflow incorpora Chromium, integración SQL y artefactos; 10 comprobaciones locales satisfactorias | Configurado localmente; falta ejecutar este cambio en GitHub |
| Campañas y automatización | Persisten gates de buzón, base de contacto y supresión | No habilitar envío masivo por completar una normalización |
| Separación y operación de producción | Plan documentado, sin evidencia actual de release PROD separado ni ensayo completo de recuperación | Pendiente |

## ¿Fue correcto el enfoque?

Sí, como arquitectura y secuencia de un MVP: PostgreSQL/Supabase para integridad, permisos y cálculo verificable; Next.js para la consola; snapshots para conservar decisiones históricas; importadores reproducibles y revisión explícita para incertidumbre. No se necesita reescribirlo para poder evolucionar a producción.

La ejecución se desvió de sus propios criterios de cierre: la base remota avanzó más que el repositorio publicado, la documentación quedó obsoleta y la existencia de productos activos no demuestra que todos sus costos tengan unidad y vigencia confirmadas. El paso a producción debe depender de evidencia comercial y operativa, además de pruebas de código.

## Variaciones propuestas, en orden

1. Preparar una entrega reproducible: revisar el diff completo, excluir datos personales/credenciales/capturas sensibles, versionar los cambios y ejecutar el CI en el SHA que se vaya a promover. Publicación y promoción deben identificarse explícitamente; conectar GitHub no publica cambios.
2. Cerrar una muestra comercial de cinco productos con proveedor, unidad de compra, cantidad por paquete, técnica, vigencia y costos comprobados. Probar 1, 12, 30, 50, 100, 110, 1.000, 1.100, 1.150 y 1.200 unidades con resultados esperados. Los tramos son intervalos, no una lista limitada de cantidades permitidas.
3. Persistir políticas mayoristas por versión, con umbral mínimo, margen, vigencia, moneda y responsable; guardar la versión utilizada dentro del histórico de la cotización. Mantener autorización de ADMIN y prohibir márgenes o tramos incoherentes.
4. Separar proyectos, secretos y despliegues de ensayo/producción; activar protección de ramas y promoción por release probado. Alinear la versión mayor de PostgreSQL de CI (actualmente 16) con Supabase (17), o demostrar compatibilidad con una matriz.
5. Ejecutar un ensayo de restauración y documentar tiempo de recuperación y pérdida máxima admisible; comprobar Auth, Storage y permisos, no únicamente el dump de public.
6. Ampliar E2E de release: login, roles ADMIN/COMERCIAL/sin perfil, filtros dependientes, edición de contacto, cotización, emisión/PDF y persistencia después de recargar. Las capturas actuales de la calculadora no cubren toda la aplicación ni comparan píxeles contra una referencia.
7. Resolver contactos y duplicados de la cola con evidencia. Mantener separados nombre jurídico, nombre de presentación y original; no corregir indiscriminadamente mayúsculas, siglas o tildes. Incorporar confirmación de buzón/rebotes cuando exista un flujo autorizado; aceptar dominios gratuitos.

## Seguridad observada

La consulta remota no encontró tablas public sin RLS. El asesor de seguridad devolvió cero errores y 59 avisos: 58 funciones SECURITY DEFINER ejecutables por authenticated y protección de contraseñas filtradas deshabilitada. La presencia de RLS no basta para garantizar permisos correctos de funciones; cada RPC debe conservar comprobación de rol y pruebas negativas.

La nueva RPC de contactos fue probada para ADMIN, COMERCIAL con correo enmascarado, usuario sin perfil y permiso anon denegado. Esto no sustituye una nueva auditoría exhaustiva de las otras 57 funciones.

- [Aviso de funciones privilegiadas](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable)
- [Protección de contraseñas](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection)

## Lovable

La búsqueda del catálogo de complementos no devolvió Lovable; no hay conexión Lovable verificada en esta tarea. La documentación oficial de su integración GitHub indica que crea un repositorio nuevo y **no importa repositorios GitHub existentes**. Por tanto, no es una incorporación directa al proyecto Next.js actual.

Sí puede aportar un prototipo de interfaz o una aplicación separada y cuenta con integración Supabase. Mi recomendación para este proyecto es conservar Next.js, Supabase y el motor SQL; evaluar Lovable solo con datos sintéticos en un prototipo separado y reutilizar después las ideas de interfaz que superen las pruebas. No transferirle automáticamente el esquema, las credenciales o los datos del CRM.

Fuentes consultadas el 18 de septiembre de 2026:

- [GitHub en Lovable: limitaciones](https://docs.lovable.dev/integrations/github#limitations)
- [Integración Supabase](https://docs.lovable.dev/integrations/supabase)
- [Experiencia de Lovable migrando su propia aplicación](https://lovable.dev/blog/how-we-migrated-lovable-dev-away-from-nextjs)
- [Último CI remoto consultado](https://github.com/Willisk8/estampados_promocionales_mattian/actions/runs/33208395903)

## Decisión

Continuar el MVP sobre la arquitectura existente. Permitir uso interno controlado y cotizaciones cuyos costos hayan sido verificados. No declarar producción lista ni el plan del chat cumplido: faltan los gates anteriores y contrastar en detalle los requisitos de la conversación ahora recuperada.
