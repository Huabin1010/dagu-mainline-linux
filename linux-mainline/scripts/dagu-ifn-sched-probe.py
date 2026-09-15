#!/usr/bin/env python3
"""After ifgl next==NULL: is schedule_update late, or dispatch late?

Live offsets:
  ifn    mutter 0x1c4404
  nview  mutter 0x1c4440
  emit   mutter 0x167340
  au     mutter 0x169664
  sched  clutter 0x675a0  clock st=+88 pend=+396
  fcdisp clutter 0x73c0c  clock st=+88 pend=+396
  wlsched mutter 0x16517c  wayland commit → schedule

No poke. From host: python3 linux-mainline/scripts/dagu-ifn-sched-probe.py --host
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
    "dagu_emit": ("libmutter-18.so.0.0.0", "0x167340", "plain"),
    "dagu_au": ("libmutter-18.so.0.0.0", "0x169664", "plain"),
    "dagu_wlsched": ("libmutter-18.so.0.0.0", "0x16517c", "plain"),
    "dagu_sched": ("libmutter-clutter-18.so", "0x675a0", "clock"),
    "dagu_fcdisp": ("libmutter-clutter-18.so", "0x73c0c", "clock"),
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
    raise SystemExit(f"no r-xp {needle}")


def parse_hex_field(line: str, key: str):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0]
    try:
        return int(v, 16)
    except ValueError:
        return None


def parse_trace(raw: str):
    kick: list[float] = []
    evs: list[dict] = []
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
        st = parse_hex_field(line, "st")
        pend = parse_hex_field(line, "pend")
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


def rel(evs, t0, lo, hi):
    out = []
    for e in evs:
        if lo <= e["t"] <= hi:
            rec = {"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
            if "st" in e:
                rec["st"] = e["st"]
            if "pend" in e:
                rec["pend"] = e["pend"]
            out.append(rec)
    return out


def classify(rec):
    ifn = rec.get("ifn0")
    sched = rec.get("sched_after_ifn")
    fc = rec.get("fc_after_ifn")
    wl = rec.get("wl_after_ifn")
    if ifn is None:
        return "no-ifn"
    if sched and sched["dt"] < ifn["dt"] + 8:
        if fc and fc["dt"] > ifn["dt"] + 50:
            return "sched-ok-fcdisp-late"
        return "sched-ok"
    if wl and wl["dt"] < ifn["dt"] + 8:
        return "wl-ok-sched-late"
    if (sched is None or sched["dt"] > ifn["dt"] + 50) and (
        fc is None or fc["dt"] > ifn["dt"] + 50
    ):
        return "ifn-then-idle"
    return "other"


def install(shell: int) -> list[str]:
    maps = {
        "libmutter-18.so.0.0.0": map_rx(shell, "libmutter-18.so.0.0.0"),
        "libmutter-clutter-18.so": map_rx(shell, "libmutter-clutter-18.so"),
    }
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
    en = TR / "events/uprobes/enable"
    if not en.is_file():
        raise SystemExit(json.dumps({"err": "no uprobes", "installed": installed}))
    en.write_text("1\n")
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
    installed = install(shell)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    kick, evs = parse_trace(raw)
    holes = []
    kinds: Counter[str] = Counter()
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        ifn = first_after(evs, a, "dagu_ifn", -8, gap + 4)
        ifn_dt = ifn["dt"] if ifn else 0.2
        rec = {
            "gap_ms": round(gap, 1),
            "ifn0": ifn,
            "nview0": first_after(evs, a, "dagu_nview", 0.2, gap + 4),
            "sched_after_ifn": first_after(evs, a, "dagu_sched", ifn_dt, gap + 4),
            "fc_after_ifn": first_after(evs, a, "dagu_fcdisp", ifn_dt, gap + 4),
            "wl_after_ifn": first_after(evs, a, "dagu_wlsched", ifn_dt, gap + 4),
            "emit_after_ifn": first_after(evs, a, "dagu_emit", ifn_dt, gap + 4),
            "au_after_ifn": first_after(evs, a, "dagu_au", ifn_dt, gap + 4),
            "inside": rel(evs, a, a + 0.002, b - 0.002),
        }
        rec["kind"] = classify(rec)
        kinds[rec["kind"]] += 1
        holes.append(rec)
    out = {
        "kind": "ifn-sched",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "counts": dict(Counter(e["n"] for e in evs)),
        "kinds": dict(kinds),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-ifn-sched.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-ifn-sched-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-ifn-sched-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-ifn-sched-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-ifn-sched.json", str(dest)], check=False)
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
