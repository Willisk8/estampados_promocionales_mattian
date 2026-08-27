# Cotizador calculado — diseño

**Fecha:** 2026-08-27
**Estado:** aprobado por el usuario en brainstorming, pendiente de plan de implementación.

## Contexto

El cotizador actual (`web/src/app/cotizador/`) solo sabe cotizar contra `precio_producto`
(tarifa publicada, vía `resolve_price()`), limitado a los 5 productos propios activos.
El usuario ya no quiere depender de eso: quiere elegir un cliente real, calcular el
precio desde el costo de proveedor + técnica de marcación + margen ajustable, ver la
cotización antes de confirmarla, generarla en PDF, y dejar preparado (sin construir
todavía) un botón de envío por correo.

Como referencia visual/funcional el usuario compartió `cotizador-v2.html` — una
calculadora standalone muy detallada para dos tipos de producto (camiseta, vaso/mug)
con fórmulas físicas manuales (aprovechamiento de rollo DTF, consumo eléctrico,
rendimiento de tinta). **Se usa solo como referencia de estilo/interacción, no como
especificación de cálculo** — ver Decisiones.

## Qué ya existe (verificado en el código, no de memoria)

Antes de diseñar nada nuevo se reconcilió esta idea contra el estado real del repo.
Gran parte del motor conceptual ya está construido:

- `fn_calculate_quote_components` (migraciones 038/039/049/054/057/058): calcula
  componentes PRODUCTO (+ merma), MARCACION (desde snapshot curado de
  `precio_tecnica_marcacion_snapshot` + `curacion_precio_tecnica_marcacion`),
  PREPARACION, EMPAQUE, TRANSPORTE, OTRO. Aplica `margin_policy_version`/
  `margin_policy_component` (margen por tipo de componente, distingue MARGIN de
  MARKUP correctamente) y `fn_quote_round` (redondeo comercial). Gateada a ADMIN.
- `cotizacion_componente`: tabla con trazabilidad completa (`source_type`,
  `source_snapshot_id`, `margen_aplicado_pct`, `precio_resultante`).
- `producto_tecnica`: `cantidad_minima_tecnica`, `cantidad_recomendada`,
  `merma_pct`, `costo_preparacion`, `permitida`.
- `margin_policy_component.minimum_pct`/`target_pct` por tipo de componente.

**El hueco real, confirmado con grep sobre el código:**
- `fn_calculate_quote_components` nunca se llama desde `web/src/` — es un simulador
  aislado, nunca conectado al frontend.
- `cotizacion_componente` nunca se inserta fuera de un test — tabla muerta en
  producción.
- `fn_consola_crear_cotizacion_simple` (la única función que crea cotizaciones
  reales) usa exclusivamente `resolve_price()`, nunca el motor de componentes.
- `minimum_pct`/`target_pct` existen como datos pero nadie los usa para bloquear o
  pedir aprobación — hoy es metadata informativa nada más.

Este spec cierra ese hueco: conecta el motor ya construido con una cotización real,
y le pone una cara.

## Decisiones (de la sesión de brainstorming)

1. **El resultado es una cotización real y persistida**, no un cálculo de vitrina.
   El usuario quiere verla, confirmar que se ve bien, generar PDF y (más adelante)
   enviarla por correo.
2. **La técnica de marcación se cotiza con el mecanismo que ya existe**: snapshot
   curado por unidad (`precio_tecnica_marcacion_snapshot`), no fórmulas físicas
   nuevas (rollo DTF, electricidad, rendimiento de tinta). Si no hay snapshot
   curado para esa combinación producto/técnica, no se puede cotizar automático
   todavía — se avisa, no se inventa un número.
3. **Acceso: ADMIN y COMERCIAL**, pero COMERCIAL no ve el desglose de costo/margen
   — solo el precio final. Enmascarado server-side (mismo patrón que los correos
   enmascarados para LECTURA), nunca confiando en que el frontend lo oculte.
4. **El cotizador nuevo reemplaza al simple por completo** — un solo flujo de
   cotización en `/cotizador`, siempre pasando por el motor de componentes aunque
   exista una tarifa publicada para ese producto. `fn_consola_crear_cotizacion_simple`
   y `resolve_price()` **no se borran** (sin beneficio real en eliminarlos, y borrar
   funciones de BD es innecesariamente irreversible) — simplemente dejan de
   invocarse desde la UI.
5. **Alta rápida de proveedor/técnica**: modal corto embebido en el cotizador que
   crea el registro en estado borrador/pendiente de revisión (mismo patrón que
   `REVIEW_REQUIRED` del catálogo propio) — no interrumpe la cotización en curso,
   pero no se trata como dato verificado hasta que alguien lo revise.
6. **PDF sí, envío por correo no todavía**: el botón de "Enviar por correo" existe
   en la UI pero deshabilitado ("próximamente") — no se construye infraestructura
   de envío en este spec.
7. **El diseño visual de `Consola Estampados.dc.html` (Claude Design) se aplica
   DESPUÉS** de este trabajo funcional, como un spec separado. El cotizador nuevo
   debe nacer con una presentación cuidada, pero no bloquea en ese rediseño visual
   completo de la consola.

## Fuera de alcance (explícito, para que no se cuele por inercia)

Cosas que aparecieron en la discusión pero no son parte de este spec:
- Fórmulas físicas de técnica (rollo DTF, electricidad, tinta) — el HTML de
  referencia es solo estilo/UX.
- Envío real de correo (SMTP/proveedor, plantilla de email, tracking de envíos).
- Vista de salud de tarifa publicada vs. costo actual (`vw_published_price_health`).
- Separación de retenciones/impuestos del precio cotizado.
- Suite de tests de monotonía/boundary (49/50/51, etc.) como práctica formal.
- Rediseño visual completo de la consola (dashboard/organizaciones/clientes/ficha).

## Arquitectura

### Por qué una función nueva, autocontenida, en vez de orquestar desde Next.js

Se consideró calcular el precio en un paso (llamando a `fn_calculate_quote_components`
desde el server action) y persistir en un segundo paso, pasándole el precio ya
calculado a una función de guardado. **Se descartó**: eso abre una ventana donde el
precio persistido no tiene por qué coincidir con el que realmente se calculó en la
base — el patrón establecido en todo el proyecto es que la función `SECURITY DEFINER`
recalcula todo interna y atómicamente, nunca confía en un número calculado afuera.

### `fn_consola_crear_cotizacion_calculada` (nueva, migración 060)

```
fn_consola_crear_cotizacion_calculada(
    p_id_organizacion      UUID DEFAULT NULL,
    p_id_producto          UUID,
    p_id_variante          UUID DEFAULT NULL,
    p_cantidad             INTEGER,
    p_id_tecnica           UUID DEFAULT NULL,
    p_numero_preparaciones INTEGER DEFAULT 1,
    p_transporte_total     NUMERIC DEFAULT 0,
    p_policy_code          TEXT DEFAULT 'MVP_DEFAULT',
    p_margen_override_pct  NUMERIC DEFAULT NULL,
    p_notas                TEXT DEFAULT NULL,
    p_idempotency_key      TEXT DEFAULT NULL
)
RETURNS TABLE(id_cotizacion UUID, numero BIGINT, total NUMERIC, status TEXT)
```

Lógica:
1. Guardia de rol: `IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN RAISE EXCEPTION` —
   mismo patrón NULL-safe que el resto de funciones de escritura desde 046.
2. Idempotencia: mismo mecanismo que 055/056/059 (`idempotency_key` por
   `creada_por`, `CONFLICT` si el payload difiere).
3. Reutiliza el cuerpo de cálculo de `fn_calculate_quote_components` (misma
   resolución de costo/técnica/merma/preparación/margen/redondeo) — se factoriza
   en una función interna compartida en vez de duplicar el SQL entre ambas
   funciones (`fn_calculate_quote_components` sigue existiendo tal cual, para el
   simulador ADMIN-only; la función nueva usa la misma lógica para persistir).
4. Si `p_margen_override_pct` viene informado, reemplaza `target_pct` de forma
   uniforme para **todos** los componentes de esta cotización puntual (el slider
   único que pidió el usuario, no un ajuste por componente — `margin_policy_component`
   sigue igual para todas las demás cotizaciones). Se valida contra el
   `minimum_pct` **más alto entre los componentes que aplican** a esta cotización
   (el más estricto): si es COMERCIAL y el override cae debajo de ese mínimo, se
   rechaza (`status='MARGIN_BELOW_MINIMUM'`, no crea nada). Si es ADMIN, se
   permite bajar del mínimo — queda su decisión, pero cada
   `cotizacion_componente` guarda su propio `minimum_pct` de referencia igual que
   hoy, así que nunca se pierde el dato de que se cotizó por debajo del mínimo
   esperado.
5. Si no hay snapshot curado disponible para la técnica pedida: `status='MARKING_COST_NOT_FOUND'`
   (mismo código que ya usa `fn_calculate_quote_components`), no se inventa un
   precio ni se cae a la fórmula física.
6. Persiste: `cotizacion` + `cotizacion_item` + **una fila en `cotizacion_componente`
   por cada componente calculado** (el hueco que cierra este spec) +
   `cotizacion_evento` (`CREADA`).
7. Enmascarado por rol al devolver el detalle: una función de lectura
   `fn_consola_componentes_cotizacion(p_id_cotizacion)` (nueva) devuelve
   `costo_unitario`/`margen_aplicado_pct` en NULL cuando el rol de quien llama es
   COMERCIAL. ADMIN ve todo. Mismo patrón de enmascaramiento que ya usa
   `fn_consola_canales_organizacion` para correos.

### Función auxiliar de lectura para el selector de técnica

`fn_consola_tecnicas_disponibles_producto(p_id_producto, p_id_variante)` — lista las
técnicas permitidas (`producto_tecnica.permitida`) que además tienen al menos un
snapshot curado (`usage_status = 'AUTOMATIC_PRICING'`, `verification_status = 'VERIFIED_PUBLIC_PRICE'`)
vigente. El selector del formulario solo ofrece técnicas que de verdad se pueden
cotizar automático — evita que el usuario elija una técnica y se encuentre con
`MARKING_COST_NOT_FOUND` después de llenar todo el formulario.

### Alta rápida de proveedor/técnica

Dos funciones de escritura mínimas, ADMIN/COMERCIAL, verificadas contra el esquema
real (`proveedor` no tiene columna de verificación, solo `activo`; `tecnica_marcacion`
no tiene `nombre`, solo `codigo`):

- `fn_consola_crear_proveedor_rapido(p_nombre)` → INSERT en `proveedor` con
  `activo = true` y un `source_id` sintético (`'MANUAL-' || gen_random_uuid()`,
  ya que esa columna es `NOT NULL UNIQUE`). No se agrega una columna de
  verificación nueva — la revisión humana pasa por la pantalla `/proveedores` ya
  existente, igual que cualquier otro proveedor.
- `fn_consola_crear_tecnica_rapida(p_codigo)` → INSERT en `tecnica_marcacion` con
  solo `codigo`; `verification_status` queda en su valor por defecto
  (`'PENDING_REVIEW'`, ya definido en la tabla desde 021) — no hace falta
  sobreescribirlo.

Ambas devuelven el id nuevo para que el modal lo seleccione de inmediato en el
formulario, sin recargar la página completa. Ninguna de las dos genera un snapshot
de precio: una técnica recién creada por esta vía no tendrá snapshot curado, así
que `fn_consola_tecnicas_disponibles_producto` no la ofrecerá hasta que alguien
cargue un precio verificado — comportamiento correcto, no un bug.

## Frontend

### Por qué NO una vista previa en vivo con JavaScript de cliente

Toda la consola hoy es server-rendered sin componentes de cliente (`"use client"`
no aparece en ningún archivo de `web/src/app/`). Se consideró una vista previa que
recalcule en vivo mientras el usuario mueve un slider de margen, pero eso exige
JS de cliente que no existe en ningún otro lugar del proyecto. **Se opta por
mantener el patrón existente**: un flujo de dos pasos, ambos server actions con
`redirect`/`revalidatePath`, sin JS de cliente nuevo.

### Flujo de dos pasos

**Paso 1 — Calcular** (`/cotizador`): formulario con cliente, producto/variante,
cantidad, técnica (del selector filtrado), preparaciones, transporte, y un campo
opcional de override de margen. Botón "Calcular" → server action llama
`fn_calculate_quote_components` (el simulador existente, sin persistir nada) →
recarga la página mostrando el desglose (enmascarado por rol) en una caja de aviso,
con un botón "Confirmar y generar cotización" que reenvía los mismos valores.

**Paso 2 — Confirmar** : server action llama `fn_consola_crear_cotizacion_calculada`
con los mismos parámetros → si `status='OK'`, redirige a una pantalla de revisión
`/cotizador/{id}` que muestra la cotización tal como la vería el cliente (usando
`fn_consola_componentes_cotizacion` para el detalle, enmascarado por rol) con dos
botones: "Generar PDF" y "Enviar por correo" (deshabilitado).

### Alta rápida

Los botones "+ Proveedor" / "+ Técnica" abren un `<details>`/sección expandible
dentro de la misma página (sigue sin JS de cliente: un `<form>` con su propio
server action que hace `revalidatePath` y vuelve al mismo formulario con el nuevo
proveedor/técnica ya seleccionado vía query param).

## PDF

Ruta de servidor (`web/src/app/cotizador/[id]/pdf/route.ts`) que:
1. Verifica sesión + que el usuario puede ver esa cotización (mismo mecanismo de
   RLS que el resto de la consola).
2. Lee la cotización + `fn_consola_componentes_cotizacion` (enmascarado por rol
   igual que la pantalla — un PDF no debe filtrar más de lo que la pantalla ya
   filtra).
3. Renderiza con **`@react-pdf/renderer`** (nueva dependencia permanente — a
   diferencia de Playwright, esto sí es una funcionalidad recurrente del producto,
   no una herramienta puntual de QA). Sin navegador headless.
4. Devuelve el PDF como descarga (`Content-Disposition: attachment`).

## Envío por correo (solo el placeholder)

Un `<button disabled title="Próximamente">Enviar por correo</button>` en la
pantalla de revisión. Sin tabla nueva, sin función nueva, sin dependencia de email.

## Testing

`database/tests/test_quote_calculada.sql` (nuevo), patrón `BEGIN`/fixtures/
`SET LOCAL ROLE`/`ROLLBACK` como el resto del proyecto:
- ADMIN ve costo/margen en el detalle; COMERCIAL los ve en NULL.
- LECTURA no puede crear cotización (mismo mensaje de guardia que ya existe).
- Técnica sin snapshot curado → `MARKING_COST_NOT_FOUND`, no crea nada.
- Override de margen dentro de rango → aplica. Debajo del mínimo con COMERCIAL →
  `MARGIN_BELOW_MINIMUM`, no crea nada. Debajo del mínimo con ADMIN → crea, y el
  componente guarda `minimum_pct` de referencia para que quede trazable.
- Idempotencia: mismo comportamiento que 059 (payload igual → misma cotización;
  payload distinto → `CONFLICT`).
- `fn_consola_tecnicas_disponibles_producto` no ofrece una técnica sin snapshot
  vigente.
- `cotizacion_componente` queda poblada correctamente tras crear (el hueco que
  cierra este spec, verificado con una consulta directa a la tabla).

## Migración

Próximo número disponible: **`060_quote_calculated_creation.sql`** (confirmado:
`000`–`059` ocupadas).
