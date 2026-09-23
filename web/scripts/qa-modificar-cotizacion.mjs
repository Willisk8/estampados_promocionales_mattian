/**
 * QA E2E real (Playwright + chromium) de las tres mejoras de esta tarea:
 *
 *   1. Boton "Modificar" en /cotizador/[id] -> precarga la calculadora y emite
 *      una cotizacion NUEVA sin tocar la original.
 *   2. Precio de venta por unidad visible en cada tarjeta de producto de la
 *      calculadora visual.
 *   3. Enlaces desde /organizaciones/[id] (numero -> detalle, PDF, y "Nueva
 *      cotizacion para este cliente" con el cliente preseleccionado).
 *
 * Corre contra el dev server en http://localhost:3000 apuntando a STAGING.
 * Entra por /login como cualquier usuario; no usa la service role.
 *
 * Uso: node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON scripts/qa-modificar-cotizacion.mjs
 */
import { chromium } from "playwright";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";

const BASE = "http://localhost:3000";
const EMAIL = process.env.QA_EMAIL;
if (!EMAIL) throw new Error("Configura QA_EMAIL para ejecutar esta prueba.");
const PASSWORD = process.env.QA_PASSWORD;
if (!PASSWORD) throw new Error("Configura QA_PASSWORD para ejecutar esta prueba.");
const SALIDA = join(process.cwd(), "qa-capturas-modificar-cotizacion");
mkdirSync(SALIDA, { recursive: true });

// Cotizacion #145: flujo viejo (una linea), SIN los costos globales inventados
// que contaminaron #150/#152-154. Es la que pide el enunciado para probar.
const COT_145 = "db4f1ff1-b299-4f0d-a426-8514cde5f6ef";
const ORG_145 = "f5675598-3e6a-54e9-ac43-6b1c5ba653b1";

const checks = [];
const check = (label, ok, detalle) => {
  checks.push({ label, ok: !!ok, detalle: String(detalle ?? "") });
  console.log((ok ? "PASS " : "FAIL ") + label + (detalle ? " :: " + detalle : ""));
};

const consolaErrores = [];
const paginaErrores = [];

// ── lectura directa a STAGING para verificar inmutabilidad ────────────
const readEnv = (name) => {
  const txt = readFileSync(join(process.cwd(), "..", ".env.staging"), "utf8");
  const line = txt.split(/\r?\n/).find((l) => l.startsWith(name + "="));
  return line ? line.slice(name.length + 1).trim() : null;
};
const SUPA = readEnv("SUPABASE_URL");
const ANON = readEnv("SUPABASE_ANON_KEY");
const tokenResp = await fetch(`${SUPA}/auth/v1/token?grant_type=password`, {
  method: "POST",
  headers: { apikey: ANON, "content-type": "application/json" },
  body: JSON.stringify({ email: EMAIL, password: PASSWORD }),
});
const TOKEN = (await tokenResp.json()).access_token;
const rest = async (path) => {
  const r = await fetch(`${SUPA}/rest/v1/${path}`, {
    headers: { apikey: ANON, Authorization: `Bearer ${TOKEN}` },
  });
  return r.json();
};

const instantanea145 = async () =>
  rest(
    `cotizacion?id_cotizacion=eq.${COT_145}&select=numero,total,estado,notas,updated_at,id_organizacion`,
  );
const items145 = async () =>
  rest(
    `cotizacion_item?id_cotizacion=eq.${COT_145}&select=id_cotizacion_item,cantidad,precio_unitario,subtotal&order=id_cotizacion_item`,
  );

const antesCot = await instantanea145();
const antesItems = await items145();
console.log("ANTES #145:", JSON.stringify(antesCot));

const navegador = await chromium.launch();
const contexto = await navegador.newContext({ viewport: { width: 1440, height: 1000 } });
const pagina = await contexto.newPage();

pagina.on("console", (m) => {
  if (m.type() === "error") consolaErrores.push(m.text());
});
pagina.on("pageerror", (e) => paginaErrores.push(String(e)));

const captura = (n) => pagina.screenshot({ path: join(SALIDA, n), fullPage: true });

try {
  // ── LOGIN ───────────────────────────────────────────────────────────
  await pagina.goto(`${BASE}/login`, { waitUntil: "networkidle" });
  await pagina.fill('input[type="email"]', EMAIL);
  await pagina.fill('input[type="password"]', PASSWORD);
  await pagina.click('button[type="submit"]');
  await pagina.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 30000 });
  check("login ADMIN", true, pagina.url());

  // ── 1) DETALLE DE #145: existe el boton Modificar ────────────────────
  await pagina.goto(`${BASE}/cotizador/${COT_145}`, { waitUntil: "networkidle" });
  await captura("01-detalle-145.png");
  const botonModificar = pagina.getByTestId("detalle-modificar");
  check("boton Modificar visible en /cotizador/[id]", await botonModificar.isVisible());
  check(
    "Modificar apunta a ?desde_cotizacion",
    (await botonModificar.getAttribute("href")) === `/cotizador?desde_cotizacion=${COT_145}`,
    await botonModificar.getAttribute("href"),
  );

  // ── 2) CLICK -> CALCULADORA PRECARGADA ───────────────────────────────
  await botonModificar.click();
  await pagina.waitForURL(`**/cotizador?desde_cotizacion=${COT_145}`, { timeout: 30000 });
  await pagina.waitForSelector('[data-testid="calc-linea"]', { timeout: 20000 });
  await captura("02-calculadora-precargada.png");

  const aviso = await pagina.getByTestId("cotizador-origen-aviso").innerText();
  check("aviso de origen menciona la #145", aviso.includes("#145"), aviso.slice(0, 120));

  const nLineas = await pagina.getByTestId("calc-linea").count();
  check("se cargo exactamente 1 linea (la que tiene la #145)", nLineas === 1, `lineas=${nLineas}`);

  const proveedorSel = await pagina.getByTestId("calc-linea-proveedor").inputValue();
  check(
    "proveedor de la linea = el de la #145",
    proveedorSel === "aeb01238-f617-5359-b36e-7070039718cc",
    proveedorSel,
  );

  const productoInput = await pagina.getByTestId("calc-linea-producto").inputValue();
  check(
    "producto de la linea = Agenda Ecologica 72",
    productoInput.includes("Agenda"),
    productoInput,
  );

  const cantidad = await pagina.getByTestId("calc-linea-cantidad").inputValue();
  check("cantidad precargada = 10", cantidad === "10", cantidad);

  const detalle = pagina.getByTestId("calc-linea-detalle");
  const costoUnit = await detalle.getAttribute("data-costo-unitario");
  check("costo unitario precargado = 4600 (el de la #145)", costoUnit === "4600", costoUnit);

  const orgSel = await pagina.getByTestId("calc-organizacion").inputValue();
  check("cliente preseleccionado = organizacion de la #145", orgSel === ORG_145, orgSel);

  const notas = await pagina.getByTestId("calc-notas").inputValue();
  check(
    "nota de referencia prellenada y editable",
    notas.includes("#145") && notas.toLowerCase().includes("ajusta"),
    notas,
  );
  const notasEditable = await pagina.getByTestId("calc-notas").isEditable();
  check("la nota NO esta forzada (es editable)", notasEditable);

  // ── 3) PRECIO DE VENTA POR UNIDAD VISIBLE EN LA LINEA ────────────────
  const precioUnitTxt = await pagina.getByTestId("calc-linea-precio-unitario").innerText();
  const precioUnitData = Number(await detalle.getAttribute("data-precio-venta-unitario"));
  const precioLineaData = Number(await detalle.getAttribute("data-precio-venta-linea"));
  check(
    "precio de venta por unidad visible en la tarjeta",
    /Precio de venta/i.test(precioUnitTxt) && /\/und/.test(precioUnitTxt),
    precioUnitTxt,
  );
  check("precio de venta unitario > 0", precioUnitData > 0, String(precioUnitData));
  // Coherencia con el reparto de ganancia por linea ya existente.
  const unidades = Number(await detalle.getAttribute("data-unidades"));
  check(
    "precio unitario * unidades == precio de la linea (+-2 por redondeo)",
    Math.abs(precioUnitData * unidades - precioLineaData) <= 2 * unidades,
    `${precioUnitData} x ${unidades} vs ${precioLineaData}`,
  );
  // Con una sola linea, el precio de la linea es el precio del pedido.
  const precioPedido = await pagina.getByTestId("calc-precio").innerText();
  const precioPedidoNum = Number(precioPedido.replace(/[^\d]/g, ""));
  check(
    "precio de la linea == precio del pedido (linea unica)",
    Math.abs(precioLineaData - precioPedidoNum) <= 2,
    `${precioLineaData} vs ${precioPedidoNum}`,
  );

  // ── 4) AJUSTAR ALGO Y EMITIR UNA COTIZACION NUEVA ────────────────────
  await pagina.getByTestId("calc-linea-cantidad").fill("12");
  await pagina.getByTestId("calc-linea-cantidad").blur();
  await pagina.waitForTimeout(400);
  const cantidad2 = await detalle.getAttribute("data-unidades");
  check("cantidad ajustada a 12 unidades", cantidad2 === "12", cantidad2);
  await captura("03-ajuste-cantidad-12.png");

  const problemas = await pagina.getByTestId("calc-emitir-problemas").count();
  check("sin problemas de emision tras precargar", problemas === 0, `bloques=${problemas}`);

  await pagina.getByTestId("calc-emitir-boton").click();
  await pagina.waitForURL(/\/cotizador\/[0-9a-f-]{36}$/, { timeout: 60000 });
  const urlNueva = pagina.url();
  const idNueva = urlNueva.split("/").pop();
  // router.push() es navegacion de cliente: la URL cambia ANTES de que se
  // pinte el detalle. Sin esperar el h1 propio de la cotizacion se lee el h1
  // de la pagina anterior ("Cotizador") y los asserts miran la pantalla vieja.
  await pagina.waitForFunction(
    () => /^Cotizaci[oó]n #\d+/.test(document.querySelector("h1")?.textContent ?? ""),
    { timeout: 30000 },
  );
  await pagina.waitForLoadState("networkidle");
  await captura("04-cotizacion-nueva-emitida.png");

  const h1 = await pagina.locator("h1").innerText();
  check("se emitio una cotizacion NUEVA con numero distinto de #145", !h1.includes("#145"), h1);
  check("el detalle muestra el numero de la cotizacion nueva", /#\d+/.test(h1), h1);
  check("la nueva cotizacion no es la #145", idNueva !== COT_145, idNueva);

  const cuerpo = await pagina.locator("body").innerText();
  check(
    "la nueva cotizacion lleva la nota de referencia a la #145",
    cuerpo.includes("#145") && /Ajusta a cotizaci/i.test(cuerpo),
    (cuerpo.match(/Ajusta a cotizaci[^\n]*/) ?? ["(no encontrada)"])[0],
  );

  const lineasNuevas = await pagina.getByTestId("detalle-linea").count();
  check("la cotizacion nueva tiene 1 linea", lineasNuevas === 1, `lineas=${lineasNuevas}`);

  // Verificacion contra la BASE, no contra el DOM: es lo que realmente quedo.
  const nuevaBd = (
    await rest(
      `cotizacion?id_cotizacion=eq.${idNueva}&select=numero,total,estado,notas,id_organizacion,canal_origen`,
    )
  )[0];
  const itemsNuevaBd = await rest(
    `cotizacion_item?id_cotizacion=eq.${idNueva}&select=cantidad,subtotal,nombre_item_snapshot`,
  );
  check("en la base: numero NUEVO distinto de 145", nuevaBd?.numero !== 145, String(nuevaBd?.numero));
  check(
    "en la base: la nota de referencia quedo persistida",
    (nuevaBd?.notas ?? "").includes("#145"),
    nuevaBd?.notas,
  );
  check(
    "en la base: mismo cliente que la #145",
    nuevaBd?.id_organizacion === ORG_145,
    nuevaBd?.id_organizacion,
  );
  check(
    "en la base: 1 item con la cantidad ajustada (12)",
    itemsNuevaBd.length === 1 && Number(itemsNuevaBd[0]?.cantidad) === 12,
    JSON.stringify(itemsNuevaBd),
  );
  check(
    "en la base: mismo producto que la #145",
    (itemsNuevaBd[0]?.nombre_item_snapshot ?? "").includes("Agenda"),
    itemsNuevaBd[0]?.nombre_item_snapshot,
  );

  // ── 5) LA ORIGINAL SIGUE INTACTA ─────────────────────────────────────
  const despuesCot = await instantanea145();
  const despuesItems = await items145();
  check(
    "cotizacion #145 sin cambios (cabecera identica)",
    JSON.stringify(antesCot) === JSON.stringify(despuesCot),
    JSON.stringify(despuesCot),
  );
  check(
    "items de la #145 sin cambios",
    JSON.stringify(antesItems) === JSON.stringify(despuesItems),
    JSON.stringify(despuesItems),
  );

  await pagina.goto(`${BASE}/cotizador/${COT_145}`, { waitUntil: "networkidle" });
  const cuerpo145 = await pagina.locator("body").innerText();
  check("la #145 sigue mostrando su total original ($65.800)", cuerpo145.includes("65.800"));
  await captura("05-145-intacta.png");

  // ── 6) PANTALLA DE LA ORGANIZACION ───────────────────────────────────
  await pagina.goto(`${BASE}/organizaciones/${ORG_145}?tab=cotizaciones`, {
    waitUntil: "networkidle",
  });
  await captura("06-organizacion-cotizaciones.png");

  const links = pagina.getByTestId("org-cotizacion-link");
  const nLinks = await links.count();
  check("el numero de cotizacion es un link", nLinks > 0, `links=${nLinks}`);

  // Debe aparecer la recien emitida (misma organizacion).
  const hrefs = [];
  for (let i = 0; i < nLinks; i += 1) hrefs.push(await links.nth(i).getAttribute("href"));
  check(
    "la cotizacion recien emitida aparece en la tabla de la organizacion",
    hrefs.includes(`/cotizador/${idNueva}`),
    hrefs.slice(0, 5).join(" | "),
  );
  check(
    "la #145 sigue listada y enlazada",
    hrefs.includes(`/cotizador/${COT_145}`),
    `${hrefs.length} links`,
  );

  const pdfLinks = await pagina.getByTestId("org-cotizacion-pdf").count();
  check("hay link PDF por fila", pdfLinks === nLinks, `pdf=${pdfLinks} filas=${nLinks}`);

  // El link del numero navega al detalle correcto.
  await links.first().click();
  await pagina.waitForURL(/\/cotizador\/[0-9a-f-]{36}$/, { timeout: 30000 });
  check("el link del numero abre el detalle de la cotizacion", true, pagina.url());
  await captura("07-detalle-desde-organizacion.png");

  // ── 7) "NUEVA COTIZACION PARA ESTE CLIENTE" ──────────────────────────
  await pagina.goto(`${BASE}/organizaciones/${ORG_145}?tab=cotizaciones`, {
    waitUntil: "networkidle",
  });
  const botonNueva = pagina.getByTestId("org-nueva-cotizacion");
  check("boton 'Nueva cotizacion para este cliente' visible", await botonNueva.isVisible());
  await botonNueva.click();
  await pagina.waitForURL(`**/cotizador?id_organizacion=${ORG_145}`, { timeout: 30000 });
  await pagina.waitForSelector('[data-testid="calc-organizacion"]', { timeout: 20000 });
  const orgPre = await pagina.getByTestId("calc-organizacion").inputValue();
  check("cliente preseleccionado en la calculadora", orgPre === ORG_145, orgPre);
  const lineasVacias = await pagina.getByTestId("calc-linea").count();
  const cantVacia = await pagina.getByTestId("calc-linea-cantidad").first().inputValue();
  check(
    "arranca con una linea vacia (no arrastra nada)",
    lineasVacias === 1 && cantVacia === "",
    `lineas=${lineasVacias} cantidad="${cantVacia}"`,
  );
  await captura("08-nueva-cotizacion-cliente-preseleccionado.png");

  // ── 8) PDF de la cotizacion nueva desde la organizacion ──────────────
  const respPdf = await pagina.request.get(`${BASE}/cotizador/${idNueva}/pdf`);
  const tipoPdf = respPdf.headers()["content-type"] ?? "";
  check(
    "el link PDF devuelve un PDF real",
    respPdf.status() === 200 && tipoPdf.includes("pdf"),
    `${respPdf.status()} ${tipoPdf}`,
  );

  // ── 9) PRECARGA DE UNA COTIZACION MULTILINEA CON COSTOS POR LINEA ────
  // #145 no ejercita ni multipack ni costos adicionales. La #150 si: 2 lineas
  // (una PACK x10 y una UNIT) y un costo por linea guardado como `costo_total`.
  // Solo se verifica la PRECARGA; no se emite, para no crear mas cotizaciones
  // con los gastos globales inventados que arrastran #150/#152-154.
  const COT_150 = "6b506b15-1e26-41da-894d-8d85680f7fea";
  await pagina.goto(`${BASE}/cotizador?desde_cotizacion=${COT_150}`, {
    waitUntil: "networkidle",
  });
  await pagina.waitForSelector('[data-testid="calc-linea"]', { timeout: 20000 });
  await captura("09-precarga-multilinea-150.png");

  const n150 = await pagina.getByTestId("calc-linea").count();
  check("la #150 precarga sus 2 lineas", n150 === 2, `lineas=${n150}`);

  const detalles150 = pagina.getByTestId("calc-linea-detalle");
  const cant0 = await pagina.getByTestId("calc-linea-cantidad").nth(0).inputValue();
  const und0 = await detalles150.nth(0).getAttribute("data-unidades");
  const pres0 = await detalles150.nth(0).getAttribute("data-presentaciones");
  check(
    "linea 1 (PACK x10): 3 paquetes = 30 unidades",
    cant0 === "3" && und0 === "30" && pres0 === "3",
    `cantidad=${cant0} unidades=${und0} presentaciones=${pres0}`,
  );

  const cant1 = await pagina.getByTestId("calc-linea-cantidad").nth(1).inputValue();
  const und1 = await detalles150.nth(1).getAttribute("data-unidades");
  check("linea 2 (UNIT): 5 unidades", cant1 === "5" && und1 === "5", `${cant1}/${und1}`);

  // Costos adicionales guardados como costo_total -> costo POR UNIDAD.
  // Linea 1: 13.584,24 / 30 und = 452,8 -> 453 ; Linea 2: 11.949,10 / 5 = 2.390.
  const nombresCosto = pagina.getByTestId("calc-linea-costo-nombre");
  const nCostos = await nombresCosto.count();
  check("se precargaron los costos adicionales de ambas lineas", nCostos === 2, `costos=${nCostos}`);
  const nombre0 = await nombresCosto.nth(0).inputValue();
  check(
    "el costo adicional conserva su descripcion original",
    nombre0.includes("Gastos generales"),
    nombre0,
  );
  const costoUnit0 = Number(await detalles150.nth(0).getAttribute("data-costo-unitario"));
  const costoUnit1 = Number(await detalles150.nth(1).getAttribute("data-costo-unitario"));
  // linea 1: 1.800 producto + 453 adicional ; linea 2: 9.500 + 2.390
  check(
    "linea 1: costo unitario = 1.800 producto + 453 adicional",
    costoUnit0 === 1800 + 453,
    String(costoUnit0),
  );
  check(
    "linea 2: costo unitario = 9.500 producto + 2.390 adicional",
    costoUnit1 === 9500 + 2390,
    String(costoUnit1),
  );
  // El importe del costo adicional se conserva (+-1 peso por unidad al redondear).
  const sub0 = Number(await detalles150.nth(0).getAttribute("data-subtotal"));
  check(
    "el importe del costo adicional se conserva tras pasarlo a por-unidad",
    Math.abs(sub0 - (1800 * 30 + 13584.24)) <= 30,
    `${sub0} vs ${1800 * 30 + 13584.24}`,
  );
  // Cada tarjeta muestra su precio de venta por unidad, tambien en multilinea.
  const precios150 = await pagina.getByTestId("calc-linea-precio-unitario").count();
  check("precio de venta por unidad en las 2 tarjetas", precios150 === 2, `tarjetas=${precios150}`);

  // ── CONSOLA ──────────────────────────────────────────────────────────
  // Se ignoran los 404 de favicon y los avisos de React DevTools.
  const realesConsola = consolaErrores.filter(
    (t) => !/favicon|Download the React DevTools/i.test(t),
  );
  check(
    "0 errores JS en consola",
    realesConsola.length === 0 && paginaErrores.length === 0,
    JSON.stringify({ consola: realesConsola, pagina: paginaErrores }),
  );

  writeFileSync(
    join(SALIDA, "resultado.json"),
    JSON.stringify(
      {
        cotizacion_origen: { id: COT_145, numero: 145 },
        cotizacion_nueva: { id: idNueva, url: urlNueva },
        antes_145: antesCot,
        despues_145: despuesCot,
        consola: realesConsola,
        errores_pagina: paginaErrores,
        checks,
      },
      null,
      2,
    ),
  );
} catch (e) {
  check("ejecucion sin excepciones", false, String(e));
  await captura("99-error.png");
} finally {
  await navegador.close();
}

const fallidos = checks.filter((c) => !c.ok);
console.log(`\n== ${checks.length - fallidos.length}/${checks.length} PASS ==`);
if (fallidos.length) {
  console.log("FALLIDOS:");
  fallidos.forEach((f) => console.log(" - " + f.label + " :: " + f.detalle));
}
console.log("Capturas en: " + SALIDA);
process.exit(fallidos.length ? 1 : 0);
