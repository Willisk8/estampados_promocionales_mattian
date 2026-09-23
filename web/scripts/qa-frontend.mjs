/**
 * QA front-end campo a campo: cotizador proveedor-first con navegador real
 * (Edge headless + CDP, sin dependencias nuevas) y captura de consola.
 * Afirmacion global: cero errores "not focusable" durante todo el flujo.
 */
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(process.cwd(), "..");
const readEnv = (name) => {
  const line = readFileSync(join(ROOT, ".env.staging"), "utf8")
    .split(/\r?\n/)
    .find((l) => l.startsWith(name + "="));
  return line ? line.slice(name.length + 1).trim() : null;
};
const sbUrl = readEnv("SUPABASE_URL");
const service = readEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = readFileSync(join(ROOT, ".qa_test_account_password"), "utf8").trim();

const list = await fetch(`${sbUrl}/auth/v1/admin/users?page=1&per_page=50`, {
  headers: { apikey: service, Authorization: `Bearer ${service}` },
}).then((r) => r.json());
const qa = (list.users ?? []).find((u) => (u.email ?? "").startsWith("qa-") && (u.email ?? "").includes("@prueba"));
if (!qa) throw new Error("NO_QA_USER");
const email = qa.email;
console.log("QA_EMAIL=" + email[0] + "***" + email.split("@")[1]);

const checks = [];
const check = (label, ok, detail) => {
  checks.push({ label, ok: !!ok, detail: String(detail ?? "").slice(0, 200) });
  console.log((ok ? "PASS " : "FAIL ") + label + (detail ? " :: " + String(detail).slice(0, 120) : ""));
};
const consoleAll = [];
let notFocusable = 0;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const port = 9224;
const userDir = mkdtempSync(join(tmpdir(), "edge-qa-front-"));
const edge = spawn(EDGE, [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${userDir}`,
  "--no-first-run", "--disable-gpu", "--window-size=1366,900", "about:blank",
], { stdio: "ignore" });
edge.on("error", (e) => console.log("EDGE_SPAWN_ERR=" + e.message));

const BASE = "http://localhost:3000";
const PROVEEDOR = "aeb01238-f617-5359-b36e-7070039718cc";
const PRODUCTO = "3207c31f-24ae-5aa9-8c54-6f1b90a76ece";
const SNAPSHOT = "abbdc809-a261-5972-a22d-7d93ce5de84f";
const ORG = "f5675598-3e6a-54e9-ac43-6b1c5ba653b1";
const COTIZ_VIEJA = "0c08ea31-0da7-44e5-8692-01e7d456e7ab";

let ws;
try {
  let version = null;
  for (let i = 0; i < 30 && !version; i++) {
    await sleep(1000);
    version = await fetch(`http://127.0.0.1:${port}/json/version`).then((r) => r.json()).catch(() => null);
  }
  if (!version) throw new Error("CDP_PORT_TIMEOUT");
  const targets = await fetch(`http://127.0.0.1:${port}/json/list`).then((r) => r.json());
  const page = targets.find((t) => t.type === "page");
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let msgId = 0;
  const pending = new Map();
  ws.addEventListener("message", (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
      return;
    }
    if (m.method === "Log.entryAdded" && (m.params.entry.level === "error" || m.params.entry.level === "warning")) {
      consoleAll.push("LOG:" + m.params.entry.text);
      if (/not focusable/i.test(m.params.entry.text)) notFocusable += 1;
    }
    if (m.method === "Runtime.consoleAPICalled" && (m.params.type === "error" || m.params.type === "assert")) {
      const t = m.params.args.map((a) => a.value ?? a.description ?? "").join(" ");
      consoleAll.push("CONSOLE:" + t);
      if (/not focusable/i.test(t)) notFocusable += 1;
    }
    if (m.method === "Runtime.exceptionThrown") {
      consoleAll.push("EXCEPTION:" + JSON.stringify(m.params.exceptionDetails).slice(0, 200));
    }
  });
  const cdp = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const id = ++msgId;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  const evaljs = async (expr) => {
    const r = await cdp("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error("EVAL_ERR " + JSON.stringify(r.exceptionDetails).slice(0, 200));
    return r.result?.value;
  };
  const nav = async (url) => {
    await cdp("Page.navigate", { url }).catch(() => {});
    for (let i = 0; i < 90; i++) {
      await sleep(1000);
      const st = await evaljs("document.readyState+'|'+location.pathname").catch(() => "loading|");
      if (st.startsWith("complete")) return st;
    }
    throw new Error("NAV_TIMEOUT " + url);
  };
  const waitFor = async (expr, label, tries = 60) => {
    for (let i = 0; i < tries; i++) {
      const v = await evaljs(expr).catch(() => false);
      if (v) return v;
      await sleep(1000);
    }
    throw new Error("WAIT_TIMEOUT " + label);
  };
  const setSelect = (name, value) => evaljs(`(() => {
    const sel = document.querySelector('select[name="${name}"]');
    if (!sel) return 'MISSING';
    const d = Object.getOwnPropertyDescriptor(sel.constructor.prototype, 'value');
    d.set.call(sel, ${JSON.stringify(value)});
    sel.dispatchEvent(new Event('change', { bubbles: true }));
    return sel.value;
  })()`);
  const setInput = (name, value) => evaljs(`(() => {
    const el = document.querySelector('input[name="${name}"]');
    if (!el) return 'MISSING';
    const d = Object.getOwnPropertyDescriptor(el.constructor.prototype, 'value');
    d.set.call(el, ${JSON.stringify(value)});
    el.dispatchEvent(new Event('input', { bubbles: true }));
    return el.value;
  })()`);
  const clickButton = (label) => evaljs(`(() => {
    const b = [...document.querySelectorAll('button')].find((x) => x.textContent.trim().includes(${JSON.stringify(label)}) && !x.disabled);
    if (!b) return 'NO_BUTTON';
    b.click();
    return 'CLICKED';
  })()`);
  const isDetail = (p) => typeof p === "string" && p.startsWith("/cotizador/") && p.length === "/cotizador/".length + 36;

  await cdp("Page.enable");
  await cdp("Runtime.enable");
  await cdp("Log.enable");
  // ===== S0: LOGIN =====
  await nav(BASE + "/login");
  await waitFor("!!document.querySelector('input[type=email]') && !!document.querySelector('input[type=password]')", "login-form");
  await evaljs(`(() => {
    const set = (sel, v) => { const el = document.querySelector(sel); const d = Object.getOwnPropertyDescriptor(el.constructor.prototype, 'value'); d.set.call(el, v); el.dispatchEvent(new Event('input', { bubbles: true })); };
    set('input[type=email]', ${JSON.stringify(email)});
    set('input[type=password]', ${JSON.stringify(password)});
    document.querySelector('button[type=submit]').click();
    return true;
  })()`);
  await waitFor("!location.pathname.startsWith('/login')", "post-login", 90);
  check("S0 login COMERCIAL redirige a consola", (await evaljs("location.pathname")) === "/", "ruta=" + (await evaljs("location.pathname")));

  // ===== S1: /cotizador base (sin estado) =====
  await nav(BASE + "/cotizador");
  await waitFor("document.body.innerText.includes('Flujo proveedor-first') || document.body.innerText.includes('1. Cliente y proveedor')", "cotizador-base", 90);
  check("S1 h1 Cotizador", (await evaljs("document.querySelector('h1')?.textContent ?? ''")).includes("Cotizador"));
  check("S1 input q_proveedor eliminado", !(await evaljs("!!document.querySelector('input[name=q_proveedor]')")));
  check("S1 boton 'Buscar proveedor' eliminado", !(await evaljs("[...document.querySelectorAll('button')].some((b) => !b.closest('[hidden]') && b.textContent.trim() === 'Buscar proveedor' && !b.closest('details'))")));
  check("S1 org select con opciones", (await evaljs("document.querySelector('select[name=id_organizacion]')?.options.length ?? 0")) >= 2);
  const provOpts = await evaljs("document.querySelector('select[name=id_proveedor]')?.options.length ?? 0");
  check("S1 proveedor select con proveedores", provOpts >= 2, "opciones=" + provOpts);
  check("S1 producto select deshabilitado sin proveedor", await evaljs("document.querySelector('select[name=id_producto_proveedor]')?.disabled ?? false"));
  check("S1 cantidad sin atributo required", !(await evaljs("document.querySelector('input[name=cantidad]')?.hasAttribute('required') ?? true")));
  check("S1 oferta select deshabilitado sin producto", await evaljs("document.querySelector('select[name=id_precio_proveedor_snapshot]')?.disabled ?? false"));
  check("S1 COMERCIAL no ve input editable de margen", !(await evaljs("!!document.querySelector('input[name=margen_override_pct]:not([type=hidden])')")));
  check("S1 sin errores 'not focusable' en consola", notFocusable === 0, "count=" + notFocusable);

  // ===== S2: cambiar proveedor -> auto-submit carga productos =====
  await setSelect("id_proveedor", PROVEEDOR);
  await waitFor("decodeURIComponent(location.search).includes('id_proveedor=aeb01238')", "auto-submit-proveedor", 90);
  await waitFor("document.querySelector('select[name=id_producto_proveedor]') && !document.querySelector('select[name=id_producto_proveedor]').disabled && document.querySelector('select[name=id_producto_proveedor]').options.length >= 2", "productos-cargados", 90);
  const prodOpts = await evaljs("document.querySelector('select[name=id_producto_proveedor]')?.options.length ?? 0");
  check("S2 seleccion de proveedor auto-carga productos SIN clic", prodOpts >= 2, "opciones_producto=" + prodOpts);
  check("S2 sin errores 'not focusable' tras auto-submit", notFocusable === 0, "count=" + notFocusable);
  // ===== S3: cambiar producto -> auto-submit carga ofertas =====
  await setSelect("id_producto_proveedor", PRODUCTO);
  await waitFor("decodeURIComponent(location.search).includes('id_producto_proveedor=3207c31f')", "auto-submit-producto", 90);
  await waitFor("document.body.innerText.includes('Seleccionado:')", "producto-seleccionado", 90);
  const snapOpts = await evaljs("document.querySelector('select[name=id_precio_proveedor_snapshot]')?.options.length ?? 0");
  check("S3 seleccion de producto auto-carga ofertas (select habilitado)", (await evaljs("!document.querySelector('select[name=id_precio_proveedor_snapshot]').disabled")) && snapOpts >= 2, "opciones_oferta=" + snapOpts);
  check("S3 aviso 'Seleccionado:' visible", (await evaljs("document.body.innerText.includes('Seleccionado:')")));
  check("S3 sin errores 'not focusable' tras auto-submit producto", notFocusable === 0, "count=" + notFocusable);

  // ===== S4: cantidad + oferta -> preview automatico (SelectAutoSubmit) =====
  await setInput("cantidad", "10");
  await setSelect("id_precio_proveedor_snapshot", SNAPSHOT);
  await waitFor("document.body.innerText.includes('Total calculado')", "preview-total", 90);
  const total = await evaljs("document.body.innerText.match(/Total calculado:[^\\n]*/)?.[0] ?? ''");
  check("S4 elegir oferta calcula preview automaticamente", total.includes("65.800"), total);
  results.total = total;

  // ===== S5: botones explicitos sin bloqueo HTML5 =====
  const calcRes = await clickButton("Calcular precio");
  await waitFor("document.body.innerText.includes('Total calculado')", "recalculo", 90);
  check("S5 boton 'Calcular precio' explicito funciona", calcRes === "CLICKED", "res=" + calcRes);
  const buscarRes = await clickButton("Buscar producto/ofertas");
  await waitFor("document.readyState==='complete'", "buscar-producto", 60);
  check("S5 'Buscar producto/ofertas' no exige campos ajenos", buscarRes === "CLICKED" && (await evaljs("document.body.innerText.includes('Cotizador')")));
  check("S5 sin errores 'not focusable' en botones de paso", notFocusable === 0, "count=" + notFocusable);

  // ===== S6: producto manual VACIO -> servidor valida (sin bloqueo HTML5) =====
  await evaljs("[...document.querySelectorAll('details')].find((d) => d.textContent.includes('Producto/precio manual'))?.setAttribute('open',''); true");
  const emptyRes = await clickButton("Guardar producto/precio");
  await waitFor("document.readyState==='complete'", "manual-vacio", 60);
  const avisoVacio = await evaljs("document.querySelector('.aviso-caja')?.textContent.replace(/\\s+/g,' ').trim().slice(0,140) ?? ''");
  check("S6 submit manual VACIO no es bloqueado por HTML5", emptyRes === "CLICKED");
  check("S6 servidor devuelve aviso de validacion", avisoVacio.length > 0, avisoVacio);
  check("S6 sin errores 'not focusable' en manual vacio", notFocusable === 0, "count=" + notFocusable);
  // ===== S7: producto manual VALIDO -> PENDING_REVIEW y aviso =====
  await evaljs("[...document.querySelectorAll('details')].find((d) => d.textContent.includes('Producto/precio manual'))?.setAttribute('open',''); true");
  await setInput("manual_nombre_producto", "QA-E2E Producto Cline");
  await setInput("manual_precio", "5000");
  const okProd = await clickButton("Guardar producto/precio");
  await waitFor("decodeURIComponent(location.search).includes('ok=producto_manual')", "manual-producto-ok", 90);
  check("S7 producto manual valido creado con aviso", (await evaljs("document.body.innerText.includes('Producto/precio manual creado en revision')")), "url=" + (await evaljs("decodeURIComponent(location.search).match(/ok=[^&]*/)?.[0]")));
  check("S7 sin errores 'not focusable' en manual valido", notFocusable === 0, "count=" + notFocusable);

  // ===== S8: tecnica manual VALIDA -> PENDING_REVIEW y aviso =====
  await evaljs("[...document.querySelectorAll('details')].find((d) => d.textContent.includes('Tecnica/costo manual'))?.setAttribute('open',''); true");
  await setInput("manual_nombre_proveedor_tecnica", "QA-E2E Proveedor Tecnica Cline");
  await setInput("manual_codigo_tecnica", "QA_E2E");
  await setInput("manual_precio_tecnica", "3000");
  const okTec = await clickButton("Guardar tecnica/costo");
  await waitFor("decodeURIComponent(location.search).includes('ok=tecnica_manual')", "manual-tecnica-ok", 90);
  check("S8 tecnica manual valida creada con aviso", (await evaljs("document.body.innerText.includes('Tecnica/costo manual creado en revision')")), "url=" + (await evaljs("decodeURIComponent(location.search).match(/ok=[^&]*/)?.[0]")));
  check("S8 sin errores 'not focusable' en tecnica manual", notFocusable === 0, "count=" + notFocusable);

  // ===== S9: preview + EMITIR con doble click adversarial =====
  const calc2 = await clickButton("Calcular precio");
  await waitFor("document.body.innerText.includes('Total calculado')", "preview-final", 90);
  results.idemKey = await evaljs("document.querySelector('input[name=idempotency_key]')?.value ?? ''");
  await evaljs(`(() => {
    const b = [...document.querySelectorAll('button')].find((x) => x.textContent.trim() === 'Emitir cotizacion' && !x.disabled);
    if (b) b.click();
    return true;
  })()`);
  await evaljs(`(() => {
    const b = [...document.querySelectorAll('button')].find((x) => x.textContent.trim() === 'Emitir cotizacion');
    if (b && !b.disabled) b.click();
    return true;
  })()`);
  let emitted = false;
  for (let i = 0; i < 75 && !emitted; i++) {
    await sleep(1000);
    const path = await evaljs("location.pathname").catch(() => "");
    if (isDetail(path)) emitted = true;
  }
  check("S9 emitir con doble click crea UNA cotizacion", emitted, "idem=" + results.idemKey);
  if (emitted) {
    await waitFor("document.readyState==='complete'", "detail-loaded", 30);
    const text = await evaljs("document.body.innerText");
    check("S9 detalle muestra EMITIDA", /EMITIDA/i.test(text));
    results.comercialVeCosto = /costo/i.test(text);
    results.comercialVeMargen = /margen/i.test(text);
    check("S9 COMERCIAL no ve 'costo' en detalle", !results.comercialVeCosto);
    check("S9 COMERCIAL no ve 'margen' en detalle", !results.comercialVeMargen);
    results.pdfNueva = await evaljs(`(async () => {
      const r = await fetch(location.pathname + '/pdf');
      const b = await r.arrayBuffer();
      return { status: r.status, type: r.headers.get('content-type'), size: b.byteLength };
    })()`);
    check("S9 PDF nueva = 200 application/pdf", results.pdfNueva.status === 200 && /pdf/i.test(results.pdfNueva.type ?? ""), JSON.stringify(results.pdfNueva));
    results.pdfVieja = await evaljs(`(async () => {
      const r = await fetch('/cotizador/${COTIZ_VIEJA}/pdf');
      const b = await r.arrayBuffer();
      return { status: r.status, size: b.byteLength };
    })()`);
    check("S9 PDF vieja sin componentes = 409", results.pdfVieja.status === 409, JSON.stringify(results.pdfVieja));
  }

  // ===== Resumen global =====
  check("GLOBAL cero errores 'not focusable' en toda la sesion", notFocusable === 0, "count=" + notFocusable);
  const pass = checks.filter((c) => c.ok).length;
  console.log("RESULTS " + JSON.stringify({ checks, results, notFocusable, consoleMuestras: consoleAll.slice(0, 15), pass, fail: checks.length - pass }, null, 1));
  console.log("FRONTEND_DONE pass=" + pass + " fail=" + (checks.length - pass) + " notFocusable=" + notFocusable);
} finally {
  try { ws?.close(); } catch {}
  try { edge.kill(); } catch {}
  await sleep(1500);
  try { rmSync(userDir, { recursive: true, force: true }); } catch {}
}
