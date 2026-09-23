"use client";

/**
 * Calculadora visual de precio de la ruta /cotizador.
 *
 * Este es el unico componente de cliente del cotizador y es deliberado: los
 * sliders, listas dinamicas y el recalculo instantaneo no se pueden hacer con el
 * flujo server-rendered del resto de la pagina. La convencion de "cero JS de
 * cliente" se rompe aqui a proposito y solo aqui: la pagina sigue siendo un
 * Server Component y le pasa a este componente los datos iniciales y el rol.
 *
 * ── MODELO DE CALCULO ────────────────────────────────────────────────────
 * A) COSTOS DEL PRODUCTO (por linea i, independientes entre lineas):
 *      costo_unitario_total_i = costo_base_unitario_i
 *                             + costo_tecnica_unitario_i
 *                             + costos_adicionales_unitarios_i
 *      costo_total_linea_i    = costo_unitario_total_i * cantidad_i
 *
 * B) COSTOS GLOBALES DEL PEDIDO (no pertenecen a ningun producto):
 *      costo_total_pedido = Σ costo_total_linea_i
 *                         + gastos_generales_del_pedido
 *                         + desgaste_de_maquinas
 *
 * C) RESULTADO FINANCIERO (formula de margen sobre venta intacta):
 *      retFactor = 1 - Σ retenciones/100
 *      precio    = Σ costo_pleno_i / (retFactor * (1 - margen_i/100))
 *      recibido  = precio * retFactor
 *      ganancia  = recibido - costo_total_pedido
 *
 * D) GANANCIA POR PRODUCTO (reparto documentado de los costos globales):
 *      Los gastos globales del pedido se reparten entre las lineas de forma
 *      PROPORCIONAL AL COSTO de cada linea (una linea que cuesta el doble
 *      absorbe el doble de gasolina, desgaste, etc.):
 *        peso_i        = costo_total_linea_i / Σ costo_total_linea
 *        costo_pleno_i = costo_total_linea_i + globales * peso_i
 *        margen_i      = margen configurado para la cantidad de esta linea
 *        precio_i      = costo_pleno_i / (retFactor * (1 - margen_i/100))
 *        ganancia_i    = precio_i * retFactor - costo_pleno_i
 *      La suma de las ganancias por linea es exactamente
 *      la ganancia neta del pedido. Si todavia no hay costo de productos, el
 *      peso se reparte en partes iguales para que la identidad se mantenga.
 *
 * ── MULTIPACK ────────────────────────────────────────────────────────────
 * `fn_consola_ofertas_producto_proveedor` devuelve, por cada observacion de
 * precio, `precio_publicado` (lo que cobra el proveedor por la presentacion
 * que vende), `unidad_compra` ('UNIT' | 'PACK' | ...), `cantidad_pack` y el
 * `id_snapshot` que despues permite emitir la cotizacion real.
 *
 * Costo unitario (misma formula que la RPC y que el motor de cotizacion):
 *   costo_unitario = unidad_compra = 'PACK' y cantidad_pack > 0
 *                    ? precio_publicado / cantidad_pack
 *                    : precio_publicado
 *
 * CANTIDAD. En una linea de producto empacado, lo que pide el cliente son
 * PAQUETES, no unidades sueltas: nadie compra 3 unidades de una caja x10.
 * Por eso, si unidad_compra = 'PACK':
 *     unidades_totales   = cantidad_de_paquetes * cantidad_pack
 *     costo_base_linea   = cantidad_de_paquetes * precio_publicado
 * Ejemplo: caja x10 a $18.000 -> 1 paquete = 10 unidades = $18.000;
 *          3 paquetes = 30 unidades = $54.000 (nunca $5.400).
 * El campo se relabela a "Cantidad de paquetes" y las unidades totales se
 * muestran como dato DERIVADO, no editable. En un producto individual
 * ('UNIT' o sin dato) no cambia nada: la cantidad son unidades.
 *
 * Todo lo que se cobra por unidad (tecnica, costos adicionales del producto)
 * se multiplica por las UNIDADES TOTALES, no por los paquetes.
 *
 * ── DIFERENCIAS CONSCIENTES CONTRA EL HTML DE REFERENCIA ────────────────
 *  - Proveedor, producto, precio, cantidad, tecnica y costos adicionales son
 *    PROPIOS DE CADA LINEA. Lo unico compartido son las TARIFAS del taller
 *    (precio del metro de rollo, ancho, $/kWh, papel, tinta), que son
 *    propiedades del taller y no del producto.
 *  - La tecnica DTF-UV ya no incluye "Transporte ($)": el transporte no es un
 *    parametro de impresion. Se carga como costo adicional del producto o como
 *    gasto general del pedido.
 *  - Solo existe "margen sobre venta" (el markup sobre costo se retiro de la UI).
 *  - Todavia NO consume las tecnicas curadas de la base: usa las formulas
 *    fisicas locales, igual que antes.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { crearClienteNavegador } from "@/lib/supabase/navegador";
import { emitirCotizacionMultilinea, previsualizarCotizacionMultilinea } from "@/app/cotizador/acciones";
import { leerImporte as aNumero, importeEditable } from "@/lib/dinero";
import { estimarDtf } from "@/lib/dtf";
import { margenPorCantidad, precioConMargen, precioComercial, validarEscalas, cantidadesComparacion, type EscalaMargen } from "@/lib/cotizacion-volumen";
import "./calculadora-cotizador.css";

type ClienteSupabase = ReturnType<typeof crearClienteNavegador>;

// ── tipos que devuelven las RPC ya usadas por la pagina ────────────────
export type ProveedorOpcion = {
  id_proveedor: string;
  nombre: string;
  ciudad: string | null;
  productos: number | string;
};

export type ProductoOpcion = {
  id_producto_proveedor: string;
  sku_proveedor: string | null;
  nombre_original: string;
  categoria: string | null;
  estado_calidad: string;
  ultimo_precio: number | string | null;
  moneda: string | null;
  unidad_compra: string | null;
  cantidad_pack: number | string | null;
  observado_en: string | null;
};

/** Cliente al que se le emite la cotizacion real (CRM ya existente). */
export type OrganizacionOpcion = {
  id_organizacion: string;
  nombre_legal: string;
  nit: string | null;
};

/**
 * Oferta concreta de `fn_consola_ofertas_producto_proveedor`. Es la unica
 * fuente del `id_snapshot`, y sin snapshot no se puede emitir una cotizacion
 * real: el motor congela el costo contra esa observacion de precio.
 */
type OfertaProveedor = {
  id_snapshot: string;
  precio_publicado: number | string;
  moneda: string;
  unidad_compra: string | null;
  cantidad_pack: number | string | null;
  costo_unitario_estimado: number | string;
  observado_en: string | null;
  vigente: boolean;
};

/** Fila de costo editable. `val` es STRING a proposito: ver CampoMoneda. */
type Fila = { name: string; val: string; modo?: "UNITARIO" | "TOTAL" };

/**
 * Linea precargada desde una cotizacion ya emitida (`?desde_cotizacion=`).
 *
 * Es un subconjunto de `LineaProducto` armado desde el snapshot congelado.
 * V2 recupera la geometria DTF y recalcula con las tarifas actuales del taller;
 * los historicos sin configuracion estructurada conservan su costo manual.
 */
export type LineaInicial = {
  idProveedor: string;
  nombreProveedor: string;
  idProducto: string;
  nombreProducto: string;
  idSnapshot: string;
  precioUnitario: string;
  precioProveedor: number | null;
  unidadCompra: string | null;
  cantidadPack: number | null;
  cantidad: string;
  tecnica?: TecnicaLinea;
  disenos?: Diseno[];
  dtfWaste?: string;
  ironInclude?: boolean;
  dtfvW?: string;
  dtfvH?: string;
  dtfvImpresiones?: string;
  dtfvWaste?: string;
  requiereRevisarTecnica?: boolean;
  reasignacionSobrante?: string;
  motivoAjuste?: string;
  otros: Fila[];
};
type Maquina = { name: string; price: string; uses: string };
type Diseno = { name: string; w: number; h: number; qty: number };

/** Tecnicas del HTML de referencia. No se inventan tecnicas nuevas. */
type TecnicaLinea = "ninguna" | "bordado" | "dtf" | "sublimacion" | "dtfv";

const TECNICAS: Array<{ v: TecnicaLinea; l: string }> = [
  { v: "ninguna", l: "Sin marcacion" },
  { v: "bordado", l: "🪡 Bordado (camiseta)" },
  { v: "dtf", l: "🖨️ DTF textil (camiseta)" },
  { v: "sublimacion", l: "🎨 Sublimacion (vaso / mug)" },
  { v: "dtfv", l: "🖨️ DTF-UV (rigidos: mug, termo, agenda)" },
];

/** Una linea del pedido: proveedor, producto, precio, cantidad y tecnica propios. */
type LineaProducto = {
  id: string;
  /** Proveedor DE ESTA LINEA. Cambiarlo no toca las demas lineas. */
  idProveedor: string;
  nombreProveedor: string;
  idProducto: string;
  nombreProducto: string;
  /**
   * Observacion de precio elegida. Sin esto la linea sirve para estimar pero
   * NO se puede emitir: la cotizacion real congela el costo contra el snapshot.
   */
  idSnapshot: string;
  /** Costo unitario ya dividido por pack. Autocompletado pero editable. */
  precioUnitario: string;
  /** Trazabilidad del precio del proveedor tal cual vino de la base. */
  precioProveedor: number | null;
  unidadCompra: string | null;
  cantidadPack: number | null;
  /**
   * Propia de la linea. Arranca vacia a proposito: no se precarga ninguna.
   * Siempre son unidades a entregar; los paquetes de compra se calculan aparte.
   */
  cantidad: string;
  tecnica: TecnicaLinea;
  requiereRevisarTecnica?: boolean;
  reasignacionSobrante?: string;
  motivoAjuste?: string;
  // bordado
  embFixed: string;
  embExtra: string;
  // DTF textil
  disenos: Diseno[];
  dtfWaste: string;
  ironInclude: boolean;
  // sublimacion
  sublImgPerSheet: string;
  // DTF-UV (solo parametros de impresion: sin transporte)
  dtfvW: string;
  dtfvH: string;
  dtfvImpresiones: string;
  dtfvWaste: string;
  /** Costos adicionales por unidad de ESTE producto (no del pedido). */
  otros: Fila[];
};

// ── formato y parseo ───────────────────────────────────────────────────
const fmt = (n: number) =>
  "$" + Math.round(Number.isFinite(n) ? n : 0).toLocaleString("es-CO");

const miles = (n: number) =>
  Math.round(Number.isFinite(n) ? n : 0).toLocaleString("es-CO");

/**
 * Parseo tolerante de un importe escrito a mano. Acepta "18000", "18.000",
 * "18.000,50" y "" (vacio = 0). El punto es separador de miles en es-CO, por
 * eso se elimina antes de parsear; la coma es el separador decimal.
 * OJO: no usar esto en porcentajes (1.104 % perderia el punto decimal).
 */
/** parseFloat clasico, para porcentajes y medidas (donde "." es decimal). */
const num = (s: string, alterno = 0) => parseFloat(s) || alterno;

const DTF_COLORS = ["#7c3aed", "#1d4ed8", "#0369a1", "#065f46", "#92400e"];

/**
 * Tarifas del taller + retenciones. Aca ya NO viven los datos de diseno
 * (costo fijo del bordado, medidas, merma): esos son por linea.
 */
const CAMPOS_INICIALES: Record<string, string> = {
  // DTF textil (rollo que compras)
  dtfPricePerMeter: "12000",
  dtfRollWidth: "58",
  // plancha DTF
  ironWatts: "2000",
  ironSecs: "160",
  ironPasses: "2",
  ironKwhPrice: "900",
  // sublimacion
  sublPaperPkg: "39500",
  sublInkSet: "140000",
  sublInkYield: "800",
  mugWatts: "280",
  mugSecs: "32",
  mugPasses: "2",
  mugKwh: "900",
  // DTF-UV
  dtfvPrice: "14000",
  dtfvRollW: "57",
  // retenciones
  rICA: "0",
  rFuente: "0",
  rIVA: "0",
  rOther: "0",
};

/** Campos de `campos` que son IMPORTES (se parsean con aNumero, no parseFloat). */
const CAMPOS_MONEDA = new Set([
  "dtfPricePerMeter",
  "ironKwhPrice",
  "sublPaperPkg",
  "sublInkSet",
  "mugKwh",
  "dtfvPrice",
]);

/** Contador de modulo: ids deterministas (mismo valor en SSR y en hidratacion). */
let seqLinea = 0;

const nuevaLinea = (): LineaProducto => ({
  id: `ln${++seqLinea}`,
  idProveedor: "",
  nombreProveedor: "",
  idProducto: "",
  nombreProducto: "",
  idSnapshot: "",
  precioUnitario: "",
  precioProveedor: null,
  unidadCompra: null,
  cantidadPack: null,
  cantidad: "",
  tecnica: "ninguna",
  embFixed: "15000",
  embExtra: "0",
  disenos: [{ name: "Pecho", w: 10, h: 12, qty: 1 }],
  dtfWaste: "10",
  ironInclude: false,
  sublImgPerSheet: "3",
  dtfvW: "25",
  dtfvH: "9",
  dtfvImpresiones: "1",
  dtfvWaste: "10",
  otros: [],
});

/**
 * Linea nueva con los valores congelados de una cotizacion ya emitida.
 * Todo lo que la base no guarda (tecnica y sus medidas) queda en su default.
 */
const lineaDesde = (inicial: LineaInicial): LineaProducto => {
  const base = nuevaLinea();
  return {
    ...base,
    ...inicial,
    // Copia propia: editar una linea no muta el snapshot recibido del servidor.
    otros: inicial.otros.map((o) => ({ ...o })),
    disenos: inicial.disenos?.map((d) => ({ ...d })) ?? base.disenos,
  };
};

/**
 * MULTIPACK: costo unitario real a partir del precio publicado del proveedor.
 * Misma formula que fn_consola_ofertas_producto_proveedor (migracion 070).
 * Si falta el dato (producto sin snapshot, precio nulo) devuelve null y la UI
 * no toca el precio de la linea: se conserva el comportamiento anterior.
 */
const costoUnitarioDe = (p: ProductoOpcion): number | null => {
  if (!p.unidad_compra) return null;
  const precio = Number(p.ultimo_precio ?? NaN);
  if (!Number.isFinite(precio) || precio <= 0) return null;
  const pack = Number(p.cantidad_pack ?? NaN);
  if (p.unidad_compra === "PACK" && Number.isFinite(pack) && pack > 0) return precio / pack;
  return precio;
};

/** Texto de la presentacion: "paquete x 10 unidades" / "por unidad". */
const presentacionDe = (unidad: string | null, pack: number | null): string => {
  if (unidad === "PACK" && pack && pack > 0)
    return `paquete x ${miles(pack)} unidad${pack === 1 ? "" : "es"}`;
  if (unidad === "METER") return "por metro";
  if (unidad === "SHEET") return "por hoja";
  if (!unidad) return "(unidad de compra sin verificar)";
  if (unidad === "UNIT") return "por unidad";
  return unidad.toLowerCase();
};

/** Resultado del calculo de una linea (costos del PRODUCTO, sin globales). */
type CalculoLinea = {
  /** Lo que digito el usuario: paquetes si es PACK, unidades si no. */
  presentaciones: number;
  /** Unidades fisicas = presentaciones * cantidad_pack (o presentaciones). */
  cantidad: number;
  /** true si la linea se cotiza por presentaciones empacadas. */
  esPack: boolean;
  /** Unidades por presentacion (1 cuando no es PACK). */
  porPresentacion: number;
  /** Divisor seguro: nunca 0 (evita division por cero en costos fijos). */
  qEff: number;
  precioBase: number;
  compradas: number;
  sobrantes: number;
  costoCompra: number;
  tecnicaUnit: number;
  tecnicaLabel: string;
  errorDtf?: string;
  otrosUnit: number;
  costoUnitTotal: number;
  subtotal: number;
};

/** Reparto de los costos globales y resultado financiero de una linea. */
type FinanzasLinea = {
  costoPleno: number;
  precio: number;
  ganancia: number;
};

/** Tarifas compartidas del taller que necesitan los paneles de tecnica. */
type Tarifas = {
  dtfRollW: number;
  dtfPricePerMeter: number;
  ironCost: number;
  sublPaperPkg: number;
  sublInkSet: number;
  sublInkYield: number;
  mugWatts: number;
  sublTotalSecs: number;
  sublElecUnit: number;
  dtfvPrice: number;
  dtfvRollW: number;
};

// ═══════════════════════════════════════════════════════════════════════
// Campo monetario editable
// ═══════════════════════════════════════════════════════════════════════
/**
 * Input de dinero que NO pelea con el usuario.
 *  - Mientras el campo tiene foco se edita como texto crudo: se puede borrar
 *    el 0 por completo y quedar vacio sin que nada lo repinte.
 *  - La normalizacion ocurre en onBlur (nunca en cada tecla).
 *  - Sin foco se muestra formateado con separador de miles.
 * El valor vive en el estado del padre como STRING; el calculo lo lee con
 * aNumero(), asi que "" cuenta como 0 sin forzar un "0" en pantalla.
 */
function CampoMoneda({
  valor,
  alCambiar,
  testId,
  ariaLabel,
  placeholder = "0",
  disabled = false,
}: {
  valor: string;
  alCambiar: (v: string) => void;
  testId?: string;
  ariaLabel?: string;
  placeholder?: string;
  disabled?: boolean;
}) {
  const [borrador, setBorrador] = useState<string | null>(null);
  const enEdicion = borrador !== null;
  const mostrado = enEdicion
    ? borrador
    : valor.trim() === ""
      ? ""
      : aNumero(valor).toLocaleString("es-CO", { maximumFractionDigits: 4 });

  return (
    <div className="mw">
      <input
        type="text"
        inputMode="decimal"
        autoComplete="off"
        data-testid={testId}
        aria-label={ariaLabel}
        placeholder={placeholder}
        disabled={disabled}
        value={mostrado}
        onFocus={(e) => setBorrador(e.currentTarget.value)}
        onChange={(e) => {
          // Solo se filtran caracteres imposibles. No se normaliza ni se
          // rellena con 0: el campo puede quedar vacio mientras se escribe.
          const limpio = e.target.value.replace(/[^\d.,]/g, "");
          setBorrador(limpio);
          alCambiar(limpio);
        }}
        onBlur={() => {
          setBorrador(null);
          const t = valor.trim();
          alCambiar(t === "" ? "" : importeEditable(aNumero(t)));
        }}
      />
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════
// Tarjeta de una linea de producto
// ═══════════════════════════════════════════════════════════════════════
function TarjetaLinea({
  linea,
  indice,
  esUnica,
  proveedores,
  supabase,
  tarifas,
  calculo,
  finanzas,
  esAdmin,
  editar,
  eliminar,
}: {
  linea: LineaProducto;
  indice: number;
  esUnica: boolean;
  proveedores: ProveedorOpcion[];
  supabase: ClienteSupabase;
  tarifas: Tarifas;
  calculo: CalculoLinea;
  finanzas: FinanzasLinea;
  esAdmin: boolean;
  editar: (patch: Partial<LineaProducto>) => void;
  eliminar: () => void;
}) {
  const l = linea;
  const c = calculo;

  // Precio de venta por unidad de ESTA linea (ya con margen, retenciones y la
  // parte prorrateada de los gastos globales del pedido). El costo unitario ya
  // se veia; esto es lo que se le cobra al cliente por unidad, que es el numero
  // que hacia falta para poder comparar contra el costo sin abrir el resumen.
  const precioVentaUnitario = c.cantidad > 0 ? finanzas.precio / c.cantidad : 0;

  // Catalogo del proveedor DE ESTA LINEA. Cada tarjeta consulta el suyo, por
  // eso el estado vive aca abajo y no en el padre.
  const [productos, setProductos] = useState<ProductoOpcion[]>([]);
  const [cargando, setCargando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [abierto, setAbierto] = useState(false);
  const [consulta, setConsulta] = useState("");

  // El texto tipeado DENTRO del selector es el que filtra: va contra el
  // servidor a proposito porque la RPC topea en 200 filas y un proveedor puede
  // tener 600+ productos (sin esto, el final del alfabeto seria inalcanzable).
  useEffect(() => {
    if (!l.idProveedor) {
      setProductos([]);
      setError(null);
      return;
    }
    let vivo = true;
    setCargando(true);
    const t = setTimeout(async () => {
      const q = consulta.trim();
      const { data, error: err } = await supabase.rpc(
        "fn_consola_buscar_productos_proveedor",
        { p_id_proveedor: l.idProveedor, p_q: q === "" ? null : q, p_limit: 200 },
      );
      if (!vivo) return;
      setCargando(false);
      if (err) {
        setError(`No se pudieron cargar productos: ${err.message}`);
        return;
      }
      setError(null);
      setProductos((data ?? []) as ProductoOpcion[]);
    }, 280);
    return () => {
      vivo = false;
      clearTimeout(t);
    };
  }, [l.idProveedor, consulta, supabase]);

  const consultaNorm = consulta.trim().toLowerCase();
  const visibles = (
    consultaNorm === ""
      ? productos
      : productos.filter((p) =>
          `${p.nombre_original} ${p.categoria ?? ""} ${p.sku_proveedor ?? ""}`
            .toLowerCase()
            .includes(consultaNorm),
        )
  ).slice(0, 80);

  const solicitudOferta = useRef(0);
  useEffect(() => () => { solicitudOferta.current += 1; }, []);

  const elegirProveedor = (id: string) => {
    solicitudOferta.current += 1;
    const prov = proveedores.find((p) => p.id_proveedor === id);
    // Cambiar de proveedor invalida el producto elegido: pertenece al anterior.
    editar({
      idProveedor: id,
      nombreProveedor: prov?.nombre ?? "",
      idProducto: "",
      nombreProducto: "",
      idSnapshot: "",
      precioProveedor: null,
      unidadCompra: null,
      cantidadPack: null,
    });
    setConsulta("");
  };

  const elegirProducto = (idProducto: string) => {
    const solicitud = ++solicitudOferta.current;
    const p = productos.find((x) => x.id_producto_proveedor === idProducto);
    if (!p) return;
    const unitario = costoUnitarioDe(p);
    const publicado = Number(p.ultimo_precio ?? NaN);
    const pack = Number(p.cantidad_pack ?? NaN);
    editar({
      idProducto,
      nombreProducto: p.nombre_original,
      idSnapshot: "",
      precioProveedor: Number.isFinite(publicado) ? publicado : null,
      unidadCompra: p.unidad_compra,
      cantidadPack: Number.isFinite(pack) ? pack : null,
      // Sin dato de precio se conserva lo que ya hubiera escrito el usuario.
      ...(unitario !== null ? { precioUnitario: importeEditable(unitario) } : {}),
    });

    // El selector de productos no trae el id del snapshot y sin el no se puede
    // emitir nada: se pide la oferta vigente aparte. Si falla, la linea sigue
    // sirviendo para estimar y el boton de emitir avisa cual falta.
    void (async () => {
      const { data, error: err } = await supabase.rpc(
        "fn_consola_ofertas_producto_proveedor",
        { p_id_producto_proveedor: idProducto, p_cantidad: 1 },
      );
      if (solicitud !== solicitudOferta.current) return;
      if (err) { setError("No se pudo consultar la oferta. Vuelve a seleccionar el producto."); return; }
      const ofertas = (data ?? []) as OfertaProveedor[];
      const oferta = ofertas.find((o) => o.vigente) ?? ofertas[0];
      if (!oferta) return;
      const publicadoOferta = Number(oferta.precio_publicado ?? NaN);
      const packOferta = Number(oferta.cantidad_pack ?? NaN);
      const unitarioOferta = Number(oferta.costo_unitario_estimado ?? NaN);
      editar({
        idSnapshot: oferta.id_snapshot,
        precioProveedor: Number.isFinite(publicadoOferta) ? publicadoOferta : null,
        unidadCompra: oferta.unidad_compra,
        cantidadPack: Number.isFinite(packOferta) ? packOferta : null,
        ...(oferta.unidad_compra && Number.isFinite(unitarioOferta) && unitarioOferta > 0
          ? { precioUnitario: importeEditable(unitarioOferta) }
          : {}),
      });
    })();
  };

  const limpiarProducto = () => {
    solicitudOferta.current += 1;
    editar({
      idProducto: "",
      nombreProducto: "",
      idSnapshot: "",
      precioProveedor: null,
      unidadCompra: null,
      cantidadPack: null,
    });
  };

  const editarCosto = (i: number, patch: Partial<Fila>) =>
    editar({ otros: l.otros.map((x, j) => (j === i ? { ...x, ...patch } : x)) });

  const editarDiseno = (i: number, patch: Partial<Diseno>) =>
    editar({ disenos: l.disenos.map((d, j) => (j === i ? { ...d, ...patch } : d)) });

  // ── panel de la tecnica elegida en ESTA linea ───────────────────────
  const panelTecnica = () => {
    if (l.tecnica === "ninguna") {
      return (
        <div className="info info-blue mb0 f12">
          Este producto se cotiza sin marcacion: solo costo base + costos
          adicionales. La tecnica es opcional.
        </div>
      );
    }

    if (l.tecnica === "bordado") {
      const embFixed = aNumero(l.embFixed);
      return (
        <>
          <div className="linea-grid2">
            <div>
              <div className="lbl">Costo fijo del programa ($)</div>
              <CampoMoneda
                valor={l.embFixed}
                testId="calc-linea-emb-fixed"
                ariaLabel="Costo fijo del programa"
                alCambiar={(v) => editar({ embFixed: v })}
              />
            </div>
            <div>
              <div className="lbl">Costo extra por unidad ($)</div>
              <CampoMoneda
                valor={l.embExtra}
                ariaLabel="Costo extra por unidad"
                alCambiar={(v) => editar({ embExtra: v })}
              />
            </div>
          </div>
          <div className="info info-green mb0 f12">
            🪡 {fmt(embFixed)} ÷ {c.qEff} uds de este producto ={" "}
            <strong>{fmt(c.tecnicaUnit)}/und</strong>
          </div>
        </>
      );
    }

    if (l.tecnica === "dtf") {
      const area = l.disenos.reduce((s, d) => s + d.w * d.h * d.qty, 0);
      const estimacion = estimarDtf(l.disenos, c.qEff, { anchoUtilCm: tarifas.dtfRollW, permitirRotacion: true, separacionCm: 0, minimoMetros: 0, reservaPct: num(l.dtfWaste, 0) });
      const metrosMerma = estimacion.ok ? estimacion.metrosFacturables / c.qEff : 0;
      return (
        <>
          <div className="linea-tarifa">
            Rollo del taller: {fmt(tarifas.dtfPricePerMeter)}/m lineal · ancho{" "}
            {tarifas.dtfRollW} cm (se edita en &quot;Tarifas y consumos del taller&quot;)
          </div>
          <div className="sub-tit">Disenos de este producto</div>
          <div className="dis-row dis-head">
            <span className="izq">Nombre</span>
            <span>Ancho cm</span>
            <span>Alto cm</span>
            <span>Uds</span>
            <span>Area</span>
            <span />
          </div>
          {l.disenos.map((d, i) => {
            const col = DTF_COLORS[i % DTF_COLORS.length];
            return (
              <div
                key={`${l.id}-d${i}`}
                className="dis-row"
                style={{ borderLeft: `3px solid ${col}` }}
              >
                <input
                  type="text"
                  value={d.name}
                  placeholder="Ej: Logo pecho"
                  aria-label="Nombre del diseno"
                  onChange={(e) => editarDiseno(i, { name: e.target.value })}
                />
                <input
                  type="number"
                  min={1}
                  step={0.5}
                  aria-label="Ancho cm"
                  className="mono"
                  value={d.w}
                  onChange={(e) => editarDiseno(i, { w: parseFloat(e.target.value) || 1 })}
                />
                <input
                  type="number"
                  min={1}
                  step={0.5}
                  aria-label="Alto cm"
                  className="mono"
                  value={d.h}
                  onChange={(e) => editarDiseno(i, { h: parseFloat(e.target.value) || 1 })}
                />
                <input
                  type="number"
                  min={1}
                  aria-label="Unidades del diseno"
                  className="mono"
                  value={d.qty}
                  onChange={(e) => editarDiseno(i, { qty: parseInt(e.target.value, 10) || 1 })}
                />
                <span className="dis-area" style={{ color: col }}>
                  {miles(d.w * d.h * d.qty)} cm²
                </span>
                {l.disenos.length > 1 ? (
                  <button
                    type="button"
                    className="btn-del"
                    aria-label="Quitar diseno"
                    onClick={() => editar({ disenos: l.disenos.filter((_, j) => j !== i) })}
                  >
                    ×
                  </button>
                ) : (
                  <span />
                )}
              </div>
            );
          })}
          <button
            type="button"
            className="btn-add mb10"
            onClick={() =>
              editar({ disenos: [...l.disenos, { name: "", w: 15, h: 20, qty: 1 }] })
            }
          >
            ＋ Agregar diseno
          </button>
          <div className="linea-grid2">
            <div>
              <div className="lbl">📐 Merma (%)</div>
              <div className="pw">
                <input
                  type="number"
                  min={0}
                  max={50}
                  aria-label="Merma DTF"
                  value={l.dtfWaste}
                  onChange={(e) => editar({ dtfWaste: e.target.value })}
                />
              </div>
            </div>
            <label className="chk">
              <input
                type="checkbox"
                checked={l.ironInclude}
                onChange={(e) => editar({ ironInclude: e.target.checked })}
              />
              Incluir luz de plancha ({fmt(tarifas.ironCost)}/und)
            </label>
          </div>
          <div className="info info-green mb0 f12">
            {c.errorDtf ? <span role="alert">{c.errorDtf}</span> : <>Estimacion rectangular con rotacion, sin separacion ni minimo facturable: </>}
            🖨️ {miles(area)} cm² → {metrosMerma.toFixed(4)} m/und ×{" "}
            {fmt(tarifas.dtfPricePerMeter)} = <strong>{fmt(c.tecnicaUnit)}/und</strong>
          </div>
        </>
      );
    }

    if (l.tecnica === "sublimacion") {
      const imgPerSheet = num(l.sublImgPerSheet, 1);
      const paperUnit = tarifas.sublPaperPkg / 100 / imgPerSheet;
      const inkUnit = tarifas.sublInkSet / tarifas.sublInkYield / imgPerSheet;
      return (
        <>
          <div className="linea-tarifa">
            Insumos del taller: papel {fmt(tarifas.sublPaperPkg)}/100 hojas · tinta{" "}
            {fmt(tarifas.sublInkSet)} ÷ {tarifas.sublInkYield} hojas · plancha mug{" "}
            {tarifas.mugWatts}W × {tarifas.sublTotalSecs}s
          </div>
          <div className="linea-grid2">
            <div>
              <div className="lbl">🖼️ Imagenes por hoja</div>
              <input
                type="number"
                min={1}
                className="mono"
                aria-label="Imagenes por hoja"
                value={l.sublImgPerSheet}
                onChange={(e) => editar({ sublImgPerSheet: e.target.value })}
              />
              <div className="nota">Mug estandar: 3/hoja</div>
            </div>
            <div />
          </div>
          <div className="info info-green mb0 f12">
            🎨 papel {fmt(paperUnit)} + tinta {fmt(inkUnit)} + luz{" "}
            {fmt(tarifas.sublElecUnit)} = <strong>{fmt(c.tecnicaUnit)}/und</strong>
          </div>
        </>
      );
    }

    // DTF-UV: SOLO parametros de impresion. El transporte NO va aca: se carga
    // como costo adicional del producto o como gasto general del pedido.
    const w = num(l.dtfvW, 1);
    const h = num(l.dtfvH, 1);
    const imp = num(l.dtfvImpresiones, 1);
    return (
      <>
        <div className="linea-tarifa">
          Rollo del taller: {fmt(tarifas.dtfvPrice)}/m lineal · ancho {tarifas.dtfvRollW} cm
        </div>
        <div className="linea-grid4">
          <div>
            <div className="lbl">↔ Ancho impresion (cm)</div>
            <input
              type="number"
              min={1}
              className="mono"
              aria-label="Ancho de impresion"
              value={l.dtfvW}
              onChange={(e) => editar({ dtfvW: e.target.value })}
            />
          </div>
          <div>
            <div className="lbl">↕ Alto impresion (cm)</div>
            <input
              type="number"
              min={1}
              className="mono"
              aria-label="Alto de impresion"
              value={l.dtfvH}
              onChange={(e) => editar({ dtfvH: e.target.value })}
            />
          </div>
          <div>
            <div className="lbl">🖨️ Impresiones por unidad</div>
            <input
              type="number"
              min={1}
              className="mono"
              aria-label="Impresiones por unidad"
              value={l.dtfvImpresiones}
              onChange={(e) => editar({ dtfvImpresiones: e.target.value })}
            />
          </div>
          <div>
            <div className="lbl">📐 Merma (%)</div>
            <div className="pw">
              <input
                type="number"
                min={0}
                max={50}
                aria-label="Merma DTF-UV"
                value={l.dtfvWaste}
                onChange={(e) => editar({ dtfvWaste: e.target.value })}
              />
            </div>
          </div>
        </div>
        <div className="info info-green mb0 f12">
          {c.errorDtf && <span role="alert">{c.errorDtf} </span>}
          Estimacion rectangular con rotacion, sin separacion ni minimo facturable.
          🖨️ {w}×{h} cm × {imp} impresion/es, ancho util {tarifas.dtfvRollW} cm: {" "}
          <strong>{fmt(c.tecnicaUnit)}/und</strong>
          <br />
          <span className="f11">
            ¿Transporte? Va como costo adicional de este producto o como gasto general
            del pedido, no como parametro de impresion.
          </span>
        </div>
      </>
    );
  };

  const hayPrecioProveedor = l.precioProveedor !== null && l.precioProveedor > 0;
  const esPack = c.esPack;

  return (
    <div className="linea" data-testid="calc-linea">
      <div className="linea-top">
        <span className="linea-num">Producto {indice + 1}</span>
        <span className="linea-sub-mini" data-testid="calc-linea-subtotal">
          {fmt(c.subtotal)}
        </span>
        <button
          type="button"
          className="btn-del"
          aria-label={`Eliminar producto ${indice + 1}`}
          data-testid="calc-linea-eliminar"
          disabled={esUnica}
          onClick={eliminar}
        >
          ×
        </button>
      </div>

      {error && (
        <div className="info info-amber f12" data-testid="calc-linea-error">
          {error}
        </div>
      )}

      <div className="linea-grid">
        <div>
          <div className="lbl">🏭 Proveedor de este producto</div>
          <select
            data-testid="calc-linea-proveedor"
            aria-label={`Proveedor del producto ${indice + 1}`}
            value={l.idProveedor}
            onChange={(e) => elegirProveedor(e.target.value)}
          >
            <option value="">Elige un proveedor</option>
            {proveedores.map((p) => (
              <option key={p.id_proveedor} value={p.id_proveedor}>
                {p.nombre}
                {p.ciudad ? ` - ${p.ciudad}` : ""} ({p.productos})
              </option>
            ))}
          </select>
        </div>
        <div>
          <div className="lbl">Producto</div>
          <div className="cbx">
            <input
              type="text"
              data-testid="calc-linea-producto"
              aria-label={`Producto ${indice + 1}`}
              autoComplete="off"
              disabled={!l.idProveedor}
              placeholder={
                l.idProveedor
                  ? "Escribi para buscar y elegi un producto"
                  : "Elegi primero el proveedor de esta linea"
              }
              value={abierto ? consulta : l.nombreProducto}
              onFocus={() => {
                setAbierto(true);
                setConsulta("");
              }}
              onChange={(e) => {
                setAbierto(true);
                setConsulta(e.target.value);
              }}
              onClick={() => { setAbierto(true); setConsulta(""); }}
              onKeyDown={(e) => {
                if (e.key === "Escape") setAbierto(false);
                if (e.key === "ArrowDown") { e.preventDefault(); e.currentTarget.parentElement?.querySelector<HTMLButtonElement>("button")?.focus(); }
              }}
              onBlur={(e) => {
                if (!e.currentTarget.parentElement?.contains(e.relatedTarget as Node | null)) setAbierto(false);
              }}
            />
            {abierto && (
              <div className="cbx-list" data-testid="calc-linea-opciones">
                {l.idProducto && (
                  <button
                    type="button"
                    className="cbx-op cbx-op-limpiar"
                    onMouseDown={(ev) => ev.preventDefault()}
                    onClick={() => {
                      limpiarProducto();
                      setAbierto(false);
                      setConsulta("");
                    }}
                  >
                    — Sin producto (precio manual) —
                  </button>
                )}
                {cargando && <div className="cbx-vacio">Buscando...</div>}
                {!cargando && visibles.length === 0 && (
                  <div className="cbx-vacio">Sin coincidencias</div>
                )}
                {visibles.map((p) => {
                  const unitario = costoUnitarioDe(p);
                  const publicado = Number(p.ultimo_precio ?? NaN);
                  const pack = Number(p.cantidad_pack ?? NaN);
                  const packOk =
                    p.unidad_compra === "PACK" && Number.isFinite(pack) && pack > 0;
                  return (
                    <button
                      type="button"
                      key={p.id_producto_proveedor}
                      className={`cbx-op${p.id_producto_proveedor === l.idProducto ? " on" : ""}`}
                      data-testid="calc-linea-opcion"
                      onMouseDown={(ev) => ev.preventDefault()}
                      onClick={() => {
                        elegirProducto(p.id_producto_proveedor);
                        setAbierto(false);
                        setConsulta("");
                      }}
                    >
                      <span className="cbx-nom">
                        {p.nombre_original}
                        {p.categoria ? <span className="cbx-cat"> · {p.categoria}</span> : null}
                      </span>
                      <span className="cbx-precio">
                        {!p.unidad_compra ? (
                          "Unidad de compra sin verificar; requiere nueva oferta"
                        ) : unitario === null ? (
                          "sin precio registrado"
                        ) : packOk ? (
                          <>
                            Precio proveedor {fmt(publicado)}{" "}
                            {presentacionDe(p.unidad_compra, pack)} →{" "}
                            <strong>{fmt(unitario)} / und</strong>
                          </>
                        ) : (
                          <>
                            Precio proveedor {fmt(publicado)}{" "}
                            {presentacionDe(p.unidad_compra, null)} →{" "}
                            <strong>{fmt(unitario)} / und</strong>
                          </>
                        )}
                      </span>
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        </div>
        <div>
          <div className="lbl">Costo unitario base</div>
          <CampoMoneda
            valor={l.precioUnitario}
            testId="calc-linea-precio"
            disabled={!esAdmin}
            ariaLabel={`Costo unitario base del producto ${indice + 1}`}
            alCambiar={(v) => editar({ precioUnitario: v })}
          />
        </div>
        <div>
          <div className="lbl">
            Unidades a entregar
          </div>
          <input
            type="number"
            min={1}
            step={1}
            placeholder="0"
            className="mono"
            data-testid="calc-linea-cantidad"
            aria-label={
              `Cantidad del producto ${indice + 1}`
            }
            value={l.cantidad}
            onChange={(e) => editar({ cantidad: e.target.value })}
          />
          {c.esPack ? (
            <div
              className="nota"
              data-testid="calc-linea-unidades-totales"
              data-unidades={c.cantidad}
              data-presentaciones={c.presentaciones}
              data-por-presentacion={c.porPresentacion}
            >
              Entrega: <strong>{miles(c.cantidad)}</strong>. Compra: {miles(c.presentaciones)} paquetes × {miles(c.porPresentacion)} = {miles(c.compradas)}. Sobrantes: {miles(c.sobrantes)}.
            </div>
          ) : (
            <div
              className="nota"
              data-testid="calc-linea-unidades-totales"
              data-unidades={c.cantidad}
              data-presentaciones={c.presentaciones}
              data-por-presentacion={1}
            >
              Unidades sueltas
            </div>
          )}
        </div>
      </div>

      {hayPrecioProveedor && (
        <div
          className="pack-info"
          data-testid="calc-linea-presentacion"
          data-precio-proveedor={Math.round(l.precioProveedor ?? 0)}
          data-unidad-compra={l.unidadCompra ?? "UNIT"}
          data-cantidad-pack={l.cantidadPack ?? ""}
          data-costo-unitario-base={c.precioBase}
        >
          <span>
            Precio proveedor:{" "}
            <strong>
              {fmt(l.precioProveedor ?? 0)} {presentacionDe(l.unidadCompra, l.cantidadPack)}
            </strong>
          </span>
          <span className="pack-sep">·</span>
          <span>
            Costo unitario aplicado:{" "}
            <strong>
              {fmt(c.precioBase)}{" "}
              / und
            </strong>
          </span>
          {esPack && (
            <span className="pack-nota" data-testid="calc-linea-pack-nota">
              {fmt(l.precioProveedor ?? 0)} ÷ {miles(l.cantidadPack ?? 1)} unidades del
              paquete
              {c.presentaciones > 0 ? (
                <>
                  {" · "}
                  {miles(c.presentaciones)} paquete{c.presentaciones === 1 ? "" : "s"} ={" "}
                  {miles(c.compradas)} unidades compradas ={" "}
                  <strong data-costo-base-linea={Math.round(c.precioBase * c.compradas)}>
                    {fmt(c.precioBase * c.compradas)}
                  </strong>{" "}
                  de costo base
                </>
              ) : null}
            </span>
          )}
        </div>
      )}

      {l.idProducto && !l.idSnapshot && (
        <div className="info info-amber mt10 mb0 f12" data-testid="calc-linea-sin-snapshot">
          Este producto no tiene una observacion de precio utilizable, asi que la linea
          sirve para estimar pero no se puede emitir como cotizacion real.
        </div>
      )}

      <div className="mt10">
        {c.sobrantes > 0 && <div className="info info-amber">
          <p>Desembolso: {fmt(c.precioBase * c.compradas)}. Sobrantes reutilizables: {c.sobrantes}. La reasignacion no reduce el desembolso.</p>
          <label>Valor reasignado a sobrantes (maximo {fmt(c.precioBase * c.sobrantes)})</label>
          <CampoMoneda valor={l.reasignacionSobrante ?? ""} ariaLabel="Valor reasignado a sobrantes" alCambiar={v => editar({ reasignacionSobrante: v })} />
          <label>Motivo de reutilizacion<input aria-label="Motivo de reutilizacion" value={l.motivoAjuste ?? ""} onChange={e => editar({ motivoAjuste: e.target.value })} /></label>
        </div>}
        <div className="lbl">🎨 Tecnica de marcacion de este producto</div>
        {l.requiereRevisarTecnica && <div role="alert">La marcacion del historico no tiene una configuracion reutilizable. Selecciona la tecnica y revisa medidas y tarifas antes de validar. <button type="button" onClick={() => editar({ tecnica: "ninguna", requiereRevisarTecnica: false })}>Quitar marcacion de la nueva cotizacion</button></div>}
        <select
          data-testid="calc-linea-tecnica"
          aria-label={`Tecnica de marcacion del producto ${indice + 1}`}
          value={l.tecnica}
          onChange={(e) => editar({ tecnica: e.target.value as TecnicaLinea, requiereRevisarTecnica: false })}
        >
          {TECNICAS.map((t) => (
            <option key={t.v} value={t.v}>
              {t.l}
            </option>
          ))}
        </select>
      </div>

      <div className="linea-tec">{panelTecnica()}</div>

      <div className="extras-box">
        <div className="extras-tit">Costos adicionales de este producto</div>
        <div className="extras-help">
          Elige si cada costo se cobra por unidad o una sola vez para esta linea. Los costos fijos se reparten entre su cantidad de unidades.
        </div>
        <div className="presets">
          {[
            ["🧑‍🏭 Mano de obra", "Mano de obra", "8000"],
            ["🛍 Empaque", "Empaque", "3000"],
            ["🚚 Flete / envio", "Flete / envio", "9000"],
          ].map(([etiq, nombre, valor]) => (
            <button
              type="button"
              key={String(etiq)}
              className="pre-btn"
              onClick={() =>
                editar({ otros: [...l.otros, { name: String(nombre), val: String(valor) }] })
              }
            >
              {etiq}
            </button>
          ))}
        </div>
        {l.otros.map((co, j) => (
          <div className="crow costo-linea" key={`${l.id}-c${j}`}>
            <input
              type="text"
              value={co.name}
              placeholder="Nombre del costo"
              aria-label="Nombre del costo adicional"
              data-testid="calc-linea-costo-nombre"
              onChange={(e) => editarCosto(j, { name: e.target.value })}
            />
            <CampoMoneda
              valor={co.val}
              testId="calc-linea-costo-valor"
              ariaLabel={co.modo === "TOTAL" ? "Costo fijo de la linea" : "Costo adicional por unidad"}
              alCambiar={(v) => editarCosto(j, { val: v })}
            />
            <select aria-label="Aplicacion del costo adicional" value={co.modo ?? "UNITARIO"} onChange={(e) => editarCosto(j, { modo: e.target.value as "UNITARIO" | "TOTAL" })}>
              <option value="UNITARIO">Por unidad</option><option value="TOTAL">Fijo de la linea</option>
            </select>
            <button
              type="button"
              className="btn-del"
              aria-label="Quitar costo"
              onClick={() => editar({ otros: l.otros.filter((_, k) => k !== j) })}
            >
              ×
            </button>
          </div>
        ))}
        <button
          type="button"
          className="btn-add"
          data-testid="calc-linea-add-costo"
          onClick={() => editar({ otros: [...l.otros, { name: "", val: "0" }] })}
        >
          ＋ Agregar costo de este producto
        </button>
      </div>

      {c.cantidad <= 0 && (
        <div className="info info-amber mt10 mb0 f12">
          {esPack
            ? "Escribi cuantos paquetes lleva el cliente para que esta linea sume al pedido."
            : "Escribi la cantidad de este producto para que sume al pedido."}
        </div>
      )}

      <div
        className="linea-total"
        data-testid="calc-linea-detalle"
        data-costo-unitario={Math.round(c.costoUnitTotal)}
        data-subtotal={Math.round(c.subtotal)}
        data-ganancia={Math.round(finanzas.ganancia)}
        data-unidades={c.cantidad}
        data-presentaciones={c.presentaciones}
        data-precio-venta-unitario={Math.round(precioVentaUnitario)}
        data-precio-venta-linea={Math.round(finanzas.precio)}
      >
        <span className="linea-total-desglose">
          ({fmt(c.precioBase)} base + {fmt(c.tecnicaUnit)} {c.tecnicaLabel} +{" "}
          {fmt(c.otrosUnit)} adicionales) = <strong>{fmt(c.costoUnitTotal)}/und</strong> ×{" "}
          {miles(c.cantidad)} und
        </span>
        <span className="linea-total-v">
          <span className="lt-costo">
            Costo: <strong>{fmt(c.subtotal)}</strong>
          </span>
          {/*
            PRECIO DE VENTA POR UNIDAD DE ESTA LINEA.
            Cada linea absorbe gastos globales en proporcion a su costo y usa
            el margen correspondiente a su cantidad. Es una estimacion antes
            del redondeo comercial; la validacion muestra el importe emitible.
          */}
          <span className="lt-precio" data-testid="calc-linea-precio-unitario">
            Precio de venta: <strong>{fmt(precioVentaUnitario)}/und</strong>
          </span>
          <span className="lt-precio" data-testid="calc-linea-precio-linea">
            Venta línea: <strong>{fmt(finanzas.precio)}</strong>
          </span>
          <span className="lt-gan" data-testid="calc-linea-ganancia">
            Ganancia: <strong>{fmt(finanzas.ganancia)}</strong>
          </span>
        </span>
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════
// Calculadora
// ═══════════════════════════════════════════════════════════════════════
export function CalculadoraCotizador({
  proveedoresIniciales,
  organizacionesIniciales = [],
  esAdmin,
  lineasIniciales,
  idOrganizacionInicial = "",
  notasIniciales = "",
}: {
  proveedoresIniciales: ProveedorOpcion[];
  organizacionesIniciales?: OrganizacionOpcion[];
  esAdmin: boolean;
  /**
   * Lineas de una cotizacion ya emitida que se quiere ajustar. La cotizacion
   * original NO se toca (es inmutable): esto solo precarga la calculadora para
   * emitir una NUEVA con numero propio. Ver lib/cotizacion-origen.ts.
   */
  lineasIniciales?: LineaInicial[];
  /** Cliente preseleccionado (desde /organizaciones/[id] o al modificar). */
  idOrganizacionInicial?: string;
  /** Nota sugerida y EDITABLE, no forzada (ej. "Ajusta a cotizacion #145..."). */
  notasIniciales?: string;
}) {
  const router = useRouter();
  const supabase = useMemo(() => crearClienteNavegador(), []);
  const [proveedores] = useState<ProveedorOpcion[]>(proveedoresIniciales);
  const [idOrganizacion, setIdOrganizacion] = useState(idOrganizacionInicial);
  const [organizaciones, setOrganizaciones] = useState<OrganizacionOpcion[]>(organizacionesIniciales);
  const [busquedaCliente, setBusquedaCliente] = useState("");
  const [errorCliente, setErrorCliente] = useState<string | null>(null);
  useEffect(() => {
    let activo = true;
    const timer = setTimeout(async () => {
      const q = busquedaCliente.trim().replace(/[%,()]/g, " ");
      let consulta = supabase.from("organizacion").select("id_organizacion, nombre_legal, nit").order("nombre_legal").limit(120);
      if (q) consulta = consulta.or(`nombre_legal.ilike.%${q}%,nit.ilike.%${q}%`);
      const { data, error } = await consulta;
      if (!activo) return;
      setErrorCliente(error ? "No se pudieron buscar los clientes." : null);
      if (data) setOrganizaciones((prev) => {
        const elegido = prev.find((o) => o.id_organizacion === idOrganizacion);
        return elegido && !data.some((o) => o.id_organizacion === elegido.id_organizacion) ? [elegido, ...data] : data;
      });
    }, 300);
    return () => { activo = false; clearTimeout(timer); };
  }, [busquedaCliente, supabase, idOrganizacion]);

  // ── A) lineas de producto ───────────────────────────────────────────
  // Inicializador perezoso: el estado se siembra UNA vez. Si el usuario borra
  // una linea precargada, no vuelve a aparecer en el siguiente render.
  const [lineas, setLineas] = useState<LineaProducto[]>(() =>
    lineasIniciales && lineasIniciales.length > 0
      ? lineasIniciales.map(lineaDesde)
      : [nuevaLinea()],
  );

  // ── emision de la cotizacion real ───────────────────────────────────
  const [notas, setNotas] = useState(notasIniciales);
  const [emitiendo, setEmitiendo] = useState(false);
  const [errorEmision, setErrorEmision] = useState<string | null>(null);

  // ── B) costos globales del pedido ───────────────────────────────────
  //
  // ARRANCAN VACIOS A PROPOSITO. Antes esto venia precargado con un gasto de
  // gasolina de $15.000 y tres maquinas ($2.500.000 + $800.000 + $3.000.000),
  // que sumaban $25.533 de costo y ~$44.147 de precio en una calculadora en la
  // que el usuario todavia no habia escrito nada. Eran valores inventados que
  // nadie habia ingresado, no se veian sin desplegar los paneles y ademas
  // viajaban prorrateados a CADA linea emitida como "Gastos generales y
  // desgaste del pedido". Un pedido vacio tiene que costar 0.
  //
  // Los valores no se perdieron: siguen a un click en los presets de cada
  // panel, que es donde corresponde elegirlos.
  const [opCosts, setOpCosts] = useState<Fila[]>([]);
  const [machines, setMachines] = useState<Maquina[]>([]);
  const [campos, setCampos] = useState<Record<string, string>>(CAMPOS_INICIALES);
  const [target, setTarget] = useState(40);
  const [margenConfirmado, setMargenConfirmado] = useState(false);
  const [idPlantilla, setIdPlantilla] = useState("");
  const [plantillas, setPlantillas] = useState<Array<{ id: string; codigo: string; version: number; estado: string; margen_base: number; tramos: EscalaMargen[] }>>([]);
  useEffect(() => { let activo = true; void supabase.rpc("fn_consola_plantillas_margen").then(({ data }) => { if (activo && Array.isArray(data)) setPlantillas(data.filter(p => p.estado === "ACTIVE")); }); return () => { activo = false; }; }, [supabase]);
  const [usarEscalas, setUsarEscalas] = useState(false);
  const [escalas, setEscalas] = useState<EscalaMargen[]>([]);
  useEffect(() => { setMargenConfirmado(false); }, [target, escalas, usarEscalas, idOrganizacion, idPlantilla]);
  const escalasActivas = usarEscalas ? escalas : [];
  const [validando, setValidando] = useState(false);
  const [validacion, setValidacion] = useState<{ firma: string; total: number; lineas: Array<{ linea: number; total: number; unidades: number; precio_unitario: number; costo_total: number | null }> } | null>(null);


  const setCampo = useCallback((clave: string, valor: string) => {
    setCampos((prev) => ({ ...prev, [clave]: valor }));
  }, []);

  const editarLinea = useCallback((id: string, patch: Partial<LineaProducto>) => {
    setLineas((prev) => prev.map((l) => (l.id === id ? { ...l, ...patch } : l)));
  }, []);

  // Porcentajes y medidas: parseFloat clasico ("." es decimal).
  const n = useCallback(
    (clave: string, alterno = 0) => parseFloat(campos[clave]) || alterno,
    [campos],
  );
  const ni = useCallback(
    (clave: string, alterno = 1) => parseInt(campos[clave], 10) || alterno,
    [campos],
  );
  // Importes: "." es separador de miles.
  const nm = useCallback((clave: string) => aNumero(campos[clave]), [campos]);

  // ── TARIFAS COMPARTIDAS DEL TALLER ──────────────────────────────────
  const dtfRollW = n("dtfRollWidth", 58);
  const dtfPricePerMeter = nm("dtfPricePerMeter");
  const ironW = n("ironWatts", 0);
  const ironS = n("ironSecs", 0);
  const ironP = ni("ironPasses", 1);
  const ironKwh = nm("ironKwhPrice");
  const ironCost = (ironW / 1000) * ((ironS * ironP) / 3600) * ironKwh;

  const sublPaperPkg = nm("sublPaperPkg");
  const sublInkSet = nm("sublInkSet");
  const sublInkYield = n("sublInkYield", 1);
  const mugWatts = n("mugWatts", 0);
  const mugSecs = n("mugSecs", 0);
  const mugPasses = ni("mugPasses", 1);
  const mugKwh = nm("mugKwh");
  const sublTotalSecs = mugSecs * mugPasses;
  const sublElecUnit = (mugWatts / 1000) * (sublTotalSecs / 3600) * mugKwh;

  const dtfvPrice = nm("dtfvPrice");
  const dtfvRollW = n("dtfvRollW", 57);

  const tarifas: Tarifas = {
    dtfRollW,
    dtfPricePerMeter,
    ironCost,
    sublPaperPkg,
    sublInkSet,
    sublInkYield,
    mugWatts,
    sublTotalSecs,
    sublElecUnit,
    dtfvPrice,
    dtfvRollW,
  };

  // ── A) CALCULO POR LINEA (formulas fisicas del HTML original) ───────
  const calcularLinea = (l: LineaProducto): CalculoLinea => {
    // Lo digitado son unidades a entregar; las presentaciones se derivan.
    const esPack = l.unidadCompra === "PACK" && !!l.cantidadPack && l.cantidadPack > 0;
    const porPresentacion = esPack ? (l.cantidadPack as number) : 1;
    const cantidad = Math.max(0, Math.floor(num(l.cantidad, 0)));
    const presentaciones = Math.ceil(cantidad / porPresentacion);
    const compradas = presentaciones * porPresentacion;
    const sobrantes = compradas - cantidad;
    const qEff = cantidad > 0 ? cantidad : 1;
    const precioBase = aNumero(l.precioUnitario);
    const costoCompra = precioBase * compradas - aNumero(l.reasignacionSobrante ?? "");

    let tecnicaUnit = 0;
    let tecnicaLabel = "Sin marcacion";
    let errorDtf: string | undefined;

    if (l.tecnica === "bordado") {
      const embFixed = aNumero(l.embFixed);
      const embExtra = aNumero(l.embExtra);
      tecnicaUnit = embFixed / qEff + embExtra;
      tecnicaLabel = `Bordado (${fmt(embFixed)} / ${qEff} uds)`;
    } else if (l.tecnica === "dtf") {
      const estimacion = estimarDtf(l.disenos, qEff, { anchoUtilCm: dtfRollW, permitirRotacion: true, separacionCm: 0, minimoMetros: 0, reservaPct: num(l.dtfWaste, 0) });
      errorDtf = estimacion.ok ? undefined : estimacion.error;
      const film = estimacion.ok ? estimacion.metrosFacturables * dtfPricePerMeter / qEff : 0;
      tecnicaUnit = film + (l.ironInclude ? ironCost : 0);
      tecnicaLabel = `DTF textil (${l.disenos.length} diseno/s)`;
    } else if (l.tecnica === "sublimacion") {
      const imgPerSheet = num(l.sublImgPerSheet, 1);
      const paperUnit = sublPaperPkg / 100 / imgPerSheet;
      const inkUnit = sublInkSet / sublInkYield / imgPerSheet;
      tecnicaUnit = paperUnit + inkUnit + sublElecUnit;
      tecnicaLabel = "Sublimacion mug";
    } else if (l.tecnica === "dtfv") {
      const w = num(l.dtfvW, 1);
      const h = num(l.dtfvH, 1);
      const imp = num(l.dtfvImpresiones, 1);
      const estimacion = estimarDtf([{ w, h, qty: imp }], qEff, { anchoUtilCm: dtfvRollW, permitirRotacion: true, separacionCm: 0, minimoMetros: 0, reservaPct: num(l.dtfvWaste, 0) });
      errorDtf = estimacion.ok ? undefined : estimacion.error;
      tecnicaUnit = estimacion.ok ? estimacion.metrosFacturables * dtfvPrice / qEff : 0;
      tecnicaLabel = "DTF-UV rigido";
    }

    const otrosUnit = l.otros.reduce((s, co) => s + aNumero(co.val) / (co.modo === "TOTAL" ? qEff : 1), 0);
    const costoUnitTotal = costoCompra / qEff + tecnicaUnit + otrosUnit;
    return {
      presentaciones,
      cantidad,
      esPack,
      porPresentacion,
      qEff,
      precioBase,
      compradas, sobrantes, costoCompra,
      tecnicaUnit,
      tecnicaLabel,
      errorDtf,
      otrosUnit,
      costoUnitTotal,
      subtotal: costoUnitTotal * cantidad,
    };
  };

  const calculos = lineas.map(calcularLinea);

  // ── B) TOTALES DEL PEDIDO ───────────────────────────────────────────
  const totalUnidades = calculos.reduce((s, c) => s + c.cantidad, 0);
  const qPedido = totalUnidades > 0 ? totalUnidades : 1;
  const productosDiferentes = lineas.length;

  const baseProductos = calculos.reduce((s, c) => s + c.costoCompra, 0);
  const tecnicasProductos = calculos.reduce((s, c) => s + c.tecnicaUnit * c.cantidad, 0);
  const extrasProductos = calculos.reduce((s, c) => s + c.otrosUnit * c.cantidad, 0);
  const subtotalGeneralProductos = calculos.reduce((s, c) => s + c.subtotal, 0);

  const sumOp = opCosts.reduce((s, c) => s + aNumero(c.val), 0);
  const opPerUnit = sumOp / qPedido;
  const machDep = machines.reduce((s, m) => {
    const usos = aNumero(m.uses);
    return s + (usos > 0 ? aNumero(m.price) / usos : 0);
  }, 0);
  const machPerUnit = machDep / qPedido;
  const globales = sumOp + machDep;

  const costoPedido = subtotalGeneralProductos + globales;
  const costoUnitPromedio = costoPedido / qPedido;

  // ── C) RETENCIONES + MARGEN SOBRE VENTA (formula intacta) ───────────
  const rICA = n("rICA", 0);
  const rFuente = n("rFuente", 0);
  const rIVA = n("rIVA", 0);
  const rOther = n("rOther", 0);
  const retPct = 0; // No hay bases fiscales confirmadas: no estimar descuentos.
  const retFactor = 1 - retPct / 100;

  const precioPara = (pt: number) => precioConMargen(costoPedido, pt, retPct);
  const finanzas: FinanzasLinea[] = calculos.map((c) => {
    const peso = subtotalGeneralProductos > 0 ? c.subtotal / subtotalGeneralProductos : 1 / Math.max(1, calculos.length);
    const costoPleno = c.subtotal + globales * peso;
    const precioLinea = precioComercial(costoPleno, margenPorCantidad(c.cantidad, target, escalasActivas), c.cantidad);
    return { costoPleno, precio: precioLinea, ganancia: precioLinea * retFactor - costoPleno };
  });
  const price = finanzas.reduce((s, f) => s + f.precio, 0);
  const received = price * retFactor;
  const retAbsICA = 0;
  const retAbsFuente = 0;
  const retAbsIVA = 0;
  const retAbsOther = 0;
  const retAbsTotal = price - received;
  const profit = received - costoPedido;
  const realMargin = received > 0 ? profit / received * 100 : 0;
  const precioPromedioUnidad = totalUnidades > 0 ? price / totalUnidades : 0;

  // ── E) EMISION DE LA COTIZACION REAL ────────────────────────────────
  // La calculadora ESTIMA. La cotizacion emitida la calcula la base de datos
  // contra el snapshot de precio del proveedor y la politica de margen
  // vigente, que es lo unico auditable. Lo que si viaja desde aca son los
  // costos que solo existen aca: la tecnica calculada con formulas fisicas,
  // los adicionales del producto y la parte prorrateada de los gastos
  // globales del pedido. Por eso el total emitido puede no coincidir al peso
  // con la estimacion de arriba, y se avisa en pantalla.
  const lineasParaEmitir = lineas
    .map((l, i) => ({ l, c: calculos[i], f: finanzas[i], indice: i }))
    .filter((x) => x.l.idSnapshot !== "" && x.c.presentaciones > 0);

  const problemasEmision: string[] = [];
  if (!margenConfirmado) problemasEmision.push("Confirma el margen para este cliente antes de validar.");
  if (!esAdmin && !idPlantilla) problemasEmision.push("Elige una plantilla de margen publicada; solo ADMIN puede fijar un margen para este pedido.");
  const errorEscalas = validarEscalas(escalasActivas, target);
  if (errorEscalas) problemasEmision.push(errorEscalas);
  if (!Number.isFinite(price) || retPct < 0 || retPct >= 100) problemasEmision.push("Revisa el margen y las retenciones: deben ser menores a 100%.");

  if (!idOrganizacion) {
    problemasEmision.push("Elegi el cliente (organizacion) al que se le emite la cotizacion.");
  }
  lineas.forEach((l, i) => {
    if (l.requiereRevisarTecnica) problemasEmision.push(`Producto ${i + 1}: selecciona de nuevo la tecnica historica antes de validar.`);
    if (!esAdmin && (l.tecnica !== "ninguna" || l.otros.some(co => aNumero(co.val) > 0) || globales > 0)) {
      problemasEmision.push(`Producto ${i + 1}: los costos manuales y la marcacion requieren validacion de ADMIN.`);
    }
    const reasignacion = aNumero(l.reasignacionSobrante ?? "");
    if (reasignacion < 0 || reasignacion > calculos[i].sobrantes * calculos[i].precioBase || (reasignacion > 0 && (!esAdmin || !l.motivoAjuste?.trim()))) problemasEmision.push(`Producto ${i + 1}: revisa el importe y motivo de sobrantes reutilizables.`);
    if (calculos[i].errorDtf) problemasEmision.push(`Producto ${i + 1}: ${calculos[i].errorDtf}`);
    if (l.idSnapshot && !l.unidadCompra) {
      problemasEmision.push(`Producto ${i + 1}: la oferta no declara su unidad de compra. Registra una nueva oferta verificada antes de emitir.`);
    }
    if (!l.idProducto || !l.idSnapshot) {
      problemasEmision.push(
        `Producto ${i + 1}: no tiene observacion de precio del proveedor, no se puede emitir.`,
      );
    }
    if (!Number.isSafeInteger(Number(l.cantidad)) || Number(l.cantidad) !== calculos[i].cantidad || calculos[i].cantidad <= 0) {
      problemasEmision.push(
        `Producto ${i + 1}: falta la cantidad entera de unidades a entregar.`,
      );
    }
  });
  if (lineasParaEmitir.length === 0) {
    problemasEmision.push(
      "Agrega al menos un producto de proveedor con cantidad mayor a cero.",
    );
  }
  if (lineasParaEmitir.length > 0 && !(price > 0)) {
    problemasEmision.push("El total de la cotizacion debe ser mayor a cero.");
  }

  const puedeEmitir = problemasEmision.length === 0 && !emitiendo && !validando;

  // Idempotencia: la misma carga reintentada reusa la clave, asi que un doble
  // click o un reintento no crea dos cotizaciones. Cambiar cualquier dato
  // genera una clave nueva.
  const claveEmision = useRef<{ firma: string; clave: string } | null>(null);

  const construirCarga = () => ({
    id_organizacion: idOrganizacion,
    margen_override_pct: esAdmin ? target : null,
    id_plantilla_margen: idPlantilla || null,
    margen_confirmado: margenConfirmado,
    notas: notas.trim() === "" ? null : notas.trim(),
    lineas: lineasParaEmitir.map(({ l, c, f }) => {
      const extras: Array<{
        descripcion: string;
        costo_unitario?: number;
        costo_total?: number;
      }> = [];

      if (l.tecnica === "bordado") {
        if (aNumero(l.embFixed) > 0) extras.push({ descripcion: "Preparacion de bordado", costo_total: aNumero(l.embFixed) });
        if (aNumero(l.embExtra) > 0) extras.push({ descripcion: "Bordado por unidad", costo_unitario: aNumero(l.embExtra) });
      } else if (c.tecnicaUnit > 0 && l.tecnica !== "dtf" && l.tecnica !== "dtfv") {
        extras.push({
          descripcion: `Marcacion: ${c.tecnicaLabel}`,
          costo_unitario: Number(c.tecnicaUnit.toFixed(4)),
        });
      }
      l.otros.forEach((co) => {
        const valor = aNumero(co.val);
        if (valor > 0) {
          extras.push({
            descripcion: co.name.trim() || "Costo adicional del producto",
            ...(co.modo === "TOTAL" ? { costo_total: Number(valor.toFixed(2)) } : { costo_unitario: Number(valor.toFixed(4)) }),
          });
        }
      });
      const globalesLinea = f.costoPleno - c.subtotal;
      if (globalesLinea > 0.5) {
        extras.push({
          descripcion: "Gastos generales y desgaste del pedido (prorrateado)",
          costo_total: Number(globalesLinea.toFixed(2)),
        });
      }

      return {
        id_precio_proveedor_snapshot: l.idSnapshot,
        id_producto_proveedor: l.idProducto,
        unidades_entregar: c.cantidad,
        id_plantilla_margen: idPlantilla || null,
        reasignacion_sobrante: aNumero(l.reasignacionSobrante ?? ""),
        motivo_ajuste: l.motivoAjuste?.trim() || null,
        configuracion_tecnica: l.tecnica === "dtf" || l.tecnica === "dtfv" ? {
          tipo: l.tecnica,
          disenos: l.tecnica === "dtf" ? l.disenos : [{ w: num(l.dtfvW, 1), h: num(l.dtfvH, 1), qty: num(l.dtfvImpresiones, 1) }],
          ancho_rollo: l.tecnica === "dtf" ? dtfRollW : dtfvRollW,
          precio_metro: l.tecnica === "dtf" ? dtfPricePerMeter : dtfvPrice,
          reserva_pct: num(l.tecnica === "dtf" ? l.dtfWaste : l.dtfvWaste, 0),
          rotacion: true, separacion: 0, minimo_metros: 0,
          costo_aplicacion_unitario: l.tecnica === "dtf" && l.ironInclude ? ironCost : 0,
        } : {},
        ...(esAdmin ? { costo_unitario_override: c.precioBase, margen_linea_pct: margenPorCantidad(c.cantidad, target, escalasActivas) } : {}),
        retencion_pct: 0,
        marking_lines: [] as unknown[],
        costos_adicionales: extras,
      };
    }),
  });

  const firmaActual = JSON.stringify(construirCarga());
  const validacionVigente = validacion?.firma === firmaActual ? validacion : null;
  const validar = async () => {
    if (!puedeEmitir) return;
    const carga = construirCarga();
    const firma = JSON.stringify(carga);
    setValidando(true); setErrorEmision(null); setValidacion(null);
    try {
      const resultado = await previsualizarCotizacionMultilinea(carga);
      if (resultado.ok) setValidacion({ firma, total: resultado.total, lineas: resultado.lineas });
      else setErrorEmision(resultado.mensaje);
    } catch { setErrorEmision("No se pudo conectar para validar el precio. Intenta nuevamente."); }
    finally { setValidando(false); }
  };

  const emitir = async () => {
    if (!puedeEmitir || !validacionVigente) return;
    setEmitiendo(true);
    setErrorEmision(null);
    try {
      const carga = construirCarga();
      const firma = JSON.stringify(carga);
      if (!claveEmision.current || claveEmision.current.firma !== firma) {
        claveEmision.current = {
          firma,
          clave:
            typeof crypto !== "undefined" && "randomUUID" in crypto
              ? crypto.randomUUID()
              : `calc-${Date.now()}-${Math.random().toString(16).slice(2)}`,
        };
      }

      const resultado = await emitirCotizacionMultilinea({
        ...carga,
        idempotency_key: claveEmision.current.clave,
        total_esperado: validacionVigente.total,
      });

      if (!resultado.ok) {
        setErrorEmision(resultado.mensaje);
        setEmitiendo(false);
        return;
      }
      router.push(`/cotizador/${resultado.id_cotizacion}`);
    } catch (e) {
      setErrorEmision(
        e instanceof Error ? e.message : "No se pudo emitir la cotizacion.",
      );
      setEmitiendo(false);
    }
  };

  const HINTS: Array<[number, number, string]> = [
    [0, 10, "Muy ajustado - apenas cubre costos"],
    [10, 20, "Bajo - funciona con mucho volumen"],
    [20, 35, "Razonable para productos personalizados"],
    [35, 50, "Buen margen - sostenible"],
    [50, 100, "Excelente - verifica que el mercado lo aguante"],
  ];
  const hint = HINTS.find((x) => realMargin >= x[0] && realMargin < x[1]);

  // ── helpers de render ───────────────────────────────────────────────
  const campoTarifa = (k: string, etiq: string, nota?: string) => (
    <div key={k}>
      <div className="lbl">{etiq}</div>
      {CAMPOS_MONEDA.has(k) ? (
        <CampoMoneda valor={campos[k]} ariaLabel={etiq} alCambiar={(v) => setCampo(k, v)} />
      ) : (
        <input
          type="number"
          min={0}
          className="mono"
          aria-label={etiq}
          value={campos[k]}
          onChange={(e) => setCampo(k, e.target.value)}
        />
      )}
      {nota && <div className="nota">{nota}</div>}
    </div>
  );

  type FilaDesglose = { n: string; v: number; tono?: "resta" | "suma" | "total" };
  const desglose: FilaDesglose[] = [
    { n: `Subtotal productos (${totalUnidades} und)`, v: baseProductos },
    ...(tecnicasProductos > 0 ? [{ n: "Tecnicas de marcacion", v: tecnicasProductos }] : []),
    ...(extrasProductos > 0
      ? [{ n: "Costos adicionales de productos", v: extrasProductos }]
      : []),
    ...(sumOp > 0 ? [{ n: "Gastos generales del pedido", v: sumOp }] : []),
    ...(machDep > 0 ? [{ n: "Desgaste de maquinas", v: machDep }] : []),
    { n: "Costo total del pedido", v: costoPedido, tono: "total" },
    { n: "Ganancia neta estimada", v: profit, tono: "suma" },
    ...(retAbsTotal > 0
      ? [{ n: `Retenciones (${retPct.toFixed(3)}%)`, v: retAbsTotal, tono: "resta" as const }]
      : []),
    { n: "Total cotizacion (precio al cliente)", v: price, tono: "total" },
  ];

  return (
    <div className="calcv2">
      <div className="wrap">
        <div className="cab">
          <div className="eyebrow">Estimacion rapida - no emite cotizacion</div>
          <h2 className="big-h1">
            &iquest;A cuanto le <em>vendo?</em>
          </h2>
          <p className="subtitle">
            Cada producto lleva su propio proveedor, costo, cantidad, tecnica y costos
            adicionales. Abajo se suman los gastos que aplican al pedido completo y se
            calcula el precio con retenciones de persona natural incluidas.
          </p>
        </div>

        {/* ═══ A) PRODUCTOS DEL PEDIDO ═══ */}
        <div className="card">
          <div className="sec">
            <span className="sec-icon icon-amber">🧵</span> Productos del pedido
            <span className="sec-meta" data-testid="calc-conteo">
              {productosDiferentes} producto(s) · {totalUnidades} unidad(es)
            </span>
          </div>

          {lineas.map((l, i) => (
            <TarjetaLinea
              key={l.id}
              linea={l}
              indice={i}
              esUnica={lineas.length === 1}
              proveedores={proveedores}
              supabase={supabase}
              tarifas={tarifas}
              calculo={calculos[i]}
              finanzas={finanzas[i]}
              esAdmin={esAdmin}
              editar={(patch) => editarLinea(l.id, patch)}
              eliminar={() => setLineas((prev) => prev.filter((x) => x.id !== l.id))}
            />
          ))}

          <button
            type="button"
            className="btn-add btn-add-big"
            data-testid="calc-agregar-producto"
            onClick={() => setLineas((prev) => [...prev, nuevaLinea()])}
          >
            ＋ Agregar producto al pedido
          </button>

          <div
            className="info info-green mt12 mb0"
            data-testid="calc-subtotal-general"
            data-valor={Math.round(subtotalGeneralProductos)}
          >
            Subtotal general de productos: <strong>{fmt(subtotalGeneralProductos)}</strong> ·{" "}
            {productosDiferentes} producto(s) diferentes · {totalUnidades} unidad(es)
          </div>
        </div>

        {/* ═══ B) COSTOS GLOBALES DEL PEDIDO ═══ */}
        <div className="cols2">
          <div className="card">
            <div className="sec">
              <span className="sec-icon icon-amber">⚙️</span> Gastos generales del pedido
            </div>

            <div className="info info-amber mb12">
              Aplican al pedido completo, no a un producto especifico: gasolina,
              transporte, internet, tu tiempo. Se ingresan como total del pedido y se
              reparten entre la suma de las cantidades de todos los productos.
            </div>

            <div className="presets">
              <span className="presets-tit">Agregar gasto tipico:</span>
              {[
                ["⛽ Gasolina", "Gasolina / transporte", "15000"],
                ["📱 Internet", "Internet / WhatsApp", "10000"],
                ["⏱ Mi tiempo", "Mi tiempo (gestion)", "20000"],
                ["🛍 Empaque", "Empaque extra", "5000"],
                ["＋ Otro", "", "0"],
              ].map(([etiq, nombre, valor]) => (
                <button
                  type="button"
                  key={String(etiq)}
                  className="pre-btn"
                  onClick={() =>
                    setOpCosts((prev) => [...prev, { name: String(nombre), val: String(valor) }])
                  }
                >
                  {etiq}
                </button>
              ))}
            </div>

            {opCosts.length === 0 && (
              <div className="info info-blue mb12 f12" data-testid="calc-sin-gastos">
                Sin gastos generales cargados: este pedido no suma nada por este
                concepto. Agrega los que apliquen con los botones de arriba.
              </div>
            )}

            <div className="crow crow-head">
              <span>Gasto</span>
              <span>Total pedido ($)</span>
              <span />
            </div>
            {opCosts.map((c, i) => (
              <div className="crow" key={`op-${i}`}>
                <input
                  type="text"
                  value={c.name}
                  placeholder="Descripcion del gasto"
                  aria-label="Descripcion del gasto"
                  onChange={(e) =>
                    setOpCosts((prev) =>
                      prev.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)),
                    )
                  }
                />
                <CampoMoneda
                  valor={c.val}
                  testId="calc-gasto-valor"
                  ariaLabel="Valor del gasto del pedido"
                  alCambiar={(v) =>
                    setOpCosts((prev) => prev.map((x, j) => (j === i ? { ...x, val: v } : x)))
                  }
                />
                <button
                  type="button"
                  className="btn-del"
                  aria-label="Quitar gasto"
                  onClick={() => setOpCosts((prev) => prev.filter((_, j) => j !== i))}
                >
                  ×
                </button>
              </div>
            ))}
            <button
              type="button"
              className="btn-add"
              onClick={() => setOpCosts((prev) => [...prev, { name: "", val: "0" }])}
            >
              ＋ Agregar gasto del pedido
            </button>
            <div
              className="info info-green mt10 mb0"
              data-testid="calc-gastos-info"
              data-total={Math.round(sumOp)}
              data-unidades={totalUnidades}
              data-por-unidad={Math.round(opPerUnit)}
            >
              Total gastos del pedido: <strong>{fmt(sumOp)}</strong> ÷ {totalUnidades} uds de
              todo el pedido = <strong>{fmt(opPerUnit)}/und</strong>
              {totalUnidades === 0 ? " (aun sin unidades: se divide entre 1)" : ""}
            </div>
          </div>

          <div className="col-stack">
            {/* Tarifas del taller: insumos compartidos, no una tecnica global */}
            <div className="card">
              <details>
                <summary className="sum-plegable">
                  🛠️ Tarifas y consumos del taller — precio del rollo, papel, tinta, kWh
                </summary>
                <div className="info info-blue mt12">
                  Esto NO es la tecnica del pedido (esa la elige cada producto): son los
                  precios de tus insumos y maquinas, iguales para todos los productos que
                  usen esa tecnica.
                </div>

                <div className="tarifa-tit">🖨️ DTF textil</div>
                <div className="linea-grid2">
                  {campoTarifa("dtfPricePerMeter", "Precio metro lineal ($)")}
                  {campoTarifa("dtfRollWidth", "Ancho rollo (cm)", `1 m = ${dtfRollW}×100 cm`)}
                </div>

                <div className="tarifa-tit">⚡ Plancha DTF</div>
                <div className="linea-grid4">
                  {campoTarifa("ironWatts", "Potencia (W)")}
                  {campoTarifa("ironSecs", "Seg/pasada")}
                  {campoTarifa("ironPasses", "Pasadas")}
                  {campoTarifa("ironKwhPrice", "$/kWh")}
                </div>
                <div className="nota mt6">
                  {ironW}W × {ironS * ironP}seg × ${miles(ironKwh)}/kWh ={" "}
                  <strong>{fmt(ironCost)}/prenda</strong>
                </div>

                <div className="tarifa-tit">🎨 Sublimacion</div>
                <div className="linea-grid4">
                  {campoTarifa("sublPaperPkg", "Papel 100 hojas ($)")}
                  {campoTarifa("sublInkSet", "Set tinta CMYK ($)")}
                  {campoTarifa("sublInkYield", "Rendimiento (hojas/set)")}
                  {campoTarifa("mugWatts", "Plancha mug (W)")}
                </div>
                <div className="linea-grid4 mt8">
                  {campoTarifa("mugSecs", "Seg/pasada")}
                  {campoTarifa("mugPasses", "Pasadas")}
                  {campoTarifa("mugKwh", "$/kWh")}
                  <div />
                </div>

                <div className="tarifa-tit">🖨️ DTF-UV (rigidos)</div>
                <div className="linea-grid2">
                  {campoTarifa("dtfvPrice", "Precio metro lineal ($)")}
                  {campoTarifa("dtfvRollW", "Ancho rollo (cm)", "Tu dato: 57 cm")}
                </div>
              </details>
            </div>

            {/* Desgaste de maquinas: arranca CONTRAIDA */}
            <div className="card">
              <details data-testid="calc-detalle-maquinas">
                <summary className="sum-plegable">
                  🔧 Desgaste de maquinas &amp; consumo electrico —{" "}
                  <span className="sum-valor">{fmt(machDep)} del pedido</span>
                </summary>

                <div className="info info-blue mt12 mb14">
                  <strong>&iquest;Que es el valor de reposicion?</strong> Cuanto te costaria{" "}
                  <em>comprar esa maquina hoy</em> si se danara. No el precio que pagaste,
                  sino el precio actual.
                  <br />
                  <strong>&iquest;Que son los usos estimados?</strong> Cuantas veces
                  calculas que vas a usar esa maquina antes de que se dane o quede obsoleta.
                  <br />
                  <strong>Costo/uso</strong> = valor reposicion ÷ usos estimados. Aplica al
                  pedido completo.
                </div>

                {/* Las maquinas del taller entran por preset, no precargadas:
                    una maquina que no usas en este pedido no deberia sumarle
                    desgaste. */}
                <div className="presets">
                  <span className="presets-tit">Agregar maquina del taller:</span>
                  {[
                    ["🖨️ Plotter", "Plotter", "2500000", "500"],
                    ["⚡ Plancha calor DTF", "Plancha calor DTF", "800000", "1500"],
                    ["🎨 Impresora sublimacion", "Impresora sublimacion", "3000000", "600"],
                  ].map(([etiq, nombre, precio, usos]) => (
                    <button
                      type="button"
                      key={String(etiq)}
                      className="pre-btn"
                      data-testid="calc-maquina-preset"
                      onClick={() =>
                        setMachines((prev) => [
                          ...prev,
                          { name: String(nombre), price: String(precio), uses: String(usos) },
                        ])
                      }
                    >
                      {etiq}
                    </button>
                  ))}
                </div>

                {machines.length === 0 && (
                  <div className="info info-blue mb12 f12" data-testid="calc-sin-maquinas">
                    Sin maquinas cargadas: este pedido no suma desgaste. Agrega solo las
                    que realmente usas para producirlo.
                  </div>
                )}

                <div className="mach-row mach-head">
                  <span className="izq">Maquina</span>
                  <span>Valor reposicion ($)</span>
                  <span>Usos estimados</span>
                  <span />
                </div>
                {machines.map((m, i) => (
                  <div className="mach-row" key={`mach-${i}`}>
                    <input
                      type="text"
                      value={m.name}
                      placeholder="Nombre maquina"
                      aria-label="Nombre de la maquina"
                      onChange={(e) =>
                        setMachines((prev) =>
                          prev.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)),
                        )
                      }
                    />
                    <CampoMoneda
                      valor={m.price}
                      ariaLabel="Valor de reposicion"
                      alCambiar={(v) =>
                        setMachines((prev) =>
                          prev.map((x, j) => (j === i ? { ...x, price: v } : x)),
                        )
                      }
                    />
                    <input
                      type="number"
                      min={1}
                      className="mono"
                      aria-label="Usos estimados"
                      value={m.uses}
                      onChange={(e) =>
                        setMachines((prev) =>
                          prev.map((x, j) => (j === i ? { ...x, uses: e.target.value } : x)),
                        )
                      }
                    />
                    <button
                      type="button"
                      className="btn-del"
                      aria-label="Quitar maquina"
                      onClick={() => setMachines((prev) => prev.filter((_, j) => j !== i))}
                    >
                      ×
                    </button>
                  </div>
                ))}
                <button
                  type="button"
                  className="btn-add"
                  onClick={() =>
                    setMachines((prev) => [...prev, { name: "", price: "0", uses: "100" }])
                  }
                >
                  ＋ Agregar maquina
                </button>
                <div
                  className="info info-green mt10 mb0"
                  data-testid="calc-maquinas-info"
                  data-total={Math.round(machDep)}
                >
                  Total desgaste/und: <strong>{fmt(machPerUnit)}</strong> ({fmt(machDep)} del
                  pedido ÷ {totalUnidades} uds)
                </div>
              </details>
            </div>

            {/* Retenciones: arranca CONTRAIDA */}
            <div className="card">
              <p>Impuestos y retenciones pendientes de confirmar con bases explicitas. No alteran este precio antes de impuestos ni se estima el neto fiscal.</p>
              <details hidden data-testid="calc-detalle-retenciones">
                <summary className="sum-plegable">
                  🏛️ Retenciones que te aplican —{" "}
                  <span className="sum-valor">{retPct.toFixed(3)}%</span>
                </summary>

                <div className="info info-blue mt12">
                  Cuando facturas, el cliente te descuenta estas retenciones <em>antes</em>{" "}
                  de pagarte; el precio que ves ya hace ese ajuste.
                  <br />
                  <strong>· ReteICA</strong> dotaciones / confecciones en Bogota:{" "}
                  <strong>1.104%</strong>. <strong>· ReteFuente</strong> compra de bienes a
                  persona natural: <strong>2.5%</strong> (como servicios: 4%).{" "}
                  <strong>· No cobras IVA</strong> como persona natural no responsable — 0%.
                  {retPct > 0 && (
                    <>
                      <br />
                      De cada $100.000 facturados te retienen{" "}
                      <strong>{fmt(retPct * 1000)}</strong> → recibes{" "}
                      <strong>{fmt((1 - retPct / 100) * 100000)}</strong>.
                    </>
                  )}
                </div>

                <div className="ret-grid">
                  {[
                    {
                      k: "rICA",
                      l: "ReteICA — Dotaciones / Confecciones (%)",
                      s: "Bogota: 1.104% · Otra ciudad: consulta tu tarifa",
                      max: 5,
                      step: 0.001,
                    },
                    {
                      k: "rFuente",
                      l: "ReteFuente — Compra de bienes / Dotaciones (%)",
                      s: "Persona natural bienes: 2.5% · Como servicios: 4%",
                      max: 20,
                      step: 0.1,
                    },
                    {
                      k: "rIVA",
                      l: "ReteIVA (%)",
                      s: "Persona natural no responsable de IVA: 0%",
                      max: 20,
                      step: 0.1,
                    },
                    {
                      k: "rOther",
                      l: "Otra retencion (%)",
                      s: "Si te aplican alguna adicional",
                      max: 10,
                      step: 0.1,
                    },
                  ].map((r) => (
                    <div className="ret-box" key={r.k}>
                      <label htmlFor={`calc-${r.k}`}>
                        {r.l}
                        <small>{r.s}</small>
                      </label>
                      <div className="pw">
                        <input
                          id={`calc-${r.k}`}
                          type="number"
                          min={0}
                          max={r.max}
                          step={r.step}
                          value={campos[r.k]}
                          onChange={(e) => setCampo(r.k, e.target.value)}
                        />
                      </div>
                    </div>
                  ))}
                </div>
              </details>
            </div>
          </div>
        </div>

        <section className="volumen-card" aria-label="Precios por mayor">
          <h3>Precios por cantidad</h3>
          <label>Plantilla publicada<select aria-label="Plantilla de margen" value={idPlantilla} onChange={e => { setIdPlantilla(e.target.value); const p = plantillas.find(p => p.id === e.target.value); if (p) { setTarget(Number(p.margen_base)); setEscalas(p.tramos ?? []); setUsarEscalas(true); } }}><option value="">Ajuste para este cliente</option>{plantillas.map(p => <option key={p.id} value={p.id}>{p.codigo} · v{p.version}</option>)}</select></label>
          <p>El costo fijo se reparte entre las unidades de cada producto. Un margen del 40% significa dividir el costo entre 0,60. Tambien puedes reducir el margen por cantidad.</p>
          <label><input type="checkbox" checked={usarEscalas} disabled={!esAdmin} onChange={(e) => setUsarEscalas(e.target.checked)} /> Aplicar margenes por volumen</label>
          {usarEscalas && <div>
            {escalas.map((escala, i) => <div className="linea-grid3" key={i}>
              <label>Desde (unidades)
                <input type="number" min="1" step="1" disabled={!esAdmin} aria-label={`Cantidad inicial de escala ${i + 1}`} value={Number.isNaN(escala.desde) ? "" : escala.desde} onChange={(e) => setEscalas(prev => prev.map((v, j) => j === i ? { ...v, desde: e.target.value === "" ? NaN : Number(e.target.value) } : v))} />
              </label>
              <label>Margen desde {escala.desde} unidades
              <input type="number" min="0" max="99" step="0.5" disabled={!esAdmin} aria-label={`Margen desde ${escala.desde} unidades`} value={escala.margen} onChange={(e) => setEscalas((prev) => prev.map((v, j) => j === i ? { ...v, margen: Number(e.target.value) } : v))} /> %
              </label>
              <button type="button" disabled={!esAdmin} aria-label={`Eliminar escala ${i + 1}`} onClick={() => setEscalas(prev => prev.filter((_, j) => j !== i))}>Eliminar escala</button>
            </div>)}
            <button type="button" disabled={!esAdmin} onClick={() => setEscalas(prev => {
              const ultima = [...prev].filter(e => Number.isSafeInteger(e.desde)).sort((a, b) => b.desde - a.desde)[0];
              return [...prev, { desde: (ultima?.desde ?? 0) + 1, margen: ultima?.margen ?? target }];
            })}>Agregar escala</button>
            {errorEscalas && <p role="alert">{errorEscalas}</p>}
          </div>}
          <p className="nota">Puedes agregar, eliminar y cambiar cantidades y margenes para este pedido. Cada tramo aplica desde su cantidad hasta antes del siguiente; el ultimo no tiene limite superior. Antes del primer tramo se usa el margen base. Por ejemplo, 1.150 unidades usan el tramo de 1.100 si el siguiente empieza en 1.200. Las escalas cuentan unidades de cada linea; un paquete se convierte a sus unidades.</p>
          {lineas.filter((l) => l.idProducto).map((l) => <div key={l.id}>
            <h4>{l.nombreProducto}</h4>
            <div className="tabla-contenedor"><table>
              <thead><tr><th>Unidades</th><th>Costo / und</th><th>Margen</th><th>Venta estimada / und</th><th>Total linea</th><th></th></tr></thead>
              <tbody>{cantidadesComparacion(calcularLinea(l).cantidad, escalasActivas).map((q) => {
                const pack = l.unidadCompra === "PACK" ? l.cantidadPack || 1 : 1;
                const presentaciones = Math.ceil(q / pack);
                const c = calcularLinea({ ...l, cantidad: String(q) });
                const otrosSubtotal = calculos.reduce((sum, calc, i) => sum + (lineas[i].id === l.id ? 0 : calc.subtotal), 0);
                const peso = c.subtotal + otrosSubtotal > 0 ? c.subtotal / (c.subtotal + otrosSubtotal) : 1 / lineas.length;
                const costo = c.subtotal + globales * peso;
                const margen = margenPorCantidad(c.cantidad, target, escalasActivas);
                const venta = precioComercial(costo, margen, c.cantidad);
                return <tr key={q}><td>{c.cantidad}{pack > 1 ? ` (${presentaciones} paquetes)` : ""}</td><td>{fmt(costo / c.cantidad)}</td><td>{margen}%</td><td>{fmt(venta / c.cantidad)}</td><td>{fmt(venta)}</td><td><button type="button" onClick={() => editarLinea(l.id, { cantidad: String(q) })}>Usar cantidad</button></td></tr>;
              })}</tbody>
            </table></div>
          </div>)}
          <p className="nota">Comparacion antes del redondeo comercial. Valida el precio final antes de emitir. Si el proveedor ofrece otro precio por mayor, registra esa oferta; no se inventa un descuento de compra.</p>
        </section>

        {/* ═══ MARGEN DESEADO (solo margen sobre venta) ═══ */}
        <div className="margen-card">
          <div className="margen-tit">🎯 Margen deseado</div>
          <div className="margen-row">
            <input
              type="range"
              disabled={!esAdmin}
              min={0}
              max={99}
              aria-label="Margen sobre venta"
              value={Math.min(Math.max(target, 0), 99)}
              onChange={(e) => setTarget(Number(e.target.value))}
            />
            <div className="pw margen-num">
              <input
                type="number"
                disabled={!esAdmin}
                min={0}
                max={99.99}
                data-testid="calc-margen"
                aria-label="Margen sobre venta (%)"
                value={target}
                onChange={(e) => setTarget(parseFloat(e.target.value) || 0)}
              />
            </div>
            <span className="margen-badge">{target}% sobre venta</span>
          </div>
          <div className="margen-help">
            <label><input type="checkbox" data-testid="calc-confirmar-margen" checked={margenConfirmado} onChange={e => setMargenConfirmado(e.target.checked)} /> Confirmo estos margenes para este cliente.</label>
            {(target === 0 || escalasActivas.some(e => e.margen === 0)) && <p role="alert">Margen cero: esta cotizacion no deja utilidad antes de impuestos.</p>}
            El margen sobre venta indica que porcentaje del precio final corresponde a tu
            ganancia.
            {hint ? ` ${hint[2]}.` : ""}
          </div>
        </div>

        {/* ═══ C) RESULTADO FINANCIERO ═══ */}
        <div className="resumen" data-testid="calc-resumen">
          <div className="res-hero">
            <div className="hero-main">
              <div className="hero-l">Precio final al cliente</div>
              <div
                className="hero-v"
                data-testid="calc-precio"
                data-valor={Math.round(price)}
              >
                {fmt(price)}
              </div>
              <div className="hero-sub">
                {retPct > 0
                  ? `Facturas ${fmt(price)} · te retienen ${fmt(retAbsTotal)} (${retPct.toFixed(2)}%)`
                  : "Sin retenciones — lo que facturas es lo que recibes"}
              </div>
            </div>
            <div className="hero-tiles">
              <div className="tile">
                <div className="tile-l">Lo que recibes despues de retenciones</div>
                <div className="tile-v" data-testid="calc-recibido">
                  {fmt(received)}
                </div>
              </div>
              <div className="tile tile-ok">
                <div className="tile-l">Ganancia neta estimada</div>
                <div className="tile-v" data-testid="calc-ganancia">
                  {fmt(profit)}
                </div>
              </div>
              <div className="tile">
                <div className="tile-l">Margen real</div>
                <div className="tile-v" data-testid="calc-margen-real">
                  {realMargin.toFixed(1)}%
                </div>
              </div>
            </div>
          </div>

          <div className="res-cols">
            <section className="panel">
              <h3 className="panel-tit">Desglose del pedido</h3>
              <div className="dg" data-testid="calc-desglose">
                {desglose.map((f, i) => (
                  <div
                    key={`dg-${i}`}
                    className={`dg-row${f.tono ? ` dg-${f.tono}` : ""}`}
                  >
                    <span>{f.n}</span>
                    <span className="dg-v">
                      {f.tono === "resta" ? `- ${fmt(f.v)}` : fmt(f.v)}
                    </span>
                  </div>
                ))}
              </div>
              {retPct > 0 && (
                <div className="dg-ret">
                  {rICA > 0 && <span>ReteICA {rICA}%: {fmt(retAbsICA)}</span>}
                  {rFuente > 0 && <span>ReteFuente {rFuente}%: {fmt(retAbsFuente)}</span>}
                  {rIVA > 0 && <span>ReteIVA {rIVA}%: {fmt(retAbsIVA)}</span>}
                  {rOther > 0 && <span>Otra {rOther}%: {fmt(retAbsOther)}</span>}
                </div>
              )}
            </section>

            <section className="panel">
              <h3 className="panel-tit">Metricas del pedido</h3>
              <div className="met-grid">
                <div className="met">
                  <div className="met-l">Total unidades</div>
                  <div className="met-v" data-testid="calc-resumen-unidades">
                    {miles(totalUnidades)}
                  </div>
                </div>
                <div className="met">
                  <div className="met-l">Productos diferentes</div>
                  <div className="met-v" data-testid="calc-resumen-lineas">
                    {productosDiferentes}
                  </div>
                </div>
                <div className="met">
                  <div className="met-l">Precio promedio por unidad</div>
                  <div
                    className="met-v"
                    data-testid="calc-resumen-promedio"
                    data-valor={Math.round(precioPromedioUnidad)}
                  >
                    {totalUnidades > 0 ? fmt(precioPromedioUnidad) : "-"}
                  </div>
                </div>
                <div className="met">
                  <div className="met-l">Costo promedio por unidad</div>
                  <div className="met-v" data-testid="calc-resumen-costo-promedio">
                    {totalUnidades > 0 ? fmt(costoUnitPromedio) : "-"}
                  </div>
                </div>
              </div>
              <div
                className="met-nota"
                data-testid="calc-costo-total"
                data-valor={Math.round(costoPedido)}
              >
                Costo total del pedido: <strong>{fmt(costoPedido)}</strong> ={" "}
                {fmt(subtotalGeneralProductos)} de productos + {fmt(globales)} de gastos
                globales.
              </div>
            </section>
          </div>

          <section className="panel">
            <h3 className="panel-tit">Comparar escenarios de margen</h3>
            <div className="sc-row">
              {[20, 35, 50].map((pt) => {
                const p2 = precioPara(pt);
                const pr2 = p2 * retFactor - costoPedido;
                const activo = Math.abs(pt - target) < 6;
                return (
                  <button
                    type="button"
                    key={pt}
                    className={`sc${activo ? " on" : ""}`}
                    onClick={() => setTarget(pt)}
                  >
                    <div className="sc-t">Margen {pt}%</div>
                    <div className="sc-p">{fmt(p2)}</div>
                    <div className="sc-d">Ganancia neta: {fmt(pr2)}</div>
                  </button>
                );
              })}
            </div>
          </section>
        </div>

        {/* ═══ E) EMITIR LA COTIZACION REAL Y SU PDF ═══ */}
        <div className="card emitir-card" data-testid="calc-emitir">
          <div className="sec">
            <span className="sec-icon icon-amber">🧾</span> Generar cotizacion y PDF
          </div>

          <div className="info info-blue mb12">
            Esto si emite una cotizacion real: queda registrada, con auditoria y con el
            costo de cada linea congelado contra la observacion de precio del proveedor.
            Valida primero el precio final: el servidor aplica los costos, margenes
            y retenciones configurados, junto con el redondeo comercial. La emision
            conserva ese total validado y los costos adicionales de cada linea.
          </div>

          <div className="linea-grid2">
            <div>
              <div className="lbl">Cliente (organizacion)</div>
              <input aria-label="Buscar cliente por nombre o NIT" placeholder="Buscar en todos los clientes por nombre o NIT" value={busquedaCliente} onChange={(e) => setBusquedaCliente(e.target.value)} />
              {errorCliente && <p role="alert">{errorCliente}</p>}
              <select
                data-testid="calc-organizacion"
                aria-label="Cliente de la cotizacion"
                value={idOrganizacion}
                onChange={(e) => setIdOrganizacion(e.target.value)}
              >
                <option value="">Elegi el cliente</option>
                {organizaciones.map((o) => (
                  <option key={o.id_organizacion} value={o.id_organizacion}>
                    {o.nombre_legal}
                    {o.nit ? ` - ${o.nit}` : ""}
                  </option>
                ))}
              </select>
              <div className="nota">
                Los datos de contacto salen del CRM de esa organizacion; no se piden
                aparte.
              </div>
            </div>
            <div>
              <div className="lbl">Notas de la cotizacion (opcional)</div>
              <input
                type="text"
                data-testid="calc-notas"
                aria-label="Notas de la cotizacion"
                placeholder="Ej: Atencion a: Maria Perez - entrega en sede norte"
                value={notas}
                onChange={(e) => setNotas(e.target.value)}
              />
              <div className="nota">
                Va al campo de notas de la cotizacion. Sirve para el &quot;atencion
                a&quot; que no esta en el CRM.
              </div>
            </div>
          </div>

          {problemasEmision.length > 0 && (
            <div className="info info-amber mb0 f12" data-testid="calc-emitir-problemas">
              <strong>Falta para poder emitir:</strong>
              <ul className="lista-problemas">
                {problemasEmision.map((p, i) => (
                  <li key={`pb-${i}`}>{p}</li>
                ))}
              </ul>
            </div>
          )}

          {errorEmision && (
            <div className="info info-amber mb0 f12" data-testid="calc-emitir-error">
              {errorEmision}
            </div>
          )}

          <button type="button" className="btn-add mt12" data-testid="calc-validar" disabled={!puedeEmitir} onClick={validar}>
            {validando ? "Validando precio..." : "Validar precio final"}
          </button>
          {validacionVigente && <div className="info" data-testid="calc-precio-validado" role="status">
            <strong>Total validado: {fmt(validacionVigente.total)}</strong>
            <ul>{validacionVigente.lineas.map((l) => <li key={l.linea}>Producto {l.linea}: {fmt(l.precio_unitario)} / und · {fmt(l.total)} total</li>)}</ul>
            Este importe sera el de la cotizacion y el PDF. Si cambias un dato, valida de nuevo.
          </div>}
          <button
            type="button"
            className="btn-add btn-add-big mt12"
            data-testid="calc-emitir-boton"
            disabled={!puedeEmitir || !validacionVigente}
            onClick={emitir}
          >
            {emitiendo ? "Emitiendo cotizacion..." : "🧾 Emitir cotizacion validada"}
          </button>

          <div
            className="nota mt6"
            data-testid="calc-emitir-resumen"
            data-lineas={lineasParaEmitir.length}
            data-unidades={totalUnidades}
          >
            Se emitiran {lineasParaEmitir.length} linea(s) de producto con {totalUnidades}{" "}
            unidad(es) en total.
          </div>
        </div>

        <div className="info info-amber mb0">
          <strong>Valida el importe antes de emitir.</strong> La vista estima tus costos y margenes.
          La validacion aplica las condiciones de compra y el redondeo comercial del servidor.
          Ese total es el que se guarda y aparece en el PDF.
          {!esAdmin && " Tu rol no ve costos ni margenes reales de la base."}
        </div>
      </div>
    </div>
  );
}
