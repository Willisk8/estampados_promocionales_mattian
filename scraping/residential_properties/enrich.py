#!/usr/bin/env python3
"""Enriquece copropiedades con contactos publicados en sitios web verificables."""

from __future__ import annotations

import argparse
import csv
import json
import re
import threading
import time
import unicodedata
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen
from urllib.robotparser import RobotFileParser

from lxml import html


ROOT = Path(__file__).resolve().parent
INPUT = ROOT / "outputs" / "conjuntos_residenciales_colombia.csv"
OUTPUT = ROOT / "outputs" / "enrichment"
MANUAL = ROOT / "manual_websites.csv"

FREE_EMAIL_DOMAINS = {
    "gmail.com", "googlemail.com", "hotmail.com", "hotmail.es", "outlook.com",
    "outlook.es", "live.com", "live.com.co", "yahoo.com", "yahoo.es",
    "yahoo.com.co", "icloud.com", "aol.com", "msn.com", "proton.me",
    "protonmail.com", "rocketmail.com", "verizon.net", "sbcglobal.net",
    "une.net.co",
}
BAD_EMAIL_DOMAINS = {
    "gmail.co", "gmal.com", "gmai.com", "gmil.com", "hotmai.com", "homail.com",
    "hotmil.com", "hotmail.co", "outlok.com", "outloo.com", "yaho.com",
}
EMAIL_RE = re.compile(r"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}", re.I)
PHONE_RE = re.compile(
    r"(?<!\d)(?:\+?57[ .\-]?)?(?:\(?60[1-8]\)?[ .\-]?)?"
    r"(?:3\d{2}[ .\-]?\d{3}[ .\-]?\d{4}|\d{3}[ .\-]?\d{4})(?!\d)"
)
CONTACT_LINK_RE = re.compile(
    r"(?i)(contact|contacto|contactenos|contáctenos|administraci[oó]n|"
    r"canales?|atenci[oó]n|servicio|whatsapp|ubicaci[oó]n)"
)
GENERIC_EMAIL_RE = re.compile(
    r"(?i)^(administracion|admin|contacto|contactenos|info|informacion|servicio|"
    r"atencion|recepcion|gerencia|pqrs|comercial|tesoreria|contabilidad)@"
)
GENERIC_NAME_TOKENS = {
    "conjunto", "residencial", "condominio", "urbanizacion", "unidad",
    "agrupacion", "propiedad", "horizontal", "edificio", "torres", "torre",
    "etapa", "sector", "bloque", "apartamentos", "vivienda", "cerrado",
    "colombia", "ph", "p", "h", "del", "de", "la", "las", "los", "el",
}

EVIDENCE_FIELDS = [
    "record_id", "property_name", "municipality", "kind", "value",
    "contact_scope", "source_url", "website", "discovery_method",
    "property_match", "match_detail", "page_title", "http_status",
    "last_modified", "fetched_at",
]
ERROR_FIELDS = ["record_id", "property_name", "website", "url", "error", "fetched_at"]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def clean(value: Any) -> str:
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", str(value or ""))).strip()


def folded(value: Any) -> str:
    text = unicodedata.normalize("NFKD", clean(value))
    text = "".join(char for char in text if not unicodedata.combining(char))
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def join_unique(values: Iterable[str]) -> str:
    return "; ".join(dict.fromkeys(clean(value) for value in values if clean(value)))


def canonical_phone(value: str) -> str:
    digits = re.sub(r"\D", "", value)
    local = digits.removeprefix("57")
    if local in {"1234567", "7654321", "0000000", "1111111", "1234567890"} or len(set(local)) <= 2:
        return ""
    if digits.startswith("57") and len(digits) in {12, 13}:
        return "+" + digits
    prefix = digits[:3]
    valid_mobile = (
        300 <= int(prefix) <= 305
        or 310 <= int(prefix) <= 324
        or prefix in {"333", "350", "351", "352", "308"}
    ) if prefix.isdigit() else False
    if len(digits) == 10 and (prefix in {"601", "602", "604", "605", "606", "607", "608"} or valid_mobile):
        return "+57" + digits
    return digits


def whatsapp_number(href: str) -> str:
    parsed = urlparse(href)
    host = parsed.netloc.lower().split(":", 1)[0]
    if host == "wa.me":
        digits = re.sub(r"\D", "", parsed.path)
    elif host.endswith("whatsapp.com"):
        digits = re.sub(r"\D", "", parsed.query)
    else:
        return ""
    if digits.startswith("57") and len(digits) == 12:
        return "+" + digits
    if len(digits) == 10 and digits.startswith("3"):
        return "+57" + digits
    return ""


def email_domain(value: str) -> str:
    for email in value.split(";"):
        match = EMAIL_RE.search(email)
        if not match:
            continue
        domain = match.group(0).rsplit("@", 1)[1].lower().strip(".")
        if domain not in FREE_EMAIL_DOMAINS and domain not in BAD_EMAIL_DOMAINS and "." in domain and not domain.endswith((".gov.co", ".edu.co")):
            return domain
    return ""


def name_tokens(name: str) -> set[str]:
    return {
        token for token in folded(name).split()
        if token not in GENERIC_NAME_TOKENS and len(token) >= 4
    }


def property_match(page_text: str, row: dict[str, str]) -> tuple[str, str]:
    page_folded = folded(page_text)
    page_tokens = set(page_folded.split())
    nit = re.sub(r"\D", "", row.get("nit", ""))
    if nit and nit in re.sub(r"\D", "", page_text):
        return "NIT_MATCH", nit
    source_emails = [email.lower() for email in EMAIL_RE.findall(row.get("email", ""))]
    page_lower = page_text.lower()
    matching_emails = [email for email in source_emails if email in page_lower]
    if matching_emails:
        return "SOURCE_EMAIL_MATCH", ", ".join(matching_emails)
    tokens = name_tokens(row["property_name"])
    matched = sorted(tokens & page_tokens)
    required = 1 if len(tokens) == 1 else max(2, (len(tokens) + 1) // 2)
    if tokens and len(matched) >= required:
        return "NAME_MATCH", ", ".join(matched)
    address_digits = re.sub(r"\D", "", row.get("address", ""))
    if len(address_digits) >= 5 and address_digits in re.sub(r"\D", "", page_text):
        return "ADDRESS_MATCH", address_digits
    return "UNVERIFIED", ", ".join(matched)


class WebClient:
    def __init__(self, user_agent: str, timeout: int, delay: float):
        self.user_agent = user_agent
        self.timeout = timeout
        self.delay = delay
        self._last_request: dict[str, float] = defaultdict(float)
        self._robots: dict[str, RobotFileParser | None] = {}
        self._lock = threading.Lock()

    def allowed(self, url: str) -> bool:
        parsed = urlparse(url)
        origin = f"{parsed.scheme}://{parsed.netloc}"
        with self._lock:
            known = origin in self._robots
            parser = self._robots.get(origin)
        if not known:
            candidate = RobotFileParser()
            candidate.set_url(origin + "/robots.txt")
            try:
                request = Request(candidate.url, headers={"User-Agent": self.user_agent})
                with urlopen(request, timeout=self.timeout) as response:
                    candidate.parse(response.read().decode("utf-8", "replace").splitlines())
                parser = candidate
            except Exception:
                parser = None
            with self._lock:
                self._robots[origin] = parser
        return True if parser is None else parser.can_fetch(self.user_agent, url)

    def get(self, url: str) -> tuple[bytes, dict[str, str], int, str]:
        host = urlparse(url).netloc.lower()
        with self._lock:
            wait = self.delay - (time.monotonic() - self._last_request[host])
        if wait > 0:
            time.sleep(wait)
        request = Request(url, headers={"User-Agent": self.user_agent, "Accept": "text/html,*/*;q=0.8"})
        with urlopen(request, timeout=self.timeout) as response:
            body = response.read(3_000_000)
            result = body, dict(response.headers.items()), response.status, response.geturl()
        with self._lock:
            self._last_request[host] = time.monotonic()
        return result


def manual_websites(path: Path) -> dict[str, tuple[str, str]]:
    if not path.exists():
        return {}
    with path.open(encoding="utf-8-sig", newline="") as handle:
        return {
            clean(row.get("record_id")): (clean(row.get("website")), clean(row.get("source_url")))
            for row in csv.DictReader(handle)
            if clean(row.get("record_id")) and clean(row.get("website"))
        }


def page_data(body: bytes, final_url: str, headers: dict[str, str], row: dict[str, str]) -> tuple[list[dict[str, str]], list[str]]:
    try:
        tree = html.fromstring(body, base_url=final_url)
        for bad in tree.xpath("//script|//style|//noscript|//svg"):
            bad.drop_tree()
        text = clean(tree.text_content())
        hrefs = tree.xpath("//a/@href")
        title = clean(" ".join(tree.xpath("//title/text()")))
    except Exception:
        text = body.decode("utf-8", "replace")
        hrefs, title = [], ""

    emails = {value.lower() for value in EMAIL_RE.findall(text)}
    phones = {canonical_phone(value) for value in PHONE_RE.findall(text)}
    whatsapps: set[str] = set()
    links: list[str] = []
    origin = urlparse(final_url).netloc.lower()
    for href in hrefs:
        absolute = urljoin(final_url, href).split("#", 1)[0]
        if href.lower().startswith("mailto:"):
            emails.update(value.lower() for value in EMAIL_RE.findall(href[7:]))
        elif href.lower().startswith("tel:"):
            phones.add(canonical_phone(href[4:]))
        whatsapp = whatsapp_number(absolute)
        if whatsapp:
            whatsapps.add(whatsapp)
        parsed = urlparse(absolute)
        if parsed.scheme in {"http", "https"} and parsed.netloc.lower() == origin and CONTACT_LINK_RE.search(parsed.path):
            links.append(absolute)

    match, detail = property_match(text, row)
    base = {
        "property_match": match,
        "match_detail": detail,
        "page_title": title,
        "last_modified": clean(headers.get("Last-Modified")),
    }
    evidence: list[dict[str, str]] = []
    for value in sorted(emails):
        scope = "CORPORATE_ROLE_PROBABLE" if GENERIC_EMAIL_RE.search(value) else "PUBLIC_EMAIL_REQUIRES_REVIEW"
        evidence.append({**base, "kind": "email", "value": value, "contact_scope": scope})
    for value in sorted(phone for phone in phones if len(re.sub(r"\D", "", phone)) >= 7):
        scope = "PUBLIC_MOBILE_REQUIRES_REVIEW" if re.sub(r"\D", "", value).removeprefix("57").startswith("3") else "PUBLIC_LANDLINE_PROBABLE"
        evidence.append({**base, "kind": "phone", "value": value, "contact_scope": scope})
    for value in sorted(whatsapps):
        evidence.append({**base, "kind": "whatsapp", "value": value, "contact_scope": "PUBLIC_WHATSAPP_REQUIRES_REVIEW"})
    return evidence, list(dict.fromkeys(links))


def crawl_one(row: dict[str, str], website: str, method: str, client: WebClient, max_pages: int) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    base = website if website.startswith(("http://", "https://")) else "https://" + website
    queue = [base.rstrip("/") + "/"]
    visited: set[str] = set()
    evidence: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    while queue and len(visited) < max_pages:
        url = queue.pop(0)
        if url in visited:
            continue
        visited.add(url)
        if not client.allowed(url):
            errors.append({"record_id": row["record_id"], "property_name": row["property_name"], "website": base, "url": url, "error": "blocked_by_robots_txt", "fetched_at": now_iso()})
            continue
        try:
            body, headers, status, final_url = client.get(url)
            page_evidence, discovered = page_data(body, final_url, headers, row)
            if method == "manual_confirmed":
                for item in page_evidence:
                    item["property_match"] = "MANUAL_CONFIRMED"
                    item["match_detail"] = "Fuente manual documentada"
            for item in page_evidence:
                evidence.append({
                    "record_id": row["record_id"], "property_name": row["property_name"],
                    "municipality": row["municipality"], **item, "source_url": final_url,
                    "website": base, "discovery_method": method, "http_status": str(status),
                    "fetched_at": now_iso(),
                })
            queue.extend(link for link in discovered if link not in visited and link not in queue)
        except (HTTPError, URLError, TimeoutError, ValueError) as exc:
            errors.append({"record_id": row["record_id"], "property_name": row["property_name"], "website": base, "url": url, "error": str(exc), "fetched_at": now_iso()})
            if method == "institutional_email_domain" and url.startswith("https://") and len(visited) == 1:
                queue.append("http://" + url.removeprefix("https://"))
    return evidence, errors


def write_csv(path: Path, rows: list[dict[str, str]], fields: list[str]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def build_enriched(base_rows: list[dict[str, str]], evidence: list[dict[str, str]]) -> list[dict[str, str]]:
    accepted = {"MANUAL_CONFIRMED", "NIT_MATCH", "NAME_MATCH", "ADDRESS_MATCH"}
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for item in evidence:
        grouped[item["record_id"]].append(item)
    result: list[dict[str, str]] = []
    for row in base_rows:
        source_emails = {value.lower() for value in EMAIL_RE.findall(row.get("email", ""))}
        items = [
            item for item in grouped[row["record_id"]]
            if item["property_match"] in accepted
            or (
                item["property_match"] == "SOURCE_EMAIL_MATCH"
                and item["kind"] == "email"
                and item["value"].lower() in source_emails
            )
        ]
        strong_items = [item for item in items if item["property_match"] in {"MANUAL_CONFIRMED", "NIT_MATCH", "ADDRESS_MATCH"}]
        web_emails = [item["value"] for item in items if item["kind"] == "email"]
        web_phones = [item["value"] for item in items if item["kind"] == "phone"]
        whatsapps = [item["value"] for item in items if item["kind"] == "whatsapp"]
        strong_emails = [item["value"] for item in strong_items if item["kind"] == "email"]
        strong_phones = [item["value"] for item in strong_items if item["kind"] == "phone"]
        preferred_email = (EMAIL_RE.findall(row.get("email", "")) or strong_emails or [""])[0]
        preferred_phone = ([row.get("phone", "")] if clean(row.get("phone", "")) else strong_phones or [""])[0]
        if strong_items:
            confidence = "HIGH_PROPERTY_MATCH"
        elif items:
            confidence = "MEDIUM_PUBLIC_PAGE_ROLE_REVIEW"
        else:
            confidence = "OFFICIAL_DATASET_ONLY"
        result.append({
            **row,
            "email_preferred": clean(preferred_email),
            "emails_public_web": join_unique(web_emails),
            "phone_preferred": clean(preferred_phone),
            "phones_public_web": join_unique(web_phones),
            "whatsapp_public": join_unique(whatsapps),
            "verified_website": join_unique(item["website"] for item in items),
            "contact_source_urls": join_unique(item["source_url"] for item in items),
            "contact_scopes": join_unique(item["contact_scope"] for item in items),
            "web_match_types": join_unique(item["property_match"] for item in items),
            "web_contact_confidence": confidence,
            "web_fetched_at": max((item["fetched_at"] for item in items), default=""),
        })
    return result


def crawl(args: argparse.Namespace) -> None:
    if not INPUT.exists():
        raise SystemExit("Falta conjuntos_residenciales_colombia.csv; ejecute scraper.py run")
    with INPUT.open(encoding="utf-8-sig", newline="") as handle:
        base_rows = list(csv.DictReader(handle))
    manual = manual_websites(args.manual)
    wanted = set(filter(None, (args.records or "").split(",")))
    candidates: list[tuple[dict[str, str], str, str]] = []
    for row in base_rows:
        if wanted and row["record_id"] not in wanted:
            continue
        if row["record_id"] in manual:
            candidates.append((row, manual[row["record_id"]][0], "manual_confirmed"))
            continue
        domain = email_domain(row.get("email", ""))
        if domain:
            candidates.append((row, "https://" + domain, "institutional_email_domain"))
    candidates.sort(key=lambda item: (folded(item[0]["municipality"]), folded(item[0]["property_name"])))
    if args.limit:
        candidates = candidates[:args.limit]
    print(f"Candidatos con sitio inferible o confirmado: {len(candidates):,}")

    client = WebClient(args.user_agent, args.timeout, args.delay)
    evidence: list[dict[str, str]] = []
    errors: list[dict[str, str]] = []
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        futures = {
            pool.submit(crawl_one, row, website, method, client, args.max_pages): (row, website)
            for row, website, method in candidates
        }
        for index, future in enumerate(as_completed(futures), start=1):
            row, website = futures[future]
            try:
                found, failed = future.result()
                evidence.extend(found)
                errors.extend(failed)
                print(f"[{index}/{len(candidates)}] {row['record_id']}: {len(found)} evidencias")
            except Exception as exc:
                errors.append({"record_id": row["record_id"], "property_name": row["property_name"], "website": website, "url": website, "error": f"worker_error: {exc}", "fetched_at": now_iso()})

    unique_evidence = {
        (item["record_id"], item["kind"], item["value"], item["source_url"]): item
        for item in evidence
    }
    evidence = sorted(unique_evidence.values(), key=lambda item: (item["record_id"], item["kind"], item["value"]))
    enriched = build_enriched(base_rows, evidence)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    write_csv(OUTPUT / "evidencia_contactos_web.csv", evidence, EVIDENCE_FIELDS)
    write_csv(OUTPUT / "errores_web.csv", errors, ERROR_FIELDS)
    enriched_fields = list(base_rows[0]) + [
        "email_preferred", "emails_public_web", "phone_preferred",
        "phones_public_web", "whatsapp_public", "verified_website",
        "contact_source_urls", "contact_scopes", "web_contact_confidence",
        "web_match_types", "web_fetched_at",
    ]
    write_csv(OUTPUT / "conjuntos_residenciales_enriquecidos.csv", enriched, enriched_fields)
    enriched_by_id = {row["record_id"]: row for row in base_rows}
    accepted_count = 0
    for item in evidence:
        if item["property_match"] in {"MANUAL_CONFIRMED", "NIT_MATCH", "NAME_MATCH", "ADDRESS_MATCH"}:
            accepted_count += 1
        elif item["property_match"] == "SOURCE_EMAIL_MATCH" and item["kind"] == "email":
            source_emails = {value.lower() for value in EMAIL_RE.findall(enriched_by_id[item["record_id"]].get("email", ""))}
            accepted_count += item["value"].lower() in source_emails
    summary = {
        "base_records": len(base_rows), "website_candidates": len(candidates),
        "evidence_rows": len(evidence), "accepted_evidence_rows": accepted_count,
        "errors": len(errors),
        "records_with_verified_web_contact": sum(row["web_contact_confidence"] != "OFFICIAL_DATASET_ONLY" for row in enriched),
        "records_with_whatsapp": sum(bool(row["whatsapp_public"]) for row in enriched),
    }
    (OUTPUT / "resumen_enriquecimiento.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


def verify(_: argparse.Namespace) -> None:
    enriched_path = OUTPUT / "conjuntos_residenciales_enriquecidos.csv"
    evidence_path = OUTPUT / "evidencia_contactos_web.csv"
    if not enriched_path.exists() or not evidence_path.exists():
        raise SystemExit("Faltan salidas; ejecute enrich.py crawl")
    with enriched_path.open(encoding="utf-8-sig", newline="") as handle:
        enriched = list(csv.DictReader(handle))
    with evidence_path.open(encoding="utf-8-sig", newline="") as handle:
        evidence = list(csv.DictReader(handle))
    assert enriched and len({row["record_id"] for row in enriched}) == len(enriched)
    assert all(item["source_url"].startswith(("http://", "https://")) for item in evidence)
    assert all(item["property_match"] in {"MANUAL_CONFIRMED", "NIT_MATCH", "NAME_MATCH", "ADDRESS_MATCH", "SOURCE_EMAIL_MATCH", "UNVERIFIED"} for item in evidence)
    print(f"Verificación correcta: {len(enriched):,} conjuntos; {len(evidence):,} evidencias")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Enriquecimiento web de conjuntos residenciales")
    sub = parser.add_subparsers(dest="command", required=True)
    crawl_parser = sub.add_parser("crawl")
    crawl_parser.add_argument("--manual", type=Path, default=MANUAL)
    crawl_parser.add_argument("--records", help="record_id separados por coma")
    crawl_parser.add_argument("--limit", type=int, default=0)
    crawl_parser.add_argument("--workers", type=int, default=4)
    crawl_parser.add_argument("--max-pages", type=int, default=3)
    crawl_parser.add_argument("--delay", type=float, default=1.0)
    crawl_parser.add_argument("--timeout", type=int, default=20)
    crawl_parser.add_argument("--user-agent", default="EstampadosData/1.0 (contacto pendiente)")
    crawl_parser.set_defaults(function=crawl)
    verify_parser = sub.add_parser("verify")
    verify_parser.set_defaults(function=verify)
    args = parser.parse_args()
    args.function(args)
