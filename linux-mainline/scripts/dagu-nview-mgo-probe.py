#!/usr/bin/env python3
"""After on-time nview, why is mgo 90–210ms late?

Live so (objdump /tmp/dagu-so/libmutter-18.so.0.0.0):
  nview  0x1c4440  notify_view_crtc_presented
  ifn    0x1c4404  ifgl next==NULL ret
  ifnr   0x1c4400  ifgl next exists but !is_ready ret
  mpost  0x1c1b20  maybe_post_next_frame
  mgo    0x1c1c04  posted==NULL go-post
  paint  mutter 0xc52a8 / 0xc52ac  bl clutter_stage_paint_view
  fcdisp clutter 0x73c0c  clutter_frame_clock_dispatch

No poke. From host: python3 linux-mainline/scripts/dagu-nview-mgo-probe.py --host
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
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440"),
    "dagu_ifn": ("libmutter-18.so.0.0.0", "0x1c4404"),
    "dagu_ifnr": ("libmutter-18.so.0.0.0", "0x1c4400"),
    "dagu_mpost": ("libmutter-18.so.0.0.0", "0x1c1b20"),
    "dagu_mgo": ("libmutter-18.so.0.0.0", "0x1c1c04"),
    "dagu_painte": ("libmutter-18.so.0.0.0", "0xc52a8"),
    "dagu_paintr": ("libmutter-18.so.0.0.0", "0xc52ac"),
    "dagu_fcdisp": ("libmutter-clutter-18.so", "0x73c0c"),
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
        if name:
            evs.append({"t": ts, "n": name})
    return kick, evs


def first_after(evs, t0, name, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for e in evs:
        if e["n"] == name and lo <= e["t"] <= hi:
            return round((e["t"] - t0) * 1000.0, 2)
    return None


def rel(evs, t0, lo, hi):
    return [{"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
            for e in evs if lo <= e["t"] <= hi]


def paint_longs(evs, t0, gap):
    out = []
    pending = None
    for e in evs:
        dt = (e["t"] - t0) * 1000.0
        if dt < -8 or dt > gap + 4:
            continue
        if e["n"] == "dagu_painte":
            pending = e["t"]
        elif e["n"] == "dagu_paintr" and pending is not None:
            dur = (e["t"] - pending) * 1000.0
            if dur >= 8:
                out.append({
                    "enter_ms": round((pending - t0) * 1000.0, 2),
                    "dur_ms": round(dur, 2),
                })
            pending = None
    return out


def classify(rec):
    nview = rec.get("nview0")
    mgo = rec.get("mgo0")
    ifn = rec.get("ifn0")
    ifnr = rec.get("ifnr0")
    mpost = rec.get("mpost0")
    paints = rec.get("paint_ge8") or []
    if paints:
        return "long-paint"
    if nview is not None and nview < 12:
        if mgo is not None and mgo < 12:
            return "nview-mgo-early-late-kick"
        if ifnr is not None and ifnr < 12 and (mgo is None or mgo > 50):
            return "nview-ifnr-wait-ready"
        if ifn is not None and ifn < 12 and (mgo is None or mgo > 50):
            return "nview-ifn-no-next"
        if mpost is not None and mpost < 12 and (mgo is None or mgo > 50):
            return "nview-mpost-no-mgo"
        if mgo is None or mgo > 50:
            return "nview-ok-silence"
    if nview is None or nview > 50:
        return "nview-late"
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
        for name, (lib, off) in SITES.items():
            line = f"p:{name} {maps[lib]}:{off}\n"
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
        rec = {
            "gap_ms": round(gap, 1),
            "nview0": first_after(evs, a, "dagu_nview", -8, gap + 4),
            "ifn0": first_after(evs, a, "dagu_ifn", -8, gap + 4),
            "ifnr0": first_after(evs, a, "dagu_ifnr", -8, gap + 4),
            "mpost0": first_after(evs, a, "dagu_mpost", -8, gap + 4),
            "mgo0": first_after(evs, a, "dagu_mgo", 0.2, gap + 4),
            "fcdisp0": first_after(evs, a, "dagu_fcdisp", -8, gap + 4),
            "paint_ge8": paint_longs(evs, a, gap),
            "pre": rel(evs, a, a - 0.008, a + 0.002),
            "inside": rel(evs, a, a + 0.002, b - 0.002),
            "close": rel(evs, a, b - 0.02, b + 0.004),
        }
        rec["kind"] = classify(rec)
        kinds[rec["kind"]] += 1
        holes.append(rec)
    out = {
        "kind": "nview-mgo",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "counts": dict(Counter(e["n"] for e in evs)),
        "kinds": dict(kinds),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-nview-mgo.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-nview-mgo-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-nview-mgo-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-nview-mgo-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-nview-mgo.json", str(dest)], check=False)
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
