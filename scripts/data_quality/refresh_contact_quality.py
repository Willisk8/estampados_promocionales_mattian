"""Actualiza metadatos de contacto con respaldo/ensayo, sin enviar correo ni llamar."""
import argparse
import collections
import concurrent.futures
import json
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

import psycopg
from dotenv import dotenv_values
from scripts.data_quality.email_checks import email_syntax, check_domain
from scripts.data_quality.normalization import fixed_area_code_for_department


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args();out=args.output_dir;out.mkdir(parents=True,exist_ok=True)
    env=dotenv_values('.env.staging');ref='psereyjwjpyakkmnabgm';db=urlsplit(env['DATABASE_URL'])
    if urlsplit(env['SUPABASE_URL']).hostname!=ref+'.supabase.co' or not (db.hostname=='db.'+ref+'.supabase.co' or ((db.hostname or '').endswith('.pooler.supabase.com') and db.username=='postgres.'+ref)):
        raise SystemExit('Proyecto incorrecto')
    if (out/'aplicacion.json').exists():raise SystemExit('Usar directorio nuevo para conservar el respaldo anterior')
    with psycopg.connect(env['DATABASE_URL'],connect_timeout=12,sslmode='require',options='-c default_transaction_read_only=on -c statement_timeout=30000') as c:
        rows=[r[0] for r in c.execute('select to_jsonb(cc) from canal_contacto cc')]
        locations=collections.defaultdict(set)
        for cid,dep in c.execute('''select cc.id_canal_contacto::text,o.departamento from canal_contacto cc
          left join persona_organizacion po on po.id_persona=cc.id_persona and po.estado<>'INACTIVE'
          join organizacion o on o.id_organizacion=coalesce(cc.id_organizacion,po.id_organizacion)
          where cc.telefono_clasificacion='FIJO_LOCAL_SIN_INDICATIVO' '''):
            area=fixed_area_code_for_department(dep)
            locations[cid].add(area or 'UNKNOWN')
    (out/'canales-antes.json').write_text(json.dumps(rows,ensure_ascii=False),encoding='utf-8')
    syntax={r['id_canal_contacto']:email_syntax(r['valor_normalizado']) for r in rows if r['tipo']=='EMAIL'}
    domains=sorted({x[1] for x in syntax.values() if x[1]})
    if check_domain('gmail.com') != 'MX':
        raise SystemExit('DNS no disponible: se detiene sin convertir fallos de conectividad en resultados de calidad.')
    cache_path=out/'dns.json'
    cache=json.loads(cache_path.read_text()) if cache_path.exists() else {}
    # Cache solo del mismo lote/fecha; el directorio aplicado nunca se reutiliza.
    if cache.get('date')!=datetime.now(timezone.utc).date().isoformat():cache={}
    results=cache.get('domains',{})
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures={pool.submit(check_domain,d):d for d in domains if d not in results}
        for i,f in enumerate(concurrent.futures.as_completed(futures),1):
            results[futures[f]]=f.result()
            if i%100==0:
                print('Dominios comprobados:',i,flush=True)
                cache_path.write_text(json.dumps({'date':datetime.now(timezone.utc).date().isoformat(),'domains':results},indent=2),encoding='utf-8')
    checked=datetime.now(timezone.utc).isoformat()
    cache_path.write_text(json.dumps({'date':checked[:10],'checked_at':checked,'domains':results},indent=2),encoding='utf-8')
    emails=[];phones=[]
    for r in rows:
        if r['tipo']=='EMAIL':
            _,domain,status=syntax[r['id_canal_contacto']]
            dns=results[domain] if status=='VALID' else 'INVALID_FORMAT'
            state=r['estado']
            if state=='ACTIVE' and dns in ('INVALID_FORMAT','NXDOMAIN','NULL_MX','NO_MAIL'):
                state='INVALID' if dns=='INVALID_FORMAT' else 'REVIEW_REQUIRED'
            emails.append((dns,checked,r.get('email_buzon_estado') or 'NO_VERIFICADO',state,r['id_canal_contacto'],r['valor_normalizado'],r['estado']))
        areas=locations.get(r['id_canal_contacto'],set())
        if len(areas)==1 and 'UNKNOWN' not in areas and not r.get('telefono_indicativo_contexto'):
            phones.append((next(iter(areas)),r['id_canal_contacto'],r['valor_normalizado'],r['estado']))
    summary={'emails':len(emails),'unique_domains':len(domains),'domain_results':dict(collections.Counter(r[0] for r in emails)),
             'fixed_area_inferred':len(phones),'email_state_changes':sum(r[3]!=r[6] for r in emails),'mailboxes_verified':0}
    (out/'plan.json').write_text(json.dumps({'emails':emails,'phones':phones},ensure_ascii=False,indent=2),encoding='utf-8')
    (out/'preview.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    with psycopg.connect(env['DATABASE_URL'],sslmode='require',connect_timeout=12,options='-c lock_timeout=5000 -c statement_timeout=60000') as c:
        def apply():
            with c.cursor() as cur:
                cur.executemany('''update canal_contacto set email_dominio_estado=%s,email_dominio_verificado_en=%s,email_buzon_estado=%s,estado=%s
                  where id_canal_contacto=%s and valor_normalizado=%s and estado=%s''',emails)
                if cur.rowcount!=len(emails):raise RuntimeError('Conflicto concurrente de correo')
                cur.executemany('''update canal_contacto set telefono_indicativo_contexto=%s
                  where id_canal_contacto=%s and valor_normalizado=%s and estado=%s and telefono_indicativo_contexto is null''',phones)
                if cur.rowcount!=len(phones):raise RuntimeError('Conflicto concurrente de telefono')
            if c.execute('select count(*) from canal_contacto where telefono_fijo is not null and telefono_celular is not null').fetchone()[0]:
                raise RuntimeError('Canal ambiguo')
        apply();c.rollback()
        if args.apply:apply();c.commit()
    summary.update(applied=args.apply,trial_rolled_back=True)
    (out/('aplicacion.json' if args.apply else 'ensayo.json')).write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print(json.dumps(summary))


if __name__=='__main__':main()
