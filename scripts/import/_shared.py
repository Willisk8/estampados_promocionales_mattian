"""
Utilidades compartidas para los scripts de importación.
"""
import hashlib
import json
import os
import uuid
from datetime import datetime, date
from pathlib import Path

IMPORT_NAMESPACE = uuid.UUID("2e639048-61b2-5a2f-bcc2-13b78b7c8f5d")


def file_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def clean_value(v):
    """Convierte valores de openpyxl a tipos compatibles con psycopg3."""
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, (datetime, date)):
        return v
    if isinstance(v, str):
        s = v.strip()
        return s if s else None
    return v


def clean_record(record: dict) -> dict:
    return {k: clean_value(v) for k, v in record.items() if not str(k).startswith("__")}


def stable_uuid(*parts: object) -> str:
    key = "|".join("" if p is None else str(p) for p in parts)
    return str(uuid.uuid5(IMPORT_NAMESPACE, key))


def source_run_name(base_name: str, limit: int | None) -> str:
    if limit is None:
        return f"{base_name}:full"
    return f"{base_name}:pilot:{limit}"


def parse_jsonb(v):
    """Convierte string JSON de Excel a dict para columnas JSONB."""
    if v is None:
        return {}
    if isinstance(v, str):
        s = v.strip()
        if not s or s == "{}":
            return {}
        try:
            return json.loads(s)
        except json.JSONDecodeError:
            return {}
    return v


def parse_text_array(v):
    """Convierte '{}' o None a None para columnas TEXT[]."""
    if v is None:
        return None
    if isinstance(v, str):
        s = v.strip()
        if s in ("", "{}"):
            return None
    return v


def load_env():
    """Carga .env.staging si existe, luego variables de entorno del sistema."""
    env_file = Path(__file__).parent.parent.parent / ".env.staging"
    if env_file.exists():
        from dotenv import load_dotenv
        load_dotenv(env_file)

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        raise RuntimeError(
            "DATABASE_URL no está configurado.\n"
            "Crea .env.staging con DATABASE_URL=postgresql://... o exporta la variable."
        )
    return db_url


def register_batch(conn, source_name: str, source_path: str, sha256: str, row_count: int) -> str:
    """
    Registra el archivo en import_batch. Retorna el id_import_batch.
    Si el mismo (source_name, sha256) ya existe, retorna None (ya importado).
    """
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id_import_batch FROM import_batch
            WHERE source_name = %s AND source_sha256 = %s
            """,
            (source_name, sha256),
        )
        row = cur.fetchone()
        if row:
            return None  # ya importado

        cur.execute(
            """
            INSERT INTO import_batch
                (source_name, source_path, source_sha256, source_row_count, import_status)
            VALUES (%s, %s, %s, %s, 'RUNNING')
            RETURNING id_import_batch
            """,
            (source_name, source_path, sha256, row_count),
        )
        batch_id = cur.fetchone()[0]
    conn.commit()
    return str(batch_id)


def register_raw_rows(
    cur,
    batch_id: str,
    sheet_name: str,
    records: list[dict],
    start_row_number: int,
    target_table: str,
    target_id_key: str,
    entity_kind: str,
) -> int:
    inserted = 0
    for offset, record in enumerate(records):
        source_row_number = record.get("__sheet_row_number", offset + 2)
        row_number = start_row_number + offset
        payload = clean_record(record)
        payload["_sheet"] = sheet_name
        payload["_sheet_row_number"] = source_row_number
        target_id = clean_value(record.get(target_id_key))

        cur.execute(
            """
            INSERT INTO import_raw_row (
                id_import_batch, row_number, raw_payload, normalized_payload,
                entity_kind, match_status, target_table, target_id
            ) VALUES (%s, %s, %s::jsonb, %s::jsonb, %s, 'IMPORTED', %s, %s)
            ON CONFLICT (id_import_batch, row_number) DO NOTHING
            """,
            (
                batch_id,
                row_number,
                json.dumps(payload, default=str, ensure_ascii=False),
                json.dumps(payload, default=str, ensure_ascii=False),
                entity_kind,
                target_table,
                target_id,
            ),
        )
        if cur.rowcount:
            inserted += 1
    return inserted


def register_review_items(
    cur,
    batch_id: str,
    table_name: str,
    target_id_key: str,
    records: list[dict],
    review_reason_key: str | None = None,
) -> int:
    inserted = 0
    for record in records:
        if clean_value(record.get("estado")) != "REVIEW_REQUIRED" and clean_value(record.get("estado_calidad")) != "NEEDS_REVIEW":
            continue

        target_id = clean_value(record.get(target_id_key))
        reason = clean_value(record.get(review_reason_key)) if review_reason_key else None
        if not reason:
            reason = f"{table_name} marcado para revision en archivo de migracion"

        cur.execute(
            """
            INSERT INTO import_review_item (
                id_import_raw_row, review_reason, severity, resolution_status
            )
            SELECT irr.id_import_raw_row, %s, 'MEDIUM', 'OPEN'
            FROM import_raw_row irr
            WHERE irr.id_import_batch = %s
              AND irr.target_table = %s
              AND irr.target_id = %s
            ON CONFLICT DO NOTHING
            """,
            (reason, batch_id, table_name, target_id),
        )
        inserted += cur.rowcount
    return inserted


def complete_batch(conn, batch_id: str, status: str = "COMPLETED"):
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE import_batch SET import_status = %s, finished_at = now() WHERE id_import_batch = %s",
            (status, batch_id),
        )
    conn.commit()
