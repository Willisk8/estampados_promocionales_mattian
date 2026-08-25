import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

type Snapshot = {
  id_snapshot: string;
  precio_publicado: number;
  moneda: string;
  unidad_compra: string | null;
  cantidad_pack: number | null;
  minimo_compra: number | null;
  observado_en: string;
  url_fuente: string | null;
};

type ProductoProveedor = {
  id_producto_proveedor: string;
  sku_proveedor: string | null;
  nombre_original: string;
  categoria: string | null;
  estado_calidad: string;
  motivo_revision: string | null;
  url_producto: string | null;
  precio_proveedor_snapshot: Snapshot[];
};

const cop = (v: number) => "$" + v.toLocaleString("es-CO", { maximumFractionDigits: 0 });

const insigniaCalidad = (estado: string) =>
  estado === "VALID" ? "insignia" : estado === "REJECTED" ? "insignia alerta" : "insignia aviso";

export default async function PaginaProveedor({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const supabase = await crearClienteServidor();

  const [prov, productos] = await Promise.all([
    supabase.from("proveedor").select("*").eq("id_proveedor", id).maybeSingle(),
    supabase
      .from("producto_proveedor")
      .select(
        "id_producto_proveedor, sku_proveedor, nombre_original, categoria, estado_calidad, motivo_revision, url_producto, precio_proveedor_snapshot(id_snapshot, precio_publicado, moneda, unidad_compra, cantidad_pack, minimo_compra, observado_en, url_fuente)",
      )
      .eq("id_proveedor", id)
      .order("nombre_original")
      .limit(300),
  ]);

  if (!prov.data) {
    return (
      <>
        <h1>Proveedor no encontrado</h1>
        <p className="subtitulo">
          <Link href="/proveedores">← Volver</Link>
        </p>
      </>
    );
  }

  const lista = (productos.data ?? []) as unknown as ProductoProveedor[];

  return (
    <>
      <p className="subtitulo" style={{ marginBottom: 6 }}>
        <Link href="/proveedores">← Proveedores</Link>
      </p>
      <h1>{prov.data.nombre}</h1>
      <p className="subtitulo">
        {prov.data.ciudad ?? "sin ciudad"} · {lista.length} productos ·{" "}
        {prov.data.activo ? "activo" : "inactivo"}
      </p>

      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Producto</th>
              <th>SKU proveedor</th>
              <th>Categoria</th>
              <th>Calidad</th>
              <th className="num">Precio mas reciente</th>
              <th>Unidad</th>
              <th className="num">Observaciones</th>
              <th>Fuente</th>
            </tr>
          </thead>
          <tbody>
            {lista.map((p) => {
              const snaps = [...(p.precio_proveedor_snapshot ?? [])].sort(
                (a, b) =>
                  new Date(b.observado_en).getTime() - new Date(a.observado_en).getTime(),
              );
              const ultimo = snaps[0];
              return (
                <tr key={p.id_producto_proveedor}>
                  <td>
                    <Link href={`/productos-proveedor/${p.id_producto_proveedor}`}>
                      {p.nombre_original}
                    </Link>
                  </td>
                  <td>{p.sku_proveedor ?? "—"}</td>
                  <td>{p.categoria ?? "—"}</td>
                  <td>
                    <span className={insigniaCalidad(p.estado_calidad)}>
                      {p.estado_calidad}
                    </span>
                  </td>
                  <td className="num">
                    {ultimo ? cop(ultimo.precio_publicado) : "sin precio"}
                  </td>
                  <td>{ultimo?.unidad_compra ?? "—"}</td>
                  <td className="num">{snaps.length}</td>
                  <td>
                    {p.url_producto ? (
                      <a href={p.url_producto} target="_blank" rel="noreferrer">
                        ver
                      </a>
                    ) : (
                      "—"
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </>
  );
}
