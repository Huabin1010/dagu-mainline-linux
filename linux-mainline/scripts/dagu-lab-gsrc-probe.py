#!/usr/bin/env python3
"""Lab GLib source dispatch duration vs mutter sendcb/ifn and kickoff holes.

Live glib 2.88 dispatch blr 0x606f4, x19=GSource, name at +80.
No poke. From host: python3 linux-mainline/scripts/dagu-lab-gsrc-probe.py --host
"""
from __future__ import annotations

import json
import os
import struct
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


def parse_hex(line: str, key: str):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0]
    try:
        return int(v, 16)
    except ValueError:
        return None


def src_name(pid: int, src: int) -> str:
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(src + 40)
        prio = struct.unpack("<i", mem.read(4))[0]
        mem.seek(src + 80)
        namep = struct.unpack("<Q", mem.read(8))[0]
        name = "?"
        if namep > 0x1000:
            mem.seek(namep)
            name = mem.read(40).split(b"\x00", 1)[0].decode("ascii", "replace") or "?"
        mem.close()
        return f"{name}@p{prio}"
    except OSError:
        return hex(src)


def install(shell: int, lab: int) -> list[str]:
    glib = map_rx(lab, "libglib-2.0.so.0.8800.0")
    mutter = map_rx(shell, "libmutter-18.so.0.0.0")
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
    installed = []
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        for name, path, off, extra in (
            ("dagu_lgs", glib, "0x606f4", " src=%x19"),
            ("dagu_lge", glib, "0x606f8", ""),
            ("dagu_ifn", mutter, "0x1c4404", ""),
            ("dagu_sendcb", mutter, "0x1673f0", ""),
            ("dagu_nview", mutter, "0x1c4440", ""),
        ):
            line = f"p:{name} {path}:{off}{extra}\n"
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
    pending_t = None
    pending_src = None
    name_cache: dict[int, str] = {}
    counts: Counter[str] = Counter()
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    lab_tag = f"-{lab}"
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
                if "dagu_lgs:" in line and lab_tag in line:
                    pending_t = ts
                    pending_src = parse_hex(line, "src")
                    counts["lgs"] += 1
                elif "dagu_lge:" in line and lab_tag in line and pending_t is not None:
                    dur = (ts - pending_t) * 1000.0
                    if dur >= 8 and pending_src:
                        nm = name_cache.get(pending_src)
                        if nm is None:
                            nm = src_name(lab, pending_src)
                            name_cache[pending_src] = nm
                        longs.append({"t": pending_t, "dur_ms": round(dur, 2), "src": hex(pending_src), "name": nm})
                    pending_t = None
                    pending_src = None
                else:
                    for n in ("dagu_ifn", "dagu_sendcb", "dagu_nview"):
                        if f"{n}:" in line:
                            evs.append({"t": ts, "n": n})
                            counts[n] += 1
                            break
    finally:
        pipe.close()
        clear()
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        def first(name, lo=-8.0):
            for e in evs:
                dt = (e["t"] - a) * 1000.0
                if e["n"] == name and lo <= dt <= gap + 4:
                    return round(dt, 2)
            return None
        hl = [
            {"enter_ms": round((x["t"] - a) * 1000.0, 2), "dur_ms": x["dur_ms"], "name": x["name"]}
            for x in longs if a - 0.004 <= x["t"] <= b + 0.002
        ]
        holes.append({
            "gap_ms": round(gap, 1),
            "ifn0": first("dagu_ifn"),
            "nview0": first("dagu_nview", 0.2),
            "send0": first("dagu_sendcb"),
            "lab_ge8": hl,
        })
    name_n = Counter(x["name"] for x in longs)
    out = {
        "kind": "lab-gsrc",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "installed": installed,
        "kick": summary(kick),
        "counts": dict(counts),
        "long_n": len(longs),
        "long_names": dict(name_n),
        "longs_ge50": [x for x in longs if x["dur_ms"] >= 50][:8],
        "holes": holes[:8],
    }
    Path("/tmp/dagu-lab-gsrc.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-lab-gsrc-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-lab-gsrc-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-lab-gsrc-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}; not pulling stale json")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-lab-gsrc.json", str(dest)], check=False)
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
