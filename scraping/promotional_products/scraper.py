#!/usr/bin/env python3
"""Catálogo auditable de artículos promocionales publicados en Colombia."""

from __future__ import annotations

import argparse
import csv
import json
import re
import time
import unicodedata
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urljoin, urlparse
from urllib.request import Request, urlopen
from urllib.robotparser import RobotFileParser

from lxml import html


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "outputs"
DEFAULT_CONFIG = ROOT / "sources.json"
PRICE_RE = re.compile(
    r"(?:COP\s*)?\$\s*([0-9]{1,3}(?:[.,][0-9]{3})+|[0-9]+(?:[.,][0-9]{1,2})?)"
    r"(?=(?:[1-9]\s*(?:d[ií]as?|a\s+\d))|[^0-9.,]|$)", re.I
)
PROMO_RE = re.compile(
    r"(?i)\b(esfer|bol[ií]graf|lapic|resaltador|agenda|libreta|cuaderno|mug|taza|pocillo|"
    r"termo|botilit|caramañola|vaso|llavero|camiseta|polo|hoodie|buso|gorra|cachucha|"
    r"bolsa|tula|morral|malet|sombrilla|paraguas|usb|memoria|pad.?mouse|mouse.?pad|"
    r"bot[oó]n|im[aá]n|portacarn|gafete|reloj|alcanc[ií]a|kit corporativo|promocional|"
    r"sublim|estamp|personaliz|publicitari|souvenir|merchandising)"
)
TECHNIQUES = {
    "sublimacion": r"sublimaci[oó]n|sublimable|sublimado",
    "serigrafia": r"serigraf[ií]a|screen",
    "grabado_laser": r"grabado\s+l[aá]ser|marcaci[oó]n\s+l[aá]ser|corte\s+l[aá]ser|\bl[aá]ser\b",
    "impresion_laser": r"impresi[oó]n\s+l[aá]ser",
    "dtf_uv": r"dtf\s*uv",
    "dtf_textil": r"dtf\s*(?:textil)?",
    "tampografia": r"tampograf[ií]a",
    "bordado": r"bordad[oa]",
    "vinilo_textil": r"vinilo\s+textil",
    "transfer": r"\btransfer\b",
    "impresion_digital": r"impresi[oó]n\s+digital|full\s*color",
    "hot_stamping": r"hot\s*stamping",
}
FIELDS = [
    "source_id", "supplier", "city", "department", "country", "record_type",
    "product_id", "sku", "name", "category", "tags", "brand", "currency",
    "price_min", "price_max", "price_text", "price_visibility", "availability",
    "description", "subtitle", "material", "color", "size_dimensions", "capacity",
    "print_techniques", "print_area", "packaging", "minimum_order", "details_json",
    "image_url", "product_url", "source_page", "fetched_at",
]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def clean(value: Any) -> str:
    if value is None:
        return ""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", str(value))).strip()


def html_text(value: Any) -> str:
    raw = clean(value)
    if not raw:
        return ""
    try:
        return clean(html.fromstring(f"<div>{raw}</div>").text_content())
    except Exception:
        return clean(re.sub(r"<[^>]+>", " ", raw))


def ascii_key(value: Any) -> str:
    text = unicodedata.normalize("NFKD", clean(value))
    return "".join(c for c in text if not unicodedata.combining(c)).lower()


def techniques(text: str) -> str:
    folded = ascii_key(text)
    found = [name for name, pattern in TECHNIQUES.items() if re.search(pattern, folded, re.I)]
    if "dtf_uv" in found and "dtf_textil" in found and not re.search(r"dtf\s*(?:textil)(?!\s*uv)", folded):
        found.remove("dtf_textil")
    return "; ".join(found)


def first_match(patterns: Iterable[str], text: str) -> str:
    for pattern in patterns:
        match = re.search(pattern, text, re.I)
        if match:
            return clean(match.group(1))
    return ""


def inferred_fields(text: str, table: dict[str, str] | None = None) -> dict[str, str]:
    table = {ascii_key(k): clean(v) for k, v in (table or {}).items()}
    joined = " ".join(f"{k}: {v}" for k, v in table.items()) + " " + text
    pick = lambda keys: next((table[k] for k in keys if table.get(k)), "")
    return {
        "material": pick(["material", "materiales"]) or first_match([r"material\s*[:\-]\s*([^.;|]{2,100})"], joined),
        "color": pick(["color", "colores"]) or first_match([r"colores?\s*[:\-]\s*([^.;|]{2,100})"], joined),
        "size_dimensions": pick(["dimensiones", "medidas", "tamano", "talla", "alto", "ancho"]) or first_match([r"(?:dimensiones|medidas|tama[nñ]o|tallas?)\s*[:\-]\s*([^.;|]{2,130})"], joined),
        "capacity": pick(["capacidad"]) or first_match([r"capacidad\s*[:\-]\s*([^.;|]{1,80})", r"\b(\d+(?:[.,]\d+)?\s*(?:oz|ml|litros?|l))\b"], joined),
        "print_area": pick(["area de impresion", "area de marcacion", "area de impresion (el arte se adecua a esta area.)"]) or first_match([r"[aá]rea\s+(?:de\s+)?(?:impresi[oó]n|marcaci[oó]n)\s*[:\-]\s*([^.;|]{2,130})"], joined),
        "packaging": pick(["empaque", "unidad de empaque", "presentacion"]) or first_match([r"(?:empaque|presentaci[oó]n|unidad(?:es)?\s+por\s+caja)\s*[:\-]\s*([^.;|]{2,160})"], joined),
        "minimum_order": pick(["pedido minimo", "cantidad minima", "compra minima"]) or first_match([r"(?:pedido|cantidad|compra)\s+m[ií]nim[oa]\s*[:\-]?\s*([^.;|]{1,80})"], joined),
    }


def details_from_html(fragment: str) -> dict[str, str]:
    if not fragment:
        return {}
    try:
        tree = html.fromstring(f"<div>{fragment}</div>")
    except Exception:
        return {}
    result: dict[str, str] = {}
    for row in tree.xpath(".//tr"):
        cells = [clean(c.text_content()) for c in row.xpath("./th|./td")]
        if len(cells) >= 2 and cells[0]:
            result[cells[0]] = " | ".join(cells[1:])
    for strong in tree.xpath(".//strong|.//b"):
        label = clean(strong.text_content()).strip(":")
        parent = clean(strong.getparent().text_content()) if strong.getparent() is not None else ""
        value = clean(parent[len(clean(strong.text_content())):]).lstrip(": -") if parent else ""
        if label and value and len(label) <= 80 and len(value) <= 300:
            result.setdefault(label, value)
    return result


def price_number(value: Any) -> str:
    raw = clean(value).replace("$", "").replace("COP", "").replace(" ", "")
    if not raw:
        return ""
    if "," in raw and "." in raw:
        raw = raw.replace(".", "").replace(",", ".") if raw.rfind(",") > raw.rfind(".") else raw.replace(",", "")
    elif raw.count(",") == 1 and len(raw.rsplit(",", 1)[1]) <= 2:
        raw = raw.replace(",", ".")
    else:
        raw = raw.replace(",", "").replace(".", "")
    try:
        return str(Decimal(raw).quantize(Decimal("0.01")))
    except InvalidOperation:
        return ""


class Client:
    def __init__(self, user_agent: str, timeout: int, delay: float):
        self.user_agent = user_agent
        self.timeout = timeout
        self.delay = delay
        self.robots: dict[str, RobotFileParser | None] = {}
        self.last_request: dict[str, float] = defaultdict(float)

    def allowed(self, url: str) -> bool:
        parsed = urlparse(url)
        origin = f"{parsed.scheme}://{parsed.netloc}"
        if origin not in self.robots:
            rp = RobotFileParser()
            rp.set_url(origin + "/robots.txt")
            try:
                req = Request(rp.url, headers={"User-Agent": self.user_agent})
                with urlopen(req, timeout=self.timeout) as response:
                    rp.parse(response.read().decode("utf-8", "replace").splitlines())
                self.robots[origin] = rp
            except Exception:
                self.robots[origin] = None
        parser = self.robots[origin]
        return True if parser is None else parser.can_fetch(self.user_agent, url)

    def get(self, url: str) -> tuple[bytes, dict[str, str], str]:
        if not self.allowed(url):
            raise PermissionError("blocked_by_robots_txt")
        host = urlparse(url).netloc
        last_error: Exception | None = None
        for attempt in range(3):
            wait = self.delay - (time.monotonic() - self.last_request[host])
            if wait > 0:
                time.sleep(wait)
            req = Request(url, headers={"User-Agent": self.user_agent, "Accept": "text/html,application/json;q=0.9,*/*;q=0.8"})
            try:
                with urlopen(req, timeout=self.timeout) as response:
                    body = response.read()
                    self.last_request[host] = time.monotonic()
                    return body, dict(response.headers.items()), response.geturl()
            except (URLError, TimeoutError) as exc:
                last_error = exc
                if attempt < 2:
                    time.sleep(1.5 * (attempt + 1))
        assert last_error is not None
        raise last_error

    def json(self, url: str) -> tuple[Any, dict[str, str], str]:
        body, headers, final_url = self.get(url)
        return json.loads(body), headers, final_url


def base_row(source: dict[str, Any], **values: Any) -> dict[str, str]:
    row = {field: "" for field in FIELDS}
    row.update({
        "source_id": source["id"], "supplier": source["name"],
        "city": source.get("city", ""), "department": source.get("department", ""),
        "country": source.get("country", "Colombia"), "record_type": "product",
        "currency": "COP", "fetched_at": now_iso(),
    })
    row.update({key: clean(value) for key, value in values.items() if key in row})
    return row


def json_after_marker(script: str, marker_pattern: str) -> Any | None:
    match = re.search(marker_pattern, script, re.S)
    if not match:
        return None
    try:
        return json.JSONDecoder().raw_decode(script[match.end():].lstrip())[0]
    except json.JSONDecodeError:
        return None


def scrape_tienda_fla(source: dict[str, Any], client: Client, details: bool) -> list[dict[str, str]]:
    catalog: dict[str, dict[str, Any]] = {}
    for category_url in source["category_urls"]:
        body, _, final_url = client.get(category_url)
        tree = html.fromstring(body, base_url=final_url)
        category = clean(" ".join(tree.xpath("//h1[1]//text()")))
        if not category or "{{" in category:
            category = unquote(category_url.rstrip("/").split("/")[-2]).replace("-", " ").title()
        items: list[dict[str, Any]] = []
        for script in tree.xpath("//script[not(@src)]/text()"):
            value = json_after_marker(script, r"\bitems\s*:\s*")
            if isinstance(value, list):
                items = value
                break
        for item in items:
            pid = str(item.get("id", ""))
            entry = catalog.setdefault(pid, {"item": item, "categories": set(), "source_page": final_url})
            entry["categories"].add(category)

    rows: list[dict[str, str]] = []
    for pid, entry in catalog.items():
        item = entry["item"]
        slug = quote(str(item.get("url_name", "")), safe="()*+-%")
        product_url = urljoin(source["base_url"], f"/producto/{pid}/{slug}")
        detail = item
        if details:
            try:
                body, _, product_url = client.get(product_url)
                tree = html.fromstring(body, base_url=product_url)
                for script in tree.xpath("//script[not(@src)]/text()"):
                    value = json_after_marker(script, r"\bitem\s*:\s*")
                    if isinstance(value, dict) and str(value.get("id", "")) == pid:
                        detail = value
                        break
            except (HTTPError, URLError, TimeoutError, PermissionError):
                # La ficha amplía los datos, pero el registro de categoría sigue
                # siendo una evidencia pública válida si una ficha falla.
                detail = item
        description_html = detail.get("description", "")
        description = html_text(description_html)
        table = details_from_html(description_html)
        inferred = inferred_fields(description + " " + clean(detail.get("subtitle")), table)
        price_text = clean(item.get("visible_price")) or (f"${detail.get('price1')}" if detail.get("price1") else "")
        image = item.get("image", "")
        rows.append(base_row(
            source, product_id=pid, sku=detail.get("barcode") or detail.get("flaid"),
            name=detail.get("name") or item.get("name"), category="; ".join(sorted(entry["categories"])),
            brand=detail.get("brand") or item.get("brand"), price_min=price_number(price_text),
            price_max=price_number(price_text), price_text=price_text, price_visibility="public_catalog",
            availability="active" if detail.get("status", 1) else "inactive", description=description,
            subtitle=detail.get("subtitle"), print_techniques=techniques(description + " " + clean(detail.get("name"))),
            details_json=json.dumps(table, ensure_ascii=False, sort_keys=True),
            image_url=urljoin(source["base_url"], image), product_url=product_url,
            source_page=entry["source_page"], **inferred,
        ))
    return rows


def scrape_shopify(source: dict[str, Any], client: Client, _: bool) -> list[dict[str, str]]:
    catalog: dict[str, dict[str, Any]] = {}
    for collection in source["collections"]:
        for page in range(1, 101):
            url = f"{source['base_url']}/collections/{collection}/products.json?limit=250&page={page}"
            payload, _, final_url = client.json(url)
            products = payload.get("products", [])
            for product in products:
                pid = str(product.get("id", ""))
                entry = catalog.setdefault(pid, {"product": product, "categories": set(), "source_page": final_url})
                entry["categories"].add(collection.replace("-", " "))
            if len(products) < 250:
                break
    rows: list[dict[str, str]] = []
    for pid, entry in catalog.items():
        product = entry["product"]
        description_html = product.get("body_html", "")
        description = html_text(description_html)
        table = details_from_html(description_html)
        variants = product.get("variants", [])
        prices = [Decimal(str(v.get("price"))) for v in variants if clean(v.get("price"))]
        available_values = [v.get("available") for v in variants if "available" in v]
        availability = "available" if any(available_values) else ("unavailable" if available_values else "not_published")
        images = product.get("images", [])
        tags = product.get("tags", [])
        if isinstance(tags, str):
            tags = [x.strip() for x in tags.split(",") if x.strip()]
        sku = "; ".join(dict.fromkeys(clean(v.get("sku")) for v in variants if clean(v.get("sku"))))
        inferred = inferred_fields(description, table)
        combined = " ".join([product.get("title", ""), description, " ".join(tags)])
        rows.append(base_row(
            source, product_id=pid, sku=sku, name=product.get("title"),
            category="; ".join(sorted(entry["categories"])), tags="; ".join(tags),
            brand=product.get("vendor"), price_min=min(prices) if prices else "",
            price_max=max(prices) if prices else "", price_text=(f"${min(prices)} - ${max(prices)}" if prices and min(prices) != max(prices) else (f"${min(prices)}" if prices else "")),
            price_visibility="public_shopify_endpoint" if prices else "not_published", availability=availability,
            description=description, print_techniques=techniques(combined),
            details_json=json.dumps(table, ensure_ascii=False, sort_keys=True),
            image_url=(images[0].get("src", "") if images else ""),
            product_url=f"{source['base_url']}/products/{product.get('handle', '')}",
            source_page=entry["source_page"], **inferred,
        ))
    return rows


def scrape_woocommerce(source: dict[str, Any], client: Client, _: bool) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for page in range(1, 101):
        url = f"{source['base_url']}/wp-json/wc/store/v1/products?per_page=100&page={page}"
        try:
            products, headers, final_url = client.json(url)
        except HTTPError as exc:
            if exc.code == 400 and page > 1:
                break
            raise
        if not products:
            break
        for product in products:
            description_html = product.get("description", "") or product.get("short_description", "")
            description = html_text(description_html)
            category_names = [c.get("name", "") for c in product.get("categories", [])]
            categories = "; ".join(category_names)
            combined = " ".join([product.get("name", ""), description, " ".join(t.get("name", "") for t in product.get("tags", [])), " ".join(category_names)])
            if source.get("promotional_only") and not PROMO_RE.search(ascii_key(combined)):
                continue
            include_category_regex = source.get("include_category_regex")
            if include_category_regex and not re.search(include_category_regex, ascii_key(" ".join(category_names)), re.I):
                continue
            exclude_regex = source.get("exclude_regex")
            if exclude_regex and re.search(exclude_regex, ascii_key(combined), re.I):
                continue
            price = product.get("prices", {})
            minor = int(price.get("currency_minor_unit", 0) or 0)
            divisor = Decimal(10) ** minor
            low = Decimal(str(price.get("price", "0") or "0")) / divisor
            regular = Decimal(str(price.get("regular_price", "0") or "0")) / divisor
            table = details_from_html(description_html)
            inferred = inferred_fields(description, table)
            images = product.get("images", [])
            rows.append(base_row(
                source, product_id=product.get("id"), sku=product.get("sku"), name=product.get("name"),
                category=categories, tags="; ".join(t.get("name", "") for t in product.get("tags", [])),
                price_min=low if low else "", price_max=max(low, regular) if (low or regular) else "",
                price_text=(f"${low}" if low else ""), price_visibility="public_store_api" if low else "not_published",
                availability="available" if product.get("is_in_stock") else "unavailable",
                description=description, print_techniques=techniques(combined),
                details_json=json.dumps(table, ensure_ascii=False, sort_keys=True),
                image_url=(images[0].get("src", "") if images else ""), product_url=product.get("permalink"),
                source_page=final_url, **inferred,
            ))
        total_pages = int(headers.get("X-WP-TotalPages", page))
        if page >= total_pages:
            break
    return rows


def structured_products(tree: Any) -> list[dict[str, Any]]:
    found: list[dict[str, Any]] = []
    def walk(value: Any) -> None:
        if isinstance(value, dict):
            kind = value.get("@type")
            if kind == "Product" or (isinstance(kind, list) and "Product" in kind):
                found.append(value)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    for script in tree.xpath('//script[@type="application/ld+json"]/text()'):
        try:
            walk(json.loads(script))
        except json.JSONDecodeError:
            continue
    return found


def generic_price_blocks(tree: Any) -> list[tuple[str, str, str]]:
    candidates: list[tuple[int, str, str, str]] = []
    for element in tree.xpath("//article|//li|//section|//div"):
        text = clean(element.text_content())
        matches = PRICE_RE.findall(text)
        if not matches or len(text) < 5 or len(text) > 650 or not PROMO_RE.search(ascii_key(text)):
            continue
        headings = element.xpath(".//h2[1]//text()|.//h3[1]//text()|.//h4[1]//text()|.//*[contains(@class,'title')][1]//text()")
        name = clean(" ".join(headings))
        if not name or len(name) > 160:
            lines = [clean(x) for x in text.splitlines() if clean(x)]
            name = next((x for x in lines if not PRICE_RE.search(x) and len(x) <= 160), "")
        if name:
            links = element.xpath(".//a[@href][1]/@href")
            candidates.append((len(text), name, "$" + clean(matches[0]), urljoin(tree.base_url or "", links[0]) if links else (tree.base_url or "")))
    result: list[tuple[str, str, str]] = []
    seen: set[tuple[str, str]] = set()
    for _, name, price, url in sorted(candidates):
        key = (ascii_key(name), price)
        if key not in seen:
            seen.add(key)
            result.append((name, price, url))
    return result[:250]


def scrape_generic(source: dict[str, Any], client: Client, _: bool) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for page_url in source["page_urls"]:
        body, _, final_url = client.get(page_url)
        tree = html.fromstring(body, base_url=final_url)
        for product in structured_products(tree):
            name = clean(product.get("name"))
            if not name or ascii_key(name) in seen:
                continue
            seen.add(ascii_key(name))
            offers = product.get("offers", {})
            if isinstance(offers, list):
                offers = offers[0] if offers else {}
            description = html_text(product.get("description"))
            image = product.get("image", "")
            if isinstance(image, list): image = image[0] if image else ""
            if isinstance(image, dict): image = image.get("url", "")
            inferred = inferred_fields(description)
            rows.append(base_row(
                source, product_id=product.get("sku"), sku=product.get("sku"), name=name,
                brand=(product.get("brand", {}).get("name", "") if isinstance(product.get("brand"), dict) else product.get("brand", "")),
                price_min=offers.get("lowPrice") or offers.get("price"), price_max=offers.get("highPrice") or offers.get("price"),
                price_text=("$" + clean(offers.get("price")) if offers.get("price") else ""),
                price_visibility="public_page" if offers.get("price") else "not_published",
                availability=clean(offers.get("availability", "")).rsplit("/", 1)[-1], description=description,
                print_techniques=techniques(name + " " + description), image_url=image,
                product_url=product.get("url") or final_url, source_page=final_url, **inferred,
            ))
        for name, price, product_url in generic_price_blocks(tree):
            key = ascii_key(name)
            if key in seen:
                continue
            seen.add(key)
            text = name
            rows.append(base_row(
                source, name=name, price_min=price_number(price), price_max=price_number(price),
                price_text=price, price_visibility="public_page", availability="not_published",
                description=text, print_techniques=techniques(text), product_url=product_url or final_url,
                source_page=final_url, **inferred_fields(text),
            ))
    return rows


ADAPTERS = {
    "tienda_fla": scrape_tienda_fla,
    "shopify_collections": scrape_shopify,
    "woocommerce_store_api": scrape_woocommerce,
    "generic_public_page": scrape_generic,
}


def write_outputs(rows: list[dict[str, str]], errors: list[dict[str, str]]) -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    rows.sort(key=lambda r: (r["supplier"].casefold(), r["category"].casefold(), r["name"].casefold()))
    with (OUTPUT / "catalogo_promocionales_colombia.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDS)
        writer.writeheader(); writer.writerows(rows)
    with (OUTPUT / "catalogo_promocionales_colombia.jsonl").open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    with (OUTPUT / "errores.csv").open("w", newline="", encoding="utf-8-sig") as fh:
        writer = csv.DictWriter(fh, fieldnames=["source_id", "url", "error", "fetched_at"])
        writer.writeheader(); writer.writerows(errors)
    by_source = defaultdict(int)
    for row in rows: by_source[row["source_id"]] += 1
    summary = {
        "generated_at": now_iso(), "rows": len(rows), "errors": len(errors),
        "by_source": dict(sorted(by_source.items())),
        "with_price": sum(bool(r["price_min"]) for r in rows),
        "with_description": sum(bool(r["description"]) for r in rows),
        "with_print_technique": sum(bool(r["print_techniques"]) for r in rows),
        "method": "Public catalog pages/APIs only; robots.txt honored; missing fields remain blank.",
    }
    (OUTPUT / "resumen.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))


def run(args: argparse.Namespace) -> None:
    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    client = Client(config["user_agent"], int(config.get("timeout_seconds", 30)), float(config.get("request_delay_seconds", 0.5)))
    wanted = set(args.sources.split(",")) if args.sources else set()
    rows: list[dict[str, str]] = []
    if args.append and wanted and (OUTPUT / "catalogo_promocionales_colombia.csv").exists():
        with (OUTPUT / "catalogo_promocionales_colombia.csv").open(encoding="utf-8-sig", newline="") as fh:
            rows = [row for row in csv.DictReader(fh) if row.get("source_id") not in wanted]
    errors: list[dict[str, str]] = []
    for source in config["sources"]:
        if wanted and source["id"] not in wanted:
            continue
        print(f"[{source['id']}] {source['name']}")
        try:
            found = ADAPTERS[source["adapter"]](source, client, not args.no_details)
            rows.extend(found)
            print(f"  {len(found):,} registros")
        except (HTTPError, URLError, TimeoutError, PermissionError, ValueError, KeyError) as exc:
            errors.append({"source_id": source["id"], "url": source.get("base_url", ""), "error": f"{type(exc).__name__}: {exc}", "fetched_at": now_iso()})
            print(f"  ERROR: {exc}")
    write_outputs(rows, errors)


def verify(_: argparse.Namespace) -> None:
    path = OUTPUT / "catalogo_promocionales_colombia.csv"
    if not path.exists():
        raise SystemExit("No existe el catálogo. Ejecute primero: python scraper.py run")
    with path.open(encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.DictReader(fh))
    assert rows, "El catálogo está vacío"
    assert list(rows[0]) == FIELDS, "Columnas inesperadas"
    assert all(r["name"] and r["product_url"] and r["source_id"] for r in rows), "Faltan campos mínimos"
    keys = [(r["source_id"], r["product_id"] or r["product_url"], r["name"]) for r in rows]
    assert len(keys) == len(set(keys)), "Hay productos duplicados dentro de una fuente"
    print(json.dumps({"rows": len(rows), "sources": len({r['source_id'] for r in rows}), "with_price": sum(bool(r["price_min"]) for r in rows)}, indent=2))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="command", required=True)
    crawl = sub.add_parser("run", help="Descargar y consolidar catálogos públicos")
    crawl.add_argument("--config", default=str(DEFAULT_CONFIG))
    crawl.add_argument("--sources", help="IDs separados por coma; vacío = todas")
    crawl.add_argument("--append", action="store_true", help="Conservar en la salida las fuentes no ejecutadas")
    crawl.add_argument("--no-details", action="store_true", help="No abrir cada ficha de Tienda FLA")
    crawl.set_defaults(func=run)
    check = sub.add_parser("verify", help="Validar la última salida")
    check.set_defaults(func=verify)
    return result


if __name__ == "__main__":
    args = parser().parse_args()
    args.func(args)
