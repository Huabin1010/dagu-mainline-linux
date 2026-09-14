#!/usr/bin/env python3
"""Zero-timeout TIMELINE_WAIT on Chrome's (handle, point).

Binary question: is the fence signaled, or did delivery drop?

Does not poke Chrome / Mutter. Dup Chrome's /dev/dri/renderD128 via
pidfd_getfd (fallback: open /proc/<pid>/fd/N), then ctypes ioctl.

Primary: DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT flags=0 timeout=0
  0 = signaled, ETIME = not signaled
Secondary: flags=WAIT_AVAILABLE (4) — what Chrome SyncobjEventfd actually waits
If signaled (or available) while Chrome available_=0: one blocking wait
on the same (handle, point) to split userspace vs msm.
"""
from __future__ import annotations

import collections
import ctypes
import errno
import json
import os
import struct
import time
import urllib.request
from pathlib import Path

VTABLE_TOP = 0xF60E2D8
VTABLE_SCHED = 0xFC6F180
VTABLE_REL_TL = 0xF60E198
LOAD_VADDR = 0x2BB0000
TR = Path("/sys/kernel/debug/tracing")

SYS_PIDFD_OPEN = 434
SYS_PIDFD_GETFD = 438
ETIME = 62
WAIT_AVAILABLE = 1 << 2


def _ioc(dir_, type_, nr, size):
    return (dir_ << 30) | (type_ << 8) | nr | (size << 16)


def _iowr(nr, size):
    return _ioc(3, ord("d"), nr, size)


class TimelineWait(ctypes.Structure):
    _fields_ = [
        ("handles", ctypes.c_uint64),
        ("points", ctypes.c_uint64),
        ("timeout_nsec", ctypes.c_int64),
        ("count_handles", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("first_signaled", ctypes.c_uint32),
        ("pad", ctypes.c_uint32),
        ("deadline_nsec", ctypes.c_uint64),
    ]


IOCTL_TL_WAIT = _iowr(0xCA, ctypes.sizeof(TimelineWait))


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


def heap_ranges(pid, limit=96 << 20):
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


def chrome_bufs(m: Mem, fm, expect_vptr):
    _, frames = deque_n(m, fm + 40) if fm else (0, [])
    out = []
    for fr in frames[:6]:
        if not plausible(fr):
            continue
        b0, b1 = m.u64(fr + 512), m.u64(fr + 520)
        if not b0 or b1 < b0:
            continue
        n = (b1 - b0) // 16
        if n < 1 or n > 8:
            continue
        handle = m.u64(b0 + 8)
        if not plausible(handle):
            continue
        tl = m.u64(handle + 48)
        if not plausible(tl) or m.u64(tl) != expect_vptr:
            continue
        dso = m.u64(tl + 16)
        buf = m.u64(handle + 24)
        out.append(
            {
                "fr": hex(fr),
                "fid": m.u32(fr),
                "fb": m.u8(fr + 656) & 1,
                "ack": m.u8(fr + 568) & 1,
                "wlid": m.u32(buf + 16) if plausible(buf) else -1,
                "h": m.u32(dso + 8) if plausible(dso) else -1,
                "pt": m.u64(tl + 32),
                "avail": m.u8(tl + 40),
                "cb": 1 if m.u64(tl + 152) else 0,
                "efd": m.i32(tl + 144),
            }
        )
    return out


def dri_fds(pid):
    hits = []
    d = Path(f"/proc/{pid}/fd")
    for p in d.iterdir():
        try:
            tgt = os.readlink(p)
        except OSError:
            continue
        if "/dri/" in tgt:
            hits.append((int(p.name), tgt))
    return hits


def pidfd_getfd(pid, target_fd):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    pfd = libc.syscall(ctypes.c_long(SYS_PIDFD_OPEN), ctypes.c_long(pid), ctypes.c_long(0))
    if pfd < 0:
        raise OSError(ctypes.get_errno() or errno.ENOSYS, "pidfd_open")
    try:
        nfd = libc.syscall(
            ctypes.c_long(SYS_PIDFD_GETFD),
            ctypes.c_long(pfd),
            ctypes.c_long(target_fd),
            ctypes.c_long(0),
        )
    finally:
        os.close(pfd)
    if nfd < 0:
        raise OSError(ctypes.get_errno() or errno.ENOSYS, "pidfd_getfd")
    return int(nfd)


def dup_pid_fd(pid, target_fd):
    try:
        return pidfd_getfd(pid, target_fd), "pidfd_getfd"
    except OSError as e:
        path = f"/proc/{pid}/fd/{target_fd}"
        return os.open(path, os.O_RDWR | os.O_CLOEXEC), f"proc_fd_open:{e.errno}"


def enc(err):
    if err == 0:
        return "ok"
    if err == ETIME:
        return "etime"
    return f"e{err}"


def tl_wait(fd, handle, point, flags, timeout_nsec):
    h = ctypes.c_uint32(handle)
    p = ctypes.c_uint64(point)
    req = TimelineWait(
        handles=ctypes.addressof(h),
        points=ctypes.addressof(p),
        timeout_nsec=timeout_nsec,
        count_handles=1,
        flags=flags,
        first_signaled=0,
        pad=0,
        deadline_nsec=0,
    )
    libc = ctypes.CDLL(None, use_errno=True)
    libc.ioctl.restype = ctypes.c_int
    libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]
    ctypes.set_errno(0)
    rc = libc.ioctl(fd, IOCTL_TL_WAIT, ctypes.byref(req))
    err = 0 if rc == 0 else (ctypes.get_errno() or errno.EIO)
    return enc(err), err


def pick_drm_fd(chrome_pid, sample_handle, sample_point):
    fds = dri_fds(chrome_pid)
    tried = []
    for n, tgt in fds:
        try:
            fd, how = dup_pid_fd(chrome_pid, n)
        except OSError as e:
            tried.append({"n": n, "tgt": tgt, "dup": str(e)})
            continue
        st, err = tl_wait(fd, sample_handle, sample_point, 0, 0)
        tried.append({"n": n, "tgt": tgt, "how": how, "dup_fd": fd, "probe": st, "errno": err})
        if st in ("ok", "etime"):
            return fd, {"chosen": n, "tgt": tgt, "how": how, "tried": tried}
        os.close(fd)
    return -1, {"chosen": None, "tried": tried}


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
        "gpu_busy": h.get("gpu_busy"),
    }


def arm_trace():
    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("8192\n")
    try:
        (TR / "trace_clock").write_text("mono\n")
    except OSError:
        pass
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
    over = [(i, 1000.0 * (ts[i + 1] - ts[i]), ts[i], ts[i + 1]) for i in range(len(ts) - 1) if ts[i + 1] - ts[i] > 0.05]
    span = (ts[-1] - ts[0]) if len(ts) > 1 else 0
    return {
        "n": len(ts),
        "hz": round(len(ts) / span, 2) if span > 0 else 0,
        "max": round(max(gaps), 1) if gaps else None,
        "gt50": len(over),
        "gt50_ms": [round(x[1], 1) for x in sorted(over, key=lambda z: -z[1])[:8]],
        "holes": [{"t0": round(a, 6), "t1": round(b, 6), "ms": round(ms, 1)} for _, ms, a, b in over[:12]],
        "span": round(span, 3),
        "t_first": ts[0] if ts else None,
        "t_last": ts[-1] if ts else None,
    }


def phase_of(t, holes):
    for h in holes:
        t0, t1 = h["t0"], h["t1"]
        if t0 - 0.05 <= t < t0:
            return "pre"
        if t0 <= t <= t1:
            return "mid"
        if t1 < t <= t1 + 0.05:
            return "post"
    return "out"


def classify_series(rows):
    """rows: list of {phase, wait0, wait4, avail, cb} for one (h,pt) in one hole."""
    mid = [r for r in rows if r["phase"] == "mid"]
    post = [r for r in rows if r["phase"] == "post"]
    pre = [r for r in rows if r["phase"] == "pre"]
    use = mid or rows
    w0 = [r["wait0"] for r in use]
    w4 = [r["wait4"] for r in use]
    avail0 = [r["avail"] for r in use]
    if not w0:
        return "no_samples"
    all_etime = all(x == "etime" for x in w0)
    all_ok = all(x == "ok" for x in w0)
    post_ok = bool(post) and post[-1]["wait0"] == "ok"
    chrome_asleep = any(r["avail"] == 0 and r["cb"] == 1 for r in use)
    avail_ok = any(x == "ok" for x in w4)
    if all_etime and post_ok:
        return "signal_late"
    if all_etime:
        if avail_ok and chrome_asleep:
            return "attached_unsignaled_chrome_asleep"
        return "never_signaled"
    if all_ok and chrome_asleep:
        return "signaled_delivery_lost"
    if "ok" in w0 and "etime" in w0 and post_ok:
        return "signal_late"
    if all_ok and all(a == 1 for a in avail0):
        return "signaled_chrome_saw"
    return "mixed"


def main():
    shell, chrome, gpu = find_pids()
    out = {"pids": {"shell": shell, "chrome": chrome, "gpu": gpu}, "ioctl": hex(IOCTL_TL_WAIT)}
    if not (chrome and gpu):
        print(json.dumps(out, indent=2))
        return
    cm, gm = Mem(chrome), Mem(gpu)
    chrome_rx = rx_chrome(chrome)
    gpu_rx = rx_chrome(gpu)
    expect_vptr = chrome_rx + (VTABLE_REL_TL + 16 - LOAD_VADDR)
    win, fm = find_window(cm, chrome_rx, heap_ranges(chrome))
    sched = find_sched(gm, gpu_rx, heap_ranges(gpu))
    out["win"] = hex(win)
    out["fm"] = hex(fm)
    out["sched"] = hex(sched)
    out["lab0"] = dump_lab()
    first = chrome_bufs(cm, fm, expect_vptr)
    out["t0_bufs"] = first
    if not first:
        print(json.dumps(out, indent=2))
        return
    h0, pt0 = first[0]["h"], first[0]["pt"]
    drm, meta = pick_drm_fd(chrome, h0, pt0)
    out["drm"] = meta
    if drm < 0:
        print(json.dumps(out, indent=2))
        return

    samples = []
    block = None
    last_swap = None
    in_stall = False
    t0 = time.clock_gettime(time.CLOCK_MONOTONIC)
    arm_trace()
    while time.clock_gettime(time.CLOCK_MONOTONIC) - t0 < 8.0:
        now = time.clock_gettime(time.CLOCK_MONOTONIC)
        swap = gp = -1
        if sched:
            swap = gm.u32(sched + 600)
            gp = gm.u32(sched + 604)
        stall = last_swap is not None and swap == last_swap and gp >= 2
        last_swap = swap
        bufs = chrome_bufs(cm, fm, expect_vptr)
        row = {"t": round(now, 6), "gp": gp, "stall": int(stall), "b": []}
        for b in bufs:
            w0, _ = tl_wait(drm, b["h"], b["pt"], 0, 0)
            w4, _ = tl_wait(drm, b["h"], b["pt"], WAIT_AVAILABLE, 0)
            rec = {
                "wlid": b["wlid"],
                "h": b["h"],
                "pt": b["pt"],
                "avail": b["avail"],
                "cb": b["cb"],
                "fb": b["fb"],
                "wait0": w0,
                "wait4": w4,
            }
            row["b"].append(rec)
            if (
                block is None
                and w0 == "ok"
                and b["avail"] == 0
                and b["cb"] == 1
            ):
                tmo = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1e9) + 200_000_000
                t_blk = time.clock_gettime(time.CLOCK_MONOTONIC)
                st, err = tl_wait(drm, b["h"], b["pt"], 0, tmo)
                block = {
                    "why": "signaled_chrome_asleep",
                    "h": b["h"],
                    "pt": b["pt"],
                    "wait0_poll": w0,
                    "block": st,
                    "errno": err,
                    "ms": round((time.clock_gettime(time.CLOCK_MONOTONIC) - t_blk) * 1000, 2),
                }
        samples.append(row)
        in_stall = stall
        time.sleep(0.008)

    if block is None:
        waiting = None
        for s in reversed(samples):
            for b in s["b"]:
                if b["avail"] == 0 and b["cb"] == 1:
                    waiting = b
                    break
            if waiting:
                break
        if waiting:
            tmo = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1e9) + 200_000_000
            t_blk = time.clock_gettime(time.CLOCK_MONOTONIC)
            st, err = tl_wait(drm, waiting["h"], waiting["pt"], 0, tmo)
            block = {
                "why": "end_still_waiting",
                "h": waiting["h"],
                "pt": waiting["pt"],
                "wait0_poll": waiting["wait0"],
                "block": st,
                "errno": err,
                "ms": round((time.clock_gettime(time.CLOCK_MONOTONIC) - t_blk) * 1000, 2),
            }

    os.close(drm)
    kick = read_kickoff()
    out["kickoff"] = kick
    out["lab1"] = dump_lab()
    out["n_samples"] = len(samples)
    out["block"] = block

    holes = kick.get("holes") or []
    counts = collections.Counter()
    hole_verdicts = []
    for hi, hole in enumerate(holes):
        by_key = collections.defaultdict(list)
        for s in samples:
            ph = phase_of(s["t"], [hole])
            if ph == "out":
                continue
            for b in s["b"]:
                by_key[(b["h"], b["pt"])].append(
                    {
                        "phase": ph,
                        "wait0": b["wait0"],
                        "wait4": b["wait4"],
                        "avail": b["avail"],
                        "cb": b["cb"],
                    }
                )
        hv = []
        for (h, pt), rows in by_key.items():
            v = classify_series(rows)
            counts[v] += 1
            w0c = collections.Counter(r["wait0"] for r in rows)
            w4c = collections.Counter(r["wait4"] for r in rows)
            hv.append(
                {
                    "h": h,
                    "pt": pt,
                    "verdict": v,
                    "n": len(rows),
                    "wait0": w0c.most_common(),
                    "wait4": w4c.most_common(),
                    "phases": collections.Counter(r["phase"] for r in rows).most_common(),
                }
            )
        hole_verdicts.append({"hole": hole, "keys": hv})

    # whole-run waiting-buffer poll
    wait_rows = [b for s in samples for b in s["b"] if b["avail"] == 0 and b["cb"] == 1]
    out["waiting_poll"] = {
        "n": len(wait_rows),
        "wait0": collections.Counter(b["wait0"] for b in wait_rows).most_common(),
        "wait4": collections.Counter(b["wait4"] for b in wait_rows).most_common(),
    }
    out["hole_verdicts"] = hole_verdicts
    out["verdict_counts"] = counts.most_common()
    # keep a thin sample stripe: first, a mid-hole, last
    keep = []
    if samples:
        keep.append(("first", samples[0]))
        keep.append(("last", samples[-1]))
        for s in samples:
            if s["stall"]:
                keep.append(("stall", s))
                break
    out["stripe"] = keep
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
