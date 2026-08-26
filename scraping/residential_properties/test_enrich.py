import unittest

from enrich import canonical_phone, email_domain, property_match, whatsapp_number


class EnrichmentTests(unittest.TestCase):
    def test_email_domain_excludes_free_mail(self):
        self.assertEqual(email_domain("admin@gmail.com"), "")
        self.assertEqual(email_domain("admin@hotmai.com"), "")
        self.assertEqual(email_domain("administracion@conjuntoejemplo.com"), "conjuntoejemplo.com")

    def test_property_name_match(self):
        row = {"property_name": "Conjunto Residencial Bosques del Sol P.H.", "nit": "", "address": ""}
        match, detail = property_match("Administración Bosques del Sol - contacto", row)
        self.assertEqual(match, "NAME_MATCH")
        self.assertIn("bosques", detail)

    def test_source_email_match(self):
        row = {"property_name": "Conjunto Uno", "nit": "", "address": "", "email": "admin@conjuntouno.com"}
        match, _ = property_match("Escríbanos a admin@conjuntouno.com", row)
        self.assertEqual(match, "SOURCE_EMAIL_MATCH")

    def test_whatsapp_link(self):
        self.assertEqual(whatsapp_number("https://wa.me/573001234567"), "+573001234567")

    def test_phone_prefixes_follow_crc_attribution(self):
        self.assertEqual(canonical_phone("601 234 5678"), "+576012345678")
        self.assertEqual(canonical_phone("603 234 5678"), "6032345678")
        self.assertEqual(canonical_phone("340 234 5678"), "3402345678")


if __name__ == "__main__":
    unittest.main()
