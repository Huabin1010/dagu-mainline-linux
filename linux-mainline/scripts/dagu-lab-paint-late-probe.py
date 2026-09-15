#!/usr/bin/env python3
"""After on-time sendcb: if lab paint_idle is late, sample lab syscall/wchan.

§69 117.6: sendcb +8, paint_idle +119. No poke, no ptrace on gnome-shell.
From host: python3 linux-mainline/scripts/dagu-lab-paint-late-probe.py --host
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

SITES = {
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440", "shell"),
    "dagu_ifn": ("libmutter-18.so.0.0.0", "0x1c4404", "shell"),
    "dagu_sendcb": ("libmutter-18.so.0.0.0", "0x1673f0", "shell"),
    "dagu_idle": ("libgtk-4.so.1.2200.4", "0x573a64", "lab"),
}

SYS = {
    "-1": "running",
    "29": "ioctl",
    "63": "read",
    "64": "write",
    "72": "pselect6",
    "73": "ppoll",
    "98": "futex",
    "113": "clock_nanosleep",
}


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


def parse_ts(line):
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def read_sys(tid):
    try:
        raw = Path(f"/proc/{tid}/syscall").read_text().strip()
    except OSError:
        return "gone", None
    if raw == "running":
        return "running", None
    parts = raw.split()
    nr = parts[0]
    a0 = None
    try:
        a0 = int(parts[1], 16)
    except (IndexError, ValueError):
        pass
    return SYS.get(nr, nr), a0


def read_wchan(tid):
    try:
        return Path(f"/proc/{tid}/wchan").read_text().strip() or None
    except OSError:
        return None


def read_stack(tid, limit=6):
    try:
        lines = Path(f"/proc/{tid}/stack").read_text().splitlines()
    except OSError:
        return []
    out = []
    for line in lines[:limit]:
        s = line.strip()
        if s.startswith("["):
            s = s.split("]", 1)[-1].strip()
        if s:
            out.append(s)
    return out


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


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def rel(xs, t0, lo, hi, limit=8):
    return [round((x - t0) * 1000.0, 2) for x in xs if lo <= x <= hi][:limit]


def install(shell, lab):
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
    maps = {
        "shell": map_rx(shell, "libmutter-18.so.0.0.0"),
        "lab": map_rx(lab, "libgtk-4.so.1.2200.4"),
    }
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        for name, (lib, off, who) in SITES.items():
            os.write(fd, f"p:{name} {maps[who]}:{off}\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    return maps


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds=12.0):
    shell, lab = find_pids()
    install(shell, lab)
    kick, nview, ifn, sendcb, idle = [], [], [], [], []
    snaps = []
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    pending = None
    last_send = None
    last_idle = None
    hole_snaps = 0
    sampled = 0
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        next_sample = 0.0
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
            now = time.clock_gettime(time.CLOCK_MONOTONIC)
            try:
                chunk = pipe.read(65536)
            except BlockingIOError:
                chunk = ""
            if chunk:
                buf += chunk
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    ts = parse_ts(line)
                    if ts is None:
                        continue
                    if "dpu_enc_kickoff:" in line:
                        kick.append(ts)
                    elif "dagu_nview:" in line:
                        nview.append(ts)
                    elif "dagu_ifn:" in line:
                        ifn.append(ts)
                    elif "dagu_idle:" in line:
                        idle.append(ts)
                        last_idle = ts
                        pending = None
                    elif "dagu_sendcb:" in line:
                        sendcb.append(ts)
                        last_send = ts
                        if (
                            nview
                            and 0 <= (ts - nview[-1]) * 1000.0 <= 15
                            and sampled < 4
                        ):
                            pending = ts
                            next_sample = now + 0.012
                            hole_snaps = 0
            if pending is not None and now >= next_sample and hole_snaps < 8:
                dt = (now - pending) * 1000.0
                if last_idle is not None and last_idle >= pending:
                    pending = None
                elif dt >= 12:
                    sysn, a0 = read_sys(lab)
                    snaps.append({
                        "dt": round(dt, 2),
                        "sys": sysn,
                        "a0": hex(a0) if isinstance(a0, int) else a0,
                        "wchan": read_wchan(lab),
                        "stack": read_stack(lab),
                    })
                    hole_snaps += 1
                    next_sample = now + 0.012
                    if dt > 140:
                        pending = None
                        sampled += 1
            if not chunk:
                time.sleep(0.0004)
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    clear()
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n = first_after(nview, a, 0, 20)
        s = first_after(sendcb, a, 0, 250)
        i = first_after(idle, a, 0, 250)
        f = first_after(ifn, a, 0, 20)
        early_n = n is not None and n <= 15
        early_s = s is not None and s <= 20
        late_i = i is None or i >= 40
        if early_n and f is not None:
            kind = "ifn-idle"
        elif early_n and early_s and late_i:
            kind = "send-ok-paint-late"
        elif early_n and (s is None or s >= 40):
            kind = "nview-ok-send-late"
        elif n is None or n >= 40:
            kind = "nview-late"
        else:
            kind = "other"
        holes.append({
            "kind": kind,
            "gap_ms": round(gap, 1),
            "nview": n,
            "ifn": f,
            "sendcb": s,
            "idle": i,
            "send_all": rel(sendcb, a, a - 0.004, b + 0.002),
            "idle_all": rel(idle, a, a - 0.004, b + 0.002),
        })
    out = {
        "kind": "lab-paint-late",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_nview": len(nview),
        "n_ifn": len(ifn),
        "n_sendcb": len(sendcb),
        "n_idle": len(idle),
        "n_snaps": len(snaps),
        "sys_snaps": dict(Counter(s.get("sys") for s in snaps)),
        "wchan_snaps": dict(Counter(s.get("wchan") for s in snaps)),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
        "snaps": snaps[:24],
    }
    Path("/tmp/dagu-lab-paint-late.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-lab-paint-late-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-lab-paint-late-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-lab-paint-late-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-lab-paint-late.json", str(dest)], check=False)
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
