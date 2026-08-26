"""
Valida que web/src/lib/pricing/modelo.ts calcule lo mismo que
pricing_model.py sobre los 5 productos reales del catalogo MVP.

No es una prueba teorica: corre ambas implementaciones sobre el mismo
archivo de insumos (mvp_catalog_inputs.json) y compara cada campo del
resultado con tolerancia de punto flotante. Cualquier divergencia futura
entre el simulador de la consola y el script de referencia se detecta aqui.

Uso:
    python scripts/catalog/validar_puerto_ts.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "catalog"))

from pricing_model import calculate_price  # noqa: E402

TOLERANCIA = 1e-6


# El catalogo real no ejercita marking.mode="bordado" ni commercial_policy
# mode="markup". Estos casos deben coincidir EXACTAMENTE (mismos numeros) con
# los CASOS_SINTETICOS de web/scripts/calcular_referencia.mjs.
CASOS_SINTETICOS = {
    "SINTETICO_BORDADO": {
        "quantity_breaks": [1, 12, 50],
        "product_costs": [{"value_unit": 5000}],
        "marking": {"mode": "bordado", "fixed_program_cost": 12000, "extra_cost_unit": 350},
        "withholdings": {"reteica_pct": 1, "retefuente_pct": 2.5},
        "commercial_policy": {"mode": "margen", "target_pct": 35},
    },
    "SINTETICO_MARKUP": {
        "quantity_breaks": [1, 12, 50],
        "product_costs": [{"value_unit": 8000}],
        "marking": {"mode": "none"},
        "commercial_policy": {"mode": "markup", "target_pct": 30},
    },
}


def calcular_con_python() -> dict[str, list[dict]]:
    catalogo = json.loads((ROOT / "scripts" / "catalog" / "mvp_catalog_inputs.json").read_text(encoding="utf-8"))
    productos = list(catalogo["products"])
    for sku, entrada in CASOS_SINTETICOS.items():
        productos.append({"product": {"sku": sku}, **entrada})

    resultado: dict[str, list[dict]] = {}
    for entrada in productos:
        sku = entrada["product"]["sku"]
        cantidades = entrada.get("quantity_breaks", [1, 12, 50, 100, 200])
        resultado[sku] = [
            {
                "quantity": r.quantity,
                "total_cost_unit": r.total_cost_unit,
                "sale_price_unit": r.sale_price_unit,
                "received_unit": r.received_unit,
                "profit_unit": r.profit_unit,
                "real_margin_pct": r.real_margin_pct,
                "real_markup_pct": r.real_markup_pct,
            }
            for r in (calculate_price(entrada, int(qty)) for qty in cantidades)
        ]
    return resultado


def calcular_con_typescript() -> dict[str, list[dict]]:
    script = ROOT / "web" / "scripts" / "calcular_referencia.mjs"
    proc = subprocess.run(
        ["node", "--experimental-strip-types", str(script)],
        cwd=ROOT / "web",
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"El script de Node fallo:\n{proc.stderr}")
    return json.loads(proc.stdout)


def comparar(python_out: dict, ts_out: dict) -> list[str]:
    diferencias = []
    if set(python_out) != set(ts_out):
        diferencias.append(f"SKUs distintos: python={set(python_out)} ts={set(ts_out)}")
        return diferencias

    for sku, filas_py in python_out.items():
        filas_ts = ts_out[sku]
        if len(filas_py) != len(filas_ts):
            diferencias.append(f"{sku}: numero de escalas distinto ({len(filas_py)} vs {len(filas_ts)})")
            continue
        for fila_py, fila_ts in zip(filas_py, filas_ts):
            qty = fila_py["quantity"]
            for campo in (
                "total_cost_unit", "sale_price_unit", "received_unit",
                "profit_unit", "real_margin_pct", "real_markup_pct",
            ):
                a, b = fila_py[campo], fila_ts[campo]
                if abs(a - b) > TOLERANCIA * max(1, abs(a)):
                    diferencias.append(
                        f"{sku} qty={qty} {campo}: python={a!r} ts={b!r} (diff={abs(a - b)!r})"
                    )
    return diferencias


def main() -> int:
    print("Calculando con Python (pricing_model.py)...")
    python_out = calcular_con_python()
    print("Calculando con TypeScript (modelo.ts) via node --experimental-strip-types...")
    ts_out = calcular_con_typescript()

    diferencias = comparar(python_out, ts_out)

    total_filas = sum(len(v) for v in python_out.values())
    print(f"\n{len(python_out)} productos, {total_filas} escalas comparadas.")

    if diferencias:
        print(f"\nDIVERGENCIAS ({len(diferencias)}):")
        for d in diferencias:
            print("  -", d)
        return 1

    print("Sin divergencias: el puerto TypeScript calcula lo mismo que pricing_model.py.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
