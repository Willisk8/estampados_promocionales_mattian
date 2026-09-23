"""Carga trazable de propiedades horizontales; ensayo por defecto, --apply confirma.

No fusiona por nombre ni atribuye representacion legal a un contacto.
Los conflictos de NIT/identidad quedan en staging para revision.
"""
import argparse
import collections
import csv
import hashlib
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

import psycopg
from dotenv import dotenv_values

sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from _shared import stable_uuid, copy_into
from scripts.data_quality.normalization import normalize_text, search_key, normalize_colombian_phone, fixed_area_code_for_department
from scripts.data_quality.email_checks import email_syntax


def clean_name(value):
    value=normalize_text(value)
    if not value or search_key(value) in {'no_aplica','no_registra','sin_informacion','na','n_a'}:
        return None
    return value


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--file',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(); args.output_dir.mkdir(parents=True,exist_ok=True)
    with args.file.open(encoding='utf-8-sig',newline='') as stream: records=list(csv.DictReader(stream))
    raw_path=Path('scraping/residential_properties/outputs/enrichment/conjuntos_residenciales_enriquecidos.csv')
    with raw_path.open(encoding='utf-8-sig',newline='') as stream: originals={r['record_id']:r for r in csv.DictReader(stream)}
    territories=json.loads(Path('outputs/calidad-viva-20260917/divipola-dane-2025.json').read_text(encoding='utf-8'))
    dane={r['attributes']['MPIO_CDPMP']:r['attributes'] for r in territories['features']}
    digest=hashlib.sha256(args.file.read_bytes()).hexdigest()
    batch=stable_uuid('residential-import',digest)
    env=dotenv_values('.env.staging');db=urlsplit(env['DATABASE_URL']);ref='psereyjwjpyakkmnabgm'
    if urlsplit(env['SUPABASE_URL']).hostname!=ref+'.supabase.co' or not (db.hostname=='db.'+ref+'.supabase.co' or ((db.hostname or '').endswith('.pooler.supabase.com') and db.username=='postgres.'+ref)):
        raise SystemExit('Proyecto incorrecto')
    with psycopg.connect(env['DATABASE_URL'],sslmode='require',connect_timeout=12,options='-c lock_timeout=5000 -c statement_timeout=120000') as conn:
        if conn.execute('select 1 from import_batch where id_import_batch=%s',(batch,)).fetchone():
            print('Lote ya registrado; no se duplica.');return
        existing=[r[0] for r in conn.execute('select to_jsonb(o) from organizacion o')]
        (args.output_dir/'organizaciones-antes.json').write_text(json.dumps(existing,ensure_ascii=False),encoding='utf-8')
        existing_ids={r['id_organizacion'] for r in existing}; existing_nits={r['nit'] for r in existing if r['nit']}
        existing_signatures={(search_key(r['nombre_legal']),search_key(r.get('municipio'))) for r in existing}
        type_id=conn.execute("select id from cat_tipo_organizacion where codigo='CONJUNTO_RESIDENCIAL'").fetchone()[0]
        conn.rollback()
        nit_counts=collections.Counter(r['nit_normalizado'] for r in records if r['nit_normalizado'])
        signatures=collections.Counter((r['nombre_busqueda'],r['codigo_divipola']) for r in records)
        orgs=[];people=[];links=[];channels={};raw=[];reviews=[];pending=[]
        for index,row in enumerate(records,1):
            oid=stable_uuid('residential',row['source_id'],row['record_id'])
            rid=stable_uuid(batch,index);reasons=[]
            verified_alias=(search_key(row['department']),search_key(row['municipality']),row['codigo_divipola'])==('tolima','el_espinal','73268')
            territory=dane.get(row['codigo_divipola']) if row['divipola_match_status']=='EXACT' or verified_alias else None
            dep=territory['DPTO_CNMBRE'] if territory else row['department']
            city=territory['MPIO_CNMBRE'] if territory else row['municipality']
            nit=row['nit_normalizado'] or None
            conflict=(oid in existing_ids or (nit and (nit in existing_nits or nit_counts[nit]>1)) or
                      signatures[(row['nombre_busqueda'],row['codigo_divipola'])]>1 or
                      (row['nombre_busqueda'],search_key(city)) in existing_signatures)
            if conflict:reasons.append('IDENTITY_CONFLICT: no fusionar automaticamente')
            if row['data_quality_status']!='VALID':reasons.append('SOURCE_QUALITY_REVIEW')
            if row['residential_classification']!='RESIDENCIAL_CONFIRMADO':reasons.append('RESIDENTIAL_CLASSIFICATION_UNCONFIRMED')
            if row['nit_status']=='REVIEW':nit=None;reasons.append('NIT_DV_REVIEW: original conservado')
            if not territory:reasons.append('TERRITORY_REVIEW')
            if row['data_quality_status']=='INVALID':conflict=True;reasons.append('INVALID_NOT_LOADED')
            org_state='REVIEW_REQUIRED' if reasons else 'ACTIVE'
            normalized=dict(row,id_organizacion=oid,departamento=dep,municipio=city,estado=org_state)
            raw.append((rid,batch,index,json.dumps(originals[row['record_id']],ensure_ascii=False),json.dumps(normalized,ensure_ascii=False),'ORGANIZATION','POSSIBLE_DUPLICATE' if conflict else 'IMPORTED','organizacion',None if conflict else oid))
            if reasons:
                reason='; '.join(reasons);pending.append({'record_id':row['record_id'],'reason':reason})
                reviews.append((stable_uuid('review',rid),rid,reason,'HIGH' if conflict else 'MEDIUM','OPEN'))
            if conflict:continue
            orgs.append((oid,nit,clean_name(row['property_name']),type_id,'PROPIEDAD_HORIZONTAL',dep,city,normalize_text(row['address']) or None,row['source_url'],org_state))
            for field,role in [('legal_representative','REPRESENTANTE_LEGAL'),('contact_person','CONTACTO')]:
                name=clean_name(row[field])
                if not name:continue
                pid=stable_uuid('residential-person',oid,role,name)
                people.append((pid,name,'REVIEW_REQUIRED'))
                links.append((stable_uuid('residential-link',pid,oid,role),pid,oid,role,row['source_url'],'REVIEW_REQUIRED'))
            for email in row['emails_normalizados'].split(';'):
                email=email.strip()
                if not email:continue
                value,domain,status=email_syntax(email)
                cid=stable_uuid('residential-channel',oid,'EMAIL',value)
                channels[cid]=(cid,oid,'EMAIL',email,value,row['source_url'],'MEDIUM','ACTIVE' if status=='VALID' else 'INVALID',None,'NO_VERIFICADO')
            # Leer telefonos crudos, no el valor con indicativo inferido del CSV normalizado.
            for field in ['phone','phone_preferred','phones_public_web','whatsapp_public']:
                for raw_phone in (originals[row['record_id']].get(field) or '').split(';'):
                    if not raw_phone.strip():continue
                    phone=normalize_colombian_phone(raw_phone)
                    kind='WHATSAPP' if field=='whatsapp_public' else 'TELEFONO'
                    cid=stable_uuid('residential-channel',oid,kind,phone.national_number)
                    area=fixed_area_code_for_department(dep) if phone.classification=='FIJO_LOCAL_SIN_INDICATIVO' else None
                    channels[cid]=(cid,oid,kind,raw_phone,phone.national_number,row['source_url'],'MEDIUM',
                        'ACTIVE' if phone.status=='VALID' else ('INVALID' if phone.status=='INVALID' else 'REVIEW_REQUIRED'),area or None,None)
        summary={'source_rows':len(records),'organizations':len(orgs),'people':len(people),'links':len(links),'channels':len(channels),'review_items':len(reviews),'staged_only':len(records)-len(orgs),'batch_id':batch}
        (args.output_dir/'preview.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
        (args.output_dir/'pending.json').write_text(json.dumps(pending,ensure_ascii=False,indent=2),encoding='utf-8')
        def apply():
            conn.execute("insert into import_batch(id_import_batch,source_name,source_path,source_sha256,source_row_count,import_status,started_at) values(%s,'conjuntos_residenciales',%s,%s,%s,'RUNNING',now())",(batch,str(args.file),digest,len(records)))
            with conn.cursor() as cur:
                for table,cols,data in [
                    ('organizacion',['id_organizacion','nit','nombre_legal','id_tipo_organizacion','tipo_entidad_origen','departamento','municipio','direccion','fuente_registro','estado'],orgs),
                    ('persona',['id_persona','nombre_completo','estado'],people),
                    ('persona_organizacion',['id_persona_organizacion','id_persona','id_organizacion','rol','fuente','estado'],links),
                    ('canal_contacto',['id_canal_contacto','id_organizacion','tipo','valor_original','valor_normalizado','fuente','confianza','estado','telefono_indicativo_contexto','email_buzon_estado'],list(channels.values())),
                    ('contactabilidad',['id_contactabilidad','id_canal_contacto','base_contacto_codigo','evidencia'],[(stable_uuid('residential-contactability',cid),cid,'DESCONOCIDA','Fuente publica; no acredita consentimiento') for cid in channels]),
                    ('import_raw_row',['id_import_raw_row','id_import_batch','row_number','raw_payload','normalized_payload','entity_kind','match_status','target_table','target_id'],raw),
                    ('import_review_item',['id_import_review_item','id_import_raw_row','review_reason','severity','resolution_status'],reviews),
                ]:
                    inserted=copy_into(cur,table,cols,data)
                    if inserted!=len(data):raise RuntimeError('Conteo de insercion inesperado: '+table)
            conn.execute("update import_batch set import_status='COMPLETED',finished_at=now() where id_import_batch=%s",(batch,))
            assert conn.execute('select count(*) from import_raw_row where id_import_batch=%s',(batch,)).fetchone()[0]==len(records)
            assert conn.execute('select count(*) from organizacion where id_organizacion=any(%s::uuid[])',([r[0] for r in orgs],)).fetchone()[0]==len(orgs)
        apply();conn.rollback();summary['trial_rolled_back']=True
        if args.apply:apply();conn.commit()
        summary['applied']=args.apply
        (args.output_dir/('aplicacion.json' if args.apply else 'ensayo.json')).write_text(json.dumps(summary,indent=2),encoding='utf-8')
        print(json.dumps(summary))


if __name__=='__main__':main()
