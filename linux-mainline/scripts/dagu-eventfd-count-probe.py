#!/usr/bin/env python3
"""Hole-only eventfd-count on Chrome's SyncobjEventfd fd.

WaylandSyncobjReleaseTimeline +144 is the eventfd passed to
DrmSyncobjIoctlWrapper::SyncobjEventfd (ELF 0x3548e38 w3, Create at
0x3548ddc). OnFileCanRead (0x3548b94) sets available_ (+40) THEN read(8).

Only records wait0=ok && available_=0. Stops after 3 count==0 or 3 count>=1.
No 8ms hammer.
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
SYS_PIDFD_OPEN = 434
SYS_PIDFD_GETFD = 438
ETIME = 62
WAIT_AVAILABLE = 1 << 2


def _iowr(nr, size):
    return (3 << 30) | (ord("d") << 8) | nr | (size << 16)


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
    chrome = gpu = 0
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
    return chrome, gpu


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
    if cap == 0 or cap > 64 or begin > cap or end > cap or end == begin:
        return 0, []
    n = end - begin if end > begin else (end - begin) % cap
    addrs = []
    if n and n <= 16 and plausible(data):
        i = begin
        for _ in range(n):
            addrs.append(m.u64(data + i * 8))
            i = (i + 1) % cap
    return n, addrs


def find_window(m, rx, ranges):
    live_vt = rx + (VTABLE_TOP - LOAD_VADDR) + 16
    needle = struct.pack("<Q", live_vt)
    for lo, hi in ranges:
        if hi - lo > 48 << 20:
            continue
        try:
            blob = m.bytes(lo, hi - lo)
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


def find_sched(m, gpu_rx, ranges):
    live_vt = gpu_rx + (VTABLE_SCHED - LOAD_VADDR) + 16
    needle = struct.pack("<Q", live_vt)
    for lo, hi in ranges:
        if hi - lo > 48 << 20:
            continue
        try:
            blob = m.bytes(lo, hi - lo)
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


def chrome_bufs(m, fm, expect_vptr):
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
                "wlid": m.u32(buf + 16) if plausible(buf) else -1,
                "h": m.u32(dso + 8) if plausible(dso) else -1,
                "pt": m.u64(tl + 32),
                "avail": m.u8(tl + 40),
                "cb": 1 if m.u64(tl + 152) else 0,
                "efd": m.i32(tl + 144),
                "fb": m.u8(fr + 656) & 1,
            }
        )
    return out


def dri_fds(pid):
    hits = []
    for p in Path(f"/proc/{pid}/fd").iterdir():
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
        return os.open(f"/proc/{pid}/fd/{target_fd}", os.O_RDWR | os.O_CLOEXEC), f"proc:{e.errno}"


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
    t0 = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    rc = libc.ioctl(fd, IOCTL_TL_WAIT, ctypes.byref(req))
    t1 = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    err = 0 if rc == 0 else (ctypes.get_errno() or errno.EIO)
    return enc(err), err, (t1 - t0) / 1e6


def pick_drm_fd(chrome_pid, h, pt):
    for n, tgt in dri_fds(chrome_pid):
        fd, how = dup_pid_fd(chrome_pid, n)
        st, _, _ = tl_wait(fd, h, pt, 0, 0)
        if st in ("ok", "etime", "e22"):
            return fd, {"n": n, "tgt": tgt, "how": how, "probe": st}
        os.close(fd)
    return -1, {}


def fdinfo_eventfd(pid, efd):
    path = f"/proc/{pid}/fd/{efd}"
    info_path = f"/proc/{pid}/fdinfo/{efd}"
    try:
        tgt = os.readlink(path)
    except OSError as e:
        return {"efd": efd, "err": f"readlink:{e.errno}"}
    rec = {"efd": efd, "tgt": tgt}
    try:
        text = Path(info_path).read_text()
    except OSError as e:
        rec["err"] = f"fdinfo:{e.errno}"
        return rec
    rec["fdinfo"] = text.strip()
    for line in text.splitlines():
        if line.startswith("eventfd-count:"):
            rec["count"] = int(line.split(":", 1)[1].strip(), 16)
        if line.startswith("pos:"):
            rec["pos"] = line.split(":", 1)[1].strip()
        if line.startswith("flags:"):
            rec["flags"] = line.split(":", 1)[1].strip()
    return rec


def comms(pid):
    out = {}
    tdir = Path(f"/proc/{pid}/task")
    for t in tdir.iterdir():
        try:
            out[int(t.name)] = (t / "comm").read_text().strip()
        except OSError:
            continue
    return out


def wchan(pid, tid):
    try:
        return Path(f"/proc/{pid}/task/{tid}/wchan").read_text().strip()
    except OSError:
        return ""


def epoll_owners(pid, efd):
    hits = []
    names = comms(pid)
    tdir = Path(f"/proc/{pid}/task")
    for t in tdir.iterdir():
        tid = int(t.name)
        fdinfo = t / "fdinfo"
        if not fdinfo.is_dir():
            continue
        for f in fdinfo.iterdir():
            try:
                text = f.read_text()
            except OSError:
                continue
            if "tfd:" not in text:
                continue
            for line in text.splitlines():
                if "tfd:" not in line:
                    continue
                parts = line.split()
                nums = [p for p in parts if p.startswith("tfd:")]
                if not nums:
                    continue
                try:
                    tfd = int(nums[0].split(":")[1])
                except ValueError:
                    continue
                if tfd == efd:
                    hits.append(
                        {
                            "tid": tid,
                            "comm": names.get(tid, ""),
                            "epollfd": int(f.name),
                            "line": line.strip(),
                            "wchan": wchan(pid, tid),
                        }
                    )
    return hits


def dump_lab():
    d = json.loads(urllib.request.urlopen("http://127.0.0.1:8770/api/dump", timeout=3).read())
    h = d.get("host") or d.get("hw") or {}
    return {
        "fps": d.get("fps"),
        "p50": d.get("p50"),
        "p99": d.get("p99"),
        "max": d.get("max"),
        "video14_open": h.get("video14_open"),
        "gpu_busy": h.get("gpu_busy"),
    }


def main():
    chrome, gpu = find_pids()
    out = {"pids": {"chrome": chrome, "gpu": gpu}}
    if not (chrome and gpu):
        print(json.dumps(out, indent=2))
        return
    cm, gm = Mem(chrome), Mem(gpu)
    crx, grx = rx_chrome(chrome), rx_chrome(gpu)
    expect = crx + (VTABLE_REL_TL + 16 - LOAD_VADDR)
    win, fm = find_window(cm, crx, heap_ranges(chrome))
    sched = find_sched(gm, grx, heap_ranges(gpu))
    out["fm"] = hex(fm)
    out["lab0"] = dump_lab()
    bufs0 = chrome_bufs(cm, fm, expect)
    if not bufs0:
        print(json.dumps(out, indent=2))
        return
    drm, meta = pick_drm_fd(chrome, bufs0[0]["h"], bufs0[0]["pt"])
    out["drm"] = meta
    if drm < 0:
        print(json.dumps(out, indent=2))
        return

    hits = []
    n0 = n1 = 0
    block = None
    last_swap = None
    t_end = time.monotonic() + 18.0
    while time.monotonic() < t_end and n0 < 3 and n1 < 3:
        gp = swap = -1
        if sched:
            swap = gm.u32(sched + 600)
            gp = gm.u32(sched + 604)
        stall = last_swap is not None and swap == last_swap and gp >= 2
        last_swap = swap
        if not stall and gp < 2:
            time.sleep(0.02)
            continue
        for b in chrome_bufs(cm, fm, expect):
            if b["avail"] != 0 or b["cb"] != 1 or b["efd"] < 0 or b["h"] < 0:
                continue
            t_poll = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
            w0, e0, ms0 = tl_wait(drm, b["h"], b["pt"], 0, 0)
            w4, e4, ms4 = tl_wait(drm, b["h"], b["pt"], WAIT_AVAILABLE, 0)
            if w0 != "ok":
                continue
            info = fdinfo_eventfd(chrome, b["efd"])
            cnt = info.get("count")
            rec = {
                "t": t_poll / 1e9,
                "gp": gp,
                "stall": int(stall),
                "wlid": b["wlid"],
                "h": b["h"],
                "pt": b["pt"],
                "avail": b["avail"],
                "cb": b["cb"],
                "fb": b["fb"],
                "efd": b["efd"],
                "wait0": w0,
                "wait0_ms": round(ms0, 3),
                "wait4": w4,
                "wait4_ms": round(ms4, 3),
                "count": cnt,
                "tgt": info.get("tgt"),
                "fdinfo": info.get("fdinfo"),
            }
            if block is None:
                tmo = t_poll + 200_000_000
                st, err, ms = tl_wait(drm, b["h"], b["pt"], 0, tmo)
                rec["block"] = {
                    "st": st,
                    "errno": err,
                    "ms": round(ms, 3),
                    "same_h_pt": True,
                    "gap_after_wait0_us": 0,
                }
                block = rec["block"]
            hits.append(rec)
            if cnt == 0:
                n0 += 1
            elif cnt is not None and cnt >= 1:
                n1 += 1
            if n0 >= 3 or n1 >= 3:
                break
        time.sleep(0.02)

    os.close(drm)
    out["lab1"] = dump_lab()
    out["hits"] = hits
    out["n0"] = n0
    out["n1"] = n1
    out["counts"] = collections.Counter(
        ("none" if h.get("count") is None else str(h.get("count"))) for h in hits
    ).most_common()
    if hits:
        efd = hits[0]["efd"]
        if n1 and not n0:
            out["epoll"] = epoll_owners(chrome, efd)
            out["verdict"] = "kernel_wrote_chrome_unread"
        elif n0 and not n1:
            out["verdict"] = "kernel_never_wrote"
        elif n0 and n1:
            out["verdict"] = "mixed_0_and_1"
        else:
            out["verdict"] = "no_count"
    else:
        out["verdict"] = "no_signaled_asleep_window"
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
