import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

type Precio = {
  id_precio: string;
  id_variante: string | null;
  precio_unitario: number;
  moneda: string;
  quantity_range: string;
  validity: string;
};

type Variante = {
  id_variante: string;
  sku_variante: string;
  nombre: string;
  estado: string;
  atributos: Record<string, unknown>;
};

type Producto = {
  id_producto: string;
  sku: string;
  nombre: string;
  categoria: string | null;
  descripcion: string | null;
  estado: string;
  variante_producto: Variante[];
  precio_producto: Precio[];
};

const cop = (v: number) => "$" + v.toLocaleString("es-CO", { maximumFractionDigits: 0 });

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

function ordenRango(rango: string): number {
  const m = rango.match(/^[\[(](\d*),/);
  return m && m[1] ? Number(m[1]) : 0;
}

export default async function PaginaProductosPropios() {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase
    .from("producto")
    .select(
      "id_producto, sku, nombre, categoria, descripcion, estado, " +
        "variante_producto(id_variante, sku_variante, nombre, estado, atributos), " +
        "precio_producto(id_precio, id_variante, precio_unitario, moneda, quantity_range, validity)",
    )
    .order("sku");

  const productos = (data ?? []) as unknown as Producto[];
  const activos = productos.filter((p) => p.estado === "ACTIVE");
  const borradores = productos.filter((p) => p.estado !== "ACTIVE");

  return (
    <>
      <h1>Productos propios</h1>
      <p className="subtitulo">
        El catalogo que Estampados vende. Solo los productos en estado{" "}
        <code>ACTIVE</code> son cotizables por <code>resolve_price()</code>.
      </p>

      {error && <div className="aviso-caja">No se pudo consultar: {error.message}</div>}

      <div className="rejilla">
        <div className="tarjeta">
          <div className="cifra">{activos.length}</div>
          <div className="etiqueta">Activos y cotizables</div>
        </div>
        <div className="tarjeta">
          <div className="cifra">{borradores.length}</div>
          <div className="etiqueta">En borrador</div>
        </div>
        <div className="tarjeta">
          <div className="cifra">
            {productos.reduce((n, p) => n + (p.precio_producto?.length ?? 0), 0)}
          </div>
          <div className="etiqueta">Precios por escala</div>
        </div>
      </div>

      {borradores.length > 0 && (
        <div className="aviso-caja">
          {borradores.length} producto(s) en borrador por tener costos placeholder
          sin confirmar (migracion 023). Tienen precios calculados, pero no se
          pueden cotizar hasta que se revisen sus costos.
        </div>
      )}

      {productos.map((p) => {
        const precios = [...(p.precio_producto ?? [])].sort(
          (a, b) => ordenRango(a.quantity_range) - ordenRango(b.quantity_range),
        );
        const variante = p.variante_producto?.[0];

        return (
          <section key={p.id_producto}>
            <h2>
              {p.nombre}{" "}
              <span
                className={p.estado === "ACTIVE" ? "insignia" : "insignia aviso"}
              >
                {p.estado}
              </span>
            </h2>
            <p className="subtitulo" style={{ marginBottom: 10 }}>
              <code>{p.sku}</code>
              {p.categoria ? ` · ${p.categoria}` : ""}
              {variante ? ` · variante ${variante.sku_variante}` : ""}
              {" · "}
              <Link href={`/productos-propios/${p.id_producto}`}>
                ver desglose
              </Link>
            </p>

            <div className="tabla-contenedor">
              <table>
                <thead>
                  <tr>
                    <th>Cantidad</th>
                    <th className="num">Precio unitario</th>
                    <th className="num">Total de la escala</th>
                    <th>Moneda</th>
                  </tr>
                </thead>
                <tbody>
                  {precios.map((pr) => {
                    const legible = rangoLegible(pr.quantity_range);
                    const min = Number(legible.split(" ")[0]) || 1;
                    return (
                      <tr key={pr.id_precio}>
                        <td>{legible}</td>
                        <td className="num">{cop(pr.precio_unitario)}</td>
                        <td className="num">{cop(pr.precio_unitario * min)}</td>
                        <td>{pr.moneda}</td>
                      </tr>
                    );
                  })}
                  {precios.length === 0 && (
                    <tr>
                      <td colSpan={4} style={{ color: "var(--texto-suave)" }}>
                        Sin precios calculados.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </section>
        );
      })}

      {productos.length === 0 && !error && (
        <div className="aviso-caja">
          No hay productos propios visibles. Si esperabas ver el catalogo MVP,
          revisa que la migracion 026 este aplicada en este entorno.
        </div>
      )}
    </>
  );
}
