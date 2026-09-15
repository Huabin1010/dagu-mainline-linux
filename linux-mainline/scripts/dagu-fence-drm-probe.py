#!/usr/bin/env python3
"""8s dma-fence + DRM/DPU ftrace around dpu_enc_kickoff holes.

No uprobe, no poke. Kernel has no drm_atomic_commit; use msm_atomic_commit_tail_*.
From host: python3 linux-mainline/scripts/dagu-fence-drm-probe.py --host
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
TR = Path("/sys/kernel/debug/tracing")

EVENTS = [
    "dma_fence/dma_fence_wait_start",
    "dma_fence/dma_fence_wait_end",
    "dma_fence/dma_fence_signaled",
    "drm/drm_vblank_event",
    "drm/drm_vblank_event_delivered",
    "dpu/dpu_enc_kickoff",
    "dpu/dpu_crtc_vblank_cb",
    "dpu/dpu_crtc_complete_flip",
    "dpu/dpu_enc_frame_done_cb",
    "dpu/dpu_enc_prepare_kickoff",
    "drm_msm_atomic/msm_atomic_commit_tail_start",
    "drm_msm_atomic/msm_atomic_commit_tail_finish",
    "drm_msm_atomic/msm_atomic_wait_flush_start",
    "drm_msm_atomic/msm_atomic_wait_flush_finish",
]

KEEP_ON = {"dpu/dpu_enc_kickoff", "dpu/dpu_crtc_vblank_cb"}


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def parse_ts(line: str) -> float | None:
    for part in line.split():
        if part.endswith(":") and part[:-1].replace(".", "", 1).isdigit():
            return float(part[:-1])
    return None


def parse_comm_pid(line: str) -> tuple[str, int | None]:
    head = line.split(" [", 1)[0].strip()
    if "-" not in head:
        return head, None
    name, pid_s = head.rsplit("-", 1)
    try:
        return name.strip(), int(pid_s)
    except ValueError:
        return head, None


FENCE_RE = re.compile(
    r"driver=(\S+)\s+timeline=(\S+)\s+context=(\d+)\s+seqno=(\d+)"
)


def parse_fence(line: str) -> dict | None:
    m = FENCE_RE.search(line)
    if not m:
        return None
    return {
        "driver": m.group(1),
        "timeline": m.group(2),
        "context": int(m.group(3)),
        "seqno": int(m.group(4)),
    }


def ev_name(line: str) -> str:
    for tok in line.split():
        if tok.endswith(":") and "_" in tok and not tok[0].isdigit():
            return tok[:-1]
    return "?"


def set_ev(rel: str, on: bool) -> None:
    p = TR / "events" / rel / "enable"
    if p.is_file():
        p.write_text("1\n" if on else "0\n")


def install() -> list[str]:
    (TR / "tracing_on").write_text("0\n")
    en = TR / "events/uprobes/enable"
    if en.is_file():
        en.write_text("0\n")
    try:
        (TR / "uprobe_events").write_text("")
    except OSError:
        pass
    for rel in EVENTS:
        set_ev(rel, False)
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("65536\n")
    ok = []
    for rel in EVENTS:
        p = TR / "events" / rel / "enable"
        if not p.is_file():
            continue
        p.write_text("1\n")
        ok.append(rel)
    return ok


def restore() -> None:
    for rel in EVENTS:
        if rel in KEEP_ON:
            continue
        set_ev(rel, False)
    for rel in KEEP_ON:
        set_ev(rel, True)
    (TR / "tracing_on").write_text("1\n")


def summary(xs: list[float]) -> dict:
    gaps = [1000.0 * (b - a) for a, b in zip(xs, xs[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (xs[-1] - xs[0]) if len(xs) > 1 else 0
    return {
        "n": len(xs),
        "hz": round(len(xs) / span, 2) if span else 0,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:8]],
    }


def on_device(seconds: float = 8.0) -> int:
    ok = install()
    kick: list[float] = []
    vbl: list[float] = []
    flip: list[float] = []
    delivered: list[float] = []
    waits: list[dict] = []
    pending: dict[tuple, float] = {}
    signaled_n = 0
    wait_start_n = 0
    wait_end_n = 0
    tails: list[dict] = []
    flushes: list[dict] = []
    prep: list[float] = []
    framedone: list[float] = []
    drop_signaled_sample = 0
    (TR / "tracing_on").write_text("1\n")
    pipe = open(TR / "trace_pipe", "r", buffering=1)
    t_end = time.clock_gettime(time.CLOCK_MONOTONIC) + seconds
    try:
        os.set_blocking(pipe.fileno(), False)
        buf = ""
        while time.clock_gettime(time.CLOCK_MONOTONIC) < t_end:
            try:
                chunk = pipe.read(131072)
            except BlockingIOError:
                chunk = ""
            if not chunk:
                time.sleep(0.0002)
                continue
            buf += chunk
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                ts = parse_ts(line)
                if ts is None:
                    continue
                comm, pid = parse_comm_pid(line)
                if "dpu_enc_kickoff:" in line:
                    kick.append(ts)
                    continue
                if "dpu_crtc_vblank_cb:" in line:
                    vbl.append(ts)
                    continue
                if "dpu_crtc_complete_flip:" in line:
                    flip.append(ts)
                    continue
                if "drm_vblank_event_delivered:" in line:
                    delivered.append(ts)
                    continue
                if "dpu_enc_prepare_kickoff:" in line:
                    prep.append(ts)
                    continue
                if "dpu_enc_frame_done_cb:" in line:
                    framedone.append(ts)
                    continue
                if "msm_atomic_commit_tail_start:" in line:
                    tails.append({"t": ts, "kind": "start", "comm": comm})
                    continue
                if "msm_atomic_commit_tail_finish:" in line:
                    tails.append({"t": ts, "kind": "finish", "comm": comm})
                    continue
                if "msm_atomic_wait_flush_start:" in line:
                    flushes.append({"t": ts, "kind": "start", "comm": comm})
                    continue
                if "msm_atomic_wait_flush_finish:" in line:
                    flushes.append({"t": ts, "kind": "finish", "comm": comm})
                    continue
                if "dma_fence_wait_start:" in line:
                    wait_start_n += 1
                    f = parse_fence(line)
                    if not f:
                        continue
                    key = (f["driver"], f["timeline"], f["context"], f["seqno"])
                    pending[key] = ts
                    waits.append({
                        "kind": "start",
                        "t": ts,
                        "comm": comm,
                        "pid": pid,
                        **f,
                    })
                    continue
                if "dma_fence_wait_end:" in line:
                    wait_end_n += 1
                    f = parse_fence(line)
                    if not f:
                        continue
                    key = (f["driver"], f["timeline"], f["context"], f["seqno"])
                    t0 = pending.pop(key, None)
                    rec = {
                        "kind": "end",
                        "t": ts,
                        "comm": comm,
                        "pid": pid,
                        "wait_ms": round((ts - t0) * 1000.0, 3) if t0 is not None else None,
                        **f,
                    }
                    waits.append(rec)
                    continue
                if "dma_fence_signaled:" in line:
                    signaled_n += 1
                    if drop_signaled_sample < 8 or signaled_n % 200 == 0:
                        f = parse_fence(line) or {}
                        waits.append({
                            "kind": "signaled",
                            "t": ts,
                            "comm": comm,
                            "pid": pid,
                            **f,
                        })
                        drop_signaled_sample += 1
                    continue
    finally:
        pipe.close()
    (TR / "tracing_on").write_text("0\n")
    restore()

    long_waits = [
        w for w in waits
        if w.get("kind") == "end" and w.get("wait_ms") is not None and w["wait_ms"] >= 8
    ]
    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        def rels(xs):
            return [round((x - a) * 1000.0, 2) for x in xs if a - 0.002 <= x <= b + 0.002]

        hole_waits = [
            w for w in waits
            if a - 0.002 <= w["t"] <= b + 0.002
        ]
        hole_long = [
            {
                "wait_ms": w["wait_ms"],
                "rel_end_ms": round((w["t"] - a) * 1000.0, 2),
                "comm": w.get("comm"),
                "driver": w.get("driver"),
                "timeline": w.get("timeline"),
                "context": w.get("context"),
                "seqno": w.get("seqno"),
            }
            for w in hole_waits
            if w.get("kind") == "end" and w.get("wait_ms") is not None and w["wait_ms"] >= 8
        ]
        starts = [w for w in hole_waits if w.get("kind") == "start"]
        holes.append({
            "gap_ms": round(gap, 1),
            "t0": round(a, 6),
            "flip": rels(flip)[:4],
            "vbl_n": len(rels(vbl)),
            "delivered": rels(delivered)[:4],
            "prep": rels(prep)[:4],
            "framedone": rels(framedone)[:4],
            "tail": [
                {"kind": t["kind"], "rel_ms": round((t["t"] - a) * 1000.0, 2), "comm": t["comm"]}
                for t in tails if a - 0.002 <= t["t"] <= b + 0.002
            ][:6],
            "flush": [
                {"kind": t["kind"], "rel_ms": round((t["t"] - a) * 1000.0, 2), "comm": t["comm"]}
                for t in flushes if a - 0.002 <= t["t"] <= b + 0.002
            ][:6],
            "n_wait_start": len(starts),
            "n_wait_end": sum(1 for w in hole_waits if w.get("kind") == "end"),
            "n_signaled_kept": sum(1 for w in hole_waits if w.get("kind") == "signaled"),
            "wait_comms": dict(Counter(w.get("comm") for w in starts)),
            "wait_timelines": dict(Counter(w.get("timeline") for w in starts)),
            "first_wait_ms": round((starts[0]["t"] - a) * 1000.0, 2) if starts else None,
            "long_waits": hole_long[:8],
        })

    out = {
        "kind": "fence-drm-dpu",
        "seconds": seconds,
        "events": ok,
        "kick": summary(kick),
        "vblank": summary(vbl),
        "flip": summary(flip),
        "n_wait_start": wait_start_n,
        "n_wait_end": wait_end_n,
        "n_signaled": signaled_n,
        "n_long_wait_ge8": len(long_waits),
        "long_wait_timelines": dict(Counter(
            f"{w.get('driver')}/{w.get('timeline')}" for w in long_waits
        )),
        "long_wait_comms": dict(Counter(w.get("comm") for w in long_waits)),
        "long_wait_max": sorted(long_waits, key=lambda w: -(w.get("wait_ms") or 0))[:8],
        "holes_ncover_wait": sum(1 for h in holes if h["n_wait_start"] > 0),
        "holes_ncover_long": sum(1 for h in holes if h["long_waits"]),
        "holes": holes[:10],
    }
    Path("/tmp/dagu-fence-drm.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


def host_main() -> int:
    extra = [a for a in sys.argv[1:] if a != "--host"]
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    subprocess.run(scp + [str(here), f"root@{HOST}:/tmp/dagu-fence-drm-probe.py"], check=True)
    r = subprocess.run(ssh + ["python3 /tmp/dagu-fence-drm-probe.py"] + extra, check=False)
    dest_dir = ROOT / "out" / "display-stress"
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = dest_dir / f"dagu-fence-drm-{stamp}.json"
    restore_cmd = (
        "python3 - <<'PY'\n"
        "from pathlib import Path\n"
        "tr=Path('/sys/kernel/debug/tracing')\n"
        "keep={'dpu/dpu_enc_kickoff','dpu/dpu_crtc_vblank_cb'}\n"
        "for rel in '''dma_fence/dma_fence_wait_start dma_fence/dma_fence_wait_end "
        "dma_fence/dma_fence_signaled drm/drm_vblank_event drm/drm_vblank_event_delivered "
        "dpu/dpu_crtc_complete_flip dpu/dpu_enc_frame_done_cb dpu/dpu_enc_prepare_kickoff "
        "drm_msm_atomic/msm_atomic_commit_tail_start drm_msm_atomic/msm_atomic_commit_tail_finish "
        "drm_msm_atomic/msm_atomic_wait_flush_start drm_msm_atomic/msm_atomic_wait_flush_finish'''.split():\n"
        "    p=tr/'events'/rel/'enable'\n"
        "    if p.is_file() and rel not in keep: p.write_text('0\\n')\n"
        "(tr/'events/dpu/dpu_enc_kickoff/enable').write_text('1\\n')\n"
        "(tr/'tracing_on').write_text('1\\n')\n"
        "print('tracing', (tr/'tracing_on').read_text().strip(), 'kick', (tr/'events/dpu/dpu_enc_kickoff/enable').read_text().strip())\n"
        "PY"
    )
    if r.returncode != 0:
        print(f"device probe failed rc={r.returncode}")
        subprocess.run(ssh + [restore_cmd], check=False)
        return r.returncode
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-fence-drm.json", str(dest)], check=False)
    if dest.is_file():
        print(dest.read_text()[:12000])
        print(f"saved {dest}")
    subprocess.run(ssh + [restore_cmd], check=False)
    return r.returncode


def main() -> int:
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
