#!/usr/bin/env python3
"""Wait-for-present holes: atomic / kickoff / complete_flip / npresent.

No poke. From host: python3 linux-mainline/scripts/dagu-present-late-probe.py --host
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
    "dagu_atomic": ("libmutter-18.so.0.0.0", "0x1b4878", "plain"),
    "dagu_mpost": ("libmutter-18.so.0.0.0", "0x1c1b20", "plain"),
    "dagu_mgo": ("libmutter-18.so.0.0.0", "0x1c1c04", "plain"),
    "dagu_nview": ("libmutter-18.so.0.0.0", "0x1c4440", "plain"),
    "dagu_qcb": ("libmutter-18.so.0.0.0", "0x1d6e40", "plain"),
    "dagu_fcdisp": ("libmutter-clutter-18.so", "0x73c0c", "clock"),
    "dagu_npresent": ("libmutter-clutter-18.so", "0x67cc4", "clock"),
    "dagu_sched": ("libmutter-clutter-18.so", "0x675a0", "clock"),
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


def parse_hex_field(line: str, key: str) -> int | None:
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0]
    try:
        return int(v, 16)
    except ValueError:
        return None


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
        evs.append({
            "t": ts,
            "n": name,
            "clk": parse_hex_field(line, "clock"),
            "st": parse_hex_field(line, "st"),
            "pend": parse_hex_field(line, "pend"),
        })
    return kick, flip, vbl, evs


def rel_ts(xs: list[float], t0: float, lo: float, hi: float) -> list[float]:
    return [round((x - t0) * 1000.0, 2) for x in xs if lo <= x <= hi]


def rel(evs: list[dict], t0: float, lo: float, hi: float) -> list[dict]:
    out = []
    for e in evs:
        if lo <= e["t"] <= hi:
            rec = {"dt": round((e["t"] - t0) * 1000.0, 2), "n": e["n"]}
            if e.get("st") is not None:
                rec["st"] = e["st"]
            if e.get("pend") is not None:
                rec["pend"] = e["pend"]
            out.append(rec)
    return out


def install(shell: int) -> list[str]:
    maps = {
        "libmutter-clutter-18.so": map_rx(shell, "libmutter-clutter-18.so"),
        "libmutter-18.so.0.0.0": map_rx(shell, "libmutter-18.so.0.0.0"),
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
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        holes.append({
            "gap_ms": round(gap, 1),
            "flip": rel_ts(flip, a, a - 0.008, b + 0.004),
            "vbl": rel_ts(vbl, a, a - 0.002, b + 0.002)[:24],
            "vbl_n": len(rel_ts(vbl, a, a, b)),
            "pre": rel(evs, a, a - 0.008, a + 0.002),
            "inside": rel(evs, a, a + 0.002, b - 0.002),
            "close": rel(evs, a, b - 0.02, b + 0.004),
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
    name_n = Counter(e["n"] for e in evs)
    out = {
        "kind": "present-late",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "flip": summary(flip),
        "vblank": summary(vbl),
        "counts": dict(name_n),
        "holes": holes[:8],
    }
    Path("/tmp/dagu-present-late.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-present-late-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-present-late-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-present-late-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-present-late.json", str(dest)], check=False)
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
