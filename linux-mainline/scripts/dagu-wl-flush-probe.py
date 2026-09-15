#!/usr/bin/env python3
"""ifn→add: when does mutter actually flush the socket vs request_frame LR.

Never hook 0x1c4404 / cave.
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

REQ_LR = {
    0x5036F0: "present_flags",
    0x503C24: "cairo_after_scale",
    0x503E50: "cairo_no_pending_cb",
    0x523EAC: "popup_present",
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
        elif cmd.startswith(b"python") and b"dagu-native-lab.py" in cmd and b"--video" in cmd:
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
    raise SystemExit(f"no r-xp {needle} pid={pid}")


def parse_pid(line):
    tok = line.lstrip().split()[0] if line.strip() else ""
    if "-" not in tok:
        return None
    try:
        return int(tok.rsplit("-", 1)[1])
    except ValueError:
        return None


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


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
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


def install(shell, lab):
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
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
    wls = map_rx(shell, "libwayland-server.so.0.24.0")
    gtk = map_rx(lab, "libgtk-4.so.1.2200.4")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_send {mu}:0x1673f0\n".encode())
        os.write(fd, f"p:dagu_pres {mu}:0x169c98\n".encode())
        os.write(fd, f"p:dagu_flush {wls}:0x84e0\n".encode())
        os.write(fd, f"p:dagu_reqfr {gtk}:0x51ae60 lr=%x30\n".encode())
        os.write(fd, f"p:dagu_idle {gtk}:0x573a64\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    flt = TR / "events/uprobes/dagu_flush/filter"
    if flt.is_file():
        flt.write_text(f"common_pid == {shell}\n")
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
    gtk_base = None
    for line in open(f"/proc/{lab}/maps"):
        if "libgtk-4.so.1.2200.4" in line and "r-xp" in line:
            gtk_base = int(line.split("-", 1)[0], 16)
            break
    if gtk_base is None:
        raise SystemExit("no gtk base")
    install(shell, lab)
    kick, nview, ifn, add, send, pres, flush, idle = [], [], [], [], [], [], [], []
    reqfr = []
    cur_kick = None
    saw_nview = False
    saw_add = False
    flush_n = 0
    flush_first = None
    flush_by = {}
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
                pid = parse_pid(line)
                if "dpu_enc_kickoff:" in line:
                    if cur_kick is not None:
                        flush_by[cur_kick] = (flush_n, flush_first)
                    cur_kick = ts
                    saw_nview = False
                    saw_add = False
                    flush_n = 0
                    flush_first = None
                    kick.append(ts)
                elif "dagu_nview:" in line and pid == shell:
                    nview.append(ts)
                    saw_nview = True
                elif "dagu_ifnchk:" in line and pid == shell:
                    if parse_hex_field(line, "next") == 0:
                        ifn.append(ts)
                elif "dagu_add:" in line and pid == shell:
                    add.append(ts)
                    saw_add = True
                elif "dagu_send:" in line and pid == shell:
                    send.append(ts)
                elif "dagu_pres:" in line and pid == shell:
                    pres.append(ts)
                elif "dagu_flush:" in line and pid == shell:
                    if cur_kick is not None and saw_nview and not saw_add:
                        flush_n += 1
                        if flush_first is None:
                            flush_first = round((ts - cur_kick) * 1000.0, 2)
                    flush.append(ts)
                elif "dagu_idle:" in line and pid == lab:
                    idle.append(ts)
                elif "dagu_reqfr:" in line and pid == lab:
                    lr = parse_hex_field(line, "lr") or 0
                    reqfr.append((ts, lr - gtk_base if gtk_base <= lr < gtk_base + 0x2000000 else lr))
    finally:
        pipe.close()
        clear()
    if cur_kick is not None:
        flush_by[cur_kick] = (flush_n, flush_first)

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
        fn, ff = flush_by.get(a, (None, None))
        first_req = None
        for t, off in reqfr:
            dt = (t - a) * 1000.0
            if 0 <= dt <= 280:
                first_req = {"dt": round(dt, 2), "who": REQ_LR.get(off, hex(off))}
                break
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "pres": first_after(pres, a, 0, 280),
            "flush_n_before_add": fn,
            "flush_first": ff,
            "add": first_after(add, a, 0, 280),
            "send": first_after(send, a, 0, 280),
            "idle": first_after(idle, a, 0, 280),
            "reqfr": first_req,
        })

    out = {
        "kind": "wl-flush",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_flush": len(flush),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-wl-flush.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-wl-flush-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-wl-flush-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-wl-flush-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-wl-flush.json", str(dest)], check=False)
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
