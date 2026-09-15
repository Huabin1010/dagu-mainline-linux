#!/usr/bin/env python3
"""ifn→add: which Wayland event mutter posts before GTK commit.

Never hook 0x1c4404 / cave.
Mutter: ifnchk 0x1c4388, add 0x164fa4, send 0x1673f0, nview 0x1c4440,
        wl_resource_post_event, buffer dec 0x167e80
Lab: wl_proxy_marshal_flags (outgoing commit/frame)

From host: python3 linux-mainline/scripts/dagu-wl-opcode-probe.py --host
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


def parse_str_field(line, key):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    rest = line[i + len(tok):]
    if rest.startswith('"'):
        end = rest.find('"', 1)
        return rest[1:end] if end > 0 else rest[1:24]
    return rest.split()[0][:48]


def read_cstr(pid, addr):
    if not addr or addr < 0x1000:
        return "?"
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(addr)
        raw = mem.read(48)
        mem.close()
        return raw.split(b"\x00", 1)[0].decode("ascii", "replace") or "?"
    except OSError:
        return hex(addr)


def iface_of(pid, obj):
    if not obj:
        return "?"
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
        mem.seek(obj)
        iface = struct.unpack("<Q", mem.read(8))[0]
        mem.seek(iface)
        namep = struct.unpack("<Q", mem.read(8))[0]
        mem.close()
        return read_cstr(pid, namep)
    except (OSError, struct.error):
        return hex(obj)


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
    (TR / "buffer_size_kb").write_text("32768\n")
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
    wls = map_rx(shell, "libwayland-server.so.0.24.0")
    wlc = map_rx(lab, "libwayland-client.so.0.24.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_send {mu}:0x1673f0\n".encode())
        os.write(fd, f"p:dagu_rel {mu}:0x167e80\n".encode())
        os.write(fd, f"p:dagu_post {wls}:0xb500 opcode=%x1 res=%x0\n".encode())
        os.write(fd, f"p:dagu_mar {wlc}:0x9104 opcode=%x1 proxy=%x0 lr=%x30\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    for name, pid in (("dagu_post", shell), ("dagu_mar", lab)):
        flt = TR / f"events/uprobes/{name}/filter"
        if flt.is_file():
            flt.write_text(f"common_pid == {pid}\n")
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
    kick, nview, ifn, add, send, rel = [], [], [], [], [], []
    cur_kick = None
    saw_nview = False
    saw_add = False
    win_post = []
    win_mar = []
    posts_by = {}
    mars_by = {}
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
                        posts_by[cur_kick] = win_post
                        mars_by[cur_kick] = win_mar
                    cur_kick = ts
                    saw_nview = False
                    saw_add = False
                    win_post = []
                    win_mar = []
                    kick.append(ts)
                elif "dagu_nview:" in line and parse_pid(line) == shell:
                    nview.append(ts)
                    saw_nview = True
                elif "dagu_ifnchk:" in line and parse_pid(line) == shell:
                    if parse_hex_field(line, "next") == 0:
                        ifn.append(ts)
                elif "dagu_add:" in line and parse_pid(line) == shell:
                    add.append(ts)
                    saw_add = True
                elif "dagu_send:" in line and parse_pid(line) == shell:
                    send.append(ts)
                elif "dagu_rel:" in line and parse_pid(line) == shell:
                    rel.append(ts)
                elif "dagu_post:" in line and parse_pid(line) == shell:
                    if cur_kick is not None and saw_nview and not saw_add and len(win_post) < 32:
                        win_post.append((
                            ts,
                            parse_hex_field(line, "opcode") or 0,
                            parse_hex_field(line, "res") or 0,
                        ))
                elif "dagu_mar:" in line and parse_pid(line) == lab:
                    if cur_kick is not None and saw_nview and not saw_add and len(win_mar) < 32:
                        win_mar.append((
                            ts,
                            parse_hex_field(line, "opcode") or 0,
                            parse_hex_field(line, "proxy") or 0,
                            parse_hex_field(line, "lr") or 0,
                        ))
    finally:
        pipe.close()
        clear()
    if cur_kick is not None:
        posts_by[cur_kick] = win_post
        mars_by[cur_kick] = win_mar

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
        posts = []
        for t, op, res in posts_by.get(a, []):
            posts.append({
                "dt": round((t - a) * 1000.0, 2),
                "op": op,
                "iface": iface_of(shell, res),
            })
        mars = []
        for t, op, proxy, lr in mars_by.get(a, []):
            mars.append({
                "dt": round((t - a) * 1000.0, 2),
                "op": op,
                "iface": iface_of(lab, proxy),
                "lr": hex(lr - gtk_base) if gtk_base <= lr < gtk_base + 0x2000000 else hex(lr),
            })
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add": first_after(add, a, 0, 280),
            "send": first_after(send, a, 0, 280),
            "rel": first_after(rel, a, 0, 280),
            "post": posts,
            "mar": mars,
        })

    out = {
        "kind": "wl-opcode",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_add": len(add),
        "n_send": len(send),
        "n_rel": len(rel),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-wl-opcode.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-wl-opcode-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-wl-opcode-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-wl-opcode-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-wl-opcode.json", str(dest)], check=False)
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
