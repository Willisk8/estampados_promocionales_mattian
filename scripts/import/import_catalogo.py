"""
Importa el catálogo de proveedores a Supabase desde el Excel de migración.

Orden de carga (respeta FKs):
  1. proveedor
  2. producto_proveedor
  3. precio_proveedor_snapshot

Uso:
  python scripts/import/import_catalogo.py --file outputs/supabase_migration_20260824/catalogo_promocionales_migracion_supabase.xlsx
  python scripts/import/import_catalogo.py --file ... --limit 30   # muestra de 30 productos
  python scripts/import/import_catalogo.py --file ... --dry-run
"""

import argparse
import json
import sys
from pathlib import Path

import openpyxl
import psycopg

sys.path.insert(0, str(Path(__file__).parent))
from _shared import clean_value, parse_jsonb, file_sha256, load_env, register_batch, complete_batch


# --------------------------------------------------------------------------- #
# Lectura del Excel
# --------------------------------------------------------------------------- #

def read_sheet(wb, sheet_name: str, limit: int | None = None) -> tuple[list[str], list[dict]]:
    ws = wb[sheet_name]
    rows_iter = ws.iter_rows(values_only=True)
    headers = [str(h) for h in next(rows_iter)]
    records = []
    for i, row in enumerate(rows_iter):
        if limit is not None and i >= limit:
            break
        records.append(dict(zip(headers, row)))
    return headers, records


# --------------------------------------------------------------------------- #
# Inserts por tabla
# --------------------------------------------------------------------------- #

def insert_proveedor(cur, records: list[dict]) -> int:
    inserted = 0
    for r in records:
        cur.execute(
            """
            INSERT INTO proveedor (id_proveedor, source_id, nombre, ciudad, pais, activo)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (id_proveedor) DO NOTHING
            """,
            (
                clean_value(r["id_proveedor"]),
                clean_value(r["source_id"]),
                clean_value(r["nombre"]),
                clean_value(r["ciudad"]),
                clean_value(r.get("pais", "CO")),
                bool(r.get("activo", True)),
            ),
        )
        if cur.rowcount:
            inserted += 1
    return inserted


def insert_producto_proveedor(cur, records: list[dict]) -> int:
    inserted = 0
    for r in records:
        tags_raw = clean_value(r.get("tags"))
        # '{}'  o None → NULL; de lo contrario dejar como string de array PG
        tags = None if tags_raw in (None, "{}", "") else tags_raw

        cur.execute(
            """
            INSERT INTO producto_proveedor (
                id_producto_proveedor, id_proveedor, sku_proveedor,
                nombre_original, categoria, tags, descripcion,
                atributos, url_producto, estado_calidad, motivo_revision
            ) VALUES (%s, %s, %s, %s, %s, %s::text[], %s, %s::jsonb, %s, %s, %s)
            ON CONFLICT (id_producto_proveedor) DO NOTHING
            """,
            (
                clean_value(r["id_producto_proveedor"]),
                clean_value(r["id_proveedor"]),
                clean_value(r.get("sku_proveedor")),
                clean_value(r["nombre_original"]),
                clean_value(r.get("categoria")),
                tags,
                clean_value(r.get("descripcion")),
                json.dumps(parse_jsonb(r.get("atributos"))),
                clean_value(r.get("url_producto")),
                clean_value(r.get("estado_calidad", "PENDING_REVIEW")),
                clean_value(r.get("motivo_revision")),
            ),
        )
        if cur.rowcount:
            inserted += 1
    return inserted


def insert_precio_proveedor_snapshot(cur, records: list[dict]) -> int:
    inserted = 0
    for r in records:
        cur.execute(
            """
            INSERT INTO precio_proveedor_snapshot (
                id_snapshot, id_producto_proveedor, precio_publicado, moneda,
                precio_texto_original, visibilidad, disponibilidad,
                url_fuente, observado_en
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (id_snapshot) DO NOTHING
            """,
            (
                clean_value(r["id_snapshot"]),
                clean_value(r["id_producto_proveedor"]),
                clean_value(r["precio_publicado"]),
                clean_value(r.get("moneda", "COP")),
                clean_value(r.get("precio_texto_original")),
                clean_value(r.get("visibilidad")),
                clean_value(r.get("disponibilidad")),
                clean_value(r.get("url_fuente")),
                clean_value(r.get("observado_en")),
            ),
        )
        if cur.rowcount:
            inserted += 1
    return inserted


# --------------------------------------------------------------------------- #
# Pipeline principal
# --------------------------------------------------------------------------- #

def run(file_path: str, limit: int | None, dry_run: bool):
    file_path = str(Path(file_path).resolve())
    source_name = "catalogo_proveedores"

    print(f"Leyendo {file_path}...")
    wb = openpyxl.load_workbook(file_path, read_only=True, data_only=True)

    _, proveedores = read_sheet(wb, "proveedor")
    _, productos = read_sheet(wb, "producto_proveedor", limit)
    prod_ids = {r["id_producto_proveedor"] for r in productos}

    # Filtrar snapshots que corresponden a los productos cargados
    _, snapshots = read_sheet(wb, "precio_proveedor_snapshot")
    if limit is not None:
        snapshots = [s for s in snapshots if s["id_producto_proveedor"] in prod_ids]

    wb.close()

    total_rows = len(proveedores) + len(productos) + len(snapshots)

    print(f"  proveedor:                  {len(proveedores):>5,}")
    print(f"  producto_proveedor:         {len(productos):>5,}")
    print(f"  precio_proveedor_snapshot:  {len(snapshots):>5,}")
    print(f"  Total filas:                {total_rows:>5,}")

    if dry_run:
        print("\n[DRY RUN] No se escribió nada en la base de datos.")
        return

    db_url = load_env()
    sha256 = file_sha256(file_path)
    print(f"\nSHA-256 del archivo: {sha256[:16]}...")

    with psycopg.connect(db_url) as conn:
        batch_id = register_batch(conn, source_name, file_path, sha256, total_rows)
        if batch_id is None:
            print("Este archivo ya fue importado (mismo checksum).")
            return

        print(f"import_batch registrado: {batch_id}")

        try:
            with conn.cursor() as cur:
                print("\nInsertando proveedor...")
                n = insert_proveedor(cur, proveedores)
                print(f"  {n:,} nuevos / {len(proveedores) - n:,} ya existían")

                print("Insertando producto_proveedor...")
                n = insert_producto_proveedor(cur, productos)
                print(f"  {n:,} nuevos / {len(productos) - n:,} ya existían")

                print("Insertando precio_proveedor_snapshot...")
                n = insert_precio_proveedor_snapshot(cur, snapshots)
                print(f"  {n:,} nuevos / {len(snapshots) - n:,} ya existían")

            conn.commit()
            complete_batch(conn, batch_id, "COMPLETED")
            print("\nImportación completada.")

        except Exception as e:
            conn.rollback()
            complete_batch(conn, batch_id, "FAILED")
            print(f"\nERROR: {e}")
            raise


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Importa catálogo de proveedores a Supabase.")
    parser.add_argument("--file", required=True, help="Ruta al Excel de migración")
    parser.add_argument("--limit", type=int, default=None, help="Importar solo los primeros N productos (muestra)")
    parser.add_argument("--dry-run", action="store_true", help="Solo leer el archivo, sin escribir en DB")
    args = parser.parse_args()

    run(args.file, args.limit, args.dry_run)
