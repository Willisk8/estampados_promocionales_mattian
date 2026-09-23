BEGIN;
INSERT INTO auth.users(id,email) VALUES
 ('00000000-0000-4000-fa86-000000000001','qa-template-admin@example.com'),
 ('00000000-0000-4000-fa86-000000000002','qa-template-sales@example.com');
INSERT INTO perfil_usuario(user_id,email,rol,activo) VALUES
 ('00000000-0000-4000-fa86-000000000001','qa-template-admin@example.com','ADMIN',true),
 ('00000000-0000-4000-fa86-000000000002','qa-template-sales@example.com','COMERCIAL',true);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fa86-000000000001"}',true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE a UUID; b UUID; bloqueado BOOLEAN; tramos JSONB; BEGIN
 a:=fn_consola_guardar_plantilla_margen('QA_TEMPLATE',40,'[{"desde":100,"margen":30},{"desde":1150,"margen":20}]');
 ASSERT (SELECT estado='DRAFT' FROM fn_consola_plantillas_margen() WHERE id=a),'Crea borrador';
 PERFORM fn_consola_publicar_plantilla_margen(a);
 bloqueado:=false;
 BEGIN PERFORM fn_consola_guardar_plantilla_margen('QA_TEMPLATE',39,'[]',a); EXCEPTION WHEN OTHERS THEN bloqueado:=true; END;
 ASSERT bloqueado,'Publicada no editable';
 b:=fn_consola_guardar_plantilla_margen('QA_TEMPLATE',35,'[]');
 PERFORM fn_consola_publicar_plantilla_margen(b);
 ASSERT (SELECT estado='RETIRED' AND margen_base=40 FROM fn_consola_plantillas_margen() WHERE id=a),'Historico conservado';
 ASSERT (SELECT estado='ACTIVE' AND version=2 FROM fn_consola_plantillas_margen() WHERE id=b),'Nueva version activa';
 FOREACH tramos IN ARRAY ARRAY['[{"desde":2,"margen":30},{"desde":2,"margen":20}]'::jsonb,
 '[{"desde":2,"margen":41}]'::jsonb,'[{"desde":1.5,"margen":30}]'::jsonb,
 '[{"desde":0,"margen":30}]'::jsonb,'[{"desde":2,"margen":-1}]'::jsonb,'null'::jsonb] LOOP
  bloqueado:=false;
  BEGIN PERFORM fn_consola_guardar_plantilla_margen('QA_BAD',40,tramos); EXCEPTION WHEN OTHERS THEN bloqueado:=true; END;
  ASSERT bloqueado,'Reglas invalidas bloqueadas';
 END LOOP;
 bloqueado:=false;
 BEGIN PERFORM fn_consola_guardar_plantilla_margen('QA_BAD',100,'[]'); EXCEPTION WHEN OTHERS THEN bloqueado:=true; END;
 ASSERT bloqueado,'Margen 100 bloqueado';
 PERFORM fn_consola_guardar_plantilla_margen('QA_DRAFT',30,'[]');
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-fa86-000000000002"}',true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE bloqueado BOOLEAN:=false; BEGIN
 ASSERT (SELECT count(*)=2 FROM fn_consola_plantillas_margen() WHERE codigo='QA_TEMPLATE'),'Comercial lee historial';
 ASSERT NOT EXISTS(SELECT 1 FROM fn_consola_plantillas_margen() WHERE codigo='QA_DRAFT'),'Comercial no ve borradores';
 BEGIN PERFORM fn_consola_guardar_plantilla_margen('QA_ATTACK',1,'[]'); EXCEPTION WHEN OTHERS THEN bloqueado:=true; END;
 ASSERT bloqueado,'Comercial no escribe';
 bloqueado:=false;
 BEGIN PERFORM fn_consola_publicar_plantilla_margen(gen_random_uuid()); EXCEPTION WHEN OTHERS THEN bloqueado:=true; END;
 ASSERT bloqueado,'Comercial no publica';
 ASSERT NOT has_table_privilege('authenticated','public.plantilla_margen_version','UPDATE'),'Sin escritura directa';
 ASSERT NOT has_function_privilege('anon','fn_consola_plantillas_margen()','EXECUTE'),'Anon bloqueado';
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claims','{}',true);
SET LOCAL ROLE authenticated;
DO $$ DECLARE bloqueado BOOLEAN:=false; BEGIN
 BEGIN PERFORM * FROM fn_consola_plantillas_margen(); EXCEPTION WHEN OTHERS THEN bloqueado:=true; END;
 ASSERT bloqueado,'Sin perfil no lee';
END $$;
RESET ROLE;
ROLLBACK;
