#!/usr/bin/env python3
"""dagu 触控可视化测试：在 fb0 上画点，同时把事件打到 stdout。

对照 ginkgo 的 ginkgo-touch-test.py。不依赖 python-evdev。
当前主线 GENI SPI / Himax 未 probe 时，屏幕会显示 NO TOUCH DEVICE，
电源键 / resin（音量下）仍可验证 input 子系统。

用法（平板上）：
  python3 /usr/local/sbin/dagu-touch-test.py --probe
  python3 /usr/local/sbin/dagu-touch-test.py
"""
from __future__ import annotations

import argparse
import array
import fcntl
import mmap
import os
import select
import struct
import sys
import time
from pathlib import Path

FB = "/dev/fb0"
# L81A 默认；probe_fb() 会按 /sys/class/graphics/fb0 覆盖。
W, H, STRIDE, BPP = 1600, 2560, 6400, 32
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT = 0x2F
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39
BTN_TOUCH = 0x14A
KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_POWER = 115, 114, 116
IOC_READ = 2
E_TYPE = ord("E")

FINGER_BGRA = [
    bytes((0xFF, 0xCC, 0x00, 0x00)),  # cyan
    bytes((0x00, 0xE0, 0xFF, 0x00)),  # yellow
    bytes((0xFF, 0x00, 0xFF, 0x00)),  # magenta
    bytes((0x40, 0xE0, 0x40, 0x00)),  # green
    bytes((0x40, 0x80, 0xFF, 0x00)),  # orange
]


def probe_fb():
    global W, H, STRIDE, BPP
    sysfb = Path("/sys/class/graphics/fb0")
    try:
        wh = (sysfb / "virtual_size").read_text().strip().split(",")
        W, H = int(wh[0]), int(wh[1])
        STRIDE = int((sysfb / "stride").read_text().strip())
        BPP = int((sysfb / "bits_per_pixel").read_text().strip())
    except (OSError, ValueError, IndexError):
        pass
    if BPP != 32:
        raise SystemExit(f"fb0 不是 32bpp（{BPP}），这套画点程序只处理 BGRA8888")


def _ioc(dir_, typ, nr, size):
    return (dir_ << 30) | (size << 16) | (typ << 8) | nr


def eviocgname(fd):
    buf = array.array("B", b"\x00" * 256)
    fcntl.ioctl(fd, _ioc(IOC_READ, E_TYPE, 0x06, 256), buf)
    return buf.tobytes().split(b"\x00", 1)[0].decode("utf-8", "replace") or "?"


def eviocgbit(fd, ev, nbytes=32):
    buf = array.array("B", b"\x00" * nbytes)
    fcntl.ioctl(fd, _ioc(IOC_READ, E_TYPE, 0x20 + ev, nbytes), buf)
    return int.from_bytes(buf.tobytes(), "little")


def eviocgabs(fd, axis):
    buf = array.array("i", [0] * 6)
    fcntl.ioctl(fd, _ioc(IOC_READ, E_TYPE, 0x40 + axis, 24), buf)
    value, amin, amax, fuzz, flat, res = buf
    return amin, amax


def bit_set(mask, bit):
    return bool(mask & (1 << bit))


def classify(fd):
    name = eviocgname(fd)
    types = eviocgbit(fd, 0, 8)
    keys = eviocgbit(fd, EV_KEY, 64) if bit_set(types, EV_KEY) else 0
    absbits = eviocgbit(fd, EV_ABS, 16) if bit_set(types, EV_ABS) else 0
    has_mt = bit_set(absbits, ABS_MT_POSITION_X) and bit_set(absbits, ABS_MT_POSITION_Y)
    has_xy = bit_set(absbits, ABS_X) and bit_set(absbits, ABS_Y)
    has_btn = bit_set(keys, BTN_TOUCH)
    lname = name.lower()
    is_touch = (
        has_mt
        or (has_xy and has_btn)
        or "touch" in lname
        or "himax" in lname
        or "hx83121" in lname
        or "hxcommon" in lname
    )
    rng = None
    if is_touch:
        ax = ABS_MT_POSITION_X if has_mt else ABS_X
        ay = ABS_MT_POSITION_Y if has_mt else ABS_Y
        try:
            xmin, xmax = eviocgabs(fd, ax)
            ymin, ymax = eviocgabs(fd, ay)
            rng = (xmin, xmax, ymin, ymax)
        except OSError:
            rng = (0, W - 1, 0, H - 1)
    return {
        "name": name,
        "touch": is_touch,
        "mt": has_mt,
        "range": rng,
        "volume": bit_set(keys, KEY_VOLUMEUP) or bit_set(keys, KEY_VOLUMEDOWN),
        "power": bit_set(keys, KEY_POWER),
    }


def list_devices():
    devs = []
    for p in sorted(Path("/dev/input").glob("event*")):
        fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
        info = classify(fd)
        info["path"] = str(p)
        info["fd"] = fd
        devs.append(info)
    return devs


# 5x7, bit4 = leftmost pixel
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
    "A": (0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    "B": (0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E),
    "C": (0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E),
    "D": (0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C),
    "E": (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F),
    "F": (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10),
    "G": (0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E),
    "H": (0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    "I": (0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E),
    "J": (0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0E),
    "K": (0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11),
    "L": (0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F),
    "M": (0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11),
    "N": (0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11),
    "O": (0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    "P": (0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10),
    "Q": (0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D),
    "R": (0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11),
    "S": (0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E),
    "T": (0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04),
    "U": (0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    "V": (0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04),
    "W": (0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11),
    "X": (0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11),
    "Y": (0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04),
    "Z": (0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F),
    "-": (0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00),
    ".": (0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x06),
    ":": (0x00, 0x06, 0x06, 0x00, 0x06, 0x06, 0x00),
    "/": (0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10),
    "+": (0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00),
    "?": (0x0E, 0x11, 0x01, 0x06, 0x04, 0x00, 0x04),
    "=": (0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00),
}


class Fb:
    def __init__(self):
        self.fd = os.open(FB, os.O_RDWR)
        self.mm = mmap.mmap(self.fd, STRIDE * H, access=mmap.ACCESS_WRITE)
        self.px = STRIDE * H

    def close(self):
        self.mm.close()
        os.close(self.fd)

    def fill(self, bgra: bytes):
        row = bgra * W + b"\x00" * (STRIDE - W * 4)
        blob = row * H
        self.mm[0 : len(blob)] = blob

    def hline(self, y, x0, x1, bgra):
        if y < 0 or y >= H:
            return
        x0 = max(0, min(W - 1, x0))
        x1 = max(0, min(W - 1, x1))
        if x1 < x0:
            x0, x1 = x1, x0
        off = y * STRIDE + x0 * 4
        self.mm[off : off + (x1 - x0 + 1) * 4] = bgra * (x1 - x0 + 1)

    def vline(self, x, y0, y1, bgra):
        if x < 0 or x >= W:
            return
        y0 = max(0, min(H - 1, y0))
        y1 = max(0, min(H - 1, y1))
        if y1 < y0:
            y0, y1 = y1, y0
        for y in range(y0, y1 + 1):
            off = y * STRIDE + x * 4
            self.mm[off : off + 4] = bgra

    def rect(self, x, y, w, h, bgra):
        for yy in range(y, min(H, y + h)):
            self.hline(yy, x, x + w - 1, bgra)

    def circle(self, cx, cy, r, bgra):
        r2 = r * r
        for dy in range(-r, r + 1):
            yy = cy + dy
            if yy < 0 or yy >= H:
                continue
            span = int((r2 - dy * dy) ** 0.5)
            self.hline(yy, cx - span, cx + span, bgra)

    def text(self, x, y, s, bgra, scale=4):
        s = s.upper()
        cx = x
        for ch in s:
            glyph = _FONT.get(ch, _FONT["?"])
            for row, bits in enumerate(glyph):
                for col in range(5):
                    if bits & (0x10 >> col):
                        self.rect(cx + col * scale, y + row * scale, scale, scale, bgra)
            cx += 6 * scale

    def glyph_width(self, s, scale=4):
        return len(s) * 6 * scale


def unblank():
    try:
        Path("/sys/class/graphics/fb0/blank").write_text("0")
    except OSError:
        pass
    for p in Path("/sys/class/vtconsole").glob("vtcon*/bind"):
        try:
            p.write_text("0")
        except OSError:
            pass


def stop_gdm():
    os.system("systemctl stop gdm >/dev/null 2>&1 || true")
    os.system("systemctl stop gdm3 >/dev/null 2>&1 || true")
    time.sleep(0.4)
    unblank()


def start_gdm():
    os.system("systemctl start gdm >/dev/null 2>&1 || systemctl start gdm3 >/dev/null 2>&1 || true")


def scale(v, vmin, vmax, out_max):
    if vmax <= vmin:
        return 0
    t = (v - vmin) / (vmax - vmin)
    t = max(0.0, min(1.0, t))
    return int(t * out_max)


def draw_chrome(fb: Fb, touches, n_events, last_key):
    grid = bytes((0x48, 0x38, 0x30, 0x00))
    white = bytes((0xFF, 0xFF, 0xFF, 0x00))
    yellow = bytes((0x00, 0xE0, 0xFF, 0x00))
    red = bytes((0x30, 0x30, 0xC0, 0x00))
    green = bytes((0x40, 0x90, 0x20, 0x00))
    mark = bytes((0xE0, 0xE0, 0xE0, 0x00))
    banner_h = 180

    fb.fill(bytes((0x22, 0x18, 0x12, 0x00)))
    for x in range(0, W, 160):
        fb.vline(x, banner_h, H - 1, grid)
    for y in range(banner_h, H, 160):
        fb.hline(y, 0, W - 1, grid)
    for x, y in ((48, banner_h + 48), (W - 48, banner_h + 48), (48, H - 48), (W - 48, H - 48)):
        fb.rect(x - 22, y - 2, 44, 4, mark)
        fb.rect(x - 2, y - 22, 4, 44, mark)

    ok = any(d["touch"] for d in touches)
    fb.rect(0, 0, W, banner_h, green if ok else red)
    if ok:
        names = ",".join(d["name"][:18] for d in touches if d["touch"])
        fb.text(24, 20, "TOUCH OK", white, 6)
        fb.text(24, 80, names[:28], yellow, 3)
        fb.text(24, 128, "TAP SCREEN  VOL- QUIT", white, 3)
    else:
        fb.text(24, 16, "NO TOUCH DEVICE", white, 6)
        fb.text(24, 80, "HIMAX SPI NOT PROBED", yellow, 3)
        fb.text(24, 128, "VOL- QUIT  ENTER QUIT", white, 3)
    fb.text(W - fb.glyph_width(f"N={n_events}", 3) - 24, 20, f"N={n_events}", white, 3)
    if last_key:
        fb.text(W - fb.glyph_width(last_key, 3) - 24, 72, last_key, yellow, 3)


def visual_loop(devs, take_fb: bool):
    restored = False
    if take_fb:
        stop_gdm()
    else:
        unblank()
    fb = Fb()
    n_events = 0
    last_key = ""
    slots = {}
    cur_slot = 0
    abs_state = {"x": None, "y": None}
    draw_chrome(fb, devs, n_events, last_key)
    print("屏幕已画测试图。用手指点屏幕；resin/音量- 退出，串口回车也退出。", flush=True)
    print("若横幅是 NO TOUCH DEVICE：Himax 还没挂上 /dev/input，点屏幕不会出点。", flush=True)

    fds = {d["fd"]: d for d in devs}
    watch = list(fds)
    if sys.stdin.isatty() or not sys.stdin.closed:
        watch.append(0)
    try:
        while True:
            ready, _, _ = select.select(watch, [], [], 0.25)
            if 0 in ready:
                line = sys.stdin.readline()
                if not line:
                    watch = [fd for fd in watch if fd != 0]
                    continue
                return
            for fd in ready:
                if fd == 0:
                    continue
                info = fds[fd]
                raw = os.read(fd, 24 * 64)
                for off in range(0, len(raw) - 23, 24):
                    _sec, _usec, typ, code, value = struct.unpack_from("QQHHi", raw, off)
                    n_events += 1
                    if typ == EV_KEY and code in (KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_POWER):
                        if code == KEY_VOLUMEUP:
                            last_key = "VOL+"
                        elif code == KEY_VOLUMEDOWN:
                            last_key = "VOL-"
                        else:
                            last_key = "PWR"
                        print(f"key {last_key} value={value}", flush=True)
                        if value == 1 and code == KEY_VOLUMEDOWN:
                            return
                        if value == 1 and code == KEY_VOLUMEUP:
                            slots.clear()
                            draw_chrome(fb, devs, n_events, last_key)
                        continue
                    if not info["touch"]:
                        continue
                    rng = info["range"] or (0, W - 1, 0, H - 1)
                    xmin, xmax, ymin, ymax = rng
                    if typ == EV_ABS:
                        if code == ABS_MT_SLOT:
                            cur_slot = value
                        elif code == ABS_MT_TRACKING_ID:
                            if value < 0:
                                slots.pop(cur_slot, None)
                            else:
                                slots.setdefault(cur_slot, {"x": 0, "y": 0, "id": value})
                                slots[cur_slot]["id"] = value
                        elif code in (ABS_MT_POSITION_X, ABS_X):
                            x = scale(value, xmin, xmax, W - 1)
                            if code == ABS_X:
                                abs_state["x"] = x
                            slots.setdefault(cur_slot, {"x": 0, "y": 0, "id": 0})
                            slots[cur_slot]["x"] = x
                        elif code in (ABS_MT_POSITION_Y, ABS_Y):
                            y = scale(value, ymin, ymax, H - 1)
                            if code == ABS_Y:
                                abs_state["y"] = y
                            slots.setdefault(cur_slot, {"x": 0, "y": 0, "id": 0})
                            slots[cur_slot]["y"] = y
                    elif typ == EV_SYN and code == SYN_REPORT:
                        if not slots and abs_state["x"] is not None:
                            slots[0] = {
                                "x": abs_state["x"],
                                "y": abs_state["y"],
                                "id": 0,
                            }
                        for sid, st in slots.items():
                            col = FINGER_BGRA[sid % len(FINGER_BGRA)]
                            fb.circle(st["x"], st["y"], 36, col)
                            print(
                                f"touch slot={sid} x={st['x']} y={st['y']}",
                                flush=True,
                            )
    finally:
        for d in devs:
            os.close(d["fd"])
        fb.close()
        if take_fb and not restored:
            start_gdm()
            restored = True


def probe():
    if not Path("/dev/input").exists():
        print("没有 /dev/input")
        return 2
    if not Path("/dev/fb0").exists():
        print("没有 /dev/fb0（DRM fbdev 没起来）")
    else:
        probe_fb()
        name = ""
        try:
            name = Path("/sys/class/graphics/fb0/name").read_text().strip()
        except OSError:
            pass
        print(f"fb0 {W}x{H} stride={STRIDE} bpp={BPP} name={name or '?'}")
    spi = sorted(Path("/sys/bus/spi/devices").glob("*")) if Path("/sys/bus/spi/devices").exists() else []
    print(f"spi devices: {', '.join(p.name for p in spi) if spi else '(none)'}")
    himax = Path("/sys/bus/spi/drivers/himax-dagu")
    print(f"himax-dagu driver: {'yes' if himax.exists() else 'no'}")
    devs = list_devices()
    if not devs:
        print("没有任何 input event 设备")
        return 2
    print(f"{'设备':<22} {'名称':<32} 触控  范围")
    n_touch = 0
    for d in devs:
        rng = ""
        if d["range"]:
            rng = f"{d['range'][0]}..{d['range'][1]} x {d['range'][2]}..{d['range'][3]}"
        print(f"{d['path']:<22} {d['name']:<32} {'YES' if d['touch'] else 'no ':4}  {rng}")
        if d["touch"]:
            n_touch += 1
        os.close(d["fd"])
    print()
    if n_touch:
        print("结论：已经有触控 event 设备，可以跑可视化测试。")
        return 0
    print("结论：还没有触控设备。")
    print("  当前只有 pm8941 电源键 / resin。")
    print("  CAF 是 Himax HX83121，挂 QUP0 SE4 = 主线 &spi4 @ 0x990000，CPHA，4 MHz。")
    print("  IRQ GPIO39，RST GPIO100（面板 tp-reset 独占，Himax 不要再绑 reset-gpios）。")
    print("  1600x2560；读事件 cmd 0x30，头 [0xF3, cmd, 0x00]。")
    print("  当前内核 CONFIG_SPI_QCOM_GENI / TOUCHSCREEN_HIMAX_DAGU 未打开，")
    print("  DTS 里 &spi4 / &qupv3_id_0 仍是 disabled。")
    return 2


def main():
    ap = argparse.ArgumentParser(description="dagu 触控测试")
    ap.add_argument("--probe", action="store_true", help="只列出设备，不画屏")
    ap.add_argument(
        "--keep-gdm",
        action="store_true",
        help="画屏时不停 GDM（Wayland 占用 DRM 时 fb0 可能看不见）",
    )
    args = ap.parse_args()
    if args.probe:
        sys.exit(probe())
    if os.geteuid() != 0:
        print("需要 root（读写 /dev/fb0 和 /dev/input）", file=sys.stderr)
        sys.exit(1)
    probe_fb()
    rc = probe()
    print()
    devs = list_devices()
    try:
        visual_loop(devs, take_fb=not args.keep_gdm)
    except KeyboardInterrupt:
        print("\n退出")
    return 0 if rc == 0 else rc


if __name__ == "__main__":
    sys.exit(main() or 0)
