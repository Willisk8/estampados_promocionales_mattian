import { randomUUID } from "node:crypto";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import { crearCotizacionCalculada, prepararCotizacionCalculada, prepararPrevisualizacion } from "./acciones";

export const dynamic = "force-dynamic";

type Resumen = {
  productos_propios_activos: number;
  productos_propios_borrador: number;
  precios_comerciales_vigentes: number;
};

type Variante = {
  id_variante: string;
  sku_variante: string;
  nombre: string;
  estado: string;
};

type Producto = {
  id_producto: string;
  sku: string;
  nombre: string;
  estado: string;
  variante_producto: Variante[];
};

type Organizacion = {
  id_organizacion: string;
  nombre_legal: string;
  nit: string | null;
};

type TecnicaDisponible = {
  id_tecnica: string;
  codigo: string;
};

type ComponentePreview = {
  tipo_componente: string;
  descripcion: string;
  cantidad: number | string;
  costo_unitario: number | string | null;
  costo_total: number | string | null;
  margen_aplicado_pct: number | string | null;
  minimum_pct: number | string | null;
  precio_resultante: number | string | null;
  status: string;
};

const cop = (v: string | number | null | undefined) =>
  v === null || v === undefined
    ? "—"
    : "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

export default async function PaginaCotizador({
  searchParams,
}: {
  searchParams: Promise<{
    id_producto?: string;
    id_variante?: string;
    id_organizacion?: string;
    cantidad?: string;
    id_tecnica?: string;
    numero_preparaciones?: string;
    transporte_total?: string;
    margen_override_pct?: string;
    notas?: string;
    previsualizar?: string;
    status?: string;
    error?: string;
  }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const sp = await searchParams;
  const supabase = await crearClienteServidor();
  const [{ data }, productosResp, organizacionesResp, cotizacionesResp] = await Promise.all([
    supabase.rpc("fn_consola_resumen"),
    supabase
      .from("producto")
      .select("id_producto, sku, nombre, estado, variante_producto(id_variante, sku_variante, nombre, estado)")
      .eq("estado", "ACTIVE")
      .order("sku"),
    supabase
      .from("organizacion")
      .select("id_organizacion, nombre_legal, nit")
      .order("nombre_legal")
      .limit(100),
    supabase
      .from("cotizacion")
      .select("id_cotizacion, numero, total, estado, created_at, metodo_precio")
      .order("created_at", { ascending: false })
      .limit(8),
  ]);
  const r = (data?.[0] ?? null) as Resumen | null;
  const productos = (productosResp.data ?? []) as unknown as Producto[];
  const organizaciones = (organizacionesResp.data ?? []) as Organizacion[];
  const cotizaciones = (cotizacionesResp.data ?? []) as Array<{
    id_cotizacion: string;
    numero: number;
    total: number | string;
    estado: string;
    created_at: string;
    metodo_precio: string | null;
  }>;
  const puedeCotizar = sesion.rol === "ADMIN" || sesion.rol === "COMERCIAL";
  const idempotencyKey = randomUUID();
  const cantidadSeleccionada = Number(sp.cantidad ?? 0);
  const productoSeleccionado = productos.find((p) => p.id_producto === sp.id_producto);
  let tecnicas: TecnicaDisponible[] = [];

  if (sp.id_producto && Number.isFinite(cantidadSeleccionada) && cantidadSeleccionada > 0) {
    const { data: tecnicasResp } = await supabase.rpc("fn_consola_tecnicas_disponibles_producto", {
      p_id_producto: sp.id_producto,
      p_id_variante: sp.id_variante || null,
      p_cantidad: cantidadSeleccionada,
    });
    tecnicas = (tecnicasResp ?? []) as TecnicaDisponible[];
  }

  let previewFilas: ComponentePreview[] = [];
  const mostrarPreview =
    sp.previsualizar === "1" &&
    !!sp.id_producto &&
    Number.isFinite(cantidadSeleccionada) &&
    cantidadSeleccionada > 0;

  if (mostrarPreview) {
    const { data: previewResp } = await supabase.rpc("fn_consola_previsualizar_cotizacion_calculada", {
      p_id_producto: sp.id_producto,
      p_cantidad: cantidadSeleccionada,
      p_id_variante: sp.id_variante || null,
      p_id_tecnica: sp.id_tecnica || null,
      p_numero_preparaciones: Number(sp.numero_preparaciones ?? 1),
      p_transporte_total: Number(sp.transporte_total ?? 0),
      p_policy_code: "MVP_DEFAULT",
      p_margen_override_pct: sp.margen_override_pct ? Number(sp.margen_override_pct) : null,
    });
    previewFilas = (previewResp ?? []) as ComponentePreview[];
  }
  const previewOk = previewFilas.length > 0 && previewFilas.every((f) => f.status === "OK");
  const previewTotal = previewOk
    ? previewFilas.reduce((acc, f) => acc + Number(f.precio_resultante ?? 0), 0)
    : null;

  return (
    <>
      <h1>Cotizador</h1>
      <p className="subtitulo">
        Cotización calculada desde costos versionados: producto, técnica,
        preparaciones y transporte. La tarifa publicada queda como referencia,
        no como único camino de emisión.
      </p>

      {sp.status && (
        <div className="aviso-caja">
          No se pudo cotizar: <code>{sp.status}</code>.
        </div>
      )}
      {sp.error && <div className="aviso-caja">{sp.error}</div>}

      <h2>1. Datos base</h2>
      <div className="tarjeta">
        <p style={{ marginTop: 0 }}>
          Primero define producto y cantidad. Con eso la consola consulta
          <code> fn_consola_tecnicas_disponibles_producto()</code> filtrando
          mínimos/máximos de cantidad para no ofrecer técnicas que luego fallen.
        </p>
        <form action={prepararCotizacionCalculada} className="filtros">
          <select name="id_organizacion" defaultValue={sp.id_organizacion ?? ""} disabled={!puedeCotizar}>
            <option value="">Sin organización asociada</option>
            {organizaciones.map((o) => (
              <option key={o.id_organizacion} value={o.id_organizacion}>
                {o.nombre_legal}
                {o.nit ? ` - ${o.nit}` : ""}
              </option>
            ))}
          </select>
          <select name="id_producto" required defaultValue={sp.id_producto ?? ""} disabled={!puedeCotizar}>
            <option value="">Producto activo</option>
            {productos.map((p) => (
              <option key={p.id_producto} value={p.id_producto}>
                {p.sku} - {p.nombre}
              </option>
            ))}
          </select>
          <select name="id_variante" defaultValue={sp.id_variante ?? ""} disabled={!puedeCotizar || !productoSeleccionado}>
            <option value="">Sin variante</option>
            {(productoSeleccionado?.variante_producto ?? [])
              .filter((v) => v.estado === "ACTIVE")
              .map((v) => (
                <option key={v.id_variante} value={v.id_variante}>
                  {v.sku_variante} - {v.nombre}
                </option>
              ))}
          </select>
          <input
            name="cantidad"
            type="number"
            min="1"
            placeholder="Cantidad"
            defaultValue={sp.cantidad ?? ""}
            required
            disabled={!puedeCotizar}
          />
          <input
            name="numero_preparaciones"
            type="number"
            min="0"
            placeholder="Preparaciones"
            defaultValue={sp.numero_preparaciones ?? "1"}
            disabled={!puedeCotizar}
          />
          <input
            name="transporte_total"
            type="number"
            min="0"
            placeholder="Transporte total"
            defaultValue={sp.transporte_total ?? "0"}
            disabled={!puedeCotizar}
          />
          {sesion.rol === "ADMIN" && (
            <input
              name="margen_override_pct"
              type="number"
              step="0.01"
              placeholder="Margen % opcional"
              defaultValue={sp.margen_override_pct ?? ""}
              disabled={!puedeCotizar}
            />
          )}
          <input name="notas" placeholder="Notas" defaultValue={sp.notas ?? ""} disabled={!puedeCotizar} />
          <button type="submit" disabled={!puedeCotizar || productos.length === 0}>
            Actualizar técnicas
          </button>
        </form>
      </div>

      <h2>2. Elegir técnica y calcular precio</h2>
      <div className="tarjeta">
        {!sp.id_producto || !sp.cantidad ? (
          <p style={{ marginTop: 0, color: "var(--texto-suave)" }}>
            Selecciona producto y cantidad para habilitar el cálculo.
          </p>
        ) : (
          <>
            <p style={{ marginTop: 0 }}>
              Producto: <strong>{productoSeleccionado?.sku ?? "seleccionado"}</strong>.{" "}
              Puedes cotizar sin técnica o elegir una técnica disponible para esta cantidad.
            </p>
            <form action={prepararPrevisualizacion} className="filtros">
              <input type="hidden" name="id_producto" value={sp.id_producto} />
              <input type="hidden" name="id_variante" value={sp.id_variante ?? ""} />
              <input type="hidden" name="id_organizacion" value={sp.id_organizacion ?? ""} />
              <input type="hidden" name="cantidad" value={sp.cantidad} />
              <input type="hidden" name="numero_preparaciones" value={sp.numero_preparaciones ?? "1"} />
              <input type="hidden" name="transporte_total" value={sp.transporte_total ?? "0"} />
              <input type="hidden" name="margen_override_pct" value={sp.margen_override_pct ?? ""} />
              <input type="hidden" name="notas" value={sp.notas ?? ""} />
              <select name="id_tecnica" defaultValue={sp.id_tecnica ?? ""} disabled={!puedeCotizar}>
                <option value="">Sin técnica explícita</option>
                {tecnicas.map((t) => (
                  <option key={t.id_tecnica} value={t.id_tecnica}>
                    {t.codigo}
                  </option>
                ))}
              </select>
              <button type="submit" disabled={!puedeCotizar}>
                Calcular precio
              </button>
            </form>
            {tecnicas.length === 0 && (
              <p style={{ fontSize: 13, color: "var(--texto-suave)", marginBottom: 0 }}>
                No hay técnicas curadas para este producto/cantidad; aún puedes calcular
                sin técnica usando costos base del producto.
              </p>
            )}
          </>
        )}
      </div>

      {mostrarPreview && (
        <>
          <h2>3. Previsualización y confirmación</h2>
          <div className="tarjeta">
            {!previewOk ? (
              <div className="aviso-caja">
                No se pudo calcular un precio: <code>{previewFilas[0]?.status ?? "SIN_DATOS"}</code>.
                Ajusta producto, cantidad o técnica y vuelve a calcular.
              </div>
            ) : (
              <>
                <p style={{ marginTop: 0 }}>
                  Este es el precio calculado. Nada se ha guardado todavía — solo al
                  confirmar se emite la cotización real.
                </p>
                <div className="tabla-contenedor">
                  <table>
                    <thead>
                      <tr>
                        <th>Componente</th>
                        <th>Descripción</th>
                        <th className="num">Cantidad</th>
                        {sesion.rol === "ADMIN" && <th className="num">Costo unitario</th>}
                        {sesion.rol === "ADMIN" && <th className="num">Costo total</th>}
                        {sesion.rol === "ADMIN" && <th className="num">Margen %</th>}
                        <th className="num">Precio</th>
                      </tr>
                    </thead>
                    <tbody>
                      {previewFilas.map((f, index) => (
                        <tr key={`${f.tipo_componente}-${index}`}>
                          <td>
                            <span className="insignia">{f.tipo_componente}</span>
                          </td>
                          <td>{f.descripcion}</td>
                          <td className="num">{Number(f.cantidad).toLocaleString("es-CO")}</td>
                          {sesion.rol === "ADMIN" && <td className="num">{cop(f.costo_unitario)}</td>}
                          {sesion.rol === "ADMIN" && <td className="num">{cop(f.costo_total)}</td>}
                          {sesion.rol === "ADMIN" && (
                            <td className="num">
                              {f.margen_aplicado_pct === null
                                ? "—"
                                : Number(f.margen_aplicado_pct).toLocaleString("es-CO")}
                            </td>
                          )}
                          <td className="num">{cop(f.precio_resultante)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <p>
                  <strong>Total: {cop(previewTotal)}</strong>
                </p>
                <form action={crearCotizacionCalculada} className="filtros">
                  <input type="hidden" name="idempotency_key" value={idempotencyKey} />
                  <input type="hidden" name="id_producto" value={sp.id_producto} />
                  <input type="hidden" name="id_variante" value={sp.id_variante ?? ""} />
                  <input type="hidden" name="id_organizacion" value={sp.id_organizacion ?? ""} />
                  <input type="hidden" name="cantidad" value={sp.cantidad} />
                  <input type="hidden" name="id_tecnica" value={sp.id_tecnica ?? ""} />
                  <input type="hidden" name="numero_preparaciones" value={sp.numero_preparaciones ?? "1"} />
                  <input type="hidden" name="transporte_total" value={sp.transporte_total ?? "0"} />
                  <input type="hidden" name="margen_override_pct" value={sp.margen_override_pct ?? ""} />
                  <input type="hidden" name="notas" value={sp.notas ?? ""} />
                  <button type="submit" disabled={!puedeCotizar}>
                    Confirmar y emitir cotización
                  </button>
                </form>
              </>
            )}
          </div>
        </>
      )}

      <h2>Últimas cotizaciones</h2>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Número</th>
              <th>Estado</th>
              <th>Método</th>
              <th className="num">Total</th>
              <th>Creada</th>
            </tr>
          </thead>
          <tbody>
            {cotizaciones.map((c) => (
              <tr key={c.id_cotizacion}>
                <td>
                  <a href={`/cotizador/${c.id_cotizacion}`}>#{c.numero}</a>
                </td>
                <td>
                  <span className="insignia">{c.estado}</span>
                </td>
                <td>{c.metodo_precio ?? "—"}</td>
                <td className="num">{cop(c.total)}</td>
                <td>{new Date(c.created_at).toLocaleString("es-CO")}</td>
              </tr>
            ))}
            {cotizaciones.length === 0 && (
              <tr>
                <td colSpan={5} style={{ color: "var(--texto-suave)" }}>
                  Sin cotizaciones emitidas.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="aviso-caja neutro">
        Catálogo actual: {r?.productos_propios_activos ?? "?"} productos activos,{" "}
        {r?.precios_comerciales_vigentes ?? "?"} precios publicados vigentes
        {r?.productos_propios_borrador
          ? ` y ${r.productos_propios_borrador} borradores por costos sin confirmar`
          : ""}
        . El flujo nuevo usa <code>fn_consola_crear_cotizacion_calculada()</code> y
        persiste componentes/snapshots para auditoría.
      </div>
    </>
  );
}
