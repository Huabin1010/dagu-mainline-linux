#!/usr/bin/env python3
"""ifn-idle: who enqueues MSM GPU jobs (lab vs gnome-shell vs other).

Uses kernel drm_msm_gpu + drm_sched events. Never open dri/0/gpu hangrd rd.
Never hook 0x1c4404 / cave / 0x84e0 / 0x18fdbc.
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

MSM_EV = (
    "drm_msm_gpu/msm_gpu_submit",
    "drm_msm_gpu/msm_gpu_submit_flush",
    "drm_msm_gpu/msm_gpu_submit_retired",
    "gpu_scheduler/drm_sched_job_queue",
    "gpu_scheduler/drm_sched_job_run",
    "gpu_scheduler/drm_sched_job_done",
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


def comm_of(pid):
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return "?"


def who_name(pid, ev_pid, shell, lab):
    p = ev_pid if ev_pid else pid
    if p == shell:
        return "shell"
    if p == lab:
        return "lab"
    return f"{comm_of(p)}:{p}"


def first_after(xs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    for x in xs:
        if lo <= x <= hi:
            return round((x - t0) * 1000.0, 2)
    return None


def last_before(recs, t0, lo_ms=0):
    lo = t0 + lo_ms / 1000.0
    last = None
    for r in recs:
        if r["t"] < lo:
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


def between(recs, t0, lo_ms, hi_ms):
    lo = t0 + lo_ms / 1000.0
    hi = t0 + hi_ms / 1000.0
    return [r for r in recs if lo <= r["t"] <= hi]


def slim(r):
    keep = ("dt", "who", "id", "seq", "ring", "elapsed_ms", "bos", "cmds", "fence")
    return {k: r[k] for k in keep if k in r and r[k] is not None}


def counts_who(recs):
    return dict(Counter(r["who"] for r in recs))


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


def on_device(seconds=12.0):
    shell, lab = find_pids()
    install(shell)
    kick, nview, ifn, add = [], [], [], []
    submit, flush, retired, queue, run, done = [], [], [], [], [], []
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
                elif "msm_gpu_submit:" in line:
                    submit.append({
                        "t": ts,
                        "who": who_name(pid, ev_pid, shell, lab),
                        "id": parse_int_field(line, "id"),
                        "ring": parse_int_field(line, "ring"),
                        "bos": parse_int_field(line, "bos"),
                        "cmds": parse_int_field(line, "cmds"),
                    })
                elif "msm_gpu_submit_flush:" in line:
                    flush.append({
                        "t": ts,
                        "who": who_name(pid, ev_pid, shell, lab),
                        "id": parse_int_field(line, "id"),
                        "seq": parse_int_field(line, None) if False else None,
                        "ring": None,
                    })
                    # print: id=%d pid=%d ring=%d:%d ticks=%lld
                    pair = None
                    i = line.find("ring=")
                    if i >= 0:
                        v = line[i + 5:].split()[0]
                        if ":" in v:
                            r, s = v.split(":", 1)
                            try:
                                flush[-1]["ring"] = int(r)
                                flush[-1]["seq"] = int(s)
                            except ValueError:
                                pass
                elif "msm_gpu_submit_retired:" in line:
                    rec = {
                        "t": ts,
                        "who": who_name(pid, ev_pid, shell, lab),
                        "id": parse_int_field(line, "id"),
                        "elapsed_ms": None,
                    }
                    i = line.find("elapsed=")
                    if i >= 0:
                        v = line[i + 8:].split()[0]
                        try:
                            rec["elapsed_ms"] = round(int(v) / 1e6, 2)
                        except ValueError:
                            pass
                    pair = None
                    i = line.find("ring=")
                    if i >= 0:
                        v = line[i + 5:].split()[0].rstrip(",")
                        if ":" in v:
                            r, s = v.split(":", 1)
                            try:
                                rec["ring"] = int(r)
                                rec["seq"] = int(s)
                            except ValueError:
                                pass
                    retired.append(rec)
                elif "drm_sched_job_queue:" in line:
                    if "ring0" not in line and "ring0182" not in line:
                        continue
                    queue.append({
                        "t": ts,
                        "who": who_name(pid, None, shell, lab),
                        "fence": parse_u64_pair(line, "fence"),
                    })
                elif "drm_sched_job_run:" in line:
                    if "ring0" not in line and "ring0182" not in line:
                        continue
                    run.append({
                        "t": ts,
                        "who": who_name(pid, None, shell, lab),
                        "fence": parse_u64_pair(line, "fence"),
                    })
                elif "drm_sched_job_done:" in line:
                    done.append({
                        "t": ts,
                        "who": who_name(pid, None, shell, lab),
                        "fence": parse_u64_pair(line, "fence"),
                    })
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
        add_dt = first_after(add, a, 0, 280)
        lo = ifn_dt if ifn_dt is not None else 0
        hi = add_dt if add_dt is not None else min(gap, 280)
        sub_mid = between(submit, a, lo, hi)
        flush_mid = between(flush, a, lo, hi)
        ret_mid = between(retired, a, lo, hi)
        run_mid = between(run, a, lo, hi)
        holes.append({
            "gap_ms": round(gap, 1),
            "kind": kind,
            "nview": first_after(nview, a, 0, 280),
            "ifn": first_after(ifn, a, 0, 280),
            "add": add_dt,
            "submit_before": slim(last_before(submit, a)) if last_before(submit, a) else None,
            "flush_before": slim(last_before(flush, a)) if last_before(flush, a) else None,
            "retired_before": slim(last_before(retired, a)) if last_before(retired, a) else None,
            "run_before": slim(last_before(run, a)) if last_before(run, a) else None,
            "submit_mid_n": counts_who(sub_mid),
            "flush_mid_n": counts_who(flush_mid),
            "retired_mid_n": counts_who(ret_mid),
            "run_mid_n": counts_who(run_mid),
            "first_flush_mid": slim(first_rec(flush, a, lo, hi) or {}) or None,
            "first_retired_mid": slim(first_rec(retired, a, lo, hi) or {}) or None,
            "first_run_mid": slim(first_rec(run, a, lo, hi) or {}) or None,
            "first_done_mid": slim(first_rec(done, a, lo, hi) or {}) or None,
            "retired_near_add": slim(first_rec(retired, a, (add_dt - 8) if add_dt else lo, (add_dt + 8) if add_dt else hi) or {}) or None,
        })

    out = {
        "kind": "msm-submit-hole",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_submit": len(submit),
        "n_flush": len(flush),
        "n_retired": len(retired),
        "n_queue": len(queue),
        "n_run": len(run),
        "n_done": len(done),
        "submit_who": counts_who(submit),
        "flush_who": counts_who(flush),
        "retired_who": counts_who(retired),
        "run_who": counts_who(run),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes[:12],
    }
    Path("/tmp/dagu-msm-submit-hole.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-msm-submit-hole-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-msm-submit-hole-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-msm-submit-hole-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-msm-submit-hole.json", str(dest)], check=False)
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
