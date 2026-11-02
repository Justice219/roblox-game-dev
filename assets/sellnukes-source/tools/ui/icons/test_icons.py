"""
Unit tests for tools/ui/icons/icons.py (pure logic: no network, no Blender, no repo writes).

Run: python3 -m unittest discover -s tools/ui/icons -p 'test_*.py'

Covers: exact disc dilation vs a brute-force disc, hue rotation, colourise + sticker border, the
catalog contract (every key
present, pins well-formed, composite refs valid), the generated Luau (every key / alias / category,
lowercase table, StyLua-shaped union), alias + lowercase resolution, receipt mapping (stale /
rejected / malformed -> 0) and the outline framing guard.
"""

from __future__ import annotations

import importlib.util
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("icons_under_test", HERE / "icons.py")
icons = importlib.util.module_from_spec(spec)
sys.modules["icons_under_test"] = icons
spec.loader.exec_module(icons)


class DilateTests(unittest.TestCase):
    """dilate() must equal a naive disc dilation exactly."""

    def test_matches_brute_force_disc(self):
        import numpy as np

        rng = np.random.default_rng(7)
        mask = rng.random((40, 52)) > 0.97
        radius = 5
        expected = np.zeros_like(mask)
        for y, x in zip(*np.nonzero(mask)):
            for dy in range(-radius, radius + 1):
                for dx in range(-radius, radius + 1):
                    if dx * dx + dy * dy <= radius * radius:
                        yy, xx = y + dy, x + dx
                        if 0 <= yy < mask.shape[0] and 0 <= xx < mask.shape[1]:
                            expected[yy, xx] = True
        self.assertTrue((icons.dilate(mask, radius) == expected).all())


class HueTests(unittest.TestCase):
    """hue_rotate() keeps alpha, is a no-op at 0 and moves pure red toward green at +120."""

    def test_hue_rotation(self):
        from PIL import Image

        image = Image.new("RGBA", (4, 4), (255, 0, 0, 128))
        self.assertIs(icons.hue_rotate(image, 0), image)
        rotated = icons.hue_rotate(image, 120).getpixel((0, 0))
        self.assertEqual(rotated[3], 128)
        self.assertGreater(rotated[1], 200)
        self.assertLess(rotated[0], 60)


class ColorizeStickerTests(unittest.TestCase):
    """colorize() keeps alpha and shading order; stickered() adds a white border inside the box."""

    def test_colorize_gold(self):
        from PIL import Image

        image = Image.new("RGBA", (2, 1), (0, 0, 0, 200))
        image.putpixel((1, 0), (255, 255, 255, 200))
        gold = icons.colorize(image, [[100, 50, 0], [200, 150, 0], [250, 240, 200]])
        self.assertEqual(gold.getpixel((0, 0)), (100, 50, 0, 200))
        self.assertEqual(gold.getpixel((1, 0)), (250, 240, 200, 200))
        self.assertIs(icons.colorize(image, None), image)

    def test_sticker_border_is_white_and_framed(self):
        from PIL import Image, ImageDraw

        raw = Image.new("RGBA", (icons.RAW_SIZE, icons.RAW_SIZE), (0, 0, 0, 0))
        margin = (icons.RAW_SIZE - icons.box_px()) // 2
        ImageDraw.Draw(raw).rectangle((margin, margin, icons.RAW_SIZE - margin, icons.RAW_SIZE - margin), fill=(255, 0, 0, 255))
        sticker = icons.stickered(raw, 0)
        bounds = sticker.getchannel("A").getbbox()
        self.assertLessEqual(bounds[2] - bounds[0], icons.box_px() + 2)
        edge = sticker.getpixel((bounds[0] + 4, icons.RAW_SIZE // 2))
        self.assertEqual(edge[:3], icons.STICKER_RGB)
        image, _ = icons.outline_and_downsample(sticker)  # still fits the shared frame
        self.assertEqual(image.size, (icons.FINAL_SIZE, icons.FINAL_SIZE))


class CatalogTests(unittest.TestCase):
    """The committed sources.json satisfies the B2 contract and the pin rules."""

    def test_catalog_valid_and_complete(self):
        every = icons.catalog()
        for key in icons.ICONS:
            self.assertIn(key, every)
        for name, entry in every.items():
            if entry["kind"] == "pack":
                self.assertRegex(entry["url"], icons.SOURCE_URL)
                self.assertRegex(entry["sha256"], icons.HASH)
            if entry["kind"] == "composite":
                for layer in entry["layers"]:
                    self.assertNotEqual(every[layer["ref"]]["kind"], "composite")

    def test_required_keys_present(self):
        # Keys B2 wired (lead message) + the HUD / currency / offer / reward / game / area set.
        for key in ("Shop", "Gems", "Robux", "Close", "Arrow", "Star", "Check", "Lock", "x2Cash", "Area10"):
            self.assertIn(key, icons.ICONS)
        # Harvest Feast keys B11 asked for (Acorn / Trophy are shared with the main set).
        for key in ("Acorn", "Trophy", "GoldenTurkey", "GobbleBomb", "HarvestEgg", "StickerSheet",
                    "DecorHayBales", "DecorPumpkinPile", "DecorScarecrow", "DecorCornucopia",
                    "DecorGarland", "DecorTurkeyStatue", *(f"Sticker{i:02d}" for i in range(1, 21))):
            self.assertIn(key, icons.ICONS)
        every = icons.catalog()
        for index in range(1, 21):
            self.assertTrue(every[f"Sticker{index:02d}"].get("sticker"), index)
        self.assertEqual(len(set(icons.ICONS)), len(icons.ICONS))

    def test_rejects_unpinned_url(self):
        with tempfile.TemporaryDirectory() as folder:
            data = json.loads(icons.SOURCES.read_text())
            data["icons"]["Rewards"]["url"] = "https://example.com/gift.png"
            path = Path(folder) / "sources.json"
            path.write_text(json.dumps(data))
            with mock.patch.object(icons, "SOURCES", path):
                with self.assertRaises(icons.ToolError):
                    icons.catalog()


class ConfigTests(unittest.TestCase):
    """The generated Luau text."""

    def setUp(self):
        self.kinds = {key: "pack" for key in icons.ICONS}
        self.text = icons.render_config({"Shop": 123}, self.kinds)

    def test_every_key_alias_category(self):
        for key in icons.ICONS:
            self.assertIn(f"\t{key} = ", self.text)
        for alias, key in icons.ALIASES.items():
            self.assertIn(f'\t{alias} = "{key}",', self.text)
        for category in icons.CATEGORIES:
            self.assertIn(f"\t{category} = table.freeze({{", self.text)
        self.assertIn('\tShop = entry(123, "hud", "pack"),', self.text)
        self.assertIn("\tRewards = entry(0, ", self.text)
        self.assertTrue(self.text.startswith("--!strict\n"))

    def test_union_is_stylua_shaped(self):
        self.assertIn('export type IconKey =\n\t"Shop"\n\t| "Rewards"', self.text)
        for line in self.text.splitlines():
            self.assertLessEqual(len(line.expandtabs(4)), 120, line)

    def test_monetization_names_resolve(self):
        lower = icons.lower_map()
        for name in ("cash", "gem", "spin", "crown", "egg", "shield", "lightning", "moon", "acorn", "boot",
                     "cursor", "skip", "turkey", "rocket", "pet", "gift", "star", "clock", "teleport"):
            target = icons.ALIASES.get(name) or lower.get(name.lower())
            self.assertIn(target, icons.ICONS, name)
        self.assertEqual(lower["shop"], "Shop")
        self.assertEqual(lower["robux"], "Robux")
        self.assertEqual(icons.ALIASES["teleport"], "Teleporter")  # exact alias beats the lowercase key


class ReceiptTests(unittest.TestCase):
    """receipt_asset() maps only fresh, non-rejected, well-formed receipts."""

    def check(self, receipt, manifest_sha="a" * 64):
        with tempfile.TemporaryDirectory() as folder:
            receipts = Path(folder)
            (receipts / "Shop.json").write_text(json.dumps(receipt))
            with mock.patch.object(icons, "RECEIPTS", receipts):
                return icons.receipt_asset("Shop", {"icons": {"Shop": {"sha256": manifest_sha}}})

    def test_mapping(self):
        good = {"assetId": 123456, "sha256": "a" * 64, "moderation": "Approved"}
        self.assertEqual(self.check(good), 123456)
        self.assertEqual(self.check({**good, "moderation": "Reviewing"}), 123456)
        self.assertEqual(self.check({**good, "moderation": "Rejected"}), 0)
        self.assertEqual(self.check(good, manifest_sha="b" * 64), 0)
        self.assertEqual(self.check({**good, "assetId": "123"}), 0)
        self.assertEqual(self.check({**good, "assetId": 0}), 0)


class OutlineTests(unittest.TestCase):
    """outline_and_downsample() output size and its framing guard."""

    def test_centered_art_gets_outline(self):
        from PIL import Image, ImageDraw

        raw = Image.new("RGBA", (icons.RAW_SIZE, icons.RAW_SIZE), (0, 0, 0, 0))
        margin = (icons.RAW_SIZE - icons.box_px()) // 2
        ImageDraw.Draw(raw).ellipse((margin, margin, icons.RAW_SIZE - margin, icons.RAW_SIZE - margin), fill=(255, 0, 0, 255))
        image, bounds = icons.outline_and_downsample(raw)
        self.assertEqual(image.size, (icons.FINAL_SIZE, icons.FINAL_SIZE))
        self.assertTrue(math.isclose(bounds[0], icons.PAD_PX, abs_tol=2))
        edge = image.getpixel((icons.PAD_PX + 4, icons.FINAL_SIZE // 2))
        self.assertEqual(edge[:3], icons.OUTLINE_RGB)

    def test_rejects_art_touching_edge(self):
        from PIL import Image

        raw = Image.new("RGBA", (icons.RAW_SIZE, icons.RAW_SIZE), (255, 0, 0, 255))
        with self.assertRaises(icons.ToolError):
            icons.outline_and_downsample(raw)


if __name__ == "__main__":
    unittest.main()
