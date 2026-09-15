#!/usr/bin/env python3
"""After on-time nview without ifn: mgo/atomic/sched vs late kickoff.

Live offsets:
  nview 0x1c4440  ifn 0x1c4404  mgo 0x1c1c04  atomic 0x1b4878
  sched clutter 0x675a0 st=+88 pend=+396
  qcb 0x1d6e40

No poke. From host: python3 linux-mainline/scripts/dagu-nview-post-probe.py --host
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
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440", "plain"),
    "dagu_ifn": ("libmutter-18.so.0.0.0", "0x1c4404", "plain"),
    "dagu_mgo": ("libmutter-18.so.0.0.0", "0x1c1c04", "plain"),
    "dagu_atomic": ("libmutter-18.so.0.0.0", "0x1b4878", "plain"),
    "dagu_qcb": ("libmutter-18.so.0.0.0", "0x1d6e40", "plain"),
    "dagu_sched": ("libmutter-clutter-18.so", "0x675a0", "clock"),
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
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        rng = line.split()[0]
        mf = f"/proc/{pid}/map_files/{rng}"
        if Path(mf).exists():
            return mf
    raise SystemExit(f"no r-xp {needle}")


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
        st = parse_hex(line, "st")
        pend = parse_hex(line, "pend")
        if st is not None:
            rec["st"] = st
        if pend is not None:
            rec["pend"] = pend
        evs.append(rec)
    return kick, evs


def first_after(evs, t0, name, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for e in evs:
        if e["n"] == name and lo <= e["t"] <= hi:
            out = {"dt": round((e["t"] - t0) * 1000.0, 2)}
            if "st" in e:
                out["st"] = e["st"]
            if "pend" in e:
                out["pend"] = e["pend"]
            return out
    return None


def rel(evs, t0, lo, hi, limit=24):
    out = []
    for e in evs:
        if lo <= e["t"] <= hi:
            rec = {"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
            if "st" in e:
                rec["st"] = e["st"]
            if "pend" in e:
                rec["pend"] = e["pend"]
            out.append(rec)
            if len(out) >= limit:
                break
    return out


def classify(rec):
    nview = rec.get("nview0")
    ifn = rec.get("ifn0")
    mgo = rec.get("mgo_after_nview")
    atm = rec.get("atomic_after_nview")
    if nview is None or nview["dt"] > 20:
        return "nview-late"
    if ifn and ifn["dt"] < nview["dt"] + 2:
        return "nview-ifn"
    if mgo and mgo["dt"] < nview["dt"] + 8:
        if atm and atm["dt"] < mgo["dt"] + 8:
            return "nview-mgo-atomic-early"
        return "nview-mgo-atomic-late"
    return "nview-no-mgo"


def install(shell):
    maps = {
        "libmutter-18.so.0.0.0": map_rx(shell, "libmutter-18.so.0.0.0"),
        "libmutter-clutter-18.so": map_rx(shell, "libmutter-clutter-18.so"),
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
            if kind == "clock":
                line = (
                    f"p:{name} {path}:{off} clock=%x0 st=+88(%x0):u32 "
                    f"pend=+396(%x0):u32\n"
                )
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
    installed = install(shell)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    kick, evs = parse_trace(raw)
    holes = []
    kinds = Counter()
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        nview = first_after(evs, a, "dagu_nview", 0.2, gap + 4)
        base = nview["dt"] if nview else 0.2
        rec = {
            "gap_ms": round(gap, 1),
            "nview0": nview,
            "ifn0": first_after(evs, a, "dagu_ifn", -8, gap + 4),
            "mgo_after_nview": first_after(evs, a, "dagu_mgo", base, gap + 4),
            "atomic_after_nview": first_after(evs, a, "dagu_atomic", base, gap + 4),
            "qcb_after_nview": first_after(evs, a, "dagu_qcb", base, gap + 4),
            "sched_after_nview": first_after(evs, a, "dagu_sched", base, gap + 4),
            "inside": rel(evs, a, a + 0.002, b - 0.002),
        }
        rec["kind"] = classify(rec)
        kinds[rec["kind"]] += 1
        holes.append(rec)
    out = {
        "kind": "nview-post",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "counts": dict(Counter(e["n"] for e in evs)),
        "kinds": dict(kinds),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-nview-post.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-nview-post-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-nview-post-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-nview-post-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-nview-post.json", str(dest)], check=False)
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
