#!/usr/bin/env python3
"""Type B hole: flip on time, next_frame NULL, after_update may delay wl_surface.frame.

On tablet: python3 /usr/local/sbin/dagu-typeb-probe.py
From host: python3 linux-mainline/scripts/dagu-typeb-probe.py --host
"""
from __future__ import annotations

import collections
import json
import os
import struct
import subprocess
import sys
import time
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
TR = Path("/sys/kernel/debug/tracing")
SO = "/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0"
CLOCK = 0x55A5880720
ONS = 0x55A1E9DB90
STATE_NAMES = (
    "init", "idle", "scheduled", "scheduled-now", "scheduled-later",
    "dispatched-one", "dispatched-one-and-scheduled",
    "dispatched-one-and-scheduled-now", "dispatched-one-and-scheduled-later",
    "dispatched-two",
)

# Live so (md5 49a6422fcc5f11ba4894fa6dd82116b1), objdump-checked.
PROBES = {
    "dagu_ff_idle": "0x1dcfa4",      # finish_frame set_result IDLE
    "dagu_ff_pend": "0x1dd054",      # finish_frame set_result PENDING
    "dagu_ff_asgn": "0x1dd064",      # posted && next==NULL assign_next
    "dagu_swap": "0x1c4bb4",         # swap_buffers set_result PENDING
    "dagu_mpost": "0x1c1b20",        # maybe_post_next_frame
    "dagu_nview": "0x1c4440",        # notify_view_crtc_presented
    "dagu_emit": "0x1696b8",         # after_update emit_frame_callbacks now
    "dagu_delay": "0x16969c",        # after_update set_ready_time(deadline)
    "dagu_skipcb": "0x169698",       # after_update ready_time!=-1, no emit
}


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


class Mem:
    def __init__(self, pid: int):
        self.f = open(f"/proc/{pid}/mem", "rb", buffering=0)

    def u64(self, a: int) -> int:
        self.f.seek(a)
        b = self.f.read(8)
        return struct.unpack("<Q", b)[0] if len(b) == 8 else 0

    def u32(self, a: int) -> int:
        self.f.seek(a)
        b = self.f.read(4)
        return struct.unpack("<I", b)[0] if len(b) == 4 else 0


def parse_trace(raw: str) -> dict:
    kick, flip = [], []
    ev = collections.defaultdict(list)
    for line in raw.splitlines():
        if line[:1] == "#":
            continue
        ts = None
        for tok in line.split():
            if tok.endswith(":") and tok[:-1].replace(".", "", 1).isdigit():
                ts = float(tok[:-1])
                break
        if ts is None:
            continue
        if "dpu_enc_kickoff:" in line:
            kick.append(ts)
        elif "dpu_crtc_complete_flip:" in line:
            flip.append(ts)
        for name in PROBES:
            if f"{name}:" in line:
                ev[name].append(ts)
    return {"kick": kick, "flip": flip, "ev": dict(ev)}


def gap_sum(ts: list[float]) -> dict:
    gaps = [1000.0 * (b - a) for a, b in zip(ts, ts[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (ts[-1] - ts[0]) if len(ts) > 1 else 0
    return {
        "n": len(ts),
        "hz": round(len(ts) / span, 2) if span > 0 else 0,
        "p50": round(sorted(gaps)[len(gaps) // 2], 2) if gaps else None,
        "max": round(max(gaps), 1) if gaps else None,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
    }


def near(ts: list[float], a: float, b: float) -> int:
    return sum(1 for t in ts if a <= t <= b)


def on_device(seconds: float = 8.0) -> int:
    pid = None
    native = None
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            cmd = (p / "cmdline").read_bytes()
        except OSError:
            continue
        if cmd.startswith(b"/usr/bin/gnome-shell"):
            pid = int(p.name)
        elif b"dagu-native-lab.py" in cmd and b"--host" not in cmd:
            native = int(p.name)
    if pid is None or native is None:
        print(json.dumps({"err": "need gnome-shell + native-lab", "pid": pid, "native": native}))
        return 2

    sm = Mem(pid)
    # verify after_update opcode; uprobes must hit the live inode
    base = None
    mf = None
    for line in open(f"/proc/{pid}/maps"):
        if "libmutter-18.so.0.0.0" in line and "r-xp" in line and "mutter-18/" not in line:
            rng = line.split()[0]
            base = int(rng.split("-", 1)[0], 16)
            mf = f"/proc/{pid}/map_files/{rng}"
            break
    insn_after = hex(sm.u32(base + 0x169668)) if base else None
    insn_fence = hex(sm.u32(base + 0x1bd9ac)) if base else None
    so_path = mf if mf and Path(mf).exists() else SO

    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    ue = TR / "uprobe_events"
    for name in list(PROBES):
        try:
            with ue.open("a") as f:
                f.write(f"-:{name}\n")
        except OSError:
            pass
    installed = []
    for name, off in PROBES.items():
        try:
            with ue.open("a") as f:
                f.write(f"p:{name} {so_path}:{off}\n")
            installed.append(name)
        except OSError as e:
            installed.append(f"{name}:FAIL:{e}")
    (TR / "events/uprobes/enable").write_text("1\n")
    (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
    flip_ev = TR / "events/dpu/dpu_crtc_complete_flip/enable"
    if flip_ev.parent.is_dir():
        flip_ev.write_text("1\n")
    (TR / "tracing_on").write_text("1\n")

    hist = collections.Counter()
    hole_snap = []
    t0 = time.monotonic()
    last_st = last_posted = last_next = None
    while time.monotonic() - t0 < seconds:
        st = sm.u32(CLOCK + 88)
        pr = sm.u32(CLOCK + 396)
        posted = sm.u64(ONS + 72)
        nxt = sm.u64(ONS + 88)
        hist[(
            STATE_NAMES[st] if 0 <= st < len(STATE_NAMES) else str(st),
            int(bool(posted)),
            int(bool(nxt)),
            pr,
        )] += 1
        last_st, last_posted, last_next = st, posted, nxt
        time.sleep(0.003)

    (TR / "tracing_on").write_text("0\n")
    (TR / "events/uprobes/enable").write_text("0\n")
    raw = (TR / "trace").read_text(errors="replace")
    for name in PROBES:
        try:
            with (TR / "uprobe_events").open("a") as f:
                f.write(f"-:{name}\n")
        except OSError:
            pass

    tr = parse_trace(raw)
    kick, flip, ev = tr["kick"], tr["flip"], tr["ev"]
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        holes.append({
            "gap_ms": round(gap, 1),
            "flip": near(flip, a, b),
            "mpost": near(ev.get("dagu_mpost", []), a, b),
            "nview": near(ev.get("dagu_nview", []), a, b),
            "swap": near(ev.get("dagu_swap", []), a, b),
            "ff_idle": near(ev.get("dagu_ff_idle", []), a, b),
            "ff_pend": near(ev.get("dagu_ff_pend", []), a, b),
            "ff_asgn": near(ev.get("dagu_ff_asgn", []), a, b),
            "emit": near(ev.get("dagu_emit", []), a, b),
            "delay": near(ev.get("dagu_delay", []), a, b),
            "skipcb": near(ev.get("dagu_skipcb", []), a, b),
        })

    out = {
        "kind": "typeb-probe",
        "seconds": seconds,
        "pid": pid,
        "native": native,
        "insn_after_update": insn_after,
        "insn_fence": insn_fence,
        "uprobes": installed,
        "kickoff": gap_sum(kick),
        "flip": gap_sum(flip),
        "counts": {k: len(v) for k, v in ev.items()},
        "clock_posted_next": [[list(k), n] for k, n in hist.most_common(12)],
        "holes": holes,
        "last": {
            "st": last_st,
            "posted": bool(last_posted),
            "next": bool(last_next),
        },
    }
    Path("/tmp/dagu-typeb-probe.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-typeb-probe.py"], check=True)
    subprocess.run(ssh + [
        "install -m755 /tmp/dagu-typeb-probe.py /usr/local/sbin/dagu-typeb-probe.py"
    ], check=True)
    r = subprocess.run(ssh + ["python3 /usr/local/sbin/dagu-typeb-probe.py"], check=False)
    out_host = ROOT / "out" / "display-stress"
    out_host.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = out_host / f"dagu-typeb-probe-{stamp}.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-typeb-probe.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text())
        print(f"saved {dest}")
    return r.returncode


def main() -> int:
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        return host_main()
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
