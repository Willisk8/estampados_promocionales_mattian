import unittest

from scraper import (
    deduplicate,
    normalize_email,
    normalize_nit,
    normalize_phone,
    residential_classification,
    source_row_allowed,
)


class NormalizationTests(unittest.TestCase):
    def test_contact_normalization(self):
        self.assertEqual(normalize_nit("892,002,346-9"), "8920023469")
        self.assertEqual(
            normalize_email("Admin@Ejemplo.com  admin@ejemplo.com"),
            "admin@ejemplo.com",
        )
        self.assertEqual(normalize_phone("Tel: 601 8220136"), "601 8220136")

    def test_residential_classification(self):
        self.assertEqual(
            residential_classification("Conjunto Portales", "", ""),
            "RESIDENCIAL_PROBABLE",
        )
        self.assertEqual(
            residential_classification("Torres Uno", "", "Residencial"),
            "RESIDENCIAL_CONFIRMADO",
        )
        self.assertEqual(
            residential_classification("Centro Comercial Uno", "Comercial", ""),
            "NO_RESIDENCIAL",
        )

    def test_deduplicate_keeps_more_complete_record(self):
        base = {
            "record_id": "same", "property_name": "Conjunto Uno", "nit": "",
            "address": "Calle 1", "neighborhood": "", "property_type": "",
            "use": "", "legal_representative": "", "contact_person": "",
            "email": "", "phone": "", "source_record_id": "1",
        }
        complete = dict(base, email="admin@conjunto.co")
        rows, removed = deduplicate([base, complete])
        self.assertEqual(removed, 1)
        self.assertEqual(rows[0]["email"], "admin@conjunto.co")

    def test_source_filter(self):
        source = {"filters": {"vereda_barrio_conjunto": "Conjunto Residencial"}}
        self.assertTrue(source_row_allowed({"VEREDA BARRIO CONJUNTO": "Conjunto Residencial"}, source))
        self.assertFalse(source_row_allowed({"VEREDA BARRIO CONJUNTO": "Barrio"}, source))


if __name__ == "__main__":
    unittest.main()
