#!/usr/bin/env python3
"""Keep mutter in tablet mode so GNOME OSK can appear.

dagu hall GPIO121 (folio) is ACTIVE_LOW in older DTS and idles at 0,
which libinput reports as laptop mode. Inject SW_TABLET_MODE=1 into
the gpio-keys evdev node. Harmless once the kernel polarity is fixed.
"""
import glob
import os
import struct
import time

EV_SYN = 0
EV_SW = 5
SYN_REPORT = 0
SW_TABLET_MODE = 1
FMT = "llHHI"


def find_gpio_keys():
    for name_path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            with open(name_path, encoding="utf-8") as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == "gpio-keys":
            return f"/dev/input/{name_path.split('/')[4]}"
    return "/dev/input/event4"


def emit(fd, etype, code, value):
    os.write(fd, struct.pack(FMT, 0, 0, etype, code, value))


def main():
    path = find_gpio_keys()
    fd = os.open(path, os.O_WRONLY)
    try:
        while True:
            emit(fd, EV_SW, SW_TABLET_MODE, 1)
            emit(fd, EV_SYN, SYN_REPORT, 0)
            time.sleep(15)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
