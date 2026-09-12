#!/usr/bin/env python3
"""Dump a landscape crop of the live KMS fb (1600x2560 + 270°).

Only valid when the primary fb is LINEAR (modifier=0). After
MUTTER_DEBUG_USE_KMS_MODIFIERS=1 the scanout is QCOM_COMPRESSED;
mmap-as-linear is compression noise, not a screenshot.
"""
from __future__ import annotations

import ctypes
import fcntl
import mmap
import os
import struct
import sys
import zlib


def iorw(typ, nr, sz):
    return (3 << 30) | (sz << 16) | (ord(typ) << 8) | nr


class fbcmd(ctypes.Structure):
    _fields_ = [
        ("fb_id", ctypes.c_uint32),
        ("width", ctypes.c_uint32),
        ("height", ctypes.c_uint32),
        ("pitch", ctypes.c_uint32),
        ("bpp", ctypes.c_uint32),
        ("depth", ctypes.c_uint32),
        ("handle", ctypes.c_uint32),
    ]


class mapd(ctypes.Structure):
    _fields_ = [
        ("handle", ctypes.c_uint32),
        ("pad", ctypes.c_uint32),
        ("offset", ctypes.c_uint64),
    ]


def map_kms():
    fb_id = None
    for line in open("/sys/kernel/debug/dri/0/state"):
        s = line.strip()
        if s.startswith("fb=") and s != "fb=0":
            fb_id = int(s.split("=")[1])
            break
    if not fb_id:
        raise SystemExit("no live fb")
    fd = os.open("/dev/dri/card0", os.O_RDWR)
    fb = fbcmd()
    fb.fb_id = fb_id
    fcntl.ioctl(fd, iorw("d", 0xAD, ctypes.sizeof(fb)), fb)
    m = mapd()
    m.handle = fb.handle
    fcntl.ioctl(fd, iorw("d", 0xB3, ctypes.sizeof(m)), m)
    mm = mmap.mmap(
        fd, fb.pitch * fb.height, mmap.MAP_SHARED, mmap.PROT_READ, offset=m.offset
    )
    return fd, mm, fb.width, fb.height, fb.pitch, fb_id


def write_png(path, w, h, raw):
    def chunk(tag, payload):
        crc = zlib.crc32(tag + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", crc)

    rows = b"".join(b"\x00" + raw[y * w * 3 : (y + 1) * w * 3] for y in range(h))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(rows, 6))
        + chunk(b"IEND", b"")
    )


def main():
    out = sys.argv[1]
    x0 = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    y0 = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    cw = int(sys.argv[4]) if len(sys.argv) > 4 else 1400
    ch = int(sys.argv[5]) if len(sys.argv) > 5 else 220
    fd, mm, w, h, st, fb_id = map_kms()
    cw = min(cw, h - x0)
    ch = min(ch, w - y0)
    raw = bytearray()
    for ly in range(y0, y0 + ch):
        for lx in range(x0, x0 + cw):
            off = lx * st + (w - 1 - ly) * 4
            raw.extend((mm[off + 2], mm[off + 1], mm[off]))
    write_png(out, cw, ch, bytes(raw))
    print(f"wrote {out} {cw}x{ch} fb={fb_id}")
    mm.close()
    os.close(fd)


if __name__ == "__main__":
    main()
