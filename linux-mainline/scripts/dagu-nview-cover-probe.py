#!/usr/bin/env python3
"""Which stock function covers nview-late / ifn-idle (entry+ret durations).

Never hook 0x1c4404 / 0x1d2b80. ifn via stock cbz at 0x1c4388 (x1=next).
  nview mutter 0x1c4440
  jsgc  mozjs  0x44c6e0
  paint clutter 0x959d0
  clock clutter 0x73c0c
  hammer gjs 0xa8624
From host: python3 linux-mainline/scripts/dagu-nview-cover-probe.py --host
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
    clutter = map_rx(shell, "libmutter-clutter-18.so.0.0.0")
    mozjs = map_rx(shell, "libmozjs-140.so.140.8.0")
    gjs = map_rx(shell, "libgjs.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mutter}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mutter}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_jsgc {mozjs}:0x44c6e0\n".encode())
        os.write(fd, f"r:dagu_jsgcret {mozjs}:0x44c6e0\n".encode())
        os.write(fd, f"p:dagu_paint {clutter}:0x959d0\n".encode())
        os.write(fd, f"r:dagu_paintret {clutter}:0x959d0\n".encode())
        os.write(fd, f"p:dagu_clock {clutter}:0x73c0c\n".encode())
        os.write(fd, f"r:dagu_clockret {clutter}:0x73c0c\n".encode())
        os.write(fd, f"p:dagu_hammer {gjs}:0xa8624\n".encode())
        os.write(fd, f"r:dagu_hammerret {gjs}:0xa8624\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    p = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if p.is_file():
        p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def pair_dur(ents, rets):
    out = []
    ri = 0
    for t0 in ents:
        while ri < len(rets) and rets[ri] < t0:
            ri += 1
        if ri < len(rets):
            out.append((t0, (rets[ri] - t0) * 1000.0))
            ri += 1
    return out


def covering(pairs, a, b, min_ms=8.0):
    hits = []
    for t0, dur in pairs:
        t1 = t0 + dur / 1000.0
        if t1 < a or t0 > b:
            continue
        if dur >= min_ms:
            hits.append({
                "dt": round((t0 - a) * 1000.0, 2),
                "dur": round(dur, 2),
            })
    return hits


def on_device(seconds=12.0):
    shell, lab = find_pids()
    install(shell)
    kick, flip, nview, ifn = [], [], [], []
    ents = {k: [] for k in ("jsgc", "paint", "clock", "hammer")}
    rets = {k: [] for k in ents}
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
                elif "dagu_ifnchk:" in line:
                    nxt = parse_hex_field(line, "next")
                    if nxt == 0:
                        ifn.append(ts)
                else:
                    for name in ents:
                        if f"dagu_{name}ret:" in line:
                            rets[name].append(ts)
                            break
                        if f"dagu_{name}:" in line:
                            ents[name].append(ts)
                            break
    finally:
        pipe.close()
        clear()

    pairs = {k: pair_dur(ents[k], rets[k]) for k in ents}
    long = {k: [round(d, 2) for _, d in pairs[k] if d >= 8][:8] for k in ents}

    holes = []
    cover_n = Counter()
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
        rec = {
            "gap_ms": round(gap, 1),
            "kind": kind,
            "flip": first_after(flip, a, 0, 20),
            "nview": first_after(nview, a, 0, 280),
            "ifn": ifn_dt,
        }
        for name in ents:
            rec[name] = covering(pairs[name], a, b, 8.0)
            if rec[name]:
                cover_n[f"{kind}:{name}"] += 1
        holes.append(rec)

    out = {
        "kind": "nview-cover",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_nview": len(nview),
        "n_ifn": len(ifn),
        "n_ent": {k: len(v) for k, v in ents.items()},
        "n_ge8": {k: len(long[k]) for k in ents},
        "ge8_ms": long,
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "cover": dict(cover_n),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-nview-cover.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-nview-cover-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-nview-cover-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-nview-cover-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-nview-cover.json", str(dest)], check=False)
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
