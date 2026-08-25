# Estampados — Plataforma Comercial MVP

Base de datos y pipeline de datos para una plataforma comercial de productos promocionales orientada al sector solidario colombiano. Incluye CRM, motor de precios, catálogo de proveedores, pipeline de importación y perfil de calidad de datos.

---

## Estado actual

| Componente | Estado | Detalle |
|---|---|---|
| Infraestructura Supabase STAGING | ✓ Completo | Proyecto `psereyjwjpyakkmnabgm`, región us-west-2 Oregon |
| Migraciones `000`–`014` | ✓ Aplicadas | 15 migraciones en STAGING |
| Motor de precios (`resolve_price`) | ✓ Operativo | Tests A–F pasando |
| CRM — organizaciones y personas | ✓ Cargado | 5,639 organizaciones · 4,642 personas |
| CRM — canales de contacto | ✓ Cargado | 16,211 canales (email, teléfono, WhatsApp, web) |
| Catálogo proveedores | ✓ Cargado | 7 proveedores · 935 productos · 934 snapshots de precio |
| Vistas operativas | ✓ Activas | Migración `013` |
| Cuarentena emails malformados | ✓ Aplicada | Migración `014` — 58 canales `REVIEW_REQUIRED` |
| Calidad de datos | ✓ Score 87/100 | Reporte en `docs/data_quality_report.md` |
| Gates pre-piloto | ⚠ Pendiente | Ver `docs/pre_pilot_gates.md` |
| CI/CD a STAGING | ✓ Activo | GitHub Actions — rama `staging` |
| Rama principal | ✓ Actualizada | `master` y `staging` apuntan al mismo commit base |
| Supabase PROD | — No iniciado | Separar cuando STAGING esté curado |

---

## Estructura del proyecto

```
estampados/
├── database/
│   ├── migrations/          # Migraciones SQL numeradas (000–014)
│   ├── tests/               # Tests de precio y CRM/contactabilidad
│   └── documentation/
│       └── migrations-guide.md
├── scripts/
│   ├── import/
│   │   ├── _shared.py           # Utilidades: COPY FROM STDIN, trazabilidad, idempotencia
│   │   ├── import_entidades.py  # Carga de organizaciones y contactos
│   │   ├── import_catalogo.py   # Carga de proveedores, productos y precios
│   │   └── requirements.txt
│   ├── analytics/
│   │   ├── data_quality_probe.py    # 20+ queries de calidad de datos → JSON
│   │   └── post_load_checks.sql     # Verificaciones post-carga
│   ├── apply_migrations.ps1
│   ├── apply_pending_migrations.ps1
│   ├── check_env.py
│   └── run_db_tests.ps1
├── docs/
│   ├── data_quality_report.md      # Reporte de calidad — corte 2026-08-25
│   ├── pre_pilot_gates.md          # Bloqueos antes de campaña/piloto
│   └── supabase-staging-setup.md   # Guía de configuración inicial
├── .github/
│   └── workflows/
│       ├── ci.yml
│       └── deploy-staging.yml      # Deploy automático a STAGING
├── .env.example                    # Plantilla de variables de entorno
└── .gitignore
```

> `scraping/` y `outputs/` pueden existir localmente en el workspace para reproducir cargas y análisis, pero no deben versionarse porque contienen datos fuente, NITs, correos, teléfonos u otros datos sensibles. El README documenta el flujo; el repositorio versionado no debe incluir esas bases crudas.

---

## Configuración de entorno

### Requisitos

- Python 3.11+
- PowerShell 7+ (para los scripts `.ps1`)
- `psql` (cliente PostgreSQL — se instala solo en CI)
- Cuenta Supabase (Free tier es suficiente para STAGING)

### Variables de entorno

```bash
cp .env.example .env.staging
# Completar con valores reales del dashboard de Supabase
```

| Variable | Descripción | Dónde obtenerla |
|---|---|---|
| `DATABASE_URL` | Conexión PostgreSQL directa o Session pooler — **puerto 5432** | Supabase → Settings → Database → Connection string |
| `SUPABASE_URL` | URL del proyecto | Supabase → Settings → API |
| `SUPABASE_ANON_KEY` | Clave pública | Supabase → Settings → API |
| `SUPABASE_SERVICE_ROLE_KEY` | Clave de servicio — **solo backend, nunca frontend** | Supabase → Settings → API |
| `HMAC_SUPPRESSION_SECRET` | Clave HMAC para hash de emails suprimidos — mínimo 32 chars | `python -c "import secrets; print(secrets.token_hex(32))"` |

> `.env.staging` está en `.gitignore` y **nunca debe commitearse**.
> `HMAC_SUPPRESSION_SECRET` tampoco debe vivir en PostgreSQL ni en Git.

### Importante — pooler de Supabase

| Puerto | Modo | Cuándo usar |
|---|---|---|
| **5432** | Session pooler — se comporta como conexión directa | Scripts de importación (COPY FROM STDIN), migraciones |
| 6543 | Transaction pooler (Supavisor) | Consultas ligeras; NO soporta COPY ni prepared statements |

Los scripts de importación usan `psycopg3` con `COPY FROM STDIN` y requieren el puerto 5432.

---

## Migraciones

### Aplicar manualmente (local o STAGING)

```powershell
# Requiere DATABASE_URL en el entorno o en .env.staging
pwsh ./scripts/apply_pending_migrations.ps1
```

El script aplica solo las migraciones que no están registradas en `schema_migrations`.

### Tabla de migraciones

| Archivo | Descripción |
|---|---|
| `000_extensions.sql` | pgcrypto, btree_gist, uuid-ossp |
| `001_catalogs.sql` | Tablas catálogo de dominio + seeds |
| `002_products.sql` | Catálogo propio: `producto` |
| `003_product_variants.sql` | Catálogo propio: `variante_producto` |
| `004_supplier_catalog.sql` | `proveedor`, `producto_proveedor`, `precio_proveedor_snapshot` |
| `005_supplier_product_mapping.sql` | Mapeo proveedor → variante propia |
| `006_prices_costs.sql` | `costo_producto`, `precio_producto` con `INT4RANGE` + `TSTZRANGE` |
| `007_price_resolution.sql` | Función `resolve_price(product_id, variant_id, qty, ts)` |
| `008_crm_organizations_people.sql` | `organizacion`, `persona`, `persona_organizacion`, `canal_contacto` |
| `009_contactability_suppression.sql` | `contactabilidad`, `supresion`, función de elegibilidad |
| `010_import_staging.sql` | `import_batch`, `import_raw_row`, `import_review_item` |
| `011_security_hardening.sql` | `search_path` fijo y revocación en funciones SECURITY DEFINER |
| `012_revoke_public_execute.sql` | Revoca EXECUTE a PUBLIC en funciones críticas |
| `013_operational_views.sql` | Vistas: CRM, revisión de importación, calidad de catálogo, elegibilidad |
| `014_quarantine_malformed_email_domains.sql` | Cuarentena de 58 emails con dominios malformados por concatenación |

### Convenciones obligatorias

- **PKs siempre UUID**: `DEFAULT gen_random_uuid()` (requiere pgcrypto)
- **Fechas siempre TIMESTAMPTZ**, nunca TIMESTAMP
- **RLS activado** en toda tabla nueva con policy `deny_all` como punto de partida
- **Rangos**: `INT4RANGE` para cantidades, `TSTZRANGE` para vigencias (no columnas separadas)
- `precio_proveedor_snapshot` es **append-only** — nunca UPDATE, solo INSERT
- **Sin credenciales hardcodeadas** en ningún archivo SQL, Python ni de configuración

---

## Correr tests

```powershell
pwsh ./scripts/run_db_tests.ps1
```

Los tests corren dentro de una transacción con `ROLLBACK` final — no modifican datos.

**Casos cubiertos — motor de precios:**

- Caso A: precio general correcto
- Caso B: precio de variante gana sobre precio de producto
- Caso C: rangos de cantidad solapados con `id_variante NULL` son rechazados
- Caso D: vigencias solapadas son rechazadas
- Caso E: cantidad fuera de escala → `PRICE_NOT_FOUND`
- Caso F: moneda no soportada → `CURRENCY_NOT_SUPPORTED`

**Casos cubiertos — CRM y contactabilidad:**

- Organización con y sin contacto
- Canal elegible vs. suprimido vs. desconocido
- Hash HMAC-SHA256 de emails

---

## CI/CD

### Deploy a STAGING

El workflow `.github/workflows/deploy-staging.yml` se activa con:

- Push a la rama `staging` que modifique archivos en `database/migrations/` o `database/tests/`
- Ejecución manual desde GitHub Actions (`workflow_dispatch`)

**Requiere el secret de GitHub Actions:**

```
SUPABASE_STAGING_DATABASE_URL = postgresql://postgres.PROJECT_ID:PASSWORD@...supabase.com:5432/postgres
```

**Qué hace el workflow:**

1. Crea la tabla `schema_migrations` si no existe (idempotente)
2. Aplica solo las migraciones pendientes en orden numérico
3. Registra cada migración aplicada en `schema_migrations`
4. Corre todos los tests de `database/tests/`

---

## Pipeline de importación

### Instalación

```powershell
cd scripts/import
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

### Cargar entidades solidarias

```powershell
# Muestra de 50 (validación antes de carga completa)
python scripts/import/import_entidades.py --file outputs/.../entidades_solidarias_migracion_supabase.xlsx --limit 50

# Carga completa
python scripts/import/import_entidades.py --file outputs/.../entidades_solidarias_migracion_supabase.xlsx
```

### Cargar catálogo de proveedores

```powershell
# Muestra de 30 productos
python scripts/import/import_catalogo.py --file outputs/.../catalogo_promocionales_migracion_supabase.xlsx --limit 30

# Carga completa
python scripts/import/import_catalogo.py --file outputs/.../catalogo_promocionales_migracion_supabase.xlsx
```

### Características del pipeline

- **COPY FROM STDIN** vía `psycopg3` — requiere Session pooler (puerto 5432)
- **Idempotente**: el mismo archivo puede importarse varias veces sin duplicar datos (dedup por SHA-256 del archivo)
- **Retry automático**: los batches en estado `FAILED` se limpian y se reintenta
- **Trazabilidad completa**: cada fila tiene enlace a `import_batch` + número de fila original en `import_raw_row`
- **Revisión**: los registros marcados `REVIEW_REQUIRED` en el Excel generan ítems en `import_review_item`

### Datos cargados en STAGING (corte 2026-08-25)

| Tabla | Filas |
|---|---|
| `organizacion` | 5,639 |
| `persona` | 4,642 |
| `persona_organizacion` | 4,642 |
| `canal_contacto` | 16,211 |
| `contactabilidad` | 16,211 |
| `proveedor` | 7 |
| `producto_proveedor` | 935 |
| `precio_proveedor_snapshot` | 934 |
| `import_raw_row` | 33,399 |
| `import_review_item` abiertos | 882 (824 MEDIUM + 58 HIGH) |

---

## Reporte de calidad de datos

**Score compuesto: 87/100 — Grado A** (corte 2026-08-25)

| Dimensión | Peso | Valor |
|---|---|---|
| Completitud | 30% | 98.5 |
| Validez | 25% | 76.3 |
| Vigencia | 20% | 65.0 |
| Unicidad | 15% | 100 |
| Consistencia | 10% | 99.7 |

Hallazgos principales:

- NIT 100% completo — deduplicación confiable
- Cobertura email por org: 99.8% — todos con hash HMAC-SHA256
- 47.4% de emails son personales (gmail/hotmail/yahoo) — riesgo de rotación anual
- 58 emails con dominios malformados en cuarentena (`REVIEW_REQUIRED`) — 58 ítems HIGH abiertos
- 824 ítems MEDIUM abiertos de revisión de organizaciones
- `estado_calidad` catálogo: 934 `VALID`, 1 `NEEDS_REVIEW`
- NaturalGraphic y Verona Studio tienen precios anómalos — no usar para costeo sin revisión
- El score 87/100 no habilita campañas: validez y vigencia siguen siendo los riesgos más sensibles

Reporte completo: [`docs/data_quality_report.md`](docs/data_quality_report.md)

Bloqueos pre-piloto: [`docs/pre_pilot_gates.md`](docs/pre_pilot_gates.md)

Para re-ejecutar el análisis:

```powershell
python scripts/analytics/data_quality_probe.py > docs/data_quality_raw.json
```

---

## Seguridad

| Regla | Detalle |
|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` solo en backend | Nunca en frontend, nunca en variables públicas |
| `HMAC_SUPPRESSION_SECRET` fuera de PostgreSQL y Git | Se genera localmente, nunca se versiona |
| Backup del `HMAC_SUPPRESSION_SECRET` | Debe guardarse en gestor seguro; si se pierde, no se pueden recalcular hashes compatibles |
| `N8N_ENCRYPTION_KEY` fuera de Git | Cuando se configure n8n |
| `.env.staging` excluida de Git | Verificar con `git status` antes de cada commit |
| Datos PII fuera de Git | `scraping/data/raw/`, `scraping/data/processed/`, `scraping/data/web/`, `scraping/outputs/`, `outputs/` |
| Retención de `import_raw_row` | Propuesta: purgar/anonimizar payloads crudos con PII después de 90 días |
| Todo trabajo en STAGING | Ninguna escritura a producción hasta que STAGING esté curado |

---

## Próximos pasos

| Prioridad | Tarea |
|---|---|
| Alta | Corregir o invalidar los 58 emails en cuarentena (`REVIEW_REQUIRED`) |
| Alta | Segmentar emails corporativos/rol/personales y no activar personales scrapeados sin consentimiento o base legal documentada |
| Alta | No habilitar campañas hasta cambiar contactabilidad de `DESCONOCIDA` a base válida |
| Alta | Validar buzones con servicio especializado antes del primer envío real |
| Alta | Respaldar `HMAC_SUPPRESSION_SECRET` fuera del entorno y definir purga de `import_raw_row` |
| Alta | Marcar NaturalGraphic y Verona como proveedores con revisión de precio obligatoria |
| Media | Resolver los 824 ítems MEDIUM de revisión de organizaciones |
| Media | Diseñar catálogo propio vendible: productos, variantes, costos, márgenes y escalas |
| Media | Migraciones comerciales siguientes: `campania`, `envio_campania`, `evento` |
| Media | Etapas futuras: `conversacion`, `mensaje`, `oportunidad`, `cotizacion`, `detalle_cotizacion` |
| Media | Módulo IA futuro: `ai_prompt_version`, `ai_execution`, `ai_eval_case`, `approval` |
| Baja | Normalizar categorías del catálogo (entidades HTML, formatos inconsistentes) |
| Baja | Mapear los 16 registros con `tipo_entidad_origen` sin resolver |
