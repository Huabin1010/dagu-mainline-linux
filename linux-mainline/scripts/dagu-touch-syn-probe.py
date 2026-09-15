#!/usr/bin/env python3
"""Measure Himax SYN_REPORT gaps and IRQ 193 affinity on dagu.

This reads the real evdev node. Do not use dagu-himax-swipe.py here:
injected MT-B is not the IC pulse.

On the tablet (root):
  python3 /usr/local/sbin/dagu-touch-syn-probe.py --wait 20
From the host:
  python3 linux-mainline/scripts/dagu-touch-syn-probe.py --host --wait 20

Hold-drag on the glass while it waits. 120 Hz should sit near 8.3 ms.
16 ms / 24 ms buckets mean a dropped SYN (IC silent, or the IRQ thread
coalesced two frames and only reported the last).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import select
import struct
import sys
import time
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
OUT_HOST = ROOT / "out/display-stress"
EVENT = struct.Struct("llHHi")
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
BTN_TOUCH = 0x14A
ABS_MT_TRACKING_ID = 0x39

HIMAX_IRQ_NAME = "himax-dagu"
BIG_AFFINITY = "f0"  # CPU 4-7
ALL_AFFINITY = "ff"


def is_tablet() -> bool:
    return Path("/sys/class/drm/card0-DSI-1").exists()


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def find_himax() -> str:
    for name in sorted(glob.glob("/sys/class/input/event*/device/name")):
        try:
            text = Path(name).read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if "Himax" in text or "HX83121" in text:
            return "/dev/input/" + Path(name).parts[4]
    return "/dev/input/event3"


def find_irq() -> str | None:
    try:
        lines = Path("/proc/interrupts").read_text(errors="replace").splitlines()
    except OSError:
        return None
    for line in lines:
        if HIMAX_IRQ_NAME in line or "himax" in line.lower():
            num = line.split(":", 1)[0].strip()
            if num.isdigit():
                return num
    return None


def irq_row(irq: str) -> dict:
    out = {
        "irq": irq,
        "cpus": [],
        "affinity": "",
        "effective": "",
        "effective_list": "",
        "node": "",
    }
    try:
        text = Path("/proc/interrupts").read_text(errors="replace")
    except OSError:
        return out
    header = text.splitlines()[0].split()
    ncpu = sum(1 for h in header if h.startswith("CPU"))
    for line in text.splitlines()[1:]:
        if not line.strip().startswith(irq + ":"):
            continue
        parts = line.split()
        # irq: c0 c1 ... device
        counts = []
        for tok in parts[1:1 + ncpu]:
            try:
                counts.append(int(tok))
            except ValueError:
                counts.append(-1)
        out["cpus"] = counts
        out["name"] = " ".join(parts[1 + ncpu:])
        break
    irqdir = Path(f"/proc/irq/{irq}")
    for key, name in (
        ("affinity", "smp_affinity"),
        ("effective", "smp_affinity_effective"),
        ("effective_list", "effective_affinity_list"),
        ("node", "node"),
    ):
        p = irqdir / name
        if p.exists():
            out[key] = p.read_text(errors="replace").strip()
    return out


def spi_pm() -> dict:
    out = {}
    for glob_path in (
        "/sys/bus/spi/devices/spi20.0/power/*",
        "/sys/bus/spi/devices/spi20.0/../../power/*",
        "/sys/devices/platform/spi/power/*",
        "/sys/devices/platform/spi/spi20/power/*",
        "/sys/devices/platform/spi/spi20/spi20.0/power/*",
    ):
        for p in glob.glob(glob_path):
            path = Path(p)
            if not path.is_file():
                continue
            try:
                out[str(path)] = path.read_text(errors="replace").strip()
            except OSError:
                pass
    # Himax is spi-gpio, not I2C. Still record any i2c-gpio power nodes.
    for p in glob.glob("/sys/bus/i2c/devices/i2c-*/device/power/control"):
        try:
            out[p] = Path(p).read_text(errors="replace").strip()
        except OSError:
            pass
    return out


def cpu_freq() -> dict:
    out = {}
    for pol in ("policy0", "policy4", "policy7"):
        base = Path(f"/sys/devices/system/cpu/cpufreq/{pol}")
        row = {}
        for name in (
            "scaling_governor", "scaling_cur_freq",
            "scaling_min_freq", "scaling_max_freq",
        ):
            p = base / name
            if p.exists():
                row[name] = p.read_text(errors="replace").strip()
        out[pol] = row
    return out


def bucket_ms(dt: float) -> str:
    ms = dt * 1000.0
    if ms < 6:
        return "<6"
    if ms < 11:
        return "8.3"
    if ms < 20:
        return "16"
    if ms < 28:
        return "24"
    if ms < 40:
        return "32+"
    return ">40"


def summarize(deltas: list[float]) -> dict:
    if not deltas:
        return {"n": 0}
    xs = sorted(deltas)
    buckets: dict[str, int] = {}
    for d in xs:
        k = bucket_ms(d)
        buckets[k] = buckets.get(k, 0) + 1
    gaps = [d for d in xs if d >= 0.014]
    return {
        "n": len(xs),
        "min_ms": round(xs[0] * 1000, 3),
        "p50_ms": round(xs[len(xs) // 2] * 1000, 3),
        "p95_ms": round(xs[int(len(xs) * 0.95)] * 1000, 3),
        "max_ms": round(xs[-1] * 1000, 3),
        "mean_hz": round((len(xs) / sum(xs)) if sum(xs) else 0, 2),
        "gaps_ge_14ms": len(gaps),
        "gap_pct": round(100.0 * len(gaps) / len(xs), 2),
        "buckets": buckets,
    }


def snapshot() -> dict:
    irq = find_irq()
    dev = find_himax()
    return {
        "t": time.time(),
        "dev": dev,
        "irq": irq_row(irq) if irq else {"irq": None},
        "spi_pm": spi_pm(),
        "cpufreq": cpu_freq(),
        "touch_boost": Path("/usr/local/sbin/dagu-touch-boost.py").exists(),
    }


def capture(dev: str, wait_s: float) -> dict:
    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    syns: list[float] = []
    downs = 0
    contact = False
    deadline = time.monotonic() + wait_s
    try:
        while time.monotonic() < deadline:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            ready, _, _ = select.select([fd], [], [], min(left, 0.25))
            if not ready:
                continue
            raw = os.read(fd, EVENT.size * 64)
            for off in range(0, len(raw) - EVENT.size + 1, EVENT.size):
                sec, usec, typ, code, value = EVENT.unpack_from(raw, off)
                ts = sec + usec / 1e6
                if typ == EV_KEY and code == BTN_TOUCH:
                    contact = value != 0
                    if contact:
                        downs += 1
                elif typ == EV_ABS and code == ABS_MT_TRACKING_ID:
                    contact = value != -1
                    if contact:
                        downs += 1
                elif typ == EV_SYN and code == SYN_REPORT and contact:
                    syns.append(ts)
    finally:
        os.close(fd)
    deltas = [b - a for a, b in zip(syns, syns[1:]) if b > a]
    # Drop the lift/down gap at contact edges (>80 ms is a new stroke).
    hold = [d for d in deltas if d < 0.080]
    return {
        "syn_n": len(syns),
        "contact_edges": downs,
        "deltas": [round(d, 6) for d in hold],
        "summary": summarize(hold),
        "raw_max_ms": round(max(deltas) * 1000, 3) if deltas else None,
    }


def set_affinity(irq: str, mask: str) -> str:
    path = Path(f"/proc/irq/{irq}/smp_affinity")
    path.write_text(mask + "\n")
    return path.read_text().strip()


def run_tablet(args: argparse.Namespace) -> dict:
    before = snapshot()
    irq = before["irq"].get("irq")
    if args.bind_big and irq:
        before["bind"] = set_affinity(str(irq), BIG_AFFINITY)
    elif args.bind_all and irq:
        before["bind"] = set_affinity(str(irq), ALL_AFFINITY)
    cap = capture(before["dev"], args.wait)
    after = snapshot()
    return {
        "before": before,
        "capture": cap,
        "after": after,
    }


def run_host(args: argparse.Namespace) -> None:
    import subprocess

    remote = "/usr/local/sbin/dagu-touch-syn-probe.py"
    here = Path(__file__).resolve()
    subprocess.check_call(
        ssh_base() + [f"install -m 755 /dev/stdin {remote}"],
        stdin=here.open("rb"),
    )
    cmd = [remote, "--wait", str(args.wait), "--json"]
    if args.bind_big:
        cmd.append("--bind-big")
    if args.bind_all:
        cmd.append("--bind-all")
    proc = subprocess.run(
        ssh_base() + cmd, capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    text = proc.stdout.strip().splitlines()[-1]
    data = json.loads(text)
    OUT_HOST.mkdir(parents=True, exist_ok=True)
    out = OUT_HOST / "touch-syn.json"
    out.write_text(json.dumps(data, indent=2) + "\n")
    print(json.dumps(data["capture"]["summary"], indent=2))
    print(f"wrote {out}")
    irq_b = data["before"]["irq"]
    irq_a = data["after"]["irq"]
    print("irq before", irq_b.get("effective_list"), irq_b.get("cpus"))
    print("irq after ", irq_a.get("effective_list"), irq_a.get("cpus"))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", action="store_true")
    ap.add_argument("--wait", type=float, default=20.0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--bind-big", action="store_true",
                    help="echo f0 > smp_affinity (CPU 4-7) before capture")
    ap.add_argument("--bind-all", action="store_true")
    ap.add_argument("--snapshot", action="store_true",
                    help="IRQ/PM/cpufreq only, no evdev wait")
    args = ap.parse_args()
    if args.host:
        run_host(args)
        return
    if not is_tablet() and not Path("/dev/input/event3").exists():
        raise SystemExit("not on tablet; use --host")
    if args.snapshot:
        data = snapshot()
        print(json.dumps(data, indent=2) if args.json else data)
        return
    data = run_tablet(args)
    if args.json:
        print(json.dumps(data, separators=(",", ":")))
    else:
        print(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()
