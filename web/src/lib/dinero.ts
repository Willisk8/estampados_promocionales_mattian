/** Importe de un campo es-CO. El estado textual conserva coma decimal. */
export function leerImporte(valor: string | number | null | undefined): number {
  if (typeof valor === "number") return Number.isFinite(valor) ? valor : 0;
  if (valor == null || valor.trim() === "") return 0;
  const limpio = valor.replace(/[^\d,.-]/g, "").replace(/\./g, "").replace(",", ".");
  const numero = Number(limpio);
  return Number.isFinite(numero) ? numero : 0;
}

export function importeEditable(numero: number): string {
  if (!Number.isFinite(numero)) return "";
  return numero.toLocaleString("es-CO", { useGrouping: false, maximumFractionDigits: 4 });
}

export function numeroOpcional(valor: unknown): number | null {
  if (valor == null || (typeof valor === "string" && valor.trim() === "")) return null;
  const numero = Number(valor);
  return Number.isFinite(numero) ? numero : null;
}
