#!/usr/bin/env python3
"""ifn-idle: attach-time sync_file seq vs last drm_sched done / MSM retired.

Never open dri/0/gpu hangrd rd. Never hook 0x1c4404 / cave / 0x84e0.
"""
from __future__ import annotations

import ctypes
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")

MSM_EV = (
    "drm_msm_gpu/msm_gpu_submit",
    "drm_msm_gpu/msm_gpu_submit_retired",
    "gpu_scheduler/drm_sched_job_queue",
    "gpu_scheduler/drm_sched_job_done",
)
SEQ_RE = re.compile(r"(\d+)$")


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


def parse_u64_pair(line, key):
    tok = f"{key}="
    i = line.find(tok)
    if i < 0:
        return None
    v = line[i + len(tok):].split()[0].rstrip(",")
    if ":" not in v:
        return None
    a, b = v.split(":", 1)
    try:
        return int(a), int(b)
    except ValueError:
        return None


def name_seq(s):
    if not s:
        return None
    m = SEQ_RE.search(s)
    return int(m.group(1)) if m else None


def sync_file_info(pid, n):
    class Info(ctypes.Structure):
        _fields_ = [
            ("name", ctypes.c_char * 32),
            ("status", ctypes.c_int32),
            ("flags", ctypes.c_uint32),
            ("num_fences", ctypes.c_uint32),
            ("pad", ctypes.c_uint32),
            ("sync_fence_info", ctypes.c_uint64),
        ]

    class Fence(ctypes.Structure):
        _fields_ = [
            ("obj_name", ctypes.c_char * 32),
            ("driver_name", ctypes.c_char * 32),
            ("status", ctypes.c_int32),
            ("flags", ctypes.c_uint32),
            ("timestamp_ns", ctypes.c_uint64),
        ]

    IOC = 0xC0383E04
    libc = ctypes.CDLL(None, use_errno=True)
    pidfd = libc.syscall(434, ctypes.c_int(pid), ctypes.c_uint(0))
    fd = None
    if pidfd >= 0:
        got = libc.syscall(438, ctypes.c_int(pidfd), ctypes.c_int(n), ctypes.c_uint(0))
        os.close(pidfd)
        if got >= 0:
            fd = got
    if fd is None:
        return None
    try:
        inf = Info()
        try:
            fcntl.ioctl(fd, IOC, inf)
        except OSError:
            return {"err": "ioctl0"}
        nfen = inf.num_fences
        fences = []
        if nfen:
            arr = (Fence * min(nfen, 4))()
            inf2 = Info()
            inf2.num_fences = min(nfen, 4)
            inf2.sync_fence_info = ctypes.addressof(arr)
            try:
                fcntl.ioctl(fd, IOC, inf2)
            except OSError:
                return {"err": "ioctl1", "n": nfen}
            for i in range(inf2.num_fences):
                f = arr[i]
                obj = f.obj_name.split(b"\x00", 1)[0].decode("ascii", "replace")
                drv = f.driver_name.split(b"\x00", 1)[0].decode("ascii", "replace")
                fences.append({
                    "obj": obj,
                    "drv": drv,
                    "st": f.status,
                    "seq": name_seq(obj) or name_seq(
                        inf.name.split(b"\x00", 1)[0].decode("ascii", "replace")
                    ),
                })
        return {
            "name": inf.name.split(b"\x00", 1)[0].decode("ascii", "replace"),
            "status": inf.status,
            "n": nfen,
            "fences": fences,
        }
    finally:
        os.close(fd)


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def last_before(recs, t0):
    last = None
    for r in recs:
        if r["t"] < t0:
            last = r
        else:
            break
    if last is None:
        return None
    out = {k: v for k, v in last.items() if k != "t"}
    out["dt"] = round((last["t"] - t0) * 1000.0, 2)
    return out


def first_rec(recs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for r in recs:
        if lo <= r["t"] <= hi:
            out = {k: v for k, v in r.items() if k != "t"}
            out["dt"] = round((r["t"] - t0) * 1000.0, 2)
            return out
    return None


def first_seq(recs, t0, lo_ms, hi_ms, seq):
    if seq is None:
        return None
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for r in recs:
        if r.get("seq") != seq:
            continue
        if lo <= r["t"] <= hi:
            out = {k: v for k, v in r.items() if k != "t"}
            out["dt"] = round((r["t"] - t0) * 1000.0, 2)
            return out
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


def ev_enable(path, on):
    p = TR / "events" / path / "enable"
    if p.is_file():
        p.write_text("1\n" if on else "0\n")


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
    (TR / "buffer_size_kb").write_text("32768\n")
    mu = map_rx(shell, "libmutter-18.so.0.0.0")
    fd = os.open(str(TR / "uprobe_events"), os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, f"p:dagu_nview {mu}:0x1c4440\n".encode())
        os.write(fd, f"p:dagu_ifnchk {mu}:0x1c4388 next=%x1\n".encode())
        os.write(fd, f"p:dagu_add {mu}:0x164fa4\n".encode())
        os.write(fd, f"p:dagu_addfd {mu}:0x18fe3c fd=%x1\n".encode())
        os.write(fd, f"p:dagu_attach {mu}:0x18fe78\n".encode())
        os.write(fd, f"p:dagu_disp {mu}:0x16e70c\n".encode())
    finally:
        os.close(fd)
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    for ev in MSM_EV:
        ev_enable(ev, True)


def clear():
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    for ev in MSM_EV:
        ev_enable(ev, False)
    (TR / "tracing_on").write_text("1\n")


def who_of(pid, ev_pid, shell, lab):
    p = ev_pid if ev_pid else pid
    if p == shell:
        return "shell"
    if p == lab:
        return "lab"
    return f"p{p}"


def classify_seq(seq, queued, done):
    if seq is None:
        return "no-seq"
    if seq in done:
        return "already-done"
    if seq in queued:
        return "queued-not-done"
    return "never-queued"


def on_device(seconds=12.0):
    shell, lab = find_pids()
    install(shell)
    kick, nview, ifn, add, attach, disp = [], [], [], [], [], []
    addfd, submit, retired, queue, done = [], [], [], [], []
    queued_seqs, done_seqs = set(), set()
    last_ret = {"lab": None, "shell": None}
    last_done = {}
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
                ev_pid = parse_int_field(line, "pid")
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                elif "dagu_nview:" in line and pid == shell:
                    nview.append(ts)
                elif "dagu_ifnchk:" in line and pid == shell:
                    if parse_hex_field(line, "next") == 0:
                        ifn.append(ts)
                elif "dagu_add:" in line and pid == shell:
                    add.append(ts)
                elif "dagu_attach:" in line and pid == shell:
                    attach.append(ts)
                elif "dagu_disp:" in line and pid == shell:
                    disp.append(ts)
                elif "dagu_addfd:" in line and pid == shell:
                    fdn = parse_hex_field(line, "fd")
                    if fdn is not None:
                        fdn = fdn & 0xFFFFFFFF
                        if fdn >= 0x80000000:
                            fdn -= 0x100000000
                    sfi = sync_file_info(shell, fdn) if fdn is not None and fdn >= 0 else None
                    seqs = [f.get("seq") for f in (sfi or {}).get("fences") or [] if f.get("seq") is not None]
                    seq = seqs[0] if seqs else name_seq((sfi or {}).get("name"))
                    klass = classify_seq(seq, queued_seqs, done_seqs)
                    addfd.append({
                        "t": ts,
                        "fd": fdn,
                        "seq": seq,
                        "klass": klass,
                        "sfi": sfi,
                        "last_ret": dict(last_ret),
                        "delta_lab": (seq - last_ret["lab"]) if seq is not None and last_ret["lab"] is not None else None,
                        "delta_shell": (seq - last_ret["shell"]) if seq is not None and last_ret["shell"] is not None else None,
                    })
                elif "msm_gpu_submit:" in line:
                    who = who_of(pid, ev_pid, shell, lab)
                    rec = {
                        "t": ts,
                        "who": who,
                        "id": parse_int_field(line, "id"),
                    }
                    submit.append(rec)
                elif "msm_gpu_submit_retired:" in line:
                    who = who_of(pid, ev_pid, shell, lab)
                    seq = None
                    i = line.find("ring=")
                    if i >= 0:
                        v = line[i + 5:].split()[0].rstrip(",")
                        if ":" in v:
                            try:
                                seq = int(v.split(":", 1)[1])
                            except ValueError:
                                pass
                    retired.append({"t": ts, "who": who, "seq": seq, "id": parse_int_field(line, "id")})
                    if seq is not None and who in last_ret:
                        last_ret[who] = seq
                elif "drm_sched_job_queue:" in line:
                    pair = parse_u64_pair(line, "fence")
                    seq = pair[1] if pair else None
                    queue.append({"t": ts, "who": who_of(pid, None, shell, lab), "ctx": pair[0] if pair else None, "seq": seq})
                    if seq is not None:
                        queued_seqs.add(seq)
                elif "drm_sched_job_done:" in line:
                    pair = parse_u64_pair(line, "fence")
                    seq = pair[1] if pair else None
                    ctx = pair[0] if pair else None
                    done.append({"t": ts, "who": who_of(pid, None, shell, lab), "ctx": ctx, "seq": seq})
                    if seq is not None:
                        done_seqs.add(seq)
                        last_done[ctx] = seq
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
        prev = last_before(addfd, a)
        seq = prev.get("seq") if prev else None
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add": first_after(add, a, 0, 280),
            "disp": first_after(disp, a, 0, 280),
            "prev_addfd": ({
                "dt": prev["dt"],
                "seq": prev.get("seq"),
                "klass": prev.get("klass"),
                "status": (prev.get("sfi") or {}).get("status"),
                "name": (prev.get("sfi") or {}).get("name"),
                "fences": (prev.get("sfi") or {}).get("fences"),
                "last_ret": prev.get("last_ret"),
                "delta_lab": prev.get("delta_lab"),
                "delta_shell": prev.get("delta_shell"),
            } if prev else None),
            "submit_before": last_before(submit, a),
            "retired_before": last_before(retired, a),
            "queue_before": last_before(queue, a),
            "done_before": last_before(done, a),
            "first_submit_after": first_rec(submit, a, 0, 280),
            "done_this_seq": first_seq(done, a, -30, 280, seq),
            "queue_this_seq": first_seq(queue, a, -280, 280, seq),
            "retired_this_seq": first_seq(retired, a, -30, 280, seq),
        })

    klass_n = dict(Counter(r.get("klass") for r in addfd))
    long_prev = [h["prev_addfd"] for h in holes if h.get("prev_addfd")]
    out = {
        "kind": "fence-seq",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_addfd": len(addfd),
        "n_submit": len(submit),
        "n_retired": len(retired),
        "n_queue": len(queue),
        "n_done": len(done),
        "klass_n": klass_n,
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:12],
        "addfd_delta_lab": dict(Counter(
            ("0" if r.get("delta_lab") == 0 else
             "+1" if r.get("delta_lab") == 1 else
             ">1" if r.get("delta_lab") is not None and r.get("delta_lab") > 1 else
             "<0" if r.get("delta_lab") is not None and r.get("delta_lab") < 0 else "?")
            for r in addfd
        )),
        "addfd_delta_shell": dict(Counter(
            ("0" if r.get("delta_shell") == 0 else
             "+1" if r.get("delta_shell") == 1 else
             ">1" if r.get("delta_shell") is not None and r.get("delta_shell") > 1 else
             "<0" if r.get("delta_shell") is not None and r.get("delta_shell") < 0 else "?")
            for r in addfd
        )),
    }
    Path("/tmp/dagu-fence-seq.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-fence-seq-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-fence-seq-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-fence-seq-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-fence-seq.json", str(dest)], check=False)
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
