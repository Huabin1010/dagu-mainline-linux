#!/usr/bin/env python3
"""dagu: short power key toggles Mutter DPMS only.

DCS 0x51 times out on this video-mode panel (~200 ms × 2 links) and
does not restore. lock-sessions makes mutter set PowerSaveMode=3 AND
the lock shield, then a second press races blank-on-lock. Just flip
PowerSaveMode 0/3; kernel unprepare is a no-op so clocks can return.
Long press stays logind HandlePowerKeyLongPress=poweroff.
"""
import glob
import os
import struct
import subprocess
import time

KEY_POWER = 116
EV_KEY = 1
FMT = "llHHI"
SIZE = struct.calcsize(FMT)
LONG_PRESS = 1.2


def find_pwrkey():
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            with open(name_path, encoding="utf-8") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == "pm8941_pwrkey":
            event = name_path.split("/")[4]
            return f"/dev/input/{event}"
    return "/dev/input/event1"


def gnome_env():
    env = os.environ.copy()
    uid = "1001"
    try:
        out = subprocess.check_output(
            ["loginctl", "list-sessions", "--no-legend"], text=True
        )
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[2] == "dagu" and "seat" in line:
                uid = parts[1]
                break
    except (OSError, subprocess.SubprocessError):
        pass
    env["XDG_RUNTIME_DIR"] = f"/run/user/{uid}"
    env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{uid}/bus"
    return env


def dpms_sysfs():
    try:
        with open("/sys/class/drm/card0-DSI-1/dpms", encoding="ascii") as f:
            return f.read().strip().lower()
    except OSError:
        return "on"


def mutter_mode():
    try:
        out = subprocess.check_output(
            [
                "busctl",
                "--user",
                "get-property",
                "org.gnome.Mutter.DisplayConfig",
                "/org/gnome/Mutter/DisplayConfig",
                "org.gnome.Mutter.DisplayConfig",
                "PowerSaveMode",
            ],
            env=gnome_env(),
            text=True,
        )
        # "i 0" / "i 3"
        parts = out.split()
        return int(parts[-1]) if parts else 0
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0 if dpms_sysfs() == "on" else 3


def set_mutter(mode):
    subprocess.run(
        [
            "busctl",
            "--user",
            "set-property",
            "org.gnome.Mutter.DisplayConfig",
            "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig",
            "PowerSaveMode",
            "i",
            str(mode),
        ],
        env=gnome_env(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def blank():
    print("dagu-power-button: blank", flush=True)
    set_mutter(3)


def unblank():
    print("dagu-power-button: unblank", flush=True)
    set_mutter(0)


def open_event():
    path = find_pwrkey()
    last_err = None
    for _ in range(60):
        path = find_pwrkey()
        try:
            return os.open(path, os.O_RDONLY)
        except OSError as err:
            last_err = err
            time.sleep(1)
    raise SystemExit(f"cannot open {path}: {last_err}")


def main():
    fd = open_event()
    down_at = None
    last = 0.0
    while True:
        data = os.read(fd, SIZE)
        if len(data) < SIZE:
            continue
        _s, _us, etype, code, value = struct.unpack(FMT, data)
        if etype != EV_KEY or code != KEY_POWER:
            continue
        now = time.monotonic()
        if value == 1:
            down_at = now
            continue
        if value != 0 or down_at is None:
            continue
        held = now - down_at
        down_at = None
        if held >= LONG_PRESS:
            continue
        if now - last < 0.35:
            continue
        last = now
        if mutter_mode() != 0 or dpms_sysfs() != "on":
            unblank()
        else:
            blank()


if __name__ == "__main__":
    main()
