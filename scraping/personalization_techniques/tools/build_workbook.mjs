import fs from "node:fs/promises";
import path from "node:path";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const moduleRoot = path.resolve("..");
const runId = process.argv[2] || "01a0394c-b6b4-7d11-bb54-d4001c6bd0fb";
const outputDir = path.join(moduleRoot, "outputs", runId);
const outputPath = path.join(outputDir, "tecnicas_personalizacion_colombia.xlsx");

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

const colName = index1 => {
  let n = index1, name = "";
  while (n > 0) { n--; name = String.fromCharCode(65 + n % 26) + name; n = Math.floor(n / 26); }
  return name;
};
const asNumber = v => v === "" || v == null ? null : Number(v);
const asDate = v => v ? new Date(v) : null;
const readCsv = async name => parseCsv(await fs.readFile(path.join(outputDir, name), "utf8"));

const prices = await readCsv("precios_tecnicas_personalizacion.csv");
const catalog = await readCsv("catalogo_tecnicas.csv");
const errors = await readCsv("errores.csv");
const config = JSON.parse(await fs.readFile(path.join(moduleRoot, "sources.json"), "utf8"));
const summaryJson = JSON.parse(await fs.readFile(path.join(outputDir, "resumen.json"), "utf8"));

const workbook = Workbook.create();
const summary = workbook.worksheets.add("Resumen");
const comparison = workbook.worksheets.add("Comparativo");
const priceSheet = workbook.worksheets.add("Precios");
const catalogSheet = workbook.worksheets.add("Catálogo técnicas");
const sourcesSheet = workbook.worksheets.add("Fuentes");
const errorsSheet = workbook.worksheets.add("Errores");
const dictionary = workbook.worksheets.add("Diccionario");

const navy = "#17324D", blue = "#2176AE", teal = "#2A9D8F", lightBlue = "#EAF3F8";
const green = "#E6F4EA", yellow = "#FFF4CC", red = "#FDECEC", gray = "#5F6B76", lightGray = "#F3F6F8";
const titleFormat = { fill: navy, font: { bold: true, color: "#FFFFFF", size: 18 }, verticalAlignment: "center" };
const headerFormat = { fill: "#DCEAF2", font: { bold: true, color: navy }, wrapText: true, verticalAlignment: "center", borders: { preset: "bottom", style: "medium", color: blue } };
const sectionFormat = { fill: blue, font: { bold: true, color: "#FFFFFF" }, verticalAlignment: "center" };
for (const sheet of [summary, comparison, priceSheet, catalogSheet, sourcesSheet, errorsSheet, dictionary]) sheet.showGridLines = false;

// Precios: datos scrapeados intactos + dos columnas auxiliares auditables.
const priceHeaders = Object.keys(prices[0]);
const priceOutHeaders = [...priceHeaders, "precio_normalizado", "uso_costeo"];
priceSheet.getRangeByIndexes(0, 0, 1, priceOutHeaders.length).values = [priceOutHeaders];
priceSheet.getRangeByIndexes(1, 0, prices.length, priceHeaders.length).values = prices.map(row => priceHeaders.map(h => {
  if (["width_cm", "height_cm", "quantity_min", "quantity_max", "price_value", "price_min", "price_max", "http_status"].includes(h)) return asNumber(row[h]);
  if (h === "fetched_at") return asDate(row[h]);
  return row[h];
}));
const priceLast = prices.length + 1;
priceSheet.getRange("AA2").formulas = [["=IF(Q2<>\"\",Q2,R2)"]];
priceSheet.getRange(`AA2:AA${priceLast}`).fillDown();
priceSheet.getRange("AB2").formulas = [["=IF(AND(Z2=\"VERIFIED_PUBLIC_PRICE\",OR(G2=\"solo_marcacion\",G2=\"solo_servicio\")),\"APTO_COMPARAR\",\"REFERENCIA/REVISAR\")"]];
priceSheet.getRange(`AB2:AB${priceLast}`).fillDown();
priceSheet.getRange(`Q2:S${priceLast}`).format.numberFormat = "$#,##0.00";
priceSheet.getRange(`AA2:AA${priceLast}`).format.numberFormat = "$#,##0.00";
priceSheet.getRange(`X2:X${priceLast}`).format.numberFormat = "yyyy-mm-dd hh:mm";
priceSheet.getRange(`Z2:AB${priceLast}`).conditionalFormats.add("containsText", { text: "REVIEW", format: { fill: yellow, font: { color: "#6B4E00" } } });
priceSheet.getRange(`AB2:AB${priceLast}`).conditionalFormats.add("containsText", { text: "APTO", format: { fill: green, font: { color: "#1B5E20" } } });
priceSheet.getRangeByIndexes(0, 0, 1, priceOutHeaders.length).format = headerFormat;
priceSheet.tables.add(`A1:${colName(priceOutHeaders.length)}${priceLast}`, true, "PreciosTecnicasTable").style = "TableStyleMedium2";
priceSheet.freezePanes.freezeRows(1); priceSheet.freezePanes.freezeColumns(5);

// Catálogo técnico.
const catalogHeaders = Object.keys(catalog[0]);
catalogSheet.getRangeByIndexes(0, 0, 1, catalogHeaders.length).values = [catalogHeaders];
catalogSheet.getRangeByIndexes(1, 0, catalog.length, catalogHeaders.length).values = catalog.map(row => catalogHeaders.map(h => h === "fetched_at" ? asDate(row[h]) : row[h]));
catalogSheet.getRangeByIndexes(0, 0, 1, catalogHeaders.length).format = headerFormat;
catalogSheet.getRange(`I2:I${catalog.length + 1}`).format.numberFormat = "yyyy-mm-dd hh:mm";
catalogSheet.tables.add(`A1:${colName(catalogHeaders.length)}${catalog.length + 1}`, true, "CatalogoTecnicasTable").style = "TableStyleMedium2";
catalogSheet.freezePanes.freezeRows(1); catalogSheet.freezePanes.freezeColumns(1);

// Errores de extracción.
const errorHeaders = errors.length ? Object.keys(errors[0]) : ["source_id", "supplier", "source_url", "fetched_at", "error_type", "detail"];
errorsSheet.getRangeByIndexes(0, 0, 1, errorHeaders.length).values = [errorHeaders];
if (errors.length) errorsSheet.getRangeByIndexes(1, 0, errors.length, errorHeaders.length).values = errors.map(row => errorHeaders.map(h => h === "fetched_at" ? asDate(row[h]) : row[h]));
errorsSheet.getRangeByIndexes(0, 0, 1, errorHeaders.length).format = headerFormat;
if (errors.length) {
  errorsSheet.getRange(`D2:D${errors.length + 1}`).format.numberFormat = "yyyy-mm-dd hh:mm";
  errorsSheet.tables.add(`A1:${colName(errorHeaders.length)}${errors.length + 1}`, true, "ErroresTecnicasTable").style = "TableStyleMedium2";
}
errorsSheet.freezePanes.freezeRows(1);

// Fuentes configuradas y estado calculado desde Precios/Errores.
const sourceHeaders = ["Proveedor", "source_id", "Ciudad", "URL", "Parser", "Observaciones", "Estado ejecución", "Nota"];
sourcesSheet.getRange("A1:H1").merge(); sourcesSheet.getRange("A1").values = [["Fuentes públicas configuradas"]]; sourcesSheet.getRange("A1:H1").format = titleFormat;
sourcesSheet.getRange("A3:H3").values = [sourceHeaders]; sourcesSheet.getRange("A3:H3").format = headerFormat;
sourcesSheet.getRangeByIndexes(3, 0, config.sources.length, 8).values = config.sources.map(s => [s.supplier, s.id, s.city, s.url, s.parser, null, null, "Precios observados; confirmar vigencia antes de comprar"]);
const sourceLast = config.sources.length + 3;
sourcesSheet.getRange("F4").formulas = [[`=COUNTIF('Precios'!$B$2:$B$${priceLast},B4)`]]; sourcesSheet.getRange(`F4:F${sourceLast}`).fillDown();
sourcesSheet.getRange("G4").formulas = [[`=IF(F4>0,"CAPTURADA",IF(COUNTIF('Errores'!$A$2:$A$${Math.max(2, errors.length + 1)},B4)>0,"ERROR","SIN DATOS"))`]]; sourcesSheet.getRange(`G4:G${sourceLast}`).fillDown();
sourcesSheet.getRange(`G4:G${sourceLast}`).conditionalFormats.add("containsText", { text: "CAPTURADA", format: { fill: green, font: { color: "#1B5E20" } } });
sourcesSheet.getRange(`G4:G${sourceLast}`).conditionalFormats.add("containsText", { text: "ERROR", format: { fill: red, font: { color: "#9B1C1C" } } });
sourcesSheet.tables.add(`A3:H${sourceLast}`, true, "FuentesTecnicasTable").style = "TableStyleMedium2";
sourcesSheet.freezePanes.freezeRows(3);

// Comparativo: solo separa costos directos de paquetes para evitar conclusiones engañosas.
comparison.getRange("A1:H1").merge(); comparison.getRange("A1").values = [["Cobertura y mínimos publicados por técnica"]]; comparison.getRange("A1:H1").format = titleFormat;
comparison.getRange("A2:H2").merge(); comparison.getRange("A2").values = [["Los mínimos no son automáticamente comparables: revise unidad, tamaño, cantidad, IVA y alcance en la hoja Precios."]]; comparison.getRange("A2:H2").format = { fill: yellow, font: { italic: true, color: "#6B4E00" }, wrapText: true };
const compHeaders = ["Técnica", "Precios directos verificados", "Mín. solo marcación", "Mín. solo servicio", "Referencias con producto", "Estado", "Factores de costo", "Uso recomendado"];
comparison.getRange("A4:H4").values = [compHeaders]; comparison.getRange("A4:H4").format = headerFormat;
comparison.getRangeByIndexes(4, 0, catalog.length, 8).values = catalog.map(r => [r.technique, null, null, null, null, null, r.typical_cost_drivers, r.best_for]);
const compLast = catalog.length + 4;
comparison.getRange("B5").formulas = [[`=COUNTIFS('Precios'!$E$2:$E$${priceLast},A5,'Precios'!$Z$2:$Z$${priceLast},"VERIFIED_PUBLIC_PRICE",'Precios'!$AB$2:$AB$${priceLast},"APTO_COMPARAR")`]]; comparison.getRange(`B5:B${compLast}`).fillDown();
comparison.getRange("C5").formulas = [[`=IF(COUNTIFS('Precios'!$E$2:$E$${priceLast},A5,'Precios'!$G$2:$G$${priceLast},"solo_marcacion",'Precios'!$Z$2:$Z$${priceLast},"VERIFIED_PUBLIC_PRICE")>0,MINIFS('Precios'!$AA$2:$AA$${priceLast},'Precios'!$E$2:$E$${priceLast},A5,'Precios'!$G$2:$G$${priceLast},"solo_marcacion",'Precios'!$Z$2:$Z$${priceLast},"VERIFIED_PUBLIC_PRICE"),"")`]]; comparison.getRange(`C5:C${compLast}`).fillDown();
comparison.getRange("D5").formulas = [[`=IF(COUNTIFS('Precios'!$E$2:$E$${priceLast},A5,'Precios'!$G$2:$G$${priceLast},"solo_servicio",'Precios'!$Z$2:$Z$${priceLast},"VERIFIED_PUBLIC_PRICE")>0,MINIFS('Precios'!$AA$2:$AA$${priceLast},'Precios'!$E$2:$E$${priceLast},A5,'Precios'!$G$2:$G$${priceLast},"solo_servicio",'Precios'!$Z$2:$Z$${priceLast},"VERIFIED_PUBLIC_PRICE"),"")`]]; comparison.getRange(`D5:D${compLast}`).fillDown();
comparison.getRange("E5").formulas = [[`=COUNTIFS('Precios'!$E$2:$E$${priceLast},A5,'Precios'!$G$2:$G$${priceLast},"producto_personalizado")`]]; comparison.getRange(`E5:E${compLast}`).fillDown();
comparison.getRange("F5").formulas = [["=IF(B5>0,\"CON PRECIO DIRECTO\",IF(E5>0,\"SOLO PAQUETE\",\"COTIZAR\"))"]]; comparison.getRange(`F5:F${compLast}`).fillDown();
comparison.getRange(`C5:D${compLast}`).format.numberFormat = "$#,##0.00";
comparison.getRange(`F5:F${compLast}`).conditionalFormats.add("containsText", { text: "CON PRECIO", format: { fill: green, font: { color: "#1B5E20" } } });
comparison.getRange(`F5:F${compLast}`).conditionalFormats.add("containsText", { text: "COTIZAR", format: { fill: yellow, font: { color: "#6B4E00" } } });
comparison.tables.add(`A4:H${compLast}`, true, "ComparativoTecnicasTable").style = "TableStyleMedium2";
comparison.freezePanes.freezeRows(4); comparison.freezePanes.freezeColumns(1);

// Resumen ejecutivo con KPIs calculados desde las hojas de datos.
summary.getRange("A1:H1").merge(); summary.getRange("A1").values = [["Precios de técnicas de personalización — Colombia"]]; summary.getRange("A1:H1").format = titleFormat; summary.getRange("A1:H1").format.rowHeight = 34;
summary.getRange("A2:H2").merge(); summary.getRange("A2").values = [[`Captura ${summaryJson.generated_at.slice(0, 10)} · Valores públicos, no cotizaciones finales`]]; summary.getRange("A2:H2").format = { fill: lightBlue, font: { italic: true, color: navy } };
for (const range of ["A4:B6", "C4:D6", "E4:F6", "G4:H6"]) summary.getRange(range).format = { fill: lightGray, borders: { preset: "outside", style: "thin", color: "#B8C7D1" } };
const cards = [["A4:B4", "Observaciones", `=COUNTA('Precios'!$A$2:$A$${priceLast})`], ["C4:D4", "Fuentes capturadas", `=COUNTIF('Fuentes'!$G$4:$G$${sourceLast},"CAPTURADA")`], ["E4:F4", "Técnicas con precio directo", `=COUNTIF('Comparativo'!$B$5:$B$${compLast},">0")`], ["G4:H4", "Filas para revisión", `=COUNTIF('Precios'!$Z$2:$Z$${priceLast},"NEEDS_REVIEW_UNIT")`]];
for (const [labelRange, label, formula] of cards) {
  summary.getRange(labelRange).merge(); summary.getRange(labelRange.split(":")[0]).values = [[label]]; summary.getRange(labelRange).format = { fill: blue, font: { bold: true, color: "#FFFFFF" }, horizontalAlignment: "center" };
  const startCol = labelRange[0], valueRange = `${startCol}5:${String.fromCharCode(startCol.charCodeAt(0)+1)}6`;
  summary.getRange(valueRange).merge(); summary.getRange(`${startCol}5`).formulas = [[formula]]; summary.getRange(valueRange).format = { font: { bold: true, size: 20, color: navy }, horizontalAlignment: "center", verticalAlignment: "center" };
}
summary.getRange("A8:H8").merge(); summary.getRange("A8").values = [["Reglas de uso para costear"]]; summary.getRange("A8:H8").format = sectionFormat;
summary.getRange("A9:H13").values = [
  ["1", "Comparar", "Compare solo filas con uso_costeo = APTO_COMPARAR y la misma unidad/tamaño/cantidad.", "", "", "", "", ""],
  ["2", "Separar", "No cargue producto_personalizado como costo_personalizacion: incluye prenda, mug o agenda.", "", "", "", "", ""],
  ["3", "Confirmar", "Valide IVA, aplicación, diseño, flete y mínimo antes de convertir la captura en costo vigente.", "", "", "", "", ""],
  ["4", "Bordado", "Registre por separado el programa/digitalización y el bordado por puntadas o por pieza.", "", "", "", "", ""],
  ["5", "Histórico", "Agregue nuevas capturas como observaciones; no sobrescriba valores anteriores.", "", "", "", "", ""]
];
for (let r = 9; r <= 13; r++) summary.getRange(`C${r}:H${r}`).merge();
summary.getRange("A9:A13").format = { fill: teal, font: { bold: true, color: "#FFFFFF" }, horizontalAlignment: "center" };
summary.getRange("B9:B13").format.font = { bold: true, color: navy };
summary.getRange("C9:H13").format = { wrapText: true, font: { color: gray } };
summary.getRange("A15:H15").merge(); summary.getRange("A15").values = [["Cobertura y pendientes"]]; summary.getRange("A15:H15").format = sectionFormat;
summary.getRange("A16:H18").merge(); summary.getRange("A16").values = [[`${summaryJson.price_observations} observaciones en ${summaryJson.fetched_sources}/${summaryJson.configured_sources} fuentes. Las fuentes con DNS, HTML dinámico o certificado inválido permanecen en Errores; no se eludieron controles de seguridad.`]]; summary.getRange("A16:H18").format = { fill: yellow, wrapText: true, verticalAlignment: "top", font: { color: "#6B4E00" } };
summary.freezePanes.freezeRows(2);

// Diccionario de campos clave y reglas de migración.
const dictionaryRows = [
  ["Precios", "price_scope", "Alcance comparable", "solo_marcacion / solo_servicio / producto_personalizado / cotizador_referencial"],
  ["Precios", "service_component", "Componente cobrado", "impresión, aplicación, programa, producto + marcación, etc."],
  ["Precios", "billing_unit", "Unidad publicada", "unidad, cm2, metro lineal, pliego, programa o lote"],
  ["Precios", "quantity_min / quantity_max", "Escala de cantidad", "Límites de la tarifa publicada"],
  ["Precios", "price_value", "Precio puntual COP", "Valor numérico publicado"],
  ["Precios", "price_min / price_max", "Rango COP", "Use cuando la fuente publica un intervalo"],
  ["Precios", "tax_status", "Tratamiento de impuestos", "Vacío = no informado; EXCLUYE_IVA cuando la fuente lo declara"],
  ["Precios", "verification_status", "Calidad de extracción", "VERIFIED_PUBLIC_PRICE o NEEDS_REVIEW_UNIT"],
  ["Precios", "uso_costeo", "Control calculado", "Solo APTO_COMPARAR para precios directos verificados"],
  ["Supabase", "costo_personalizacion", "Destino futuro", "No cargar automáticamente paquetes; confirmar vigencia y alcance primero"]
];
dictionary.getRange("A1:D1").merge(); dictionary.getRange("A1").values = [["Diccionario y controles de integración"]]; dictionary.getRange("A1:D1").format = titleFormat;
dictionary.getRange("A3:D3").values = [["Hoja/destino", "Campo", "Definición", "Regla"]]; dictionary.getRange("A3:D3").format = headerFormat;
dictionary.getRangeByIndexes(3, 0, dictionaryRows.length, 4).values = dictionaryRows;
dictionary.tables.add(`A3:D${dictionaryRows.length + 3}`, true, "DiccionarioTecnicasTable").style = "TableStyleMedium2";
dictionary.freezePanes.freezeRows(3);

// Anchos legibles y ajuste de texto.
const widths = new Map([
  [summary, [8, 17, 22, 12, 18, 12, 20, 12]],
  [comparison, [23, 16, 18, 18, 16, 20, 34, 42]],
  [priceSheet, [26, 20, 24, 14, 20, 24, 22, 38, 38, 22, 10, 10, 12, 12, 18, 10, 14, 14, 14, 14, 42, 48, 46, 22, 10, 22, 16, 20]],
  [catalogSheet, [22, 24, 40, 42, 42, 42, 34, 46, 22, 20]],
  [sourcesSheet, [28, 24, 15, 48, 22, 16, 20, 42]],
  [errorsSheet, [24, 28, 48, 22, 22, 54]],
  [dictionary, [18, 28, 34, 60]]
]);
for (const [sheet, cols] of widths) cols.forEach((w, i) => sheet.getRangeByIndexes(0, i, 1, 1).format.columnWidth = w);
priceSheet.getRange(`H2:V${priceLast}`).format.wrapText = true;
catalogSheet.getRange(`A1:J${catalog.length + 1}`).format.wrapText = true;
comparison.getRange(`A4:H${compLast}`).format.wrapText = true;
sourcesSheet.getRange(`A3:H${sourceLast}`).format.wrapText = true;
errorsSheet.getRange(`A1:F${Math.max(2, errors.length + 1)}`).format.wrapText = true;
dictionary.getRange(`A3:D${dictionaryRows.length + 3}`).format.wrapText = true;

await fs.mkdir(outputDir, { recursive: true });
const previews = [
  ["Resumen", "A1:H18"], ["Comparativo", `A1:H${compLast}`], ["Precios", `A1:AB${Math.min(priceLast, 18)}`],
  ["Catálogo técnicas", `A1:J${catalog.length + 1}`], ["Fuentes", `A1:H${sourceLast}`],
  ["Errores", `A1:F${Math.max(2, errors.length + 1)}`], ["Diccionario", `A1:D${dictionaryRows.length + 3}`]
];
for (const [sheetName, range] of previews) {
  const preview = await workbook.render({ sheetName, range, scale: 1, format: "png" });
  await fs.writeFile(path.join(outputDir, `preview_${sheetName.replace(/\s+/g, "_")}.png`), new Uint8Array(await preview.arrayBuffer()));
}

const formulaErrors = await workbook.inspect({ kind: "match", searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A", options: { useRegex: true, maxResults: 300 }, summary: "final formula error scan" });
await fs.writeFile(path.join(outputDir, "formula_errors.inspect.ndjson"), formulaErrors.ndjson || "", "utf8");
const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(outputPath);
console.log(JSON.stringify({ outputPath, observations: prices.length, techniques: catalog.length, sources: config.sources.length, errors: errors.length }, null, 2));
