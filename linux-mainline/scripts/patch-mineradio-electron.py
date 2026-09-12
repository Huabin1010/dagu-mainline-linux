#!/usr/bin/env python3
"""Patch the installed Mineradio Electron main process for dagu.

Removes FD_MESA_DEBUG=notile (a650 WebGL CCU hang) and appends the same
font / fractional-scale switches as linux-mainline/scripts/dagu-chrome.sh.
"""
from __future__ import annotations

import pathlib
import sys

DEFAULT = pathlib.Path("/opt/Mineradio/resources/app/desktop/main.js")


def patch(text: str) -> str:
    old_notile = "process.env.FD_MESA_DEBUG = 'noubwc,notile';"
    new_notile = "process.env.FD_MESA_DEBUG = process.env.FD_MESA_DEBUG || 'noubwc';"
    if old_notile in text:
        text = text.replace(old_notile, new_notile, 1)
    needle = "['disable-features', 'Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation'],"
    extra = """['disable-features', 'Vulkan,DefaultANGLEVulkan,VulkanFromANGLE,WaylandOverlayDelegation'],
    ['enable-features', 'WaylandFractionalScaleV1'],
    ['disable-lcd-text'],
    ['font-render-hinting', 'none'],"""
    if "['disable-lcd-text']" not in text and needle in text:
        text = text.replace(needle, extra, 1)
    return text


def main() -> int:
    path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)
    orig = path.read_text(encoding="utf-8")
    new = patch(orig)
    if new == orig:
        print(f"unchanged {path}")
        return 0
    path.write_text(new, encoding="utf-8")
    print(f"patched {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
