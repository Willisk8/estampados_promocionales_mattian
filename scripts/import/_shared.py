"""
Utilidades compartidas para los scripts de importación.
"""
import hashlib
import json
import os
from datetime import datetime, date
from pathlib import Path


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


def complete_batch(conn, batch_id: str, status: str = "COMPLETED"):
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE import_batch SET import_status = %s, finished_at = now() WHERE id_import_batch = %s",
            (status, batch_id),
        )
    conn.commit()
