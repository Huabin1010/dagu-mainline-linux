#!/usr/bin/env python3
"""Order of queue_frame_callbacks / emit / GTK thaw vs nview in kickoff holes.

From host: python3 linux-mainline/scripts/dagu-addcb-probe.py --host
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

MUTTER = {
    "dagu_emit": "0x167340",
    "dagu_sendcb": "0x1673f0",
    "dagu_nview": "0x1c4440",
    "dagu_mpost": "0x1c1b20",
    "dagu_atomic": "0x1b4878",
}
GTK = {
    "dagu_fcb": "0x518a40",
    "dagu_thaw": "0x5a4da0",
    "dagu_apaint": "0x518c60",
}


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
        elif cmd.startswith(b"python3\x00/usr/local/sbin/dagu-native-lab.py"):
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
    raise SystemExit(f"no r-xp {needle} pid={pid}")


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def install(shell: int, lab: int) -> list[str]:
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
        "mutter": map_rx(shell, "libmutter-18.so.0.0.0"),
        "gtk": map_rx(lab, "libgtk-4.so.1.2200.4"),
    }
    installed = []
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        for name, off in MUTTER.items():
            os.write(fd, f"p:{name} {maps['mutter']}:{off}\n".encode())
            installed.append(name)
        for name, off in GTK.items():
            os.write(fd, f"p:{name} {maps['gtk']}:{off}\n".encode())
            installed.append(name)
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    return installed


def clear() -> None:
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    p = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if p.is_file():
        p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    installed = install(shell, lab)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    names = list(MUTTER) + list(GTK)
    kick: list[float] = []
    flip: list[float] = []
    evs: list[dict] = []
    for line in raw.splitlines():
        ts = parse_ts(line)
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
            continue
        if "dpu_crtc_complete_flip:" in line:
            flip.append(ts)
            continue
        for name in names:
            if f"{name}:" in line:
                evs.append({"t": ts, "n": name})
                break

    def rel(name: str, t0: float, lo: float, hi: float) -> list[float]:
        return [round((e["t"] - t0) * 1000.0, 2) for e in evs if e["n"] == name and lo <= e["t"] <= hi]

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        rec = {
            "gap_ms": round(gap, 1),
            "flip": [round((x - a) * 1000.0, 2) for x in flip if a - 0.008 <= x <= b + 0.004][:6],
        }
        for name in names:
            xs = rel(name, a, a - 0.006, b + 0.004)
            rec[name] = xs[:8] + xs[-2:]
        nview = rec["dagu_nview"]
        emit = rec["dagu_emit"]
        sendcb = rec["dagu_sendcb"]
        fcb = rec["dagu_fcb"]
        atomic = rec["dagu_atomic"]
        early_n = [x for x in nview if 2 <= x <= 15]
        late_n = [x for x in nview if x >= 40]
        early_at = [x for x in atomic if 2 <= x <= 15]
        early_em = [x for x in emit if 2 <= x <= 15]
        early_cb = [x for x in sendcb if 2 <= x <= 15]
        early_fcb = [x for x in fcb if 2 <= x <= 15]
        if early_n and not early_at:
            rec["kind"] = "nview-no-post"
        elif late_n and not early_n:
            rec["kind"] = "nview-late"
        else:
            rec["kind"] = "other"
        rec["emit_when"] = "early" if early_em else ("late" if emit else "none")
        rec["sendcb_when"] = "early" if early_cb else ("late" if sendcb else "none")
        rec["fcb_when"] = "early" if early_fcb else ("late" if fcb else "none")
        holes.append(rec)

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

    out = {
        "kind": "addcb",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "counts": dict(Counter(e["n"] for e in evs)),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "emit_when": dict(Counter(h["emit_when"] for h in holes)),
        "sendcb_when": dict(Counter(h["sendcb_when"] for h in holes)),
        "fcb_when": dict(Counter(h["fcb_when"] for h in holes)),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-addcb.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-addcb-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-addcb-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-addcb-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-addcb.json", str(dest)], check=False)
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
