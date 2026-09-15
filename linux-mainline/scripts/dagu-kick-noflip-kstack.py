#!/usr/bin/env python3
"""After kickoff, if complete_flip missing 20ms: sample KMS + irq + kworker.

No mutter uprobes. From host:
  python3 linux-mainline/scripts/dagu-kick-noflip-kstack.py --host
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

SYSC = {
    "-1": "running",
    "29": "ioctl",
    "73": "ppoll",
    "98": "futex",
}


def ssh_base():
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_pids():
    shell = lab = kms = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell") and b"--mode=ubuntu" in cmd:
            shell = int(p.name)
            for tid_p in (p / "task").iterdir():
                try:
                    if (tid_p / "comm").read_text().strip() == "KMS thread":
                        kms = int(tid_p.name)
                except OSError:
                    pass
        elif cmd.startswith(b"python") and b"dagu-native-lab.py" in cmd:
            lab = int(p.name)
    if shell is None or lab is None or kms is None:
        raise SystemExit(json.dumps({"err": "need ubuntu+lab+kms"}))
    return shell, lab, kms


def parse_ts(line):
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
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
        "max": round(max(over), 1) if over else (round(max(gaps), 1) if gaps else 0),
    }


def read_sys(tid):
    try:
        raw = Path(f"/proc/{tid}/syscall").read_text().strip()
        wchan = Path(f"/proc/{tid}/wchan").read_text().strip()
    except OSError:
        return {"raw": "gone"}
    if raw == "running":
        return {"name": "running", "wchan": wchan}
    nr = raw.split()[0]
    return {"name": SYSC.get(nr, nr), "wchan": wchan, "raw": raw[:70]}


def read_stack(tid, limit=8):
    try:
        lines = Path(f"/proc/{tid}/stack").read_text().splitlines()
    except OSError:
        return []
    out = []
    for line in lines[:limit]:
        s = line.strip()
        if "]" in s:
            s = s.split("]", 1)[-1].strip()
        if s:
            out.append(s)
    return out


def irq_hits():
    out = {}
    try:
        text = Path("/proc/interrupts").read_text()
    except OSError:
        return out
    for line in text.splitlines():
        if "dpu" in line.lower() or "mdss" in line.lower() or "disp" in line.lower():
            out[line.split(":", 1)[0].strip()] = " ".join(line.split()[-3:])
    return out


def kworkers():
    hits = []
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            comm = (p / "comm").read_text().strip()
        except OSError:
            continue
        if "dpu" in comm or "crtc" in comm or "commit" in comm or comm.startswith("irq/"):
            if "dpu" in comm or "msm" in comm or "commit" in comm or "crtc" in comm:
                hits.append({"pid": int(p.name), "comm": comm, **read_sys(int(p.name)),
                             "stack": read_stack(int(p.name))})
    return hits[:8]


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def install():
    (TR / "tracing_on").write_text("0\n")
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("8192\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    vbl = TR / "events/drm/drm_vblank_event_delivered/enable"
    if vbl.is_file():
        vbl.write_text("1\n")


def clear():
    for rel in (
        "events/dpu/dpu_crtc_complete_flip/enable",
        "events/drm/drm_vblank_event_delivered/enable",
    ):
        p = TR / rel
        if p.is_file():
            p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds=12.0):
    shell, lab, kms = find_pids()
    install()
    kick, flip, vbl = [], [], []
    snaps = []
    last_kick = None
    wall_kick = None
    saw_flip = False
    sampled = False
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
                chunk = ""
            if chunk:
                buf += chunk
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    ts = parse_ts(line)
                    if ts is None:
                        continue
                    if "dpu_enc_kickoff:" in line:
                        last_kick = ts
                        wall_kick = time.clock_gettime(time.CLOCK_MONOTONIC)
                        saw_flip = False
                        sampled = False
                        kick.append(ts)
                    elif "dpu_crtc_complete_flip:" in line:
                        flip.append(ts)
                        if last_kick is not None and ts >= last_kick:
                            saw_flip = True
                    elif "drm_vblank_event_delivered:" in line:
                        vbl.append(ts)
            now = time.clock_gettime(time.CLOCK_MONOTONIC)
            if (
                wall_kick is not None
                and not saw_flip
                and not sampled
                and now >= wall_kick + 0.020
            ):
                snaps.append({
                    "at_ms": round((now - wall_kick) * 1000.0, 2),
                    "kms": read_sys(kms),
                    "kms_stack": read_stack(kms),
                    "kworkers": kworkers(),
                })
                sampled = True
            if not chunk:
                time.sleep(0.001)
    finally:
        pipe.close()
        clear()

    # second pass classification + delayed snaps were hard in live loop;
    # do hole classify from lists, and one live snap file if we caught any.
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        f = first_after(flip, a, 0, 20)
        f_late = first_after(flip, a, 20, 280)
        holes.append({
            "gap_ms": round(gap, 1),
            "flip20": f,
            "flip_late": f_late,
            "kind": "flip-ok" if f is not None else "flip-late",
        })

    out = {
        "kind": "kick-noflip",
        "shell": shell,
        "lab": lab,
        "kms": kms,
        "seconds": seconds,
        "kick": summary(kick),
        "flip": summary(flip),
        "vbl": summary(vbl),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
        "kms_now": read_sys(kms),
        "irq": irq_hits(),
        "snaps": snaps[:8],
    }
    Path("/tmp/dagu-kick-noflip.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-kick-noflip-kstack.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-kick-noflip-kstack.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-kick-noflip-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-kick-noflip.json", str(dest)], check=False)
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
