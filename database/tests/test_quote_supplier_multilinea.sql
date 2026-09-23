-- database/tests/test_quote_supplier_multilinea.sql
--
-- Cubre fn_consola_crear_cotizacion_proveedor_multilinea y
-- fn_consola_items_cotizacion (migracion 075).
--
-- El fixture del producto empacado replica a proposito el caso real de
-- STAGING que motivo el cambio: "CAJA SUBLIMABLE DULCE PAQUETE X 10 UNIDADES"
-- (SY-SGB3), $18.000 el paquete de 10. La regla que se prueba es que la
-- cantidad de una linea PACK son PRESENTACIONES, no unidades sueltas:
--   1 paquete  -> 10 unidades -> costo base 18.000
--   3 paquetes -> 30 unidades -> costo base 54.000  (nunca 5.400)
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fd00-000000000001', 'admin-multilinea@prueba.local'),
    ('00000000-0000-4000-fd00-000000000002', 'comercial-multilinea@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fd00-000000000001', 'admin-multilinea@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fd00-000000000002', 'comercial-multilinea@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio)
VALUES ('00000000-0000-4000-fd00-000000000010', '901777666', 'ORG MULTILINEA TEST', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.');

INSERT INTO proveedor (id_proveedor, source_id, nombre, ciudad)
VALUES ('00000000-0000-4000-fd00-000000000020', 'test_multilinea', 'Proveedor Test Multilinea', 'Bogota');

-- Producto empacado: caja x10 a 18.000 (replica de SY-SGB3).
INSERT INTO producto_proveedor (
    id_producto_proveedor, id_proveedor, sku_proveedor, nombre_original, categoria, estado_calidad
)
VALUES (
    '00000000-0000-4000-fd00-000000000021',
    '00000000-0000-4000-fd00-000000000020',
    'SY-SGB3-TEST',
    'CAJA SUBLIMABLE DULCE PAQUETE X 10 UNIDADES',
    'Sublimables',
    'VALID'
);

INSERT INTO precio_proveedor_snapshot (
    id_snapshot, id_producto_proveedor, precio_publicado, moneda,
    precio_texto_original, url_fuente, observado_en, unidad_compra, cantidad_pack
)
VALUES (
    '00000000-0000-4000-fd00-000000000022',
    '00000000-0000-4000-fd00-000000000021',
    18000, 'COP', '$18.000 paquete x10',
    'https://proveedor.example/caja-sublimable-dulce',
    '2026-08-01 00:00:00+00', 'PACK', 10
);

-- Producto individual: 9.500 por unidad.
INSERT INTO producto_proveedor (
    id_producto_proveedor, id_proveedor, sku_proveedor, nombre_original, categoria, estado_calidad
)
VALUES (
    '00000000-0000-4000-fd00-000000000023',
    '00000000-0000-4000-fd00-000000000020',
    'MUG-UNIT-TEST',
    'Mug blanco 11 oz unidad',
    'Mugs',
    'VALID'
);

INSERT INTO precio_proveedor_snapshot (
    id_snapshot, id_producto_proveedor, precio_publicado, moneda,
    precio_texto_original, url_fuente, observado_en, unidad_compra, cantidad_pack
)
VALUES (
    '00000000-0000-4000-fd00-000000000024',
    '00000000-0000-4000-fd00-000000000023',
    9500, 'COP', '$9.500 unidad',
    'https://proveedor.example/mug-unidad',
    '2026-08-01 00:00:00+00', 'UNIT', NULL
);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

-- ── CASO 1 y CASO 2: multipack, la cantidad son paquetes ──────────────
DO $$
DECLARE
    r RECORD;
    v_item RECORD;
    v_prod RECORD;
BEGIN
    SELECT * INTO r
      FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object(
                'id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022',
                'cantidad', 1
            )
        ),
        p_idempotency_key => 'multilinea-pack-1'
      );

    ASSERT r.status = 'OK', format('CASO 1 debe ser OK, obtuve %s', r.status);
    ASSERT r.lineas = 1, format('CASO 1 debe reportar 1 linea, obtuve %s', r.lineas);

    SELECT * INTO v_item FROM cotizacion_item WHERE id_cotizacion = r.id_cotizacion;
    ASSERT v_item.cantidad = 10,
        format('CASO 1: 1 paquete x10 debe dar 10 unidades totales, obtuve %s', v_item.cantidad);
    ASSERT (v_item.metadata_costeo->>'cantidad_presentaciones')::numeric = 1,
        format('CASO 1: debe registrar 1 presentacion, obtuve %s', v_item.metadata_costeo->>'cantidad_presentaciones');
    ASSERT v_item.unidad_compra_snapshot = 'PACK', 'CASO 1: debe congelar unidad PACK';
    ASSERT v_item.cantidad_pack_snapshot = 10, 'CASO 1: debe congelar cantidad_pack 10';
    ASSERT v_item.costo_compra_unitario_snapshot = 1800,
        format('CASO 1: costo unitario congelado debe ser 1800, obtuve %s', v_item.costo_compra_unitario_snapshot);
    ASSERT v_item.cantidad_sobrante = 0, 'CASO 1: comprar paquetes enteros no deja sobrante';

    SELECT * INTO v_prod
      FROM cotizacion_componente
     WHERE id_cotizacion_item = v_item.id_cotizacion_item AND tipo_componente = 'PRODUCTO';
    ASSERT v_prod.costo_total = 18000,
        format('CASO 1: costo base de linea debe ser 18000, obtuve %s', v_prod.costo_total);
    ASSERT v_prod.precio_resultante = 25800,
        format('CASO 1: precio con margen 30%% y UP_100 debe ser 25800, obtuve %s', v_prod.precio_resultante);

    RAISE NOTICE 'PASSED - CASO 1 multipack cantidad=1 -> 10 unidades, costo base 18000';

    SELECT * INTO r
      FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object(
                'id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022',
                'cantidad', 3
            )
        ),
        p_idempotency_key => 'multilinea-pack-3'
      );

    ASSERT r.status = 'OK', format('CASO 2 debe ser OK, obtuve %s', r.status);

    SELECT * INTO v_item FROM cotizacion_item WHERE id_cotizacion = r.id_cotizacion;
    ASSERT v_item.cantidad = 30,
        format('CASO 2: 3 paquetes x10 deben dar 30 unidades, obtuve %s', v_item.cantidad);

    SELECT * INTO v_prod
      FROM cotizacion_componente
     WHERE id_cotizacion_item = v_item.id_cotizacion_item AND tipo_componente = 'PRODUCTO';
    ASSERT v_prod.costo_total = 54000,
        format('CASO 2: costo base debe ser 54000 (no 5400), obtuve %s', v_prod.costo_total);
    ASSERT v_prod.costo_total <> 5400, 'CASO 2: 5400 seria dividir en vez de multiplicar';

    RAISE NOTICE 'PASSED - CASO 2 multipack cantidad=3 -> 30 unidades, costo base 54000';
END;
$$;

-- ── CASO 3: producto individual sin cambios de semantica ──────────────
DO $$
DECLARE
    r RECORD;
    v_item RECORD;
    v_prod RECORD;
BEGIN
    SELECT * INTO r
      FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object(
                'id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000024',
                'cantidad', 7
            )
        ),
        p_idempotency_key => 'multilinea-unit-7'
      );

    ASSERT r.status = 'OK', format('CASO 3 debe ser OK, obtuve %s', r.status);

    SELECT * INTO v_item FROM cotizacion_item WHERE id_cotizacion = r.id_cotizacion;
    ASSERT v_item.cantidad = 7,
        format('CASO 3: en UNIT la cantidad son unidades sueltas, obtuve %s', v_item.cantidad);
    ASSERT (v_item.metadata_costeo->>'cantidad_presentaciones')::numeric = 7,
        'CASO 3: en UNIT presentaciones y unidades coinciden';
    ASSERT v_item.costo_compra_unitario_snapshot = 9500,
        format('CASO 3: costo unitario debe ser el precio publicado, obtuve %s', v_item.costo_compra_unitario_snapshot);

    SELECT * INTO v_prod
      FROM cotizacion_componente
     WHERE id_cotizacion_item = v_item.id_cotizacion_item AND tipo_componente = 'PRODUCTO';
    ASSERT v_prod.costo_total = 66500,
        format('CASO 3: 7 x 9500 = 66500, obtuve %s', v_prod.costo_total);

    RAISE NOTICE 'PASSED - CASO 3 producto individual conserva la semantica de unidades';
END;
$$;

-- ── CASO 4: persistencia real de 2 lineas (pack + individual) ─────────
DO $$
DECLARE
    r RECORD;
    v_count INTEGER;
    v_pack RECORD;
    v_unit RECORD;
    v_suma NUMERIC;
    v_it RECORD;
BEGIN
    SELECT * INTO r
      FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object(
                'id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022',
                'id_producto_proveedor', '00000000-0000-4000-fd00-000000000021',
                'cantidad', 3
            ),
            jsonb_build_object(
                'id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000024',
                'cantidad', 12,
                'costos_adicionales', jsonb_build_array(
                    jsonb_build_object('descripcion', 'Sublimacion mug', 'costo_unitario', 1500)
                )
            )
        ),
        p_transporte_total => 20000,
        p_notas => 'Atencion a: Compras. Prueba multilinea.',
        p_idempotency_key => 'multilinea-2-lineas'
      );

    ASSERT r.status = 'OK', format('CASO 4 debe ser OK, obtuve %s', r.status);
    ASSERT r.lineas = 2, format('CASO 4 debe reportar 2 lineas, obtuve %s', r.lineas);

    SELECT COUNT(*) INTO v_count FROM cotizacion_item WHERE id_cotizacion = r.id_cotizacion;
    ASSERT v_count = 2, format('CASO 4: deben persistir 2 cotizacion_item, obtuve %s', v_count);

    SELECT * INTO v_pack
      FROM cotizacion_item
     WHERE id_cotizacion = r.id_cotizacion
       AND id_precio_proveedor_snapshot = '00000000-0000-4000-fd00-000000000022';
    SELECT * INTO v_unit
      FROM cotizacion_item
     WHERE id_cotizacion = r.id_cotizacion
       AND id_precio_proveedor_snapshot = '00000000-0000-4000-fd00-000000000024';

    ASSERT v_pack.source_mode = 'SUPPLIER_PRODUCT' AND v_unit.source_mode = 'SUPPLIER_PRODUCT',
        'CASO 4: ambas lineas deben quedar como SUPPLIER_PRODUCT';
    ASSERT v_pack.id_producto IS NULL AND v_unit.id_producto IS NULL,
        'CASO 4: no debe exigir producto propio';
    ASSERT v_pack.cantidad = 30, format('CASO 4: linea pack debe tener 30 unidades, obtuve %s', v_pack.cantidad);
    ASSERT v_unit.cantidad = 12, format('CASO 4: linea unit debe tener 12 unidades, obtuve %s', v_unit.cantidad);
    ASSERT v_pack.nombre_item_snapshot = 'CAJA SUBLIMABLE DULCE PAQUETE X 10 UNIDADES',
        'CASO 4: debe congelar el nombre del item';
    ASSERT v_pack.proveedor_snapshot->>'nombre' = 'Proveedor Test Multilinea',
        'CASO 4: debe congelar el proveedor';
    ASSERT (v_pack.metadata_costeo->>'linea')::int = 1 AND (v_unit.metadata_costeo->>'linea')::int = 2,
        'CASO 4: debe conservar el orden de las lineas';

    -- El transporte del pedido va una sola vez (modo SEPARATE_LINE).
    SELECT COUNT(*) INTO v_count
      FROM cotizacion_componente cc
      JOIN cotizacion_item ci ON ci.id_cotizacion_item = cc.id_cotizacion_item
     WHERE ci.id_cotizacion = r.id_cotizacion AND cc.tipo_componente = 'TRANSPORTE';
    ASSERT v_count = 1, format('CASO 4: el transporte del pedido no debe duplicarse por linea, obtuve %s', v_count);

    -- El costo adicional de la linea 2 se persiste como componente OTRO.
    SELECT COUNT(*) INTO v_count
      FROM cotizacion_componente cc
     WHERE cc.id_cotizacion_item = v_unit.id_cotizacion_item AND cc.tipo_componente = 'OTRO';
    ASSERT v_count = 1, format('CASO 4: debe persistir el costo adicional de linea, obtuve %s', v_count);

    SELECT SUM(cc.precio_resultante) INTO v_suma
      FROM cotizacion_componente cc
      JOIN cotizacion_item ci ON ci.id_cotizacion_item = cc.id_cotizacion_item
     WHERE ci.id_cotizacion = r.id_cotizacion;
    ASSERT v_suma = r.total,
        format('CASO 4: el total debe ser la suma de componentes (%s vs %s)', v_suma, r.total);
    ASSERT (v_pack.subtotal + v_unit.subtotal) = r.total,
        format('CASO 4: la suma de subtotales de linea debe ser el total (%s vs %s)',
               v_pack.subtotal + v_unit.subtotal, r.total);

    -- Lectura por linea para el detalle y el PDF.
    SELECT COUNT(*) INTO v_count FROM fn_consola_items_cotizacion(r.id_cotizacion);
    ASSERT v_count = 2, format('CASO 4: items_cotizacion debe devolver 2 filas, obtuve %s', v_count);

    SELECT * INTO v_it FROM fn_consola_items_cotizacion(r.id_cotizacion) WHERE linea = 1;
    ASSERT v_it.unidad_compra = 'PACK', 'CASO 4: linea 1 debe reportarse como PACK';
    ASSERT v_it.cantidad_pack = 10, 'CASO 4: linea 1 debe reportar contenido 10';
    ASSERT v_it.cantidad_presentaciones = 3, 'CASO 4: linea 1 debe reportar 3 presentaciones';
    ASSERT v_it.unidades_totales = 30, 'CASO 4: linea 1 debe reportar 30 unidades totales';
    ASSERT v_it.total_linea = v_pack.subtotal, 'CASO 4: total_linea debe coincidir con el subtotal del item';
    ASSERT v_it.costo_compra_unitario = 1800, 'CASO 4: ADMIN si ve el costo de compra';

    RAISE NOTICE 'PASSED - CASO 4 persistencia real de 2 lineas con snapshots congelados';
END;
$$;

-- ── Idempotencia sobre el arreglo completo de lineas ──────────────────
DO $$
DECLARE
    r1 RECORD;
    r2 RECORD;
    v_lineas JSONB := jsonb_build_array(
        jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 2),
        jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000024', 'cantidad', 5)
    );
BEGIN
    SELECT * INTO r1 FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => v_lineas,
        p_idempotency_key => 'multilinea-idem-001'
    );
    SELECT * INTO r2 FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => v_lineas,
        p_idempotency_key => 'multilinea-idem-001'
    );

    ASSERT r1.status = 'OK' AND r2.status = 'OK', 'reintento identico debe devolver OK';
    ASSERT r1.id_cotizacion = r2.id_cotizacion, 'reintento identico debe devolver la misma cotizacion';

    -- Cambiar una cantidad de UNA linea ya es otro payload.
    SELECT * INTO r2 FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 2),
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000024', 'cantidad', 6)
        ),
        p_idempotency_key => 'multilinea-idem-001'
    );
    ASSERT r2.status = 'CONFLICT', format('payload distinto con misma key debe ser CONFLICT, obtuve %s', r2.status);

    -- Agregar una linea tambien es otro payload.
    SELECT * INTO r2 FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => v_lineas || jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000024', 'cantidad', 1)
        ),
        p_idempotency_key => 'multilinea-idem-001'
    );
    ASSERT r2.status = 'CONFLICT', format('linea extra con misma key debe ser CONFLICT, obtuve %s', r2.status);

    RAISE NOTICE 'PASSED - idempotencia compara el arreglo completo de lineas';
END;
$$;

-- ── Validaciones de entrada: nada se escribe a medias ─────────────────
DO $$
DECLARE
    r RECORD;
    v_antes INTEGER;
    v_despues INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_antes FROM cotizacion;

    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => '[]'::jsonb
    );
    ASSERT r.status = 'NO_LINES', format('arreglo vacio debe ser NO_LINES, obtuve %s', r.status);

    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => '{"no":"es-arreglo"}'::jsonb
    );
    ASSERT r.status = 'INVALID_LINES', format('objeto en vez de arreglo debe ser INVALID_LINES, obtuve %s', r.status);

    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 0)
        )
    );
    ASSERT r.status = 'INVALID_QUANTITY', format('cantidad 0 debe ser INVALID_QUANTITY, obtuve %s', r.status);

    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 1.5)
        )
    );
    ASSERT r.status = 'INVALID_QUANTITY', format('media presentacion debe ser INVALID_QUANTITY, obtuve %s', r.status);

    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 1),
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-0000000000ff', 'cantidad', 1)
        )
    );
    ASSERT r.status = 'SUPPLIER_PRICE_NOT_FOUND',
        format('snapshot inexistente en la segunda linea debe abortar, obtuve %s', r.status);

    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-0000000000fe',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 1)
        )
    );
    ASSERT r.status = 'ORGANIZATION_NOT_FOUND',
        format('organizacion inexistente debe ser ORGANIZATION_NOT_FOUND, obtuve %s', r.status);

    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object(
                'id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022',
                'id_producto_proveedor', '00000000-0000-4000-fd00-000000000023',
                'cantidad', 1
            )
        )
    );
    ASSERT r.status = 'LINE_PRODUCT_MISMATCH',
        format('producto que no corresponde al snapshot debe ser LINE_PRODUCT_MISMATCH, obtuve %s', r.status);

    SELECT COUNT(*) INTO v_despues FROM cotizacion;
    ASSERT v_antes = v_despues,
        format('ninguna validacion fallida debe dejar cotizaciones a medias (%s -> %s)', v_antes, v_despues);

    RAISE NOTICE 'PASSED - validaciones rechazan sin escribir nada';
END;
$$;

-- ── Transporte distribuido: se prorratea y la suma es exacta ──────────
DO $$
DECLARE
    r RECORD;
    v_suma NUMERIC;
    v_count INTEGER;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 1),
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000024', 'cantidad', 10)
        ),
        p_transporte_total => 30000,
        p_transport_mode => 'DISTRIBUTED',
        p_idempotency_key => 'multilinea-transporte-distribuido'
    );

    ASSERT r.status = 'OK', format('transporte distribuido debe ser OK, obtuve %s', r.status);

    SELECT COUNT(*), SUM(cc.costo_total) INTO v_count, v_suma
      FROM cotizacion_componente cc
      JOIN cotizacion_item ci ON ci.id_cotizacion_item = cc.id_cotizacion_item
     WHERE ci.id_cotizacion = r.id_cotizacion AND cc.tipo_componente = 'TRANSPORTE';

    ASSERT v_count = 2, format('distribuido debe dejar un componente por linea, obtuve %s', v_count);
    ASSERT v_suma = 30000, format('el prorrateo debe sumar exactamente 30000, obtuve %s', v_suma);

    RAISE NOTICE 'PASSED - transporte distribuido se prorratea sin perder ni inventar pesos';
END;
$$;

RESET ROLE;

-- ── Enmascaramiento por rol ───────────────────────────────────────────
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    r RECORD;
    v_it RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 1)
        ),
        p_margen_override_pct => 40,
        p_idempotency_key => 'multilinea-comercial-margen'
    );
    ASSERT r.status = 'MARGIN_OVERRIDE_FORBIDDEN',
        format('COMERCIAL no debe inyectar margen manual, obtuve %s', r.status);

    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 2)
        ),
        p_idempotency_key => 'multilinea-comercial-ok'
    );
    ASSERT r.status = 'OK', format('COMERCIAL si debe poder emitir con la politica vigente, obtuve %s', r.status);

    SELECT * INTO v_it FROM fn_consola_items_cotizacion(r.id_cotizacion) WHERE linea = 1;
    ASSERT v_it.status = 'OK', 'COMERCIAL debe poder leer las lineas';
    ASSERT v_it.total_linea IS NOT NULL, 'COMERCIAL si ve el precio de venta de la linea';
    ASSERT v_it.precio_unitario_venta IS NOT NULL, 'COMERCIAL si ve el precio unitario de venta';
    ASSERT v_it.costo_compra_unitario IS NULL, 'COMERCIAL no debe ver el costo de compra';
    ASSERT v_it.sku_proveedor IS NULL, 'COMERCIAL no debe ver el SKU del proveedor';
    ASSERT v_it.proveedor IS NULL, 'COMERCIAL no debe ver el nombre del proveedor';
    ASSERT v_it.unidades_totales = 20, format('COMERCIAL: 2 paquetes x10 son 20 unidades, obtuve %s', v_it.unidades_totales);

    RAISE NOTICE 'PASSED - items_cotizacion enmascara costo, SKU y proveedor para COMERCIAL';
END;
$$;

RESET ROLE;

-- ── No romper lo existente: el flujo de un solo producto sigue igual ──
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    r RECORD;
    v_item RECORD;
    v_it RECORD;
BEGIN
    SELECT * INTO r
      FROM fn_consola_crear_cotizacion_proveedor(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_id_precio_proveedor_snapshot => '00000000-0000-4000-fd00-000000000024',
        p_cantidad => 12,
        p_idempotency_key => 'multilinea-no-regresion-single'
      );

    ASSERT r.status = 'OK', format('el flujo de un producto debe seguir OK, obtuve %s', r.status);

    SELECT * INTO v_item FROM cotizacion_item WHERE id_cotizacion = r.id_cotizacion;
    ASSERT v_item.cantidad = 12, 'el flujo de un producto sigue interpretando la cantidad en unidades';

    -- La lectura por linea tambien sirve para cotizaciones viejas de una linea.
    SELECT * INTO v_it FROM fn_consola_items_cotizacion(r.id_cotizacion) WHERE linea = 1;
    ASSERT v_it.unidades_totales = 12, 'items_cotizacion debe leer cotizaciones de una sola linea';
    ASSERT v_it.cantidad_presentaciones = 12, 'sin metadata de presentaciones cae a unidades (UNIT)';

    RAISE NOTICE 'PASSED - fn_consola_crear_cotizacion_proveedor (un producto) no cambio';
END;
$$;

RESET ROLE;

-- ── Sin perfil de consola no se puede ni crear ni leer ────────────────
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-0000000000aa"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    r RECORD;
    v_it RECORD;
BEGIN
    SELECT * INTO r FROM fn_consola_crear_cotizacion_proveedor_multilinea(
        p_id_organizacion => '00000000-0000-4000-fd00-000000000010',
        p_lineas => jsonb_build_array(
            jsonb_build_object('id_precio_proveedor_snapshot', '00000000-0000-4000-fd00-000000000022', 'cantidad', 1)
        )
    );
    ASSERT r.status = 'FORBIDDEN', format('sin perfil debe ser FORBIDDEN, obtuve %s', r.status);

    SELECT * INTO v_it FROM fn_consola_items_cotizacion('00000000-0000-4000-fd00-000000000010');
    ASSERT v_it.status = 'FORBIDDEN', format('sin perfil no debe leer lineas, obtuve %s', v_it.status);

    RAISE NOTICE 'PASSED - sin perfil de consola queda FORBIDDEN en creacion y lectura';
END;
$$;

RESET ROLE;


RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000001"}', true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE carga jsonb; previo jsonb; emitida record; n int; m numeric; anterior numeric := NULL; precio numeric; before_count int;
BEGIN
  SELECT count(*) INTO before_count FROM cotizacion;
  FOREACH n IN ARRAY ARRAY[1,12,30,50] LOOP
    m := CASE WHEN n >= 50 THEN 25 WHEN n >= 30 THEN 30 WHEN n >= 12 THEN 35 ELSE 40 END;
    carga := jsonb_build_array(jsonb_build_object(
      'id_precio_proveedor_snapshot','00000000-0000-4000-fd00-000000000024',
      'id_producto_proveedor','00000000-0000-4000-fd00-000000000023',
      'cantidad',n,'costo_unitario_override',1000,'margen_linea_pct',m,'retencion_pct',0,
      'costos_adicionales',jsonb_build_array(jsonb_build_object('descripcion','Preparacion fija','costo_total',6000))));
    previo := fn_consola_previsualizar_cotizacion_multilinea('00000000-0000-4000-fd00-000000000010',carga,40);
    ASSERT previo->>'status'='OK', format('preview: %s',previo);
    precio := (previo->>'total')::numeric / n;
    ASSERT anterior IS NULL OR precio < anterior, 'El precio unitario debe bajar con costos fijos repartidos y menor margen';
    anterior := precio;
    ASSERT (previo->'lineas'->0->>'costo_total')::numeric = 1000*n+6000, 'El fijo no debe multiplicarse por cantidad';
    ASSERT (previo->>'total')::numeric >= (1000*n+6000)/(1-m/100), 'El precio debe cubrir el margen seleccionado';
    SELECT * INTO emitida FROM fn_consola_emitir_cotizacion_verificada('00000000-0000-4000-fd00-000000000010',carga,1,40,NULL,'volume-wrong-'||n);
    ASSERT emitida.status='PREVIEW_CHANGED', 'Un total anterior incorrecto debe impedir la emision';
    SELECT * INTO emitida FROM fn_consola_emitir_cotizacion_verificada('00000000-0000-4000-fd00-000000000010',carga,(previo->>'total')::numeric,40,NULL,'volume-'||n);
    ASSERT emitida.status='OK' AND emitida.total=(previo->>'total')::numeric, format('Preview y emision deben coincidir: %s',emitida);
  END LOOP;
  ASSERT (SELECT count(*) FROM cotizacion)=before_count+4, 'Preview y emision rechazada no deben crear filas';
  -- Cambiar el costo base debe modificar el importe real, no solo la pantalla.
  carga := jsonb_set(carga,'{0,costo_unitario_override}','2000');
  previo := fn_consola_previsualizar_cotizacion_multilinea('00000000-0000-4000-fd00-000000000010',carga,40);
  ASSERT (previo->>'total')::numeric > emitida.total, 'El costo pactado debe llegar al motor';
  carga := jsonb_set(carga,'{0,retencion_pct}','10');
  previo := fn_consola_previsualizar_cotizacion_multilinea('00000000-0000-4000-fd00-000000000010',carga,40);
  ASSERT (previo->>'total')::numeric * .9 >= (2000*50+6000)/.75, 'La retencion efectiva debe respetar el margen sobre recibido';
  carga := jsonb_set(carga,'{0,margen_linea_pct}','100');
  previo := fn_consola_previsualizar_cotizacion_multilinea('00000000-0000-4000-fd00-000000000010',carga,40);
  ASSERT previo->>'status'='INVALID_PRICING_INPUT', 'Margen 100 no es valido';
END;
$$;
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fd00-000000000002"}', true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE p jsonb;
BEGIN
  p := fn_consola_previsualizar_cotizacion_multilinea('00000000-0000-4000-fd00-000000000010',
    '[{"id_precio_proveedor_snapshot":"00000000-0000-4000-fd00-000000000024","cantidad":12,"margen_linea_pct":10}]',NULL);
  ASSERT p->>'status'='PRICING_OVERRIDE_FORBIDDEN', 'COMERCIAL no puede forzar escalas desde RPC';
  ASSERT (SELECT count(*) FROM cotizacion_item)=0, 'COMERCIAL no puede leer snapshots de costo directamente';
  ASSERT (SELECT count(*) FROM cotizacion_evento)=0, 'COMERCIAL no puede leer metadata sensible de eventos';
END;
$$;

ROLLBACK;
