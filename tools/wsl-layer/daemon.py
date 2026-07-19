from __future__ import annotations

import argparse
import json
import socket
import socketserver
import sys
import threading
import time
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from paths import clear_state, ensure_layer_dir, load_config, save_state
    from protocol import Event, Request
    from shell import PersistentShell, ping_wsl
else:
    from .paths import clear_state, ensure_layer_dir, load_config, save_state
    from .protocol import Event, Request
    from .shell import PersistentShell, ping_wsl


class SessionServer:
    def __init__(self, host: str, port: int, config: dict):
        self.host = host
        self.port = port
        self.config = config
        self.shell = PersistentShell(
            distro=config.get("wsl_distro"),
            initial_cwd=config.get("initial_cwd"),
        )
        self.started_at = time.time()

    def start_shell(self) -> None:
        ping_wsl(self.config.get("wsl_distro"))
        self.shell.start()

    def handle(self, req: Request, write_line) -> None:
        if req.op == "ping":
            write_line(Event(type="pong", message="ok", cwd=self.shell.cwd).to_line())
            return

        if req.op == "status":
            write_line(
                Event(
                    type="status",
                    message="running" if self.shell.alive else "stopped",
                    cwd=self.shell.cwd,
                    pid=self.shell._proc.pid if self.shell.alive and self.shell._proc else None,
                ).to_line()
            )
            return

        if req.op == "cd":
            if not req.path:
                write_line(Event(type="error", message="missing path").to_line())
                return
            cwd = self.shell.cd(req.path)
            write_line(Event(type="done", exit_code=0, cwd=cwd).to_line())
            return

        if req.op == "run":
            if not req.command:
                write_line(Event(type="error", message="missing command").to_line())
                return

            def on_output(stream: str, data: str) -> None:
                write_line(Event(type="output", stream=stream, data=data).to_line())

            try:
                code, cwd = self.shell.run(req.command, on_output, timeout=req.timeout)
                write_line(Event(type="done", exit_code=code, cwd=cwd).to_line())
            except TimeoutError as exc:
                write_line(Event(type="error", message=str(exc)).to_line())
            except Exception as exc:  # noqa: BLE001 - surface to client
                write_line(Event(type="error", message=str(exc)).to_line())
            return

        if req.op == "shutdown":
            write_line(Event(type="shutdown", message="bye").to_line())
            self.shell.stop()
            raise SystemExit(0)

        write_line(Event(type="error", message=f"unknown op: {req.op}").to_line())


class ThreadedTCPHandler(socketserver.BaseRequestHandler):
    server: "ThreadedTCPServer"

    def handle(self) -> None:
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        file_obj = self.request.makefile("rwb")
        write_lock = threading.Lock()

        def write_line(line: str) -> None:
            payload = (line + "\n").encode("utf-8")
            with write_lock:
                file_obj.write(payload)
                file_obj.flush()

        while True:
            raw = file_obj.readline()
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                req = Request.from_json(line)
                self.server.session.handle(req, write_line)
            except SystemExit:
                break
            except Exception as exc:  # noqa: BLE001
                write_line(Event(type="error", message=str(exc)).to_line())


class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, host: str, port: int, session: SessionServer):
        super().__init__((host, port), ThreadedTCPHandler)
        self.session = session


def run_daemon(foreground: bool) -> int:
    config = load_config()
    host = config["host"]
    port = int(config["port"])

    ensure_layer_dir()
    session = SessionServer(host, port, config)
    session.start_shell()

    server = ThreadedTCPServer(host, port, session)
    save_state(
        {
            "host": host,
            "port": port,
            "pid": __import__("os").getpid(),
            "started_at": time.time(),
            "cwd": session.shell.cwd,
        }
    )

    if foreground:
        print(json.dumps({"type": "ready", "host": host, "port": port, "cwd": session.shell.cwd}), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            session.shell.stop()
            clear_state()
        return 0

    # Foreground mode expected when launched by client start
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="WSL persistent streaming daemon")
    parser.add_argument("--foreground", action="store_true", help="Run in foreground")
    args = parser.parse_args()
    return run_daemon(args.foreground)


if __name__ == "__main__":
    raise SystemExit(main())
