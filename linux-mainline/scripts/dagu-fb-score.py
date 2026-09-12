#!/usr/bin/env python3
"""Quantify dagu scanout snow.

Prefer the live KMS dumb mapping (card0 GETFB + MAP_DUMB). /dev/fb0 is
msmdrmfb and goes stale after GDM reallocates the primary BO — it will
read as all-black while the panel is fine.

Metrics (step px grid):
  unique / font_unique  distinct colors (font = top 96px)
  font_aa               mid-luma samples (real AA glyphs, not 1-bit tiles)
  font_tile32 / tile32  |corr| of row means vs lag=32 (macrotile-as-linear)
  faults                a6xx hangcheck lines in dmesg

Font-snow oracle (fb0 while it was still the live BO, destile leftover):
  font_unique=3  font_aa≈0  font_tile32=0.81  only 0/170/255 blocks

Pass: font_unique>=20 and font_aa>=40 and font_tile32<0.35 and faults==0.
"""
from __future__ import annotations

import collections
import ctypes
import fcntl
import math
import mmap
import os
import re
import subprocess
import sys


def _iorw(typ: str, nr: int, sz: int) -> int:
    return (3 << 30) | (sz << 16) | (ord(typ) << 8) | nr


class _drm_mode_fb_cmd(ctypes.Structure):
    _fields_ = [
        ("fb_id", ctypes.c_uint32),
        ("width", ctypes.c_uint32),
        ("height", ctypes.c_uint32),
        ("pitch", ctypes.c_uint32),
        ("bpp", ctypes.c_uint32),
        ("depth", ctypes.c_uint32),
        ("handle", ctypes.c_uint32),
    ]


class _drm_mode_map_dumb(ctypes.Structure):
    _fields_ = [
        ("handle", ctypes.c_uint32),
        ("pad", ctypes.c_uint32),
        ("offset", ctypes.c_uint64),
    ]


def _live_fb_id():
    try:
        for line in open("/sys/kernel/debug/dri/0/state"):
            s = line.strip()
            if s.startswith("fb=") and s != "fb=0":
                return int(s.split("=")[1])
    except OSError:
        return None
    return None


def map_scanout():
    """Return (mm, w, h, stride, src, closer)."""
    fb_id = _live_fb_id()
    if fb_id:
        fd = os.open("/dev/dri/card0", os.O_RDWR)
        fb = _drm_mode_fb_cmd()
        fb.fb_id = fb_id
        try:
            fcntl.ioctl(fd, _iorw("d", 0xAD, ctypes.sizeof(fb)), fb)
            req = _drm_mode_map_dumb()
            req.handle = fb.handle
            fcntl.ioctl(fd, _iorw("d", 0xB3, ctypes.sizeof(req)), req)
            mm = mmap.mmap(
                fd,
                fb.pitch * fb.height,
                mmap.MAP_SHARED,
                mmap.PROT_READ,
                offset=req.offset,
            )
            def closer():
                mm.close()
                os.close(fd)
            return mm, fb.width, fb.height, fb.pitch, f"kms:{fb_id}", closer
        except OSError:
            os.close(fd)

    w, h = (int(x) for x in open("/sys/class/graphics/fb0/virtual_size").read().split(","))
    stride = int(open("/sys/class/graphics/fb0/stride").read())
    fd = os.open("/dev/fb0", os.O_RDONLY)
    mm = mmap.mmap(fd, stride * h, mmap.MAP_SHARED, mmap.PROT_READ)
    def closer():
        mm.close()
        os.close(fd)
    return mm, w, h, stride, "fb0", closer


def _tile32(row_mean, step):
    lag = max(1, 32 // step)
    pairs_a = []
    pairs_b = []
    for i in range(len(row_mean) - lag):
        if row_mean[i] > 0 and row_mean[i + lag] > 0:
            pairs_a.append(row_mean[i])
            pairs_b.append(row_mean[i + lag])
    if len(pairs_a) <= 8:
        return 0.0
    ma = sum(pairs_a) / len(pairs_a)
    mb = sum(pairs_b) / len(pairs_b)
    cov = sum((x - ma) * (y - mb) for x, y in zip(pairs_a, pairs_b))
    va = math.sqrt(sum((x - ma) ** 2 for x in pairs_a))
    vb = math.sqrt(sum((y - mb) ** 2 for y in pairs_b))
    return abs(cov / (va * vb)) if va * vb else 0.0


def score_fb(step: int = 8):
    mm, w, h, stride, src, closer = map_scanout()
    c = collections.Counter()
    ui = collections.Counter()
    font = collections.Counter()
    black = white = n = ui_n = 0
    font_aa = font_n = 0
    row_mean = []
    font_row = []
    font_h = min(h, 96)
    for y in range(0, h, step):
        off = y * stride
        row = mm[off : off + w * 4]
        ui_acc = 0
        ui_cnt = 0
        for x in range(0, w, step):
            p = row[x * 4 : x * 4 + 4]
            c[p] += 1
            n += 1
            b, g, r = p[0], p[1], p[2]
            luma = b + g + r
            if luma < 24:
                black += 1
            if luma > 720:
                white += 1
            if luma >= 48:
                ui[p] += 1
                ui_n += 1
                ui_acc += luma
                ui_cnt += 1
            if y < font_h:
                font[p] += 1
                font_n += 1
                if 40 <= luma <= 700:
                    font_aa += 1
        row_mean.append(ui_acc / ui_cnt if ui_cnt else 0.0)
        if y < font_h:
            font_row.append(ui_acc / ui_cnt if ui_cnt else 0.0)
    closer()

    dmesg = subprocess.check_output(["dmesg"], text=True, errors="replace")
    faults = len(re.findall(r"gpu fault|hangcheck recover", dmesg))
    font_tile32 = round(_tile32(font_row, step), 4)
    tile32 = round(_tile32(row_mean, step), 4)
    return {
        "src": src,
        "w": w,
        "h": h,
        "samples": n,
        "unique": len(c),
        "ui_unique": len(ui),
        "ui_n": ui_n,
        "black_frac": round(black / max(n, 1), 4),
        "white_frac": round(white / max(n, 1), 4),
        "tile32": tile32,
        "font_unique": len(font),
        "font_aa": font_aa,
        "font_n": font_n,
        "font_tile32": font_tile32,
        "faults": faults,
        "pass": (
            len(font) >= 20
            and font_aa >= 40
            and font_tile32 < 0.35
            and faults == 0
        ),
    }


def main():
    s = score_fb()
    print(
        "src={src} unique={unique} ui_unique={ui_unique} black={black_frac} "
        "tile32={tile32} font_unique={font_unique} font_aa={font_aa} "
        "font_tile32={font_tile32} faults={faults} pass={pass}".format(**s)
    )
    return 0 if s["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
