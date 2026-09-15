#!/usr/bin/env python3
"""No-uprobe: walk default-context GSources; during kickoff holes snapshot IN_CALL."""
from __future__ import annotations

import json
import struct
import time
from collections import Counter
from pathlib import Path

TR = Path("/sys/kernel/debug/tracing")


def u64(mem, a):
    mem.seek(a)
    b = mem.read(8)
    return struct.unpack("<Q", b)[0] if len(b) == 8 else 0


def u32(mem, a):
    mem.seek(a)
    b = mem.read(4)
    return struct.unpack("<I", b)[0] if len(b) == 4 else 0


def i32(mem, a):
    mem.seek(a)
    b = mem.read(4)
    return struct.unpack("<i", b)[0] if len(b) == 4 else 0


def cstr(mem, a, n=64):
    if not a or a > 0x0000FFFFFFFFFFFF:
        return ""
    try:
        mem.seek(a)
        b = mem.read(n)
    except OSError:
        return ""
    s = b.split(b"\x00", 1)[0]
    if not s or any(x < 32 or x > 126 for x in s):
        return ""
    return s.decode()


def find_shell():
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            c = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if c.startswith(b"/usr/bin/gnome-shell") and b"--mode=ubuntu" in c:
            return int(p.name)
    raise SystemExit("no ubuntu")


def maps(pid):
    glib_rw = mutter_rx = gjs_rx = moz_rx = clutter_rx = None
    heaps = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        path = parts[-1] if len(parts) > 5 else ""
        if "libglib-2.0.so" in path and "rw-p" in parts[1]:
            glib_rw = (lo, hi)
        if "libmutter-18.so.0.0.0" in path and "r-xp" in parts[1] and "mutter-18/" not in path:
            mutter_rx = (lo, hi)
        if "libgjs.so" in path and "r-xp" in parts[1]:
            gjs_rx = (lo, hi)
        if "libmozjs" in path and "r-xp" in parts[1]:
            moz_rx = (lo, hi)
        if "libmutter-clutter" in path and "r-xp" in parts[1]:
            clutter_rx = (lo, hi)
        if parts[1].startswith("rw") and not path.startswith("/"):
            sz = hi - lo
            if 0x8000 <= sz <= 0x8000000:
                heaps.append((lo, hi))
    return glib_rw, heaps, {
        "mutter": mutter_rx, "gjs": gjs_rx, "mozjs": moz_rx, "clutter": clutter_rx,
    }


def resolve(rx, pc):
    if not pc:
        return hex(pc)
    for name, rng in rx.items():
        if rng and rng[0] <= pc < rng[1]:
            return f"{name}+{pc - rng[0]:#x}"
    return hex(pc)


def main():
    pid = find_shell()
    glib_rw, heaps, rx = maps(pid)
    mem = open(f"/proc/{pid}/mem", "rb", buffering=0)
    ctx_slot = glib_rw[0] + 0xA90
    ctx = u64(mem, ctx_slot)
    needle = struct.pack("<Q", ctx)
    srcs = []
    for lo, hi in heaps:
        pos = lo
        while pos < hi:
            n = min(0x100000, hi - pos)
            try:
                mem.seek(pos)
                blob = mem.read(n)
            except OSError:
                pos += n
                continue
            if not blob:
                break
            start = 0
            while True:
                i = blob.find(needle, start)
                if i < 0:
                    break
                # GSource+32 == context
                if i >= 32 and (i - 32) % 8 == 0:
                    s = pos + i - 32
                    try:
                        ref = u32(mem, s + 0x18)
                        prio = i32(mem, s + 40)
                        flags = u32(mem, s + 44)
                    except OSError:
                        start = i + 8
                        continue
                    if 1 <= ref <= 64 and -400 <= prio <= 400:
                        srcs.append(s)
                start = i + 8
            pos += n
    srcs = sorted(set(srcs))
    print(json.dumps({"pid": pid, "ctx": hex(ctx), "nsrc": len(srcs)}), flush=True)

    def snap_one(s):
        name = cstr(mem, u64(mem, s + 80))
        funcs = u64(mem, s)
        disp = u64(mem, funcs + 16) if funcs else 0
        return {
            "s": hex(s),
            "name": name,
            "prio": i32(mem, s + 40),
            "flags": hex(u32(mem, s + 44)),
            "f2c": hex(u32(mem, s + 0x2C)),
            "disp": resolve(rx, disp),
            "cb": hex(u64(mem, s + 136)),
            "flush": u32(mem, s + 144),
        }

    catalog = []
    for s in srcs:
        try:
            catalog.append(snap_one(s))
        except OSError:
            pass
    print(json.dumps({"catalog": catalog[:40], "ncatalog": len(catalog)}), flush=True)

    TR.joinpath("tracing_on").write_text("1\n")
    TR.joinpath("events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    TR.joinpath("trace").write_text("")
    last = time.monotonic()
    holes = []
    t0 = time.monotonic()
    while time.monotonic() - t0 < 8.2:
        now = time.monotonic()
        raw = TR.joinpath("trace").read_text(errors="replace")
        TR.joinpath("trace").write_text("")
        saw = False
        for line in raw.splitlines():
            if "dpu_enc_kickoff" in line:
                saw = True
        if saw:
            last = now
        elif now - last >= 0.045 and len(holes) < 8:
            incall = []
            for s in srcs:
                try:
                    f44 = u32(mem, s + 44)
                    f2c = u32(mem, s + 0x2C)
                except OSError:
                    continue
                if (f44 & 2) or (f2c & 2):
                    try:
                        incall.append(snap_one(s))
                    except OSError:
                        pass
            holes.append({
                "dt": round((now - last) * 1000, 1),
                "sys": Path(f"/proc/{pid}/syscall").read_text().strip().split()[0],
                "incall": incall,
            })
            last = now
        time.sleep(0.003)
    TR.joinpath("tracing_on").write_text("1\n")
    print(json.dumps({"holes": holes}))


if __name__ == "__main__":
    main()
