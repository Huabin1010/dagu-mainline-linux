#!/usr/bin/env python3
"""While ifn-emit is applied: emit/head/send after nview, no cave/ifn hooks.

Do NOT hook 0x1c4404 (file ret eats live b cave) or 0x1d2b80
(file is zeros → UDF, kills gnome-shell). Stock sites only:
  emit  0x167340  x0=comp x1=view
  empty 0x167368  x22=comp+88 head
  send  0x1673f0
  nview 0x1c4440
  au    0x1696c0
No poke here. From host:
  python3 linux-mainline/scripts/dagu-ifn-cave-path-probe.py --host
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
        os.write(fd, f"p:dagu_emit {mf}:0x167340 comp=%x0 view=%x1\n".encode())
        os.write(fd, f"p:dagu_head {mf}:0x167368 head=%x22\n".encode())
        os.write(fd, f"p:dagu_send {mf}:0x1673f0\n".encode())
        os.write(fd, f"p:dagu_nview {mf}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_au {mf}:0x1696c0\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    return mf


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
    emit, head = [], []
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
                    emit.append((ts, {
                        "comp": hex(parse_hex_field(line, "comp") or 0),
                        "view": hex(parse_hex_field(line, "view") or 0),
                    }))
                elif "dagu_head:" in line:
                    emit_h = parse_hex_field(line, "head")
                    head.append((ts, {
                        "head": hex(emit_h or 0),
                        "empty": emit_h == 0,
                    }))
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n_dt = first_after(nview, a, 0, 20)
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": "ifn-idle" if n_dt is not None else "nview-late",
            "nview": first_after(nview, a, 0, 280),
            "emit": near(emit, a, 0, 20),
            "head": near(head, a, 0, 20),
            "send": first_after(send, a, 0, 20),
            "send_late": first_after(send, a, 20, 280),
            "au": first_after(au, a, 0, 20),
            "au_late": first_after(au, a, 20, 280),
        })

    send_after_n = 0
    empty_after_n = 0
    emit_after_n = 0
    for h in holes:
        if h["kind"] != "ifn-idle":
            continue
        if h["emit"]:
            emit_after_n += 1
        if h["head"] and h["head"][0].get("empty"):
            empty_after_n += 1
        if h["send"] is not None:
            send_after_n += 1

    out = {
        "kind": "ifn-cave-path",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_emit": len(emit),
        "n_head": len(head),
        "n_send": len(send),
        "n_nview": len(nview),
        "n_au": len(au),
        "ifn_idle_emit_le20": emit_after_n,
        "ifn_idle_empty_le20": empty_after_n,
        "ifn_idle_send_le20": send_after_n,
        "head_empty": sum(1 for _, e in head if e.get("empty")),
        "emit_comp": Counter(e.get("comp") for _, e in emit).most_common(4),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-ifn-cave-path.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-ifn-cave-path-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-ifn-cave-path-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-ifn-cave-path-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-ifn-cave-path.json", str(dest)], check=False)
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
