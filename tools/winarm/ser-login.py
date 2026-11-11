#!/usr/bin/env python3
"""Log in as root on the dagu USB serial console, robust to kernel noise.

  ser-login.py [--dev /dev/ttyACM0]

Kernel messages (ufshcd WB) interleave with the getty prompts, so prompts
are not matched; fixed waits are used and the result is checked by
echoing a marker. Exit 0 when a root shell answers.
"""
import argparse
import os
import termios
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyACM0")
    a = ap.parse_args()
    fd = os.open(a.dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    t = termios.tcgetattr(fd)
    t[0] = 0
    t[1] = 0
    t[3] = 0
    termios.tcsetattr(fd, termios.TCSANOW, t)

    def wr(b):
        for _ in range(100):
            try:
                os.write(fd, b)
                return
            except BlockingIOError:
                time.sleep(0.1)

    def rd(s):
        b = b""
        e = time.time() + s
        while time.time() < e:
            try:
                d = os.read(fd, 65536)
                if d:
                    b += d
                    continue
            except BlockingIOError:
                pass
            time.sleep(0.05)
        return b

    rd(1)
    wr(b"echo @@L''OK@@\r")
    if b"@@LOK@@" in rd(2):
        print("already logged in")
        return 0
    for _ in range(3):
        wr(b"\x03\r")
        rd(4)
        wr(b"root\r")
        rd(3)
        wr(b"dagu\r")
        rd(6)
        wr(b"dmesg -n 1; echo @@L''OK@@\r")
        if b"@@LOK@@" in rd(3):
            print("logged in")
            return 0
    print("login failed")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
