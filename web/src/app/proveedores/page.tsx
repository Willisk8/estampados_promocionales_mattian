import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

type Calidad = {
  id_proveedor: string;
  proveedor: string;
  ciudad: string | null;
  activo: boolean;
  productos: number;
  productos_validos: number;
  productos_pendientes: number;
  productos_en_revision: number;
  productos_rechazados: number;
  snapshots: number;
  productos_sin_snapshot: number;
  precio_min: number | null;
  precio_promedio: number | null;
  precio_max: number | null;
  tiene_precio_sospechosamente_bajo: boolean;
  tiene_precio_sospechosamente_alto: boolean;
};

const cop = (v: number | null) =>
  v === null ? "—" : v.toLocaleString("es-CO", { maximumFractionDigits: 0 });

export default async function PaginaProveedores() {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase
    .from("vw_catalogo_proveedor_quality")
    .select("*")
    .order("productos", { ascending: false });

  const filas = (data ?? []) as Calidad[];
  const conAlerta = filas.filter(
    (f) => f.tiene_precio_sospechosamente_bajo || f.tiene_precio_sospechosamente_alto,
  );

  return (
    <>
      <h1>Proveedores</h1>
      <p className="subtitulo">
        Calidad del catalogo observado. Los precios son snapshots historicos:
        nunca se editan, un precio nuevo es una observacion nueva.
      </p>

      {error && <div className="aviso-caja">No se pudo consultar: {error.message}</div>}

      {conAlerta.length > 0 && (
        <div className="aviso-caja">
          {conAlerta.length} proveedor(es) con precios fuera de rango razonable
          (por debajo de $100 o por encima de $500.000). Revisar antes de usarlos
          para costear.
        </div>
      )}

      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Proveedor</th>
              <th>Ciudad</th>
              <th className="num">Productos</th>
              <th className="num">Validos</th>
              <th className="num">Por revisar</th>
              <th className="num">Sin precio</th>
              <th className="num">Precio min</th>
              <th className="num">Promedio</th>
              <th className="num">Precio max</th>
              <th>Alertas</th>
            </tr>
          </thead>
          <tbody>
            {filas.map((f) => (
              <tr key={f.id_proveedor}>
                <td>
                  <Link href={`/proveedores/${f.id_proveedor}`}>{f.proveedor}</Link>
                </td>
                <td>{f.ciudad ?? "—"}</td>
                <td className="num">{f.productos}</td>
                <td className="num">{f.productos_validos}</td>
                <td className="num">
                  {f.productos_pendientes + f.productos_en_revision}
                </td>
                <td className="num">{f.productos_sin_snapshot}</td>
                <td className="num">{cop(f.precio_min)}</td>
                <td className="num">{cop(f.precio_promedio)}</td>
                <td className="num">{cop(f.precio_max)}</td>
                <td>
                  {f.tiene_precio_sospechosamente_bajo && (
                    <span className="insignia alerta">bajo</span>
                  )}{" "}
                  {f.tiene_precio_sospechosamente_alto && (
                    <span className="insignia alerta">alto</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
