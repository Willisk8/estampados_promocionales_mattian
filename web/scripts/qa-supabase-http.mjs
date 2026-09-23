/** Integracion HTTP real: sesion QA, SSR, PDF y Storage. Sin automatizar UI. */
import { createServerClient } from '@supabase/ssr';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';

const { SUPABASE_URL, SUPABASE_ANON_KEY, QA_EMAIL, QA_PASSWORD, QA_QUOTE_ID } = process.env;
if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !QA_EMAIL || !QA_PASSWORD || !QA_QUOTE_ID) throw new Error('Faltan variables de QA');
if (SUPABASE_URL !== 'https://psereyjwjpyakkmnabgm.supabase.co') throw new Error('Destino no confirmado');
const base = 'http://127.0.0.1:3000';
const out = resolve('../outputs/supabase-http-final');
mkdirSync(out, { recursive: true });
const jar = new Map();
const checks = [];
function check(label, ok) { checks.push({ label, ok: !!ok }); console.log(`${ok ? 'PASS' : 'FAIL'} ${label}`); if (!ok) throw new Error(label); }
const client = createServerClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  cookies: { getAll: () => [...jar].map(([name,value])=>({name,value})), setAll: entries => entries.forEach(e=>jar.set(e.name,e.value)) },
});
async function request(path) {
  const response = await fetch(base+path,{headers:{Cookie:[...jar].map(([k,v])=>`${k}=${v}`).join('; ')},redirect:'manual',signal:AbortSignal.timeout(90000)});
  for (const raw of response.headers.getSetCookie()) { const pair=raw.split(';',1)[0]; const index=pair.indexOf('='); jar.set(pair.slice(0,index),pair.slice(index+1)); }
  return response;
}
try {
  const login = await client.auth.signInWithPassword({email:QA_EMAIL,password:QA_PASSWORD});
  check('Login real de la cuenta QA',!login.error && !!login.data.user);
  const userId=login.data.user.id;
  const profile=await client.from('perfil_usuario').select('rol,activo').eq('user_id',userId).single();
  check('Cuenta QA comercial activa',profile.data?.rol==='COMERCIAL'&&profile.data.activo===true);
  for(const table of ['cotizacion_item','cotizacion_evento']) {
    const result=await client.from(table).select('*').limit(1);
    check(`COMERCIAL no obtiene filas internas de ${table}`,!result.error && result.data?.length===0);
  }
  const docsAdmin=await client.from('cotizacion_documento').select('id_cotizacion_documento').eq('rol_consola','ADMIN').limit(1);
  check('COMERCIAL no ve documentos de ADMIN',!docsAdmin.error && docsAdmin.data?.length===0);
  if(process.env.QA_ADMIN_PDF_PATH) {
    const signed=await client.storage.from('cotizaciones-pdf').createSignedUrl(process.env.QA_ADMIN_PDF_PATH,60);
    check('Storage deniega firma de un PDF de ADMIN',!!signed.error && !signed.data?.signedUrl);
  }
  for(const path of ['/','/clientes','/cotizador',`/cotizador/${QA_QUOTE_ID}`]) {
    const response=await request(path); const html=await response.text();
    check(`SSR autenticado ${path}`,response.status===200 && !html.includes('name="password"') && !html.includes('NEXT_HTTP_ERROR_FALLBACK;500'));
  }
  const before=await client.from('cotizacion_documento').select('id_cotizacion_documento').eq('id_cotizacion',QA_QUOTE_ID).eq('generado_por',userId);
  check('Historial accesible antes de generar',!before.error);
  const pdf=await request(`/cotizador/${QA_QUOTE_ID}/pdf`);
  const bytes=Buffer.from(await pdf.arrayBuffer());
  check('Ruta genera PDF y confirma archivado',pdf.status===200&&pdf.headers.get('content-type')?.includes('application/pdf')&&bytes.subarray(0,5).toString()==='%PDF-');
  writeFileSync(resolve(out,'cotizacion-qa.pdf'),bytes);
  const after=await client.from('cotizacion_documento').select('id_cotizacion_documento,storage_path,metadata').eq('id_cotizacion',QA_QUOTE_ID).eq('generado_por',userId).order('created_at',{ascending:false});
  check('Una generacion nueva registrada',!after.error&&after.data.length===before.data.length+1);
  const doc=after.data[0];
  check('Ruta exclusiva del usuario',doc.storage_path.split('/')[2]===userId);
  const signed=await client.storage.from('cotizaciones-pdf').createSignedUrl(doc.storage_path,60);
  check('Firma de descarga permitida',!signed.error&&!!signed.data?.signedUrl);
  const download=await fetch(signed.data.signedUrl,{signal:AbortSignal.timeout(20000)});
  check('Bytes archivados iguales al PDF entregado',download.ok&&Buffer.from(await download.arrayBuffer()).equals(bytes));
  const update=await client.storage.from('cotizaciones-pdf').update(doc.storage_path,bytes,{contentType:'application/pdf'});
  check('Storage bloquea sobrescritura del PDF registrado',!!update.error);
  const upsert=await client.storage.from('cotizaciones-pdf').upload(doc.storage_path,bytes,{contentType:'application/pdf',upsert:true});
  check('Storage bloquea upsert del PDF registrado',!!upsert.error);
  const remove=await client.storage.from('cotizaciones-pdf').remove([doc.storage_path]);
  const still=await client.storage.from('cotizaciones-pdf').download(doc.storage_path);
  check('Storage conserva PDF registrado ante intento de borrado',(!remove.data?.length||!!remove.error)&&!still.error);
  const orphan=`cotizaciones/${QA_QUOTE_ID}/${userId}/qa-temporal-${randomUUID()}.pdf`;
  const upload=await client.storage.from('cotizaciones-pdf').upload(orphan,bytes,{contentType:'application/pdf'});
  check('Se puede subir un objeto propio sin registro',!upload.error);
  const cleanup=await client.storage.from('cotizaciones-pdf').remove([orphan]);
  check('Se puede limpiar solo el objeto de prueba sin registro',!cleanup.error&&cleanup.data?.length===1);
  const anonymous=await fetch(base+`/cotizador/${QA_QUOTE_ID}/pdf`,{redirect:'manual',signal:AbortSignal.timeout(20000)});
  check('Acceso anonimo al PDF rechazado',[301,302,303,307,308,401,403].includes(anonymous.status));
  writeFileSync(resolve(out,'documento.json'),JSON.stringify({quote:QA_QUOTE_ID,documentId:doc.id_cotizacion_documento,bytes:bytes.length},null,2));
} finally {
  writeFileSync(resolve(out,'resultado.json'),JSON.stringify({at:new Date().toISOString(),checks},null,2));
  await client.auth.signOut({scope:'local'});
}
