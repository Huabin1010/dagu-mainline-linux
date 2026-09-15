#!/usr/bin/env python3
"""ifn-emit applied: why cave emit (nview+2, no au) does not send.

Stock sites only — never hook 0x1c4404 / 0x1d2b80.
  emit 0x167340  actor 0x1673b0  vis 0x1673c8  empty 0x167404
  send 0x1673f0  nview 0x1c4440  au 0x1696c0
From host: python3 linux-mainline/scripts/dagu-cave-emit-why-probe.py --host
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
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


def near(xs, t0, lo_ms, hi_ms, limit=8):
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
    mf = map_rx(shell, "libmutter-18.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mf}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_emit {mf}:0x167340\n".encode())
        os.write(fd, f"p:dagu_actor {mf}:0x1673b0 x0=%x0\n".encode())
        os.write(fd, f"p:dagu_empty {mf}:0x167404 x0=%x0\n".encode())
        os.write(fd, f"p:dagu_send {mf}:0x1673f0\n".encode())
        os.write(fd, f"p:dagu_au {mf}:0x1696c0\n".encode())
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
    kick, nview, au, send = [], [], [], []
    emit, actor, vis, empty = [], [], [], []
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
                elif "dagu_nview:" in line:
                    nview.append(ts)
                elif "dagu_au:" in line:
                    au.append(ts)
                elif "dagu_send:" in line:
                    send.append(ts)
                elif "dagu_emit:" in line:
                    emit.append((ts, {}))
                elif "dagu_actor:" in line:
                    v = parse_hex_field(line, "x0") or 0
                    actor.append((ts, {"x0": hex(v), "zero": v == 0}))
                elif "dagu_vis:" in line:
                    v = parse_hex_field(line, "x0") or 0
                    vis.append((ts, {"x0": hex(v), "zero": v == 0}))
                elif "dagu_empty:" in line:
                    v = parse_hex_field(line, "x0") or 0
                    empty.append((ts, {"x0": hex(v), "yes": v == 1}))
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n_dt = first_after(nview, a, 0, 20)
        au_early = first_after(au, a, 0, 20)
        rec = {
            "gap_ms": round(gap, 1),
            "kind": "ifn-idle" if n_dt is not None else "nview-late",
            "nview": first_after(nview, a, 0, 280),
            "au": au_early,
            "emit": near(emit, a, 0, 20),
            "actor": near(actor, a, 0, 20),
            "vis": near(vis, a, 0, 20),
            "empty": near(empty, a, 0, 20),
            "send": first_after(send, a, 0, 20),
            "send_late": first_after(send, a, 20, 280),
        }
        rec["cave_like"] = bool(rec["emit"] and au_early is None)
        holes.append(rec)

    cave_holes = [h for h in holes if h.get("cave_like")]
    out = {
        "kind": "cave-emit-why",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_emit": len(emit),
        "n_send": len(send),
        "n_au": len(au),
        "actor_zero": sum(1 for _, e in actor if e.get("zero")),
        "vis_zero": sum(1 for _, e in vis if e.get("zero")),
        "empty_yes": sum(1 for _, e in empty if e.get("yes")),
        "holes": holes[:8],
        "cave_like": cave_holes[:6],
    }
    Path("/tmp/dagu-cave-emit-why.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-cave-emit-why-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-cave-emit-why-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-cave-emit-why-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-cave-emit-why.json", str(dest)], check=False)
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
