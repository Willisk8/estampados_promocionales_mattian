# Reconciliación Git ↔ Supabase STAGING

Fecha de corte: 2026-08-25
Etapa A1 del plan de consola interna (Etapas A y B).

## Propósito

Reconstruir qué se desplegó a mano en STAGING antes de sincronizar ninguna rama.
Este documento es el criterio de cierre de A1: **cada diferencia entre Git y
STAGING tiene aquí una explicación y una decisión propuesta**. Ninguna rama se
sincroniza hasta que esas decisiones estén aprobadas.

## Método

Consulta de sólo lectura a STAGING con `psycopg` (no hay `psql` en la máquina de
trabajo), contrastada con `git ls-tree` de las ramas `staging` y `master` y con
el árbol de trabajo local.

```sql
SELECT filename, applied_at FROM public.schema_migrations ORDER BY filename;
```

---

## 1. Migraciones

23 migraciones aplicadas en STAGING (`000`–`022`). La rama desplegable
`staging` sólo contiene 21.

| Migración | Rama `staging` | Rama `master` | Local | STAGING | Estado |
|---|:--:|:--:|:--:|:--:|---|
| `000`–`020` | sí | sí | sí | aplicada | Alineada |
| `021_marking_technique_costs.sql` | **no** | sí | sí | aplicada 2026-08-25 15:06 UTC | **Aplicada a mano; ausente de la rama desplegable** |
| `022_import_raw_row_retention.sql` | **no** | **no** | sí, **sin commitear** | aplicada 2026-08-25 17:25 UTC | **Aplicada a mano; no existe en Git** |

Las migraciones `000`–`010` se aplicaron el 2026-08-24 entre las 21:30 y las
21:31 UTC; el resto de forma escalonada el 2026-08-25. El patrón es coherente
con aplicación manual mediante `psql` o el runner local, no con el workflow
`deploy-staging.yml`, que sólo dispara desde la rama `staging`.

### Decisión propuesta

1. **`021`** — Está en `master` con su commit (`89ca1ed`). Promover `master` a
   `staging` publica la migración que ya está aplicada; el runner la saltará por
   checksum. Riesgo bajo.
2. **`022`** — Commitear primero en `master`, con el mismo contenido exacto que
   se aplicó (su checksum ya está registrado, ver §3). Si el archivo local
   difiriera de lo aplicado, no hay forma de saberlo: la migración se aplicó sin
   registro de checksum.

---

## 2. Catálogo propio: la deriva más seria

STAGING contiene **5 productos `ACTIVE`, 5 variantes `ACTIVE` y 35 precios
comerciales** con vigencia `2026-08-01` → `2026-12-31`. Todos vigentes hoy.

Ese catálogo **no se puede reproducir desde ningún estado commiteado**:

| Fuente | Productos | `valid_from` |
|---|---|---|
| `scripts/catalog/mvp_catalog_inputs.json` **commiteado** | 3 — MUG, CAMI, TERMO | `2026-09-01` |
| `scripts/catalog/mvp_catalog_inputs.json` **local, sin commitear** | 5 — + TULA-ECO, ESFERO-ECO | `2026-08-01` |
| **STAGING** | **5** — MUG, CAMI, TERMO, TULA-ECO, ESFERO-ECO | **`2026-08-01`** |

STAGING coincide con la copia de trabajo sin commitear, no con `master` ni con
`staging`.

Además, el SQL que se aplicó — `outputs/mvp_catalog_seed.sql` — **está excluido
de Git** por `.gitignore:43` (`outputs/`). El generador
(`scripts/catalog/generate_catalog_seed.py`) sí está versionado, pero sus
insumos no lo están en la versión que se usó.

**Consecuencia práctica:** quien clone el repositorio y regenere el seed obtiene
3 productos con precios que no entran en vigor hasta septiembre. Lo que hay en
STAGING desaparecería de la historia si se pierde la copia de trabajo local.

### Decisión propuesta

Commitear `scripts/catalog/mvp_catalog_inputs.json` tal como está, para que los
5 productos vigentes queden reproducibles. Antes de hacerlo, confirmar
explícitamente dos cosas que el cambio introduce sin dejar registro:

- **`valid_from` retrocedió** de `2026-09-01` a `2026-08-01`, lo que puso los
  precios en vigor de inmediato. ¿Fue deliberado?
- **TULA-ECO y ESFERO-ECO** llevan `estado_costos: "placeholder_por_confirmar"`
  en sus atributos, y aun así están `ACTIVE` y son cotizables por
  `resolve_price()`. El plan de cierre del MVP los marcaba como «costos
  placeholder por confirmar». Productos con costos sin confirmar no deberían
  estar activos.

No propongo revertir nada: propongo dejarlo registrado y decidir.

---

## 3. Checksums de migraciones (A2, ya ejecutado)

`public.schema_migrations` tenía `filename` y `applied_at`, sin forma de detectar
que una migración aplicada cambiara de contenido.

Se añadieron `checksum_sha256` y `checksum_backfilled`, y se registraron los 23
checksums reconstruidos con
`python scripts/backfill_migration_checksums.py --apply`.

**Límite honesto de la reconstrucción:** el checksum se calculó sobre los
archivos tal como están hoy. Si una migración se editó después de aplicarse, el
checksum registrado corresponde a la versión editada y esa diferencia ya no es
detectable. Por eso las 23 quedan marcadas `checksum_backfilled = true`: de aquí
en adelante el runner detecta cambios, pero no puede afirmar nada sobre lo
ocurrido antes.

A partir de ahora `scripts/apply_pending_migrations.ps1` aborta si una migración
ya aplicada cambia de contenido, y `database/migrations/CHECKSUMS.txt` permite a
`scripts/audit_change.py` avisar de lo mismo sin conexión a la base.

---

## 4. Otras diferencias sin commitear

| Archivo | Naturaleza | Decisión propuesta |
|---|---|---|
| `database/migrations/022_...sql` | Migración aplicada, sin versionar | Commitear (§1) |
| `scripts/catalog/mvp_catalog_inputs.json` | Insumos del catálogo vivo | Commitear tras confirmar §2 |
| `database/tests/test_crm_contactability.sql` | Test SQL modificado | Revisar y commitear con el resto |
| `README.md`, `docs/catalogo_propio_mvp.md`, `docs/plan_trabajo_cierre_mvp.md`, `docs/pre_pilot_gates.md` | Documentación | Commitear |
| `scripts/audit_change.py`, `scripts/backfill_migration_checksums.py` | Nuevos (Etapa A) | Commitear |

---

## 5. Hallazgo colateral: CI

Las migraciones `011`, `018`, `019` y `020` ejecutan
`REVOKE ... FROM anon, authenticated` sin guarda de existencia, y el repositorio
no contenía ningún `CREATE ROLE`. El job de CI aplica las migraciones sobre un
contenedor `postgres:16` limpio, donde esos roles no existen.

Resuelto en A4 con `database/ci/bootstrap_supabase_roles.sql`, ejecutado desde
`ci.yml` antes de aplicar migraciones. No es una migración y lleva una guarda
que aborta si detecta una instancia real de Supabase.

**Pendiente de confirmar:** el estado histórico del workflow en GitHub Actions.
No hay `gh` en esta máquina, así que no pude comprobar si CI estaba en rojo
desde la migración `011`. Conviene mirarlo antes de dar el workflow por sano.

---

## Estado de cierre de A1

La tabla está completa: cada diferencia entre Git y STAGING está explicada. Las
decisiones de §1 y §2 requieren tu aprobación antes de tocar ninguna rama.
