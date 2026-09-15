#!/usr/bin/env python3
"""Split mgo → post_update → asyncimpl → drmModeAtomicCommit on Type B holes.

Live so offsets (objdump of /tmp/dagu-so/libmutter-18.so.0.0.0):
  mgo        0x1c1c04  maybe_post posted==NULL path
  postul     0x1aaeec  meta_kms_device_post_update
  asyncimpl  0x1affd0  process_async_update_in_impl
  atomic     0x1b4878  drmModeAtomicCommit@plt

No poke. From host: python3 linux-mainline/scripts/dagu-mgo-atomic-probe.py --host
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
    "dagu_mgo": ("libmutter-18.so.0.0.0", "0x1c1c04"),
    "dagu_postul": ("libmutter-18.so.0.0.0", "0x1aaeec"),
    "dagu_asyncimpl": ("libmutter-18.so.0.0.0", "0x1affd0"),
    "dagu_atomic": ("libmutter-18.so.0.0.0", "0x1b4878"),
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440"),
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


def parse_trace(raw: str) -> tuple[list[float], list[float], list[float], list[dict]]:
    kick: list[float] = []
    flip: list[float] = []
    vbl: list[float] = []
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
        if "dpu_crtc_complete_flip:" in line:
            flip.append(ts)
            continue
        if "dpu_crtc_vblank_cb:" in line:
            vbl.append(ts)
            continue
        name = None
        for n in SITES:
            if f"{n}:" in line:
                name = n
                break
        if not name:
            continue
        evs.append({"t": ts, "n": name})
    return kick, flip, vbl, evs


def rel_ts(xs: list[float], t0: float, lo: float, hi: float) -> list[float]:
    return [round((x - t0) * 1000.0, 2) for x in xs if lo <= x <= hi]


def rel(evs: list[dict], t0: float, lo: float, hi: float) -> list[dict]:
    return [{"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
            for e in evs if lo <= e["t"] <= hi]


def first_after(evs: list[dict], t0: float, name: str, lo_ms: float, hi_ms: float):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for e in evs:
        if e["n"] == name and lo <= e["t"] <= hi:
            return round((e["t"] - t0) * 1000.0, 2)
    return None


def classify(hole: dict) -> str:
    mgo = hole.get("mgo0")
    post = hole.get("postul0")
    impl = hole.get("async0")
    atm = hole.get("atomic0")
    if mgo is None:
        return "no-mgo"
    if post is None or (post - mgo) > 8:
        return "mgo-no-postul"
    if impl is None or (impl - post) > 8:
        return "postul-no-asyncimpl"
    if atm is None or (atm - impl) > 8:
        return "asyncimpl-no-atomic"
    if atm > 50:
        return "atomic-on-time-then-late-kick"
    return "pipeline-ok-other"


def install(shell: int) -> list[str]:
    path = map_rx(shell, "libmutter-18.so.0.0.0")
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
        for name, (_lib, off) in SITES.items():
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
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_vblank_cb/enable").write_text("1\n")
    return installed


def clear() -> None:
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    for relpath in (
        "events/dpu/dpu_crtc_complete_flip/enable",
        "events/dpu/dpu_crtc_vblank_cb/enable",
    ):
        p = TR / relpath
        if p.is_file():
            p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


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


def on_device(seconds: float = 8.0) -> int:
    shell, lab = find_pids()
    installed = install(shell)
    (TR / "tracing_on").write_text("1\n")
    time.sleep(seconds)
    (TR / "tracing_on").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    clear()
    kick, flip, vbl, evs = parse_trace(raw)
    holes = []
    kinds: Counter[str] = Counter()
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        mgo0 = first_after(evs, a, "dagu_mgo", 0.2, gap + 4)
        if mgo0 is None:
            mgo0 = first_after(evs, a, "dagu_mgo", -8, gap + 4)
        rec = {
            "gap_ms": round(gap, 1),
            "flip": rel_ts(flip, a, a - 0.008, b + 0.004),
            "vbl_n": len(rel_ts(vbl, a, a, b)),
            "mgo0": mgo0,
            "postul0": first_after(evs, a, "dagu_postul", (mgo0 if mgo0 is not None else 0.2), gap + 4),
            "async0": first_after(evs, a, "dagu_asyncimpl", (mgo0 if mgo0 is not None else 0.2), gap + 4),
            "atomic0": first_after(evs, a, "dagu_atomic", (mgo0 if mgo0 is not None else 0.2), gap + 4),
            "nview0": first_after(evs, a, "dagu_nview", -8, gap + 4),
            "inside": rel(evs, a, a + 0.002, b - 0.002),
            "close": rel(evs, a, b - 0.02, b + 0.004),
        }
        rec["kind"] = classify(rec)
        kinds[rec["kind"]] += 1
        holes.append(rec)
    out = {
        "kind": "mgo-atomic",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "flip": summary(flip),
        "vblank": summary(vbl),
        "counts": dict(Counter(e["n"] for e in evs)),
        "kinds": dict(kinds),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-mgo-atomic.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-mgo-atomic-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-mgo-atomic-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-mgo-atomic-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-mgo-atomic.json", str(dest)], check=False)
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
