#!/usr/bin/env python3
"""Apply Mutter scales, dump rotated KMS crops, score glyph bands.

Must apply scales as the session user (dagu). Root mmap of card0 is OK.
Panel is 1600x2560 FB + transform 270° → landscape 2560x1600.
"""
from __future__ import annotations

import collections
import ctypes
import fcntl
import json
import math
import mmap
import os
import struct
import subprocess
import sys
import time
import zlib

# Exact doubles Mutter accepts on this panel (InvalidArgs otherwise).
SCALES = [
    1.0,
    1.25,
    1.3333333730697632,
    1.6666666269302368,
    2.0,
    2.5,
    2.6666667461395264,
]
MODE = "1600x2560@120.000"
OUT = "/tmp/dagu-scale-sweep"
TRANSFORM = 3  # 270°
SESSION_USER = os.environ.get("DAGU_SESSION_USER", "dagu")


def iorw(typ, nr, sz):
    return (3 << 30) | (sz << 16) | (ord(typ) << 8) | nr


class drm_mode_fb_cmd(ctypes.Structure):
    _fields_ = [
        ("fb_id", ctypes.c_uint32),
        ("width", ctypes.c_uint32),
        ("height", ctypes.c_uint32),
        ("pitch", ctypes.c_uint32),
        ("bpp", ctypes.c_uint32),
        ("depth", ctypes.c_uint32),
        ("handle", ctypes.c_uint32),
    ]


class drm_mode_map_dumb(ctypes.Structure):
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
    fd = os.open("/dev/dri/card0", os.O_RDWR)
    fb = drm_mode_fb_cmd()
    fb.fb_id = fb_id
    fcntl.ioctl(fd, iorw("d", 0xAD, ctypes.sizeof(fb)), fb)
    req = drm_mode_map_dumb()
    req.handle = fb.handle
    fcntl.ioctl(fd, iorw("d", 0xB3, ctypes.sizeof(req)), req)
    mm = mmap.mmap(
        fd, fb.pitch * fb.height, mmap.MAP_SHARED, mmap.PROT_READ, offset=req.offset
    )
    return fd, mm, fb.width, fb.height, fb.pitch, fb_id


def land_bgr(mm, w, st, lx, ly):
    """Landscape pixel after 270° CW. display(lx,ly) ← fb(w-1-ly, lx)."""
    fx = w - 1 - ly
    fy = lx
    off = fy * st + fx * 4
    return mm[off], mm[off + 1], mm[off + 2]


def write_land_ppm(path, mm, w, h, st, x0, y0, cw, ch):
    """Crop in landscape pixels (2560 x 1600)."""
    lw, lh = h, w
    x0 = max(0, min(x0, lw - 1))
    y0 = max(0, min(y0, lh - 1))
    cw = min(cw, lw - x0)
    ch = min(ch, lh - y0)
    with open(path, "wb") as o:
        o.write(b"P6\n%d %d\n255\n" % (cw, ch))
        buf = bytearray()
        for ly in range(y0, y0 + ch):
            for lx in range(x0, x0 + cw):
                b, g, r = land_bgr(mm, w, st, lx, ly)
                buf.extend((r, g, b))
            o.write(buf)
            buf.clear()
    return cw, ch


def ppm_to_png(src, dst):
    data = open(src, "rb").read()
    i = 2
    while data[i] in (32, 9, 10, 13):
        i += 1
    parts = []
    while len(parts) < 3:
        while data[i] in (32, 9, 10, 13):
            i += 1
        if data[i] == 35:
            while data[i] != 10:
                i += 1
            i += 1
            continue
        start = i
        while data[i] not in (32, 9, 10, 13):
            i += 1
        parts.append(data[start:i])
    w, h, _maxv = int(parts[0]), int(parts[1]), int(parts[2])
    if data[i] in (32, 9, 13):
        i += 1
    if data[i] == 10:
        i += 1
    raw = data[i:]

    def chunk(tag, payload):
        crc = zlib.crc32(tag + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", crc)

    rows = b"".join(b"\x00" + raw[y * w * 3 : (y + 1) * w * 3] for y in range(h))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    open(dst, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(rows, 6))
        + chunk(b"IEND", b"")
    )


def score_land(mm, w, h, st, x0, y0, cw, ch, step=2):
    lw, lh = h, w
    x0 = max(0, min(x0, lw - 1))
    y0 = max(0, min(y0, lh - 1))
    cw = min(cw, lw - x0)
    ch = min(ch, lh - y0)
    cols = collections.Counter()
    n = aa = chroma = ones = 0
    edge = 0
    prev = None
    rowm = []
    for ly in range(y0, y0 + ch, step):
        acc = cnt = 0
        for lx in range(x0, x0 + cw, step):
            b, g, r = land_bgr(mm, w, st, lx, ly)
            cols[(r, g, b)] += 1
            n += 1
            L = r + g + b
            acc += L
            cnt += 1
            if 40 <= L <= 700:
                aa += 1
            if max(r, g, b) - min(r, g, b) >= 18:
                chroma += 1
            if (r, g, b) in ((0, 0, 0), (255, 255, 255), (170, 170, 170)):
                ones += 1
            if prev is not None:
                edge += abs(L - prev)
            prev = L
        rowm.append(acc / max(cnt, 1))
    lag = max(1, 32 // step)
    a, b = [], []
    for i in range(len(rowm) - lag):
        a.append(rowm[i])
        b.append(rowm[i + lag])
    tile = 0.0
    if len(a) > 8:
        ma = sum(a) / len(a)
        mb = sum(b) / len(b)
        cov = sum((x - ma) * (y - mb) for x, y in zip(a, b))
        va = math.sqrt(sum((x - ma) ** 2 for x in a))
        vb = math.sqrt(sum((y - mb) ** 2 for y in b))
        tile = abs(cov / (va * vb)) if va * vb else 0.0
    return {
        "unique": len(cols),
        "aa": aa,
        "chroma": round(chroma / max(n, 1), 4),
        "ones": round(ones / max(n, 1), 4),
        "tile32": round(tile, 4),
        "edge": round(edge / max(n, 1), 2),
        "n": n,
    }


def find_yellow_bands(mm, w, h, st):
    """Return landscape y of yellow #ff0 marker rows (S12/S16 labels)."""
    lw, lh = h, w
    hits = []
    for ly in range(80, min(lh, 900), 4):
        n = 0
        for lx in range(40, min(lw, 400), 4):
            b, g, r = land_bgr(mm, w, st, lx, ly)
            if r > 200 and g > 180 and b < 80:
                n += 1
        if n >= 8:
            hits.append(ly)
    # cluster
    bands = []
    cur = []
    for y in hits:
        if not cur or y - cur[-1] <= 12:
            cur.append(y)
        else:
            bands.append(sum(cur) // len(cur))
            cur = [y]
    if cur:
        bands.append(sum(cur) // len(cur))
    return bands


def session_env():
    uid = pwd_uid(SESSION_USER)
    return {
        "XDG_RUNTIME_DIR": f"/run/user/{uid}",
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{uid}/bus",
        "HOME": f"/home/{SESSION_USER}",
        "USER": SESSION_USER,
        "LOGNAME": SESSION_USER,
    }


def pwd_uid(name):
    import pwd

    return pwd.getpwnam(name).pw_uid


def as_session(argv):
    env = os.environ.copy()
    env.update(session_env())
    if os.geteuid() == 0:
        return ["sudo", "-u", SESSION_USER, f"XDG_RUNTIME_DIR={env['XDG_RUNTIME_DIR']}",
                f"DBUS_SESSION_BUS_ADDRESS={env['DBUS_SESSION_BUS_ADDRESS']}"] + argv
    return argv


def apply_scale(scale: float):
    code = f"""
import dbus, time
bus = dbus.SessionBus()
obj = bus.get_object("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig")
iface = dbus.Interface(obj, "org.gnome.Mutter.DisplayConfig")
serial, monitors, logical, props = iface.GetCurrentState()
mon = [("DSI-1", "{MODE}", dbus.Dictionary({{}}, signature="sv"))]
cfg = [(dbus.Int32(0), dbus.Int32(0), dbus.Double({scale!r}), dbus.UInt32({TRANSFORM}), dbus.Boolean(True), mon)]
iface.ApplyMonitorsConfig(serial, 1, cfg, dbus.Dictionary({{}}, signature="sv"))
time.sleep(1.2)
_,_,logical,_ = iface.GetCurrentState()
print(float(logical[0][2]))
"""
    env = os.environ.copy()
    env.update(session_env())
    if os.geteuid() == 0:
        r = subprocess.run(
            ["sudo", "-u", SESSION_USER, "env",
             f"XDG_RUNTIME_DIR={env['XDG_RUNTIME_DIR']}",
             f"DBUS_SESSION_BUS_ADDRESS={env['DBUS_SESSION_BUS_ADDRESS']}",
             "python3", "-c", code],
            capture_output=True, text=True, timeout=20,
        )
    else:
        r = subprocess.run(["python3", "-c", code], capture_output=True, text=True, timeout=20, env=env)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout or "apply failed").strip())
    return float(r.stdout.strip().splitlines()[-1])


def list_scales():
    code = r"""
import dbus
bus = dbus.SessionBus()
obj = bus.get_object("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig")
iface = dbus.Interface(obj, "org.gnome.Mutter.DisplayConfig")
serial, monitors, logical, props = iface.GetCurrentState()
print("logical", [float(x[2]) for x in logical])
for m in monitors:
    modes = m[1]
    for mode in modes:
        if "1600" in str(mode[0]) and "2560" in str(mode[0]):
            print("mode", mode[0], "scales", list(mode[5]) if len(mode) > 5 else None)
            break
"""
    env = os.environ.copy()
    env.update(session_env())
    if os.geteuid() == 0:
        r = subprocess.run(
            ["sudo", "-u", SESSION_USER, "env",
             f"XDG_RUNTIME_DIR={env['XDG_RUNTIME_DIR']}",
             f"DBUS_SESSION_BUS_ADDRESS={env['DBUS_SESSION_BUS_ADDRESS']}",
             "python3", "-c", code],
            capture_output=True, text=True, timeout=15,
        )
    else:
        r = subprocess.run(["python3", "-c", code], capture_output=True, text=True, timeout=15, env=env)
    return (r.stdout + r.stderr).strip()


def dump_one(tag, mm, w, h, st, fb_id):
    os.makedirs(OUT, exist_ok=True)
    rec = {"tag": tag, "fb": fb_id}
    write_land_ppm(f"{OUT}/ui-{tag}.ppm", mm, w, h, st, 0, 0, min(h, 1400), 160)
    rec["ui"] = score_land(mm, w, h, st, 80, 40, 900, 90)
    bands = find_yellow_bands(mm, w, h, st)
    rec["yellow_y"] = bands
    for i, y in enumerate(bands[:6]):
        write_land_ppm(f"{OUT}/mark{i}-{tag}.ppm", mm, w, h, st, 0, max(0, y - 8), 900, 70)
        rec[f"mark{i}"] = score_land(mm, w, h, st, 20, max(0, y - 4), 860, 56)
    # body paragraph / small text band under first markers
    if bands:
        y = min(bands[0] + 40, w - 80)
        write_land_ppm(f"{OUT}/body-{tag}.ppm", mm, w, h, st, 0, y, 1100, 120)
        rec["body"] = score_land(mm, w, h, st, 20, y, 1080, 110)
    rec["ui"]["pass"] = (
        rec["ui"]["unique"] >= 20
        and rec["ui"]["tile32"] < 0.45
        and rec["ui"]["chroma"] < 0.08
    )
    return rec


def main():
    os.makedirs(OUT, exist_ok=True)
    print("SCALES_QUERY", list_scales(), flush=True)
    rows = []
    wanted = SCALES
    if os.environ.get("DAGU_SCALES"):
        wanted = [float(x) for x in os.environ["DAGU_SCALES"].split(",")]
    for sc in wanted:
        try:
            got = apply_scale(sc)
        except Exception as e:
            print(f"SCALE_FAIL {sc} {e}", flush=True)
            continue
        time.sleep(2.0)
        fd, mm, w, h, st, fb_id = map_kms()
        tag = f"{got:.3f}".replace(".", "p")
        rec = dump_one(tag, mm, w, h, st, fb_id)
        rec["scale"] = got
        rec["want"] = sc
        print(json.dumps(rec, sort_keys=True), flush=True)
        rows.append(rec)
        mm.close()
        os.close(fd)
        for name in os.listdir(OUT):
            if name.endswith(".ppm") and tag in name:
                src = os.path.join(OUT, name)
                ppm_to_png(src, src[:-4] + ".png")
    with open(f"{OUT}/score.json", "w") as f:
        json.dump(rows, f, indent=2)
    ok = bool(rows) and all(r.get("ui", {}).get("pass") for r in rows)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
