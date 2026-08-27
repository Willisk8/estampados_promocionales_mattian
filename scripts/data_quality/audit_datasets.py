"""Audita y genera copias normalizadas de las bases operativas de Estampados.

Los archivos fuente nunca se sobrescriben. Las salidas incluyen columnas de
calidad y un registro consolidado de incidencias para revision humana.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
from dataclasses import asdict
from datetime import date
import difflib
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.data_quality.normalization import (  # noqa: E402
    extract_colombian_phones,
    extract_emails,
    fixed_area_code_for_department,
    normalize_decimal,
    normalize_iso_datetime,
    normalize_nit,
    normalize_text,
    normalize_url,
    repair_reversible_mojibake,
    search_key,
)


DEFAULT_OUTPUT = ROOT / "outputs" / f"data_quality_{date.today():%Y%m%d}"
DIVIPOLA_PATH = ROOT / "scraping" / "residential_properties" / "outputs" / "cobertura_municipios_colombia.csv"

DATASETS = {
    "fondos_empleados": ROOT / "scraping" / "data" / "web" / "base_consolidada_contactos.csv",
    "productos_promocionales": ROOT / "scraping" / "promotional_products" / "outputs" / "catalogo_promocionales_colombia.csv",
    "catalogo_tecnicas": ROOT / "scraping" / "personalization_techniques" / "outputs" / "01a0394c-b6b4-7d11-bb54-d4001c6bd0fb" / "catalogo_tecnicas.csv",
    "precios_tecnicas": ROOT / "scraping" / "personalization_techniques" / "outputs" / "01a0394c-b6b4-7d11-bb54-d4001c6bd0fb" / "precios_tecnicas_personalizacion.csv",
    "conjuntos_residenciales": ROOT / "scraping" / "residential_properties" / "outputs" / "enrichment" / "conjuntos_residenciales_enriquecidos.csv",
}

STANDARD_SOURCES = {
    "unicode_nfc": "https://www.unicode.org/reports/tr15/",
    "divipola": "https://www.dane.gov.co/index.php/sistema-estadistico-nacional-sen/normas-y-estandares/nomenclaturas-y-clasificaciones/nomenclaturas/codificacion-de-la-division-politico-administrativa-de-colombia-divipola",
    "telefonia_crc": "https://normograma.crcom.gov.co/crc/compilacion/docs/circular_crc_0127_2020.htm",
    "nit_dian": "https://normograma.dian.gov.co/dian/compilacion/docs/resolucion_dian_0004_2019.htm",
    "email_rfc5321": "https://www.rfc-editor.org/info/rfc5321/",
    "fecha_iso8601": "https://www.iso.org/iso-8601-date-and-time-format.html",
    "gtin_gs1": "https://gs1co.org/soluciones/identificacion/numeros-globales-de-identificacion-de-productos-gtin",
    "unspsc_colombia": "https://operaciones.colombiacompra.gov.co/clasificador-de-bienes-y-Servicios",
}


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields: list[str] = []
    for row in rows:
        for key in row:
            if key not in fields:
                fields.append(key)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


class Issues:
    def __init__(self) -> None:
        self.rows: list[dict[str, str]] = []
        self.by_record: dict[tuple[str, str], set[str]] = defaultdict(set)
        self.count_by_record: Counter[tuple[str, str]] = Counter()

    def add(
        self,
        dataset: str,
        record_id: str,
        field: str,
        code: str,
        severity: str,
        raw_value: object = "",
        normalized_value: object = "",
        message: str = "",
    ) -> None:
        self.rows.append({
            "dataset": dataset,
            "record_id": record_id,
            "field": field,
            "code": code,
            "severity": severity,
            "raw_value": normalize_text(raw_value),
            "normalized_value": normalize_text(normalized_value),
            "message": message,
        })
        self.by_record[(dataset, record_id)].add(severity)
        self.count_by_record[(dataset, record_id)] += 1

    def status(self, dataset: str, record_id: str) -> str:
        levels = self.by_record.get((dataset, record_id), set())
        if "ERROR" in levels:
            return "INVALID"
        if "REVIEW" in levels:
            return "REVIEW_REQUIRED"
        return "VALID"


class DivipolaMatcher:
    def __init__(self, path: Path) -> None:
        rows = read_csv(path)
        self.rows = rows
        self.exact = {
            (search_key(row["department"]), search_key(row["municipality"])): row
            for row in rows
        }
        self.department_names: dict[str, str] = {}
        self.by_department: dict[str, list[dict[str, str]]] = defaultdict(list)
        for row in rows:
            dep_key = search_key(row["department"])
            self.department_names[dep_key] = row["department"]
            self.by_department[dep_key].append(row)

    @staticmethod
    def _degraded_key(value: str) -> str:
        return search_key(value.replace("\ufffd", ""))

    @staticmethod
    def _ratio(left: str, right: str) -> float:
        return difflib.SequenceMatcher(None, left, right).ratio()

    def match(self, department: object, municipality: object) -> tuple[str, str, str, str]:
        dep = normalize_text(department)
        mun = normalize_text(municipality)
        exact = self.exact.get((search_key(dep), search_key(mun)))
        if exact:
            return exact["department"], exact["municipality"], exact["divipola"], "EXACT"

        dep_key = self._degraded_key(dep)
        dep_candidates = sorted(
            self.department_names,
            key=lambda key: self._ratio(dep_key, key),
            reverse=True,
        )
        if not dep_candidates or self._ratio(dep_key, dep_candidates[0]) < 0.82:
            return dep, mun, "", "NOT_FOUND"
        best_dep = dep_candidates[0]
        mun_key = self._degraded_key(mun)
        candidates = sorted(
            self.by_department[best_dep],
            key=lambda row: self._ratio(mun_key, search_key(row["municipality"])),
            reverse=True,
        )
        if not candidates or self._ratio(mun_key, search_key(candidates[0]["municipality"])) < 0.82:
            return self.department_names[best_dep], mun, "", "DEPARTMENT_ONLY"
        best = candidates[0]
        return best["department"], best["municipality"], best["divipola"], "FUZZY_REVIEW"


def clean_all_text(row: dict[str, str], dataset: str, record_id: str, issues: Issues) -> dict[str, str]:
    cleaned: dict[str, str] = {}
    for field, raw in row.items():
        value, repaired = repair_reversible_mojibake(raw)
        cleaned[field] = value
        if repaired:
            issues.add(dataset, record_id, field, "MOJIBAKE_REPAIRED", "REVIEW", raw, value,
                       "Reparacion reversible latin-1/UTF-8; verificar contra la fuente.")
        if "\ufffd" in value:
            issues.add(dataset, record_id, field, "UNICODE_REPLACEMENT_CHAR", "REVIEW", raw, value,
                       "El caracter original ya se perdio; se requiere recargar la fuente.")
    return cleaned


def add_location(
    row: dict[str, str], dataset: str, record_id: str, issues: Issues,
    matcher: DivipolaMatcher, department_field: str, municipality_field: str,
) -> None:
    department, municipality, divipola, status = matcher.match(
        row.get(department_field, ""), row.get(municipality_field, "")
    )
    row["departamento_normalizado"] = department
    row["municipio_normalizado"] = municipality
    row["codigo_divipola"] = divipola
    row["divipola_match_status"] = status
    if status != "EXACT":
        severity = "REVIEW" if status in {"FUZZY_REVIEW", "DEPARTMENT_ONLY"} else "ERROR"
        issues.add(dataset, record_id, f"{department_field}/{municipality_field}",
                   "DIVIPOLA_" + status, severity,
                   f"{row.get(department_field, '')} / {row.get(municipality_field, '')}",
                   f"{department} / {municipality} / {divipola}",
                   "La ubicacion debe confirmarse contra DIVIPOLA.")


def add_nit(row: dict[str, str], dataset: str, record_id: str, field: str, issues: Issues) -> None:
    result = normalize_nit(row.get(field, ""))
    row["nit_normalizado"] = result.base
    row["nit_dv"] = result.verification_digit
    row["nit_dv_valido"] = "" if result.verification_valid is None else str(result.verification_valid).lower()
    row["nit_status"] = result.status
    if result.status in {"INVALID", "REVIEW"}:
        issues.add(dataset, record_id, field, result.issue, "ERROR" if result.status == "INVALID" else "REVIEW",
                   result.raw, result.base, "El DV se conserva separado del NIT base.")


def add_contacts(
    row: dict[str, str], dataset: str, record_id: str, issues: Issues,
    email_fields: list[str], phone_fields: list[str], fixed_area_code: str = "",
) -> None:
    emails: list[str] = []
    for field in email_fields:
        found, invalid = extract_emails(row.get(field, ""))
        for value in found:
            if value not in emails:
                emails.append(value)
        for value in invalid:
            issues.add(dataset, record_id, field, "INVALID_EMAIL_FORMAT", "ERROR", value, "",
                       "No se usara automaticamente como canal de contacto.")
    row["emails_normalizados"] = "; ".join(emails)

    phones: list[str] = []
    classifications: list[str] = []
    seen_phone_issues: set[tuple[str, str]] = set()
    for field in phone_fields:
        for result in extract_colombian_phones(row.get(field, "")):
            value = result.national_number
            classification = result.classification
            status = result.status
            issue_code = result.issue
            if classification == "FIJO_LOCAL_SIN_INDICATIVO" and fixed_area_code:
                value = fixed_area_code + result.local_number
                classification = "FIJO"
                status = "REVIEW"
                issue_code = "AREA_CODE_INFERRED_FROM_DIVIPOLA"
            if value and value not in phones:
                phones.append(value)
                classifications.append(classification)
            issue_key = (issue_code, result.raw)
            if status in {"INVALID", "REVIEW"} and issue_key not in seen_phone_issues:
                seen_phone_issues.add(issue_key)
                issues.add(dataset, record_id, field, issue_code, "ERROR" if status == "INVALID" else "REVIEW",
                           result.raw, value, classification)
    row["telefonos_normalizados"] = "; ".join(phones)
    row["telefonos_clasificacion"] = "; ".join(classifications)


def add_timestamp(row: dict[str, str], dataset: str, record_id: str, field: str, issues: Issues) -> None:
    normalized, status = normalize_iso_datetime(row.get(field, ""))
    row[field + "_normalizado"] = normalized
    if status not in {"VALID", "EMPTY"}:
        issues.add(dataset, record_id, field, "DATETIME_" + status, "REVIEW",
                   row.get(field, ""), normalized, "Usar ISO 8601/RFC 3339 con zona horaria.")


def finish_status(row: dict[str, str], dataset: str, record_id: str, issues: Issues) -> None:
    row["data_quality_status"] = issues.status(dataset, record_id)
    row["data_quality_issue_count"] = str(issues.count_by_record[(dataset, record_id)])


def normalize_funds(rows: list[dict[str, str]], matcher: DivipolaMatcher, issues: Issues) -> list[dict[str, str]]:
    dataset = "fondos_empleados"
    output = []
    for index, source in enumerate(rows, 2):
        record_id = normalize_text(source.get("nit")) or f"row-{index}"
        row = clean_all_text(source, dataset, record_id, issues)
        row["nombre_busqueda"] = search_key(row.get("nombre_entidad"))
        add_nit(row, dataset, record_id, "nit", issues)
        add_location(row, dataset, record_id, issues, matcher, "departamento", "municipio")
        add_contacts(
            row, dataset, record_id, issues,
            ["correo_preferido", "correos_sitio_oficial", "correo_registro_oficial"],
            ["telefono_preferido", "telefonos_sitio_oficial", "telefono_registro_oficial", "whatsapp_publico"],
            fixed_area_code_for_department(row.get("departamento_normalizado")),
        )
        for field in ("fecha_consulta_web", "fecha_reporte_oficial"):
            add_timestamp(row, dataset, record_id, field, issues)
        finish_status(row, dataset, record_id, issues)
        output.append(row)
    return output


def normalize_products(rows: list[dict[str, str]], matcher: DivipolaMatcher, issues: Issues) -> list[dict[str, str]]:
    dataset = "productos_promocionales"
    output = []
    seen_keys: set[str] = set()
    for index, source in enumerate(rows, 2):
        record_id = normalize_text(source.get("product_id") or source.get("sku") or source.get("product_url")) or f"row-{index}"
        row = clean_all_text(source, dataset, record_id, issues)
        row["nombre_busqueda"] = search_key(row.get("name"))
        row["proveedor_busqueda"] = search_key(row.get("supplier"))
        row["country_code"] = "CO" if search_key(row.get("country")) == "colombia" else ""
        if not row.get("department") and search_key(row.get("city")) in {"colombia", "nacional"}:
            row["departamento_normalizado"] = ""
            row["municipio_normalizado"] = ""
            row["codigo_divipola"] = ""
            row["divipola_match_status"] = "NATIONAL_SCOPE"
        else:
            add_location(row, dataset, record_id, issues, matcher, "department", "city")
        for field in ("price_min", "price_max", "minimum_order"):
            normalized, status = normalize_decimal(row.get(field, ""))
            row[field + "_normalizado"] = normalized
            if status == "INVALID_FORMAT":
                issues.add(dataset, record_id, field, "INVALID_DECIMAL", "ERROR", row.get(field, ""), normalized)
        row["currency"] = row.get("currency", "").upper()
        if row["currency"] not in {"", "COP"}:
            issues.add(dataset, record_id, "currency", "UNEXPECTED_CURRENCY", "REVIEW", row["currency"], row["currency"])
        for field in ("product_url", "source_page", "image_url"):
            normalized, status = normalize_url(row.get(field, ""))
            row[field + "_normalizado"] = normalized
            if status == "INVALID_FORMAT":
                issues.add(dataset, record_id, field, "INVALID_URL", "ERROR", row.get(field, ""), normalized)
        add_timestamp(row, dataset, record_id, "fetched_at", issues)
        unique_key = "|".join(filter(None, [
            row.get("source_id", ""), row.get("sku", ""), row.get("product_id", ""),
            row.get("product_url_normalizado", ""), row.get("nombre_busqueda", ""),
        ]))
        row["product_identity_key"] = unique_key
        if unique_key in seen_keys:
            issues.add(dataset, record_id, "product_identity_key", "DUPLICATE_PRODUCT_KEY", "ERROR", unique_key, unique_key)
        seen_keys.add(unique_key)
        finish_status(row, dataset, record_id, issues)
        output.append(row)
    return output


def normalize_technique_rows(
    rows: list[dict[str, str]], dataset: str, issues: Issues,
) -> list[dict[str, str]]:
    output = []
    seen: set[str] = set()
    for index, source in enumerate(rows, 2):
        record_id = normalize_text(source.get("observation_id") or source.get("technique")) or f"row-{index}"
        row = clean_all_text(source, dataset, record_id, issues)
        row["technique"] = search_key(row.get("technique"))
        row["technique_label"] = normalize_text(source.get("technique")).replace("_", " ")
        if not row["technique"]:
            issues.add(dataset, record_id, "technique", "MISSING_TECHNIQUE", "ERROR")
        identity = row.get("observation_id") or row["technique"]
        if identity in seen:
            issues.add(dataset, record_id, "observation_id", "DUPLICATE_TECHNIQUE_ID", "ERROR", identity, identity)
        seen.add(identity)
        for field in ("price_value", "price_min", "price_max", "width_cm", "height_cm", "quantity_min", "quantity_max"):
            if field in row:
                normalized, status = normalize_decimal(row.get(field, ""))
                row[field + "_normalizado"] = normalized
                if status == "INVALID_FORMAT":
                    issues.add(dataset, record_id, field, "INVALID_DECIMAL", "ERROR", row.get(field, ""), normalized)
        if "currency" in row:
            row["currency"] = row.get("currency", "").upper()
        if "source_url" in row:
            normalized, status = normalize_url(row.get("source_url"))
            row["source_url_normalizado"] = normalized
            if status == "INVALID_FORMAT":
                issues.add(dataset, record_id, "source_url", "INVALID_URL", "ERROR", row.get("source_url"), normalized)
        if "fetched_at" in row:
            add_timestamp(row, dataset, record_id, "fetched_at", issues)
        finish_status(row, dataset, record_id, issues)
        output.append(row)
    return output


def normalize_residential(rows: list[dict[str, str]], matcher: DivipolaMatcher, issues: Issues) -> list[dict[str, str]]:
    dataset = "conjuntos_residenciales"
    output = []
    seen: set[str] = set()
    for index, source in enumerate(rows, 2):
        record_id = normalize_text(source.get("record_id")) or f"row-{index}"
        row = clean_all_text(source, dataset, record_id, issues)
        row["nombre_busqueda"] = search_key(row.get("property_name"))
        if record_id in seen:
            issues.add(dataset, record_id, "record_id", "DUPLICATE_RECORD_ID", "ERROR", record_id, record_id)
        seen.add(record_id)
        add_nit(row, dataset, record_id, "nit", issues)
        add_location(row, dataset, record_id, issues, matcher, "department", "municipality")
        add_contacts(
            row, dataset, record_id, issues,
            ["email", "email_preferred", "emails_public_web"],
            ["phone", "phone_preferred", "phones_public_web", "whatsapp_public"],
            fixed_area_code_for_department(row.get("departamento_normalizado")),
        )
        for field in ("source_data_updated_at", "fetched_at", "web_fetched_at"):
            add_timestamp(row, dataset, record_id, field, issues)
        # contact_person nunca se convierte automaticamente en representante legal.
        if row.get("contact_person") and not row.get("legal_representative"):
            row["contact_role_status"] = "CONTACT_PERSON_ONLY"
        else:
            row["contact_role_status"] = "SEPARATE_ROLES_PRESERVED"
        finish_status(row, dataset, record_id, issues)
        output.append(row)
    return output


def build_suppliers(products: list[dict[str, str]], prices: list[dict[str, str]], issues: Issues) -> list[dict[str, str]]:
    grouped: dict[str, dict[str, set[str]]] = {}
    sources = [("productos_promocionales", products), ("precios_tecnicas", prices)]
    for dataset, rows in sources:
        for row in rows:
            supplier = normalize_text(row.get("supplier"))
            key = search_key(supplier)
            if not key:
                continue
            item = grouped.setdefault(key, {"names": set(), "cities": set(), "departments": set(), "urls": set(), "datasets": set()})
            item["names"].add(supplier)
            item["cities"].add(normalize_text(row.get("city")))
            item["departments"].add(normalize_text(row.get("department") or row.get("departamento_normalizado")))
            for field in ("product_url_normalizado", "source_url_normalizado", "source_page_normalizado"):
                url = normalize_text(row.get(field))
                if url:
                    item["urls"].add(url)
            item["datasets"].add(dataset)

    output = []
    for key, item in sorted(grouped.items()):
        names = sorted(value for value in item["names"] if value)
        record_id = key
        row = {
            "supplier_key": key,
            "supplier_name": names[0] if names else key,
            "supplier_name_variants": "; ".join(names),
            "cities": "; ".join(sorted(value for value in item["cities"] if value)),
            "departments": "; ".join(sorted(value for value in item["departments"] if value)),
            "source_urls": "; ".join(sorted(item["urls"])),
            "source_datasets": "; ".join(sorted(item["datasets"])),
            "nit_normalizado": "",
            "nit_dv": "",
        }
        issues.add("proveedores", record_id, "nit_normalizado", "SUPPLIER_NIT_MISSING", "REVIEW", "", "",
                   "Completar con RUT/RUES antes de usar el proveedor como entidad fiscal.")
        finish_status(row, "proveedores", record_id, issues)
        output.append(row)
    return output


def summarize(outputs: dict[str, list[dict[str, str]]], issues: Issues) -> dict[str, object]:
    datasets = {}
    for name, rows in outputs.items():
        statuses = Counter(row.get("data_quality_status", "") for row in rows)
        datasets[name] = {"rows": len(rows), "statuses": dict(statuses)}
    return {
        "generated_at": date.today().isoformat(),
        "source_files_are_immutable": True,
        "datasets": datasets,
        "issue_count": len(issues.rows),
        "issues_by_code": dict(Counter(row["code"] for row in issues.rows).most_common()),
        "issues_by_severity": dict(Counter(row["severity"] for row in issues.rows)),
        "issues_by_dataset": dict(Counter(row["dataset"] for row in issues.rows)),
        "issue_samples": issues.rows[:300],
        "standards": STANDARD_SOURCES,
    }


def run(output_dir: Path) -> dict[str, object]:
    missing = [str(path) for path in [DIVIPOLA_PATH, *DATASETS.values()] if not path.exists()]
    if missing:
        raise FileNotFoundError("Faltan archivos fuente: " + ", ".join(missing))

    output_dir.mkdir(parents=True, exist_ok=True)
    matcher = DivipolaMatcher(DIVIPOLA_PATH)
    issues = Issues()
    outputs: dict[str, list[dict[str, str]]] = {}

    outputs["fondos_empleados"] = normalize_funds(read_csv(DATASETS["fondos_empleados"]), matcher, issues)
    outputs["productos_promocionales"] = normalize_products(read_csv(DATASETS["productos_promocionales"]), matcher, issues)
    outputs["catalogo_tecnicas"] = normalize_technique_rows(read_csv(DATASETS["catalogo_tecnicas"]), "catalogo_tecnicas", issues)
    outputs["precios_tecnicas"] = normalize_technique_rows(read_csv(DATASETS["precios_tecnicas"]), "precios_tecnicas", issues)
    outputs["conjuntos_residenciales"] = normalize_residential(read_csv(DATASETS["conjuntos_residenciales"]), matcher, issues)
    outputs["proveedores"] = build_suppliers(outputs["productos_promocionales"], outputs["precios_tecnicas"], issues)

    for name, rows in outputs.items():
        write_csv(output_dir / f"{name}_normalizados.csv", rows)
    write_csv(output_dir / "incidencias_calidad.csv", issues.rows)
    summary = summarize(outputs, issues)
    (output_dir / "resumen_calidad.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    summary = run(args.output_dir.resolve())
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
