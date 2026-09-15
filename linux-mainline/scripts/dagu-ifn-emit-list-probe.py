#!/usr/bin/env python3
"""At ifn and emit: dump onscreen+136 view, compositor+88 list, surface+476.

Why ifn-emit did not move sendcb: empty view, empty list, or skip flag.
No poke. From host: python3 linux-mainline/scripts/dagu-ifn-emit-list-probe.py --host
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
COMP = 0x5564C7EF20


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
    raise SystemExit(f"no r-xp {needle}")


def u64(mem, addr):
    try:
        mem.seek(addr)
        return struct.unpack("<Q", mem.read(8))[0]
    except (OSError, struct.error):
        return 0


def u32(mem, addr):
    try:
        mem.seek(addr)
        return struct.unpack("<I", mem.read(4))[0]
    except (OSError, struct.error):
        return 0


def walk_list(mem, head, limit=8):
    out = []
    seen = set()
    p = head
    while p and p not in seen and len(out) < limit:
        if p < 0x10000:
            break
        seen.add(p)
        surf = u64(mem, p)
        nxt = u64(mem, p + 8)
        actor = u64(mem, surf + 48) if surf > 0x10000 else 0
        flag = u32(mem, surf + 476) if surf > 0x10000 else 0
        out.append({
            "surf": hex(surf),
            "actor": hex(actor),
            "flag476": flag,
        })
        p = nxt
    return out


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
        os.write(fd, f"p:dagu_ifn {mf}:0x1c4404 onsc=%x0\n".encode())
        os.write(fd, f"p:dagu_emit {mf}:0x167340 comp=%x0 view=%x1\n".encode())
        os.write(fd, f"p:dagu_sendcb {mf}:0x1673f0\n".encode())
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
    mem = open(f"/proc/{shell}/mem", "rb", buffering=0)
    install(shell)
    kick, nview, ifn, emit, sendcb, au = [], [], [], [], [], []
    ifn_snaps, emit_snaps = [], []
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
                chunk = ""
            if chunk:
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
                    elif "dagu_sendcb:" in line:
                        sendcb.append(ts)
                    elif "dagu_ifn:" in line:
                        ifn.append(ts)
                        onsc = parse_hex_field(line, "onsc")
                        view = u64(mem, onsc + 136) if onsc else 0
                        head = u64(mem, COMP + 88)
                        head368 = u64(mem, COMP + 368)
                        ifn_snaps.append({
                            "onsc": hex(onsc) if onsc else None,
                            "view136": hex(view),
                            "n88": len(walk_list(mem, head)),
                            "list88": walk_list(mem, head),
                            "n368": len(walk_list(mem, head368)),
                            "list368": walk_list(mem, head368),
                        })
                    elif "dagu_emit:" in line:
                        emit.append(ts)
                        comp = parse_hex_field(line, "comp")
                        view = parse_hex_field(line, "view")
                        head = u64(mem, (comp or COMP) + 88)
                        emit_snaps.append({
                            "comp": hex(comp) if comp else None,
                            "view": hex(view) if view else None,
                            "n88": len(walk_list(mem, head)),
                            "list88": walk_list(mem, head),
                        })
            if not chunk:
                time.sleep(0.0004)
    finally:
        pipe.close()
        mem.close()
    (TR / "tracing_on").write_text("0\n")
    clear()
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        holes.append({
            "gap_ms": round(gap, 1),
            "nview": first_after(nview, a, 0, 20),
            "ifn": first_after(ifn, a, 0, 20),
            "emit": first_after(emit, a, 0, 250),
            "au": first_after(au, a, 0, 250),
            "sendcb": first_after(sendcb, a, 0, 250),
        })
    out = {
        "kind": "ifn-emit-list",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "comp": hex(COMP),
        "kick": summary(kick),
        "n_ifn": len(ifn),
        "n_emit": len(emit),
        "n_au": len(au),
        "n_sendcb": len(sendcb),
        "ifn_view_zero": sum(1 for s in ifn_snaps if s.get("view136") in ("0x0", "0x0")),
        "ifn_n88": dict(Counter(s.get("n88") for s in ifn_snaps)),
        "ifn_n368": dict(Counter(s.get("n368") for s in ifn_snaps)),
        "emit_n88": dict(Counter(s.get("n88") for s in emit_snaps)),
        "holes": holes[:8],
        "ifn_snaps": ifn_snaps[:8],
        "emit_late": [s for s in emit_snaps][-4:],
    }
    Path("/tmp/dagu-ifn-emit-list.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-ifn-emit-list-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-ifn-emit-list-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-ifn-emit-list-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-ifn-emit-list.json", str(dest)], check=False)
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
