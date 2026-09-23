"""Formato y DNS de correo: nunca afirma existencia del buzon ni envia correo."""
import json
from urllib.parse import urlencode
from urllib.request import urlopen

from email_validator import EmailNotValidError, validate_email


def email_syntax(value):
    try:
        result = validate_email(value, check_deliverability=False)
        return result.normalized, result.ascii_domain, 'VALID'
    except EmailNotValidError:
        return value, None, 'INVALID_FORMAT'


def dns_query(domain, kind):
    # Solo sale el dominio, nunca la direccion de correo completa.
    url = 'https://dns.google/resolve?' + urlencode({'name': domain, 'type': kind})
    with urlopen(url, timeout=8) as response:
        return json.load(response)


def check_domain(domain, query=dns_query):
    try:
        mx = query(domain, 'MX')
        if mx.get('Status') == 3:
            return 'NXDOMAIN'
        if mx.get('Status') != 0:
            return 'UNKNOWN'
        records = [r.get('data', '').split() for r in mx.get('Answer', []) if r.get('type') == 15]
        if any(len(r)==2 and r[1]!='.' for r in records):
            return 'MX'
        if any(r==['0','.'] for r in records):
            return 'NULL_MX'
        answers = [query(domain, kind) for kind in ('A','AAAA')]
        if any(a.get('Status') not in (0,3) for a in answers):
            return 'UNKNOWN'
        if any(r.get('type') in (1,28) for a in answers for r in a.get('Answer', [])):
            txt = query(domain, 'TXT')
            if txt.get('Status') != 0:
                return 'UNKNOWN'
            if any(r.get('data','').strip('"').strip().lower()=='v=spf1 -all' for r in txt.get('Answer',[]) if r.get('type')==16):
                return 'NO_MAIL'
            return 'ADDRESS_FALLBACK'
        return 'NO_MAIL'
    except Exception:
        # Timeout/SERVFAIL no demuestra dominio ni buzon inexistente.
        return 'UNKNOWN'
