#!/usr/bin/env python3
"""ifn-idle: implicit dma-buf poll vs DmaBuf readiness GSource.

Never hook 0x1c4404 / cave / 0x84e0.
Explicit drmSyncobjEventfd (0x18faac) is unused on this lab path.
Hook implicit g_poll at 0x18fdbc, source new at 0x18ff40, attach at
0x18fe78, dispatch at 0x16e70c.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")


def ssh_base():
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_pids():
    shell = lab = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell") and b"--mode=ubuntu" in cmd:
            shell = int(p.name)
        elif cmd.startswith(b"python") and b"dagu-native-lab.py" in cmd and b"--video" in cmd:
            lab = int(p.name)
    if shell is None or lab is None:
        raise SystemExit(json.dumps({"err": "need ubuntu+lab", "shell": shell, "lab": lab}))
    return shell, lab


def map_rx(pid, needle):
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        rng = line.split()[0]
        mf = f"/proc/{pid}/map_files/{rng}"
        if Path(mf).exists():
            return mf
    raise SystemExit(f"no r-xp {needle} pid={pid}")


def parse_pid(line):
    tok = line.lstrip().split()[0] if line.strip() else ""
    if "-" not in tok:
        return None
    try:
        return int(tok.rsplit("-", 1)[1])
    except ValueError:
        return None


def parse_ts(line):
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def parse_hex_field(line, key):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0]
    try:
        return int(v, 16)
    except ValueError:
        return None


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def first_pair(pairs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for t, extra in pairs:
        if lo <= t <= hi:
            return {"dt": round((t - t0) * 1000.0, 2), **extra}
    return None


def summary(xs):
    gaps = [1000.0 * (b - a) for a, b in zip(xs, xs[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (xs[-1] - xs[0]) if len(xs) > 1 else 0
    return {
        "n": len(xs),
        "hz": round(len(xs) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
    }


def install(shell):
    (TR / "tracing_on").write_text("0\n")
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        time.sleep(0.05)
        (TR / "uprobe_events").write_text("")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_ipoll {mu}:0x18fdbc n=%x0 fd=%x14\n".encode())
        os.write(fd, f"p:dagu_addfd {mu}:0x18fe3c fd=%x1\n".encode())
        os.write(fd, f"p:dagu_srcnew {mu}:0x18ff40 src=%x0\n".encode())
        os.write(fd, f"p:dagu_attach {mu}:0x18fe78 src=%x0\n".encode())
        os.write(fd, f"p:dagu_disp {mu}:0x16e70c src=%x0\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "tracing_on").write_text("1\n")


def fd_name(pid, n):
    try:
        return os.readlink(f"/proc/{pid}/fd/{n}")
    except OSError:
        return None


class _SyncFileInfo:
    pass


def sync_file_info(pid, n):
    """SYNC_IOC_FILE_INFO on /proc/<pid>/fd/<n>. None if gone."""
    import ctypes
    import fcntl

    class Info(ctypes.Structure):
        _fields_ = [
            ("name", ctypes.c_char * 32),
            ("status", ctypes.c_int32),
            ("flags", ctypes.c_uint32),
            ("num_fences", ctypes.c_uint32),
            ("pad", ctypes.c_uint32),
            ("sync_fence_info", ctypes.c_uint64),
        ]

    class Fence(ctypes.Structure):
        _fields_ = [
            ("obj_name", ctypes.c_char * 32),
            ("driver_name", ctypes.c_char * 32),
            ("status", ctypes.c_int32),
            ("flags", ctypes.c_uint32),
            ("timestamp_ns", ctypes.c_uint64),
        ]

    IOC = 0xC0383E04
    fd = None
    libc = ctypes.CDLL(None, use_errno=True)
    # aarch64: pidfd_open=434 pidfd_getfd=438
    pidfd = libc.syscall(434, ctypes.c_int(pid), ctypes.c_uint(0))
    if pidfd >= 0:
        got = libc.syscall(438, ctypes.c_int(pidfd), ctypes.c_int(n), ctypes.c_uint(0))
        os.close(pidfd)
        if got >= 0:
            fd = got
    if fd is None:
        try:
            fd = os.open(f"/proc/{pid}/fd/{n}", os.O_RDWR)
        except OSError:
            return None
    try:
        inf = Info()
        try:
            fcntl.ioctl(fd, IOC, inf)
        except OSError:
            return {"err": "ioctl0"}
        nfen = inf.num_fences
        fences = []
        if nfen:
            arr = (Fence * min(nfen, 8))()
            inf2 = Info()
            inf2.num_fences = min(nfen, 8)
            inf2.sync_fence_info = ctypes.addressof(arr)
            try:
                fcntl.ioctl(fd, IOC, inf2)
            except OSError:
                return {
                    "name": inf.name.split(b"\x00", 1)[0].decode("ascii", "replace"),
                    "status": inf.status,
                    "n": nfen,
                    "err": "ioctl1",
                }
            for i in range(inf2.num_fences):
                f = arr[i]
                fences.append({
                    "obj": f.obj_name.split(b"\x00", 1)[0].decode("ascii", "replace"),
                    "drv": f.driver_name.split(b"\x00", 1)[0].decode("ascii", "replace"),
                    "st": f.status,
                })
        return {
            "name": inf.name.split(b"\x00", 1)[0].decode("ascii", "replace"),
            "status": inf.status,
            "n": nfen,
            "fences": fences,
        }
    finally:
        os.close(fd)


def on_device(seconds=12.0):
    shell, lab = find_pids()
    install(shell)
    kick, nview, ifn, add = [], [], [], []
    ipoll, srcnew, attach, disp, addfd = [], [], [], [], []
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
            try:
                chunk = pipe.read(65536)
            except BlockingIOError:
                time.sleep(0.001)
                continue
            if not chunk:
                time.sleep(0.001)
                continue
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                ts = parse_ts(line)
                if ts is None:
                    continue
                pid = parse_pid(line)
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                elif pid != shell:
                    continue
                elif "dagu_nview:" in line:
                    nview.append(ts)
                elif "dagu_ifnchk:" in line:
                    if parse_hex_field(line, "next") == 0:
                        ifn.append(ts)
                elif "dagu_add:" in line:
                    add.append(ts)
                elif "dagu_ipoll:" in line:
                    ipoll.append((ts, {
                        "n": parse_hex_field(line, "n"),
                        "fd": parse_hex_field(line, "fd"),
                    }))
                elif "dagu_addfd:" in line:
                    fdn = parse_hex_field(line, "fd")
                    if fdn is not None:
                        fdn = fdn & 0xFFFFFFFF
                        if fdn >= 0x80000000:
                            fdn -= 0x100000000
                    info = None
                    name = None
                    if fdn is not None and fdn >= 0:
                        name = fd_name(shell, fdn)
                        info = sync_file_info(shell, fdn)
                    addfd.append((ts, {
                        "fd": fdn,
                        "name": name,
                        "sfi": info,
                    }))
                elif "dagu_srcnew:" in line:
                    srcnew.append(ts)
                elif "dagu_attach:" in line:
                    attach.append(ts)
                elif "dagu_disp:" in line:
                    src = parse_hex_field(line, "src")
                    extra = {"src": src, "fds": [], "names": [], "tags": 0}
                    raw = b"\xff" * 16
                    if src:
                        src = src & 0x00FFFFFFFFFFFFFF
                        extra["src"] = src
                        mem = os.open(f"/proc/{shell}/mem", os.O_RDONLY)
                        try:
                            os.lseek(mem, src + 0x78, os.SEEK_SET)
                            tags = os.read(mem, 32)
                            os.lseek(mem, src + 0x98, os.SEEK_SET)
                            raw = os.read(mem, 16)
                            os.lseek(mem, src + 0x68, os.SEEK_SET)
                            bufp = int.from_bytes(os.read(mem, 8), "little")
                            extra["tags"] = sum(
                                1 for i in range(4)
                                if int.from_bytes(tags[i * 8:(i + 1) * 8], "little") != 0
                            )
                            implicit = []
                            bufp = bufp & 0x00FFFFFFFFFFFFFF
                            if bufp:
                                os.lseek(mem, bufp + 104, os.SEEK_SET)
                                inner = int.from_bytes(os.read(mem, 8), "little")
                                inner = inner & 0x00FFFFFFFFFFFFFF
                                if inner:
                                    os.lseek(mem, inner + 0x3c, os.SEEK_SET)
                                    iraw = os.read(mem, 16)
                                    implicit = [
                                        int.from_bytes(iraw[i * 4:(i + 1) * 4], "little", signed=True)
                                        for i in range(4)
                                    ]
                            extra["implicit"] = implicit
                        except OSError:
                            extra["read_err"] = 1
                        finally:
                            os.close(mem)
                        for i in range(4):
                            fdn = int.from_bytes(raw[i * 4:(i + 1) * 4], "little", signed=True)
                            extra["fds"].append(fdn)
                            extra["names"].append(fd_name(shell, fdn) if fdn >= 0 else None)
                            if fdn < 0 and extra.get("implicit"):
                                ifd = extra["implicit"][i]
                                if ifd >= 0:
                                    extra["names"][-1] = fd_name(shell, ifd)
                    disp.append((ts, extra))
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n_dt = first_after(nview, a, 0, 20)
        ifn_dt = first_after(ifn, a, 0, 20)
        kind = (
            "ifn-idle" if n_dt is not None and ifn_dt is not None
            else "nview-ok" if n_dt is not None
            else "nview-late"
        )
        prev_att = None
        for t in reversed(attach):
            if t <= a:
                prev_att = t
                break
        disp_hit = first_pair(disp, a, 0, 280)
        wait_ms = None
        if prev_att is not None and disp_hit is not None:
            wait_ms = round((a + disp_hit["dt"] / 1000.0 - prev_att) * 1000.0, 2)
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add": first_after(add, a, 0, 280),
            "ipoll": first_pair(ipoll, a, 0, 280),
            "srcnew": first_after(srcnew, a, 0, 280),
            "attach": first_after(attach, a, 0, 280),
            "addfd": first_pair(addfd, a, -280, 20),
            "prev_attach": round((a - prev_att) * 1000.0, 2) if prev_att is not None else None,
            "wait_ms": wait_ms,
            "disp": disp_hit,
        })

    waits = []
    di = 0
    for t in attach:
        while di < len(disp) and disp[di][0] < t:
            di += 1
        if di < len(disp):
            waits.append((disp[di][0] - t) * 1000.0)
            di += 1
    def bucket(ms):
        if ms < 2:
            return "<2"
        if ms < 8:
            return "2-8"
        if ms < 16:
            return "8-16"
        if ms < 50:
            return "16-50"
        if ms < 80:
            return "50-80"
        if ms < 120:
            return "80-120"
        return ">=120"

    out = {
        "kind": "dmabuf-ready",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_ipoll": len(ipoll),
        "n_srcnew": len(srcnew),
        "n_attach": len(attach),
        "n_disp": len(disp),
        "ipoll_n": dict(Counter(p[1]["n"] for p in ipoll)),
        "ipoll_n0": sum(1 for _, p in ipoll if p["n"] == 0),
        "n_addfd": len(addfd),
        "addfd_names": dict(Counter(p[1]["name"] or "?" for p in addfd)),
        "wait_n": len(waits),
        "wait_buckets": dict(Counter(bucket(w) for w in waits)),
        "wait_gt50": sum(1 for w in waits if w > 50),
        "wait_max": round(max(waits), 1) if waits else None,
        "wait_p50": round(sorted(waits)[len(waits)//2], 2) if waits else None,
        "sfi_drv": dict(Counter(
            f["drv"]
            for _, extra in addfd
            for f in (extra.get("sfi") or {}).get("fences") or []
        )),
        "sfi_obj": dict(Counter(
            f["obj"]
            for _, extra in addfd
            for f in (extra.get("sfi") or {}).get("fences") or []
        )),
        "sfi_err": dict(Counter(
            (extra.get("sfi") or {}).get("err") or "ok"
            for _, extra in addfd
        )),
        "long_sfi": [
            {
                "wait": round(waits[i], 1),
                "sfi": addfd[i][1].get("sfi") if i < len(addfd) else None,
                "name": addfd[i][1].get("name") if i < len(addfd) else None,
            }
            for i, w in enumerate(waits) if w > 50
        ][:8],
        "fd_names": dict(Counter(
            n for _, extra in disp for n in extra.get("names", []) if n
        )),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-dmabuf-ready.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main():
    extra = [a for a in sys.argv[1:] if a != "--host"]
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-dmabuf-ready-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-dmabuf-ready-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-dmabuf-ready-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-dmabuf-ready.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main():
    args = [a for a in sys.argv[1:] if a != "--host"]
    seconds = 12.0
    if args:
        try:
            seconds = float(args[0])
        except ValueError:
            pass
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device(seconds)


if __name__ == "__main__":
    raise SystemExit(main())
