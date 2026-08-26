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

// Etapa C (Cliente 360, docs/plan_ia.md) — Fase 7.

export async function registrarInteraccion(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const tipoInteraccion = String(formData.get("tipo_interaccion") ?? "");
  const direccion = String(formData.get("direccion") ?? "OUTBOUND");
  const motivo = String(formData.get("motivo") ?? "SEGUIMIENTO");
  const asunto = String(formData.get("asunto") ?? "").trim();
  const resumen = String(formData.get("resumen") ?? "").trim();

  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_registrar_interaccion", {
    p_id_organizacion: id,
    p_tipo_interaccion: tipoInteraccion,
    p_direccion: direccion,
    p_motivo: motivo,
    p_asunto: asunto || null,
    p_resumen: resumen || null,
  });

  revalidatePath(`/organizaciones/${id}`);
  if (error) redirect(`/organizaciones/${id}?tab=timeline&error=${encodeURIComponent(error.message)}`);
  redirect(`/organizaciones/${id}?tab=timeline&ok=interaccion`);
}

export async function programarSeguimiento(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const idCotizacion = String(formData.get("id_cotizacion") ?? "");
  const fechaProgramada = String(formData.get("fecha_programada") ?? "");
  const notas = String(formData.get("notas") ?? "").trim();

  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_programar_seguimiento", {
    p_id_cotizacion: idCotizacion,
    p_fecha_programada: fechaProgramada,
    p_notas: notas || null,
  });

  revalidatePath(`/organizaciones/${id}`);
  if (error) redirect(`/organizaciones/${id}?tab=cotizaciones&error=${encodeURIComponent(error.message)}`);
  redirect(`/organizaciones/${id}?tab=cotizaciones&ok=seguimiento`);
}

export async function completarSeguimiento(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const idFollowup = String(formData.get("id_cotizacion_followup") ?? "");
  const cancelado = formData.get("cancelado") === "true";
  const notas = String(formData.get("notas") ?? "").trim();

  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_completar_seguimiento", {
    p_id_cotizacion_followup: idFollowup,
    p_notas: notas || null,
    p_cancelado: cancelado,
  });

  revalidatePath(`/organizaciones/${id}`);
  if (error) redirect(`/organizaciones/${id}?tab=cotizaciones&error=${encodeURIComponent(error.message)}`);
  redirect(`/organizaciones/${id}?tab=cotizaciones&ok=seguimiento`);
}

export async function actualizarPreferenciaCliente(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const canalPreferido = String(formData.get("canal_preferido") ?? "").trim();
  const horarioPreferido = String(formData.get("horario_preferido") ?? "").trim();
  const frecuencia = String(formData.get("frecuencia_contacto_preferida") ?? "").trim();
  const sensibilidadPrecio = String(formData.get("sensibilidad_precio") ?? "MEDIA");
  const notasComerciales = String(formData.get("notas_comerciales") ?? "").trim();

  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_actualizar_preferencia_cliente", {
    p_id_organizacion: id,
    p_canal_preferido: canalPreferido || null,
    p_horario_preferido: horarioPreferido || null,
    p_frecuencia_contacto_preferida: frecuencia || null,
    p_sensibilidad_precio: sensibilidadPrecio || null,
    p_notas_comerciales: notasComerciales || null,
  });

  revalidatePath(`/organizaciones/${id}`);
  if (error) redirect(`/organizaciones/${id}?tab=preferencias&error=${encodeURIComponent(error.message)}`);
  redirect(`/organizaciones/${id}?tab=preferencias&ok=preferencia`);
}

export async function aprobarAccionIA(formData: FormData) {
  const id = String(formData.get("id") ?? "");
  const idPropuesta = String(formData.get("id_ia_accion_propuesta") ?? "");
  const aprobar = formData.get("aprobar") === "true";
  const notas = String(formData.get("notas") ?? "").trim();

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase
    .rpc("fn_consola_aprobar_accion_ia", {
      p_id_ia_accion_propuesta: idPropuesta,
      p_aprobar: aprobar,
      p_notas: notas || null,
    })
    .single();

  revalidatePath(`/organizaciones/${id}`);
  if (error) redirect(`/organizaciones/${id}?tab=ia&error=${encodeURIComponent(error.message)}`);

  // La propuesta puede haber expirado justo al intentar resolverla: la
  // funcion ya no lanza excepcion en ese caso (048), solo devuelve
  // estado='EXPIRADA'. Sin este chequeo se reportaria "aprobada" o
  // "rechazada" aunque en realidad no se aplico nada.
  const estado = (data as { estado?: string } | null)?.estado;
  if (estado === "EXPIRADA") {
    redirect(`/organizaciones/${id}?tab=ia&error=${encodeURIComponent("La propuesta expiró antes de poder resolverse.")}`);
  }
  redirect(`/organizaciones/${id}?tab=ia&ok=${aprobar ? "aprobada" : "rechazada"}`);
}
