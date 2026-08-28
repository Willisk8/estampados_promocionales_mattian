-- database/tests/test_quote_supplier_first.sql
BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fe00-000000000001', 'admin-supplier-first@prueba.local'),
    ('00000000-0000-4000-fe00-000000000002', 'comercial-supplier-first@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fe00-000000000001', 'admin-supplier-first@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fe00-000000000002', 'comercial-supplier-first@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio)
VALUES ('00000000-0000-4000-fe00-000000000010', '901888777', 'ORG SUPPLIER FIRST TEST', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.');

INSERT INTO proveedor (id_proveedor, source_id, nombre, ciudad)
VALUES ('00000000-0000-4000-fe00-000000000020', 'test_supplier_first', 'Proveedor Test Supplier First', 'Bogota');

INSERT INTO producto_proveedor (
    id_producto_proveedor, id_proveedor, sku_proveedor, nombre_original,
    categoria, estado_calidad
)
VALUES (
    '00000000-0000-4000-fe00-000000000021',
    '00000000-0000-4000-fe00-000000000020',
    'MUG-CAJA-36',
    'Mug blanco 11 oz caja x36',
    'Mugs',
    'VALID'
);

INSERT INTO precio_proveedor_snapshot (
    id_snapshot, id_producto_proveedor, precio_publicado, moneda,
    precio_texto_original, url_fuente, observado_en, unidad_compra,
    cantidad_pack, minimo_compra, incremento_compra, precio_vigencia,
    notas_costeo
)
VALUES (
    '00000000-0000-4000-fe00-000000000022',
    '00000000-0000-4000-fe00-000000000021',
    180000,
    'COP',
    '$180.000 caja x36',
    'https://proveedor.example/mug-caja-36',
    '2026-08-01 00:00:00+00',
    'PACK',
    36,
    1,
    1,
    '[2026-08-01 00:00:00+00, 2027-01-01 00:00:00+00)'::tstzrange,
    'Fixture: caja x36 para probar costo unitario proveedor-first'
);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    r RECORD;
    c RECORD;
    v_item RECORD;
    v_count INTEGER;
    v_selector RECORD;
BEGIN
    SELECT * INTO v_selector
      FROM fn_consola_buscar_proveedores_producto('supplier first', 10)
     WHERE id_proveedor = '00000000-0000-4000-fe00-000000000020';
    ASSERT v_selector.id_proveedor IS NOT NULL, 'selector debe encontrar proveedor por texto';

    SELECT * INTO v_selector
      FROM fn_consola_buscar_productos_proveedor(
        '00000000-0000-4000-fe00-000000000020',
        'mug',
        10
      )
     WHERE id_producto_proveedor = '00000000-0000-4000-fe00-000000000021';
    ASSERT v_selector.id_producto_proveedor IS NOT NULL, 'selector debe encontrar producto del proveedor';

    SELECT * INTO v_selector
      FROM fn_consola_ofertas_producto_proveedor(
        '00000000-0000-4000-fe00-000000000021',
        12
      )
     WHERE id_snapshot = '00000000-0000-4000-fe00-000000000022';
    ASSERT v_selector.costo_unitario_estimado = 5000, format('selector de ofertas debe calcular 5000/und, obtuve %s', v_selector.costo_unitario_estimado);
    ASSERT v_selector.cantidad_sobrante = 24, format('selector de ofertas debe mostrar 24 sobrantes, obtuve %s', v_selector.cantidad_sobrante);

    SELECT * INTO c
      FROM fn_consola_previsualizar_cotizacion_proveedor(
        p_id_precio_proveedor_snapshot => '00000000-0000-4000-fe00-000000000022',
        p_cantidad => 12,
        p_marking_lines => '[]'::jsonb,
        p_transporte_total => 0
      )
     WHERE tipo_componente = 'PRODUCTO';

    ASSERT c.status = 'OK', format('preview proveedor-first debe ser OK, obtuve %s', c.status);
    ASSERT c.costo_unitario = 5000, format('caja 180000/36 debe dar 5000, obtuve %s', c.costo_unitario);
    ASSERT c.costo_total = 60000, format('12 mugs deben costar 60000 consumidos, obtuve %s', c.costo_total);
    ASSERT c.source_type = 'PRECIO_PROVEEDOR_SNAPSHOT', format('source_type incorrecto: %s', c.source_type);

    SELECT * INTO r
      FROM fn_consola_crear_cotizacion_proveedor(
        p_id_organizacion => '00000000-0000-4000-fe00-000000000010',
        p_id_precio_proveedor_snapshot => '00000000-0000-4000-fe00-000000000022',
        p_cantidad => 12,
        p_marking_lines => '[]'::jsonb,
        p_transporte_total => 0,
        p_idempotency_key => 'supplier-first-key-001'
      );

    ASSERT r.status = 'OK', format('crear proveedor-first debe ser OK, obtuve %s', r.status);
    ASSERT r.id_cotizacion IS NOT NULL, 'debe devolver id_cotizacion';

    SELECT * INTO v_item
      FROM cotizacion_item
     WHERE id_cotizacion = r.id_cotizacion;

    ASSERT v_item.source_mode = 'SUPPLIER_PRODUCT', format('source_mode esperado SUPPLIER_PRODUCT, obtuve %s', v_item.source_mode);
    ASSERT v_item.id_producto IS NULL, 'cotizacion proveedor-first no debe requerir producto propio';
    ASSERT v_item.id_producto_proveedor = '00000000-0000-4000-fe00-000000000021', 'debe congelar producto_proveedor';
    ASSERT v_item.id_precio_proveedor_snapshot = '00000000-0000-4000-fe00-000000000022', 'debe congelar precio_proveedor_snapshot';
    ASSERT v_item.costo_compra_unitario_snapshot = 5000, format('costo unitario congelado incorrecto: %s', v_item.costo_compra_unitario_snapshot);
    ASSERT v_item.cantidad_comprada = 36, format('debe registrar compra sugerida de caja completa, obtuve %s', v_item.cantidad_comprada);
    ASSERT v_item.cantidad_sobrante = 24, format('debe registrar 24 sobrantes, obtuve %s', v_item.cantidad_sobrante);

    SELECT COUNT(*) INTO v_count
      FROM cotizacion_componente cc
     WHERE cc.id_cotizacion_item = v_item.id_cotizacion_item
       AND cc.source_type = 'PRECIO_PROVEEDOR_SNAPSHOT';
    ASSERT v_count = 1, format('debe persistir un componente trazado a snapshot proveedor, obtuve %s', v_count);

    RAISE NOTICE 'PASSED - cotizacion proveedor-first desde caja x36 sin producto propio';
END;
$$;

DO $$
DECLARE
    r1 RECORD;
    r2 RECORD;
BEGIN
    SELECT * INTO r1
      FROM fn_consola_crear_cotizacion_proveedor(
        p_id_organizacion => '00000000-0000-4000-fe00-000000000010',
        p_id_precio_proveedor_snapshot => '00000000-0000-4000-fe00-000000000022',
        p_cantidad => 12,
        p_idempotency_key => 'supplier-first-key-002'
      );
    SELECT * INTO r2
      FROM fn_consola_crear_cotizacion_proveedor(
        p_id_organizacion => '00000000-0000-4000-fe00-000000000010',
        p_id_precio_proveedor_snapshot => '00000000-0000-4000-fe00-000000000022',
        p_cantidad => 12,
        p_idempotency_key => 'supplier-first-key-002'
      );

    ASSERT r1.status = 'OK' AND r2.status = 'OK', 'retry identico debe devolver OK';
    ASSERT r1.id_cotizacion = r2.id_cotizacion, 'retry identico debe devolver la misma cotizacion';

    SELECT * INTO r2
      FROM fn_consola_crear_cotizacion_proveedor(
        p_id_organizacion => '00000000-0000-4000-fe00-000000000010',
        p_id_precio_proveedor_snapshot => '00000000-0000-4000-fe00-000000000022',
        p_cantidad => 13,
        p_idempotency_key => 'supplier-first-key-002'
      );

    ASSERT r2.status = 'CONFLICT', format('misma key con payload distinto debe ser CONFLICT, obtuve %s', r2.status);

    RAISE NOTICE 'PASSED - idempotencia proveedor-first';
END;
$$;

RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    c RECORD;
BEGIN
    SELECT * INTO c
      FROM fn_consola_previsualizar_cotizacion_proveedor(
        p_id_precio_proveedor_snapshot => '00000000-0000-4000-fe00-000000000022',
        p_cantidad => 12
      )
     WHERE tipo_componente = 'PRODUCTO';

    ASSERT c.status = 'OK', format('COMERCIAL debe previsualizar OK, obtuvo %s', c.status);
    ASSERT c.costo_unitario IS NULL, 'COMERCIAL no debe ver costo unitario';
    ASSERT c.costo_total IS NULL, 'COMERCIAL no debe ver costo total';
    ASSERT c.margen_aplicado_pct IS NULL, 'COMERCIAL no debe ver margen';
    ASSERT c.precio_resultante IS NOT NULL, 'COMERCIAL si ve precio resultante';

    RAISE NOTICE 'PASSED - preview proveedor-first enmascara costos para COMERCIAL';
END;
$$;

RESET ROLE;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000001"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    p RECORD;
    t RECORD;
    found RECORD;
BEGIN
    SELECT * INTO p
      FROM fn_consola_crear_producto_proveedor_manual(
        p_nombre_proveedor => 'Proveedor Manual Cotizador',
        p_nombre_producto => 'Tula eco manual',
        p_sku_proveedor => 'TULA-MANUAL',
        p_categoria => 'Tulas',
        p_precio => 72000,
        p_unidad_compra => 'PACK',
        p_cantidad_pack => 12,
        p_notas => 'Precio digitado en cotizador para prueba'
      );

    ASSERT p.status = 'OK', format('alta manual producto debe ser OK, obtuvo %s', p.status);
    PERFORM set_config('app.manual_producto_proveedor', p.id_producto_proveedor::text, false);
    PERFORM set_config('app.manual_precio_proveedor', p.id_precio_proveedor_snapshot::text, false);

    SELECT * INTO t
      FROM fn_consola_crear_snapshot_tecnica_manual(
        p_nombre_proveedor_tecnica => 'Proveedor Tecnica Manual',
        p_codigo_tecnica => 'DTF Textil Manual',
        p_precio => 26000,
        p_billing_unit => 'metro',
        p_width_cm => 58,
        p_quantity_min => 1,
        p_size_label => '58x100 cm',
        p_notas => 'Precio manual de prueba'
      );

    ASSERT t.status = 'OK', format('alta manual tecnica debe ser OK, obtuvo %s', t.status);
    PERFORM set_config('app.manual_tecnica_snapshot', t.id_snapshot::text, false);

    SELECT * INTO found
      FROM fn_consola_buscar_snapshots_tecnica_marcacion('manual', 10, 'COP', 20)
     WHERE id_snapshot = t.id_snapshot;
    ASSERT found.id_snapshot IS NOT NULL, 'selector debe poder devolver snapshot manual pendiente para uso explicito';

    RAISE NOTICE 'PASSED - altas manuales proveedor/producto/precio y tecnica/snapshot quedan en revision';
END;
$$;

RESET ROLE;

DO $$
DECLARE
    found RECORD;
BEGIN
    SELECT pp.estado_calidad, pps.unidad_compra, pps.cantidad_pack, pps.precio_publicado
      INTO found
      FROM producto_proveedor pp
      JOIN precio_proveedor_snapshot pps ON pps.id_producto_proveedor = pp.id_producto_proveedor
     WHERE pp.id_producto_proveedor = current_setting('app.manual_producto_proveedor')::uuid;

    ASSERT found.estado_calidad = 'PENDING_REVIEW', 'producto manual debe quedar PENDING_REVIEW';
    ASSERT found.unidad_compra = 'PACK', 'precio manual debe conservar unidad PACK';
    ASSERT found.cantidad_pack = 12, 'precio manual debe conservar cantidad_pack';
    ASSERT found.precio_publicado = 72000, 'precio manual debe conservar precio';

    SELECT pts.verification_status, c.usage_status, pts.price_value, pts.billing_unit
      INTO found
      FROM precio_tecnica_marcacion_snapshot pts
      JOIN curacion_precio_tecnica_marcacion c ON c.id_snapshot = pts.id_snapshot
     WHERE pts.id_snapshot = current_setting('app.manual_tecnica_snapshot')::uuid;

    ASSERT found.verification_status = 'PENDING_REVIEW', 'snapshot tecnica manual debe quedar PENDING_REVIEW';
    ASSERT found.usage_status = 'NEEDS_REVIEW', 'curacion manual debe quedar NEEDS_REVIEW';
    ASSERT found.price_value = 26000, 'snapshot tecnica manual debe conservar precio';
    ASSERT found.billing_unit = 'metro', 'snapshot tecnica manual debe conservar billing_unit';

    RAISE NOTICE 'PASSED - tablas manuales conservan datos y estado de revision';
END;
$$;

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000002"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    p RECORD;
BEGIN
    SELECT * INTO p
      FROM fn_consola_crear_producto_proveedor_manual(
        p_nombre_proveedor => 'Proveedor Manual Comercial',
        p_nombre_producto => 'Esfero manual comercial',
        p_precio => 1200,
        p_unidad_compra => 'UNIT'
      );

    ASSERT p.status = 'OK', format('COMERCIAL debe poder crear manual pendiente, obtuvo %s', p.status);
    RAISE NOTICE 'PASSED - COMERCIAL puede crear dato manual pendiente';
END;
$$;

RESET ROLE;

INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-4000-fe00-000000000003', 'lectura-supplier-first@prueba.local');
INSERT INTO perfil_usuario (user_id, email, rol, activo)
VALUES ('00000000-0000-4000-fe00-000000000003', 'lectura-supplier-first@prueba.local', 'LECTURA', true);

SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe00-000000000003"}', true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE
    p RECORD;
BEGIN
    SELECT * INTO p
      FROM fn_consola_crear_producto_proveedor_manual(
        p_nombre_proveedor => 'Proveedor Bloqueado',
        p_nombre_producto => 'Producto bloqueado',
        p_precio => 1000
      );

    ASSERT p.status = 'FORBIDDEN', format('LECTURA debe recibir FORBIDDEN, obtuvo %s', p.status);
    RAISE NOTICE 'PASSED - LECTURA no crea datos manuales';
END;
$$;

RESET ROLE;

ROLLBACK;
