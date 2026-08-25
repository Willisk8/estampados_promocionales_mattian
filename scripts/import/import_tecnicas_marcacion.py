"""
Importa tecnicas de marcacion y snapshots de precio desde los CSV de investigacion.

Uso:
  python scripts/import/import_tecnicas_marcacion.py --dir scraping/personalization_techniques/outputs/<run_id>
  python scripts/import/import_tecnicas_marcacion.py --dir ... --dry-run
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from _shared import (  # noqa: E402
    clean_value,
    copy_into,
    file_sha256,
    load_env,
    register_batch,
    register_raw_rows,
    source_run_name,
    stable_uuid,
    complete_batch,
)

SNAPSHOT_IDENTITY_FIELDS = [
    "source_id", "supplier", "city", "technique", "service_component",
    "price_scope", "compatible_products", "compatible_materials",
    "size_label", "width_cm", "height_cm", "quantity_min", "quantity_max",
    "billing_unit", "currency", "price_value", "price_min", "price_max",
    "tax_status", "conditions", "evidence_text", "source_url", "fetched_at",
    "http_status", "verification_status"
]

REQUIRED_PRICE_FIELDS = ["source_id", "supplier", "technique"]


def read_csv(path: Path) -> list[dict]:
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    for idx, row in enumerate(rows, start=2):
        row["__sheet_row_number"] = idx
    return rows


def parse_float(value) -> float | None:
    value = clean_value(value)
    if value is None:
        return None
    return float(value)


def parse_int(value) -> int | None:
    value = clean_value(value)
    if value is None:
        return None
    return int(float(value))


def snapshot_observation_id(row: dict) -> str:
    payload = {field: clean_value(row.get(field)) or "" for field in SNAPSHOT_IDENTITY_FIELDS}
    payload = {field: str(value) for field, value in payload.items()}
    payload["_identity_version"] = "snapshot-v2"
    return hashlib.sha256(
        json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()[:32]


def has_any_price(row: dict) -> bool:
    return any(clean_value(row.get(field)) is not None for field in ("price_value", "price_min", "price_max"))


def validate_price_records(price_records: list[dict]) -> None:
    invalid: list[str] = []
    for row in price_records:
        missing = [field for field in REQUIRED_PRICE_FIELDS if clean_value(row.get(field)) is None]
        if not has_any_price(row):
            missing.append("price_value|price_min|price_max")
        if missing:
            invalid.append(
                f"fila {row.get('__sheet_row_number', '?')}: faltan {', '.join(missing)}"
            )
    if invalid:
        preview = "; ".join(invalid[:10])
        extra = "" if len(invalid) <= 10 else f"; ... {len(invalid) - 10} mas"
        raise RuntimeError(
            "precios_tecnicas_personalizacion.csv contiene filas invalidas. "
            "La carga se aborta para no perder trazabilidad: "
            f"{preview}{extra}"
        )


def aliases_to_array(value) -> list[str] | None:
    value = clean_value(value)
    if not value:
        return None
    return [part.strip() for part in str(value).split(";") if part.strip()]


def technique_id(code: str) -> str:
    return stable_uuid("tecnica_marcacion", code)


def supplier_id(source_id: str, supplier: str) -> str:
    return stable_uuid("proveedor_tecnica_marcacion", source_id or supplier)


def normalize_techniques(records: list[dict], price_records: list[dict]) -> list[dict]:
    normalized_by_code = {}
    for row in records:
        code = clean_value(row.get("technique"))
        if not code:
            continue
        normalized_by_code[code] = {
            **row,
            "id_tecnica": technique_id(code),
            "codigo": code,
            "aliases_array": aliases_to_array(row.get("aliases")),
        }

    # Algunas investigaciones de precio descubren variantes/técnicas que aún no
    # están en el catálogo curado. Se insertan como PENDING_REVIEW para conservar
    # trazabilidad y evitar snapshots huérfanos, pero no se deben usar para
    # costeo automático hasta revisar su semántica.
    for row in price_records:
        code = clean_value(row.get("technique"))
        if not code or code in normalized_by_code:
            continue
        normalized_by_code[code] = {
            "id_tecnica": technique_id(code),
            "codigo": code,
            "aliases_array": None,
            "compatible_products": clean_value(row.get("compatible_products")),
            "compatible_materials": clean_value(row.get("compatible_materials")),
            "best_for": None,
            "limitations": "Tecnica derivada de observaciones de precio; requiere curacion manual.",
            "typical_cost_drivers": clean_value(row.get("billing_unit")),
            "source_url": clean_value(row.get("source_url")),
            "fetched_at": clean_value(row.get("fetched_at")),
            "verification_status": "PENDING_REVIEW",
            "__sheet_row_number": row.get("__sheet_row_number"),
        }
    return list(normalized_by_code.values())


def normalize_suppliers(price_records: list[dict]) -> list[dict]:
    by_source = {}
    for row in price_records:
        source_id = clean_value(row.get("source_id"))
        supplier = clean_value(row.get("supplier"))
        if not source_id or not supplier:
            continue
        if source_id not in by_source:
            by_source[source_id] = {
                "id_proveedor_tecnica": supplier_id(source_id, supplier),
                "source_id": source_id,
                "nombre": supplier,
                "ciudad": clean_value(row.get("city")),
                "pais": "CO",
                "source_url": clean_value(row.get("source_url")),
            }
    return list(by_source.values())


def normalize_prices(price_records: list[dict]) -> list[dict]:
    normalized = []
    for row in price_records:
        source_id = clean_value(row.get("source_id"))
        supplier = clean_value(row.get("supplier"))
        technique = clean_value(row.get("technique"))
        if not (source_id and supplier and technique):
            continue
        observation_id = snapshot_observation_id(row)
        formato_costeo = {
            "size_label": clean_value(row.get("size_label")),
            "billing_unit": clean_value(row.get("billing_unit")),
            "conditions": clean_value(row.get("conditions")),
            "price_scope": clean_value(row.get("price_scope")),
        }
        normalized.append({
            **row,
            "observation_id": observation_id,
            "id_snapshot": stable_uuid("precio_tecnica_marcacion_snapshot", observation_id),
            "id_tecnica": technique_id(technique),
            "id_proveedor_tecnica": supplier_id(source_id, supplier),
            "formato_costeo": json.dumps(
                {k: v for k, v in formato_costeo.items() if v is not None},
                ensure_ascii=False,
                sort_keys=True,
            ),
        })
    return normalized


def insert_techniques(cur, records: list[dict]) -> int:
    rows = [
        (
            r["id_tecnica"],
            r["codigo"],
            r.get("aliases_array"),
            clean_value(r.get("compatible_products")),
            clean_value(r.get("compatible_materials")),
            clean_value(r.get("best_for")),
            clean_value(r.get("limitations")),
            clean_value(r.get("typical_cost_drivers")),
            clean_value(r.get("source_url")),
            clean_value(r.get("fetched_at")),
            clean_value(r.get("verification_status", "PENDING_REVIEW")),
        )
        for r in records
    ]
    return copy_into(
        cur,
        "tecnica_marcacion",
        [
            "id_tecnica", "codigo", "aliases", "productos_compatibles",
            "materiales_compatibles", "mejor_para", "limitaciones",
            "drivers_costo", "source_url", "fetched_at", "verification_status",
        ],
        rows,
        conflict_col="id_tecnica",
    )


def insert_suppliers(cur, records: list[dict]) -> int:
    rows = [
        (
            r["id_proveedor_tecnica"],
            r["source_id"],
            r["nombre"],
            r.get("ciudad"),
            r.get("pais", "CO"),
            r.get("source_url"),
        )
        for r in records
    ]
    return copy_into(
        cur,
        "proveedor_tecnica_marcacion",
        ["id_proveedor_tecnica", "source_id", "nombre", "ciudad", "pais", "source_url"],
        rows,
        conflict_col="id_proveedor_tecnica",
    )


def insert_prices(cur, records: list[dict]) -> int:
    rows = [
        (
            r["id_snapshot"],
            r["id_tecnica"],
            r["id_proveedor_tecnica"],
            clean_value(r.get("observation_id")),
            clean_value(r.get("service_component")),
            clean_value(r.get("price_scope")),
            clean_value(r.get("compatible_products")),
            clean_value(r.get("compatible_materials")),
            clean_value(r.get("size_label")),
            parse_float(r.get("width_cm")),
            parse_float(r.get("height_cm")),
            parse_int(r.get("quantity_min")),
            parse_int(r.get("quantity_max")),
            clean_value(r.get("billing_unit")),
            clean_value(r.get("currency", "COP")),
            parse_float(r.get("price_value")),
            parse_float(r.get("price_min")),
            parse_float(r.get("price_max")),
            clean_value(r.get("tax_status")),
            clean_value(r.get("conditions")),
            clean_value(r.get("evidence_text")),
            clean_value(r.get("source_url")),
            clean_value(r.get("fetched_at")),
            parse_int(r.get("http_status")),
            clean_value(r.get("verification_status", "PENDING_REVIEW")),
            r["formato_costeo"],
        )
        for r in records
    ]
    return copy_into(
        cur,
        "precio_tecnica_marcacion_snapshot",
        [
            "id_snapshot", "id_tecnica", "id_proveedor_tecnica", "observation_id",
            "service_component", "price_scope", "productos_compatibles",
            "materiales_compatibles", "size_label", "width_cm", "height_cm",
            "quantity_min", "quantity_max", "billing_unit", "currency",
            "price_value", "price_min", "price_max", "tax_status",
            "condiciones", "evidence_text", "source_url", "fetched_at",
            "http_status", "verification_status", "formato_costeo",
        ],
        rows,
        conflict_col="id_snapshot",
    )


def run(input_dir: str, dry_run: bool):
    input_path = Path(input_dir).resolve()
    techniques_path = input_path / "catalogo_tecnicas.csv"
    prices_path = input_path / "precios_tecnicas_personalizacion.csv"
    if not techniques_path.exists() or not prices_path.exists():
        raise RuntimeError("El directorio debe contener catalogo_tecnicas.csv y precios_tecnicas_personalizacion.csv")

    techniques_raw = read_csv(techniques_path)
    prices_raw = read_csv(prices_path)
    validate_price_records(prices_raw)
    techniques = normalize_techniques(techniques_raw, prices_raw)
    raw_techniques = normalize_techniques(techniques_raw, [])
    suppliers = normalize_suppliers(prices_raw)
    prices = normalize_prices(prices_raw)

    source_rows = len(techniques_raw) + len(prices_raw)
    target_rows = len(techniques) + len(suppliers) + len(prices)
    print(f"Directorio: {input_path}")
    print(f"  filas fuente CSV:                  {source_rows:>5,}")
    print(f"  tecnica_marcacion:                 {len(techniques):>5,}")
    print(f"  proveedor_tecnica_marcacion:       {len(suppliers):>5,}")
    print(f"  precio_tecnica_marcacion_snapshot: {len(prices):>5,}")
    print(f"  Total filas destino:               {target_rows:>5,}")

    if dry_run:
        print("\n[DRY RUN] No se escribió nada en la base de datos.")
        return

    combined_sha = file_sha256(str(techniques_path)) + file_sha256(str(prices_path))
    source_name = source_run_name("tecnicas_marcacion", None)

    import psycopg

    db_url = load_env()
    with psycopg.connect(db_url, prepare_threshold=None) as conn:
        batch_id = register_batch(conn, source_name, str(input_path), combined_sha, source_rows)
        if batch_id is None:
            print("Estos CSV ya fueron importados (mismo checksum).")
            return

        print(f"import_batch registrado: {batch_id}")
        try:
            with conn.cursor() as cur:
                print("\nRegistrando trazabilidad import_raw_row...")
                row_cursor = 1
                n = register_raw_rows(
                    cur, batch_id, "catalogo_tecnicas", raw_techniques, row_cursor,
                    "tecnica_marcacion", "id_tecnica", "OTHER",
                )
                row_cursor += len(raw_techniques)
                n += register_raw_rows(
                    cur, batch_id, "precios_tecnicas_personalizacion", prices, row_cursor,
                    "precio_tecnica_marcacion_snapshot", "id_snapshot", "OTHER",
                )
                print(f"  {n:,} filas raw registradas")

                print("\nInsertando tecnicas...")
                n = insert_techniques(cur, techniques)
                print(f"  {n:,} nuevas / {len(techniques) - n:,} ya existían")

                print("Insertando proveedores de tecnicas...")
                n = insert_suppliers(cur, suppliers)
                print(f"  {n:,} nuevos / {len(suppliers) - n:,} ya existían")

                print("Insertando snapshots de precios de tecnicas...")
                n = insert_prices(cur, prices)
                print(f"  {n:,} nuevos / {len(prices) - n:,} ya existían")

            conn.commit()
            complete_batch(conn, batch_id, "COMPLETED")
            print("\nImportación completada.")
        except Exception:
            conn.rollback()
            complete_batch(conn, batch_id, "FAILED")
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Importa costos de tecnicas de marcacion.")
    parser.add_argument("--dir", required=True, help="Directorio con CSV de investigacion")
    parser.add_argument("--dry-run", action="store_true", help="Solo leer archivos, sin escribir en DB")
    args = parser.parse_args()

    run(args.dir, args.dry_run)
