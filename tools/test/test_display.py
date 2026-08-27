#!/usr/bin/env python3
"""Display configuration and rotation unit tests for dagu UEFI port."""
from __future__ import annotations

import re
import struct
import subprocess
import sys
import unittest
from pathlib import Path

from display_constants import (
    CONOUT_COLUMNS,
    CONOUT_ROWS,
    CONSOLE_LOGICAL_HEIGHT,
    CONSOLE_LOGICAL_WIDTH,
    CONSOLE_SCALE_PERCENT,
    GLYPH_HEIGHT,
    GLYPH_WIDTH,
    GOP_HEIGHT,
    GOP_WIDTH,
    PANEL_HEIGHT,
    PANEL_WIDTH,
    SAFE_MARGIN_LOGICAL_X,
    SAFE_MARGIN_LOGICAL_Y,
    SAFE_MARGIN_X,
    SAFE_MARGIN_Y,
    graphics_console_deltas,
    physical_text_extents,
)

ROOT = Path(__file__).resolve().parents[2]
PORT_DSC = ROOT / "port/dagu/Platform/Xiaomi/sm8250/dagu.dsc"
DTB = ROOT / "port/dagu/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb"
ELISH_DTB = ROOT / "edk2-msm/Platform/Xiaomi/sm8250/FdtBlob_compat/elish.dtb"
SIMPLEFB = ROOT / "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/SimpleFbDxe/SimpleFbDxe.c"
APPLY_PORT = ROOT / "tools/apply-dagu-port.sh"
DISPLAY_RESERVED_BYTES = 0x02400000
BPP = 4


def parse_dsc_pcds(path: Path, token: str = r"[\w]+") -> dict[str, int | str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    out: dict[str, int | str] = {}
    pattern = rf"g{token}TokenSpaceGuid\.(Pcd\w+)\|([^|#\s]+)"
    for line in text.splitlines():
        m = re.search(pattern, line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if val.startswith('"'):
            out[key] = val.strip('"')
        else:
            out[key] = int(val, 0)
    return out


def rotate_90_cw(panel_x: int, panel_y: int, phys_w: int, phys_h: int) -> tuple[int, int]:
    return phys_w - 1 - panel_y, panel_x


class TestDisplayConstants(unittest.TestCase):
    def test_logical_resolution_scales_to_panel(self) -> None:
        self.assertEqual(CONSOLE_LOGICAL_WIDTH, 1706)
        self.assertEqual(CONSOLE_LOGICAL_HEIGHT, 1066)
        self.assertAlmostEqual(
            CONSOLE_LOGICAL_WIDTH * CONSOLE_SCALE_PERCENT / 100, PANEL_WIDTH, delta=1
        )
        self.assertAlmostEqual(
            CONSOLE_LOGICAL_HEIGHT * CONSOLE_SCALE_PERCENT / 100, PANEL_HEIGHT, delta=1
        )

    def test_conout_dimensions(self) -> None:
        self.assertEqual(CONOUT_COLUMNS, 206)
        self.assertEqual(CONOUT_ROWS, 53)

    def test_physical_margins_after_upscale(self) -> None:
        _, _, margin_x, margin_y = physical_text_extents(CONOUT_COLUMNS, CONOUT_ROWS)
        self.assertGreaterEqual(margin_x, 35)
        self.assertLessEqual(margin_x, 50)
        self.assertGreaterEqual(margin_y, 35)
        self.assertLessEqual(margin_y, 50)


class TestDaguDisplayConfig(unittest.TestCase):
    def setUp(self) -> None:
        self.qcom = parse_dsc_pcds(PORT_DSC, "Qcom")
        self.mde = parse_dsc_pcds(PORT_DSC, "EfiMdeModulePkg")

    def test_dsc_hardware_stride_matches_panel(self) -> None:
        self.assertEqual(self.qcom["PcdMipiFrameBufferWidth"], 1600)
        self.assertEqual(self.qcom["PcdMipiFrameBufferHeight"], 2560)

    def test_dsc_logical_gop_resolution(self) -> None:
        self.assertEqual(self.qcom["PcdMipiFrameBufferVisibleWidth"], CONSOLE_LOGICAL_WIDTH)
        self.assertEqual(self.qcom["PcdMipiFrameBufferVisibleHeight"], CONSOLE_LOGICAL_HEIGHT)

    def test_dsc_console_scale(self) -> None:
        self.assertEqual(self.qcom["PcdMipiFrameBufferConsoleScale"], CONSOLE_SCALE_PERCENT)

    def test_dsc_uart_port_matches_dtb_serial0(self) -> None:
        from display_constants import DEBUG_UART_PORT_BASE

        self.assertEqual(self.qcom.get("PcdDebugUartPortBase"), DEBUG_UART_PORT_BASE)

    def test_dsc_rotation_enabled(self) -> None:
        self.assertEqual(self.qcom["PcdMipiFrameBufferRotation"], 90)

    def test_build_defaults_to_screen_console(self) -> None:
        text = (ROOT / "tools/build-dagu-uefi.sh").read_text(
            encoding="utf-8", errors="replace"
        )
        self.assertIn("USE_UART=0", text)
        self.assertIn("FrameBufferSerialPortLib", text)

    def test_framebuffer_serial_uses_rotation_pcds(self) -> None:
        fb = ROOT / "port/dagu/Silicon/Qualcomm/QcomPkg/Library/FrameBufferSerialPortLib/FrameBufferSerialPortLib.c"
        src = fb.read_text(encoding="utf-8", errors="replace")
        self.assertIn("PcdMipiFrameBufferRotation", src)
        self.assertIn("FbPutPixelLogical", src)

    def test_console_uses_scaled_text_mode(self) -> None:
        self.assertEqual(self.mde["PcdVideoHorizontalResolution"], 0)
        self.assertEqual(self.mde["PcdVideoVerticalResolution"], 0)
        self.assertEqual(self.mde["PcdConOutColumn"], CONOUT_COLUMNS)
        self.assertEqual(self.mde["PcdConOutRow"], CONOUT_ROWS)

    def test_framebuffer_fits_display_reserved(self) -> None:
        phys_w = int(self.qcom["PcdMipiFrameBufferWidth"])
        phys_h = int(self.qcom["PcdMipiFrameBufferHeight"])
        need = phys_w * phys_h * BPP
        self.assertLessEqual(need, DISPLAY_RESERVED_BYTES)

    def test_simplefb_uses_scale_and_rotation(self) -> None:
        src = SIMPLEFB.read_text(encoding="utf-8", errors="replace")
        self.assertIn("PcdMipiFrameBufferRotation", src)
        self.assertIn("PcdMipiFrameBufferConsoleScale", src)
        self.assertIn("mPanelWidth", src)
        self.assertIn("SyncShadowRegionToPhysical", src)
        self.assertIn("mUseShadow", src)

    def test_auto_fullscreen_text_mode_size(self) -> None:
        auto_cols = GOP_WIDTH // GLYPH_WIDTH
        auto_rows = GOP_HEIGHT // GLYPH_HEIGHT
        self.assertEqual(auto_cols, 213)
        self.assertEqual(auto_rows, 56)

    def test_apply_port_adds_scaled_text_mode(self) -> None:
        text = APPLY_PORT.read_text(encoding="utf-8", errors="replace")
        self.assertIn("{ 206, 53 }", text)
        self.assertIn("PcdMipiFrameBufferConsoleScale", text)
        self.assertIn("GraphicsConsole.c", text)


class TestGraphicsConsoleLayout(unittest.TestCase):
    def test_default_80x25_has_large_padding(self) -> None:
        dx, dy = graphics_console_deltas(GOP_WIDTH, GOP_HEIGHT, 80, 25)
        self.assertGreaterEqual(dx, 500)
        self.assertGreaterEqual(dy, 290)

    def test_logical_safe_mode_is_centered(self) -> None:
        dx, dy = graphics_console_deltas(GOP_WIDTH, GOP_HEIGHT, CONOUT_COLUMNS, CONOUT_ROWS)
        self.assertEqual(dx, (GOP_WIDTH - CONOUT_COLUMNS * GLYPH_WIDTH) // 2)
        self.assertEqual(dy, (GOP_HEIGHT - CONOUT_ROWS * GLYPH_HEIGHT) // 2)
        self.assertGreaterEqual(dx, SAFE_MARGIN_LOGICAL_X)
        self.assertGreaterEqual(dy, SAFE_MARGIN_LOGICAL_Y)

    def test_upscaled_text_fills_panel_with_physical_inset(self) -> None:
        phys_w, phys_h, margin_x, margin_y = physical_text_extents(
            CONOUT_COLUMNS, CONOUT_ROWS
        )
        self.assertEqual(phys_w + 2 * margin_x, PANEL_WIDTH)
        self.assertEqual(phys_h + 2 * margin_y, PANEL_HEIGHT)
        self.assertEqual(margin_x, 44)
        self.assertEqual(margin_y, 45)

    def test_scaled_mode_uses_most_of_logical_screen(self) -> None:
        used_w = CONOUT_COLUMNS * GLYPH_WIDTH
        used_h = CONOUT_ROWS * GLYPH_HEIGHT
        self.assertGreaterEqual(used_w / GOP_WIDTH, 0.96)
        self.assertGreaterEqual(used_h / GOP_HEIGHT, 0.94)


class TestSimpleFbPerformance(unittest.TestCase):
    def test_region_sync_used_for_partial_blt(self) -> None:
        src = SIMPLEFB.read_text(encoding="utf-8", errors="replace")
        self.assertIn(
            "SyncShadowRegionToPhysical(DestinationX, DestinationY, Width, Height)",
            src,
        )
        self.assertIn("WriteBackInvalidateDataCacheRange", src)


class TestRotationMath(unittest.TestCase):
    def setUp(self) -> None:
        self.phys_w = 1600
        self.phys_h = 2560

    def test_panel_space_rotation_covers_full_physical_buffer(self) -> None:
        seen = set()
        for panel_y in range(PANEL_HEIGHT):
            for panel_x in range(PANEL_WIDTH):
                px, py = rotate_90_cw(panel_x, panel_y, self.phys_w, self.phys_h)
                self.assertGreaterEqual(px, 0)
                self.assertLess(px, self.phys_w)
                self.assertGreaterEqual(py, 0)
                self.assertLess(py, self.phys_h)
                seen.add((px, py))
        self.assertEqual(len(seen), self.phys_w * self.phys_h)

    def test_panel_space_rotation_corners(self) -> None:
        self.assertEqual(
            rotate_90_cw(0, 0, self.phys_w, self.phys_h),
            (1599, 0),
        )
        self.assertEqual(
            rotate_90_cw(PANEL_WIDTH - 1, PANEL_HEIGHT - 1, self.phys_w, self.phys_h),
            (0, PANEL_WIDTH - 1),
        )

    def test_upscale_sample_indices_stay_in_logical_bounds(self) -> None:
        for panel_y in range(PANEL_HEIGHT):
            for panel_x in range(PANEL_WIDTH):
                lx = panel_x * CONSOLE_LOGICAL_WIDTH // PANEL_WIDTH
                ly = panel_y * CONSOLE_LOGICAL_HEIGHT // PANEL_HEIGHT
                self.assertLess(lx, CONSOLE_LOGICAL_WIDTH)
                self.assertLess(ly, CONSOLE_LOGICAL_HEIGHT)


class TestDaguDtb(unittest.TestCase):
    def test_dtb_exists_and_valid(self) -> None:
        self.assertTrue(DTB.exists(), f"missing {DTB}")
        blob = DTB.read_bytes()
        self.assertEqual(blob[:4], b"\xd0\x0d\xfe\xed")
        size = struct.unpack(">I", blob[4:8])[0]
        self.assertEqual(len(blob), size)

    def test_dtb_contains_l81a_panel(self) -> None:
        text = self._fdtdump(DTB)
        self.assertIn("l81a_42_04_0a", text)

    def test_dtb_panel_stride_dimensions(self) -> None:
        text = self._fdtdump(DTB)
        self.assertRegex(
            text,
            r"l81a_42_04_0a_dual_dphy_video[\s\S]*?"
            r"qcom,mdss-dsi-panel-width = <0x00000320>",
        )
        self.assertRegex(
            text,
            r"l81a_42_04_0a_dual_dphy_video[\s\S]*?"
            r"qcom,mdss-dsi-panel-height = <0x00000a00>",
        )

    def test_dagu_dtb_not_elish_placeholder(self) -> None:
        if not ELISH_DTB.exists():
            self.skipTest("elish.dtb not present for comparison")
        self.assertNotEqual(DTB.read_bytes(), ELISH_DTB.read_bytes())

    @staticmethod
    def _fdtdump(path: Path) -> str:
        try:
            return subprocess.check_output(
                ["fdtdump", str(path)],
                stderr=subprocess.STDOUT,
                text=True,
            )
        except FileNotFoundError:
            raise unittest.SkipTest("fdtdump not installed")
        except subprocess.CalledProcessError as exc:
            self.fail(f"fdtdump failed: {exc.output}")


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
