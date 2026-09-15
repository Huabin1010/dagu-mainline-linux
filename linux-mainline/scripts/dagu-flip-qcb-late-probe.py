#!/usr/bin/env python3
"""Type B: complete_flip on time, queue_callback 65–90ms late.

Hooks live mutter: drmHandleEvent, flipped_in_impl, qcb, nview.
After flip, if no hev in 8ms, sample KMS thread syscall/wchan/stack.
No poke, no ptrace. From host:
  python3 linux-mainline/scripts/dagu-flip-qcb-late-probe.py --host
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

SITES = {
    "dagu_hev": ("0x1b1a2c", "fd=%x0"),       # drmHandleEvent@plt
    "dagu_impl": ("0x1bd2c0", None),           # flipped_in_impl
    "dagu_qcb": ("0x1d6e40", "x1=%x1"),        # meta_thread_queue_callback
    "dagu_nview": ("0x1c4440", None),          # notify_view_crtc_presented
    "dagu_ifn": ("0x1c4388", "next=%x1"),      # ifgl cbz next; never hook 0x1c4404
    "dagu_sendcb": ("0x1673f0", None),         # wl_callback_send_done
}

SYS = {
    "-1": "running",
    "29": "ioctl",
    "56": "openat",
    "63": "read",
    "64": "write",
    "72": "pselect6",
    "73": "ppoll",
    "98": "futex",
    "113": "clock_nanosleep",
    "226": "mprotect",
}


def ssh_base():
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_pids():
    shell = lab = kms = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell") and b"--mode=ubuntu" in cmd:
            shell = int(p.name)
            for tid_p in (p / "task").iterdir():
                try:
                    comm = (tid_p / "comm").read_text().strip()
                except OSError:
                    continue
                if comm == "KMS thread":
                    kms = int(tid_p.name)
        elif cmd.startswith(b"python") and b"dagu-native-lab.py" in cmd:
            lab = int(p.name)
    if shell is None or lab is None or kms is None:
        raise SystemExit(json.dumps({
            "err": "need ubuntu+lab+kms", "shell": shell, "lab": lab, "kms": kms,
        }))
    return shell, lab, kms


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


def parse_tid(line):
    head = line.split(" [", 1)[0].strip()
    if "-" not in head:
        return None
    try:
        return int(head.rsplit("-", 1)[1])
    except ValueError:
        return None


def read_sys(tid):
    try:
        raw = Path(f"/proc/{tid}/syscall").read_text().strip()
    except OSError:
        return "gone", None, []
    if raw == "running":
        return "running", None, []
    parts = raw.split()
    try:
        nr = parts[0]
        args = [int(x, 16) for x in parts[1:7]]
    except (ValueError, IndexError):
        return raw.split()[0] if raw else "gone", None, []
    return SYS.get(nr, nr), args[0] if args else None, args


def read_wchan(tid):
    try:
        return Path(f"/proc/{tid}/wchan").read_text().strip() or None
    except OSError:
        return None


def read_stack(tid, limit=8):
    try:
        lines = Path(f"/proc/{tid}/stack").read_text().splitlines()
    except OSError:
        return []
    out = []
    for line in lines[:limit]:
        s = line.strip()
        if s.startswith("["):
            s = s.split("]", 1)[-1].strip()
        if s:
            out.append(s)
    return out


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


def rel(xs, t0, lo, hi, limit=8):
    return [round((x - t0) * 1000.0, 2) for x in xs if lo <= x <= hi][:limit]


def classify(kick_t, nxt, flip, hev, impl, qcb, nview, sendcb, ifn):
    # this-frame flip is the first complete_flip after kickoff, not the
    # leftover from the previous frame sitting at -8..0.
    f = first_after(flip, kick_t, 0, 20)
    f_late = first_after(flip, kick_t, 20, 250)
    h = first_after(hev, kick_t, 0, 250)
    im = first_after(impl, kick_t, 0, 250)
    q = first_after(qcb, kick_t, 0, 250)
    n = first_after(nview, kick_t, 0, 250)
    s = first_after(sendcb, kick_t, 0, 250)
    i = first_after(ifn, kick_t, 0, 250)
    early_n = n is not None and n <= 15
    early_q = q is not None and q <= 15
    late_q = q is None or q >= 40
    late_h = h is None or h >= 40
    late_im = im is None or im >= 40
    if f is None and f_late is not None:
        kind = "kick-late"
    elif f is None:
        kind = "no-flip"
    elif early_n:
        kind = "ifn-idle"
    elif late_q and late_h:
        kind = "hev-late"
    elif late_q and late_im:
        kind = "impl-late"
    elif late_q:
        kind = "qcb-late"
    elif early_q and (n is None or n >= 40):
        kind = "nview-late"
    else:
        kind = "other"
    return {
        "kind": kind,
        "flip": f,
        "flip_late": f_late,
        "hev": h,
        "impl": im,
        "qcb0": q,
        "nview": n,
        "sendcb": s,
        "ifn": i,
        "hev_after_flip": None if h is None or f is None else round(h - f, 2),
        "send_after_nview": None if s is None or n is None else round(s - n, 2),
    }


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
        for name, (off, fetch) in SITES.items():
            line = f"p:{name} {mf}:{off}"
            if fetch:
                line += f" {fetch}"
            os.write(fd, (line + "\n").encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    (TR / "events/dpu/dpu_crtc_complete_flip/enable").write_text("1\n")
    vbl = TR / "events/drm/drm_vblank_event_delivered/enable"
    if vbl.is_file():
        vbl.write_text("1\n")
    return mf


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    for rel_path in (
        "events/dpu/dpu_crtc_complete_flip/enable",
        "events/drm/drm_vblank_event_delivered/enable",
    ):
        p = TR / rel_path
        if p.is_file():
            p.write_text("0\n")
    (TR / "tracing_on").write_text("1\n")


def on_device(seconds=12.0):
    shell, lab, kms = find_pids()
    mf = install(shell)
    kick, flip, vbl, hev, impl, qcb, nview = [], [], [], [], [], [], []
    sendcb, ifn = [], []
    hev_fd = []
    qcb_x1 = []
    snaps = []
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    pending_flip = None
    last_kick = None
    last_flip = None
    last_hev = None
    hole_snaps = 0
    holes_sampled = 0
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
                        if holes_sampled < 4:
                            pending_flip = ts
                            next_sample = now + 0.008
                            hole_snaps = 0
                    elif "drm_vblank_event_delivered:" in line:
                        vbl.append(ts)
                    elif "dagu_hev:" in line:
                        hev.append(ts)
                        last_hev = ts
                        fd = parse_hex_field(line, "fd")
                        hev_fd.append((ts, parse_tid(line), fd))
                        if pending_flip is not None and ts >= pending_flip:
                            pending_flip = None
                            hole_snaps = 0
                    elif "dagu_impl:" in line:
                        impl.append(ts)
                    elif "dagu_nview:" in line:
                        nview.append(ts)
                    elif "dagu_ifn:" in line:
                        if parse_hex_field(line, "next") == 0:
                            ifn.append(ts)
                    elif "dagu_sendcb:" in line:
                        sendcb.append(ts)
                    elif "dagu_qcb:" in line:
                        qcb.append(ts)
                        qcb_x1.append((ts, parse_hex_field(line, "x1"), parse_tid(line)))
            if pending_flip is not None and now >= next_sample and hole_snaps < 10:
                dt = (now - pending_flip) * 1000.0
                if last_hev is not None and last_hev >= pending_flip:
                    pending_flip = None
                    hole_snaps = 0
                elif dt >= 8:
                    sysn, a0, args = read_sys(kms)
                    rec = {
                        "dt": round(dt, 2),
                        "sys": sysn,
                        "a0": hex(a0) if isinstance(a0, int) else a0,
                        "wchan": read_wchan(kms),
                        "stack": read_stack(kms),
                        "flip_from_kick": round((pending_flip - last_kick) * 1000.0, 2)
                        if last_kick else None,
                    }
                    snaps.append(rec)
                    hole_snaps += 1
                    next_sample = now + 0.008
                    if dt > 160:
                        pending_flip = None
                        holes_sampled += 1
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
        info = classify(a, b, flip, hev, impl, qcb, nview, sendcb, ifn)
        info["gap_ms"] = round(gap, 1)
        info["flip_all"] = rel(flip, a, a - 0.008, b + 0.002)
        info["vbl"] = rel(vbl, a, a - 0.008, b + 0.002)
        info["hev_all"] = rel(hev, a, a - 0.004, b + 0.002)
        info["impl_all"] = rel(impl, a, a - 0.004, b + 0.002)
        info["qcb"] = rel(qcb, a, a - 0.004, b + 0.002)
        info["nview_all"] = rel(nview, a, a - 0.004, b + 0.002)
        info["ifn_all"] = rel(ifn, a, a - 0.004, b + 0.002)
        info["sendcb_all"] = rel(sendcb, a, a - 0.004, b + 0.002)
        holes.append(info)
    out = {
        "kind": "flip-qcb-late",
        "shell": shell,
        "lab": lab,
        "kms": kms,
        "seconds": seconds,
        "mf": mf,
        "kick": summary(kick),
        "flip": summary(flip),
        "n_vbl": len(vbl),
        "n_hev": len(hev),
        "n_impl": len(impl),
        "n_qcb": len(qcb),
        "n_nview": len(nview),
        "n_ifn": len(ifn),
        "n_sendcb": len(sendcb),
        "hev_tid": dict(Counter(t for _, t, _ in hev_fd)),
        "hev_fd": dict(Counter(fd for _, _, fd in hev_fd)),
        "qcb_tid": dict(Counter(t for _, _, t in qcb_x1)),
        "n_snaps": len(snaps),
        "sys_snaps": dict(Counter(s.get("sys") for s in snaps)),
        "wchan_snaps": dict(Counter(s.get("wchan") for s in snaps)),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:8],
        "snaps": snaps[:32],
    }
    Path("/tmp/dagu-flip-qcb-late.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-flip-qcb-late-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-flip-qcb-late-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-flip-qcb-late-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-flip-qcb-late.json", str(dest)], check=False)
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
