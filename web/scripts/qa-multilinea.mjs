/**
 * QA E2E real (Playwright + chromium) de los 6 casos de validacion del ajuste
 * multipack / multilinea / PDF de cotizacion.
 *
 * Corre contra el dev server en http://localhost:3000 apuntando a STAGING.
 * No usa la service role: entra por /login como cualquier usuario.
 *
 * Uso: node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON scripts/qa-multilinea.mjs
 */
import { chromium } from "playwright";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { inflateSync } from "node:zlib";

const BASE = "http://localhost:3000";
const EMAIL = process.env.QA_EMAIL;
if (!EMAIL) throw new Error("Configura QA_EMAIL para ejecutar esta prueba.");
const PASSWORD = process.env.QA_PASSWORD;
if (!PASSWORD) throw new Error("Configura QA_PASSWORD para ejecutar esta prueba.");
const SALIDA = join(process.cwd(), "qa-capturas-cotizador-multipack-pdf");
mkdirSync(SALIDA, { recursive: true });

// Fixture multipack: STAGING no tiene NINGUN snapshot con unidad_compra='PACK'
// (934 snapshots, todos NULL), incluido el SY-SGB3 real. Se registra por la via
// que el propio producto ofrece para eso -alta manual de producto/precio de
// proveedor, que queda PENDING_REVIEW- replicando el caso del enunciado.
const PROVEEDOR_QA = "QA MULTIPACK FIXTURE";
const PRODUCTO_PACK = "CAJA SUBLIMABLE DULCE PAQUETE X 10 UNIDADES (QA SY-SGB3)";
const PRODUCTO_UNIT = "MUG BLANCO 11 OZ QA UNIDAD";
const ORG_TEST = "ASOCIACION MUTUAL BURSATIL ASOBURSATIL";
const COTIZACIONES_PREVIAS = [
  ["146", "a7ad28e9-23d8-4caf-8e18-59798ff972c4"],
  ["145", "db4f1ff1-b299-4f0d-a426-8514cde5f6ef"],
];

const checks = [];
const check = (label, ok, detalle) => {
  checks.push({ label, ok: !!ok, detalle: String(detalle ?? "") });
  console.log((ok ? "PASS " : "FAIL ") + label + (detalle ? " :: " + detalle : ""));
};

const consolaErrores = [];
const paginaErrores = [];
const httpErrores = [];

/**
 * Extrae el texto visible de un PDF de @react-pdf.
 * pdfkit escribe el contenido en un stream Flate y el texto como arreglos
 * `[<hex> kern <hex>] TJ` (fuente subseteada) o `(literal) Tj`. Se cubren los
 * dos casos: sin esto, el PDF "pasa" cualquier assert por texto vacio.
 */
const textoPdf = (buffer) => {
  const partes = [];
  const bin = buffer.toString("latin1");
  const re = /stream\r?\n/g;
  let m;
  while ((m = re.exec(bin)) !== null) {
    const inicio = m.index + m[0].length;
    const fin = bin.indexOf("endstream", inicio);
    if (fin < 0) continue;
    const crudo = Buffer.from(bin.slice(inicio, fin), "latin1");
    let texto;
    try {
      texto = inflateSync(crudo).toString("latin1");
    } catch {
      continue;
    }
    for (const t of texto.matchAll(/\[((?:[^\]])*)\]\s*TJ/g)) {
      let frase = "";
      for (const h of t[1].matchAll(/<([0-9a-fA-F]*)>/g)) {
        frase += Buffer.from(h[1], "hex").toString("latin1");
      }
      for (const s of t[1].matchAll(/\(((?:\\.|[^()\\])*)\)/g)) {
        frase += s[1].replace(/\\([()\\])/g, "$1");
      }
      if (frase) partes.push(frase);
    }
    for (const t of texto.matchAll(/<([0-9a-fA-F]+)>\s*Tj/g)) {
      partes.push(Buffer.from(t[1], "hex").toString("latin1"));
    }
    for (const t of texto.matchAll(/\(((?:\\.|[^()\\])*)\)\s*Tj/g)) {
      partes.push(t[1].replace(/\\([()\\])/g, "$1"));
    }
  }
  return partes.join(" ");
};

const navegador = await chromium.launch({ headless: true });
const contexto = await navegador.newContext({ viewport: { width: 1440, height: 1000 } });
const page = await contexto.newPage();

page.on("console", (msg) => {
  if (msg.type() === "error") consolaErrores.push(msg.text());
});
page.on("pageerror", (err) => paginaErrores.push(String(err)));
page.on("response", (r) => {
  if (r.status() >= 400 && !r.url().includes("favicon")) {
    httpErrores.push(`${r.status()} ${r.url()}`);
  }
});

const foto = (n) => page.screenshot({ path: join(SALIDA, n), fullPage: true });

try {
  // ── LOGIN ───────────────────────────────────────────────────────────
  await page.goto(`${BASE}/login`, { waitUntil: "networkidle" });
  await page.fill('input[name="email"]', EMAIL);
  await page.fill('input[name="password"]', PASSWORD);
  await Promise.all([
    page.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 30000 }),
    page.click('button[type="submit"]'),
  ]);
  check("login ADMIN", !page.url().includes("/login"), page.url());

  await page.goto(`${BASE}/cotizador`, { waitUntil: "networkidle" });
  await page.waitForSelector('[data-testid="calc-linea"]');
  await foto("00-cotizador-inicial.png");

  // ── FIXTURE MULTIPACK (alta manual, feature del propio producto) ─────
  const abrirDetalles = async () => {
    await page.evaluate(() => {
      document.querySelectorAll("details").forEach((d) => {
        d.open = true;
      });
    });
    await page.waitForTimeout(300);
  };

  /** Lee del selector de la calculadora el proveedor QA y cuantos productos tiene. */
  const leerProveedorQA = async () =>
    page.evaluate((nombre) => {
      const op = Array.from(
        document.querySelectorAll('[data-testid="calc-linea-proveedor"] option'),
      ).find((o) => (o.textContent ?? "").includes(nombre));
      if (!op) return null;
      const m = (op.textContent ?? "").match(/\((\d+)\)\s*$/);
      return { id: op.value, productos: m ? Number(m[1]) : 0 };
    }, PROVEEDOR_QA);

  const altaManual = async (nombre, sku, precio, unidad, pack) => {
    await abrirDetalles();
    await page.waitForSelector('input[name="manual_nombre_producto"]', { state: "visible" });
    await page.fill('input[name="manual_nombre_proveedor"]', PROVEEDOR_QA);
    await page.fill('input[name="manual_nombre_producto"]', nombre);
    await page.fill('input[name="manual_sku_proveedor"]', sku);
    await page.fill('input[name="manual_categoria"]', "QA fixture");
    await page.fill('input[name="manual_precio"]', String(precio));
    await page.selectOption('select[name="manual_unidad_compra"]', unidad);
    if (pack) await page.fill('input[name="manual_cantidad_pack"]', String(pack));
    await page.fill(
      'input[name="manual_notas"]',
      "Fixture de QA para validar multipack en el cotizador. No es un precio real de proveedor.",
    );
    await Promise.all([
      page.waitForURL(/ok=producto_manual|error=/, { timeout: 30000 }),
      page.click('button:has-text("Guardar producto/precio")'),
    ]);
    await page.waitForLoadState("networkidle");
    return page.url();
  };

  let infoQA = await leerProveedorQA();

  if (!infoQA) {
    const u1 = await altaManual(PRODUCTO_PACK, "QA-SY-SGB3", 18000, "PACK", 10);
    check("alta manual producto PACK x10 a $18.000", u1.includes("ok=producto_manual"), u1.slice(0, 120));
    await page.goto(`${BASE}/cotizador`, { waitUntil: "networkidle" });
    infoQA = await leerProveedorQA();
  } else {
    check("fixture multipack ya existia en STAGING", true, `${PROVEEDOR_QA} (${infoQA.productos})`);
  }

  if (infoQA && infoQA.productos < 2) {
    // Con id_proveedor en la URL, el hidden del formulario reusa el proveedor
    // ya creado (la funcion crea uno nuevo si solo recibe el nombre).
    await page.goto(`${BASE}/cotizador?modo=proveedor&id_proveedor=${infoQA.id}`, {
      waitUntil: "networkidle",
    });
    const u2 = await altaManual(PRODUCTO_UNIT, "QA-MUG-UNIT", 9500, "UNIT", null);
    check("alta manual producto UNIT a $9.500", u2.includes("ok=producto_manual"), u2.slice(0, 120));
  }

  // ── CALCULADORA: multipack ──────────────────────────────────────────
  await page.goto(`${BASE}/cotizador`, { waitUntil: "networkidle" });
  await page.waitForSelector('[data-testid="calc-linea"]');

  const elegirProducto = async (indice, textoProducto) => {
    const linea = page.locator('[data-testid="calc-linea"]').nth(indice);
    const opciones = await linea
      .locator('[data-testid="calc-linea-proveedor"] option')
      .allTextContents();
    const opcion = opciones.find((o) => o.includes(PROVEEDOR_QA));
    if (!opcion) throw new Error("PROVEEDOR_QA_NO_ESTA_EN_EL_SELECTOR");
    await linea.locator('[data-testid="calc-linea-proveedor"]').selectOption({ label: opcion });
    await page.waitForTimeout(1200);
    await linea.locator('[data-testid="calc-linea-producto"]').click();
    await linea.locator('[data-testid="calc-linea-producto"]').fill(textoProducto.slice(0, 20));
    await page.waitForTimeout(1500);
    const opcionProducto = linea
      .locator('[data-testid="calc-linea-opcion"]')
      .filter({ hasText: textoProducto.slice(0, 25) })
      .first();
    await opcionProducto.waitFor({ timeout: 15000 });
    await opcionProducto.click();
    await page.waitForTimeout(1200);
    return linea;
  };

  const linea1 = await elegirProducto(0, PRODUCTO_PACK);

  const leerLinea = async (linea) => {
    const det = linea.locator('[data-testid="calc-linea-detalle"]');
    const und = linea.locator('[data-testid="calc-linea-unidades-totales"]');
    return {
      etiquetaCantidad: await linea
        .locator('[data-testid="calc-linea-cantidad"]')
        .evaluate((el) => el.parentElement?.querySelector(".lbl")?.textContent?.trim() ?? ""),
      unidades: Number(await und.getAttribute("data-unidades")),
      presentaciones: Number(await und.getAttribute("data-presentaciones")),
      porPresentacion: Number(await und.getAttribute("data-por-presentacion")),
      costoUnitario: Number(await det.getAttribute("data-costo-unitario")),
      subtotal: Number(await det.getAttribute("data-subtotal")),
      textoUnidades: (await und.innerText()).replace(/\s+/g, " "),
    };
  };

  // CASO 1 -------------------------------------------------------------
  await linea1.locator('[data-testid="calc-linea-cantidad"]').fill("1");
  await page.waitForTimeout(600);
  let l1 = await leerLinea(linea1);
  const presentacion1 = (
    await linea1.locator('[data-testid="calc-linea-presentacion"]').innerText()
  ).replace(/\s+/g, " ");
  check(
    "CASO 1 · etiqueta del campo dice 'Cantidad de paquetes'",
    /Cantidad de paquetes/i.test(l1.etiquetaCantidad),
    l1.etiquetaCantidad,
  );
  check("CASO 1 · unidades totales = 10", l1.unidades === 10, `unidades=${l1.unidades}`);
  check("CASO 1 · presentaciones = 1", l1.presentaciones === 1, `presentaciones=${l1.presentaciones}`);
  check(
    "CASO 1 · costo base de linea = $18.000",
    l1.costoUnitario * l1.unidades === 18000 && l1.subtotal === 18000,
    `costo_unit=${l1.costoUnitario} x ${l1.unidades} = ${l1.costoUnitario * l1.unidades}; subtotal=${l1.subtotal}`,
  );
  check(
    "CASO 1 · muestra 'Unidades totales' como dato derivado",
    /Unidades totales/i.test(l1.textoUnidades),
    l1.textoUnidades,
  );
  check(
    "CASO 1 · muestra precio proveedor por paquete y costo unitario",
    /paquete x 10/i.test(presentacion1) && /1\.800/.test(presentacion1),
    presentacion1.slice(0, 160),
  );
  await foto("01-caso1-multipack-cantidad-1.png");

  // CASO 2 -------------------------------------------------------------
  await linea1.locator('[data-testid="calc-linea-cantidad"]').fill("3");
  await page.waitForTimeout(600);
  l1 = await leerLinea(linea1);
  const base3 = l1.costoUnitario * l1.unidades;
  check("CASO 2 · unidades totales = 30", l1.unidades === 30, `unidades=${l1.unidades}`);
  check("CASO 2 · costo base de linea = $54.000", base3 === 54000, `base=${base3}`);
  check("CASO 2 · NO da $5.400", base3 !== 5400, `base=${base3}`);
  await foto("02-caso2-multipack-cantidad-3.png");

  // CASO 3 -------------------------------------------------------------
  await page.click('[data-testid="calc-agregar-producto"]');
  await page.waitForTimeout(400);
  const linea2 = await elegirProducto(1, PRODUCTO_UNIT);
  await linea2.locator('[data-testid="calc-linea-cantidad"]').fill("5");
  await page.waitForTimeout(600);
  const l2 = await leerLinea(linea2);
  check(
    "CASO 3 · producto UNIT conserva la etiqueta 'Cantidad de este producto'",
    /Cantidad de este producto/i.test(l2.etiquetaCantidad),
    l2.etiquetaCantidad,
  );
  check("CASO 3 · unidades = cantidad digitada (5)", l2.unidades === 5, `unidades=${l2.unidades}`);
  check(
    "CASO 3 · costo base = 5 x $9.500 = $47.500",
    l2.costoUnitario * l2.unidades === 47500,
    `base=${l2.costoUnitario * l2.unidades}`,
  );
  await foto("03-caso3-producto-individual.png");

  // ── CASO 4: emitir la cotizacion real de 2 lineas ───────────────────
  const problemasAntes = await page
    .locator('[data-testid="calc-emitir-problemas"]')
    .innerText()
    .catch(() => "");
  check(
    "CASO 4 · sin cliente elegido el boton avisa y no deja emitir",
    /cliente/i.test(problemasAntes) &&
      (await page.locator('[data-testid="calc-emitir-boton"]').isDisabled()),
    problemasAntes.replace(/\s+/g, " ").slice(0, 140),
  );
  await foto("04-caso4-validacion-sin-cliente.png");

  const opcionesOrg = await page
    .locator('[data-testid="calc-organizacion"] option')
    .allTextContents();
  const opcionOrg = opcionesOrg.find((o) => o.includes(ORG_TEST));
  if (!opcionOrg) throw new Error("ORG_TEST_NO_ESTA_EN_EL_SELECTOR");
  await page.selectOption('[data-testid="calc-organizacion"]', { label: opcionOrg });
  await page.fill('[data-testid="calc-notas"]', "QA multilinea: atencion a Compras.");
  await page.waitForTimeout(400);
  await foto("05-caso4-listo-para-emitir.png");

  const habilitado = await page.locator('[data-testid="calc-emitir-boton"]').isEnabled();
  check("CASO 4 · con cliente y lineas el boton se habilita", habilitado, `enabled=${habilitado}`);

  await Promise.all([
    page.waitForURL(/\/cotizador\/[0-9a-f-]{36}$/, { timeout: 60000 }),
    page.click('[data-testid="calc-emitir-boton"]'),
  ]);
  await page.waitForLoadState("networkidle");
  const urlCotizacion = page.url();
  const idCotizacion = urlCotizacion.split("/").pop();
  check("CASO 4 · redirige al detalle de la cotizacion", /[0-9a-f-]{36}$/.test(idCotizacion), urlCotizacion);

  const filas = page.locator('[data-testid="detalle-linea"]');
  await filas.first().waitFor({ timeout: 20000 });
  const nFilas = await filas.count();
  check("CASO 4 · el detalle muestra 2 lineas", nFilas === 2, `filas=${nFilas}`);

  const textoFila1 = (await filas.nth(0).innerText()).replace(/\s+/g, " ");
  const textoFila2 = (await filas.nth(1).innerText()).replace(/\s+/g, " ");
  check(
    "CASO 4 · linea 1 = pack (presentacion, 3 paquetes, 30 unidades)",
    /Paquete x 10/i.test(textoFila1) && /\b3\b/.test(textoFila1) && /\b30\b/.test(textoFila1),
    textoFila1.slice(0, 160),
  );
  check(
    "CASO 4 · linea 2 = unidad (5 unidades)",
    /Unidad/i.test(textoFila2) && /\b5\b/.test(textoFila2),
    textoFila2.slice(0, 160),
  );
  await foto("06-caso4-detalle-cotizacion.png");

  // ── CASO 5: PDF de cliente ──────────────────────────────────────────
  const resPdf = await page.request.get(`${BASE}/cotizador/${idCotizacion}/pdf`);
  const bufPdf = Buffer.from(await resPdf.body());
  writeFileSync(join(SALIDA, "07-caso5-cotizacion-cliente.pdf"), bufPdf);
  check(
    "CASO 5 · el PDF responde 200 application/pdf",
    resPdf.status() === 200 && (resPdf.headers()["content-type"] ?? "").includes("pdf"),
    `${resPdf.status()} ${resPdf.headers()["content-type"]} ${bufPdf.length}B`,
  );

  const texto = textoPdf(bufPdf);
  writeFileSync(join(SALIDA, "07-caso5-texto-extraido.txt"), texto);
  check("CASO 5 · el PDF dice COTIZACION", /COTIZACION/i.test(texto), texto.slice(0, 80));
  check("CASO 5 · el PDF trae los datos del cliente", texto.includes("ASOBURSATIL"), "cliente");
  check(
    "CASO 5 · el PDF trae la presentacion multipack y las unidades",
    /Paquete x 10/i.test(texto) && /\b30\b/.test(texto),
    "linea pack",
  );
  check("CASO 5 · el PDF trae las 2 lineas", /MUG BLANCO/i.test(texto), "linea unit");
  check("CASO 5 · el PDF trae Subtotal y Total", /Subtotal/i.test(texto) && /Total/i.test(texto), "resumen");
  const prohibidos = ["Margen", "margen", "Costo", "costo", "Ganancia", "ganancia", "Proveedor", "proveedor", "QA MULTIPACK FIXTURE", "Rentabilidad"];
  const filtrados = prohibidos.filter((p) => texto.includes(p));
  check(
    "CASO 5 · el PDF NO expone costo, margen, ganancia ni proveedor",
    filtrados.length === 0,
    filtrados.join(", ") || "ninguno",
  );

  await page.goto(`${BASE}/cotizador/${idCotizacion}`, { waitUntil: "networkidle" });
  await foto("08-caso5-detalle-con-boton-pdf.png");

  // ── CASO 6: no romper lo existente ──────────────────────────────────
  for (const [numero, idViejo] of COTIZACIONES_PREVIAS) {
    await page.goto(`${BASE}/cotizador/${idViejo}`, { waitUntil: "networkidle" });
    const titulo = await page.locator("h1").innerText();
    const filasViejas = await page.locator('[data-testid="detalle-linea"]').count();
    check(
      `CASO 6 · cotizacion #${numero} previa sigue abriendo con su linea`,
      titulo.includes(numero) && filasViejas === 1,
      `${titulo} filas=${filasViejas}`,
    );
    const pdfViejo = await page.request.get(`${BASE}/cotizador/${idViejo}/pdf`);
    const bufViejo = Buffer.from(await pdfViejo.body());
    check(
      `CASO 6 · PDF de la cotizacion #${numero} sigue generandose`,
      pdfViejo.status() === 200 && bufViejo.length > 1000,
      `${pdfViejo.status()} ${bufViejo.length}B`,
    );
    writeFileSync(join(SALIDA, `09-caso6-cotizacion-${numero}.pdf`), bufViejo);
    await foto(`09-caso6-cotizacion-${numero}.png`);
  }

  // ── PANTALLAS DE PROVEEDOR / PRODUCTO PROVEEDOR ─────────────────────
  if (infoQA) {
    await page.goto(`${BASE}/proveedores/${infoQA.id}`, { waitUntil: "networkidle" });
    const tabla = (await page.locator("table").innerText()).replace(/\s+/g, " ");
    check(
      "PROVEEDOR · la tabla muestra precio por paquete, contenido y costo unitario",
      /Precio proveedor/i.test(tabla) &&
        /Contenido/i.test(tabla) &&
        /Costo unitario interno/i.test(tabla) &&
        /paquete/i.test(tabla) &&
        /1\.800/.test(tabla),
      tabla.slice(0, 220),
    );
    await foto("10-proveedor-lista-productos.png");

    const enlaceProducto = page.locator("a").filter({ hasText: "CAJA SUBLIMABLE" }).first();
    await enlaceProducto.click();
    await page.waitForLoadState("networkidle");
    const resumen = (
      await page.locator('[data-testid="producto-precio-resumen"]').innerText()
    ).replace(/\s+/g, " ");
    check(
      "PRODUCTO PROVEEDOR · ficha con precio/paquete + contenido + costo unitario",
      /Precio proveedor/i.test(resumen) &&
        /\$18\.000 \/ paquete/i.test(resumen) &&
        /Contenido/i.test(resumen) &&
        /10 unidades/i.test(resumen) &&
        /Costo unitario interno/i.test(resumen) &&
        /\$1\.800 \/ unidad/i.test(resumen),
      resumen.slice(0, 240),
    );
    await foto("11-producto-proveedor-ficha.png");
  } else {
    check("PROVEEDOR · fixture disponible", false, "no se encontro el proveedor QA");
  }
} catch (e) {
  check("EJECUCION SIN EXCEPCIONES", false, String(e).slice(0, 400));
  await foto("99-error.png").catch(() => {});
} finally {
  check("consola del navegador sin errores JS", consolaErrores.length === 0, consolaErrores.slice(0, 5).join(" | "));
  check("sin excepciones no capturadas en la pagina", paginaErrores.length === 0, paginaErrores.slice(0, 5).join(" | "));
  check(
    "sin respuestas HTTP >= 400",
    httpErrores.length === 0,
    httpErrores.slice(0, 5).join(" | "),
  );

  const fallos = checks.filter((c) => !c.ok);
  const resumen =
    checks.map((c) => `${c.ok ? "PASS" : "FAIL"}\t${c.label}\t${c.detalle}`).join("\n") +
    `\n\nTOTAL=${checks.length} PASS=${checks.length - fallos.length} FAIL=${fallos.length}\n`;
  writeFileSync(join(SALIDA, "resultado-qa.txt"), resumen);
  console.log("\n" + `TOTAL=${checks.length} PASS=${checks.length - fallos.length} FAIL=${fallos.length}`);
  console.log("CAPTURAS=" + SALIDA);
  await navegador.close();
  process.exit(fallos.length === 0 ? 0 : 1);
}
