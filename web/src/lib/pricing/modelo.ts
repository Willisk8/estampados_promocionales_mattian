/**
 * Puerto fiel de scripts/catalog/pricing_model.py a TypeScript.
 *
 * Por que existe: el simulador administrativo de la consola necesita correr
 * en el servidor de Next.js, no invocar un script de Python aparte. La logica
 * es la misma; solo cambia el lenguaje. Cada funcion documenta de que linea
 * del original viene, y scripts/catalog/validar_puerto_ts.py compara ambas
 * implementaciones sobre los 5 productos reales del catalogo — no es un
 * ejercicio teorico, es la prueba de que este archivo calcula lo mismo.
 *
 * No escribe en Supabase. Sirve solo para simular escenarios.
 */

import type {
  ConfiguracionCosteo,
  ConfigMarcacion,
  InsumoCosto,
  OpcionCompraPliego,
  ResultadoPrecio,
} from "./tipos";

const ALTURA_MAXIMA_PLIEGO_CM = 100_000;

/** Redondeo para mostrar en pantalla. Python usa round() (banker's rounding). */
export function dinero(valor: number): number {
  const piso = Math.floor(valor);
  const resto = valor - piso;
  if (Math.abs(resto - 0.5) > 1e-9) return Math.round(valor);
  // Empate exacto en .5: redondea al par, igual que Python.
  return piso % 2 === 0 ? piso : piso + 1;
}

/**
 * Primer elemento con el valor maximo/minimo de `clave`, no el ultimo.
 * Python min()/max() conservan el primer elemento visto en caso de empate;
 * Math.max/Array.reduce con `>=` no lo harian, asi que se replica a mano.
 */
function porClaveMax<T>(items: T[], clave: (item: T) => number): T {
  let mejor = items[0];
  let mejorValor = clave(mejor);
  for (let i = 1; i < items.length; i++) {
    const valor = clave(items[i]);
    if (valor > mejorValor) {
      mejor = items[i];
      mejorValor = valor;
    }
  }
  return mejor;
}

function porClaveMin<T>(items: T[], clave: (item: T) => number): T {
  let mejor = items[0];
  let mejorValor = clave(mejor);
  for (let i = 1; i < items.length; i++) {
    const valor = clave(items[i]);
    if (valor < mejorValor) {
      mejor = items[i];
      mejorValor = valor;
    }
  }
  return mejor;
}

/** pricing_model.py: tiered_unit_cost() */
export function costoUnitarioEscalonado(item: InsumoCosto, cantidad: number): number {
  const niveles = item.tiers;
  if (!niveles || niveles.length === 0) {
    return Number(item.value_unit ?? 0);
  }

  const validos = niveles.filter((t) => (t.from_qty ?? 1) <= cantidad);
  const candidatos = validos.length > 0 ? validos : [porClaveMin(niveles, (t) => t.from_qty ?? 1)];
  const nivel = porClaveMax(candidatos, (t) => t.from_qty ?? 1);

  if (nivel.value_unit !== undefined) return Number(nivel.value_unit);
  if (nivel.pack_price !== undefined && nivel.pack_qty !== undefined) {
    return Number(nivel.pack_price) / Math.max(Number(nivel.pack_qty), 1);
  }
  throw new Error(`Nivel de costo invalido para ${item.name ?? "insumo sin nombre"}`);
}

/** pricing_model.py: electricity_cost_unit() */
export function costoElectricidadUnidad(
  watts: number,
  segundos: number,
  pasadas: number,
  precioKwh: number,
): number {
  return (watts / 1000) * ((segundos * pasadas) / 3600) * precioKwh;
}

/**
 * pricing_model.py: least_cost_sheet_purchase()
 * Programacion dinamica (coin-change no acotado): costo minimo para cubrir
 * al menos `alturaRequeridaCm` combinando los formatos de `opciones`.
 */
export function compraOptimaPliegos(
  alturaRequeridaCm: number,
  opciones: OpcionCompraPliego[],
): number {
  if (alturaRequeridaCm <= 0) return 0;
  if (!opciones || opciones.length === 0) return 0;

  const normalizadas = opciones
    .filter((o) => Number(o.height_cm ?? 0) > 0)
    .map((o) => ({ altura: Math.round(Number(o.height_cm)), precio: Number(o.price) }));
  if (normalizadas.length === 0) return 0;

  const objetivo = Math.round(alturaRequeridaCm + 0.499999);
  if (objetivo > ALTURA_MAXIMA_PLIEGO_CM) {
    throw new Error(
      `required_height_cm=${objetivo} supera el limite operativo de ` +
        `${ALTURA_MAXIMA_PLIEGO_CM} cm para la optimizacion exacta`,
    );
  }

  const alturaMaxima = Math.max(...normalizadas.map((o) => o.altura));
  const limite = objetivo + alturaMaxima;
  const INF = Infinity;
  const dp = new Array<number>(limite + 1).fill(INF);
  dp[0] = 0;

  for (let actual = 0; actual <= limite; actual++) {
    if (dp[actual] === INF) continue;
    for (const { altura, precio } of normalizadas) {
      const siguiente = Math.min(limite, actual + altura);
      if (dp[actual] + precio < dp[siguiente]) {
        dp[siguiente] = dp[actual] + precio;
      }
    }
  }

  let minimo = INF;
  for (let i = objetivo; i <= limite; i++) {
    if (dp[i] < minimo) minimo = dp[i];
  }
  return minimo;
}

/** pricing_model.py: marking_cost_unit() */
export function costoMarcacionUnidad(config: ConfigMarcacion, cantidad: number): number {
  const modo = config.mode;

  if (!modo || modo === "none") return 0;

  if (modo === "bordado") {
    const fijo = Number(config.fixed_program_cost ?? 0);
    const extra = Number(config.extra_cost_unit ?? 0);
    return fijo / cantidad + extra;
  }

  if (modo === "dtf") {
    const anchoRolloCm = Number(config.roll_width_cm ?? 58);
    const desperdicioPct = Number(config.waste_pct ?? 0);
    const disenos = config.designs ?? [];

    const areaTotalCm2 = disenos.reduce(
      (acc, d) => acc + Number(d.width_cm ?? 0) * Number(d.height_cm ?? 0) * Number(d.units_per_product ?? 1),
      0,
    );
    const alturaTotalCm = ((areaTotalCm2 * cantidad) / anchoRolloCm) * (1 + desperdicioPct / 100);

    let costo: number;
    if (config.purchase_options && config.purchase_options.length > 0) {
      costo = compraOptimaPliegos(alturaTotalCm, config.purchase_options) / cantidad;
    } else {
      const precioPorMetro = Number(config.price_per_meter ?? 0);
      const metrosUnidad = (areaTotalCm2 / anchoRolloCm / 100) * (1 + desperdicioPct / 100);
      costo = metrosUnidad * precioPorMetro;
    }

    const plancha = config.iron;
    if (plancha && plancha.include) {
      costo += costoElectricidadUnidad(
        Number(plancha.watts ?? 0),
        Number(plancha.seconds ?? 0),
        Number(plancha.passes ?? 1),
        Number(plancha.kwh_price ?? 0),
      );
    }
    return costo;
  }

  if (modo === "sublimacion_mug") {
    const paqueteHojas = Number(config.paper_package_100_sheets ?? 0);
    const imagenesPorHoja = Number(config.images_per_sheet ?? 1);
    const juegoTinta = Number(config.ink_set_cost ?? 0);
    const rendimientoTintaHojas = Number(config.ink_yield_sheets ?? 1);
    const papel = paqueteHojas / 100 / imagenesPorHoja;
    const tinta = juegoTinta / rendimientoTintaHojas / imagenesPorHoja;
    const elec = costoElectricidadUnidad(
      Number(config.watts ?? 0),
      Number(config.seconds ?? 0),
      Number(config.passes ?? 1),
      Number(config.kwh_price ?? 0),
    );
    return papel + tinta + elec;
  }

  if (modo === "dtf_uv") {
    const precioPorMetro = Number(config.price_per_meter ?? 0);
    const anchoRolloCm = Number(config.roll_width_cm ?? 58);
    const anchoCm = Number(config.width_cm ?? 0);
    const altoCm = Number(config.height_cm ?? 0);
    const desperdicioPct = Number(config.waste_pct ?? 0);
    const transporteTotal = Number(config.transport_total ?? 0);
    const alturaTotalCm = ((anchoCm * altoCm * cantidad) / anchoRolloCm) * (1 + desperdicioPct / 100);

    if (config.purchase_options && config.purchase_options.length > 0) {
      return (
        compraOptimaPliegos(alturaTotalCm, config.purchase_options) / cantidad +
        transporteTotal / cantidad
      );
    }
    const metrosUnidad = (anchoCm * altoCm) / anchoRolloCm / 100 * (1 + desperdicioPct / 100);
    return metrosUnidad * precioPorMetro + transporteTotal / cantidad;
  }

  throw new Error(`Modo de marcacion no soportado: ${modo}`);
}

/**
 * pricing_model.py: shipping_cost_unit()
 * Se conserva para paridad con el original aunque calculate_price no la
 * invoca: los costos con billing="separate" se cobran aparte, nunca entran
 * al precio unitario.
 */
export function costoEnvioUnidad(config: ConfiguracionCosteo, cantidad: number): number {
  const total = (config.order_costs ?? [])
    .filter((c) => c.billing === "separate")
    .reduce((acc, c) => acc + Number(c.value_total ?? 0), 0);
  return total / cantidad;
}

/** pricing_model.py: calculate_price() */
export function calcularPrecio(config: ConfiguracionCosteo, cantidad: number): ResultadoPrecio {
  const costoProductos = (config.product_costs ?? []).reduce(
    (acc, c) => acc + costoUnitarioEscalonado(c, cantidad),
    0,
  );

  const costosPedidoUnidad =
    (config.order_costs ?? [])
      .filter((c) => c.billing !== "separate")
      .reduce((acc, c) => acc + Number(c.value_total ?? 0), 0) / cantidad;

  const politicaDesgaste = config.machine_wear_policy ?? {};
  const amortMinima = Number(politicaDesgaste.min_amortization_qty ?? 1);
  const cantidadEfectiva = Math.max(cantidad, amortMinima);
  const costoMaquinasUnidad =
    (config.machines ?? []).reduce(
      (acc, m) => acc + Number(m.replacement_value ?? 0) / Math.max(Number(m.estimated_uses ?? 1), 1),
      0,
    ) / cantidadEfectiva;

  const marcacion = costoMarcacionUnidad(config.marking ?? {}, cantidad);

  const costoTotal = costoProductos + marcacion + costosPedidoUnidad + costoMaquinasUnidad;

  const retenciones = config.withholdings ?? {};
  const pctRetencion =
    Number(retenciones.reteica_pct ?? 0) +
    Number(retenciones.retefuente_pct ?? 0) +
    Number(retenciones.reteiva_pct ?? 0) +
    Number(retenciones.other_pct ?? 0);
  const factorRetencion = 1 - pctRetencion / 100;

  const comercial = config.commercial_policy ?? {};
  const objetivo = Number(comercial.target_pct ?? 40);
  const modo = comercial.mode ?? "margen";

  let precioVenta: number;
  if (modo === "margen") {
    const factorMargen = 1 - objetivo / 100;
    precioVenta = costoTotal / (factorRetencion * factorMargen);
  } else if (modo === "markup") {
    precioVenta = (costoTotal * (1 + objetivo / 100)) / factorRetencion;
  } else {
    throw new Error(`Modo de politica comercial no soportado: ${modo}`);
  }

  const recibido = precioVenta * factorRetencion;
  const ganancia = recibido - costoTotal;
  const margenReal = recibido ? (ganancia / recibido) * 100 : 0;
  const markupReal = costoTotal ? (ganancia / costoTotal) * 100 : 0;

  return {
    quantity: cantidad,
    total_cost_unit: costoTotal,
    sale_price_unit: precioVenta,
    received_unit: recibido,
    profit_unit: ganancia,
    real_margin_pct: margenReal,
    real_markup_pct: markupReal,
  };
}
