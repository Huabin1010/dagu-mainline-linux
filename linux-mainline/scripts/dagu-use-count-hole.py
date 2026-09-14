#!/usr/bin/env python3
"""Hole-aligned peek: Chrome Ozone + Mutter use_count / transaction queue.

Does not poke. Does not preload gnome-shell. Hardware path only.
"""
from __future__ import annotations

import collections
import json
import os
import struct
import time
import urllib.request
from pathlib import Path

def find_pids():
    shell = chrome = gpu = 0
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes().replace(b"\x00", b" ")
        except OSError:
            continue
        if not chrome and b"/usr/lib/chromium/chromium" in cmd and b"--type=" not in cmd:
            chrome = int(p.name)
        elif b"--type=gpu-process" in cmd and b"/usr/lib/chromium/chromium" in cmd:
            gpu = int(p.name)
        elif b"/usr/bin/gnome-shell" in cmd and b"--mode=" in cmd:
            shell = int(p.name)
    return shell, chrome, gpu


FM_HINT = 0x4400B59EE0
SCHED_HINT = 0x24000B8700
LOAD_VADDR = 0x2BB0000
VTABLE_SCHED = 0xFC6F180
USE_OFF = 64
TYPE_OFF = 72
RP_OFF = 152
BUF_OFF = 104
HELD_OFF = 112
FIRST_OFF = 440
LAST_OFF = 448
FIFO_OFF = 472
CLOCK_HINT = 0x55A4B090D0


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


def heap_ranges(pid):
    rs = []
    for lo, hi, perm, off, path in maps(pid):
        if "rw-p" not in perm:
            continue
        if path and path not in ("[heap]", "[anon:libc_malloc]"):
            if not path.startswith("[anon:") and path != "":
                continue
        if hi - lo < 0x1000 or hi - lo > 96 << 20:
            continue
        rs.append((lo, hi))
    return rs


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

    def i32(self, a):
        self.f.seek(a)
        b = self.f.read(4)
        return struct.unpack("<i", b)[0] if len(b) == 4 else 0

    def bytes(self, a, n):
        self.f.seek(a)
        return self.f.read(n)


def plausible_ptr(a):
    return 0x100000000 <= a < 0x800000000000 and (a & 7) == 0


def deque_n(m: Mem, head):
    # circular_deque: begin, end at +24/+32 relative to deque start? Chrome
    # libc++ circular_deque: { T* ptr; size_t cap; size_t begin; size_t end }
    # previous session: data +0 of deque, cap +8, begin/end +16/+24 within the
    # deque which itself sits at object+8 (pending) / +40 (submitted).
    data, cap, begin, end = (
        m.u64(head),
        m.u64(head + 8),
        m.u64(head + 16),
        m.u64(head + 24),
    )
    if cap == 0 or cap > 64:
        return 0, []
    if begin > cap or end > cap:
        return 0, []
    n = (end - begin) % cap if end != begin else 0
    if end > begin:
        n = end - begin
    addrs = []
    if n and n <= 16 and plausible_ptr(data):
        i = begin
        for _ in range(n):
            addrs.append(m.u64(data + i * 8))
            i = (i + 1) % cap
    return n, addrs


def frame_info(m: Mem, fr):
    if not plausible_ptr(fr):
        return None
    cb = m.u64(fr + 544)
    fb_has = m.u32(fr + 656) & 1
    b0, b1 = m.u64(fr + 512), m.u64(fr + 520)
    empty = 1 if (not b0 or b0 == b1) else 0
    return (1 if cb else 0, fb_has, empty)


def find_fm(m: Mem, hint):
    if hint:
        n_sub, _ = deque_n(m, hint + 40)
        n_pend, _ = deque_n(m, hint + 8)
        if n_sub + n_pend <= 16:
            skip = m.bytes(hint + 301, 1)
            if skip in (b"\x00", b"\x01"):
                return hint
    return 0


def find_sched(m: Mem, gpu_rx, hint):
    live_vt = gpu_rx + (VTABLE_SCHED - LOAD_VADDR) + 16
    if hint:
        if m.u64(hint) == live_vt:
            return hint
    return hint if hint and plausible_ptr(hint) else 0


def scan_dma_bufs(sm: Mem, ranges):
    found = []
    for lo, hi in ranges:
        size = hi - lo
        if size > 64 << 20:
            continue
        try:
            blob = sm.bytes(lo, size)
        except OSError:
            continue
        for i in range(0, len(blob) - 160, 8):
            uc = struct.unpack_from("<I", blob, i + USE_OFF)[0]
            if uc == 0 or uc > 8:
                continue
            typ = struct.unpack_from("<I", blob, i + TYPE_OFF)[0]
            if typ != 4:
                continue
            ref = struct.unpack_from("<I", blob, i + 8)[0]
            if ref == 0 or ref > 64:
                continue
            comp = struct.unpack_from("<Q", blob, i + 24)[0]
            res = struct.unpack_from("<Q", blob, i + 32)[0]
            if not plausible_ptr(comp) or not plausible_ptr(res):
                continue
            rp = struct.unpack_from("<Q", blob, i + RP_OFF)[0]
            rplen = 0
            if plausible_ptr(rp):
                try:
                    rplen = sm.u32(rp + 8)
                    if rplen > 16:
                        rplen = -1
                except OSError:
                    rplen = -2
            found.append(
                {
                    "addr": lo + i,
                    "uc": uc,
                    "ref": ref,
                    "rp": rplen,
                    "res": res,
                }
            )
        if len(found) > 64:
            break
    return found


def scan_surfaces(sm: Mem, ranges, buf_set):
    hits = []
    for lo, hi in ranges:
        size = hi - lo
        if size > 64 << 20:
            continue
        try:
            blob = sm.bytes(lo, size)
        except OSError:
            continue
        for i in range(0, len(blob) - 480, 8):
            buf = struct.unpack_from("<Q", blob, i + BUF_OFF)[0]
            if buf not in buf_set:
                continue
            held = struct.unpack_from("<I", blob, i + HELD_OFF)[0]
            if held > 1:
                continue
            first = struct.unpack_from("<Q", blob, i + FIRST_OFF)[0]
            last = struct.unpack_from("<Q", blob, i + LAST_OFF)[0]
            fifo = struct.unpack_from("<I", blob, i + FIFO_OFF)[0]
            if fifo > 1:
                continue
            if first and not plausible_ptr(first):
                continue
            hits.append(
                {
                    "addr": lo + i,
                    "buf": buf,
                    "held": held,
                    "first": first,
                    "last": last,
                    "fifo": fifo,
                }
            )
    return hits


def txn_info(sm: Mem, txn):
    if not plausible_ptr(txn):
        return None
    try:
        entries = sm.u64(txn + 48)
        bufs = sm.u64(txn + 56)
        tgt = sm.u64(txn + 64)
        seq = sm.u64(txn + 40)
        nent = nbuf = -1
        if plausible_ptr(entries):
            nent = sm.u32(entries + 20)  # glib nnodes guess
        if plausible_ptr(bufs):
            nbuf = sm.u32(bufs + 20)
        return {
            "txn": txn,
            "seq": seq,
            "nent": nent,
            "nbufsrc": nbuf,
            "tgt": tgt,
            "bufs_ptr": bufs,
        }
    except OSError:
        return None


def dump_lab():
    try:
        d = json.loads(
            urllib.request.urlopen("http://127.0.0.1:8770/api/dump", timeout=3).read()
        )
        h = d.get("host") or {}
        return {
            "fps": d.get("fps"),
            "p50": d.get("p50"),
            "p99": d.get("p99"),
            "max": d.get("max"),
            "holes": d.get("holes"),
            "video14_open": h.get("video14_open"),
            "software_decode": (d.get("verdict") or {}).get("software_decode"),
            "vblank_fps": h.get("vblank_fps"),
            "venus_irq": h.get("venus_irq"),
        }
    except Exception as e:
        return {"err": str(e)}


def main():
    SHELL, CHROME, GPU = find_pids()
    if not (SHELL and CHROME and GPU):
        raise SystemExit(f"pids shell={SHELL} chrome={CHROME} gpu={GPU}")
    cm = Mem(CHROME)
    gm = Mem(GPU)
    sm = Mem(SHELL)
    gpu_rx = rx_chrome(GPU)
    fm = find_fm(cm, FM_HINT)
    sched = find_sched(gm, gpu_rx, SCHED_HINT)
    clock = CLOCK_HINT
    try:
        rr = gm.u32(clock + 28) if False else 0
    except OSError:
        clock = 0
    # clutter clock lives in gnome-shell
    try:
        rr = sm.u32(CLOCK_HINT + 28)
        clock = CLOCK_HINT if rr in (60, 120) else 0
    except OSError:
        clock = 0

    ranges = heap_ranges(SHELL)
    bufs = scan_dma_bufs(sm, ranges)
    buf_set = {b["addr"] for b in bufs}
    surfs = scan_surfaces(sm, ranges, buf_set)

    snap0 = {
        "pids": {"shell": SHELL, "chrome": CHROME, "gpu": GPU},
        "lab": dump_lab(),
        "fm": hex(fm),
        "sched": hex(sched) if sched else None,
        "clock": hex(clock) if clock else None,
        "dma_n": len(bufs),
        "dma": bufs,
        "surf_n": len(surfs),
        "surf": surfs,
    }

    hist = collections.Counter()
    hole_rows = []
    last_swap = None
    freeze_t = None
    t0 = time.monotonic()
    while time.monotonic() - t0 < 6.0:
        pend_n = sub_n = gpu_pend = nd = -1
        frames = []
        if fm:
            pend_n, _ = deque_n(cm, fm + 8)
            sub_n, subs = deque_n(cm, fm + 40)
            skip = cm.bytes(fm + 301, 1)[0]
            frames = [frame_info(cm, a) for a in subs[:6]]
        else:
            skip = -1
        swap = -1
        if sched:
            swap = gm.u32(sched + 600)
            gpu_pend = gm.u32(sched + 604)
            nd = gm.bytes(sched + 596, 1)[0]
        st = inh = pr = -1
        if clock:
            st = sm.u32(clock + 88)
            pr = sm.u32(clock + 396)
            inh = sm.u32(clock + 404)
        ucs = []
        firsts = []
        for s in surfs[:8]:
            try:
                ucs.append(sm.u32(s["buf"] + USE_OFF))
                firsts.append(1 if sm.u64(s["addr"] + FIRST_OFF) else 0)
            except OSError:
                ucs.append(-1)
                firsts.append(-1)
        key = (
            sub_n,
            pend_n,
            skip,
            tuple(frames),
            gpu_pend,
            nd,
            st,
            tuple(ucs),
            tuple(firsts),
        )
        hist[str(key)] += 1
        now = time.monotonic()
        if last_swap is not None and swap == last_swap:
            if freeze_t is None:
                freeze_t = now
            elif now - freeze_t >= 0.045 and len(hole_rows) < 24:
                hole_rows.append(
                    {
                        "dt_ms": round((now - freeze_t) * 1000, 1),
                        "swap": swap,
                        "sub": sub_n,
                        "pend": pend_n,
                        "skip": skip,
                        "frames": frames,
                        "gpu_pend": gpu_pend,
                        "nd": nd,
                        "clock_st": st,
                        "clock_pr": pr,
                        "ucs": ucs,
                        "firsts": firsts,
                    }
                )
                freeze_t = now + 0.2
        else:
            freeze_t = None
        last_swap = swap
        time.sleep(0.002)

    # refresh bufs/surfs + txn after the window
    bufs2 = scan_dma_bufs(sm, ranges)
    buf_set2 = {b["addr"] for b in bufs2}
    surfs2 = scan_surfaces(sm, ranges, buf_set2)
    txns = []
    for s in surfs2:
        first = s["first"]
        if first:
            info = txn_info(sm, first)
            if info:
                txns.append({"surf": hex(s["addr"]), **info})

    out = {
        "snap0": snap0,
        "lab1": dump_lab(),
        "hist_top": hist.most_common(16),
        "holes": hole_rows,
        "dma1": bufs2,
        "surf1": surfs2,
        "txns": txns,
    }
    Path("/tmp/dagu-usecount-hole.json").write_text(json.dumps(out, default=hex))
    print(json.dumps({
        "lab0": snap0["lab"],
        "lab1": out["lab1"],
        "fm": snap0["fm"],
        "dma_n0": snap0["dma_n"],
        "dma_n1": len(bufs2),
        "surf_n0": snap0["surf_n"],
        "surf_n1": len(surfs2),
        "dma": bufs2,
        "surf": surfs2,
        "txns": txns,
        "hist_top": hist.most_common(8),
        "n_holes": len(hole_rows),
        "holes": hole_rows[:8],
    }, default=str, indent=2))


if __name__ == "__main__":
    main()
