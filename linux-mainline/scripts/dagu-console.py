#!/usr/bin/env python3
"""Talk to dagu over g_serial (/dev/ttyACM0), no RNDIS required.

Commands:
  ./scripts/dagu-console.py run 'uname -a'
  ./scripts/dagu-console.py put local.py /usr/local/sbin/dagu-touch-test.py
  ./scripts/dagu-console.py stream 'python3 -u /usr/local/sbin/dagu-touch-test.py'
"""
from __future__ import annotations

import argparse
import base64
import errno
import os
import select
import sys
import termios
import time
from pathlib import Path

PROMPT = "###DAGU### "
PORT_DEFAULT = "/dev/ttyACM0"
PASS_FILE = Path(__file__).resolve().parent.parent / "out" / "root-password"


def open_tty(port: str) -> int:
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
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
    return fd


def read_some(fd: int, sec: float) -> str:
    end = time.time() + sec
    buf = b""
    while time.time() < end:
        try:
            chunk = os.read(fd, 8192)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                chunk = b""
            else:
                raise
        if chunk:
            buf += chunk
            end = time.time() + 0.15
        else:
            time.sleep(0.03)
    return buf.decode("utf-8", "replace")


def write_line(fd: int, s: str) -> None:
    os.write(fd, s.encode("utf-8", "replace") + b"\r")


def wait_for(fd: int, needles, timeout: float) -> str:
    if isinstance(needles, str):
        needles = (needles,)
    end = time.time() + timeout
    buf = ""
    while time.time() < end:
        buf += read_some(fd, 0.2)
        for n in needles:
            if n in buf:
                return buf
    return buf


def load_password() -> str:
    if not PASS_FILE.is_file():
        raise SystemExit(f"missing {PASS_FILE}")
    return PASS_FILE.read_text().strip()


def login(fd: int) -> None:
    write_line(fd, "")
    out = wait_for(fd, ("login:", "Password:", "# ", PROMPT), 2.0)
    if PROMPT in out:
        return
    if "login:" in out:
        write_line(fd, "root")
        out = wait_for(fd, ("Password:", "# ", PROMPT), 3.0)
    if "Password:" in out:
        write_line(fd, load_password())
        wait_for(fd, ("# ", PROMPT, "$ "), 5.0)
    # Quiet the Ubuntu 26 OSC spam so we can find our prompt.
    write_line(fd, "export TERM=dumb SYSTEMD_OSC_CONTEXT=0; unset PROMPT_COMMAND; PS1='" + PROMPT + "'")
    got = wait_for(fd, (PROMPT,), 4.0)
    if PROMPT not in got:
        write_line(fd, "")
        got = wait_for(fd, (PROMPT,), 2.0)
    if PROMPT not in got:
        raise SystemExit("serial login failed — is 0525:a4a7 /dev/ttyACM0 a getty?")


def run(fd: int, cmd: str, timeout: float = 30.0) -> str:
    write_line(fd, cmd)
    end = time.time() + timeout
    buf = ""
    while time.time() < end:
        buf += read_some(fd, 0.25)
        # Command echo + output + next prompt.
        if buf.count(PROMPT) >= 1 and buf.rstrip().endswith(PROMPT.rstrip()):
            break
        if PROMPT in buf[len(cmd) :]:
            # prompt appeared after the echoed command
            tail = buf.rsplit(PROMPT, 1)[-1]
            if not tail.strip():
                break
    # Drop the echoed command line and the trailing prompt.
    body = buf
    if body.startswith(cmd):
        body = body[len(cmd) :]
    body = body.replace("\r", "")
    if PROMPT in body:
        body = body.rsplit(PROMPT, 1)[0]
    return body.strip("\n")


def put(fd: int, src: Path, dst: str) -> None:
    data = src.read_bytes()
    b64 = base64.b64encode(data).decode("ascii")
    run(fd, "rm -f /tmp/dagu-put.b64")
    chunk = 400
    for i in range(0, len(b64), chunk):
        piece = b64[i : i + chunk]
        run(fd, "printf '%s' '" + piece + "' >> /tmp/dagu-put.b64")
    out = run(
        fd,
        "mkdir -p \"$(dirname '"
        + dst
        + "')\" && base64 -d /tmp/dagu-put.b64 > '"
        + dst
        + "' && chmod +x '"
        + dst
        + "' && rm -f /tmp/dagu-put.b64 && wc -c '"
        + dst
        + "'",
    )
    print(out)


def stream(fd: int, cmd: str) -> int:
    write_line(fd, cmd)
    stdin_fd = sys.stdin.fileno()
    old = None
    if sys.stdin.isatty():
        old = termios.tcgetattr(stdin_fd)
        raw = termios.tcgetattr(stdin_fd)
        raw[3] = raw[3] & ~(termios.ECHO | termios.ICANON)
        raw[6][termios.VMIN] = 0
        raw[6][termios.VTIME] = 0
        termios.tcsetattr(stdin_fd, termios.TCSANOW, raw)
    buf = ""
    try:
        while True:
            r, _, _ = select.select([fd, stdin_fd], [], [], 0.25)
            if stdin_fd in r:
                data = os.read(stdin_fd, 1024)
                if data:
                    if data == b"\x03":
                        os.write(fd, b"\x03")
                    else:
                        os.write(fd, data)
            if fd in r:
                chunk = os.read(fd, 4096)
                if not chunk:
                    continue
                text = chunk.decode("utf-8", "replace")
                sys.stdout.write(text.replace("\r", ""))
                sys.stdout.flush()
                buf += text
                if PROMPT in buf[-80:]:
                    return 0
    except KeyboardInterrupt:
        os.write(fd, b"\x03")
        wait_for(fd, (PROMPT,), 5.0)
        return 130
    finally:
        if old is not None:
            termios.tcsetattr(stdin_fd, termios.TCSANOW, old)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="dagu USB serial helper")
    ap.add_argument("--port", default=os.environ.get("DAGU_TTY", PORT_DEFAULT))
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_run = sub.add_parser("run")
    p_run.add_argument("command")
    p_put = sub.add_parser("put")
    p_put.add_argument("src")
    p_put.add_argument("dst")
    p_stream = sub.add_parser("stream")
    p_stream.add_argument("command")
    args = ap.parse_args()

    if not Path(args.port).exists():
        raise SystemExit(f"no {args.port} — want g_serial 0525:a4a7")

    fd = open_tty(args.port)
    try:
        login(fd)
        if args.cmd == "run":
            print(run(fd, args.command))
            return 0
        if args.cmd == "put":
            put(fd, Path(args.src), args.dst)
            return 0
        if args.cmd == "stream":
            return stream(fd, args.command)
    finally:
        os.close(fd)
    return 1


if __name__ == "__main__":
    sys.exit(main())
