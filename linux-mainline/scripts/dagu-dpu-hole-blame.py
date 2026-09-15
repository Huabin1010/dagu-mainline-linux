#!/usr/bin/env python3
"""Homepage slow-scroll hole attribution. No FUNCTION_TRACER.

From host: python3 linux-mainline/scripts/dagu-dpu-hole-blame.py --host
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from collections import Counter
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
OUT_HOST = ROOT / "out/display-stress"
OUT_DEV = Path("/var/log/dagu-dpu")
TR = Path("/sys/kernel/debug/tracing")
LINE_RE = re.compile(
    r"^\s*(?P<comm>\S+)-(?P<pid>\d+)\s+\[\d+\]\s+\S+\s+(?P<ts>[\d.]+):\s+(?P<ev>\S+):\s*(?P<rest>.*)$"
)


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def read_int(path: str) -> int:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return -1


def read_wchan(pid: int) -> str:
    try:
        return Path(f"/proc/{pid}/wchan").read_text().strip()[:48]
    except OSError:
        return "?"


def find_pids() -> dict[str, int]:
    out = {}
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            comm = (p / "comm").read_text().strip()
            cmd = (p / "cmdline").read_text(errors="replace")
        except OSError:
            continue
        if comm == "gnome-shell" and "pid" not in out:
            out["gnome-shell"] = int(p.name)
        if "type=gpu-process" in cmd and "gpu" not in out:
            out["gpu"] = int(p.name)
        if comm == "VizCompositorTh":
            out["viz"] = int(p.name)
        if comm == "Compositor" and "chromium" in cmd:
            out.setdefault("compositor", int(p.name))
    # Viz is a thread of the GPU process
    gpu = out.get("gpu")
    if gpu:
        tdir = Path(f"/proc/{gpu}/task")
        if tdir.is_dir():
            for t in tdir.iterdir():
                try:
                    c = (t / "comm").read_text().strip()
                except OSError:
                    continue
                if c == "VizCompositorTh":
                    out["viz"] = int(t.name)
                if c == "gdrv0" or c.endswith(":gdrv0"):
                    out["gdrv"] = int(t.name)
    g = out.get("gnome-shell")
    if g:
        tdir = Path(f"/proc/{g}/task")
        if tdir.is_dir():
            for t in tdir.iterdir():
                try:
                    c = (t / "comm").read_text().strip()
                except OSError:
                    continue
                if "gdrv" in c:
                    out["gnome-gdrv"] = int(t.name)
    return out


def arm_trace() -> None:
    (TR / "tracing_on").write_text("0\n")
    (TR / "trace").write_text("")
    (TR / "buffer_size_kb").write_text("16384\n")
    (TR / "events/dpu/enable").write_text("1\n")
    fence = TR / "events/dma_fence"
    if fence.is_dir():
        (fence / "dma_fence_wait_start/enable").write_text("1\n")
        (fence / "dma_fence_wait_end/enable").write_text("1\n")
        (fence / "dma_fence_signaled/enable").write_text("1\n")
    (TR / "tracing_on").write_text("1\n")


def on_device() -> int:
    OUT_DEV.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = OUT_DEV / f"hole-blame-{stamp}"
    dest.mkdir(parents=True, exist_ok=True)
    pids = find_pids()
    samples: list[dict] = []
    stop = threading.Event()
    t0 = time.monotonic()

    def sampler() -> None:
        while not stop.is_set():
            row = {
                "t": time.monotonic() - t0,
                "gpu_busy": read_int("/sys/class/drm/card0/device/gpu_busy_percent"),
                "gpu_hz": read_int("/sys/class/devfreq/3d00000.gpu/cur_freq"),
            }
            for name, pid in pids.items():
                row[f"wchan_{name}"] = read_wchan(pid)
            samples.append(row)
            time.sleep(0.04)

    arm_trace()
    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    swipe = Path("/usr/local/sbin/dagu-himax-swipe.py")
    subprocess.run(
        [sys.executable, str(swipe), "--profile", "slow", "--no-tap"],
        check=False,
    )
    stop.set()
    th.join(timeout=1)
    (TR / "tracing_on").write_text("0\n")
    raw = dest / "trace.txt"
    raw.write_bytes((TR / "trace").read_bytes())

    kick: list[float] = []
    vblank: list[float] = []
    flip: list[float] = []
    fences: list[tuple[float, str, str, str]] = []
    waits: list[tuple[float, str, str]] = []  # ts, phase, driver
    drv_re = re.compile(r"driver=(\S+)\s+timeline=(\S+)")
    with raw.open(errors="replace") as fh:
        for line in fh:
            m = LINE_RE.match(line)
            if not m:
                continue
            ts = float(m.group("ts"))
            ev = m.group("ev")
            rest = m.group("rest")
            if ev == "dpu_enc_kickoff":
                kick.append(ts)
            elif ev == "dpu_crtc_vblank_cb":
                vblank.append(ts)
            elif ev == "dpu_crtc_complete_flip":
                flip.append(ts)
            elif ev.startswith("dma_fence"):
                fences.append((ts, m.group("comm"), ev, rest[:160]))
                dm = drv_re.search(rest)
                drv = f"{dm.group(1)}/{dm.group(2)}" if dm else "?"
                if ev == "dma_fence_wait_start":
                    waits.append((ts, "start", drv))
                elif ev == "dma_fence_wait_end":
                    waits.append((ts, "end", drv))

    holes = []
    for a, b in zip(kick, kick[1:]):
        gap = (b - a) * 1000.0
        if gap <= 50:
            continue
        mid = (a + b) / 2
        # samples use monotonic; holes use kernel boot time. Compare via
        # relative offset from first kick.
        holes.append({"t0": a, "t1": b, "gap_ms": round(gap, 2)})

    if kick:
        k0 = kick[0]
        for h in holes:
            rel0 = h["t0"] - k0
            rel1 = h["t1"] - k0
            near = [s for s in samples if rel0 - 0.02 <= s["t"] - samples[0]["t"] <= rel1 + 0.05]
            # better: map via capture span
            span_k = kick[-1] - k0
            span_s = samples[-1]["t"] - samples[0]["t"] if samples else 1
            s0 = samples[0]["t"] + rel0 * (span_s / span_k) if span_k else 0
            s1 = samples[0]["t"] + rel1 * (span_s / span_k) if span_k else 0
            near = [s for s in samples if s0 - 0.03 <= s["t"] <= s1 + 0.03]
            h["gpu_busy"] = [s["gpu_busy"] for s in near]
            h["wchan_gnome"] = Counter(s.get("wchan_gnome-shell", "?") for s in near)
            h["wchan_gpu"] = Counter(s.get("wchan_gpu", "?") for s in near)
            h["wchan_viz"] = Counter(s.get("wchan_viz", "?") for s in near)
            h["wchan_gdrv"] = Counter(s.get("wchan_gdrv", "?") for s in near)
            h["wchan_gnome_gdrv"] = Counter(s.get("wchan_gnome-gdrv", "?") for s in near)
            fw = [f for f in fences if h["t0"] <= f[0] <= h["t1"]]
            h["fence_n"] = len(fw)
            h["fence_ev"] = Counter(f[2] for f in fw)
            h["fence_comm"] = Counter(f[1] for f in fw)
            h["vblank_n"] = sum(1 for t in vblank if h["t0"] <= t <= h["t1"])
            h["flip_n"] = sum(1 for t in flip if h["t0"] < t <= h["t1"])
            hole_waits = [w for w in waits if h["t0"] <= w[0] <= h["t1"]]
            live = [w for w in hole_waits if "signaled-timeline" not in w[2] and w[2] != "stub/stub"]
            h["wait_drv"] = Counter(w[2] for w in hole_waits)
            h["wait_live_n"] = len(live)
            # pair start/end for stub wait length
            starts = [w[0] for w in hole_waits if w[1] == "start"]
            ends = [w[0] for w in hole_waits if w[1] == "end"]
            durs = [(b - a) * 1000.0 for a, b in zip(starts, ends) if b >= a]
            h["wait_max_ms"] = round(max(durs), 3) if durs else 0
            # kernel stuck = many vblanks, no flip until the closing kickoff
            h["kernel_verdict"] = (
                "userspace-no-commit"
                if h["vblank_n"] >= 4 and h["flip_n"] <= 1 and h["wait_live_n"] == 0
                else "check-live-wait" if h["wait_live_n"] else "short-or-mixed"
            )

    report = {
        "dest": str(dest),
        "pids": pids,
        "kick_n": len(kick),
        "hole_n": len(holes),
        "holes": holes,
        "fence_n": len(fences),
        "samples_n": len(samples),
        "gpu_busy_all": [s["gpu_busy"] for s in samples],
        "wchan_gnome_all": dict(Counter(s.get("wchan_gnome-shell", "?") for s in samples)),
        "wchan_gpu_all": dict(Counter(s.get("wchan_gpu", "?") for s in samples)),
        "wchan_viz_all": dict(Counter(s.get("wchan_viz", "?") for s in samples)),
        "wchan_gdrv_all": dict(Counter(s.get("wchan_gdrv", "?") for s in samples)),
        "wchan_gnome_gdrv_all": dict(Counter(s.get("wchan_gnome-gdrv", "?") for s in samples)),
        "flip_n": len(flip),
        "vblank_n": len(vblank),
    }
    (dest / "blame.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({
        "dest": str(dest),
        "pids": pids,
        "kick_n": len(kick),
        "hole_n": len(holes),
        "holes": [
            {
                "gap_ms": h["gap_ms"],
                "gpu_busy": h.get("gpu_busy"),
                "wchan_gnome": dict(h.get("wchan_gnome", {})),
                "wchan_gpu": dict(h.get("wchan_gpu", {})),
                "wchan_viz": dict(h.get("wchan_viz", {})),
                "wchan_gdrv": dict(h.get("wchan_gdrv", {})),
                "fence_n": h.get("fence_n"),
                "fence_ev": dict(h.get("fence_ev", {})),
                "fence_comm": dict(h.get("fence_comm", {})),
                "vblank_n": h.get("vblank_n"),
                "flip_n": h.get("flip_n"),
                "wait_drv": dict(h.get("wait_drv", {})),
                "wait_live_n": h.get("wait_live_n"),
                "wait_max_ms": h.get("wait_max_ms"),
                "kernel_verdict": h.get("kernel_verdict"),
            }
            for h in holes
        ],
        "flip_n": len(flip),
        "vblank_n": len(vblank),
        "gpu_busy_p50": sorted(report["gpu_busy_all"])[len(report["gpu_busy_all"]) // 2] if samples else None,
        "wchan_gnome_all": report["wchan_gnome_all"],
        "wchan_gpu_all": report["wchan_gpu_all"],
        "wchan_viz_all": report["wchan_viz_all"],
        "wchan_gdrv_all": report["wchan_gdrv_all"],
        "wchan_gnome_gdrv_all": report["wchan_gnome_gdrv_all"],
        "fence_n": len(fences),
    }, indent=2))
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--host":
        remote = "/usr/local/sbin/dagu-dpu-hole-blame.py"
        swipe = ROOT / "scripts" / "dagu-himax-swipe.py"
        subprocess.run(
            ssh_base() + [f"cat >{remote} && chmod 755 {remote}"],
            input=Path(__file__).read_bytes(),
            check=True,
        )
        subprocess.run(
            ssh_base() + ["cat >/usr/local/sbin/dagu-himax-swipe.py && chmod 755 /usr/local/sbin/dagu-himax-swipe.py"],
            input=swipe.read_bytes(),
            check=True,
        )
        proc = subprocess.run(ssh_base() + [remote], check=False)
        OUT_HOST.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null", "-r",
                f"root@{HOST}:{OUT_DEV}/hole-blame-*",
                str(OUT_HOST) + "/",
            ],
            check=False,
        )
        return proc.returncode
    return on_device()


if __name__ == "__main__":
    raise SystemExit(main())
