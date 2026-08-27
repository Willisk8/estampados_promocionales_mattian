# Hallazgos de QA

Registro de hallazgos de auditoría/QA que no son visibles desde el código o
el historial de git por sí solos: decisiones de producto pendientes, deuda
de cobertura de tests, y el motivo detrás de un fix que no es obvio leyendo
solo la migración.

No es un sustituto de `docs/plan_ia.md` ni de las migraciones mismas — es el
lugar donde un hallazgo queda anotado antes de convertirse en migración (o
en la decisión de no tocar nada), para que no se pierda si el trabajo se
retoma en otra sesión.

## Convención

- **ID**: `QA-<AREA>-NNN`, correlativo por área. No reutilizar un ID aunque
  su hallazgo original nunca se haya documentado (ver QA-QUOTE-001 a 003).
- **Estado**: `abierto` / `corregido en <migración o commit>` / `decisión de
  producto pendiente` / `descartado (motivo)`.
- Se agrega una fila cuando se abre el hallazgo; se edita el estado cuando
  se resuelve. No se borran filas resueltas.

## Motor de cotizaciones

| ID | Hallazgo | Estado | Referencia |
|---|---|---|---|
| QA-QUOTE-001 a 003 | Desconocido. Las migraciones 055/056 citan "QA-QUOTE-004" en sus cabeceras pero no hay rastro en el repo ni en ningún transcript local de qué eran 001-003 ni quién los reportó. | perdido — no hay información que reconstruir | — |
| QA-QUOTE-004 | Doble clic / retry de `fn_consola_crear_cotizacion_simple` emitía cotizaciones duplicadas. | corregido en `055_quote_simple_idempotency.sql` (retry secuencial) y `056_quote_simple_idempotency_concurrency.sql` (carrera concurrente) | [055](../database/migrations/055_quote_simple_idempotency.sql), [056](../database/migrations/056_quote_simple_idempotency_concurrency.sql) |
| QA-QUOTE-005 | Reusar `idempotency_key` con un payload distinto (ej. cantidad 10 → 999) devolvía en silencio la cotización vieja con `status=OK`, sin señal de conflicto. Encontrado por `ingeniero-qa` validando 055/056 end-to-end. Decisión de producto (usuario, 2026-08-27): debe marcar conflicto explícito, no devolver datos obsoletos en silencio — consistente con el resto del proyecto (precios que nunca se sobrescriben, guardias que fallan cerrado). | corregido en `059_quote_idempotency_conflict_on_payload_mismatch.sql` (status='CONFLICT') | [059](../database/migrations/059_quote_idempotency_conflict_on_payload_mismatch.sql) |
| QA-QUOTE-006 | La suite de tests de idempotencia (`test_quote_simple_idempotency.sql`) solo cubría el retry feliz secuencial: no cubría payload divergente, aislamiento por usuario, ni clave en blanco. `ingeniero-qa` probó los 3 casos a mano (todos pasaban) pero no quedaban cableados — una regresión futura habría pasado el CI sin que nadie se enterara. | corregido — los 3 casos + el de CONFLICT quedaron cableados en `test_quote_simple_idempotency.sql` junto con 059 | [test_quote_simple_idempotency.sql](../database/tests/test_quote_simple_idempotency.sql) |

## Pendientes de bajo impacto (no bloquean, sin ticket propio todavía)

- `fn_resolve_margin_policy_version` conserva un GRANT explícito a
  `authenticated` que ya no se ejecuta desde ningún camino alcanzable
  (queda gateado por `fn_calculate_quote_components`, restringido a ADMIN
  desde 049). Dead code sin riesgo práctico, candidato a limpieza futura.
- Estado en STAGING de `PRD-MUG-11OZ`, `PRD-CAMI-BASICA`, `PRD-TERMO-BASICO`
  sin verificar.
- Grants a `anon` en `vw_cotizaciones_activas` y `vw_clientes_para_followup`
  sin verificar.
