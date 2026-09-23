"""Aplica el plan revisado de calidad y migraciones 080/081, con ensayo previo.

Por defecto solo ensaya y revierte. --apply exige autorización del proyecto
psereyjwjpyakkmnabgm; conserva el respaldo local y el plan original/normalizado.
"""
import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import urlsplit

import psycopg
from psycopg import sql
from psycopg.types.json import Jsonb
from dotenv import dotenv_values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    directory = Path(args.directory)
    env = dotenv_values(root/'.env.staging')
    ref = 'psereyjwjpyakkmnabgm'
    assert urlsplit(env['SUPABASE_URL']).hostname == ref+'.supabase.co'
    db = urlsplit(env['DATABASE_URL'])
    assert db.hostname == 'db.'+ref+'.supabase.co' or ((db.hostname or '').endswith('.pooler.supabase.com') and db.username == 'postgres.'+ref)
    plan = json.loads((directory/'correcciones-preview.json').read_text(encoding='utf-8'))
    # Lista cerrada para este lote revisado; no ejecutar identificadores del JSON.
    allowed = {('organizacion','id_organizacion','nombre_legal'),('organizacion','id_organizacion','departamento'),('organizacion','id_organizacion','municipio'),('persona','id_persona','nombre_completo')}
    assert all((x['table'],x['pk'],x['field']) in allowed for x in plan)
    migrations = [root/'database/migrations'/name for name in ['080_exact_territory_filters.sql','081_require_supplier_purchase_unit.sql','082_preserve_unknown_purchase_unit_in_selector.sql']]
    checks = []
    with psycopg.connect(env['DATABASE_URL'],sslmode='require',connect_timeout=12,
                         options='-c lock_timeout=5000 -c statement_timeout=30000') as conn:
        definitions = conn.execute("select p.oid::regprocedure::text,pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('fn_consola_organizaciones','fn_consola_ubicaciones','fn_quote_calculate_supplier_components_core','fn_consola_ofertas_producto_proveedor')").fetchall()
        (directory/'funciones-antes.json').write_text(json.dumps(definitions,indent=2),encoding='utf-8')
        conn.rollback()

        def apply():
            for path in migrations:
                contents = path.read_text(encoding='utf-8-sig')
                digest = hashlib.sha256(contents.encode()).hexdigest()
                present = conn.execute('select checksum_sha256 from public.schema_migrations where filename=%s',(path.name,)).fetchone()
                if present:
                    assert present[0] == digest
                else:
                    conn.execute(contents)
                    conn.execute('insert into public.schema_migrations(filename,checksum_sha256,checksum_backfilled) values (%s,%s,false)',(path.name,digest))
            for table, pk, field in allowed:
                batch = [c for c in plan if (c['table'],c['pk'],c['field'])==(table,pk,field)]
                if not batch:
                    continue
                query = sql.SQL('update public.{table} set {field}=%s where {pk}=%s and {field} is not distinct from %s').format(table=sql.Identifier(table),field=sql.Identifier(field),pk=sql.Identifier(pk))
                cursor=conn.cursor()
                cursor.executemany(query,[(c['normalized'],c['id'],c['original']) for c in batch])
                assert cursor.rowcount == len(batch), 'El registro cambio desde el respaldo; se revierte el lote.'

        def verify():
            admin = conn.execute("select user_id from public.perfil_usuario where rol='ADMIN' and activo limit 1").fetchone()[0]
            org = conn.execute('select id_organizacion from public.organizacion limit 1').fetchone()[0]
            conn.execute("select set_config('request.jwt.claims',%s,true)",(json.dumps({'sub':str(admin),'role':'authenticated'}),))
            conn.execute('set local role authenticated')
            for dept in ['CUNDINAMARCA','SANTANDER','BOGOTÁ, D.C.']:
                rows=conn.execute('select departamento from public.fn_consola_organizaciones(p_departamento=>%s,p_limite=>200)',(dept,)).fetchall()
                assert rows and all(r[0]==dept for r in rows), dept
                checks.append('Filtro exacto '+dept)
            rows=conn.execute("select municipio from public.fn_consola_organizaciones(p_municipio=>'BOGOTÁ, D.C.',p_limite=>200)").fetchall()
            assert rows and all(r[0]=='BOGOTÁ, D.C.' for r in rows)
            checks.append('Bogota sin departamento')
            conn.execute('reset role')
            snap=conn.execute("select id_snapshot,id_producto_proveedor from public.precio_proveedor_snapshot where unidad_compra is null and moneda='COP' order by observado_en desc limit 1").fetchone()
            conn.execute('set local role authenticated')
            payload=[{'id_precio_proveedor_snapshot':str(snap[0]),'id_producto_proveedor':str(snap[1]),'cantidad':1}]
            result=conn.execute('select public.fn_consola_previsualizar_cotizacion_multilinea(%s,%s,40)',(org,Jsonb(payload))).fetchone()[0]
            assert result['status']=='PURCHASE_UNIT_UNVERIFIED',result['status']
            checks.append('Servidor bloquea unidad ausente incluso con llamada directa')
            offer=conn.execute('select unidad_compra,costo_unitario_estimado from public.fn_consola_ofertas_producto_proveedor(%s) where id_snapshot=%s',(snap[1],snap[0])).fetchone()
            assert offer == (None,None)
            checks.append('Selector conserva unidad y costo unitario desconocidos')
            conn.execute('reset role')
            for table, pk, field in allowed:
                batch=[c for c in plan if (c['table'],c['pk'],c['field'])==(table,pk,field)]
                if not batch:
                    continue
                query=sql.SQL('select {pk}::text,{field} from public.{table} where {pk}=any(%s::uuid[])').format(table=sql.Identifier(table),pk=sql.Identifier(pk),field=sql.Identifier(field))
                actual=dict(conn.execute(query,([c['id'] for c in batch],)).fetchall())
                assert all(actual.get(c['id'])==c['normalized'] for c in batch)
            checks.append('Todos los valores normalizados verificados')

        apply()
        verify()
        conn.rollback()
        checks.append('Ensayo revertido')
        if args.apply:
            apply()
            verify()
            conn.commit()
        result=dict(applied=args.apply,changes=len(plan),checks=checks)
        (directory/('aplicacion.json' if args.apply else 'ensayo.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        print(json.dumps(result,ensure_ascii=True))


if __name__ == '__main__':
    main()
