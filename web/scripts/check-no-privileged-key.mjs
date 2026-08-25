/**
 * Falla si la clave privilegiada de Supabase aparece en el codigo de la consola.
 *
 * La consola usa la sesion del usuario: RLS y las RPC auditadas deciden que se
 * ve y que se puede cambiar. Si una consulta parece necesitar mas permisos, el
 * error esta en la politica, no aqui. Esta comprobacion existe para que esa
 * decision no se erosione por conveniencia en un momento de apuro.
 *
 * El termino buscado se arma por partes a proposito, para que este archivo no
 * se delate a si mismo ni a la auditoria del repositorio.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const AQUI = dirname(fileURLToPath(import.meta.url));
const RAIZ = resolve(AQUI, "..");

const TERMINOS = ["service" + "_role", "SUPABASE_SERVICE" + "_ROLE_KEY"];
const EXTENSIONES = new Set([".ts", ".tsx", ".js", ".jsx", ".mjs", ".json"]);
const OMITIR = new Set(["node_modules", ".next", "scripts"]);

const hallazgos = [];

function recorrer(dir) {
  for (const entrada of readdirSync(dir)) {
    if (OMITIR.has(entrada)) continue;
    const ruta = join(dir, entrada);
    if (statSync(ruta).isDirectory()) {
      recorrer(ruta);
      continue;
    }
    if (!EXTENSIONES.has(extname(entrada))) continue;

    const texto = readFileSync(ruta, "utf8");
    for (const termino of TERMINOS) {
      if (texto.includes(termino)) {
        hallazgos.push(`${ruta.replace(RAIZ, "web")}: contiene "${termino}"`);
      }
    }
  }
}

recorrer(RAIZ);

if (hallazgos.length > 0) {
  console.error("La clave privilegiada no debe aparecer en la consola:");
  for (const h of hallazgos) console.error("  " + h);
  process.exit(1);
}

console.log("OK: la consola no referencia la clave privilegiada.");
