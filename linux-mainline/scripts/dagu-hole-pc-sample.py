#!/usr/bin/env python3
"""Kickoff-hole PC sample for gnome-shell + identity GTK lab.

No extra uprobes. Align /proc/<pid>/stat eip to maps.
From host: python3 linux-mainline/scripts/dagu-hole-pc-sample.py --host
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import struct
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
        raise SystemExit(json.dumps({"err": "need shell+lab", "shell": shell, "lab": lab}))
    return shell, lab


def load_maps(pid: int) -> list[tuple[int, int, int, str]]:
    out = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        lo, hi = (int(x, 16) for x in parts[0].split("-"))
        perm, off = parts[1], int(parts[2], 16)
        if "x" not in perm:
            continue
        path = parts[-1] if len(parts) > 5 else ""
        out.append((lo, hi, off, path))
    return out


def resolve(maps, pc: int) -> str:
    for lo, hi, off, path in maps:
        if lo <= pc < hi:
            name = path.rsplit("/", 1)[-1] if path.startswith("/") else path or "anon"
            return f"{name}+{pc - lo + off:#x}"
    return hex(pc)


def read_pc_stat(pid: int) -> int | None:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    rpar = raw.rfind(")")
    fields = raw[rpar + 2 :].split()
    try:
        return int(fields[27])
    except (IndexError, ValueError):
        return None


def read_wchan(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/wchan").read_text().strip()[:48]
    except OSError:
        return ""


def read_sys_pc(pid: int) -> tuple[str, int | None, list[str]]:
    try:
        raw = Path(f"/proc/{pid}/syscall").read_text().strip()
    except OSError:
        return "gone", None, []
    if raw == "running":
        return "running", read_pc_stat(pid), []
    parts = raw.split()
    pc = None
    if len(parts) >= 9:
        try:
            pc = int(parts[-1], 16)
        except ValueError:
            pc = None
    return parts[0], pc, parts


def read_timespec_ms(pid: int, addr: int) -> float | None:
    if not addr:
        return None
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(addr)
        sec, nsec = struct.unpack("<qq", mem.read(16))
        mem.close()
    except OSError:
        return None
    if sec < 0:
        return -1.0
    return sec * 1000.0 + nsec / 1e6


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    smaps = load_maps(shell)
    lmaps = load_maps(lab)
    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    flip_ev = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if flip_ev.is_file():
        flip_ev.write_text("1\n")
    (TR / "tracing_on").write_text("1\n")
    samples = []
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
        t = time.clock_gettime(time.CLOCK_MONOTONIC)
        sh_sys, sh_pc, sh_parts = read_sys_pc(shell)
        lab_sys, lab_pc, _ = read_sys_pc(lab)
        tmo = None
        nfds = None
        if sh_sys == "73" and len(sh_parts) >= 4:
            try:
                nfds = int(sh_parts[2], 16)
                tmo = read_timespec_ms(shell, int(sh_parts[3], 16))
            except ValueError:
                pass
        samples.append({
            "t": t,
            "sh_sys": sh_sys,
            "lab_sys": lab_sys,
            "sh_pc": sh_pc,
            "lab_pc": lab_pc,
            "sh_wchan": read_wchan(shell),
            "tmo": tmo,
            "nfds": nfds,
        })
        time.sleep(0.001)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    (TR / "tracing_on").write_text("1\n")
    if flip_ev.is_file():
        flip_ev.write_text("0\n")
    kick = []
    flip = []
    for line in raw.splitlines():
        ts = None
        for tok in line.split():
            if tok.endswith(":") and tok[:-1].replace(".", "", 1).isdigit():
                ts = float(tok[:-1])
                break
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
        elif "dpu_crtc_complete_flip:" in line:
            flip.append(ts)
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        sh_c: Counter[str] = Counter()
        lab_c: Counter[str] = Counter()
        sh_sys: Counter[str] = Counter()
        lab_sys: Counter[str] = Counter()
        sh_w: Counter[str] = Counter()
        tmos: list[float] = []
        nfds_c: Counter[int] = Counter()
        n = 0
        for s in samples:
            if not (a + 0.008 <= s["t"] <= b - 0.008):
                continue
            n += 1
            sh_sys[s["sh_sys"]] += 1
            lab_sys[s["lab_sys"]] += 1
            if s.get("sh_wchan"):
                sh_w[s["sh_wchan"]] += 1
            if s["sh_pc"]:
                sh_c[resolve(smaps, s["sh_pc"])] += 1
            if s["lab_pc"]:
                lab_c[resolve(lmaps, s["lab_pc"])] += 1
            if s.get("tmo") is not None:
                tmos.append(s["tmo"])
            if s.get("nfds") is not None:
                nfds_c[s["nfds"]] += 1
        flip_rel = [round((x - a) * 1000.0, 2) for x in flip if a - 0.008 <= x <= b + 0.004]
        early_flip = any(0 <= f <= 12 for f in flip_rel)
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": "flip-early" if early_flip else "flip-late",
            "flip": flip_rel[:6],
            "n": n,
            "tmo_ms": [round(x, 1) for x in tmos[:3] + tmos[-2:]],
            "nfds": nfds_c.most_common(3),
            "sh_sys": sh_sys.most_common(4),
            "lab_sys": lab_sys.most_common(4),
            "sh_wchan": sh_w.most_common(4),
            "sh_pc": sh_c.most_common(8),
            "lab_pc": lab_c.most_common(8),
        })
    gaps = [1000.0 * (b - a) for a, b in zip(kick, kick[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (kick[-1] - kick[0]) if len(kick) > 1 else 0
    out = {
        "kind": "hole-pc",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick_n": len(kick),
        "hz": round(len(kick) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
        "sample_n": len(samples),
        "hole_kinds": dict(Counter(h.get("kind", "?") for h in holes)),
        "holes": holes,
    }
    Path("/tmp/dagu-hole-pc.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-hole-pc-sample.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-hole-pc-sample.py"], check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-hole-pc-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-hole-pc.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main() -> int:
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
