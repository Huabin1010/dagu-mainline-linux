#!/usr/bin/env python3
"""Peek / set live Clutter frame clock GSource priority.

Must call g_source_set_priority (re-sorts). Do not poke the int only.
From host: python3 linux-mainline/scripts/dagu-clock-prio.py --host [peek|set0|set150]
"""
from __future__ import annotations

import json
import os
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


def find_shell() -> tuple[int, str, int]:
    pid = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell"):
            pid = int(p.name)
            break
    if pid is None:
        raise SystemExit("no gnome-shell")
    mf = None
    base = None
    for line in open(f"/proc/{pid}/maps"):
        if "libmutter-clutter-18.so" in line and "r-xp" in line:
            rng = line.split()[0]
            base = int(rng.split("-", 1)[0], 16)
            mf = f"/proc/{pid}/map_files/{rng}"
            break
    if not mf:
        raise SystemExit("no clutter map")
    return pid, mf, base


def capture_clock(pid: int, mf: str) -> tuple[int | None, int | None]:
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
        # schedule_update entry: x0 is ClutterFrameClock*
        os.write(fd, f"p:dagu_clk {mf}:0x675a0 x0=%x0\n".encode())
    finally:
        os.close(fd)
    if not (TR / "events/uprobes/enable").is_file():
        raise SystemExit("uprobe not created")
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")
    time.sleep(0.35)
    (TR / "events/uprobes/enable").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    ue.write_text("")
    clk = None
    for line in raw.splitlines():
        if "dagu_clk:" not in line:
            continue
        for tok in line.replace(")", " ").replace("(", " ").split():
            if tok.startswith("x0="):
                try:
                    clk = int(tok.split("=", 1)[1], 16)
                except ValueError:
                    pass
        if clk and clk > 0x10000:
            break
    if not clk:
        return None, None
    mem = open(f"/proc/{pid}/mem", "rb", buffering=0)
    mem.seek(clk + 72)
    src = struct.unpack("<Q", mem.read(8))[0]
    mem.close()
    return src, clk


def peek(pid: int, src: int, clk: int) -> dict:
    mem = open(f"/proc/{pid}/mem", "rb", buffering=0)
    mem.seek(src + 40)
    prio = struct.unpack("<i", mem.read(4))[0]
    mem.seek(clk + 72)
    src2 = struct.unpack("<Q", mem.read(8))[0]
    mem.seek(clk + 88)
    state = struct.unpack("<I", mem.read(4))[0]
    mem.seek(clk + 92)
    mode = struct.unpack("<I", mem.read(4))[0]
    mem.seek(clk + 28)
    hz = struct.unpack("<f", mem.read(4))[0]
    mem.close()
    return {
        "src": hex(src),
        "clk": hex(clk),
        "src_from_clk": hex(src2),
        "prio": prio,
        "state": state,
        "mode": mode,
        "hz": round(hz, 2),
    }


def gdb_set_prio(pid: int, src: int, prio: int) -> str:
    r = subprocess.run(
        [
            "gdb", "-p", str(pid), "-batch",
            "-ex", "set pagination off",
            "-ex", "set confirm off",
            "-ex", f"call (void)g_source_set_priority((void *){src:#x}, {prio})",
        ],
        capture_output=True, text=True, timeout=8,
    )
    return ((r.stdout or "") + (r.stderr or ""))[-2000:]


def on_device() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "peek"
    pid, mf, base = find_shell()
    src, clk = capture_clock(pid, mf)
    if not src or not clk:
        raise SystemExit(json.dumps({"err": "no clock hit", "pid": pid}))
    before = peek(pid, src, clk)
    gdb_out = ""
    after = before
    if cmd == "set0":
        gdb_out = gdb_set_prio(pid, src, 0)
        after = peek(pid, src, clk)
    elif cmd == "set150":
        gdb_out = gdb_set_prio(pid, src, 150)
        after = peek(pid, src, clk)
    out = {
        "kind": "clock-prio",
        "cmd": cmd,
        "pid": pid,
        "base": hex(base),
        "before": before,
        "after": after,
        "gdb": gdb_out[-800:],
        "alive": Path(f"/proc/{pid}").exists(),
    }
    Path("/tmp/dagu-clock-prio.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    cmd = "peek"
    args = [a for a in sys.argv[1:] if a != "--host"]
    if args:
        cmd = args[0]
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-clock-prio.py"], check=True)
    r = subprocess.run(ssh + [f"python3 /tmp/dagu-clock-prio.py {cmd}"], check=False)
    dest = ROOT / "out" / "display-stress"
    dest.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    destf = dest / f"dagu-clock-prio-{stamp}.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-clock-prio.json", str(destf)], check=False)
    if destf.is_file():
        print(destf.read_text())
        print(f"saved {destf}")
    return r.returncode


def main() -> int:
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
