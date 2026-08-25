import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import { rangoLegible, ordenRango } from "@/lib/rangos";

export const dynamic = "force-dynamic";

const cop = (v: number) => "$" + v.toLocaleString("es-CO", { maximumFractionDigits: 0 });
const pct = (v: number) => (v * 100).toFixed(1) + " %";


export default async function PaginaProductoPropio({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const esAdmin = sesion.rol === "ADMIN";
  const supabase = await crearClienteServidor();

  const [prod, precios, costos, mapeos] = await Promise.all([
    supabase
      .from("producto")
      .select("*, variante_producto(*)")
      .eq("id_producto", id)
      .maybeSingle(),
    supabase.from("precio_producto").select("*").eq("id_producto", id),
    supabase.from("costo_producto").select("*").eq("id_producto", id),
    supabase.from("mapeo_proveedor_variante").select("*"),
  ]);

  if (!prod.data) {
    return (
      <>
        <h1>Producto no encontrado</h1>
        <p className="subtitulo">
          <Link href="/productos-propios">← Volver</Link>
        </p>
      </>
    );
  }

  const p = prod.data;
  const variantes = (p.variante_producto ?? []) as Array<{
    id_variante: string;
    sku_variante: string;
    nombre: string;
    estado: string;
    atributos: Record<string, unknown>;
  }>;
  const listaPrecios = [...(precios.data ?? [])].sort(
    (a, b) => ordenRango(a.quantity_range) - ordenRango(b.quantity_range),
  );
  const costo = (costos.data ?? [])[0];
  const costoTotal = costo
    ? Number(costo.costo_base) +
      Number(costo.costo_personalizacion) +
      Number(costo.costo_empaque) +
      Number(costo.otros_costos)
    : null;

  const idsVariante = new Set(variantes.map((v) => v.id_variante));
  const mapeosDelProducto = (mapeos.data ?? []).filter((m) =>
    idsVariante.has(m.id_variante),
  );

  return (
    <>
      <p className="subtitulo" style={{ marginBottom: 6 }}>
        <Link href="/productos-propios">← Productos propios</Link>
      </p>
      <h1>{p.nombre}</h1>
      <p className="subtitulo">
        <code>{p.sku}</code>
        {p.categoria ? ` · ${p.categoria}` : ""} ·{" "}
        <span className={p.estado === "ACTIVE" ? "insignia" : "insignia aviso"}>
          {p.estado}
        </span>
      </p>

      {p.descripcion && <p style={{ maxWidth: 720 }}>{p.descripcion}</p>}

      <h2>Variantes</h2>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>SKU</th>
              <th>Nombre</th>
              <th>Estado</th>
              <th>Atributos</th>
            </tr>
          </thead>
          <tbody>
            {variantes.map((v) => (
              <tr key={v.id_variante}>
                <td>
                  <code>{v.sku_variante}</code>
                </td>
                <td>{v.nombre}</td>
                <td>
                  <span
                    className={v.estado === "ACTIVE" ? "insignia" : "insignia aviso"}
                  >
                    {v.estado}
                  </span>
                </td>
                <td>
                  {Object.entries(v.atributos ?? {}).map(([k, val]) => (
                    <span key={k} className="insignia neutra" style={{ marginRight: 4 }}>
                      {k}: {String(val)}
                    </span>
                  ))}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {esAdmin && costo && (
        <>
          <h2>Estructura de costo</h2>
          <p className="subtitulo" style={{ marginBottom: 10 }}>
            Vigencia registrada: <code>{String(costo.vigencia)}</code>
          </p>
          <div className="tabla-contenedor">
            <table>
              <thead>
                <tr>
                  <th>Componente</th>
                  <th className="num">Valor unitario</th>
                  <th className="num">Peso</th>
                </tr>
              </thead>
              <tbody>
                {[
                  ["Costo base (proveedor)", costo.costo_base],
                  ["Personalizacion / marcacion", costo.costo_personalizacion],
                  ["Empaque", costo.costo_empaque],
                  ["Otros costos", costo.otros_costos],
                ].map(([etiqueta, valor]) => (
                  <tr key={String(etiqueta)}>
                    <td>{etiqueta}</td>
                    <td className="num">{cop(Number(valor))}</td>
                    <td className="num">
                      {costoTotal ? pct(Number(valor) / costoTotal) : "—"}
                    </td>
                  </tr>
                ))}
                <tr>
                  <td>
                    <strong>Costo total</strong>
                  </td>
                  <td className="num">
                    <strong>{cop(costoTotal ?? 0)}</strong>
                  </td>
                  <td className="num">100 %</td>
                </tr>
              </tbody>
            </table>
          </div>
        </>
      )}

      {!esAdmin && (
        <div className="aviso-caja neutro">
          La estructura de costo y el margen solo son visibles para el rol ADMIN.
          Tu rol es {sesion.rol}.
        </div>
      )}

      <h2>Precios por escala</h2>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Cantidad</th>
              <th className="num">Precio unitario</th>
              {esAdmin && <th className="num">Utilidad unitaria</th>}
              {esAdmin && <th className="num">Margen implicito</th>}
              <th>Vigencia</th>
            </tr>
          </thead>
          <tbody>
            {listaPrecios.map((pr) => {
              const precio = Number(pr.precio_unitario);
              const utilidad = costoTotal !== null ? precio - costoTotal : null;
              return (
                <tr key={pr.id_precio}>
                  <td>{rangoLegible(pr.quantity_range)}</td>
                  <td className="num">{cop(precio)}</td>
                  {esAdmin && (
                    <td className="num">{utilidad !== null ? cop(utilidad) : "—"}</td>
                  )}
                  {esAdmin && (
                    <td className="num">
                      {utilidad !== null ? pct(utilidad / precio) : "—"}
                    </td>
                  )}
                  <td>{String(pr.validity).slice(1, 11)} en adelante</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {esAdmin && costoTotal !== null && (
        <div className="aviso-caja">
          <strong>El margen de arriba es una estimacion, no el dato guardado.</strong>{" "}
          Se calcula restando un unico costo total a cada escala, pero{" "}
          <code>costo_producto</code> tiene una sola fila para este producto,
          registrada a una cantidad de referencia. El costo real baja al comprar
          por caja o al amortizar la marcacion, asi que el margen verdadero de las
          escalas altas es mayor que el que ves.
        </div>
      )}

      <h2>Trazabilidad del calculo</h2>
      <div className="aviso-caja">
        Esto es lo que <strong>no</strong> esta guardado en la base, y es el
        trabajo que falta antes de poder cotizar de verdad:
        <ul style={{ margin: "8px 0 0", paddingLeft: 20 }}>
          <li>
            De que snapshot de proveedor salio el costo base
            {mapeosDelProducto.length === 0 && (
              <>
                {" "}
                — <code>mapeo_proveedor_variante</code> esta vacio, asi que no hay
                ningun vinculo entre este producto y el catalogo del proveedor
              </>
            )}
          </li>
          <li>Que tecnica de marcacion y que snapshot de precio se uso</li>
          <li>Que margen, retenciones y mano de obra se aplicaron</li>
          <li>Como cambia el costo entre una escala y otra</li>
        </ul>
        <p style={{ marginBottom: 0, marginTop: 8 }}>
          Hoy ese calculo vive en <code>scripts/catalog/pricing_model.py</code> con
          entradas en <code>mvp_catalog_inputs.json</code>, fuera de la base. La
          base guarda el resultado, no el razonamiento.
        </p>
      </div>
    </>
  );
}
