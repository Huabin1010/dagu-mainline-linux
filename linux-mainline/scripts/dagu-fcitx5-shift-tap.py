#!/usr/bin/env python3
"""Xiaomi folio: tap Shift → fcitx5-remote -t.

This kernel has no /dev/uinput (CONFIG_INPUT_UINPUT was off), so keyd cannot
remap. Watch the real keyboard without grabbing: a Shift tap with no other
key in between toggles 中/英. Hold Shift + letter still capitalizes.
"""
from __future__ import annotations

import os
import select
import subprocess
import time

from evdev import InputDevice, ecodes, list_devices

USER = "dagu"
UID = 1001
RUNTIME = f"/run/user/{UID}"
DEVICE_NAME = "Xiaomi Keyboard"
TAP_SEC = 0.50
SHIFTS = {ecodes.KEY_LEFTSHIFT, ecodes.KEY_RIGHTSHIFT}


def toggle() -> None:
    env = os.environ.copy()
    env.update(
        {
            "HOME": f"/home/{USER}",
            "XDG_RUNTIME_DIR": RUNTIME,
            "DBUS_SESSION_BUS_ADDRESS": f"unix:path={RUNTIME}/bus",
            "DISPLAY": ":0",
            "WAYLAND_DISPLAY": "wayland-0",
        }
    )
    subprocess.run(
        ["runuser", "-u", USER, "--", "fcitx5-remote", "-t"],
        env=env,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def open_keyboard() -> InputDevice | None:
    for path in list_devices():
        try:
            dev = InputDevice(path)
        except OSError:
            continue
        if dev.name == DEVICE_NAME:
            return dev
    return None


def main() -> None:
    while True:
        dev = open_keyboard()
        if dev is None:
            time.sleep(1.0)
            continue
        pending: dict[int, tuple[float, bool]] = {}
        try:
            while True:
                ready, _, _ = select.select([dev.fd], [], [], 2.0)
                if not ready:
                    continue
                for ev in dev.read():
                    if ev.type != ecodes.EV_KEY or ev.value == 2:
                        continue
                    if ev.code in SHIFTS:
                        if ev.value == 1:
                            pending[ev.code] = (ev.timestamp(), False)
                        elif ev.value == 0 and ev.code in pending:
                            t0, dirty = pending.pop(ev.code)
                            if not dirty and (ev.timestamp() - t0) <= TAP_SEC:
                                toggle()
                    elif pending:
                        pending = {k: (t0, True) for k, (t0, _) in pending.items()}
        except OSError:
            time.sleep(0.3)


if __name__ == "__main__":
    main()
