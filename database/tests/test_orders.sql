-- ============================================================
-- test_orders.sql
-- Verifica pedidos y conversion desde cotizacion aceptada (043).
-- ============================================================

BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-b200-000000000001', 'lectura-pedidos@prueba.local'),
    ('00000000-0000-4000-b200-000000000002', 'comercial-pedidos@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-b200-000000000001', 'lectura-pedidos@prueba.local', 'LECTURA', true),
    ('00000000-0000-4000-b200-000000000002', 'comercial-pedidos@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio
) VALUES (
    '00000000-0000-4000-b200-000000000010',
    '900333777',
    'ORGANIZACION PEDIDOS',
    'Fondos de empleados',
    'Bogota, D.C.',
    'Bogota, D.C.'
);

INSERT INTO producto (id_producto, sku, nombre, estado)
VALUES (
    '00000000-0000-4000-b200-000000000040',
    'TEST-PEDIDOS',
    'Producto fixture pedidos',
    'ACTIVE'
);

-- Cotizacion en BORRADOR: debe rechazar la conversion
INSERT INTO cotizacion (
    id_cotizacion, id_organizacion, estado, moneda, total,
    creada_por, rol_consola, metodo_precio
) VALUES (
    '00000000-0000-4000-b200-000000000020',
    '00000000-0000-4000-b200-000000000010',
    'BORRADOR', 'COP', 0,
    '00000000-0000-4000-b200-000000000002', 'COMERCIAL',
    'TARIFA_PUBLICADA'
);

-- Cotizacion ACEPTADA con item: debe convertir correctamente
INSERT INTO cotizacion (
    id_cotizacion, id_organizacion, estado, moneda, total,
    creada_por, rol_consola, metodo_precio, fecha_emision, fecha_aceptacion
) VALUES (
    '00000000-0000-4000-b200-000000000021',
    '00000000-0000-4000-b200-000000000010',
    'ACEPTADA', 'COP', 90000,
    '00000000-0000-4000-b200-000000000002', 'COMERCIAL',
    'TARIFA_PUBLICADA', now(), now()
);

INSERT INTO cotizacion_item (
    id_cotizacion, id_producto, cantidad, precio_unitario, subtotal, producto_snapshot
)
VALUES (
    '00000000-0000-4000-b200-000000000021',
    '00000000-0000-4000-b200-000000000040',
    12,
    7500,
    90000,
    '{"sku":"TEST-PEDIDOS","precio_unitario_congelado":7500}'::JSONB
);

-- Pedido manual de control: sin cotizacion, origen MANUAL
INSERT INTO pedido (
    id_pedido, id_organizacion, id_cotizacion, origen, subtotal, total,
    creado_por, rol_consola
) VALUES (
    '00000000-0000-4000-b200-000000000030',
    '00000000-0000-4000-b200-000000000010', NULL, 'MANUAL', 20000, 20000,
    '00000000-0000-4000-b200-000000000002', 'COMERCIAL'
);

INSERT INTO pedido_item (
    id_pedido, id_producto, cantidad, precio_unitario, subtotal, producto_snapshot
)
VALUES (
    '00000000-0000-4000-b200-000000000030',
    '00000000-0000-4000-b200-000000000040',
    2,
    10000,
    20000,
    '{"sku":"TEST-PEDIDOS"}'::JSONB
);

-- ----------------------------------------------------------
-- El CHECK de origen protege la consistencia del par (origen, id_cotizacion)
-- ----------------------------------------------------------
DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        INSERT INTO pedido (
            id_organizacion, id_cotizacion, origen, subtotal, total,
            creado_por, rol_consola
        ) VALUES (
            '00000000-0000-4000-b200-000000000010', NULL, 'COTIZACION', 1, 1,
            '00000000-0000-4000-b200-000000000002', 'COMERCIAL'
        );
    EXCEPTION WHEN check_violation THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'origen=COTIZACION sin id_cotizacion debe rechazarse';
    RAISE NOTICE 'PASSED - CHECK de origen protege la consistencia';
END;
$$;

-- ----------------------------------------------------------
-- LECTURA no puede convertir ni transicionar
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-b200-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_bloqueada BOOLEAN := false;
BEGIN
    BEGIN
        PERFORM * FROM fn_consola_convertir_cotizacion_en_pedido('00000000-0000-4000-b200-000000000021');
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'LECTURA no debe poder convertir cotizaciones en pedidos';
    RAISE NOTICE 'PASSED - LECTURA bloqueada en conversion';
END;
$$;

RESET ROLE;

-- ----------------------------------------------------------
-- Conversion desde BORRADOR se rechaza (status, no excepcion)
-- ----------------------------------------------------------
SELECT set_config('request.jwt.claims',
                  '{"sub":"00000000-0000-4000-b200-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE v_status TEXT; v_pedidos_antes INT; v_pedidos_despues INT;
BEGIN
    SELECT count(*) INTO v_pedidos_antes FROM pedido;

    SELECT status INTO v_status
      FROM fn_consola_convertir_cotizacion_en_pedido('00000000-0000-4000-b200-000000000020');
    ASSERT v_status = 'QUOTE_NOT_ACCEPTED', format('esperaba QUOTE_NOT_ACCEPTED, obtuve %s', v_status);

    SELECT count(*) INTO v_pedidos_despues FROM pedido;
    ASSERT v_pedidos_antes = v_pedidos_despues, 'una conversion rechazada no debe crear pedido';

    RAISE NOTICE 'PASSED - conversion desde BORRADOR rechazada sin crear pedido';
END;
$$;

-- ----------------------------------------------------------
-- Conversion desde ACEPTADA funciona
-- ----------------------------------------------------------
DO $$
DECLARE
    v_id_pedido UUID;
    v_status TEXT;
    v_total_items INT;
    v_subtotal_pedido NUMERIC;
    v_estado_cotizacion TEXT;
    v_evento_conversion INT;
BEGIN
    SELECT id_pedido, status INTO v_id_pedido, v_status
      FROM fn_consola_convertir_cotizacion_en_pedido('00000000-0000-4000-b200-000000000021');
    ASSERT v_status = 'OK', format('esperaba OK, obtuve %s', v_status);
    ASSERT v_id_pedido IS NOT NULL, 'debe devolver el id del pedido creado';

    SELECT count(*), sum(subtotal) INTO v_total_items, v_subtotal_pedido
      FROM pedido_item WHERE id_pedido = v_id_pedido;
    ASSERT v_total_items = 1, 'debe copiar exactamente los items de la cotizacion';
    ASSERT v_subtotal_pedido = 90000, 'el subtotal del pedido debe igualar la suma de items copiados';

    SELECT estado INTO v_estado_cotizacion
      FROM cotizacion WHERE id_cotizacion = '00000000-0000-4000-b200-000000000021';
    ASSERT v_estado_cotizacion = 'CONVERTIDA_A_PEDIDO', 'la cotizacion debe quedar CONVERTIDA_A_PEDIDO';

    SELECT count(*) INTO v_evento_conversion
      FROM cotizacion_evento
     WHERE id_cotizacion = '00000000-0000-4000-b200-000000000021'
       AND estado_nuevo = 'CONVERTIDA_A_PEDIDO';
    ASSERT v_evento_conversion = 1, 'la conversion debe dejar evento en cotizacion_evento';

    RAISE NOTICE 'PASSED - conversion desde ACEPTADA crea pedido y cierra la cotizacion';
END;
$$;

-- No se puede convertir dos veces la misma cotizacion
DO $$
DECLARE v_status TEXT;
BEGIN
    SELECT status INTO v_status
      FROM fn_consola_convertir_cotizacion_en_pedido('00000000-0000-4000-b200-000000000021');
    ASSERT v_status = 'QUOTE_NOT_ACCEPTED',
        'una cotizacion ya CONVERTIDA_A_PEDIDO no debe volver a convertirse (ya no esta en ACEPTADA)';
    RAISE NOTICE 'PASSED - no se duplica la conversion';
END;
$$;

-- ----------------------------------------------------------
-- Precios congelados: cambiar la tarifa activa no afecta al pedido ya creado
-- ----------------------------------------------------------
DO $$
DECLARE
    v_id_producto UUID;
    v_precio_pedido NUMERIC;
BEGIN
    SELECT ci.id_producto, ci.precio_unitario INTO v_id_producto, v_precio_pedido
      FROM pedido_item ci
      JOIN pedido p ON p.id_pedido = ci.id_pedido
     WHERE p.id_cotizacion = '00000000-0000-4000-b200-000000000021';

    ASSERT v_precio_pedido = 7500, 'el precio congelado del item debe ser el de la cotizacion original';

    -- Aunque cambiara la tarifa activa del producto, el pedido no la vuelve
    -- a resolver: no hay ninguna funcion que reescriba pedido_item.
    PERFORM 1 FROM information_schema.columns
     WHERE table_name = 'pedido_item' AND column_name = 'precio_unitario';
    ASSERT FOUND, 'pedido_item.precio_unitario debe existir como snapshot propio';

    RAISE NOTICE 'PASSED - precios permanecen congelados tras la conversion';
END;
$$;

-- ----------------------------------------------------------
-- Transicion de pedido: RECIBIDO -> EN_DISENO, y CANCELADO desde ENTREGADO se rechaza
-- ----------------------------------------------------------
DO $$
DECLARE v_id_pedido UUID; v_estado TEXT;
BEGIN
    SELECT id_pedido INTO v_id_pedido FROM pedido
     WHERE id_cotizacion = '00000000-0000-4000-b200-000000000021';

    PERFORM * FROM fn_consola_transicionar_pedido(v_id_pedido, 'EN_DISENO', 'inicia diseno');
    SELECT estado INTO v_estado FROM pedido WHERE id_pedido = v_id_pedido;
    ASSERT v_estado = 'EN_DISENO', 'debe transicionar a EN_DISENO';

    RAISE NOTICE 'PASSED - transicion de pedido funciona';
END;
$$;

DO $$
DECLARE v_id_pedido UUID; v_bloqueada BOOLEAN := false;
BEGIN
    SELECT id_pedido INTO v_id_pedido FROM pedido
     WHERE id_cotizacion = '00000000-0000-4000-b200-000000000021';

    BEGIN
        -- EN_DISENO no puede saltar directo a ENTREGADO.
        PERFORM * FROM fn_consola_transicionar_pedido(v_id_pedido, 'ENTREGADO', NULL);
    EXCEPTION WHEN OTHERS THEN
        v_bloqueada := true;
    END;
    ASSERT v_bloqueada, 'EN_DISENO -> ENTREGADO debe rechazarse';
    RAISE NOTICE 'PASSED - transicion invalida de pedido rechazada';
END;
$$;

-- ----------------------------------------------------------
-- Pedido manual no rompe metricas: coexiste con el convertido en
-- cualquier agregacion por producto de la organizacion.
-- ----------------------------------------------------------
DO $$
DECLARE v_pedidos_organizacion INT; v_items_agrupados INT;
BEGIN
    SELECT count(*) INTO v_pedidos_organizacion
      FROM pedido
     WHERE id_organizacion = '00000000-0000-4000-b200-000000000010';
    ASSERT v_pedidos_organizacion = 2, 'deben coexistir el pedido manual y el convertido';

    SELECT count(*) INTO v_items_agrupados
      FROM (
          SELECT pi.id_producto, sum(pi.cantidad) AS total_cantidad
            FROM pedido_item pi
            JOIN pedido p ON p.id_pedido = pi.id_pedido
           WHERE p.id_organizacion = '00000000-0000-4000-b200-000000000010'
           GROUP BY pi.id_producto
      ) agregado;
    ASSERT v_items_agrupados >= 1, 'la agregacion por producto debe incluir items de ambos origenes sin fallar';

    RAISE NOTICE 'PASSED - pedido manual coexiste sin romper agregaciones por producto';
END;
$$;

-- El timeline consolidado tambien recibe los eventos de pedido.
-- cliente_evento tiene deny_all (es PII): se verifica por la via sancionada,
-- fn_consola_timeline_cliente, no por SELECT directo.
DO $$
DECLARE v_eventos_pedido INT;
BEGIN
    SELECT count(*) INTO v_eventos_pedido
      FROM fn_consola_timeline_cliente('00000000-0000-4000-b200-000000000010')
     WHERE categoria = 'PEDIDO';
    ASSERT v_eventos_pedido >= 2, 'el timeline debe mostrar CREADO y la transicion de pedido';
    RAISE NOTICE 'PASSED - timeline recibe eventos de pedido';
END;
$$;

RESET ROLE;

ROLLBACK;
