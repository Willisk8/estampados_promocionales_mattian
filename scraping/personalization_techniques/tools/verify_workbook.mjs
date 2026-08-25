import fs from "node:fs/promises";
import path from "node:path";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const moduleRoot = path.resolve("..");
const runId = process.argv[2] || "01a0394c-b6b4-7d11-bb54-d4001c6bd0fb";
const outputDir = path.join(moduleRoot, "outputs", runId);
const workbookPath = path.join(outputDir, "tecnicas_personalizacion_colombia.xlsx");
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(workbookPath));

const sheets = await workbook.inspect({ kind: "sheet", include: "id,name", maxChars: 4000 });
const summary = await workbook.inspect({ kind: "table", range: "Resumen!A1:H18", include: "values,formulas", tableMaxRows: 18, tableMaxCols: 8, maxChars: 8000 });
const comparison = await workbook.inspect({ kind: "table", range: "Comparativo!A1:H16", include: "values,formulas", tableMaxRows: 16, tableMaxCols: 8, maxChars: 10000 });
const errors = await workbook.inspect({ kind: "match", searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A", options: { useRegex: true, maxResults: 300 }, summary: "final formula error scan" });

const report = [sheets.ndjson, summary.ndjson, comparison.ndjson, errors.ndjson].join("\n");
await fs.writeFile(path.join(outputDir, "verify_workbook.inspect.ndjson"), report, "utf8");
const formulaErrors = (errors.ndjson || "").includes("matched 0 entries") ? 0 : 1;
console.log(JSON.stringify({ workbookPath, formulaErrors, inspectedRanges: ["Resumen!A1:H18", "Comparativo!A1:H16"] }, null, 2));
process.exitCode = formulaErrors ? 1 : 0;
