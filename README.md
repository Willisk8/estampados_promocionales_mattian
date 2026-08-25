# Estampados — Plataforma Comercial MVP

Base de datos y pipeline de datos para una plataforma comercial de productos promocionales orientada al sector solidario colombiano. Incluye CRM, motor de precios, catálogo de proveedores, pipeline de importación y perfil de calidad de datos.

---

## Estado actual

| Componente | Estado | Detalle |
|---|---|---|
| Infraestructura Supabase STAGING | ✓ Completo | Proyecto `psereyjwjpyakkmnabgm`, región us-west-2 Oregon |
| Migraciones `000`–`021` | ✓ Aplicadas en STAGING | 22 migraciones numeradas; deploy idempotente vía `schema_migrations` |
| Motor de precios (`resolve_price`) | ✓ Operativo | Tests A–F pasando |
| CRM — organizaciones y personas | ✓ Cargado | 5,639 organizaciones · 4,642 personas |
| CRM — canales de contacto | ✓ Cargado | 16,211 canales (email, teléfono, WhatsApp, web) |
| Catálogo proveedores | ✓ Cargado | 7 proveedores · 935 productos · 934 snapshots de precio |
| Propiedad horizontal | ✓ Pipeline · ⚠ no cargado | 25 fuentes territoriales · 23,799 PH · 8,342 residenciales; sin importador Supabase todavía |
| Vistas operativas | ✓ Activas | Migraciones `013` y `015` |
| Cuarentena emails malformados | ✓ Aplicada | Migración `014` — 58 canales `REVIEW_REQUIRED` |
| Calidad de datos | ✓ Score 87/100 | Reporte en `docs/data_quality_report.md` |
| Gates pre-piloto | ⚠ Pendiente | Ver `docs/pre_pilot_gates.md` |
| CI/CD a STAGING | ✓ Activo | GitHub Actions — rama `staging` |
| Rama principal | ⚠ Gobernanza MVP | `staging` es la rama desplegable a STAGING; `master` puede adelantarse mientras haya cambios pendientes de promover |
| Supabase PROD | — No iniciado | Plan explícito en `docs/staging_prod_separation_plan.md` |

---

## Estructura del proyecto

```
estampados/
├── database/
│   ├── migrations/          # Migraciones SQL numeradas
│   ├── tests/               # Tests de precio y CRM/contactabilidad
│   └── documentation/
│       └── migrations-guide.md
├── scripts/
│   ├── catalog/
│   │   ├── pricing_model.py        # Modelo reproducible basado en cotizador-v2.html
│   │   └── example_quote_inputs.json
│   ├── import/
│   │   ├── _shared.py           # Utilidades: COPY FROM STDIN, trazabilidad, idempotencia
│   │   ├── import_entidades.py  # Carga de organizaciones y contactos
│   │   ├── import_catalogo.py   # Carga de proveedores, productos y precios
│   │   └── requirements.txt
│   ├── analytics/
│   │   ├── data_quality_probe.py    # 20+ queries de calidad de datos → JSON
│   │   └── post_load_checks.sql     # Verificaciones post-carga
│   ├── apply_pending_migrations.ps1
│   ├── check_env.py
│   └── run_db_tests.ps1
├── tests/
│   └── test_pricing_model.py       # Tests unitarios Python del motor de precios
├── scraping/                       # Código de scraping versionado; datos/outputs ignorados
│   ├── scrape.py
│   ├── promotional_products/
│   └── residential_properties/
│       ├── scraper.py            # Consolida fuentes territoriales oficiales
│       ├── coverage.py           # Cruza DIVIPOLA, SUIT y genera cola de validación
│       └── enrich.py             # Evidencia web de correo, teléfono y WhatsApp
├── docs/
│   ├── data_quality_report.md      # Reporte de calidad — corte 2026-08-25
│   ├── catalogo_propio_mvp.md      # Modelo para convertir costos proveedor en precios propios
│   ├── pre_pilot_gates.md          # Bloqueos antes de campaña/piloto
│   └── supabase-staging-setup.md   # Guía de configuración inicial
├── .github/
│   └── workflows/
│       ├── ci.yml
│       └── deploy-staging.yml      # Deploy automático a STAGING
├── .env.example                    # Plantilla de variables de entorno
└── .gitignore
```

> El código de `scraping/` sí se versiona para continuidad del proyecto. Sus datos crudos, procesados, outputs, caches y archivos con PII siguen fuera de Git por `.gitignore`.

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
No usar scripts no idempotentes para migraciones. El único flujo manual soportado es `apply_pending_migrations.ps1`.

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
| `015_email_quality_classification.sql` | Clasificación fina de emails para segmentación pre-piloto |
| `016_fix_security_invoker_views.sql` | Corrige vistas detectadas como SECURITY DEFINER por linter Supabase |
| `017_supplier_price_purchase_terms.sql` | Agrega condiciones de compra proveedor para costos variables |
| `018_audit_hardening.sql` | Bloquea variantes inactivas y deduplica historial en elegibilidad CRM |
| `019_channel_scoped_campaign_eligibility.sql` | Corrige elegibilidad por canal cuando `018` ya fue aplicada en STAGING |
| `020_require_email_hash_for_campaign_eligibility.sql` | Exige HMAC para elegibilidad y evita omitir supresión global |
| `021_marking_technique_costs.sql` | Tablas append-only para costos de técnicas de marcación |

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

### Tests Python

```powershell
python -m unittest discover -s tests
```

CI ejecuta estos tests antes de aplicar migraciones SQL.

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
4. Corre tests Python del motor de precios
5. Corre todos los tests de `database/tests/`

### Separación PROD

No existe todavía un entorno PROD real. `master` y `staging` pueden estar sincronizadas durante el MVP, pero el deploy automático solo apunta a STAGING. El plan para PROD vive en [`docs/staging_prod_separation_plan.md`](docs/staging_prod_separation_plan.md).

---

## Pipeline de importación

### Instalación

```powershell
cd scripts/import
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Las dependencias están fijadas por versión exacta para reducir drift entre ejecuciones.

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

## Pipeline de propiedad horizontal

`scraping/residential_properties/` es el tercer pipeline de datos del proyecto.
Consolida registros territoriales de propiedad horizontal, clasifica el
subconjunto residencial, audita cobertura alcaldía por alcaldía y enriquece
contactos públicos con evidencia y niveles de confianza.

```powershell
cd scraping/residential_properties

# Descargar y normalizar fuentes territoriales
python scraper.py run --user-agent "EstampadosData/1.0 (correo@dominio.co)"
python scraper.py verify

# Cruzar 1,122 territorios DIVIPOLA con trámites SUIT
python coverage.py --user-agent "EstampadosData/1.0 (correo@dominio.co)"

# Buscar contactos en sitios públicos asociados y verificar salidas
python enrich.py crawl --user-agent "EstampadosData/1.0 (correo@dominio.co)"
python enrich.py verify
```

Estado del último corte local, 2026-08-25:

| Métrica | Resultado |
|---|---:|
| Fuentes territoriales integradas | 25 |
| Propiedades horizontales consolidadas | 23,799 |
| Conjuntos residenciales confirmados o probables | 8,342 |
| Territorios DIVIPOLA auditados | 1,122 |
| Trámites SUIT localizados | 1,505 |
| Conjuntos en cola de validación | 8,342 |

Los archivos crudos, resultados y contactos quedan fuera de Git mediante
`scraping/**/outputs/`. El código y las configuraciones reproducibles sí se
versionan. La documentación operativa completa está en
[`scraping/residential_properties/README.md`](scraping/residential_properties/README.md).

**Estado Supabase:** este pipeline todavía no alimenta STAGING. No existe un
importador ni un mapeo aprobado hacia `organizacion`, `persona`,
`persona_organizacion` y `canal_contacto`. Antes de cargarlo se debe definir la
deduplicación con las organizaciones existentes, separar contactos corporativos
de datos personales y conservar la fecha/URL de cada evidencia.

---

## Catálogo propio MVP

El catálogo proveedor cargado no es todavía el catálogo vendible. Para transformar costos reales en precios comerciales propios se agregó:

```powershell
python scripts/catalog/pricing_model.py scripts/catalog/example_quote_inputs.json
```

El modelo viene de la calculadora local `cotizador-v2.html` y contempla costo proveedor, personalización, empaque, gastos por pedido, desgaste de máquinas, retenciones y margen/markup.

Para generar SQL revisable del catálogo propio MVP:

```powershell
python scripts/catalog/generate_catalog_seed.py scripts/catalog/mvp_catalog_inputs.json > outputs/mvp_catalog_seed.sql
```

Los productos generados quedan en `DRAFT`; no serán cotizables por `resolve_price()` hasta que se activen explícitamente.

Documento: [`docs/catalogo_propio_mvp.md`](docs/catalogo_propio_mvp.md)

### Costos de técnicas de marcación

La investigación de mercado de técnicas vive en
`scraping/personalization_techniques/outputs/` y se importa con:

```powershell
python scripts/import/import_tecnicas_marcacion.py --dir scraping/personalization_techniques/outputs/<run_id>
```

El objetivo es alimentar la calculadora con costos actualizables de DTF, DTFV,
sublimación, tampografía, serigrafía, láser y bordado. Ver
[`docs/tecnicas_marcacion_costos.md`](docs/tecnicas_marcacion_costos.md).

Carga inicial STAGING: 14 técnicas · 12 proveedores/fuentes · 65 snapshots.

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
- 45.9% de emails son personales probables; 1.5% son rol/entidad en dominio gratuito
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
| Datos PII fuera de Git | `scraping/**/outputs/`, `scraping/data/raw/`, `scraping/data/processed/`, `scraping/data/web/`, `outputs/` |
| Retención de `import_raw_row` | Propuesta: purgar/anonimizar payloads crudos con PII después de 90 días |
| Todo trabajo en STAGING | Ninguna escritura a producción hasta que STAGING esté curado |

### Estado de despliegue de migraciones

Hasta el corte del 2026-08-25, las migraciones se han aplicado manualmente con
`psql` o `scripts/apply_pending_migrations.ps1`. El workflow
`.github/workflows/deploy-staging.yml` despliega únicamente desde `staging` o por
ejecución manual (`workflow_dispatch`). Si `master` está por delante de
`staging`, esos cambios deben tratarse como pendientes de integración/despliegue
en STAGING. En ningún caso la sincronía entre ramas equivale a un despliegue de
producción.

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
| Media | Diseñar y probar el importador idempotente de propiedad horizontal antes de cargarlo en Supabase STAGING |
| Media | Diseñar catálogo propio vendible: productos, variantes, costos, márgenes y escalas |
| Media | Migraciones comerciales siguientes: `campania`, `envio_campania`, `evento` |
| Media | Etapas futuras: `conversacion`, `mensaje`, `oportunidad`, `cotizacion`, `detalle_cotizacion` |
| Media | Módulo IA futuro: `ai_prompt_version`, `ai_execution`, `ai_eval_case`, `approval` |
| Baja | Normalizar categorías del catálogo (entidades HTML, formatos inconsistentes) |
| Baja | Mapear los 16 registros con `tipo_entidad_origen` sin resolver |
