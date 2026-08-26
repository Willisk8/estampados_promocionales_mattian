#!/usr/bin/env python3
"""Descarga, normaliza, compara y enriquece entidades del sector solidario.

El rastreo web se limita a sitios institucionales públicos, respeta robots.txt y
guarda evidencia trazable. No evade autenticación, CAPTCHA ni restricciones.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
import unicodedata
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlparse
from urllib.request import Request, urlopen
from urllib.robotparser import RobotFileParser

import pandas as pd
from lxml import html


ROOT = Path(__file__).resolve().parent
RAW = ROOT / "data" / "raw"
PROCESSED = ROOT / "data" / "processed"
WEB = ROOT / "data" / "web"
MANUAL_WEBSITES = ROOT / "data" / "manual" / "websites.csv"

SOCRATA_ID = "kg2d-yfyg"
SOCRATA_API = f"https://www.datos.gov.co/resource/{SOCRATA_ID}.json"
SOCRATA_METADATA = f"https://www.datos.gov.co/api/views/{SOCRATA_ID}"
HISTORICAL_XLSX = (
    "https://www.supersolidaria.gov.co/sites/default/files/entidades/"
    "20231205_listado_entidades_vigiladas_oct_2023.xlsx"
)

CURRENT_ALL = RAW / "entidades_sector_solidario_todas_las_cargas.csv"
METADATA = RAW / "socrata_metadata.json"
HISTORICAL = RAW / "entidades_vigiladas_2023-10.xlsx"

FREE_EMAIL_DOMAINS = {
    "gmail.com", "googlemail.com", "hotmail.com", "hotmail.es", "outlook.com",
    "outlook.es", "live.com", "live.com.co", "yahoo.com", "yahoo.es",
    "icloud.com", "aol.com", "msn.com", "proton.me", "protonmail.com",
}
BAD_DOMAIN_SUFFIXES = {"cov.go", "gob.co.com", "com.co.com"}
EMAIL_RE = re.compile(r"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}", re.I)
PHONE_RE = re.compile(
    r"(?<!\d)(?:\+?57[ .\-]?)?(?:\(?60[1-8]\)?[ .\-]?)?"
    r"(?:3\d{2}[ .\-]?\d{3}[ .\-]?\d{4}|\d{3}[ .\-]?\d{4})(?!\d)"
)
YEAR_RE = re.compile(r"\b(20(?:2[3-9]|3\d))\b")
ASSOCIATES_RE = re.compile(
    r"(?i)(?:mas\s+de|más\s+de|cerca\s+de|aproximadamente|alrededor\s+de|"
    r"somos|cuenta\s+con|tenemos|beneficia\s+a|beneficiando\s+a|reune\s+a|"
    r"reúne\s+a|base\s+de|\+\s*(?:de)?)?\s*"
    r"(\d{1,3}(?:[.,\s]\d{3})+|\d{2,6})\s+"
    r"(?:asociad[oa]s|afiliad[oa]s)\b"
)
CONTACT_LINK_RE = re.compile(
    r"(?i)(contact|contacto|contactenos|contáctenos|directorio|oficina|sede|"
    r"canales?|atencion|atención|servicio.al.asociado|pqrs|whatsapp)"
)
GENERIC_EMAIL_RE = re.compile(
    r"(?i)^(contacto|contactenos|info|informacion|servicio|servicios|"
    r"atencion|atencionalcliente|afiliaciones|comercial|mercadeo|"
    r"bienestar|convenios|solicitudes|gerencia|administracion|fondo)@"
)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def ensure_dirs() -> None:
    for directory in (RAW, PROCESSED, WEB):
        directory.mkdir(parents=True, exist_ok=True)


def clean_text(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", str(value))).strip()


def ascii_key(value: object) -> str:
    text = unicodedata.normalize("NFKD", clean_text(value))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def normalize_nit(value: object) -> str:
    digits = re.sub(r"\D", "", clean_text(value))
    # El NIT institucional suele publicarse como nueve dígitos base + DV.
    # Si el usuario ya entrega los nueve dígitos base, no se recorta de nuevo.
    return digits[:-1] if len(digits) == 10 else digits


def normalize_phone(value: object) -> str:
    return re.sub(r"[^0-9+;xX, ]", "", clean_text(value))


def http_get(url: str, user_agent: str, timeout: int = 30) -> tuple[bytes, dict[str, str], int, str]:
    request = Request(url, headers={"User-Agent": user_agent, "Accept": "*/*"})
    with urlopen(request, timeout=timeout) as response:
        return response.read(), dict(response.headers.items()), response.status, response.geturl()


def download_file(url: str, path: Path, user_agent: str) -> None:
    body, _, _, _ = http_get(url, user_agent=user_agent, timeout=60)
    path.write_bytes(body)


def fetch_sources(args: argparse.Namespace) -> None:
    ensure_dirs()
    if args.force or not HISTORICAL.exists():
        print(f"Descargando corte histórico: {HISTORICAL_XLSX}")
        download_file(HISTORICAL_XLSX, HISTORICAL, args.user_agent)

    print(f"Descargando metadatos: {SOCRATA_METADATA}")
    download_file(SOCRATA_METADATA, METADATA, args.user_agent)

    count_url = SOCRATA_API + "?" + urlencode({"$select": "count(*)"})
    count_body, _, _, _ = http_get(count_url, args.user_agent)
    total = int(json.loads(count_body)[0]["count"])
    print(f"Filas anunciadas por la API: {total:,}")

    fields: list[str] = []
    temp_path = CURRENT_ALL.with_suffix(".csv.part")
    with temp_path.open("w", newline="", encoding="utf-8-sig") as output:
        writer = None
        for offset in range(0, total, args.page_size):
            query = urlencode({
                "$select": "*,:id,:created_at,:updated_at",
                "$order": ":id",
                "$limit": args.page_size,
                "$offset": offset,
            })
            body, _, _, _ = http_get(SOCRATA_API + "?" + query, args.user_agent, timeout=90)
            rows = json.loads(body)
            if not rows:
                break
            if writer is None:
                preferred = [
                    "codentidad", "fechaultirepo", "mes", "a_o", "nombreentidad",
                    "sigla", "nit", "nombretipo", "departamento", "municipio",
                    "direccion", "telefono", "codactividad", "nombreactividad",
                    "representantelegal", "correo", "supervision",
                    ":id", ":created_at", ":updated_at",
                ]
                extra = sorted({key for row in rows for key in row} - set(preferred))
                fields = preferred + extra
                writer = csv.DictWriter(output, fieldnames=fields, extrasaction="ignore")
                writer.writeheader()
            writer.writerows(rows)
            print(f"  {min(offset + len(rows), total):,}/{total:,}")
    temp_path.replace(CURRENT_ALL)
    print(f"Fuente completa guardada en {CURRENT_ALL}")


CURRENT_MAP = {
    "codentidad": "entity_code",
    "fechaultirepo": "latest_report_date",
    "nombreentidad": "entity_name",
    "sigla": "acronym",
    "nit": "nit_display",
    "nombretipo": "entity_type",
    "departamento": "department",
    "municipio": "municipality",
    "direccion": "address",
    "telefono": "phone",
    "representantelegal": "legal_representative",
    "correo": "email",
    "supervision": "supervision_level",
    "id": "socrata_row_id",
    "created_at": "socrata_created_at",
    "updated_at": "socrata_updated_at",
}

HISTORICAL_MAP = {
    "codigo_entidad": "entity_code",
    "fecha_ultimo_reporte": "latest_report_date",
    "nombreentidad": "entity_name",
    "sigla": "acronym",
    "nit": "nit_display",
    "nombre_tipo": "entity_type",
    "departamento": "department",
    "municipio": "municipality",
    "direccion": "address",
    "telefono": "phone",
    "celular": "mobile",
    "email": "email",
    "supervision": "supervision_level",
    "representante_legal": "legal_representative",
}


def normalized_frame(df: pd.DataFrame, mapping: dict[str, str], snapshot: str, source_url: str) -> pd.DataFrame:
    df = df.copy()
    df.columns = [ascii_key(c) for c in df.columns]
    available = {key: value for key, value in mapping.items() if key in df.columns}
    df = df.rename(columns=available)
    wanted = list(dict.fromkeys(mapping.values()))
    for column in wanted:
        if column not in df.columns:
            df[column] = ""
    df = df[wanted]
    for column in df.columns:
        df[column] = df[column].map(clean_text)
    if "mobile" not in df.columns:
        df["mobile"] = ""
    df["nit"] = df["nit_display"].map(normalize_nit)
    df["phones"] = df.apply(
        lambda row: "; ".join(x for x in dict.fromkeys(
            [normalize_phone(row.get("phone", "")), normalize_phone(row.get("mobile", ""))]
        ) if x), axis=1
    )
    df["snapshot"] = snapshot
    df["source_url"] = source_url
    return df


def choose_latest_current(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["_completeness"] = df[[
        "entity_name", "address", "phones", "email", "legal_representative"
    ]].ne("").sum(axis=1)
    df["_sort_updated"] = pd.to_datetime(df["socrata_updated_at"], errors="coerce", utc=True)
    df["_sort_report"] = pd.to_datetime(df["latest_report_date"], errors="coerce", utc=True)
    key = df["entity_code"].where(df["entity_code"].ne(""), df["nit"])
    df["_entity_key"] = key.where(key.ne(""), df["entity_name"].map(ascii_key))
    df = df.sort_values(
        ["_entity_key", "_sort_updated", "_sort_report", "_completeness"],
        ascending=[True, True, True, True], na_position="first",
    ).drop_duplicates("_entity_key", keep="last")
    return df.drop(columns=["_completeness", "_sort_updated", "_sort_report", "_entity_key"])


def build_outputs(_: argparse.Namespace) -> None:
    ensure_dirs()
    if not CURRENT_ALL.exists() or not HISTORICAL.exists():
        raise SystemExit("Faltan fuentes. Ejecute primero: python scrape.py fetch")

    current_raw = pd.read_csv(CURRENT_ALL, dtype=str, keep_default_na=False)
    current = normalized_frame(current_raw, CURRENT_MAP, "latest_api_row", SOCRATA_API)
    current = choose_latest_current(current)

    historical_raw = pd.read_excel(HISTORICAL, sheet_name="LISTADO DE ENTIDADES", header=4, dtype=str)
    historical_raw = historical_raw.loc[:, ~historical_raw.columns.astype(str).str.startswith("Unnamed")]
    historical = normalized_frame(historical_raw, HISTORICAL_MAP, "2023-10", HISTORICAL_XLSX)
    historical = historical[historical["nit"].ne("") | historical["entity_name"].ne("")]
    historical = historical.sort_values("latest_report_date").drop_duplicates("nit", keep="last")

    current_path = PROCESSED / "entidades_actuales.csv"
    historical_path = PROCESSED / "entidades_2023-10.csv"
    current.to_csv(current_path, index=False, encoding="utf-8-sig")
    historical.to_csv(historical_path, index=False, encoding="utf-8-sig")

    old_cols = ["nit", "entity_name", "phones", "email", "address", "legal_representative"]
    new_cols = old_cols + ["latest_report_date", "socrata_updated_at", "source_url"]
    comparison = historical[old_cols].merge(
        current[new_cols], on="nit", how="outer", suffixes=("_2023", "_current"), indicator=True
    )
    comparison["source_presence"] = comparison["_merge"].map({
        "both": "present_in_both_sources",
        "left_only": "only_in_2023_source",
        "right_only": "only_in_current_source",
    }).astype(str)
    present_in_both = comparison["_merge"].eq("both")
    comparison = comparison.drop(columns="_merge")
    for field in ("phones", "email", "address", "legal_representative"):
        differs = (
            comparison[f"{field}_2023"].fillna("").str.casefold()
            != comparison[f"{field}_current"].fillna("").str.casefold()
        )
        comparison[f"{field}_changed"] = differs.where(present_in_both, "")
    comparison.to_csv(PROCESSED / "cambios_contacto_2023_vs_actual.csv", index=False, encoding="utf-8-sig")

    manifest = {
        "generated_at": now_iso(),
        "source_rows": {"socrata_all_loads": len(current_raw), "historical_xlsx": len(historical_raw)},
        "normalized_rows": {"current_entities": len(current), "historical_entities": len(historical)},
        "outputs": [current_path.name, historical_path.name, "cambios_contacto_2023_vs_actual.csv"],
        "method": "Latest Socrata row per entity code, ordered by :updated_at, report date and completeness.",
        "warning": "Source presence is not a legal determination of active/inactive status.",
    }
    (PROCESSED / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(manifest, indent=2, ensure_ascii=False))


@dataclass
class CrawlConfig:
    user_agent: str
    delay: float
    timeout: int
    max_pages: int
    workers: int
    contact_paths: list[str]


def load_config(args: argparse.Namespace) -> CrawlConfig:
    values = {}
    if args.config:
        values = json.loads(Path(args.config).read_text(encoding="utf-8"))
    return CrawlConfig(
        user_agent=values.get("user_agent", args.user_agent),
        delay=float(values.get("request_delay_seconds", 1.5)),
        timeout=int(values.get("timeout_seconds", 20)),
        max_pages=int(values.get("max_pages_per_entity", 8)),
        workers=int(values.get("workers", 12)),
        contact_paths=values.get("contact_paths", ["", "/contacto", "/contactenos", "/nosotros"]),
    )


def email_domain(email: str) -> str:
    match = EMAIL_RE.search(email or "")
    if not match:
        return ""
    domain = match.group(0).rsplit("@", 1)[1].lower().strip(".")
    if domain in FREE_EMAIL_DOMAINS or domain in BAD_DOMAIN_SUFFIXES or "." not in domain:
        return ""
    return domain


def manual_websites() -> dict[str, str]:
    if not MANUAL_WEBSITES.exists():
        return {}
    with MANUAL_WEBSITES.open(encoding="utf-8-sig", newline="") as source:
        return {
            normalize_nit(row.get("nit")): row.get("website", "").strip()
            for row in csv.DictReader(source) if row.get("website", "").strip()
        }


def robots_allowed(url: str, user_agent: str, timeout: int) -> bool:
    parsed = urlparse(url)
    robots_url = f"{parsed.scheme}://{parsed.netloc}/robots.txt"
    parser = RobotFileParser()
    parser.set_url(robots_url)
    try:
        body, _, _, _ = http_get(robots_url, user_agent, timeout)
        parser.parse(body.decode("utf-8", errors="replace").splitlines())
        return parser.can_fetch(user_agent, url)
    except (HTTPError, URLError, TimeoutError, ValueError):
        return True


def clean_candidate(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip(" .,:;|-\n\t")


def canonical_phone(value: str) -> str:
    digits = re.sub(r"\D", "", value)
    if digits.startswith("57") and len(digits) in (12, 13):
        return "+" + digits
    if len(digits) == 10 and (digits.startswith("3") or digits.startswith("60")):
        return "+57" + digits
    return digits


def whatsapp_number(href: str) -> str:
    parsed = urlparse(href)
    host = parsed.netloc.lower().split(":", 1)[0]
    if not (host == "wa.me" or host.endswith("whatsapp.com")):
        return ""
    raw = parsed.path if host == "wa.me" else parsed.query
    digits = re.sub(r"\D", "", raw)
    if digits.startswith("57") and len(digits) == 12:
        return "+" + digits
    if len(digits) == 10 and digits.startswith("3"):
        return "+57" + digits
    return ""


def email_scope(value: str) -> str:
    return "institutional_general" if GENERIC_EMAIL_RE.search(value) else "public_staff_or_area"


def entity_match(text: str, entity: dict[str, str]) -> str:
    folded = " " + ascii_key(text).replace("_", " ") + " "
    page_digits = re.sub(r"\D", "", text)
    nit = entity.get("nit", "")
    if nit and nit in page_digits:
        return "nit_match"
    acronym = ascii_key(entity.get("acronym", "")).replace("_", " ")
    if len(acronym) >= 4 and f" {acronym} " in folded:
        return "acronym_match"
    name = ascii_key(entity.get("entity_name", "")).replace("_", " ")
    if len(name) >= 12 and f" {name} " in folded:
        return "full_name_match"
    return "unverified_domain_inference"


def reliable_associate_context(value: str, context: str) -> bool:
    number_text = clean_text(value)
    if not number_text.isdigit():
        return False
    number = int(number_text)
    if number < 20 or number > 250_000:
        return False
    folded = ascii_key(context).replace("_", " ")
    if "@" in context:
        return False
    noisy_terms = (
        "linea", "llamando", "whatsapp", "telefono", "contacto", "gratuita",
        "gratis", "premio", "premio", "ganador", "ganadores", "primeros",
        "noticias", "listado", "constituyo", "constitucion", "firma de",
    )
    if any(term in folded for term in noisy_terms):
        return False
    if 1900 <= number <= 2099 and not any(
        term in folded for term in (
            "mas de", "base de", "cuenta con", "tenemos", "somos",
            "asociados activos", "asociados comprometidos", "total de",
        )
    ):
        return False
    positive_terms = (
        "mas de", "base de", "cuenta con", "tenemos", "somos", "beneficia",
        "beneficiando", "reune", "asociados activos", "asociados comprometidos",
        "total de", "sus asociados", "+ de",
    )
    return any(term in folded for term in positive_terms) or "+" in context


def associate_value_from_context(value: str, context: str) -> str:
    matches = list(ASSOCIATES_RE.finditer(context))
    if matches:
        raw = matches[-1].group(1)
        digits = re.sub(r"\D", "", raw)
        if digits:
            return str(int(digits))
    digits = re.sub(r"\D", "", clean_text(value))
    return str(int(digits)) if digits else ""


def page_evidence(
    body: bytes,
    final_url: str,
    headers: dict[str, str],
    entity: dict[str, str],
) -> list[dict[str, str]]:
    try:
        tree = html.fromstring(body, base_url=final_url)
        for bad in tree.xpath("//script|//style|//noscript|//svg"):
            bad.drop_tree()
        text = clean_text(tree.text_content())
        hrefs = tree.xpath("//a/@href")
    except Exception:
        text = body.decode("utf-8", errors="replace")
        hrefs = []

    emails = set(EMAIL_RE.findall(text))
    phones = {canonical_phone(x) for x in PHONE_RE.findall(text)}
    for href in hrefs:
        if href.lower().startswith("mailto:"):
            emails.update(EMAIL_RE.findall(href[7:]))
        elif href.lower().startswith("tel:"):
            phones.add(canonical_phone(href[4:]))

    whatsapps = {whatsapp_number(urljoin(final_url, href)) for href in hrefs}
    whatsapps.discard("")

    evidence: list[dict[str, str]] = []
    years = [int(y) for y in YEAR_RE.findall(text)]
    year_hint = str(max(years)) if years else ""
    last_modified = headers.get("Last-Modified", "")
    match_status = entity_match(text, entity)
    for value in sorted(e.lower() for e in emails):
        evidence.append({"kind": "email", "value": value, "contact_scope": email_scope(value), "page_year_hint": year_hint, "last_modified": last_modified, "entity_match": match_status})
    for value in sorted(p for p in phones if len(re.sub(r"\D", "", p)) >= 7):
        evidence.append({"kind": "phone", "value": value, "contact_scope": "institutional_phone", "page_year_hint": year_hint, "last_modified": last_modified, "entity_match": match_status})
    for value in sorted(whatsapps):
        evidence.append({"kind": "whatsapp", "value": value, "contact_scope": "public_whatsapp", "page_year_hint": year_hint, "last_modified": last_modified, "entity_match": match_status})
    associated_counts: dict[str, str] = {}
    for match in ASSOCIATES_RE.finditer(text):
        raw_value = match.group(1)
        digits = re.sub(r"\D", "", raw_value)
        if not digits:
            continue
        number = int(digits)
        if number < 5 or number > 10_000_000:
            continue
        start = max(0, match.start() - 90)
        end = min(len(text), match.end() + 90)
        context = clean_candidate(text[start:end])
        if match.end() < len(text) and text[match.end()] == "@":
            continue
        if not reliable_associate_context(str(number), context):
            continue
        associated_counts[str(number)] = context[:260]
    for value, context in sorted(associated_counts.items(), key=lambda item: int(item[0]), reverse=True):
        evidence.append({
            "kind": "associated_count",
            "value": value,
            "contact_scope": context,
            "page_year_hint": year_hint,
            "last_modified": last_modified,
            "entity_match": match_status,
        })
    return evidence


def discovered_contact_links(body: bytes, final_url: str) -> list[str]:
    try:
        tree = html.fromstring(body, base_url=final_url)
    except Exception:
        return []
    origin = urlparse(final_url)
    links: list[str] = []
    for anchor in tree.xpath("//a[@href]"):
        href = anchor.get("href", "")
        label = clean_text(" ".join(anchor.itertext()))
        absolute = urljoin(final_url, href).split("#", 1)[0]
        parsed = urlparse(absolute)
        if parsed.scheme not in {"http", "https"} or parsed.netloc.lower() != origin.netloc.lower():
            continue
        if CONTACT_LINK_RE.search(f"{label} {parsed.path}") and absolute not in links:
            links.append(absolute)
    return links


def crawl_entity(entity: dict[str, str], website: str, method: str, cfg: CrawlConfig) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    base = website if website.startswith(("http://", "https://")) else "https://" + website
    queue = [base.rstrip("/") + "/"]
    queue.extend(urljoin(queue[0], path.lstrip("/")) for path in cfg.contact_paths if path)
    visited: set[str] = set()
    output_rows: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    while queue and len(visited) < cfg.max_pages:
        url = queue.pop(0)
        if url in visited:
            continue
        visited.add(url)
        if not robots_allowed(url, cfg.user_agent, cfg.timeout):
            errors.append({"nit": entity["nit"], "url": url, "error": "blocked_by_robots_txt", "fetched_at": now_iso()})
            continue
        try:
            body, headers, status, final_url = http_get(url, cfg.user_agent, cfg.timeout)
            content_type = headers.get("Content-Type", "")
            if "html" not in content_type.lower() and not final_url.lower().endswith((".htm", ".html", "/")):
                continue
            if len(visited) == 1:
                discovered = discovered_contact_links(body, final_url)
                queue = discovered + [item for item in queue if item not in discovered]
            for item in page_evidence(body, final_url, headers, entity):
                if method == "manual":
                    item["entity_match"] = "manual_confirmed"
                output_rows.append({
                    "nit": entity["nit"], "entity_name": entity["entity_name"], **item,
                    "source_url": final_url, "website": base, "discovery_method": method,
                    "http_status": str(status), "fetched_at": now_iso(),
                })
        except (HTTPError, URLError, TimeoutError, ValueError) as exc:
            errors.append({"nit": entity["nit"], "url": url, "error": str(exc), "fetched_at": now_iso()})
        time.sleep(cfg.delay)
    return output_rows, errors


def join_unique(values: Iterable[str]) -> str:
    return "; ".join(dict.fromkeys(value for value in values if clean_text(value)))


def build_consolidated(current: pd.DataFrame, historical: pd.DataFrame, evidence: pd.DataFrame) -> pd.DataFrame:
    accepted = {"manual_confirmed", "nit_match", "acronym_match", "full_name_match"}
    verified = evidence[evidence["entity_match"].isin(accepted)].copy() if not evidence.empty else evidence.copy()
    grouped: dict[str, dict[str, list[str]]] = defaultdict(lambda: defaultdict(list))
    scopes: dict[str, list[str]] = defaultdict(list)
    fetched_at: dict[str, list[str]] = defaultdict(list)
    for row in verified.to_dict("records"):
        grouped[row["nit"]][row["kind"]].append(row["value"])
        grouped[row["nit"]]["source_url"].append(row["source_url"])
        grouped[row["nit"]]["website"].append(row.get("website", ""))
        grouped[row["nit"]]["entity_match"].append(row.get("entity_match", ""))
        if row.get("kind") in {"email", "phone", "whatsapp"}:
            scopes[row["nit"]].append(row.get("contact_scope", ""))
        fetched_at[row["nit"]].append(row.get("fetched_at", ""))

    old = historical.set_index("nit", drop=False).to_dict("index") if not historical.empty else {}
    rows: list[dict[str, str]] = []
    for entity in current.to_dict("records"):
        nit = entity["nit"]
        previous = old.get(nit, {})
        web_emails = list(dict.fromkeys(grouped[nit]["email"]))
        web_emails.sort(key=lambda value: (email_scope(value) != "institutional_general", value))
        official_email = clean_text(entity.get("email")) or clean_text(previous.get("email"))
        official_phones = clean_text(entity.get("phones")) or clean_text(previous.get("phones"))
        best_email = web_emails[0] if web_emails else official_email
        web_phones = list(dict.fromkeys(grouped[nit]["phone"]))
        whatsapps = list(dict.fromkeys(grouped[nit]["whatsapp"]))
        best_phone = web_phones[0] if web_phones else official_phones
        associate_rows = [
            row for row in verified[verified["nit"].eq(nit)].to_dict("records")
            if row.get("kind") == "associated_count"
            and reliable_associate_context(clean_text(row.get("value")), clean_text(row.get("contact_scope")))
        ] if not verified.empty else []
        associate_rows.sort(
            key=lambda row: (
                int(clean_text(row.get("page_year_hint")) or "0"),
                int(associate_value_from_context(
                    clean_text(row.get("value")), clean_text(row.get("contact_scope"))
                ) or "0"),
            ),
            reverse=True,
        )
        associates_value = associate_value_from_context(
            clean_text(associate_rows[0].get("value")),
            clean_text(associate_rows[0].get("contact_scope")),
        ) if associate_rows else ""
        associates_source = clean_text(associate_rows[0].get("source_url")) if associate_rows else ""
        associates_context = clean_text(associate_rows[0].get("contact_scope")) if associate_rows else ""
        associates_confidence = (
            "media_sitio_oficial_publico" if associates_value else "no_disponible_en_fuentes_publicas_consultadas"
        )
        matches = set(grouped[nit]["entity_match"])
        if matches & {"manual_confirmed", "nit_match", "full_name_match"}:
            confidence = "alta_sitio_oficial_validado"
        elif "acronym_match" in matches:
            confidence = "media_sitio_validado_por_sigla"
        else:
            confidence = "media_registro_oficial"
        rows.append({
            "nit": nit,
            "nombre_entidad": entity.get("entity_name", ""),
            "sigla": entity.get("acronym", ""),
            "tipo_entidad": entity.get("entity_type", ""),
            "departamento": entity.get("department", ""),
            "municipio": entity.get("municipality", ""),
            "direccion": entity.get("address", "") or previous.get("address", ""),
            "correo_preferido": best_email,
            "correos_sitio_oficial": join_unique(web_emails),
            "correo_registro_oficial": official_email,
            "telefono_preferido": best_phone,
            "telefonos_sitio_oficial": join_unique(web_phones),
            "telefono_registro_oficial": official_phones,
            "whatsapp_publico": join_unique(whatsapps),
            "numero_asociados": associates_value,
            "fuente_numero_asociados": associates_source,
            "contexto_numero_asociados": associates_context,
            "confianza_numero_asociados": associates_confidence,
            "sitio_web": join_unique(grouped[nit]["website"]),
            "urls_fuente_contacto": join_unique(grouped[nit]["source_url"]),
            "alcance_contacto_web": join_unique(scopes[nit]),
            "confianza_contacto": confidence,
            "tiene_contacto_utilizable": "si" if best_email or best_phone or whatsapps else "no",
            "fecha_consulta_web": max(fetched_at[nit], default=""),
            "fuente_registro": entity.get("source_url", ""),
            "fecha_reporte_oficial": entity.get("latest_report_date", ""),
        })
    return pd.DataFrame(rows)


def crawl(args: argparse.Namespace) -> None:
    ensure_dirs()
    current_path = PROCESSED / "entidades_actuales.csv"
    if not current_path.exists():
        raise SystemExit("Falta entidades_actuales.csv. Ejecute primero: python scrape.py build")
    cfg = load_config(args)
    entities = pd.read_csv(current_path, dtype=str, keep_default_na=False)
    sites = manual_websites()
    if args.nits:
        wanted = {normalize_nit(nit) for nit in args.nits.split(",")}
        entities = entities[entities["nit"].isin(wanted)]

    candidates = []
    for row in entities.to_dict("records"):
        website = sites.get(row["nit"], "")
        method = "manual"
        if not website:
            domain = email_domain(row.get("email", ""))
            website = f"https://{domain}" if domain else ""
            method = "institutional_email_domain"
        if website:
            candidates.append((row, website, method))
    if args.limit:
        candidates = candidates[: args.limit]

    output_rows: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    with ThreadPoolExecutor(max_workers=max(1, cfg.workers)) as pool:
        futures = {pool.submit(crawl_entity, entity, website, method, cfg): (index, entity, website)
                   for index, (entity, website, method) in enumerate(candidates, start=1)}
        for completed, future in enumerate(as_completed(futures), start=1):
            index, entity, website = futures[future]
            print(f"[{completed}/{len(candidates)}] {entity['nit']} {entity['entity_name']} -> {website}")
            try:
                rows, crawl_errors = future.result()
                output_rows.extend(rows)
                errors.extend(crawl_errors)
            except Exception as exc:
                errors.append({"nit": entity["nit"], "url": website, "error": f"worker_error: {exc}", "fetched_at": now_iso()})

    columns = [
        "nit", "entity_name", "kind", "value", "contact_scope", "source_url", "website",
        "discovery_method", "entity_match", "page_year_hint", "last_modified",
        "http_status", "fetched_at",
    ]
    evidence = pd.DataFrame(output_rows, columns=columns).drop_duplicates(
        ["nit", "kind", "value", "source_url"]
    )
    evidence.to_csv(WEB / "evidencia_web.csv", index=False, encoding="utf-8-sig")
    pd.DataFrame(errors, columns=["nit", "url", "error", "fetched_at"]).to_csv(
        WEB / "errores_web.csv", index=False, encoding="utf-8-sig"
    )

    historical = pd.read_csv(PROCESSED / "entidades_2023-10.csv", dtype=str, keep_default_na=False)
    enriched = build_consolidated(pd.read_csv(current_path, dtype=str, keep_default_na=False), historical, evidence)
    enriched.to_csv(WEB / "base_consolidada_contactos.csv", index=False, encoding="utf-8-sig")
    print(f"Evidencias: {len(evidence):,}; errores: {len(errors):,}; base consolidada: {len(enriched):,}")


def consolidate(_: argparse.Namespace) -> None:
    current = pd.read_csv(PROCESSED / "entidades_actuales.csv", dtype=str, keep_default_na=False)
    historical = pd.read_csv(PROCESSED / "entidades_2023-10.csv", dtype=str, keep_default_na=False)
    evidence_path = WEB / "evidencia_web.csv"
    evidence = pd.read_csv(evidence_path, dtype=str, keep_default_na=False) if evidence_path.exists() else pd.DataFrame()
    result = build_consolidated(current, historical, evidence)
    result.to_csv(WEB / "base_consolidada_contactos.csv", index=False, encoding="utf-8-sig")
    print(f"Base consolidada regenerada: {len(result):,} entidades")


def verify(_: argparse.Namespace) -> None:
    required = [
        PROCESSED / "entidades_actuales.csv",
        PROCESSED / "entidades_2023-10.csv",
        PROCESSED / "cambios_contacto_2023_vs_actual.csv",
        PROCESSED / "manifest.json",
    ]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        raise SystemExit("Faltan salidas: " + ", ".join(missing))
    current = pd.read_csv(required[0], dtype=str, keep_default_na=False)
    historical = pd.read_csv(required[1], dtype=str, keep_default_na=False)
    assert current["nit"].ne("").mean() > 0.95, "Demasiados NIT vacíos en fuente actual"
    assert current["nit"].duplicated().sum() == 0, "Hay NIT duplicados en fuente actual"
    assert historical["nit"].duplicated().sum() == 0, "Hay NIT duplicados en corte histórico"
    consolidated_path = WEB / "base_consolidada_contactos.csv"
    consolidated = pd.read_csv(consolidated_path, dtype=str, keep_default_na=False) if consolidated_path.exists() else pd.DataFrame()
    if not consolidated.empty:
        assert len(consolidated) == len(current), "La base consolidada no cubre todas las entidades actuales"
        assert consolidated["nit"].duplicated().sum() == 0, "Hay NIT duplicados en la base consolidada"
    print(json.dumps({
        "current_rows": len(current),
        "historical_rows": len(historical),
        "current_with_email": int(current["email"].ne("").sum()),
        "current_with_phone": int(current["phones"].ne("").sum()),
        "consolidated_rows": len(consolidated),
        "consolidated_usable_contacts": int(consolidated.get("tiene_contacto_utilizable", pd.Series(dtype=str)).eq("si").sum()),
        "consolidated_with_whatsapp": int(consolidated.get("whatsapp_publico", pd.Series(dtype=str)).ne("").sum()),
    }, indent=2, ensure_ascii=False))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--user-agent", default="EstampadosContactResearch/1.0")
    sub = result.add_subparsers(dest="command", required=True)
    fetch = sub.add_parser("fetch", help="Descargar fuentes oficiales")
    fetch.add_argument("--force", action="store_true")
    fetch.add_argument("--page-size", type=int, default=50000)
    fetch.set_defaults(func=fetch_sources)
    build = sub.add_parser("build", help="Normalizar y comparar 2023 vs. fuente actual")
    build.set_defaults(func=build_outputs)
    web = sub.add_parser("crawl", help="Rastrear sitios institucionales públicos")
    web.add_argument("--config", help="Ruta a JSON; use config.example.json como base")
    web.add_argument("--limit", type=int, default=20, help="Entidades a procesar; 0 = todas")
    web.add_argument("--nits", help="Lista de NIT separados por coma")
    web.set_defaults(func=crawl)
    one = sub.add_parser("consolidate", help="Regenerar la base única desde fuentes oficiales y evidencia web")
    one.set_defaults(func=consolidate)
    check = sub.add_parser("verify", help="Validar salidas tabulares")
    check.set_defaults(func=verify)
    return result


if __name__ == "__main__":
    parsed = parser().parse_args()
    try:
        parsed.func(parsed)
    except KeyboardInterrupt:
        print("Interrumpido por el usuario", file=sys.stderr)
        raise SystemExit(130)
