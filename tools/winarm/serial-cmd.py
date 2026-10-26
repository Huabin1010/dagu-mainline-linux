#!/usr/bin/env python3
"""Run shell commands on the dagu Linux over the USB serial gadget (ttyGS0).

Used when the tablet is only reachable by USB (no Wi-Fi/SSH): the board's
Linux exposes a CDC-ACM console (0525:a4a7) that shows up as /dev/ttyACM*.

  serial-cmd.py [--dev /dev/ttyACM0] [--timeout 30] 'command; command'

Each command is wrapped with unique start/end markers so the output can be
cut out of the console noise; the exit code is propagated.
"""
import argparse
import os
import sys
import termios
import time
import uuid


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyACM0")
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--raw", action="store_true", help="send keystrokes, dump output")
    ap.add_argument("--push", metavar="LOCAL",
                    help="stream LOCAL to the remote path given as cmd (base64)")
    ap.add_argument("cmd")
    a = ap.parse_args()

    fd = os.open(a.dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    t = termios.tcgetattr(fd)
    t[0] = 0                      # iflag
    t[1] = 0                      # oflag
    t[3] = 0                      # lflag: raw, no echo
    termios.tcsetattr(fd, termios.TCSANOW, t)

    def read_for(sec, until=None):
        buf = b""
        end = time.time() + sec
        while time.time() < end:
            try:
                chunk = os.read(fd, 65536)
                if chunk:
                    buf += chunk
                    if until and until in buf:
                        return buf
                    continue
            except BlockingIOError:
                pass
            time.sleep(0.05)
        return buf

    read_for(0.3)
    if a.push:
        import base64
        import hashlib
        size = os.path.getsize(a.push)
        # base64.encodebytes layout: 57 input bytes -> 76 chars + "\n" per line
        full, rem = divmod(size, 57)
        b64len = full * 77 + ((4 * ((rem + 2) // 3) + 1) if rem else 0)
        tag = uuid.uuid4().hex[:8]
        # Remote side: no echo, read exactly b64len bytes, decode, report sha.
        os.write(fd, (f"stty -echo; head -c {b64len} | base64 -d > '{a.cmd}'; stty echo; "
                      f"echo @@P{tag}''@@ $(sha256sum '{a.cmd}' | cut -c1-16)\r").encode())
        time.sleep(0.5)
        sha = hashlib.sha256()
        sent, t0, last = 0, time.time(), 0.0
        with open(a.push, "rb") as fh:
            while True:
                chunk = fh.read(57 * 4096)        # multiple of 57: line layout preserved
                if not chunk:
                    break
                sha.update(chunk)
                view = memoryview(base64.encodebytes(chunk))
                while view:
                    try:
                        n = os.write(fd, view[:65536])
                        view = view[n:]
                    except BlockingIOError:
                        time.sleep(0.005)
                    # drain console output so the gadget never stalls on us
                    try:
                        os.read(fd, 65536)
                    except BlockingIOError:
                        pass
                sent += len(chunk)
                if size > 50 << 20 and time.time() - last > 30:
                    last = time.time()
                    sys.stderr.write(f"  {sent >> 20}/{size >> 20} MiB "
                                     f"{sent / (last - t0 + 1e-9) / 1e6:.1f} MB/s\n")
        out = read_for(a.timeout, until=f"@@P{tag}@@".encode()).decode("utf-8", "replace")
        out += read_for(1.0).decode("utf-8", "replace")
        want = sha.hexdigest()[:16]
        got = out.split(f"@@P{tag}@@", 1)[1].split()[0] if f"@@P{tag}@@" in out else "?"
        print(f"pushed {size} bytes in {time.time() - t0:.0f}s -> {a.cmd}: "
              f"remote {got} local {want}")
        return 0 if got == want else 1
    if a.raw:
        os.write(fd, a.cmd.encode() + b"\r")
        sys.stdout.write(read_for(a.timeout).decode("utf-8", "replace"))
        return 0

    tag = uuid.uuid4().hex[:8]
    beg, fin = f"@@B{tag}@@", f"@@E{tag}@@"
    # Markers are split in the echoed command line so only real output matches.
    line = (f"echo @@B{tag}''@@; ( {a.cmd} ) 2>&1; "
            f"echo @@E{tag}''@@ $?\r")
    view = memoryview(line.encode())
    while view:                        # fd is non-blocking: the gadget can be full
        try:
            view = view[os.write(fd, view):]
        except BlockingIOError:
            read_for(0.05)             # drain console output, then retry
    out = read_for(a.timeout, until=fin.encode()).decode("utf-8", "replace")
    out += read_for(0.3).decode("utf-8", "replace")
    if beg not in out:
        sys.stderr.write("no response on console:\n" + out[-2000:] + "\n")
        return 2
    body = out.split(beg, 1)[1]
    if fin not in body:
        sys.stdout.write(body.replace("\r", ""))
        sys.stderr.write(f"\n[timeout after {a.timeout}s]\n")
        return 124
    body, tail = body.split(fin, 1)
    sys.stdout.write(body.replace("\r", "").lstrip("\n"))
    try:
        return int(tail.strip().split()[0])
    except (ValueError, IndexError):
        return 0


if __name__ == "__main__":
    sys.exit(main())
