import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "catalog"))

from pricing_model import (  # noqa: E402
    calculate_price,
    least_cost_sheet_purchase,
    marking_cost_unit,
    money,
    tiered_unit_cost,
)


class PricingModelTests(unittest.TestCase):
    def test_tiered_unit_cost_supports_unit_and_pack(self):
        item = {
            "name": "Mug 11 oz",
            "tiers": [
                {"from_qty": 1, "value_unit": 6200},
                {"from_qty": 12, "pack_qty": 36, "pack_price": 129000},
                {"from_qty": 36, "pack_qty": 36, "pack_price": 120000},
            ],
        }

        self.assertEqual(tiered_unit_cost(item, 1), 6200)
        self.assertEqual(tiered_unit_cost(item, 12), 129000 / 36)
        self.assertEqual(tiered_unit_cost(item, 36), 120000 / 36)

    def test_least_cost_sheet_purchase_combines_supplier_formats(self):
        options = [
            {"width_cm": 58, "height_cm": 30, "price": 8000},
            {"width_cm": 58, "height_cm": 50, "price": 13000},
            {"width_cm": 58, "height_cm": 100, "price": 26000},
        ]

        self.assertEqual(least_cost_sheet_purchase(16.5, options), 8000)
        self.assertEqual(least_cost_sheet_purchase(33, options), 13000)
        self.assertEqual(least_cost_sheet_purchase(99, options), 26000)
        self.assertEqual(least_cost_sheet_purchase(825, options), 216000)

    def test_dtf_chest_and_back_uses_supplier_purchase_options(self):
        config = {
            "mode": "dtf",
            "roll_width_cm": 58,
            "waste_pct": 10,
            "purchase_options": [
                {"width_cm": 58, "height_cm": 30, "price": 8000},
                {"width_cm": 58, "height_cm": 50, "price": 13000},
                {"width_cm": 58, "height_cm": 100, "price": 26000},
            ],
            "designs": [
                {"name": "Pecho", "width_cm": 10, "height_cm": 12, "units_per_product": 1},
                {"name": "Espalda", "width_cm": 25, "height_cm": 30, "units_per_product": 1},
            ],
            "iron": {"include": False},
        }

        self.assertEqual(money(marking_cost_unit(config, 1)), 8000)
        self.assertEqual(money(marking_cost_unit(config, 2)), 6500)
        self.assertEqual(money(marking_cost_unit(config, 12)), 4333)

    def test_mvp_catalog_prices_drop_with_supplier_volume(self):
        data = json.loads((ROOT / "scripts" / "catalog" / "mvp_catalog_inputs.json").read_text(encoding="utf-8"))
        products = {item["product"]["sku"]: item for item in data["products"]}

        mug_1 = calculate_price(products["PRD-MUG-11OZ"], 1)
        mug_12 = calculate_price(products["PRD-MUG-11OZ"], 12)
        shirt_1 = calculate_price(products["PRD-CAMI-BASICA"], 1)
        shirt_50 = calculate_price(products["PRD-CAMI-BASICA"], 50)
        bottle_1 = calculate_price(products["PRD-TERMO-BASICO"], 1)
        bottle_12 = calculate_price(products["PRD-TERMO-BASICO"], 12)

        self.assertGreater(mug_1.sale_price_unit, mug_12.sale_price_unit)
        self.assertGreater(shirt_1.sale_price_unit, shirt_50.sale_price_unit)
        self.assertGreater(bottle_1.sale_price_unit, bottle_12.sale_price_unit)
        self.assertEqual(money(mug_12.sale_price_unit), 9577)
        self.assertEqual(money(shirt_50.sale_price_unit), 30241)
        self.assertEqual(money(bottle_12.sale_price_unit), 38979)


if __name__ == "__main__":
    unittest.main()
