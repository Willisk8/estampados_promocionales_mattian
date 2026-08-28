/**
 * Formateo de fecha para el PDF de cotizacion (I-3).
 *
 * cotizacion.fecha_emision es nullable: para cotizaciones del flujo simple
 * anterior puede ser NULL, y `new Date(null)` no lanza pero produce la epoca
 * Unix (1-ene-1970). Este helper centraliza la proteccion y devuelve texto
 * legible en su lugar.
 */
export function formatoFechaPdf(
  fechaEmision: string | null | undefined,
): string {
  if (!fechaEmision) return "Sin fecha de emisi\u00f3n";

  const fecha = new Date(fechaEmision);
  if (Number.isNaN(fecha.getTime())) return "Fecha inv\u00e1lida";

  return fecha.toLocaleString("es-CO");
}