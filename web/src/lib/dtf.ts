export type RectanguloDtf = { w: number; h: number; qty: number };
export type OpcionesDtf = {
  anchoUtilCm: number;
  permitirRotacion: boolean;
  separacionCm: number;
  minimoMetros: number;
  reservaPct: number;
};

/** Estimacion rectangular de un unico diseno repetido, no nesting mixto. */
export function estimarDtf(disenos: RectanguloDtf[], unidades: number, opciones: OpcionesDtf) {
  const fallo = (error: string) => ({ ok: false as const, error });
  const { anchoUtilCm, permitirRotacion, separacionCm, minimoMetros, reservaPct } = opciones;
  if (![anchoUtilCm, separacionCm, minimoMetros, reservaPct].every(Number.isFinite)
    || anchoUtilCm <= 0 || separacionCm < 0 || minimoMetros < 0 || reservaPct < 0
    || !Number.isSafeInteger(unidades) || unidades <= 0) return fallo("Parametros DTF invalidos.");
  if (disenos.length !== 1) return fallo("Los disenos mixtos requieren una disposicion y un costo manual documentados.");
  const d = disenos[0];
  if (![d.w, d.h].every(Number.isFinite) || d.w <= 0 || d.h <= 0
    || !Number.isSafeInteger(d.qty) || d.qty <= 0) return fallo("Dimensiones o repeticiones DTF invalidas.");
  const repeticiones = Math.ceil(d.qty * unidades * (1 + reservaPct / 100));
  if (!Number.isSafeInteger(repeticiones)) return fallo("La cantidad DTF excede el limite de calculo.");
  const orientaciones = permitirRotacion ? [[d.w, d.h], [d.h, d.w]] : [[d.w, d.h]];
  const validas = orientaciones.flatMap(([ancho, alto], indice) => {
    const columnas = Math.floor((anchoUtilCm + separacionCm) / (ancho + separacionCm));
    if (columnas < 1) return [];
    const filas = Math.ceil(repeticiones / columnas);
    const metros = (filas * alto + (filas - 1) * separacionCm) / 100;
    return [{ columnas, filas, metros, rotado: indice === 1 }];
  }).sort((a, b) => a.metros - b.metros);
  if (!validas.length) return fallo("El diseno no cabe en el ancho util del rollo en ninguna orientacion permitida.");
  const mejor = validas[0];
  if (!Number.isFinite(mejor.metros)) return fallo("El consumo DTF excede el limite de calculo.");
  return { ok: true as const, ...mejor, repeticiones, metrosFacturables: Math.max(mejor.metros, minimoMetros) };
}
