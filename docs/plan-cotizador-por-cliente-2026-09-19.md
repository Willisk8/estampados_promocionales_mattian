# Plan vigente: cotizador interno por cliente

Fecha: 2026-09-19. Estado actualizado: 2026-09-23.

Avance local: las migraciones 085–086 implementan el contrato por unidades a
entregar, compra completa, margen por cotización y plantillas versionadas; la
calculadora usa las RPC nuevas. Las 86 migraciones se aplicaron de cero en
PostgreSQL 17 local; pasaron los 33 tests SQL, la compilación Next.js y la
regresión visual con PostgreSQL local. El servicio local está levantado en
`http://localhost:3000`. El proyecto Supabase `psereyjwjpyakkmnabgm` solo
tiene aplicadas las migraciones hasta 084 (verificado en lectura el 2026-09-23),
por lo que el flujo V2 todavía no funciona contra ese proyecto. Falta CI del
mismo SHA y promoción controlada. También faltan pruebas reales con Auth/PDF y
Storage, grupos de líneas equivalentes, y la validación comercial con pedidos
reales. Este avance no certifica producción.

El motor V2 ahora rechaza dos líneas de la misma oferta y configuración técnica
en un pedido para evitar descuentos por tramo o preparaciones duplicadas al
partir cantidades. El usuario debe consolidarlas manualmente en una línea; la
agrupación automática y los grupos de trabajo compartidos siguen pendientes.

Revisión posterior del 2026-09-23: al duplicar un histórico V2, la geometría
DTF guardada vuelve a la calculadora y el costo DTF calculado ya no se copia
como un importe fijo adicional. Si el histórico trae una geometría inválida,
la nueva cotización exige una revisión explícita de la técnica. La prueba de
regresión está en `web/scripts/test-cotizacion-origen.mjs` y corre con `npm test`.

Este plan sustituye el requisito anterior de construir cinco productos propios con tablas de precios. Conserva la arquitectura Next.js/Supabase y el catálogo proveedor. Las auditorías del 18 de septiembre son evidencia del estado observado, no certificaciones de producción ni nuevas reglas comerciales.

## 1. Objetivo y decisiones confirmadas

Seleccionar cualquier producto de un proveedor, configurar el pedido, calcular su costo y ajustar el margen para un cliente concreto. Guardar la cotización y sus versiones sin exigir previamente un producto propio ni un precio de venta publicado. La validación se hará por escenarios, no por cinco referencias obligatorias.

| Decisión | Comportamiento acordado |
|---|---|
| Destinatario inicial | Uso interno por ADMIN y vendedores; autoservicio, pagos y marketplace quedan fuera de este cierre |
| Margen | ADMIN lo ajusta por cotización/línea; los mínimos heredados no se consideran aprobados por el negocio |
| Retenciones | Separadas del precio; mostrar neto estimado solo cuando existan bases y tasas explícitas |
| Redondeo | Unitario comercial antes de impuestos hacia arriba al peso; subtotal = unitario × unidades entregadas |
| Compra por paquetes | Incluir inicialmente el costo de toda la compra; ADMIN puede reasignar costo a sobrantes reutilizables con motivo |
| Cantidades | Cualquier entero positivo dentro de límites técnicos documentados; tramos configurables, último tramo abierto |
| Histórico | Cotización emitida conserva cliente, usuario, configuración, costos, margen, redondeo y resultados utilizados |

No convertir costos faltantes en cero ni inferir unidad de compra de un precio ambiguo. Permitir completar o confirmar esos datos al cotizar, creando una observación nueva con fuente, fecha y responsable. El catálogo completo no necesita estar curado para que una referencia confirmada pueda cotizarse.

## 2. Cambios del flujo y del cálculo

### Selección y configuración

- Seleccionar proveedor/producto existente o registrar una referencia manual mínima sin crear un producto propio. Reutilizar las altas auditadas existentes. La fuente puede ser URL, documento o referencia identificable a una oferta del proveedor.
- Introducir siempre la cantidad solicitada en unidades a entregar. Mostrar por separado paquetes necesarios, unidades compradas, unidades de reserva y sobrantes. Adaptar explícitamente las RPC antiguas que interpretan cantidad como paquetes; no cambiar silenciosamente su significado.
- Configurar técnica, sustrato, dimensiones, ubicaciones de impresión, preparaciones, empaque y entrega durante la cotización. Reutilizar parámetros del taller versionados, sin exigir fichas económicas por producto.
- Distinguir ausencia de costo de costo cero confirmado. Un borrador puede estar incompleto; emitir exige todos los costos aplicables confirmados y una configuración técnicamente válida.

### Autoridad de cálculo e interfaces

- Crear un contrato versionado de cálculo que reciba cliente, líneas, unidades, fuente de compra, configuración técnica, política elegida y ajustes autorizados. Mantener adaptadores para contratos anteriores e históricos.
- Calcular en servidor consumo, compra, costos fijos, margen y redondeo. El navegador captura entradas y muestra el resultado del servidor; sus cálculos provisionales no habilitan emisión.
- Retornar componentes, costo asignado al pedido, desembolso, valor asignado a sobrantes, unitario comercial, subtotal, impuestos explícitos, total, advertencias y versión/huella del cálculo.
- Las fórmulas de importación o comparación no serán otra autoridad comercial. Usar decimal/NUMERIC en importes del servidor; comprobar equivalencia en las herramientas auxiliares.
- Mantener idempotencia y emisión condicionada a la previsualización: si cambian entradas, costos o política, devolver PREVIEW_CHANGED y exigir una nueva validación.

### Reglas económicas

- Margen sobre venta: precio antes de impuestos = costo asignado / (1 − margen/100). Admitir 0 ≤ margen < 100; 0 requiere advertencia y confirmación de ADMIN, sin imponer los mínimos iniciales. No introducir descuentos o precios manuales negativos como atajo.
- Una nueva cotización toma el margen configurado como sugerencia; ADMIN puede sustituirlo para ese cliente sin cambiar otras cotizaciones. No publicar porcentajes nuevos como si fueran decisiones del usuario. Si no hay valor explícitamente confirmado, pedirlo antes de emitir.
- Persistir plantillas opcionales de margen por cantidad con versiones DRAFT/ACTIVE/RETIRED. Aplicar el tramo correspondiente a toda la cantidad del grupo, no escala progresiva, como continuidad del modelo existente. No sembrar 12/30/50 como reglas obligatorias.
- Mantener identidad de componentes y permitir configuración explícita de margen por componente; transporte se sugiere al costo, con cualquier cambio visible y auditado. Un ajuste de margen de línea no debe modificar silenciosamente componentes excluidos.
- Agrupar para escala las líneas de la misma referencia/variante, oferta proveedor y configuración técnica idéntica. No sumar productos diferentes automáticamente. Las preparaciones compartidas deben declararse mediante un grupo de trabajo; dividir una línea sin cambiar el trabajo no crea costos ni descuentos distintos.
- Aplicar redondeo una vez al unitario comercial de cada línea, después de combinar sus componentes y antes de impuestos. Los componentes conservan precisión interna; el residuo del redondeo se muestra como ajuste y no como costo ficticio. PDF, pantalla y base deben conciliar exactamente.
- Retirar el aumento automático del precio por retenciones. Mantener impuestos y retenciones como conceptos separados; no sumar porcentajes con bases diferentes. No inferir régimen tributario, tasas ni obligación de retener. La ausencia de configuración fiscal se muestra como pendiente de confirmar, no como exención.
- Compra completa por defecto: costo asignado = desembolso de compra. Si ADMIN declara sobrantes reutilizables, limitar la reasignación al costo proporcional de unidades realmente sobrantes; registrar cantidad, importe, responsable y motivo. Mostrar que esa reasignación no reduce el desembolso requerido. No crear un sistema de inventario completo en este alcance.

### Viabilidad técnica

- Bloquear DTF cuando ninguna orientación permitida del diseño cabe en el ancho útil. Registrar ancho útil, rotación, separación y mínimo facturable; no certificar una estimación por área como imposición exacta.
- Para v1, calcular diseños rectangulares repetidos mediante filas y columnas, considerando ambas orientaciones permitidas y eligiendo el menor consumo válido. Trabajos mixtos sin disposición definida pasan a costo manual documentado; no prometer optimización de nesting.
- Nombrar la merma existente como reserva adicional porcentual: ceil(cantidad × (1 + reserva/100)). No reinterpretar históricos como tasa de rechazo. Si se necesita tasa de rechazo productivo, será una regla distinta y explícita.

## 3. Permisos, persistencia y compatibilidad

- ADMIN confirma fuentes/costos manuales, ajusta márgenes y reasigna sobrantes. Cada ajuste registra antes/después, motivo, actor y fecha. COMERCIAL configura pedidos y usa políticas publicadas; cambios económicos excepcionales se solicitan a ADMIN. Validar permisos también en RPC, no solo ocultando controles.
- Conservar los mínimos heredados en su contexto histórico. Para el nuevo flujo usar una política explícita sin esos bloqueos comerciales; mantener validaciones matemáticas, permisos y alertas de ganancia nula.
- Cotización emitida: guardar entradas físicas estructuradas, fuente/snapshot, política y versión del motor, costos e importes finales. Abrir el PDF nunca recalcula. Duplicar para otro cliente crea borrador y revalida precios actuales; editar una emitida crea versión enlazada.
- Añadir migraciones nuevas a continuación de las aplicadas. No alterar 000–084 ni recalcular cotizaciones anteriores. Proteger datos económicos emitidos y políticas publicadas frente a cambios destructivos, separando las transiciones legítimas de estado.
- Reutilizar estados existentes; distinguir claramente borrador incompleto, pendiente de autorización y emitida. Los avisos no sustituyen bloqueos por datos indispensables ausentes.
- Tarifas publicadas y catálogo propio existentes siguen disponibles para sus flujos actuales. No se eliminan ni son prerrequisitos del nuevo flujo proveedor → cotización por cliente.

## 4. Pruebas y criterios de cierre

- Cantidades 1, 3, 12, 30, 37, 50, 100, 110, 1.000, 1.100, 1.150 y 1.200; límites inmediatamente anterior/posterior a cada tramo configurado.
- Unitario × cantidad = subtotal en base, pantalla y PDF. Cambiar retenciones no altera precio ni total de venta; sí el neto estimado cuando sus bases están definidas.
- Un costo fijo por preparación se cobra una vez. Una línea y su división equivalente mantienen el resultado; una preparación adicional explícita sí cambia el costo.
- Pedido 37/caja36: compra72, entrega37, sobrantes35; por defecto se carga toda la compra y solo ADMIN puede reasignar el costo justificado de sobrantes.
- DTF60×60 en ancho58 se rechaza; DTF60×10 puede admitir rotación cuando el ancho útil y separación lo permitan. Probar cambio de rollo, reserva, mínimo facturable y entradas inválidas.
- Dos clientes pueden recibir márgenes diferentes para la misma configuración. Reabrir un histórico conserva valores aunque cambien proveedor, política o parámetros del taller.
- ADMIN, COMERCIAL, lectura, usuario sin perfil y anónimo: pruebas de RPC y escrituras directas, intentos de introducir costos/márgenes no autorizados, PDF y Storage.
- Mantener pruebas de calculadora con capturas y añadir E2E real Next/Auth/Supabase en entorno aislado: seleccionar proveedor, confirmar unidad, configurar, previsualizar, emitir, descargar PDF y recargar histórico.
- Cierre funcional: escenarios anteriores satisfactorios y trazables. Validación comercial posterior: diez cotizaciones supervisadas comparadas con compras/producción reales; no confundir pruebas sintéticas con rentabilidad demostrada.

## 5. Orden de entrega y producción

1. Contrato nuevo y motor: unidades, compra completa, costos técnicos, margen, retenciones separadas y redondeo.
2. Interfaz por cliente, plantillas versionadas, autorización y snapshots históricos.
3. Pruebas SQL, funcionales y E2E; actualizar documentación para retirar el requisito de cinco productos propios.
4. Preparar una entrega reproducible, excluyendo PII/secretos y artefactos locales. CI debe aprobar el mismo SHA antes de migrar; controlar concurrencia, destino y versión PostgreSQL compatible con remoto.
5. Validar migraciones en entorno aislado, con respaldo y ensayo de restauración. Publicar/promover como acción identificada aparte: este documento no ejecuta push, despliegue ni crea servicios de pago.

Producción sigue condicionada a separación de entornos, permisos verificados, recuperación ensayada y piloto comercial. La limpieza de contactos continúa como trabajo de calidad independiente; no condiciona cotizar una referencia con datos suficientes ni habilita campañas por sí sola.
