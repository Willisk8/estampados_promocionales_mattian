# Gates pre-piloto

Fecha de corte: 2026-08-25

Este documento separa lo que ya esta listo en la capa de datos de lo que todavia bloquea un piloto comercial. No reemplaza revision legal; deja criterios tecnicos y operativos para decidir con evidencia.

Referencias normativas usadas como marco:

- Ley 1581 de 2012: autorizacion previa e informada del titular y excepciones legales.
- Decreto 1377 de 2013: recoleccion limitada a datos pertinentes, finalidades especificas y deber de obtener autorizacion salvo excepciones.
- Concepto SIC sobre datos corporativos: ciertos datos de personas juridicas/corporativos pueden quedar por fuera de la orbita de la Ley 1581, pero los datos personales de personas naturales siguen protegidos.

## Estado resumido

La capa de datos en Supabase STAGING esta lista para uso interno de CRM, curacion y analisis. El bloqueo del piloto no es principalmente tecnico: es contactabilidad/base legal, vigencia real de buzones y curacion de datos de riesgo.

## Gate 1 - Contactabilidad y consentimiento

Estado: bloqueante.

No se debe lanzar una campana masiva mientras los canales sigan con `base_contacto_codigo = 'DESCONOCIDA'`.

Segmentacion minima antes de cualquier activacion:

| Segmento | Criterio tecnico | Tratamiento recomendado |
|---|---|---|
| Email corporativo de dominio institucional | Dominio no personal y no rol generico | Revision legal + posible contacto B2B controlado si existe base defendible |
| Email de rol | Local-part tipo `info@`, `compras@`, `gerencia@`, `contacto@` | Prioritario para revision porque suele representar canal organizacional |
| Rol/entidad en dominio gratuito | Ej. `compras.fondo@gmail.com`, `tesorero.fondoabc@yahoo.com` | No tratar como personal puro; requiere revision legal y validacion de buzon |
| Email personal | Dominios como `gmail.com`, `hotmail.com`, `yahoo.com`, `outlook.com` | No incluir en marketing sin consentimiento o base legal documentada |
| Email malformado | Dominios en cuarentena | Corregir manualmente o marcar `INVALID` |

Vista operativa: `vw_email_quality_classification`.

La vista `vw_campaign_eligibility_queue` debe seguir devolviendo `eligible = false` hasta que exista una base valida y auditable.

## Gate 2 - Vigencia y validacion real de buzones

Estado: pendiente.

La validacion actual cubre formato y hashing, no existencia real del buzon ni riesgo de rebote. Antes de la primera campana se necesita validacion externa de email, idealmente con resultados persistidos como metadata de calidad.

Minimo esperado por email:

| Campo sugerido | Proposito |
|---|---|
| `validation_provider` | Servicio usado |
| `validation_status` | `VALID`, `INVALID`, `RISKY`, `UNKNOWN` |
| `validation_checked_at` | Fecha de validacion |
| `validation_reason` | Motivo tecnico: MX, disposable, mailbox, catch-all, etc. |

## Gate 3 - Revision abierta

Estado: pendiente.

Conteo actual:

| Severidad | Estado | Items |
|---|---|---:|
| HIGH | OPEN | 58 |
| MEDIUM | OPEN | 824 |

Los 58 HIGH corresponden a dominios malformados puestos en cuarentena por la migracion `014`.

## Gate 4 - Backup de secretos y retencion de PII

Estado: parcialmente implementado.

El `HMAC_SUPPRESSION_SECRET` debe respaldarse fuera del entorno local, fuera de Git y fuera de Supabase. Si se pierde, no se pueden recalcular hashes compatibles para comparar contra supresiones previas.

Politica propuesta para `import_raw_row`:

| Dato | Politica propuesta |
|---|---|
| `import_batch` | Retener como metadata de linaje |
| `import_raw_row.raw_payload` | Retener maximo 90 dias en STAGING salvo necesidad auditada |
| `import_raw_row.normalized_payload` | Retener maximo 90 dias si contiene PII |
| `target_table` / `target_id` | Retener para trazabilidad minima |

La migracion `022_import_raw_row_retention.sql` crea
`fn_anonymize_import_raw_rows(p_retention_days, p_dry_run)` para anonimizar
`raw_payload` y `normalized_payload` sin perder metadata de linaje. Por defecto
corre en dry-run. Queda pendiente ejecutar la politica de forma programada y
respaldar el `HMAC_SUPPRESSION_SECRET` fuera del entorno local.

## Gate 5 - Catalogo propio

Estado: en ejecucion.

El catalogo proveedor esta cargado como referencia de mercado, pero no reemplaza
el catalogo propio. El seed MVP ya contempla 5 productos con vigencia desde
`2026-08-01T00:00:00+00:00`:

- `PRD-MUG-11OZ`
- `PRD-CAMI-BASICA`
- `PRD-TERMO-BASICO`
- `PRD-TULA-ECO`
- `PRD-ESFERO-ECO`

Falta aplicar el seed a STAGING, activar controladamente los productos de prueba
y validar `resolve_price()` antes de considerar cerrado el gate tecnico.

## Decision

Hasta cerrar estos gates, el sistema puede usarse para:

- curacion interna;
- analisis de calidad;
- priorizacion comercial;
- construccion de catalogo propio;
- diseno de campanas sin envio.

No debe usarse aun para:

- campanas masivas;
- sincronizacion automatica con Brevo;
- activacion de contactos personales scrapeados;
- cotizaciones reales basadas solo en precios de proveedores.
