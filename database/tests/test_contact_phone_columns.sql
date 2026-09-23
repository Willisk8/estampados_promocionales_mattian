BEGIN;
DO $$
DECLARE org UUID := gen_random_uuid(); c UUID := gen_random_uuid(); r RECORD;
BEGIN
 INSERT INTO organizacion(id_organizacion,nombre_legal) VALUES(org,'QA contacto separado');
 INSERT INTO canal_contacto(id_canal_contacto,id_organizacion,tipo,valor_original,valor_normalizado)
 VALUES(c,org,'TELEFONO','+57 601 2345678 ext 12','6012345678');
 SELECT * INTO r FROM canal_contacto WHERE id_canal_contacto=c;
 IF r.telefono_fijo<>'6012345678' OR r.telefono_celular IS NOT NULL OR r.telefono_codigo_area<>'601' OR r.telefono_numero_local<>'2345678' THEN
   RAISE EXCEPTION 'Fijo/extension incorrectos'; END IF;
 UPDATE canal_contacto SET valor_original='3101234567' WHERE id_canal_contacto=c;
 SELECT * INTO r FROM canal_contacto WHERE id_canal_contacto=c;
 IF r.telefono_celular<>'3101234567' OR r.telefono_fijo IS NOT NULL THEN RAISE EXCEPTION 'Celular incorrecto'; END IF;
 UPDATE canal_contacto SET valor_original='2345678',telefono_indicativo_contexto='601' WHERE id_canal_contacto=c;
 SELECT * INTO r FROM canal_contacto WHERE id_canal_contacto=c;
 IF r.telefono_fijo<>'6012345678' OR r.estado<>'REVIEW_REQUIRED' THEN RAISE EXCEPTION 'Inferencia debe seguir en revision'; END IF;
 IF fn_normalize_colombian_phone('06-01 2345678')<>'6012345678' THEN RAISE EXCEPTION 'Cero extra'; END IF;
 IF has_function_privilege('anon','fn_consola_canales_detalle(uuid)','EXECUTE') THEN RAISE EXCEPTION 'RPC anon abierta'; END IF;
 UPDATE canal_contacto SET tipo='EMAIL',valor_original='admin@gmail.com',valor_normalizado='admin@gmail.com' WHERE id_canal_contacto=c;
 UPDATE canal_contacto SET email_dominio_estado='MX',email_buzon_estado='NO_VERIFICADO',email_dominio_verificado_en=now() WHERE id_canal_contacto=c;
 UPDATE canal_contacto SET valor_original='otro@outlook.com',valor_normalizado='otro@outlook.com' WHERE id_canal_contacto=c;
 SELECT * INTO r FROM canal_contacto WHERE id_canal_contacto=c;
 IF r.email_dominio_estado IS NOT NULL OR r.email_dominio_verificado_en IS NOT NULL OR r.email_buzon_estado<>'NO_VERIFICADO' THEN
   RAISE EXCEPTION 'Verificacion antigua no debe sobrevivir al cambio de correo'; END IF;
END;
$$;
INSERT INTO auth.users(id,email) VALUES
 ('00000000-0000-4000-fa83-000000000001','qa-contact-admin@example.com'),
 ('00000000-0000-4000-fa83-000000000002','qa-contact-sales@example.com'),
 ('00000000-0000-4000-fa83-000000000003','qa-contact-none@example.com');
INSERT INTO perfil_usuario(user_id,email,rol,activo) VALUES
 ('00000000-0000-4000-fa83-000000000001','qa-contact-admin@example.com','ADMIN',true),
 ('00000000-0000-4000-fa83-000000000002','qa-contact-sales@example.com','COMERCIAL',true);
INSERT INTO organizacion(id_organizacion,nombre_legal) VALUES
 ('00000000-0000-4000-fa83-000000000010','QA correo gratuito');
INSERT INTO canal_contacto(id_organizacion,tipo,valor_original,valor_normalizado) VALUES
 ('00000000-0000-4000-fa83-000000000010','EMAIL','Conjunto@gmail.com','Conjunto@gmail.com');
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fa83-000000000002"}',true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 ASSERT (SELECT valor='C***@gmail.com' AND enmascarado FROM fn_consola_canales_detalle('00000000-0000-4000-fa83-000000000010')),'COMERCIAL conserva mascara';
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fa83-000000000001"}',true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 ASSERT (SELECT valor='Conjunto@gmail.com' AND NOT enmascarado FROM fn_consola_canales_detalle('00000000-0000-4000-fa83-000000000010')),'ADMIN ve valor';
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fa83-000000000003"}',true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE blocked BOOLEAN:=false; BEGIN
 BEGIN PERFORM * FROM fn_consola_canales_detalle('00000000-0000-4000-fa83-000000000010');
 EXCEPTION WHEN OTHERS THEN blocked:=true; END;
 ASSERT blocked,'Usuario sin perfil no accede';
END $$;
RESET ROLE;
ROLLBACK;
