#!/usr/bin/env python3
"""ifn-idle: at add_unix_fd, poll(sync_fd) vs FILE_INFO on the same dup.

Never hook 0x1c4388 / 0x1c4404 / cave / 0x18ff40 / 0x84e0.
Never open dri/0/gpu.
Hooks: nview 0x1c4440, hasnext 0x1c4398, addfd 0x18fe3c, disp 0x16e70c.
"""
from __future__ import annotations

import ctypes
import fcntl
import json
import os
import select
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
        elif cmd.startswith(b"python") and b"dagu-native-lab.py" in cmd:
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


def parse_u64_pair(line, key):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0].rstrip(",")
    if ":" not in v:
        return None
    a, b = v.split(":", 1)
    try:
        return int(a), int(b)
    except ValueError:
        return None


def steal_fd(pid, n):
    libc = ctypes.CDLL(None, use_errno=True)
    pidfd = libc.syscall(434, ctypes.c_int(pid), ctypes.c_uint(0))
    if pidfd < 0:
        return None
    got = libc.syscall(438, ctypes.c_int(pidfd), ctypes.c_int(n), ctypes.c_uint(0))
    os.close(pidfd)
    return got if got >= 0 else None


def sync_file_info(fd):
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
    inf = Info()
    try:
        fcntl.ioctl(fd, IOC, inf)
    except OSError:
        return {"err": "ioctl0"}
    nfen = inf.num_fences
    fences = []
    if nfen:
        arr = (Fence * min(nfen, 4))()
        inf2 = Info()
        inf2.num_fences = min(nfen, 4)
        inf2.sync_fence_info = ctypes.addressof(arr)
        try:
            fcntl.ioctl(fd, IOC, inf2)
        except OSError:
            return {"err": "ioctl1", "n": nfen, "status": inf.status}
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


def snap_fd(pid, n):
    fd = steal_fd(pid, n)
    if fd is None:
        return {"err": "steal"}
    try:
        try:
            pr, pw, pe = select.select([fd], [], [fd], 0)
            poll_in = bool(pr)
            poll_err = bool(pe)
        except OSError as e:
            poll_in = poll_err = None
            poll_err = str(e.errno)
        sfi = sync_file_info(fd)
        try:
            name = os.readlink(f"/proc/self/fd/{fd}")
        except OSError:
            name = None
        return {"poll_in": poll_in, "poll_err": poll_err, "sfi": sfi, "link": name}
    finally:
        os.close(fd)


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def last_before(recs, t0):
    last = None
    for r in recs:
        if r["t"] < t0:
            last = r
        else:
            break
    if last is None:
        return None
    out = {k: v for k, v in last.items() if k != "t"}
    out["dt"] = round((last["t"] - t0) * 1000.0, 2)
    return out


def first_rec(recs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for r in recs:
        if lo <= r["t"] <= hi:
            out = {k: v for k, v in r.items() if k != "t"}
            out["dt"] = round((r["t"] - t0) * 1000.0, 2)
            return out
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


def ev_enable(path, on):
    p = TR / "events" / path / "enable"
    if p.is_file():
        p.write_text("1\n" if on else "0\n")


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
        os.write(fd, f"p:dagu_hasnext {mu}:0x1c4398\n".encode())
        os.write(fd, f"p:dagu_addfd {mu}:0x18fe3c fd=%x1\n".encode())
        os.write(fd, f"p:dagu_disp {mu}:0x16e70c\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    ev_enable("gpu_scheduler/drm_sched_job_done", True)


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    ev_enable("gpu_scheduler/drm_sched_job_done", False)
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds=12.0):
    shell, lab = find_pids()
    install(shell)
    kick, nview, hasnext, disp = [], [], [], []
    addfd, done = [], []
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
                elif "dagu_nview:" in line and pid == shell:
                    nview.append(ts)
                elif "dagu_hasnext:" in line and pid == shell:
                    hasnext.append(ts)
                elif "dagu_disp:" in line and pid == shell:
                    disp.append(ts)
                elif "dagu_addfd:" in line and pid == shell:
                    fdn = parse_hex_field(line, "fd")
                    if fdn is not None:
                        fdn = fdn & 0xFFFFFFFF
                        if fdn >= 0x80000000:
                            fdn -= 0x100000000
                    snap = snap_fd(shell, fdn) if fdn is not None and fdn >= 0 else {"err": "fd"}
                    addfd.append({"t": ts, "fd": fdn, **snap})
                elif "drm_sched_job_done:" in line:
                    pair = parse_u64_pair(line, "fence")
                    done.append({
                        "t": ts,
                        "ctx": pair[0] if pair else None,
                        "seq": pair[1] if pair else None,
                    })
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        nv = first_after(nview, a, 0, gap + 1)
        hn = first_after(hasnext, a, 0, 20)
        kind = "nview-late" if nv is None or nv > 20 else ("hasnext" if hn is not None else "ifn-idle")
        prev = last_before(addfd, a)
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": nv,
            "hasnext": hn,
            "disp": first_after(disp, a, 0, 280),
            "prev_addfd": prev,
            "done_after": first_rec(done, a, 0, 280),
            "done_before": last_before(done, a),
        })

    def bucket(rows):
        c = Counter()
        for r in rows:
            sfi = r.get("sfi") or {}
            st = sfi.get("status") if isinstance(sfi, dict) else None
            pin = r.get("poll_in")
            if r.get("err"):
                c["steal-fail"] += 1
            elif st is None:
                c["no-sfi"] += 1
            else:
                c[f"st{st}_poll{int(bool(pin))}"] += 1
        return dict(c)

    hole_add = [h["prev_addfd"] for h in holes if h.get("prev_addfd")]
    out = {
        "kind": "syncfd-poll",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_addfd": len(addfd),
        "n_disp": len(disp),
        "n_nview": len(nview),
        "n_hasnext": len(hasnext),
        "n_done": len(done),
        "addfd_bucket": bucket(addfd),
        "hole_bucket": bucket(hole_add),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes,
    }
    Path("/tmp/dagu-syncfd-poll.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-syncfd-poll-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-syncfd-poll-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-syncfd-poll-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-syncfd-poll.json", str(dest)], check=False)
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
    if "--host" in sys.argv or os.environ.get("DAGU_SSH_HOST"):
        if Path("/proc/1/comm").read_text().strip() != "systemd" or Path("/sys/kernel/debug/tracing/tracing_on").exists() and os.uname().machine == "aarch64" and Path("/usr/bin/gnome-shell").exists():
            # on device
            return on_device(seconds)
    if "--host" in sys.argv:
        return host_main()
    return on_device(seconds)


if __name__ == "__main__":
    if "--host" in sys.argv:
        raise SystemExit(host_main())
    raise SystemExit(main())
