#!/usr/bin/env python3
"""Audita cobertura municipal de propiedad horizontal con DIVIPOLA y SUIT."""

from __future__ import annotations

import argparse
import csv
import json
import re
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "outputs"
SOURCES = ROOT / "sources.json"
DIVIPOLA_API = "https://www.datos.gov.co/resource/gdxc-w37w.json"
SUIT_API = "https://www.datos.gov.co/resource/mntw-htj4.json"


def clean(value: Any) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    return "" if text.upper() in {"NULL", "N/A", "NA"} else text


def key(value: Any) -> str:
    text = unicodedata.normalize("NFKD", clean(value))
    text = "".join(char for char in text if not unicodedata.combining(char))
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def http_json(url: str, user_agent: str) -> Any:
    request = Request(url, headers={"User-Agent": user_agent, "Accept": "application/json"})
    with urlopen(request, timeout=90) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_all(api: str, user_agent: str, query: str | None = None) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    page_size = 5000
    for offset in range(0, 100_000, page_size):
        params: dict[str, Any] = {"$limit": page_size, "$offset": offset}
        if query:
            params["$q"] = query
        page = http_json(api + "?" + urlencode(params), user_agent)
        result.extend(page)
        if len(page) < page_size:
            break
    return result


def is_registry_procedure(row: dict[str, Any]) -> bool:
    text = key(" ".join((
        clean(row.get("nombre_del_tr_mite_u_otro")),
        clean(row.get("nombre_com_n")),
        clean(row.get("prop_sito_del_tr_mite_u_otro")),
    )))
    return "propiedad horizontal" in text and any(token in text for token in (
        "inscripcion", "representacion legal", "representante legal", "certificacion",
        "extincion", "registro de la propiedad horizontal",
    ))


def join_key(department: str, municipality: str) -> tuple[str, str]:
    dept = key(department).replace("bogota d c", "bogota")
    muni = key(municipality).replace("bogota d c", "bogota")
    muni = {"el espinal": "espinal"}.get(muni, muni)
    return dept, muni


def write_csv(path: Path, rows: list[dict[str, Any]], fields: list[str]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def run(args: argparse.Namespace) -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    divipola = fetch_all(DIVIPOLA_API, args.user_agent)
    suit_raw = fetch_all(SUIT_API, args.user_agent, "propiedad horizontal")
    suit = [row for row in suit_raw if is_registry_procedure(row)]

    source_config = json.loads(SOURCES.read_text(encoding="utf-8"))["sources"]
    base_path = OUTPUT / "propiedades_horizontales_colombia.csv"
    counts: dict[tuple[str, str], int] = defaultdict(int)
    if base_path.exists():
        with base_path.open(encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                counts[join_key(row["department"], row["municipality"])] += 1

    source_by_place: dict[tuple[str, str], list[str]] = defaultdict(list)
    for source in source_config:
        source_by_place[join_key(source["department"], source["municipality"])].append(source["id"])

    suit_by_place: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in suit:
        suit_by_place[join_key(clean(row.get("departamento")), clean(row.get("municipio")))].append(row)

    coverage: list[dict[str, Any]] = []
    for territory in divipola:
        place = join_key(clean(territory.get("dpto")), clean(territory.get("nom_mpio")))
        procedures = suit_by_place.get(place, [])
        online_urls = sorted({clean(row.get("url_tramite_en_l_nea")) for row in procedures if clean(row.get("url_tramite_en_l_nea"))})
        viewers = sorted({clean(row.get("url_del_visor_del_tr_mite")) for row in procedures if clean(row.get("url_del_visor_del_tr_mite"))})
        source_ids = source_by_place.get(place, [])
        record_count = counts.get(place, 0)
        if record_count:
            status = "BASE_ABIERTA_INTEGRADA"
        elif procedures:
            status = "TRAMITE_LOCAL_SIN_BASE_ABIERTA_LOCALIZADA"
        else:
            status = "SIN_FUENTE_NI_TRAMITE_LOCALIZADO"
        coverage.append({
            "divipola": clean(territory.get("cod_mpio")),
            "department": clean(territory.get("dpto")),
            "municipality": clean(territory.get("nom_mpio")),
            "territory_type": clean(territory.get("tipo_municipio")),
            "coverage_status": status,
            "records_in_base": record_count,
            "source_ids": "; ".join(source_ids),
            "registry_procedure_count": len(procedures),
            "online_procedure_urls": "; ".join(online_urls),
            "suit_viewer_urls": "; ".join(viewers),
        })

    procedure_rows = [{
        "department": clean(row.get("departamento")),
        "municipality": clean(row.get("municipio")),
        "entity": clean(row.get("nombre_de_la_entidad")),
        "procedure": clean(row.get("nombre_del_tr_mite_u_otro")),
        "common_name": clean(row.get("nombre_com_n")),
        "last_updated": clean(row.get("fecha_actualizaci_n")),
        "channel": clean(row.get("medio_por_donde_se_realiza")),
        "online_url": clean(row.get("url_tramite_en_l_nea")),
        "result_url": clean(row.get("url_resultado_web")),
        "suit_viewer_url": clean(row.get("url_del_visor_del_tr_mite")),
    } for row in suit]

    coverage.sort(key=lambda row: (key(row["department"]), key(row["municipality"])))
    procedure_rows.sort(key=lambda row: (key(row["department"]), key(row["municipality"]), key(row["procedure"])))
    coverage_fields = [
        "divipola", "department", "municipality", "territory_type", "coverage_status",
        "records_in_base", "source_ids", "registry_procedure_count",
        "online_procedure_urls", "suit_viewer_urls",
    ]
    procedure_fields = [
        "department", "municipality", "entity", "procedure", "common_name",
        "last_updated", "channel", "online_url", "result_url", "suit_viewer_url",
    ]
    write_csv(OUTPUT / "cobertura_municipios_colombia.csv", coverage, coverage_fields)
    write_csv(OUTPUT / "tramites_alcaldias_propiedad_horizontal.csv", procedure_rows, procedure_fields)
    pending = [row for row in coverage if row["coverage_status"] != "BASE_ABIERTA_INTEGRADA"]
    write_csv(OUTPUT / "municipios_pendientes_fuente_abierta.csv", pending, coverage_fields)

    coverage_by_place = {
        join_key(row["department"], row["municipality"]): row for row in coverage
    }
    validation_queue: list[dict[str, Any]] = []
    residential_path = OUTPUT / "conjuntos_residenciales_colombia.csv"
    if residential_path.exists():
        with residential_path.open(encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                territory = coverage_by_place.get(join_key(row["department"], row["municipality"]), {})
                gaps = []
                if not clean(row.get("legal_representative")):
                    gaps.append("representante_legal")
                elif clean(row.get("representative_temporal_status")) != "FUENTE_RECIENTE_NO_CERTIFICADA":
                    gaps.append("vigencia_representante")
                if not clean(row.get("email")):
                    gaps.append("correo")
                if not clean(row.get("phone")):
                    gaps.append("telefono_whatsapp")
                validation_queue.append({
                    "record_id": row["record_id"],
                    "department": row["department"],
                    "municipality": row["municipality"],
                    "property_name": row["property_name"],
                    "nit": row["nit"],
                    "address": row["address"],
                    "legal_representative_at_source_date": row["legal_representative"],
                    "representative_temporal_status": row["representative_temporal_status"],
                    "email_at_source": row["email"],
                    "phone_at_source": row["phone"],
                    "missing_or_pending_fields": "; ".join(gaps),
                    "municipality_coverage_status": territory.get("coverage_status", ""),
                    "suit_viewer_urls": territory.get("suit_viewer_urls", ""),
                    "recommended_action": "Consultar certificado/registro vigente ante la alcaldía y solicitar únicamente contactos institucionales públicos",
                })
    validation_queue.sort(key=lambda row: (
        0 if "vigencia_representante" in row["missing_or_pending_fields"] else 1,
        0 if "representante_legal" in row["missing_or_pending_fields"] else 1,
        key(row["department"]), key(row["municipality"]), key(row["property_name"]),
    ))
    validation_fields = [
        "record_id", "department", "municipality", "property_name", "nit", "address",
        "legal_representative_at_source_date", "representative_temporal_status",
        "email_at_source", "phone_at_source", "missing_or_pending_fields",
        "municipality_coverage_status", "suit_viewer_urls", "recommended_action",
    ]
    write_csv(OUTPUT / "cola_validacion_conjuntos.csv", validation_queue, validation_fields)
    summary = {
        "territories": len(coverage),
        "territories_with_open_data": sum(row["coverage_status"] == "BASE_ABIERTA_INTEGRADA" for row in coverage),
        "territories_with_registry_procedure_only": sum(row["coverage_status"] == "TRAMITE_LOCAL_SIN_BASE_ABIERTA_LOCALIZADA" for row in coverage),
        "territories_without_located_source": sum(row["coverage_status"] == "SIN_FUENTE_NI_TRAMITE_LOCALIZADO" for row in coverage),
        "registry_procedures": len(procedure_rows),
        "residential_records_in_validation_queue": len(validation_queue),
        "note": "SUIT es un inventario de trámites, no una base de copropiedades ni prueba de vigencia actual.",
    }
    (OUTPUT / "resumen_cobertura_municipal.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Cobertura municipal de propiedad horizontal")
    parser.add_argument("--user-agent", default="EstampadosData/1.0 (contacto pendiente)")
    run(parser.parse_args())
