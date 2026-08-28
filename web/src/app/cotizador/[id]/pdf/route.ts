import { renderToBuffer } from "@react-pdf/renderer";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { DocumentoCotizacion } from "./documento";
import { formatoFechaPdf } from "./formato";

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

  // I-3: una cotizacion sin componentes persistidos (flujo simple anterior,
  // metodo_precio = TARIFA_PUBLICADA) no debe producir un PDF con tabla vacia
  // que parezca un documento de cara al cliente sin ninguna linea de detalle.
  if (filasValidas.length === 0) {
    return new Response(
      "PDF no disponible: esta cotizacion no tiene desglose de componentes persistido.",
      { status: 409 },
    );
  }

  const buffer = await renderToBuffer(
    DocumentoCotizacion({
      numero: cotizacion.numero,
      fecha: formatoFechaPdf(cotizacion.fecha_emision as string | null),
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
