-- ============================================================
-- test_ia_proposal_expiry.sql
-- Verifica que expirar una propuesta de IA persista (048), en vez de
-- revertirse a si misma como antes de la correccion.
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-f900-000000000001', 'comercial-expiry@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-f900-000000000001', 'comercial-expiry@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-f900-000000000010',
    '900444555',
    'ORGANIZACION EXPIRY',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

-- Sesion y propuesta ya vencida, insertadas directamente (como owner) para
-- fijar expira_at en el pasado sin depender de p_vigencia_horas.
INSERT INTO ia_sesion (id_ia_sesion, id_usuario, rol_consola)
VALUES ('00000000-0000-4000-f900-000000000020', '00000000-0000-4000-f900-000000000001', 'COMERCIAL');

INSERT INTO ia_accion_propuesta (
    id_ia_accion_propuesta, id_ia_sesion, id_organizacion, tipo_accion,
    justificacion, expira_at
) VALUES (
    '00000000-0000-4000-f900-000000000030',
    '00000000-0000-4000-f900-000000000020',
    '00000000-0000-4000-f900-000000000010',
    'REGISTRAR_INTERACCION',
    'propuesta de prueba ya vencida',
    now() - interval '1 hour'
);

SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f900-000000000001"}', true);
SET LOCAL ROLE authenticated;

-- ----------------------------------------------------------
-- Antes de 048: esto lanzaba excepcion Y revertia el UPDATE a EXPIRADA,
-- dejando la propuesta en PENDIENTE para siempre. Ahora debe devolver la
-- fila con estado='EXPIRADA' sin excepcion, y quedar persistido.
-- ----------------------------------------------------------
DO $$
DECLARE v_estado TEXT; v_excepcion BOOLEAN := false;
BEGIN
    BEGIN
        SELECT estado INTO v_estado
          FROM fn_consola_aprobar_accion_ia(
            '00000000-0000-4000-f900-000000000030', true, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_excepcion := true;
    END;
    ASSERT NOT v_excepcion, 'aprobar una propuesta vencida no debe lanzar excepcion (048)';
    ASSERT v_estado = 'EXPIRADA', format('esperaba EXPIRADA, obtuve %s', v_estado);
    RAISE NOTICE 'PASSED - expirar no lanza excepcion, devuelve EXPIRADA';
END;
$$;

RESET ROLE;

-- El UPDATE debe haber persistido de verdad (no revertido).
DO $$
DECLARE v_estado TEXT;
BEGIN
    SELECT estado INTO v_estado
      FROM ia_accion_propuesta
     WHERE id_ia_accion_propuesta = '00000000-0000-4000-f900-000000000030';
    ASSERT v_estado = 'EXPIRADA', 'EXPIRADA debe persistir en la tabla, no revertirse';
    RAISE NOTICE 'PASSED - EXPIRADA persiste en la base';
END;
$$;

-- Un segundo intento de aprobarla cae en "ya resuelta", no repite el ciclo.
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-f900-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_aprobar_accion_ia(
            '00000000-0000-4000-f900-000000000030', true, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'una propuesta ya EXPIRADA no debe poder aprobarse en un segundo intento';
    RAISE NOTICE 'PASSED - un segundo intento no repite el ciclo de expiracion';
END;
$$;

RESET ROLE;

ROLLBACK;
