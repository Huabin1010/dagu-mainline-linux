#!/usr/bin/env python3
"""During Type B holes, snap MSM ring last/retired/rbbm.

Never hook 0x1c4404 / cave / 0x84e0. Never open hangrd/rd.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")
GPU = Path("/sys/kernel/debug/dri/0/gpu")
BUSY = Path("/sys/class/drm/card0/device/gpu_busy_percent")

RE_LAST = re.compile(r"last-fence:\s*(\d+)")
RE_RET = re.compile(r"retired-fence:\s*(\d+)")
RE_RBBM = re.compile(r"rbbm-status:\s*(\S+)")


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


def gpu_snap():
    fd = os.open(str(GPU), os.O_RDONLY)
    try:
        head = os.read(fd, 512).decode("ascii", "replace")
    finally:
        os.close(fd)
    last = RE_LAST.search(head)
    ret = RE_RET.search(head)
    rbbm = RE_RBBM.search(head)
    busy = None
    try:
        busy = int(BUSY.read_text().strip())
    except (OSError, ValueError):
        pass
    lf = int(last.group(1)) if last else None
    rf = int(ret.group(1)) if ret else None
    return {
        "t": time.clock_gettime(time.CLOCK_MONOTONIC),
        "last": lf,
        "retired": rf,
        "inflight": (lf - rf) if lf is not None and rf is not None else None,
        "rbbm": rbbm.group(1) if rbbm else None,
        "busy": busy,
    }


def lab_dmabufs(lab):
    n = 0
    try:
        for p in Path(f"/proc/{lab}/fd").iterdir():
            try:
                name = os.readlink(p)
            except OSError:
                continue
            if "dmabuf" in name:
                n += 1
    except OSError:
        return None
    return n


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
    (TR / "buffer_size_kb").write_text("8192\n")
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_attach {mu}:0x18fe78\n".encode())
        os.write(fd, f"p:dagu_disp {mu}:0x16e70c\n".encode())
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


def on_device(seconds=10.0):
    shell, lab = find_pids()
    install(shell)
    kick, nview, ifn, add, attach, disp = [], [], [], [], [], []
    snaps = []
    stop = threading.Event()

    def sampler():
        while not stop.is_set():
            try:
                snaps.append(gpu_snap())
            except OSError:
                pass
            time.sleep(0.002)

    th = threading.Thread(target=sampler, daemon=True)
    th.start()
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
                elif "dagu_attach:" in line:
                    attach.append(ts)
                elif "dagu_disp:" in line:
                    disp.append(ts)
    finally:
        pipe.close()
        stop.set()
        th.join(timeout=1)
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
        win = [s for s in snaps if a <= s["t"] <= b]
        inflights = [s["inflight"] for s in win if s["inflight"] is not None]
        rbbm_nz = sum(1 for s in win if s["rbbm"] and s["rbbm"] != "0x00000000")
        busies = [s["busy"] for s in win if s["busy"] is not None]
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add": first_after(add, a, 0, 280),
            "attach": first_after(attach, a, -20, 20),
            "disp": first_after(disp, a, 0, 280),
            "snaps": len(win),
            "inf_max": max(inflights) if inflights else None,
            "inf_min": min(inflights) if inflights else None,
            "rbbm_nz": rbbm_nz,
            "busy_max": max(busies) if busies else None,
            "busy_min": min(busies) if busies else None,
            "first": win[0] if win else None,
            "mid": win[len(win)//2] if win else None,
            "last": win[-1] if win else None,
        })

    out = {
        "kind": "gpu-ring-snap",
        "shell": shell,
        "lab": lab,
        "lab_dmabufs": lab_dmabufs(lab),
        "seconds": seconds,
        "kick": summary(kick),
        "n_attach": len(attach),
        "n_disp": len(disp),
        "n_snaps": len(snaps),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-gpu-ring-snap.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-gpu-ring-snap-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-gpu-ring-snap-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-gpu-ring-snap-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-gpu-ring-snap.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main():
    args = [a for a in sys.argv[1:] if a != "--host"]
    seconds = 10.0
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
