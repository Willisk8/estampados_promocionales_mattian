import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

const cop = (v: string | number | null | undefined) =>
  v === null || v === undefined
    ? "—"
    : "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

type Cotizacion = {
  id_cotizacion: string;
  numero: number;
  total: number | string;
  estado: string;
  fecha_emision: string | null;
  metodo_precio: string | null;
  notas: string | null;
};

type Componente = {
  tipo_componente: string;
  descripcion: string;
  cantidad: number | string;
  costo_unitario: number | string | null;
  costo_total: number | string | null;
  margen_aplicado_pct: number | string | null;
  precio_resultante: number | string;
  status: string;
};

export default async function DetalleCotizacion({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const supabase = await crearClienteServidor();
  const [{ data: cotizacion }, { data: componentes }] = await Promise.all([
    supabase
      .from("cotizacion")
      .select("id_cotizacion, numero, total, estado, fecha_emision, metodo_precio, notas")
      .eq("id_cotizacion", id)
      .maybeSingle(),
    supabase.rpc("fn_consola_componentes_cotizacion", { p_id_cotizacion: id }),
  ]);

  if (!cotizacion) {
    return (
      <>
        <h1>Cotización no encontrada</h1>
        <p className="subtitulo">No existe una cotización con ese identificador.</p>
      </>
    );
  }

  const c = cotizacion as Cotizacion;
  const filas = (componentes ?? []) as Componente[];
  const filasValidas = filas.filter((f) => f.status === "OK");
  const puedeVerCostos = sesion.rol === "ADMIN";
  const puedeGenerarPdf = filasValidas.length > 0;

  return (
    <>
      <h1>Cotización #{c.numero}</h1>
      <p className="subtitulo">
        Método: {c.metodo_precio ?? "—"} · Estado: {c.estado} · Emitida:{" "}
        {c.fecha_emision ? new Date(c.fecha_emision).toLocaleString("es-CO") : "—"}
      </p>

      {filas[0]?.status && filas[0].status !== "OK" && (
        <div className="aviso-caja">
          No se pudo leer el desglose: <code>{filas[0].status}</code>.
        </div>
      )}

      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Componente</th>
              <th>Descripción</th>
              <th className="num">Cantidad</th>
              {puedeVerCostos && <th className="num">Costo unitario</th>}
              {puedeVerCostos && <th className="num">Costo total</th>}
              {puedeVerCostos && <th className="num">Margen %</th>}
              <th className="num">Precio</th>
            </tr>
          </thead>
          <tbody>
            {filasValidas.map((f, index) => (
              <tr key={`${f.tipo_componente}-${index}`}>
                <td>
                  <span className="insignia">{f.tipo_componente}</span>
                </td>
                <td>{f.descripcion}</td>
                <td className="num">{Number(f.cantidad).toLocaleString("es-CO")}</td>
                {puedeVerCostos && <td className="num">{cop(f.costo_unitario)}</td>}
                {puedeVerCostos && <td className="num">{cop(f.costo_total)}</td>}
                {puedeVerCostos && (
                  <td className="num">
                    {f.margen_aplicado_pct === null ? "—" : Number(f.margen_aplicado_pct).toLocaleString("es-CO")}
                  </td>
                )}
                <td className="num">{cop(f.precio_resultante)}</td>
              </tr>
            ))}
            {filasValidas.length === 0 && (
              <tr>
                <td colSpan={puedeVerCostos ? 7 : 4} style={{ color: "var(--texto-suave)" }}>
                  Esta cotización no tiene componentes persistidos.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="tarjeta">
        <p style={{ marginTop: 0 }}>
          <strong>Total:</strong> {cop(c.total)}
        </p>
        {c.notas && <p>{c.notas}</p>}
        <div className="filtros">
          <a href="/cotizador">
            <button type="button">Volver al cotizador</button>
          </a>
          <button type="button" disabled title="Pendiente: generación/envío de PDF">
            Enviar PDF por correo
          </button>
          {puedeGenerarPdf ? (
            <a href={`/cotizador/${id}/pdf`}>
              <button type="button">Generar PDF</button>
            </a>
          ) : (
            <button
              type="button"
              disabled
              title="PDF no disponible: esta cotización no tiene desglose de componentes persistido"
            >
              Generar PDF
            </button>
          )}
        </div>
      </div>
    </>
  );
}
