import path from "node:path";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const workbookPath = path.resolve("..", "outputs", "comparativo_base_20260824", "comparativo_precios_promocionales_colombia.xlsx");
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(workbookPath));

const summary = await workbook.inspect({
  kind: "table",
  range: "Resumen!A1:H18",
  include: "values,formulas",
  tableMaxRows: 18,
  tableMaxCols: 8,
  maxChars: 8000,
});
const comparison = await workbook.inspect({
  kind: "table",
  range: "Comparativo!A4:U18",
  include: "values,formulas",
  tableMaxRows: 15,
  tableMaxCols: 21,
  maxChars: 12000,
});
const errors = await workbook.inspect({
  kind: "match",
  searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
  options: { useRegex: true, maxResults: 300 },
  summary: "final formula error scan",
  maxChars: 5000,
});

console.log(JSON.stringify({
  summary: summary.ndjson,
  comparison: comparison.ndjson,
  errors: errors.ndjson,
}, null, 2));
