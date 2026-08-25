import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "import"))

from _shared import clean_record, validate_database_role  # noqa: E402
from import_entidades import (  # noqa: E402
    is_valid_email,
    normalize_contact_record,
    prepare_contact_records,
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
        self.assertEqual(record["valor_normalizado"], "correo invalido")
        self.assertEqual(record["__raw_payload"]["valor_normalizado"], " Correo Invalido ")

    def test_normalized_payload_differs_from_raw_when_values_need_cleaning(self):
        raw = {"tipo": " email ", "valor_normalizado": " VENTAS@EXAMPLE.COM "}
        normalized = normalize_contact_record(clean_record(raw))
        self.assertNotEqual(json.dumps(raw, sort_keys=True), json.dumps(normalized, sort_keys=True))
        self.assertEqual(normalized["tipo"], "EMAIL")
        self.assertEqual(normalized["valor_normalizado"], "ventas@example.com")


if __name__ == "__main__":
    unittest.main()
