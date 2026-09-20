#!/usr/bin/env python3
"""Unit tests for Mineradio / Chrome CSS glass layout.

Locks TILE6_3 vs LINEAR so a size heuristic cannot silently re-snow
backdrop-filter. Run:

  python3 linux-mainline/tests/test_dagu_glass_layout.py
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from dagu_glass_layout import (  # noqa: E402
    ATLAS_MAX_SHORT,
    ATLAS_MIN_LONG,
    LAYOUT_CASES,
    LINEAR,
    PAGE_MIN_H,
    TILE,
    color_rt_layout,
    hunt_tile_to_layout,
)


class CorpusTests(unittest.TestCase):
    def test_named_sizes_match_expected_layout(self) -> None:
        for name, w, h, bpp, r8, expected in LAYOUT_CASES:
            with self.subTest(name=name, size=f"{w}x{h}", bpp=bpp, r8=r8):
                got = color_rt_layout(w, h, bpp=bpp, r8=r8, a8=r8)
                self.assertEqual(
                    got,
                    expected,
                    f"{name} {w}x{h} bpp={bpp} r8={r8}: {got} != {expected}",
                )


class MineradioGlassTests(unittest.TestCase):
    def test_playlist_cards_are_linear(self) -> None:
        for w, h in ((640, 384), (1024, 512), (512, 256), (256, 256), (704, 256)):
            self.assertEqual(color_rt_layout(w, h), LINEAR, f"{w}x{h}")

    def test_queue_drawer_is_linear(self) -> None:
        # Hunt: 1536x896 / 1536x256. 640x896 would still match the
        # 832x576 page-tile bucket (non-square, both in [576,1024]).
        for w, h in ((1536, 896), (1536, 256), (128, 1088)):
            self.assertEqual(color_rt_layout(w, h), LINEAR, f"{w}x{h}")

    def test_search_and_window_are_linear(self) -> None:
        for w, h in ((1024, 128), (1920, 1080), (2304, 1536), (1920, 1088)):
            self.assertEqual(color_rt_layout(w, h), LINEAR, f"{w}x{h}")


class ChromeCorpusTests(unittest.TestCase):
    def test_glass_probe_bar_is_linear(self) -> None:
        self.assertEqual(color_rt_layout(2496, 416), LINEAR)

    def test_page_tile_832x576_stays_tiled(self) -> None:
        self.assertEqual(color_rt_layout(832, 576), TILE)

    def test_page_tile_bucket_does_not_eat_card_pads(self) -> None:
        self.assertLess(384, PAGE_MIN_H)
        self.assertLess(512, PAGE_MIN_H)
        self.assertEqual(color_rt_layout(640, 384), LINEAR)
        self.assertEqual(color_rt_layout(1024, 512), LINEAR)

    def test_skia_atlas_strip_stays_tiled(self) -> None:
        self.assertEqual(color_rt_layout(3840, 360), TILE)
        self.assertEqual(color_rt_layout(2560, 240), TILE)

    def test_glass_bar_is_not_classified_as_atlas(self) -> None:
        self.assertGreater(416, ATLAS_MAX_SHORT)
        self.assertEqual(color_rt_layout(2496, 416), LINEAR)

    def test_wide_tab_strip_is_linear(self) -> None:
        self.assertEqual(color_rt_layout(1819, 89), LINEAR)
        self.assertEqual(color_rt_layout(1981, 40), LINEAR)


class FormatGateTests(unittest.TestCase):
    def test_r8_glyphs_stay_tiled_even_at_glass_sizes(self) -> None:
        for w, h in ((1024, 512), (2048, 2048), (512, 256), (1536, 896)):
            self.assertEqual(color_rt_layout(w, h, bpp=1, r8=True), TILE, f"{w}x{h}")

    def test_a8_path_atlas_stays_tiled(self) -> None:
        self.assertEqual(color_rt_layout(512, 256, bpp=1, a8=True), TILE)
        self.assertEqual(color_rt_layout(128, 128, bpp=1, a8=True), TILE)

    def test_depth_stays_tiled(self) -> None:
        self.assertEqual(color_rt_layout(1920, 1080, depth=True), TILE)

    def test_rejects_empty_size(self) -> None:
        with self.assertRaises(ValueError):
            color_rt_layout(0, 256)


class HuntLogContractTests(unittest.TestCase):
    def test_tile_mode_zero_is_linear(self) -> None:
        self.assertEqual(hunt_tile_to_layout(0), LINEAR)

    def test_tile_mode_three_is_tiled(self) -> None:
        self.assertEqual(hunt_tile_to_layout(3), TILE)

    def test_4bpp_drawer_snow_would_fail_this_table(self) -> None:
        """Regression: 1536x896 / 1536x256 b8g8r8a8 tile=3 was the queue-drawer snow."""
        for w, h in ((1536, 896), (1536, 256), (1536, 864)):
            self.assertEqual(color_rt_layout(w, h), LINEAR, f"{w}x{h}")
        self.assertNotEqual(hunt_tile_to_layout(3), LINEAR)


class AtlasThresholdTests(unittest.TestCase):
    def test_2048x400_is_atlas_boundary_tiled(self) -> None:
        self.assertEqual(color_rt_layout(ATLAS_MIN_LONG, ATLAS_MAX_SHORT), TILE)

    def test_2048x401_is_glass_not_atlas(self) -> None:
        self.assertEqual(color_rt_layout(ATLAS_MIN_LONG, ATLAS_MAX_SHORT + 1), LINEAR)

    def test_2047x360_is_not_atlas(self) -> None:
        self.assertEqual(color_rt_layout(ATLAS_MIN_LONG - 1, 360), LINEAR)


def _old_linear_ui_both_le_1024(width: int, height: int) -> bool:
    """Pre-drawer Mesa: LINEAR only when both sides <= 1024."""
    return width <= 1024 and height <= 1024


class MixedSizeGlassTests(unittest.TestCase):
    """Drawer snow: one side >1024 used to miss linear-ui and stay TILE6_3."""

    MIXED_GLASS = (
        (1536, 896),
        (1536, 256),
        (128, 1088),
        (1280, 720),
        (1600, 256),
        (1920, 88),
        (1920, 1080),
        (2304, 1536),
        (2496, 416),
        (1819, 89),
    )

    def test_mixed_glass_sizes_are_linear(self) -> None:
        for w, h in self.MIXED_GLASS:
            self.assertEqual(color_rt_layout(w, h), LINEAR, f"{w}x{h}")

    def test_old_both_le_1024_rule_would_snow_the_drawer(self) -> None:
        self.assertFalse(_old_linear_ui_both_le_1024(1536, 896))
        self.assertFalse(_old_linear_ui_both_le_1024(1536, 256))
        self.assertEqual(color_rt_layout(1536, 896), LINEAR)
        self.assertEqual(color_rt_layout(1536, 256), LINEAR)


class PageTileBoundaryTests(unittest.TestCase):
    def test_page_tile_box_stays_tiled(self) -> None:
        for w, h in ((832, 576), (1024, 576), (385, 576), (1024, 1024 - 1)):
            self.assertEqual(color_rt_layout(w, h), TILE, f"{w}x{h}")

    def test_square_never_page_tiled(self) -> None:
        for side in (256, 512, 576, 640, 1024):
            self.assertEqual(color_rt_layout(side, side), LINEAR, f"{side}x{side}")

    def test_just_outside_page_tile_box_is_linear(self) -> None:
        self.assertEqual(color_rt_layout(384, 576), LINEAR)  # width not > 383
        self.assertEqual(color_rt_layout(1025, 576), LINEAR)
        self.assertEqual(color_rt_layout(832, 575), LINEAR)
        self.assertEqual(color_rt_layout(832, 1025), LINEAR)


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
