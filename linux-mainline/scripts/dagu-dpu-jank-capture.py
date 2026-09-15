#!/usr/bin/env python3
"""DPU ftrace on the local pipeline lab (not Bilibili).

idle → slow feed scroll → fast flicks → idle.
Does not enable FUNCTION_TRACER or hw_log_mask.
From host: python3 linux-mainline/scripts/dagu-dpu-jank-capture.py --host
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
OUT_HOST = ROOT / "out/display-stress"
OUT_DEV = Path("/var/log/dagu-dpu")
TR = Path("/sys/kernel/debug/tracing")

RC_EVENT = {1: "KICKOFF", 2: "FRAME_DONE", 3: "PRE_STOP", 4: "STOP", 5: "ENTER_IDLE"}
RC_STATE = {0: "OFF", 1: "PRE_OFF", 2: "ON", 3: "IDLE"}
LINE_RE = re.compile(
    r"^\s*(?P<comm>\S+)-(?P<pid>\d+)\s+"
    r"\[(?P<cpu>\d+)\]\s+\S+\s+"
    r"(?P<ts>[\d.]+):\s+"
    r"(?P<ev>\S+):\s+(?P<rest>.*)$"
)
RC_RE = re.compile(
    r"(?P<phase>begin|kickoff|frame done|pre stop|stop|idle):\s*"
    r"id:(?P<id>\d+),\s*sw_event:(?P<ev>\d+).*rc_state:(?P<st>\d+)"
)
FLUSH_RE = re.compile(r"pending_flush_ret=(?P<bits>0x[0-9a-fA-F]+)")


def is_tablet() -> bool:
    return Path("/sys/class/drm/card0-DSI-1").exists()


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def read_vblank() -> dict:
    text = Path("/sys/kernel/debug/dri/0/crtc-0/status").read_text(errors="replace")
    out = {"fps": None, "count": None}
    for line in text.splitlines():
        if "vblank" not in line:
            continue
        for tok in line.split():
            if tok.startswith("fps:"):
                out["fps"] = float(tok.split(":", 1)[1])
            if tok.startswith("count:"):
                out["count"] = int(tok.split(":", 1)[1])
    return out


def read_int(path: str) -> int:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return -1


def arm_trace() -> None:
    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    (TR / "events/dpu/enable").write_text("1\n")
    drm = TR / "events/drm"
    if drm.is_dir():
        (drm / "enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")


NATIVE_PORTRAIT = (
    "--native-portrait" in sys.argv
    or os.environ.get("DAGU_SWIPE_NATIVE", "0") == "1"
)


def swipe_profile(profile: str) -> None:
    script = Path("/usr/local/sbin/dagu-himax-swipe.py")
    if not script.is_file():
        script = ROOT / "scripts" / "dagu-himax-swipe.py"
    cmd = [sys.executable, str(script), "--profile", profile, "--no-tap"]
    if NATIVE_PORTRAIT:
        cmd.append("--native-portrait")
    subprocess.run(cmd, check=False)


def screenshot(path: Path) -> None:
    helper = Path("/usr/local/sbin/dagu-gnome-screenshot.sh")
    if not helper.is_file():
        return
    tmp = Path("/tmp") / path.name
    subprocess.run([str(helper), "--local", str(tmp)], check=False)
    if tmp.is_file():
        path.write_bytes(tmp.read_bytes())


def gaps(ts: list[float]) -> list[float]:
    return [b - a for a, b in zip(ts, ts[1:]) if b >= a]


def pct(vals: list[float], p: float) -> float | None:
    if not vals:
        return None
    s = sorted(vals)
    i = min(len(s) - 1, max(0, int(round((p / 100.0) * (len(s) - 1)))))
    return s[i]


def phase_kickoff(parsed: dict, marks: dict) -> dict:
    """Split kickoff gaps by idle1 / slow / fast / idle2 using marks_s.

    ftrace timestamps are CLOCK_MONOTONIC, same as time.monotonic() marks.
    slow_start / fast_start / swipe_end are offsets from idle_start.
    """
    kick_ts = parsed.get("kick_ts") or []
    idle_abs = marks.get("idle_start")
    if idle_abs is None or parsed.get("t0") is None:
        return {}

    def summarize_slice(name: str, start_off: float, end_off: float) -> dict:
        lo = idle_abs + start_off
        hi = idle_abs + end_off
        sl = [t for t in kick_ts if lo <= t < hi]
        g = [x * 1000.0 for x in gaps(sl)]
        over50 = [x for x in g if x > 50.0]
        span = max(end_off - start_off, 1e-6)
        return {
            "name": name,
            "n": len(sl),
            "hz": round(len(sl) / span, 1),
            "gap_ms_p50": pct(g, 50),
            "gap_ms_p99": pct(g, 99),
            "gap_ms_max": max(g) if g else None,
            "gaps_gt_50ms": len(over50),
            "big_gaps_ms": sorted((round(x, 2) for x in over50), reverse=True)[:8],
        }

    slow = float(marks.get("slow_start", 1.5))
    fast = float(marks.get("fast_start", slow + 5.0))
    end = float(marks.get("swipe_end", fast + 2.0))
    t1 = parsed.get("t1") or (idle_abs + end + 1.5)
    idle2_end = max(t1 - idle_abs, end)
    return {
        "idle1": summarize_slice("idle1", 0.0, slow),
        "slow": summarize_slice("slow", slow, fast),
        "fast": summarize_slice("fast", fast, end),
        "idle2": summarize_slice("idle2", end, idle2_end),
    }


def parse_trace(path: Path) -> dict:
    counts: Counter[str] = Counter()
    vblank_ts: list[float] = []
    kick_ts: list[float] = []
    flush_ts: list[float] = []
    flush_dsc = 0
    rc_rows = []
    idle_enter = []
    kick_from_idle = []
    bad = []
    t0 = t1 = None
    last_state = None
    with path.open(errors="replace") as fh:
        for line in fh:
            m = LINE_RE.match(line)
            if not m:
                continue
            ts = float(m.group("ts"))
            ev = m.group("ev")
            rest = m.group("rest")
            t0 = ts if t0 is None else t0
            t1 = ts
            counts[ev] += 1
            if ev == "dpu_crtc_vblank_cb":
                vblank_ts.append(ts)
            elif ev == "dpu_enc_kickoff":
                kick_ts.append(ts)
                if last_state == 3:
                    kick_from_idle.append(ts)
            elif ev == "dpu_enc_trigger_flush":
                flush_ts.append(ts)
                fm = FLUSH_RE.search(rest)
                if fm and int(fm.group("bits"), 16) & (1 << 22):
                    flush_dsc += 1
            elif ev == "dpu_enc_rc":
                rm = RC_RE.search(rest)
                if rm:
                    sev = int(rm.group("ev"))
                    st = int(rm.group("st"))
                    phase = rm.group("phase")
                    rc_rows.append((ts, phase, sev, st))
                    if phase == "idle" or sev == 5:
                        idle_enter.append(ts)
                        last_state = 3
                    elif phase == "kickoff" or (sev == 1 and phase != "begin"):
                        last_state = 2
                    elif phase == "begin":
                        last_state = st
            elif ev in (
                "dpu_enc_wait_event_timeout",
                "dpu_enc_frame_done_timeout",
                "dpu_enc_underrun_cb",
            ):
                bad.append({"t": ts, "ev": ev, "rest": rest[:180]})

    def summarize(name: str, ts: list[float]) -> dict:
        g = [x * 1000.0 for x in gaps(ts)]
        over16 = sum(1 for x in g if x > 16.7)
        over33 = sum(1 for x in g if x > 33.4)
        over50 = sum(1 for x in g if x > 50.0)
        return {
            "name": name,
            "n": len(ts),
            "gap_ms_p50": pct(g, 50),
            "gap_ms_p99": pct(g, 99),
            "gap_ms_max": max(g) if g else None,
            "gaps_gt_16ms": over16,
            "gaps_gt_33ms": over33,
            "gaps_gt_50ms": over50,
            "big_gaps_ms": sorted((round(x, 2) for x in g if x > 16.7), reverse=True)[:12],
        }

    rc_count = Counter()
    for _ts, phase, sev, st in rc_rows:
        rc_count[f"{RC_EVENT.get(sev, sev)}/{phase}/state={RC_STATE.get(st, st)}"] += 1

    return {
        "t0": t0,
        "t1": t1,
        "span_s": None if t0 is None or t1 is None else round(t1 - t0, 3),
        "events": dict(counts.most_common()),
        "vblank_cb": summarize("dpu_crtc_vblank_cb", vblank_ts),
        "kickoff": summarize("dpu_enc_kickoff", kick_ts),
        "flush": summarize("dpu_enc_trigger_flush", flush_ts),
        "flush_with_dsc_bit22": flush_dsc,
        "rc": dict(rc_count),
        "enter_idle_n": len(idle_enter),
        "kick_from_idle_n": len(kick_from_idle),
        "timeouts": bad,
        "kick_ts": kick_ts,
    }


def on_device() -> int:
    OUT_DEV.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = OUT_DEV / f"jank-capture-{stamp}"
    dest.mkdir(parents=True, exist_ok=True)

    subprocess.run(["/usr/local/sbin/dagu-venus-load.sh"], check=False)
    venus = {
        "video14": Path("/dev/video14").exists(),
        "video15": Path("/dev/video15").exists(),
    }

    screenshot(dest / "before.png")
    arm_trace()
    samples = []
    t_mark = {"idle_start": time.monotonic()}
    deadline = time.monotonic() + 1.5
    while time.monotonic() < deadline:
        samples.append(
            {
                "t": time.monotonic() - t_mark["idle_start"],
                "phase": "idle1",
                "gpu_busy": read_int("/sys/class/drm/card0/device/gpu_busy_percent"),
                "gpu_hz": read_int("/sys/class/devfreq/3d00000.gpu/cur_freq"),
                "vblank": read_vblank(),
            }
        )
        time.sleep(0.2)

    t_mark["slow_start"] = time.monotonic() - t_mark["idle_start"]
    swipe_profile("slow")
    t_mark["fast_start"] = time.monotonic() - t_mark["idle_start"]
    swipe_profile("fast")
    t_mark["swipe_end"] = time.monotonic() - t_mark["idle_start"]

    deadline = time.monotonic() + 1.5
    while time.monotonic() < deadline:
        samples.append(
            {
                "t": time.monotonic() - t_mark["idle_start"],
                "phase": "idle2",
                "gpu_busy": read_int("/sys/class/drm/card0/device/gpu_busy_percent"),
                "gpu_hz": read_int("/sys/class/devfreq/3d00000.gpu/cur_freq"),
                "vblank": read_vblank(),
            }
        )
        time.sleep(0.2)
    screenshot(dest / "after.png")

    (TR / "tracing_on").write_text("1\n")
    raw = dest / "trace.txt"
    raw.write_bytes((TR / "trace").read_bytes())
    dmesg = subprocess.check_output(["dmesg", "-T"], text=True, errors="replace")
    (dest / "dmesg-dpu.txt").write_text(
        "\n".join(
            ln
            for ln in dmesg.splitlines()
            if re.search(r"vblank timeout|commit done|underrun|underflow|dsc|DSC", ln, re.I)
        )
        + "\n"
    )
    try:
        (dest / "drm-state.txt").write_text(
            Path("/sys/kernel/debug/dri/0/state").read_text(errors="replace")
        )
    except OSError:
        pass

    parsed = parse_trace(raw)
    parsed["stamp"] = stamp
    parsed["venus"] = venus
    parsed["marks_s"] = t_mark
    parsed["samples"] = samples
    parsed["timeout_dmesg"] = dmesg.count("vblank timeout:")
    parsed["native_portrait"] = NATIVE_PORTRAIT
    parsed["phase_kickoff"] = phase_kickoff(parsed, t_mark)
    parsed.pop("kick_ts", None)
    (dest / "summary.json").write_text(json.dumps(parsed, indent=2) + "\n")

    interesting = (
        "dpu_enc_wait_event_timeout",
        "dpu_enc_frame_done_timeout",
        "dpu_enc_underrun_cb",
        "dpu_enc_rc",
        "dpu_enc_vblank_cb",
    )
    with raw.open(errors="replace") as fh, (dest / "trace-interesting.txt").open("w") as out:
        for line in fh:
            if any(name in line for name in interesting):
                out.write(line)

    print(json.dumps({
        "dest": str(dest),
        "span_s": parsed["span_s"],
        "vblank_cb": parsed["vblank_cb"],
        "kickoff": parsed["kickoff"],
        "enter_idle_n": parsed["enter_idle_n"],
        "kick_from_idle_n": parsed["kick_from_idle_n"],
        "timeouts": parsed["timeouts"],
        "timeout_dmesg": parsed["timeout_dmesg"],
        "venus": venus,
        "rc": parsed["rc"],
        "marks_s": t_mark,
        "native_portrait": NATIVE_PORTRAIT,
        "phase_kickoff": parsed.get("phase_kickoff"),
    }, indent=2))
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--host":
        remote = "/usr/local/sbin/dagu-dpu-jank-capture.py"
        swipe = ROOT / "scripts" / "dagu-himax-swipe.py"
        orient = ROOT / "scripts" / "dagu-mutter-orientation.py"
        native = "--native-portrait" in sys.argv
        lab_py = ROOT / "scripts" / "dagu-pipeline-lab.py"
        lab_html = ROOT / "scripts" / "dagu-pipeline-tab.html"
        if lab_py.is_file() and lab_html.is_file():
            subprocess.run(
                [
                    "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    str(lab_py), str(lab_html), f"root@{HOST}:/tmp/",
                ],
                check=False,
            )
            subprocess.run(
                ssh_base() + [
                    "install -m755 /tmp/dagu-pipeline-lab.py /usr/local/sbin/dagu-pipeline-lab.py; "
                    "mkdir -p /usr/local/share/dagu-pipeline-lab; "
                    "install -m644 /tmp/dagu-pipeline-tab.html /usr/local/share/dagu-pipeline-lab/; "
                    "ln -sfn /usr/local/share/dagu-pipeline-lab/dagu-pipeline-tab.html "
                    "/usr/local/share/dagu-pipeline-lab/dagu-pipeline-lab.html; "
                    "pkill -u dagu -f 'chrome|chromium' || true; "
                    "pkill -f '/usr/local/sbin/dagu-pipeline-lab.py' || true; "
                    "python3 /usr/local/sbin/dagu-pipeline-lab.py --serve --once; "
                    "DAGU_LAB_URL=http://127.0.0.1:8770/dagu-pipeline-tab.html "
                    "nohup python3 /usr/local/sbin/dagu-pipeline-lab.py --serve --launch "
                    ">/tmp/dagu-pipeline-lab.log 2>&1 & "
                    "sleep 2"
                ],
                check=False,
            )
            time.sleep(8)
        subprocess.run(
            ssh_base() + [f"cat >{remote} && chmod 755 {remote}"],
            input=Path(__file__).read_bytes(),
            check=True,
        )
        if swipe.is_file():
            subprocess.run(
                ssh_base() + ["cat >/usr/local/sbin/dagu-himax-swipe.py && chmod 755 /usr/local/sbin/dagu-himax-swipe.py"],
                input=swipe.read_bytes(),
                check=True,
            )
        if native and orient.is_file():
            subprocess.run(
                ssh_base() + ["cat >/usr/local/sbin/dagu-mutter-orientation.py && chmod 755 /usr/local/sbin/dagu-mutter-orientation.py"],
                input=orient.read_bytes(),
                check=True,
            )
            subprocess.run(ssh_base() + ["/usr/local/sbin/dagu-mutter-orientation.py", "set-normal"], check=True)
            time.sleep(0.8)
            # Dismiss "Keep these display settings?" (right pill, portrait).
            for xy in ("920 1340", "980 1380", "900 1300"):
                subprocess.run(
                    ssh_base() + ["/usr/local/sbin/dagu-himax-swipe.py", "--tap"] + xy.split(),
                    check=False,
                )
                time.sleep(0.25)
            time.sleep(1.2)
        remote_cmd = [remote]
        if native:
            remote_cmd.append("--native-portrait")
        try:
            proc = subprocess.run(ssh_base() + remote_cmd, check=False)
        finally:
            if native:
                subprocess.run(
                    ssh_base() + ["/usr/local/sbin/dagu-mutter-orientation.py", "set-daily"],
                    check=False,
                )
                time.sleep(0.7)
                # 270° Keep Changes ≈ logical (1450,850) → physical (749,1450)
                for xy in ("749 1450", "760 1480", "740 1420"):
                    subprocess.run(
                        ssh_base() + ["/usr/local/sbin/dagu-himax-swipe.py", "--tap"] + xy.split(),
                        check=False,
                    )
                    time.sleep(0.2)
                time.sleep(1.5)
                subprocess.run(
                    ssh_base() + ["/usr/local/sbin/dagu-mutter-orientation.py", "get"],
                    check=False,
                )
        OUT_HOST.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null", "-r",
                f"root@{HOST}:{OUT_DEV}/jank-capture-*",
                str(OUT_HOST) + "/",
            ],
            check=False,
        )
        return proc.returncode
    if not is_tablet():
        print("not on tablet; use --host", file=sys.stderr)
        return 2
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
