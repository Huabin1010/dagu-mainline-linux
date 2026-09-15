#!/usr/bin/env python3
"""Type A: all-ctx drm_sched pending/credits at dpu_enc_kickoff holes.

No mutter uprobes. Never open dri/0/gpu. Restore tracing_on=1.
Uses gpu_scheduler traces: queue hw_job_count == credit_count,
job count == entity queue depth before this push (0 => first => wakeup).
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

EV = (
    "gpu_scheduler/drm_sched_job_queue",
    "gpu_scheduler/drm_sched_job_run",
    "gpu_scheduler/drm_sched_job_done",
    "gpu_scheduler/drm_sched_job_unschedulable",
    "gpu_scheduler/drm_sched_job_add_dep",
    "dpu/dpu_enc_kickoff",
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
        elif cmd.startswith(b"python") and b"dagu-native-lab.py" in cmd:
            lab = int(p.name)
    if shell is None or lab is None:
        raise SystemExit(json.dumps({"err": "need ubuntu+lab", "shell": shell, "lab": lab}))
    return shell, lab


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


def parse_tagged(line, key):
    tok = f"{key}:"
    i = line.find(tok)
    if i < 0:
        tok = f"{key}="
        i = line.find(tok)
        if i < 0:
            return None
    v = line[i + len(tok):].split()[0].rstrip(",")
    try:
        return int(v, 10)
    except ValueError:
        return None


def parse_fence(line, key="fence"):
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


def who_name(pid, shell, lab):
    if pid == shell:
        return "shell"
    if pid == lab:
        return "lab"
    return f"{comm_of(pid)}:{pid}"


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


def install():
    (TR / "tracing_on").write_text("0\n")
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("32768\n")
    for ev in EV:
        ev_enable(ev, True)


def clear():
    for ev in EV:
        ev_enable(ev, False)
    (TR / "tracing_on").write_text("1\n")


def dt_ms(t, t0):
    if t is None:
        return None
    return round((t - t0) * 1000.0, 2)


def on_device(seconds=8.0):
    shell, lab = find_pids()
    install()
    kick = []
    jobs = {}
    unsched = []
    deps = []
    ctx_who = {}
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
                    continue
                fence = parse_fence(line)
                if "drm_sched_job_queue:" in line and fence:
                    hw = parse_tagged(line, "hw job count")
                    jc = parse_tagged(line, ", job count")
                    cid = parse_tagged(line, "client_id")
                    who = who_name(pid, shell, lab)
                    ctx_who.setdefault(fence[0], who)
                    jobs[fence] = {
                        "who": who,
                        "pid": pid,
                        "client_id": cid,
                        "job_count": jc,
                        "hw_q": hw,
                        "t_q": ts,
                        "t_run": None,
                        "t_done": None,
                        "hw_run": None,
                    }
                elif "drm_sched_job_run:" in line and fence:
                    rec = jobs.get(fence)
                    if rec is None:
                        rec = jobs.setdefault(fence, {
                            "who": who_name(pid, shell, lab),
                            "t_q": None,
                        })
                    rec["t_run"] = ts
                    rec["hw_run"] = parse_tagged(line, "hw job count")
                    rec["job_count_run"] = parse_tagged(line, ", job count")
                elif "drm_sched_job_done:" in line and fence:
                    rec = jobs.get(fence)
                    if rec is None:
                        rec = jobs.setdefault(fence, {"who": ctx_who.get(fence[0], "?")})
                    rec["t_done"] = ts
                elif "drm_sched_job_unschedulable:" in line and fence:
                    dep = parse_fence(line, "unsignalled fence")
                    if dep is None:
                        i = line.find("depends on unsignalled fence=")
                        if i >= 0:
                            rest = line[i + len("depends on unsignalled fence="):].split()[0]
                            if ":" in rest:
                                a, b = rest.split(":", 1)
                                try:
                                    dep = (int(a), int(b))
                                except ValueError:
                                    dep = None
                    unsched.append({
                        "t": ts,
                        "fence": fence,
                        "who": ctx_who.get(fence[0], who_name(pid, shell, lab)),
                        "dep": list(dep) if dep else None,
                    })
                elif "drm_sched_job_add_dep:" in line and fence:
                    dep = None
                    i = line.find("depends on fence=")
                    if i >= 0:
                        rest = line[i + len("depends on fence="):].split()[0]
                        if ":" in rest:
                            a, b = rest.split(":", 1)
                            try:
                                dep = (int(a), int(b))
                            except ValueError:
                                dep = None
                    deps.append({"t": ts, "fence": fence, "dep": list(dep) if dep else None})
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = 1000.0 * (b - a)
        if gap <= 50:
            continue
        pending = []
        inflight = []
        for fence, rec in jobs.items():
            tq = rec.get("t_q")
            tr = rec.get("t_run")
            td = rec.get("t_done")
            queued = tq is not None and tq < a
            ran = tr is not None and tr < a
            finished = td is not None and td < a
            if queued and not finished:
                pending.append({
                    "who": rec.get("who"),
                    "seq": fence[1],
                    "ctx": fence[0],
                    "client_id": rec.get("client_id"),
                    "job_count": rec.get("job_count"),
                    "hw_q": rec.get("hw_q"),
                    "q": dt_ms(tq, a),
                    "run": dt_ms(tr, a),
                    "done": dt_ms(td, a),
                    "hw_run": rec.get("hw_run"),
                    "age_ms": dt_ms(tq, a),
                })
            if ran and not finished:
                inflight.append({
                    "who": rec.get("who"),
                    "seq": fence[1],
                    "ctx": fence[0],
                    "hw_run": rec.get("hw_run"),
                    "run": dt_ms(tr, a),
                    "done": dt_ms(td, a),
                })
        pending.sort(key=lambda x: (x["q"] is None, x["q"] or 0))
        uns_mid = []
        for u in unsched:
            if a - 0.05 <= u["t"] <= b:
                uns_mid.append({
                    "dt": dt_ms(u["t"], a),
                    "who": u["who"],
                    "seq": u["fence"][1],
                    "dep": u["dep"],
                })
        first_run = None
        for p in pending:
            if p.get("run") is not None:
                if first_run is None or p["run"] < first_run:
                    first_run = p["run"]
        kind = "A-pending" if pending else "B-empty"
        holes.append({
            "gap": round(gap, 1),
            "kind": kind,
            "pending_n": len(pending),
            "inflight_n": len(inflight),
            "pending_who": dict(Counter(p["who"] for p in pending)),
            "inflight_who": dict(Counter(p["who"] for p in inflight)),
            "hw_q_max": max((p["hw_q"] for p in pending if p["hw_q"] is not None), default=None),
            "job_count_max": max((p["job_count"] for p in pending if p["job_count"] is not None), default=None),
            "n_first": sum(1 for p in pending if p.get("job_count") == 0),
            "first_pending_run": first_run,
            "pending": pending[:12],
            "inflight": inflight[:8],
            "unsched_n": len(uns_mid),
            "unsched": uns_mid[:8],
        })

    out = {
        "kind": "sched-credit",
        "shell": shell,
        "lab": lab,
        "seconds": seconds,
        "kick": summary(kick),
        "n_jobs": len(jobs),
        "n_unsched": len(unsched),
        "n_deps": len(deps),
        "who": dict(Counter(r.get("who") for r in jobs.values())),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes,
    }
    Path("/tmp/dagu-sched-credit.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-sched-credit-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-sched-credit-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-sched-credit-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-sched-credit.json", str(dest)], check=False)
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
