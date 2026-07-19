from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from daemon import run_daemon
    from paths import LIVE_LOG, clear_state, ensure_layer_dir, load_config, load_state, save_state
    from protocol import Event, Request, encode_request
    from shell import ping_wsl
else:
    from .daemon import run_daemon
    from .paths import LIVE_LOG, clear_state, ensure_layer_dir, load_config, load_state, save_state
    from .protocol import Event, Request, encode_request
    from .shell import ping_wsl


def configure_unbuffered_io() -> None:
    """Cursor/CI pipes are not TTYs; force immediate byte writes."""
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(line_buffering=False, write_through=True)
            except (OSError, ValueError):
                pass


configure_unbuffered_io()


def emit_bytes(data: str, *, mirror_log: bool = True) -> None:
    if not data:
        return
    payload = data.encode("utf-8", errors="replace")
    os.write(1, payload)
    if mirror_log:
        ensure_layer_dir()
        with LIVE_LOG.open("ab") as handle:
            handle.write(payload)
            handle.flush()


def emit_stderr(data: str) -> None:
    if not data:
        return
    payload = data.encode("utf-8", errors="replace")
    os.write(2, payload)


def connect(host: str, port: int, timeout: float = 5.0) -> socket.socket:
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(None)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


def send_request(sock: socket.socket, req: Request) -> None:
    payload = encode_request(req) + "\n"
    sock.sendall(payload.encode("utf-8"))


def iter_events(sock: socket.socket):
    buf = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            yield Event.from_json(line.decode("utf-8"))


def is_daemon_alive(state: dict | None) -> bool:
    if not state:
        return False
    host = state.get("host", "127.0.0.1")
    port = int(state.get("port", 0))
    try:
        sock = connect(host, port, timeout=1.0)
        send_request(sock, Request(op="ping"))
        for event in iter_events(sock):
            sock.close()
            return event.type == "pong"
        sock.close()
    except OSError:
        return False
    return False


def cmd_start(args: argparse.Namespace) -> int:
    if is_daemon_alive(load_state()):
        state = load_state() or {}
        print(json.dumps({"type": "started", "already_running": True, **state}, ensure_ascii=False))
        return 0

    config = load_config()
    ping_wsl(config.get("wsl_distro"))

    daemon_path = Path(__file__).resolve().parent / "daemon.py"
    log_path = Path(__file__).resolve().parents[2] / ".wsl-layer" / "daemon.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_file = log_path.open("a", encoding="utf-8")

    creationflags = 0
    if sys.platform == "win32":
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS | subprocess.CREATE_NO_WINDOW

    proc = subprocess.Popen(
        [sys.executable, str(daemon_path), "--foreground"],
        stdout=log_file,
        stderr=subprocess.STDOUT,
        creationflags=creationflags,
        close_fds=False,
    )

    deadline = time.time() + 45
    while time.time() < deadline:
        if proc.poll() is not None:
            print(log_path.read_text(encoding="utf-8", errors="replace"), file=sys.stderr)
            return 1
        state = load_state()
        if is_daemon_alive(state):
            print(
                json.dumps(
                    {
                        "type": "started",
                        "host": state.get("host"),
                        "port": state.get("port"),
                        "pid": state.get("pid"),
                        "cwd": state.get("cwd"),
                    },
                    ensure_ascii=False,
                )
            )
            return 0
        time.sleep(0.1)

    proc.kill()
    print("Timed out waiting for WSL layer daemon", file=sys.stderr)
    return 1


def cmd_stop(_: argparse.Namespace) -> int:
    state = load_state()
    if not state:
        print("WSL layer is not running")
        return 0

    host = state.get("host", "127.0.0.1")
    port = int(state["port"])
    try:
        sock = connect(host, port)
        send_request(sock, Request(op="shutdown"))
        for _ in iter_events(sock):
            pass
        sock.close()
    except OSError:
        pass

    pid = state.get("pid")
    if pid and sys.platform == "win32":
        subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)

    clear_state()
    print('{"type":"stopped"}')
    return 0


def cmd_status(_: argparse.Namespace) -> int:
    state = load_state()
    if not is_daemon_alive(state):
        print(json.dumps({"type": "status", "running": False}, ensure_ascii=False))
        return 1

    host = state["host"]
    port = int(state["port"])
    sock = connect(host, port)
    send_request(sock, Request(op="status"))
    for event in iter_events(sock):
        print(
            json.dumps(
                {
                    "type": "status",
                    "running": True,
                    "host": host,
                    "port": port,
                    "daemon_pid": state.get("pid"),
                    "shell_pid": event.pid,
                    "cwd": event.cwd,
                },
                ensure_ascii=False,
            )
        )
        sock.close()
        return 0
    sock.close()
    return 1


def cmd_run(args: argparse.Namespace) -> int:
    if not is_daemon_alive(load_state()):
        start_code = cmd_start(argparse.Namespace())
        if start_code != 0:
            return start_code

    ensure_layer_dir()
    LIVE_LOG.write_bytes(b"")
    emit_stderr(
        f"[wsl-layer] streaming -> stdout + {LIVE_LOG}\n"
        f"[wsl-layer] 另开终端实时查看: Get-Content -Wait {LIVE_LOG}\n"
    )

    state = load_state()
    assert state
    host = state["host"]
    port = int(state["port"])

    sock = connect(host, port)
    send_request(
        sock,
        Request(op="run", command=args.command, timeout=args.timeout),
    )

    exit_code = 1
    for event in iter_events(sock):
        if event.type == "output" and event.data:
            stream = event.stream or "stdout"
            if args.json:
                line = json.dumps(
                    {"type": "output", "stream": stream, "data": event.data},
                    ensure_ascii=False,
                )
                emit_bytes(line + "\n", mirror_log=False)
            else:
                emit_bytes(event.data)
        elif event.type == "done":
            exit_code = event.exit_code or 0
            if args.json:
                line = json.dumps(
                    {"type": "done", "exit_code": exit_code, "cwd": event.cwd},
                    ensure_ascii=False,
                )
                emit_bytes(line + "\n", mirror_log=False)
            break
        elif event.type == "error":
            emit_stderr((event.message or "error") + "\n")
            exit_code = 1
            break

    sock.close()
    return exit_code


def cmd_logs(args: argparse.Namespace) -> int:
    ensure_layer_dir()
    if not LIVE_LOG.is_file():
        emit_stderr("[wsl-layer] live.log 尚不存在，先 run 一条命令\n")
        return 1

    with LIVE_LOG.open("r", encoding="utf-8", errors="replace") as handle:
        if args.from_start:
            handle.seek(0)
        else:
            handle.seek(0, os.SEEK_END)

        if not args.follow:
            tail = handle.read()
            if tail:
                emit_bytes(tail, mirror_log=False)
            return 0

        emit_stderr(f"[wsl-layer] following {LIVE_LOG} (Ctrl+C 退出)\n")
        while True:
            chunk = handle.read()
            if chunk:
                emit_bytes(chunk, mirror_log=False)
            else:
                time.sleep(0.2)


def cmd_cd(args: argparse.Namespace) -> int:
    if not is_daemon_alive(load_state()):
        cmd_start(argparse.Namespace())

    state = load_state()
    assert state
    sock = connect(state["host"], int(state["port"]))
    send_request(sock, Request(op="cd", path=args.path))
    code = 1
    for event in iter_events(sock):
        if event.type == "done":
            code = event.exit_code or 0
            print(json.dumps({"type": "done", "cwd": event.cwd}, ensure_ascii=False))
            break
        if event.type == "error":
            print(event.message, file=sys.stderr)
            break
    sock.close()
    return code


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wsl-layer",
        description="Persistent WSL shell with streaming output",
    )
    sub = parser.add_subparsers(dest="action", required=True)

    sub.add_parser("start", help="Start persistent WSL daemon")

    sub.add_parser("stop", help="Stop daemon and shell")

    sub.add_parser("status", help="Show daemon status")

    p_run = sub.add_parser("run", help="Run command in persistent shell")
    p_run.add_argument("command", help="Shell command string")
    p_run.add_argument("--timeout", type=float, default=None)
    p_run.add_argument("--json", action="store_true", help="Emit NDJSON events")

    p_cd = sub.add_parser("cd", help="Change persistent shell cwd")
    p_cd.add_argument("path")

    p_logs = sub.add_parser("logs", help="Tail live output log")
    p_logs.add_argument(
        "--follow",
        "-f",
        action="store_true",
        help="Follow log file like tail -f",
    )
    p_logs.add_argument(
        "--from-start",
        action="store_true",
        help="Read from beginning instead of end",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.action == "start":
        return cmd_start(args)
    if args.action == "stop":
        return cmd_stop(args)
    if args.action == "status":
        return cmd_status(args)
    if args.action == "run":
        return cmd_run(args)
    if args.action == "cd":
        return cmd_cd(args)
    if args.action == "logs":
        return cmd_logs(args)
    parser.error(f"unknown action: {args.action}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
