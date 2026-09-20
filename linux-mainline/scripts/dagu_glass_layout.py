#!/usr/bin/env python3
"""Adreno 650 color-RT layout for Chrome / Mineradio CSS glass.

ANGLE samples these textures as LINEAR. Mesa must allocate LINEAR pixels
or backdrop-filter reads TILE6_3 as row-major snow.

Hunt (Mineradio, 2026-09-20):
  640x384  / 1024x512  playlist cards   — glass, must LINEAR
  1536x256 / 1536x896  playlist drawer  — glass, must LINEAR
  512x256  / 256x256   padded glass     — already LINEAR
  832x576               Chrome page tile — TILE6_3
  3840x360              Skia atlas strip — TILE6_3
  R8 glyphs             — TILE6_3

Do not disable backdrop-filter or GPU raster.
"""
from __future__ import annotations

from typing import Literal

Layout = Literal["LINEAR", "TILE"]

LINEAR: Layout = "LINEAR"
TILE: Layout = "TILE"

# Atlas strip: Skia 3840x360. Not the 2496x416 glass bar (height 416).
ATLAS_MIN_LONG = 2048
ATLAS_MAX_SHORT = 400

# Chrome OOP raster tile 832x576. Floor 576 keeps 640x384 / 1024x512 glass
# out of this bucket (those pads are height 384 and 512).
PAGE_MIN_H = 576
PAGE_MAX_H = 1024
PAGE_MIN_W = 384
PAGE_MAX_W = 1024


def color_rt_layout(
    width: int,
    height: int,
    *,
    bpp: int = 4,
    r8: bool = False,
    a8: bool = False,
    depth: bool = False,
) -> Layout:
    """Return LINEAR or TILE for a color render target.

    bpp is bytes per pixel of the color format. R8/A8/depth stay tiled:
    those are sampled with the real fdl layout, not ANGLE-as-LINEAR.
    """
    if width <= 0 or height <= 0:
        raise ValueError(f"invalid size {width}x{height}")
    if depth or r8 or a8 or bpp == 1:
        return TILE
    if bpp != 4:
        return TILE

    long_side = max(width, height)
    short_side = min(width, height)
    if long_side >= ATLAS_MIN_LONG and short_side <= ATLAS_MAX_SHORT:
        return TILE

    if (
        width != height
        and PAGE_MIN_W < width <= PAGE_MAX_W
        and PAGE_MIN_H <= height <= PAGE_MAX_H
    ):
        return TILE

    return LINEAR


# (name, width, height, bpp, r8, expected)
# Live hunt sizes first; then the destile / icon-upload corpus.
LAYOUT_CASES: list[tuple[str, int, int, int, bool, Layout]] = [
    # Mineradio playlist cards (snow before page-tile floor 576)
    ("mineradio-card-snapshot", 640, 384, 4, False, LINEAR),
    ("mineradio-card-blur", 1024, 512, 4, False, LINEAR),
    ("mineradio-card-pad-512x256", 512, 256, 4, False, LINEAR),
    ("mineradio-card-pad-256", 256, 256, 4, False, LINEAR),
    ("mineradio-card-pad-512", 512, 512, 4, False, LINEAR),
    # Mineradio playlist / queue drawer (snow after card fix)
    ("mineradio-drawer-panel", 1536, 896, 4, False, LINEAR),
    ("mineradio-drawer-header", 1536, 256, 4, False, LINEAR),
    ("mineradio-drawer-panel-864", 1536, 864, 4, False, LINEAR),
    ("mineradio-drawer-narrow", 128, 1088, 4, False, LINEAR),
    # Search / window
    ("mineradio-search-1024x128", 1024, 128, 4, False, LINEAR),
    ("mineradio-window-1920x1080", 1920, 1080, 4, False, LINEAR),
    ("mineradio-window-2304x1536", 2304, 1536, 4, False, LINEAR),
    ("chrome-swapchain-2477x1560", 2477, 1560, 4, False, LINEAR),
    # Chrome CSS glass probe
    ("glass-bar-2496x416", 2496, 416, 4, False, LINEAR),
    ("glass-icon-64x32", 64, 32, 4, False, LINEAR),
    ("glass-icon-32x32", 32, 32, 4, False, LINEAR),
    ("glass-icon-128x128", 128, 128, 4, False, LINEAR),
    ("tab-strip-1819x89", 1819, 89, 4, False, LINEAR),
    ("toolbar-1981x40", 1981, 40, 4, False, LINEAR),
    # Must stay TILE
    ("chrome-page-tile-832x576", 832, 576, 4, False, TILE),
    ("skia-atlas-3840x360", 3840, 360, 4, False, TILE),
    ("skia-atlas-2560x240", 2560, 240, 4, False, TILE),
    ("skia-atlas-2048x400", 2048, 400, 4, False, TILE),
    ("glyph-r8-2048", 2048, 2048, 1, True, TILE),
    ("glyph-r8-1024x512", 1024, 512, 1, True, TILE),
    ("glyph-r8-drawer-size", 1536, 896, 1, True, TILE),
    ("path-atlas-a8-512", 512, 256, 1, True, TILE),
    # Mixed-size 4bpp that the old both-le-1024 linear-ui missed
    ("mixed-1280x720", 1280, 720, 4, False, LINEAR),
    ("mixed-1600x256", 1600, 256, 4, False, LINEAR),
    ("mixed-1920x88", 1920, 88, 4, False, LINEAR),
    ("page-tile-1024x576", 1024, 576, 4, False, TILE),
    ("page-tile-385x576", 385, 576, 4, False, TILE),
    ("square-1024", 1024, 1024, 4, False, LINEAR),
]


def hunt_tile_to_layout(tile: int) -> Layout:
    """fdl tile_mode 0 = LINEAR, 3 = TILE6_3."""
    if tile == 0:
        return LINEAR
    return TILE
