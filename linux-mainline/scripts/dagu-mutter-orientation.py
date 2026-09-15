#!/usr/bin/env python3
"""Get/set Mutter DSI-1 transform/scale without restarting gdm.

  0 = normal (panel 1600×2560)
  3 = right / 270° (daily landscape)

From host: python3 linux-mainline/scripts/dagu-mutter-orientation.py --host get
           python3 linux-mainline/scripts/dagu-mutter-orientation.py --host set-normal
           python3 linux-mainline/scripts/dagu-mutter-orientation.py --host set-right
           python3 linux-mainline/scripts/dagu-mutter-orientation.py --host set-normal-1
           python3 linux-mainline/scripts/dagu-mutter-orientation.py --host set-daily
           python3 linux-mainline/scripts/dagu-mutter-orientation.py --host set-normal-temp
           python3 linux-mainline/scripts/dagu-mutter-orientation.py --host set-normal-1-temp
           python3 linux-mainline/scripts/dagu-mutter-orientation.py --host set-daily-temp
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
MODE = "1600x2560@120.000"
# 1 = temporary (may expire). 2 = persistent (writes monitors.xml).
METHOD = 2


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


ON_DEVICE = r'''
import dbus, json, sys
want = sys.argv[1]
bus = dbus.SessionBus()
obj = bus.get_object("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig")
iface = dbus.Interface(obj, "org.gnome.Mutter.DisplayConfig")
serial, monitors, logical, props = iface.GetCurrentState()
cur = {
    "serial": int(serial),
    "scale": float(logical[0][2]) if logical else None,
    "transform": int(logical[0][3]) if logical else None,
    "x": int(logical[0][0]) if logical else None,
    "y": int(logical[0][1]) if logical else None,
}
if want == "get":
    print(json.dumps(cur))
    raise SystemExit(0)
method = 2
if want == "set-normal":
    tf, scale = 0, (cur["scale"] if cur["scale"] is not None else 1.25)
elif want == "set-right":
    tf, scale = 3, (cur["scale"] if cur["scale"] is not None else 1.25)
elif want == "set-normal-1":
    tf, scale = 0, 1.0
elif want == "set-daily":
    tf, scale = 3, 1.25
elif want == "set-normal-temp":
    tf, scale, method = 0, (cur["scale"] if cur["scale"] is not None else 1.25), 1
elif want == "set-normal-1-temp":
    tf, scale, method = 0, 1.0, 1
elif want == "set-daily-temp":
    tf, scale, method = 3, 1.25, 1
else:
    raise SystemExit("bad want")
mon = [("DSI-1", "1600x2560@120.000", dbus.Dictionary({}, signature="sv"))]
cfg = [(dbus.Int32(0), dbus.Int32(0), dbus.Double(scale), dbus.UInt32(tf), dbus.Boolean(True), mon)]
iface.ApplyMonitorsConfig(serial, method, cfg, dbus.Dictionary({}, signature="sv"))
serial, monitors, logical, props = iface.GetCurrentState()
print(json.dumps({
    "serial": int(serial),
    "scale": float(logical[0][2]),
    "transform": int(logical[0][3]),
}))
'''


def on_device(cmd: str) -> int:
    env = os.environ.copy()
    env.update({
        "XDG_RUNTIME_DIR": "/run/user/1001",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1001/bus",
        "HOME": "/home/dagu",
    })
    argv = [
        "sudo", "-u", "dagu", "env",
        "XDG_RUNTIME_DIR=/run/user/1001",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
        "HOME=/home/dagu",
        "python3", "-c", ON_DEVICE, cmd,
    ]
    r = subprocess.run(argv, env=env)
    return r.returncode


def main() -> int:
    args = [a for a in sys.argv[1:] if a]
    host = False
    if args and args[0] == "--host":
        host = True
        args = args[1:]
    cmd = args[0] if args else "get"
    if cmd not in (
        "get", "set-normal", "set-right", "set-normal-1", "set-daily",
        "set-normal-temp", "set-normal-1-temp", "set-daily-temp",
    ):
        print(
            "usage: dagu-mutter-orientation.py [--host] "
            "get|set-normal|set-right|set-normal-1|set-daily|"
            "set-normal-temp|set-normal-1-temp|set-daily-temp",
            file=sys.stderr,
        )
        return 2
    if host:
        remote = "/usr/local/sbin/dagu-mutter-orientation.py"
        subprocess.run(
            ssh_base() + [f"cat >{remote} && chmod 755 {remote}"],
            input=Path(__file__).read_bytes(),
            check=True,
        )
        return subprocess.run(ssh_base() + [remote, cmd], check=False).returncode
    return on_device(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
