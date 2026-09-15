"""Shared display constants for dagu UEFI port tests and docs."""
from __future__ import annotations

# Landscape panel in use
PANEL_WIDTH = 2560
PANEL_HEIGHT = 1600

GLYPH_WIDTH = 8
GLYPH_HEIGHT = 19

# Upscale console shadow to fill the panel (150% -> ~50% larger glyphs vs 100%)
CONSOLE_SCALE_PERCENT = 150

# Logical GOP / shadow resolution (panel / scale)
CONSOLE_LOGICAL_WIDTH = PANEL_WIDTH * 100 // CONSOLE_SCALE_PERCENT
CONSOLE_LOGICAL_HEIGHT = PANEL_HEIGHT * 100 // CONSOLE_SCALE_PERCENT

# Safe inset for rounded corners on the physical panel
SAFE_MARGIN_X = 40
SAFE_MARGIN_Y = 40

# Matching logical margin before upscale (40px / 1.5 = 26px)
SAFE_MARGIN_LOGICAL_X = SAFE_MARGIN_X * 100 // CONSOLE_SCALE_PERCENT
SAFE_MARGIN_LOGICAL_Y = SAFE_MARGIN_Y * 100 // CONSOLE_SCALE_PERCENT

CONOUT_COLUMNS = (
    CONSOLE_LOGICAL_WIDTH - 2 * SAFE_MARGIN_LOGICAL_X
) // GLYPH_WIDTH
CONOUT_ROWS = (
    CONSOLE_LOGICAL_HEIGHT - 2 * SAFE_MARGIN_LOGICAL_Y
) // GLYPH_HEIGHT

# GOP reports the logical (pre-upscale) resolution to UEFI console code
GOP_WIDTH = CONSOLE_LOGICAL_WIDTH
GOP_HEIGHT = CONSOLE_LOGICAL_HEIGHT

from uart_expectations import (  # noqa: F401 re-export for tests
    DTB_SERIAL0_MMIO as DEBUG_UART_PORT_BASE,
    SERIAL_BAUD,
)


def graphics_console_deltas(
    horizontal: int, vertical: int, columns: int, rows: int
) -> tuple[int, int]:
    delta_x = (horizontal - columns * GLYPH_WIDTH) // 2
    delta_y = (vertical - rows * GLYPH_HEIGHT) // 2
    return delta_x, delta_y


def physical_text_extents(columns: int, rows: int) -> tuple[int, int, int, int]:
    """Return physical pixel width/height and margins after console upscale."""
    logical_w = columns * GLYPH_WIDTH
    logical_h = rows * GLYPH_HEIGHT
    phys_w = logical_w * CONSOLE_SCALE_PERCENT // 100
    phys_h = logical_h * CONSOLE_SCALE_PERCENT // 100
    margin_x = (PANEL_WIDTH - phys_w) // 2
    margin_y = (PANEL_HEIGHT - phys_h) // 2
    return phys_w, phys_h, margin_x, margin_y
