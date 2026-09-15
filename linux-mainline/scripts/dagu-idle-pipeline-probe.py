#!/usr/bin/env python3
"""A/B idle pipeline: schedutil vs CPU performance. GPU has no performance gov.

Do not leave governors pinned. Do not toggle Chrome GPU vs CPU raster.

On tablet: python3 /usr/local/sbin/dagu-idle-pipeline-probe.py
From host:  python3 linux-mainline/scripts/dagu-idle-pipeline-probe.py --host
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
OUT_HOST = ROOT / "out/display-stress"
GPU = Path("/sys/class/devfreq/3d00000.gpu")
POLICIES = (
    Path("/sys/devices/system/cpu/cpufreq/policy0"),
    Path("/sys/devices/system/cpu/cpufreq/policy4"),
    Path("/sys/devices/system/cpu/cpufreq/policy7"),
)


def is_tablet() -> bool:
    return Path("/sys/class/drm/card0-DSI-1").exists()


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace").strip()
    except OSError:
        return ""


def write_text(path: Path, value: str) -> str:
    try:
        path.write_text(value + "\n")
        return read_text(path)
    except OSError as exc:
        return f"ERR:{exc}"


def read_vblank() -> dict:
    text = read_text(Path("/sys/kernel/debug/dri/0/crtc-0/status"))
    out = {"fps": None, "count": None, "raw": text[:200]}
    for line in text.splitlines():
        if "vblank" not in line:
            continue
        for tok in line.split():
            if tok.startswith("fps:"):
                try:
                    out["fps"] = float(tok.split(":", 1)[1])
                except ValueError:
                    pass
            if tok.startswith("count:"):
                try:
                    out["count"] = int(tok.split(":", 1)[1])
                except ValueError:
                    pass
    return out


def power_snap() -> dict:
    gpu = {}
    for name in (
        "governor", "min_freq", "max_freq", "cur_freq",
        "available_governors", "available_frequencies",
    ):
        gpu[name] = read_text(GPU / name)
    cpus = {}
    for pol in POLICIES:
        cpus[pol.name] = {
            "governor": read_text(pol / "scaling_governor"),
            "cur": read_text(pol / "scaling_cur_freq"),
            "min": read_text(pol / "scaling_min_freq"),
            "max": read_text(pol / "scaling_max_freq"),
        }
    return {
        "gpu": gpu,
        "cpu": cpus,
        "busy": read_text(Path("/sys/class/drm/card0/device/gpu_busy_percent")),
        "vblank": read_vblank(),
    }


def dmesg_hits() -> list[str]:
    try:
        raw = subprocess.check_output(
            ["dmesg"], text=True, stderr=subprocess.DEVNULL
        )
    except (OSError, subprocess.CalledProcessError):
        return []
    keys = ("vblank timeout", "underflow", "underrun", "wait for commit done",
            "hangcheck")
    return [ln for ln in raw.splitlines() if any(k in ln.lower() for k in keys)]


def sample(sec: float) -> dict:
    t0 = time.monotonic()
    v0 = read_vblank()
    freqs: list[int] = []
    busy: list[int] = []
    p0: list[int] = []
    p4: list[int] = []
    p7: list[int] = []
    while time.monotonic() - t0 < sec:
        try:
            freqs.append(int(read_text(GPU / "cur_freq") or "-1"))
        except ValueError:
            freqs.append(-1)
        try:
            busy.append(int(read_text(Path("/sys/class/drm/card0/device/gpu_busy_percent")) or "-1"))
        except ValueError:
            busy.append(-1)
        try:
            p0.append(int(read_text(POLICIES[0] / "scaling_cur_freq") or "-1"))
        except ValueError:
            p0.append(-1)
        try:
            p4.append(int(read_text(POLICIES[1] / "scaling_cur_freq") or "-1"))
        except ValueError:
            p4.append(-1)
        try:
            p7.append(int(read_text(POLICIES[2] / "scaling_cur_freq") or "-1"))
        except ValueError:
            p7.append(-1)
        time.sleep(0.02)
    dt = time.monotonic() - t0
    v1 = read_vblank()
    c0, c1 = v0.get("count"), v1.get("count")
    vhz = None
    if isinstance(c0, int) and isinstance(c1, int) and c1 >= c0 and dt > 0:
        vhz = round((c1 - c0) / dt, 2)
    gf = [x for x in freqs if x > 0]
    return {
        "sec": round(dt, 3),
        "gpu_freq_min": min(gf) if gf else None,
        "gpu_freq_max": max(gf) if gf else None,
        "gpu_freq_set": sorted(set(gf)),
        "busy_avg": round(sum(x for x in busy if x >= 0) / max(1, sum(1 for x in busy if x >= 0)), 1),
        "busy_max": max((x for x in busy if x >= 0), default=None),
        "cpu0_min": min((x for x in p0 if x > 0), default=None),
        "cpu0_max": max((x for x in p0 if x > 0), default=None),
        "cpu4_min": min((x for x in p4 if x > 0), default=None),
        "cpu4_max": max((x for x in p4 if x > 0), default=None),
        "cpu7_min": min((x for x in p7 if x > 0), default=None),
        "cpu7_max": max((x for x in p7 if x > 0), default=None),
        "drm_vblank_hz": vhz,
        "vblank_delta": (c1 - c0) if isinstance(c0, int) and isinstance(c1, int) else None,
        "vblank_fps_sysfs": v1.get("fps"),
    }


def try_gpu_performance() -> dict:
    before = read_text(GPU / "governor")
    after = write_text(GPU / "governor", "performance")
    return {
        "available": read_text(GPU / "available_governors"),
        "before": before,
        "after": after,
        "accepted": after == "performance",
    }


def set_cpu(gov: str) -> dict:
    out = {}
    for pol in POLICIES:
        out[pol.name] = write_text(pol / "scaling_governor", gov)
    return out


def chrome_cmd() -> str:
    try:
        return subprocess.check_output(
            ["pgrep", "-a", "-u", "dagu", "-f", "chromium|chrome"],
            text=True, stderr=subprocess.DEVNULL,
        )[:800]
    except subprocess.CalledProcessError:
        return ""


def run_tablet() -> dict:
    saved_cpu = {pol.name: read_text(pol / "scaling_governor") for pol in POLICIES}
    saved_gpu = read_text(GPU / "governor")
    saved_gmin = read_text(GPU / "min_freq")
    hits0 = dmesg_hits()
    gpu_try = try_gpu_performance()
    base = {
        "power": power_snap(),
        "chrome": chrome_cmd(),
        "dmesg_hits_before": hits0[-12:],
        "gpu_performance_try": gpu_try,
    }
    idle = sample(8.0)
    cpu_lock = set_cpu("performance")
    locked_power = power_snap()
    locked = sample(8.0)
    hits1 = dmesg_hits()
    restored = {
        "cpu": set_cpu(saved_cpu.get("policy0") or "schedutil"),
        "gpu": write_text(GPU / "governor", saved_gpu or "simple_ondemand"),
        "gpu_min": write_text(GPU / "min_freq", saved_gmin or "587000000"),
    }
    new_hits = hits1[len(hits0):]
    return {
        "saved": {"cpu": saved_cpu, "gpu": saved_gpu, "gpu_min": saved_gmin},
        "before": base,
        "idle_current": idle,
        "cpu_lock": cpu_lock,
        "locked_power": locked_power,
        "idle_performance": locked,
        "dmesg_new_during_ab": new_hits,
        "dmesg_hits_after": hits1[-12:],
        "restored": restored,
        "note": (
            "Adreno 650 max OPP is 670 MHz. GPU sysfs has no performance "
            "governor. vblank timeout 0x400000 is CTL_FLUSH BIT(22)=SSPP_CURSOR0."
        ),
    }


def main() -> None:
    if "--host" in sys.argv or not is_tablet():
        here = Path(__file__).resolve()
        remote = "/usr/local/sbin/dagu-idle-pipeline-probe.py"
        subprocess.check_call(
            ssh_base() + [f"install -m 755 /dev/stdin {remote}"],
            stdin=here.open("rb"),
        )
        proc = subprocess.run(
            ssh_base() + [remote], capture_output=True, text=True, check=False,
        )
        if proc.returncode != 0:
            sys.stderr.write(proc.stderr)
            raise SystemExit(proc.returncode)
        data = json.loads(proc.stdout.strip().splitlines()[-1])
        OUT_HOST.mkdir(parents=True, exist_ok=True)
        out = OUT_HOST / "idle-pipeline.json"
        out.write_text(json.dumps(data, indent=2) + "\n")
        print(json.dumps({
            "gpu_try": data["before"]["gpu_performance_try"],
            "idle_current": data["idle_current"],
            "idle_performance": data["idle_performance"],
            "dmesg_new": data["dmesg_new_during_ab"],
            "dmesg_tail": data["dmesg_hits_after"],
        }, indent=2))
        print(f"wrote {out}")
        return
    print(json.dumps(run_tablet(), separators=(",", ":")))


if __name__ == "__main__":
    main()
