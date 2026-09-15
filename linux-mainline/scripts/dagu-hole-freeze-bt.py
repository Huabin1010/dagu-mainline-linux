#!/usr/bin/env python3
"""SIGSTOP gnome-shell mid kickoff hole while main is running; dump bt.

No extra uprobes. Does not restart gnome-shell. Max 2 freezes.
From host: python3 linux-mainline/scripts/dagu-hole-freeze-bt.py --host
"""
from __future__ import annotations

import json
import os
import signal
import struct
import subprocess
import sys
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


def find_shell() -> int:
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell"):
            return int(p.name)
    raise SystemExit("no gnome-shell")


def syscall(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/syscall").read_text().strip().split()[0]
    except OSError:
        return "gone"


def live_insn(pid: int) -> dict:
    base = mesa = cbase = None
    for line in open(f"/proc/{pid}/maps"):
        if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
            base = int(line.split("-", 1)[0], 16)
        elif "libmutter-clutter-18.so" in line and "r-xp" in line:
            cbase = int(line.split("-", 1)[0], 16)
        elif "libgallium-26.0.8" in line and "r-xp" in line:
            mesa = int(line.split("-", 1)[0], 16)
    out = {"base": hex(base) if base else None, "cbase": hex(cbase) if cbase else None}
    mem = open(f"/proc/{pid}/mem", "rb", buffering=0)
    if base:
        for off in (0x1bd9ac, 0x1bd9d8, 0x1d6ee4, 0x1b4820):
            mem.seek(base + off)
            out[hex(off)] = hex(struct.unpack("<I", mem.read(4))[0])
    if cbase:
        mem.seek(cbase + 0x67bf8)
        out["clutter_67bf8"] = hex(struct.unpack("<I", mem.read(4))[0])
    if mesa:
        mem.seek(mesa + 0x1cf740)
        out["mesa_1cf740"] = hex(struct.unpack("<I", mem.read(4))[0])
        mem.seek(mesa + 0x1cf74c)
        out["mesa_1cf74c"] = hex(struct.unpack("<I", mem.read(4))[0])
    mem.close()
    return out


def gdb_bt(pid: int) -> str:
    r = subprocess.run(
        [
            "gdb", "-p", str(pid), "-batch",
            "-ex", "set pagination off",
            "-ex", "set confirm off",
            "-ex", "thread 1",
            "-ex", "bt 28",
            "-ex", "info registers pc x30",
        ],
        capture_output=True, text=True, timeout=8,
    )
    return (r.stdout or "") + (r.stderr or "")


def on_device(seconds: float = 12.0, max_catch: int = 2) -> int:
    pid = find_shell()
    insn = live_insn(pid)
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    last_kick = time.clock_gettime(time.CLOCK_MONOTONIC)
    catches = []
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    os.set_blocking(pipe.fileno(), False)
    while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end and len(catches) < max_catch:
        try:
            line = pipe.readline()
        except OSError:
            line = ""
        if line and "dpu_enc_kickoff:" in line:
            last_kick = time.clock_gettime(time.CLOCK_MONOTONIC)
        now = time.clock_gettime(time.CLOCK_MONOTONIC)
        gap = (now - last_kick) * 1000.0
        if gap < 28:
            time.sleep(0.0004)
            continue
        sy = syscall(pid)
        if sy != "running":
            time.sleep(0.0004)
            continue
        frozen = False
        try:
            os.kill(pid, signal.SIGSTOP)
            frozen = True
            time.sleep(0.002)
            sy2 = syscall(pid)
            bt = gdb_bt(pid)
            kstacks = {}
            for tdir in Path(f"/proc/{pid}/task").iterdir():
                try:
                    st = (tdir / "stack").read_text()
                except OSError:
                    continue
                if st.strip() and st.strip() != "0x0":
                    kstacks[tdir.name] = st.strip().splitlines()[:8]
            catches.append({
                "gap_ms": round(gap, 1),
                "sy_before": sy,
                "sy_stopped": sy2,
                "bt": bt[-8000:],
                "kstacks": kstacks,
            })
        finally:
            if frozen:
                os.kill(pid, signal.SIGCONT)
        time.sleep(0.15)
        last_kick = time.clock_gettime(time.CLOCK_MONOTONIC)
    pipe.close()
    out = {
        "kind": "hole-freeze-bt",
        "pid": pid,
        "insn": insn,
        "seconds": seconds,
        "n": len(catches),
        "catches": catches,
    }
    Path("/tmp/dagu-hole-freeze-bt.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps({k: out[k] for k in ("kind", "pid", "insn", "n")}, indent=2))
    for i, c in enumerate(catches):
        print(f"\n===== catch {i} gap={c['gap_ms']} sy={c['sy_before']} =====")
        print(c["bt"])
    return 0


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-hole-freeze-bt.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-hole-freeze-bt.py"], check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-hole-freeze-bt-{stamp}.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-hole-freeze-bt.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text()[:20000])
        print(f"saved {dest}")
    return r.returncode


def main() -> int:
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
