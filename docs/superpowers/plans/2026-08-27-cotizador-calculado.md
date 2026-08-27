# Cotizador Calculado Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conectar el motor de cálculo de componentes ya existente (`fn_calculate_quote_components`) con una cotización real y persistida, con acceso ADMIN/COMERCIAL (masking de costos para COMERCIAL), alta rápida de proveedor/técnica, y generación de PDF.

**Architecture:** Se extrae la lógica de cálculo de `fn_calculate_quote_components` a una función interna sin guardia de rol (`fn_quote_calculate_components_core`), reutilizada tanto por el simulador ADMIN-only existente como por la nueva función que persiste (`fn_consola_crear_cotizacion_calculada`). El frontend sigue el patrón zero-client-JS ya establecido: dos pasos vía server actions + `redirect`, sin componentes de cliente.

**Tech Stack:** PostgreSQL/PL/pgSQL (SECURITY DEFINER), Next.js 15 App Router server actions, `@react-pdf/renderer` (nueva dependencia).

**Spec:** `docs/superpowers/specs/2026-08-27-cotizador-calculado-design.md`

## Global Constraints

- UUID en PKs, `TIMESTAMPTZ`, `gen_random_uuid()`.
- Toda función de escritura nueva: `SECURITY DEFINER`, `SET search_path = public, pg_temp`, guardia de rol `IF v_rol IS NULL OR v_rol NOT IN (...)` (NULL-safe), `REVOKE ALL ... FROM PUBLIC` + `GRANT EXECUTE ... TO authenticated` explícito.
- Nunca editar una migración ya aplicada — cada corrección es una migración nueva.
- Cada migración termina con `python scripts/backfill_migration_checksums.py --apply` y se verifica con `python scripts/audit_change.py --file <archivo>`.
- Tests SQL: patrón `BEGIN` → fixtures con UUID literales → `set_config('request.jwt.claims', ...)` + `SET LOCAL ROLE authenticated` → `DO $$ ... ASSERT ... $$` → `RESET ROLE` → `ROLLBACK`.
- Cero JS de cliente nuevo en `web/src/app/` (ningún archivo del proyecto usa `"use client"` hoy).
- Próximo número de migración disponible: `060`.

---

## Task 1: Extraer el cálculo a una función interna sin guardia de rol

**Files:**
- Create: `database/migrations/060_extract_quote_calculation_core.sql`
- Test: correr `database/tests/test_quote_engine_components.sql` sin modificarlo (prueba de regresión: el comportamiento externo de `fn_calculate_quote_components` no debe cambiar).

**Interfaces:**
- Produces: `fn_quote_calculate_components_core(p_id_producto UUID, p_id_variante UUID, p_cantidad INTEGER, p_id_tecnica UUID, p_numero_preparaciones INTEGER, p_transporte_total NUMERIC, p_policy_code TEXT, p_at TIMESTAMPTZ, p_moneda TEXT, p_margen_override_pct NUMERIC DEFAULT NULL) RETURNS TABLE(tipo_componente TEXT, descripcion TEXT, cantidad NUMERIC, costo_unitario NUMERIC, costo_total NUMERIC, pricing_method TEXT, margen_aplicado_pct NUMERIC, minimum_pct NUMERIC, precio_resultante NUMERIC, source_type TEXT, source_snapshot_id UUID, metadata JSONB, status TEXT)` — **sin guardia de rol**, `REVOKE ALL FROM PUBLIC, authenticated` (solo alcanzable por llamada anidada desde otra función `SECURITY DEFINER`, mismo patrón que `fn_ai_resolver_sesion`). Nota: agrega la columna `minimum_pct` a la salida (no existía en `fn_calculate_quote_components`) porque Task 3 la necesita para bloquear overrides de margen.
- Consumes: nada nuevo — es el cuerpo exacto de `fn_calculate_quote_components` (058), con dos cambios: (a) sin el bloque `IF v_rol IS DISTINCT FROM 'ADMIN' THEN ... FORBIDDEN`, (b) el `CASE` de margen usa `COALESCE(p_margen_override_pct, p.target_pct, 0)` en vez de `COALESCE(p.target_pct, 0)`, y el SELECT final agrega `COALESCE(p.minimum_pct, 0) AS minimum_pct`.

- [ ] **Step 1: Leer el cuerpo actual de la función vigente**

```powershell
$env:PATH = "C:\Users\willi\pgsql16\bin;" + $env:PATH
. C:\Users\willi\pg-estampados\entorno.ps1
psql -At -c "SELECT pg_get_functiondef('fn_calculate_quote_components(uuid,uuid,integer,uuid,integer,numeric,text,timestamptz,text)'::regprocedure);" $env:DATABASE_URL
```

Usar este texto como base literal — no reescribir de memoria. Debe coincidir con `database/migrations/058_quote_components_do_not_inherit_technique_when_absent.sql`.

- [ ] **Step 2: Escribir la migración**

```sql
-- ============================================================
-- 060_extract_quote_calculation_core.sql
--
-- Extrae el cuerpo de calculo de fn_calculate_quote_components (058) a una
-- funcion interna sin guardia de rol, para que la Task 3
-- (fn_consola_crear_cotizacion_calculada, accesible a ADMIN y COMERCIAL)
-- pueda reutilizar el mismo calculo sin heredar el guardia ADMIN-only del
-- simulador. Mismo patron que fn_ai_resolver_sesion (046): SECURITY
-- DEFINER, REVOKE ALL FROM PUBLIC/authenticated, solo alcanzable por
-- llamada anidada desde otra funcion SECURITY DEFINER.
--
-- Agrega minimum_pct a la salida (no estaba en 058) porque la Task 3 la
-- necesita para bloquear un override de margen que caiga bajo el minimo.
-- Agrega p_margen_override_pct: si viene, reemplaza target_pct de forma
-- uniforme para todos los componentes de esta llamada puntual.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_quote_calculate_components_core(
    p_id_producto uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_cantidad integer DEFAULT 1,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_at timestamp with time zone DEFAULT now(),
    p_moneda text DEFAULT 'COP'::text,
    p_margen_override_pct numeric DEFAULT NULL::numeric
)
RETURNS TABLE(
    tipo_componente text,
    descripcion text,
    cantidad numeric,
    costo_unitario numeric,
    costo_total numeric,
    pricing_method text,
    margen_aplicado_pct numeric,
    minimum_pct numeric,
    precio_resultante numeric,
    source_type text,
    source_snapshot_id uuid,
    metadata jsonb,
    status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id_policy UUID;
    v_rounding_rule TEXT;
    v_cost costo_producto%ROWTYPE;
    v_producto_tecnica producto_tecnica%ROWTYPE;
    v_marking_snapshot RECORD;
    v_qty_produccion INTEGER;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Cantidad invalida'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, '{}'::JSONB, 'INVALID_QUANTITY'::TEXT;
        RETURN;
    END IF;

    IF p_numero_preparaciones IS NULL OR p_numero_preparaciones < 0 THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Numero de preparaciones invalido'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('numero_preparaciones', p_numero_preparaciones),
            'INVALID_PREPARATION_COUNT'::TEXT;
        RETURN;
    END IF;

    SELECT
        NULL::UUID AS id_snapshot,
        NULL::NUMERIC AS price_value,
        NULL::TEXT AS billing_unit,
        NULL::INTEGER AS quantity_min,
        NULL::INTEGER AS quantity_max,
        NULL::TEXT AS formula_code,
        NULL::TIMESTAMPTZ AS fetched_at
      INTO v_marking_snapshot;

    SELECT mpv.id_margin_policy_version, mpv.rounding_rule
      INTO v_id_policy, v_rounding_rule
      FROM margin_policy_version mpv
     WHERE mpv.codigo = p_policy_code
       AND mpv.estado = 'ACTIVE'
       AND mpv.vigencia @> p_at
     ORDER BY lower(mpv.vigencia) DESC
     LIMIT 1;

    IF v_id_policy IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Politica de margen no encontrada'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('policy_code', p_policy_code),
            'MARGIN_POLICY_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    IF p_id_tecnica IS NOT NULL THEN
        SELECT pt.*
          INTO v_producto_tecnica
          FROM producto_tecnica pt
         WHERE pt.id_producto = p_id_producto
           AND COALESCE(pt.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
               = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           AND pt.id_tecnica = p_id_tecnica
           AND pt.permitida
         ORDER BY (pt.id_variante IS NOT NULL) DESC, pt.created_at DESC
         LIMIT 1;
    END IF;

    IF p_id_tecnica IS NOT NULL AND v_producto_tecnica.id_producto_tecnica IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Tecnica no permitida/configurada para producto'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('id_tecnica', p_id_tecnica),
            'PRODUCT_TECHNIQUE_NOT_CONFIGURED'::TEXT;
        RETURN;
    END IF;

    IF v_producto_tecnica.id_producto_tecnica IS NOT NULL
       AND p_cantidad < v_producto_tecnica.cantidad_minima_tecnica THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Cantidad inferior al minimo tecnico'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object(
                'cantidad_minima_tecnica', v_producto_tecnica.cantidad_minima_tecnica,
                'id_producto_tecnica', v_producto_tecnica.id_producto_tecnica
            ),
            'BELOW_TECHNIQUE_MINIMUM'::TEXT;
        RETURN;
    END IF;

    IF p_id_tecnica IS NOT NULL THEN
        SELECT
            pts.id_snapshot, pts.price_value, pts.billing_unit,
            pts.quantity_min, pts.quantity_max, c.formula_code, pts.fetched_at
          INTO v_marking_snapshot
          FROM precio_tecnica_marcacion_snapshot pts
          JOIN curacion_precio_tecnica_marcacion c ON c.id_snapshot = pts.id_snapshot
         WHERE pts.id_tecnica = p_id_tecnica
           AND c.usage_status = 'AUTOMATIC_PRICING'
           AND pts.verification_status = 'VERIFIED_PUBLIC_PRICE'
           AND pts.currency = p_moneda
           AND pts.price_value IS NOT NULL
           AND lower(COALESCE(pts.billing_unit, '')) = 'unidad'
           AND (pts.quantity_min IS NULL OR pts.quantity_min <= p_cantidad)
           AND (pts.quantity_max IS NULL OR pts.quantity_max >= p_cantidad)
           AND (pts.fetched_at IS NULL OR pts.fetched_at <= p_at)
         ORDER BY pts.fetched_at DESC NULLS LAST, pts.created_at DESC
         LIMIT 1;

        IF v_marking_snapshot.id_snapshot IS NULL THEN
            RETURN QUERY SELECT
                NULL::TEXT, 'Costo de marcacion curado no encontrado para tecnica/cantidad/moneda'::TEXT,
                0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, NULL::UUID,
                jsonb_build_object(
                    'id_tecnica', p_id_tecnica, 'cantidad', p_cantidad,
                    'moneda', p_moneda, 'billing_unit_requerida', 'unidad'
                ),
                'MARKING_COST_NOT_FOUND'::TEXT;
            RETURN;
        END IF;

        IF p_numero_preparaciones > 0
           AND COALESCE(v_producto_tecnica.costo_preparacion, 0) <= 0 THEN
            RETURN QUERY SELECT
                NULL::TEXT, 'Costo de preparacion no configurado para producto/tecnica'::TEXT,
                0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, NULL::UUID,
                jsonb_build_object(
                    'id_producto_tecnica', v_producto_tecnica.id_producto_tecnica,
                    'numero_preparaciones', p_numero_preparaciones
                ),
                'PREPARATION_COST_NOT_CONFIGURED'::TEXT;
            RETURN;
        END IF;

        IF p_numero_preparaciones > 0
           AND v_producto_tecnica.moneda_preparacion <> p_moneda THEN
            RETURN QUERY SELECT
                NULL::TEXT, 'Moneda de preparacion no coincide con cotizacion'::TEXT,
                0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
                'NONE'::TEXT, NULL::UUID,
                jsonb_build_object(
                    'moneda_preparacion', v_producto_tecnica.moneda_preparacion,
                    'moneda_cotizacion', p_moneda
                ),
                'PREPARATION_CURRENCY_MISMATCH'::TEXT;
            RETURN;
        END IF;
    END IF;

    IF p_id_tecnica IS NULL THEN
        v_qty_produccion := p_cantidad;
    ELSE
        v_qty_produccion := CEIL(p_cantidad * (1 + COALESCE(v_producto_tecnica.merma_pct, 0) / 100.0));
    END IF;

    SELECT cp.*
      INTO v_cost
      FROM costo_producto cp
     WHERE cp.id_producto = p_id_producto
       AND COALESCE(cp.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
       AND cp.vigencia @> p_at
       AND cp.moneda = p_moneda
     ORDER BY (cp.id_variante IS NOT NULL) DESC, lower(cp.vigencia) DESC
     LIMIT 1;

    IF v_cost.id_costo IS NULL THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Costo vigente no encontrado'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID,
            jsonb_build_object('moneda', p_moneda),
            'COST_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    WITH policy AS (
        SELECT mpc.* FROM margin_policy_component mpc
        WHERE mpc.id_margin_policy_version = v_id_policy
    ),
    raw_components AS (
        SELECT
            'PRODUCTO'::TEXT AS tipo_componente,
            'Producto base con merma de produccion'::TEXT AS descripcion,
            v_qty_produccion::NUMERIC AS cantidad,
            v_cost.costo_base::NUMERIC AS costo_unitario,
            (v_cost.costo_base * v_qty_produccion)::NUMERIC AS costo_total,
            'COSTO_PRODUCTO'::TEXT AS source_type,
            v_cost.id_costo AS source_snapshot_id,
            jsonb_build_object(
                'cantidad_cliente', p_cantidad, 'cantidad_produccion', v_qty_produccion,
                'merma_pct', CASE WHEN p_id_tecnica IS NULL THEN 0 ELSE COALESCE(v_producto_tecnica.merma_pct, 0) END
            ) AS metadata
        WHERE v_cost.costo_base > 0

        UNION ALL
        SELECT 'MARCACION', 'Marcacion/personalizacion desde snapshot curado',
            p_cantidad::NUMERIC, v_marking_snapshot.price_value::NUMERIC,
            (v_marking_snapshot.price_value * p_cantidad)::NUMERIC,
            'PRECIO_TECNICA_SNAPSHOT', v_marking_snapshot.id_snapshot,
            jsonb_build_object(
                'id_tecnica', p_id_tecnica, 'producto_tecnica', v_producto_tecnica.id_producto_tecnica,
                'billing_unit', v_marking_snapshot.billing_unit, 'formula_code', v_marking_snapshot.formula_code,
                'quantity_min', v_marking_snapshot.quantity_min, 'quantity_max', v_marking_snapshot.quantity_max
            )
        WHERE p_id_tecnica IS NOT NULL

        UNION ALL
        SELECT 'MARCACION', 'Marcacion/personalizacion desde costo_producto',
            p_cantidad::NUMERIC, v_cost.costo_personalizacion::NUMERIC,
            (v_cost.costo_personalizacion * p_cantidad)::NUMERIC,
            'COSTO_PRODUCTO', v_cost.id_costo, jsonb_build_object('id_tecnica', p_id_tecnica)
        WHERE p_id_tecnica IS NULL AND v_cost.costo_personalizacion > 0

        UNION ALL
        SELECT 'PREPARACION', 'Preparacion/setup',
            p_numero_preparaciones::NUMERIC, v_producto_tecnica.costo_preparacion::NUMERIC,
            (v_producto_tecnica.costo_preparacion * p_numero_preparaciones)::NUMERIC,
            'PRODUCTO_TECNICA', v_producto_tecnica.id_producto_tecnica,
            jsonb_build_object('id_tecnica', p_id_tecnica, 'moneda_preparacion', v_producto_tecnica.moneda_preparacion)
        WHERE p_id_tecnica IS NOT NULL AND p_numero_preparaciones > 0

        UNION ALL
        SELECT 'EMPAQUE', 'Empaque', p_cantidad::NUMERIC, v_cost.costo_empaque::NUMERIC,
            (v_cost.costo_empaque * p_cantidad)::NUMERIC, 'COSTO_PRODUCTO', v_cost.id_costo, '{}'::JSONB
        WHERE v_cost.costo_empaque > 0

        UNION ALL
        SELECT 'OTRO', 'Otros costos', p_cantidad::NUMERIC, v_cost.otros_costos::NUMERIC,
            (v_cost.otros_costos * p_cantidad)::NUMERIC, 'COSTO_PRODUCTO', v_cost.id_costo, '{}'::JSONB
        WHERE v_cost.otros_costos > 0

        UNION ALL
        SELECT 'TRANSPORTE', 'Transporte', 1::NUMERIC, p_transporte_total::NUMERIC,
            p_transporte_total::NUMERIC, 'MANUAL', NULL::UUID, '{}'::JSONB
        WHERE COALESCE(p_transporte_total, 0) > 0
    )
    SELECT
        rc.tipo_componente, rc.descripcion, rc.cantidad,
        round(rc.costo_unitario, 4) AS costo_unitario,
        round(rc.costo_total, 2) AS costo_total,
        COALESCE(p.pricing_method, 'MARGIN') AS pricing_method,
        COALESCE(p_margen_override_pct, p.target_pct, 0) AS margen_aplicado_pct,
        COALESCE(p.minimum_pct, 0) AS minimum_pct,
        CASE
            WHEN COALESCE(p.pricing_method, 'MARGIN') = 'PASS_THROUGH'
                THEN round(fn_quote_apply_margin(rc.costo_total, COALESCE(p.pricing_method, 'MARGIN'), COALESCE(p_margen_override_pct, p.target_pct, 0)), 2)
            ELSE fn_quote_round(fn_quote_apply_margin(rc.costo_total, COALESCE(p.pricing_method, 'MARGIN'), COALESCE(p_margen_override_pct, p.target_pct, 0)), v_rounding_rule)
        END AS precio_resultante,
        rc.source_type, rc.source_snapshot_id,
        rc.metadata || jsonb_build_object('policy_id', v_id_policy, 'rounding_rule', v_rounding_rule, 'minimum_pct', COALESCE(p.minimum_pct, 0)) AS metadata,
        'OK'::TEXT AS status
    FROM raw_components rc
    LEFT JOIN policy p ON p.tipo_componente = rc.tipo_componente
    ORDER BY CASE rc.tipo_componente
        WHEN 'PRODUCTO' THEN 1 WHEN 'MARCACION' THEN 2 WHEN 'PREPARACION' THEN 3
        WHEN 'EMPAQUE' THEN 4 WHEN 'TRANSPORTE' THEN 5 ELSE 9
    END;
END;
$function$;

REVOKE ALL ON FUNCTION fn_quote_calculate_components_core(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, NUMERIC) FROM PUBLIC, authenticated;

COMMENT ON FUNCTION fn_quote_calculate_components_core(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT, NUMERIC) IS
    'Nucleo de calculo sin guardia de rol, extraido de fn_calculate_quote_components (058) en 060. Solo alcanzable por llamada anidada desde otra funcion SECURITY DEFINER (fn_calculate_quote_components o fn_consola_crear_cotizacion_calculada) - nunca otorgada a authenticated directamente.';

-- fn_calculate_quote_components pasa a ser un envoltorio delgado: guardia
-- ADMIN + llamada al nucleo, sin margen override (el simulador no lo ofrece).
CREATE OR REPLACE FUNCTION public.fn_calculate_quote_components(
    p_id_producto uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_cantidad integer DEFAULT 1,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_at timestamp with time zone DEFAULT now(),
    p_moneda text DEFAULT 'COP'::text
)
RETURNS TABLE(
    tipo_componente text, descripcion text, cantidad numeric, costo_unitario numeric,
    costo_total numeric, pricing_method text, margen_aplicado_pct numeric,
    precio_resultante numeric, source_type text, source_snapshot_id uuid,
    metadata jsonb, status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS DISTINCT FROM 'ADMIN' THEN
        RETURN QUERY SELECT
            NULL::TEXT, 'Solo ADMIN puede consultar costos y margenes'::TEXT,
            0::NUMERIC, 0::NUMERIC, 0::NUMERIC, 'PASS_THROUGH'::TEXT, 0::NUMERIC, 0::NUMERIC,
            'NONE'::TEXT, NULL::UUID, '{}'::JSONB, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT c.tipo_componente, c.descripcion, c.cantidad, c.costo_unitario, c.costo_total,
           c.pricing_method, c.margen_aplicado_pct, c.precio_resultante, c.source_type,
           c.source_snapshot_id, c.metadata, c.status
      FROM fn_quote_calculate_components_core(
          p_id_producto, p_id_variante, p_cantidad, p_id_tecnica, p_numero_preparaciones,
          p_transporte_total, p_policy_code, p_at, p_moneda, NULL
      ) c;
END;
$function$;

REVOKE ALL ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_calculate_quote_components(UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, TIMESTAMPTZ, TEXT) IS
    'Simulador ADMIN-only. Desde 060 es un envoltorio delgado sobre fn_quote_calculate_components_core; el calculo real vive ahi para compartirse con fn_consola_crear_cotizacion_calculada.';
```

- [ ] **Step 3: Aplicar en transacción de prueba (dry-run) contra Postgres local**

```powershell
psql -v ON_ERROR_STOP=1 -c "BEGIN;" -f database/migrations/060_extract_quote_calculation_core.sql -c "ROLLBACK;" $env:DATABASE_URL
```

Expected: sin errores, `ROLLBACK` al final.

- [ ] **Step 4: Aplicar de verdad y correr la suite de regresión**

```powershell
.\scripts\apply_pending_migrations.ps1
.\scripts\run_db_tests.ps1
```

Expected: `test_quote_engine_components.sql` sigue pasando sin ningún cambio en su archivo — prueba de que el comportamiento externo de `fn_calculate_quote_components` no cambió.

- [ ] **Step 5: Regenerar checksums y commitear**

```bash
python scripts/backfill_migration_checksums.py --apply
python scripts/audit_change.py --file database/migrations/060_extract_quote_calculation_core.sql
git add database/migrations/060_extract_quote_calculation_core.sql database/migrations/CHECKSUMS.txt
git commit -m "feat: extract quote calculation core, shared by simulator and future persist path"
```

---

## Task 2: Función de lectura enmascarada por rol

**Files:**
- Create: `database/migrations/061_quote_components_masked_read.sql`
- Test: `database/tests/test_quote_componentes_masking.sql`

**Interfaces:**
- Consumes: tabla `cotizacion_componente` (038), `cotizacion_item.id_cotizacion` (029), `fn_consola_rol()`.
- Produces: `fn_consola_componentes_cotizacion(p_id_cotizacion UUID) RETURNS TABLE(tipo_componente TEXT, descripcion TEXT, cantidad NUMERIC, costo_unitario NUMERIC, costo_total NUMERIC, margen_aplicado_pct NUMERIC, precio_resultante NUMERIC, status TEXT)` — `costo_unitario`/`costo_total`/`margen_aplicado_pct` en NULL cuando el rol de quien llama es COMERCIAL; ADMIN ve todo; cualquier otro rol (o sin rol) recibe cero filas con `status='FORBIDDEN'` en una fila única.

- [ ] **Step 1: Escribir el test primero (contra fixtures insertadas directamente, sin pasar por Task 3 que todavía no existe)**

```sql
-- database/tests/test_quote_componentes_masking.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fc00-000000000001', 'admin-mask@prueba.local'),
    ('00000000-0000-4000-fc00-000000000002', 'comercial-mask@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fc00-000000000001', 'admin-mask@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fc00-000000000002', 'comercial-mask@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio)
VALUES ('00000000-0000-4000-fc00-000000000010', '900555111', 'ORG MASK TEST', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.');

INSERT INTO cotizacion (id_cotizacion, id_organizacion, estado, moneda, total, creada_por, rol_consola, metodo_precio, fecha_emision)
VALUES ('00000000-0000-4000-fc00-000000000020', '00000000-0000-4000-fc00-000000000010', 'EMITIDA', 'COP', 50000, '00000000-0000-4000-fc00-000000000001', 'ADMIN', 'CALCULO_COMPONENTES', now());

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fc00-000000000003', 'TEST-MASK', 'Producto test mask', 'ACTIVE');

INSERT INTO cotizacion_item (id_cotizacion_item, id_cotizacion, id_producto, cantidad, precio_unitario, subtotal, producto_snapshot)
VALUES ('00000000-0000-4000-fc00-000000000030', '00000000-0000-4000-fc00-000000000020', '00000000-0000-4000-fc00-000000000003', 10, 5000, 50000, '{}'::jsonb);

INSERT INTO cotizacion_componente (id_cotizacion_item, tipo_componente, descripcion, cantidad, costo_unitario, costo_total, pricing_method, margen_aplicado_pct, precio_resultante, source_type)
VALUES ('00000000-0000-4000-fc00-000000000030', 'PRODUCTO', 'Producto base', 10, 3000, 30000, 'MARGIN', 25, 50000, 'COSTO_PRODUCTO');

-- ADMIN ve el desglose completo
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fc00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_componentes_cotizacion('00000000-0000-4000-fc00-000000000020') LIMIT 1;
    ASSERT r.costo_unitario = 3000, format('ADMIN debe ver costo_unitario real, obtuve %s', r.costo_unitario);
    ASSERT r.margen_aplicado_pct = 25, 'ADMIN debe ver margen real';
    ASSERT r.precio_resultante = 50000, 'precio_resultante siempre visible';
    RAISE NOTICE 'PASSED - ADMIN ve desglose completo';
END;
$$;

RESET ROLE;

-- COMERCIAL ve costo/margen en NULL
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fc00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_componentes_cotizacion('00000000-0000-4000-fc00-000000000020') LIMIT 1;
    ASSERT r.costo_unitario IS NULL, 'COMERCIAL no debe ver costo_unitario';
    ASSERT r.costo_total IS NULL, 'COMERCIAL no debe ver costo_total';
    ASSERT r.margen_aplicado_pct IS NULL, 'COMERCIAL no debe ver margen_aplicado_pct';
    ASSERT r.precio_resultante = 50000, 'COMERCIAL SI debe ver el precio final';
    RAISE NOTICE 'PASSED - COMERCIAL ve precio sin costo/margen';
END;
$$;

RESET ROLE;

-- Sin perfil activo: FORBIDDEN, no una excepcion
INSERT INTO auth.users (id, email) VALUES ('00000000-0000-4000-fc00-000000000099', 'sin-perfil-mask@prueba.local');
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fc00-000000000099"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_componentes_cotizacion('00000000-0000-4000-fc00-000000000020') LIMIT 1;
    ASSERT r.status = 'FORBIDDEN', format('sin perfil debe devolver FORBIDDEN, obtuve %s', r.status);
    RAISE NOTICE 'PASSED - sin perfil activo devuelve FORBIDDEN sin excepcion';
END;
$$;

RESET ROLE;

ROLLBACK;
```

- [ ] **Step 2: Correr el test para verificar que falla (la función no existe todavía)**

```powershell
psql -v ON_ERROR_STOP=1 -f database/tests/test_quote_componentes_masking.sql $env:DATABASE_URL
```

Expected: FAIL con `function fn_consola_componentes_cotizacion(uuid) does not exist`.

- [ ] **Step 3: Escribir la migración**

```sql
-- ============================================================
-- 061_quote_components_masked_read.sql
--
-- fn_consola_componentes_cotizacion: lectura del desglose de una
-- cotizacion calculada, enmascarada por rol. COMERCIAL puede ver y enviar
-- la cotizacion pero no el costo/margen real -mismo principio que el
-- enmascaramiento de correos para LECTURA (024)-. Nunca confia en el
-- frontend para ocultar el dato: el propio backend devuelve NULL.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_componentes_cotizacion(
    p_id_cotizacion uuid
)
RETURNS TABLE(
    tipo_componente text,
    descripcion text,
    cantidad numeric,
    costo_unitario numeric,
    costo_total numeric,
    margen_aplicado_pct numeric,
    precio_resultante numeric,
    status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL', 'LECTURA') THEN
        RETURN QUERY SELECT
            NULL::TEXT, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
            NULL::NUMERIC, NULL::NUMERIC, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        cc.tipo_componente,
        cc.descripcion,
        cc.cantidad,
        CASE WHEN v_rol = 'ADMIN' THEN cc.costo_unitario ELSE NULL END,
        CASE WHEN v_rol = 'ADMIN' THEN cc.costo_total ELSE NULL END,
        CASE WHEN v_rol = 'ADMIN' THEN cc.margen_aplicado_pct ELSE NULL END,
        cc.precio_resultante,
        'OK'::TEXT
      FROM cotizacion_componente cc
      JOIN cotizacion_item ci ON ci.id_cotizacion_item = cc.id_cotizacion_item
     WHERE ci.id_cotizacion = p_id_cotizacion
     ORDER BY CASE cc.tipo_componente
        WHEN 'PRODUCTO' THEN 1 WHEN 'MARCACION' THEN 2 WHEN 'PREPARACION' THEN 3
        WHEN 'EMPAQUE' THEN 4 WHEN 'TRANSPORTE' THEN 5 ELSE 9
     END;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_componentes_cotizacion(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_componentes_cotizacion(UUID) TO authenticated;

COMMENT ON FUNCTION fn_consola_componentes_cotizacion(UUID) IS
    'Desglose de una cotizacion calculada, enmascarado por rol: ADMIN ve costo/margen real, COMERCIAL y LECTURA solo ven el precio final. Sin perfil activo devuelve FORBIDDEN, no excepcion.';
```

- [ ] **Step 4: Aplicar y correr el test**

```powershell
.\scripts\apply_pending_migrations.ps1
psql -v ON_ERROR_STOP=1 -f database/tests/test_quote_componentes_masking.sql $env:DATABASE_URL
```

Expected: los 3 `PASSED`, `ROLLBACK` final.

- [ ] **Step 5: Regenerar checksums y commitear**

```bash
python scripts/backfill_migration_checksums.py --apply
python scripts/audit_change.py --file database/migrations/061_quote_components_masked_read.sql
git add database/migrations/061_quote_components_masked_read.sql database/migrations/CHECKSUMS.txt database/tests/test_quote_componentes_masking.sql
git commit -m "feat: masked read of quote component breakdown by role"
```

---

## Task 3: Persistir la cotización calculada

**Files:**
- Create: `database/migrations/062_quote_calculated_creation.sql`
- Test: `database/tests/test_quote_calculada.sql`

**Interfaces:**
- Consumes: `fn_quote_calculate_components_core(...)` (Task 1), `fn_consola_componentes_cotizacion` (Task 2, usado en el test para verificar masking end-to-end), tablas `cotizacion`/`cotizacion_item`/`cotizacion_componente`/`cotizacion_evento`.
- Produces: `fn_consola_crear_cotizacion_calculada(p_id_organizacion UUID DEFAULT NULL, p_id_producto UUID, p_id_variante UUID DEFAULT NULL, p_cantidad INTEGER, p_id_tecnica UUID DEFAULT NULL, p_numero_preparaciones INTEGER DEFAULT 1, p_transporte_total NUMERIC DEFAULT 0, p_policy_code TEXT DEFAULT 'MVP_DEFAULT', p_margen_override_pct NUMERIC DEFAULT NULL, p_notas TEXT DEFAULT NULL, p_idempotency_key TEXT DEFAULT NULL) RETURNS TABLE(id_cotizacion UUID, numero BIGINT, total NUMERIC, status TEXT)`.

- [ ] **Step 1: Escribir el test primero**

```sql
-- database/tests/test_quote_calculada.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fd00-000000000001', 'admin-calc@prueba.local'),
    ('00000000-0000-4000-fd00-000000000002', 'comercial-calc@prueba.local'),
    ('00000000-0000-4000-fd00-000000000003', 'lectura-calc@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fd00-000000000001', 'admin-calc@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fd00-000000000002', 'comercial-calc@prueba.local', 'COMERCIAL', true),
    ('00000000-0000-4000-fd00-000000000003', 'lectura-calc@prueba.local', 'LECTURA', true);

INSERT INTO organizacion (id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio)
VALUES ('00000000-0000-4000-fd00-000000000010', '900666222', 'ORG CALC TEST', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.');

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES ('00000000-0000-4000-fd00-000000000003', 'TEST-CALC', 'Producto test calculado', 'ACTIVE');

INSERT INTO costo_producto (id_costo, id_producto, id_variante, costo_base, costo_personalizacion, costo_empaque, otros_costos, moneda, vigencia)
VALUES ('00000000-0000-4000-fd00-000000000004', '00000000-0000-4000-fd00-000000000003', NULL, 2000, 0, 200, 0, 'COP', '[2026-01-01 00:00:00+00, 2027-01-01 00:00:00+00)'::TSTZRANGE);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

-- ADMIN crea, ve costo/margen real
DO $$
DECLARE r RECORD; det RECORD; v_count_componentes INTEGER;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 10
    );
    ASSERT r.status = 'OK', format('ADMIN debe crear OK, obtuve %s', r.status);
    PERFORM set_config('app.id_cot_admin', r.id_cotizacion::text, false);

    SELECT COUNT(*) INTO v_count_componentes FROM cotizacion_componente cc
      JOIN cotizacion_item ci ON ci.id_cotizacion_item = cc.id_cotizacion_item
     WHERE ci.id_cotizacion = r.id_cotizacion;
    ASSERT v_count_componentes >= 2, format('debe persistir PRODUCTO y EMPAQUE al menos, obtuve %s filas', v_count_componentes);

    SELECT * INTO det FROM fn_consola_componentes_cotizacion(r.id_cotizacion) WHERE tipo_componente = 'PRODUCTO';
    ASSERT det.costo_unitario = 2000, 'ADMIN debe ver costo_unitario real en la cotizacion recien creada';

    RAISE NOTICE 'PASSED - ADMIN crea cotizacion calculada con componentes persistidos';
END;
$$;

RESET ROLE;

-- COMERCIAL crea, no ve costo/margen
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD; det RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 5
    );
    ASSERT r.status = 'OK', format('COMERCIAL debe poder crear, obtuve %s', r.status);

    SELECT * INTO det FROM fn_consola_componentes_cotizacion(r.id_cotizacion) WHERE tipo_componente = 'PRODUCTO';
    ASSERT det.costo_unitario IS NULL, 'COMERCIAL no debe ver costo_unitario ni siquiera de su propia cotizacion';
    ASSERT det.precio_resultante IS NOT NULL, 'COMERCIAL si ve el precio final';

    RAISE NOTICE 'PASSED - COMERCIAL crea cotizacion, ve precio sin costo/margen';
END;
$$;

RESET ROLE;

-- LECTURA no puede crear
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueado BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_crear_cotizacion_calculada(
            p_id_producto => '00000000-0000-4000-fd00-000000000003',
            p_cantidad => 1
        );
    EXCEPTION WHEN OTHERS THEN
        v_bloqueado := true;
    END;
    ASSERT v_bloqueado, 'LECTURA no debe poder crear cotizaciones calculadas';
    RAISE NOTICE 'PASSED - LECTURA bloqueada';
END;
$$;

RESET ROLE;

-- Tecnica sin snapshot curado: no crea nada
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD; v_count_antes INTEGER; v_count_despues INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count_antes FROM cotizacion;

    INSERT INTO tecnica_marcacion (id_tecnica, codigo) VALUES ('00000000-0000-4000-fd00-000000000005', 'sin_snapshot_test');
    INSERT INTO producto_tecnica (id_producto_tecnica, id_producto, id_variante, id_tecnica, cantidad_minima_tecnica, cantidad_recomendada, configuracion_estandar, merma_pct, permitida)
    VALUES ('00000000-0000-4000-fd00-000000000006', '00000000-0000-4000-fd00-000000000003', NULL, '00000000-0000-4000-fd00-000000000005', 1, 1, '{}'::jsonb, 0, true);

    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 10,
        p_id_tecnica => '00000000-0000-4000-fd00-000000000005'
    );
    ASSERT r.status = 'MARKING_COST_NOT_FOUND', format('esperaba MARKING_COST_NOT_FOUND, obtuve %s', r.status);

    SELECT COUNT(*) INTO v_count_despues FROM cotizacion;
    ASSERT v_count_despues = v_count_antes, 'un status distinto de OK no debe crear cotizacion';

    RAISE NOTICE 'PASSED - tecnica sin snapshot no crea nada';
END;
$$;

-- Override de margen debajo del minimo: COMERCIAL bloqueado, ADMIN permitido
INSERT INTO margin_policy_version (id_margin_policy_version, codigo, estado, vigencia, rounding_rule)
VALUES ('00000000-0000-4000-fd00-000000000007', 'TEST_CALC_POLICY', 'ACTIVE', '[2026-01-01 00:00:00+00,)'::tstzrange, 'NEAREST_100');
INSERT INTO margin_policy_component (id_margin_policy_version, tipo_componente, pricing_method, target_pct, minimum_pct)
VALUES ('00000000-0000-4000-fd00-000000000007', 'PRODUCTO', 'MARGIN', 30, 15);

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 10,
        p_policy_code => 'TEST_CALC_POLICY',
        p_margen_override_pct => 5
    );
    ASSERT r.status = 'OK', format('ADMIN debe poder bajar del minimo, obtuve %s', r.status);
    RAISE NOTICE 'PASSED - ADMIN puede cotizar bajo el margen minimo';
END;
$$;

RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003',
        p_cantidad => 10,
        p_policy_code => 'TEST_CALC_POLICY',
        p_margen_override_pct => 5
    );
    ASSERT r.status = 'MARGIN_BELOW_MINIMUM', format('COMERCIAL debe bloquearse bajo el minimo, obtuve %s', r.status);
    RAISE NOTICE 'PASSED - COMERCIAL bloqueado bajo el margen minimo';
END;
$$;

RESET ROLE;

-- Idempotencia: mismo payload misma cotizacion, payload distinto CONFLICT
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r1 RECORD; r2 RECORD; r3 RECORD;
BEGIN
    SELECT * INTO r1 FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003', p_cantidad => 20,
        p_idempotency_key => 'fixture-key-calc-idem'
    );
    SELECT * INTO r2 FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003', p_cantidad => 20,
        p_idempotency_key => 'fixture-key-calc-idem'
    );
    ASSERT r1.id_cotizacion = r2.id_cotizacion, 'mismo payload + misma clave debe devolver la misma cotizacion';

    SELECT * INTO r3 FROM fn_consola_crear_cotizacion_calculada(
        p_id_producto => '00000000-0000-4000-fd00-000000000003', p_cantidad => 999,
        p_idempotency_key => 'fixture-key-calc-idem'
    );
    ASSERT r3.status = 'CONFLICT', format('payload distinto misma clave debe dar CONFLICT, obtuve %s', r3.status);
    RAISE NOTICE 'PASSED - idempotencia igual que 059';
END;
$$;

RESET ROLE;

ROLLBACK;
```

- [ ] **Step 2: Correr el test para verificar que falla**

```powershell
psql -v ON_ERROR_STOP=1 -f database/tests/test_quote_calculada.sql $env:DATABASE_URL
```

Expected: FAIL con `function fn_consola_crear_cotizacion_calculada(...) does not exist`.

- [ ] **Step 3: Escribir la migración**

```sql
-- ============================================================
-- 062_quote_calculated_creation.sql
--
-- fn_consola_crear_cotizacion_calculada: cierra el hueco central del spec
-- 2026-08-27-cotizador-calculado-design.md. Reutiliza
-- fn_quote_calculate_components_core (060) para calcular, y persiste
-- cotizacion + cotizacion_item + una fila de cotizacion_componente por
-- cada componente -tabla que hasta ahora ninguna funcion de produccion
-- poblaba-. Gateada a ADMIN y COMERCIAL (a diferencia del simulador,
-- ADMIN-only). Mismo mecanismo de idempotencia que 055/056/059.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_crear_cotizacion_calculada(
    p_id_organizacion uuid DEFAULT NULL::uuid,
    p_id_producto uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
    p_cantidad integer,
    p_id_tecnica uuid DEFAULT NULL::uuid,
    p_numero_preparaciones integer DEFAULT 1,
    p_transporte_total numeric DEFAULT 0,
    p_policy_code text DEFAULT 'MVP_DEFAULT'::text,
    p_margen_override_pct numeric DEFAULT NULL::numeric,
    p_notas text DEFAULT NULL::text,
    p_idempotency_key text DEFAULT NULL::text
)
RETURNS TABLE(id_cotizacion uuid, numero bigint, total numeric, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_key TEXT := NULLIF(btrim(p_idempotency_key), '');
    v_id_cotizacion UUID;
    v_numero BIGINT;
    v_total NUMERIC(14,2);
    v_id_item UUID;
    v_comp RECORD;
    v_max_minimum NUMERIC := 0;
    v_below_minimum BOOLEAN := false;
    v_payload_coincide BOOLEAN;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear cotizaciones calculadas.';
    END IF;

    IF v_key IS NOT NULL THEN
        SELECT c.id_cotizacion, c.numero, c.total,
               (c.id_organizacion IS NOT DISTINCT FROM p_id_organizacion
                AND ci.id_producto IS NOT DISTINCT FROM p_id_producto
                AND ci.id_variante IS NOT DISTINCT FROM p_id_variante
                AND ci.cantidad IS NOT DISTINCT FROM p_cantidad
                AND ci.id_tecnica IS NOT DISTINCT FROM p_id_tecnica)
          INTO v_id_cotizacion, v_numero, v_total, v_payload_coincide
          FROM cotizacion c
          JOIN cotizacion_item ci ON ci.id_cotizacion = c.id_cotizacion
         WHERE c.creada_por = auth.uid()
           AND c.idempotency_key = v_key
         LIMIT 1;

        IF FOUND THEN
            RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total,
                (CASE WHEN v_payload_coincide THEN 'OK' ELSE 'CONFLICT' END)::TEXT;
            RETURN;
        END IF;
    END IF;

    -- Calcula primero (sin persistir): si algun status distinto de OK, no crea nada.
    CREATE TEMPORARY TABLE tmp_componentes_calculados ON COMMIT DROP AS
    SELECT * FROM fn_quote_calculate_components_core(
        p_id_producto, p_id_variante, p_cantidad, p_id_tecnica, p_numero_preparaciones,
        p_transporte_total, p_policy_code, now(), 'COP', p_margen_override_pct
    );

    IF EXISTS (SELECT 1 FROM tmp_componentes_calculados WHERE status <> 'OK') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC,
            (SELECT status FROM tmp_componentes_calculados WHERE status <> 'OK' LIMIT 1);
        RETURN;
    END IF;

    IF p_margen_override_pct IS NOT NULL THEN
        SELECT MAX(minimum_pct) INTO v_max_minimum FROM tmp_componentes_calculados;
        v_below_minimum := p_margen_override_pct < v_max_minimum;

        IF v_below_minimum AND v_rol <> 'ADMIN' THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'MARGIN_BELOW_MINIMUM'::TEXT;
            RETURN;
        END IF;
    END IF;

    SELECT SUM(precio_resultante) INTO v_total FROM tmp_componentes_calculados;

    BEGIN
        INSERT INTO cotizacion (
            id_organizacion, estado, moneda, total, creada_por, rol_consola, notas,
            metodo_precio, fecha_emision, origen, canal_origen, idempotency_key
        )
        VALUES (
            p_id_organizacion, 'EMITIDA', 'COP', v_total,
            auth.uid(), v_rol, nullif(btrim(p_notas), ''),
            'CALCULO_COMPONENTES', now(), 'CONSOLA', 'INTERNO', v_key
        )
        RETURNING cotizacion.id_cotizacion, cotizacion.numero, cotizacion.total
          INTO v_id_cotizacion, v_numero, v_total;
    EXCEPTION WHEN unique_violation THEN
        IF v_key IS NULL THEN
            RAISE;
        END IF;

        SELECT c.id_cotizacion, c.numero, c.total,
               (c.id_organizacion IS NOT DISTINCT FROM p_id_organizacion
                AND ci.id_producto IS NOT DISTINCT FROM p_id_producto
                AND ci.id_variante IS NOT DISTINCT FROM p_id_variante
                AND ci.cantidad IS NOT DISTINCT FROM p_cantidad
                AND ci.id_tecnica IS NOT DISTINCT FROM p_id_tecnica)
          INTO v_id_cotizacion, v_numero, v_total, v_payload_coincide
          FROM cotizacion c
          JOIN cotizacion_item ci ON ci.id_cotizacion = c.id_cotizacion
         WHERE c.creada_por = auth.uid()
           AND c.idempotency_key = v_key
         LIMIT 1;

        IF FOUND THEN
            RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total,
                (CASE WHEN v_payload_coincide THEN 'OK' ELSE 'CONFLICT' END)::TEXT;
            RETURN;
        END IF;

        RAISE;
    END;

    INSERT INTO cotizacion_item (
        id_cotizacion, id_producto, id_variante, cantidad, precio_unitario, subtotal,
        producto_snapshot, id_tecnica
    )
    VALUES (
        v_id_cotizacion, p_id_producto, p_id_variante, p_cantidad,
        round(v_total / p_cantidad, 2), v_total,
        jsonb_build_object('id_producto', p_id_producto, 'capturado_en', now()),
        p_id_tecnica
    )
    RETURNING cotizacion_item.id_cotizacion_item INTO v_id_item;

    FOR v_comp IN SELECT * FROM tmp_componentes_calculados LOOP
        INSERT INTO cotizacion_componente (
            id_cotizacion_item, tipo_componente, descripcion, cantidad, costo_unitario,
            costo_total, pricing_method, margen_aplicado_pct, precio_resultante,
            source_type, source_snapshot_id, metadata
        )
        VALUES (
            v_id_item, v_comp.tipo_componente, v_comp.descripcion, v_comp.cantidad,
            v_comp.costo_unitario, v_comp.costo_total, v_comp.pricing_method,
            v_comp.margen_aplicado_pct, v_comp.precio_resultante,
            v_comp.source_type, v_comp.source_snapshot_id, v_comp.metadata
        );
    END LOOP;

    INSERT INTO cotizacion_evento (id_cotizacion, tipo_evento, estado_anterior, estado_nuevo, actor_tipo, actor_id, rol_consola, metadata)
    VALUES (v_id_cotizacion, 'CREADA', NULL, 'EMITIDA', 'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('metodo_precio', 'CALCULO_COMPONENTES', 'margen_override_pct', p_margen_override_pct));

    RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) IS
    'Crea una cotizacion real calculada desde costos versionados (reemplaza a fn_consola_crear_cotizacion_simple en la UI desde 062). ADMIN y COMERCIAL. Persiste cotizacion_componente -antes muerta en produccion-. Override de margen bloqueado bajo el minimo salvo para ADMIN.';
```

Nota: `producto_tecnica.id_tecnica` en `cotizacion_item` requiere que la columna exista — ya existe desde 050 (`ALTER TABLE cotizacion_item ADD COLUMN id_tecnica UUID REFERENCES tecnica_marcacion`). Verificar con `\d cotizacion_item` antes de aplicar si hay dudas.

- [ ] **Step 4: Aplicar y correr el test**

```powershell
.\scripts\apply_pending_migrations.ps1
psql -v ON_ERROR_STOP=1 -f database/tests/test_quote_calculada.sql $env:DATABASE_URL
```

Expected: todos los `PASSED`, `ROLLBACK` final.

- [ ] **Step 5: Correr la suite completa para descartar regresiones**

```powershell
.\scripts\run_db_tests.ps1
python scripts/audit_change.py --all
```

- [ ] **Step 6: Regenerar checksums y commitear**

```bash
python scripts/backfill_migration_checksums.py --apply
git add database/migrations/062_quote_calculated_creation.sql database/migrations/CHECKSUMS.txt database/tests/test_quote_calculada.sql
git commit -m "feat: persist calculated quotes with role-gated margin override"
```

---

## Task 4: Selector de técnicas disponibles

**Files:**
- Create: `database/migrations/063_tecnicas_disponibles_producto.sql`
- Test: `database/tests/test_tecnicas_disponibles.sql`

**Interfaces:**
- Produces: `fn_consola_tecnicas_disponibles_producto(p_id_producto UUID, p_id_variante UUID DEFAULT NULL) RETURNS TABLE(id_tecnica UUID, codigo TEXT)` — solo técnicas `permitida=true` en `producto_tecnica` que además tienen un snapshot vigente con `usage_status='AUTOMATIC_PRICING'` y `verification_status='VERIFIED_PUBLIC_PRICE'`.

- [ ] **Step 1: Escribir el test primero**

```sql
-- database/tests/test_tecnicas_disponibles.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES ('00000000-0000-4000-fe00-000000000001', 'admin-tecdisp@prueba.local');
INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES ('00000000-0000-4000-fe00-000000000001', 'admin-tecdisp@prueba.local', 'ADMIN', true);

INSERT INTO producto (id_producto, sku, nombre, estado) VALUES ('00000000-0000-4000-fe00-000000000003', 'TEST-TECDISP', 'Producto test tecnicas', 'ACTIVE');

INSERT INTO tecnica_marcacion (id_tecnica, codigo) VALUES
    ('00000000-0000-4000-fe00-000000000010', 'con_snapshot'),
    ('00000000-0000-4000-fe00-000000000011', 'sin_snapshot');

INSERT INTO producto_tecnica (id_producto_tecnica, id_producto, id_variante, id_tecnica, cantidad_minima_tecnica, cantidad_recomendada, configuracion_estandar, merma_pct, permitida) VALUES
    ('00000000-0000-4000-fe00-000000000020', '00000000-0000-4000-fe00-000000000003', NULL, '00000000-0000-4000-fe00-000000000010', 1, 1, '{}'::jsonb, 0, true),
    ('00000000-0000-4000-fe00-000000000021', '00000000-0000-4000-fe00-000000000003', NULL, '00000000-0000-4000-fe00-000000000011', 1, 1, '{}'::jsonb, 0, true);

INSERT INTO proveedor_tecnica_marcacion (id_proveedor_tecnica, source_id, nombre)
VALUES ('00000000-0000-4000-fe00-000000000030', 'fixture_tecdisp_provider', 'Proveedor test tecdisp');

INSERT INTO precio_tecnica_marcacion_snapshot (id_snapshot, id_tecnica, id_proveedor_tecnica, observation_id, service_component, price_scope, billing_unit, currency, price_value, fetched_at, verification_status)
VALUES ('00000000-0000-4000-fe00-000000000040', '00000000-0000-4000-fe00-000000000010', '00000000-0000-4000-fe00-000000000030', 'fixture-tecdisp-2026', 'marcacion', 'solo_marcacion', 'unidad', 'COP', 1000, now(), 'VERIFIED_PUBLIC_PRICE');

INSERT INTO curacion_precio_tecnica_marcacion (id_snapshot, usage_status, formula_code)
VALUES ('00000000-0000-4000-fe00-000000000040', 'AUTOMATIC_PRICING', 'unit_fixture');

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM fn_consola_tecnicas_disponibles_producto('00000000-0000-4000-fe00-000000000003')
     WHERE id_tecnica = '00000000-0000-4000-fe00-000000000010';
    ASSERT v_count = 1, 'la tecnica con snapshot curado debe aparecer';

    SELECT COUNT(*) INTO v_count FROM fn_consola_tecnicas_disponibles_producto('00000000-0000-4000-fe00-000000000003')
     WHERE id_tecnica = '00000000-0000-4000-fe00-000000000011';
    ASSERT v_count = 0, 'la tecnica sin snapshot curado NO debe aparecer';

    RAISE NOTICE 'PASSED - solo se ofrecen tecnicas con snapshot curado vigente';
END;
$$;

RESET ROLE;
ROLLBACK;
```

- [ ] **Step 2: Correr para verificar que falla** — `psql -v ON_ERROR_STOP=1 -f database/tests/test_tecnicas_disponibles.sql $env:DATABASE_URL` → FAIL, función no existe.

- [ ] **Step 3: Escribir la migración**

```sql
-- ============================================================
-- 063_tecnicas_disponibles_producto.sql
--
-- Selector para el formulario del cotizador: solo ofrece tecnicas que de
-- verdad se pueden cotizar automatico (mismo filtro que usa
-- fn_quote_calculate_components_core para MARKING_COST_NOT_FOUND), para
-- que el usuario no llene todo el formulario y se encuentre con el error
-- al final.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_tecnicas_disponibles_producto(
    p_id_producto uuid,
    p_id_variante uuid DEFAULT NULL::uuid
)
RETURNS TABLE(id_tecnica uuid, codigo text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL', 'LECTURA') THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT DISTINCT tm.id_tecnica, tm.codigo
      FROM producto_tecnica pt
      JOIN tecnica_marcacion tm ON tm.id_tecnica = pt.id_tecnica
      JOIN precio_tecnica_marcacion_snapshot pts ON pts.id_tecnica = pt.id_tecnica
      JOIN curacion_precio_tecnica_marcacion c ON c.id_snapshot = pts.id_snapshot
     WHERE pt.id_producto = p_id_producto
       AND COALESCE(pt.id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
           = COALESCE(p_id_variante, '00000000-0000-0000-0000-000000000000'::uuid)
       AND pt.permitida
       AND c.usage_status = 'AUTOMATIC_PRICING'
       AND pts.verification_status = 'VERIFIED_PUBLIC_PRICE'
       AND lower(COALESCE(pts.billing_unit, '')) = 'unidad'
     ORDER BY tm.codigo;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID) TO authenticated;

COMMENT ON FUNCTION fn_consola_tecnicas_disponibles_producto(UUID, UUID) IS
    'Lista tecnicas permitidas para un producto que ademas tienen snapshot curado vigente (AUTOMATIC_PRICING + VERIFIED_PUBLIC_PRICE) - para que el selector del cotizador no ofrezca una tecnica que despues fallaria con MARKING_COST_NOT_FOUND.';
```

- [ ] **Step 4: Aplicar y correr el test** — `PASSED`.

- [ ] **Step 5: Regenerar checksums y commitear.**

```bash
python scripts/backfill_migration_checksums.py --apply
git add database/migrations/063_tecnicas_disponibles_producto.sql database/migrations/CHECKSUMS.txt database/tests/test_tecnicas_disponibles.sql
git commit -m "feat: list only techniques with a curated price snapshot available"
```

---

## Task 5: Alta rápida de proveedor y técnica

**Files:**
- Create: `database/migrations/064_alta_rapida_proveedor_tecnica.sql`
- Test: `database/tests/test_alta_rapida_proveedor_tecnica.sql`

**Interfaces:**
- Produces: `fn_consola_crear_proveedor_rapido(p_nombre TEXT) RETURNS TABLE(id_proveedor UUID, status TEXT)`, `fn_consola_crear_tecnica_rapida(p_codigo TEXT) RETURNS TABLE(id_tecnica UUID, status TEXT)`.

- [ ] **Step 1: Escribir el test primero**

```sql
-- database/tests/test_alta_rapida_proveedor_tecnica.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-ff00-000000000001', 'admin-altarapida@prueba.local'),
    ('00000000-0000-4000-ff00-000000000002', 'lectura-altarapida@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-ff00-000000000001', 'admin-altarapida@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-ff00-000000000002', 'lectura-altarapida@prueba.local', 'LECTURA', true);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ff00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE r RECORD; v_activo BOOLEAN; v_source_id TEXT;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_proveedor_rapido('Proveedor Alta Rapida SAS');
    ASSERT r.status = 'OK', format('debe crear OK, obtuve %s', r.status);

    SELECT activo, source_id INTO v_activo, v_source_id FROM proveedor WHERE id_proveedor = r.id_proveedor;
    ASSERT v_activo = true, 'el proveedor de alta rapida nace activo';
    ASSERT v_source_id LIKE 'MANUAL-%', 'debe tener un source_id sintetico para satisfacer el UNIQUE';

    RAISE NOTICE 'PASSED - alta rapida de proveedor';
END;
$$;

DO $$
DECLARE r RECORD; v_status TEXT;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_tecnica_rapida('tecnica_alta_rapida_test');
    ASSERT r.status = 'OK', format('debe crear OK, obtuve %s', r.status);

    SELECT verification_status INTO v_status FROM tecnica_marcacion WHERE id_tecnica = r.id_tecnica;
    ASSERT v_status = 'PENDING_REVIEW', format('debe nacer PENDING_REVIEW (default de la tabla), obtuve %s', v_status);

    RAISE NOTICE 'PASSED - alta rapida de tecnica';
END;
$$;

RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-ff00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueado BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_crear_proveedor_rapido('No deberia crearse');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueado := true;
    END;
    ASSERT v_bloqueado, 'LECTURA no debe poder crear proveedores';
    RAISE NOTICE 'PASSED - LECTURA bloqueada en alta rapida';
END;
$$;

RESET ROLE;
ROLLBACK;
```

- [ ] **Step 2: Correr para verificar que falla.**

- [ ] **Step 3: Escribir la migración**

```sql
-- ============================================================
-- 064_alta_rapida_proveedor_tecnica.sql
--
-- Alta minima de proveedor/tecnica desde el cotizador, sin interrumpir el
-- flujo de armar una cotizacion. No se agrega vocabulario de verificacion
-- nuevo: proveedor no tiene columna de estado (solo `activo`, que ya nace
-- true para cualquier proveedor) y tecnica_marcacion ya tiene
-- verification_status DEFAULT 'PENDING_REVIEW' desde 021 - el registro
-- creado aqui simplemente hereda ese default. La revision humana pasa por
-- /proveedores y /tecnicas, igual que cualquier otro registro.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_crear_proveedor_rapido(
    p_nombre text
)
RETURNS TABLE(id_proveedor uuid, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_nombre TEXT := NULLIF(btrim(p_nombre), '');
    v_id UUID;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear proveedores.';
    END IF;

    IF v_nombre IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, 'INVALID_INPUT'::TEXT;
        RETURN;
    END IF;

    INSERT INTO proveedor (nombre, source_id, activo)
    VALUES (v_nombre, 'MANUAL-' || gen_random_uuid()::text, true)
    RETURNING proveedor.id_proveedor INTO v_id;

    RETURN QUERY SELECT v_id, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_proveedor_rapido(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_proveedor_rapido(TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_proveedor_rapido(TEXT) IS
    'Alta minima de proveedor desde el cotizador. Nace activo, sin columna de verificacion (no existe en el esquema) - la revision pasa por /proveedores.';

CREATE OR REPLACE FUNCTION public.fn_consola_crear_tecnica_rapida(
    p_codigo text
)
RETURNS TABLE(id_tecnica uuid, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_codigo TEXT := NULLIF(btrim(p_codigo), '');
    v_id UUID;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear tecnicas.';
    END IF;

    IF v_codigo IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, 'INVALID_INPUT'::TEXT;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM tecnica_marcacion WHERE codigo = v_codigo) THEN
        RETURN QUERY SELECT NULL::UUID, 'DUPLICATE_CODE'::TEXT;
        RETURN;
    END IF;

    INSERT INTO tecnica_marcacion (codigo)
    VALUES (v_codigo)
    RETURNING tecnica_marcacion.id_tecnica INTO v_id;

    RETURN QUERY SELECT v_id, 'OK'::TEXT;
END;
$function$;

REVOKE ALL ON FUNCTION fn_consola_crear_tecnica_rapida(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_tecnica_rapida(TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_tecnica_rapida(TEXT) IS
    'Alta minima de tecnica de marcacion desde el cotizador. verification_status queda en su default (PENDING_REVIEW, 021) - sin snapshot curado, fn_consola_tecnicas_disponibles_producto no la ofrecera hasta que alguien cargue un precio verificado.';
```

- [ ] **Step 4: Aplicar y correr el test.**

- [ ] **Step 5: Regenerar checksums y commitear.**

```bash
python scripts/backfill_migration_checksums.py --apply
git add database/migrations/064_alta_rapida_proveedor_tecnica.sql database/migrations/CHECKSUMS.txt database/tests/test_alta_rapida_proveedor_tecnica.sql
git commit -m "feat: quick-add supplier/technique from the quote builder"
```

---

## Task 6: Frontend — flujo de dos pasos en /cotizador

**Files:**
- Modify: `web/src/app/cotizador/page.tsx` (reescritura completa)
- Modify: `web/src/app/cotizador/acciones.ts` (reescritura completa)

**Interfaces:**
- Consumes: `fn_consola_crear_cotizacion_calculada`, `fn_calculate_quote_components` (Task 1/3), `fn_consola_tecnicas_disponibles_producto` (Task 4), `fn_consola_crear_proveedor_rapido`/`fn_consola_crear_tecnica_rapida` (Task 5), `fn_consola_componentes_cotizacion` (Task 2).
- Produces: la página redirige a `/cotizador/{id}` (Task 7) tras crear con éxito.

Este task no tiene ciclo TDD de backend — se verifica manualmente contra Postgres local + `npm run dev`, siguiendo el patrón de verificación de UI ya usado en el proyecto (no hay Playwright instalado de forma permanente; instalar puntual si se quiere probar con navegador real, igual que en la sesión de QA).

- [ ] **Step 1: Reescribir `acciones.ts`**

```typescript
"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { crearClienteServidor } from "@/lib/supabase/servidor";

function leerNumero(formData: FormData, campo: string): number | null {
  const v = formData.get(campo);
  if (v === null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

export async function calcularCotizacion(formData: FormData) {
  const idProducto = String(formData.get("id_producto") ?? "");
  const idVariante = String(formData.get("id_variante") ?? "") || null;
  const cantidad = leerNumero(formData, "cantidad") ?? 0;
  const idTecnica = String(formData.get("id_tecnica") ?? "") || null;
  const numeroPreparaciones = leerNumero(formData, "numero_preparaciones") ?? 1;
  const transporteTotal = leerNumero(formData, "transporte_total") ?? 0;
  const margenOverride = leerNumero(formData, "margen_override_pct");

  const params = new URLSearchParams({
    id_producto: idProducto,
    cantidad: String(cantidad),
    numero_preparaciones: String(numeroPreparaciones),
    transporte_total: String(transporteTotal),
  });
  if (idVariante) params.set("id_variante", idVariante);
  if (idTecnica) params.set("id_tecnica", idTecnica);
  if (margenOverride !== null) params.set("margen_override_pct", String(margenOverride));
  const idOrganizacion = String(formData.get("id_organizacion") ?? "");
  if (idOrganizacion) params.set("id_organizacion", idOrganizacion);
  const notas = String(formData.get("notas") ?? "");
  if (notas) params.set("notas", notas);

  redirect(`/cotizador?paso=revisar&${params.toString()}`);
}

export async function confirmarCotizacion(formData: FormData) {
  const idProducto = String(formData.get("id_producto") ?? "");
  const idVariante = String(formData.get("id_variante") ?? "") || null;
  const idOrganizacion = String(formData.get("id_organizacion") ?? "") || null;
  const cantidad = leerNumero(formData, "cantidad") ?? 0;
  const idTecnica = String(formData.get("id_tecnica") ?? "") || null;
  const numeroPreparaciones = leerNumero(formData, "numero_preparaciones") ?? 1;
  const transporteTotal = leerNumero(formData, "transporte_total") ?? 0;
  const margenOverride = leerNumero(formData, "margen_override_pct");
  const notas = String(formData.get("notas") ?? "") || null;
  const idempotencyKey = String(formData.get("idempotency_key") ?? "") || null;

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_crear_cotizacion_calculada", {
    p_id_organizacion: idOrganizacion,
    p_id_producto: idProducto,
    p_id_variante: idVariante,
    p_cantidad: cantidad,
    p_id_tecnica: idTecnica,
    p_numero_preparaciones: numeroPreparaciones,
    p_transporte_total: transporteTotal,
    p_margen_override_pct: margenOverride,
    p_notas: notas,
    p_idempotency_key: idempotencyKey,
  });

  revalidatePath("/cotizador");

  if (error) redirect(`/cotizador?error=${encodeURIComponent(error.message)}`);

  const resultado = data?.[0] as { id_cotizacion: string | null; status: string } | undefined;
  if (!resultado || resultado.status !== "OK") {
    redirect(`/cotizador?status=${encodeURIComponent(resultado?.status ?? "ERROR")}`);
  }

  redirect(`/cotizador/${resultado.id_cotizacion}`);
}

export async function altaRapidaProveedor(formData: FormData) {
  const nombre = String(formData.get("nombre_proveedor") ?? "");
  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_crear_proveedor_rapido", { p_nombre: nombre });
  revalidatePath("/proveedores");
  if (error) redirect(`/cotizador?error=${encodeURIComponent(error.message)}`);
  redirect(`/cotizador?ok=proveedor`);
}

export async function altaRapidaTecnica(formData: FormData) {
  const codigo = String(formData.get("codigo_tecnica") ?? "");
  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_crear_tecnica_rapida", { p_codigo: codigo });
  revalidatePath("/tecnicas");
  if (error) redirect(`/cotizador?error=${encodeURIComponent(error.message)}`);
  redirect(`/cotizador?ok=tecnica`);
}
```

- [ ] **Step 2: Reescribir `page.tsx`**

```tsx
import { randomUUID } from "node:crypto";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import { calcularCotizacion, confirmarCotizacion, altaRapidaProveedor, altaRapidaTecnica } from "./acciones";

export const dynamic = "force-dynamic";

const cop = (v: string | number | null) =>
  v === null ? "—" : "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

export default async function PaginaCotizador({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const sp = await searchParams;
  const supabase = await crearClienteServidor();
  const puedeCotizar = sesion.rol === "ADMIN" || sesion.rol === "COMERCIAL";
  const idempotencyKey = randomUUID();

  const [{ data: organizaciones }, { data: productos }] = await Promise.all([
    supabase.from("organizacion").select("id_organizacion, nombre_legal, nit").order("nombre_legal").limit(200),
    supabase.from("producto").select("id_producto, sku, nombre, estado").eq("estado", "ACTIVE").order("sku"),
  ]);

  const idProductoSeleccionado = sp.id_producto ?? "";
  let tecnicas: { id_tecnica: string; codigo: string }[] = [];
  if (idProductoSeleccionado) {
    const { data } = await supabase.rpc("fn_consola_tecnicas_disponibles_producto", {
      p_id_producto: idProductoSeleccionado,
    });
    tecnicas = data ?? [];
  }

  const enPasoRevisar = sp.paso === "revisar" && idProductoSeleccionado;
  let componentes: Array<{
    tipo_componente: string;
    descripcion: string;
    cantidad: number;
    costo_unitario: number | null;
    costo_total: number | null;
    margen_aplicado_pct: number | null;
    precio_resultante: number;
    status: string;
  }> = [];
  let totalCalculado = 0;
  let statusCalculo = "OK";

  if (enPasoRevisar) {
    const { data } = await supabase.rpc("fn_calculate_quote_components", {
      p_id_producto: idProductoSeleccionado,
      p_id_variante: sp.id_variante || null,
      p_cantidad: Number(sp.cantidad ?? 1),
      p_id_tecnica: sp.id_tecnica || null,
      p_numero_preparaciones: Number(sp.numero_preparaciones ?? 1),
      p_transporte_total: Number(sp.transporte_total ?? 0),
    });
    componentes = data ?? [];
    statusCalculo = componentes[0]?.status ?? "ERROR";
    totalCalculado = componentes.reduce((acc, c) => acc + Number(c.precio_resultante ?? 0), 0);
  }

  return (
    <>
      <h1>Cotizador</h1>
      <p className="subtitulo">Cotización calculada desde costo real de producto y técnica de marcación.</p>

      {sp.ok === "proveedor" && <div className="aviso-caja neutro">Proveedor creado. Ya está disponible en /proveedores.</div>}
      {sp.ok === "tecnica" && <div className="aviso-caja neutro">Técnica creada. Ya está disponible en /tecnicas.</div>}
      {sp.status && <div className="aviso-caja">No se pudo cotizar: <code>{sp.status}</code>.</div>}
      {sp.error && <div className="aviso-caja">{sp.error}</div>}

      {!enPasoRevisar && (
        <div className="tarjeta">
          <h2>1. Datos de la cotización</h2>
          <form action={calcularCotizacion} className="filtros">
            <select name="id_organizacion" defaultValue="" disabled={!puedeCotizar}>
              <option value="">Sin organización asociada</option>
              {(organizaciones ?? []).map((o) => (
                <option key={o.id_organizacion} value={o.id_organizacion}>
                  {o.nombre_legal}{o.nit ? ` - ${o.nit}` : ""}
                </option>
              ))}
            </select>
            <select name="id_producto" required disabled={!puedeCotizar}>
              <option value="">Producto</option>
              {(productos ?? []).map((p) => (
                <option key={p.id_producto} value={p.id_producto}>{p.sku} - {p.nombre}</option>
              ))}
            </select>
            <input name="cantidad" type="number" min="1" placeholder="Cantidad" required disabled={!puedeCotizar} />
            <select name="id_tecnica" disabled={!puedeCotizar}>
              <option value="">Sin técnica</option>
              {tecnicas.map((t) => (
                <option key={t.id_tecnica} value={t.id_tecnica}>{t.codigo}</option>
              ))}
            </select>
            <input name="numero_preparaciones" type="number" min="0" defaultValue="1" placeholder="Preparaciones" disabled={!puedeCotizar} />
            <input name="transporte_total" type="number" min="0" defaultValue="0" placeholder="Transporte" disabled={!puedeCotizar} />
            {sesion.rol === "ADMIN" && (
              <input name="margen_override_pct" type="number" step="0.01" placeholder="Margen % (opcional)" disabled={!puedeCotizar} />
            )}
            <input name="notas" placeholder="Notas" disabled={!puedeCotizar} />
            <button type="submit" disabled={!puedeCotizar}>Calcular</button>
          </form>

          <details style={{ marginTop: 16 }}>
            <summary>+ Agregar proveedor</summary>
            <form action={altaRapidaProveedor} className="filtros" style={{ marginTop: 8 }}>
              <input name="nombre_proveedor" placeholder="Nombre del proveedor" required />
              <button type="submit">Crear proveedor</button>
            </form>
          </details>
          <details style={{ marginTop: 8 }}>
            <summary>+ Agregar técnica</summary>
            <form action={altaRapidaTecnica} className="filtros" style={{ marginTop: 8 }}>
              <input name="codigo_tecnica" placeholder="Código de la técnica" required />
              <button type="submit">Crear técnica</button>
            </form>
          </details>
        </div>
      )}

      {enPasoRevisar && (
        <div className="tarjeta">
          <h2>2. Revisar antes de confirmar</h2>
          {statusCalculo !== "OK" ? (
            <div className="aviso-caja">No se pudo calcular: <code>{statusCalculo}</code>. Volvé al paso 1.</div>
          ) : (
            <>
              <div className="tabla-contenedor">
                <table>
                  <thead>
                    <tr>
                      <th>Componente</th>
                      {sesion.rol === "ADMIN" && <th className="num">Costo</th>}
                      {sesion.rol === "ADMIN" && <th className="num">Margen %</th>}
                      <th className="num">Precio</th>
                    </tr>
                  </thead>
                  <tbody>
                    {componentes.map((c, i) => (
                      <tr key={i}>
                        <td>{c.descripcion}</td>
                        {sesion.rol === "ADMIN" && <td className="num">{cop(c.costo_total)}</td>}
                        {sesion.rol === "ADMIN" && <td className="num">{c.margen_aplicado_pct ?? "—"}</td>}
                        <td className="num">{cop(c.precio_resultante)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <p><strong>Total: {cop(totalCalculado)}</strong></p>
              <form action={confirmarCotizacion}>
                <input type="hidden" name="idempotency_key" value={idempotencyKey} />
                <input type="hidden" name="id_producto" value={sp.id_producto} />
                <input type="hidden" name="id_variante" value={sp.id_variante ?? ""} />
                <input type="hidden" name="id_organizacion" value={sp.id_organizacion ?? ""} />
                <input type="hidden" name="cantidad" value={sp.cantidad ?? "1"} />
                <input type="hidden" name="id_tecnica" value={sp.id_tecnica ?? ""} />
                <input type="hidden" name="numero_preparaciones" value={sp.numero_preparaciones ?? "1"} />
                <input type="hidden" name="transporte_total" value={sp.transporte_total ?? "0"} />
                <input type="hidden" name="margen_override_pct" value={sp.margen_override_pct ?? ""} />
                <input type="hidden" name="notas" value={sp.notas ?? ""} />
                <button type="submit">Confirmar y generar cotización</button>
              </form>
            </>
          )}
        </div>
      )}
    </>
  );
}
```

- [ ] **Step 3: Verificar manualmente contra Postgres local + `npm run dev`**

```powershell
. C:\Users\willi\pg-estampados\entorno.ps1
cd web
npm run dev
```

Abrir `/cotizador`, loguear con una cuenta ADMIN real de STAGING, calcular una cotización de un producto con costo vigente, confirmar que la tabla de componentes se ve, confirmar, y verificar que redirige a `/cotizador/{id}` (fallará hasta Task 7 — es esperado, verificar solo hasta la redirección).

- [ ] **Step 4: `npm run verificar` y commit**

```bash
cd web && npm run verificar
git add web/src/app/cotizador/page.tsx web/src/app/cotizador/acciones.ts
git commit -m "feat: two-step calculated quote flow in the cotizador page"
```

---

## Task 7: Pantalla de revisión + botón de correo deshabilitado

**Files:**
- Create: `web/src/app/cotizador/[id]/page.tsx`

**Interfaces:**
- Consumes: `fn_consola_componentes_cotizacion` (Task 2), tabla `cotizacion`.
- Produces: enlace a `/cotizador/[id]/pdf` (Task 8).

- [ ] **Step 1: Escribir la página**

```tsx
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

const cop = (v: string | number | null) =>
  v === null ? "—" : "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

export default async function RevisionCotizacion({ params }: { params: Promise<{ id: string }> }) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const supabase = await crearClienteServidor();

  const [{ data: cotizacion }, { data: componentes }] = await Promise.all([
    supabase.from("cotizacion").select("id_cotizacion, numero, total, estado, fecha_emision").eq("id_cotizacion", id).maybeSingle(),
    supabase.rpc("fn_consola_componentes_cotizacion", { p_id_cotizacion: id }),
  ]);

  if (!cotizacion) {
    return <h1>Cotización no encontrada</h1>;
  }

  const filas = componentes ?? [];

  return (
    <>
      <h1>Cotización #{cotizacion.numero}</h1>
      <p className="subtitulo">Emitida {new Date(cotizacion.fecha_emision).toLocaleString("es-CO")}</p>

      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Componente</th>
              {sesion.rol === "ADMIN" && <th className="num">Costo</th>}
              {sesion.rol === "ADMIN" && <th className="num">Margen %</th>}
              <th className="num">Precio</th>
            </tr>
          </thead>
          <tbody>
            {filas.map((c: { descripcion: string; costo_total: number | null; margen_aplicado_pct: number | null; precio_resultante: number }, i: number) => (
              <tr key={i}>
                <td>{c.descripcion}</td>
                {sesion.rol === "ADMIN" && <td className="num">{cop(c.costo_total)}</td>}
                {sesion.rol === "ADMIN" && <td className="num">{c.margen_aplicado_pct ?? "—"}</td>}
                <td className="num">{cop(c.precio_resultante)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p><strong>Total: {cop(cotizacion.total)}</strong></p>

      <div className="filtros">
        <a href={`/cotizador/${id}/pdf`}><button type="button">Generar PDF</button></a>
        <button type="button" disabled title="Próximamente">Enviar por correo</button>
      </div>
    </>
  );
}
```

- [ ] **Step 2: Verificar manualmente** — repetir el flujo de Task 6 Step 3 completo; confirmar que la pantalla de revisión carga con los datos correctos y que el botón de correo aparece deshabilitado.

- [ ] **Step 3: `npm run verificar` y commit**

```bash
cd web && npm run verificar
git add web/src/app/cotizador/\[id\]/page.tsx
git commit -m "feat: quote review screen with disabled email button"
```

---

## Task 8: Generación de PDF

**Files:**
- Modify: `web/package.json` (agregar `@react-pdf/renderer`)
- Create: `web/src/app/cotizador/[id]/pdf/documento.tsx`
- Create: `web/src/app/cotizador/[id]/pdf/route.ts`

**Interfaces:**
- Consumes: `fn_consola_componentes_cotizacion` (Task 2), tabla `cotizacion`.
- Produces: `GET /cotizador/{id}/pdf` → descarga PDF.

- [ ] **Step 1: Instalar la dependencia**

```bash
cd web
npm install @react-pdf/renderer
```

- [ ] **Step 2: Escribir el documento PDF**

```tsx
// web/src/app/cotizador/[id]/pdf/documento.tsx
import { Document, Page, Text, View, StyleSheet } from "@react-pdf/renderer";

const styles = StyleSheet.create({
  page: { padding: 32, fontSize: 11, fontFamily: "Helvetica" },
  titulo: { fontSize: 18, marginBottom: 4 },
  subtitulo: { fontSize: 10, color: "#555", marginBottom: 16 },
  filaEncabezado: { flexDirection: "row", borderBottom: 1, paddingBottom: 4, marginBottom: 4, fontWeight: 700 },
  fila: { flexDirection: "row", paddingVertical: 3, borderBottom: 0.5, borderColor: "#ddd" },
  colDescripcion: { flex: 3 },
  colPrecio: { flex: 1, textAlign: "right" },
  total: { marginTop: 12, fontSize: 13, textAlign: "right" },
});

const cop = (v: number) => "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

export type ComponentePdf = { descripcion: string; precio_resultante: number };

export function DocumentoCotizacion({
  numero,
  fecha,
  total,
  componentes,
}: {
  numero: number;
  fecha: string;
  total: number;
  componentes: ComponentePdf[];
}) {
  return (
    <Document>
      <Page size="A4" style={styles.page}>
        <Text style={styles.titulo}>Cotización #{numero}</Text>
        <Text style={styles.subtitulo}>Estampados Promocionales · {fecha}</Text>

        <View style={styles.filaEncabezado}>
          <Text style={styles.colDescripcion}>Concepto</Text>
          <Text style={styles.colPrecio}>Precio</Text>
        </View>
        {componentes.map((c, i) => (
          <View style={styles.fila} key={i}>
            <Text style={styles.colDescripcion}>{c.descripcion}</Text>
            <Text style={styles.colPrecio}>{cop(c.precio_resultante)}</Text>
          </View>
        ))}

        <Text style={styles.total}>Total: {cop(total)}</Text>
      </Page>
    </Document>
  );
}
```

- [ ] **Step 3: Escribir la ruta**

```typescript
// web/src/app/cotizador/[id]/pdf/route.ts
import { renderToBuffer } from "@react-pdf/renderer";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { DocumentoCotizacion } from "./documento";

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) {
    return new Response("No autorizado", { status: 401 });
  }

  const { id } = await params;
  const supabase = await crearClienteServidor();

  const [{ data: cotizacion }, { data: componentes }] = await Promise.all([
    supabase.from("cotizacion").select("numero, total, fecha_emision").eq("id_cotizacion", id).maybeSingle(),
    supabase.rpc("fn_consola_componentes_cotizacion", { p_id_cotizacion: id }),
  ]);

  if (!cotizacion) {
    return new Response("Cotización no encontrada", { status: 404 });
  }

  const buffer = await renderToBuffer(
    DocumentoCotizacion({
      numero: cotizacion.numero,
      fecha: new Date(cotizacion.fecha_emision).toLocaleString("es-CO"),
      total: Number(cotizacion.total),
      componentes: componentes ?? [],
    })
  );

  return new Response(new Uint8Array(buffer), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `attachment; filename="cotizacion-${cotizacion.numero}.pdf"`,
    },
  });
}
```

- [ ] **Step 4: Verificar manualmente**

```powershell
cd web
npm run dev
```

Loguear, ir a una cotización existente (`/cotizador/{id}`), clic en "Generar PDF", confirmar que descarga un PDF legible con el desglose correcto (enmascarado por rol si se prueba con COMERCIAL — el PDF no debe filtrar más que la pantalla).

- [ ] **Step 5: `npm run verificar` y commit**

```bash
cd web && npm run verificar
git add web/package.json web/package-lock.json "web/src/app/cotizador/[id]/pdf/documento.tsx" "web/src/app/cotizador/[id]/pdf/route.ts"
git commit -m "feat: PDF generation for calculated quotes via @react-pdf/renderer"
```

---

## Task 9: Regresión final y push

- [ ] **Step 1: Suite completa desde base vacía (local)**

```powershell
. C:\Users\willi\pg-estampados\entorno.ps1
.\scripts\apply_pending_migrations.ps1
.\scripts\run_db_tests.ps1
python -m unittest scripts.evals.run_evals -v
python scripts/audit_change.py --all
cd web; npm run check:privilegios; npm run test; npm run verificar
```

- [ ] **Step 2: Verificar contra un clon limpio antes de pushear** (lección de la sesión anterior — ver memoria `feedback_verificar_estado_limpio`)

```bash
git stash -u
# repetir Step 1 sobre el estado stasheado si aplica, o clonar a un temporal
git stash pop
```

- [ ] **Step 3: Push**

```bash
git push origin master
```
