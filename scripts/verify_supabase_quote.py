"""Prueba remota del motor y RLS dentro de una transaccion revertida.

No conserva cotizaciones ni cambios de perfil. Las secuencias pueden consumir
numeros aunque se reviertan las filas (comportamiento normal de PostgreSQL).
"""
import json
from pathlib import Path
from uuid import uuid4
import psycopg
from psycopg.types.json import Jsonb
from dotenv import dotenv_values

root = Path(__file__).resolve().parent.parent
env = dotenv_values(root / '.env.staging')
assert env['SUPABASE_URL'].rstrip('/') == 'https://psereyjwjpyakkmnabgm.supabase.co'
qa = (root / '.qa_test_account_user_id').read_text(encoding='utf-8-sig').strip()
checks = []


def check(label, condition):
    checks.append({'label': label, 'ok': bool(condition)})
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    assert condition, label


with psycopg.connect(env['DATABASE_URL'], sslmode='require', connect_timeout=12,
                     options='-c lock_timeout=5000 -c statement_timeout=30000') as conn:
    try:
        profile = conn.execute('select u.email,p.rol,p.activo from auth.users u join public.perfil_usuario p on p.user_id=u.id where u.id=%s', (qa,)).fetchone()
        assert profile and profile[0].startswith('qa-') and '@prueba' in profile[0] and profile[1:] == ('COMERCIAL', True)
        admin = conn.execute("select user_id from public.perfil_usuario where rol='ADMIN' and activo limit 1").fetchone()[0]
        quote, org = conn.execute("select id_cotizacion,id_organizacion from public.cotizacion where notas ilike '%%QA%%' and id_organizacion is not null order by created_at desc limit 1").fetchone()
        snapshot, product = conn.execute("select id_snapshot,id_producto_proveedor from public.precio_proveedor_snapshot where unidad_compra='UNIT' and coalesce(minimo_compra,1)=1 and coalesce(incremento_compra,1)=1 and precio_publicado>0 and moneda='COP' order by observado_en desc limit 1").fetchone()
        before = conn.execute('select count(*) from public.cotizacion').fetchone()[0]

        def role(user):
            conn.execute('RESET ROLE')
            conn.execute("select set_config('request.jwt.claims',%s,true)", (json.dumps({'sub': str(user), 'role': 'authenticated'}),))
            conn.execute('SET LOCAL ROLE authenticated')

        role(admin)
        previous = None
        scenarios = []
        for quantity, margin in [(1,40),(12,35),(30,30),(50,25)]:
            payload = [{'id_precio_proveedor_snapshot':str(snapshot),'id_producto_proveedor':str(product),
                        'cantidad':quantity,'costo_unitario_override':1000,'margen_linea_pct':margin,'retencion_pct':0,
                        'costos_adicionales':[{'descripcion':'QA preparacion fija','costo_total':6000}]}]
            preview = conn.execute('select public.fn_consola_previsualizar_cotizacion_multilinea(%s,%s,40)', (org,Jsonb(payload))).fetchone()[0]
            check(f'Preview remoto {quantity} unidades',preview.get('status')=='OK')
            check(f'Costo fijo conservado en {quantity} unidades',preview['lineas'][0]['costo_total']==1000*quantity+6000)
            check(f'Margen protegido en {quantity} unidades',preview['total'] >= (1000*quantity+6000)/(1-margin/100))
            unit = preview['total']/quantity
            check(f'Precio por unidad decreciente en {quantity}',previous is None or unit<previous)
            previous=unit
            wrong=conn.execute('select status from public.fn_consola_emitir_cotizacion_verificada(%s,%s,1,40,%s,%s)',(org,Jsonb(payload),'QA revertida',str(uuid4()))).fetchone()[0]
            check(f'Emision rechaza total incorrecto en {quantity}',wrong=='PREVIEW_CHANGED')
            emitted=conn.execute('select status,total from public.fn_consola_emitir_cotizacion_verificada(%s,%s,%s,40,%s,%s)',(org,Jsonb(payload),preview['total'],'QA revertida',str(uuid4()))).fetchone()
            check(f'Emision coincide con preview en {quantity}',emitted[0]=='OK' and emitted[1]==preview['total'])
            scenarios.append({'quantity':quantity,'margin':margin,'total':preview['total']})

        role(qa)
        denied=conn.execute('select public.fn_consola_previsualizar_cotizacion_multilinea(%s,%s,40)',(org,Jsonb(payload))).fetchone()[0]
        check('COMERCIAL no puede imponer margen interno',denied.get('status')=='MARGIN_OVERRIDE_FORBIDDEN')
        for role_name, active in [('COMERCIAL',True),('LECTURA',True),('COMERCIAL',False)]:
            conn.execute('RESET ROLE')
            conn.execute('update public.perfil_usuario set rol=%s,activo=%s where user_id=%s',(role_name,active,qa))
            role(qa)
            label=role_name if active else 'INACTIVO'
            for table in ['cotizacion_item','cotizacion_evento']:
                check(f'{label}: sin costos/eventos directos',conn.execute(f'select count(*) from public.{table}').fetchone()[0]==0)
            check(f'{label}: sin documentos ADMIN',conn.execute("select count(*) from public.cotizacion_documento where rol_consola='ADMIN'").fetchone()[0]==0)
            check(f'{label}: rol validado',conn.execute('select public.fn_consola_rol()').fetchone()[0]==(role_name if active else None))
        conn.execute('RESET ROLE')
        check('Solo emisiones validas crearon filas en la transaccion',conn.execute('select count(*) from public.cotizacion').fetchone()[0]==before+4)
    finally:
        conn.rollback()
        path=root/'outputs/supabase-http-final/resultado-sql.json'
        path.parent.mkdir(exist_ok=True,parents=True)
        path.write_text(json.dumps({'checks':checks},indent=2),encoding='utf-8')
    check('Cotizaciones de prueba revertidas',conn.execute('select count(*) from public.cotizacion').fetchone()[0]==before)
    check('Perfil QA original conservado',conn.execute('select rol,activo from public.perfil_usuario where user_id=%s',(qa,)).fetchone()==('COMERCIAL',True))
    conn.rollback()
    path.write_text(json.dumps({'checks':checks,'scenarios':scenarios},indent=2),encoding='utf-8')
