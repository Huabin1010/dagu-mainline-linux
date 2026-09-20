#!/usr/bin/env python3
"""dagu off-mode charging (Android charger-mode equivalent).

Shutdown writes a pending flag. The next boot, if a charger is already
online and the boot was not a power-key / warm reboot, skip GDM and
draw a battery on fb0. Unplug powers off. Long KEY_POWER starts GNOME.

ABL may also pass androidboot.mode=charger or androidboot.bootreason=usb.
PM8150 PON_REASON1 bits win when the kernel exports them.

Do not start GNOME, SoftISP, or PipeWire on this path. Keep ssh / g_serial.
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
import sys
import time
from dataclasses import dataclass
from pathlib import Path

PENDING = Path("/var/lib/dagu/offmode-pending")
MODE_FLAG = Path("/run/dagu-charger-mode")
REAL_POWEROFF = Path("/run/dagu-real-poweroff")
SHUTDOWN_SCHED = Path("/run/systemd/shutdown/scheduled")
CMDLINE_PATH = Path("/proc/cmdline")
PSY_CHARGER = Path("/sys/class/power_supply/pm8150b-charger")
PSY_BATT = Path("/sys/class/power_supply/bms")
FB_PATH = "/dev/fb0"
FB_SYS = Path("/sys/class/graphics/fb0")
DPMS = Path("/sys/class/drm/card0-DSI-1/dpms")

# PM8150 / PM8998 PON_REASON1 @ pon+0x08
PON_HARD_RESET = 0x01
PON_SMPL = 0x02
PON_RTC = 0x04
PON_DC_CHG = 0x08
PON_USB_CHG = 0x10
PON_PON1 = 0x20
PON_CBLPWR = 0x40
PON_KPDPWR = 0x80
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

# HyperOS charger: battery stays on, then the panel sleeps. 8 s was too
# short (looked like a blink). Idle sleep is DPMS, not s2idle — s2idle
# drops the gadget and the charger looks unplugged.
SCREEN_ON_SEC = 45.0
LONG_PRESS = 2.5
UNPLUG_SEC = 5.0
GATE_WAIT_SEC = 15.0
INHIBIT_POLL = 0.25

KEY_POWER = 116
EV_KEY = 1
EV_FMT = "llHHI"
EV_SIZE = struct.calcsize(EV_FMT)

# Landscape 270° so the battery is upright with the panel's usual GNOME transform.
# fb is 1600x2560 portrait scanout.
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
        k, _, v = tok.partition("=")
        out[k] = v
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


def want_charger_mode(h: BootHints) -> bool:
    """True = skip GDM, run the charging UI.

    Power-button boot, or no VBUS, is always the desktop. ABL may still
    pass androidboot.mode=charger when the debug cable was in last boot.
    """
    if h.pwrkey_held:
        return False
    if h.charger_online is False:
        return False

    kv = cmdline_map(h.cmdline)
    mode = kv.get("androidboot.mode", "").lower()
    if mode in ("normal", "recovery", "bootloader"):
        return False

    reason = bootreason_token(h.cmdline)
    if reason in PWRKEY_REASONS or reason in WARM_REASONS:
        return False

    if mode == "charger" or reason in CHARGER_REASONS:
        return True

    if h.pon_reason is not None:
        if h.pon_reason & PON_KPDPWR:
            return False
        if h.pon_reason & PON_HARD_RESET:
            return False
        if h.pon_reason & PON_CHARGER:
            return True

    if h.pending and h.charger_online:
        return True
    return False


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


def battery_capacity() -> int:
    v = psy_int(PSY_BATT, "capacity")
    if v is None:
        return -1
    return max(0, min(100, v))


def battery_status() -> str:
    return read_text(PSY_BATT / "status") or "Unknown"


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
    # Do not glob /sys/devices/** — that walks the whole tree and hangs.
    candidates = (
        "/sys/kernel/debug/qcom-pon/reason",
        "/sys/power/pmic_pon_state",
        "/sys/bus/spmi/devices/*/pon_reason",
        "/sys/devices/platform/*.spmi/*pon*/pon_reason",
        "/sys/devices/platform/*.spmi/*pon*/reason",
    )
    for pat in candidates:
        if "*" in pat:
            paths = glob.glob(pat)
        else:
            paths = [pat]
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
        buf = bytearray(96)
        import fcntl

        # EVIOCGKEY(96)
        ioc = (2 << 30) | (96 << 16) | (ord("E") << 8) | 0x18
        fcntl.ioctl(fd, ioc, buf)
        bit = KEY_POWER
        return bool(buf[bit // 8] & (1 << (bit % 8)))
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
    MODE_FLAG.write_text("1\n", encoding="ascii")


def clear_mode() -> None:
    try:
        MODE_FLAG.unlink()
    except OSError:
        pass


def log(msg: str) -> None:
    print(f"dagu-offmode: {msg}", flush=True)


def live_hints() -> BootHints:
    return BootHints(
        cmdline=read_text(CMDLINE_PATH),
        pending=PENDING.is_file(),
        charger_online=wait_charger(),
        pon_reason=find_pon_reason(),
        pwrkey_held=pwrkey_held(),
    )


def _gate_should_wait(cmdline: str, pending: bool, pon: int | None) -> bool:
    if pending:
        return True
    kv = cmdline_map(cmdline)
    mode = kv.get("androidboot.mode", "").lower()
    if mode == "charger":
        return True
    reason = bootreason_token(cmdline)
    if reason in CHARGER_REASONS:
        return True
    if pon is not None and (pon & PON_CHARGER) and not (pon & PON_KPDPWR):
        return True
    return False


def cmd_gate() -> int:
    cmdline = read_text(CMDLINE_PATH)
    pending = PENDING.is_file()
    pon = find_pon_reason()
    if not _gate_should_wait(cmdline, pending, pon):
        clear_mode()
        if pending:
            clear_pending()
        log("gate skip (cold power-on)")
        return 0
    h = BootHints(
        cmdline=cmdline,
        pending=pending,
        charger_online=wait_charger(),
        pon_reason=pon,
        pwrkey_held=pwrkey_held(),
    )
    enter = want_charger_mode(h)
    log(
        f"gate pending={h.pending} charger={h.charger_online} "
        f"pon={h.pon_reason!r} pwrkey={h.pwrkey_held} "
        f"reason={bootreason_token(h.cmdline)!r} enter={enter}"
    )
    if enter:
        mark_mode()
        return 0
    clear_mode()
    clear_pending()
    return 0


def cmd_mark_pending() -> int:
    if REAL_POWEROFF.is_file():
        log("real poweroff, pending kept")
        mark_pending()
        return 0
    mark_pending()
    log("marked pending")
    return 0


def run(cmd: list[str]) -> int:
    try:
        return subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return 127


def enter_charger_target() -> None:
    # Do not isolate: that tears down ssh / g_serial and looks like unplug.
    mark_mode()
    mark_pending()
    run(["systemctl", "stop", "gdm.service"])
    run(["systemctl", "stop", "gdm3.service"])
    run(["systemctl", "start", "dagu-offmode-charger.service"])


def start_gnome() -> None:
    clear_mode()
    clear_pending()
    run(["systemctl", "reset-failed", "gdm.service"])
    run(["systemctl", "reset-failed", "gdm3.service"])
    run(["systemctl", "--no-block", "start", "graphical.target"])
    run(["systemctl", "--no-block", "start", "gdm.service"])
    run(["systemctl", "--no-block", "start", "dagu-offmode-daemon.service"])


def real_poweroff() -> None:
    REAL_POWEROFF.write_text("1\n", encoding="ascii")
    mark_pending()
    run(["systemctl", "poweroff", "--force", "--no-block"])
    time.sleep(8)
    os._exit(0)


def parse_shutdown_mode(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("MODE="):
            return line.split("=", 1)[1].strip().lower()
    return ""


def cmd_daemon() -> int:
    """Sit next to GNOME. Divert poweroff-with-cable into charger UI."""
    inhibit = subprocess.Popen(
        [
            "systemd-inhibit",
            "--what=shutdown",
            "--mode=delay",
            "--who=dagu-offmode",
            "--why=off-mode charger",
            "sleep",
            "infinity",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    log("daemon inhibit delay")
    try:
        while True:
            if MODE_FLAG.is_file():
                time.sleep(1)
                continue
            if SHUTDOWN_SCHED.is_file():
                mode = parse_shutdown_mode(read_text(SHUTDOWN_SCHED))
                online = charger_online()
                log(f"shutdown scheduled mode={mode} charger={online}")
                if mode in ("reboot", "halt", "kexec"):
                    if inhibit.poll() is None:
                        inhibit.terminate()
                    return 0
                if mode == "poweroff" or mode == "":
                    mark_pending()
                    if online:
                        enter_charger_target()
                        time.sleep(30)
                        return 0
                    if inhibit.poll() is None:
                        inhibit.terminate()
                    return 0
            time.sleep(INHIBIT_POLL)
    except KeyboardInterrupt:
        return 0
    finally:
        if inhibit.poll() is None:
            inhibit.terminate()


def unblank() -> None:
    try:
        (FB_SYS / "blank").write_text("0")
    except OSError:
        pass
    try:
        DPMS.write_text("On")
    except OSError:
        pass
    for p in Path("/sys/class/vtconsole").glob("vtcon*/bind"):
        try:
            p.write_text("0")
        except OSError:
            pass


def blank_screen() -> None:
    try:
        DPMS.write_text("Off")
    except OSError:
        try:
            (FB_SYS / "blank").write_text("1")
        except OSError:
            pass


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
            wake.write_text("enabled")
        except OSError:
            pass
        break
    wake = Path("/sys/class/power_supply/pm8150b-charger/device/power/wakeup")
    try:
        wake.write_text("enabled")
    except OSError:
        pass


def suspend_s2idle() -> None:
    try:
        Path("/sys/power/state").write_text("mem")
    except OSError as err:
        log(f"s2idle failed: {err}")


def wait_fb(timeout: float = 20.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if Path(FB_PATH).exists() and (FB_SYS / "virtual_size").exists():
            return True
        time.sleep(0.2)
    return False


class Fb:
    def __init__(self) -> None:
        sysfb = FB_SYS
        wh = (sysfb / "virtual_size").read_text().strip().split(",")
        self.w, self.h = int(wh[0]), int(wh[1])
        self.stride = int((sysfb / "stride").read_text().strip())
        bpp = int((sysfb / "bits_per_pixel").read_text().strip())
        if bpp != 32:
            raise SystemExit(f"fb0 is {bpp}bpp, need 32")
        self.fd = os.open(FB_PATH, os.O_RDWR)
        self.mm = mmap.mmap(self.fd, self.stride * self.h, access=mmap.ACCESS_WRITE)
        if ROTATE in (90, 270):
            self.lw, self.lh = self.h, self.w
        else:
            self.lw, self.lh = self.w, self.h

    def close(self) -> None:
        self.mm.close()
        os.close(self.fd)

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
        self.mm[0 : len(blob)] = blob

    def hline_fb(self, y: int, x0: int, x1: int, bgra: bytes) -> None:
        if y < 0 or y >= self.h:
            return
        x0 = max(0, min(self.w - 1, x0))
        x1 = max(0, min(self.w - 1, x1))
        if x1 < x0:
            x0, x1 = x1, x0
        off = y * self.stride + x0 * 4
        n = x1 - x0 + 1
        self.mm[off : off + n * 4] = bgra * n

    def px(self, lx: int, ly: int, bgra: bytes) -> None:
        x, y = self.map_xy(lx, ly)
        if x < 0 or y < 0 or x >= self.w or y >= self.h:
            return
        off = y * self.stride + x * 4
        self.mm[off : off + 4] = bgra

    def rect(self, lx: int, ly: int, w: int, h: int, bgra: bytes) -> None:
        if w <= 0 or h <= 0:
            return
        # Fast path: after 270/90 a landscape axis-aligned rect is a
        # portrait axis-aligned rect — fill with fb hlines.
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


def draw_bolt(fb: Fb, cx: int, cy: int, color: bytes, s: int) -> None:
    # 4 stacked parallelograms as a lightning bolt.
    pts = (
        (0, -6),
        (2, -6),
        (-1, 0),
        (3, 0),
        (-2, 6),
        (0, 2),
        (-3, 2),
    )
    for px, py in pts:
        fb.rect(cx + px * s - s, cy + py * s - s, s * 2, s * 2, color)
    fb.rect(cx - s, cy - 5 * s, 2 * s, 4 * s, color)
    fb.rect(cx - 2 * s, cy - s, 5 * s, 2 * s, color)
    fb.rect(cx + s, cy, 2 * s, 5 * s, color)


def draw_battery(fb: Fb, cap: int, charging: bool, pulse: float = 1.0) -> None:
    fb.fill(BLACK)
    bw, bh = 520, 260
    x = (fb.lw - bw) // 2
    y = (fb.lh - bh) // 2 - 40
    t = 14
    nub_w, nub_h = 36, 90
    fb.rect(x, y, bw, t, WHITE)
    fb.rect(x, y + bh - t, bw, t, WHITE)
    fb.rect(x, y, t, bh, WHITE)
    fb.rect(x + bw - t, y, t, bh, WHITE)
    fb.rect(x + bw, y + (bh - nub_h) // 2, nub_w, nub_h, WHITE)

    inner_w = bw - 4 * t
    inner_h = bh - 4 * t
    ix, iy = x + 2 * t, y + 2 * t
    frac = 0.0 if cap < 0 else cap / 100.0
    if charging and cap >= 0 and cap < 100:
        frac = frac * (0.25 + 0.75 * max(0.0, min(1.0, pulse)))
    fill_w = int(inner_w * frac)
    if cap < 0:
        color = GRAY
    elif cap < 15:
        color = RED
    elif cap < 30:
        color = YELLOW
    else:
        color = GREEN
    if fill_w > 0:
        fb.rect(ix, iy, fill_w, inner_h, color)
    if charging:
        draw_bolt(fb, x + bw // 2, y + bh // 2, WHITE, 8)

    label = "--%" if cap < 0 else f"{cap}%"
    scale = 14
    tw = fb.text_width(label, scale)
    fb.text((fb.lw - tw) // 2, y + bh + 48, label, WHITE, scale)


def open_pwrkey() -> int | None:
    path = find_pwrkey()
    if not path:
        return None
    try:
        return os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None


def cmd_ui() -> int:
    mark_mode()
    run(["systemctl", "stop", "gdm.service"])
    run(["systemctl", "stop", "gdm3.service"])
    time.sleep(0.5)
    if not wait_fb():
        log("no fb0, start GNOME")
        start_gnome()
        return 1
    unblank()
    enable_wakeup()
    try:
        fb = Fb()
    except (OSError, ValueError, SystemExit) as err:
        log(f"fb open failed: {err}; start GNOME")
        start_gnome()
        return 1
    pfd = open_pwrkey()
    log(f"ui fb={fb.w}x{fb.h} rotate={ROTATE} pwrkey_fd={pfd}")

    down_at: float | None = None
    visible_until = time.monotonic() + SCREEN_ON_SEC
    last_draw = 0.0
    blanked = False
    offline_since: float | None = None
    t0 = time.monotonic()

    def pulse() -> float:
        return 0.5 + 0.5 * math.sin((time.monotonic() - t0) * 2.2)

    def show_battery() -> None:
        nonlocal blanked, visible_until
        cap = battery_capacity()
        st = battery_status().lower()
        chg = st in ("charging", "full") or bool(charger_online())
        draw_battery(fb, cap, chg and st != "full", pulse())
        unblank()
        blanked = False
        visible_until = time.monotonic() + SCREEN_ON_SEC

    def finish_gnome() -> int:
        log("long power, start GNOME")
        try:
            fb.close()
        except Exception:
            pass
        if pfd is not None:
            try:
                os.close(pfd)
            except OSError:
                pass
        start_gnome()
        return 0

    show_battery()

    try:
        while True:
            now = time.monotonic()
            online = charger_online()
            if online is False:
                if offline_since is None:
                    offline_since = now
                    log("charger offline, debounce")
                elif now - offline_since >= UNPLUG_SEC:
                    log("unplug, poweroff")
                    try:
                        fb.close()
                    except Exception:
                        pass
                    if pfd is not None:
                        os.close(pfd)
                    real_poweroff()
                    return 0
            else:
                offline_since = None

            if pfd is None:
                time.sleep(0.2)
                evs: list = []
            else:
                evs, _, _ = select.select([pfd], [], [], 0.2)

            if pfd is not None and evs:
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
                        show_battery()

            if down_at is not None and time.monotonic() - down_at >= LONG_PRESS:
                return finish_gnome()
            if down_at is None and pwrkey_held():
                down_at = time.monotonic()

            now = time.monotonic()
            if now < visible_until:
                if blanked:
                    unblank()
                    blanked = False
                if now - last_draw >= 0.35:
                    cap = battery_capacity()
                    st = battery_status().lower()
                    chg = st in ("charging", "full") or bool(charger_online())
                    draw_battery(fb, cap, chg and st != "full", pulse())
                    last_draw = now
                continue

            if not blanked:
                log("idle, blank panel")
                blank_screen()
                blanked = True
            enable_wakeup()
    except KeyboardInterrupt:
        return 0
    finally:
        try:
            fb.close()
        except Exception:
            pass
        if pfd is not None:
            try:
                os.close(pfd)
            except OSError:
                pass


def cmd_status() -> int:
    h = live_hints()
    print(f"pending={h.pending}")
    print(f"charger_online={h.charger_online}")
    print(f"capacity={battery_capacity()}")
    print(f"status={battery_status()}")
    print(f"pon_reason={h.pon_reason!r}")
    print(f"pwrkey_held={h.pwrkey_held}")
    print(f"bootreason={bootreason_token(h.cmdline)!r}")
    print(f"want_charger_mode={want_charger_mode(h)}")
    print(f"cmdline={h.cmdline}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="dagu off-mode charger")
    ap.add_argument(
        "mode",
        nargs="?",
        choices=("gate", "ui", "daemon", "mark-pending", "status"),
        default="status",
    )
    args = ap.parse_args(argv)
    if args.mode == "gate":
        return cmd_gate()
    if args.mode == "ui":
        return cmd_ui()
    if args.mode == "daemon":
        return cmd_daemon()
    if args.mode == "mark-pending":
        return cmd_mark_pending()
    return cmd_status()


if __name__ == "__main__":
    raise SystemExit(main())
