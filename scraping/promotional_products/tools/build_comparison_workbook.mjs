import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const projectRoot = path.resolve("..");
const csvPath = path.join(projectRoot, "outputs", "catalogo_promocionales_colombia.csv");
const configPath = path.join(projectRoot, "sources.json");
const outputDir = path.join(projectRoot, "outputs", "comparativo_base_20260824");
const outputPath = path.join(outputDir, "comparativo_precios_promocionales_colombia.xlsx");

function parseCsv(text) {
  text = text.replace(/^\uFEFF/, "");
  const rows = [];
  let row = [], field = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') { row.push(field); field = ""; }
    else if (ch === '\n') { row.push(field.replace(/\r$/, "")); rows.push(row); row = []; field = ""; }
    else field += ch;
  }
  if (field || row.length) { row.push(field.replace(/\r$/, "")); rows.push(row); }
  const headers = rows.shift();
  return rows.filter(r => r.some(Boolean)).map(r => Object.fromEntries(headers.map((h, i) => [h, r[i] ?? ""])));
}

const fold = (value) => String(value ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
const num = (value) => value === "" || value == null ? null : Number(value);
function colName(index1) {
  let value = index1, name = "";
  while (value > 0) { value--; name = String.fromCharCode(65 + (value % 26)) + name; value = Math.floor(value / 26); }
  return name;
}

const familyRules = [
  ["Esferos y bolígrafos", /\b(esfero|boligrafo|lapicero)\b/],
  ["Mugs y tazas", /\b(mug|taza|pocillo|jarro)\b/],
  ["Llaveros", /\bllavero/],
  ["Agendas y libretas", /\b(agenda|libreta|cuaderno)\b/],
  ["Termos y botilitos", /\b(termo|botilito|caramanola|vaso viajero|botella)\b/],
  ["Camisetas y textiles", /\b(camiseta|polo|hoodie|buso|delantal)\b/],
  ["Gorras", /\b(gorra|cachucha)\b/],
  ["Bolsas y tulas", /\b(bolsa|tula|tote)\b/],
  ["Pad mouse", /\b(pad.?mouse|mouse.?pad)\b/],
  ["Botones e imanes", /\b(boton|iman)\b/],
  ["Identificación", /\b(portacarn|gafete|escarapela|brazalete|yoyo)\b/],
  ["Tecnología y USB", /\b(usb|memoria|cargador|power.?bank|parlante|tecnologia)\b/],
  ["Sombrillas", /\b(sombrilla|paraguas)\b/],
  ["Kits corporativos", /\b(kit|set elegante|paquete empresarial)\b/],
];

function familyFor(row) {
  const text = fold(`${row.name} ${row.subtitle} ${row.category}`);
  for (const [name, regex] of familyRules) if (regex.test(text)) return name;
  return "Otros promocionales";
}

function quantityFor(row) {
  const text = fold(`${row.name} ${row.subtitle} ${row.packaging}`);
  const patterns = [
    /\bx\s*(\d{1,4})\b/, /\b(\d{1,4})\s*(?:unidades|unidad|unds|und)\b/,
    /\bpaquete\s+(?:de|x)\s*(\d{1,4})\b/, /\bpack\s+x?\s*(\d{1,4})\b/,
  ];
  for (const regex of patterns) {
    const match = text.match(regex);
    if (match && Number(match[1]) > 0) return { quantity: Number(match[1]), method: "detectada en nombre/empaque" };
  }
  return { quantity: 1, method: "asumida 1; validar presentación" };
}

const csvText = await fs.readFile(csvPath, "utf8");
const raw = parseCsv(csvText);
const config = JSON.parse(await fs.readFile(configPath, "utf8"));

const normalized = raw.map((row, index) => {
  const quantity = quantityFor(row);
  const family = familyFor(row);
  const price = num(row.price_min);
  const comparability = quantity.method.startsWith("detectada") ? "media: cantidad detectada" : "baja: validar unidad/paquete";
  return {
    key: `${row.source_id}-${row.product_id || index + 1}`,
    family, supplier: row.supplier, product: row.name, description: row.description,
    price, quantity: quantity.quantity, quantityMethod: quantity.method,
    techniques: row.print_techniques, material: row.material, capacity: row.capacity,
    dimensions: row.size_dimensions, packaging: row.packaging, availability: row.availability,
    city: row.city, url: row.product_url, fetchedAt: row.fetched_at,
    comparability, sourceId: row.source_id, rawIndex: index,
  };
});

function bestCandidate(family, sourceIds) {
  return normalized
    .map((row, index) => ({...row, normalizedIndex: index, unitPrice: row.price == null ? Infinity : row.price / row.quantity}))
    .filter(row => row.family === family && sourceIds.includes(row.sourceId) && Number.isFinite(row.unitPrice) && eligibleForComparison(family, row.product))
    .sort((a, b) => a.unitPrice - b.unitPrice || a.product.localeCompare(b.product))[0] ?? null;
}

function eligibleForComparison(family, product) {
  const name = fold(product);
  const excludedAccessory = /\b(caja|estuche|repuesto|refill|tapa|soporte)\b/;
  const rules = {
    "Esferos y bolígrafos": /\b(esfero|boligrafo|lapicero)\b/,
    "Mugs y tazas": /\b(mug|taza|pocillo|jarro)\b/,
    "Llaveros": /\bllavero/,
    "Agendas y libretas": /\b(agenda|libreta|cuaderno)\b/,
    "Termos y botilitos": /\b(termo|botilito|caramanola|vaso viajero|botella)\b/,
    "Camisetas y textiles": /\b(camiseta|polo|hoodie|buso|delantal)\b/,
    "Gorras": /\b(gorra|cachucha)\b/,
    "Bolsas y tulas": /\b(bolsa|tula|tote)\b/,
    "Pad mouse": /\b(pad.?mouse|mouse.?pad)\b/,
    "Botones e imanes": /\b(boton|iman)\b/,
    "Identificación": /\b(portacarn|gafete|escarapela|brazalete|yoyo)\b/,
    "Tecnología y USB": /\b(memoria usb|usb\s*\d+\s*gb|cargador|power.?bank|parlante)\b/,
    "Sombrillas": /\b(sombrilla|paraguas)\b/,
    "Kits corporativos": /\b(kit corporativo|kit empresarial|set elegante|paquete empresarial)\b/,
  };
  if (!rules[family]?.test(name)) return false;
  if (["Esferos y bolígrafos", "Mugs y tazas"].includes(family) && excludedAccessory.test(name)) return false;
  if (family === "Mugs y tazas") {
    const ounces = name.match(/\b(\d+(?:[.,]\d+)?)\s*oz\b/);
    if (ounces && Number(ounces[1].replace(",", ".")) < 10) return false;
  }
  if (family === "Agendas y libretas" && /\b(colorear|ejercicios|infantil)\b/.test(name)) return false;
  if (family === "Camisetas y textiles" && /\b(alcancia|llavero|portarretrato)\b/.test(name)) return false;
  return true;
}

const integratedSources = [
  ["Tienda FLA / Grupo FLA SAS", "tienda_fla", "Bogotá", "https://tiendafla.com/", "Integrada", "Catálogo promocional y fichas detalladas"],
  ["Esferos.com / Botón Promo SAS", "esferos_com", "Bogotá", "https://esferos.com/", "Integrada", "Mayor cantidad de referencias; revisar si el precio requiere sesión comercial"],
  ["Colorisa Studio", "colorisa_studio", "Bogotá", "https://colorisastudio.com/productos", "Integrada", "Precios unitarios visibles"],
  ["Verona Studio", "verona_studio", "Bogotá", "https://veronastudio.com.co/", "Integrada", "Productos destacados con precio"],
  ["NaturalGraphic", "natural_graphic", "Bogotá", "https://naturalgraphic.com.co/sublmacion/", "Integrada", "Precios publicados; la página advierte que no incluyen IVA"],
  ["INGenios Maquinando Ideas", "ingenios_col", "Villavicencio", "https://www.ingenioscol.com/", "Integrada", "Respaldo nacional con tienda pública"],
  ["Sublifly / Sublimatic SAS", "sublifly", "Bogotá", "https://www.sublifly.co/", "Integrada", "Insumos sublimables con precio público; se excluyen máquinas, tintas y repuestos"],
];
const reviewSources = [
  ["Sublimaco", "sublimaco", "Bogotá", "https://www.sublimaco.com/", "Revisión manual", "Catálogo por cotización; la API y los mapas del sitio redirigen a /lander"],
  ["MacBrand Digital", "macbrand", "Bogotá", "https://www.macbrand.co/", "Revisión manual", "Página válida; la estructura actual no produjo filas confiables"],
  ["Láser Piente", "laser_piente", "Bogotá", "https://laserpientesas.com/material-pop", "Revisión manual", "Mugs, esferos, agendas, llaveros y técnicas; cotización"],
  ["Markmelo", "markmelo", "Colombia", "https://markmelo.com/catalogos-promocionales/", "Revisión manual", "Catálogo amplio; validar acceso a precio por referencia"],
  ["Colprinter", "colprinter", "Bogotá", "https://colprinter.com/material-pop", "Revisión manual", "Catálogo POP; precios principalmente por cotización"],
  ["MyBrand Promocionales", "mybrand", "Bogotá", "https://mybrandpromocionales.com/", "Revisión manual", "Amplias categorías y técnicas; precios por cotización"],
];

const countBySource = new Map();
for (const row of normalized) countBySource.set(row.sourceId, (countBySource.get(row.sourceId) ?? 0) + 1);

const workbook = Workbook.create();
const summary = workbook.worksheets.add("Resumen");
const comparison = workbook.worksheets.add("Comparativo");
const base = workbook.worksheets.add("Base normalizada");
const pages = workbook.worksheets.add("Páginas");
const sourceData = workbook.worksheets.add("Datos fuente");

const navy = "#17324D", blue = "#2176AE", teal = "#2A9D8F", lightBlue = "#EAF3F8";
const yellow = "#FFF4CC", green = "#E6F4EA", red = "#FDECEC", gray = "#657786", lightGray = "#F3F6F8";
const titleFormat = { fill: navy, font: { bold: true, color: "#FFFFFF", size: 18 }, verticalAlignment: "center" };
const sectionFormat = { fill: blue, font: { bold: true, color: "#FFFFFF" }, verticalAlignment: "center" };
const headerFormat = { fill: "#DCEAF2", font: { bold: true, color: navy }, verticalAlignment: "center", wrapText: true, borders: { preset: "bottom", style: "medium", color: blue } };

for (const sheet of [summary, comparison, base, pages, sourceData]) sheet.showGridLines = false;

// Datos fuente: conserva el CSV sin transformar.
const rawHeaders = Object.keys(raw[0]);
sourceData.getRangeByIndexes(0, 0, 1, rawHeaders.length).values = [rawHeaders];
for (const identifier of ["source_id", "sku"]) {
  const idx = rawHeaders.indexOf(identifier);
  if (idx >= 0) sourceData.getRangeByIndexes(1, idx, raw.length, 1).format.numberFormat = "@";
}
const productIdIndex = rawHeaders.indexOf("product_id");
if (productIdIndex >= 0) sourceData.getRangeByIndexes(1, productIdIndex, raw.length, 1).format.numberFormat = "0";
sourceData.getRangeByIndexes(1, 0, raw.length, rawHeaders.length).values = raw.map(row => rawHeaders.map(h => {
  if (["price_min", "price_max"].includes(h)) return num(row[h]);
  return row[h];
}));
sourceData.getRangeByIndexes(0, 0, 1, rawHeaders.length).format = headerFormat;
sourceData.freezePanes.freezeRows(1);
sourceData.getRangeByIndexes(0, 0, raw.length + 1, rawHeaders.length).format.font = { name: "Aptos", size: 9 };
sourceData.getRangeByIndexes(1, rawHeaders.indexOf("price_min"), raw.length, 2).format.numberFormat = "$#,##0";
const fetchedIndex = rawHeaders.indexOf("fetched_at");
if (fetchedIndex >= 0) sourceData.getRangeByIndexes(1, fetchedIndex, raw.length, 1).format.numberFormat = "yyyy-mm-dd hh:mm";
sourceData.tables.add(`A1:${colName(rawHeaders.length)}${raw.length + 1}`, true, "DatosFuenteTable").style = "TableStyleMedium2";

// Base normalizada: capa de trabajo editable.
const baseHeaders = ["Clave", "Familia comparable", "Proveedor", "Producto", "Descripción", "Precio publicado COP", "Cantidad estimada", "Método cantidad", "Precio unitario estimado", "Técnicas", "Material", "Capacidad", "Dimensiones", "Empaque", "Disponibilidad", "Ciudad", "URL", "Fecha consulta", "Nivel comparabilidad", "Estado revisión", "Seleccionado", "Notas", "source_id", "Tiene técnica"];
base.getRange("A1:X1").merge(); base.getRange("A1").values = [["Base normalizada de artículos promocionales"]]; base.getRange("A1:X1").format = titleFormat; base.getRange("A1:X1").format.rowHeight = 32;
base.getRange("A2:X2").merge(); base.getRange("A2").values = [["La cantidad se detecta en nombre/empaque; si no aparece, se asume 1 y se marca para validación. Precio unitario = precio publicado / cantidad estimada."]]; base.getRange("A2:X2").format = { fill: lightBlue, font: { color: navy, italic: true }, wrapText: true };
base.getRange("A4:X4").values = [baseHeaders]; base.getRange("A4:X4").format = headerFormat;
const baseValues = normalized.map(row => [row.key, row.family, row.supplier, row.product, row.description, row.price, row.quantity, row.quantityMethod, null, row.techniques, row.material, row.capacity, row.dimensions, row.packaging, row.availability, row.city, row.url, row.fetchedAt, row.comparability, "Pendiente", "No", "", row.sourceId, null]);
base.getRangeByIndexes(4, 0, baseValues.length, baseHeaders.length).values = baseValues;
base.getRange("I5").formulas = [["=IF(G5>0,F5/G5,\"\")"]]; base.getRange(`I5:I${normalized.length + 4}`).fillDown();
base.getRange("X5").formulas = [["=IF(J5<>\"\",1,0)"]]; base.getRange(`X5:X${normalized.length + 4}`).fillDown();
base.getRange(`F5:F${normalized.length + 4}`).format.numberFormat = "$#,##0";
base.getRange(`I5:I${normalized.length + 4}`).format.numberFormat = "$#,##0";
base.getRange(`R5:R${normalized.length + 4}`).format.numberFormat = "yyyy-mm-dd hh:mm";
base.getRange(`T5:T${normalized.length + 4}`).dataValidation = { rule: { type: "list", values: ["Pendiente", "Validado", "Descartado", "Pedir cotización"] } };
base.getRange(`U5:U${normalized.length + 4}`).dataValidation = { rule: { type: "list", values: ["No", "Sí"] } };
base.getRange(`T5:V${normalized.length + 4}`).format.fill = yellow;
base.getRange(`T5:T${normalized.length + 4}`).conditionalFormats.add("containsText", { text: "Validado", format: { fill: green, font: { color: "#1B5E20" } } });
base.getRange(`T5:T${normalized.length + 4}`).conditionalFormats.add("containsText", { text: "Descartado", format: { fill: red, font: { color: "#9B1C1C" } } });
base.tables.add(`A4:X${normalized.length + 4}`, true, "BaseNormalizadaTable").style = "TableStyleMedium2";
base.freezePanes.freezeRows(4); base.freezePanes.freezeColumns(4);

// Comparativo: principal frente a principal y mejor alternativa adicional.
const compHeaders = ["Familia", "Criterio", "Producto Tienda FLA", "Precio FLA", "Cant.", "Unitario est.", "URL FLA", "Producto Esferos.com", "Precio Esferos", "Cant.", "Unitario est.", "URL Esferos", "Otro proveedor", "Otro producto", "Otro precio", "Cant.", "Unitario est.", "URL otro", "Mejor unitario", "Brecha", "Advertencia"];
comparison.getRange("A1:U1").merge(); comparison.getRange("A1").values = [["Comparativo inicial de precios por familia"]]; comparison.getRange("A1:U1").format = titleFormat; comparison.getRange("A1:U1").format.rowHeight = 32;
comparison.getRange("A2:U2").merge(); comparison.getRange("A2").values = [["Cada bloque muestra la referencia de menor precio unitario estimado dentro de la familia. Es una preselección, no una comparación técnica exacta: validar material, tamaño, marcación, IVA, flete y cantidad mínima."]]; comparison.getRange("A2:U2").format = { fill: yellow, font: { color: "#6B4E00", italic: true }, wrapText: true };
comparison.getRange("A4:U4").values = [compHeaders]; comparison.getRange("A4:U4").format = headerFormat;
const compRows = [];
const compFormulas = [];
for (let i = 0; i < familyRules.length; i++) {
  const family = familyRules[i][0];
  const fla = bestCandidate(family, ["tienda_fla"]);
  const esf = bestCandidate(family, ["esferos_com"]);
  const other = bestCandidate(family, ["colorisa_studio", "verona_studio", "natural_graphic", "ingenios_col", "sublifly"]);
  const excelRow = i + 5;
  const criterion = "Menor precio unitario estimado; validar equivalencia";
  compRows.push([family, criterion, "", null, null, null, "", "", null, null, null, "", "", "", null, null, null, "", null, null, "No incluye automáticamente IVA, marcación ni flete"]);
  const ref = candidate => candidate ? candidate.normalizedIndex + 5 : null;
  const formula = (candidate, col) => candidate ? `='Base normalizada'!${col}${ref(candidate)}` : "";
  compFormulas.push([
    "", "", formula(fla, "D"), formula(fla, "F"), formula(fla, "G"), formula(fla, "I"), formula(fla, "Q"),
    formula(esf, "D"), formula(esf, "F"), formula(esf, "G"), formula(esf, "I"), formula(esf, "Q"),
    formula(other, "C"), formula(other, "D"), formula(other, "F"), formula(other, "G"), formula(other, "I"), formula(other, "Q"),
    `=IF(COUNTA(F${excelRow},K${excelRow},Q${excelRow})=0,\"\",MIN(F${excelRow},K${excelRow},Q${excelRow}))`, `=IF(COUNTA(F${excelRow},K${excelRow},Q${excelRow})<2,\"\",MAX(F${excelRow},K${excelRow},Q${excelRow})-MIN(F${excelRow},K${excelRow},Q${excelRow}))`, "",
  ]);
}
comparison.getRangeByIndexes(4, 0, compRows.length, compHeaders.length).values = compRows;
comparison.getRangeByIndexes(4, 2, compFormulas.length, 18).formulas = compFormulas.map(row => row.slice(2, 20));
for (const col of ["D", "F", "I", "K", "O", "Q", "S", "T"]) comparison.getRange(`${col}5:${col}${compRows.length + 4}`).format.numberFormat = "$#,##0";
comparison.getRange(`S5:S${compRows.length + 4}`).format.fill = green;
comparison.getRange(`T5:T${compRows.length + 4}`).conditionalFormats.add("dataBar", { color: "#E76F51", gradient: true });
comparison.tables.add(`A4:U${compRows.length + 4}`, true, "ComparativoTable").style = "TableStyleMedium2";
comparison.freezePanes.freezeRows(4); comparison.freezePanes.freezeColumns(2);

// Páginas integradas y candidatas para revisión.
pages.getRange("A1:H1").merge(); pages.getRange("A1").values = [["Páginas válidas y candidatas para ampliar la base"]]; pages.getRange("A1:H1").format = titleFormat; pages.getRange("A1:H1").format.rowHeight = 32;
pages.getRange("A3:H3").values = [["Proveedor", "ID", "Ciudad / alcance", "URL", "Estado", "Productos obtenidos", "Tiene precios", "Notas"]]; pages.getRange("A3:H3").format = headerFormat;
const pageRows = integratedSources.map(r => [r[0], r[1], r[2], r[3], r[4], countBySource.get(r[1]) ?? 0, "Sí", r[5]])
  .concat(reviewSources.map(r => [r[0], r[1], r[2], r[3], r[4], countBySource.get(r[1]) ?? 0, "Por validar", r[5]]));
pages.getRangeByIndexes(3, 0, pageRows.length, 8).values = pageRows;
pages.getRange(`E4:E${pageRows.length + 3}`).conditionalFormats.add("containsText", { text: "Integrada", format: { fill: green, font: { color: "#1B5E20" } } });
pages.getRange(`E4:E${pageRows.length + 3}`).conditionalFormats.add("containsText", { text: "Revisión", format: { fill: yellow, font: { color: "#6B4E00" } } });
pages.tables.add(`A3:H${pageRows.length + 3}`, true, "PaginasTable").style = "TableStyleMedium2";
pages.freezePanes.freezeRows(3);

// Resumen ejecutivo con KPIs formula-driven.
summary.getRange("A1:H1").merge(); summary.getRange("A1").values = [["Base inicial de precios promocionales — Colombia"]]; summary.getRange("A1:H1").format = titleFormat; summary.getRange("A1:H1").format.rowHeight = 34;
summary.getRange("A2:H2").merge(); summary.getRange("A2").values = [["Corte: 2026-08-24 · Valores publicados, no cotizaciones finales"]]; summary.getRange("A2:H2").format = { fill: lightBlue, font: { color: navy, italic: true } };
for (const range of ["A4:B6", "C4:D6", "E4:F6", "G4:H6"]) summary.getRange(range).format = { fill: lightGray, borders: { preset: "outside", style: "thin", color: "#B8C7D1" } };
summary.getRange("A4:B4").merge(); summary.getRange("A4").values = [["Productos"]];
summary.getRange("C4:D4").merge(); summary.getRange("C4").values = [["Fuentes integradas"]];
summary.getRange("E4:F4").merge(); summary.getRange("E4").values = [["Familias comparables"]];
summary.getRange("G4:H4").merge(); summary.getRange("G4").values = [["Con técnica detectada"]];
summary.getRange("A5:B6").merge(); summary.getRange("A5").formulas = [[`=COUNTA('Base normalizada'!$A$5:$A$${normalized.length + 4})`]];
summary.getRange("C5:D6").merge(); summary.getRange("C5").formulas = [[`=COUNTIF('Páginas'!$E$4:$E$${pageRows.length + 3},\"Integrada\")`]];
summary.getRange("E5:F6").merge(); summary.getRange("E5").formulas = [[`=COUNTA('Comparativo'!$A$5:$A$${familyRules.length + 4})`]];
summary.getRange("G5:H6").merge(); summary.getRange("G5").formulas = [[`=SUM('Base normalizada'!$X$5:$X$${normalized.length + 4})`]];
summary.getRange("A4:H4").format = { fill: blue, font: { bold: true, color: "#FFFFFF" }, horizontalAlignment: "center" };
summary.getRange("A5:H6").format = { font: { bold: true, color: navy, size: 20 }, horizontalAlignment: "center", verticalAlignment: "center" };
summary.getRange("A8:H8").merge(); summary.getRange("A8").values = [["Cómo empezar a darle forma a la base"]]; summary.getRange("A8:H8").format = sectionFormat;
summary.getRange("A9:H13").values = [
  ["1", "Filtrar", "Use Comparativo para revisar familias y abrir URLs.", "", "", "", "", ""],
  ["2", "Validar", "En Base normalizada confirme unidad/paquete, material, técnica, IVA y flete.", "", "", "", "", ""],
  ["3", "Seleccionar", "Marque Seleccionado = Sí y Estado revisión = Validado.", "", "", "", "", ""],
  ["4", "Cotizar", "Los portales sin precio deben quedar como proveedores por cotizar, no como precio cero.", "", "", "", "", ""],
  ["5", "Actualizar", "Vuelva a ejecutar el scraper y regenere el libro conservando criterios de revisión.", "", "", "", "", ""],
];
for (let r = 9; r <= 13; r++) { summary.getRange(`C${r}:H${r}`).merge(); }
summary.getRange("A9:A13").format = { fill: teal, font: { bold: true, color: "#FFFFFF" }, horizontalAlignment: "center" };
summary.getRange("B9:B13").format.font = { bold: true, color: navy };
summary.getRange("C9:H13").format = { wrapText: true, font: { color: gray } };
summary.getRange("A15:H15").merge(); summary.getRange("A15").values = [["Qué significa “comparable”"]]; summary.getRange("A15:H15").format = sectionFormat;
summary.getRange("A16:H18").merge(); summary.getRange("A16").values = [["La familia comparable agrupa productos por uso (mug, esfero, agenda, etc.). El comparativo elige la referencia con menor precio unitario estimado por proveedor, pero no garantiza igualdad de material, tamaño, acabado o técnica. Por eso toda decisión debe pasar por Estado revisión = Validado."]]; summary.getRange("A16:H18").format = { fill: yellow, wrapText: true, verticalAlignment: "top", font: { color: "#6B4E00" } };

// Widths and readable layout.
for (const [sheet, widths] of [
  [summary, [8, 18, 22, 12, 18, 12, 22, 12]],
  [comparison, [20, 28, 34, 14, 9, 14, 38, 34, 14, 9, 14, 38, 23, 34, 14, 9, 14, 38, 14, 14, 32]],
  [base, [18, 22, 24, 34, 48, 16, 12, 24, 17, 20, 18, 14, 18, 26, 16, 14, 42, 22, 24, 18, 13, 26, 16, 12]],
  [pages, [27, 18, 18, 44, 18, 18, 15, 48]],
  [sourceData, [18, 27, 14, 18, 13, 14, 20, 20, 38, 28]],
]) widths.forEach((width, i) => sheet.getRangeByIndexes(0, i, 1, 1).format.columnWidth = width);

comparison.getRange(`A4:U${compRows.length + 4}`).format.wrapText = true;
comparison.getRange(`A5:U${compRows.length + 4}`).format.rowHeight = 48;
base.getRange(`D5:E${normalized.length + 4}`).format.wrapText = true;
pages.getRange(`A3:H${pageRows.length + 3}`).format.wrapText = true;
pages.getRange(`A4:H${pageRows.length + 3}`).format.rowHeight = 38;
summary.freezePanes.freezeRows(2);

await fs.mkdir(outputDir, { recursive: true });
for (const [sheetName, range] of [["Resumen", "A1:H18"], ["Comparativo", "A1:U18"], ["Base normalizada", "A1:X18"], ["Páginas", "A1:H14"], ["Datos fuente", "A1:J18"]]) {
  const preview = await workbook.render({ sheetName, range, scale: 1, format: "png" });
  await fs.writeFile(path.join(outputDir, `preview_${sheetName.replace(/\s+/g, "_")}.png`), new Uint8Array(await preview.arrayBuffer()));
}

const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(outputPath);
console.log(JSON.stringify({ outputPath, rows: normalized.length, sources: integratedSources.length, comparisonFamilies: familyRules.length }, null, 2));
