# Guía de Migraciones — Estampados DB (Supabase Staging)

## Orden de aplicación

Aplicar en orden numérico estricto. Cada migración depende de las anteriores.

| Archivo | Descripción |
|---|---|
| `000_extensions.sql` | Extensiones de PostgreSQL (pgcrypto, btree_gist, uuid-ossp) |
| `001_catalogs.sql` | Tablas catálogo de dominio + seeds iniciales |
| `002_products.sql` | Catálogo propio: tabla `producto` |
| `003_product_variants.sql` | Catálogo propio: tabla `variante_producto` |
| `004_supplier_catalog.sql` | Datos de proveedor: `proveedor`, `producto_proveedor`, `precio_proveedor_snapshot` |
| `005_supplier_product_mapping.sql` | Mapeo proveedor-variante (requiere aprobación humana) |
| `006_prices_costs.sql` | Motor de precios: `costo_producto`, `precio_producto` |
| `007_price_resolution.sql` | Función `resolve_price` (fuente única de verdad para precios) |
| `008_crm_organizations_people.sql` | CRM base: organizaciones, personas, relaciones y canales |
| `009_contactability_suppression.sql` | Contactabilidad, supresiones y elegibilidad de campaña |
| `010_import_staging.sql` | Lotes de importación, filas raw y cola de revisión |
| `011_security_hardening.sql` | Hardening de funciones: search_path fijo y revocación a anon/authenticated |
| `012_revoke_public_execute.sql` | Revoca EXECUTE a PUBLIC en funciones SECURITY DEFINER |
| `013_operational_views.sql` | Vistas operativas para CRM, revisión de importación, calidad de catálogo y elegibilidad |
| `014_quarantine_malformed_email_domains.sql` | Marca 58 emails con dominios malformados como `REVIEW_REQUIRED` y abre revisión trazable |

## Cómo aplicar en Supabase Staging

```bash
# Requiere DATABASE_URL en el entorno.
pwsh ./scripts/apply_pending_migrations.ps1
```

> NUNCA incluir credenciales en archivos versionados.
> Usar variables de entorno o Supabase Vault.

El despliegue automático a STAGING vive en `.github/workflows/deploy-staging.yml`.
Se activa con push a la rama `staging` o manualmente desde GitHub Actions, y requiere el secret
`SUPABASE_STAGING_DATABASE_URL`.

## Cómo agregar una nueva migración

1. El nombre sigue el patrón `NNN_descripcion_corta.sql` donde NNN es el siguiente número en secuencia.
2. Verificar que el número no esté ya tomado con `ls database/migrations/`.
3. Todo objeto nuevo debe cumplir las convenciones obligatorias (ver sección siguiente).
4. Si la migración es destructiva (DROP, ALTER con pérdida de datos), agregarla también en `database/documentation/` con análisis de impacto.
5. Hacer PR para revisión antes de aplicar en staging o producción.

## Convenciones obligatorias

### Identificadores
- **PKs siempre UUID**: `id_xxx UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- **Nunca SERIAL ni INT como PK**
- Requiere extensión `pgcrypto` (habilitada en `000_extensions.sql`)

### Fechas
- **Siempre TIMESTAMPTZ**: `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`
- **Nunca TIMESTAMP** (sin zona horaria)

### Row Level Security
- Toda tabla nueva debe tener:
  ```sql
  ALTER TABLE nombre_tabla ENABLE ROW LEVEL SECURITY;
  CREATE POLICY deny_all ON nombre_tabla AS RESTRICTIVE FOR ALL USING (false);
  ```
- La policy `deny_all` es el punto de partida seguro. Las policies permisivas se agregan explícitamente según necesidad.

### Rangos
- Cantidad: `INT4RANGE` (no columnas separadas `qty_min`/`qty_max`)
- Vigencia temporal: `TSTZRANGE` (no columnas separadas `valid_from`/`valid_to`)

### Tablas append-only
- `precio_proveedor_snapshot` es append-only. **Nunca ejecutar UPDATE** sobre esta tabla.
- Si se necesita corregir un snapshot, insertar un nuevo registro con los datos correctos.

### Credenciales
- **Ningún archivo SQL, Python o de configuración debe contener credenciales hardcodeadas.**
- Usar variables de entorno, `.env` (excluido via `.gitignore`), o Supabase Vault.

## Cómo correr los tests

Los tests están en `database/tests/test_price_resolution.sql`.
También hay pruebas CRM/contactabilidad en `database/tests/test_crm_contactability.sql`.
Se ejecutan dentro de una transacción que termina en `ROLLBACK` para no afectar datos.

```bash
pwsh ./scripts/run_db_tests.ps1
```

El output esperado es una serie de `NOTICE` con `PASSED` para cada caso:

```
NOTICE:  CASO A PASSED — Precio general correcto
NOTICE:  CASO B PASSED — Precio de variante gana sobre precio de producto
NOTICE:  CASO C PASSED — Rangos de cantidad solapados rechazados correctamente
NOTICE:  CASO D PASSED — Vigencias solapadas rechazadas correctamente
NOTICE:  CASO E PASSED — Cantidad fuera de escala devuelve PRICE_NOT_FOUND
NOTICE:  CASO F PASSED — ...
NOTICE:  CASO EXTRA PASSED — Moneda no soportada devuelve CURRENCY_NOT_SUPPORTED
ROLLBACK
```

Si algún `ASSERT` falla, el bloque `DO` lanzará una excepción con el mensaje de diagnóstico.
