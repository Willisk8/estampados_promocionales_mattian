import { randomUUID } from "node:crypto";
import { crearClienteServidor } from "@/lib/supabase/servidor";

/**
 * PDFs de cotizacion en Supabase Storage.
 *
 * Mismo patron que lib/imagenes.ts: bucket PRIVADO, URLs firmadas server-side
 * y de vida corta. Un PDF de cotizacion lleva precios y datos del cliente, asi
 * que nunca se sirve por URL publica.
 *
 * El bucket y la RLS los crea la migracion 076; la fila de registro la escribe
 * fn_consola_registrar_documento_cotizacion (042, ampliada en 076).
 */
export const BUCKET_COTIZACIONES = "cotizaciones-pdf";

/** 30 minutos, igual que las imagenes de catalogo. */
const VIGENCIA_SEGUNDOS = 60 * 30;

export type DocumentoCotizacion = {
  id_cotizacion_documento: string;
  tipo_documento: string;
  storage_path: string;
  created_at: string;
  rol_consola: string;
  metadata: Record<string, unknown> | null;
};

export type DocumentoConUrl = DocumentoCotizacion & {
  /** null cuando el objeto ya no esta en Storage o la firma fallo. */
  url: string | null;
};

/**
 * Ruta estable y unica de un PDF dentro del bucket.
 *
 * Se agrupa por cotizacion para que listar/limpiar una cotizacion sea un
 * prefijo, y lleva un UUID porque regenerar el PDF NO debe pisar el anterior:
 * cada generacion es un documento propio con su fila y su fecha.
 */
export function rutaPdfCotizacion(idCotizacion: string, numero: number, userId: string): string {
  return `cotizaciones/${idCotizacion}/${userId}/${numero}-${randomUUID()}.pdf`;
}

/**
 * Documentos de una cotizacion, cada uno con su URL de descarga firmada.
 *
 * La RLS de 077 filtra documentos segun el rol y oculta los PDF de ADMIN a
 * otros perfiles activos, asi que se consulta la tabla directo. Las firmas se
 * piden en lote (createSignedUrls) por la misma razon que en imagenes.ts: una
 * llamada por fila seria una llamada por PDF.
 */
export async function documentosDeCotizacion(
  idCotizacion: string,
): Promise<DocumentoConUrl[]> {
  const supabase = await crearClienteServidor();

  const { data, error } = await supabase
    .from("cotizacion_documento")
    .select("id_cotizacion_documento, tipo_documento, storage_path, created_at, rol_consola, metadata")
    .eq("id_cotizacion", idCotizacion)
    .order("created_at", { ascending: false });

  if (error) throw new Error("No se pudo consultar el historial de documentos.");
  const filas = (data ?? []) as DocumentoCotizacion[];
  if (filas.length === 0) return [];

  const rutas = filas.map((f) => f.storage_path);
  const { data: firmadas } = await supabase.storage
    .from(BUCKET_COTIZACIONES)
    .createSignedUrls(rutas, VIGENCIA_SEGUNDOS);

  const porRuta = new Map(
    (firmadas ?? [])
      .filter((f) => f.signedUrl && !f.error)
      .map((f) => [f.path as string, f.signedUrl as string]),
  );

  return filas.map((f) => ({ ...f, url: porRuta.get(f.storage_path) ?? null }));
}
