#!/usr/bin/env python3
"""nview-late: which mozjs/gjs entry is in the hole (LR of 62cee0).

Hooks (no poke):
  dpu kickoff/flip
  mutter nview @ 0x1c4440, ifn @ 0x1c4404
  mozjs JS_GC / MaybeGC / IncrementalGCSlice / StartIncrementalGC / gcCycle@0x62cee0
  gjs hammer @ 0xa8624
Do not hook checkOverBudget (too hot). From host:
  python3 linux-mainline/scripts/dagu-nview-gc-entry-probe.py --host
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


def ssh_base():
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_pids():
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
        raise SystemExit(json.dumps({"err": "need ubuntu+lab"}))
    return shell, lab


def map_rx(pid, needle):
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


def parse_ts(line):
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def parse_hex_field(line, key):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0]
    try:
        return int(v, 16)
    except ValueError:
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
        "max": round(max(gaps), 1) if gaps else None,
    }


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def near(xs, t0, lo_ms, hi_ms, limit=12):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    out = []
    for t, extra in xs:
        if lo <= t <= hi:
            rec = {"dt": round((t - t0) * 1000.0, 2)}
            rec.update(extra)
            out.append(rec)
            if len(out) >= limit:
                break
    return out


def resolve_lr(lr, bases):
    if not lr:
        return None
    for name, base in bases.items():
        if base <= lr < base + 0x4000000:
            return f"{name}+{lr - base:#x}"
    return hex(lr)


def install(shell):
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
    mutter = map_rx(shell, "libmutter-18.so.0.0.0")
    mozjs = map_rx(shell, "libmozjs-140.so.140.8.0")
    gjs = map_rx(shell, "libgjs.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mutter}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifn {mutter}:0x1c4404\n".encode())
        os.write(fd, f"p:dagu_jsgc {mozjs}:0x44c6e0\n".encode())
        os.write(fd, f"p:dagu_maybe {mozjs}:0x4521a0\n".encode())
        os.write(fd, f"p:dagu_incs {mozjs}:0x62dda0\n".encode())
        os.write(fd, f"p:dagu_start {mozjs}:0x62dca0\n".encode())
        os.write(fd, f"p:dagu_cycle {mozjs}:0x62cee0 lr=%x30 w1=%x1 w3=%x3\n".encode())
        os.write(fd, f"p:dagu_hammer {gjs}:0xa8624\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    bases = {}
    for line in open(f"/proc/{shell}/maps"):
        if "r-xp" not in line:
            continue
        rng = line.split()[0]
        lo = int(rng.split("-")[0], 16)
        if "libmutter-18.so.0.0.0" in line and "mutter-18/" not in line:
            bases["mutter"] = lo
        elif "libmozjs-140.so.140.8.0" in line:
            bases["mozjs"] = lo
        elif "libgjs.so.0.0.0" in line:
            bases["gjs"] = lo
    return bases


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds=12.0):
    shell, lab = find_pids()
    bases = install(shell)
    kick, flip, nview, ifn = [], [], [], []
    evs = {k: [] for k in ("jsgc", "maybe", "incs", "start", "cycle", "hammer")}
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
                time.sleep(0.002)
                continue
            if not chunk:
                time.sleep(0.002)
                continue
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                ts = parse_ts(line)
                if ts is None:
                    continue
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                elif "dpu_crtc_complete_flip:" in line:
                    flip.append(ts)
                elif "dagu_nview:" in line:
                    nview.append(ts)
                elif "dagu_ifn:" in line:
                    ifn.append(ts)
                else:
                    for name in evs:
                        if f"dagu_{name}:" in line:
                            extra = {}
                            if name == "cycle":
                                lr = parse_hex_field(line, "lr")
                                extra = {
                                    "lr": hex(lr) if lr else None,
                                    "sym": resolve_lr(lr, bases),
                                    "w1": parse_hex_field(line, "w1"),
                                    "w3": parse_hex_field(line, "w3"),
                                }
                            evs[name].append((ts, extra))
                            break
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n_dt = first_after(nview, a, 0, 20)
        kind = "ifn-idle" if n_dt is not None else "nview-late"
        rec = {
            "gap_ms": round(gap, 1),
            "kind": kind,
            "flip": first_after(flip, a, 0, 20),
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 20),
        }
        for name in evs:
            rec[name] = near(evs[name], a, -5, 280)
        rec["counts"] = {name: len(rec[name]) for name in evs}
        holes.append(rec)

    lr_all = Counter()
    lr_hole = Counter()
    for _, extra in evs["cycle"]:
        lr_all[extra.get("sym") or "?"] += 1
    for h in holes:
        if h["kind"] != "nview-late":
            continue
        for c in h["cycle"]:
            lr_hole[c.get("sym") or "?"] += 1

    out = {
        "kind": "nview-gc-entry",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "bases": {k: hex(v) for k, v in bases.items()},
        "kick": summary(kick),
        "flip": summary(flip),
        "n_nview": len(nview),
        "n_ifn": len(ifn),
        "n_events": {k: len(v) for k, v in evs.items()},
        "cycle_lr_all": lr_all.most_common(12),
        "cycle_lr_nview_late": lr_hole.most_common(12),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-nview-gc-entry.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-nview-gc-entry-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-nview-gc-entry-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-nview-gc-entry-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-nview-gc-entry.json", str(dest)], check=False)
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
