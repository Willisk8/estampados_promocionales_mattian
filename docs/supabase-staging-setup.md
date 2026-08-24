# Configuración de Supabase STAGING

## Prerrequisitos
- Cuenta en supabase.com (plan Free es suficiente para STAGING)
- psql instalado localmente, o acceso al SQL Editor de Supabase

## Paso 1 — Crear proyecto en Supabase

1. Ir a https://supabase.com/dashboard/projects
2. Clic en "New project"
3. Nombre: `estampados-staging`
4. Contraseña de base de datos: generar con gestor de contraseñas (mínimo 24 chars)
5. Región: South America (São Paulo) — más cerca de Colombia
6. Plan: Free tier
7. Clic en "Create new project" — esperar ~2 minutos

## Paso 2 — Obtener credenciales

En el dashboard del proyecto:
- Settings → API → Project URL → copiar a `SUPABASE_URL`
- Settings → API → Project API Keys → `anon public` → copiar a `SUPABASE_ANON_KEY`
- Settings → API → Project API Keys → `service_role` → copiar a `SUPABASE_SERVICE_ROLE_KEY`
- Settings → Database → Connection string → URI → copiar a `DATABASE_URL`

⚠️ **NUNCA compartir la service_role key.** Solo usarla en scripts de backend, nunca en el frontend.

## Paso 3 — Configurar variables de entorno

```bash
cp .env.example .env.staging
# Editar .env.staging con los valores reales obtenidos en el paso anterior
```

Verificar que `.env.staging` está en `.gitignore` antes de continuar:
```bash
git status  # No debe aparecer .env.staging
```

## Paso 4 — Aplicar migraciones

### Opción A: CD automático desde GitHub Actions
1. En GitHub ir a Settings -> Secrets and variables -> Actions.
2. Crear el secret `SUPABASE_STAGING_DATABASE_URL` con el connection string de Postgres STAGING.
3. Hacer push a la rama `staging`.
4. El workflow `Deploy Staging` aplica solo migraciones pendientes y corre tests.

### Opción B: SQL Editor de Supabase (manual)
1. Ir al SQL Editor en el dashboard de Supabase
2. Aplicar cada archivo en orden:
   - `database/migrations/000_extensions.sql`
   - `database/migrations/001_catalogs.sql`
   - `database/migrations/002_products.sql`
   - `database/migrations/003_product_variants.sql`
   - `database/migrations/004_supplier_catalog.sql`
   - `database/migrations/005_supplier_product_mapping.sql`
   - `database/migrations/006_prices_costs.sql`
   - `database/migrations/007_price_resolution.sql`
   - `database/migrations/008_crm_organizations_people.sql`
   - `database/migrations/009_contactability_suppression.sql`
   - `database/migrations/010_import_staging.sql`
   - `database/migrations/011_security_hardening.sql`
   - `database/migrations/012_revoke_public_execute.sql`
3. Ejecutar los tests para verificar:
   - `database/tests/test_price_resolution.sql`
   - `database/tests/test_crm_contactability.sql`

### Opción C: psql desde terminal
```bash
# Cargar variables de entorno
export $(cat .env.staging | grep -v '^#' | xargs)

# Aplicar solo migraciones pendientes
pwsh ./scripts/apply_pending_migrations.ps1

# Correr pruebas
pwsh ./scripts/run_db_tests.ps1
```

## Paso 5 — Verificar RLS

En el SQL Editor verificar que ninguna tabla es accesible sin service_role:
```sql
-- Debe devolver 0 filas (no error, sino política deny_all activa)
SELECT * FROM producto;        -- como anon
SELECT * FROM proveedor;       -- como anon
SELECT * FROM precio_producto; -- como anon
SELECT * FROM organizacion;    -- como anon
SELECT * FROM canal_contacto;  -- como anon
```

## Paso 6 — Generar secreto HMAC

```python
import secrets
print(secrets.token_hex(32))
```

Guardar el resultado como `HMAC_SUPPRESSION_SECRET` en `.env.staging`.
**Guardar también una copia segura fuera del VPS** (gestor de contraseñas).

## Separación STAGING vs PROD

| Variable | STAGING | PROD |
|---|---|---|
| SUPABASE_URL | staging project | prod project |
| SUPABASE_SERVICE_ROLE_KEY | staging key | prod key (diferente) |
| DATABASE_URL | staging DB | prod DB (diferente) |
| HMAC_SUPPRESSION_SECRET | staging secret | DEBE ser diferente |
| N8N_ENCRYPTION_KEY | staging key | DEBE ser diferente |

**Nunca copiar credenciales de PROD a STAGING ni viceversa.**

## Verificación final

- [ ] Proyecto creado en Supabase
- [ ] Credenciales en .env.staging (no en Git)
- [ ] Migraciones aplicadas en orden
- [ ] Tests de resolve_price pasan
- [ ] RLS activo — anon sin acceso
- [ ] Secreto HMAC generado y respaldado
