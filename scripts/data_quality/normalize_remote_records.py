"""Plan verificable de normalizacion; --apply ensaya y aplica con control optimista.

Lee el respaldo completo de public. No altera historicos, originales, precios,
identificadores, codigos, consentimientos ni relaciones comerciales.
"""
import argparse
import collections
import csv
import hashlib
import json
import re
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

import psycopg
from psycopg import sql
from dotenv import dotenv_values
from scripts.data_quality.audit_live_snapshot import repair, damaged
from scripts.data_quality.normalization import normalize_colombian_phone

FIELDS = {
    'organizacion': ('id_organizacion', ['nombre_legal','nombre_comercial','sigla','direccion','departamento','municipio']),
    'persona': ('id_persona', ['nombres','apellidos','nombre_completo']),
    'proveedor': ('id_proveedor', ['nombre','ciudad','pais']),
    'proveedor_tecnica_marcacion': ('id_proveedor_tecnica', ['nombre','ciudad','pais']),
    'producto': ('id_producto', ['nombre','descripcion','categoria']),
    'variante_producto': ('id_variante', ['nombre']),
    'producto_proveedor': ('id_producto_proveedor', ['nombre_original','descripcion','categoria']),
}


def compatible(original, candidates):
    # Caracteres perdidos: solo una fuente unica que coincide con TODO lo restante.
    value = repair(original)
    pattern = ''.join('.' if c == '\ufffd' else re.escape(c) for c in value)
    pattern = re.sub(r'(?:\\\?)+', lambda m: '.{1,' + str(max(1,len(m.group())//4)) + '}', pattern)
    matches = {c for c in candidates if c and not damaged(c) and
               re.fullmatch(pattern, c, flags=re.IGNORECASE)}
    return next(iter(matches)) if len(matches) == 1 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--official-xlsx', type=Path)
    parser.add_argument('--official-csv', type=Path)
    parser.add_argument('--verified-sources', type=Path)
    args = parser.parse_args()
    base = Path(args.directory)
    read = lambda name: json.loads((base / (name + '.json')).read_text(encoding='utf-8'))
    inventory = read('inventario')
    source = collections.defaultdict(set)
    if (base/'aplicacion.json').exists():
        raise SystemExit('Este respaldo ya fue aplicado; crear un respaldo nuevo antes de otro lote.')
    if args.verified_sources:
        entries=json.loads(args.verified_sources.read_text(encoding='utf-8'))
        for item in entries:
            if not item.get('url') or not item.get('verified_at'):
                raise ValueError('Fuente sin trazabilidad')
            for row in read('organizacion'):
                if row['nit']==item['nit']:
                    source[('organizacion',row['id_organizacion'],'nombre_legal')].add(item['nombre_legal'])
        (base/'fuentes-web.json').write_text(json.dumps(entries,ensure_ascii=False,indent=2),encoding='utf-8')
    for row in read('import_raw_row'):
        if row['target_table'] not in FIELDS or not row['target_id']:
            continue
        for key, value in (row['raw_payload'] or {}).items():
            if isinstance(value, str) and value.strip() and not damaged(value):
                source[(row['target_table'], row['target_id'], key)].add(repair(value))
    if args.official_xlsx:
        import pandas as pd
        by_nit = collections.defaultdict(list)
        for row in read('organizacion'):
            by_nit[row['nit']].append(row)
        for _, entry in pd.read_excel(args.official_xlsx,header=4).fillna('').iterrows():
            nit = re.sub(r'\D','',str(entry['NIT']))
            nit = nit[:-1] if len(nit)==10 else nit
            for row in by_nit[nit]:
                for field,key in [('nombre_legal','NOMBREENTIDAD'),('sigla','SIGLA'),('direccion','DIRECCIÓN')]:
                    value=repair(entry[key])
                    if value and not damaged(value): source[('organizacion',row['id_organizacion'],field)].add(value)
        (base/'fuente-oficial.json').write_text(json.dumps({'path':str(args.official_xlsx),
            'sha256':hashlib.sha256(args.official_xlsx.read_bytes()).hexdigest(),
            'scope':'Recuperar caracteres del mismo texto por NIT; no cambiar direccion a una distinta ni certificar vigencia'}),encoding='utf-8')
    if args.official_csv:
        by_nit = collections.defaultdict(list)
        org_nit = {}
        for row in read('organizacion'):
            by_nit[row['nit']].append(row)
            org_nit[row['id_organizacion']] = row['nit']
        people_by_nit = collections.defaultdict(set)
        for row in read('persona_organizacion'):
            if row['rol']=='REPRESENTANTE_LEGAL':
                people_by_nit[org_nit.get(row['id_organizacion'])].add(row['id_persona'])
        with args.official_csv.open(encoding='utf-8-sig',newline='') as stream:
            for entry in csv.DictReader(stream):
                nit = re.sub(r'\D','',entry['nit'].split('-')[0])
                for row in by_nit[nit]:
                    for field,key in [('nombre_legal','nombreentidad'),('sigla','sigla'),('direccion','direccion')]:
                        value=repair(entry[key])
                        if value and not damaged(value): source[('organizacion',row['id_organizacion'],field)].add(value)
                name=repair(entry['representantelegal']).upper()
                if name and not damaged(name):
                    for pid in people_by_nit[nit]: source[('persona',pid,'nombre_completo')].add(name)
        (base/'fuente-historica.json').write_text(json.dumps({'path':str(args.official_csv),
            'sha256':hashlib.sha256(args.official_csv.read_bytes()).hexdigest(),
            'scope':'Mismo NIT y vinculo existente; solo recuperacion de caracteres, no cambia vigencia ni roles'}),encoding='utf-8')
    catalog = json.loads(Path('scripts/catalog/mvp_catalog_inputs.json').read_text(encoding='utf-8'))
    for entry in catalog['products']:
        product = entry['product']
        for table, identity, key, mapping in [
            ('producto', product['sku'], 'sku', {'nombre':'name','descripcion':'description','categoria':'category'}),
            ('variante_producto',product['variant_sku'],'sku_variante',{'nombre':'variant_name'})]:
            pk = FIELDS[table][0]
            for row in read(table):
                if row[key] == identity:
                    for field, src in mapping.items():
                        source[(table,row[pk],field)].add(product[src])
    plan, pending, scanned = [], [], {}
    for table, (pk, fields) in FIELDS.items():
        rows = read(table)
        scanned[table] = len(rows)
        for row in rows:
            for field in fields:
                original = row.get(field)
                if not isinstance(original, str) or not original:
                    continue
                value = repair(original)
                evidence = 'NFC, espacios y codificacion reversible; conserva caso y signos internos'
                if damaged(value):
                    value = compatible(value, source[(table,row[pk],field)])
                    evidence = 'Fuente original por mismo ID/SKU o fuente oficial por NIT; coincidencia completa salvo caracteres perdidos'
                    if value is None:
                        pending.append(dict(table=table,id=row[pk],field=field,original=original,reason='SOURCE_REQUIRED'))
                        continue
                if value != original:
                    plan.append(dict(table=table,pk=pk,id=row[pk],field=field,original=original,normalized=value,evidence=evidence))
    # Un telefono sintacticamente especial no debe conservarse como validado.
    for row in read('canal_contacto'):
        if row['tipo'] in ('TELEFONO','WHATSAPP') and row['estado']=='ACTIVE':
            result=normalize_colombian_phone(row['valor_normalizado'])
            if result.status in ('REVIEW','INVALID'):
                plan.append(dict(table='canal_contacto',pk='id_canal_contacto',id=row['id_canal_contacto'],field='estado',
                                 original='ACTIVE',normalized='REVIEW_REQUIRED' if result.status=='REVIEW' else 'INVALID',
                                 evidence=result.issue))
    # Inspeccion de todos los registros, incluidos JSON; no reescribe evidencia historica.
    findings=collections.Counter()
    def inspect(value, table, path):
        if isinstance(value, dict):
            for key,item in value.items(): inspect(item,table,path+'.'+key)
        elif isinstance(value,list):
            for item in value: inspect(item,table,path+'[]')
        elif isinstance(value,str):
            if '\ufffd' in value or re.search(r'\?{2,}',value): findings[(table,path,'LOST_CHARACTERS')]+=1
            if value != unicodedata.normalize('NFC',value): findings[(table,path,'NON_NFC')]+=1
    for table in inventory:
        for row in read(table): inspect(row,table,'')
    summary={'tables_scanned':len(inventory),'rows_scanned':sum(inventory.values()),'mutable_tables':scanned,
             'changes':len(plan),'by_field':dict(collections.Counter(x['table']+'.'+x['field'] for x in plan)),
             'pending':len(pending),'pending_by_field':dict(collections.Counter(x['table']+'.'+x['field'] for x in pending)),
             'historical_and_current_indicators':[dict(table=t,path=p,code=k,count=n) for (t,p,k),n in findings.items()]}
    for name,value in [('plan',plan),('pendientes',pending),('resumen',summary)]:
        (base/(name+'.json')).write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf-8')
    if not args.apply:
        print(json.dumps({k:v for k,v in summary.items() if k!='historical_and_current_indicators'},ensure_ascii=True))
        return
    env=dotenv_values('.env.staging')
    ref='psereyjwjpyakkmnabgm'
    db=urlsplit(env['DATABASE_URL'])
    if urlsplit(env['SUPABASE_URL']).hostname != ref+'.supabase.co' or not (
        db.hostname=='db.'+ref+'.supabase.co' or ((db.hostname or '').endswith('.pooler.supabase.com') and db.username=='postgres.'+ref)):
        raise SystemExit('Proyecto incorrecto')
    hashes={t:hashlib.sha256((base/(t+'.json')).read_bytes()).hexdigest() for t in inventory}
    (base/'backup-sha256.json').write_text(json.dumps(hashes,indent=2),encoding='utf-8')
    with psycopg.connect(env['DATABASE_URL'],sslmode='require',connect_timeout=12,
                         options='-c lock_timeout=5000 -c statement_timeout=30000') as conn:
        def apply_and_verify():
            for item in plan:
                query=sql.SQL('UPDATE public.{t} SET {f}=%s WHERE {pk}=%s AND {f} IS NOT DISTINCT FROM %s RETURNING {f}').format(
                    t=sql.Identifier(item['table']),f=sql.Identifier(item['field']),pk=sql.Identifier(item['pk']))
                rows=conn.execute(query,(item['normalized'],item['id'],item['original'])).fetchall()
                if rows != [(item['normalized'],)]: raise RuntimeError('Conflicto concurrente: lote revertido')
            for item in plan:
                actual=conn.execute(sql.SQL('SELECT {f} FROM public.{t} WHERE {pk}=%s').format(
                    f=sql.Identifier(item['field']),t=sql.Identifier(item['table']),pk=sql.Identifier(item['pk'])),(item['id'],)).fetchone()
                if actual != (item['normalized'],): raise RuntimeError('Verificacion fallida: lote revertido')
        apply_and_verify()
        conn.rollback()
        apply_and_verify()
        conn.commit()
    result={'applied':True,'changes':len(plan),'trial_rolled_back':True,'values_verified':True}
    (base/'aplicacion.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result))


if __name__=='__main__':
    main()
