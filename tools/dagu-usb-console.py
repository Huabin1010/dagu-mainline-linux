#!/usr/bin/env python3
"""dagu USB CDC-ACM console (0525:a4a7).

Type-C gadget, not a USB-TTL dongle. Same VID/PID for:
  - Linux g_serial (ttyGS0)
  - UEFI DaguUsbCdcAcmDxe on UsbfnDwc3 (boot log replay)

  python3 tools/dagu-usb-console.py wait
  python3 tools/dagu-usb-console.py log
  python3 tools/dagu-usb-console.py run 'dmesg | tail'
  python3 tools/dagu-usb-console.py shell
"""
from __future__ import annotations

import argparse
import os
import stat
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONSOLE = ROOT / "linux-mainline" / "scripts" / "dagu-console.py"
VID = "0525"
PID = "a4a7"


def _read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace").strip().lower()
    except OSError:
        return ""


def find_acm() -> Path | None:
    env = os.environ.get("DAGU_TTY")
    if env:
        p = Path(env)
        return p if p.exists() else None

    usb = Path("/sys/bus/usb/devices")
    if usb.is_dir():
        for dev in usb.iterdir():
            if _read(dev / "idVendor") != VID:
                continue
            if _read(dev / "idProduct") != PID:
                continue
            for tty in sorted(dev.rglob("ttyACM*")) + sorted(dev.rglob("ttyUSB*")):
                node = Path("/dev") / tty.name
                if node.exists():
                    return node

    for name in ("ttyACM0", "ttyACM1", "ttyACM2", "ttyUSB0", "ttyUSB1"):
        node = Path("/dev") / name
        if node.exists():
            return node
    return None


def wait_acm(sec: float) -> Path:
    end = time.time() + sec
    while time.time() < end:
        got = find_acm()
        if got is not None:
            return got
        time.sleep(0.4)
    raise SystemExit(
        "no USB CDC-ACM 0525:a4a7 — need Linux g_serial or UEFI DaguUsbCdcAcmDxe. "
        "lsusb should show NetChip 0525:a4a7, not 18d1:d00d. "
        "1-IF gadget: sudo modprobe usbserial vendor=0x0525 product=0xa4a7"
    )


def log_acm(port: Path, sec: float | None) -> int:
    import fcntl
    import struct
    import termios

    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    try:
        attrs = termios.tcgetattr(fd)
        iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
        iflag = termios.IGNBRK | termios.IGNPAR
        oflag = 0
        cflag = termios.CS8 | termios.CREAD | termios.CLOCAL | termios.B115200
        lflag = 0
        cc = list(cc)
        cc[termios.VMIN] = 0
        cc[termios.VTIME] = 1
        termios.tcsetattr(
            fd,
            termios.TCSANOW,
            [iflag, oflag, cflag, lflag, termios.B115200, termios.B115200, cc],
        )
        try:
            fcntl.ioctl(fd, 0x5416, struct.pack("I", 0x002 | 0x004))
        except OSError:
            pass
        deadline = None if sec is None else time.time() + sec
        while deadline is None or time.time() < deadline:
            chunk = os.read(fd, 4096)
            if chunk:
                sys.stdout.buffer.write(chunk.replace(b"\r", b""))
                sys.stdout.buffer.flush()
            else:
                time.sleep(0.05)
    except KeyboardInterrupt:
        return 130
    finally:
        os.close(fd)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", default=None)
    ap.add_argument("--wait", type=float, default=30.0)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("wait")
    p_log = sub.add_parser("log")
    p_log.add_argument("--seconds", type=float, default=None)
    p_run = sub.add_parser("run")
    p_run.add_argument("command")
    sub.add_parser("shell")
    args = ap.parse_args()

    port = Path(args.port) if args.port else wait_acm(args.wait)
    if not port.exists():
        raise SystemExit(f"no {port}")
    if not stat.S_ISCHR(port.stat().st_mode):
        raise SystemExit(f"{port} is not a tty")

    print(f"==> {port} USB CDC-ACM 0525:a4a7 115200 8N1", file=sys.stderr)

    if args.cmd == "wait":
        return 0
    if args.cmd == "log":
        return log_acm(port, args.seconds)
    if args.cmd == "run":
        return subprocess.call(
            [sys.executable, str(CONSOLE), "--port", str(port), "run", args.command]
        )
    if args.cmd == "shell":
        return subprocess.call(
            [sys.executable, str(CONSOLE), "--port", str(port), "stream", "bash"]
        )
    return 2


if __name__ == "__main__":
    sys.exit(main())
