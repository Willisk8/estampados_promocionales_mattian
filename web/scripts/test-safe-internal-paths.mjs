import assert from "node:assert/strict";

import {
  agregarParametroARutaInterna,
  rutaInternaSegura,
} from "../src/lib/rutas-internas.ts";

const casosAceptados = [
  ["/", "/"],
  ["/importaciones", "/importaciones"],
  ["/importaciones?pagina=2", "/importaciones?pagina=2"],
  ["/organizaciones/00000000-0000-4000-c000-000000000010?tab=ia", "/organizaciones/00000000-0000-4000-c000-000000000010?tab=ia"],
];

for (const [entrada, esperada] of casosAceptados) {
  assert.equal(rutaInternaSegura(entrada), esperada);
}

const casosRechazados = [
  "",
  "https://evil.example/importaciones",
  "//evil.example/importaciones",
  "/\\evil",
  "/admin",
  "/api/auth",
  "/login",
  "/_next/static",
];

for (const entrada of casosRechazados) {
  assert.equal(rutaInternaSegura(entrada, "/importaciones"), "/importaciones");
}

assert.equal(
  agregarParametroARutaInterna("/importaciones?pagina=2", "ok", "revision"),
  "/importaciones?pagina=2&ok=revision",
);

assert.equal(
  agregarParametroARutaInterna("//evil.example/x", "error", "fallo", "/importaciones"),
  "/importaciones?error=fallo",
);
