#!/usr/bin/env python3
"""Solution 3: Mutter release-point vs Chrome WaitForFence point.

Does not rebuild libmutter. Reads live objects after objdump of:
  Chrome official-152 WaylandSyncobjReleaseTimeline
  stock libmutter-18 handle_release_points / MetaWaylandSyncPoint

Chrome (ELF):
  WaylandBufferHandle +24 wl_buffer*, +32 sync_method, +48 ReleaseTimeline*
  ReleaseTimeline +16 DrmSyncobj* (handle at +8), +24 wp_timeline proxy,
                    +32 current point, +40 fence_available, +144 eventfd,
                    +152 OnceCallback
  vtable ELF 0xf60e198; stored vptr = rx + (0xf60e1a8 - 0x2bb0000)
  wl_proxy id at +16

Mutter (stock):
  MetaWaylandBuffer +64 use_count, +72 type, +152 GPtrArray* release_points
  GPtrArray pdata +0, len +8
  MetaWaylandSyncPoint +24 timeline*, +32 sync_point   (ldp at 0x167d54)
  MetaWaylandSyncobjTimeline +24 MetaDrmTimeline*
  MetaDrmTimeline +24 drm fd, +32 drm_syncobj handle   (0xc4560 / 0xc45f0)

Verdict per buffer (solution3.md table):
  same + use==0 + rplen>=1  → signal never sent (sync_fd<0)
  |delta|==1                → off-by-one / increment-before-signal
  rplen==0 and Chrome waiting → mutter cleared or never queued
"""
from __future__ import annotations

import collections
import json
import struct
import time
import urllib.request
from pathlib import Path

VTABLE_TOP = 0xF60E2D8
VTABLE_SCHED = 0xFC6F180
VTABLE_REL_TL = 0xF60E198
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

    def i32(self, a):
        self.f.seek(a)
        b = self.f.read(4)
        return struct.unpack("<i", b)[0] if len(b) == 4 else -1

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


def heap_ranges(pid, limit=256 << 20):
    pref, rest = [], []
    for lo, hi, perm, off, path in maps(pid):
        if "rw" not in perm:
            continue
        if path.startswith("/usr/") or path.startswith("/lib") or ".so" in path:
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


def chrome_release_tl(m: Mem, handle, expect_vptr):
    if not plausible(handle):
        return None
    buf = m.u64(handle + 24)
    wlid = m.u32(buf + 16) if plausible(buf) else -1
    tl = m.u64(handle + 48)
    row = {
        "handle": hex(handle),
        "hid": m.u32(handle + 8),
        "sync": m.u32(handle + 32),
        "wl_buf": hex(buf) if buf else "0",
        "wlid": wlid,
        "tl": hex(tl) if tl else "0",
    }
    if not plausible(tl):
        row["verdict"] = "no_timeline"
        return row
    vptr = m.u64(tl)
    row["vptr_ok"] = vptr == expect_vptr
    dso = m.u64(tl + 16)
    proxy = m.u64(tl + 24)
    row["chrome_point"] = m.u64(tl + 32)
    row["available"] = m.u8(tl + 40)
    row["eventfd"] = m.i32(tl + 144)
    row["cb"] = 1 if m.u64(tl + 152) else 0
    row["chrome_handle"] = m.u32(dso + 8) if plausible(dso) else -1
    row["tl_proto"] = m.u32(proxy + 16) if plausible(proxy) else -1
    return row


def map_entries(m: Mem, fr, expect_vptr):
    b0, b1 = m.u64(fr + 512), m.u64(fr + 520)
    if not b0 or not b1 or b1 < b0:
        return []
    n = (b1 - b0) // 16
    if n > 8:
        return []
    rows = []
    for i in range(n):
        handle = m.u64(b0 + i * 16 + 8)
        row = chrome_release_tl(m, handle, expect_vptr) or {}
        row["surf"] = hex(m.u64(b0 + i * 16))
        rows.append(row)
    return rows


def frame_row(m: Mem, fr, expect_vptr):
    if not plausible(fr):
        return None
    return {
        "fr": hex(fr),
        "id": m.u32(fr),
        "ack": m.u8(fr + 568) & 1,
        "fb": m.u8(fr + 656) & 1,
        "mapn": max(0, (m.u64(fr + 520) - m.u64(fr + 512)) // 16)
        if m.u64(fr + 520) >= m.u64(fr + 512)
        else -1,
        "bufs": map_entries(m, fr, expect_vptr),
    }


def mutter_points(m: Mem, rp):
    if not plausible(rp):
        return []
    pdata, ln = m.u64(rp), m.u32(rp + 8)
    if ln > 8 or not plausible(pdata):
        return []
    out = []
    for i in range(ln):
        sp = m.u64(pdata + i * 8)
        if not plausible(sp):
            continue
        tl = m.u64(sp + 24)
        point = m.u64(sp + 32)
        drm_tl = m.u64(tl + 24) if plausible(tl) else 0
        out.append(
            {
                "sp": hex(sp),
                "point": point,
                "wl_tl": hex(tl) if tl else "0",
                "mutter_handle": m.u32(drm_tl + 32) if plausible(drm_tl) else -1,
                "drm_fd": m.i32(drm_tl + 24) if plausible(drm_tl) else -1,
            }
        )
    return out


def find_buffers_by_ids(m: Mem, ranges, want_ids):
    """Collect every DMA-BUF candidate; pick per wlid later."""
    want = set(want_ids)
    found = {rid: [] for rid in want}
    for lo, hi in ranges:
        size = hi - lo
        if size > 128 << 20:
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
            pts = mutter_points(m, rp)
            found[rid].append(
                {
                    "buf": hex(lo + i),
                    "klass": hex(k),
                    "use": uc,
                    "rplen": rplen,
                    "points": pts,
                }
            )
    return found


def pick_mutter(cands, chrome_handle, chrome_point):
    if not cands:
        return None
    def score(c):
        pts = [p["point"] for p in c.get("points") or []]
        mh = (c.get("points") or [{}])[0].get("mutter_handle") if c.get("points") else None
        handle_hit = 0 if mh == chrome_handle and chrome_handle not in (None, -1) else 1
        delta = abs(pts[0] - chrome_point) if pts and chrome_point is not None else 10**9
        return (handle_hit, delta, c.get("rplen") == 0, -c.get("use", 0))
    return min(cands, key=score)


def classify(chrome_row, mutter_row):
    cpt = chrome_row.get("chrome_point")
    waiting = chrome_row.get("available") == 0 and (
        chrome_row.get("cb") or (chrome_row.get("eventfd", -1) >= 0)
    )
    if not mutter_row:
        return "mutter_buffer_not_found"
    pts = [p["point"] for p in mutter_row.get("points") or []]
    use = mutter_row.get("use")
    if pts and cpt is not None:
        delta = pts[0] - cpt
        if delta == 0:
            if use == 0:
                return "same_point_unsignaled"
            return "same_point_still_in_use"
        if abs(delta) == 1:
            return "off_by_one"
        return f"mismatch_delta_{delta}"
    if not pts and waiting:
        return "mutter_empty_chrome_waiting"
    if not pts:
        return "mutter_empty"
    return "no_chrome_point"


def attach_mutter(frames, found):
    pairs = []
    for fr in frames or []:
        if not fr:
            continue
        for b in fr.get("bufs") or []:
            cands = found.get(b.get("wlid")) or []
            mid = pick_mutter(cands, b.get("chrome_handle"), b.get("chrome_point"))
            b["mutter"] = mid
            b["n_cands"] = len(cands)
            b["verdict"] = classify(b, mid)
            pairs.append(
                {
                    "wlid": b.get("wlid"),
                    "tl_proto": b.get("tl_proto"),
                    "chrome_point": b.get("chrome_point"),
                    "available": b.get("available"),
                    "eventfd": b.get("eventfd"),
                    "cb": b.get("cb"),
                    "chrome_handle": b.get("chrome_handle"),
                    "n_cands": len(cands),
                    "use": None if not mid else mid.get("use"),
                    "rplen": None if not mid else mid.get("rplen"),
                    "mutter_points": None if not mid else [p["point"] for p in mid.get("points") or []],
                    "mutter_handle": None
                    if not mid or not mid.get("points")
                    else mid["points"][0].get("mutter_handle"),
                    "verdict": b["verdict"],
                    "fb": fr.get("fb"),
                    "ack": fr.get("ack"),
                }
            )
    return pairs


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
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "span": round(span, 3),
    }


def snapshot(cm, sm, fm, sh_rs, expect_vptr):
    _, frames = deque_n(cm, fm + 40) if fm else (0, [])
    rows = [frame_row(cm, a, expect_vptr) for a in frames[:6]]
    ids = []
    for r in rows:
        if not r:
            continue
        for b in r.get("bufs") or []:
            if b.get("wlid") and b["wlid"] > 0:
                ids.append(b["wlid"])
    found = find_buffers_by_ids(sm, sh_rs, ids) if ids else {}
    pairs = attach_mutter(rows, found)
    return {"frames": rows, "pairs": pairs, "wlids": ids}


def main():
    shell, chrome, gpu = find_pids()
    out = {"pids": {"shell": shell, "chrome": chrome, "gpu": gpu}}
    if not (chrome and gpu and shell):
        print(json.dumps(out, indent=2))
        return
    cm, gm, sm = Mem(chrome), Mem(gpu), Mem(shell)
    chrome_rx = rx_chrome(chrome)
    gpu_rx = rx_chrome(gpu)
    expect_vptr = chrome_rx + (VTABLE_REL_TL + 16 - LOAD_VADDR)
    out["rx"] = {"chrome": hex(chrome_rx), "gpu": hex(gpu_rx)}
    out["expect_rel_vptr"] = hex(expect_vptr)
    chrome_rs = heap_ranges(chrome)
    gpu_rs = heap_ranges(gpu)
    sh_rs = heap_ranges(shell)
    win, fm = find_window(cm, chrome_rx, chrome_rs)
    sched = find_sched(gm, gpu_rx, gpu_rs)
    out["win"] = hex(win)
    out["fm"] = hex(fm)
    out["sched"] = hex(sched)
    out["lab0"] = dump_lab()
    out["t0"] = snapshot(cm, sm, fm, sh_rs, expect_vptr)

    holes = []
    last_swap = None
    t0 = time.monotonic()
    arm_trace()
    while time.monotonic() - t0 < 8.0:
        swap = gp = -1
        if sched:
            swap = gm.u32(sched + 600)
            gp = gm.u32(sched + 604)
        if last_swap is not None and swap == last_swap and gp >= 2 and len(holes) < 4:
            rec = snapshot(cm, sm, fm, sh_rs, expect_vptr)
            rec["gpu_pend"] = gp
            holes.append(rec)
        last_swap = swap
        time.sleep(0.004)
    out["holes"] = holes
    out["kickoff"] = read_kickoff()
    out["lab1"] = dump_lab()
    t0_counts = collections.Counter(p.get("verdict") or "?" for p in out["t0"].get("pairs") or [])
    hole_counts = collections.Counter()
    for h in holes:
        for p in h.get("pairs") or []:
            hole_counts[p.get("verdict") or "?"] += 1
    out["verdict_t0"] = t0_counts.most_common()
    out["verdict_holes"] = hole_counts.most_common()
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
