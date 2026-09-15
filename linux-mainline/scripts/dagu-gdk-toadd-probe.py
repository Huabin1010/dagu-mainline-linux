#!/usr/bin/env python3
"""Hole-relative GDK timeout_add interval vs sendcb/thaw/paint_idle.

Live GTK 4.22 (objdump /tmp/dagu-so/libgtk-4.so.1.2200.4 + board maps):
  maybe_start_idle paint  g_timeout_add_full @ 0x56efb4  w0=120 w1=interval_ms
  maybe_start_idle flush  g_timeout_add_full @ 0x56f02c  w0=1   w1=interval_ms
  min_interval_us         sub x1,x1,x0        @ 0x56f0ac
  paint_idle              0x573a64
  thaw                    0x5a4da0
  request_phase           0x5733d0

§65 only counted paint-path interval (always 0). This also timestamps
when the timeout is armed vs sendcb, and the flush-path interval.

No poke. From host: python3 linux-mainline/scripts/dagu-gdk-toadd-probe.py --host
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

SITES = {
    "dagu_ifn": ("libmutter-18.so.0.0.0", "0x1c4404", "plain"),
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440", "plain"),
    "dagu_sendcb": ("libmutter-18.so.0.0.0", "0x1673f0", "plain"),
    "dagu_qcb": ("libmutter-18.so.0.0.0", "0x1d6e40", "plain"),
    "dagu_thaw": ("libgtk-4.so.1.2200.4", "0x5a4da0", "plain"),
    "dagu_reqph": ("libgtk-4.so.1.2200.4", "0x5733d0", "plain"),
    "dagu_idle": ("libgtk-4.so.1.2200.4", "0x573a64", "plain"),
    "dagu_paint_to": ("libgtk-4.so.1.2200.4", "0x56efb4", "w1"),
    "dagu_flush_to": ("libgtk-4.so.1.2200.4", "0x56f02c", "w1"),
    "dagu_delay_us": ("libgtk-4.so.1.2200.4", "0x56f0ac", "x1"),
}


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
        raise SystemExit(json.dumps({"err": "need ubuntu+lab", "shell": shell, "lab": lab}))
    return shell, lab


def map_rx(pid, needle):
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" not in line:
            rng = line.split()[0]
            mf = f"/proc/{pid}/map_files/{rng}"
            if Path(mf).exists():
                return mf
            continue
        if needle != "libmutter-18.so.0.0.0":
            rng = line.split()[0]
            mf = f"/proc/{pid}/map_files/{rng}"
            if Path(mf).exists():
                return mf
    raise SystemExit(f"no r-xp {needle} pid={pid}")


def parse_hex(line, key):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0]
    try:
        return int(v, 16)
    except ValueError:
        return None


def parse_trace(raw):
    kick, evs = [], []
    for line in raw.splitlines():
        ts = None
        for part in line.split():
            if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
                ts = float(part[:-1])
                break
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
            continue
        name = None
        for n in SITES:
            if f"{n}:" in line:
                name = n
                break
        if not name:
            continue
        rec = {"t": ts, "n": name}
        w1 = parse_hex(line, "w1")
        x1 = parse_hex(line, "x1")
        if w1 is not None:
            rec["w1"] = w1
        if x1 is not None:
            rec["x1"] = x1
        evs.append(rec)
    return kick, evs


def first_after(evs, t0, name, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for e in evs:
        if e["n"] == name and lo <= e["t"] <= hi:
            out = {"dt": round((e["t"] - t0) * 1000.0, 2)}
            if "w1" in e:
                out["ms"] = e["w1"]
            if "x1" in e:
                out["us"] = e["x1"]
            return out
    return None


def rel(evs, t0, lo, hi, limit=48):
    out = []
    for e in evs:
        if lo <= e["t"] <= hi:
            rec = {"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
            if "w1" in e:
                rec["ms"] = e["w1"]
            if "x1" in e:
                rec["us"] = e["x1"]
            out.append(rec)
            if len(out) >= limit:
                break
    return out


def classify(rec):
    nview = rec.get("nview0")
    ifn = rec.get("ifn0")
    send = rec.get("send0")
    idle = rec.get("idle0")
    pto = rec.get("paint_to0")
    if nview is None or nview["dt"] > 20:
        return "nview-late"
    if ifn and ifn["dt"] < (nview["dt"] + 2):
        return "nview-ifn"
    if send and send["dt"] < 20 and idle and idle["dt"] > 50:
        return "sendcb-ok-idle-late"
    if pto and pto["dt"] > 50:
        return "toadd-late"
    if pto and pto.get("ms", 0) >= 20:
        return "toadd-long-interval"
    return "other"


def install(shell, lab):
    maps = {
        "libmutter-18.so.0.0.0": map_rx(shell, "libmutter-18.so.0.0.0"),
        "libgtk-4.so.1.2200.4": map_rx(lab, "libgtk-4.so.1.2200.4"),
    }
    (TR / "tracing_on").write_text("0\n")
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    ue = TR / "uprobe_events"
    try:
        ue.write_text("")
    except OSError:
        time.sleep(0.05)
        ue.write_text("")
    installed = []
    fd = os.open(str(ue), os.O_WRONLY | os.O_APPEND)
    try:
        for name, (lib, off, kind) in SITES.items():
            path = maps[lib]
            if kind == "w1":
                line = f"p:{name} {path}:{off} w1=%x1\n"
            elif kind == "x1":
                line = f"p:{name} {path}:{off} x1=%x1\n"
            else:
                line = f"p:{name} {path}:{off}\n"
            try:
                os.write(fd, line.encode())
                installed.append(name)
            except OSError as e:
                installed.append(f"{name}:FAIL:{e}")
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    return installed


def clear():
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


def on_device(seconds=8.0):
    shell, lab = find_pids()
    installed = install(shell, lab)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    kick, evs = parse_trace(raw)
    paint_ms = Counter()
    flush_ms = Counter()
    delay_us = []
    for e in evs:
        if e["n"] == "dagu_paint_to" and "w1" in e:
            paint_ms[e["w1"]] += 1
        elif e["n"] == "dagu_flush_to" and "w1" in e:
            flush_ms[e["w1"]] += 1
        elif e["n"] == "dagu_delay_us" and "x1" in e:
            delay_us.append(e["x1"])
    holes = []
    kinds = Counter()
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        rec = {
            "gap_ms": round(gap, 1),
            "nview0": first_after(evs, a, "dagu_nview", 0.2, gap + 4),
            "ifn0": first_after(evs, a, "dagu_ifn", -8, gap + 4),
            "send0": first_after(evs, a, "dagu_sendcb", -8, gap + 4),
            "qcb0": first_after(evs, a, "dagu_qcb", -8, gap + 4),
            "thaw0": first_after(evs, a, "dagu_thaw", -8, gap + 4),
            "req0": first_after(evs, a, "dagu_reqph", -8, gap + 4),
            "idle0": first_after(evs, a, "dagu_idle", -8, gap + 4),
            "paint_to0": first_after(evs, a, "dagu_paint_to", -8, gap + 4),
            "flush_to0": first_after(evs, a, "dagu_flush_to", -8, gap + 4),
            "delay0": first_after(evs, a, "dagu_delay_us", -8, gap + 4),
            "inside": rel(evs, a, a - 0.004, b + 0.002),
        }
        rec["kind"] = classify(rec)
        kinds[rec["kind"]] += 1
        holes.append(rec)
    delay_ms = [round(u / 1000.0, 1) for u in delay_us if u < (1 << 40)]
    out = {
        "kind": "gdk-toadd",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "counts": dict(Counter(e["n"] for e in evs)),
        "paint_interval_ms": dict(paint_ms),
        "flush_interval_ms": dict(flush_ms),
        "delay_us_n": len(delay_us),
        "delay_us_ge20ms": sum(1 for u in delay_us if u >= 20000),
        "delay_us_p50": sorted(delay_ms)[len(delay_ms) // 2] if delay_ms else None,
        "delay_us_max_ms": max(delay_ms) if delay_ms else None,
        "kinds": dict(kinds),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-gdk-toadd.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-gdk-toadd-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-gdk-toadd-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-gdk-toadd-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-gdk-toadd.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main():
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
