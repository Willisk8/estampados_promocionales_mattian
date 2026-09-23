BEGIN;

INSERT INTO auth.users (id, email) VALUES
    ('00000000-0000-4000-fe01-000000000001', 'admin-multilinea-territory@prueba.local'),
    ('00000000-0000-4000-fe01-000000000002', 'comercial-multilinea-territory@prueba.local');

INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
    ('00000000-0000-4000-fe01-000000000001', 'admin-multilinea-territory@prueba.local', 'ADMIN', true),
    ('00000000-0000-4000-fe01-000000000002', 'comercial-multilinea-territory@prueba.local', 'COMERCIAL', true);

INSERT INTO organizacion (id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio)
VALUES ('00000000-0000-4000-fe01-000000000010', '901777665', 'ORG MULTILINEA TEST', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.');

INSERT INTO proveedor (id_proveedor, source_id, nombre, ciudad)
VALUES ('00000000-0000-4000-fe01-000000000020', 'test_territory_units', 'Proveedor Test Multilinea', 'Bogota');

-- Producto empacado: caja x10 a 18.000 (replica de SY-SGB3).
INSERT INTO producto_proveedor (
    id_producto_proveedor, id_proveedor, sku_proveedor, nombre_original, categoria, estado_calidad
)
VALUES (
    '00000000-0000-4000-fe01-000000000021',
    '00000000-0000-4000-fe01-000000000020',
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
    '00000000-0000-4000-fe01-000000000022',
    '00000000-0000-4000-fe01-000000000021',
    18000, 'COP', '$18.000 paquete x10',
    'https://proveedor.example/caja-sublimable-dulce',
    '2026-08-01 00:00:00+00', 'PACK', 10
);

-- Producto individual: 9.500 por unidad.
INSERT INTO producto_proveedor (
    id_producto_proveedor, id_proveedor, sku_proveedor, nombre_original, categoria, estado_calidad
)
VALUES (
    '00000000-0000-4000-fe01-000000000023',
    '00000000-0000-4000-fe01-000000000020',
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
    '00000000-0000-4000-fe01-000000000024',
    '00000000-0000-4000-fe01-000000000023',
    9500, 'COP', '$9.500 unidad',
    'https://proveedor.example/mug-unidad',
    '2026-08-01 00:00:00+00', 'UNIT', NULL
);


INSERT INTO organizacion(nit,nombre_legal,departamento,municipio) VALUES
('901777661','QA SANTANDER','SANTANDER','BUCARAMANGA'),
('901777662','QA NORTE','NORTE DE SANTANDER','SAN JOSE DE CUCUTA'),
('901777663','QA CUNDI','CUNDINAMARCA','SOACHA');
INSERT INTO precio_proveedor_snapshot(id_snapshot,id_producto_proveedor,precio_publicado,moneda,precio_texto_original,url_fuente,observado_en)
VALUES ('00000000-0000-4000-fe01-000000000025','00000000-0000-4000-fe01-000000000023',1000,'COP','1000 sin unidad','https://proveedor.example/unknown',now());
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-fe01-000000000001"}', true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE result JSONB; q INTEGER;
BEGIN
 ASSERT (SELECT count(*) FROM fn_consola_organizaciones(p_busqueda=>'QA',p_departamento=>'Santander'))=1,'Santander no debe incluir Norte de Santander';
 ASSERT (SELECT count(*) FROM fn_consola_organizaciones(p_busqueda=>'QA',p_departamento=>'Cundinamarca',p_municipio=>'SOACHA'))=1,'Filtro combinado';
 ASSERT (SELECT count(*) FROM fn_consola_organizaciones(p_busqueda=>'QA',p_municipio=>'SOACHA'))=1,'Ciudad sin departamento';
 result := fn_consola_previsualizar_cotizacion_multilinea('00000000-0000-4000-fe01-000000000010',
 '[{"id_precio_proveedor_snapshot":"00000000-0000-4000-fe01-000000000025","cantidad":1}]',40);
 ASSERT result->>'status'='PURCHASE_UNIT_UNVERIFIED','Unidad desconocida no se presume UNIT';
 ASSERT (SELECT unidad_compra IS NULL AND costo_unitario_estimado IS NULL FROM fn_consola_ofertas_producto_proveedor('00000000-0000-4000-fe01-000000000023') WHERE id_snapshot='00000000-0000-4000-fe01-000000000025'), 'El selector conserva unidad desconocida';
 FOREACH q IN ARRAY ARRAY[1,100,110,1000,1100,1150,1200] LOOP
  result := fn_consola_previsualizar_cotizacion_multilinea('00000000-0000-4000-fe01-000000000010',
   jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot','00000000-0000-4000-fe01-000000000024','cantidad',q,'margen_linea_pct',20)),40);
  ASSERT result->>'status'='OK', format('Cantidad arbitraria %s: %s',q,result->>'status');
 END LOOP;
 result := fn_consola_previsualizar_cotizacion_multilinea('00000000-0000-4000-fe01-000000000010',
 '[{"id_precio_proveedor_snapshot":"00000000-0000-4000-fe01-000000000022","cantidad":115}]',40);
 ASSERT result->>'status'='OK','Paquete declarado conserva soporte';
END $$;
RESET ROLE;
ROLLBACK;
