-- ============================================================
-- 048_fix_ia_proposal_expiry_rollback.sql
--
-- Corrige un bug real en fn_consola_aprobar_accion_ia (045), encontrado
-- por revision de codigo externa.
--
-- HALLAZGO
-- El UPDATE a estado='EXPIRADA' y el RAISE EXCEPTION siguiente ocurren en
-- la misma ejecucion, sin ningun bloque EXCEPTION que cree un savepoint
-- implicito alrededor del UPDATE. Cuando el RAISE EXCEPTION propaga fuera
-- de la funcion, Postgres revierte toda la transaccion -incluido ese
-- UPDATE-, asi que la propuesta se queda en PENDIENTE para siempre.
-- Cada intento futuro de aprobarla repite el mismo ciclo: intenta marcar
-- EXPIRADA, lo revierte al lanzar la excepcion, sigue en PENDIENTE.
--
-- Verificado el comportamiento contra Postgres antes de escribir la
-- correccion (misma disciplina que 046 con la logica de NULL NOT IN).
--
-- CORRECCION
-- Expirar no es un error del llamador -es un estado que se descubre al
-- consultar, como una tarjeta de credito vencida en caja-. Se marca
-- EXPIRADA con un RETURN normal (sin excepcion), para que el UPDATE
-- persista como parte de la ejecucion exitosa de la funcion. El llamador
-- ve estado='EXPIRADA' en la fila devuelta en vez de recibir una
-- excepcion, y el siguiente intento de aprobarla cae en el chequeo
-- "solo se puede resolver una propuesta PENDIENTE" de forma normal.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_consola_aprobar_accion_ia(
    p_id_ia_accion_propuesta UUID,
    p_aprobar BOOLEAN,
    p_notas TEXT DEFAULT NULL
)
RETURNS TABLE (
    id_ia_accion_propuesta UUID,
    estado                  TEXT,
    aprobada_at             TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rol           TEXT := fn_consola_rol();
    v_estado_actual TEXT;
    v_expira_at     TIMESTAMPTZ;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden aprobar o rechazar propuestas de IA.';
    END IF;

    SELECT iap.estado, iap.expira_at
      INTO v_estado_actual, v_expira_at
      FROM ia_accion_propuesta iap
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Propuesta no encontrada.';
    END IF;

    IF v_estado_actual <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'Solo se puede resolver una propuesta PENDIENTE. Estado actual: %', v_estado_actual;
    END IF;

    -- Expirar no es un error del llamador: se persiste con RETURN normal,
    -- no con RAISE, para que el UPDATE no se revierta a si mismo.
    --
    -- WHERE calificado con el nombre de tabla: id_ia_accion_propuesta
    -- tambien es una columna de salida de esta funcion (RETURNS TABLE), y
    -- PL/pgSQL la trae al alcance como variable, lo que vuelve ambiguo el
    -- nombre sin calificar (mismo caso que occurred_at en fn_ai_cliente_timeline, 045).
    IF now() > v_expira_at THEN
        UPDATE ia_accion_propuesta
           SET estado = 'EXPIRADA'
         WHERE ia_accion_propuesta.id_ia_accion_propuesta = p_id_ia_accion_propuesta;

        RETURN QUERY
        SELECT iap.id_ia_accion_propuesta, iap.estado, iap.aprobada_at
          FROM ia_accion_propuesta iap
         WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta;
        RETURN;
    END IF;

    UPDATE ia_accion_propuesta iap
       SET estado       = CASE WHEN p_aprobar THEN 'APROBADA' ELSE 'RECHAZADA' END,
           aprobada_por = auth.uid(),
           aprobada_at  = now(),
           resultado    = CASE WHEN nullif(btrim(p_notas), '') IS NOT NULL
                                THEN jsonb_build_object('notas', btrim(p_notas))
                                ELSE iap.resultado END
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta;

    RETURN QUERY
    SELECT iap.id_ia_accion_propuesta, iap.estado, iap.aprobada_at
      FROM ia_accion_propuesta iap
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta;
END;
$$;

REVOKE ALL ON FUNCTION fn_consola_aprobar_accion_ia(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_consola_aprobar_accion_ia(UUID, BOOLEAN, TEXT) TO authenticated;

COMMENT ON FUNCTION fn_consola_aprobar_accion_ia(UUID, BOOLEAN, TEXT) IS
    'Corregido en 048: expirar se persiste con RETURN normal, no con RAISE+UPDATE (el RAISE revertia el UPDATE y la propuesta quedaba PENDIENTE para siempre).';
