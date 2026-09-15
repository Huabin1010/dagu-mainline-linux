#!/usr/bin/env python3
"""Sample gnome-shell main/KMS syscall during kickoff holes.

No mutter uprobes (those have hung the 8s window). Kickoff trace only.
From host: python3 linux-mainline/scripts/dagu-hole-syscall-sample.py --host
"""
from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import time
from collections import Counter
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


def find_pids() -> tuple[int, int, int]:
    shell = native = kms = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell"):
            shell = int(p.name)
        elif b"dagu-native-lab.py" in cmd:
            native = int(p.name)
    if shell is None or native is None:
        raise SystemExit(json.dumps({"err": "need shell+lab", "shell": shell, "native": native}))
    for tid in Path(f"/proc/{shell}/task").iterdir():
        try:
            if (tid / "comm").read_text().strip() == "KMS thread":
                kms = int(tid.name)
                break
        except OSError:
            pass
    if kms is None:
        raise SystemExit("no KMS thread")
    return shell, native, kms


def read_syscall(tid: int) -> tuple[int | None, list[int], str]:
    try:
        raw = Path(f"/proc/{tid}/syscall").read_text().strip()
    except OSError:
        return None, [], "gone"
    if raw == "running":
        return -1, [], "running"
    parts = raw.split()
    try:
        nr = int(parts[0], 0)
        args = [int(x, 16) for x in parts[1:7]]
    except (ValueError, IndexError):
        return None, [], raw
    return nr, args, raw


def read_ts_ms(mem, addr: int) -> float | None:
    if not addr:
        return None
    try:
        mem.seek(addr)
        sec, nsec = struct.unpack("<qq", mem.read(16))
    except (OSError, struct.error):
        return None
    if sec < 0 or nsec < 0:
        return None
    return sec * 1000.0 + nsec / 1e6


def on_device(seconds: float = 8.0) -> int:
    shell, native, kms = find_pids()
    mem = open(f"/proc/{shell}/mem", "rb", buffering=0)
    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")

    samples: list[tuple[float, int | None, int | None, float | None, float | None, str, str]] = []
    t_end = time.monotonic() + seconds
    while time.monotonic() < t_end:
        now = time.monotonic()
        nr_m, args_m, raw_m = read_syscall(shell)
        nr_k, args_k, raw_k = read_syscall(kms)
        tmo_m = tmo_k = None
        if nr_m == 73 and len(args_m) >= 3:
            tmo_m = read_ts_ms(mem, args_m[2])
        if nr_k == 73 and len(args_k) >= 3:
            tmo_k = read_ts_ms(mem, args_k[2])
        w_m = Path(f"/proc/{shell}/wchan").read_text() if Path(f"/proc/{shell}/wchan").exists() else ""
        w_k = Path(f"/proc/{kms}/wchan").read_text() if Path(f"/proc/{kms}/wchan").exists() else ""
        samples.append((now, nr_m, nr_k, tmo_m, tmo_k, w_m, w_k))
        time.sleep(0.001)

    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    mem.close()

    kicks: list[float] = []
    # trace timestamps are seconds; convert via first sample wall is monotonic != trace clock
    # Use trace clock only for gaps; map holes by relative position in the window
    # Better: parse trace ts as CLOCK_MONOTONIC (same as time.monotonic on this kernel)
    for line in raw.splitlines():
        if "dpu_enc_kickoff:" not in line:
            continue
        for tok in line.split():
            if tok.endswith(":") and tok[:-1].replace(".", "", 1).isdigit():
                kicks.append(float(tok[:-1]))
                break

    # Align: both CLOCK_MONOTONIC if tracing clock is mono
    holes = []
    for a, b in zip(kicks, kicks[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        mid0, mid1 = a + 0.008, b - 0.002
        in_hole = [s for s in samples if mid0 <= s[0] <= mid1]
        # If clocks don't match, fall back to last 8s samples overlapping by index
        holes.append({
            "gap_ms": round(gap, 1),
            "t0": a,
            "n_samp": len(in_hole),
            "main_nr": Counter(s[1] for s in in_hole).most_common(4),
            "kms_nr": Counter(s[2] for s in in_hole).most_common(4),
            "main_tmo": [round(s[3], 2) for s in in_hole if s[3] is not None][:8],
            "main_tmo_max": max((s[3] for s in in_hole if s[3] is not None), default=None),
            "main_wchan": Counter(s[5] for s in in_hole).most_common(3),
            "kms_wchan": Counter(s[6] for s in in_hole).most_common(3),
        })

    # If all holes have n_samp=0, clocks differ — bucket samples by local monotonic gaps
    if holes and all(h["n_samp"] == 0 for h in holes):
        # Rebuild using sample-local kick detection: 1s kick count windows won't work.
        # Use last-kick from tracing_mark? Instead correlate by assuming sample window
        # == trace window and remap kicks into sample timebase.
        if kicks and samples:
            k0, s0 = kicks[0], samples[0][0]
            scale = 1.0
            for h in holes:
                a = s0 + (h["t0"] - k0) * scale
                b = a + h["gap_ms"] / 1000.0
                in_hole = [s for s in samples if a + 0.008 <= s[0] <= b - 0.002]
                h["n_samp"] = len(in_hole)
                h["aligned"] = "mono-shift"
                h["main_nr"] = Counter(s[1] for s in in_hole).most_common(4)
                h["kms_nr"] = Counter(s[2] for s in in_hole).most_common(4)
                h["main_tmo"] = [round(s[3], 2) for s in in_hole if s[3] is not None][:8]
                h["main_tmo_max"] = max((s[3] for s in in_hole if s[3] is not None), default=None)
                h["main_wchan"] = Counter(s[5] for s in in_hole).most_common(3)
                h["kms_wchan"] = Counter(s[6] for s in in_hole).most_common(3)

    idle = [s for s in samples if s[1] == 73]
    out = {
        "kind": "hole-syscall",
        "seconds": seconds,
        "pid": shell,
        "native": native,
        "kms": kms,
        "n_samp": len(samples),
        "kick_n": len(kicks),
        "kick_hz": round(len(kicks) / seconds, 2),
        "main_nr_all": Counter(s[1] for s in samples).most_common(8),
        "kms_nr_all": Counter(s[2] for s in samples).most_common(8),
        "main_ppoll_tmo_p50": None,
        "holes": holes,
        "hole_n": len(holes),
    }
    tmos = sorted(s[3] for s in idle if s[3] is not None)
    if tmos:
        out["main_ppoll_tmo_p50"] = round(tmos[len(tmos) // 2], 2)
        out["main_ppoll_tmo_max"] = round(tmos[-1], 2)
        out["main_ppoll_tmo_gt50"] = sum(1 for t in tmos if t > 50)
    Path("/tmp/dagu-hole-syscall.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-hole-syscall-sample.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-hole-syscall-sample.py"], check=False)
    out_host = ROOT / "out" / "display-stress"
    out_host.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = out_host / f"dagu-hole-syscall-{stamp}.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-hole-syscall.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    return r.returncode


def main() -> int:
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
