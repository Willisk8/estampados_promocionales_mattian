# Plan de trabajo para cierre del MVP comercial

Fecha de corte: 2026-08-25

Este plan organiza lo que falta después de cerrar la capa técnica base:
migraciones, CRM, importación, contactabilidad, catálogo proveedor y costos de
técnicas de marcación. El objetivo inmediato no es lanzar campañas; es dejar
lista una muestra comercial verificable con precios propios calculados y una
base de datos segura para seguir curando contactos.

## Estado de partida

| Frente | Estado | Nota |
|---|---|---|
| Supabase STAGING | Cerrado para Fase 1 | Migraciones `000`-`021` aplicadas; `022` agrega retencion PII. |
| CRM solidario | Cargado | 5,639 organizaciones y 16,211 canales. |
| Catálogo proveedor | Cargado | 7 proveedores, 935 productos, 934 snapshots. |
| Técnicas de marcación | Cargado inicial | 14 técnicas, 12 proveedores/fuentes, 65 snapshots. |
| Catálogo propio vendible | En construcción | Seed MVP de 5 productos generado; falta aplicación/activación controlada. |
| Propiedad horizontal | Pipeline listo, no cargado | Falta importador y deduplicación contra CRM. |
| Campañas | Bloqueado | Depende de contactabilidad, validación de buzones y revisión legal. |

---

## Hito 1 - Sincronizar el trabajo técnico reciente

Prioridad: alta.

Objetivo: dejar versionado y desplegable lo ya construido para costos de
técnicas de marcación.

Tareas:

- Confirmar que el commit local `feat: add marking technique cost catalog` esté
  en GitHub.
- Sincronizar `master` y `staging` cuando se apruebe publicar el cambio.
- Verificar que GitHub Actions ejecute CI y deploy de STAGING sin fallos.
- Confirmar en Supabase que `schema_migrations` contiene `021_marking_technique_costs.sql` y `022_import_raw_row_retention.sql`.

Entregable:

- Rama `staging` actualizada y workflow verde.

Criterio de cierre:

- El repositorio remoto contiene migración, importador, scraper documentado y
  documentación de técnicas.

---

## Hito 2 - Curar costos de técnicas de marcación

Prioridad: alta.

Objetivo: convertir la investigación de mercado en reglas utilizables por la
calculadora sin quemar valores en código.

Tareas:

- Clasificar snapshots por uso:
  - `AUTOMATIC_PRICING`;
  - `REFERENCE_ONLY`;
  - `NEEDS_REVIEW`;
  - `DO_NOT_USE`.
- Confirmar que DTF textil, DTF UV y sublimación tengan reglas de cálculo
  suficientes para producto MVP.
- Mantener tampografía, serigrafía, láser y bordado como referencia si falta
  setup, unidad real, área, puntadas o mínimo de pedido.
- Curar las técnicas derivadas:
  - `vinilo_alta_densidad`;
  - `acabado_agenda_multitecnica`.
- Documentar proveedor, formato, unidad de cobro, vigencia y URL/fuente.

Entregable:

- Tabla de costos de marcación lista para alimentar la calculadora en los casos
  aprobados.

Criterio de cierre:

- Para cada técnica aprobada hay una fórmula clara:
  - por metro;
  - por formato;
  - por hoja;
  - por unidad;
  - por setup más unidad.

---

## Hito 3 - Ajustar la calculadora a costos versionados

Prioridad: alta.

Objetivo: que la calculadora use costos proveedor y costos de marcación por
snapshot, no valores fijos ocultos.

Tareas:

- Mantener el JSON como entrada reproducible del MVP mientras se define si
  Supabase será la fuente primaria.
- Alinear `scripts/catalog/pricing_model.py` con:
  - `precio_proveedor_snapshot`;
  - `precio_tecnica_marcacion_snapshot`;
  - escalas por cantidad;
  - formatos mínimos de compra;
  - vigencia de costos.
- Modelar compra óptima para DTF/DTFV:
  - 58 x 15 cm;
  - 58 x 30 cm;
  - 58 x 50 cm;
  - 58 x 100 cm;
  - metro lineal.
- Modelar sublimación por hoja/formato:
  - mug: hasta 3 imágenes por A4/carta según plantilla;
  - tula: una impresión grande por hoja o formato superior, pendiente de
    material compatible.
- Evitar sumar desgaste de máquina a pedidos de una sola unidad cuando la
  política indique cantidad mínima de amortización.

Entregable:

- Calculadora capaz de explicar costo unitario, precio final, margen y fuente de
  cada costo.

Criterio de cierre:

- Los cálculos de 5 productos MVP se pueden reproducir desde archivos/versiones
  controladas y no dependen de números sueltos en conversación.

---

## Hito 4 - Cerrar catálogo propio MVP

Prioridad: alta.

Objetivo: tener productos propios reales en `producto`, `variante_producto`,
`costo_producto` y `precio_producto`, inicialmente en `DRAFT`.

Productos candidatos:

| Producto | Técnica inicial | Estado recomendado |
|---|---|---|
| Mug 11 oz | Sublimación | Incluir. |
| Camiseta DTF pecho | DTF textil | Incluir. |
| Camiseta DTF pecho + espalda | DTF textil | Incluir. |
| Tula ecológica | DTF textil 15 x 20 cm | Incluida con costos placeholder por confirmar. |
| Termo | DTF UV | Incluir con revisión de área y proveedor. |
| Esfero | Tampografía/UV | Incluido con marcación fija provisional; unidad/setup siguen por confirmar. |
| Kit temporada | Composición variable | No incluir todavía. |

Tareas:

- Definir SKU propio y variantes.
- Mapear producto proveedor elegido.
- Definir costo proveedor por unidad, docena, caja o escala.
- Definir técnica y tamaño de marcación.
- Calcular costo de personalización, mano de obra y empaque.
- Calcular precios por escala comercial.
- Generar seed SQL.
- Insertar todo como `DRAFT`.
- Revisar resultado antes de activar.

Entregable:

- Seed SQL de catálogo propio MVP aplicado en STAGING.

Criterio de cierre:

- Al menos 5 productos propios tienen precio reproducible.
- `resolve_price()` devuelve `OK` para cantidades representativas.
- Solo productos revisados pasan de `DRAFT` a `ACTIVE`.

Smoke test mínimo:

```sql
SELECT *
FROM resolve_price(
    '<id_producto>'::uuid,
    '<id_variante>'::uuid,
    120,
    now(),
    'COP'
);
```

---

## Hito 5 - Política de actualización de precios y costos

Prioridad: media-alta.

Objetivo: aceptar que los precios cambian mensual, semanal o diariamente, sin
romper cotizaciones históricas.

Reglas:

- Nunca actualizar snapshots históricos.
- Cuando cambie un costo, insertar un nuevo snapshot.
- Recalcular costos y precios propios con nueva vigencia.
- Mantener nuevas versiones en `DRAFT` hasta revisión humana.
- Guardar fuente, fecha, proveedor, unidad y evidencia.

Tareas:

- Definir frecuencia mínima de revisión de proveedores.
- Crear checklist mensual de precios:
  - mugs;
  - camisetas;
  - termos;
  - tula;
  - DTF textil;
  - DTF UV;
  - sublimación;
  - tampografía/serigrafía si aplica.
- Definir cómo se invalida o reemplaza una lista comercial anterior.

Entregable:

- Procedimiento documentado para actualización de costos.

Criterio de cierre:

- Una cotización puede auditar con qué snapshot de proveedor y técnica fue
  calculada.

---

## Hito 6 - Gates pre-piloto de datos y seguridad

Prioridad: alta para campañas, media para trabajo interno.

Objetivo: no activar campañas con datos inseguros, incompletos o legalmente
débiles.

Tareas:

- Resolver o invalidar 58 emails `HIGH`.
- Resolver 824 ítems `MEDIUM` o excluirlos del piloto.
- Segmentar emails:
  - corporativo institucional;
  - rol;
  - rol/entidad en dominio gratuito;
  - personal;
  - malformado.
- Validar buzones con proveedor externo.
- Respaldar `HMAC_SUPPRESSION_SECRET` fuera de Git, Supabase y equipo local.
- Implementar política de retención/purga para `import_raw_row` con PII.

Entregable:

- Gates `pre_pilot_gates.md` cerrados o con exclusiones explícitas.

Criterio de cierre:

- `vw_campaign_eligibility_queue` solo expone canales con base válida,
  contactabilidad efectiva, HMAC y sin supresión.

---

## Hito 7 - Preparar propiedad horizontal

Prioridad: media.

Objetivo: cargar propiedad horizontal sin duplicar ni contaminar el CRM actual.

Tareas:

- Diseñar importador idempotente.
- Mapear hacia:
  - `organizacion`;
  - `persona`;
  - `persona_organizacion`;
  - `canal_contacto`;
  - `contactabilidad`;
  - `import_raw_row`;
  - `import_review_item`.
- Deduplicar contra las 5,639 organizaciones existentes.
- Separar fuente oficial de evidencia web.
- Cargar muestra de 50 a 100 registros.
- Revisar resultados antes de carga masiva.

Entregable:

- Piloto de importación PH en STAGING.

Criterio de cierre:

- La muestra entra con trazabilidad completa, sin duplicados críticos y con
  contactos clasificados por confianza.

---

## Hito 8 - Campañas, n8n e IA

Prioridad: futura.

Objetivo: activar automatización comercial solo cuando catálogo y contactabilidad
estén listos.

No iniciar hasta cerrar:

- catálogo propio MVP;
- validación de buzones;
- base legal/contactabilidad;
- supresión HMAC;
- revisión de HIGH/MEDIUM;
- política de PII.

Tablas futuras:

- `campania`;
- `envio_campania`;
- `evento`;
- `conversacion`;
- `mensaje`;
- `oportunidad`;
- `cotizacion`;
- `detalle_cotizacion`;
- `ai_prompt_version`;
- `ai_execution`;
- `ai_eval_case`;
- `approval`.

---

## Orden recomendado de ejecución

1. Publicar y sincronizar el trabajo de `021`-`022` en GitHub/STAGING.
2. Curar costos de técnicas para uso automático.
3. Ajustar calculadora con costos versionados.
4. Cerrar 5 productos MVP propios.
5. Probar `resolve_price()` de punta a punta.
6. Activar solo productos validados.
7. Cerrar gates de datos antes de campañas.
8. Probar importador de propiedad horizontal.
9. Diseñar campañas/n8n/IA después.

## Definición de listo de la fase actual

La fase actual se considera cerrada cuando:

- hay al menos 5 productos propios activos y cotizables;
- los costos de proveedor y marcación usados por esos productos tienen fuente y
  snapshot;
- `resolve_price()` responde correctamente para cantidades de 1, 12, 36, 120 y
  500 cuando aplique;
- las técnicas no confiables no participan en cálculo automático;
- GitHub, `staging` y Supabase STAGING reflejan el mismo estado técnico.
