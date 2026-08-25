import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


scraper = load_module(
    "personalization_techniques_scraper",
    ROOT / "scraping" / "personalization_techniques" / "scraper.py",
)

import_tecnicas = load_module(
    "import_tecnicas_marcacion",
    ROOT / "scripts" / "import" / "import_tecnicas_marcacion.py",
)


class PersonalizationTechniqueTests(unittest.TestCase):
    def test_observation_id_changes_with_snapshot_identity_fields(self):
        base = {
            "source_id": "proveedor_demo",
            "supplier": "Proveedor Demo",
            "city": "Bogotá",
            "technique": "dtf_textil",
            "service_component": "impresion",
            "price_scope": "solo_servicio",
            "compatible_products": "camisetas",
            "compatible_materials": "algodón",
            "size_label": "58 x 100 cm",
            "width_cm": 58,
            "height_cm": 100,
            "quantity_min": 1,
            "quantity_max": "",
            "billing_unit": "metro lineal",
            "currency": "COP",
            "price_value": 26000,
            "price_min": "",
            "price_max": "",
            "tax_status": "",
            "conditions": "precio público",
            "evidence_text": "metro DTF textil $26.000",
            "source_url": "https://example.com/dtf",
            "fetched_at": "2026-08-25T10:00:00+00:00",
            "http_status": 200,
            "verification_status": "VERIFIED_PUBLIC_PRICE",
        }
        changed_date = {**base, "fetched_at": "2026-09-01T10:00:00+00:00"}
        changed_qty = {**base, "quantity_max": 99}

        self.assertNotEqual(scraper.make_observation_id(base), scraper.make_observation_id(changed_date))
        self.assertNotEqual(scraper.make_observation_id(base), scraper.make_observation_id(changed_qty))

    def test_verify_rejects_empty_price_observations(self):
        with tempfile.TemporaryDirectory() as tmp:
            output_dir = Path(tmp)
            with (output_dir / "precios_tecnicas_personalizacion.csv").open("w", encoding="utf-8-sig", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=scraper.PRICE_FIELDS)
                writer.writeheader()
            with (output_dir / "errores.csv").open("w", encoding="utf-8-sig", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=scraper.ERROR_FIELDS)
                writer.writeheader()
            (output_dir / "resumen.json").write_text(
                json.dumps({
                    "configured_sources": 12,
                    "fetched_sources": 0,
                    "price_observations": 0,
                    "errors": 0,
                }),
                encoding="utf-8",
            )

            result = scraper.verify(output_dir)

        self.assertFalse(result["ok"])
        self.assertIn("no_price_observations", result["errors"])
        self.assertIn("no_sources_captured", result["errors"])

    def test_importer_rejects_incomplete_price_rows(self):
        rows = [{
            "__sheet_row_number": 2,
            "source_id": "src",
            "supplier": "",
            "technique": "dtf_textil",
            "price_value": "26000",
        }]

        with self.assertRaisesRegex(RuntimeError, "fila 2"):
            import_tecnicas.validate_price_records(rows)


if __name__ == "__main__":
    unittest.main()
