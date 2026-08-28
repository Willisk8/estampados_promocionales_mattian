# Plan — Cotizador proveedor-first y calculadora comercial visual

Fecha: 2026-08-28

## Objetivo

Rediseñar el cotizador para que funcione como herramienta real de venta: primero se elige el cliente, luego el proveedor, el producto del proveedor, el costo vigente de compra, la técnica de marcación y sus costos, y finalmente se genera una cotización visual con desglose, borrador, emisión y PDF.

El cotizador debe parecerse en flujo y claridad al HTML de referencia `C:\Users\willi\Downloads\cotizador-v2.html`, pero usando la base de datos, snapshots versionados, roles, RLS, idempotencia y auditoría que ya existen en el proyecto.

## Decisión de arquitectura

El flujo nuevo no debe depender de que exista primero un producto propio `ACTIVE`.

La fuente primaria de una cotización operativa será:

1. `proveedor`
2. `producto_proveedor`
3. `precio_proveedor_snapshot`
4. `tecnica_marcacion`
5. `proveedor_tecnica_marcacion`
6. `precio_tecnica_marcacion_snapshot`
7. `margin_policy_version`
8. `cotizacion`, `cotizacion_item`, `cotizacion_componente`, `cotizacion_evento`, `cotizacion_documento`

`producto`, `variante_producto`, `precio_producto` y `resolve_price()` siguen existiendo, pero quedan como catálogo/tarifa publicada opcional, no como requisito para cotizar cualquier producto de proveedor.

## Hallazgos que motivan el cambio

- La UI actual de `/cotizador` todavía arranca desde `producto` propio activo.
- `cotizacion_item.id_producto` es `NOT NULL`, por lo que hoy una cotización no puede nacer solo desde `producto_proveedor`.
- `fn_consola_crear_proveedor_rapido()` solo crea el proveedor por nombre; no crea producto, precio ni evidencia.
- `fn_consola_crear_tecnica_rapida()` solo crea la técnica; no crea proveedor de técnica ni snapshot de costo.
- `fn_quote_calculate_components_core()` calcula desde `costo_producto`; para el nuevo flujo se necesita calcular desde `precio_proveedor_snapshot`.
- El HTML viejo tiene buenas ideas de operación: cantidad, costos por unidad, técnica, DTF por área, sublimación por hoja, gastos, desgaste/luz, escenarios y documento. Esas ideas deben vivir server-side y quedar auditadas.

## Alcance funcional

El cotizador debe permitir:

- Seleccionar organización/cliente.
- Seleccionar proveedor de producto.
- Buscar producto dentro de ese proveedor por texto: mug, termo, vaso, agenda, tula, esfero, etc.
- Elegir una oferta/snapshot de costo vigente del proveedor.
- Crear proveedor nuevo, producto nuevo y precio nuevo desde el cotizador cuando no exista.
- Seleccionar técnica de marcación desde datos curados.
- Crear técnica/proveedor de técnica/costo manual cuando no exista.
- Cargar datos básicos y avanzados de marcación:
  - técnica;
  - proveedor de técnica;
  - posición/cara;
  - ancho/alto;
  - cantidad de diseños;
  - número de preparaciones;
  - merma;
  - unidad de cobro: unidad, metro, área, hoja, pack, servicio fijo;
  - evidencia o nota de origen.
- Manejar múltiples ítems en una misma cotización.
- Manejar transporte separado o distribuido por ítem.
- Mostrar desglose visual antes de emitir.
- Guardar borrador.
- Emitir cotización.
- Generar PDF desde datos persistidos.
- Dejar todo trazable por snapshot, fuente, usuario, fecha y evento.

## Fase 0 — Bitácora y seguridad operacional

1. Antes de cualquier implementación, anexar este plan en `ESTADO_TRABAJO_CLAUDE.txt`.
2. Trabajar en el worktree:
   `C:\Users\willi\Documents\Proyectos\Estampados\.claude\worktrees\cotizador-calculado`
3. No tocar migraciones `000`-`068`.
4. Crear nuevas migraciones desde el siguiente número disponible.
5. No hacer push, merge, deploy ni escribir en STAGING/PROD sin autorización explícita.

## Fase 1 — Modelo de datos proveedor-first

Migración propuesta: `069_supplier_first_quote_model.sql`

Cambios:

- Extender `cotizacion_item` para soportar ítems nacidos desde proveedor:
  - `id_producto_proveedor`
  - `id_precio_proveedor_snapshot`
  - `source_mode`: `OWN_PRODUCT`, `SUPPLIER_PRODUCT`, `MANUAL`
  - `nombre_item_snapshot`
  - `sku_proveedor_snapshot`
  - `proveedor_snapshot`
  - `costo_compra_unitario_snapshot`
  - `unidad_compra_snapshot`
  - `cantidad_pack_snapshot`
  - `cantidad_comprada`
  - `cantidad_usada`
  - `cantidad_sobrante`
  - `metadata_costeo`
- Permitir `id_producto` nullable solo si el ítem tiene `id_producto_proveedor` o es manual.
- Agregar constraints para evitar ítems sin fuente.
- Crear índices por `id_producto_proveedor`, `id_precio_proveedor_snapshot` y `source_mode`.
- Mantener snapshots congelados dentro de `producto_snapshot`.

Regla de costeo de packs:

- Si el proveedor vende caja de 36 mugs y el cliente cotiza 12, el costo unitario consumido puede ser `precio_caja / 36`, pero la cotización debe conservar:
  - valor real de compra;
  - unidades compradas;
  - unidades usadas;
  - unidades sobrantes;
  - criterio comercial usado.

Esto evita engañarnos con el costo unitario y permite saber si queda inventario o si se está asumiendo caja completa.

## Fase 2 — Unificar proveedores de producto y proveedores de técnica

Migración propuesta: `070_link_marking_suppliers_to_suppliers.sql`

Cambios:

- Agregar `proveedor_tecnica_marcacion.id_proveedor`.
- Permitir que un mismo proveedor exista como proveedor de producto y proveedor de técnica.
- Crear función controlada para vincular ambos registros.
- Mantener `source_id` separado para no romper importadores.

Razón:

Surtimundo, Surtivinilos u otro proveedor puede vender producto, DTF, DTF UV o servicio de marcación. El sistema no debe duplicar identidades comerciales sin necesidad.

## Fase 3 — Captura manual auditada desde el cotizador

Migración propuesta: `071_quote_manual_supplier_product_and_price.sql`

Funciones nuevas:

- `fn_consola_crear_proveedor_producto_precio_manual(...)`
- `fn_consola_crear_proveedor_tecnica_precio_manual(...)`

Reglas:

- Roles permitidos: `ADMIN` y `COMERCIAL`.
- Todo dato creado desde cotizador queda con origen `MANUAL_COTIZADOR`.
- Estado inicial:
  - producto proveedor: `PENDING_REVIEW`
  - precio proveedor: snapshot append-only con evidencia/nota obligatoria
  - técnica/precio técnica: `PENDING_REVIEW`
- El dato manual puede usarse en la cotización actual si el usuario lo confirma.
- El dato manual no entra a selección automática futura hasta que `ADMIN` lo apruebe.

Campos mínimos para producto manual:

- proveedor;
- nombre del producto;
- SKU o referencia si existe;
- categoría opcional;
- precio;
- moneda;
- unidad de compra;
- cantidad pack si aplica;
- mínimo de compra;
- vigencia u observado en;
- nota/evidencia.

Campos mínimos para técnica manual:

- proveedor de técnica;
- técnica;
- unidad de cobro;
- precio;
- ancho/alto si aplica;
- cantidad mínima/máxima si aplica;
- preparación/setup si aplica;
- merma;
- nota/evidencia.

## Fase 4 — Motor de cálculo desde snapshots de proveedor

Migración propuesta: `072_supplier_snapshot_quote_calculation.sql`

Crear un núcleo nuevo:

- `fn_quote_calculate_supplier_components_core(...)`

Entradas principales:

- `p_id_precio_proveedor_snapshot`
- `p_cantidad`
- `p_marking_lines jsonb`
- `p_transporte_total`
- `p_transport_mode`: `SEPARATE_LINE` o `DISTRIBUTED`
- `p_policy_code`
- `p_margen_override_pct`
- `p_at`
- `p_moneda`

Componentes calculados:

- `PRODUCTO`
- `MARCACION`
- `PREPARACION`
- `EMPAQUE`
- `TRANSPORTE`
- `OTRO`

Reglas:

- Producto se calcula desde `precio_proveedor_snapshot`, no desde `costo_producto`.
- Técnica se calcula desde `precio_tecnica_marcacion_snapshot` o desde un snapshot manual autorizado para esa cotización.
- DTF textil y DTF UV deben soportar cálculo por área:
  `ancho_cm * alto_cm * cantidad / ancho_rollo_cm / 100 * precio_metro`
- Sublimación debe soportar cálculo por hoja:
  costo hoja + tinta + capacidad por hoja, por ejemplo mug con 3 diseños por A4.
- Bordado, tampografía, serigrafía y láser deben soportar setup/preparación separada del costo unitario.
- Retenciones no inflan el precio de venta; solo se proyectan aparte.
- IVA/impuestos se modelan como capa posterior cuando se defina.
- Margen y redondeo se aplican con `margin_policy_version`.
- Margen bajo o negativo debe devolver estado de revisión/bloqueo, no emitir automáticamente.

## Fase 5 — Persistencia de borrador, emisión y múltiples ítems

Migración propuesta: `073_supplier_quote_draft_and_items.sql`

Funciones:

- `fn_consola_previsualizar_cotizacion_proveedor(...)`
- `fn_consola_guardar_borrador_cotizacion_proveedor(...)`
- `fn_consola_emitir_cotizacion_proveedor(...)`
- `fn_consola_agregar_item_borrador(...)`
- `fn_consola_recalcular_item_borrador(...)`
- `fn_consola_eliminar_item_borrador(...)`

Reglas:

- La previsualización no persiste.
- El borrador persiste, pero puede editarse creando eventos/versiones.
- La emisión congela snapshots, componentes, totales y PDF posterior.
- La cotización emitida no se recalcula al abrirla.
- Cambios posteriores crean nueva versión o nueva cotización.
- Mantener idempotencia por clave y comparación completa de payload.

## Fase 6 — APIs de búsqueda para la UI

Migración propuesta: `074_supplier_quote_console_selectors.sql`

Funciones de lectura controlada:

- `fn_consola_buscar_proveedores_producto(q text)`
- `fn_consola_buscar_productos_proveedor(p_id_proveedor uuid, q text)`
- `fn_consola_ofertas_producto_proveedor(p_id_producto_proveedor uuid, p_cantidad integer, p_at timestamptz)`
- `fn_consola_tecnicas_para_cotizar(p_id_producto_proveedor uuid, p_cantidad integer, q text)`
- `fn_consola_precios_tecnica_para_cotizar(p_id_tecnica uuid, p_cantidad integer, p_moneda text)`

Todas deben:

- respetar rol `ADMIN`/`COMERCIAL`;
- no exponer márgenes internos;
- devolver solo lo necesario para cotizar;
- distinguir datos curados de datos manuales pendientes.

## Fase 7 — Rediseño visual de `/cotizador`

Archivos principales:

- `web/src/app/cotizador/page.tsx`
- `web/src/app/cotizador/acciones.ts`
- posibles componentes server-side bajo `web/src/app/cotizador/_componentes/`
- CSS en `web/src/app/globals.css` o módulos existentes, siguiendo el estilo CRM actual

Pantalla propuesta:

1. Encabezado compacto:
   cliente, contacto, fecha, vigencia, estado de borrador.
2. Columna/formulario de captura:
   proveedor, buscador de producto, oferta/costo, cantidad, técnica, proveedor técnica, medidas, preparaciones, transporte, notas.
3. Panel de cálculo:
   componentes tipo HTML viejo: producto, marcación, preparación, empaque, transporte, total.
4. Escenarios:
   mostrar 3 alternativas de margen/precio, visibles para ADMIN; COMERCIAL ve precio final y alertas, no margen interno.
5. Ítems:
   tabla de productos cotizados, cantidad, precio unitario, subtotal, estado.
6. Resumen fijo:
   total, validez, botones `Guardar borrador`, `Emitir cotización`, `Generar PDF`.

Comportamiento visual:

- Desktop: denso, estilo CRM, sin hero ni cards decorativas grandes.
- Mobile: columnas apiladas, botones utilizables, sin controles de 180px de alto.
- Inspirado en el HTML viejo: claro, táctil, con desglose vivo, pero sin cálculo inseguro en cliente.

## Fase 8 — PDF y documento comercial

Archivos:

- `web/src/app/cotizador/[id]/pdf/documento.tsx`
- `web/src/app/cotizador/[id]/pdf/route.ts`
- página `/cotizador/[id]`

Cambios:

- PDF debe mostrar cliente, fecha, validez, ítems, descripción comercial, cantidad, precio unitario, subtotal y total.
- No debe mostrar costos, márgenes ni snapshots internos.
- Debe registrar `cotizacion_documento` y evento `PDF_GENERADO` cuando se guarde en Storage.
- Para cotizaciones antiguas sin componentes, debe mostrar línea legible en vez de tabla vacía.
- Guardar ruta Storage, no binario en tabla.

## Fase 9 — Pruebas

SQL:

- DB limpia aplica migraciones `000` hasta la última.
- Cotización desde producto proveedor sin producto propio.
- Cotización con producto propio mapeado.
- Pack caja x36 cotizando 12, 36 y 72.
- DTF por área con 15x20, pecho + espalda y varios diseños.
- Sublimación mug: A4 con 3 imágenes por hoja.
- Técnica manual pendiente usable solo en cotización actual.
- Técnica pendiente no aparece en selector automático.
- Idempotencia con mismo payload devuelve misma cotización.
- Idempotencia con payload distinto devuelve `CONFLICT`.
- COMERCIAL no ve margen/costo; ADMIN sí.
- RLS no permite leer tablas sensibles directo.

Frontend:

- `npm test`
- `npm run build` o script equivalente del proyecto.
- Prueba responsive 1440x900, 1024x768 y 390x844.
- Flujo:
  cliente -> proveedor -> producto proveedor -> oferta -> técnica -> preview -> borrador -> emitir -> PDF.

Manual STAGING, solo con autorización:

- ADMIN crea cotización completa.
- COMERCIAL crea cotización sin ver margen.
- Se agrega producto nuevo manual y queda `PENDING_REVIEW`.
- Se agrega técnica/costo manual y queda `PENDING_REVIEW`.
- Se descarga PDF real y se revisa visualmente.

## Fase 10 — QA externo

Cuando el plan esté implementado localmente:

1. Ejecutar suite local completa.
2. Actualizar `ESTADO_TRABAJO_CLAUDE.txt` con archivos tocados y resultados.
3. Enviar al chat `Configura ingeniero IA de QA` el resumen de cambios y pedir revalidación.
4. Enviar también a:
   - `Auditar software y arquitectura`: `01a03ff5-7dc7-7ee2-b6ba-c9dff91c5bbd`
   - `Auditar cambios del repositorio`: `01a038e3-b339-75d3-bcc1-bf34d9464a16`
5. Iterar hallazgos hasta quedar sin bloqueantes.

## Fuera de alcance por ahora

- Envío real por correo o WhatsApp.
- Campañas.
- Inventario contable formal por sobrantes de pack.
- Aprobación legal/compliance de marketing.
- Pasarela de pago.
- Producción/PROD.

## Criterio de cierre

Esta etapa se considera lista cuando se pueda demostrar, en local y luego en STAGING autorizado, una cotización de punta a punta así:

Cliente
-> proveedor de producto
-> producto de proveedor
-> snapshot de costo
-> técnica/proveedor de técnica
-> snapshot de costo de marcación
-> cálculo por componentes
-> borrador
-> emisión
-> PDF
-> eventos Cliente 360
-> desglose visible según rol
-> auditoría con snapshots congelados

Sin depender de que el producto exista previamente como `producto` propio `ACTIVE`.
