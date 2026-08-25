"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { crearClienteServidor } from "@/lib/supabase/servidor";

export async function crearCotizacionSimple(formData: FormData) {
  const seleccion = String(formData.get("producto_variante") ?? "");
  const [idProducto, idVarianteRaw = ""] = seleccion.split("|");
  const idOrganizacionRaw = String(formData.get("id_organizacion") ?? "");
  const cantidad = Number(formData.get("cantidad") ?? 0);
  const notas = String(formData.get("notas") ?? "");

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_crear_cotizacion_simple", {
    p_id_organizacion: idOrganizacionRaw || null,
    p_id_producto: idProducto,
    p_id_variante: idVarianteRaw || null,
    p_cantidad: cantidad,
    p_moneda: "COP",
    p_notas: notas || null,
  });

  revalidatePath("/cotizador");

  if (error) redirect(`/cotizador?error=${encodeURIComponent(error.message)}`);

  const resultado = data?.[0] as
    | { numero: number | null; total: number | string | null; status: string }
    | undefined;

  if (!resultado || resultado.status !== "OK") {
    redirect(`/cotizador?status=${encodeURIComponent(resultado?.status ?? "ERROR")}`);
  }

  redirect(
    `/cotizador?ok=cotizacion&numero=${resultado.numero}&total=${encodeURIComponent(
      String(resultado.total),
    )}`,
  );
}
