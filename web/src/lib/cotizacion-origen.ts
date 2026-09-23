import { crearClienteServidor } from "@/lib/supabase/servidor";
import { numeroOpcional as numeroFinito, importeEditable } from "@/lib/dinero";
import type { LineaInicial } from "@/componentes/calculadora-cotizador";

/**
 * Reconstruccion de una cotizacion ya emitida como estado inicial de la
 * calculadora visual (`/cotizador?desde_cotizacion=<id>`).
 *
 * POR QUE ESTO EXISTE
 * -------------------
 * `cotizacion` es INMUTABLE por diseno (RLS `deny_update` desde la migracion
 * 029). Cuando el cliente pide cambios sobre una cotizacion ya emitida no se
 * edita la original: se emite una NUEVA con numero propio. Lo unico que hacia
 * falta era no volver a tipear todo. Esto es composicion en el frontend; no
 * toca el motor de precios ni ninguna funcion SQL.
 *
 * DE DONDE SALE CADA DATO
 * -----------------------
 * Todo viene de `cotizacion_item`, que guarda los snapshots congelados en el
 * momento de emitir (migracion 075):
 *   - proveedor        -> proveedor_snapshot->>'id_proveedor' / 'nombre'
 *   - producto         -> id_producto_proveedor + nombre_item_snapshot
 *   - observacion de precio -> id_precio_proveedor_snapshot
 *   - costo unitario   -> costo_compra_unitario_snapshot (ya dividido por pack)
 *   - presentacion     -> unidad_compra_snapshot + cantidad_pack_snapshot
 *   - cantidad         -> cantidad entregada del item
 *   - costos por linea -> metadata_costeo->'costos_adicionales' (el array
 *                         EXACTO que se envio al emitir, ver 075 linea ~650)
 *
 * No se lee `cotizacion_componente`: ademas de ser ADMIN-only desde la 067,
 * `metadata_costeo` ya conserva los costos adicionales tal cual se enviaron,
 * sin el margen ni el redondeo que el motor les aplico despues.
 *
 * COMPATIBILIDAD CON COTIZACIONES VIEJAS
 * --------------------------------------
 * Las cotizaciones anteriores a la 075 (flujo de una sola linea, p.ej. #145 y
 * #146) no tienen `linea`, `cantidad_presentaciones` ni `costos_adicionales`
 * en `metadata_costeo`. Por eso cada campo tiene el mismo fallback que usa
 * `fn_consola_items_cotizacion`: sin el, esas cotizaciones cargarian en cero.
 *
 * Los historicos anteriores a V2 no guardan geometria DTF. V2 si la conserva:
 * se recuperan medidas y reserva, pero la nueva cotizacion vuelve a validar
 * contra las tarifas actuales del taller.
 */

/** Fila de `cotizacion_item` con lo necesario para rearmar una linea. */
type ItemOrigen = {
  cantidad: number | string;
  id_producto_proveedor: string | null;
  id_precio_proveedor_snapshot: string | null;
  proveedor_snapshot: { id_proveedor?: string; nombre?: string } | null;
  nombre_item_snapshot: string | null;
  costo_compra_unitario_snapshot: number | string | null;
  unidad_compra_snapshot: string | null;
  cantidad_pack_snapshot: number | string | null;
  metadata_costeo: Record<string, unknown> | null;
  created_at: string;
};

export type CotizacionOrigen = {
  id_cotizacion: string;
  numero: number;
  id_organizacion: string | null;
  lineas: LineaInicial[];
  /** Lineas del original que no se pudieron rearmar (sin snapshot de precio). */
  omitidas: number;
};

/** Conserva importes con decimales y diferencia costos unitarios de fijos. */
export const lineaDesdeItem = (item: ItemOrigen): LineaInicial | null => {
  // Sin observacion de precio la linea no se puede volver a emitir: el motor
  // congela el costo contra ese snapshot. Se descarta y se avisa en pantalla.
  if (!item.id_precio_proveedor_snapshot || !item.id_producto_proveedor) return null;

  const meta = (item.metadata_costeo ?? {}) as Record<string, unknown>;
  const unidades = numeroFinito(item.cantidad) ?? 0;
  const pack = numeroFinito(item.cantidad_pack_snapshot);
  const unidad = item.unidad_compra_snapshot ?? "UNIT";
  const esPack = unidad === "PACK" && pack !== null && pack > 0;

  // El nuevo formulario solicita unidades a entregar. Incluso en cotizaciones
  // antiguas, cantidad del item es la cantidad entregada, no los paquetes.

  const costoUnitario = numeroFinito(item.costo_compra_unitario_snapshot) ?? 0;
  const publicadoMeta = numeroFinito(meta.precio_publicado);
  const precioProveedor =
    publicadoMeta !== null
      ? publicadoMeta
      : esPack
        ? costoUnitario * (pack as number)
        : costoUnitario;

  const extras = Array.isArray(meta.costos_adicionales)
    ? (meta.costos_adicionales as Array<Record<string, unknown>>)
    : [];

  const generadoDtf = (e: Record<string, unknown>) =>
    e && typeof e === "object" && e.configuracion_tecnica && typeof e.configuracion_tecnica === "object"
    && e.calculo && typeof e.calculo === "object";
  const extraTecnica = extras.find(generadoDtf);
  const configRaw = meta.configuracion_tecnica && typeof meta.configuracion_tecnica === "object"
    ? meta.configuracion_tecnica : extraTecnica?.configuracion_tecnica;
  const config = configRaw && typeof configRaw === "object" && !Array.isArray(configRaw)
    ? configRaw as Record<string, unknown> : null;
  const disenos = Array.isArray(config?.disenos) ? config.disenos : [];
  const diseno = disenos.length === 1 && disenos[0] && typeof disenos[0] === "object"
    ? disenos[0] as Record<string, unknown> : null;
  const ancho = numeroFinito(diseno?.w);
  const alto = numeroFinito(diseno?.h);
  const repeticiones = numeroFinito(diseno?.qty);
  const reserva = numeroFinito(config?.reserva_pct);
  const geometriaValida = (config?.tipo === "dtf" || config?.tipo === "dtfv")
    && ancho !== null && ancho > 0 && alto !== null && alto > 0
    && repeticiones !== null && Number.isSafeInteger(repeticiones) && repeticiones > 0
    && reserva !== null && reserva >= 0 && reserva <= 100;
  const tecnicaInicial: Partial<LineaInicial> = geometriaValida
    ? config?.tipo === "dtf"
      ? {
          tecnica: "dtf", disenos: [{ name: String(diseno?.name ?? "Diseno historico"), w: ancho!, h: alto!, qty: repeticiones! }],
          dtfWaste: String(reserva), ironInclude: (numeroFinito(config.costo_aplicacion_unitario) ?? 0) > 0,
        }
      : { tecnica: "dtfv", dtfvW: String(ancho), dtfvH: String(alto),
          dtfvImpresiones: String(repeticiones), dtfvWaste: String(reserva) }
    : extraTecnica ? { requiereRevisarTecnica: true } : {};

  const otros = extras
    .filter((e) => e && typeof e === "object" && !generadoDtf(e))
    .map((e) => {
      const total = numeroFinito(e.costo_total);
      const valor = total ?? numeroFinito(e.costo_unitario) ?? 0;
      return { name: String(e.descripcion ?? "").trim() || "Costo adicional", val: importeEditable(valor), modo: total !== null ? "TOTAL" as const : "UNITARIO" as const };
    })
    .filter((e) => Number(e.val.replace(",", ".")) > 0);

  return {
    idProveedor: item.proveedor_snapshot?.id_proveedor ?? "",
    nombreProveedor: item.proveedor_snapshot?.nombre ?? "",
    idProducto: item.id_producto_proveedor,
    nombreProducto: item.nombre_item_snapshot ?? "Producto",
    idSnapshot: item.id_precio_proveedor_snapshot,
    precioUnitario: importeEditable(costoUnitario),
    precioProveedor,
    unidadCompra: unidad,
    cantidadPack: esPack ? (pack as number) : null,
    cantidad: String(Math.max(0, Math.round(unidades))),
    ...tecnicaInicial,
    otros,
  };
};

/**
 * Lee una cotizacion emitida y devuelve las lineas listas para precargar la
 * calculadora. Devuelve null si no existe o no tiene lineas reutilizables.
 * SOLO LECTURA: nunca escribe nada sobre la cotizacion original.
 */
export async function cotizacionParaModificar(
  idCotizacion: string,
): Promise<CotizacionOrigen | null> {
  const supabase = await crearClienteServidor();

  const [{ data: cotizacion }, { data: items }] = await Promise.all([
    supabase
      .from("cotizacion")
      .select("id_cotizacion, numero, id_organizacion")
      .eq("id_cotizacion", idCotizacion)
      .maybeSingle(),
    supabase
      .from("cotizacion_item")
      .select(
        "cantidad, id_producto_proveedor, id_precio_proveedor_snapshot, proveedor_snapshot, nombre_item_snapshot, costo_compra_unitario_snapshot, unidad_compra_snapshot, cantidad_pack_snapshot, metadata_costeo, created_at",
      )
      .eq("id_cotizacion", idCotizacion),
  ]);

  if (!cotizacion) return null;

  // Mismo orden que el detalle y el PDF: `linea` de metadata_costeo y, para las
  // cotizaciones viejas que no la tienen, la fecha de creacion.
  const filas = ((items ?? []) as ItemOrigen[]).slice().sort((a, b) => {
    const la = numeroFinito((a.metadata_costeo ?? {}).linea) ?? Number.MAX_SAFE_INTEGER;
    const lb = numeroFinito((b.metadata_costeo ?? {}).linea) ?? Number.MAX_SAFE_INTEGER;
    if (la !== lb) return la - lb;
    return a.created_at.localeCompare(b.created_at);
  });

  const lineas: LineaInicial[] = [];
  let omitidas = 0;
  for (const fila of filas) {
    const linea = lineaDesdeItem(fila);
    if (linea) lineas.push(linea);
    else omitidas += 1;
  }

  if (lineas.length === 0) return null;

  const c = cotizacion as {
    id_cotizacion: string;
    numero: number;
    id_organizacion: string | null;
  };

  return {
    id_cotizacion: c.id_cotizacion,
    numero: c.numero,
    id_organizacion: c.id_organizacion,
    lineas,
    omitidas,
  };
}
