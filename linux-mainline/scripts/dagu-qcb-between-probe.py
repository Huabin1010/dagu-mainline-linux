#!/usr/bin/env python3
"""After on-time qcb with late nview: sample gnome-shell GLib/syscall in the gap.

KMS-thread qcb is not tagged as shell in gsrc-long. This watches trace_pipe,
and if nview is still missing 12ms after a qcb that follows a kickoff, samples
the main thread every ~4ms until nview or 160ms.

GLib 2.88 default ctx (same as dagu-qcb-ctx-sample.py):
  ctx+24 owner, +32 ocnt, +40 waiters, +112 in_check
  source+136 callbacks, priv+16 ready_time
  wakeup eventfd at ctx+152 (fd via /proc)

No poke. From host: python3 linux-mainline/scripts/dagu-qcb-between-probe.py --host
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
GLIB_SLOT = 0x180A90


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


def map_base(pid, needle):
    for line in open(f"/proc/{pid}/maps"):
        if needle not in line or "r-xp" not in line:
            continue
        if needle == "libmutter-18.so.0.0.0" and "mutter-18/" in line:
            continue
        return int(line.split("-", 1)[0], 16)
    raise SystemExit(f"no r-xp {needle}")


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


def u64(mem, a):
    mem.seek(a)
    return struct.unpack("<Q", mem.read(8))[0]


def u32(mem, a):
    mem.seek(a)
    return struct.unpack("<I", mem.read(4))[0]


def evcount(pid, fd):
    try:
        raw = Path(f"/proc/{pid}/fdinfo/{fd}").read_text()
    except OSError:
        return None
    for line in raw.splitlines():
        if line.startswith("eventfd-count:"):
            return int(line.split()[1], 16)
    return None


def wakeup_fd(pid, ctx, mem):
    efd_addr = u64(mem, ctx + 152)
    # ctx+152 is GMainContext->waiters? qcb-ctx said +152 wakeup.
    # Also try scanning fdinfo for eventfd belonging to glib.
    return efd_addr


def sample(pid, ctx, src):
    rec = {}
    try:
        rec["sys"] = Path(f"/proc/{pid}/syscall").read_text().strip().split()[0]
    except OSError:
        rec["sys"] = "gone"
    try:
        rec["wchan"] = Path(f"/proc/{pid}/wchan").read_text().strip()[:48]
    except OSError:
        rec["wchan"] = ""
    rec["efd3"] = evcount(pid, 3)
    rec["efd4"] = evcount(pid, 4)
    try:
        mem = open(f"/proc/{pid}/mem", "rb")
    except OSError:
        return rec
    try:
        rec["owner"] = hex(u64(mem, ctx + 24))
        rec["ocnt"] = u32(mem, ctx + 32)
        rec["waiters"] = hex(u64(mem, ctx + 40))
        rec["in_check"] = u32(mem, ctx + 112)
        rec["cb"] = hex(u64(mem, src + 136))
        rec["flush"] = u32(mem, src + 144)
        priv = u64(mem, src + 88)
        if priv:
            ready = u64(mem, priv + 16)
            rec["ready"] = -1 if ready == (1 << 64) - 1 else ready
        rec["wake_ptr"] = hex(u64(mem, ctx + 152))
    except OSError:
        rec["mem"] = "fail"
    finally:
        mem.close()
    return rec


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
        os.write(fd, f"p:dagu_qcb {mf}:0x1d6e40 cb=%x1\n".encode())
        os.write(fd, f"p:dagu_qarm {mf}:0x1d6ee4 src=%x0\n".encode())
        os.write(fd, f"p:dagu_qhit {mf}:0x1d6e98 src=%x19\n".encode())
        os.write(fd, f"p:dagu_nview {mf}:0x1c4440\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    return mf


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    p = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if p.is_file():
        p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


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


def on_device(seconds=8.0):
    shell, lab = find_pids()
    glib = map_base(shell, "libglib-2.0.so.0.8800.0")
    mem = open(f"/proc/{shell}/mem", "rb")
    ctx = u64(mem, glib + GLIB_SLOT)
    mem.close()
    # callback source used by default-context qcb; scan hash is unstable,
    # reuse last known from maps: pick first GSource-looking ptr via idle sample.
    src = 0
    try:
        mem = open(f"/proc/{shell}/mem", "rb")
        # GMainContext sources hash at +56 on this glib (qcb-ctx used SRC_DEFAULT).
        # Fall back: read ctx+200 scratch if it looks like a pointer.
        cand = u64(mem, ctx + 200)
        mem.close()
        if 0x100000000 <= cand < 0x800000000000:
            src = cand
    except OSError:
        src = 0
    # Prefer the live source from /tmp if present
    hint = Path("/tmp/dagu-qcb-src")
    if hint.is_file():
        try:
            src = int(hint.read_text().strip(), 16)
        except ValueError:
            pass
    idle = sample(shell, ctx, src) if src else {"sys": "nosrc"}
    install(shell)
    kick, flip, qcb, nview, qhit = [], [], [], [], []
    qcb_cb = []  # (ts, cb)
    gaps_sampled = []
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    pending_q = None
    last_kick = None
    last_flip = None
    last_cb = None
    snaps = []
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        next_sample = 0.0
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
            now = time.clock_gettime(time.CLOCK_MONOTONIC)
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
                        last_kick = ts
                    elif "dpu_crtc_complete_flip:" in line:
                        flip.append(ts)
                        last_flip = ts
                    elif "dagu_nview:" in line:
                        nview.append(ts)
                        pending_q = None
                    elif "dagu_qarm:" in line:
                        src_hit = parse_hex_field(line, "src")
                        if src_hit:
                            src = src_hit
                    elif "dagu_qhit:" in line:
                        qhit.append(ts)
                        src_hit = parse_hex_field(line, "src")
                        if src_hit:
                            src = src_hit
                    elif "dagu_qcb:" in line:
                        qcb.append(ts)
                        cb = parse_hex_field(line, "cb")
                        qcb_cb.append((ts, cb))
                        if last_flip is not None and 0 <= (ts - last_flip) * 1000.0 <= 8:
                            pending_q = ts
                            last_cb = cb
                            next_sample = now + 0.012
            if pending_q is not None and now >= next_sample:
                dt = (now - pending_q) * 1000.0
                if dt >= 12 and (not nview or nview[-1] < pending_q):
                    rec = sample(shell, ctx, src) if src else sample(shell, ctx, ctx)
                    rec["dt"] = round(dt, 2)
                    rec["q_from_kick"] = round((pending_q - last_kick) * 1000.0, 2) if last_kick else None
                    rec["q_from_flip"] = round((pending_q - last_flip) * 1000.0, 2) if last_flip else None
                    rec["src"] = hex(src)
                    rec["cb"] = hex(last_cb) if last_cb else None
                    snaps.append(rec)
                    next_sample = now + 0.004
                    if dt > 160:
                        gaps_sampled.append({"q": pending_q, "snaps": snaps[-8:]})
                        pending_q = None
                elif nview and nview[-1] >= pending_q:
                    pending_q = None
            if not chunk:
                time.sleep(0.0004)
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    clear()
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        q = [round((x - a) * 1000.0, 2) for x in qcb if a - 0.004 <= x <= b + 0.002]
        miss = [round((x - a) * 1000.0, 2) for x in qhit if a - 0.004 <= x <= b + 0.002]
        n = [round((x - a) * 1000.0, 2) for x in nview if a - 0.004 <= x <= b + 0.002]
        f = [round((x - a) * 1000.0, 2) for x in flip if a - 0.008 <= x <= b + 0.002]
        early_q = [x for x in q if -2 <= x <= 15]
        early_n = [x for x in n if -2 <= x <= 15]
        late_n = [x for x in n if x >= 40]
        holes.append({
            "gap_ms": round(gap, 1),
            "flip": f[:4],
            "qcb": q[:6],
            "qhit": miss[:4],
            "qcb_cb": [
                {"dt": round((t - a) * 1000.0, 2), "cb": hex(cb) if cb else None}
                for t, cb in qcb_cb if a - 0.004 <= t <= a + 0.012
            ][:6],
            "nview": n[:4],
            "kind": "nview-late" if late_n and not early_n and early_q else (
                "nview-ok" if early_n else "other"),
        })
    syss = Counter(s.get("sys") for s in snaps)
    out = {
        "kind": "qcb-between",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "ctx": hex(ctx),
        "src": hex(src),
        "idle": idle,
        "kick": summary(kick),
        "n_qcb": len(qcb),
        "n_qhit": len(qhit),
        "cb_all": dict(Counter(hex(cb) if cb else "0" for _, cb in qcb_cb)),
        "cb_postflip": dict(Counter(
            hex(cb) if cb else "0"
            for t, cb in qcb_cb
            if any(0 <= (t - f) * 1000.0 <= 8 for f in flip)
        )),
        "n_nview": len(nview),
        "n_snaps": len(snaps),
        "sys_snaps": dict(syss),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
        "snaps_head": snaps[:24],
        "late_snaps": [s for s in snaps if s.get("dt", 0) >= 20][:16],
    }
    Path("/tmp/dagu-qcb-between.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-qcb-between-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-qcb-between-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-qcb-between-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-qcb-between.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
    return r.returncode


def main():
    args = [a for a in sys.argv[1:] if a != "--host"]
    seconds = 8.0
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
