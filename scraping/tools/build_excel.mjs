import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const __filename = fileURLToPath(import.meta.url);
const rootDir = path.resolve(path.dirname(__filename), "..");
const outDir = path.join(rootDir, "outputs", "entidades_solidarias");
const sourcePath = path.join(rootDir, "data", "web", "base_consolidada_contactos.csv");
const workbookPath = path.join(outDir, "entidades_solidarias_scraping.xlsx");

function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (quoted) {
      if (ch === '"' && next === '"') { cell += '"'; i += 1; }
      else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ",") { row.push(cell); cell = ""; }
    else if (ch === "\n") { row.push(cell.replace(/\r$/, "")); rows.push(row); row = []; cell = ""; }
    else cell += ch;
  }
  if (cell.length || row.length) { row.push(cell.replace(/\r$/, "")); rows.push(row); }
  return rows.filter((item) => item.some((value) => value !== ""));
}

function colName(index) {
  let name = "";
  for (let n = index + 1; n > 0; n = Math.floor((n - 1) / 26)) {
    name = String.fromCharCode(65 + ((n - 1) % 26)) + name;
  }
  return name;
}

const rows = parseCsv((await fs.readFile(sourcePath, "utf8")).replace(/^\uFEFF/, ""));
if (rows.length < 2) throw new Error("La base consolidada no contiene registros");
const width = Math.max(...rows.map((row) => row.length));
const normalized = rows.map((row) => [...row, ...Array(width - row.length).fill("")]);
const endCol = colName(width - 1);
const endCell = `${endCol}${normalized.length}`;

const workbook = Workbook.create();
const sheet = workbook.worksheets.add("Base consolidada");
sheet.showGridLines = false;
sheet.getRange(`A1:${endCell}`).values = normalized;
sheet.tables.add(`A1:${endCell}`, true, "BaseConsolidadaContactos").style = "TableStyleMedium2";
sheet.freezePanes.freezeRows(1);
sheet.freezePanes.freezeColumns(2);

const header = sheet.getRange(`A1:${endCol}1`);
header.format = {
  fill: "#164E63",
  font: { bold: true, color: "#FFFFFF" },
  wrapText: true,
  verticalAlignment: "center",
};
header.format.rowHeight = 34;

sheet.getRange("A:A").format.columnWidth = 14;
sheet.getRange("B:B").format.columnWidth = 42;
sheet.getRange("C:D").format.columnWidth = 22;
sheet.getRange("E:F").format.columnWidth = 18;
sheet.getRange("G:G").format.columnWidth = 34;
sheet.getRange("H:J").format.columnWidth = 30;
sheet.getRange("K:M").format.columnWidth = 24;
sheet.getRange("N:N").format.columnWidth = 24;
sheet.getRange("O:O").format.columnWidth = 28;
sheet.getRange("P:P").format.columnWidth = 48;
sheet.getRange("Q:R").format.columnWidth = 26;
sheet.getRange("S:S").format.columnWidth = 18;
sheet.getRange("T:T").format.columnWidth = 22;
sheet.getRange("U:V").format.columnWidth = 34;
sheet.getRange("W:W").format.columnWidth = 18;
sheet.getRange("X:X").format.columnWidth = 42;
sheet.getRange("Y:Y").format.columnWidth = 52;
sheet.getRange("Z:Z").format.columnWidth = 34;
sheet.getRange(`A2:A${normalized.length}`).format.numberFormat = "@";
sheet.getRange(`O2:O${normalized.length}`).format.numberFormat = "#,##0";
sheet.getRange(`A1:${endCell}`).format.verticalAlignment = "top";

const inspection = await workbook.inspect({
  kind: "table",
  range: `'Base consolidada'!A1:${endCol}8`,
  include: "values,formulas",
  tableMaxRows: 8,
  tableMaxCols: width,
  maxChars: 7000,
});
console.log(inspection.ndjson);

const errors = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 50 },
  summary: "final formula error scan",
});
console.log(errors.ndjson);

const preview = await workbook.render({
  sheetName: "Base consolidada",
  range: `A1:${endCol}20`,
  scale: 1,
  format: "png",
});
await fs.mkdir(outDir, { recursive: true });
await fs.writeFile(path.join(outDir, "resumen_preview.png"), new Uint8Array(await preview.arrayBuffer()));

const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(workbookPath);
console.log(JSON.stringify({ workbookPath, rows: normalized.length - 1, columns: width }));
