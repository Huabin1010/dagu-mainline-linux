#!/usr/bin/env python3
"""ifn-idle: who makes GTK commit (~queue_frame_callbacks) at +90ms before sendcb.

Never hook 0x1c4404 / cave.
Mutter (shell): ifnchk 0x1c4388, add 0x164fa4, send 0x1673f0, nview 0x1c4440
Lab GTK: paint_idle, thaw+lr, request_phase+lr, timeout_add w1, force_next_commit
Lab glib: dispatch blr 0x606f4 count/names only between ifn and add.

From host: python3 linux-mainline/scripts/dagu-lab-add-why-probe.py --host
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

THAW_LR = {
    0x518A44: "wl_frame_cb",
    0x516EA4: "force_commit",
    0x5A4D84: "thaw_idle",
}

REQ_LR = {
    0x2418FC: "widget_qdraw",
    0x3BA354: "widget_qdraw2",
    0x59FAF8: "surf_qrender",
    0x5A4D84: "thaw_idle",
    0x5A4EBC: "thaw_pending",
}

SYSC = {-1: "running", 29: "ioctl", 73: "ppoll", 98: "futex"}


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
        raise SystemExit(json.dumps({"err": "need ubuntu+lab --video", "shell": shell, "lab": lab}))
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


def src_name(pid, src):
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(src + 80)
        namep = struct.unpack("<Q", mem.read(8))[0]
        name = "?"
        if namep > 0x1000:
            mem.seek(namep)
            name = mem.read(48).split(b"\x00", 1)[0].decode("ascii", "replace") or "?"
        mem.close()
        return name
    except OSError:
        return hex(src)


def read_sys(tid):
    try:
        raw = Path(f"/proc/{tid}/syscall").read_text().strip()
        wchan = Path(f"/proc/{tid}/wchan").read_text().strip()
    except OSError:
        return {"raw": "gone"}
    if raw == "running":
        return {"name": "running", "wchan": wchan}
    nr = raw.split()[0]
    try:
        nri = int(nr, 0)
    except ValueError:
        nri = None
    return {"name": SYSC.get(nri, nr), "wchan": wchan, "raw": raw[:70]}


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


def install(shell, lab):  # lab used for dagu_gs pid filter
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
    gtk = map_rx(lab, "libgtk-4.so.1.2200.4")
    glib = map_rx(lab, "libglib-2.0.so.0.8800.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_send {mu}:0x1673f0\n".encode())
        os.write(fd, f"p:dagu_idle {gtk}:0x573a64\n".encode())
        os.write(fd, f"p:dagu_thaw {gtk}:0x5a4da0 lr=%x30\n".encode())
        os.write(fd, f"p:dagu_req {gtk}:0x5733d0 lr=%x30 ph=%x1\n".encode())
        os.write(fd, f"p:dagu_toadd {gtk}:0x56efb4 w1=%x1\n".encode())
        os.write(fd, f"p:dagu_force {gtk}:0x516e20\n".encode())
        os.write(fd, f"p:dagu_gs {glib}:0x606f4 src=%x19\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    gs_flt = TR / "events/uprobes/dagu_gs/filter"
    if gs_flt.is_file():
        gs_flt.write_text(f"common_pid == {lab}\n")
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
        raise SystemExit("no lab gtk base")
    install(shell, lab)
    kick, nview, ifn, add, send = [], [], [], [], []
    idle, thaw, req, toadd, force = [], [], [], [], []
    gs_n = 0
    gs_src = Counter()
    cur_kick = None
    saw_nview = False
    saw_add = False
    sampled = False
    gs_wins = []
    sys_wins = []
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
                    if cur_kick is not None:
                        gs_wins.append((cur_kick, gs_n, gs_src.most_common(6)))
                    cur_kick = ts
                    gs_n = 0
                    gs_src = Counter()
                    saw_nview = False
                    saw_add = False
                    sampled = False
                    kick.append(ts)
                elif "dagu_nview:" in line:
                    if parse_pid(line) == shell:
                        nview.append(ts)
                        saw_nview = True
                elif "dagu_ifnchk:" in line:
                    if parse_pid(line) == shell and parse_hex_field(line, "next") == 0:
                        ifn.append(ts)
                elif "dagu_add:" in line:
                    if parse_pid(line) == shell:
                        add.append(ts)
                        saw_add = True
                elif "dagu_send:" in line:
                    if parse_pid(line) == shell:
                        send.append(ts)
                elif "dagu_idle:" in line:
                    if parse_pid(line) == lab:
                        idle.append(ts)
                elif "dagu_thaw:" in line:
                    if parse_pid(line) == lab:
                        thaw.append((ts, parse_hex_field(line, "lr") or 0))
                elif "dagu_req:" in line:
                    if parse_pid(line) == lab:
                        req.append((ts, parse_hex_field(line, "lr") or 0, parse_hex_field(line, "ph") or 0))
                elif "dagu_toadd:" in line:
                    if parse_pid(line) == lab:
                        toadd.append((ts, parse_hex_field(line, "w1") or 0))
                elif "dagu_force:" in line:
                    if parse_pid(line) == lab:
                        force.append(ts)
                elif "dagu_gs:" in line:
                    if parse_pid(line) == lab and cur_kick is not None and saw_nview and not saw_add:
                        gs_n += 1
                        src = parse_hex_field(line, "src")
                        if src:
                            gs_src[src] += 1
                if (
                    cur_kick is not None
                    and not saw_add
                    and not sampled
                    and ts >= cur_kick + 0.020
                ):
                    sys_wins.append((cur_kick, read_sys(lab)))
                    sampled = True
    finally:
        pipe.close()
        clear()
    if cur_kick is not None:
        gs_wins.append((cur_kick, gs_n, gs_src.most_common(6)))

    gs_by = {t: (n, top) for t, n, top in gs_wins}
    sys_by = {t: info for t, info in sys_wins}

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
        gs_n, top = gs_by.get(a, (None, []))
        names = [{"n": c, "name": src_name(lab, s)} for s, c in top]
        first_thaw = None
        thaw_who = None
        for t, lr in thaw:
            dt = (t - a) * 1000.0
            if 0 <= dt <= 280:
                first_thaw = round(dt, 2)
                off = lr - gtk_base
                thaw_who = THAW_LR.get(off, hex(off))
                break
        first_req = None
        req_who = None
        for t, lr, ph in req:
            dt = (t - a) * 1000.0
            if 0 <= dt <= 280:
                first_req = {"dt": round(dt, 2), "ph": ph, "who": REQ_LR.get(lr - gtk_base, hex(lr - gtk_base))}
                break
        first_to = None
        for t, w1 in toadd:
            dt = (t - a) * 1000.0
            if 0 <= dt <= 280:
                first_to = {"dt": round(dt, 2), "ms": w1}
                break
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add": first_after(add, a, 0, 280),
            "send": first_after(send, a, 0, 280),
            "idle": first_after(idle, a, 0, 280),
            "thaw": first_thaw,
            "thaw_who": thaw_who,
            "req": first_req,
            "toadd": first_to,
            "force": first_after(force, a, 0, 280),
            "gs_before_add": gs_n,
            "gs_top": names,
            "lab20": sys_by.get(a),
        })

    out = {
        "kind": "lab-add-why",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_add": len(add),
        "n_idle": len(idle),
        "n_thaw": len(thaw),
        "n_force": len(force),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-lab-add-why.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-lab-add-why-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-lab-add-why-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-lab-add-why-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-lab-add-why.json", str(dest)], check=False)
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
