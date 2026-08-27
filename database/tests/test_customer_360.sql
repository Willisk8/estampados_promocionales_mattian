-- ============================================================
-- test_customer_360.sql
-- Verifica Cliente 360, metricas y temperatura derivada (044).
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-c300-000000000001', 'lectura-360@prueba.local'),
    ('00000000-0000-4000-c300-000000000002', 'comercial-360@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-c300-000000000001', 'lectura-360@prueba.local', 'LECTURA', true),
    ('00000000-0000-4000-c300-000000000002', 'comercial-360@prueba.local', 'COMERCIAL', true);

-- Cliente A: sin ninguna gestion nunca -> debe aparecer en sin_gestion y FRIO
INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-c300-00000000000a',
    '900111000',
    'ORGANIZACION SIN GESTION',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

-- Cliente B: interaccion reciente -> ACTIVO, no aparece en sin_gestion
INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-c300-00000000000b',
    '900222000',
    'ORGANIZACION ACTIVA',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

-- Cliente C: DESCARTADO -> PERDIDO pese a tener interaccion reciente
INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-c300-00000000000c',
    '900333000',
    'ORGANIZACION DESCARTADA',
    'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'
);

INSERT INTO relacion_comercial_organizacion (id_organizacion, estado_comercial, actualizado_por)
VALUES ('00000000-0000-4000-c300-00000000000c', 'DESCARTADO', '00000000-0000-4000-c300-000000000002');

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES (
    '00000000-0000-4000-c300-000000000040',
    'TEST-CLIENTE-360',
    'Producto fixture Cliente 360',
    'ACTIVE'
);

-- Un pedido y una cotizacion con item para calcular metricas de compra/cotizado
INSERT INTO cotizacion (
    id_cotizacion, id_organizacion, estado, moneda, total,
    creada_por, rol_consola, metodo_precio, fecha_emision
) VALUES (
    '00000000-0000-4000-c300-000000000020',
    '00000000-0000-4000-c300-00000000000b',
    'ACEPTADA', 'COP', 100000,
    '00000000-0000-4000-c300-000000000002', 'COMERCIAL', 'TARIFA_PUBLICADA', now()
);

INSERT INTO cotizacion_item (
    id_cotizacion, id_producto, cantidad, precio_unitario, subtotal, producto_snapshot
)
VALUES (
    '00000000-0000-4000-c300-000000000020',
    '00000000-0000-4000-c300-000000000040',
    10,
    10000,
    100000,
    '{"sku":"TEST-CLIENTE-360"}'::JSONB
);

INSERT INTO pedido (
    id_pedido, id_organizacion, id_cotizacion, origen, subtotal, total,
    creado_por, rol_consola
) VALUES (
    '00000000-0000-4000-c300-000000000030',
    '00000000-0000-4000-c300-00000000000b', NULL, 'MANUAL', 40000, 40000,
    '00000000-0000-4000-c300-000000000002', 'COMERCIAL'
);

INSERT INTO pedido_item (
    id_pedido, id_producto, cantidad, precio_unitario, subtotal, producto_snapshot
)
VALUES (
    '00000000-0000-4000-c300-000000000030',
    '00000000-0000-4000-c300-000000000040',
    4,
    10000,
    40000,
    '{"sku":"TEST-CLIENTE-360"}'::JSONB
);

-- ----------------------------------------------------------
-- LECTURA registra la interaccion reciente del Cliente B y C
-- (usa la funcion de Fase 1, ya probada; aqui solo se usa como fixture)
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-c300-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
BEGIN
    PERFORM * FROM fn_consola_registrar_interaccion(
        '00000000-0000-4000-c300-00000000000b', 'LLAMADA', 'OUTBOUND', 'SEGUIMIENTO');
    PERFORM * FROM fn_consola_registrar_interaccion(
        '00000000-0000-4000-c300-00000000000c', 'LLAMADA', 'OUTBOUND', 'SEGUIMIENTO');
END;
$$;

-- ----------------------------------------------------------
-- Cliente sin gestion aparece; cliente con interaccion no aparece
-- ----------------------------------------------------------
DO $$
DECLARE v_presente BOOLEAN; v_ausente BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM fn_consola_clientes_sin_gestion(30)
         WHERE id_organizacion = '00000000-0000-4000-c300-00000000000a'
    ) INTO v_presente;
    ASSERT v_presente, 'un cliente sin ninguna gestion debe aparecer como pendiente';

    SELECT NOT EXISTS (
        SELECT 1 FROM fn_consola_clientes_sin_gestion(30)
         WHERE id_organizacion = '00000000-0000-4000-c300-00000000000b'
    ) INTO v_ausente;
    ASSERT v_ausente, 'un cliente con interaccion reciente no debe aparecer como sin gestion';

    RAISE NOTICE 'PASSED - fn_consola_clientes_sin_gestion distingue gestionados de no gestionados';
END;
$$;

-- ----------------------------------------------------------
-- Temperatura: FRIO / ACTIVO / PERDIDO segun corresponda
-- ----------------------------------------------------------
DO $$
DECLARE v_temp TEXT;
BEGIN
    SELECT temperatura INTO v_temp FROM fn_consola_cliente_360('00000000-0000-4000-c300-00000000000a');
    ASSERT v_temp = 'FRIO', format('cliente sin gestion debe ser FRIO, fue %s', v_temp);

    SELECT temperatura INTO v_temp FROM fn_consola_cliente_360('00000000-0000-4000-c300-00000000000b');
    ASSERT v_temp = 'ACTIVO', format('cliente con interaccion reciente debe ser ACTIVO, fue %s', v_temp);

    SELECT temperatura INTO v_temp FROM fn_consola_cliente_360('00000000-0000-4000-c300-00000000000c');
    ASSERT v_temp = 'PERDIDO', 'DESCARTADO debe imponerse sobre la interaccion reciente';

    RAISE NOTICE 'PASSED - temperatura respeta precedencia DESCARTADO > interaccion reciente';
END;
$$;

-- La temperatura cambia al insertar una interaccion reciente
DO $$
DECLARE v_temp_antes TEXT; v_temp_despues TEXT;
BEGIN
    SELECT temperatura INTO v_temp_antes FROM fn_consola_cliente_360('00000000-0000-4000-c300-00000000000a');
    ASSERT v_temp_antes = 'FRIO', 'estado inicial debe ser FRIO';

    PERFORM * FROM fn_consola_registrar_interaccion(
        '00000000-0000-4000-c300-00000000000a', 'VISITA', 'OUTBOUND', 'SEGUIMIENTO');

    SELECT temperatura INTO v_temp_despues FROM fn_consola_cliente_360('00000000-0000-4000-c300-00000000000a');
    ASSERT v_temp_despues = 'ACTIVO', 'tras una interaccion reciente el cliente debe pasar a ACTIVO';

    RAISE NOTICE 'PASSED - la temperatura cambia al registrar una interaccion';
END;
$$;

-- ----------------------------------------------------------
-- Cliente con pedidos muestra producto mas comprado
-- ----------------------------------------------------------
DO $$
DECLARE v_producto TEXT; v_vendido NUMERIC; v_cotizado NUMERIC;
BEGIN
    SELECT producto_mas_comprado, valor_total_vendido, valor_total_cotizado
      INTO v_producto, v_vendido, v_cotizado
      FROM fn_consola_cliente_360('00000000-0000-4000-c300-00000000000b');

    ASSERT v_producto IS NOT NULL, 'un cliente con pedidos debe mostrar producto_mas_comprado';
    ASSERT v_vendido = 40000, 'valor_total_vendido debe sumar los pedidos del cliente';
    ASSERT v_cotizado = 100000, 'valor_total_cotizado debe sumar las cotizaciones del cliente';

    RAISE NOTICE 'PASSED - metricas de compra y cotizacion correctas';
END;
$$;

-- ----------------------------------------------------------
-- Cotizaciones abiertas calculan dias activas
-- ----------------------------------------------------------
DO $$
DECLARE v_dias INT; v_abiertas INT;
BEGIN
    SELECT dias_activa INTO v_dias FROM vw_cotizaciones_activas
     WHERE id_cotizacion = '00000000-0000-4000-c300-000000000020';
    ASSERT v_dias >= 0, 'dias_activa debe ser un numero no negativo';

    SELECT cotizaciones_abiertas INTO v_abiertas
      FROM fn_consola_cliente_360('00000000-0000-4000-c300-00000000000b');
    ASSERT v_abiertas = 1, 'el cliente B debe tener 1 cotizacion abierta (ACEPTADA, no convertida)';

    RAISE NOTICE 'PASSED - vw_cotizaciones_activas y conteo de abiertas correctos';
END;
$$;

-- ----------------------------------------------------------
-- Ninguna vista/funcion de esta fase devuelve un correo sin enmascarar
-- ----------------------------------------------------------
DO $$
DECLARE v_texto TEXT;
BEGIN
    SELECT string_agg(v.temperatura || coalesce(v.canal_preferido, ''), ' ')
      INTO v_texto
      FROM (VALUES
          ('00000000-0000-4000-c300-00000000000a'::uuid),
          ('00000000-0000-4000-c300-00000000000b'::uuid),
          ('00000000-0000-4000-c300-00000000000c'::uuid)
      ) AS o(id_organizacion)
      CROSS JOIN LATERAL fn_consola_cliente_360(o.id_organizacion) AS v;

    ASSERT v_texto !~ '@', 'fn_consola_cliente_360 no debe exponer ningun correo';
    RAISE NOTICE 'PASSED - fn_consola_cliente_360 no expone correos';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- LECTURA no puede escribir preferencias, pero si puede leer las vistas 360
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-c300-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_actualizar_preferencia_cliente(
            '00000000-0000-4000-c300-00000000000a', 'EMAIL');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'LECTURA no debe poder actualizar preferencias';
    RAISE NOTICE 'PASSED - LECTURA bloqueada al actualizar preferencia';
END;
$$;

DO $$
DECLARE v_temp TEXT;
BEGIN
    SELECT temperatura INTO v_temp FROM fn_consola_cliente_360('00000000-0000-4000-c300-00000000000a');
    ASSERT v_temp IS NOT NULL, 'LECTURA debe poder consultar el 360 aunque no pueda escribir';
    RAISE NOTICE 'PASSED - LECTURA puede leer fn_consola_cliente_360';
END;
$$;

RESET ROLE;

ROLLBACK;
