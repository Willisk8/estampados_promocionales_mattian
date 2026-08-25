#!/usr/bin/env python3
"""Scraper auditable de precios de técnicas de personalización en Colombia."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import time
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from urllib.robotparser import RobotFileParser
from urllib.parse import urlparse

from lxml import html


ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = ROOT / "sources.json"
DEFAULT_OUTPUT = ROOT / "outputs"

PRICE_FIELDS = [
    "observation_id", "source_id", "supplier", "city", "technique",
    "service_component", "price_scope", "compatible_products",
    "compatible_materials", "size_label", "width_cm", "height_cm",
    "quantity_min", "quantity_max", "billing_unit", "currency",
    "price_value", "price_min", "price_max", "tax_status", "conditions",
    "evidence_text", "source_url", "fetched_at", "http_status",
    "verification_status"
]

CATALOG_FIELDS = [
    "technique", "aliases", "compatible_products", "compatible_materials",
    "best_for", "limitations", "typical_cost_drivers", "source_url",
    "fetched_at", "verification_status"
]

ERROR_FIELDS = ["source_id", "supplier", "source_url", "fetched_at", "error_type", "detail"]

SNAPSHOT_IDENTITY_FIELDS = [
    "source_id", "supplier", "city", "technique", "service_component",
    "price_scope", "compatible_products", "compatible_materials",
    "size_label", "width_cm", "height_cm", "quantity_min", "quantity_max",
    "billing_unit", "currency", "price_value", "price_min", "price_max",
    "tax_status", "conditions", "evidence_text", "source_url", "fetched_at",
    "http_status", "verification_status"
]


TECHNIQUE_CATALOG = [
    ["sublimacion", "sublimado", "mugs; termos recubiertos; camisetas deportivas; telas; cojines; cintas", "poliéster claro; cerámica o metal con recubrimiento sublimable", "fotografías y full color; tacto cero en textil", "no funciona directamente sobre algodón oscuro ni objetos sin recubrimiento", "tamaño; cantidad; tipo de blanco; calandra o plancha"],
    ["dtf_textil", "DTF; direct to film", "camisetas; polos; hoodies; gorras; bolsos; uniformes", "algodón; poliéster; mezclas; textiles claros y oscuros", "full color desde pocas unidades", "requiere termofijado; tacto perceptible según área", "área o metro lineal; cantidad; aplicación incluida o solo transfer"],
    ["dtf_uv", "DTF UV; UV DTF", "mugs; termos; botellas; agendas; esferos; vidrio; acrílico; metal; plástico", "superficies rígidas lisas", "logos full color sin calor y tirajes cortos", "no es la opción ideal para superficies muy flexibles o rugosas", "área; metro lineal; barniz; aplicación"],
    ["vinilo_textil", "HTV; vinilo termoadhesivo", "camisetas; buzos; gorras; uniformes; bolsas", "textiles compatibles con calor", "nombres, números, colores planos y tirajes cortos", "cada color exige corte y depilado; menos conveniente para detalles complejos", "centímetros cuadrados; colores; depilado; cantidad"],
    ["serigrafia", "screen; screen printing", "camisetas; bolsas; agendas; papel; plásticos planos", "textil; papel; algunos rígidos según tinta", "tirajes medianos y grandes con pocos colores", "cada color requiere pantalla y preparación; mínimos frecuentes", "número de tintas; pantallas; tamaño; cantidad"],
    ["tampografia", "pad printing; tampografía", "esferos; llaveros; promocionales pequeños; piezas curvas", "plástico; metal; vidrio; superficies curvas", "marcación pequeña y repetitiva en piezas irregulares", "área limitada y costos de cliché/preparación", "tintas; cliché; posiciones; cantidad"],
    ["bordado", "bordado computarizado", "polos; camisas; gorras; chaquetas; morrales; parches", "textiles con estabilidad suficiente", "acabado corporativo durable", "detalle mínimo y costo dependen de puntadas; requiere programa", "digitalización/programa; puntadas; tamaño; prendas; cantidad"],
    ["grabado_laser", "marcación láser; laser engraving", "termos; esferos metálicos; llaveros; madera; cuero; acrílico", "metal; madera; cuero; acrílico y otros según equipo", "marca permanente y precisa", "resultado de color limitado al material; pruebas recomendadas", "tiempo máquina; área; material; cantidad"],
    ["impresion_uv_directa", "UV plana; cama plana UV", "agendas; placas; acrílico; madera; metal; vidrio; promocionales", "superficies rígidas y algunos flexibles", "full color directo, tinta blanca y barniz", "requiere fijación/calce y superficie adecuada", "área; montaje; tinta blanca; capas de barniz; material"],
    ["hot_stamping", "hot foil; estampado en caliente; termoestampado", "agendas; cuadernos; empaques; cuero; papel", "papel; cartón; cuero y sintéticos compatibles", "acabado metálico premium", "requiere cliché y es menos apto para imágenes fotográficas", "cliché; área; color foil; cantidad"],
    ["transfer", "transfer térmico", "camisetas; textiles; algunos rígidos", "depende del papel/film y sustrato", "tirajes cortos y diseños digitales", "durabilidad y tacto varían por sistema", "tamaño; papel/film; aplicación; cantidad"],
    ["escudo_tpu", "parche TPU; escudo 3D", "uniformes deportivos; gorras; morrales; prendas", "textiles mediante costura o termofijado", "relieve, durabilidad y apariencia deportiva", "molde y mínimos pueden encarecer tirajes cortos", "molde; tamaño; cantidad; aplicación"]
]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def clean(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "")).strip()


def identity_value(value: Any) -> str:
    return clean(value)


def make_observation_id(row: dict[str, Any]) -> str:
    payload = {field: identity_value(row.get(field)) for field in SNAPSHOT_IDENTITY_FIELDS}
    payload["_identity_version"] = "snapshot-v2"
    return hashlib.sha256(
        json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()[:32]


def fold(value: Any) -> str:
    text = unicodedata.normalize("NFKD", clean(value))
    return "".join(ch for ch in text if not unicodedata.combining(ch)).lower()


def parse_money(value: str) -> float | None:
    raw = re.sub(r"[^0-9.,]", "", value or "")
    if not raw:
        return None
    if "," in raw and "." in raw:
        raw = raw.replace(".", "").replace(",", ".") if raw.rfind(",") > raw.rfind(".") else raw.replace(",", "")
    elif raw.count(".") > 1 or ("." in raw and len(raw.rsplit(".", 1)[1]) == 3):
        raw = raw.replace(".", "")
    elif raw.count(",") > 1 or ("," in raw and len(raw.rsplit(",", 1)[1]) == 3):
        raw = raw.replace(",", "")
    else:
        raw = raw.replace(",", ".")
    try:
        return float(raw)
    except ValueError:
        return None


class Client:
    def __init__(self, user_agent: str, timeout: int, delay: float):
        self.user_agent = user_agent
        self.timeout = timeout
        self.delay = delay
        self.robots: dict[str, RobotFileParser | None] = {}
        self.last_request: dict[str, float] = {}

    def allowed(self, url: str) -> bool:
        parsed = urlparse(url)
        origin = f"{parsed.scheme}://{parsed.netloc}"
        if origin not in self.robots:
            rp = RobotFileParser(origin + "/robots.txt")
            try:
                req = Request(rp.url, headers={"User-Agent": self.user_agent})
                with urlopen(req, timeout=self.timeout) as response:
                    rp.parse(response.read().decode("utf-8", "replace").splitlines())
                self.robots[origin] = rp
            except Exception:
                self.robots[origin] = None
        parser = self.robots[origin]
        return True if parser is None else parser.can_fetch(self.user_agent, url)

    def get(self, url: str) -> tuple[str, int, str]:
        if not self.allowed(url):
            raise PermissionError("blocked_by_robots_txt")
        host = urlparse(url).netloc
        wait = self.delay - (time.monotonic() - self.last_request.get(host, 0))
        if wait > 0:
            time.sleep(wait)
        req = Request(url, headers={"User-Agent": self.user_agent, "Accept": "text/html,application/xhtml+xml"})
        with urlopen(req, timeout=self.timeout) as response:
            body = response.read()
            self.last_request[host] = time.monotonic()
            encoding = response.headers.get_content_charset() or "utf-8"
            return body.decode(encoding, "replace"), response.status, response.geturl()


def page_text(raw_html: str) -> str:
    tree = html.fromstring(raw_html)
    for bad in tree.xpath("//script|//style|//noscript|//svg"):
        bad.drop_tree()
    return clean(tree.text_content())


def evidence(text: str, start: int, end: int, pad: int = 90) -> str:
    return clean(text[max(0, start - pad): min(len(text), end + pad)])[:500]


def add_row(rows: list[dict[str, Any]], source: dict[str, Any], fetched_at: str, http_status: int,
            technique: str, component: str, scope: str, billing_unit: str,
            price: float | None, ev: str, **kwargs: Any) -> None:
    if price is None and not kwargs.get("price_min") and not kwargs.get("price_max"):
        return
    row = {field: "" for field in PRICE_FIELDS}
    row.update({
        "source_id": source["id"], "supplier": source["supplier"], "city": source["city"],
        "technique": technique, "service_component": component, "price_scope": scope,
        "billing_unit": billing_unit, "currency": "COP", "price_value": price,
        "evidence_text": ev, "source_url": source["url"], "fetched_at": fetched_at,
        "http_status": http_status, "verification_status": "VERIFIED_PUBLIC_PRICE"
    })
    row.update({k: v for k, v in kwargs.items() if k in row})
    row["observation_id"] = make_observation_id(row)
    rows.append(row)


def find_price(text: str, pattern: str) -> tuple[float | None, str]:
    match = re.search(pattern, text, re.I)
    return (parse_money(match.group("price")), evidence(text, match.start(), match.end())) if match else (None, "")


def parse_ink_dtf(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    sizes = [
        ("Marquilla 5-7 cm", "marquilla", "5-7 cm"), ("Bolsillo 8-12 cm", "bolsillo", "8-12 cm"),
        ("Media carta 15-18 cm", "media carta", "15-18 cm"), ("Carta 21x28 cm", "carta", "21 x 28 cm"),
        ("Tabloide 29x38 cm", "tabloide", "29 x 38 cm")
    ]
    quantities = [1, 12, 50, 100]
    for label, token, dims in sizes:
        block = re.search(rf"{token}[^$]{{0,180}}((?:\$\s*[0-9.,]+[^$]*){{4}})", text, re.I)
        if not block:
            continue
        prices = re.findall(r"\$\s*([0-9][0-9.,]*)", block.group(0))[:4]
        for qty, raw in zip(quantities, prices):
            add_row(rows, source, at, status, "dtf_textil", "impresion_y_transfer", "solo_marcacion",
                    "unidad", parse_money(raw), evidence(text, block.start(), block.end()), size_label=label,
                    quantity_min=qty, quantity_max={1: 11, 12: 49, 50: 99, 100: ""}[qty],
                    compatible_products="camisetas; hoodies; chaquetas; textiles",
                    compatible_materials="algodón; poliéster; mezclas",
                    conditions="Full color; precio publicado por tamaño y escala")
    return rows


def parse_mugnifico(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    products = [
        ("Mug blanco 11 oz", r"blanco\s+11\s*oz", "mug cerámica blanco 11 oz"),
        ("Mug interior y oreja color 11 oz", r"interior\s+y\s+oreja\s+(?:de\s+)?color\s+11\s*oz", "mug cerámica 11 oz"),
        ("Mini mug 6 oz", r"mini\s+mug\s+6\s*oz", "mini mug cerámica 6 oz"),
        ("Mug tapa y base silicona 11 oz", r"tapa\s+y\s+base\s+silicona\s+11\s*oz", "mug 11 oz con silicona")
    ]
    starts: list[tuple[int, str, str]] = []
    for label, pattern, product in products:
        m = re.search(pattern, text, re.I)
        if m:
            starts.append((m.start(), label, product))
    starts.sort()
    for idx, (pos, label, product) in enumerate(starts):
        end = starts[idx + 1][0] if idx + 1 < len(starts) else min(len(text), pos + 1000)
        block = text[pos:end]
        seen_quantities: set[int] = set()
        for match in re.finditer(r"(\d+)\s*(?:-|–|a)\s*(\d+)|(?P<open>\d+)\s+en\s+adelante", block, re.I):
            qmin = int(match.group("open") or match.group(1))
            # Wix repite el mismo contenido para distintas vistas responsivas.
            if qmin in seen_quantities:
                continue
            qmax = "" if match.group("open") else int(match.group(2))
            tail = block[match.end():match.end() + 80]
            pm = re.search(r"\$\s*([0-9][0-9.,]*)", tail)
            if pm:
                seen_quantities.add(qmin)
                add_row(rows, source, at, status, "sublimacion", "producto_mas_personalizacion",
                        "producto_personalizado", "unidad", parse_money(pm.group(1)),
                        clean(block[max(0, match.start()-30):match.end()+pm.end()+20]),
                        size_label=label, quantity_min=qmin, quantity_max=qmax,
                        compatible_products=product, compatible_materials="cerámica sublimable",
                        conditions="Precio incluye el mug personalizado; no aisla el costo de marcación")
    return rows


def parse_innova_laser(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    anchor = re.search(r"CORTE Y GRABADO L[AÁ]SER", text, re.I)
    if not anchor:
        return rows
    block = text[anchor.start():anchor.start() + 1800]
    match = re.search(r"Precio desde.{0,120}?\$\s*(30[.,]?000).{0,120}?\$\s*(80[.,]?000).{0,80}?100\s*u", block, re.I)
    if not match:
        return rows
    add_row(rows, source, at, status, "grabado_laser", "corte_y_grabado", "servicio_por_lote", "100 unidades",
            None, clean(block[max(0, match.start()-50):match.end()+50]), price_min=parse_money(match.group(1)),
            price_max=parse_money(match.group(2)), quantity_min=100,
            compatible_materials="acrílico; MDF; cuero; sintéticos",
            conditions="Rango publicado por 100 unidades; alcance depende del trabajo")
    return rows


def parse_expresa(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    specs = [
        ("dtf_textil", "impresion", "metro lineal", r"DTF Premium.{0,260}?desde\s*5\s*m\s*:\s*\$\s*(?P<price>[0-9.,]+)", {"quantity_min": 5, "width_cm": 58}),
        ("dtf_textil", "impresion", "metro lineal", r"base\s*\$\s*(?P<price>[0-9.,]+)\s*/\s*m", {"quantity_min": 1, "width_cm": 58}),
        ("dtf_uv", "impresion", "metro lineal", r"DTF UV.{0,220}?\$\s*(?P<price>[0-9.,]+)\s*/\s*metro", {"width_cm": 58}),
        ("bordado", "programa_digitalizacion", "programa", r"Programa digital\s*:\s*\$\s*(?P<price>[0-9.,]+)", {"quantity_min": 1}),
        ("escudo_tpu", "fabricacion", "unidad", r"30\s*uds\s*:\s*\$\s*(?P<price>[0-9.,]+)", {"quantity_min": 30, "quantity_max": 49}),
        ("escudo_tpu", "fabricacion", "unidad", r"50\s*uds\s*:\s*\$\s*(?P<price>[0-9.,]+)", {"quantity_min": 50, "quantity_max": 99}),
        ("escudo_tpu", "fabricacion", "unidad", r"100\s*uds\s*:\s*\$\s*(?P<price>[0-9.,]+)", {"quantity_min": 100}),
        ("vinilo_alta_densidad", "material_impreso", "pliego", r"44\s*[x×]\s*49\s*cm\s*:\s*\$\s*(?P<price>[0-9.,]+)", {"size_label": "44 x 49 cm", "width_cm": 44, "height_cm": 49}),
        ("vinilo_alta_densidad", "material_impreso", "pliego", r"44\s*[x×]\s*100\s*cm\s*:\s*\$\s*(?P<price>[0-9.,]+)", {"size_label": "44 x 100 cm", "width_cm": 44, "height_cm": 100})
    ]
    for technique, component, unit, pattern, extra in specs:
        price, ev = find_price(text, pattern)
        add_row(rows, source, at, status, technique, component, "solo_servicio", unit, price, ev,
                compatible_products="textiles y promocionales según técnica", conditions="Precio público del servicio o componente", **extra)
    return rows


def parse_single(text: str, source: dict[str, Any], at: str, status: int, technique: str,
                 component: str, scope: str, unit: str, pattern: str, **extra: Any) -> list[dict[str, Any]]:
    price, ev = find_price(text, pattern)
    rows: list[dict[str, Any]] = []
    add_row(rows, source, at, status, technique, component, scope, unit, price, ev, **extra)
    return rows


def parse_imprinco_vinilo(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    base = re.search(r"\$\s*([0-9.,]+)\s*-\s*\$\s*([0-9.,]+)", text)
    if base:
        add_row(rows, source, at, status, "vinilo_textil", "corte_y_aplicacion", "solo_marcacion", "cm2",
                None, evidence(text, base.start(), base.end()), price_min=parse_money(base.group(1)),
                price_max=parse_money(base.group(2)), quantity_min=1, compatible_products="camisetas; buzos; gorras; uniformes",
                compatible_materials="textiles compatibles con calor", conditions="Precio por cm² y por color")
    for qmin, qmax, pattern in [(50, 99, r"50\s+99\s+\$\s*(?P<price>[0-9.,]+)"), (100, 999, r"100\s+999\s+\$\s*(?P<price>[0-9.,]+)")]:
        price, ev = find_price(text, pattern)
        add_row(rows, source, at, status, "vinilo_textil", "corte_y_aplicacion", "solo_marcacion", "cm2", price, ev,
                quantity_min=qmin, quantity_max=qmax, compatible_products="camisetas; buzos; gorras; uniformes",
                compatible_materials="textiles compatibles con calor", conditions="Precio por cm² y por color")
    return rows


def parse_disenco(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    specs = [
        ("dtf_textil", "impresion", "metro lineal", r"DTF Textil Premium.{0,180}?Desde\s*\$\s*(?P<price>[0-9.,]+)\s*/\s*m"),
        ("dtf_uv", "impresion", "metro lineal", r"DTF UV para R[ií]gidos.{0,180}?Desde\s*\$\s*(?P<price>[0-9.,]+)\s*/\s*m"),
        ("sublimacion", "calandra", "metro lineal", r"Sublimaci[oó]n en Calandra.{0,180}?Desde\s*\$\s*(?P<price>[0-9.,]+)\s*/\s*m")
    ]
    rows: list[dict[str, Any]] = []
    for technique, component, unit, pattern in specs:
        price, ev = find_price(text, pattern)
        add_row(rows, source, at, status, technique, component, "solo_servicio", unit, price, ev,
                conditions="Precio publicado como 'desde'; confirmar archivo, ancho y cantidad")
    return rows


def parse_dayarve(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for qmin, qmax, pat in [
        (10, 49, r"10\s*[–-]\s*49\s*uds\s*\$\s*(?P<price>[0-9.,]+)"),
        (50, 99, r"50\s*[–-]\s*99\s*uds\s*\$\s*(?P<price>[0-9.,]+)"),
        (100, "", r"100\s*\+\s*uds\s*\$\s*(?P<price>[0-9.,]+)")]:
        price, ev = find_price(text, pat)
        add_row(rows, source, at, status, "bordado", "producto_mas_personalizacion", "producto_personalizado", "unidad",
                price, ev, quantity_min=qmin, quantity_max=qmax, compatible_products="polo",
                conditions="Incluye polo y una posición de bordado; valor ilustrativo sujeto a cotización")
    return rows


def parse_printeam(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    return parse_single(text, source, at, status, "acabado_agenda_multitecnica", "producto_mas_personalizacion",
                        "producto_personalizado", "unidad", r"agenda personalizada 2027.{0,180}?desde\s*\$\s*(?P<price>[0-9.,]+)",
                        quantity_min=20, compatible_products="agenda", compatible_materials="papel; cartón; cubierta",
                        conditions="Puede incluir impresión full color; hot foil, relieve o termoestampado son opciones, no costos aislados")


def parse_sm_techniques(text: str, source: dict[str, Any], at: str, status: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    specs = [("serigrafia", "Serigraf[ií]a\s*-\s*Screen Textil"), ("sublimacion", "Sublimaci[oó]n\s*-\s*Branditex"), ("tampografia", "Tampograf[ií]a\s*-\s*R[ií]gidos")]
    for technique, label in specs:
        price, ev = find_price(text, label + r"\s*Precio\s*\$\s*(?P<price>[0-9.,]+)")
        add_row(rows, source, at, status, technique, "marcacion", "solo_marcacion", "unidad_configuracion_web", price, ev,
                verification_status="NEEDS_REVIEW_UNIT", conditions="La página publica valor sin aclarar escala/unidad; validar antes de costear")
        if rows:
            rows[-1]["verification_status"] = "NEEDS_REVIEW_UNIT"
    return rows


PARSERS: dict[str, Callable[[str, dict[str, Any], str, int], list[dict[str, Any]]]] = {
    "ink_dtf": parse_ink_dtf,
    "mugnifico": parse_mugnifico,
    "expresa": parse_expresa,
    "arte_sublimacion": lambda t, s, a, h: parse_single(t, s, a, h, "sublimacion", "impresion_y_preparacion", "solo_marcacion", "impresion A4", r"\$\s*(?P<price>3[.,]?500).{0,100}?Precio por Impresi[oó]n A4", size_label="A4 21 x 29.7 cm", width_cm=21, height_cm=29.7, compatible_products="mugs; prendas de poliéster", compatible_materials="poliéster +70%; cerámica sublimable", conditions="Incluye preparación del diseño"),
    "arte_dtf": lambda t, s, a, h: parse_single(t, s, a, h, "dtf_textil", "producto_mas_personalizacion", "producto_personalizado", "unidad", r"Desde\s*\$\s*(?P<price>36[.,]?900)", quantity_min=1, compatible_products="camiseta", conditions="Incluye camiseta, DTF y asistencia de diseño; varía por tamaño y posiciones"),
    "maitex": lambda t, s, a, h: parse_single(t, s, a, h, "dtf_textil", "impresion", "solo_servicio", "metro lineal", r"Impresi[oó]n por metro en DTF.{0,120}?\$\s*(?P<price>23[.,]?000)", conditions="Impresión DTF por metro; confirmar ancho y aplicación"),
    "imprinco_vinilo": parse_imprinco_vinilo,
    "publicitar_dtf_uv": lambda t, s, a, h: parse_single(t, s, a, h, "dtf_uv", "impresion_y_aplicacion", "solo_marcacion", "unidad", r"\$\s*(?P<price>32[.,]?400)\s*\+\s*IVA", size_label="máximo 7 x 10 cm", width_cm=7, height_cm=10, quantity_min=1, tax_status="EXCLUYE_IVA", conditions="Página también muestra texto '1 unidad sin marca'; revisar alcance exacto antes de compra"),
    "disenco": parse_disenco,
    "innova_laser": parse_innova_laser,
    "smartpoint_uv": lambda t, s, a, h: parse_single(t, s, a, h, "impresion_uv_directa", "impresion_y_montaje", "cotizador_referencial", "unidad", r"TOTAL A COBRAR\s*\$\s*(?P<price>18[.,]?000)", quantity_min=1, conditions="Escenario predeterminado del cotizador; costo de fabricación mostrado $7.814 y montaje $3.000; recalcular con medidas reales"),
    "dayarve": parse_dayarve,
    "lucky": lambda t, s, a, h: parse_single(t, s, a, h, "dtf_textil", "producto_mas_personalizacion", "producto_personalizado", "unidad", r"Precio por unidad \(detal\).{0,80}?\$\s*(?P<price>60[.,]?000)", quantity_min=1, compatible_products="camiseta", conditions="Incluye camiseta y estampado full color; mayorista desde 12 unidades solo cotización"),
    "printeam": parse_printeam,
    "sm_techniques": parse_sm_techniques
}


def write_csv(path: Path, fields: list[str], rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def run(config_path: Path, output_dir: Path, selected: set[str] | None = None) -> dict[str, Any]:
    config = json.loads(config_path.read_text(encoding="utf-8"))
    client = Client(config["user_agent"], config["timeout_seconds"], config["request_delay_seconds"])
    rows: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    fetched_sources = 0
    for source in config["sources"]:
        if selected and source["id"] not in selected:
            continue
        at = now_iso()
        try:
            raw, http_status, final_url = client.get(source["url"])
            source = {**source, "url": final_url}
            text = page_text(raw)
            parsed = PARSERS[source["parser"]](text, source, at, http_status)
            if not parsed:
                raise ValueError("price_patterns_not_found")
            rows.extend(parsed)
            fetched_sources += 1
            print(f"[OK] {source['id']}: {len(parsed)} precios", flush=True)
        except Exception as exc:
            errors.append({"source_id": source["id"], "supplier": source["supplier"], "source_url": source["url"],
                           "fetched_at": at, "error_type": type(exc).__name__, "detail": clean(exc)[:500]})
            print(f"[ERROR] {source['id']}: {type(exc).__name__}: {exc}", flush=True)

    source_by_id = {s["id"]: s for s in config["sources"]}
    catalog_sources = {
        "sublimacion": "arte_creaciones_sublimacion", "dtf_textil": "ink_bordados_dtf",
        "dtf_uv": "publicitar_dtf_uv", "vinilo_textil": "imprinco_vinilo",
        "serigrafia": "sm_impresion_tecnicas", "tampografia": "sm_impresion_tecnicas",
        "bordado": "expresa_tus_ideas", "grabado_laser": "innova_laser",
        "impresion_uv_directa": "smartpoint_uv", "hot_stamping": "printeam_agendas",
        "transfer": "ink_bordados_dtf", "escudo_tpu": "expresa_tus_ideas"
    }
    catalog_rows = []
    for item in TECHNIQUE_CATALOG:
        technique = item[0]
        ref = source_by_id[catalog_sources[technique]]
        catalog_rows.append(dict(zip(CATALOG_FIELDS[:-3], item), source_url=ref["url"], fetched_at=now_iso(),
                                 verification_status="TECHNICAL_REFERENCE"))
    write_csv(output_dir / "precios_tecnicas_personalizacion.csv", PRICE_FIELDS, rows)
    write_csv(output_dir / "catalogo_tecnicas.csv", CATALOG_FIELDS, catalog_rows)
    write_csv(output_dir / "errores.csv", ERROR_FIELDS, errors)
    summary = {
        "generated_at": now_iso(), "configured_sources": len(config["sources"]), "fetched_sources": fetched_sources,
        "price_observations": len(rows), "techniques_with_prices": dict(Counter(r["technique"] for r in rows)),
        "verification_statuses": dict(Counter(r["verification_status"] for r in rows)), "errors": len(errors),
        "output_dir": str(output_dir.resolve()),
        "warning": "Precios observados, no cotizaciones. No combinar costos de producto personalizado con costos puros de marcación."
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "resumen.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


def verify(output_dir: Path) -> dict[str, Any]:
    with (output_dir / "precios_tecnicas_personalizacion.csv").open(encoding="utf-8-sig") as handle:
        prices = list(csv.DictReader(handle))
    summary_path = output_dir / "resumen.json"
    summary = json.loads(summary_path.read_text(encoding="utf-8")) if summary_path.exists() else {}
    scraper_errors_path = output_dir / "errores.csv"
    scraper_errors = []
    if scraper_errors_path.exists():
        with scraper_errors_path.open(encoding="utf-8-sig") as handle:
            scraper_errors = list(csv.DictReader(handle))
    errors: list[str] = []
    warnings: list[str] = []
    if not prices:
        errors.append("no_price_observations")
    if not {r.get("source_id", "") for r in prices if r.get("source_id", "")}:
        errors.append("no_sources_captured")
    if summary:
        if int(summary.get("fetched_sources") or 0) <= 0:
            errors.append("summary_no_fetched_sources")
        if int(summary.get("price_observations") or -1) != len(prices):
            errors.append("summary_price_observations_mismatch")
        if int(summary.get("configured_sources") or 0) <= 0:
            errors.append("summary_no_configured_sources")
    else:
        errors.append("missing_resumen_json")
    if scraper_errors:
        warnings.append("scraper_errors_present")
    ids = [r["observation_id"] for r in prices]
    if len(ids) != len(set(ids)):
        errors.append("duplicate_observation_id")
    for idx, row in enumerate(prices, 2):
        if not row["source_url"].startswith("https://"):
            errors.append(f"row_{idx}_invalid_url")
        values = [row["price_value"], row["price_min"], row["price_max"]]
        if not any(v and float(v) > 0 for v in values):
            errors.append(f"row_{idx}_missing_positive_price")
        if not row["evidence_text"]:
            errors.append(f"row_{idx}_missing_evidence")
        if row["price_scope"] == "producto_personalizado" and row["service_component"] == "solo_marcacion":
            errors.append(f"row_{idx}_scope_component_conflict")
    result = {
        "rows": len(prices),
        "sources": len({r.get("source_id", "") for r in prices if r.get("source_id", "")}),
        "techniques": len(set(r["technique"] for r in prices)),
        "scraper_errors": len(scraper_errors),
        "warnings": warnings,
        "errors": errors,
        "ok": not errors,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    run_p = sub.add_parser("run")
    run_p.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    run_p.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    run_p.add_argument("--sources", default="")
    verify_p = sub.add_parser("verify")
    verify_p.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    if args.command == "run":
        selected = {x.strip() for x in args.sources.split(",") if x.strip()} or None
        print(json.dumps(run(args.config, args.output_dir, selected), ensure_ascii=False, indent=2))
        return 0
    return 0 if verify(args.output_dir)["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
