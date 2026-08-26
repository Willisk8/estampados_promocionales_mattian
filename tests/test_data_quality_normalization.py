import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.data_quality.normalization import (  # noqa: E402
    calculate_nit_verification_digit,
    fixed_area_code_for_department,
    normalize_colombian_phone,
    normalize_email,
    normalize_nit,
    normalize_text,
    search_key,
)


class ColombiaDataQualityTests(unittest.TestCase):
    def test_canonical_text_preserves_accents_and_search_key_folds_them(self):
        self.assertEqual(normalize_text('  "Organización\nÚnica"  '), "Organización Única")
        self.assertEqual(search_key("Organización Única"), "organizacion_unica")

    def test_fixed_prefixes_exclude_603(self):
        self.assertEqual(normalize_colombian_phone("+57 601 234 5678").classification, "FIJO")
        self.assertEqual(normalize_colombian_phone("608 234 5678").classification, "FIJO")
        result = normalize_colombian_phone("603 234 5678")
        self.assertEqual(result.classification, "INVALIDO")
        self.assertEqual(result.status, "INVALID")
        self.assertEqual(fixed_area_code_for_department("Bogotá, D.C."), "601")
        self.assertEqual(fixed_area_code_for_department("Nariño"), "602")

    def test_mobile_ranges_are_not_every_3xx_number(self):
        self.assertEqual(normalize_colombian_phone("3201234567").classification, "CELULAR")
        self.assertEqual(normalize_colombian_phone("3331234567").classification, "CELULAR")
        self.assertEqual(normalize_colombian_phone("3501234567").classification, "MOVIL_TRUNKING")
        self.assertEqual(normalize_colombian_phone("3081234567").classification, "MOVIL_SATELITAL")
        self.assertEqual(normalize_colombian_phone("3401234567").classification, "RANGO_NO_ATRIBUIDO")

    def test_legacy_and_special_numbers_are_reviewable(self):
        legacy = normalize_colombian_phone("03 311 765 4321")
        self.assertEqual(legacy.national_number, "3117654321")
        self.assertEqual(legacy.issue, "LEGACY_03_REMOVED")
        self.assertEqual(
            normalize_colombian_phone("018000 919278").classification,
            "SERVICIO_COBRO_REVERTIDO",
        )
        self.assertEqual(
            normalize_colombian_phone("2345678").classification,
            "FIJO_LOCAL_SIN_INDICATIVO",
        )

    def test_email_preserves_local_part_case(self):
        self.assertEqual(normalize_email("Ventas@EJEMPLO.COM"), ("Ventas@ejemplo.com", "VALID"))

    def test_nit_keeps_base_and_dv_separate(self):
        base = "800071483"
        dv = calculate_nit_verification_digit(base)
        result = normalize_nit(base + dv)
        self.assertEqual(result.base, base)
        self.assertEqual(result.verification_digit, dv)
        self.assertTrue(result.verification_valid)


if __name__ == "__main__":
    unittest.main()
