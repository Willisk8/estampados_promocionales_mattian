"""
Genera SQL para poblar catalogo propio MVP en estado DRAFT.

No ejecuta SQL. El output se revisa antes de aplicar.

Uso:
  python scripts/catalog/generate_catalog_seed.py scripts/catalog/mvp_catalog_inputs.json > outputs/mvp_catalog_seed.sql
"""

from __future__ import annotations

import json
import sys
import uuid
from pathlib import Path
from typing import Any

from pricing_model import calculate_price, marking_cost_unit, money


NS = uuid.UUID("7d1f2d5c-6736-4bd8-b582-f055a34d7db1")


def stable_uuid(*parts: object) -> uuid.UUID:
    return uuid.uuid5(NS, ":".join(str(p) for p in parts))


def q(value: object) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def jsonb(value: Any) -> str:
    return q(json.dumps(value, ensure_ascii=False, sort_keys=True)) + "::jsonb"


def numeric(value: float) -> str:
    return f"{float(value):.2f}"


def range_for(breaks: list[int], idx: int) -> str:
    start = int(breaks[idx])
    if idx + 1 < len(breaks):
        return f"'[{start},{int(breaks[idx + 1])})'::int4range"
    return f"'[{start},)'::int4range"


def classify_costs(config: dict[str, Any], reference_qty: int) -> dict[str, float]:
    base = 0.0
    personalization = 0.0
    packaging = 0.0
    other = 0.0

    for item in config.get("product_costs", []):
        name = str(item.get("name", "")).lower()
        value = float(item.get("value_unit", 0))
        if any(token in name for token in ("proveedor", "material", "insumo", "producto", "camiseta", "mug", "termo")):
            base += value
        elif any(token in name for token in ("mano", "marcacion", "marcación", "personalizacion", "personalización")):
            personalization += value
        elif "empaque" in name:
            packaging += value
        else:
            other += value

    personalization += marking_cost_unit(config.get("marking", {}), reference_qty)
    other += sum(float(c.get("value_total", 0)) for c in config.get("order_costs", [])) / reference_qty
    other += sum(
        float(m.get("replacement_value", 0)) / max(float(m.get("estimated_uses", 1)), 1)
        for m in config.get("machines", [])
    ) / reference_qty

    return {
        "base": base,
        "personalization": personalization,
        "packaging": packaging,
        "other": other,
    }


def generate_product_sql(config: dict[str, Any], valid_from: str, valid_to: str) -> list[str]:
    p = config["product"]
    sku = p["sku"]
    variant_sku = p["variant_sku"]
    product_id = stable_uuid("producto", sku)
    variant_id = stable_uuid("variante", sku, variant_sku)
    cost_id = stable_uuid("costo", sku, variant_sku, valid_from)
    breaks = [int(qty) for qty in config.get("quantity_breaks", [1, 12, 50, 100, 200])]
    reference_qty = int(config.get("cost_reference_quantity", breaks[-2] if len(breaks) > 1 else breaks[0]))
    costs = classify_costs(config, reference_qty)
    validity = f"'[{valid_from},{valid_to})'::tstzrange"

    lines = [
        f"-- Producto propio MVP: {sku} / {variant_sku}",
        "INSERT INTO producto (id_producto, sku, nombre, categoria, descripcion, estado, activo)",
        (
            f"VALUES ('{product_id}'::uuid, {q(sku)}, {q(p['name'])}, {q(p.get('category'))}, "
            f"{q(p.get('description'))}, 'DRAFT', true)"
        ),
        "ON CONFLICT (sku) DO NOTHING;",
        "",
        "INSERT INTO variante_producto (id_variante, id_producto, sku_variante, nombre, atributos, estado, activo)",
        (
            f"VALUES ('{variant_id}'::uuid, '{product_id}'::uuid, {q(variant_sku)}, {q(p['variant_name'])}, "
            f"{jsonb(p.get('attributes', {}))}, 'DRAFT', true)"
        ),
        "ON CONFLICT (id_producto, sku_variante) DO NOTHING;",
        "",
        (
            "INSERT INTO costo_producto (id_costo, id_producto, id_variante, costo_base, "
            "costo_personalizacion, costo_empaque, otros_costos, moneda, vigencia)"
        ),
        (
            f"VALUES ('{cost_id}'::uuid, '{product_id}'::uuid, '{variant_id}'::uuid, "
            f"{numeric(costs['base'])}, {numeric(costs['personalization'])}, "
            f"{numeric(costs['packaging'])}, {numeric(costs['other'])}, 'COP', {validity})"
        ),
        "ON CONFLICT (id_costo) DO NOTHING;",
        "",
    ]

    for idx, qty in enumerate(breaks):
        result = calculate_price(config, qty)
        price_id = stable_uuid("precio", sku, variant_sku, qty, valid_from)
        lines.extend([
            "INSERT INTO precio_producto (id_precio, id_producto, id_variante, quantity_range, validity, precio_unitario, moneda, incluye_impuestos)",
            (
                f"VALUES ('{price_id}'::uuid, '{product_id}'::uuid, '{variant_id}'::uuid, "
                f"{range_for(breaks, idx)}, {validity}, {numeric(money(result.sale_price_unit))}, 'COP', false)"
            ),
            "ON CONFLICT (id_precio) DO NOTHING;",
        ])

    supplier_ids = config.get("supplier_product_ids", [])
    if supplier_ids:
        lines.append("")
    for supplier_product_id in supplier_ids:
        mapping_id = stable_uuid("mapeo", variant_id, supplier_product_id)
        lines.extend([
            "INSERT INTO mapeo_proveedor_variante (id_mapeo, id_variante, id_producto_proveedor, estado_mapeo, confirmado_en, notas)",
            (
                f"VALUES ('{mapping_id}'::uuid, '{variant_id}'::uuid, '{supplier_product_id}'::uuid, "
                "'PENDING_REVIEW', NULL, 'Mapeo sugerido desde scripts/catalog/mvp_catalog_inputs.json')"
            ),
            "ON CONFLICT (id_variante, id_producto_proveedor) DO NOTHING;",
        ])

    lines.append("")
    return lines


def main(path: str) -> None:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    valid_from = data["valid_from"]
    valid_to = data["valid_to"]
    print("-- ============================================================")
    print("-- Catalogo propio MVP generado. Revisar antes de aplicar.")
    print("-- Productos quedan en DRAFT: resolve_price no los cotiza hasta estado ACTIVE.")
    print("-- ============================================================")
    print("BEGIN;")
    print("")
    for product in data.get("products", []):
        print("\n".join(generate_product_sql(product, valid_from, valid_to)))
    print("COMMIT;")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python scripts/catalog/generate_catalog_seed.py <catalog_inputs.json>")
    main(sys.argv[1])
