/**
 * Utilidades para leer int4range de PostgreSQL en la interfaz.
 *
 * Vive fuera de app/ a proposito: Next.js 15 exige que un page.tsx solo
 * exporte el conjunto fijo de simbolos de ruta (default, generateStaticParams,
 * etc.), asi que una funcion auxiliar exportada desde un page.tsx rompe la
 * verificacion de tipos del build (aunque el dev server no lo detecta).
 */

/** `[12,36)` de un int4range se lee mejor como "12 – 35". */
export function rangoLegible(rango: string): string {
  const m = rango.match(/^([\[(])(\d*),(\d*)([\])])$/);
  if (!m) return rango;
  const [, abre, desde, hasta, cierra] = m;
  const min = desde ? Number(desde) + (abre === "(" ? 1 : 0) : 1;
  if (!hasta) return `${min} o mas`;
  const max = Number(hasta) - (cierra === ")" ? 1 : 0);
  return min === max ? String(min) : `${min} – ${max}`;
}

export function ordenRango(rango: string): number {
  const m = rango.match(/^[\[(](\d*),/);
  return m && m[1] ? Number(m[1]) : 0;
}
