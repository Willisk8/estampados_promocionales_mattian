import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "import"))

from _shared import clean_record, validate_database_role  # noqa: E402
from import_entidades import (  # noqa: E402
    classify_colombian_phone,
    is_valid_email,
    is_malformed_email_domain,
    normalize_colombian_phone,
    normalize_contact_record,
    prepare_contact_records,
    sanitize_visible_text,
)


class ImportHelperTests(unittest.TestCase):
    def test_backend_database_roles(self):
        self.assertEqual(
            validate_database_role("postgresql://postgres.project:secret@db.example/db"),
            "postgres.project",
        )
        with self.assertRaises(RuntimeError):
            validate_database_role("postgresql://authenticated:secret@db.example/db")

    def test_email_validation_and_quarantine(self):
        self.assertTrue(is_valid_email("ventas@example.com"))
        for bad in ("sin-arroba", "a@@example.com", "a @example.com", "a@example"):
            self.assertFalse(is_valid_email(bad))

        [record] = prepare_contact_records([{
            "id_canal_contacto": "00000000-0000-4000-b000-000000000004",
            "tipo": "email",
            "valor_original": " Correo Invalido ",
            "valor_normalizado": " Correo Invalido ",
            "estado": "ACTIVE",
        }])
        self.assertEqual(record["estado"], "INVALID")
        self.assertEqual(record["valor_normalizado"], "Correo Invalido")
        self.assertEqual(record["__raw_payload"]["valor_normalizado"], " Correo Invalido ")

    def test_visible_text_and_colombian_phone_sanitization(self):
        self.assertEqual(
            sanitize_visible_text('  "Organización"\n de   Bogotá  '),
            '"Organización" de Bogotá',
        )
        self.assertEqual(
            normalize_colombian_phone("+57 (601) 234-5678"),
            "6012345678",
        )
        self.assertEqual(
            normalize_colombian_phone("0057 320 123 4567"),
            "3201234567",
        )
        self.assertEqual(classify_colombian_phone("6027654321"), "FIJO")
        self.assertEqual(classify_colombian_phone("6037654321"), "INVALIDO")
        self.assertEqual(classify_colombian_phone("3117654321"), "CELULAR")
        self.assertEqual(classify_colombian_phone("2117654321"), "INVALIDO")

        [record] = prepare_contact_records([{
            "id_canal_contacto": "00000000-0000-4000-b000-000000000099",
            "tipo": "TELEFONO",
            "valor_original": "123 45",
            "valor_normalizado": "123 45",
            "estado": "ACTIVE",
        }])
        self.assertEqual(record["valor_normalizado"], "12345")
        self.assertEqual(record["estado"], "INVALID")
        self.assertIn("Telefono colombiano requiere revision", record["__review_reason"])

    def test_known_malformed_domains_are_quarantined(self):
        malformed_domains = (
            "coomservi.combogot",
            "colegiocoomeva.edu.codocente",
            "fbcsena.comauxiliar",
        )
        records = prepare_contact_records([
            {
                "id_canal_contacto": f"00000000-0000-4000-b000-00000000010{i}",
                "tipo": "EMAIL",
                "valor_original": f"contacto@{domain}",
                "valor_normalizado": f"contacto@{domain}",
                "estado": "ACTIVE",
            }
            for i, domain in enumerate(malformed_domains)
        ])

        for record, domain in zip(records, malformed_domains):
            self.assertTrue(is_valid_email(record["valor_normalizado"]))
            self.assertTrue(is_malformed_email_domain(record["valor_normalizado"]))
            self.assertEqual(record["estado"], "REVIEW_REQUIRED")
            self.assertEqual(record["__review_severity"], "HIGH")
            self.assertIn(domain, record["__review_reason"])

    def test_normalized_payload_differs_from_raw_when_values_need_cleaning(self):
        raw = {"tipo": " email ", "valor_normalizado": " VENTAS@EXAMPLE.COM "}
        normalized = normalize_contact_record(clean_record(raw))
        self.assertNotEqual(json.dumps(raw, sort_keys=True), json.dumps(normalized, sort_keys=True))
        self.assertEqual(normalized["tipo"], "EMAIL")
        self.assertEqual(normalized["valor_normalizado"], "VENTAS@example.com")


if __name__ == "__main__":
    unittest.main()
