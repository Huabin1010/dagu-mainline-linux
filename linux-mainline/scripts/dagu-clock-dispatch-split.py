#!/usr/bin/env python3
"""Split long clutter_frame_clock_dispatch into vfunc + nview + GJS.

clutter 0x73c0c dispatch, 0x73fb0 new_frame, 0x74058 before, 0x74244 frame.
gjs 0xa8624 GC idle. mutter nview 0x1c4440.
From host: python3 linux-mainline/scripts/dagu-clock-dispatch-split.py --host
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
    raise SystemExit(f"no r-xp {needle}")


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def install(shell: int) -> None:
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
    (TR / "buffer_size_kb").write_text("32768\n")
    cl = map_rx(shell, "libmutter-clutter-18.so")
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
    gjs = map_rx(shell, "libgjs.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        # GSource wrapper around clock dispatch (enter/ret)
        os.write(fd, f"p:dagu_fce {cl}:0x744c0\n".encode())
        os.write(fd, f"p:dagu_fcr {cl}:0x744f4\n".encode())
        os.write(fd, f"p:dagu_nfr {cl}:0x73fb0\n".encode())
        os.write(fd, f"p:dagu_nfrr {cl}:0x73fb4\n".encode())
        os.write(fd, f"p:dagu_bef {cl}:0x74058\n".encode())
        os.write(fd, f"p:dagu_befr {cl}:0x7405c\n".encode())
        os.write(fd, f"p:dagu_frm {cl}:0x74244\n".encode())
        os.write(fd, f"p:dagu_frmr {cl}:0x74248\n".encode())
        os.write(fd, f"p:dagu_nready {cl}:0x743ec\n".encode())
        os.write(fd, f"p:dagu_nreadyr {cl}:0x743f0\n".encode())
        os.write(fd, f"p:dagu_paint {mu}:0xc52a8\n".encode())
        os.write(fd, f"p:dagu_paintr {mu}:0xc52ac\n".encode())
        os.write(fd, f"p:dagu_swap {mu}:0xc5a34\n".encode())
        os.write(fd, f"p:dagu_swapr {mu}:0xc5a38\n".encode())
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_gjs {gjs}:0xa8624\n".encode())
        os.write(fd, f"p:dagu_gjsr {gjs}:0xa866c\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")


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
    install(shell)
    kick: list[float] = []
    flip: list[float] = []
    nview: list[float] = []
    longs: list[dict] = []
    cur: dict | None = None
    pending: dict[str, float] = {}
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    tag = f"-{shell}"
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
            try:
                chunk = pipe.read(65536)
            except BlockingIOError:
                chunk = ""
            if not chunk:
                time.sleep(0.0002)
                continue
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                ts = parse_ts(line)
                if ts is None:
                    continue
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                    continue
                if "dpu_crtc_complete_flip:" in line:
                    flip.append(ts)
                    continue
                if tag not in line:
                    continue
                if "dagu_nview:" in line:
                    nview.append(ts)
                elif "dagu_fce:" in line:
                    cur = {"t": ts}
                elif "dagu_fcr:" in line and cur is not None:
                    dt = (ts - cur["t"]) * 1000.0
                    cur["dt"] = round(dt, 2)
                    if dt >= 8.0:
                        longs.append(cur)
                    cur = None
                elif "dagu_nfr:" in line:
                    pending["nfr"] = ts
                elif "dagu_nfrr:" in line and "nfr" in pending and cur is not None:
                    cur["nfr"] = round((ts - pending.pop("nfr")) * 1000.0, 2)
                elif "dagu_bef:" in line:
                    pending["bef"] = ts
                elif "dagu_befr:" in line and "bef" in pending and cur is not None:
                    cur["bef"] = round((ts - pending.pop("bef")) * 1000.0, 2)
                elif "dagu_frm:" in line:
                    pending["frm"] = ts
                elif "dagu_frmr:" in line and "frm" in pending and cur is not None:
                    cur["frm"] = round((ts - pending.pop("frm")) * 1000.0, 2)
                elif "dagu_nready:" in line:
                    pending["nready"] = ts
                elif "dagu_nreadyr:" in line and "nready" in pending and cur is not None:
                    cur["nready"] = round((ts - pending.pop("nready")) * 1000.0, 2)
                elif "dagu_paint:" in line:
                    pending["paint"] = ts
                elif "dagu_paintr:" in line and "paint" in pending and cur is not None:
                    cur["paint"] = round((ts - pending.pop("paint")) * 1000.0, 2)
                elif "dagu_swap:" in line:
                    pending["swap"] = ts
                elif "dagu_swapr:" in line and "swap" in pending and cur is not None:
                    cur["swap"] = round((ts - pending.pop("swap")) * 1000.0, 2)
                elif "dagu_gjs:" in line:
                    pending["gjs"] = ts
                elif "dagu_gjsr:" in line and "gjs" in pending:
                    g0 = pending.pop("gjs")
                    gdt = (ts - g0) * 1000.0
                    if cur is not None:
                        cur["gjs"] = round(gdt, 2)
                    if gdt >= 8.0:
                        longs.append({"t": g0, "dt": round(gdt, 2), "only": "gjs"})
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n = [round((x - a) * 1000.0, 2) for x in nview if a - 0.006 <= x <= b + 0.002]
        f = [round((x - a) * 1000.0, 2) for x in flip if a - 0.008 <= x <= b + 0.002]
        early_n = [x for x in n if -2 <= x <= 15]
        late_n = [x for x in n if x >= 40]
        near = []
        for d in longs:
            dt = (d["t"] - a) * 1000.0
            if -15 <= dt <= gap + 2:
                near.append({k: d[k] for k in d if k != "t"} | {"at": round(dt, 2)})
        holes.append({
            "gap_ms": round(gap, 1),
            "flip": f[:4],
            "nview": n[:4],
            "kind": "nview-late" if late_n and not early_n else (
                "nview-ok" if early_n else "other"),
            "long": near[:4],
        })

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
        "kind": "clock-split",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "long_n": len(longs),
        "long_max": sorted(longs, key=lambda d: d.get("dt", 0), reverse=True)[:8],
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-clock-split.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-clock-dispatch-split.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-clock-dispatch-split.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-clock-split-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-clock-split.json", str(dest)], check=False)
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
