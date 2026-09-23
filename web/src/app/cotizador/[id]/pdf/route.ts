import { renderToBuffer } from "@react-pdf/renderer";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { BUCKET_COTIZACIONES, rutaPdfCotizacion } from "@/lib/documentos-cotizacion";
import { DocumentoCotizacion, type ClientePdf, type LineaPdf } from "./documento";
import { formatoFechaPdf } from "./formato";

type ItemRpc = {
  linea: number;
  nombre_item: string;
  descripcion_marcacion: string | null;
  unidad_compra: string;
  cantidad_pack: number | string | null;
  cantidad_presentaciones: number | string;
  unidades_totales: number;
  precio_unitario_venta: number | string | null;
  total_linea: number | string;
  status: string;
};

type ComponenteRpc = { status: string };

type Canal = { tipo: string; valor: string; estado: string };
type Persona = { nombre_completo: string; cargo: string | null };

const presentacionDe = (unidad: string, pack: number | string | null) => {
  const n = Number(pack ?? NaN);
  if (unidad === "PACK" && Number.isFinite(n) && n > 0) {
    return `Paquete x ${n.toLocaleString("es-CO")} und`;
  }
  if (unidad === "METER") return "Metro";
  if (unidad === "SHEET") return "Hoja";
  return "Unidad";
};

export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) {
    return new Response("No autorizado", { status: 401 });
  }

  if (sesion.rol === "LECTURA") return new Response("Tu rol puede descargar documentos archivados, pero no generar documentos nuevos.", { status: 403 });

  const { id } = await params;
  const supabase = await crearClienteServidor();

  const [{ data: cotizacion }, { data: componentes }, { data: items }] = await Promise.all([
    supabase
      .from("cotizacion")
      .select("numero, total, fecha_emision, notas, id_organizacion")
      .eq("id_cotizacion", id)
      .maybeSingle(),
    supabase.rpc("fn_consola_componentes_cotizacion", { p_id_cotizacion: id }),
    supabase.rpc("fn_consola_items_cotizacion", { p_id_cotizacion: id }),
  ]);

  if (!cotizacion) {
    return new Response("Cotización no encontrada", { status: 404 });
  }

  const filasValidas = ((componentes ?? []) as ComponenteRpc[]).filter(
    (f) => f.status === "OK",
  );

  // I-3: una cotizacion sin componentes persistidos (flujo simple anterior,
  // metodo_precio = TARIFA_PUBLICADA) no debe producir un PDF con tabla vacia
  // que parezca un documento de cara al cliente sin ninguna linea de detalle.
  if (filasValidas.length === 0) {
    return new Response(
      "PDF no disponible: esta cotizacion no tiene desglose de componentes persistido.",
      { status: 409 },
    );
  }

  const lineasRpc = ((items ?? []) as ItemRpc[]).filter((f) => f.status === "OK");

  if (lineasRpc.length === 0) {
    return new Response(
      "PDF no disponible: esta cotizacion no tiene lineas de producto persistidas.",
      { status: 409 },
    );
  }

  // Datos del cliente: el CRM que ya existe. La cotizacion no guarda contacto
  // propio y no hace falta que lo haga. El correo llega enmascarado para roles
  // no ADMIN porque lo enmascara fn_consola_canales_organizacion.
  let cliente: ClientePdf = null;
  const idOrganizacion = (cotizacion as { id_organizacion: string | null }).id_organizacion;

  if (idOrganizacion) {
    const [orgResp, canalesResp, personasResp] = await Promise.all([
      supabase
        .from("organizacion")
        .select("nombre_legal, nit, municipio, departamento")
        .eq("id_organizacion", idOrganizacion)
        .maybeSingle(),
      supabase.rpc("fn_consola_canales_organizacion", {
        p_id_organizacion: idOrganizacion,
      }),
      supabase.rpc("fn_consola_personas_organizacion", {
        p_id_organizacion: idOrganizacion,
      }),
    ]);

    const org = orgResp.data as {
      nombre_legal: string;
      nit: string | null;
      municipio: string | null;
      departamento: string | null;
    } | null;

    if (org) {
      const canales = ((canalesResp.data ?? []) as Canal[]).filter(
        (c) => c.estado === "ACTIVE",
      );
      const persona = ((personasResp.data ?? []) as Persona[])[0] ?? null;
      cliente = {
        nombre: org.nombre_legal,
        nit: org.nit,
        ciudad: [org.municipio, org.departamento].filter(Boolean).join(", ") || null,
        contacto: persona
          ? `${persona.nombre_completo}${persona.cargo ? ` — ${persona.cargo}` : ""}`
          : null,
        correo: canales.find((c) => c.tipo === "EMAIL")?.valor ?? null,
        telefono:
          canales.find((c) => c.tipo === "TELEFONO")?.valor ??
          canales.find((c) => c.tipo === "WHATSAPP")?.valor ??
          null,
      };
    }
  }

  const lineas: LineaPdf[] = lineasRpc.map((l) => ({
    linea: l.linea,
    nombre: l.nombre_item,
    detalle: l.descripcion_marcacion,
    presentacion: presentacionDe(l.unidad_compra, l.cantidad_pack),
    cantidad: Number(l.cantidad_presentaciones ?? 0),
    unidades: Number(l.unidades_totales ?? 0),
    esPack: l.unidad_compra === "PACK",
    precioUnitario: Number(l.precio_unitario_venta ?? 0),
    totalLinea: Number(l.total_linea ?? 0),
  }));

  const buffer = await renderToBuffer(
    DocumentoCotizacion({
      numero: (cotizacion as { numero: number }).numero,
      fecha: formatoFechaPdf(
        (cotizacion as { fecha_emision: string | null }).fecha_emision,
      ),
      total: Number((cotizacion as { total: number | string }).total),
      lineas,
      cliente,
      notas: (cotizacion as { notas: string | null }).notas,
    }),
  );

  const numero = (cotizacion as { numero: number }).numero;

  // Entregar solo un PDF archivado y registrado. Si el registro falla,
  // limpiar el archivo propio aun no registrado y mostrar el fallo.
  try {
    const rutaStorage = rutaPdfCotizacion(id, numero, sesion.userId);

    const { error: errorSubida } = await supabase.storage
      .from(BUCKET_COTIZACIONES)
      .upload(rutaStorage, new Uint8Array(buffer), {
        contentType: "application/pdf",
        upsert: false,
      });

    if (errorSubida) {
      console.error(
        `[pdf] no se pudo subir el PDF de la cotizacion ${id} a ${BUCKET_COTIZACIONES}:`,
        errorSubida.message,
      );
      return new Response("No se pudo archivar el PDF. Intenta nuevamente; la cotizacion sigue guardada.", { status: 503 });
    } else {
      // Solo se registra si el archivo esta realmente arriba: una fila que
      // apunte a un objeto inexistente daria un link de descarga roto.
      const { error: errorRegistro } = await supabase.rpc(
        "fn_consola_registrar_documento_cotizacion",
        {
          p_id_cotizacion: id,
          p_tipo_documento: "PDF_GENERADO",
          p_storage_path: rutaStorage,
          p_metadata: {
            numero,
            bytes: buffer.length,
            lineas: lineas.length,
            total: Number((cotizacion as { total: number | string }).total),
          },
        },
      );

      if (errorRegistro) {
        console.error(
          `[pdf] PDF subido pero no registrado para la cotizacion ${id}:`,
          errorRegistro.message,
        );
        await supabase.storage.from(BUCKET_COTIZACIONES).remove([rutaStorage]);
        return new Response("No se pudo registrar el PDF en el historial. Intenta nuevamente.", { status: 503 });
      }
    }
  } catch (e) {
    console.error(
      `[pdf] fallo inesperado archivando el PDF de la cotizacion ${id}:`,
      e instanceof Error ? e.message : e,
    );
    return new Response("No se pudo archivar el PDF. Intenta nuevamente.", { status: 503 });
  }

  return new Response(new Uint8Array(buffer), {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `attachment; filename="cotizacion-${numero}.pdf"`,
    },
  });
}
