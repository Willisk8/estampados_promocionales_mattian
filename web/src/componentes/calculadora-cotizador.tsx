"use client";

/**
 * Calculadora visual de precio - port del HTML de referencia cotizador-v2.html.
 *
 * Este es el unico componente de cliente del cotizador y es deliberado: los
 * sliders, tabs y el recalculo instantaneo no se pueden hacer con el flujo
 * server-rendered del resto de la pagina. La convencion de "cero JS de cliente"
 * se rompe aqui a proposito y solo aqui: la pagina sigue siendo un Server
 * Component y le pasa a este componente los datos iniciales y el rol.
 *
 * Diferencias conscientes contra el HTML de referencia:
 *  - "Costos del producto" ya no es una lista manual: el costo base por unidad
 *    sale de un proveedor y un producto reales de Supabase (RPC curadas).
 *  - La seccion de "Generar cotizacion .docx" del HTML no se porta: la emision
 *    real vive en el flujo proveedor-first de la misma pagina.
 *  - La tecnica de marcacion es la del HTML original (bordado / DTF /
 *    sublimacion / DTF-UV con formulas fisicas locales). Todavia NO consume las
 *    tecnicas curadas de la base.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { crearClienteNavegador } from "@/lib/supabase/navegador";
import "./calculadora-cotizador.css";

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

type Fila = { name: string; val: number };
type Maquina = { name: string; price: number; uses: number };
type Diseno = { name: string; w: number; h: number; qty: number };

const fmt = (n: number) =>
  "$" + Math.round(Number.isFinite(n) ? n : 0).toLocaleString("es-CO");

const MODE_COLOR: Record<string, string> = {
  camiseta: "var(--purple)",
  vaso: "#be185d",
  ambos: "var(--green)",
};

const DTF_COLORS = ["#7c3aed", "#1d4ed8", "#0369a1", "#065f46", "#92400e"];

const CAMPOS_INICIALES: Record<string, string> = {
  // bordado camiseta
  embFixed: "15000",
  embExtra: "0",
  // DTF camiseta
  dtfPricePerMeter: "12000",
  dtfRollWidth: "58",
  dtfWaste: "10",
  // plancha DTF
  ironWatts: "2000",
  ironSecs: "160",
  ironPasses: "2",
  ironKwhPrice: "900",
  // sublimacion vaso
  sublPaperPkg: "39500",
  sublImgPerSheet: "3",
  sublInkSet: "140000",
  sublInkYield: "800",
  mugWatts: "280",
  mugSecs: "32",
  mugPasses: "2",
  mugKwh: "900",
  // DTF-UV vaso
  dtfvPrice: "14000",
  dtfvRollW: "57",
  dtfvW: "25",
  dtfvH: "9",
  dtfvWaste: "10",
  dtfvTransport: "0",
  // retenciones
  rICA: "1.104",
  rFuente: "2.5",
  rIVA: "0",
  rOther: "0",
};

export function CalculadoraCotizador({
  proveedoresIniciales,
  esAdmin,
}: {
  proveedoresIniciales: ProveedorOpcion[];
  esAdmin: boolean;
}) {
  const supabase = useMemo(() => crearClienteNavegador(), []);

  // ── estado de proveedor / producto reales ───────────────────────────
  const [qProveedor, setQProveedor] = useState("");
  const [proveedores, setProveedores] = useState<ProveedorOpcion[]>(proveedoresIniciales);
  const [idProveedor, setIdProveedor] = useState("");
  const [qProducto, setQProducto] = useState("");
  const [productos, setProductos] = useState<ProductoOpcion[]>([]);
  const [idProducto, setIdProducto] = useState("");
  const [cargandoProd, setCargandoProd] = useState(false);
  const [errorDatos, setErrorDatos] = useState<string | null>(null);
  const [costoBase, setCostoBase] = useState("0");

  // ── estado del calculador (identico al HTML de referencia) ──────────
  const [qty, setQty] = useState(25);
  const [prodCosts, setProdCosts] = useState<Fila[]>([
    { name: "Mano de obra", val: 8000 },
    { name: "Empaque", val: 3000 },
    { name: "Flete / envio", val: 9000 },
  ]);
  const [opCosts, setOpCosts] = useState<Fila[]>([
    { name: "Gasolina / transporte", val: 15000 },
  ]);
  const [machines, setMachines] = useState<Maquina[]>([
    { name: "Plotter", price: 2500000, uses: 500 },
    { name: "Plancha calor DTF", price: 800000, uses: 1500 },
    { name: "Impresora sublimacion", price: 3000000, uses: 600 },
  ]);
  const [productMode, setProductMode] = useState<"camiseta" | "vaso" | "ambos">("camiseta");
  const [camiTech, setCamiTech] = useState<"bordado" | "dtf">("bordado");
  const [vasoTech, setVasoTech] = useState<"sublimacion" | "dtfv">("sublimacion");
  const [dtfDesigns, setDtfDesigns] = useState<Diseno[]>([
    { name: "Pecho", w: 10, h: 12, qty: 1 },
    { name: "Espalda", w: 25, h: 30, qty: 1 },
  ]);
  const [ironInclude, setIronInclude] = useState(false);
  const [campos, setCampos] = useState<Record<string, string>>(CAMPOS_INICIALES);
  const [target, setTarget] = useState(40);
  const [mType, setMType] = useState<"margen" | "markup">("margen");

  const setCampo = useCallback((clave: string, valor: string) => {
    setCampos((prev) => ({ ...prev, [clave]: valor }));
  }, []);

  // `parseFloat(x)||alterno`, exactamente como el HTML de referencia.
  const n = useCallback(
    (clave: string, alterno = 0) => parseFloat(campos[clave]) || alterno,
    [campos],
  );
  const ni = useCallback(
    (clave: string, alterno = 1) => parseInt(campos[clave], 10) || alterno,
    [campos],
  );

  // ── busqueda de proveedores (RPC real, debounce) ────────────────────
  useEffect(() => {
    let vivo = true;
    const t = setTimeout(async () => {
      const { data, error } = await supabase.rpc("fn_consola_buscar_proveedores_producto", {
        p_q: qProveedor.trim() === "" ? null : qProveedor.trim(),
        p_limit: 80,
      });
      if (!vivo) return;
      if (error) {
        setErrorDatos(`No se pudieron cargar proveedores: ${error.message}`);
        return;
      }
      setErrorDatos(null);
      setProveedores((data ?? []) as ProveedorOpcion[]);
    }, 320);
    return () => {
      vivo = false;
      clearTimeout(t);
    };
  }, [qProveedor, supabase]);

  // ── productos del proveedor elegido (RPC real) ──────────────────────
  useEffect(() => {
    if (!idProveedor) {
      setProductos([]);
      return;
    }
    let vivo = true;
    setCargandoProd(true);
    const t = setTimeout(async () => {
      const { data, error } = await supabase.rpc("fn_consola_buscar_productos_proveedor", {
        p_id_proveedor: idProveedor,
        p_q: qProducto.trim() === "" ? null : qProducto.trim(),
        p_limit: 120,
      });
      if (!vivo) return;
      setCargandoProd(false);
      if (error) {
        setErrorDatos(`No se pudieron cargar productos: ${error.message}`);
        return;
      }
      setErrorDatos(null);
      setProductos((data ?? []) as ProductoOpcion[]);
    }, 320);
    return () => {
      vivo = false;
      clearTimeout(t);
    };
  }, [idProveedor, qProducto, supabase]);

  const productoSel = productos.find((p) => p.id_producto_proveedor === idProducto) ?? null;

  // El precio publicado puede venir por paquete; el calculador necesita
  // costo por unidad, asi que se divide entre las unidades del pack.
  const costoUnitarioDe = useCallback((p: ProductoOpcion) => {
    const precio = Number(p.ultimo_precio ?? 0);
    if (!Number.isFinite(precio) || precio <= 0) return 0;
    const pack = Number(p.cantidad_pack ?? 0);
    if (p.unidad_compra === "PACK" && Number.isFinite(pack) && pack > 0) return precio / pack;
    return precio;
  }, []);

  const elegirProducto = (p: ProductoOpcion) => {
    setIdProducto(p.id_producto_proveedor);
    setCostoBase(String(Math.round(costoUnitarioDe(p))));
  };

  // ── CALCULO (port literal de las formulas del HTML) ─────────────────
  const q = qty > 0 ? qty : 1;

  // DTF camiseta
  const dtfRollW = n("dtfRollWidth", 58);
  const dtfTotalArea = dtfDesigns.reduce((s, d) => s + d.w * d.h * d.qty, 0);
  const dtfMeters = dtfTotalArea / dtfRollW / 100;
  const dtfMetersWaste = dtfMeters * (1 + n("dtfWaste", 0) / 100);
  const dtfCostFilm = dtfMetersWaste * n("dtfPricePerMeter", 0);
  const dtfMetersTotal = dtfMetersWaste * q;
  const dtfTotalH = dtfDesigns.reduce((s, d) => s + d.h * d.qty, 0);
  const dtfAvgW = dtfTotalH > 0 ? dtfTotalArea / dtfTotalH : 0;
  const dtfUsePct = Math.min((dtfAvgW / dtfRollW) * 100, 100);
  const ironW = n("ironWatts", 0);
  const ironS = n("ironSecs", 0);
  const ironP = ni("ironPasses", 1);
  const ironKwh = n("ironKwhPrice", 0);
  const ironCost = (ironW / 1000) * ((ironS * ironP) / 3600) * ironKwh;
  const ironFinal = ironInclude ? ironCost : 0;
  const dtfCostPerUnit = dtfCostFilm + ironFinal;
  const dtfResumen = dtfDesigns
    .map((d) => `${d.name || "Diseno"} ${d.w}x${d.h}cm x${d.qty}`)
    .join(", ");

  // Sublimacion vaso
  const sublPaperPkg = n("sublPaperPkg", 0);
  const sublImgPerSheet = n("sublImgPerSheet", 1);
  const sublInkSet = n("sublInkSet", 0);
  const sublInkYield = n("sublInkYield", 1);
  const mugWatts = n("mugWatts", 0);
  const mugSecs = n("mugSecs", 0);
  const mugPasses = ni("mugPasses", 1);
  const mugKwh = n("mugKwh", 0);
  const sublPaperUnit = sublPaperPkg / 100 / sublImgPerSheet;
  const sublInkUnit = sublInkSet / sublInkYield / sublImgPerSheet;
  const sublTotalSecs = mugSecs * mugPasses;
  const sublElecUnit = (mugWatts / 1000) * (sublTotalSecs / 3600) * mugKwh;
  const sublTotal = sublPaperUnit + sublInkUnit + sublElecUnit;

  // DTF-UV vaso
  const dtfvPrice = n("dtfvPrice", 0);
  const dtfvRollW = n("dtfvRollW", 57);
  const dtfvW = n("dtfvW", 1);
  const dtfvH = n("dtfvH", 1);
  const dtfvMeters = ((dtfvW * dtfvH) / dtfvRollW / 100) * (1 + n("dtfvWaste", 0) / 100);
  const dtfvFilm = dtfvMeters * dtfvPrice;
  const dtfvTrans = n("dtfvTransport", 0) / q;
  const dtfvTotal = dtfvFilm + dtfvTrans;

  // Marcacion total
  const showCami = productMode === "camiseta" || productMode === "ambos";
  const showVaso = productMode === "vaso" || productMode === "ambos";
  const embFixed = n("embFixed", 0);
  const embExtra = n("embExtra", 0);
  const bordadoUnit = embFixed / q + embExtra;

  let camiCost = 0;
  let camiLabel = "";
  if (showCami) {
    if (camiTech === "bordado") {
      camiCost = bordadoUnit;
      camiLabel = `Bordado (${fmt(embFixed)} / ${q} uds)`;
    } else {
      camiCost = dtfCostPerUnit;
      camiLabel = `DTF camiseta (${dtfResumen})`;
    }
  }
  let vasoCost = 0;
  let vasoLabel = "";
  if (showVaso) {
    if (vasoTech === "sublimacion") {
      vasoCost = sublTotal;
      vasoLabel = "Sublimacion mug";
    } else {
      vasoCost = dtfvTotal;
      vasoLabel = "DTF-UV rigido";
    }
  }
  const marcacionPerUnit = camiCost + vasoCost;

  const costoProducto = parseFloat(costoBase) || 0;
  const sumProd = costoProducto + prodCosts.reduce((s, c) => s + c.val, 0);
  const sumOp = opCosts.reduce((s, c) => s + c.val, 0);
  const opPerUnit = sumOp / q;
  const machDep = machines.reduce((s, m) => s + (m.uses > 0 ? m.price / m.uses : 0), 0);
  const machPerUnit = machDep / q;
  const totalCost = sumProd + marcacionPerUnit + opPerUnit + machPerUnit;

  const rICA = n("rICA", 0);
  const rFuente = n("rFuente", 0);
  const rIVA = n("rIVA", 0);
  const rOther = n("rOther", 0);
  const retPct = rICA + rFuente + rIVA + rOther;
  const retFactor = 1 - retPct / 100;

  const precioPara = (pt: number) => {
    if (mType === "margen") {
      const mf = 1 - pt / 100;
      return retFactor > 0 && mf > 0 ? totalCost / (retFactor * mf) : totalCost * 2;
    }
    const bruto = totalCost * (1 + pt / 100);
    return retFactor > 0 ? bruto / retFactor : bruto;
  };

  const price = precioPara(target);
  const received = price * retFactor;
  const retAbsICA = (price * rICA) / 100;
  const retAbsFuente = (price * rFuente) / 100;
  const retAbsIVA = (price * rIVA) / 100;
  const retAbsOther = (price * rOther) / 100;
  const retAbsTotal = price - received;
  const profit = received - totalCost;
  const realMargin = received > 0 ? (profit / received) * 100 : 0;
  const realMarkup = totalCost > 0 ? (profit / totalCost) * 100 : 0;

  const HINTS: Array<[number, number, string]> = [
    [0, 10, "Muy ajustado - apenas cubre costos"],
    [10, 20, "Bajo - funciona con mucho volumen"],
    [20, 35, "Razonable para productos personalizados"],
    [35, 50, "Buen margen - sostenible"],
    [50, 100, "Excelente - verifica que el mercado lo aguante"],
  ];
  const vHint = mType === "margen" ? realMargin : realMarkup;
  const hint = HINTS.find((x) => vHint >= x[0] && vHint < x[1]);

  type FilaCascada = {
    n: string;
    v: number;
    c: string;
    bold?: boolean;
    sep?: boolean;
    bg?: string;
  };
  const cascada: FilaCascada[] = [
    { n: "Precio que le cobras al cliente", v: price, c: "rgba(255,255,255,.9)", bold: true },
    ...(rICA > 0
      ? [{ n: `  - ReteICA (${rICA}%)`, v: -retAbsICA, c: "#fca5a5" }]
      : []),
    ...(rFuente > 0
      ? [{ n: `  - ReteFuente (${rFuente}%)`, v: -retAbsFuente, c: "#fca5a5" }]
      : []),
    ...(rIVA > 0 ? [{ n: `  - ReteIVA (${rIVA}%)`, v: -retAbsIVA, c: "#fca5a5" }] : []),
    ...(rOther > 0
      ? [{ n: `  - Otra retencion (${rOther}%)`, v: -retAbsOther, c: "#fca5a5" }]
      : []),
    ...(retPct > 0
      ? [
          {
            n: "= Lo que recibes en tu cuenta",
            v: received,
            c: "rgba(255,255,255,.8)",
            sep: true,
            bold: true,
          },
        ]
      : []),
    {
      n: "  - Costos del producto",
      v: -sumProd,
      c: "rgba(255,255,255,.5)",
      sep: retPct === 0,
    },
    ...(camiCost > 0
      ? [{ n: `  - ${camiLabel}`, v: -camiCost, c: "rgba(255,255,255,.5)" }]
      : []),
    ...(vasoCost > 0
      ? [{ n: `  - ${vasoLabel}`, v: -vasoCost, c: "rgba(255,255,255,.5)" }]
      : []),
    ...(sumOp > 0
      ? [
          {
            n: `  - Gastos del pedido (/ ${q} uds)`,
            v: -opPerUnit,
            c: "rgba(255,255,255,.5)",
          },
        ]
      : []),
    ...(machDep > 0
      ? [
          {
            n: `  - Desgaste maquinas (/ ${q} uds)`,
            v: -machPerUnit,
            c: "rgba(255,255,255,.5)",
          },
        ]
      : []),
    {
      n: "= Tu ganancia neta por unidad",
      v: profit,
      c: "#6ee7b7",
      bg: "rgba(110,231,183,.15)",
      bold: true,
      sep: true,
    },
  ];

  // ── helpers de render ───────────────────────────────────────────────
  const tabStyle = (activo: boolean, colorActivo: string): React.CSSProperties => ({
    flex: 1,
    padding: "10px 6px",
    border: "none",
    background: activo ? colorActivo : "var(--card2)",
    color: activo ? "#fff" : "var(--muted)",
    fontFamily: "'Outfit', ui-sans-serif, system-ui, sans-serif",
    fontSize: 13,
    fontWeight: 600,
    cursor: "pointer",
    transition: "all .2s",
  });

  const etiqueta: React.CSSProperties = {
    fontSize: 12,
    color: "var(--muted)",
    marginBottom: 5,
  };
  const mono: React.CSSProperties = {
    textAlign: "center",
    fontFamily: "'DM Mono', ui-monospace, monospace",
  };

  return (
    <div className="calcv2">
      <div className="wrap">
        <div
          style={{
            marginBottom: 26,
            paddingBottom: 18,
            borderBottom: "1px solid var(--border)",
          }}
        >
          <div className="eyebrow">Estimacion rapida - no emite cotizacion</div>
          <h2 className="big-h1">
            &iquest;A cuanto le <em>vendo?</em>
          </h2>
          <p className="subtitle">
            El costo del producto sale del proveedor real; el resto lo pones tu. Elige tu
            margen y la calculadora te dice el precio, con retenciones de persona natural
            incluidas.
          </p>
        </div>

        {errorDatos && (
          <div className="info info-amber" data-testid="calc-error">
            {errorDatos}
          </div>
        )}

        {/* ═══ UNIDADES DEL PEDIDO ═══ */}
        <div className="card">
          <div className="sec">
            <span
              className="sec-icon"
              style={{ background: "#e8f3ed", color: "var(--green)" }}
            >
              📦
            </span>{" "}
            Pedido actual
          </div>
          <div className="qty-row">
            <label htmlFor="calc-qty-slider">Unidades del pedido:</label>
            <input
              id="calc-qty-slider"
              type="range"
              min={1}
              max={500}
              value={Math.min(qty, 500)}
              onChange={(e) => setQty(parseInt(e.target.value, 10) || 1)}
            />
            <input
              id="calc-qty"
              type="number"
              min={1}
              value={qty}
              style={{ width: 70, flexShrink: 0 }}
              onChange={(e) => setQty(parseInt(e.target.value, 10) || 1)}
            />
            <span className="qty-val" data-testid="calc-qty-lbl">
              {q} uds
            </span>
          </div>
        </div>

        {/* ═══ COSTOS DEL PRODUCTO (proveedor + productos reales) ═══ */}
        <div className="card">
          <div className="sec">
            <span
              className="sec-icon"
              style={{ background: "#fef3c7", color: "var(--amber)" }}
            >
              🧵
            </span>{" "}
            Costos del producto
            <span
              style={{
                marginLeft: "auto",
                fontWeight: 400,
                fontSize: 11,
                textTransform: "none",
                letterSpacing: 0,
                color: "var(--muted)",
              }}
            >
              por unidad
            </span>
          </div>

          <div className="prov-grid">
            <div>
              <div style={etiqueta}>🔎 Buscar proveedor</div>
              <input
                type="text"
                data-testid="calc-q-proveedor"
                placeholder="Nombre o ciudad del proveedor"
                value={qProveedor}
                onChange={(e) => setQProveedor(e.target.value)}
              />
            </div>
            <div>
              <div style={etiqueta}>🏭 Proveedor</div>
              <select
                data-testid="calc-proveedor"
                value={idProveedor}
                onChange={(e) => {
                  setIdProveedor(e.target.value);
                  setIdProducto("");
                  setCostoBase("0");
                }}
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
          </div>

          {idProveedor && (
            <>
              <div style={{ ...etiqueta, marginTop: 4 }}>
                🔎 Buscar producto de este proveedor
              </div>
              <input
                type="text"
                data-testid="calc-q-producto"
                placeholder="mug, termo, camiseta, agenda..."
                value={qProducto}
                onChange={(e) => setQProducto(e.target.value)}
                style={{ marginBottom: 12 }}
              />

              {cargandoProd ? (
                <div className="prod-vacio">Cargando productos...</div>
              ) : productos.length === 0 ? (
                <div className="prod-vacio">
                  Este proveedor no tiene productos que coincidan con la busqueda.
                </div>
              ) : (
                <>
                <div className="prod-vacio" style={{ padding: "0 0 6px" }}>
                  {productos.length} producto(s) · haz clic en uno para usar su precio como
                  costo base
                  {productos.length >= 20 ? " · escribe arriba para filtrar" : ""}
                </div>
                <div className="prod-cards" data-testid="calc-productos">
                  {productos.map((p) => {
                    const unitario = costoUnitarioDe(p);
                    const activo = p.id_producto_proveedor === idProducto;
                    return (
                      <button
                        type="button"
                        key={p.id_producto_proveedor}
                        className={`prod-card${activo ? " on" : ""}`}
                        data-testid="calc-producto-card"
                        onClick={() => elegirProducto(p)}
                      >
                        <span className="prod-card-n">{p.nombre_original}</span>
                        <span className="prod-card-m">
                          {p.sku_proveedor ? `${p.sku_proveedor} · ` : ""}
                          {p.categoria ?? "sin categoria"} · {p.estado_calidad}
                        </span>
                        {unitario > 0 ? (
                          <span className="prod-card-p">
                            {fmt(unitario)}
                            <span
                              style={{
                                fontSize: 11,
                                fontWeight: 400,
                                color: "var(--muted)",
                              }}
                            >
                              {" "}
                              /und
                              {p.unidad_compra === "PACK" && Number(p.cantidad_pack) > 0
                                ? ` (pack de ${Number(p.cantidad_pack)})`
                                : ""}
                            </span>
                          </span>
                        ) : (
                          <span className="prod-card-p sinprecio">Sin precio registrado</span>
                        )}
                      </button>
                    );
                  })}
                </div>
                </>
              )}
            </>
          )}

          <div className="crow" style={{ marginTop: 6 }}>
            <span style={{ fontSize: 13, color: "var(--ink)", fontWeight: 600 }}>
              {productoSel
                ? productoSel.nombre_original
                : "Producto base (elige uno arriba)"}
            </span>
            <div className="mw">
              <input
                type="number"
                min={0}
                data-testid="calc-costo-base"
                value={costoBase}
                onChange={(e) => setCostoBase(e.target.value)}
              />
            </div>
            <span />
          </div>

          <div style={{ ...etiqueta, marginTop: 10 }}>Otros costos por unidad</div>
          {prodCosts.map((c, i) => (
            <div className="crow" key={`prod-${i}`}>
              <input
                type="text"
                value={c.name}
                placeholder="Nombre del costo"
                onChange={(e) =>
                  setProdCosts((prev) =>
                    prev.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)),
                  )
                }
              />
              <div className="mw">
                <input
                  type="number"
                  min={0}
                  value={c.val}
                  onChange={(e) =>
                    setProdCosts((prev) =>
                      prev.map((x, j) =>
                        j === i ? { ...x, val: parseFloat(e.target.value) || 0 } : x,
                      ),
                    )
                  }
                />
              </div>
              <button
                type="button"
                className="btn-del"
                aria-label="Quitar costo"
                onClick={() => setProdCosts((prev) => prev.filter((_, j) => j !== i))}
              >
                ×
              </button>
            </div>
          ))}
          <button
            type="button"
            className="btn-add"
            onClick={() => setProdCosts((prev) => [...prev, { name: "", val: 0 }])}
          >
            ＋ Agregar costo de producto
          </button>

          <div className="info info-green" style={{ marginTop: 10, marginBottom: 0 }}>
            Costo del producto: <strong>{fmt(sumProd)}/und</strong>
            {productoSel ? ` (base ${fmt(costoProducto)} de ${productoSel.nombre_original})` : ""}
          </div>
        </div>

        {/* ═══ TECNICA DE MARCACION ═══ */}
        <div className="card">
          <div className="sec">
            <span
              className="sec-icon"
              style={{ background: "var(--purple-l)", color: "var(--purple)" }}
            >
              🎨
            </span>{" "}
            Tecnica de marcacion
          </div>

          <div
            style={{
              fontSize: 11,
              color: "var(--muted)",
              marginBottom: 6,
              textTransform: "uppercase",
              letterSpacing: ".07em",
            }}
          >
            &iquest;Que estas produciendo?
          </div>
          <div
            style={{
              display: "flex",
              marginBottom: 18,
              border: "1px solid var(--border)",
              borderRadius: 10,
              overflow: "hidden",
            }}
          >
            <button
              type="button"
              data-testid="calc-mode-camiseta"
              onClick={() => setProductMode("camiseta")}
              style={tabStyle(productMode === "camiseta", MODE_COLOR.camiseta)}
            >
              👕 Camiseta
            </button>
            <button
              type="button"
              data-testid="calc-mode-vaso"
              onClick={() => setProductMode("vaso")}
              style={tabStyle(productMode === "vaso", MODE_COLOR.vaso)}
            >
              ☕ Vaso/Mug
            </button>
            <button
              type="button"
              data-testid="calc-mode-ambos"
              onClick={() => setProductMode("ambos")}
              style={tabStyle(productMode === "ambos", MODE_COLOR.ambos)}
            >
              👕+☕ Ambos
            </button>
          </div>

          {/* ── PANEL CAMISETA ── */}
          {showCami && (
            <div>
              <div
                style={{
                  fontSize: 11,
                  color: "var(--muted)",
                  marginBottom: 6,
                  textTransform: "uppercase",
                  letterSpacing: ".07em",
                }}
              >
                Tecnica para camiseta
              </div>
              <div
                style={{
                  display: "flex",
                  marginBottom: 14,
                  border: "1px solid var(--border)",
                  borderRadius: 10,
                  overflow: "hidden",
                }}
              >
                <button
                  type="button"
                  data-testid="calc-cami-bordado"
                  onClick={() => setCamiTech("bordado")}
                  style={{
                    ...tabStyle(camiTech === "bordado", "var(--purple)"),
                    padding: "9px 6px",
                  }}
                >
                  🪡 Bordado
                </button>
                <button
                  type="button"
                  data-testid="calc-cami-dtf"
                  onClick={() => setCamiTech("dtf")}
                  style={{
                    ...tabStyle(camiTech === "dtf", "var(--purple)"),
                    padding: "9px 6px",
                  }}
                >
                  🖨️ DTF
                </button>
              </div>

              {camiTech === "bordado" ? (
                <div>
                  <div className="info info-amber" style={{ marginBottom: 10 }}>
                    El programa de bordado tiene un <strong>costo fijo por diseno</strong>{" "}
                    que se divide entre todas las unidades del pedido.
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr",
                      gap: 10,
                      marginBottom: 10,
                    }}
                  >
                    <div>
                      <div style={etiqueta}>Costo fijo del programa ($)</div>
                      <div className="mw">
                        <input
                          type="number"
                          min={0}
                          data-testid="calc-emb-fixed"
                          value={campos.embFixed}
                          onChange={(e) => setCampo("embFixed", e.target.value)}
                        />
                      </div>
                    </div>
                    <div>
                      <div style={etiqueta}>Costo extra por puntos/tamano ($)</div>
                      <div className="mw">
                        <input
                          type="number"
                          min={0}
                          value={campos.embExtra}
                          onChange={(e) => setCampo("embExtra", e.target.value)}
                        />
                      </div>
                    </div>
                  </div>
                </div>
              ) : (
                <div>
                  <div className="info info-blue" style={{ marginBottom: 10 }}>
                    El rollo DTF tiene un ancho fijo. El costo se calcula por area total de
                    disenos en el pedido, convertida a metros lineales.
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 1fr 1fr",
                      gap: 10,
                      marginBottom: 10,
                    }}
                  >
                    <div>
                      <div style={etiqueta}>💰 Precio metro lineal ($)</div>
                      <div className="mw">
                        <input
                          type="number"
                          min={0}
                          data-testid="calc-dtf-precio"
                          value={campos.dtfPricePerMeter}
                          onChange={(e) => setCampo("dtfPricePerMeter", e.target.value)}
                        />
                      </div>
                      <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 3 }}>
                        1 m = {dtfRollW}×100 cm ={" "}
                        {(dtfRollW * 100).toLocaleString("es-CO")} cm²
                      </div>
                    </div>
                    <div>
                      <div style={etiqueta}>📏 Ancho rollo (cm)</div>
                      <input
                        type="number"
                        min={10}
                        max={200}
                        style={mono}
                        value={campos.dtfRollWidth}
                        onChange={(e) => setCampo("dtfRollWidth", e.target.value)}
                      />
                    </div>
                    <div>
                      <div style={etiqueta}>📐 Merma (%)</div>
                      <div className="pw">
                        <input
                          type="number"
                          min={0}
                          max={50}
                          value={campos.dtfWaste}
                          onChange={(e) => setCampo("dtfWaste", e.target.value)}
                        />
                      </div>
                    </div>
                  </div>

                  <div
                    style={{
                      fontSize: 12,
                      fontWeight: 600,
                      color: "var(--ink)",
                      marginBottom: 6,
                    }}
                  >
                    Disenos del pedido
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "1fr 62px 62px 62px 90px 30px",
                      gap: 6,
                      marginBottom: 4,
                      alignItems: "end",
                    }}
                  >
                    <span style={{ fontSize: 10, color: "var(--muted)", paddingLeft: 4 }}>
                      Nombre
                    </span>
                    <span
                      style={{ fontSize: 10, color: "var(--muted)", textAlign: "center" }}
                    >
                      Ancho
                      <br />
                      (cm)
                    </span>
                    <span
                      style={{ fontSize: 10, color: "var(--muted)", textAlign: "center" }}
                    >
                      Alto
                      <br />
                      (cm)
                    </span>
                    <span
                      style={{ fontSize: 10, color: "var(--muted)", textAlign: "center" }}
                    >
                      Uds
                      <br />
                      diseno
                    </span>
                    <span
                      style={{ fontSize: 10, color: "var(--muted)", textAlign: "center" }}
                    >
                      Area
                      <br />
                      (cm²)
                    </span>
                    <span />
                  </div>

                  {dtfDesigns.map((d, i) => {
                    const area = d.w * d.h * d.qty;
                    const col = DTF_COLORS[i % DTF_COLORS.length];
                    const editar = (patch: Partial<Diseno>) =>
                      setDtfDesigns((prev) =>
                        prev.map((x, j) => (j === i ? { ...x, ...patch } : x)),
                      );
                    return (
                      <div
                        key={`dtf-${i}`}
                        style={{
                          display: "grid",
                          gridTemplateColumns: "1fr 62px 62px 62px 90px 30px",
                          gap: 6,
                          alignItems: "center",
                          marginBottom: 7,
                          padding: "7px 8px",
                          background: "var(--card2)",
                          borderRadius: 8,
                          borderLeft: `3px solid ${col}`,
                        }}
                      >
                        <input
                          type="text"
                          value={d.name}
                          placeholder="Ej: Logo pecho"
                          style={{ fontSize: 13 }}
                          onChange={(e) => editar({ name: e.target.value })}
                        />
                        <input
                          type="number"
                          min={1}
                          step={0.5}
                          style={{ ...mono, fontSize: 13 }}
                          value={d.w}
                          onChange={(e) => editar({ w: parseFloat(e.target.value) || 1 })}
                        />
                        <input
                          type="number"
                          min={1}
                          step={0.5}
                          style={{ ...mono, fontSize: 13 }}
                          value={d.h}
                          onChange={(e) => editar({ h: parseFloat(e.target.value) || 1 })}
                        />
                        <input
                          type="number"
                          min={1}
                          style={{ ...mono, fontSize: 13 }}
                          value={d.qty}
                          onChange={(e) =>
                            editar({ qty: parseInt(e.target.value, 10) || 1 })
                          }
                        />
                        <div
                          style={{
                            fontFamily: "'DM Mono', ui-monospace, monospace",
                            fontSize: 12,
                            color: col,
                            textAlign: "center",
                            fontWeight: 600,
                          }}
                        >
                          {Math.round(area).toLocaleString("es-CO")} cm²
                        </div>
                        {dtfDesigns.length > 1 ? (
                          <button
                            type="button"
                            className="btn-del"
                            aria-label="Quitar diseno"
                            onClick={() =>
                              setDtfDesigns((prev) => prev.filter((_, j) => j !== i))
                            }
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
                    className="btn-add"
                    style={{ marginBottom: 10 }}
                    onClick={() =>
                      setDtfDesigns((prev) => [...prev, { name: "", w: 15, h: 20, qty: 1 }])
                    }
                  >
                    ＋ Agregar diseno
                  </button>

                  <div
                    style={{
                      background: "var(--card2)",
                      border: "1px solid var(--border)",
                      borderRadius: 10,
                      padding: "12px 14px",
                      marginBottom: 4,
                    }}
                  >
                    <div
                      style={{
                        display: "flex",
                        justifyContent: "space-between",
                        fontSize: 12,
                        marginBottom: 4,
                      }}
                    >
                      <span style={{ color: "var(--muted)" }}>Aprovechamiento del rollo</span>
                      <span
                        style={{
                          fontFamily: "'DM Mono', ui-monospace, monospace",
                          color: "var(--purple)",
                          fontWeight: 600,
                        }}
                      >
                        {dtfUsePct.toFixed(1)}%
                      </span>
                    </div>
                    <div
                      style={{
                        height: 6,
                        background: "var(--border)",
                        borderRadius: 4,
                        overflow: "hidden",
                        marginBottom: 6,
                      }}
                    >
                      <div
                        style={{
                          height: "100%",
                          borderRadius: 4,
                          width: `${dtfUsePct.toFixed(1)}%`,
                          background:
                            dtfUsePct > 70 ? "#16a34a" : dtfUsePct > 40 ? "#ca8a04" : "#dc2626",
                          transition: "width .3s",
                        }}
                      />
                    </div>
                    <div style={{ fontSize: 11, color: "var(--muted)" }}>
                      {dtfUsePct < 50 ? "⚠️ Bajo aprovechamiento" : "✅ Buen aprovechamiento"} —
                      ancho promedio: <strong>{dtfAvgW.toFixed(1)} cm</strong> de {dtfRollW} cm
                    </div>
                    <div
                      style={{
                        display: "grid",
                        gridTemplateColumns: "repeat(auto-fit,minmax(110px,1fr))",
                        gap: 8,
                        marginTop: 10,
                      }}
                    >
                      {[
                        { l: "Area/unidad", v: `${Math.round(dtfTotalArea)} cm²` },
                        {
                          l: "Metros/unidad (c/merma)",
                          v: `${dtfMetersWaste.toFixed(4)} m`,
                        },
                        { l: `Metros pedido (${q}uds)`, v: `${dtfMetersTotal.toFixed(3)} m` },
                        { l: "Costo DTF/unidad", v: fmt(dtfCostFilm) },
                      ].map((s) => (
                        <div
                          key={s.l}
                          style={{
                            background: "var(--card)",
                            border: "1px solid var(--border)",
                            borderRadius: 8,
                            padding: "8px 10px",
                          }}
                        >
                          <div
                            style={{
                              fontSize: 10,
                              textTransform: "uppercase",
                              letterSpacing: ".06em",
                              color: "var(--muted)",
                              marginBottom: 2,
                            }}
                          >
                            {s.l}
                          </div>
                          <div
                            style={{
                              fontFamily: "'DM Mono', ui-monospace, monospace",
                              fontSize: 13,
                              color: "var(--purple)",
                              fontWeight: 600,
                            }}
                          >
                            {s.v}
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>

                  <div
                    style={{
                      marginTop: 12,
                      background: "var(--amber-l)",
                      border: "1px solid #fde68a",
                      borderRadius: 10,
                      padding: "12px 14px",
                    }}
                  >
                    <div
                      style={{
                        fontSize: 11,
                        fontWeight: 600,
                        color: "var(--amber)",
                        textTransform: "uppercase",
                        letterSpacing: ".07em",
                        marginBottom: 10,
                      }}
                    >
                      ⚡ Consumo electrico — plancha DTF
                    </div>
                    <div
                      style={{
                        display: "grid",
                        gridTemplateColumns: "repeat(auto-fit,minmax(120px,1fr))",
                        gap: 8,
                        marginBottom: 8,
                      }}
                    >
                      {[
                        { k: "ironWatts", l: "Potencia (W)", step: 100, mw: false },
                        { k: "ironSecs", l: "Seg/pasada", step: 5, mw: false },
                        { k: "ironPasses", l: "Pasadas", step: 1, mw: false },
                        { k: "ironKwhPrice", l: "$/kWh", step: 10, mw: true },
                      ].map((f) => (
                        <div key={f.k}>
                          <div
                            style={{ fontSize: 11, color: "var(--amber)", marginBottom: 4 }}
                          >
                            {f.l}
                          </div>
                          {f.mw ? (
                            <div className="mw">
                              <input
                                type="number"
                                min={0}
                                step={f.step}
                                value={campos[f.k]}
                                onChange={(e) => setCampo(f.k, e.target.value)}
                              />
                            </div>
                          ) : (
                            <input
                              type="number"
                              min={0}
                              step={f.step}
                              style={{ ...mono, fontSize: 13 }}
                              value={campos[f.k]}
                              onChange={(e) => setCampo(f.k, e.target.value)}
                            />
                          )}
                        </div>
                      ))}
                    </div>
                    <div style={{ fontSize: 12, color: "var(--amber)" }}>
                      {ironW}W × {ironS * ironP}seg × ${ironKwh}/kWh ={" "}
                      <strong>{fmt(ironCost)}/prenda</strong>
                    </div>
                    <label
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: 6,
                        fontSize: 12,
                        color: "var(--amber)",
                        marginTop: 8,
                        cursor: "pointer",
                      }}
                    >
                      <input
                        type="checkbox"
                        checked={ironInclude}
                        onChange={(e) => setIronInclude(e.target.checked)}
                      />
                      Incluir costo de luz plancha en el precio
                    </label>
                  </div>
                </div>
              )}

              <div
                className="info info-green"
                data-testid="calc-emb-info"
                style={{ marginTop: 10, marginBottom: 0 }}
              >
                {camiTech === "bordado" ? (
                  <>
                    🪡 <strong>{fmt(embFixed)}</strong> / {q} uds ={" "}
                    <strong>{fmt(bordadoUnit)}/und</strong>
                    {embExtra > 0 ? " (incluye extra)" : ""}
                  </>
                ) : (
                  <>
                    🖨️ {dtfDesigns.length} diseno(s) →{" "}
                    <strong>{fmt(dtfCostPerUnit)}/und</strong>
                    {ironFinal > 0 ? " (incl. luz plancha)" : ""}
                  </>
                )}
              </div>
            </div>
          )}

          {productMode === "ambos" && (
            <div style={{ height: 1, background: "var(--border)", margin: "18px 0" }} />
          )}

          {/* ── PANEL VASO ── */}
          {showVaso && (
            <div>
              <div
                style={{
                  fontSize: 11,
                  color: "var(--muted)",
                  marginBottom: 6,
                  textTransform: "uppercase",
                  letterSpacing: ".07em",
                }}
              >
                Tecnica para vaso / mug
              </div>
              <div
                style={{
                  display: "flex",
                  marginBottom: 14,
                  border: "1px solid var(--border)",
                  borderRadius: 10,
                  overflow: "hidden",
                }}
              >
                <button
                  type="button"
                  data-testid="calc-vaso-subl"
                  onClick={() => setVasoTech("sublimacion")}
                  style={{
                    ...tabStyle(vasoTech === "sublimacion", "#be185d"),
                    padding: "9px 6px",
                  }}
                >
                  🎨 Sublimacion
                </button>
                <button
                  type="button"
                  data-testid="calc-vaso-dtfv"
                  onClick={() => setVasoTech("dtfv")}
                  style={{
                    ...tabStyle(vasoTech === "dtfv", "#7c3aed"),
                    padding: "9px 6px",
                  }}
                >
                  🖨️ DTF-UV
                </button>
              </div>

              {vasoTech === "sublimacion" ? (
                <div>
                  <div className="info info-amber" style={{ marginBottom: 10 }}>
                    <strong>Costos por unidad:</strong> papel (hoja A4 ÷ imagenes/hoja) +
                    tinta (set CMYK ÷ rendimiento ÷ imagenes/hoja) + luz plancha.
                    <br />
                    <strong>Papel A4 x100 hojas ≈ $39.500</strong> ·{" "}
                    <strong>Tinta set CMYK 4×100ml ≈ $140.000, rinde ~800 hojas</strong> ·{" "}
                    <strong>Plancha mug ~280W, 32 seg × 2 pasadas, $900/kWh</strong>
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "repeat(auto-fit,minmax(140px,1fr))",
                      gap: 10,
                      marginBottom: 12,
                    }}
                  >
                    <div>
                      <div style={etiqueta}>💰 Precio paquete 100 hojas ($)</div>
                      <div className="mw">
                        <input
                          type="number"
                          min={0}
                          data-testid="calc-subl-papel"
                          value={campos.sublPaperPkg}
                          onChange={(e) => setCampo("sublPaperPkg", e.target.value)}
                        />
                      </div>
                    </div>
                    <div>
                      <div style={etiqueta}>🖼️ Imagenes por hoja</div>
                      <input
                        type="number"
                        min={1}
                        style={mono}
                        value={campos.sublImgPerSheet}
                        onChange={(e) => setCampo("sublImgPerSheet", e.target.value)}
                      />
                      <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 3 }}>
                        Mug estandar: 3/hoja
                      </div>
                    </div>
                    <div>
                      <div style={etiqueta}>🎨 Set tinta CMYK ($)</div>
                      <div className="mw">
                        <input
                          type="number"
                          min={0}
                          value={campos.sublInkSet}
                          onChange={(e) => setCampo("sublInkSet", e.target.value)}
                        />
                      </div>
                      <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 3 }}>
                        4 botellas 100ml
                      </div>
                    </div>
                    <div>
                      <div style={etiqueta}>📄 Rendimiento (hojas/set)</div>
                      <input
                        type="number"
                        min={1}
                        style={mono}
                        value={campos.sublInkYield}
                        onChange={(e) => setCampo("sublInkYield", e.target.value)}
                      />
                    </div>
                  </div>

                  <div
                    style={{
                      fontSize: 12,
                      fontWeight: 600,
                      color: "var(--ink)",
                      marginBottom: 6,
                    }}
                  >
                    ⚡ Plancha de sublimacion mug
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "repeat(auto-fit,minmax(110px,1fr))",
                      gap: 8,
                      marginBottom: 8,
                    }}
                  >
                    {[
                      { k: "mugWatts", l: "Potencia (W)", step: 10, mw: false, nota: "Plancha mug: ~280W" },
                      { k: "mugSecs", l: "Seg/pasada", step: 1, mw: false, nota: "" },
                      { k: "mugPasses", l: "Pasadas", step: 1, mw: false, nota: "360° × 2" },
                      { k: "mugKwh", l: "$/kWh", step: 10, mw: true, nota: "" },
                    ].map((f) => (
                      <div key={f.k}>
                        <div style={{ fontSize: 11, color: "var(--muted)", marginBottom: 4 }}>
                          {f.l}
                        </div>
                        {f.mw ? (
                          <div className="mw">
                            <input
                              type="number"
                              min={0}
                              step={f.step}
                              value={campos[f.k]}
                              onChange={(e) => setCampo(f.k, e.target.value)}
                            />
                          </div>
                        ) : (
                          <input
                            type="number"
                            min={0}
                            step={f.step}
                            style={{ ...mono, fontSize: 13 }}
                            value={campos[f.k]}
                            onChange={(e) => setCampo(f.k, e.target.value)}
                          />
                        )}
                        {f.nota && (
                          <div style={{ fontSize: 10, color: "var(--muted)", marginTop: 2 }}>
                            {f.nota}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                  <div
                    className="info info-green"
                    data-testid="calc-subl-info"
                    style={{ fontSize: 12, marginBottom: 0 }}
                  >
                    Papel: <strong>{fmt(sublPaperPkg)}/100÷{sublImgPerSheet}</strong>=
                    {fmt(sublPaperUnit)} &nbsp;|&nbsp; Tinta:{" "}
                    <strong>
                      {fmt(sublInkSet)}/{sublInkYield}÷{sublImgPerSheet}
                    </strong>
                    ={fmt(sublInkUnit)} &nbsp;|&nbsp; Luz:{" "}
                    <strong>
                      {mugWatts}W×{sublTotalSecs}seg×${mugKwh}
                    </strong>
                    ={fmt(sublElecUnit)} &nbsp;→&nbsp;{" "}
                    <strong>Total: {fmt(sublTotal)}/und</strong>
                  </div>
                </div>
              ) : (
                <div>
                  <div className="info info-blue" style={{ marginBottom: 10 }}>
                    <strong>DTF-UV para rigidos:</strong> rollo de{" "}
                    <strong>57 cm de ancho</strong> por defecto. El costo es proporcional al
                    area del diseno. Incluye el valor del transporte si aplica.
                  </div>
                  <div
                    style={{
                      display: "grid",
                      gridTemplateColumns: "repeat(auto-fit,minmax(130px,1fr))",
                      gap: 10,
                      marginBottom: 10,
                    }}
                  >
                    <div>
                      <div style={etiqueta}>💰 Precio metro lineal ($)</div>
                      <div className="mw">
                        <input
                          type="number"
                          min={0}
                          data-testid="calc-dtfv-precio"
                          value={campos.dtfvPrice}
                          onChange={(e) => setCampo("dtfvPrice", e.target.value)}
                        />
                      </div>
                    </div>
                    <div>
                      <div style={etiqueta}>📏 Ancho rollo (cm)</div>
                      <input
                        type="number"
                        min={1}
                        style={mono}
                        value={campos.dtfvRollW}
                        onChange={(e) => setCampo("dtfvRollW", e.target.value)}
                      />
                      <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 3 }}>
                        Tu dato: 57 cm
                      </div>
                    </div>
                    <div>
                      <div style={etiqueta}>↔ Ancho diseno (cm)</div>
                      <input
                        type="number"
                        min={1}
                        style={mono}
                        value={campos.dtfvW}
                        onChange={(e) => setCampo("dtfvW", e.target.value)}
                      />
                    </div>
                    <div>
                      <div style={etiqueta}>↕ Alto diseno (cm)</div>
                      <input
                        type="number"
                        min={1}
                        style={mono}
                        value={campos.dtfvH}
                        onChange={(e) => setCampo("dtfvH", e.target.value)}
                      />
                    </div>
                    <div>
                      <div style={etiqueta}>📐 Merma (%)</div>
                      <div className="pw">
                        <input
                          type="number"
                          min={0}
                          max={50}
                          value={campos.dtfvWaste}
                          onChange={(e) => setCampo("dtfvWaste", e.target.value)}
                        />
                      </div>
                    </div>
                    <div>
                      <div style={etiqueta}>🚚 Transporte ($)</div>
                      <div className="mw">
                        <input
                          type="number"
                          min={0}
                          value={campos.dtfvTransport}
                          onChange={(e) => setCampo("dtfvTransport", e.target.value)}
                        />
                      </div>
                      <div style={{ fontSize: 11, color: "var(--muted)", marginTop: 3 }}>
                        por pedido ÷ uds
                      </div>
                    </div>
                  </div>
                </div>
              )}

              <div
                className="info info-green"
                data-testid="calc-mug-info"
                style={{ marginTop: 6, marginBottom: 0 }}
              >
                {vasoTech === "sublimacion" ? (
                  <>
                    🎨 <strong>{fmt(sublTotal)}/und</strong> (papel+tinta+luz)
                  </>
                ) : (
                  <>
                    🖨️ DTF-UV: {dtfvW}×{dtfvH}cm ÷ {dtfvRollW}cm → {fmt(dtfvFilm)}/und
                    {dtfvTrans > 0 ? ` + transporte ${fmt(dtfvTrans)}/und` : ""} ={" "}
                    <strong>{fmt(dtfvTotal)}/und</strong>
                  </>
                )}
              </div>
            </div>
          )}
        </div>

        {/* ═══ GASTOS DEL PEDIDO ═══ */}
        <div className="card">
          <div className="sec">
            <span
              className="sec-icon"
              style={{ background: "var(--amber-l)", color: "var(--amber)" }}
            >
              ⚙️
            </span>{" "}
            Gastos del pedido
            <span
              style={{
                marginLeft: "auto",
                fontWeight: 400,
                fontSize: 11,
                textTransform: "none",
                letterSpacing: 0,
                color: "var(--muted)",
              }}
            >
              se dividen entre las unidades
            </span>
          </div>

          <div className="info info-amber" style={{ marginBottom: 12 }}>
            <strong>Tu caso:</strong> gastos que ocurren <em>por pedido</em>, no
            mensualmente — gasolina, transporte, internet, tu tiempo. Se ingresan como total
            del pedido y la calculadora los divide entre las unidades automaticamente.
          </div>

          <div className="presets">
            <span style={{ fontSize: 11, color: "var(--muted)", width: "100%", marginBottom: 2 }}>
              Agregar gasto tipico:
            </span>
            {[
              ["⛽ Gasolina", "Gasolina / transporte", 15000],
              ["📱 Internet", "Internet / WhatsApp", 10000],
              ["⏱ Mi tiempo", "Mi tiempo (gestion)", 20000],
              ["🛍 Empaque", "Empaque extra", 5000],
              ["＋ Otro", "", 0],
            ].map(([etiq, nombre, valor]) => (
              <button
                type="button"
                key={String(etiq)}
                className="pre-btn"
                onClick={() =>
                  setOpCosts((prev) => [...prev, { name: String(nombre), val: Number(valor) }])
                }
              >
                {etiq}
              </button>
            ))}
          </div>

          <div
            style={{
              display: "grid",
              gridTemplateColumns: "1fr 130px 30px",
              gap: 7,
              marginBottom: 4,
            }}
          >
            <span style={{ fontSize: 10, color: "var(--muted)", paddingLeft: 4 }}>Gasto</span>
            <span style={{ fontSize: 10, color: "var(--muted)", paddingLeft: 4 }}>
              Total pedido ($)
            </span>
            <span />
          </div>
          {opCosts.map((c, i) => (
            <div className="crow" key={`op-${i}`}>
              <input
                type="text"
                value={c.name}
                placeholder="Descripcion del gasto"
                onChange={(e) =>
                  setOpCosts((prev) =>
                    prev.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)),
                  )
                }
              />
              <div className="mw">
                <input
                  type="number"
                  min={0}
                  value={c.val}
                  onChange={(e) =>
                    setOpCosts((prev) =>
                      prev.map((x, j) =>
                        j === i ? { ...x, val: parseFloat(e.target.value) || 0 } : x,
                      ),
                    )
                  }
                />
              </div>
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
            onClick={() => setOpCosts((prev) => [...prev, { name: "", val: 0 }])}
          >
            ＋ Agregar gasto del pedido
          </button>
          <div className="info info-green" style={{ marginTop: 10, marginBottom: 0 }}>
            Total gastos del pedido: <strong>{fmt(sumOp)}</strong> ÷ {q} uds ={" "}
            <strong>{fmt(opPerUnit)}/und</strong>
          </div>
        </div>

        {/* ═══ MAQUINAS ═══ */}
        <div className="card">
          <div className="sec">
            <span
              className="sec-icon"
              style={{ background: "var(--blue-l)", color: "var(--blue)" }}
            >
              🔧
            </span>{" "}
            Desgaste de maquinas &amp; consumo electrico
          </div>

          <div className="info info-blue" style={{ marginBottom: 14 }}>
            <strong>&iquest;Que es el valor de reposicion?</strong> Es cuanto te costaria{" "}
            <em>comprar esa maquina hoy</em> si se danara. No el precio que pagaste, sino el
            precio actual.
            <br />
            <br />
            <strong>&iquest;Que son los usos estimados?</strong> Cuantas veces calculas que vas
            a usar esa maquina antes de que se dane o quede obsoleta.
            <br />
            <br />
            <strong>Costo/uso</strong> = valor reposicion ÷ usos estimados.
          </div>

          <div
            style={{
              display: "grid",
              gridTemplateColumns: "1fr 110px 110px 30px",
              gap: 7,
              marginBottom: 4,
            }}
          >
            <span className="col-h" style={{ textAlign: "left", paddingLeft: 4 }}>
              Maquina
            </span>
            <span className="col-h">Valor reposicion ($)</span>
            <span className="col-h">Usos estimados</span>
            <span />
          </div>
          {machines.map((m, i) => (
            <div className="mach-row" key={`mach-${i}`}>
              <input
                type="text"
                value={m.name}
                placeholder="Nombre maquina"
                onChange={(e) =>
                  setMachines((prev) =>
                    prev.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)),
                  )
                }
              />
              <div className="mw">
                <input
                  type="number"
                  min={0}
                  value={m.price}
                  onChange={(e) =>
                    setMachines((prev) =>
                      prev.map((x, j) =>
                        j === i ? { ...x, price: parseFloat(e.target.value) || 0 } : x,
                      ),
                    )
                  }
                />
              </div>
              <input
                type="number"
                min={1}
                style={{ textAlign: "center" }}
                value={m.uses}
                onChange={(e) =>
                  setMachines((prev) =>
                    prev.map((x, j) =>
                      j === i ? { ...x, uses: parseFloat(e.target.value) || 1 } : x,
                    ),
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
              setMachines((prev) => [...prev, { name: "", price: 0, uses: 100 }])
            }
          >
            ＋ Agregar maquina
          </button>
          <div className="info info-green" style={{ marginTop: 10, marginBottom: 0 }}>
            {machines
              .map((m) => `${m.name}: ${fmt(m.uses > 0 ? m.price / m.uses : 0)}/pedido`)
              .join(" · ")}
            <br />
            Total desgaste/und: <strong>{fmt(machPerUnit)}</strong> ({fmt(machDep)}/pedido ÷{" "}
            {q} uds)
          </div>
        </div>

        {/* ═══ RETENCIONES ═══ */}
        <div className="card">
          <div className="sec">
            <span
              className="sec-icon"
              style={{ background: "var(--blue-l)", color: "var(--blue)" }}
            >
              🏛️
            </span>{" "}
            Retenciones que te aplican
          </div>

          <div className="info info-blue">
            <strong>&iquest;Como funciona?</strong> Cuando facturas, el cliente te descuenta
            estas retenciones <em>antes</em> de pagarte. El precio que ves ya hace ese ajuste.
            <br />
            <br />
            <strong>· ReteICA</strong>: para dotaciones / confecciones en Bogota:{" "}
            <strong>1.104%</strong>.<br />
            <strong>· ReteFuente</strong>: compra de bienes / dotaciones a persona natural:{" "}
            <strong>2.5%</strong>. Como servicios: 4%.
            <br />
            <strong>· No cobras IVA</strong> como persona natural no responsable — pon 0%.
          </div>

          <div
            style={{
              background: "var(--blue-l)",
              border: "1px solid #bfdbfe",
              borderRadius: 10,
              padding: "14px 16px",
              marginBottom: 14,
              display: "flex",
              flexWrap: "wrap",
              gap: 12,
              alignItems: "center",
            }}
          >
            <div style={{ flex: 1, minWidth: 160 }}>
              <div
                style={{
                  fontSize: 10,
                  textTransform: "uppercase",
                  letterSpacing: ".07em",
                  color: "var(--blue)",
                  marginBottom: 3,
                }}
              >
                Total que te retienen
              </div>
              <div
                style={{
                  fontFamily: "'DM Mono', ui-monospace, monospace",
                  fontSize: 26,
                  fontWeight: 500,
                  color: "var(--blue)",
                }}
              >
                {retPct.toFixed(3)}%
              </div>
            </div>
            <div style={{ flex: 1, minWidth: 130 }}>
              <div
                style={{
                  fontSize: 10,
                  textTransform: "uppercase",
                  letterSpacing: ".07em",
                  color: "var(--blue)",
                  marginBottom: 3,
                }}
              >
                De cada $100.000 facturados
              </div>
              <div style={{ fontSize: 13, color: "#1e3a8a" }}>
                {retPct > 0 ? (
                  <>
                    te retienen <strong>{fmt(retPct * 1000)}</strong> → recibes{" "}
                    <strong>{fmt((1 - retPct / 100) * 100000)}</strong>
                  </>
                ) : (
                  <>
                    no aplican retenciones — recibes <strong>$100.000</strong>
                  </>
                )}
              </div>
            </div>
            <div style={{ flex: 1, minWidth: 130 }}>
              <div
                style={{
                  fontSize: 10,
                  textTransform: "uppercase",
                  letterSpacing: ".07em",
                  color: "var(--blue)",
                  marginBottom: 3,
                }}
              >
                Precio minimo para cubrirlas
              </div>
              <div style={{ fontSize: 12, color: "#1e3a8a" }}>
                {retPct > 0 ? (
                  <>
                    El precio ya sube <strong>{fmt(retAbsTotal)}</strong>/und para cubrir
                    retenciones
                  </>
                ) : (
                  <>Sin ajuste — precio directo</>
                )}
              </div>
            </div>
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
        </div>

        {/* ═══ MARGEN ═══ */}
        <div className="dark-card">
          <div className="sec">🎯 &iquest;Que margen quieres ganar?</div>
          <div className="margin-row">
            <input
              type="range"
              min={5}
              max={80}
              value={Math.min(Math.max(target, 5), 80)}
              onChange={(e) => setTarget(parseInt(e.target.value, 10) || 1)}
            />
            <input
              type="number"
              min={1}
              max={99}
              data-testid="calc-margen"
              value={target}
              onChange={(e) => setTarget(parseFloat(e.target.value) || 0)}
            />
            <span style={{ color: "rgba(255,255,255,.4)", fontSize: 20 }}>%</span>
          </div>
          <div className="margin-big">{target}%</div>
          <div style={{ fontSize: 13, color: "rgba(255,255,255,.4)", marginTop: 6 }}>
            {hint ? hint[2] : ""}
          </div>
          <div className="mtype-row">
            <button
              type="button"
              className={`mtype-btn${mType === "margen" ? " on" : ""}`}
              onClick={() => setMType("margen")}
            >
              📊 Margen sobre venta
              <br />
              <span style={{ fontSize: 10, opacity: 0.6 }}>ganancia ÷ precio de venta</span>
            </button>
            <button
              type="button"
              className={`mtype-btn${mType === "markup" ? " on" : ""}`}
              onClick={() => setMType("markup")}
            >
              💰 Markup sobre costo
              <br />
              <span style={{ fontSize: 10, opacity: 0.6 }}>ganancia ÷ costo total</span>
            </button>
          </div>
          <div style={{ fontSize: 11, color: "rgba(255,255,255,.3)", marginTop: 10 }}>
            {mType === "margen"
              ? `Margen = ganancia / lo que recibes. Un ${target}% significa que de cada $100 que te pagan, $${target} son tu ganancia.`
              : `Markup = ganancia / costo total. Un ${target}% significa que vendes ${target}% por encima de tus costos.`}
          </div>
        </div>

        {/* ═══ RESULTADO ═══ */}
        <div className="res-card">
          <div className="res-hl">
            {mType === "margen"
              ? `Precio para ${target}% de margen real (ya incluye retenciones)`
              : `Precio para ${target}% de markup real (ya incluye retenciones)`}
          </div>
          <div className="res-price" data-testid="calc-precio">
            {fmt(price)}
          </div>
          <div className="res-sub">
            {retPct > 0
              ? `Facturas ${fmt(price)} · te retienen ${fmt(retAbsTotal)} (${retPct.toFixed(2)}%) · recibes ${fmt(received)}`
              : "Sin retenciones — lo que facturas es lo que recibes"}
          </div>

          <div className="res-grid">
            <div className="res-box">
              <div className="res-box-l">Costo total/und</div>
              <div className="res-box-v" data-testid="calc-costo-total">
                {fmt(totalCost)}
              </div>
            </div>
            <div className="res-box">
              <div className="res-box-l">Tu ganancia neta</div>
              <div className="res-box-v">{fmt(profit)}</div>
            </div>
            <div className="res-box">
              <div className="res-box-l">Margen real</div>
              <div className="res-box-v">{realMargin.toFixed(1)}%</div>
            </div>
            <div className="res-box">
              <div className="res-box-l">Recibes (tras retenciones)</div>
              <div className="res-box-v">{fmt(received)}</div>
            </div>
          </div>

          <div style={{ marginTop: 16 }}>
            {cascada.map((r, i) => (
              <div
                className="wf-row"
                key={`wf-${i}`}
                style={{
                  background: r.bg ?? "transparent",
                  ...(r.sep
                    ? {
                        borderTop: "1px solid rgba(255,255,255,.15)",
                        marginTop: 8,
                        paddingTop: 10,
                      }
                    : {}),
                }}
              >
                <span
                  style={{
                    color: r.c,
                    fontWeight: r.bold ? 600 : 400,
                    fontSize: r.bold ? 13 : 12,
                    whiteSpace: "pre-wrap",
                  }}
                >
                  {r.n}
                </span>
                <span
                  style={{
                    fontFamily: "'DM Mono', ui-monospace, monospace",
                    fontSize: 12,
                    color: r.c,
                    fontWeight: r.bold ? 600 : 400,
                  }}
                >
                  {r.v < 0 ? `- ${fmt(-r.v)}` : fmt(r.v)}
                </span>
              </div>
            ))}
          </div>

          <div
            style={{
              fontSize: 10,
              textTransform: "uppercase",
              letterSpacing: ".08em",
              color: "rgba(255,255,255,.35)",
              marginTop: 18,
              marginBottom: 8,
            }}
          >
            Comparar escenarios
          </div>
          <div className="sc-row">
            {[20, 35, 50].map((pt) => {
              const p2 = precioPara(pt);
              const rec2 = p2 * retFactor;
              const pr2 = rec2 - totalCost;
              const activo = Math.abs(pt - target) < 6;
              return (
                <button
                  type="button"
                  key={pt}
                  className={`sc${activo ? " on" : ""}`}
                  onClick={() => setTarget(pt)}
                >
                  <div className="sc-t">
                    {mType === "margen" ? "Margen" : "Markup"} {pt}%
                  </div>
                  <div className="sc-p">{fmt(p2)}</div>
                  <div className="sc-d">Ganancia real: {fmt(pr2)}/und</div>
                </button>
              );
            })}
          </div>
        </div>

        <div className="info info-amber" style={{ marginBottom: 0 }}>
          <strong>Esto es una estimacion visual.</strong> No emite cotizacion ni queda
          registrada: para eso usa el flujo proveedor-first de abajo, que aplica la politica
          de margen, deja auditoria y genera el PDF.
          {!esAdmin && " Tu rol no ve costos ni margenes reales de la base."}
        </div>
      </div>
    </div>
  );
}
