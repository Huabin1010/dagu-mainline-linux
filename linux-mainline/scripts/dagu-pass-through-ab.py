#!/usr/bin/env python3
"""A/B Mutter Normal+scale=1.0 pass-through vs daily 270°/1.25.

Does not restart gdm. Confirmation banner must be tapped (Keep).
From host: python3 linux-mainline/scripts/dagu-pass-through-ab.py
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
OUT = ROOT / "out/display-stress"


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def ssh(cmd: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(ssh_base() + [cmd], check=check, text=True, capture_output=True)


def put(local: Path, remote: str) -> None:
    subprocess.run(
        ssh_base() + [f"cat >{remote} && chmod 755 {remote}"],
        input=local.read_bytes(),
        check=True,
    )


def tap(x: int, y: int) -> None:
    subprocess.run(
        ssh_base() + ["/usr/local/sbin/dagu-himax-swipe.py", "--tap", str(x), str(y)],
        check=False,
    )


def keep_taps(kind: str) -> None:
    # Physical 1600×2560. Banner "Keep these display settings?" sits low.
    if kind == "portrait":
        coords = (
            (920, 1340), (980, 1380), (900, 1300),
            (1100, 2280), (1280, 2360), (1400, 2420),
            (800, 2300), (1000, 2400), (1200, 2480),
        )
    else:
        coords = (
            (749, 1450), (760, 1480), (740, 1420),
            (1280, 1480), (1400, 1500),
        )
    for x, y in coords:
        tap(x, y)
        time.sleep(0.18)


def screenshot(host_name: str) -> None:
    helper = ROOT / "scripts" / "dagu-gnome-screenshot.sh"
    if not helper.is_file():
        return
    dest = OUT / host_name
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(helper), str(dest)], check=False)


def planes() -> str:
    r = ssh("python3 -c \"print(open('/sys/kernel/debug/dri/0/state').read())\"")
    return r.stdout


def plane_summary(state: str) -> list[dict]:
    rows = []
    cur = None
    for line in state.splitlines():
        if line.startswith("plane["):
            if cur:
                rows.append(cur)
            cur = {"name": line.split(":")[-1].strip(), "fb": None, "alloc": None, "size": None}
        elif cur is not None:
            s = line.strip()
            if s.startswith("crtc="):
                cur["crtc"] = s.split("=", 1)[1]
            elif s.startswith("fb="):
                cur["fb"] = s.split("=", 1)[1]
            elif s.startswith("allocated by"):
                cur["alloc"] = s.split("=", 1)[1].strip()
            elif s.startswith("size="):
                cur["size"] = s.split("=", 1)[1]
            elif s.startswith("crtc["):
                rows.append(cur)
                break
    if cur and cur not in rows:
        rows.append(cur)
    return [r for r in rows if r.get("fb") and r.get("fb") != "0"]


def orient(cmd: str) -> dict:
    r = ssh(f"/usr/local/sbin/dagu-mutter-orientation.py {cmd}")
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        return {"raw": r.stdout, "err": r.stderr}


def reload_ext() -> None:
    ssh(
        "sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 "
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus "
        "HOME=/home/dagu gnome-extensions disable dagu-present-pump@local; "
        "sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 "
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus "
        "HOME=/home/dagu gnome-extensions enable dagu-present-pump@local"
    )


def scanout() -> dict:
    r = ssh("cat /run/user/1001/dagu-scanout.json 2>/dev/null || cat /tmp/dagu-scanout.json 2>/dev/null || echo {}")
    try:
        return json.loads(r.stdout)
    except Exception:
        return {"raw": r.stdout}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = OUT / f"passthrough-ab-{stamp}"
    dest.mkdir(parents=True, exist_ok=True)

    put(ROOT / "scripts" / "dagu-mutter-orientation.py", "/usr/local/sbin/dagu-mutter-orientation.py")
    put(ROOT / "scripts" / "dagu-himax-swipe.py", "/usr/local/sbin/dagu-himax-swipe.py")
    ext = ROOT / "scripts" / "dagu-present-pump@local"
    ssh("mkdir -p /home/dagu/.local/share/gnome-shell/extensions/dagu-present-pump@local")
    put(ext / "extension.js",
        "/home/dagu/.local/share/gnome-shell/extensions/dagu-present-pump@local/extension.js")
    put(ext / "metadata.json",
        "/home/dagu/.local/share/gnome-shell/extensions/dagu-present-pump@local/metadata.json")
    ssh("chown -R dagu:dagu /home/dagu/.local/share/gnome-shell/extensions/dagu-present-pump@local")
    ssh("rm -f /tmp/dagu-want-fullscreen /run/user/1001/dagu-want-fullscreen")
    reload_ext()
    time.sleep(1.2)

    report: dict = {"stamp": stamp, "steps": []}

    def step(name: str, extra: dict | None = None) -> None:
        time.sleep(0.4)
        row = {
            "name": name,
            "orient": orient("get"),
            "scanout": scanout(),
            "planes": plane_summary(planes()),
        }
        if extra:
            row.update(extra)
        report["steps"].append(row)
        print(json.dumps(row, indent=2), flush=True)

    step("daily-270-1.25")
    screenshot(f"passthrough-ab-{stamp}/01-daily.png")

    print("=== set-normal-1 ===", flush=True)
    report["after_set_normal_1"] = orient("set-normal-1")
    time.sleep(0.8)
    screenshot(f"passthrough-ab-{stamp}/02-normal1-banner.png")
    keep_taps("portrait")
    time.sleep(1.0)
    got = orient("get")
    report["after_keep_normal_1"] = got
    if got.get("transform") != 0 or abs(float(got.get("scale") or 0) - 1.0) > 0.01:
        print("Keep missed, tapping more", flush=True)
        keep_taps("portrait")
        time.sleep(1.0)
        got = orient("get")
        report["after_keep_normal_1_retry"] = got
    screenshot(f"passthrough-ab-{stamp}/03-normal1.png")
    step("normal-1-max")

    print("=== request Chrome fullscreen ===", flush=True)
    ssh("touch /run/user/1001/dagu-want-fullscreen; chown dagu:dagu /run/user/1001/dagu-want-fullscreen; chmod 666 /run/user/1001/dagu-want-fullscreen")
    time.sleep(2.5)
    screenshot(f"passthrough-ab-{stamp}/04-normal1-fs.png")
    step("normal-1-fs")

    (dest / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    (dest / "drm-state.txt").write_text(planes())

    print("=== restore daily ===", flush=True)
    ssh("rm -f /tmp/dagu-want-fullscreen /run/user/1001/dagu-want-fullscreen")
    # Leave fullscreen if we entered it so restore is a maximized window.
    ssh(
        "sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 "
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus "
        "HOME=/home/dagu gnome-extensions disable dagu-present-pump@local; "
        "sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 "
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus "
        "HOME=/home/dagu gnome-extensions enable dagu-present-pump@local"
    )
    time.sleep(0.6)
    report["restore"] = orient("set-daily")
    time.sleep(0.7)
    keep_taps("landscape")
    time.sleep(1.2)
    report["restore_get"] = orient("get")
    if report["restore_get"].get("transform") != 3:
        keep_taps("landscape")
        time.sleep(1.0)
        report["restore_get"] = orient("get")
    screenshot(f"passthrough-ab-{stamp}/05-restored.png")
    (dest / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({
        "dest": str(dest),
        "restore": report["restore_get"],
        "normal_1_planes": [s["planes"] for s in report["steps"] if "normal-1" in s["name"]],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
