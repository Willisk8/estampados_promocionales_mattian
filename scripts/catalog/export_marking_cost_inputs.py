"""
Exporta costos curados de tecnicas de marcacion desde Supabase.

No escribe en la base. Devuelve JSON para alimentar o auditar la calculadora:

  python scripts/catalog/export_marking_cost_inputs.py > outputs/marking_cost_inputs.json
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "import"))

from _shared import load_env  # noqa: E402


QUERY = """
SELECT
    tecnica_codigo,
    proveedor_nombre,
    service_component,
    price_scope,
    size_label,
    width_cm,
    height_cm,
    quantity_min,
    quantity_max,
    billing_unit,
    currency,
    price_value,
    price_min,
    price_max,
    tax_status,
    verification_status,
    usage_status,
    formula_code,
    usage_notes,
    source_url,
    fetched_at
FROM vw_precio_tecnica_marcacion_curado
WHERE usage_status = 'AUTOMATIC_PRICING'
ORDER BY tecnica_codigo, formula_code, proveedor_nombre, quantity_min NULLS FIRST, height_cm NULLS FIRST;
"""


def clean(row: dict) -> dict:
    cleaned = {}
    for key, value in row.items():
        if value is None:
            continue
        if isinstance(value, Decimal):
            cleaned[key] = float(value)
        elif hasattr(value, "isoformat"):
            cleaned[key] = value.isoformat()
        else:
            cleaned[key] = value
    return cleaned


def main() -> None:
    import psycopg
    from psycopg.rows import dict_row

    grouped: dict[str, list[dict]] = defaultdict(list)
    with psycopg.connect(load_env(), row_factory=dict_row, prepare_threshold=None) as conn:
        with conn.cursor() as cur:
            cur.execute(QUERY)
            for row in cur.fetchall():
                grouped[row["tecnica_codigo"]].append(clean(dict(row)))

    payload = {
        "source": "vw_precio_tecnica_marcacion_curado",
        "usage_status": "AUTOMATIC_PRICING",
        "techniques": dict(sorted(grouped.items())),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
