-- ============================================================
-- 068_fix_transporte_idempotency_comparison.sql
--
-- IMPORTANT fix from the final whole-branch review of cotizador-calculado:
-- fn_quote_calculated_payload_matches (064) compared the retry's
-- p_transporte_total against SUM(precio_resultante) of the persisted
-- TRANSPORTE component -a POST-margin value- and p_numero_preparaciones
-- against SUM(cantidad) of persisted PREPARACION components. Both are
-- proxies for what was actually submitted, reconstructed from computed
-- output instead of read from the input itself. It only looked correct
-- because MVP_DEFAULT prices TRANSPORTE at PASS_THROUGH 0% margin, so
-- input and output happened to match by coincidence. Reproduced live
-- during review with a non-zero-margin TRANSPORTE policy: an identical
-- legitimate retry (same idempotency_key, same payload) incorrectly
-- returned CONFLICT, and a genuinely different payload incorrectly
-- returned OK with the stale quote.
--
-- Fix: fn_consola_crear_cotizacion_calculada (062/064) already stores the
-- exact submitted p_transporte_total and p_numero_preparaciones, untouched
-- by margin, in the CREADA cotizacion_evento's metadata at creation time.
-- Read those instead of reverse-engineering them from persisted component
-- rows. Keeps the existing "preparaciones only matters when a technique is
-- selected" normalization (harmless input differences without a technique
-- must not cause a spurious CONFLICT), now applied to the raw stored value
-- instead of a computed one.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_quote_calculated_payload_matches(
    p_id_cotizacion uuid,
    p_id_organizacion uuid,
    p_id_producto uuid,
    p_id_variante uuid,
    p_cantidad integer,
    p_id_tecnica uuid,
    p_numero_preparaciones integer,
    p_transporte_total numeric,
    p_policy_code text,
    p_margen_override_pct numeric
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(bool_and(
        c.id_organizacion IS NOT DISTINCT FROM p_id_organizacion
        AND ci.id_producto IS NOT DISTINCT FROM p_id_producto
        AND ci.id_variante IS NOT DISTINCT FROM p_id_variante
        AND ci.cantidad IS NOT DISTINCT FROM p_cantidad
        AND ci.id_tecnica IS NOT DISTINCT FROM p_id_tecnica
        AND mpv.codigo IS NOT DISTINCT FROM COALESCE(p_policy_code, 'MVP_DEFAULT')
        AND COALESCE((ev.metadata->>'transporte_total')::numeric, 0)
            IS NOT DISTINCT FROM COALESCE(p_transporte_total, 0)
        AND (CASE WHEN ci.id_tecnica IS NULL THEN 0
                  ELSE COALESCE((ev.metadata->>'numero_preparaciones')::integer, 1) END)
            IS NOT DISTINCT FROM
            (CASE WHEN p_id_tecnica IS NULL THEN 0 ELSE COALESCE(p_numero_preparaciones, 1) END)
        AND (ev.metadata->>'margen_override_pct')::numeric IS NOT DISTINCT FROM p_margen_override_pct
    ), false)
      FROM cotizacion c
      JOIN cotizacion_item ci ON ci.id_cotizacion = c.id_cotizacion
      LEFT JOIN margin_policy_version mpv ON mpv.id_margin_policy_version = c.id_margin_policy_version
      LEFT JOIN LATERAL (
          SELECT ce.metadata
            FROM cotizacion_evento ce
           WHERE ce.id_cotizacion = c.id_cotizacion
             AND ce.tipo_evento = 'CREADA'
           ORDER BY ce.occurred_at ASC
           LIMIT 1
      ) ev ON true
     WHERE c.id_cotizacion = p_id_cotizacion;
$function$;

COMMENT ON FUNCTION fn_quote_calculated_payload_matches(UUID, UUID, UUID, UUID, INTEGER, UUID, INTEGER, NUMERIC, TEXT, NUMERIC) IS
    'Helper interno para idempotencia de cotizacion calculada: compara el payload comercial completo persistido contra el retry. No se otorga a authenticated. Desde 068, transporte_total y numero_preparaciones se leen del metadata crudo del evento CREADA, no de componentes ya calculados post-margen (068 corrigio un falso-CONFLICT/falso-OK cuando TRANSPORTE tiene una politica de margen distinta de PASS_THROUGH 0%).';
