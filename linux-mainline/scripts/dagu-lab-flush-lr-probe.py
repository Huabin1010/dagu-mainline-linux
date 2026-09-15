#!/usr/bin/env python3
"""ifn-idle: who in lab calls fd_submit_sp_flush / flush_submit_list at +99.

Never hook 0x1c4388 / 0x1c4404 / cave / 0x84e0. Never open dri/0/gpu.
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


def maps_rx(pid):
    out = []
    for line in open(f"/proc/{pid}/maps"):
        if "r-xp" not in line:
            continue
        rng = line.split()[0]
        a, b = rng.split("-")
        path = line.split()[-1] if "/" in line else "?"
        out.append((int(a, 16), int(b, 16), path))
    return out


def resolve(maps, addr):
    if not addr:
        return None
    for a, b, path in maps:
        if a <= addr < b:
            return f"{path.rsplit('/', 1)[-1]}+{hex(addr - a)}"
    return hex(addr)


def parse_pid(line):
    tok = line.lstrip().split()[0] if line.strip() else ""
    if "-" not in tok:
        return None
    try:
        return int(tok.rsplit("-", 1)[1])
    except ValueError:
        return None


def parse_comm(line):
    s = line.lstrip()
    tok = s.split()[0] if s else ""
    if "-" in tok:
        return tok.rsplit("-", 1)[0]
    return tok


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


def parse_int_field(line, key):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0].rstrip(",")
    try:
        return int(v, 10)
    except ValueError:
        return None


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def first_pair(pairs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for t, extra in pairs:
        if lo <= t <= hi:
            return {"dt": round((t - t0) * 1000.0, 2), **extra}
    return None


def last_pair(pairs, t0):
    last = None
    for t, extra in pairs:
        if t < t0:
            last = {"dt": round((t - t0) * 1000.0, 2), **extra}
        else:
            break
    return last


def count_between(pairs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    return sum(1 for t, _ in pairs if lo <= t <= hi)


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
    ga = map_rx(lab, "libgallium-26.0.8-1ubuntu0.3.so")
    egl = map_rx(lab, "libEGL_mesa.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_hasnext {mu}:0x1c4398\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_spfl {ga}:0xca13c4 lr=%x30\n".encode())
        os.write(fd, f"p:dagu_fsl {ga}:0xc9fb04 lr=%x30\n".encode())
        os.write(fd, f"p:dagu_swap {egl}:0x2ce20 lr=%x30\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/drm_msm_gpu/msm_gpu_submit/enable").write_text("1\n")


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    p = TR / "events/drm_msm_gpu/msm_gpu_submit/enable"
    if p.is_file():
        p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds=12.0):
    shell, lab = find_pids()
    lab_maps = maps_rx(lab)
    install(shell, lab)
    kick, nview, has, add = [], [], [], []
    spfl, fsl, swap, sub = [], [], [], []
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
                comm = parse_comm(line)
                extra = {
                    "comm": comm,
                    "lr": resolve(lab_maps, parse_hex_field(line, "lr")),
                }
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                elif "dagu_nview:" in line and pid == shell:
                    nview.append(ts)
                elif "dagu_hasnext:" in line and pid == shell:
                    has.append(ts)
                elif "dagu_add:" in line and pid == shell:
                    add.append(ts)
                elif "dagu_spfl:" in line and pid == lab:
                    spfl.append((ts, extra))
                elif "dagu_fsl:" in line and pid == lab:
                    fsl.append((ts, extra))
                elif "dagu_swap:" in line and pid == lab:
                    swap.append((ts, extra))
                elif "msm_gpu_submit:" in line and parse_int_field(line, "pid") == lab:
                    sub.append((ts, {"comm": comm, "id": parse_int_field(line, "id")}))
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        n_dt = first_after(nview, a, 0, 20)
        h_dt = first_after(has, a, 0, 20)
        if n_dt is not None and h_dt is None:
            kind = "ifn-idle"
        elif n_dt is not None:
            kind = "nview-ok"
        else:
            kind = "nview-late"
        add_dt = first_after(add, a, 0, 280)
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "hasnext": first_after(has, a, 0, 280),
            "add": add_dt,
            "swap_before": last_pair(swap, a),
            "spfl_before": last_pair(spfl, a),
            "fsl_before": last_pair(fsl, a),
            "sub_before": last_pair(sub, a),
            "first_spfl": first_pair(spfl, a, 0, 280),
            "first_fsl": first_pair(fsl, a, 0, 280),
            "first_sub": first_pair(sub, a, 0, 280),
            "first_swap": first_pair(swap, a, 0, 280),
            "n_spfl_mid": count_between(spfl, a, n_dt or 0, add_dt or 280) if kind == "ifn-idle" else None,
            "n_swap_mid": count_between(swap, a, n_dt or 0, add_dt or 280) if kind == "ifn-idle" else None,
        })

    out = {
        "kind": "lab-flush-lr",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_spfl": len(spfl),
        "n_fsl": len(fsl),
        "n_swap": len(swap),
        "n_sub": len(sub),
        "spfl_lr": dict(Counter(e["lr"] for _, e in spfl)),
        "fsl_lr": dict(Counter(e["lr"] for _, e in fsl)),
        "spfl_comm": dict(Counter(e["comm"] for _, e in spfl)),
        "sub_comm": dict(Counter(e["comm"] for _, e in sub)),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-lab-flush-lr.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-lab-flush-lr-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-lab-flush-lr-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-lab-flush-lr-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-lab-flush-lr.json", str(dest)], check=False)
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
