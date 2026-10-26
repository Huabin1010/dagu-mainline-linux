#!/usr/bin/env python3
"""Grab the QEMU guest screen via the HMP monitor socket and write a PNG.

  qemu-shot.py /root/woa/mon.sock /root/woa/shot.png [scale]

Stdlib only (the tablet has no ImageMagick): PPM from `screendump`, nearest-
neighbour downscale, zlib-compressed PNG.
"""
import os
import socket
import struct
import sys
import time
import zlib

sock_path, out = sys.argv[1], sys.argv[2]
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 2
ppm = out + ".ppm"
if os.path.exists(ppm):
    os.unlink(ppm)
s = socket.socket(socket.AF_UNIX)
s.connect(sock_path)
s.settimeout(5)
time.sleep(0.3)
s.recv(65536)
s.sendall(f"screendump {ppm}\n".encode())
for _ in range(50):
    time.sleep(0.2)
    if os.path.exists(ppm) and os.path.getsize(ppm) > 100:
        time.sleep(0.5)
        break
s.close()

d = open(ppm, "rb").read()
parts = d.split(b"\n", 3)
w, h = map(int, parts[1].split())
px = parts[3]
rows = []
for y in range(0, h, scale):
    row = bytearray(b"\x00")
    base = y * w * 3
    for x in range(0, w, scale):
        i = base + x * 3
        row += px[i:i + 3]
    rows.append(bytes(row))
raw = b"".join(rows)
ow, oh = (w + scale - 1) // scale, (h + scale - 1) // scale


def chunk(t, b):
    return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)


png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ow, oh, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
open(out, "wb").write(png)
os.unlink(ppm)
print(out, ow, oh, len(png))
