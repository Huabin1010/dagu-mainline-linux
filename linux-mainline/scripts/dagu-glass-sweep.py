#!/usr/bin/env python3
"""Open the glass probe at several Mutter scales and dump KMS crops.

GPU path only. Run on the tablet as root (KMS mmap) after Chrome is up.
"""
from __future__ import annotations

import os
import subprocess
import time

SCALES = [
    1.0,
    1.25,
    1.3333333730697632,
    2.0,
]
MODE = "1600x2560@120.000"
TRANSFORM = 3
OUT = "/tmp/dagu-glass-sweep"
PAGE = "file:///home/dagu/dagu-glass-probe.html"


def wake():
    subprocess.run(
        [
            "sudo", "-u", "dagu",
            "XDG_RUNTIME_DIR=/run/user/1001",
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
            "python3", "-c",
            "import dbus\n"
            "bus=dbus.SessionBus()\n"
            "try:\n"
            " ss=bus.get_object('org.gnome.ScreenSaver','/org/gnome/ScreenSaver')\n"
            " dbus.Interface(ss,'org.gnome.ScreenSaver').SetActive(False)\n"
            "except Exception:\n"
            " pass\n"
            "o=bus.get_object('org.gnome.Mutter.DisplayConfig','/org/gnome/Mutter/DisplayConfig')\n"
            "dbus.Interface(o,'org.freedesktop.DBus.Properties').Set("
            "'org.gnome.Mutter.DisplayConfig','PowerSaveMode', dbus.Int32(0))\n",
        ],
        check=False,
    )


def apply_scale(scale: float) -> float:
    code = (
        "import dbus,time\n"
        "bus=dbus.SessionBus()\n"
        "o=bus.get_object('org.gnome.Mutter.DisplayConfig','/org/gnome/Mutter/DisplayConfig')\n"
        "i=dbus.Interface(o,'org.gnome.Mutter.DisplayConfig')\n"
        "serial,_,_,_=i.GetCurrentState()\n"
        f"mon=[('DSI-1','{MODE}',dbus.Dictionary({{}},signature='sv'))]\n"
        f"cfg=[(dbus.Int32(0),dbus.Int32(0),dbus.Double({scale!r}),"
        f"dbus.UInt32({TRANSFORM}),dbus.Boolean(True),mon)]\n"
        "i.ApplyMonitorsConfig(serial,1,cfg,dbus.Dictionary({},signature='sv'))\n"
        "time.sleep(1.0)\n"
        "_,_,logical,_=i.GetCurrentState()\n"
        "print(float(logical[0][2]))\n"
    )
    r = subprocess.run(
        [
            "sudo", "-u", "dagu",
            "env",
            "XDG_RUNTIME_DIR=/run/user/1001",
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
            "python3", "-c", code,
        ],
        capture_output=True, text=True, timeout=20,
    )
    try:
        return float(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return scale


def crop(path, x, y, w, h):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    subprocess.run(
        ["python3", "/usr/local/sbin/dagu-kms-land-crop.py", path, str(x), str(y), str(w), str(h)],
        check=False,
    )


def main():
    os.makedirs(OUT, exist_ok=True)
    wake()
    for s in SCALES:
        got = apply_scale(s)
        time.sleep(1.2)
        tag = f"{got:.3f}".replace(".", "p")
        crop(f"{OUT}/glass-{tag}-full.png", 0, 0, 1600, 1100)
        crop(f"{OUT}/glass-{tag}-bar.png", 20, 80, 1560, 200)
        crop(f"{OUT}/glass-{tag}-cards.png", 20, 260, 1560, 520)
        print(f"scale={got} wrote {OUT}/glass-{tag}-*.png")


if __name__ == "__main__":
    main()
