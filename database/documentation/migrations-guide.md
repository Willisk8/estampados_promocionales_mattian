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

## Cómo aplicar en Supabase Staging

```bash
# Desde el SQL Editor de Supabase o via psql:
psql "$SUPABASE_DB_URL" -f database/migrations/000_extensions.sql
psql "$SUPABASE_DB_URL" -f database/migrations/001_catalogs.sql
psql "$SUPABASE_DB_URL" -f database/migrations/002_products.sql
psql "$SUPABASE_DB_URL" -f database/migrations/003_product_variants.sql
psql "$SUPABASE_DB_URL" -f database/migrations/004_supplier_catalog.sql
psql "$SUPABASE_DB_URL" -f database/migrations/005_supplier_product_mapping.sql
psql "$SUPABASE_DB_URL" -f database/migrations/006_prices_costs.sql
psql "$SUPABASE_DB_URL" -f database/migrations/007_price_resolution.sql
```

> NUNCA incluir credenciales en archivos versionados.
> Usar variables de entorno o Supabase Vault.

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
Se ejecutan dentro de una transacción que termina en `ROLLBACK` para no afectar datos.

```bash
psql "$SUPABASE_DB_URL" -f database/tests/test_price_resolution.sql
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
