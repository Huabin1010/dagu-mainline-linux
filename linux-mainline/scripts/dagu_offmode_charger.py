#!/usr/bin/env python3
"""Off-mode charging, matching the HyperOS charger path on this board.

The flash-package ramdisk starts /system/bin/charger when the bootloader
sets androidboot.mode=charger, and does not start the desktop. This
program is that screen on Linux:

  * battery percent from the composite gauge
  * panel sleeps after a long idle (backlight floor, black frame)
  * short power key wakes the battery
  * holding the power key boots the desktop
  * unplug powers off

Shutting down from the desktop is a real power-off, as on Android. With
the cable in, the PMIC powers the tablet straight back up and ABL boots
the kernel with androidboot.mode=charger; that is the only way into this
screen. Nothing holds the shutdown back: an old delay inhibitor kept
logind waiting its full 20 s, long enough for GDM to respawn the greeter.

A USB cable used for the serial gadget also makes the charger look
online. That alone must not skip the desktop. Only a charger wake
(bootloader mode, charger boot reason, or power-on reason without the
power key) enters this screen. A leftover shutdown flag does not.
"""

from __future__ import annotations

import argparse
import glob
import math
import mmap
import os
import select
import struct
import subprocess
import threading
import time
import zlib
from dataclasses import dataclass
from pathlib import Path

PENDING = Path("/var/lib/dagu/offmode-pending")
MODE_FLAG = Path("/run/dagu-charger-mode")
REAL_POWEROFF = Path("/run/dagu-real-poweroff")
CMDLINE_PATH = Path("/proc/cmdline")
PSY_CHARGER = Path("/sys/class/power_supply/pm8150b-charger")
PSY_BATT = Path("/sys/class/power_supply/bms")
PSY_CELLS = (
    Path("/sys/class/power_supply/bq27z561-0"),
    Path("/sys/class/power_supply/bq27z561-1"),
)
FB_PATH = "/dev/fb0"
FB_SYS = Path("/sys/class/graphics/fb0")
BACKLIGHT = Path("/sys/class/backlight/l81a-wled/brightness")
BL_POWER = Path("/sys/class/backlight/l81a-wled/bl_power")
# The panel driver keeps the LEDs off through a charger boot until this
# is cleared, so the kernel log never shows (Android shows nothing either).
CHARGER_DARK = Path("/sys/module/panel_xiaomi_dagu_l81a/parameters/charger_dark")
BL_POWER_ON = 0
BL_POWER_OFF = 4

# PM8150 PON_REASON1. Power-key wins over cable, same as the bootloader.
PON_HARD_RESET = 0x01
PON_USB_CHG = 0x10
PON_CBLPWR = 0x40
PON_KPDPWR = 0x80
PON_DC_CHG = 0x08
PON_CHARGER = PON_USB_CHG | PON_CBLPWR | PON_DC_CHG

CHARGER_REASONS = frozenset(
    {
        "usb",
        "usb_chg",
        "usbchg",
        "charger",
        "cblpwr",
        "cable",
        "offmode_charge",
        "off-mode-charge",
        "offmode-charge",
    }
)
PWRKEY_REASONS = frozenset(
    {
        "kpdpwr",
        "pwr_key",
        "power_key",
        "powerkey",
        "pon1",
        "hard",
        "hard_reset",
        "hardreset",
    }
)
WARM_REASONS = frozenset({"reboot", "kernel_panic", "panic", "watchdog", "wdt"})

# HyperOS keeps the battery up, then the panel sleeps. Measured on this
# tablet: about 45 s with no key. 8 s looked like a blink.
SCREEN_ON_SEC = 45.0
LONG_PRESS = 2.5
# Android healthd waits through a short cable bounce. A few seconds of
# USBIN absent while the port manager still sees the partner is not an
# unplug; powering off there reboots straight into the kernel console.
UNPLUG_SEC = 15.0
KDSETMODE = 0x4B3A
KD_GRAPHICS = 1
GATE_WAIT_SEC = 8.0

KEY_POWER = 116
EV_KEY = 1
EV_FMT = "llHHI"
EV_SIZE = struct.calcsize(EV_FMT)
EVIOCGRAB = 0x40044590

# Panel scanout is portrait. The tablet is used landscape, same 270 deg
# turn the desktop uses, so the battery stands upright.
ROTATE = 270

BLACK = b"\x00\x00\x00\x00"
WHITE = b"\xff\xff\xff\x00"
GREEN = b"\x50\xd0\x50\x00"
YELLOW = b"\x00\xd8\xff\x00"
RED = b"\x40\x40\xff\x00"
GRAY = b"\x90\x90\x90\x00"

_FONT = {
    " ": (0, 0, 0, 0, 0, 0, 0),
    "0": (0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E),
    "1": (0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E),
    "2": (0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F),
    "3": (0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E),
    "4": (0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02),
    "5": (0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E),
    "6": (0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E),
    "7": (0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08),
    "8": (0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E),
    "9": (0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C),
    "%": (0x19, 0x1A, 0x04, 0x08, 0x0B, 0x13, 0x00),
    "-": (0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00),
    "?": (0x0E, 0x11, 0x01, 0x06, 0x04, 0x00, 0x04),
}


@dataclass(frozen=True)
class BootHints:
    cmdline: str = ""
    pending: bool = False
    charger_online: bool | None = None
    pon_reason: int | None = None
    pwrkey_held: bool = False


def cmdline_map(cmdline: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for tok in cmdline.split():
        if "=" not in tok:
            continue
        key, _, val = tok.partition("=")
        out[key] = val
    return out


def bootreason_token(cmdline: str) -> str:
    kv = cmdline_map(cmdline)
    raw = (
        kv.get("androidboot.bootreason")
        or kv.get("bootreason")
        or kv.get("androidboot.reboot_reason")
        or ""
    )
    raw = raw.strip().lower().replace(",", " ").replace(":", " ")
    parts = [p for p in raw.split() if p]
    if not parts:
        return ""
    if parts[0] == "reboot" and len(parts) > 1:
        return parts[-1]
    return parts[0]


def charger_wake(h: BootHints) -> bool:
    """True when this boot was caused by the cable, not the power key.

    The debug cable makes the charger look online on a normal desktop
    boot. androidboot.mode=charger from the bootloader is the signal
    the flash package uses. A stale pending file is not.
    """
    if h.pwrkey_held:
        return False
    reason = bootreason_token(h.cmdline)
    if reason in PWRKEY_REASONS or reason in WARM_REASONS:
        return False
    if h.pon_reason is not None:
        if h.pon_reason & PON_KPDPWR or h.pon_reason & PON_HARD_RESET:
            return False

    kv = cmdline_map(h.cmdline)
    mode = kv.get("androidboot.mode", "").lower()
    if mode in ("normal", "recovery", "bootloader"):
        return False
    if mode == "charger" or reason in CHARGER_REASONS:
        return True
    if h.pon_reason is not None and (h.pon_reason & PON_CHARGER):
        return True
    return False


def want_charger_mode(h: BootHints) -> bool:
    """True = skip the desktop and draw the battery."""
    if h.charger_online is False:
        return False
    return charger_wake(h)


def parse_pon_reason(text: str) -> int | None:
    t = text.strip().lower()
    if not t:
        return None
    try:
        return int(t, 0 if t.startswith("0x") else 16)
    except ValueError:
        return None


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def psy_int(root: Path, name: str) -> int | None:
    try:
        return int((root / name).read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None


def charger_online() -> bool | None:
    v = psy_int(PSY_CHARGER, "online")
    if v is None:
        return None
    return bool(v)


def vbus_from_flags(flags: list[int | None]) -> bool | None:
    """True when any charger input still reports the cable."""
    seen = [v for v in flags if v is not None]
    if not seen:
        return None
    return any(bool(v) for v in seen)


def vbus_present() -> bool | None:
    flags: list[int | None] = [psy_int(PSY_CHARGER, "online")]
    for path in glob.glob("/sys/class/power_supply/tcpm-source-psy-*/online"):
        try:
            flags.append(int(Path(path).read_text(encoding="ascii").strip()))
        except (OSError, ValueError):
            flags.append(None)
    return vbus_from_flags(flags)


def battery_capacity() -> int:
    v = psy_int(PSY_BATT, "capacity")
    if v is None:
        cells = [psy_int(p, "capacity") for p in PSY_CELLS]
        cells = [c for c in cells if c is not None]
        if not cells:
            return -1
        v = sum(cells) // len(cells)
    return max(0, min(100, v))


def battery_status() -> str:
    st = read_text(PSY_BATT / "status")
    if st:
        return st
    for p in PSY_CELLS:
        st = read_text(p / "status")
        if st:
            return st
    return "Unknown"


def wait_charger(timeout: float = GATE_WAIT_SEC) -> bool | None:
    deadline = time.monotonic() + timeout
    last: bool | None = None
    while time.monotonic() < deadline:
        last = charger_online()
        if last is not None:
            return last
        time.sleep(0.2)
    return last


def find_pon_reason() -> int | None:
    candidates = (
        "/sys/kernel/debug/qcom-pon/reason",
        "/sys/power/pmic_pon_state",
        "/sys/bus/spmi/devices/*/pon_reason",
    )
    for pat in candidates:
        paths = glob.glob(pat) if "*" in pat else [pat]
        for path in paths:
            got = parse_pon_reason(read_text(Path(path)))
            if got is not None:
                return got
    return None


def find_pwrkey() -> str | None:
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            name = Path(name_path).read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if name == "pm8941_pwrkey":
            return "/dev/input/" + name_path.split("/")[4]
    return None


def pwrkey_held(event_path: str | None = None) -> bool:
    path = event_path or find_pwrkey()
    if not path:
        return False
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        import fcntl

        buf = bytearray(96)
        ioc = (2 << 30) | (96 << 16) | (ord("E") << 8) | 0x18
        fcntl.ioctl(fd, ioc, buf)
        return bool(buf[KEY_POWER // 8] & (1 << (KEY_POWER % 8)))
    except OSError:
        return False
    finally:
        os.close(fd)


def mark_pending() -> None:
    PENDING.parent.mkdir(parents=True, exist_ok=True)
    PENDING.write_text("1\n", encoding="ascii")
    try:
        os.sync()
    except OSError:
        pass


def clear_pending() -> None:
    try:
        PENDING.unlink()
    except OSError:
        pass


def mark_mode() -> None:
    try:
        MODE_FLAG.write_text("1\n", encoding="ascii")
    except OSError:
        pass


def clear_mode() -> None:
    try:
        MODE_FLAG.unlink()
    except OSError:
        pass


def log(msg: str) -> None:
    print(f"dagu-offmode: {msg}", flush=True)


def run(cmd: list[str]) -> int:
    try:
        return subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return 127


def cmd_gate() -> int:
    cmdline = read_text(CMDLINE_PATH)
    pending = PENDING.is_file()
    pon = find_pon_reason()
    # Do not wait on the charger just because a shutdown flag is left
    # over or a USB cable is plugged. That wait used to hold the desktop.
    hinted = BootHints(cmdline=cmdline, pending=pending, pon_reason=pon, pwrkey_held=pwrkey_held())
    if not charger_wake(hinted):
        clear_mode()
        release_charger_dark()
        if pending:
            clear_pending()
            log("gate clear stale pending")
        log("gate skip (desktop)")
        return 0
    online = wait_charger()
    h = BootHints(
        cmdline=cmdline,
        pending=pending,
        charger_online=online,
        pon_reason=pon,
        pwrkey_held=hinted.pwrkey_held,
    )
    enter = want_charger_mode(h)
    log(
        f"gate pending={h.pending} charger={h.charger_online} "
        f"pon={h.pon_reason!r} pwrkey={h.pwrkey_held} "
        f"reason={bootreason_token(h.cmdline)!r} enter={enter}"
    )
    if enter:
        mark_mode()
        # Not enabled at boot: its Conflicts= on gdm would drop the
        # gdm start job from a normal desktop boot. Queue it here; the
        # stop job it puts on gdm replaces the pending gdm start.
        run(["systemctl", "start", "--no-block", "dagu-offmode-charger.service"])
        return 0
    # Charger boot, but the cable is already gone or the key is held:
    # the desktop comes up, so the panel must light.
    clear_mode()
    clear_pending()
    release_charger_dark()
    return 0


def cmd_mark_pending() -> int:
    mark_pending()
    log("marked pending")
    return 0


def start_gnome() -> None:
    clear_mode()
    clear_pending()
    # Long press boots the desktop: same as a normal boot from here on,
    # the rest of the system came up with this charger boot.
    release_charger_dark()
    set_bl_power(BL_POWER_ON)
    # The charger service conflicts with the desktop until this process
    # exits. Schedule the handoff in its own unit so it still runs.
    run(
        [
            "systemd-run",
            "--collect",
            "--unit=dagu-charger-handoff",
            "/bin/sh",
            "-c",
            "sleep 0.6; "
            "systemctl reset-failed gdm.service gdm3.service || true; "
            "systemctl start gdm.service; "
            "systemctl unmask --runtime serial-getty@tty0.service "
            "getty@tty1.service || true",
        ]
    )


def real_poweroff() -> None:
    try:
        REAL_POWEROFF.write_text("1\n", encoding="ascii")
    except OSError:
        pass
    mark_pending()
    run(["systemctl", "poweroff", "--force", "--no-block"])
    time.sleep(8)
    os._exit(0)



class Surface:
    """32-bit scanout. Logical coordinates are rotated for the user."""

    def __init__(self, buf: bytearray | mmap.mmap, w: int, h: int, stride: int) -> None:
        self.buf = buf
        self.w = w
        self.h = h
        self.stride = stride
        if ROTATE in (90, 270):
            self.lw, self.lh = h, w
        else:
            self.lw, self.lh = w, h

    def map_xy(self, lx: int, ly: int) -> tuple[int, int]:
        if ROTATE == 90:
            return ly, self.h - 1 - lx
        if ROTATE == 270:
            return self.w - 1 - ly, lx
        if ROTATE == 180:
            return self.w - 1 - lx, self.h - 1 - ly
        return lx, ly

    def fill(self, bgra: bytes) -> None:
        row = bgra * self.w + b"\x00" * (self.stride - self.w * 4)
        blob = row * self.h
        self.buf[0 : len(blob)] = blob

    def hline_fb(self, y: int, x0: int, x1: int, bgra: bytes) -> None:
        if y < 0 or y >= self.h:
            return
        x0 = max(0, min(self.w - 1, x0))
        x1 = max(0, min(self.w - 1, x1))
        if x1 < x0:
            x0, x1 = x1, x0
        off = y * self.stride + x0 * 4
        n = x1 - x0 + 1
        self.buf[off : off + n * 4] = bgra * n

    def rect(self, lx: int, ly: int, w: int, h: int, bgra: bytes) -> None:
        if w <= 0 or h <= 0:
            return
        x0, y0 = self.map_xy(lx, ly)
        x1, y1 = self.map_xy(lx + w - 1, ly + h - 1)
        xa, xb = (x0, x1) if x0 <= x1 else (x1, x0)
        ya, yb = (y0, y1) if y0 <= y1 else (y1, y0)
        for y in range(ya, yb + 1):
            self.hline_fb(y, xa, xb, bgra)

    def text(self, lx: int, ly: int, s: str, bgra: bytes, scale: int = 10) -> None:
        cx = lx
        for ch in s:
            glyph = _FONT.get(ch, _FONT["?"])
            for row, bits in enumerate(glyph):
                for col in range(5):
                    if bits & (0x10 >> col):
                        self.rect(cx + col * scale, ly + row * scale, scale, scale, bgra)
            cx += 6 * scale

    def text_width(self, s: str, scale: int = 10) -> int:
        return len(s) * 6 * scale

    def fb_rect(self, lx: int, ly: int, w: int, h: int) -> tuple[int, int, int, int]:
        """Scanout rectangle (x0, y0, x1, y1 inclusive) of a logical one."""
        x0, y0 = self.map_xy(lx, ly)
        x1, y1 = self.map_xy(lx + w - 1, ly + h - 1)
        return min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)

    def copy_to(self, dst: "Surface", lx: int = 0, ly: int = 0,
                w: int | None = None, h: int | None = None) -> None:
        """Copy a finished region to the scanout, one memmove per row.

        Drawing straight into the scanout let the panel show the cleared
        and half-drawn states. The frame is built here first; the scanout
        only ever sees whole rows of the new frame.
        """
        if w is None or h is None:
            n = self.stride * self.h
            dst.buf[0:n] = memoryview(self.buf)[0:n]
            return
        x0, y0, x1, y1 = self.fb_rect(lx, ly, w, h)
        src = memoryview(self.buf)
        a = x0 * 4
        b = (x1 + 1) * 4
        for y in range(y0, y1 + 1):
            off = y * self.stride
            dst.buf[off + a : off + b] = src[off + a : off + b]

    def count(self, bgra: bytes) -> int:
        raw = self.buf if isinstance(self.buf, (bytes, bytearray)) else bytes(self.buf)
        n = 0
        for y in range(self.h):
            row = raw[y * self.stride : y * self.stride + self.w * 4]
            n += row.count(bgra)
        return n


def draw_bolt(fb: Surface, cx: int, cy: int, color: bytes, s: int) -> None:
    fb.rect(cx - s, cy - 5 * s, 2 * s, 4 * s, color)
    fb.rect(cx - 2 * s, cy - s, 5 * s, 2 * s, color)
    fb.rect(cx + s, cy, 2 * s, 5 * s, color)


# Android's charger animates the level while charging; the frame never
# blanks. A soft light sweeps across the filled part, 30 frames a second,
# then rests. Only the inside of the battery changes between frames.
FRAME_SEC = 1.0 / 30.0
SWEEP_SEC = 1.6
REST_SEC = 0.7


def _blend(a: bytes, b: bytes, k: float) -> bytes:
    return bytes(int(a[i] + (b[i] - a[i]) * k) for i in range(3)) + b"\x00"


def battery_box(fb: Surface) -> tuple[int, int, int, int, int, int, int, int, int]:
    bw, bh = 520, 260
    x = (fb.lw - bw) // 2
    y = (fb.lh - bh) // 2 - 40
    t = 14
    ix, iy = x + 2 * t, y + 2 * t
    return x, y, bw, bh, t, ix, iy, bw - 4 * t, bh - 4 * t


def fill_color(cap: int) -> bytes:
    if cap < 0:
        return GRAY
    if cap < 15:
        return RED
    if cap < 30:
        return YELLOW
    return GREEN


def sweep_phase(elapsed: float) -> float:
    """0 → 1 across the sweep, 1 while resting (no highlight shown)."""
    cyc = elapsed % (SWEEP_SEC + REST_SEC)
    return min(1.0, cyc / SWEEP_SEC)


BOLT_SCALE = 8


def fill_shades(cap: int, charging: bool, phase: float, iw: int) -> list[bytes]:
    """Colour of each column inside the battery, left to right."""
    frac = 0.0 if cap < 0 else min(1.0, cap / 100.0)
    fill_w = int(iw * frac)
    color = fill_color(cap)
    cols = [color] * fill_w + [BLACK] * (iw - fill_w)
    if fill_w > 0 and charging and 0 <= cap < 100:
        band = max(24, iw // 4)
        ease = 0.5 - 0.5 * math.cos(math.pi * max(0.0, min(1.0, phase)))
        centre = -band + (fill_w + 2 * band) * ease
        hi = _blend(color, WHITE, 0.5)
        shades = [_blend(color, hi, i / 16) for i in range(17)]
        for cx in range(max(0, int(centre - band)), min(fill_w, int(centre + band) + 1)):
            d = 1.0 - abs(cx - centre) / band
            if d > 0.0:
                cols[cx] = shades[int(16 * d * d * (3.0 - 2.0 * d))]
    return cols


def bolt_columns(fb: Surface) -> range:
    """Columns inside the battery that the bolt covers."""
    x, _y, bw, _bh, _t, ix, _iy, _iw, _ih = battery_box(fb)
    cx = x + bw // 2
    return range(cx - 2 * BOLT_SCALE - ix, cx + 3 * BOLT_SCALE - ix)


def paint_columns(fb: Surface, shades: list[bytes], columns, charging: bool) -> None:
    x, y, bw, bh, _t, ix, iy, _iw, ih = battery_box(fb)
    for cx in columns:
        fb.rect(ix + cx, iy, 1, ih, shades[cx])
    if charging:
        draw_bolt(fb, x + bw // 2, y + bh // 2, WHITE, BOLT_SCALE)


def draw_fill(fb: Surface, cap: int, charging: bool, phase: float = 1.0) -> None:
    """Redraw the inside of the battery. Every pixel is written once."""
    iw = battery_box(fb)[7]
    paint_columns(fb, fill_shades(cap, charging, phase, iw), range(iw), charging)


def draw_battery(fb: Surface, cap: int, charging: bool, phase: float = 1.0) -> None:
    fb.fill(BLACK)
    x, y, bw, bh, t, _ix, _iy, _iw, _ih = battery_box(fb)
    nub_w, nub_h = 36, 90
    fb.rect(x, y, bw, t, WHITE)
    fb.rect(x, y + bh - t, bw, t, WHITE)
    fb.rect(x, y, t, bh, WHITE)
    fb.rect(x + bw - t, y, t, bh, WHITE)
    fb.rect(x + bw, y + (bh - nub_h) // 2, nub_w, nub_h, WHITE)
    draw_fill(fb, cap, charging, phase)
    label = "--%" if cap < 0 else f"{cap}%"
    scale = 14
    tw = fb.text_width(label, scale)
    fb.text((fb.lw - tw) // 2, y + bh + 48, label, WHITE, scale)


def memory_surface(w: int = 800, h: int = 1280) -> Surface:
    stride = w * 4
    return Surface(bytearray(stride * h), w, h, stride)


def logical_rgb(fb: Surface) -> tuple[int, int, bytes]:
    """User-facing landscape image, row-major RGB."""
    raw = bytes(fb.buf)
    rows = bytearray()
    for ly in range(fb.lh):
        for lx in range(fb.lw):
            x, y = fb.map_xy(lx, ly)
            off = y * fb.stride + x * 4
            b, g, r = raw[off], raw[off + 1], raw[off + 2]
            rows += bytes((r, g, b))
    return fb.lw, fb.lh, bytes(rows)


def write_png(path: Path, w: int, h: int, rgb: bytes) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    raw = b"".join(b"\x00" + rgb[y * w * 3 : (y + 1) * w * 3] for y in range(h))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def read_brightness() -> int | None:
    try:
        return int(BACKLIGHT.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None


def write_brightness(value: int) -> None:
    try:
        BACKLIGHT.write_text(str(int(value)), encoding="ascii")
    except OSError:
        pass


def read_bl_power() -> int | None:
    try:
        return int(BL_POWER.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None


def set_bl_power(value: int) -> None:
    try:
        BL_POWER.write_text(str(int(value)), encoding="ascii")
    except OSError:
        pass


def release_charger_dark() -> None:
    try:
        CHARGER_DARK.write_text("0", encoding="ascii")
    except OSError:
        pass


def unblank(saved: int | None) -> None:
    try:
        (FB_SYS / "blank").write_text("0", encoding="ascii")
    except OSError:
        pass
    if saved is not None and saved > 0:
        write_brightness(saved)
    set_bl_power(BL_POWER_ON)
    release_charger_dark()


def blank_panel(fb: Surface | None) -> None:
    # bl_power off switches the LED boost off (HWEN and the DSI link stay
    # up), so the asleep screen is dark like Android's, not a dim glow.
    # Lights first, then clear: clearing a lit panel shows a black frame.
    set_bl_power(BL_POWER_OFF)
    if fb is not None:
        fb.fill(BLACK)


def quiet_console() -> None:
    """Stop the framebuffer console from repainting the kernel log.

    The boot command line leaves that console on the panel. The Android
    charger takes the display and does not share it with the log.
    """
    try:
        Path("/proc/sys/kernel/printk").write_text("1\n", encoding="ascii")
    except OSError:
        pass
    for bind in glob.glob("/sys/class/vtconsole/vtcon*/bind"):
        try:
            Path(bind).write_text("0", encoding="ascii")
        except OSError:
            pass
    import fcntl

    for tty in ("/dev/tty0", "/dev/tty1"):
        try:
            fd = os.open(tty, os.O_RDWR | os.O_NOCTTY)
        except OSError:
            continue
        try:
            fcntl.ioctl(fd, KDSETMODE, KD_GRAPHICS)
        except OSError:
            pass
        finally:
            os.close(fd)


def hold_consoles() -> None:
    """Keep GDM and the text logins off the panel for this charger boot.

    Each `systemctl mask --runtime` is a daemon reload (about a second
    each at boot), so this runs after the battery is already on screen.
    GDM never started: the gate queued this unit, whose Conflicts= on
    GDM replaced GDM's start job. Stopping it again is only a guard.
    """
    run(["systemctl", "stop", "--no-block", "gdm.service", "gdm3.service"])
    run(["systemctl", "stop", "serial-getty@tty0.service", "getty@tty1.service"])
    run(
        [
            "systemctl",
            "mask",
            "--runtime",
            "serial-getty@tty0.service",
            "getty@tty1.service",
        ]
    )


def enable_wakeup() -> None:
    for path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            name = Path(path).read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if name != "pm8941_pwrkey":
            continue
        wake = Path(path).parent / "power" / "wakeup"
        try:
            wake.write_text("enabled", encoding="ascii")
        except OSError:
            pass
        break


def open_fb() -> tuple[Surface, int]:
    wh = (FB_SYS / "virtual_size").read_text(encoding="ascii").strip().split(",")
    w, h = int(wh[0]), int(wh[1])
    stride = int((FB_SYS / "stride").read_text(encoding="ascii").strip())
    bpp = int((FB_SYS / "bits_per_pixel").read_text(encoding="ascii").strip())
    if bpp != 32:
        raise SystemExit(f"fb0 is {bpp}bpp, need 32")
    fd = os.open(FB_PATH, os.O_RDWR)
    mm = mmap.mmap(fd, stride * h, access=mmap.ACCESS_WRITE)
    return Surface(mm, w, h, stride), fd


def open_pwrkey() -> int | None:
    path = find_pwrkey()
    if not path:
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        import fcntl

        fcntl.ioctl(fd, EVIOCGRAB, 1)
    except OSError:
        pass
    return fd


def start_inhibit() -> subprocess.Popen[bytes] | None:
    try:
        return subprocess.Popen(
            [
                "systemd-inhibit",
                "--what=handle-power-key:handle-suspend-key:sleep",
                "--mode=block",
                "--who=dagu-offmode-ui",
                "--why=charger screen",
                "sleep",
                "infinity",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None


def cmd_render(capacity: int, charging: bool, out: Path) -> int:
    fb = memory_surface()
    draw_battery(fb, capacity, charging, 1.0)
    w, h, rgb = logical_rgb(fb)
    # logical_rgb walks the full rotated view. memory_surface is small
    # so the PNG stays a check of layout, not a panel-sized file.
    write_png(out, w, h, rgb)
    log(f"render cap={capacity} charging={charging} {w}x{h} -> {out}")
    return 0


def cmd_preview(seconds: float, blank_after: float) -> int:
    """Draw on the panel, sleep the backlight, restore. No power-off."""
    saved = read_brightness()
    if saved is None or saved <= 0:
        saved = 800
    fb, fd = open_fb()
    inhibit = start_inhibit()
    green_before_blank = 0
    blank_level: int | None = None
    try:
        unblank(saved)
        cap = battery_capacity()
        st = battery_status().lower()
        charging = st == "charging" and cap < 100
        draw_battery(fb, cap, charging, 1.0)
        green_before_blank = fb.count(GREEN)
        log(
            f"preview cap={cap} status={battery_status()} "
            f"green={green_before_blank} white={fb.count(WHITE)} saved_bl={saved}"
        )
        show_until = time.monotonic() + max(0.0, blank_after)
        end = time.monotonic() + max(seconds, blank_after)
        blanked = False
        while time.monotonic() < end:
            if not blanked and time.monotonic() >= show_until:
                blank_panel(fb)
                blanked = True
                blank_level = read_bl_power()
                log(f"preview blank bl_power={blank_level}")
            time.sleep(0.2)
        if not blanked:
            blank_panel(fb)
            blank_level = read_bl_power()
    finally:
        unblank(saved)
        try:
            fb.buf.close()  # type: ignore[union-attr]
        except Exception:
            pass
        os.close(fd)
        if inhibit is not None and inhibit.poll() is None:
            inhibit.terminate()
    restored = read_brightness()
    log(f"preview restored brightness={restored} blank_was={blank_level}")
    if green_before_blank < 1000:
        log("preview frame has too little fill")
        return 1
    if blank_level != BL_POWER_OFF:
        log("preview blank did not power the backlight down")
        return 1
    return 0


def cmd_ui() -> int:
    mark_mode()
    # Only a charger boot gets here. The kernel log is on fb0 but the
    # panel is dark (charger_dark): take the console, draw, then light.
    quiet_console()
    saved = read_brightness()
    if saved is None or saved <= 0:
        saved = 800
    try:
        fb, fd = open_fb()
    except (OSError, ValueError, SystemExit) as err:
        log(f"fb open failed: {err}; start desktop")
        start_gnome()
        return 1
    # Light the LEDs only once the battery is on fb0 (show_battery), or
    # the kernel log left on the console flashes first.
    enable_wakeup()
    inhibit = start_inhibit()
    pfd = open_pwrkey()
    log(f"ui fb={fb.w}x{fb.h} rotate={ROTATE} pwrkey_fd={pfd} bl={saved}")

    # Frames are built in `back` and copied to the scanout. Drawing into
    # the scanout itself cleared the whole panel to black and redrew it
    # every 0.35 s: the panel showed those half-drawn frames as flicker.
    back = Surface(bytearray(fb.stride * fb.h), fb.w, fb.h, fb.stride)
    _x, _y, _bw, _bh, _t, ix, iy, iw, ih = battery_box(back)
    bolt = set(bolt_columns(back))
    prev_shades: list[bytes] = []

    down_at: float | None = None
    visible_until = time.monotonic() + SCREEN_ON_SEC
    blanked = False
    offline_since: float | None = None
    shown: tuple[int, bool] | None = None
    sweep_t0 = time.monotonic()
    next_frame = 0.0
    next_poll = 0.0
    cap, charging = -1, False

    def read_state() -> tuple[int, bool]:
        c = battery_capacity()
        return c, battery_status().lower() == "charging" and c < 100

    def present_full() -> None:
        nonlocal shown, prev_shades
        phase = sweep_phase(time.monotonic() - sweep_t0)
        draw_battery(back, cap, charging, phase)
        back.copy_to(fb)
        shown = (cap, charging)
        prev_shades = fill_shades(cap, charging, phase, iw)

    def present_sweep(now: float) -> None:
        # Only the columns under the moving light change, so only those
        # scanout rows are written. Resting between sweeps costs nothing.
        nonlocal prev_shades
        shades = fill_shades(cap, charging, sweep_phase(now - sweep_t0), iw)
        changed = [i for i in range(iw) if shades[i] != prev_shades[i]]
        if not changed:
            return
        over_bolt = charging and not bolt.isdisjoint(changed)
        paint_columns(back, shades, changed, over_bolt)
        for i in sorted(set(changed) | (bolt if over_bolt else set())):
            back.copy_to(fb, ix + i, iy, 1, ih)
        prev_shades = shades

    def show_battery() -> None:
        nonlocal blanked, visible_until, sweep_t0, cap, charging
        cap, charging = read_state()
        sweep_t0 = time.monotonic()
        present_full()
        unblank(saved)
        blanked = False
        visible_until = time.monotonic() + SCREEN_ON_SEC

    def finish_gnome() -> int:
        log("long power, start desktop")
        unblank(saved)
        return 0

    def finish_poweroff() -> int:
        log("unplug, poweroff")
        blank_panel(fb)
        real_poweroff()
        return 0

    show_battery()
    log("battery on screen")
    threading.Thread(target=hold_consoles, daemon=True).start()
    try:
        while True:
            now = time.monotonic()
            if now >= next_poll:
                next_poll = now + 1.0
                online = vbus_present()
                if online is False:
                    if offline_since is None:
                        offline_since = now
                        log("charger offline, debounce")
                    elif now - offline_since >= UNPLUG_SEC:
                        return finish_poweroff()
                else:
                    offline_since = None
                if not blanked:
                    cap, charging = read_state()

            # Sleep until the next frame (or a key). Asleep: wait for keys.
            if blanked:
                timeout = max(0.0, next_poll - now)
            else:
                timeout = max(0.0, next_frame - now)
            if down_at is not None:
                timeout = min(timeout, max(0.0, down_at + LONG_PRESS - now))
            if pfd is not None:
                evs, _, _ = select.select([pfd], [], [], timeout)
            else:
                time.sleep(timeout)
                evs = []

            if evs:
                while True:
                    try:
                        data = os.read(pfd, EV_SIZE)
                    except OSError:
                        break
                    if len(data) < EV_SIZE:
                        break
                    _s, _us, etype, code, value = struct.unpack(EV_FMT, data)
                    if etype != EV_KEY or code != KEY_POWER:
                        continue
                    if value == 1:
                        down_at = time.monotonic()
                        if blanked:
                            show_battery()
                    elif value == 0 and down_at is not None:
                        held = time.monotonic() - down_at
                        down_at = None
                        if held >= LONG_PRESS:
                            return finish_gnome()
                        log("short power, show battery")
                        visible_until = time.monotonic() + SCREEN_ON_SEC

            now = time.monotonic()
            if down_at is not None and now - down_at >= LONG_PRESS:
                return finish_gnome()

            if blanked:
                continue
            if now >= visible_until:
                log("idle, blank panel")
                blank_panel(fb)
                blanked = True
                enable_wakeup()
                continue
            if now >= next_frame:
                next_frame = now + FRAME_SEC
                if shown != (cap, charging):
                    present_full()
                elif charging:
                    present_sweep(now)
    except KeyboardInterrupt:
        return 0
    finally:
        unblank(saved)
        try:
            fb.buf.close()  # type: ignore[union-attr]
        except Exception:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
        if pfd is not None:
            try:
                os.close(pfd)
            except OSError:
                pass
        if inhibit is not None and inhibit.poll() is None:
            inhibit.terminate()
        # Any exit other than unplug-poweroff returns to the desktop.
        # real_poweroff uses os._exit and does not reach here.
        start_gnome()


def cmd_status() -> int:
    h = BootHints(
        cmdline=read_text(CMDLINE_PATH),
        pending=PENDING.is_file(),
        charger_online=charger_online(),
        pon_reason=find_pon_reason(),
        pwrkey_held=pwrkey_held(),
    )
    print(f"pending={h.pending}")
    print(f"charger_online={h.charger_online}")
    print(f"capacity={battery_capacity()}")
    print(f"status={battery_status()}")
    print(f"pon_reason={h.pon_reason!r}")
    print(f"pwrkey_held={h.pwrkey_held}")
    print(f"bootreason={bootreason_token(h.cmdline)!r}")
    print(f"want_charger_mode={want_charger_mode(h)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="dagu off-mode charger")
    ap.add_argument(
        "mode",
        nargs="?",
        choices=("gate", "ui", "mark-pending", "status", "render", "preview"),
        default="status",
    )
    ap.add_argument("--capacity", type=int, default=67)
    ap.add_argument("--charging", action="store_true")
    ap.add_argument("--out", default="/tmp/dagu-offmode-render.png")
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--blank-after", type=float, default=4.0)
    args = ap.parse_args(argv)
    if args.mode == "gate":
        return cmd_gate()
    if args.mode == "ui":
        return cmd_ui()
    if args.mode == "mark-pending":
        return cmd_mark_pending()
    if args.mode == "render":
        return cmd_render(args.capacity, args.charging, Path(args.out))
    if args.mode == "preview":
        return cmd_preview(args.seconds, args.blank_after)
    return cmd_status()


if __name__ == "__main__":
    raise SystemExit(main())
