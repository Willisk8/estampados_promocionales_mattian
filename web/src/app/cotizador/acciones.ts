"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { crearClienteServidor } from "@/lib/supabase/servidor";

const leerTexto = (formData: FormData, campo: string) => {
  const valor = String(formData.get(campo) ?? "").trim();
  return valor || null;
};

const leerNumero = (formData: FormData, campo: string) => {
  const valor = String(formData.get(campo) ?? "").trim();
  if (!valor) return null;
  const numero = Number(valor);
  return Number.isFinite(numero) ? numero : null;
};

export async function prepararCotizacionCalculada(formData: FormData) {
  const params = new URLSearchParams();
  const idProducto = leerTexto(formData, "id_producto");
  const idVariante = leerTexto(formData, "id_variante");
  const cantidad = leerNumero(formData, "cantidad");
  const idOrganizacion = leerTexto(formData, "id_organizacion");
  const numeroPreparaciones = leerNumero(formData, "numero_preparaciones");
  const transporteTotal = leerNumero(formData, "transporte_total");
  const margenOverride = leerNumero(formData, "margen_override_pct");
  const notas = leerTexto(formData, "notas");

  if (idProducto) params.set("id_producto", idProducto);
  if (idVariante) params.set("id_variante", idVariante);
  if (cantidad) params.set("cantidad", String(cantidad));
  if (idOrganizacion) params.set("id_organizacion", idOrganizacion);
  if (numeroPreparaciones !== null) {
    params.set("numero_preparaciones", String(numeroPreparaciones));
  }
  if (transporteTotal !== null) params.set("transporte_total", String(transporteTotal));
  if (margenOverride !== null) params.set("margen_override_pct", String(margenOverride));
  if (notas) params.set("notas", notas);

  redirect(`/cotizador?${params.toString()}`);
}

export async function prepararPrevisualizacion(formData: FormData) {
  const params = new URLSearchParams();
  const idProducto = leerTexto(formData, "id_producto");
  const idVariante = leerTexto(formData, "id_variante");
  const cantidad = leerNumero(formData, "cantidad");
  const idOrganizacion = leerTexto(formData, "id_organizacion");
  const idTecnica = leerTexto(formData, "id_tecnica");
  const numeroPreparaciones = leerNumero(formData, "numero_preparaciones");
  const transporteTotal = leerNumero(formData, "transporte_total");
  const margenOverride = leerNumero(formData, "margen_override_pct");
  const notas = leerTexto(formData, "notas");

  if (idProducto) params.set("id_producto", idProducto);
  if (idVariante) params.set("id_variante", idVariante);
  if (cantidad) params.set("cantidad", String(cantidad));
  if (idOrganizacion) params.set("id_organizacion", idOrganizacion);
  if (idTecnica) params.set("id_tecnica", idTecnica);
  if (numeroPreparaciones !== null) {
    params.set("numero_preparaciones", String(numeroPreparaciones));
  }
  if (transporteTotal !== null) params.set("transporte_total", String(transporteTotal));
  if (margenOverride !== null) params.set("margen_override_pct", String(margenOverride));
  if (notas) params.set("notas", notas);
  params.set("previsualizar", "1");

  redirect(`/cotizador?${params.toString()}`);
}

const conservarEstado = (formData: FormData, params: URLSearchParams) => {
  for (const campo of [
    "id_producto",
    "id_variante",
    "id_organizacion",
    "cantidad",
    "id_tecnica",
    "numero_preparaciones",
    "transporte_total",
    "margen_override_pct",
    "notas",
  ]) {
    const valor = leerTexto(formData, campo);
    if (valor) params.set(campo, valor);
  }
};

export async function altaRapidaProveedor(formData: FormData) {
  const nombre = leerTexto(formData, "nombre_proveedor");
  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_crear_proveedor_rapido", { p_nombre: nombre });
  revalidatePath("/proveedores");

  const params = new URLSearchParams();
  conservarEstado(formData, params);
  if (error) {
    params.set("error", error.message);
  } else {
    params.set("ok", "proveedor");
  }
  redirect(`/cotizador?${params.toString()}`);
}

export async function altaRapidaTecnica(formData: FormData) {
  const codigo = leerTexto(formData, "codigo_tecnica");
  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_crear_tecnica_rapida", { p_codigo: codigo });
  revalidatePath("/tecnicas");

  const params = new URLSearchParams();
  conservarEstado(formData, params);
  if (error) {
    params.set("error", error.message);
  } else {
    params.set("ok", "tecnica");
  }
  redirect(`/cotizador?${params.toString()}`);
}

export async function crearCotizacionCalculada(formData: FormData) {
  const idProducto = leerTexto(formData, "id_producto");
  const idVariante = leerTexto(formData, "id_variante");
  const idOrganizacion = leerTexto(formData, "id_organizacion");
  const cantidad = leerNumero(formData, "cantidad") ?? 0;
  const idTecnica = leerTexto(formData, "id_tecnica");
  const numeroPreparaciones = leerNumero(formData, "numero_preparaciones") ?? 1;
  const transporteTotal = leerNumero(formData, "transporte_total") ?? 0;
  const margenOverride = leerNumero(formData, "margen_override_pct");
  const notas = leerTexto(formData, "notas");
  const idempotencyKey = leerTexto(formData, "idempotency_key");

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_crear_cotizacion_calculada", {
    p_id_producto: idProducto,
    p_cantidad: cantidad,
    p_id_organizacion: idOrganizacion,
    p_id_variante: idVariante,
    p_id_tecnica: idTecnica,
    p_numero_preparaciones: numeroPreparaciones,
    p_transporte_total: transporteTotal,
    p_policy_code: "MVP_DEFAULT",
    p_margen_override_pct: margenOverride,
    p_notas: notas,
    p_idempotency_key: idempotencyKey,
  });

  revalidatePath("/cotizador");

  if (error) redirect(`/cotizador?error=${encodeURIComponent(error.message)}`);

  const resultado = data?.[0] as
    | { id_cotizacion: string | null; numero: number | null; total: number | string | null; status: string }
    | undefined;

  if (!resultado || resultado.status !== "OK" || !resultado.id_cotizacion) {
    redirect(`/cotizador?status=${encodeURIComponent(resultado?.status ?? "ERROR")}`);
  }

  redirect(`/cotizador/${resultado.id_cotizacion}`);
}
