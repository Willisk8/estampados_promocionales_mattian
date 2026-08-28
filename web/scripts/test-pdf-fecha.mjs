import assert from "node:assert/strict";

import { formatoFechaPdf } from "../src/app/cotizador/[id]/pdf/formato.ts";

// fecha_emision es nullable; new Date(null) devuelve la epoca Unix (1970).
// El helper debe devolver texto legible, nunca una fecha de 1969/1970.
assert.equal(formatoFechaPdf(null), "Sin fecha de emisi\u00f3n");
assert.equal(formatoFechaPdf(undefined), "Sin fecha de emisi\u00f3n");
assert.equal(formatoFechaPdf(""), "Sin fecha de emisi\u00f3n");

// Fecha invalida -> texto legible, no "Invalid Date" crudo.
assert.equal(formatoFechaPdf("no-es-una-fecha"), "Fecha inv\u00e1lida");

// Fecha valida -> formato legible es-CO que contiene el anio.
const conFecha = formatoFechaPdf("2026-08-28T10:00:00.000Z");
assert.match(conFecha, /2026/);

// Una cadena de la epoca Unix no debe romper el helper: debe renderizarse como
// fecha (agnostico a zona horaria del entorno), nunca como "Invalid Date".
const conEpoch = formatoFechaPdf("1970-01-01T00:00:00.000Z");
assert.notEqual(conEpoch, "Fecha inv\u00e1lida");
assert.match(conEpoch, /\d{1,2}\/\d{1,2}\/\d{4}/);

console.log("OK: formatoFechaPdf protege NULL e invalidas en PDF de cotizacion");