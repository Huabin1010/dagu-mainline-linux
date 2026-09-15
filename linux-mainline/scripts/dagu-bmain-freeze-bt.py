#!/usr/bin/env python3
"""Freeze gnome-shell when schedule_update is not followed by fcdisp.

Uprobes only on live clutter map_files. Max 2 freezes. Restores tracing_on=1.
From host: python3 linux-mainline/scripts/dagu-bmain-freeze-bt.py --host
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_shell() -> tuple[int, str]:
    pid = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell") and b"--mode=ubuntu" in cmd:
            pid = int(p.name)
            break
    if pid is None:
        raise SystemExit("no gnome-shell")
    mf = None
    for line in open(f"/proc/{pid}/maps"):
        if "libmutter-clutter-18.so" in line and "r-xp" in line:
            rng = line.split()[0]
            mf = f"/proc/{pid}/map_files/{rng}"
            break
    if not mf:
        raise SystemExit("no clutter map")
    return pid, mf


def syscall(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/syscall").read_text().strip().split()[0]
    except OSError:
        return "gone"


def gdb_bt(pid: int) -> str:
    r = subprocess.run(
        [
            "gdb", "-p", str(pid), "-batch",
            "-ex", "set pagination off",
            "-ex", "set confirm off",
            "-ex", "thread 1",
            "-ex", "bt 32",
            "-ex", "info registers pc",
        ],
        capture_output=True, text=True, timeout=8,
    )
    return ((r.stdout or "") + (r.stderr or ""))[-9000:]


def on_device(seconds: float = 14.0, max_catch: int = 2) -> int:
    pid, mf = find_shell()
    en = TR / "events/uprobes/enable"
    ue = TR / "uprobe_events"
    if en.is_file():
        en.write_text("0\n")
    try:
        ue.write_text("")
    except OSError:
        time.sleep(0.05)
        ue.write_text("")
    fd = os.open(str(ue), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_fsched {mf}:0x675a0\n".encode())
        os.write(fd, f"p:dagu_fdisp {mf}:0x73c0c\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")
    last_sched = 0.0
    last_disp = 0.0
    n_sched = n_disp = n_gap = 0
    lock = threading.Lock()
    stop = threading.Event()

    def reader() -> None:
        nonlocal last_sched, last_disp, n_sched, n_disp
        with open(TR / "trace_pipe", "r", buffering=1) as pipe:
            while not stop.is_set():
                line = pipe.readline()
                if not line:
                    continue
                now = time.clock_gettime(time.CLOCK_MONOTONIC)
                with lock:
                    if "dagu_fsched:" in line:
                        last_sched = now
                        n_sched += 1
                    elif "dagu_fdisp:" in line:
                        last_disp = now
                        n_disp += 1

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    catches = []
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    try:
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end and len(catches) < max_catch:
            now = time.clock_gettime(time.CLOCK_MONOTONIC)
            with lock:
                ls, ld = last_sched, last_disp
            if ld <= 0 or ls <= ld:
                time.sleep(0.0004)
                continue
            gap = (now - ld) * 1000.0
            if gap < 25:
                time.sleep(0.0004)
                continue
            n_gap += 1
            sy = syscall(pid)
            if sy not in ("running", "73"):
                time.sleep(0.0004)
                continue
            frozen = False
            try:
                os.kill(pid, signal.SIGSTOP)
                frozen = True
                time.sleep(0.001)
                bt = gdb_bt(pid)
                catches.append({
                    "gap_ms": round(gap, 1),
                    "sy": sy,
                    "sy_stop": syscall(pid),
                    "bt": bt,
                })
            finally:
                if frozen:
                    os.kill(pid, signal.SIGCONT)
            with lock:
                now2 = time.clock_gettime(time.CLOCK_MONOTONIC)
                last_disp = now2
                last_sched = now2
            time.sleep(0.2)
    finally:
        stop.set()
        if en.is_file():
            en.write_text("0\n")
        ue.write_text("")
        (TR / "tracing_on").write_text("1\n")
    out = {
        "kind": "bmain-freeze",
        "pid": pid,
        "n": len(catches),
        "n_sched": n_sched,
        "n_disp": n_disp,
        "n_gap": n_gap,
        "catches": catches,
    }
    Path("/tmp/dagu-bmain-freeze-bt.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps({k: out[k] for k in ("kind", "pid", "n", "n_sched", "n_disp", "n_gap")}, indent=2))
    for i, c in enumerate(catches):
        print(f"\n===== catch {i} sched_gap={c['gap_ms']} sy={c['sy']} =====")
        print(c["bt"])
    return 0


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-bmain-freeze-bt.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-bmain-freeze-bt.py"], check=False)
    dest = ROOT / "out" / "display-stress"
    dest.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    destf = dest / f"dagu-bmain-freeze-bt-{stamp}.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-bmain-freeze-bt.json", str(destf)], check=False)
    if destf.is_file():
        print(destf.read_text()[:18000])
        print(f"saved {destf}")
    return r.returncode


def main() -> int:
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
