#!/usr/bin/env python3
"""10s Sysprof --gnome-shell + dpu_enc_kickoff on the identity lab. No poke."""
from __future__ import annotations

import json
import os
import signal
import subprocess
import time
from pathlib import Path

TR = Path("/sys/kernel/debug/tracing")
SYSCAP = Path("/tmp/dagu-sysprof-align.syscap")
OUT = Path("/tmp/dagu-sysprof-align.json")


def kick_summary(ts: list[float]) -> dict:
    gaps = [1000.0 * (b - a) for a, b in zip(ts, ts[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (ts[-1] - ts[0]) if len(ts) > 1 else 0
    holes = []
    for a, b in zip(ts, ts[1:]):
        g = (b - a) * 1000.0
        if g > 50:
            holes.append({"t0": round(a, 6), "t1": round(b, 6), "gap_ms": round(g, 1)})
    return {
        "n": len(ts),
        "hz": round(len(ts) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "holes": holes[:12],
    }


def main() -> int:
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "trace").write_text("")
    (TR / "tracing_on").write_text("1\n")
    env = os.environ.copy()
    env.update({
        "XDG_RUNTIME_DIR": "/run/user/1001",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1001/bus",
        "WAYLAND_DISPLAY": "wayland-0",
        "HOME": "/home/dagu",
    })
    if SYSCAP.exists():
        SYSCAP.unlink()
    cmd = [
        "sudo", "-u", "dagu", "env",
        "XDG_RUNTIME_DIR=/run/user/1001",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
        "WAYLAND_DISPLAY=wayland-0",
        "HOME=/home/dagu",
        "sysprof-cli", "--gnome-shell", "--no-perf", "--no-sysprofd",
        "--no-decode", "--no-debuginfod", "--no-battery", "--no-disk",
        "--no-network", "--no-memory", "--force", str(SYSCAP),
    ]
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    time.sleep(10.0)
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        proc.send_signal(signal.SIGINT)
        proc.wait(timeout=5)
    (TR / "tracing_on").write_text("0\n")
    kicks: list[float] = []
    for line in (TR / "trace").read_text(errors="replace").splitlines():
        if "dpu_enc_kickoff:" not in line:
            continue
        for part in line.split():
            if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
                kicks.append(float(part[:-1]))
                break
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")
    out = {
        "syscap": str(SYSCAP),
        "syscap_bytes": SYSCAP.stat().st_size if SYSCAP.exists() else 0,
        "kick": kick_summary(kicks),
        "sysprof_rc": proc.returncode,
        "sysprof_err": (proc.stderr.read().decode("utf-8", "replace")[-400:] if proc.stderr else ""),
    }
    OUT.write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
