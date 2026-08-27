"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { crearClienteServidor } from "@/lib/supabase/servidor";
import { agregarParametroARutaInterna, rutaInternaSegura } from "@/lib/rutas-internas";

export async function resolverRevision(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const estado = String(formData.get("estado") ?? "");
  const notas = String(formData.get("notas") ?? "");
  const retorno = rutaInternaSegura(formData.get("retorno"), "/importaciones");

  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_resolver_revision", {
    p_id_import_review_item: id,
    p_resolution_status: estado,
    p_resolution_notes: notas || null,
  });

  revalidatePath("/importaciones");

  if (error) {
    redirect(agregarParametroARutaInterna(retorno, "error", error.message, "/importaciones"));
  }
  redirect(agregarParametroARutaInterna(retorno, "ok", "revision", "/importaciones"));
}
