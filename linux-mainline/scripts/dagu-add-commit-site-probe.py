#!/usr/bin/env python3
"""ifn-idle: which leftover GTK/Mesa commit site hits before mutter 0x164fa4 add.

Never hook 0x1c4404 / cave / 0x84e0 / all-marshal.
Already excluded as +90 wakeup: Mesa 0x2ce20 ifn→add=0, after_paint 0x518cac=0,
cairo 0x503c28 / simple 0x5035d0 / wl GL 0x523dd0 / hide 0x51b4f0=0.

This pass hooks the remaining mov w1,#6 sites plus apply/add/reqfr.
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

APPLY_LR = {
    0x18ED08: "actor_tree_apply",
}

SITE_NAMES = (
    "apply",
    "add",
    "reqfr",
    "nsub",
    "subcom",
    "apcom",
    "cairo2",
    "cursor",
    "tlpres",
    "tlprop",
    "mesa",
    "hide",
)


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
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" not in line:
            rng = line.split()[0]
            mf = f"/proc/{pid}/map_files/{rng}"
            if Path(mf).exists():
                return mf
            continue
        if needle == "libmutter-18.so.0.0.0":
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


def last_before(xs, t0, lo_ms):
    lo = t0 + lo_ms / 1000.0
    last = None
    for t in xs:
        if t < lo:
            last = round((t - t0) * 1000.0, 2)
        else:
            break
    return last


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
    gtk = map_rx(lab, "libgtk-4.so.1.2200.4")
    mesa = map_rx(lab, "libEGL_mesa.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_apply {mu}:0x165124 lr=%x30\n".encode())
        os.write(fd, f"p:dagu_reqfr {gtk}:0x51ae60\n".encode())
        os.write(fd, f"p:dagu_nsub {gtk}:0x51af84 n=%x0\n".encode())
        os.write(fd, f"p:dagu_subcom {gtk}:0x51b00c\n".encode())
        os.write(fd, f"p:dagu_apcom {gtk}:0x518cac\n".encode())
        os.write(fd, f"p:dagu_cairo2 {gtk}:0x5046e4\n".encode())
        os.write(fd, f"p:dagu_cursor {gtk}:0x5161ec\n".encode())
        os.write(fd, f"p:dagu_tlpres {gtk}:0x51dd44\n".encode())
        os.write(fd, f"p:dagu_tlprop {gtk}:0x51a848\n".encode())
        os.write(fd, f"p:dagu_hide {gtk}:0x51b4f0\n".encode())
        os.write(fd, f"p:dagu_mesa {mesa}:0x2ce20\n".encode())
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
    install(shell, lab)
    kick, nview, ifn = [], [], []
    ev = {n: [] for n in SITE_NAMES}
    apply_lr = []
    nsub = []
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
                    ev["add"].append(ts)
                elif "dagu_apply:" in line and pid == shell:
                    ev["apply"].append(ts)
                    lr = parse_hex_field(line, "lr")
                    if lr is not None and mu_base is not None:
                        apply_lr.append((ts, lr - mu_base))
                    else:
                        apply_lr.append((ts, lr))
                elif pid == lab:
                    if "dagu_reqfr:" in line:
                        ev["reqfr"].append(ts)
                    elif "dagu_nsub:" in line:
                        ev["nsub"].append(ts)
                        nsub.append((ts, parse_hex_field(line, "n") or 0))
                    elif "dagu_subcom:" in line:
                        ev["subcom"].append(ts)
                    elif "dagu_apcom:" in line:
                        ev["apcom"].append(ts)
                    elif "dagu_cairo2:" in line:
                        ev["cairo2"].append(ts)
                    elif "dagu_cursor:" in line:
                        ev["cursor"].append(ts)
                    elif "dagu_tlpres:" in line:
                        ev["tlpres"].append(ts)
                    elif "dagu_tlprop:" in line:
                        ev["tlprop"].append(ts)
                    elif "dagu_hide:" in line:
                        ev["hide"].append(ts)
                    elif "dagu_mesa:" in line:
                        ev["mesa"].append(ts)
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
        add_dt = first_after(ev["add"], a, 0, 280)
        lo = ifn_dt if ifn_dt is not None else 0
        hi = add_dt if add_dt is not None else 280
        rec = {
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add": add_dt,
            "apply": first_after(ev["apply"], a, 0, 280),
            "reqfr": first_after(ev["reqfr"], a, 0, 280),
            "mesa_before": last_before(ev["mesa"], a, 0),
            "sites": {n: first_after(ev[n], a, 0, 280) for n in SITE_NAMES},
        }
        if kind == "ifn-idle":
            rec["ifn_add"] = {n: between(ev[n], a, lo, hi) for n in SITE_NAMES}
            rec["nsub"] = [
                {"dt": round((t - a) * 1000.0, 2), "n": n}
                for t, n in nsub
                if a + lo / 1000.0 <= t <= a + hi / 1000.0
            ]
            rec["apply_lr"] = [
                {
                    "dt": round((t - a) * 1000.0, 2),
                    "who": APPLY_LR.get(off, hex(off) if off is not None else None),
                }
                for t, off in apply_lr
                if a + lo / 1000.0 <= t <= a + hi / 1000.0
            ]
        holes.append(rec)

    out = {
        "kind": "add-commit-site",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n": {n: len(ev[n]) for n in SITE_NAMES},
        "nsub_vals": dict(Counter(n for _, n in nsub)),
        "apply_who": dict(Counter(
            APPLY_LR.get(off, hex(off) if off is not None else "?")
            for _, off in apply_lr
        )),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-add-commit-site.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-add-commit-site-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-add-commit-site-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-add-commit-site-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-add-commit-site.json", str(dest)], check=False)
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
