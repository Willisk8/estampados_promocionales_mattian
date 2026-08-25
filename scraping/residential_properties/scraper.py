#!/usr/bin/env python3
"""Consolida registros oficiales municipales de propiedad horizontal.

No certifica que una persona continúe ejerciendo la representación legal: el
resultado siempre conserva la fecha de actualización de cada fuente oficial.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = ROOT / "sources.json"
OUTPUT = ROOT / "outputs"
API_ROOT = "https://www.datos.gov.co"

ALIASES = {
    "property_name": (
        "nombre", "nombre_de_copropiedad", "nombre_de_la_copropiedad",
        "razon_social", "nombre_edificio_o_conjunto",
        "nombre_de_la_persona_juridica", "nombre_copropiedad",
        "propiedad_horizontal", "conjunto", "nombre_ph", "nombre_edificio",
        "nombre_propiedad_horizontal", "nombre_de_propiedad_horizontal",
        "nombre_de_la_propiedad", "nombre_de_la_propiedead",
        "propiedades_horizontales", "nombre_edif",
    ),
    "nit": ("nit",),
    "address": (
        "direccion", "direcci_n", "direccion_de_la_propiedad",
        "direccion_inmueble", "direccion_edif", "ubicaci_n",
    ),
    "neighborhood": ("barrio_vereda", "barrio", "localizacion", "localidad"),
    "property_type": ("tipo_inmueble", "tipo_de_propiedad", "vereda_barrio_conjunto"),
    "use": ("uso_inmueble",),
    "legal_representative": (
        "representante_legal", "nombre_del_representante",
        "administrador_y_o", "actual_administrador",
    ),
    "contact_person": ("nombre_persona_contacto",),
    "email": ("correo_electronico", "correo", "email", "email_edificio"),
    "phone": ("telefono", "tel_fono", "telefono_de_conjunto"),
    "source_record_id": (
        "id", "n", "n_reg", "num_registro", "no_exp", "personeria",
        "n_de_consecutivo", "item", "unnamed_column",
    ),
}

FIELDS = [
    "record_id", "property_name", "nit", "department", "municipality",
    "address", "neighborhood", "property_type", "use",
    "legal_representative", "contact_person", "email", "phone",
    "residential_classification",
    "representative_temporal_status", "source_data_updated_at", "fetched_at",
    "source_id", "source_name", "source_record_id", "source_url", "api_url",
]

MISSING_VALUES = {
    "", "-", "/", "n/a", "na", "no aplica", "sin dato", "sin datos",
    "no registra", "no registrado", "ninguno", "null", "s.i.", "s/d",
}
COMMERCIAL_RE = re.compile(
    r"\b(comercial|centro comercial|oficinas?|bodegas?|industrial|hotel|mall)\b",
    re.I,
)
RESIDENTIAL_RE = re.compile(r"\b(residencial|vivienda|habitacional)\b", re.I)
RESIDENTIAL_NAME_RE = re.compile(
    r"\b(conjunto|condominio|urbanizaci[oó]n|unidad residencial|"
    r"agrupaci[oó]n residencial|ciudadela)\b",
    re.I,
)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def clean(value: Any) -> str:
    if value is None:
        return ""
    text = re.sub(r"\s+", " ", str(value)).strip()
    return "" if text.casefold() in MISSING_VALUES else text


def ascii_key(value: Any) -> str:
    text = unicodedata.normalize("NFKD", clean(value))
    text = "".join(char for char in text if not unicodedata.combining(char))
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def normalize_nit(value: Any) -> str:
    return re.sub(r"\D", "", clean(value))


def normalize_email(value: Any) -> str:
    emails = re.findall(r"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}", clean(value), re.I)
    return "; ".join(dict.fromkeys(email.lower() for email in emails))


def normalize_phone(value: Any) -> str:
    raw = clean(value)
    if not raw:
        return ""
    candidates = re.findall(r"(?:\+?57\s*)?(?:\(?60[1-8]\)?\s*)?(?:3\d{9}|\d{7})(?:\s*(?:ext\.?|x)\s*\d+)?", raw, re.I)
    return "; ".join(dict.fromkeys(re.sub(r"\s+", " ", item).strip() for item in candidates))


def first(row: dict[str, Any], aliases: Iterable[str]) -> str:
    for alias in aliases:
        value = clean(row.get(alias))
        if value:
            return value
    return ""


def residential_classification(name: str, property_type: str, use: str) -> str:
    combined = " ".join((name, property_type, use))
    if COMMERCIAL_RE.search(combined) and not RESIDENTIAL_RE.search(combined):
        return "NO_RESIDENCIAL"
    if RESIDENTIAL_RE.search(" ".join((property_type, use))) or RESIDENTIAL_RE.search(name):
        return "RESIDENCIAL_CONFIRMADO"
    if RESIDENTIAL_NAME_RE.search(combined):
        return "RESIDENCIAL_PROBABLE"
    return "USO_NO_DETERMINADO"


def temporal_status(updated_at: str, representative: str) -> str:
    if not representative:
        return "SIN_REPRESENTANTE_EN_FUENTE"
    try:
        updated = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
    except ValueError:
        return "FECHA_FUENTE_DESCONOCIDA"
    age_days = (datetime.now(timezone.utc) - updated.astimezone(timezone.utc)).days
    return "FUENTE_RECIENTE_NO_CERTIFICADA" if age_days <= 365 else "REQUIERE_VALIDACION_ACTUAL"


def http_json(url: str, user_agent: str, timeout: int = 60) -> Any:
    request = Request(url, headers={"User-Agent": user_agent, "Accept": "application/json"})
    with urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def metadata_date(source_id: str, user_agent: str) -> str:
    metadata = http_json(f"{API_ROOT}/api/views/{source_id}", user_agent)
    timestamp = metadata.get("rowsUpdatedAt") or metadata.get("publicationDate")
    if isinstance(timestamp, (int, float)):
        return datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="seconds")
    return clean(timestamp)


def fetch_rows(source_id: str, user_agent: str, page_size: int) -> list[dict[str, Any]]:
    api_url = f"{API_ROOT}/resource/{source_id}.json"
    rows: list[dict[str, Any]] = []
    for offset in range(0, 1_000_000, page_size):
        query = urlencode({"$limit": page_size, "$offset": offset})
        page = http_json(f"{api_url}?{query}", user_agent, timeout=90)
        if not isinstance(page, list):
            raise ValueError("La API no devolvió una lista")
        rows.extend(page)
        if len(page) < page_size:
            break
    return rows


def fetch_csv_rows(source: dict[str, str], user_agent: str) -> list[dict[str, Any]]:
    request = Request(source["data_url"], headers={"User-Agent": user_agent, "Accept": "text/csv"})
    with urlopen(request, timeout=90) as response:
        body = response.read()
    try:
        text = body.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = body.decode("latin-1")
    return list(csv.DictReader(text.splitlines(), delimiter=source.get("delimiter", ",")))


def normalize_row(
    row: dict[str, Any], source: dict[str, str], updated_at: str, fetched_at: str
) -> dict[str, str]:
    normalized = {ascii_key(key): value for key, value in row.items()}
    values = {field: first(normalized, aliases) for field, aliases in ALIASES.items()}
    values["nit"] = normalize_nit(values["nit"])
    values["email"] = normalize_email(values["email"])
    values["phone"] = normalize_phone(values["phone"])
    classification = residential_classification(
        values["property_name"], values["property_type"], values["use"]
    )
    identity = "|".join((
        source["id"], source["municipality"], values["property_name"], values["address"],
        values["nit"], values["source_record_id"],
    ))
    api_url = source.get("data_url", f"{API_ROOT}/resource/{source['id']}.json")
    return {
        "record_id": hashlib.sha256(ascii_key(identity).encode()).hexdigest()[:24],
        "property_name": values["property_name"],
        "nit": values["nit"],
        "department": source["department"],
        "municipality": source["municipality"],
        "address": values["address"],
        "neighborhood": values["neighborhood"],
        "property_type": values["property_type"],
        "use": values["use"],
        "legal_representative": values["legal_representative"],
        "contact_person": values["contact_person"],
        "email": values["email"],
        "phone": values["phone"],
        "residential_classification": classification,
        "representative_temporal_status": temporal_status(updated_at, values["legal_representative"]),
        "source_data_updated_at": updated_at,
        "fetched_at": fetched_at,
        "source_id": source["id"],
        "source_name": source["name"],
        "source_record_id": values["source_record_id"],
        "source_url": source.get("source_url", f"{API_ROOT}/d/{source['id']}"),
        "api_url": api_url,
    }


def load_sources(path: Path, selected: set[str] | None) -> list[dict[str, str]]:
    sources = json.loads(path.read_text(encoding="utf-8"))["sources"]
    if selected:
        unknown = selected - {source["id"] for source in sources}
        if unknown:
            raise SystemExit(f"Fuentes desconocidas: {', '.join(sorted(unknown))}")
        sources = [source for source in sources if source["id"] in selected]
    return sources


def source_row_allowed(row: dict[str, Any], source: dict[str, Any]) -> bool:
    normalized = {ascii_key(key): clean(value) for key, value in row.items()}
    return all(
        normalized.get(ascii_key(field), "").casefold() == clean(expected).casefold()
        for field, expected in source.get("filters", {}).items()
    )


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def deduplicate(rows: list[dict[str, str]]) -> tuple[list[dict[str, str]], int]:
    """Conserva la versión más completa de duplicados exactos de identidad."""
    best: dict[str, dict[str, str]] = {}
    for row in rows:
        current = best.get(row["record_id"])
        if current is None:
            best[row["record_id"]] = row
            continue
        useful_fields = (
            "property_name", "nit", "address", "neighborhood", "property_type",
            "use", "legal_representative", "contact_person", "email", "phone",
            "source_record_id",
        )
        if sum(bool(row[field]) for field in useful_fields) > sum(bool(current[field]) for field in useful_fields):
            best[row["record_id"]] = row
    return list(best.values()), len(rows) - len(best)


def run(args: argparse.Namespace) -> None:
    selected = set(filter(None, (args.sources or "").split(","))) or None
    sources = load_sources(args.config, selected)
    fetched_at = now_iso()
    records: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    coverage: list[dict[str, Any]] = []

    for source in sources:
        print(f"[{source['id']}] {source['municipality']}")
        try:
            if source.get("type", "socrata") == "csv":
                updated_at = source["source_data_updated_at"]
                source_rows = fetch_csv_rows(source, args.user_agent)
            else:
                updated_at = metadata_date(source["id"], args.user_agent)
                source_rows = fetch_rows(source["id"], args.user_agent, args.page_size)
            source_rows = [row for row in source_rows if source_row_allowed(row, source)]
            normalized = [normalize_row(row, source, updated_at, fetched_at) for row in source_rows]
            normalized = [row for row in normalized if row["property_name"]]
            records.extend(normalized)
            coverage.append({
                "source_id": source["id"], "municipality": source["municipality"],
                "rows": len(normalized), "source_data_updated_at": updated_at,
                "with_representative": sum(bool(row["legal_representative"]) for row in normalized),
                "with_email": sum(bool(row["email"]) for row in normalized),
                "with_phone": sum(bool(row["phone"]) for row in normalized),
            })
            print(f"  {len(normalized):,} registros")
        except (HTTPError, URLError, TimeoutError, ValueError, json.JSONDecodeError) as exc:
            errors.append({"source_id": source["id"], "municipality": source["municipality"], "error": str(exc)})
            print(f"  ERROR: {exc}")

    raw_record_count = len(records)
    records, duplicates_removed = deduplicate(records)
    records.sort(key=lambda row: (ascii_key(row["department"]), ascii_key(row["municipality"]), ascii_key(row["property_name"])))
    residential = [row for row in records if row["residential_classification"] in {"RESIDENCIAL_CONFIRMADO", "RESIDENCIAL_PROBABLE"}]
    id_counts = Counter(row["record_id"] for row in records)
    duplicate_ids = {record_id for record_id, count in id_counts.items() if count > 1}
    if duplicate_ids:
        raise SystemExit(f"Se detectaron {len(duplicate_ids)} identificadores duplicados")

    OUTPUT.mkdir(parents=True, exist_ok=True)
    write_csv(OUTPUT / "propiedades_horizontales_colombia.csv", records)
    write_csv(OUTPUT / "conjuntos_residenciales_colombia.csv", residential)
    with (OUTPUT / "propiedades_horizontales_colombia.jsonl").open("w", encoding="utf-8") as handle:
        for row in records:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    (OUTPUT / "resumen.json").write_text(json.dumps({
        "generated_at": fetched_at,
        "scope": "Fuentes municipales publicadas; no es un registro nacional exhaustivo",
        "raw_record_count": raw_record_count,
        "duplicate_rows_removed": duplicates_removed,
        "total_records": len(records),
        "residential_records": len(residential),
        "with_legal_representative": sum(bool(row["legal_representative"]) for row in records),
        "with_email": sum(bool(row["email"]) for row in records),
        "with_phone": sum(bool(row["phone"]) for row in records),
        "coverage": coverage,
        "errors": errors,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    with (OUTPUT / "errores.csv").open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["source_id", "municipality", "error"])
        writer.writeheader()
        writer.writerows(errors)
    print(f"Total PH: {len(records):,}; conjuntos residenciales probables/confirmados: {len(residential):,}")


def verify(_: argparse.Namespace) -> None:
    path = OUTPUT / "propiedades_horizontales_colombia.csv"
    if not path.exists():
        raise SystemExit("Falta la salida. Ejecute primero: python scraper.py run")
    with path.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    assert rows, "La salida está vacía"
    assert set(FIELDS) == set(rows[0]), "El esquema CSV no coincide"
    assert all(row["property_name"] for row in rows), "Hay registros sin nombre"
    assert len({row["record_id"] for row in rows}) == len(rows), "Hay record_id duplicados"
    assert all(row["source_url"].startswith("https://") for row in rows)
    print(f"Verificación correcta: {len(rows):,} registros auditables")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Scraper de propiedad horizontal en Colombia")
    sub = result.add_subparsers(dest="command", required=True)
    run_parser = sub.add_parser("run", help="Descargar, normalizar y consolidar")
    run_parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    run_parser.add_argument("--sources", help="IDs Socrata separados por coma")
    run_parser.add_argument("--page-size", type=int, default=5000)
    run_parser.add_argument("--user-agent", default="EstampadosData/1.0 (contacto pendiente)")
    run_parser.set_defaults(function=run)
    verify_parser = sub.add_parser("verify", help="Validar la última salida")
    verify_parser.set_defaults(function=verify)
    return result


if __name__ == "__main__":
    args = parser().parse_args()
    args.function(args)
