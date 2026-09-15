#!/usr/bin/env python3
"""ifn vs after_update: compositor+88 length, +476 flush, when +88 is prepended.

Never hook 0x1c4404 / cave.
  ifnchk 0x1c4388  au emit 0x1696c0  send 0x1673f0
  add    0x164fa4  g_list_prepend into comp+88 (queue_frame_callbacks)
  qempty 0x164f58  pending frame list empty → return
From host: python3 linux-mainline/scripts/dagu-ifn-au-list-probe.py --host
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


def u64(mem, addr):
    try:
        mem.seek(addr)
        b = mem.read(8)
        return struct.unpack("<Q", b)[0] if len(b) == 8 else 0
    except OSError:
        return 0


def u32(mem, addr):
    try:
        mem.seek(addr)
        b = mem.read(4)
        return struct.unpack("<I", b)[0] if len(b) == 4 else 0
    except OSError:
        return 0


def glist_len(mem, head):
    n = 0
    seen = set()
    p = head
    while p and p not in seen and n < 24:
        seen.add(p)
        n += 1
        p = u64(mem, p + 8)
    return n


def first_surf(mem, head):
    if not head:
        return 0
    return u64(mem, head)


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
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_au {mu}:0x1696c0 comp=%x0 view=%x1\n".encode())
        os.write(fd, f"p:dagu_send {mu}:0x1673f0\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4 surf=%x1\n".encode())
        os.write(fd, f"p:dagu_qempty {mu}:0x164f58\n".encode())
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


def snap_list(mem, comp):
    if not comp:
        return None
    head = u64(mem, comp + 88)
    bar = u64(mem, comp + 368)
    surf = first_surf(mem, head)
    return {
        "n88": glist_len(mem, head) if head else 0,
        "n368": glist_len(mem, bar) if bar else 0,
        "head88": hex(head) if head else "0",
        "surf": hex(surf) if surf else "0",
        "flush476": u32(mem, surf + 476) if surf else None,
    }


def on_device(seconds=12.0):
    shell, lab = find_pids()
    install(shell)
    mem = open(f"/proc/{shell}/mem", "rb", buffering=0)
    kick, nview, ifn, au, send, add, qempty = [], [], [], [], [], [], []
    ifn_snap, au_snap = [], []
    comp = 0
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
                        ifn_snap.append((ts, snap_list(mem, comp)))
                elif "dagu_au:" in line:
                    au.append(ts)
                    c = parse_hex_field(line, "comp") or 0
                    if c:
                        comp = c
                    au_snap.append((ts, snap_list(mem, comp), parse_hex_field(line, "view")))
                elif "dagu_send:" in line:
                    send.append(ts)
                elif "dagu_add:" in line:
                    add.append(ts)
                elif "dagu_qempty:" in line:
                    qempty.append(ts)
    finally:
        pipe.close()
        mem.close()
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
        isnap = next((s for t, s in ifn_snap if 0 <= (t - a) * 1000.0 <= 20), None)
        asnap = next((s for t, s, _ in au_snap if 0 <= (t - a) * 1000.0 <= 280), None)
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add0": first_after(add, a, -2, 280),
            "qempty0": first_after(qempty, a, -2, 280),
            "au": first_after(au, a, 0, 280),
            "send": first_after(send, a, 0, 280),
            "ifn_list": isnap,
            "au_list": asnap,
        })

    out = {
        "kind": "ifn-au-list",
        "shell": shell,
        "lab": lab,
        "comp": hex(comp) if comp else None,
        "seconds": seconds,
        "kick": summary(kick),
        "n_add": len(add),
        "n_qempty": len(qempty),
        "n_au": len(au),
        "n_ifn": len(ifn),
        "n_send": len(send),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-ifn-au-list.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-ifn-au-list-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-ifn-au-list-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-ifn-au-list-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-ifn-au-list.json", str(dest)], check=False)
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
