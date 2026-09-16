#!/usr/bin/env python3
"""Align RustDesk mouce uinput ABS with the compositor landscape.

dagu DSI-1 is physically 1600x2560. Daily Mutter is transform 3 (270°) and
scale 1.25, so the logical desktop is 2048x1280. RustDesk 1.4.9 encodes the
rotated capture as 2560x1600 and injects those pixels 1:1 into uinput, but
get_desktop_rect_for_uinput() on a single display uses unrotated physical
width/height. ABS 0:1600 x 0:2560 then clips/stretches clicks onto the
wrong place.

Himax already carries the panel transform. This virtual pointer must stay
unbound and use the rotated physical range (2560x1600) so libinput can
map it onto the logical desktop. Do not change Mutter transform 3.

No D-Bus: udev PROGRAM must return before libinput opens the node.
"""
from __future__ import annotations

import ctypes
import fcntl
import glob
import os
import syslog
import sys
import xml.etree.ElementTree as ET

MOUSE_NAME = "mouce-library-fake-mouse"
DEFAULT_PHY = (1600, 2560)
ABS_X, ABS_Y = 0, 1
# mutter MetaMonitorTransform: 90=1, 270=3
ROTATED = {1, 3}


class AbsInfo(ctypes.Structure):
    _fields_ = [
        ("value", ctypes.c_int),
        ("minimum", ctypes.c_int),
        ("maximum", ctypes.c_int),
        ("fuzz", ctypes.c_int),
        ("flat", ctypes.c_int),
        ("resolution", ctypes.c_int),
    ]


def _ioc(dir_, nr):
    return dir_ | (ctypes.sizeof(AbsInfo) << 16) | (ord("E") << 8) | nr


def eviocgabs(code):
    return _ioc(0x80000000, 0x40 + code)


def eviocsabs(code):
    return _ioc(0x40000000, 0xC0 + code)


def log(msg: str) -> None:
    syslog.syslog(syslog.LOG_INFO, f"dagu-rustdesk-uinput-abs: {msg}")
    print(f"dagu-rustdesk-uinput-abs: {msg}", file=sys.stderr)


def drm_mode() -> tuple[int, int]:
    for path in glob.glob("/sys/class/drm/card*-DSI-1/modes"):
        try:
            line = open(path, encoding="ascii").read().splitlines()
        except OSError:
            continue
        if not line or "x" not in line[0]:
            continue
        w, h = line[0].split("x", 1)
        return int(w), int(h)
    return DEFAULT_PHY


def xml_transform() -> int | None:
    path = "/home/dagu/.config/monitors.xml"
    try:
        rot = ET.parse(path).getroot().findtext(
            ".//logicalmonitor/transform/rotation"
        )
    except (OSError, ET.ParseError):
        return None
    if rot in ("right", "left"):
        return 3
    if rot == "upside_down":
        return 2
    if rot in ("normal", None):
        return 0
    return None


def target_abs(phy_w: int, phy_h: int) -> tuple[int, int]:
    transform = xml_transform()
    if transform is None:
        # Portrait panel + landscape desktop is the daily product path.
        transform = 3 if phy_h > phy_w else 0
    if transform in ROTATED:
        return phy_h, phy_w
    return phy_w, phy_h


def find_mouse_nodes(explicit: str | None) -> list[str]:
    if explicit:
        return [explicit]
    nodes = []
    for path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            name = open(path, encoding="utf-8").read().strip()
        except OSError:
            continue
        if name == MOUSE_NAME:
            ev = os.path.basename(os.path.dirname(os.path.dirname(path)))
            nodes.append(f"/dev/input/{ev}")
    return nodes


def set_abs(node: str, max_x: int, max_y: int) -> None:
    fd = os.open(node, os.O_RDWR)
    try:
        for code, maximum in ((ABS_X, max_x), (ABS_Y, max_y)):
            info = AbsInfo()
            fcntl.ioctl(fd, eviocgabs(code), info)
            info.minimum = 0
            info.maximum = maximum
            info.value = min(max(info.value, 0), maximum)
            fcntl.ioctl(fd, eviocsabs(code), info)
        ax, ay = AbsInfo(), AbsInfo()
        fcntl.ioctl(fd, eviocgabs(ABS_X), ax)
        fcntl.ioctl(fd, eviocgabs(ABS_Y), ay)
        log(f"{node} ABS {ax.minimum}:{ax.maximum} x {ay.minimum}:{ay.maximum}")
        if ax.maximum != max_x or ay.maximum != max_y:
            raise OSError(f"EVIOCSABS did not stick on {node}")
    finally:
        os.close(fd)


def main() -> int:
    syslog.openlog("dagu-rustdesk-uinput-abs")
    explicit = sys.argv[1] if len(sys.argv) > 1 else None
    nodes = find_mouse_nodes(explicit)
    if not nodes:
        log(f"no {MOUSE_NAME} node yet")
        return 0
    phy_w, phy_h = drm_mode()
    max_x, max_y = target_abs(phy_w, phy_h)
    log(f"panel {phy_w}x{phy_h} -> uinput 0:{max_x} x 0:{max_y}")
    for node in nodes:
        set_abs(node, max_x, max_y)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log(f"failed: {exc}")
        raise SystemExit(1)
