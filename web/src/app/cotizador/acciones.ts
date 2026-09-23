"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { crearClienteServidor } from "@/lib/supabase/servidor";

const leerTexto = (formData: FormData, campo: string) => {
  const valor = String(formData.get(campo) ?? "").trim();
  return valor || null;
};

/**
 * Traduccion de los status de fn_consola_crear_cotizacion_proveedor_multilinea
 * a algo accionable. Se mantiene el status crudo como respaldo cuando aparezca
 * uno nuevo: es preferible mostrar el codigo que tragarse el error.
 */
const MENSAJES_MULTILINEA: Record<string, string> = {
  PREVIEW_CHANGED: "El precio cambio desde la validacion. Valida otra vez antes de emitir.",
  INVALID_PRICING_INPUT: "Revisa costos, margenes y porcentajes: hay valores invalidos.",
  INVALID_MARGIN: "El margen debe ser mayor o igual a 0 y menor que 100%.",
  PRICING_OVERRIDE_FORBIDDEN: "Solo ADMIN puede modificar costos y porcentajes.",
  FORBIDDEN: "Tu rol no puede emitir cotizaciones.",
  MARGIN_OVERRIDE_FORBIDDEN: "Solo un ADMIN puede fijar el margen a mano.",
  NO_LINES: "La cotizacion no tiene ninguna linea de producto.",
  INVALID_LINES: "El formato de las lineas es invalido.",
  TOO_MANY_LINES: "Demasiadas lineas en una sola cotizacion (maximo 50).",
  INVALID_LINE: "Una de las lineas llego con formato invalido.",
  INVALID_LINE_SNAPSHOT: "Una linea no tiene una observacion de precio valida.",
  INVALID_QUANTITY:
    "Hay una linea con cantidad invalida: debe ser un entero mayor a cero.",
  PURCHASE_UNIT_UNVERIFIED: "La oferta no declara su unidad de compra. Verifica si el precio corresponde a unidad, paquete u otra presentacion y registra una nueva observacion; conserva el historico.",
  INVALID_PACK_QUANTITY:
    "Un producto empacado no tiene registradas cuantas unidades trae el paquete.",
  INVALID_MARKING_LINES: "El formato de la marcacion de una linea es invalido.",
  INVALID_EXTRA_COSTS: "Hay un costo adicional con valor invalido.",
  INVALID_TRANSPORT_MODE: "Modo de transporte invalido.",
  INVALID_TRANSPORT_TOTAL: "El transporte del pedido no puede ser negativo.",
  LINE_PRODUCT_MISMATCH:
    "Una linea trae un producto que no corresponde a su observacion de precio.",
  ORGANIZATION_NOT_FOUND: "El cliente seleccionado ya no existe.",
  SUPPLIER_PRICE_NOT_FOUND:
    "Una linea usa un precio de proveedor que no esta vigente o fue retirado.",
  MARKING_COST_NOT_FOUND: "Una tecnica de marcacion no esta disponible para cotizar.",
  MARGIN_POLICY_NOT_FOUND: "No hay politica de margen vigente.",
  MARGIN_TEMPLATE_NOT_FOUND: "La plantilla de margen ya no esta publicada. Elige una plantilla vigente y valida otra vez.",
  MARGIN_BELOW_MINIMUM: "El margen queda por debajo del minimo permitido.",
  TECHNICAL_CONFIGURATION_REQUIRED: "La configuracion tecnica esta incompleta o requiere un costo manual documentado.",
  INVALID_TECHNICAL_INPUT: "Revisa medidas, reserva, tarifa y unidades de la tecnica.",
  DESIGN_DOES_NOT_FIT: "El diseño no cabe en el ancho util del rollo, incluso al girarlo.",
  INVALID_SURPLUS_ALLOCATION: "El valor reasignado excede el sobrante o necesita autorizacion y motivo de ADMIN.",
  NO_COMPONENTS: "El calculo no produjo componentes.",
  CONFLICT:
    "Ya existe una cotizacion emitida con esta misma clave pero con otros datos. Cambia algo o recarga la pagina.",
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

/**
 * Emite una cotizacion proveedor-first de VARIAS lineas desde la calculadora.
 *
 * A diferencia del resto de acciones de este archivo no recibe FormData ni
 * redirige: la llama un componente de cliente y le devuelve el resultado, para
 * que la calculadora pueda mostrar el motivo exacto cuando la base rechaza
 * (falta de cliente, snapshot vencido, margen no permitido) en vez de tirar la
 * pantalla abajo. La navegacion la hace el cliente con el id devuelto.
 *
 * Toda la validacion economica vive en la base
 * (fn_consola_emitir_cotizacion_cliente, migraciones 085-086): aca solo
 * se exige la confirmacion de la interfaz y se traduce el status. El rol, el margen manual y la vigencia de
 * los snapshots NO se confian al frontend.
 */
export async function emitirCotizacionMultilinea(carga: {
  id_organizacion: string;
  lineas: Array<{
    id_precio_proveedor_snapshot: string;
    id_producto_proveedor?: string;
    unidades_entregar: number;
    id_plantilla_margen?: string | null;
    reasignacion_sobrante?: number;
    motivo_ajuste?: string | null;
    configuracion_tecnica?: unknown;
    costo_unitario_override?: number;
    margen_linea_pct?: number;
    retencion_pct?: number;
    marking_lines?: unknown[];
    costos_adicionales?: Array<{
      descripcion: string;
      costo_unitario?: number;
      costo_total?: number;
    }>;
  }>;
  margen_override_pct: number | null;
  id_plantilla_margen?: string | null;
  margen_confirmado?: boolean;
  notas: string | null;
  idempotency_key: string;
  total_esperado: number;
}): Promise<
  | { ok: true; id_cotizacion: string; numero: number | null; total: number | null }
  | { ok: false; mensaje: string }
> {
  if (!carga.id_organizacion) {
    return { ok: false, mensaje: "Falta elegir el cliente (organizacion) de la cotizacion." };
  }
  if (!Array.isArray(carga.lineas) || carga.lineas.length === 0) {
    return { ok: false, mensaje: "La cotizacion no tiene ninguna linea de producto." };
  }
  if (!carga.margen_confirmado) {
    return { ok: false, mensaje: "Confirma el margen de este cliente antes de emitir." };
  }

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc(
    "fn_consola_emitir_cotizacion_cliente",
    {
      p_id_organizacion: carga.id_organizacion,
      p_lineas: carga.lineas,
      p_total_esperado: carga.total_esperado,
      p_margen_override_pct: carga.margen_override_pct,
      p_notas: carga.notas,
      p_idempotency_key: carga.idempotency_key,
    },
  );

  if (error) return { ok: false, mensaje: error.message };

  const resultado = data?.[0] as
    | {
        id_cotizacion: string | null;
        numero: number | null;
        total: number | string | null;
        lineas: number | null;
        status: string;
      }
    | undefined;

  if (!resultado) {
    return { ok: false, mensaje: "La base no devolvio resultado para la cotizacion." };
  }

  if (resultado.status !== "OK" || !resultado.id_cotizacion) {
    return { ok: false, mensaje: MENSAJES_MULTILINEA[resultado.status] ?? resultado.status };
  }

  revalidatePath("/cotizador");

  return {
    ok: true,
    id_cotizacion: resultado.id_cotizacion,
    numero: resultado.numero,
    total: resultado.total === null ? null : Number(resultado.total),
  };
}

export async function crearProductoProveedorManual(formData: FormData) {
  const params = new URLSearchParams();
  conservarEstadoProveedor(formData, params);
  params.set("modo", "proveedor");

  // Validacion server-side: el HTML5 required de estos campos se retiro porque
  // viven en <details> ocultos y bloqueaban submits de otros pasos.
  const nombreProducto = leerTexto(formData, "manual_nombre_producto");
  const precioManual = leerNumero(formData, "manual_precio");
  if (!nombreProducto || precioManual === null) {
    params.set("error", "Producto manual incompleto: se requieren nombre del producto y precio.");
    redirect(`/cotizador?${params.toString()}`);
  }

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_crear_producto_proveedor_manual", {
    p_id_proveedor: leerTexto(formData, "id_proveedor"),
    p_nombre_proveedor: leerTexto(formData, "manual_nombre_proveedor"),
    p_nombre_producto: nombreProducto,
    p_sku_proveedor: leerTexto(formData, "manual_sku_proveedor"),
    p_categoria: leerTexto(formData, "manual_categoria"),
    p_precio: precioManual,
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

  // Validacion server-side (mismo motivo que producto manual).
  const nombreProveedorTecnica = leerTexto(formData, "manual_nombre_proveedor_tecnica");
  const codigoTecnica = leerTexto(formData, "manual_codigo_tecnica");
  const precioTecnica = leerNumero(formData, "manual_precio_tecnica");
  if (!nombreProveedorTecnica || !codigoTecnica || precioTecnica === null) {
    params.set("error", "Tecnica manual incompleta: se requieren proveedor de tecnica, codigo y precio.");
    redirect(`/cotizador?${params.toString()}`);
  }

  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_crear_snapshot_tecnica_manual", {
    p_id_proveedor_tecnica: leerTexto(formData, "manual_id_proveedor_tecnica"),
    p_nombre_proveedor_tecnica: nombreProveedorTecnica,
    p_codigo_tecnica: codigoTecnica,
    p_precio: precioTecnica,
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

export async function previsualizarCotizacionMultilinea(carga: Omit<Parameters<typeof emitirCotizacionMultilinea>[0], "idempotency_key" | "total_esperado">) {
  if (!carga.margen_confirmado) return { ok: false as const, mensaje: "Confirma el margen de este cliente antes de validar." };
  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_previsualizar_cotizacion_cliente", {
    p_id_organizacion: carga.id_organizacion, p_lineas: carga.lineas, p_margen_override_pct: carga.margen_override_pct,
  });
  if (error) return { ok: false as const, mensaje: "No se pudo validar la cotizacion: " + error.message };
  if (!data || data.status !== "OK") return { ok: false as const, mensaje: MENSAJES_MULTILINEA[data?.status] ?? data?.status ?? "Sin respuesta del calculo." };
  return { ok: true as const, total: Number(data.total), lineas: data.lineas as Array<{linea:number;total:number;unidades:number;precio_unitario:number;costo_total:number|null}> };
}
