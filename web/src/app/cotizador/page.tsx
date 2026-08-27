import { randomUUID } from "node:crypto";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import { crearCotizacionSimple } from "./acciones";

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

const cop = (v: string | number) =>
  "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

export default async function PaginaCotizador({
  searchParams,
}: {
  searchParams: Promise<{ ok?: string; numero?: string; total?: string; status?: string; error?: string }>;
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
      .select("id_cotizacion, numero, total, estado, created_at")
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
  }>;
  const puedeCotizar = sesion.rol === "ADMIN" || sesion.rol === "COMERCIAL";
  const idempotencyKey = randomUUID();

  return (
    <>
      <h1>Cotizador</h1>
      <p className="subtitulo">
        Presente desde el primer dia para que la separacion entre cotizar y
        simular quede clara.
      </p>

      {sp.ok === "cotizacion" && (
        <div className="aviso-caja neutro">
          Cotizacion #{sp.numero} emitida por {cop(sp.total ?? 0)}.
        </div>
      )}
      {sp.status && (
        <div className="aviso-caja">
          No se pudo cotizar: <code>{sp.status}</code>.
        </div>
      )}
      {sp.error && <div className="aviso-caja">{sp.error}</div>}

      <h2>Cotizacion comercial</h2>
      <div className="tarjeta">
        <p style={{ marginTop: 0 }}>
          Consulta precios ya aprobados mediante <code>resolve_price()</code>. No
          recalcula nada: la RPC de servidor guarda una cotizacion emitida con
          snapshot del producto, precio y cantidad.
        </p>
        <form action={crearCotizacionSimple} className="filtros">
          <input type="hidden" name="idempotency_key" value={idempotencyKey} />
          <select name="id_organizacion" defaultValue="" disabled={!puedeCotizar}>
            <option value="">Sin organizacion asociada</option>
            {organizaciones.map((o) => (
              <option key={o.id_organizacion} value={o.id_organizacion}>
                {o.nombre_legal}
                {o.nit ? ` - ${o.nit}` : ""}
              </option>
            ))}
          </select>
          <select name="producto_variante" required disabled={!puedeCotizar}>
            <option value="">Producto aprobado</option>
            {productos.flatMap((p) => {
              const variantes = (p.variante_producto ?? []).filter(
                (v) => v.estado === "ACTIVE",
              );
              if (variantes.length === 0) {
                return [
                  <option key={p.id_producto} value={`${p.id_producto}|`}>
                    {p.sku} - {p.nombre}
                  </option>,
                ];
              }
              return variantes.map((v) => (
                <option
                  key={v.id_variante}
                  value={`${p.id_producto}|${v.id_variante}`}
                >
                  {p.sku} / {v.sku_variante} - {p.nombre} ({v.nombre})
                </option>
              ));
            })}
          </select>
          <input
            name="cantidad"
            type="number"
            min="1"
            placeholder="Cantidad"
            required
            disabled={!puedeCotizar}
          />
          <input name="notas" placeholder="Notas" disabled={!puedeCotizar} />
          <button type="submit" disabled={!puedeCotizar || productos.length === 0}>
            Emitir
          </button>
        </form>
        <p style={{ fontSize: 13, color: "var(--texto-suave)", marginBottom: 0 }}>
          <code>resolve_price()</code> sigue sin permiso directo para el navegador;
          solo la funcion controlada de cotizacion puede usarlo.
        </p>
      </div>

      <h2>Ultimas cotizaciones</h2>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Numero</th>
              <th>Estado</th>
              <th className="num">Total</th>
              <th>Creada</th>
            </tr>
          </thead>
          <tbody>
            {cotizaciones.map((c) => (
              <tr key={c.id_cotizacion}>
                <td>#{c.numero}</td>
                <td>
                  <span className="insignia">{c.estado}</span>
                </td>
                <td className="num">{cop(c.total)}</td>
                <td>{new Date(c.created_at).toLocaleString("es-CO")}</td>
              </tr>
            ))}
            {cotizaciones.length === 0 && (
              <tr>
                <td colSpan={4} style={{ color: "var(--texto-suave)" }}>
                  Sin cotizaciones emitidas.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <h2>Simulador administrativo</h2>
      <div className="tarjeta">
        <p style={{ marginTop: 0 }}>
          Calcula desde insumos: costo de proveedor, marcacion, empaque, mano de
          obra, gastos, retenciones y margen. Sirve para construir escalas nuevas,
          no para cotizarle a un cliente.
        </p>
        <div className="filtros">
          <input placeholder="Costo proveedor" disabled />
          <input placeholder="Tecnica" disabled />
          <input placeholder="Margen %" disabled />
          <button type="button" disabled>
            Simular
          </button>
        </div>
        <p style={{ fontSize: 13, color: "var(--texto-suave)", marginBottom: 0 }}>
          La logica vive hoy en <code>scripts/catalog/pricing_model.py</code> y se
          ejecuta desde consola, con entradas versionadas en JSON.
        </p>
      </div>

      <div className="aviso-caja neutro">
        Catalogo actual: {r?.productos_propios_activos ?? "?"} productos activos,{" "}
        {r?.precios_comerciales_vigentes ?? "?"} precios vigentes
        {r?.productos_propios_borrador
          ? ` y ${r.productos_propios_borrador} borradores por costos sin confirmar`
          : ""}
        .{" "}
        Estas dos funciones estan separadas a proposito. Un precio aprobado no
        debe recalcularse libremente durante una cotizacion: si el calculo cambia,
        cambia la escala, y eso pasa por revision.
      </div>
    </>
  );
}
