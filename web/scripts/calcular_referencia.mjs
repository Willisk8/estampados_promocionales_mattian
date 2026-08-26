// Calcula precios con el puerto TypeScript sobre los 5 productos reales del
// catalogo, para comparar contra la salida de scripts/catalog/pricing_model.py.
// Ejecutar con: node --experimental-strip-types scripts/calcular_referencia.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { calcularPrecio } from "../src/lib/pricing/modelo.ts";

const AQUI = dirname(fileURLToPath(import.meta.url));
const RAIZ_PROYECTO = join(AQUI, "..", "..");
const RUTA_INSUMOS = join(RAIZ_PROYECTO, "scripts", "catalog", "mvp_catalog_inputs.json");

const catalogo = JSON.parse(readFileSync(RUTA_INSUMOS, "utf8"));
const salida = {};

for (const entrada of catalogo.products) {
  const sku = entrada.product.sku;
  const cantidades = entrada.quantity_breaks ?? [1, 12, 50, 100, 200];
  salida[sku] = cantidades.map((qty) => calcularPrecio(entrada, qty));
}

// El catalogo real no ejercita marking.mode="bordado" ni commercial_policy
// mode="markup". Se agregan sinteticos identicos a los de
// validar_puerto_ts.py para cubrir el modelo documentado completo, no solo
// lo que hoy vive en produccion.
const CASOS_SINTETICOS = {
  SINTETICO_BORDADO: {
    quantity_breaks: [1, 12, 50],
    product_costs: [{ value_unit: 5000 }],
    marking: { mode: "bordado", fixed_program_cost: 12000, extra_cost_unit: 350 },
    withholdings: { reteica_pct: 1, retefuente_pct: 2.5 },
    commercial_policy: { mode: "margen", target_pct: 35 },
  },
  SINTETICO_MARKUP: {
    quantity_breaks: [1, 12, 50],
    product_costs: [{ value_unit: 8000 }],
    marking: { mode: "none" },
    commercial_policy: { mode: "markup", target_pct: 30 },
  },
};

for (const [sku, entrada] of Object.entries(CASOS_SINTETICOS)) {
  salida[sku] = entrada.quantity_breaks.map((qty) => calcularPrecio(entrada, qty));
}

console.log(JSON.stringify(salida));
