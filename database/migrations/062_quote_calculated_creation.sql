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
--
-- GAP resuelto respecto al diseno original: cotizacion tiene el CHECK
-- ck_cotizacion_margen_versionado (040), que exige
-- id_margin_policy_version poblado cuando metodo_precio =
-- 'CALCULO_COMPONENTES' (el metodo que esta funcion siempre usa). En vez
-- de resolver la politica una segunda vez con una consulta aparte -que
-- podria, en teoria, devolver una version distinta si vigencia cambia
-- entre ambas llamadas-, se lee el mismo id_margin_policy_version que el
-- nucleo de calculo ya dejo en cada fila de metadata (clave 'policy_id',
-- ver 060): asi se garantiza que la version registrada en cotizacion es
-- exactamente la que se uso para calcular los precios.
--
-- NOTA DE FIRMA: el orden de parametros del brief original intercalaba
-- p_id_organizacion DEFAULT NULL antes de p_id_producto/p_cantidad (sin
-- default), lo cual Postgres rechaza ("input parameters after one with a
-- default value must also have defaults"). Se reordena dejando los dos
-- parametros obligatorios primero; no rompe compatibilidad porque todo
-- llamador (test incluido) pasa argumentos por nombre (=>), nunca
-- posicionalmente.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_consola_crear_cotizacion_calculada(
    p_id_producto uuid,
    p_cantidad integer,
    p_id_organizacion uuid DEFAULT NULL::uuid,
    p_id_variante uuid DEFAULT NULL::uuid,
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
    v_id_policy UUID;
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
    -- DROP explicito antes de crear: ON COMMIT DROP solo limpia al terminar
    -- la transaccion, no la sentencia. Si esta funcion se llama mas de una
    -- vez dentro de la misma transaccion (tests con multiples DO $$ antes
    -- de ROLLBACK; o, en produccion, un llamador que agrupa varias
    -- llamadas en una sola transaccion), la segunda llamada choca con la
    -- tabla temporal que la primera aun no vio dropeada.
    DROP TABLE IF EXISTS tmp_componentes_calculados;

    CREATE TEMPORARY TABLE tmp_componentes_calculados ON COMMIT DROP AS
    SELECT * FROM fn_quote_calculate_components_core(
        p_id_producto, p_id_variante, p_cantidad, p_id_tecnica, p_numero_preparaciones,
        p_transporte_total, p_policy_code, now(), 'COP', p_margen_override_pct
    );

    -- Calificado con el alias tc: 'status' tambien es una columna de salida
    -- de esta funcion (RETURNS TABLE), y PL/pgSQL la trae al alcance como
    -- variable, lo que vuelve ambiguo el nombre sin calificar (mismo bug
    -- documentado en 050 para fn_consola_crear_cotizacion_simple).
    IF EXISTS (SELECT 1 FROM tmp_componentes_calculados tc WHERE tc.status <> 'OK') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC,
            (SELECT tc.status FROM tmp_componentes_calculados tc WHERE tc.status <> 'OK' LIMIT 1);
        RETURN;
    END IF;

    -- Misma version de politica que efectivamente calculo los precios:
    -- el nucleo (060) la deja en metadata->>'policy_id' de cada fila OK.
    SELECT (metadata->>'policy_id')::UUID INTO v_id_policy
      FROM tmp_componentes_calculados
     LIMIT 1;

    -- costo_producto no exige costo_base > 0 (006): un producto con todos
    -- los costos en su default de 0, sin tecnica ni transporte, hace que
    -- el nucleo devuelva cero filas pese a que la politica y el costo
    -- vigente si se resolvieron. Sin esta guarda, v_id_policy quedaria
    -- NULL y el INSERT de mas abajo reventaria contra
    -- ck_cotizacion_margen_versionado (040) con un error crudo en vez de
    -- un status de negocio controlado.
    IF v_id_policy IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'NO_COMPONENTS'::TEXT;
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
            metodo_precio, id_margin_policy_version, fecha_emision, origen, canal_origen,
            idempotency_key
        )
        VALUES (
            p_id_organizacion, 'EMITIDA', 'COP', v_total,
            auth.uid(), v_rol, nullif(btrim(p_notas), ''),
            'CALCULO_COMPONENTES', v_id_policy, now(), 'CONSOLA', 'INTERNO', v_key
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

REVOKE ALL ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_crear_cotizacion_calculada(UUID, INTEGER, UUID, UUID, UUID, INTEGER, NUMERIC, TEXT, NUMERIC, TEXT, TEXT) IS
    'Crea una cotizacion real calculada desde costos versionados (reemplaza a fn_consola_crear_cotizacion_simple en la UI desde 062). ADMIN y COMERCIAL. Persiste cotizacion_componente -antes muerta en produccion-. id_margin_policy_version se toma de metadata->>policy_id del propio calculo (nunca se resuelve dos veces). Override de margen bloqueado bajo el minimo salvo para ADMIN.';
