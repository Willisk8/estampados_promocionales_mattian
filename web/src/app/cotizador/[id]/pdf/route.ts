import { renderToBuffer } from "@react-pdf/renderer";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { DocumentoCotizacion } from "./documento";

type ComponenteRpc = {
  descripcion: string;
  precio_resultante: number | string;
  status: string;
};

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) {
    return new Response("No autorizado", { status: 401 });
  }

  const { id } = await params;
  const supabase = await crearClienteServidor();

  const [{ data: cotizacion }, { data: componentes }] = await Promise.all([
    supabase.from("cotizacion").select("numero, total, fecha_emision").eq("id_cotizacion", id).maybeSingle(),
    supabase.rpc("fn_consola_componentes_cotizacion", { p_id_cotizacion: id }),
  ]);

  if (!cotizacion) {
    return new Response("Cotización no encontrada", { status: 404 });
  }

  const filas = (componentes ?? []) as ComponenteRpc[];
  const filasValidas = filas.filter((f) => f.status === "OK");

  const buffer = await renderToBuffer(
    DocumentoCotizacion({
      numero: cotizacion.numero,
      fecha: new Date(cotizacion.fecha_emision).toLocaleString("es-CO"),
      total: Number(cotizacion.total),
      componentes: filasValidas.map((f) => ({
        descripcion: f.descripcion,
        precio_resultante: Number(f.precio_resultante),
      })),
    })
  );

  return new Response(new Uint8Array(buffer), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `attachment; filename="cotizacion-${cotizacion.numero}.pdf"`,
    },
  });
}
