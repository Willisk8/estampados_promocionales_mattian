"""
Importa entidades solidarias a Supabase desde el Excel de migración.

Orden de carga (respeta FKs):
  1. organizacion
  2. persona
  3. persona_organizacion
  4. canal_contacto

Uso:
  python scripts/import/import_entidades.py --file outputs/supabase_migration_20260824/entidades_solidarias_migracion_supabase.xlsx
  python scripts/import/import_entidades.py --file ... --limit 50   # muestra de 50 orgs
  python scripts/import/import_entidades.py --file ... --dry-run    # sin escribir en DB
"""

import argparse
import hashlib
import hmac
import os
import sys
from pathlib import Path

import openpyxl

sys.path.insert(0, str(Path(__file__).parent))
from _shared import (
    clean_value,
    file_sha256,
    load_env,
    register_batch,
    register_raw_rows,
    register_review_items,
    source_run_name,
    stable_uuid,
    complete_batch,
)


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
        record = dict(zip(headers, row))
        record["__sheet_row_number"] = i + 2
        records.append(record)
    return headers, records


# --------------------------------------------------------------------------- #
# Cálculo de email_hash
# --------------------------------------------------------------------------- #

def compute_email_hash(email: str, secret: str) -> str:
    return hmac.new(secret.encode(), email.lower().strip().encode(), hashlib.sha256).hexdigest()


# --------------------------------------------------------------------------- #
# Inserts por tabla
# --------------------------------------------------------------------------- #

def insert_organizacion(cur, records: list[dict]) -> int:
    inserted = 0
    for r in records:
        cur.execute(
            """
            INSERT INTO organizacion (
                id_organizacion, nit, nombre_legal, nombre_comercial, sigla,
                tipo_entidad_origen, departamento, municipio, direccion,
                fuente_registro, fecha_reporte_oficial, estado
            ) VALUES (
                %s, %s, %s, %s, %s,
                %s, %s, %s, %s,
                %s, %s, %s
            )
            ON CONFLICT (id_organizacion) DO NOTHING
            """,
            (
                clean_value(r["id_organizacion"]),
                clean_value(r["nit"]),
                clean_value(r["nombre_legal"]),
                clean_value(r["nombre_comercial"]),
                clean_value(r["sigla"]),
                clean_value(r["tipo_entidad_origen"]),
                clean_value(r["departamento"]),
                clean_value(r["municipio"]),
                clean_value(r["direccion"]),
                clean_value(r["fuente_registro"]),
                clean_value(r["fecha_reporte_oficial"]),
                clean_value(r.get("estado", "ACTIVE")),
            ),
        )
        if cur.rowcount:
            inserted += 1
    return inserted


def insert_persona(cur, records: list[dict]) -> int:
    inserted = 0
    for r in records:
        cur.execute(
            """
            INSERT INTO persona (
                id_persona, nombres, apellidos, nombre_completo,
                tipo_documento, numero_documento_hash, estado
            ) VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (id_persona) DO NOTHING
            """,
            (
                clean_value(r["id_persona"]),
                clean_value(r["nombres"]),
                clean_value(r["apellidos"]),
                clean_value(r["nombre_completo"]),
                clean_value(r["tipo_documento"]),
                clean_value(r["numero_documento_hash"]),
                clean_value(r.get("estado", "ACTIVE")),
            ),
        )
        if cur.rowcount:
            inserted += 1
    return inserted


def insert_persona_organizacion(cur, records: list[dict]) -> int:
    inserted = 0
    for r in records:
        cur.execute(
            """
            INSERT INTO persona_organizacion (
                id_persona_organizacion, id_persona, id_organizacion,
                rol, cargo, area, fecha_inicio, fecha_fin, fuente, estado
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (id_persona_organizacion) DO NOTHING
            """,
            (
                clean_value(r["id_persona_organizacion"]),
                clean_value(r["id_persona"]),
                clean_value(r["id_organizacion"]),
                clean_value(r.get("rol", "CONTACTO")),
                clean_value(r["cargo"]),
                clean_value(r["area"]),
                clean_value(r["fecha_inicio"]),
                clean_value(r["fecha_fin"]),
                clean_value(r["fuente"]),
                clean_value(r.get("estado", "ACTIVE")),
            ),
        )
        if cur.rowcount:
            inserted += 1
    return inserted


def insert_canal_contacto(cur, records: list[dict], hmac_secret: str | None) -> int:
    inserted = 0
    for r in records:
        email_hash = clean_value(r.get("email_hash"))
        tipo = clean_value(r.get("tipo"))
        valor_norm = clean_value(r.get("valor_normalizado"))

        # Calcular email_hash si falta y hay secreto disponible
        if tipo == "EMAIL" and valor_norm and not email_hash and hmac_secret:
            email_hash = compute_email_hash(valor_norm, hmac_secret)

        cur.execute(
            """
            INSERT INTO canal_contacto (
                id_canal_contacto, id_organizacion, id_persona,
                tipo, valor_original, valor_normalizado,
                email_hash, fuente, confianza, estado
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (id_canal_contacto) DO NOTHING
            """,
            (
                clean_value(r["id_canal_contacto"]),
                clean_value(r.get("id_organizacion")),
                clean_value(r.get("id_persona")),
                tipo,
                clean_value(r["valor_original"]),
                valor_norm,
                email_hash,
                clean_value(r["fuente"]),
                clean_value(r.get("confianza", "UNKNOWN")),
                clean_value(r.get("estado", "ACTIVE")),
            ),
        )
        if cur.rowcount:
            inserted += 1
    return inserted


def insert_contactabilidad_desconocida(cur, records: list[dict], source_name: str) -> int:
    inserted = 0
    for r in records:
        canal_id = clean_value(r["id_canal_contacto"])
        contactabilidad_id = stable_uuid("contactabilidad", canal_id)
        cur.execute(
            """
            INSERT INTO contactabilidad (
                id_contactabilidad, id_canal_contacto,
                base_contacto_codigo, evidencia
            ) VALUES (%s, %s, 'DESCONOCIDA', %s)
            ON CONFLICT (id_contactabilidad) DO NOTHING
            """,
            (
                contactabilidad_id,
                canal_id,
                f"Importacion {source_name}: base legal no confirmada",
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
    source_name = source_run_name("entidades_solidarias", limit)

    print(f"Leyendo {file_path}...")
    wb = openpyxl.load_workbook(file_path, read_only=True, data_only=True)

    _, orgs = read_sheet(wb, "organizacion", limit)
    org_ids = {r["id_organizacion"] for r in orgs}

    # Filtrar personas/canales/relaciones que corresponden solo a las orgs cargadas
    _, personas = read_sheet(wb, "persona")
    _, pers_orgs = read_sheet(wb, "persona_organizacion")
    _, canales = read_sheet(wb, "canal_contacto")

    if limit is not None:
        # Filtrar las demás tablas para que solo incluyan registros de las orgs de la muestra
        pers_org_filtered = [r for r in pers_orgs if r["id_organizacion"] in org_ids]
        persona_ids = {r["id_persona"] for r in pers_org_filtered}
        personas_filtered = [r for r in personas if r["id_persona"] in persona_ids]
        canales_filtered = [r for r in canales if r.get("id_organizacion") in org_ids]
    else:
        pers_org_filtered = pers_orgs
        personas_filtered = personas
        canales_filtered = canales

    wb.close()

    total_rows = len(orgs) + len(personas_filtered) + len(pers_org_filtered) + len(canales_filtered)

    print(f"  organizacion:        {len(orgs):>6,}")
    print(f"  persona:             {len(personas_filtered):>6,}")
    print(f"  persona_organizacion:{len(pers_org_filtered):>6,}")
    print(f"  canal_contacto:      {len(canales_filtered):>6,}")
    print(f"  contactabilidad:     {len(canales_filtered):>6,}")
    print(f"  Total filas:         {total_rows:>6,}")

    if dry_run:
        print("\n[DRY RUN] No se escribió nada en la base de datos.")
        return

    db_url = load_env()
    hmac_secret = os.environ.get("HMAC_SUPPRESSION_SECRET")
    if not hmac_secret:
        print("ADVERTENCIA: HMAC_SUPPRESSION_SECRET no configurado — email_hash quedará NULL.")

    sha256 = file_sha256(file_path)
    print(f"\nSHA-256 del archivo: {sha256[:16]}...")

    import psycopg

    with psycopg.connect(db_url, prepare_threshold=None) as conn:
        batch_id = register_batch(conn, source_name, file_path, sha256, total_rows)
        if batch_id is None:
            print("Este archivo ya fue importado (mismo checksum). Usa un archivo diferente para reimportar.")
            return

        print(f"import_batch registrado: {batch_id}")

        try:
            with conn.cursor() as cur:
                print("\nRegistrando trazabilidad import_raw_row...")
                row_cursor = 1
                n = register_raw_rows(
                    cur, batch_id, "organizacion", orgs, row_cursor,
                    "organizacion", "id_organizacion", "ORGANIZATION",
                )
                row_cursor += len(orgs)
                n += register_raw_rows(
                    cur, batch_id, "persona", personas_filtered, row_cursor,
                    "persona", "id_persona", "PERSON",
                )
                row_cursor += len(personas_filtered)
                n += register_raw_rows(
                    cur, batch_id, "persona_organizacion", pers_org_filtered, row_cursor,
                    "persona_organizacion", "id_persona_organizacion", "OTHER",
                )
                row_cursor += len(pers_org_filtered)
                n += register_raw_rows(
                    cur, batch_id, "canal_contacto", canales_filtered, row_cursor,
                    "canal_contacto", "id_canal_contacto", "OTHER",
                )
                print(f"  {n:,} filas raw registradas")

                print("\nInsertando organizacion...")
                n = insert_organizacion(cur, orgs)
                print(f"  {n:,} nuevas / {len(orgs) - n:,} ya existían")

                print("Insertando persona...")
                n = insert_persona(cur, personas_filtered)
                print(f"  {n:,} nuevas / {len(personas_filtered) - n:,} ya existían")

                print("Insertando persona_organizacion...")
                n = insert_persona_organizacion(cur, pers_org_filtered)
                print(f"  {n:,} nuevas / {len(pers_org_filtered) - n:,} ya existían")

                print("Insertando canal_contacto...")
                n = insert_canal_contacto(cur, canales_filtered, hmac_secret)
                print(f"  {n:,} nuevas / {len(canales_filtered) - n:,} ya existían")

                print("Insertando contactabilidad DESCONOCIDA...")
                n = insert_contactabilidad_desconocida(cur, canales_filtered, source_name)
                print(f"  {n:,} nuevas / {len(canales_filtered) - n:,} ya existían")

                print("Registrando elementos para revision...")
                n = register_review_items(cur, batch_id, "organizacion", "id_organizacion", orgs)
                n += register_review_items(cur, batch_id, "persona", "id_persona", personas_filtered)
                n += register_review_items(
                    cur,
                    batch_id,
                    "persona_organizacion",
                    "id_persona_organizacion",
                    pers_org_filtered,
                )
                print(f"  {n:,} elementos de revision abiertos")

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
    parser = argparse.ArgumentParser(description="Importa entidades solidarias a Supabase.")
    parser.add_argument("--file", required=True, help="Ruta al Excel de migración")
    parser.add_argument("--limit", type=int, default=None, help="Importar solo las primeras N organizaciones (muestra)")
    parser.add_argument("--dry-run", action="store_true", help="Solo leer el archivo, sin escribir en DB")
    args = parser.parse_args()

    run(args.file, args.limit, args.dry_run)
