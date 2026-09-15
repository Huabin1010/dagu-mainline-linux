#!/usr/bin/env python3
"""B-kick: workqueue queue/execute of drm commit_work vs dpu_enc_kickoff.

No poke. From host: python3 linux-mainline/scripts/dagu-wq-commit-probe.py --host
"""
from __future__ import annotations

import json
import os
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


def find_pids() -> tuple[int, int]:
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


def map_rx(pid: int, needle: str) -> str:
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        rng = line.split()[0]
        mf = f"/proc/{pid}/map_files/{rng}"
        if Path(mf).exists():
            return mf
    raise SystemExit(f"no r-xp {needle}")


def kallsym(name: str) -> str:
    for line in open("/proc/kallsyms"):
        parts = line.split()
        if len(parts) >= 3 and parts[-1] == name:
            return parts[0]
    raise SystemExit(f"no kallsym {name}")


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def install(shell: int) -> dict:
    commit = kallsym("commit_work")
    (TR / "tracing_on").write_text("0\n")
    en0 = TR / "events/uprobes/enable"
    if en0.is_file():
        en0.write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    ue = TR / "uprobe_events"
    try:
        ue.write_text("")
    except OSError:
        time.sleep(0.05)
        ue.write_text("")
    path = map_rx(shell, "libmutter-18.so.0.0.0")
    with os.fdopen(os.open(str(ue), os.O_WRONLY | os.O_APPEND), "w") as f:
        f.write(f"p:dagu_atomic {path}:0x1b4878\n")
    (TR / "events/uprobes/enable").write_text("1\n")
    filt = f"function == 0x{int(commit, 16):x}\n"
    for ev in ("workqueue_queue_work", "workqueue_execute_start", "workqueue_execute_end"):
        p = TR / "events/workqueue" / ev
        (p / "filter").write_text(filt)
        (p / "enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    return {"commit_work": commit, "filter": filt.strip()}


def clear() -> None:
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    for ev in ("workqueue_queue_work", "workqueue_execute_start", "workqueue_execute_end"):
        p = TR / "events/workqueue" / ev
        if (p / "enable").is_file():
            (p / "enable").write_text("0\n")
        if (p / "filter").is_file():
            (p / "filter").write_text("0\n")
    for relpath in (
        "events/dpu/dpu_crtc_complete_flip/enable",
    ):
        p = TR / relpath
        if p.is_file():
            p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    meta = install(shell)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    kick: list[float] = []
    flip: list[float] = []
    atomic: list[float] = []
    queue: list[float] = []
    exe_s: list[float] = []
    exe_e: list[float] = []
    for line in raw.splitlines():
        ts = parse_ts(line)
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
        elif "dpu_crtc_complete_flip:" in line:
            flip.append(ts)
        elif "dagu_atomic:" in line:
            atomic.append(ts)
        elif "workqueue_queue_work:" in line:
            queue.append(ts)
        elif "workqueue_execute_start:" in line:
            exe_s.append(ts)
        elif "workqueue_execute_end:" in line:
            exe_e.append(ts)

    def summary(xs: list[float]) -> dict:
        gaps = [1000.0 * (b - a) for a, b in zip(xs, xs[1:]) if b >= a]
        over = [g for g in gaps if g > 50]
        span = (xs[-1] - xs[0]) if len(xs) > 1 else 0
        return {
            "n": len(xs),
            "hz": round(len(xs) / span, 2) if span else 0,
            "gt50": len(over),
            "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        }

    def rel_in(xs: list[float], t0: float, lo: float, hi: float) -> list[float]:
        return [round((x - t0) * 1000.0, 2) for x in xs if lo <= x <= hi]

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        q_in = rel_in(queue, a, a + 0.002, b + 0.001)
        e_in = rel_in(exe_s, a, a + 0.002, b + 0.001)
        holes.append({
            "gap_ms": round(gap, 1),
            "pre_atomic": rel_in(atomic, a, a - 0.004, a + 0.002),
            "pre_queue": rel_in(queue, a, a - 0.004, a + 0.002),
            "pre_exe_s": rel_in(exe_s, a, a - 0.004, a + 0.002),
            "pre_exe_e": rel_in(exe_e, a, a - 0.004, a + 0.008),
            "pre_flip": rel_in(flip, a, a - 0.004, a + 0.008),
            "in_atomic": rel_in(atomic, a, a + 0.002, b + 0.001),
            "in_queue": q_in,
            "in_exe_s": e_in,
            "in_exe_e": rel_in(exe_e, a, a + 0.002, b + 0.001),
            "in_flip": rel_in(flip, a, a + 0.002, b + 0.001),
            "q_to_exe_ms": (
                None if not q_in or not e_in else round(e_in[0] - q_in[0], 2)
            ),
        })
    out = {
        "kind": "wq-commit",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "meta": meta,
        "kick": summary(kick),
        "flip": summary(flip),
        "counts": {
            "atomic": len(atomic),
            "queue": len(queue),
            "exe_start": len(exe_s),
            "exe_end": len(exe_e),
        },
        "holes": holes[:8],
    }
    Path("/tmp/dagu-wq-commit.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    extra = [a for a in sys.argv[1:] if a != "--host"]
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-wq-commit-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-wq-commit-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-wq-commit-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-wq-commit.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--host"]
    seconds = 8.0
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
