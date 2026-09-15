#!/usr/bin/env python3
"""Type A: ring0 workqueue queue vs execute vs drm_sched_job_run.

No kprobes (CONFIG_KPROBES=n). No mutter uprobes. Never open dri/0/gpu.
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
    "dpu/dpu_enc_kickoff",
    "gpu_scheduler/drm_sched_job_queue",
    "gpu_scheduler/drm_sched_job_run",
    "gpu_scheduler/drm_sched_job_done",
    "drm_msm_gpu/msm_gpu_suspend",
    "drm_msm_gpu/msm_gpu_resume",
    "workqueue/workqueue_queue_work",
    "workqueue/workqueue_execute_start",
    "workqueue/workqueue_execute_end",
)

RUNW = "ffffffed361c5370"
FREEW = "ffffffed361c4ce4"


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


def parse_fence(line):
    tok = "fence="
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


def who_name(pid, shell, lab):
    if pid == shell:
        return "shell"
    if pid == lab:
        return "lab"
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return f"p{pid}"


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


def wfilter(rel, text):
    p = TR / "events" / rel / "filter"
    p.write_text(text if text else "0\n")


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
    wfilter("workqueue/workqueue_queue_work",
            f'function == 0x{RUNW} || function == 0x{FREEW}')
    wfilter("workqueue/workqueue_execute_start",
            f'function == 0x{RUNW} || function == 0x{FREEW}')
    wfilter("workqueue/workqueue_execute_end",
            f'function == 0x{RUNW} || function == 0x{FREEW}')
    for ev in EV:
        ev_enable(ev, True)


def clear():
    for rel in (
        "workqueue/workqueue_queue_work",
        "workqueue/workqueue_execute_start",
        "workqueue/workqueue_execute_end",
    ):
        try:
            ev_enable(rel, False)
            wfilter(rel, "0")
        except OSError:
            pass
    for ev in EV:
        ev_enable(ev, False)
    (TR / "tracing_on").write_text("1\n")


def dt_ms(t, t0):
    if t is None:
        return None
    return round((t - t0) * 1000.0, 2)


def fn_kind(line):
    if "drm_sched_run_job_work" in line or RUNW in line:
        return "runw"
    if "drm_sched_free_job_work" in line or FREEW in line:
        return "freew"
    return "other"


def on_device(seconds=8.0):
    shell, lab = find_pids()
    install()
    kick = []
    jobs = {}
    wq_q, wq_s, wq_e = [], [], []
    sus, res = [], []
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
                elif "msm_gpu_suspend:" in line:
                    sus.append(ts)
                elif "msm_gpu_resume:" in line:
                    res.append(ts)
                elif "workqueue_queue_work:" in line:
                    wq_q.append({"t": ts, "fn": fn_kind(line)})
                elif "workqueue_execute_start:" in line:
                    wq_s.append({"t": ts, "fn": fn_kind(line)})
                elif "workqueue_execute_end:" in line:
                    wq_e.append({"t": ts, "fn": fn_kind(line)})
                elif "drm_sched_job_queue:" in line:
                    fence = parse_fence(line)
                    if not fence:
                        continue
                    jobs[fence] = {
                        "who": who_name(pid, shell, lab),
                        "jc": parse_tagged(line, ", job count"),
                        "hw": parse_tagged(line, "hw job count"),
                        "t_q": ts,
                        "t_run": None,
                        "t_done": None,
                    }
                elif "drm_sched_job_run:" in line:
                    fence = parse_fence(line)
                    if fence:
                        rec = jobs.setdefault(fence, {"who": who_name(pid, shell, lab)})
                        rec["t_run"] = ts
                elif "drm_sched_job_done:" in line:
                    fence = parse_fence(line)
                    if fence:
                        rec = jobs.setdefault(fence, {})
                        rec["t_done"] = ts
    finally:
        pipe.close()
        clear()

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = 1000.0 * (b - a)
        if gap <= 50:
            continue
        pending = []
        for fence, rec in jobs.items():
            tq, tr, td = rec.get("t_q"), rec.get("t_run"), rec.get("t_done")
            if tq is not None and tq < a and (td is None or td >= a):
                pending.append({
                    "who": rec.get("who"),
                    "seq": fence[1],
                    "jc": rec.get("jc"),
                    "hw": rec.get("hw"),
                    "q": dt_ms(tq, a),
                    "run": dt_ms(tr, a),
                    "done": dt_ms(td, a),
                })
        pending.sort(key=lambda x: (x["q"] is None, x["q"] or 0))
        inflight = []
        long_run = []
        for fence, rec in jobs.items():
            tr, td = rec.get("t_run"), rec.get("t_done")
            if tr is not None and tr < a and (td is None or td >= a):
                inflight.append({
                    "who": rec.get("who"),
                    "seq": fence[1],
                    "run": dt_ms(tr, a),
                    "done": dt_ms(td, a),
                    "dur": None if td is None else round((td - tr) * 1000.0, 2),
                })
            if tr is not None and a - 0.03 <= tr <= b and td is not None:
                dur = (td - tr) * 1000.0
                if dur >= 5.0:
                    long_run.append({
                        "who": rec.get("who"),
                        "seq": fence[1],
                        "run": dt_ms(tr, a),
                        "done": dt_ms(td, a),
                        "dur": round(dur, 2),
                    })
        inflight.sort(key=lambda x: (x["run"] is None, x["run"] or 0))
        long_run.sort(key=lambda x: (x["dur"] is None, -(x["dur"] or 0)))

        def around(xs, key="t"):
            out = []
            for r in xs:
                t = r[key] if isinstance(r, dict) else r
                if a - 0.02 <= t <= b:
                    item = {"dt": dt_ms(t, a)}
                    if isinstance(r, dict) and "fn" in r:
                        item["fn"] = r["fn"]
                    out.append(item)
            return out

        q_mid = around(wq_q)
        s_mid = around(wq_s)
        e_mid = around(wq_e)
        q_before = [dt_ms(r["t"], a) for r in wq_q if a - 0.03 <= r["t"] < a]
        s_before = [dt_ms(r["t"], a) for r in wq_s if a - 0.03 <= r["t"] < a]
        holes.append({
            "gap": round(gap, 1),
            "kind": "A-pending" if pending else "B-empty",
            "pending_n": len(pending),
            "pending": pending[:8],
            "inflight_n": len(inflight),
            "inflight": inflight[:8],
            "long_run": long_run[:6],
            "wq_q_before": q_before[-6:],
            "wq_s_before": s_before[-6:],
            "wq_q_mid": q_mid[:4] + ([{"gap": True}] + q_mid[-4:] if len(q_mid) > 8 else []),
            "wq_s_mid": s_mid[:4] + ([{"gap": True}] + s_mid[-4:] if len(s_mid) > 8 else []),
            "wq_e_mid": e_mid[:4] + ([{"gap": True}] + e_mid[-4:] if len(e_mid) > 8 else []),
            "first_q_mid": q_mid[0]["dt"] if q_mid else None,
            "first_s_mid": s_mid[0]["dt"] if s_mid else None,
            "n_q_mid": len(q_mid),
            "n_s_mid": len(s_mid),
            "sus": [dt_ms(t, a) for t in sus if a - 0.05 <= t <= b][:4],
            "res": [dt_ms(t, a) for t in res if a - 0.05 <= t <= b][:4],
        })

    out = {
        "kind": "sched-wq",
        "shell": shell,
        "lab": lab,
        "kick": summary(kick),
        "n_jobs": len(jobs),
        "n_wq_q": len(wq_q),
        "n_wq_s": len(wq_s),
        "n_wq_e": len(wq_e),
        "wq_fn": dict(Counter(r["fn"] for r in wq_s)),
        "kinds": dict(Counter(h["kind"] for h in holes)),
        "holes": holes,
    }
    Path("/tmp/dagu-sched-wq.json").write_text(json.dumps(out, indent=2) + "\n")
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
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-sched-wq-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-sched-wq-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-sched-wq-{stamp}.json"
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + ["sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'"], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-sched-wq.json", str(dest)], check=False)
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
