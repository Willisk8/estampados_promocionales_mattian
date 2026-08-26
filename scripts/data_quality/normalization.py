"""Reglas reutilizables de normalizacion, sin modificar el dato fuente.

El texto canonico conserva tildes y caracteres significativos en Unicode NFC.
Las claves ASCII se generan por separado y solo se usan para busqueda/matching.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import re
import unicodedata
from urllib.parse import urlsplit, urlunsplit


FIXED_PREFIXES = frozenset({"601", "602", "604", "605", "606", "607", "608"})
MOBILE_TERRESTRIAL_PREFIXES = frozenset(
    [*(f"{value:03d}" for value in range(300, 306)),
     *(f"{value:03d}" for value in range(310, 325)), "333"]
)
MOBILE_TRUNKING_PREFIXES = frozenset({"350", "351", "352"})
MOBILE_SATELLITE_PREFIXES = frozenset({"308"})
RESERVED_MOBILE_PREFIXES = frozenset(
    ["306", "307", "309",
     *(f"{value:03d}" for value in range(325, 333)),
     *(f"{value:03d}" for value in range(334, 350)),
     *(f"{value:03d}" for value in range(353, 370)),
     *(f"{value:03d}" for value in range(371, 399)), "399"]
)
FIXED_AREA_BY_DEPARTMENT = {
    "bogota_d_c": "601", "cundinamarca": "601",
    "cauca": "602", "narino": "602", "valle_del_cauca": "602", "valle": "602",
    "antioquia": "604", "cordoba": "604", "choco": "604",
    "atlantico": "605", "bolivar": "605", "cesar": "605", "la_guajira": "605",
    "magdalena": "605", "sucre": "605",
    "caldas": "606", "quindio": "606", "risaralda": "606",
    "arauca": "607", "norte_de_santander": "607", "santander": "607",
    "amazonas": "608", "boyaca": "608", "casanare": "608", "caqueta": "608",
    "guaviare": "608", "guainia": "608", "huila": "608", "meta": "608",
    "tolima": "608", "putumayo": "608", "san_andres": "608",
    "archipielago_de_san_andres_providencia_y_santa_catalina": "608",
    "vaupes": "608", "vichada": "608",
}

EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
EMAIL_FIND_RE = re.compile(r"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I)
CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
SPACE_RE = re.compile(r"\s+")
MOJIBAKE_MARKERS = ("Ã", "Â", "â€", "ðŸ")


@dataclass(frozen=True)
class PhoneResult:
    raw: str
    national_number: str
    e164: str
    classification: str
    area_code: str = ""
    local_number: str = ""
    extension: str = ""
    status: str = "VALID"
    issue: str = ""


@dataclass(frozen=True)
class NitResult:
    raw: str
    base: str
    verification_digit: str
    verification_valid: bool | None
    status: str
    issue: str = ""


def normalize_text(value: object | None) -> str:
    """Unicode NFC, sin controles ni saltos, con espacios colapsados.

    Solo retira comillas cuando envuelven todo el valor; conserva comillas y
    apostrofes internos que pueden formar parte del nombre legal o comercial.
    """
    if value is None:
        return ""
    text = unicodedata.normalize("NFC", str(value).lstrip("\ufeff"))
    text = CONTROL_RE.sub(" ", text).replace("\r", " ").replace("\n", " ").replace("\t", " ")
    text = SPACE_RE.sub(" ", text).strip()
    pairs = (("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"))
    for left, right in pairs:
        if len(text) >= 2 and text.startswith(left) and text.endswith(right):
            text = text[len(left):-len(right)].strip()
            break
    return text


def repair_reversible_mojibake(value: object | None) -> tuple[str, bool]:
    """Repara solo mojibake latin-1/UTF-8 reversible; U+FFFD nunca se adivina."""
    text = normalize_text(value)
    if "\ufffd" in text or not any(marker in text for marker in MOJIBAKE_MARKERS):
        return text, False
    try:
        repaired = text.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text, False
    return (normalize_text(repaired), True) if repaired != text else (text, False)


def search_key(value: object | None) -> str:
    text = unicodedata.normalize("NFKD", normalize_text(value)).casefold()
    text = "".join(char for char in text if not unicodedata.combining(char))
    return re.sub(r"[^a-z0-9]+", "_", text).strip("_")


def fixed_area_code_for_department(value: object | None) -> str:
    return FIXED_AREA_BY_DEPARTMENT.get(search_key(value), "")


def normalize_email(value: object | None) -> tuple[str, str]:
    text = normalize_text(value)
    if not text:
        return "", "EMPTY"
    if not EMAIL_RE.fullmatch(text):
        return text, "INVALID_FORMAT"
    local, domain = text.rsplit("@", 1)
    # RFC 5321 exige preservar el caso del local-part; el dominio no distingue caso.
    return f"{local}@{domain.lower()}", "VALID"


def extract_emails(value: object | None) -> tuple[list[str], list[str]]:
    text = normalize_text(value)
    found: list[str] = []
    invalid: list[str] = []
    for candidate in EMAIL_FIND_RE.findall(text):
        normalized, status = normalize_email(candidate)
        target = found if status == "VALID" else invalid
        if normalized and normalized not in target:
            target.append(normalized)
    if text and not found:
        invalid.append(text)
    return found, invalid


def normalize_url(value: object | None) -> tuple[str, str]:
    text = normalize_text(value)
    if not text:
        return "", "EMPTY"
    if "://" not in text:
        text = "https://" + text
    try:
        parts = urlsplit(text)
    except ValueError:
        return text, "INVALID_FORMAT"
    if parts.scheme.lower() not in {"http", "https"} or not parts.hostname:
        return text, "INVALID_FORMAT"
    host = parts.hostname.encode("idna").decode("ascii").lower()
    port = parts.port
    netloc = host
    if port and not ((parts.scheme.lower() == "http" and port == 80) or (parts.scheme.lower() == "https" and port == 443)):
        netloc += f":{port}"
    path = parts.path or ""
    return urlunsplit((parts.scheme.lower(), netloc, path, parts.query, "")), "VALID"


def _extract_extension(value: str) -> tuple[str, str]:
    match = re.search(r"(?:ext\.?|extension|x)\s*([0-9]{1,8})\s*$", value, re.I)
    if not match:
        return value, ""
    return value[:match.start()], match.group(1)


def normalize_colombian_phone(value: object | None) -> PhoneResult:
    raw = normalize_text(value)
    without_extension, extension = _extract_extension(raw)
    digits = re.sub(r"\D", "", without_extension)
    issue = ""

    if len(digits) == 14 and digits.startswith("0057"):
        digits = digits[4:]
    elif len(digits) == 12 and digits.startswith("57"):
        digits = digits[2:]
    elif len(digits) == 12 and digits.startswith("03"):
        digits = digits[2:]
        issue = "LEGACY_03_REMOVED"

    prefix = digits[:3]
    if len(digits) == 10 and prefix in FIXED_PREFIXES:
        return PhoneResult(raw, digits, "+57" + digits, "FIJO", prefix, digits[3:], extension, "VALID", issue)
    if len(digits) == 10 and prefix in MOBILE_TERRESTRIAL_PREFIXES:
        return PhoneResult(raw, digits, "+57" + digits, "CELULAR", extension=extension, issue=issue)
    if len(digits) == 10 and prefix in MOBILE_TRUNKING_PREFIXES:
        return PhoneResult(raw, digits, "+57" + digits, "MOVIL_TRUNKING", extension=extension, status="REVIEW", issue=issue or "SPECIAL_MOBILE_RANGE")
    if len(digits) == 10 and prefix in MOBILE_SATELLITE_PREFIXES:
        return PhoneResult(raw, digits, "+57" + digits, "MOVIL_SATELITAL", extension=extension, status="REVIEW", issue=issue or "SPECIAL_MOBILE_RANGE")
    if len(digits) == 10 and digits.startswith("3"):
        return PhoneResult(raw, digits, "+57" + digits, "RANGO_NO_ATRIBUIDO", extension=extension, status="REVIEW", issue="UNATTRIBUTED_3XX_PREFIX")
    if digits.startswith("01800"):
        return PhoneResult(raw, digits, "", "SERVICIO_COBRO_REVERTIDO", extension=extension, status="REVIEW", issue="VALIDATE_SERVICE_NUMBER_IN_SIGRI")
    if len(digits) == 7:
        return PhoneResult(raw, digits, "", "FIJO_LOCAL_SIN_INDICATIVO", local_number=digits, extension=extension, status="REVIEW", issue="AREA_CODE_REQUIRED")
    return PhoneResult(raw, digits, "", "INVALIDO", extension=extension, status="INVALID", issue="INVALID_COLOMBIAN_NUMBER")


def extract_colombian_phones(value: object | None) -> list[PhoneResult]:
    text = normalize_text(value)
    if not text:
        return []
    parts = [part.strip() for part in re.split(r"\s*[;|/]\s*", text) if part.strip()]
    return [normalize_colombian_phone(part) for part in parts]


def calculate_nit_verification_digit(base: str) -> str:
    if not base.isdigit() or not (1 <= len(base) <= 15):
        raise ValueError("La base del NIT debe contener entre 1 y 15 digitos")
    weights = [71, 67, 59, 53, 47, 43, 41, 37, 29, 23, 19, 17, 13, 7, 3]
    selected = weights[-len(base):]
    remainder = sum(int(digit) * weight for digit, weight in zip(base, selected)) % 11
    return str(remainder if remainder < 2 else 11 - remainder)


def normalize_nit(value: object | None) -> NitResult:
    raw = normalize_text(value)
    digits = re.sub(r"\D", "", raw)
    if not digits:
        return NitResult(raw, "", "", None, "EMPTY")
    if len(digits) == 10:
        base, dv = digits[:9], digits[9]
        valid = calculate_nit_verification_digit(base) == dv
        return NitResult(raw, base, dv, valid, "VALID" if valid else "REVIEW", "" if valid else "DV_MISMATCH")
    if len(digits) in {8, 9}:
        return NitResult(raw, digits, "", None, "VALID_BASE_ONLY", "DV_NOT_PROVIDED")
    return NitResult(raw, digits, "", None, "INVALID", "INVALID_NIT_LENGTH")


def normalize_decimal(value: object | None) -> tuple[str, str]:
    text = normalize_text(value)
    if not text:
        return "", "EMPTY"
    normalized = text.replace("$", "").replace("COP", "").replace(" ", "")
    if normalized.count(",") == 1 and normalized.count(".") == 0:
        normalized = normalized.replace(",", ".")
    elif normalized.count(".") > 1 and "," not in normalized:
        normalized = normalized.replace(".", "")
    try:
        number = Decimal(normalized)
    except InvalidOperation:
        return text, "INVALID_FORMAT"
    return format(number, "f"), "VALID"


def normalize_iso_datetime(value: object | None) -> tuple[str, str]:
    text = normalize_text(value)
    if not text:
        return "", "EMPTY"
    candidate = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        return text, "INVALID_FORMAT"
    if parsed.tzinfo is None:
        return parsed.isoformat(), "REVIEW_NO_TIMEZONE"
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"), "VALID"
