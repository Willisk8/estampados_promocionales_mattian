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

const conservarEstadoProveedor = (formData: FormData, params: URLSearchParams) => {
  for (const campo of [
    "id_organizacion",
    "id_proveedor",
    "q_producto",
    "id_producto_proveedor",
    "id_precio_proveedor_snapshot",
    "cantidad",
    "id_snapshot_tecnica",
    "marcacion_descripcion",
    "marcacion_ancho_cm",
    "marcacion_alto_cm",
    "marcacion_merma_pct",
    "numero_preparaciones",
    "costo_preparacion",
    "transporte_total",
    "transport_mode",
    "margen_override_pct",
    "notas",
  ]) {
    const valor = leerTexto(formData, campo);
    if (valor) params.set(campo, valor);
  }
};

const construirLineasMarcacion = (formData: FormData) => {
  const idSnapshot = leerTexto(formData, "id_snapshot_tecnica");
  if (!idSnapshot) return [];

  const linea: Record<string, string | number> = {
    id_snapshot: idSnapshot,
  };

  const descripcion = leerTexto(formData, "marcacion_descripcion");
  const ancho = leerNumero(formData, "marcacion_ancho_cm");
  const alto = leerNumero(formData, "marcacion_alto_cm");
  const merma = leerNumero(formData, "marcacion_merma_pct");
  const preparaciones = leerNumero(formData, "numero_preparaciones");
  const costoPreparacion = leerNumero(formData, "costo_preparacion");

  if (descripcion) linea.descripcion = descripcion;
  if (ancho !== null) linea.ancho_cm = ancho;
  if (alto !== null) linea.alto_cm = alto;
  if (merma !== null) linea.merma_pct = merma;
  if (preparaciones !== null) linea.numero_preparaciones = preparaciones;
  if (costoPreparacion !== null) linea.costo_preparacion = costoPreparacion;

  return [linea];
};

export async function prepararCotizacionProveedor(formData: FormData) {
  const params = new URLSearchParams();
  conservarEstadoProveedor(formData, params);
  redirect(`/cotizador?modo=proveedor&${params.toString()}`);
}

export async function previsualizarCotizacionProveedor(formData: FormData) {
  const params = new URLSearchParams();
  conservarEstadoProveedor(formData, params);
  params.set("modo", "proveedor");
  params.set("previsualizar_proveedor", "1");
  redirect(`/cotizador?${params.toString()}`);
}

export async function crearCotizacionProveedor(formData: FormData) {
  const idOrganizacion = leerTexto(formData, "id_organizacion");
  const idPrecioProveedorSnapshot = leerTexto(formData, "id_precio_proveedor_snapshot");
  const cantidad = leerNumero(formData, "cantidad") ?? 0;
  const transporteTotal = leerNumero(formData, "transporte_total") ?? 0;
  const transportMode = leerTexto(formData, "transport_mode") ?? "SEPARATE_LINE";
  const margenOverride = leerNumero(formData, "margen_override_pct");
  const notas = leerTexto(formData, "notas");
  const idempotencyKey = leerTexto(formData, "idempotency_key");
  const markingLines = construirLineasMarcacion(formData);

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_crear_cotizacion_proveedor", {
    p_id_organizacion: idOrganizacion,
    p_id_precio_proveedor_snapshot: idPrecioProveedorSnapshot,
    p_cantidad: cantidad,
    p_marking_lines: markingLines,
    p_transporte_total: transporteTotal,
    p_transport_mode: transportMode,
    p_policy_code: "MVP_DEFAULT",
    p_margen_override_pct: margenOverride,
    p_notas: notas,
    p_idempotency_key: idempotencyKey,
  });

  revalidatePath("/cotizador");

  if (error) redirect(`/cotizador?modo=proveedor&error=${encodeURIComponent(error.message)}`);

  const resultado = data?.[0] as
    | { id_cotizacion: string | null; numero: number | null; total: number | string | null; status: string }
    | undefined;

  if (!resultado || resultado.status !== "OK" || !resultado.id_cotizacion) {
    redirect(`/cotizador?modo=proveedor&status=${encodeURIComponent(resultado?.status ?? "ERROR")}`);
  }

  redirect(`/cotizador/${resultado.id_cotizacion}`);
}

export async function crearProductoProveedorManual(formData: FormData) {
  const params = new URLSearchParams();
  conservarEstadoProveedor(formData, params);
  params.set("modo", "proveedor");

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_crear_producto_proveedor_manual", {
    p_id_proveedor: leerTexto(formData, "id_proveedor"),
    p_nombre_proveedor: leerTexto(formData, "manual_nombre_proveedor"),
    p_nombre_producto: leerTexto(formData, "manual_nombre_producto"),
    p_sku_proveedor: leerTexto(formData, "manual_sku_proveedor"),
    p_categoria: leerTexto(formData, "manual_categoria"),
    p_precio: leerNumero(formData, "manual_precio"),
    p_moneda: leerTexto(formData, "manual_moneda") ?? "COP",
    p_unidad_compra: leerTexto(formData, "manual_unidad_compra") ?? "UNIT",
    p_cantidad_pack: leerNumero(formData, "manual_cantidad_pack"),
    p_minimo_compra: leerNumero(formData, "manual_minimo_compra"),
    p_incremento_compra: leerNumero(formData, "manual_incremento_compra"),
    p_url_fuente: leerTexto(formData, "manual_url_fuente"),
    p_notas: leerTexto(formData, "manual_notas"),
  });

  revalidatePath("/cotizador");
  revalidatePath("/proveedores");

  const resultado = data?.[0] as
    | {
        id_proveedor: string | null;
        id_producto_proveedor: string | null;
        id_precio_proveedor_snapshot: string | null;
        status: string;
      }
    | undefined;

  if (error) {
    params.set("error", error.message);
  } else if (!resultado || resultado.status !== "OK") {
    params.set("status", resultado?.status ?? "ERROR");
  } else {
    params.set("ok", "producto_manual");
    if (resultado.id_proveedor) params.set("id_proveedor", resultado.id_proveedor);
    if (resultado.id_producto_proveedor) {
      params.set("id_producto_proveedor", resultado.id_producto_proveedor);
    }
    if (resultado.id_precio_proveedor_snapshot) {
      params.set("id_precio_proveedor_snapshot", resultado.id_precio_proveedor_snapshot);
    }
  }

  redirect(`/cotizador?${params.toString()}`);
}

export async function crearSnapshotTecnicaManual(formData: FormData) {
  const params = new URLSearchParams();
  conservarEstadoProveedor(formData, params);
  params.set("modo", "proveedor");

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_crear_snapshot_tecnica_manual", {
    p_id_proveedor_tecnica: leerTexto(formData, "manual_id_proveedor_tecnica"),
    p_nombre_proveedor_tecnica: leerTexto(formData, "manual_nombre_proveedor_tecnica"),
    p_codigo_tecnica: leerTexto(formData, "manual_codigo_tecnica"),
    p_precio: leerNumero(formData, "manual_precio_tecnica"),
    p_moneda: leerTexto(formData, "manual_moneda_tecnica") ?? "COP",
    p_billing_unit: leerTexto(formData, "manual_billing_unit") ?? "unidad",
    p_width_cm: leerNumero(formData, "manual_width_cm"),
    p_height_cm: leerNumero(formData, "manual_height_cm"),
    p_quantity_min: leerNumero(formData, "manual_quantity_min"),
    p_quantity_max: leerNumero(formData, "manual_quantity_max"),
    p_size_label: leerTexto(formData, "manual_size_label"),
    p_source_url: leerTexto(formData, "manual_source_url"),
    p_notas: leerTexto(formData, "manual_notas_tecnica"),
  });

  revalidatePath("/cotizador");
  revalidatePath("/tecnicas");

  const resultado = data?.[0] as
    | {
        id_tecnica: string | null;
        id_proveedor_tecnica: string | null;
        id_snapshot: string | null;
        status: string;
      }
    | undefined;

  if (error) {
    params.set("error", error.message);
  } else if (!resultado || resultado.status !== "OK") {
    params.set("status", resultado?.status ?? "ERROR");
  } else {
    params.set("ok", "tecnica_manual");
    if (resultado.id_snapshot) params.set("id_snapshot_tecnica", resultado.id_snapshot);
  }

  redirect(`/cotizador?${params.toString()}`);
}
