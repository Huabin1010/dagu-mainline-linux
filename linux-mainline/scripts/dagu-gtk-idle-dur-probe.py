#!/usr/bin/env python3
"""Duration of GTK paint_idle / gsk_renderer_render vs mutter ifn/sendcb.

Uses uretprobe on:
  paint_idle          gtk 0x573a64
  gsk_renderer_render gtk 0x5dfc40

No poke. From host: python3 linux-mainline/scripts/dagu-gtk-idle-dur-probe.py --host
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

FUNCS = {
    "idle": ("libgtk-4.so.1.2200.4", "0x573a64", "lab"),
    "gsk": ("libgtk-4.so.1.2200.4", "0x5dfc40", "lab"),
}
PLAIN = {
    "dagu_ifn": ("libmutter-18.so.0.0.0", "0x1c4404", "shell"),
    "dagu_sendcb": ("libmutter-18.so.0.0.0", "0x1673f0", "shell"),
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440", "shell"),
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
    raise SystemExit(f"no r-xp {needle} pid={pid}")


def parse_ts(line: str):
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def install(shell: int, lab: int) -> list[str]:
    maps = {
        "shell:libmutter-18.so.0.0.0": map_rx(shell, "libmutter-18.so.0.0.0"),
        "lab:libgtk-4.so.1.2200.4": map_rx(lab, "libgtk-4.so.1.2200.4"),
    }
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
    installed = []
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        for name, (lib, off, who) in PLAIN.items():
            path = maps[f"{who}:{lib}"]
            line = f"p:{name} {path}:{off}\n"
            try:
                os.write(fd, line.encode())
                installed.append(name)
            except OSError as e:
                installed.append(f"{name}:FAIL:{e}")
        for name, (lib, off, who) in FUNCS.items():
            path = maps[f"{who}:{lib}"]
            for kind, pref in (("e", "p"), ("r", "r")):
                n = f"dagu_{name}{kind}"
                line = f"{pref}:{n} {path}:{off}\n"
                try:
                    os.write(fd, line.encode())
                    installed.append(n)
                except OSError as e:
                    installed.append(f"{n}:FAIL:{e}")
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    return installed


def clear() -> None:
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "tracing_on").write_text("1\n")


def summary(xs):
    gaps = [1000.0 * (b - a) for a, b in zip(xs, xs[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (xs[-1] - xs[0]) if len(xs) > 1 else 0
    return {
        "n": len(xs),
        "hz": round(len(xs) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
    }


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    installed = install(shell, lab)
    kick: list[float] = []
    evs: list[dict] = []
    longs: list[dict] = []
    pending: dict[str, float] = {}
    counts: Counter[str] = Counter()
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
                for name in ("idle", "gsk"):
                    if f"dagu_{name}e:" in line:
                        pending[name] = ts
                        counts[name] += 1
                    elif f"dagu_{name}r:" in line and name in pending:
                        dur = (ts - pending[name]) * 1000.0
                        if dur >= 8:
                            longs.append({"n": name, "t": pending[name], "dur_ms": round(dur, 2)})
                        del pending[name]
                for name in ("dagu_ifn", "dagu_sendcb", "dagu_nview"):
                    if f"{name}:" in line:
                        evs.append({"t": ts, "n": name})
                        counts[name] += 1
    finally:
        pipe.close()
        clear()
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        def first(name, lo=0.2):
            for e in evs:
                dt = (e["t"] - a) * 1000.0
                if e["n"] == name and lo <= dt <= gap + 4:
                    return round(dt, 2)
            return None
        hl = [
            {"n": x["n"], "enter_ms": round((x["t"] - a) * 1000.0, 2), "dur_ms": x["dur_ms"]}
            for x in longs if a - 0.008 <= x["t"] <= b + 0.004
        ]
        holes.append({
            "gap_ms": round(gap, 1),
            "ifn0": first("dagu_ifn", -8),
            "nview0": first("dagu_nview"),
            "send0": first("dagu_sendcb", -8),
            "longs": hl,
        })
    out = {
        "kind": "gtk-idle-dur",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "counts": dict(counts),
        "long_n": len(longs),
        "longs_ge50": [x for x in longs if x["dur_ms"] >= 50][:8],
        "holes": holes[:8],
    }
    Path("/tmp/dagu-gtk-idle-dur.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-gtk-idle-dur-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-gtk-idle-dur-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-gtk-idle-dur-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-gtk-idle-dur.json", str(dest)], check=False)
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
