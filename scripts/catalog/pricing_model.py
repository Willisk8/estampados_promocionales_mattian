"""
Modelo de costeo/precio basado en cotizador-v2.html.

No escribe en Supabase. Sirve para transformar costos comerciales reales
en precios unitarios por escala antes de poblar precio_producto.

Uso:
  python scripts/catalog/pricing_model.py scripts/catalog/example_quote_inputs.json
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


def money(value: float) -> int:
    return round(value)


@dataclass
class PriceResult:
    quantity: int
    total_cost_unit: float
    sale_price_unit: float
    received_unit: float
    profit_unit: float
    real_margin_pct: float
    real_markup_pct: float


def tiered_unit_cost(item: dict[str, Any], quantity: int) -> float:
    """Devuelve costo unitario de un insumo según escala/proveedor.

    Formatos soportados:
    - {"value_unit": 15000}
    - {"tiers": [{"from_qty": 1, "value_unit": 13000}, ...]}
    - {"tiers": [{"from_qty": 12, "pack_qty": 36, "pack_price": 129000}, ...]}
    """
    tiers = item.get("tiers")
    if not tiers:
        return float(item.get("value_unit", 0))

    valid_tiers = [
        t for t in tiers
        if int(t.get("from_qty", 1)) <= quantity
    ]
    if not valid_tiers:
        valid_tiers = [min(tiers, key=lambda t: int(t.get("from_qty", 1)))]

    tier = max(valid_tiers, key=lambda t: int(t.get("from_qty", 1)))
    if "value_unit" in tier:
        return float(tier["value_unit"])
    if "pack_price" in tier and "pack_qty" in tier:
        return float(tier["pack_price"]) / max(float(tier["pack_qty"]), 1)
    raise ValueError(f"Invalid cost tier for {item.get('name', 'unnamed item')}: {tier}")


def electricity_cost_unit(watts: float, seconds: float, passes: int, kwh_price: float) -> float:
    return (watts / 1000.0) * ((seconds * passes) / 3600.0) * kwh_price


def least_cost_sheet_purchase(required_height_cm: float, options: list[dict[str, Any]]) -> float:
    """Costo mínimo para cubrir un largo requerido con formatos de proveedor.

    Se asume que todas las opciones comparten el mismo ancho útil de impresión.
    El cálculo permite combinar formatos: por ejemplo 8 metros + 30 cm.
    """
    if required_height_cm <= 0:
        return 0.0
    if not options:
        return 0.0

    normalized = [
        (int(round(float(o["height_cm"]))), float(o["price"]))
        for o in options
        if float(o.get("height_cm", 0)) > 0
    ]
    if not normalized:
        return 0.0

    target = int(round(required_height_cm + 0.499999))
    max_height = max(height for height, _ in normalized)
    limit = target + max_height
    inf = float("inf")
    dp = [inf] * (limit + 1)
    dp[0] = 0.0

    for current in range(limit + 1):
        if dp[current] == inf:
            continue
        for height, price in normalized:
            nxt = min(limit, current + height)
            dp[nxt] = min(dp[nxt], dp[current] + price)

    return min(dp[target:])


def marking_cost_unit(config: dict[str, Any], quantity: int) -> float:
    mode = config.get("mode")

    if mode == "none" or not mode:
        return 0.0

    if mode == "bordado":
        fixed = float(config.get("fixed_program_cost", 0))
        extra = float(config.get("extra_cost_unit", 0))
        return fixed / quantity + extra

    if mode == "dtf":
        roll_width_cm = float(config.get("roll_width_cm", 58))
        waste_pct = float(config.get("waste_pct", 0))
        designs = config.get("designs", [])

        total_area_cm2 = sum(
            float(d.get("width_cm", 0))
            * float(d.get("height_cm", 0))
            * float(d.get("units_per_product", 1))
            for d in designs
        )
        total_height_cm = (total_area_cm2 * quantity / roll_width_cm) * (1 + waste_pct / 100.0)
        if config.get("purchase_options"):
            cost = least_cost_sheet_purchase(total_height_cm, config["purchase_options"]) / quantity
        else:
            price_per_meter = float(config.get("price_per_meter", 0))
            meters_unit = (total_area_cm2 / roll_width_cm / 100.0) * (1 + waste_pct / 100.0)
            cost = meters_unit * price_per_meter

        iron = config.get("iron")
        if iron and iron.get("include", False):
            cost += electricity_cost_unit(
                float(iron.get("watts", 0)),
                float(iron.get("seconds", 0)),
                int(iron.get("passes", 1)),
                float(iron.get("kwh_price", 0)),
            )
        return cost

    if mode == "sublimacion_mug":
        paper_pkg = float(config.get("paper_package_100_sheets", 0))
        images_per_sheet = float(config.get("images_per_sheet", 1))
        ink_set = float(config.get("ink_set_cost", 0))
        ink_yield_sheets = float(config.get("ink_yield_sheets", 1))
        paper = paper_pkg / 100.0 / images_per_sheet
        ink = ink_set / ink_yield_sheets / images_per_sheet
        elec = electricity_cost_unit(
            float(config.get("watts", 0)),
            float(config.get("seconds", 0)),
            int(config.get("passes", 1)),
            float(config.get("kwh_price", 0)),
        )
        return paper + ink + elec

    if mode == "dtf_uv":
        price_per_meter = float(config.get("price_per_meter", 0))
        roll_width_cm = float(config.get("roll_width_cm", 58))
        width_cm = float(config.get("width_cm", 0))
        height_cm = float(config.get("height_cm", 0))
        waste_pct = float(config.get("waste_pct", 0))
        transport_total = float(config.get("transport_total", 0))
        total_height_cm = (width_cm * height_cm * quantity / roll_width_cm) * (1 + waste_pct / 100.0)
        if config.get("purchase_options"):
            return least_cost_sheet_purchase(total_height_cm, config["purchase_options"]) / quantity + transport_total / quantity
        meters_unit = (width_cm * height_cm / roll_width_cm / 100.0) * (1 + waste_pct / 100.0)
        return meters_unit * price_per_meter + transport_total / quantity

    raise ValueError(f"Unsupported marking mode: {mode}")


def shipping_cost_unit(config: dict[str, Any], quantity: int) -> float:
    """Costos de envio/transporte — se cobran por separado, no van en precio_producto."""
    return sum(
        float(c.get("value_total", 0))
        for c in config.get("order_costs", [])
        if c.get("billing") == "separate"
    ) / quantity


def calculate_price(config: dict[str, Any], quantity: int) -> PriceResult:
    product_costs = sum(tiered_unit_cost(c, quantity) for c in config.get("product_costs", []))
    # Solo incluir order_costs sin billing=separate en el precio unitario
    order_costs_unit = sum(
        float(c.get("value_total", 0))
        for c in config.get("order_costs", [])
        if c.get("billing") != "separate"
    ) / quantity
    machine_wear_policy = config.get("machine_wear_policy", {})
    # min_amortization_qty: denominador minimo para amortizar desgaste.
    # Para qty < min, el costo por unidad equivale al de min unidades.
    # Evita inversiones de precio (qty=2 mas caro que qty=1).
    min_amort = int(machine_wear_policy.get("min_amortization_qty", 1))
    effective_qty = max(quantity, min_amort)
    machine_costs_unit = sum(
        float(m.get("replacement_value", 0)) / max(float(m.get("estimated_uses", 1)), 1)
        for m in config.get("machines", [])
    ) / effective_qty
    marking = marking_cost_unit(config.get("marking", {}), quantity)

    total_cost = product_costs + marking + order_costs_unit + machine_costs_unit

    taxes = config.get("withholdings", {})
    ret_pct = (
        float(taxes.get("reteica_pct", 0))
        + float(taxes.get("retefuente_pct", 0))
        + float(taxes.get("reteiva_pct", 0))
        + float(taxes.get("other_pct", 0))
    )
    ret_factor = 1 - ret_pct / 100.0
    commercial = config.get("commercial_policy", {})
    target = float(commercial.get("target_pct", 40))
    mode = commercial.get("mode", "margen")

    if mode == "margen":
        margin_factor = 1 - target / 100.0
        sale_price = total_cost / (ret_factor * margin_factor)
    elif mode == "markup":
        sale_price = total_cost * (1 + target / 100.0) / ret_factor
    else:
        raise ValueError(f"Unsupported commercial policy mode: {mode}")

    received = sale_price * ret_factor
    profit = received - total_cost
    real_margin = profit / received * 100 if received else 0
    real_markup = profit / total_cost * 100 if total_cost else 0

    return PriceResult(
        quantity=quantity,
        total_cost_unit=total_cost,
        sale_price_unit=sale_price,
        received_unit=received,
        profit_unit=profit,
        real_margin_pct=real_margin,
        real_markup_pct=real_markup,
    )


def main(path: str) -> None:
    config = json.loads(Path(path).read_text(encoding="utf-8"))
    ranges = config.get("quantity_breaks", [1, 12, 50, 100, 200])
    results = [calculate_price(config, int(qty)) for qty in ranges]

    print("qty,costo_unitario,precio_unitario,recibido_unitario,ganancia_unitaria,margen_real_pct,markup_real_pct")
    for r in results:
        print(
            f"{r.quantity},"
            f"{money(r.total_cost_unit)},"
            f"{money(r.sale_price_unit)},"
            f"{money(r.received_unit)},"
            f"{money(r.profit_unit)},"
            f"{r.real_margin_pct:.2f},"
            f"{r.real_markup_pct:.2f}"
        )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python scripts/catalog/pricing_model.py <input.json>")
    main(sys.argv[1])
