#!/usr/bin/env python3
"""ifn-idle: Mesa alt commit 0x2c06c / wrap 0x19410c vs mutter add.

Never hook 0x1c4404 / cave / 0x84e0 / all-marshal.
0x2ce20 ifn→add was 0; leftover GTK w1=#6 sites were 0.
0x2bf8c is another Mesa WSI path: driSwapBuffers then wl_surface.commit at 0x2c06c.
0x19410c is window-role apply_state that blr-s actor 0x165124.
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

WRAP_LR = {}


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


def maps_base(pid, needle):
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        return int(line.split("-", 1)[0], 16)
    return None


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


def between(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    return [round((t - t0) * 1000.0, 2) for t in xs if lo <= t <= hi]


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
    mesa = map_rx(lab, "libEGL_mesa.so.0.0.0")
    gtk = map_rx(lab, "libgtk-4.so.1.2200.4")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_apply {mu}:0x165124\n".encode())
        os.write(fd, f"p:dagu_wrap {mu}:0x19410c lr=%x30\n".encode())
        os.write(fd, f"p:dagu_mesa {mesa}:0x2ce20\n".encode())
        os.write(fd, f"p:dagu_malt {mesa}:0x2bf8c lr=%x30\n".encode())
        os.write(fd, f"p:dagu_mcom {mesa}:0x2c06c\n".encode())
        os.write(fd, f"p:dagu_pop {gtk}:0x522dc0\n".encode())
        os.write(fd, f"p:dagu_xdg6 {gtk}:0x51e4d4\n".encode())
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
    mu_base = maps_base(shell, "libmutter-18.so.0.0.0")
    mesa_base = maps_base(lab, "libEGL_mesa.so.0.0.0")
    gtk_base = maps_base(lab, "libgtk-4.so.1.2200.4")
    install(shell, lab)
    kick, nview, ifn = [], [], []
    add, apply, wrap, mesa, malt, mcom, pop, xdg6 = (
        [], [], [], [], [], [], [], []
    )
    wrap_lr, malt_lr = [], []
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
                    kick.append(ts)
                elif "dagu_nview:" in line and pid == shell:
                    nview.append(ts)
                elif "dagu_ifnchk:" in line and pid == shell:
                    if parse_hex_field(line, "next") == 0:
                        ifn.append(ts)
                elif "dagu_add:" in line and pid == shell:
                    add.append(ts)
                elif "dagu_apply:" in line and pid == shell:
                    apply.append(ts)
                elif "dagu_wrap:" in line and pid == shell:
                    wrap.append(ts)
                    lr = parse_hex_field(line, "lr")
                    off = (lr - mu_base) if (lr and mu_base) else lr
                    wrap_lr.append((ts, off))
                elif pid == lab:
                    if "dagu_mesa:" in line:
                        mesa.append(ts)
                    elif "dagu_malt:" in line:
                        malt.append(ts)
                        lr = parse_hex_field(line, "lr")
                        off = (lr - mesa_base) if (lr and mesa_base) else lr
                        if gtk_base and lr and gtk_base <= lr < gtk_base + 0x2000000:
                            off = ("gtk", lr - gtk_base)
                        malt_lr.append((ts, off))
                    elif "dagu_mcom:" in line:
                        mcom.append(ts)
                    elif "dagu_pop:" in line:
                        pop.append(ts)
                    elif "dagu_xdg6:" in line:
                        xdg6.append(ts)
    finally:
        pipe.close()
        clear()

    def lrname(off):
        if isinstance(off, tuple):
            return f"gtk+{hex(off[1])}"
        return WRAP_LR.get(off, hex(off) if off is not None else None)

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n_dt = first_after(nview, a, 0, 20)
        ifn_dt = first_after(ifn, a, 0, 20)
        kind = (
            "ifn-idle" if n_dt is not None and ifn_dt is not None
            else "nview-ok" if n_dt is not None
            else "nview-late"
        )
        add_dt = first_after(add, a, 0, 280)
        lo = ifn_dt if ifn_dt is not None else 0
        hi = add_dt if add_dt is not None else 280
        rec = {
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add": add_dt,
            "apply": first_after(apply, a, 0, 280),
            "wrap": first_after(wrap, a, 0, 280),
            "mesa": first_after(mesa, a, 0, 280),
            "malt": first_after(malt, a, 0, 280),
            "mcom": first_after(mcom, a, 0, 280),
            "pop": first_after(pop, a, 0, 280),
            "xdg6": first_after(xdg6, a, 0, 280),
        }
        if kind == "ifn-idle":
            rec["ifn_add"] = {
                "wrap": between(wrap, a, lo, hi),
                "mesa": between(mesa, a, lo, hi),
                "malt": between(malt, a, lo, hi),
                "mcom": between(mcom, a, lo, hi),
                "pop": between(pop, a, lo, hi),
                "xdg6": between(xdg6, a, lo, hi),
            }
            rec["wrap_lr"] = [
                {"dt": round((t - a) * 1000.0, 2), "who": lrname(off)}
                for t, off in wrap_lr
                if a + lo / 1000.0 <= t <= a + hi / 1000.0
            ]
            rec["malt_lr"] = [
                {"dt": round((t - a) * 1000.0, 2), "who": lrname(off)}
                for t, off in malt_lr
                if a + lo / 1000.0 <= t <= a + hi / 1000.0
            ]
        holes.append(rec)

    out = {
        "kind": "mesa-alt-commit",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n": {
            "apply": len(apply),
            "add": len(add),
            "wrap": len(wrap),
            "mesa": len(mesa),
            "malt": len(malt),
            "mcom": len(mcom),
            "pop": len(pop),
            "xdg6": len(xdg6),
        },
        "wrap_who": dict(Counter(lrname(off) for _, off in wrap_lr)),
        "malt_who": dict(Counter(lrname(off) for _, off in malt_lr)),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-mesa-alt-commit.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-mesa-alt-commit-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-mesa-alt-commit-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-mesa-alt-commit-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-mesa-alt-commit.json", str(dest)], check=False)
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
