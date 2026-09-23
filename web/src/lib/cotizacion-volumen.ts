export type EscalaMargen = { desde: number; margen: number };

export function margenPorCantidad(unidades: number, margenBase: number, escalas: EscalaMargen[]): number {
  return [...escalas].sort((a, b) => b.desde - a.desde).find((e) => unidades >= e.desde)?.margen ?? margenBase;
}

/** Precio antes de impuestos; retenciones no modifican la venta. */
export function precioConMargen(costo: number, margen: number, _retencion = 0): number {
  if (![costo, margen].every(Number.isFinite) || costo < 0 || margen < 0 || margen >= 100) return NaN;
  return costo / (1 - margen / 100);
}

export function precioComercial(costo: number, margen: number, unidades: number): number {
  if (!Number.isSafeInteger(unidades) || unidades <= 0) return NaN;
  const unitario = precioConMargen(costo, margen) / unidades;
  // Absorber exclusivamente ruido binario menor que un ULP alrededor del entero.
  const entero = Math.round(unitario);
  return (Math.abs(unitario - entero) <= Number.EPSILON * Math.max(1, Math.abs(unitario)) ? entero : Math.ceil(unitario)) * unidades;
}

export function validarEscalas(escalas: EscalaMargen[], margenBase: number): string | null {
  if (!Number.isFinite(margenBase) || margenBase < 0 || margenBase >= 100) return "El margen base debe estar entre 0% y menos de 100%.";
  let anterior = margenBase;
  const cantidades = new Set<number>();
  for (const escala of [...escalas].sort((a, b) => a.desde - b.desde)) {
    if (!Number.isSafeInteger(escala.desde) || escala.desde < 1) return "Cada escala debe empezar en una cantidad entera positiva.";
    if (cantidades.has(escala.desde)) return "No puede haber dos escalas que empiecen en la misma cantidad.";
    cantidades.add(escala.desde);
    if (!Number.isFinite(escala.margen) || escala.margen < 0 || escala.margen >= 100) return "Los margenes deben estar entre 0% y menos de 100%.";
    if (escala.margen > anterior) return "El margen de una escala mayor no debe superar el de la escala anterior.";
    anterior = escala.margen;
  }
  return null;
}

export function cantidadesComparacion(actual: number, escalas: EscalaMargen[]): number[] {
  return [...new Set([1, actual, ...escalas.map(e => e.desde)])]
    .filter(n => Number.isSafeInteger(n) && n > 0).sort((a, b) => a - b);
}
