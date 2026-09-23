BEGIN;
INSERT INTO auth.users(id,email) VALUES
 ('00000000-0000-4000-fe10-000000000001','admin-access@test.local'),
 ('00000000-0000-4000-fe10-000000000002','sales-access@test.local'),
 ('00000000-0000-4000-fe10-000000000003','reader-access@test.local');
INSERT INTO perfil_usuario(user_id,email,rol,activo) VALUES
 ('00000000-0000-4000-fe10-000000000001','admin-access@test.local','ADMIN',true),
 ('00000000-0000-4000-fe10-000000000002','sales-access@test.local','COMERCIAL',true),
 ('00000000-0000-4000-fe10-000000000003','reader-access@test.local','LECTURA',true);
INSERT INTO cotizacion(id_cotizacion,estado,moneda,total,creada_por,rol_consola)
VALUES ('00000000-0000-4000-fe10-000000000010','EMITIDA','COP',10000,'00000000-0000-4000-fe10-000000000001','ADMIN');

SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fe10-000000000001"}',true);
SET LOCAL ROLE authenticated;
INSERT INTO storage.objects(bucket_id,name) VALUES
 ('cotizaciones-pdf','cotizaciones/00000000-0000-4000-fe10-000000000010/00000000-0000-4000-fe10-000000000001/admin.pdf');
SELECT * FROM fn_consola_registrar_documento_cotizacion(
 '00000000-0000-4000-fe10-000000000010','PDF_GENERADO',
 'cotizaciones/00000000-0000-4000-fe10-000000000010/00000000-0000-4000-fe10-000000000001/admin.pdf');

RESET ROLE;
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fe10-000000000002"}',true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE n integer; blocked boolean := false;
BEGIN
 ASSERT (SELECT count(*) FROM cotizacion_documento)=0,'COMERCIAL no ve documentos ADMIN';
 ASSERT (SELECT count(*) FROM storage.objects WHERE bucket_id='cotizaciones-pdf')=0,'COMERCIAL no firma PDF ADMIN';
 BEGIN
  PERFORM * FROM fn_consola_registrar_documento_cotizacion('00000000-0000-4000-fe10-000000000010','PDF_GENERADO',
   'cotizaciones/00000000-0000-4000-fe10-000000000010/00000000-0000-4000-fe10-000000000001/admin.pdf');
 EXCEPTION WHEN others THEN blocked := true; END;
 ASSERT blocked,'Registrar un archivo ADMIN como COMERCIAL no puede eludir los permisos';
 INSERT INTO storage.objects(bucket_id,name) VALUES
  ('cotizaciones-pdf','cotizaciones/00000000-0000-4000-fe10-000000000010/00000000-0000-4000-fe10-000000000002/sales.pdf') RETURNING 1 INTO n;
 ASSERT n=1,'Debe poder subir con RETURNING antes de registrar';
 PERFORM * FROM fn_consola_registrar_documento_cotizacion('00000000-0000-4000-fe10-000000000010','PDF_GENERADO',
  'cotizaciones/00000000-0000-4000-fe10-000000000010/00000000-0000-4000-fe10-000000000002/sales.pdf');
 UPDATE storage.objects SET metadata='{"alterado":true}' WHERE bucket_id='cotizaciones-pdf';
 GET DIAGNOSTICS n = ROW_COUNT;
 ASSERT n=0,'Nadie puede sobrescribir un PDF registrado';
 DELETE FROM storage.objects WHERE bucket_id='cotizaciones-pdf';
 GET DIAGNOSTICS n = ROW_COUNT;
 ASSERT n=0,'Nadie puede borrar un PDF registrado';
 INSERT INTO storage.objects(bucket_id,name) VALUES
  ('cotizaciones-pdf','cotizaciones/00000000-0000-4000-fe10-000000000010/00000000-0000-4000-fe10-000000000002/failed.pdf');
 DELETE FROM storage.objects WHERE name LIKE '%/failed.pdf';
 GET DIAGNOSTICS n = ROW_COUNT;
 ASSERT n=1,'La limpieza solo borra el archivo propio no registrado';
END; $$;

RESET ROLE;
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fe10-000000000003"}',true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 ASSERT (SELECT count(*) FROM cotizacion_documento)=1,'LECTURA solo ve el PDF COMERCIAL';
 ASSERT (SELECT count(*) FROM storage.objects WHERE bucket_id='cotizaciones-pdf')=1,'Storage coincide con permisos del historial';
END; $$;

-- Una degradacion de ADMIN a COMERCIAL no habilita borrar archivos historicos
-- ocultos por RLS ni los reclasifica como archivos propios sin registro.
RESET ROLE;
UPDATE perfil_usuario SET rol='COMERCIAL' WHERE user_id='00000000-0000-4000-fe10-000000000001';
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fe10-000000000001"}',true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE n int; BEGIN
 ASSERT NOT fn_quote_pdf_archivo_propio_sin_registro('cotizaciones/00000000-0000-4000-fe10-000000000010/00000000-0000-4000-fe10-000000000001/admin.pdf');
 DELETE FROM storage.objects WHERE name LIKE '%/admin.pdf'; GET DIAGNOSTICS n = ROW_COUNT;
 ASSERT n=0,'Cambio de rol no permite borrar PDF ADMIN';
END; $$;
ROLLBACK;
