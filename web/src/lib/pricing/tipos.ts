/**
 * Tipos de la configuracion de costeo. Reflejan el JSON que consume
 * scripts/catalog/pricing_model.py — los nombres de campo estan en ingles a
 * proposito, porque son el formato de archivo real (mvp_catalog_inputs.json),
 * no una eleccion de este puerto.
 */

export interface NivelCosto {
  from_qty?: number;
  value_unit?: number;
  pack_price?: number;
  pack_qty?: number;
  source_note?: string;
}

export interface InsumoCosto {
  name?: string;
  supplier?: string;
  value_unit?: number;
  tiers?: NivelCosto[];
}

export interface CostoPedido {
  name?: string;
  value_total: number;
  billing?: "separate" | string;
}

export interface Maquina {
  name?: string;
  replacement_value: number;
  estimated_uses: number;
}

export interface PoliticaDesgasteMaquina {
  min_amortization_qty?: number;
}

export interface DisenoDtf {
  width_cm: number;
  height_cm: number;
  units_per_product?: number;
}

export interface OpcionCompraPliego {
  height_cm: number;
  price: number;
}

export interface ConfigPlancha {
  include?: boolean;
  watts?: number;
  seconds?: number;
  passes?: number;
  kwh_price?: number;
}

export type ConfigMarcacion =
  | { mode?: undefined | "none" }
  | {
      mode: "bordado";
      fixed_program_cost?: number;
      extra_cost_unit?: number;
    }
  | {
      mode: "dtf";
      roll_width_cm?: number;
      waste_pct?: number;
      designs?: DisenoDtf[];
      purchase_options?: OpcionCompraPliego[];
      price_per_meter?: number;
      iron?: ConfigPlancha;
    }
  | {
      mode: "sublimacion_mug";
      paper_package_100_sheets?: number;
      images_per_sheet?: number;
      ink_set_cost?: number;
      ink_yield_sheets?: number;
      watts?: number;
      seconds?: number;
      passes?: number;
      kwh_price?: number;
    }
  | {
      mode: "dtf_uv";
      price_per_meter?: number;
      roll_width_cm?: number;
      width_cm?: number;
      height_cm?: number;
      waste_pct?: number;
      transport_total?: number;
      purchase_options?: OpcionCompraPliego[];
    };

export interface Retenciones {
  reteica_pct?: number;
  retefuente_pct?: number;
  reteiva_pct?: number;
  other_pct?: number;
}

export interface PoliticaComercial {
  mode?: "margen" | "markup";
  target_pct?: number;
}

export interface ConfiguracionCosteo {
  quantity_breaks?: number[];
  product_costs?: InsumoCosto[];
  order_costs?: CostoPedido[];
  machines?: Maquina[];
  machine_wear_policy?: PoliticaDesgasteMaquina;
  marking?: ConfigMarcacion;
  withholdings?: Retenciones;
  commercial_policy?: PoliticaComercial;
}

export interface ResultadoPrecio {
  quantity: number;
  total_cost_unit: number;
  sale_price_unit: number;
  received_unit: number;
  profit_unit: number;
  real_margin_pct: number;
  real_markup_pct: number;
}
