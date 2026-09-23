/** Chromium + componente real + motor SQL local. No usa STAGING ni credenciales QA. */
import { build } from 'esbuild';
import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const web = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(web, '..');
const out = resolve(root, process.env.QA_OUTPUT_DIR ?? 'outputs/qa-browser');
mkdirSync(out, { recursive: true });
const dsn = process.env.QA_DATABASE_URL;
if (!dsn || !['127.0.0.1','localhost','[::1]'].includes(new URL(dsn).hostname)) throw new Error('QA_DATABASE_URL debe apuntar a PostgreSQL local con las migraciones aplicadas.');

const python = `
import sys,json,decimal
import psycopg
from pathlib import Path
conn=psycopg.connect(sys.argv[1],connect_timeout=8,options='-c statement_timeout=30000')
cur=conn.cursor()
fixture=Path('database/tests/test_quote_supplier_multilinea.sql').read_text(encoding='utf-8').split("SELECT set_config")[0]
cur.execute(fixture)
cur.execute("SELECT set_config('request.jwt.claims', %s, true)",(json.dumps({'sub':'00000000-0000-4000-fd00-000000000001'}),))
cur.execute('SET LOCAL ROLE authenticated')
print(json.dumps({'ready':True}),flush=True)
try:
 for line in sys.stdin:
  request=json.loads(line); data=request['data']; op=request['op']
  cur.execute('SAVEPOINT request')
  try:
   if op=='preview':
    cur.execute('SELECT fn_consola_previsualizar_cotizacion_cliente(%s,%s::jsonb,%s)',(data['id_organizacion'],json.dumps(data['lineas']),data['margen_override_pct']))
    result=cur.fetchone()[0]
   elif op=='emit':
    cur.execute('SELECT * FROM fn_consola_emitir_cotizacion_cliente(%s,%s::jsonb,%s,%s,%s,%s)',(data['id_organizacion'],json.dumps(data['lineas']),data['total_esperado'],data['margen_override_pct'],data['notas'],data['idempotency_key']))
    result=dict(zip([d.name for d in cur.description],cur.fetchone()))
   else: raise ValueError('Operacion invalida')
   cur.execute('RELEASE SAVEPOINT request')
   print(json.dumps(result,default=str),flush=True)
  except Exception as e:
   cur.execute('ROLLBACK TO SAVEPOINT request')
   print(json.dumps({'status':'ERROR','message':str(e)}),flush=True)
finally:
 conn.rollback();conn.close()
`;
const worker = spawn(process.env.PYTHON ?? 'python', ['-u','-c',python,dsn], { cwd: root, windowsHide: true, stdio: ['pipe','pipe','pipe'] });
const queue = [];
const ready = new Promise((resolveReady,reject) => {
  const lines = createInterface({ input: worker.stdout });
  lines.on('line',line => { const data=JSON.parse(line); if(data.ready) resolveReady(); else queue.shift()?.(data); });
  worker.once('error',reject);
  worker.once('exit',code => { if(code) reject(new Error('SQL worker failed: '+code)); });
});
worker.stderr.on('data',b => process.stderr.write(b));
const sql = (op,data) => new Promise(resolveResult => { queue.push(resolveResult); worker.stdin.write(JSON.stringify({op,data})+'\n'); });

const org='00000000-0000-4000-fd00-000000000010';
const provider='00000000-0000-4000-fd00-000000000020';
const pack='00000000-0000-4000-fd00-000000000021';
const unit='00000000-0000-4000-fd00-000000000023';
const mocks = `
const products=[{id_producto_proveedor:'${pack}',nombre_original:'Caja x10 QA',ultimo_precio:18000,unidad_compra:'PACK',cantidad_pack:10},{id_producto_proveedor:'${unit}',nombre_original:'Mug QA',ultimo_precio:9500,unidad_compra:'UNIT',cantidad_pack:null}];
window.qa={calls:[],lastPreview:null,lastEmission:null};
const request=async(op,data)=>{window.qa.calls.push({op,data});const r=await fetch('/rpc',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({op,data})});return r.json();};
export const useRouter=()=>({push:path=>{window.qa.destination=path;}});
export const crearClienteNavegador=()=>({
 rpc:async(name,args)=>{
  if(name==='fn_consola_buscar_productos_proveedor')return {data:products,error:null};
  if(name==='fn_consola_plantillas_margen')return {data:[],error:null};
  const p=products.find(p=>p.id_producto_proveedor===args.p_id_producto_proveedor);
  await new Promise(r=>setTimeout(r,p.id_producto_proveedor==='${pack}'?900:30));
  return {data:[{id_snapshot:p.id_producto_proveedor==='${pack}'?'00000000-0000-4000-fd00-000000000022':'00000000-0000-4000-fd00-000000000024',precio_publicado:p.ultimo_precio,costo_unitario_estimado:p.unidad_compra==='PACK'?1800:9500,unidad_compra:p.unidad_compra,cantidad_pack:p.cantidad_pack,vigente:true}],error:null};
 },
 from:()=>{const q={select:()=>q,order:()=>q,limit:()=>q,or:()=>q,then:resolve=>resolve({data:[{id_organizacion:'${org}',nombre_legal:'Organizacion QA',nit:'901777666'}],error:null})};return q;}
});
export async function previsualizarCotizacionMultilinea(carga){const data=await request('preview',carga);window.qa.lastPreview=data;return data.status==='OK'?{ok:true,total:Number(data.total),lineas:data.lineas}:{ok:false,mensaje:data.message??data.status};}
export async function emitirCotizacionMultilinea(carga){const data=await request('emit',carga);window.qa.lastEmission=data;return data.status==='OK'?{ok:true,...data,total:Number(data.total)}:{ok:false,mensaje:data.message??data.status};}
`;
let browser, server, page;
const checks=[];
const check=(name,condition)=>{assert.ok(condition,name);checks.push(name);console.log('PASS '+name);};
try {
  await ready;
  const bundle=await build({
    stdin:{contents:`import React from 'react';import{createRoot}from'react-dom/client';import{CalculadoraCotizador}from'./src/componentes/calculadora-cotizador';import './src/app/globals.css';createRoot(document.getElementById('root')).render(<CalculadoraCotizador esAdmin={true} proveedoresIniciales={[{id_proveedor:'${provider}',nombre:'Proveedor QA',productos:2,ciudad:'Bogota'}]} organizacionesIniciales={[{id_organizacion:'${org}',nombre_legal:'Organizacion QA',nit:'901777666'}]} idOrganizacionInicial='${org}'/>);`,resolveDir:web,loader:'tsx'},
    absWorkingDir:web,bundle:true,write:false,outdir:out,jsx:'automatic',define:{'process.env.NODE_ENV':'"development"'},
    plugins:[{name:'isolated-adapters',setup(b){
      b.onResolve({filter:/^(next\/navigation|@\/lib\/supabase\/navegador|@\/app\/cotizador\/acciones)$/},()=>({path:'adapters',namespace:'qa'}));
      b.onLoad({filter:/.*/,namespace:'qa'},()=>({contents:mocks,loader:'js'}));
      b.onResolve({filter:/^@\//},args=>({path:resolve(web,'src',args.path.slice(2)+'.ts')}));
    }}],
  });
  const js=bundle.outputFiles.find(f=>f.path.endsWith('.js')).text;
  const css=bundle.outputFiles.find(f=>f.path.endsWith('.css')).text;
  server=createServer(async(req,res)=>{
    if(req.url==='/rpc'&&req.method==='POST'){
      let body='';for await(const b of req){body+=b;if(body.length>100000){res.writeHead(413).end();return;}}
      try{const {op,data}=JSON.parse(body);res.setHeader('Content-Type','application/json');res.end(JSON.stringify(await sql(op,data)));}catch{res.writeHead(500).end();}return;
    }
    if(req.url==='/app.js'){res.setHeader('Content-Type','application/javascript');res.end(js);return;}
    if(req.url==='/app.css'){res.setHeader('Content-Type','text/css');res.end(css);return;}
    res.setHeader('Content-Type','text/html');res.end('<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/app.css"><body><main style="padding:20px;max-width:1600px;margin:auto"><h1>QA aislado del cotizador</h1><div id="root"></div></main><script src="/app.js"></script></body></html>');
  });
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  browser=await chromium.launch({headless:true});
  page=await browser.newPage({viewport:{width:1440,height:1000}});
  page.setDefaultTimeout(15000);
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  await page.getByTestId('calc-linea-proveedor').selectOption(provider);
  await page.getByTestId('calc-linea-producto').click();
  await page.getByTestId('calc-linea-opcion').filter({hasText:'Caja x10 QA'}).click();
  await page.getByTestId('calc-linea-producto').click();
  await page.getByTestId('calc-linea-opcion').filter({hasText:'Mug QA'}).click();
  await page.waitForTimeout(1100);
  check('La respuesta tardia del paquete no pisa el costo del mug',(await page.getByTestId('calc-linea-precio').inputValue())==='9.500');
  await page.getByTestId('calc-linea-precio').fill('18.000,50');
  await page.getByTestId('calc-linea-cantidad').fill('12');
  const valorDecimal=await page.getByTestId('calc-linea-precio').inputValue();
  console.log('Decimal mostrado:',valorDecimal);
  check('Los decimales sobreviven al blur',Number(valorDecimal.replaceAll('.', '').replace(',', '.'))===18000.5);
  await page.getByTestId('calc-linea-precio').fill('1000');
  await page.getByTestId('calc-linea-add-costo').click();
  await page.getByTestId('calc-linea-costo-nombre').fill('Preparacion fija');
  await page.getByTestId('calc-linea-costo-valor').fill('6000');
  await page.getByLabel('Aplicacion del costo adicional').selectOption('TOTAL');
  await page.getByTestId('calc-margen').fill('40');
  await page.getByLabel('Aplicar margenes por volumen').check();
  await page.getByRole('button',{name:'Agregar escala'}).click();
  await page.getByLabel('Cantidad inicial de escala 1').fill('12');
  await page.getByLabel('Margen desde 12 unidades').fill('35');
  await page.getByRole('button',{name:'Agregar escala'}).click();
  await page.getByLabel('Cantidad inicial de escala 2').fill('30');
  await page.getByLabel('Margen desde 30 unidades').fill('30');
  await page.getByTestId('calc-confirmar-margen').check();
  check('Emision bloqueada antes de validar',await page.getByTestId('calc-emitir-boton').isDisabled());
  await page.getByTestId('calc-validar').click();
  await page.getByTestId('calc-precio-validado').waitFor();
  const preview=await page.evaluate(()=>window.qa.lastPreview);
  check('El servidor calcula 12 unidades y fijo sin multiplicarlo',Number(preview.lineas[0].costo_total)===18000);
  check('Margen de 35% y redondeo unitario: total 27.696',Number(preview.total)===27696);
  await page.getByTestId('calc-linea-cantidad').fill('30');
  check('Cambiar cantidad invalida el total previo',await page.getByTestId('calc-emitir-boton').isDisabled());
  await page.getByTestId('calc-validar').click();await page.getByTestId('calc-precio-validado').waitFor();
  check('30 unidades con 30% dan 51.450',Number(await page.evaluate(()=>window.qa.lastPreview.total))===51450);
  await page.getByTestId('calc-emitir-boton').click();
  await page.waitForFunction(()=>window.qa.lastEmission?.status==='OK');
  check('Total emitido coincide con la validacion',Number(await page.evaluate(()=>window.qa.lastEmission.total))===51450);
  await page.screenshot({path:resolve(out,'cotizador-desktop.png'),fullPage:true});
  await page.setViewportSize({width:390,height:844});
  check('El documento movil no desborda horizontalmente',await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));
  await page.screenshot({path:resolve(out,'cotizador-movil.png'),fullPage:true});
  if (errors.length) console.error('Errores JavaScript:',errors);
  check('Sin errores de JavaScript',errors.length===0);
  writeFileSync(resolve(out,'resultado.json'),JSON.stringify({checks,preview,errors},null,2));
} catch (error) {
  writeFileSync(resolve(out,'failure.json'),JSON.stringify({checks,error:String(error)},null,2));
  await page?.screenshot({path:resolve(out,'failure.png'),fullPage:true}).catch(()=>{});
  throw error;
} finally {
  await browser?.close();
  if(server)await new Promise(r=>server.close(r));
  worker.stdin.end();
}
