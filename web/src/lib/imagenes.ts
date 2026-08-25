import { crearClienteServidor } from "@/lib/supabase/servidor";

const BUCKET = "catalogo-proveedor";
const VIGENCIA_SEGUNDOS = 60 * 30;

export type ImagenProducto = {
  id_producto_proveedor: string;
  ruta_storage: string | null;
  url_origen: string;
  estado: string;
  capturada_en: string | null;
};

/**
 * Devuelve una URL firmada por producto, para las imagenes ya copiadas.
 *
 * El bucket es privado: se sirve con la sesion del usuario y la politica de
 * storage exige un perfil de consola activo. Se firman en lote porque pedir
 * una firma por producto en un listado de 300 seria una llamada por fila.
 *
 * Las imagenes que todavia no se han copiado devuelven null en vez de caer al
 * CDN del proveedor: mostrar unas desde Storage y otras desde fuera haria
 * imposible saber que se esta viendo.
 */
export async function firmarImagenes(
  idsProductoProveedor: string[],
): Promise<Map<string, { url: string; capturada_en: string | null }>> {
  const resultado = new Map<string, { url: string; capturada_en: string | null }>();
  if (idsProductoProveedor.length === 0) return resultado;

  const supabase = await crearClienteServidor();

  const { data: imagenes } = await supabase
    .from("imagen_producto_proveedor")
    .select("id_producto_proveedor, ruta_storage, capturada_en, estado")
    .in("id_producto_proveedor", idsProductoProveedor)
    .eq("estado", "DESCARGADA");

  const filas = (imagenes ?? []) as ImagenProducto[];
  const rutas = filas
    .map((f) => f.ruta_storage)
    .filter((r): r is string => Boolean(r));
  if (rutas.length === 0) return resultado;

  const { data: firmadas } = await supabase.storage
    .from(BUCKET)
    .createSignedUrls(rutas, VIGENCIA_SEGUNDOS);

  const porRuta = new Map(
    (firmadas ?? [])
      .filter((f) => f.signedUrl && !f.error)
      .map((f) => [f.path as string, f.signedUrl as string]),
  );

  for (const fila of filas) {
    if (!fila.ruta_storage) continue;
    const url = porRuta.get(fila.ruta_storage);
    if (url) {
      resultado.set(fila.id_producto_proveedor, {
        url,
        capturada_en: fila.capturada_en,
      });
    }
  }

  return resultado;
}
