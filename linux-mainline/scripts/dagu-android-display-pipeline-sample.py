#!/usr/bin/env python3
"""Switch the extract tablet to 120 Hz, run an on-device kickoff sample, restore."""
from __future__ import annotations

import argparse
import subprocess
import time
from pathlib import Path


def adb(serial: str, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["adb", "-s", serial, *args],
        check=check,
        text=True,
        capture_output=True,
    )


def su(serial: str, cmd: str, check: bool = True) -> str:
    r = adb(serial, "shell", "su", "-c", cmd, check=check)
    return r.stdout


def settings_get(serial: str, ns: str, key: str) -> str:
    r = adb(serial, "shell", "settings", "get", ns, key, check=False)
    return (r.stdout or "").strip()


def settings_put(serial: str, ns: str, key: str, value: str | None) -> None:
    if value in ("", "null", "None"):
        adb(serial, "shell", "settings", "delete", ns, key, check=False)
        return
    adb(serial, "shell", "settings", "put", ns, key, value, check=False)


def parse_kickoff(text: str) -> int | None:
    for line in text.splitlines():
        if line.startswith("panel_kickoff_count="):
            return int(line.split("=", 1)[1])
    return None


def parse_uptime_s(token: str) -> float | None:
    # /proc/uptime first field, may be glued to VSYNC=...
    try:
        return float(token.split()[0])
    except (IndexError, ValueError):
        return None


def summarize_unique(ns_values: list[int], name: str) -> str:
    if len(ns_values) < 2:
        return f"{name}: n={len(ns_values)}"
    gaps = [(b - a) / 1e6 for a, b in zip(ns_values, ns_values[1:]) if b > a]
    if not gaps:
        return f"{name}: n={len(ns_values)} no positive gaps"
    gaps.sort()
    span_s = (ns_values[-1] - ns_values[0]) / 1e9
    hz = (len(ns_values) - 1) / span_s if span_s > 0 else 0.0
    gt16 = sum(1 for g in gaps if g > 16.7)
    gt50 = sum(1 for g in gaps if g > 50)
    return (
        f"{name}_n={len(ns_values)} hz={hz:.2f} p50={gaps[len(gaps)//2]:.3f}ms "
        f"max={gaps[-1]:.3f}ms gt16.7={gt16} gt50={gt50}"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--script-dir", required=True)
    args = ap.parse_args()
    serial = args.serial
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    script_dir = Path(args.script_dir)

    old = {
        "miui": settings_get(serial, "secure", "miui_refresh_rate"),
        "peak": settings_get(serial, "system", "peak_refresh_rate"),
        "minr": settings_get(serial, "system", "min_refresh_rate"),
    }
    (out / "settings-before.txt").write_text(repr(old) + "\n", encoding="utf-8")

    remote_sample = "/data/local/tmp/dagu-android-display-pipeline-ondevice-sample.sh"
    try:
        adb(serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP", check=False)
        settings_put(serial, "secure", "miui_refresh_rate", "120")
        settings_put(serial, "system", "peak_refresh_rate", "120")
        settings_put(serial, "system", "min_refresh_rate", "120")
        time.sleep(1.0)

        sf = adb(serial, "shell", "dumpsys", "SurfaceFlinger").stdout
        lines = sf.splitlines()
        keep: list[str] = list(lines[:90])
        keep.append("")
        keep.append("--- Scheduler excerpt ---")
        grabbing = False
        for line in lines:
            if (
                line.startswith("Scheduler:")
                or line.startswith("VsyncSchedule")
                or "VSYNC period" in line
            ):
                grabbing = True
            if grabbing:
                keep.append(line)
                if line.startswith("Total missed frame"):
                    break
        (out / "sf-scheduler-120.txt").write_text("\n".join(keep) + "\n", encoding="utf-8")

        adb(
            serial,
            "push",
            str(script_dir / "dagu-android-display-pipeline-ondevice-sample.sh"),
            remote_sample,
        )
        t0 = time.time()
        su(
            serial,
            f"cp {remote_sample} /data/local/tmp/dagu-disp-sample.sh; "
            "chmod 755 /data/local/tmp/dagu-disp-sample.sh; "
            "sh /data/local/tmp/dagu-disp-sample.sh",
        )
        elapsed = time.time() - t0
        adb(
            serial,
            "pull",
            "/data/local/tmp/dagu-disp-pipeline/sample",
            str(out / "device-sample"),
        )

        sample_dir = out / "device-sample"
        before = (sample_dir / "disp_count_before.txt").read_text(encoding="utf-8")
        after = (sample_dir / "disp_count_after.txt").read_text(encoding="utf-8")
        kick0 = parse_kickoff(before)
        kick1 = parse_kickoff(after)
        poll = (sample_dir / "poll.txt").read_text(encoding="utf-8")
        vs_ns: list[int] = []
        rt_ns: list[int] = []
        for line in poll.splitlines():
            if "VSYNC=" in line:
                try:
                    vs_ns.append(int(line.split("VSYNC=", 1)[1].split()[0].split("=")[-1]))
                except (IndexError, ValueError):
                    pass
            if "RETIRE_FRAME_TIME=" in line:
                try:
                    rt_ns.append(int(line.split("RETIRE_FRAME_TIME=", 1)[1].split()[0]))
                except (IndexError, ValueError):
                    pass
        # unique in-order
        def uniq(seq: list[int]) -> list[int]:
            out_s: list[int] = []
            last = None
            for v in seq:
                if v != last:
                    out_s.append(v)
                    last = v
            return out_s

        vs_u = uniq(vs_ns)
        rt_u = uniq(rt_ns)

        summary = [
            f"host_elapsed_s={elapsed:.3f}",
            f"settings_before={old}",
            f"hw_vsync_before={(sample_dir / 'hw_vsync_before.txt').read_text(encoding='utf-8').strip()}",
            f"hw_vsync_after={(sample_dir / 'hw_vsync_after.txt').read_text(encoding='utf-8').strip()}",
            f"dynamic_fps_before={(sample_dir / 'dynamic_fps_before.txt').read_text(encoding='utf-8').strip()} "
            f"after={(sample_dir / 'dynamic_fps_after.txt').read_text(encoding='utf-8').strip()}",
            f"measured_fps_before={(sample_dir / 'measured_fps_before.txt').read_text(encoding='utf-8').strip()}",
            f"measured_fps_after={(sample_dir / 'measured_fps_after.txt').read_text(encoding='utf-8').strip()}",
        ]
        if kick0 is not None and kick1 is not None:
            dk = kick1 - kick0
            hz = dk / elapsed if elapsed else 0.0
            summary.append(f"panel_kickoff_delta={dk}")
            summary.append(f"panel_kickoff_hz_vs_host={hz:.3f}")
        summary.append(summarize_unique(vs_u, "vsync"))
        summary.append(summarize_unique(rt_u, "retire"))
        (out / "summary.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
        print("\n".join(summary))
    finally:
        settings_put(serial, "secure", "miui_refresh_rate", old["miui"])
        settings_put(serial, "system", "peak_refresh_rate", old["peak"])
        settings_put(serial, "system", "min_refresh_rate", old["minr"])
        (out / "settings-after-restore.txt").write_text(
            f"miui={settings_get(serial, 'secure', 'miui_refresh_rate')}\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
