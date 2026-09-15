#!/usr/bin/env python3
"""No-uprobe: find MetaOnscreen via page-flip listener vtable, sample +88 next during kickoff holes."""
from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")
VT_OFF = 0x2AACD0


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        " -o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def u64(mem, a: int) -> int:
    mem.seek(a)
    b = mem.read(8)
    return struct.unpack("<Q", b)[0] if len(b) == 8 else 0


def u32(mem, a: int) -> int:
    mem.seek(a)
    b = mem.read(4)
    return struct.unpack("<I", b)[0] if len(b) == 4 else 0


def find_shell() -> int:
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


def mutter_maps(pid: int) -> tuple[int, tuple[int, int], list[tuple[int, int]], int]:
    vt = None
    mutter_rx = None
    glib_ctx = None
    heaps = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        off = int(parts[2], 16)
        path = parts[-1] if len(parts) > 5 else ""
        if "libmutter-18.so.0.0.0" in path and "mutter-18/" not in path:
            if "r-xp" in parts[1]:
                mutter_rx = (lo, hi)
            if off <= VT_OFF < off + (hi - lo):
                vt = lo + (VT_OFF - off)
        if "libglib-2.0.so" in path and "rw-p" in parts[1]:
            # this RW page starts at ELF 0x180000; default ctx ptr @ 0x180A90
            slot = lo + 0xA90
            if lo <= slot < hi:
                try:
                    tmp = open(f"/proc/{pid}/mem", "rb")
                    glib_ctx = u64(tmp, slot)
                    tmp.close()
                except OSError:
                    glib_ctx = None
        if not parts[1].startswith("rw"):
            continue
        sz = hi - lo
        if sz < 0x8000 or sz > 0x8000000:
            continue
        if path.startswith("/"):
            continue
        heaps.append((lo, hi))
    if vt is None or mutter_rx is None:
        raise SystemExit("no vtable/rx map")
    return vt, mutter_rx, heaps, glib_ctx or 0


def find_onscreens(mem, vt: int, heaps, mutter_rx, ctx) -> list[int]:
    needle = struct.pack("<Q", vt)
    rx0, rx1 = mutter_rx
    ons = []
    hits = 0
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
                lis = pos + i - 16
                try:
                    ref = u32(mem, lis)
                    crtc = u64(mem, lis + 8)
                    lctx = u64(mem, lis + 24)
                    ud = u64(mem, lis + 32)
                    dest = u64(mem, lis + 40)
                except OSError:
                    start = i + 8
                    continue
                hits += 1
                print(json.dumps({
                    "lis": hex(lis), "ref": ref, "crtc": hex(crtc),
                    "lctx": hex(lctx), "ud": hex(ud), "dest": hex(dest),
                    "dest_rx": rx0 <= dest < rx1, "ctx_ok": (not ctx or lctx == ctx),
                }), flush=True)
                if (
                    1 <= ref <= 32
                    and ud
                    and crtc
                    and rx0 <= dest < rx1
                    and (not ctx or lctx == ctx)
                    and ud not in ons
                ):
                    ons.append(ud)
                start = i + 8
            pos += n
    print(json.dumps({"vt_hits": hits, "ctx": hex(ctx), "ons": [hex(x) for x in ons]}), flush=True)
    return ons


def snap(mem, ons: int) -> dict:
    return {
        "ons": hex(ons),
        "p64": hex(u64(mem, ons + 64)),
        "p72": hex(u64(mem, ons + 72)),
        "n88": hex(u64(mem, ons + 88)),
        "p144": hex(u64(mem, ons + 144)),
        "p160": hex(u64(mem, ons + 160)),
    }


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def main() -> None:
    shell = find_shell()
    vt, mutter_rx, heaps, ctx = mutter_maps(shell)
    mem = open(f"/proc/{shell}/mem", "rb", buffering=0)
    print(json.dumps({"shell": shell, "vt": hex(vt), "nheap": len(heaps), "ctx": hex(ctx), "rx": [hex(x) for x in mutter_rx]}), flush=True)
    ons = find_onscreens(mem, vt, heaps, mutter_rx, ctx)
    if not ons:
        raise SystemExit("no onscreen")

    chg = {o: {"n88": set(), "p72": set(), "p64": set()} for o in ons}
    for _ in range(40):
        for o in ons:
            s = snap(mem, o)
            chg[o]["n88"].add(s["n88"])
            chg[o]["p72"].add(s["p72"])
            chg[o]["p64"].add(s["p64"])
        time.sleep(0.008)
    live = []
    for o, d in chg.items():
        rec = {k: sorted(v) for k, v in d.items()}
        rec["ons"] = hex(o)
        rec["live"] = len(d["n88"]) + len(d["p72"]) + len(d["p64"]) > 3
        print(json.dumps(rec), flush=True)
        if rec["live"]:
            live.append(o)
    if not live:
        live = ons[:2]

    TR.joinpath("tracing_on").write_text("1\n")
    TR.joinpath("events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    TR.joinpath("trace").write_text("")
    time.sleep(8)
    raw = TR.joinpath("trace").read_text(errors="replace")
    kts = []
    for line in raw.splitlines():
        if "dpu_enc_kickoff" not in line or line[:1] == "#":
            continue
        ts = parse_ts(line)
        if ts is not None:
            kts.append(ts)
    holes = []
    for i in range(1, len(kts)):
        g = (kts[i] - kts[i - 1]) * 1000
        if g >= 50:
            holes.append(round(g, 1))
    span = (kts[-1] - kts[0]) if len(kts) > 1 else 0
    snaps = [snap(mem, o) for o in live]
    TR.joinpath("tracing_on").write_text("1\n")
    print(json.dumps({
        "hz": round((len(kts) - 1) / span, 2) if span else 0,
        "n": len(kts),
        "gt50": len(holes),
        "holes": holes[:12],
        "after": snaps,
        "nlive": len(live),
    }))


if __name__ == "__main__":
    if "--host" in sys.argv:
        here = Path(__file__).read_text()
        subprocess.check_call(
            [
                "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null", f"root@{HOST}",
                "python3", "-",
            ],
            input=here.encode(),
        )
    else:
        main()
