import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/app/globals.css", import.meta.url), "utf8");

assert.match(
  css,
  /\.filtros\s+input,\s*\.filtros\s+select,\s*\.filtros\s+button\s*\{[\s\S]*?flex:\s*1 1 180px;/,
  "El flex-basis movil de 180px debe estar limitado a filtros.",
);

assert.doesNotMatch(
  css,
  /@media\s*\(max-width:\s*980px\)[\s\S]*?input,\s*select,\s*button\s*\{[\s\S]*?flex:\s*1 1 180px;/,
  "No aplicar flex-basis 180px global a input/select/button en movil.",
);

assert.match(
  css,
  /\.centro\s+form\s*>\s*input,\s*\.centro\s+form\s*>\s*button\s*\{[\s\S]*?flex:\s*1 1 auto;[\s\S]*?width:\s*100%;/,
  "El login movil debe conservar controles de altura normal y ancho completo.",
);

console.log("OK: responsive CSS login/filtros");
