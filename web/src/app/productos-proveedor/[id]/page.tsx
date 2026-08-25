import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

const cop = (v: number) => "$" + v.toLocaleString("es-CO", { maximumFractionDigits: 0 });

export default async function PaginaProductoProveedor({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const supabase = await crearClienteServidor();

  const [prod, snaps] = await Promise.all([
    supabase
      .from("producto_proveedor")
      .select("*, proveedor(id_proveedor, nombre)")
      .eq("id_producto_proveedor", id)
      .maybeSingle(),
    supabase
      .from("precio_proveedor_snapshot")
      .select("*")
      .eq("id_producto_proveedor", id)
      .order("observado_en", { ascending: false }),
  ]);

  if (!prod.data) {
    return (
      <>
        <h1>Producto no encontrado</h1>
        <p className="subtitulo">
          <Link href="/proveedores">← Proveedores</Link>
        </p>
      </>
    );
  }

  const p = prod.data;
  const proveedor = p.proveedor as { id_proveedor: string; nombre: string } | null;
  const historico = snaps.data ?? [];

  return (
    <>
      <p className="subtitulo" style={{ marginBottom: 6 }}>
        {proveedor ? (
          <Link href={`/proveedores/${proveedor.id_proveedor}`}>
            ← {proveedor.nombre}
          </Link>
        ) : (
          <Link href="/proveedores">← Proveedores</Link>
        )}
      </p>
      <h1>{p.nombre_original}</h1>
      <p className="subtitulo">
        {p.categoria ?? "sin categoria"} ·{" "}
        <span
          className={
            p.estado_calidad === "VALID" ? "insignia" : "insignia aviso"
          }
        >
          {p.estado_calidad}
        </span>
      </p>

      {p.motivo_revision && (
        <div className="aviso-caja">Motivo de revision: {p.motivo_revision}</div>
      )}

      <h2>Ficha</h2>
      <div className="tarjeta">
        <dl className="datos">
          <dt>SKU proveedor</dt>
          <dd>{p.sku_proveedor ?? "—"}</dd>
          <dt>Descripcion</dt>
          <dd>{p.descripcion ?? "—"}</dd>
          <dt>Etiquetas</dt>
          <dd>{(p.tags ?? []).join(", ") || "—"}</dd>
          <dt>URL del producto</dt>
          <dd>
            {p.url_producto ? (
              <a href={p.url_producto} target="_blank" rel="noreferrer">
                {p.url_producto}
              </a>
            ) : (
              "—"
            )}
          </dd>
        </dl>
      </div>

      <h2>Historico de precios observados ({historico.length})</h2>
      <div className="aviso-caja neutro">
        Esta tabla es de solo lectura por diseno. Un cambio de precio no edita un
        snapshot: crea una observacion nueva, para que cualquier calculo pasado
        siga siendo reproducible.
      </div>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Observado</th>
              <th className="num">Precio</th>
              <th>Moneda</th>
              <th>Unidad</th>
              <th className="num">Cantidad pack</th>
              <th className="num">Minimo</th>
              <th>Formato</th>
              <th>Disponibilidad</th>
              <th>Fuente</th>
            </tr>
          </thead>
          <tbody>
            {historico.map((s) => (
              <tr key={s.id_snapshot}>
                <td>{new Date(s.observado_en).toLocaleDateString("es-CO")}</td>
                <td className="num">{cop(s.precio_publicado)}</td>
                <td>{s.moneda}</td>
                <td>{s.unidad_compra ?? "—"}</td>
                <td className="num">{s.cantidad_pack ?? "—"}</td>
                <td className="num">{s.minimo_compra ?? "—"}</td>
                <td>
                  {s.ancho_cm && s.alto_cm ? `${s.ancho_cm} × ${s.alto_cm} cm` : "—"}
                </td>
                <td>{s.disponibilidad ?? "—"}</td>
                <td>
                  {s.url_fuente ? (
                    <a href={s.url_fuente} target="_blank" rel="noreferrer">
                      ver
                    </a>
                  ) : (
                    "—"
                  )}
                </td>
              </tr>
            ))}
            {historico.length === 0 && (
              <tr>
                <td colSpan={9} style={{ color: "var(--texto-suave)" }}>
                  Sin precios observados para este producto.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
