"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { crearClienteServidor } from "@/lib/supabase/servidor";

export async function actualizarEstadoComercial(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const estado = String(formData.get("estado_comercial") ?? "PROSPECTO");
  const prioridad = String(formData.get("prioridad") ?? "MEDIA");
  const notas = String(formData.get("notas") ?? "");

  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_actualizar_estado_comercial", {
    p_id_organizacion: id,
    p_estado_comercial: estado,
    p_prioridad: prioridad,
    p_notas: notas || null,
  });

  revalidatePath(`/organizaciones/${id}`);
  revalidatePath("/organizaciones");
  if (error) redirect(`/organizaciones/${id}?error=${encodeURIComponent(error.message)}`);
  redirect(`/organizaciones/${id}?ok=comercial`);
}

export async function clasificarTipoOrganizacion(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const tipo = String(formData.get("tipo_codigo") ?? "");
  const criterio = String(formData.get("criterio") ?? "MANUAL");

  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_clasificar_tipo_organizacion", {
    p_id_organizacion: id,
    p_tipo_codigo: tipo,
    p_criterio: criterio || "MANUAL",
  });

  revalidatePath(`/organizaciones/${id}`);
  revalidatePath("/organizaciones");
  if (error) redirect(`/organizaciones/${id}?error=${encodeURIComponent(error.message)}`);
  redirect(`/organizaciones/${id}?ok=tipo`);
}
