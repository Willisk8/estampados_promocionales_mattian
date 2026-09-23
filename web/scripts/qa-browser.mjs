/**
 * QA E2E con navegador real (Edge headless + CDP, sin dependencias nuevas).
 * Flujo: login -> preview proveedor-first -> emitir -> detalle -> PDF (200) -> PDF viejo (409).
 * Nunca imprime contrasenias ni cookies. Ejecutar desde web/.
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const port = 9223;
const userDir = mkdtempSync(join(tmpdir(), "edge-qa-"));
const edge = spawn(EDGE, [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${userDir}`,
  "--no-first-run", "--disable-gpu", "--window-size=1366,900", "about:blank",
], { stdio: "ignore" });
edge.on("error", (e) => console.log("EDGE_SPAWN_ERR=" + e.message));

let ws;
const results = {};
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
      const st = await evaljs("document.readyState+'|'+location.href").catch(() => "loading|");
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

  await cdp("Page.enable");
  await cdp("Runtime.enable");

  // 1) LOGIN
  await nav("http://localhost:3000/login");
  await waitFor("!!document.querySelector('input[type=email]') && !!document.querySelector('input[type=password]')", "login-form");
  await evaljs(`(() => {
    const set = (sel, v) => { const el = document.querySelector(sel); const d = Object.getOwnPropertyDescriptor(el.constructor.prototype, 'value'); d.set.call(el, v); el.dispatchEvent(new Event('input', {bubbles: true})); };
    set('input[type=email]', ${JSON.stringify(email)});
    set('input[type=password]', ${JSON.stringify(password)});
    document.querySelector('button[type=submit]').click();
    return true;
  })()`);
  await waitFor("!location.pathname.startsWith('/login')", "post-login", 90);
  results.loginUrl = await evaljs("location.pathname");
  // 2) PREVIEW proveedor-first
  const PREVIEW = "http://localhost:3000/cotizador?modo=proveedor&id_organizacion=f5675598-3e6a-54e9-ac43-6b1c5ba653b1&id_proveedor=aeb01238-f617-5359-b36e-7070039718cc&q_producto=&id_producto_proveedor=3207c31f-24ae-5aa9-8c54-6f1b90a76ece&id_precio_proveedor_snapshot=abbdc809-a261-5972-a22d-7d93ce5de84f&cantidad=10&previsualizar_proveedor=1";
  await nav(PREVIEW);
  await waitFor("document.body.innerText.includes('Total calculado')", "preview-total", 90);
  results.total = await evaljs("document.body.innerText.match(/Total calculado:[^\\n]*/)?.[0]");
  results.comercialVeInputMargenOverride = await evaljs(
    "!!document.querySelector('input[name=margen_override_pct]:not([type=hidden])')",
  );
  results.idemKey = await evaljs("document.querySelector('input[name=idempotency_key]')?.value ?? null");
  if (process.env.QA_PROBE_ONLY === "1") {
    console.log("RESULTS " + JSON.stringify(results, null, 1));
    console.log("PROBE_DONE");
    try { ws.close(); } catch {}
    try { edge.kill(); } catch {}
    process.exit(0);
  }

  // 3) EMITIR con doble click adversarial (misma idempotency_key)
  results.emitButtons = await evaljs(`(() => {
    const btns = [...document.querySelectorAll('button')].filter((b) => /Emitir cotizacion/i.test(b.textContent) && !b.disabled);
    if (btns.length) btns[0].click();
    return btns.length;
  })()`);
  results.secondClick = await evaljs(`(() => {
    const btns = [...document.querySelectorAll('button')].filter((b) => /Emitir cotizacion/i.test(b.textContent));
    if (!btns.length) return 'NO_BUTTON';
    if (btns[0].disabled) return 'DISABLED_BY_REACT';
    btns[0].click();
    return 'CLICKED_AGAIN';
  })()`);
  let emitted = false;
  for (let i = 0; i < 75 && !emitted; i++) {
    await sleep(1000);
    const path = await evaljs("location.pathname").catch(() => "");
    if (/^\/cotizador\/[0-9a-f-]{36}$/.test(path)) emitted = true;
  }
  if (emitted) {
    results.detailUrl = await evaljs("location.pathname");
    await waitFor("document.readyState==='complete'", "detail-loaded", 30);
    const text = await evaljs("document.body.innerText");
    results.detailHasEmitida = /EMITIDA|emitida/i.test(text);
    results.comercialVeCosto = /costo/i.test(text);
    results.comercialVeMargen = /margen/i.test(text);
    results.detailExtract = text.replace(/\s+/g, " ").slice(0, 400);
    // 4) PDF nueva cotizacion (esperado 200 application/pdf)
    results.pdfNueva = await evaljs(`(async () => {
      const r = await fetch(location.pathname + '/pdf');
      const b = await r.arrayBuffer();
      return { status: r.status, type: r.headers.get('content-type'), size: b.byteLength };
    })()`);

    // 5) PDF cotizacion vieja sin componentes (esperado 409)
    results.pdfVieja = await evaljs(`(async () => {
      const r = await fetch('/cotizador/0c08ea31-0da7-44e5-8692-01e7d456e7ab/pdf');
      const b = await r.arrayBuffer();
      return { status: r.status, size: b.byteLength };
    })()`);

    // 6) Negativa: COMERCIAL intenta margen_override_pct=25 (regla 073 -> debe rechazar)
    await nav(PREVIEW + "&margen_override_pct=25");
    await waitFor(
      "document.body.innerText.includes('Total calculado') || document.body.innerText.toLowerCase().includes('no se pudo')",
      "preview-override",
      90,
    );
    results.overridePreviewTotal = await evaljs(
      "document.body.innerText.match(/Total calculado:[^\\n]*/)?.[0] ?? null",
    );
    await evaljs(`(() => {
      const btns = [...document.querySelectorAll('button')].filter((b) => /Emitir cotizacion/i.test(b.textContent) && !b.disabled);
      if (btns.length) btns[0].click();
      return btns.length;
    })()`);
    results.overrideBypassed = false;
    results.overrideRejected = false;
    for (let i = 0; i < 30; i++) {
      await sleep(1000);
      const path = await evaljs("location.pathname").catch(() => "");
      if (/^[/]cotizador[/][0-9a-f-]{36}$/.test(path)) {
        results.overrideBypassed = true;
        break;
      }
      const body = await evaljs(
        "document.body.innerText.replace(/\\s+/g,' ').slice(0, 400)",
      ).catch(() => "");
      if (/No se pudo cotizar|No se pudo calcular/i.test(body)) {
        results.overrideRejected = true;
        results.overrideBodySnippet = body;
        break;
      }
    }
    if (!results.overrideBypassed && !results.overrideRejected) {
      results.overrideBodySnippet = await evaljs(
        "document.body.innerText.replace(/\\s+/g,' ').slice(0, 400)",
      ).catch(() => null);
    }
  } else {
    results.emitError = await evaljs("document.body.innerText.replace(/\\s+/g,' ').slice(0, 500)").catch(() => null);
  }
  console.log("RESULTS " + JSON.stringify(results, null, 1));
  console.log("BROWSER_E2E_DONE emitted=" + emitted);
} finally {
  try { ws?.close(); } catch {}
  try { edge.kill(); } catch {}
  await sleep(1500);
  try { rmSync(userDir, { recursive: true, force: true }); } catch {}
}
