-- Contrato cliente v2: cantidades entregadas, compra completa y redondeo al peso.
-- Solo fixtures sinteticos; ejecutar en PostgreSQL de pruebas, nunca datos vivos.
BEGIN;

INSERT INTO auth.users(id,email) VALUES
 ('00000000-0000-4000-fc85-000000000001','admin-client-contract@prueba.local'),
 ('00000000-0000-4000-fc85-000000000002','sales-client-contract@prueba.local'),
 ('00000000-0000-4000-fc85-000000000003','reader-client-contract@prueba.local');
INSERT INTO perfil_usuario(user_id,email,rol,activo) VALUES
 ('00000000-0000-4000-fc85-000000000001','admin-client-contract@prueba.local','ADMIN',true),
 ('00000000-0000-4000-fc85-000000000002','sales-client-contract@prueba.local','COMERCIAL',true),
 ('00000000-0000-4000-fc85-000000000003','reader-client-contract@prueba.local','LECTURA',true);
INSERT INTO proveedor(id_proveedor,source_id,nombre,ciudad)
 VALUES('00000000-0000-4000-fc85-000000000010','client_contract_test','Proveedor contrato cliente','Bogota');
INSERT INTO producto_proveedor(id_producto_proveedor,id_proveedor,sku_proveedor,nombre_original,estado_calidad) VALUES
 ('00000000-0000-4000-fc85-000000000011','00000000-0000-4000-fc85-000000000010','CC-PACK','Articulo paquete diez','VALID'),
 ('00000000-0000-4000-fc85-000000000012','00000000-0000-4000-fc85-000000000010','CC-UNIT','Articulo individual','VALID'),
 ('00000000-0000-4000-fc85-000000000013','00000000-0000-4000-fc85-000000000010','CC-PACK36','Articulo paquete treinta y seis','VALID');
INSERT INTO precio_proveedor_snapshot(id_snapshot,id_producto_proveedor,precio_publicado,moneda,precio_texto_original,url_fuente,observado_en,unidad_compra,cantidad_pack) VALUES
 ('00000000-0000-4000-fc85-000000000021','00000000-0000-4000-fc85-000000000011',18000,'COP','18000 paquete diez','https://example.invalid/pack',now(),'PACK',10),
 ('00000000-0000-4000-fc85-000000000022','00000000-0000-4000-fc85-000000000012',1000,'COP','1000 unidad','https://example.invalid/unit',now(),'UNIT',NULL),
 ('00000000-0000-4000-fc85-000000000023','00000000-0000-4000-fc85-000000000013',36000,'COP','36000 paquete 36','https://example.invalid/pack36',now(),'PACK',36);

SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fc85-000000000001"}',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE
 payload jsonb; preview jsonb; retained jsonb; legacy jsonb; detail jsonb;
 emitted record; repeated record; item record; n integer; expected numeric; before_count bigint;
 plantilla_id uuid;
BEGIN
 -- Un paquete para comprar no significa diez unidades adicionales para el cliente.
 payload := jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000021','unidades_entregar',12));
 SELECT count(*) INTO before_count FROM cotizacion;
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,payload,0);
 ASSERT preview->>'status'='OK',format('PACK preview: %s',preview);
 detail := preview->'lineas'->0;
 ASSERT (detail->>'unidades')::numeric=12,'Entregar exactamente doce';
 ASSERT (detail->>'unidades_comprar')::numeric=20,'Comprar veinte unidades en dos paquetes';
 ASSERT (detail->>'cantidad_presentaciones')::numeric=2,'Comprar dos paquetes';
 ASSERT (detail->>'cantidad_sobrante')::numeric=8,'Ocho unidades sobrantes';
 ASSERT (detail->>'costo_total')::numeric=36000,'Cubrir ambos paquetes completos';
 ASSERT (preview->>'total')::numeric=36000,'ADMIN puede elegir margen cero';
 ASSERT (SELECT count(*) FROM cotizacion)=before_count,'Preview no escribe cotizaciones';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000023','unidades_entregar',37)),0);
 ASSERT preview->>'status'='OK' AND (preview->'lineas'->0->>'unidades_comprar')::numeric=72
  AND (preview->'lineas'->0->>'cantidad_sobrante')::numeric=35,
  '37 solicitadas de caja36 compra 72 y deja 35';
 ASSERT (preview->'lineas'->0->>'costo_total')::numeric=72000,
  'La compra completa entra al costo antes del redondeo';
 ASSERT (preview->>'total')::numeric=72002,
  'El unitario 1946 redondeado al peso produce 72002';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000023','unidades_entregar',37,
  'reasignacion_sobrante',35000,'motivo_ajuste','35 unidades reservadas para pedido siguiente')),0);
 ASSERT preview->>'status'='OK' AND (preview->'lineas'->0->>'costo_total')::numeric=37000,
  'ADMIN puede reasignar solamente costo proporcional del sobrante con motivo';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000023','unidades_entregar',37,
  'reasignacion_sobrante',35001,'motivo_ajuste','Excede sobrante')),0);
 ASSERT preview->>'status'='INVALID_SURPLUS_ALLOCATION',
  'No se puede asignar mas que el costo de 35 unidades sobrantes';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000023','unidades_entregar',37,
  'reasignacion_sobrante',1000)),0);
 ASSERT preview->>'status'='INVALID_SURPLUS_ALLOCATION',
  'La reasignacion exige motivo';

 -- El endpoint historico conserva cantidad=presentaciones y su regla anterior.
 legacy := fn_consola_previsualizar_cotizacion_multilinea(NULL,
  jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000021','cantidad',1)),0);
 ASSERT legacy->>'status'='OK','Contrato legacy disponible';
 ASSERT (legacy->'lineas'->0->>'unidades')::numeric=10,'Legacy sigue entregando diez por paquete';
 ASSERT (legacy->>'total')::numeric=18000,'Legacy conserva costo paquete completo';

 -- Caso independiente: doce x1000 +6000 fijo; 35% margen y ceil al peso unitario.
 payload := jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000022','unidades_entregar',12,
  'costos_adicionales',jsonb_build_array(jsonb_build_object('descripcion','Preparacion fija','costo_total',6000))));
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,payload,35);
 ASSERT preview->>'status'='OK',format('UNIT preview: %s',preview);
 ASSERT (preview->>'total')::numeric=27696,format('18000/.65/12 ->2308 x12=27696: %s',preview);
 ASSERT (preview->'lineas'->0->>'precio_unitario')::numeric=2308,'Redondear una vez al peso unitario';
 plantilla_id := fn_consola_guardar_plantilla_margen('CLIENTE_TEST',40,
  '[{"desde":12,"margen":35},{"desde":30,"margen":30}]'::jsonb);
 PERFORM fn_consola_publicar_plantilla_margen(plantilla_id);
 PERFORM set_config('test.client_template_id',plantilla_id::text,true);
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_set(payload,'{0,id_plantilla_margen}',to_jsonb(plantilla_id::text)));
 ASSERT preview->>'status'='OK' AND (preview->>'total')::numeric=27696,
  'La plantilla publicada decide el margen desde 12 unidades';
 SELECT * INTO emitted FROM fn_consola_emitir_cotizacion_cliente(NULL,
  jsonb_set(payload,'{0,id_plantilla_margen}',to_jsonb(plantilla_id::text)),27696,
  NULL,NULL,'client-contract-template');
 ASSERT emitted.status='OK','Emite con plantilla publicada';
 SELECT * INTO item FROM cotizacion_item WHERE id_cotizacion=emitted.id_cotizacion;
 ASSERT item.metadata_costeo->'plantilla_margen'->>'codigo'='CLIENTE_TEST',
  'Congela codigo, version y tramos de la plantilla';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_set(payload,'{0,id_plantilla_margen}','"00000000-0000-4000-0000-000000000000"'));
 ASSERT preview->>'status'='MARGIN_TEMPLATE_NOT_FOUND','Plantilla inexistente rechazada';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_set(payload,'{0,configuracion_tecnica}',
   '{"tipo":"dtf","disenos":[{"w":10,"h":10,"qty":1}],"ancho_rollo":60,"precio_metro":10000,"reserva_pct":0,"rotacion":true,"separacion":0,"minimo_metros":0,"costo_aplicacion_unitario":0}'::jsonb),40);
 ASSERT preview->>'status'='OK' AND (preview->'lineas'->0->>'costo_total')::numeric=20000,
  'DTF calcula geometria y costo en PostgreSQL';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_set(payload,'{0,configuracion_tecnica}',
   '{"tipo":"dtf","disenos":[{"w":70,"h":80,"qty":1}],"ancho_rollo":60,"precio_metro":10000,"reserva_pct":0,"rotacion":true,"separacion":0,"minimo_metros":0,"costo_aplicacion_unitario":0}'::jsonb),40);
 ASSERT preview->>'status'='DESIGN_DOES_NOT_FIT','Diseno que no entra en el rollo se rechaza';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,payload,35);
 retained := fn_consola_previsualizar_cotizacion_cliente(NULL,jsonb_set(payload,'{0,retencion_pct}','10'),35);
 ASSERT retained->>'status'='OK','Retencion informativa aceptada';
 ASSERT retained->>'total'=preview->>'total','Retencion no aumenta precio de venta';

 -- Cantidades arbitrarias y limites de tramos: sin valores 12/30/50 quemados.
 FOREACH n IN ARRAY ARRAY[1,12,30,50,100,110,1000,1100,1150,1200] LOOP
  preview := fn_consola_previsualizar_cotizacion_cliente(NULL,jsonb_set(payload,'{0,unidades_entregar}',to_jsonb(n)),35);
  expected := ceil((1000*n+6000)/.65/n)*n;
  ASSERT preview->>'status'='OK',format('Cantidad %s debe ser cotizable: %s',n,preview);
  ASSERT (preview->>'total')::numeric=expected,format('Cantidad %s: esperado %s, recibido %s',n,expected,preview);
  ASSERT (preview->'lineas'->0->>'precio_unitario')::numeric*n=expected,'Unitario por cantidad coincide con total';
 END LOOP;

 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,payload,35);
 SELECT * INTO emitted FROM fn_consola_emitir_cotizacion_cliente(NULL,payload,1,35,NULL,'client-contract-stale');
 ASSERT emitted.status='PREVIEW_CHANGED',format('Rechazar precio esperado desactualizado: %s',emitted.status);
 ASSERT (SELECT count(*) FROM cotizacion)=before_count+1,'Rechazo no deja cabecera parcial';
 SELECT * INTO emitted FROM fn_consola_emitir_cotizacion_cliente(NULL,payload,(preview->>'total')::numeric,35,NULL,'client-contract-issued');
 ASSERT emitted.status='OK',format('Emision coincide con preview: %s',emitted.status);
 ASSERT emitted.total=(preview->>'total')::numeric,'Total emitido igual al presentado';
 SELECT * INTO item FROM cotizacion_item WHERE id_cotizacion=emitted.id_cotizacion;
 ASSERT item.cantidad=12 AND item.precio_unitario=2308 AND item.subtotal=27696,'Congelar unitario y total coherentes';
 SELECT * INTO repeated FROM fn_consola_emitir_cotizacion_cliente(NULL,payload,27696,35,NULL,'client-contract-issued');
 ASSERT repeated.status='OK' AND repeated.id_cotizacion=emitted.id_cotizacion,'Reintento no duplica';
 SELECT * INTO repeated FROM fn_consola_emitir_cotizacion_cliente(NULL,jsonb_set(payload,'{0,unidades_entregar}','13'),30000,35,NULL,'client-contract-issued');
 ASSERT repeated.status='CONFLICT','Clave repetida con otras unidades produce conflicto';

 FOREACH n IN ARRAY ARRAY[0,-1] LOOP
  preview := fn_consola_previsualizar_cotizacion_cliente(NULL,jsonb_set(payload,'{0,unidades_entregar}',to_jsonb(n)),35);
  ASSERT preview->>'status'='INVALID_QUANTITY','Cantidad no positiva rechazada';
 END LOOP;
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,jsonb_set(payload,'{0,unidades_entregar}','1.5'),35);
 ASSERT preview->>'status'='INVALID_QUANTITY','No entregar fraccion de articulo';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,(payload #- '{0,unidades_entregar}'),35);
 ASSERT preview->>'status'='INVALID_QUANTITY','No adivinar cantidad ausente';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,payload,100);
 ASSERT preview->>'status'='INVALID_MARGIN','Margen 100 no es calculable';
 payload := jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000021','unidades_entregar',12));
 SELECT * INTO emitted FROM fn_consola_emitir_cotizacion_cliente(NULL,payload,36000,0,NULL,'client-contract-pack');
 ASSERT emitted.status='OK','Emitir compra completa con entrega parcial de paquete';
 SELECT * INTO item FROM cotizacion_item WHERE id_cotizacion=emitted.id_cotizacion;
 ASSERT item.cantidad=12 AND item.cantidad_comprada=20 AND item.cantidad_sobrante=8,
  'Historico distingue entrega, compra y sobrante';
 ASSERT item.subtotal=36000 AND item.precio_unitario=3000,'Historico incluye costo del sobrante';
 RAISE NOTICE 'PASSED - contrato cliente: PACK, redondeo, retenciones, cantidades, emision e idempotencia';
END $$;
RESET ROLE;

SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fc85-000000000002"}',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE payload jsonb; preview jsonb;
BEGIN
 payload := jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000022','unidades_entregar',12));
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,payload);
 ASSERT preview->>'status'='OK','COMERCIAL puede cotizar con politica';
 ASSERT (preview->'lineas'->0->>'costo_total') IS NULL,'COMERCIAL no ve costo interno';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_set(payload,'{0,id_plantilla_margen}',to_jsonb(current_setting('test.client_template_id'))));
 ASSERT preview->>'status'='OK' AND (preview->>'total')::numeric=18468,
  'COMERCIAL aplica plantilla publicada sin poder editar margen';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,payload,0);
 ASSERT preview->>'status'='MARGIN_OVERRIDE_FORBIDDEN','COMERCIAL no puede cambiar margen global';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,jsonb_set(payload,'{0,margen_linea_pct}','0'));
 ASSERT preview->>'status'='PRICING_OVERRIDE_FORBIDDEN','COMERCIAL no evade permiso mediante margen de linea';
 preview := fn_consola_previsualizar_cotizacion_cliente(NULL,
  jsonb_set(jsonb_set(payload,'{0,reasignacion_sobrante}','1000'),
   '{0,motivo_ajuste}','"motivo vendedor"'));
 ASSERT preview->>'status'='INVALID_SURPLUS_ALLOCATION',
  'COMERCIAL no reasigna sobrantes';
END $$;
RESET ROLE;

DO $$
DECLARE uid text; preview jsonb; emitted record; payload jsonb;
BEGIN
 payload := jsonb_build_array(jsonb_build_object('id_precio_proveedor_snapshot',
  '00000000-0000-4000-fc85-000000000022','unidades_entregar',12));
 FOREACH uid IN ARRAY ARRAY['00000000-0000-4000-fc85-000000000003','00000000-0000-4000-fc85-000000000099'] LOOP
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',uid)::text,true);
  SET LOCAL ROLE authenticated;
  preview := fn_consola_previsualizar_cotizacion_cliente(NULL,payload);
  ASSERT preview->>'status'='FORBIDDEN','LECTURA y sin perfil no cotizan';
  SELECT * INTO emitted FROM fn_consola_emitir_cotizacion_cliente(NULL,payload,12000);
  ASSERT emitted.status='FORBIDDEN','LECTURA y sin perfil no emiten';
  RESET ROLE;
 END LOOP;
 ASSERT NOT has_function_privilege('anon','public.fn_consola_previsualizar_cotizacion_cliente(uuid,jsonb,numeric)','EXECUTE'),'Anon sin acceso a preview';
 ASSERT NOT has_function_privilege('anon','public.fn_consola_emitir_cotizacion_cliente(uuid,jsonb,numeric,numeric,text,text)','EXECUTE'),'Anon sin acceso a emision';
 RAISE NOTICE 'PASSED - contrato cliente: permisos por rol y costos enmascarados';
END $$;
ROLLBACK;
