#!/usr/bin/env python3
"""GLib dispatch >=8ms overlapping kickoff holes. No qcb/idlecb (too hot).

Stock: glib blr 0x606f4 / next 0x606f8, x19=GSource, name at +80.
Never hook 0x1c4404 / cave. ifn via 0x1c4388.
From host: python3 linux-mainline/scripts/dagu-gsrc-hole-probe.py --host
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
    }


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def src_name(pid, src):
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(src + 80)
        namep = struct.unpack("<Q", mem.read(8))[0]
        name = "?"
        if namep > 0x1000:
            mem.seek(namep)
            name = mem.read(40).split(b"\x00", 1)[0].decode("ascii", "replace") or "?"
        mem.seek(src + 16)
        funcs = struct.unpack("<Q", mem.read(8))[0]
        disp = 0
        if funcs > 0x1000:
            mem.seek(funcs + 16)
            disp = struct.unpack("<Q", mem.read(8))[0]
        mem.close()
        return f"{name}+{disp:#x}" if disp else name
    except OSError:
        return hex(src)


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
    glib = map_rx(shell, "libglib-2.0.so.0.8800.0")
    mozjs = map_rx(shell, "libmozjs-140.so.140.8.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mutter}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mutter}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_gs {glib}:0x606f4 src=%x19\n".encode())
        os.write(fd, f"p:dagu_ge {glib}:0x606f8\n".encode())
        os.write(fd, f"p:dagu_jsgc {mozjs}:0x44c6e0\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds=12.0):
    shell, lab = find_pids()
    install(shell)
    kick, nview, ifn, jsgc = [], [], [], []
    longs = []
    pending_t = pending_src = None
    name_cache = {}
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
                time.sleep(0.001)
                continue
            if not chunk:
                time.sleep(0.001)
                continue
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                ts = parse_ts(line)
                if ts is None:
                    continue
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                elif "dagu_nview:" in line:
                    nview.append(ts)
                elif "dagu_ifnchk:" in line:
                    if parse_hex_field(line, "next") == 0:
                        ifn.append(ts)
                elif "dagu_jsgc:" in line:
                    jsgc.append(ts)
                elif "dagu_gs:" in line:
                    pending_t = ts
                    pending_src = parse_hex_field(line, "src")
                elif "dagu_ge:" in line and pending_t is not None:
                    dur = (ts - pending_t) * 1000.0
                    if dur >= 8:
                        src = pending_src or 0
                        if src not in name_cache:
                            name_cache[src] = src_name(shell, src)
                        longs.append((pending_t, dur, name_cache[src]))
                    pending_t = pending_src = None
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n_dt = first_after(nview, a, 0, 20)
        ifn_dt = first_after(ifn, a, 0, 20)
        if n_dt is not None and ifn_dt is not None:
            kind = "ifn-idle"
        elif n_dt is not None:
            kind = "nview-ok"
        else:
            kind = "nview-late"
        cov = []
        for t0, dur, name in longs:
            t1 = t0 + dur / 1000.0
            if t1 < a - 0.005 or t0 > b:
                continue
            cov.append({
                "dt": round((t0 - a) * 1000.0, 2),
                "dur": round(dur, 2),
                "name": name,
            })
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": ifn_dt,
            "jsgc": first_after(jsgc, a, -20, 280),
            "long": cov[:6],
        })

    out = {
        "kind": "gsrc-hole",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_long": len(longs),
        "long_names": Counter(n for _, _, n in longs).most_common(12),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-gsrc-hole.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-gsrc-hole-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-gsrc-hole-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-gsrc-hole-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-gsrc-hole.json", str(dest)], check=False)
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
