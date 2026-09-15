#!/usr/bin/env python3
"""Hole-aligned peek: Chrome FM + Mutter use_count / first_committed / buf_sources."""
from __future__ import annotations

import collections
import json
import struct
import time
import urllib.request
from pathlib import Path

VTABLE_TOP = 0xF60E2D8
VTABLE_SCHED = 0xFC6F180
LOAD_VADDR = 0x2BB0000
TR = Path("/sys/kernel/debug/tracing")


def find_pids():
    shell = chrome = gpu = 0
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes().replace(b"\x00", b" ")
        except OSError:
            continue
        if cmd.startswith(b"/usr/lib/chromium/chromium ") and b"--type=" not in cmd:
            chrome = int(p.name)
        elif b"--type=gpu-process" in cmd and b"/usr/lib/chromium/chromium" in cmd:
            gpu = int(p.name)
        elif cmd.startswith(b"/usr/bin/gnome-shell"):
            shell = int(p.name)
    return shell, chrome, gpu


class Mem:
    def __init__(self, pid):
        self.f = open(f"/proc/{pid}/mem", "rb", buffering=0)

    def u64(self, a):
        self.f.seek(a)
        b = self.f.read(8)
        return struct.unpack("<Q", b)[0] if len(b) == 8 else 0

    def u32(self, a):
        self.f.seek(a)
        b = self.f.read(4)
        return struct.unpack("<I", b)[0] if len(b) == 4 else 0

    def u8(self, a):
        self.f.seek(a)
        b = self.f.read(1)
        return b[0] if b else 0

    def bytes(self, a, n):
        self.f.seek(a)
        return self.f.read(n)


def maps(pid):
    out = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        perm, off = parts[1], int(parts[2], 16)
        path = parts[-1] if parts[-1].startswith("/") else ""
        out.append((lo, hi, perm, off, path))
    return out


def rx_chrome(pid):
    for lo, hi, perm, off, path in maps(pid):
        if "r-xp" in perm and off == 0x2BA0000 and path.endswith("/chromium"):
            return lo
    return 0


def rx_mutter(pid):
    for lo, hi, perm, off, path in maps(pid):
        if "r-xp" in perm and off == 0 and "libmutter-18.so.0" in path:
            return lo
    return 0


def heap_ranges(pid, limit=96 << 20):
    pref, rest = [], []
    for lo, hi, perm, off, path in maps(pid):
        if "rw-p" not in perm:
            continue
        if path and path not in ("[heap]", "[anon:libc_malloc]") and not path.startswith("[anon"):
            continue
        sz = hi - lo
        if sz < 0x1000 or sz > limit:
            continue
        (pref if path in ("[heap]", "[anon:libc_malloc]", "") else rest).append((lo, hi))
    return pref + rest


def plausible(a):
    return 0x100000000 <= a < 0x800000000000 and (a & 7) == 0


def deque_n(m: Mem, head):
    data, cap, begin, end = m.u64(head), m.u64(head + 8), m.u64(head + 16), m.u64(head + 24)
    if cap == 0 or cap > 64 or begin > cap or end > cap:
        return 0, []
    if end == begin:
        return 0, []
    n = end - begin if end > begin else (end - begin) % cap
    addrs = []
    if n and n <= 16 and plausible(data):
        i = begin
        for _ in range(n):
            addrs.append(m.u64(data + i * 8))
            i = (i + 1) % cap
    return n, addrs


def map_entries(m: Mem, fr):
    b0, b1 = m.u64(fr + 512), m.u64(fr + 520)
    if not b0 or not b1 or b1 < b0:
        return []
    n = (b1 - b0) // 16
    if n > 8:
        return []
    rows = []
    for i in range(n):
        surf = m.u64(b0 + i * 16)
        handle = m.u64(b0 + i * 16 + 8)
        hid = sync = buf = 0
        if plausible(handle):
            hid = m.u32(handle + 8)
            buf = m.u64(handle + 24)
            sync = m.u32(handle + 32)
        rows.append({"surf": hex(surf), "handle": hex(handle), "id": hid, "sync": sync, "wl_buf": hex(buf)})
    return rows


def frame_row(m: Mem, fr):
    if not plausible(fr):
        return None
    return {
        "fr": hex(fr),
        "id": m.u32(fr),
        "cb": 1 if m.u64(fr + 544) else 0,
        "ack": m.u8(fr + 568) & 1,
        "fb": m.u8(fr + 656) & 1,
        "pack": m.u8(fr + 664) & 1,
        "mapn": max(0, (m.u64(fr + 520) - m.u64(fr + 512)) // 16) if m.u64(fr + 520) >= m.u64(fr + 512) else -1,
        "bufs": map_entries(m, fr),
    }


def find_window(m: Mem, rx, ranges):
    live_vt = rx + (VTABLE_TOP - LOAD_VADDR) + 16
    needle = struct.pack("<Q", live_vt)
    for lo, hi in ranges:
        size = hi - lo
        if size > 48 << 20:
            continue
        try:
            blob = m.bytes(lo, size)
        except OSError:
            continue
        start = 0
        while True:
            j = blob.find(needle, start)
            if j < 0:
                break
            if j % 8 == 0:
                addr = lo + j
                try:
                    fm = m.u64(addr + 248)
                    if plausible(fm):
                        n_sub, _ = deque_n(m, fm + 40)
                        if 1 <= n_sub <= 8:
                            return addr, fm
                except OSError:
                    pass
            start = j + 8
    return 0, 0


def find_sched(m: Mem, gpu_rx, ranges):
    live_vt = gpu_rx + (VTABLE_SCHED - LOAD_VADDR) + 16
    needle = struct.pack("<Q", live_vt)
    for lo, hi in ranges:
        size = hi - lo
        if size > 48 << 20:
            continue
        try:
            blob = m.bytes(lo, size)
        except OSError:
            continue
        start = 0
        while True:
            j = blob.find(needle, start)
            if j < 0:
                break
            if j % 8 == 0:
                addr = lo + j
                try:
                    pend = m.u32(addr + 604)
                    mx = m.u32(addr + 608)
                    if pend <= 8 and 1 <= mx <= 8:
                        return addr
                except OSError:
                    pass
            start = j + 8
    return 0


def ghash_n(m: Mem, ht):
    if not plausible(ht):
        return -1
    # glib GHashTable: nnodes at +12 (int)
    try:
        n = m.u32(ht + 12)
        return n if n < 4096 else -2
    except OSError:
        return -1


def wl_id(m: Mem, resource):
    if not plausible(resource):
        return -1
    return m.u32(resource + 16)


def is_wl_buffer_resource(m: Mem, res):
    if not plausible(res):
        return False, -1
    try:
        iface = m.u64(res)
        rid = m.u32(res + 16)
        if not plausible(iface) or rid <= 0 or rid > 0x10000:
            return False, -1
        name = m.u64(iface)
        if not plausible(name):
            return False, -1
        s = m.bytes(name, 10)
    except OSError:
        return False, -1
    return s.startswith(b"wl_buffer"), rid


def find_buffers_by_ids(m: Mem, ranges, want_ids):
    want = set(want_ids)
    found = {}
    klass = 0
    for lo, hi in ranges:
        size = hi - lo
        if size > 48 << 20:
            continue
        try:
            blob = m.bytes(lo, size)
        except OSError:
            continue
        for i in range(0, len(blob) - 160, 8):
            typ = struct.unpack_from("<I", blob, i + 72)[0]
            if typ != 4:
                continue
            uc = struct.unpack_from("<I", blob, i + 64)[0]
            if uc > 16:
                continue
            res = struct.unpack_from("<Q", blob, i + 32)[0]
            ok, rid = is_wl_buffer_resource(m, res)
            if not ok or rid not in want:
                continue
            k = struct.unpack_from("<Q", blob, i)[0]
            if not plausible(k):
                continue
            rp = struct.unpack_from("<Q", blob, i + 152)[0]
            if not plausible(rp):
                continue
            rplen = m.u32(rp + 8)
            if rplen > 16:
                continue
            addr = lo + i
            if klass == 0:
                klass = k
            elif k != klass:
                continue
            found[rid] = {
                "buf": hex(addr),
                "klass": hex(k),
                "use": uc,
                "rplen": rplen,
                "res": hex(res),
                "comp": hex(struct.unpack_from("<Q", blob, i + 24)[0]),
            }
        if len(found) >= len(want):
            break
    return klass, found


def find_surfaces(m: Mem, ranges, buf_addrs):
    want = set(buf_addrs)
    hits = []
    for lo, hi in ranges:
        size = hi - lo
        if size > 48 << 20:
            continue
        try:
            blob = m.bytes(lo, size)
        except OSError:
            continue
        for i in range(0, len(blob) - 480, 8):
            buf = struct.unpack_from("<Q", blob, i + 104)[0]
            if buf not in want:
                continue
            held = struct.unpack_from("<I", blob, i + 112)[0]
            if held > 1:
                continue
            first = struct.unpack_from("<Q", blob, i + 440)[0]
            last = struct.unpack_from("<Q", blob, i + 448)[0]
            fifo = struct.unpack_from("<I", blob, i + 472)[0]
            if fifo > 1:
                continue
            if first and not plausible(first):
                continue
            if last and not plausible(last):
                continue
            addr = lo + i
            tx = {}
            if first and plausible(first):
                src = m.u64(first + 56)
                tgt = m.u64(first + 64)
                tx = {
                    "first": hex(first),
                    "last": hex(last),
                    "buf_sources": hex(src),
                    "src_n": ghash_n(m, src),
                    "target_us": tgt,
                }
            hits.append(
                {
                    "surf": hex(addr),
                    "buffer": hex(buf),
                    "held": held,
                    "fifo": fifo,
                    "first": hex(first) if first else 0,
                    "tx": tx,
                }
            )
        if len(hits) >= 8:
            break
    return hits


def dump_lab():
    d = json.loads(urllib.request.urlopen("http://127.0.0.1:8770/api/dump", timeout=3).read())
    h = d.get("host") or d.get("hw") or {}
    v = d.get("verdict") or {}
    return {
        "fps": d.get("fps"),
        "p50": d.get("p50"),
        "p99": d.get("p99"),
        "max": d.get("max"),
        "holes": d.get("holes"),
        "video14_open": h.get("video14_open"),
        "software_decode": v.get("software_decode"),
        "vblank_fps": h.get("vblank_fps"),
        "venus_irq": h.get("venus_irq"),
        "gpu_busy": h.get("gpu_busy"),
    }


def arm_trace():
    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("8192\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")


def read_kickoff():
    (TR / "tracing_on").write_text("0\n")
    ts = []
    raw = (TR / "trace").read_text(errors="replace")
    for line in raw.splitlines():
        if "dpu_enc_kickoff" not in line or line[:1] == "#":
            continue
        parts = line.split()
        for p in parts:
            if p.endswith(":") and p[:-1].replace(".", "", 1).isdigit():
                try:
                    ts.append(float(p[:-1]))
                    break
                except ValueError:
                    pass
    gaps = [1000.0 * (b - a) for a, b in zip(ts, ts[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (ts[-1] - ts[0]) if len(ts) > 1 else 0
    return {
        "n": len(ts),
        "hz": round(len(ts) / span, 2) if span > 0 else 0,
        "max": round(max(gaps), 1) if gaps else None,
        "p50": round(sorted(gaps)[len(gaps) // 2], 2) if gaps else None,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:10]],
        "span": round(span, 3),
    }


def mutter_snapshot(sm, ranges, ids):
    klass, bufs = find_buffers_by_ids(sm, ranges, ids)
    buf_addrs = [int(v["buf"], 16) for v in bufs.values()]
    surfs = find_surfaces(sm, ranges, buf_addrs) if buf_addrs else []
    return {"klass": hex(klass), "bufs": bufs, "surfs": surfs}


def main():
    shell, chrome, gpu = find_pids()
    out = {"pids": {"shell": shell, "chrome": chrome, "gpu": gpu}}
    if not (chrome and gpu and shell):
        print(json.dumps(out, indent=2))
        return
    cm, gm, sm = Mem(chrome), Mem(gpu), Mem(shell)
    chrome_rs = heap_ranges(chrome)
    gpu_rs = heap_ranges(gpu)
    sh_rs = heap_ranges(shell)
    chrome_rx = rx_chrome(chrome)
    gpu_rx = rx_chrome(gpu)
    mutter_rx = rx_mutter(shell)
    out["rx"] = {"chrome": hex(chrome_rx), "gpu": hex(gpu_rx), "mutter": hex(mutter_rx)}
    if mutter_rx:
        insn = sm.u32(mutter_rx + 0x18E3DC)
        out["has_dep_bufsrc"] = {"va": hex(mutter_rx + 0x18E3DC), "insn": hex(insn), "stock": insn == 0x35000560}
    win, fm = find_window(cm, chrome_rx, chrome_rs)
    sched = find_sched(gm, gpu_rx, gpu_rs)
    out["win"] = hex(win)
    out["fm"] = hex(fm)
    out["sched"] = hex(sched)
    out["lab0"] = dump_lab()

    _, frames0 = deque_n(cm, fm + 40) if fm else (0, [])
    rows0 = [frame_row(cm, a) for a in frames0[:6]]
    out["frames0"] = rows0
    ids = []
    for r in rows0:
        if not r:
            continue
        for b in r.get("bufs") or []:
            if b["id"]:
                ids.append(b["id"])
    out["wlids"] = ids
    out["mutter0"] = mutter_snapshot(sm, sh_rs, ids) if ids else {}

    hist = collections.Counter()
    holes = []
    last_swap = None
    t0 = time.monotonic()
    arm_trace()
    while time.monotonic() - t0 < 8.0:
        frames = []
        if fm:
            pend_n, _ = deque_n(cm, fm + 8)
            sub_n, subs = deque_n(cm, fm + 40)
            frames = [frame_row(cm, a) for a in subs[:6]]
        else:
            pend_n = sub_n = -1
        swap = gp = mx = -1
        if sched:
            swap = gm.u32(sched + 600)
            gp = gm.u32(sched + 604)
            mx = gm.u32(sched + 608)
        key = (pend_n, sub_n, gp)
        hist[str(key)] += 1
        if last_swap is not None and swap == last_swap and gp >= 2 and len(holes) < 6:
            rec = {
                "pend": pend_n,
                "sub": sub_n,
                "gpu_pend": gp,
                "max": mx,
                "frames": frames,
            }
            if len(holes) == 0:
                hole_ids = []
                for r in frames:
                    if not r:
                        continue
                    for b in r.get("bufs") or []:
                        if b["id"]:
                            hole_ids.append(b["id"])
                rec["mutter"] = mutter_snapshot(sm, sh_rs, hole_ids) if hole_ids else {}
            holes.append(rec)
        last_swap = swap
        time.sleep(0.004)
    out["hist"] = hist.most_common(12)
    out["holes"] = holes
    out["kickoff"] = read_kickoff()
    out["lab1"] = dump_lab()
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
