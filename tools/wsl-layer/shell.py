from __future__ import annotations

import base64
import shlex
import subprocess
import threading
import time
import uuid
from collections.abc import Callable


OutputCallback = Callable[[str, str], None]


class PersistentShell:
    """Long-lived WSL bash session with streaming stdout/stderr."""

    def __init__(self, distro: str | None = None, initial_cwd: str | None = None):
        self.distro = distro
        self.cwd = initial_cwd or "/"
        self._proc: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()
        self._stdout_buffer = bytearray()
        self._stdout_lock = threading.Lock()
        self._reader_stop = threading.Event()
        self._reader_thread: threading.Thread | None = None
        self._use_script: bool | None = None

    def _cd_command(self, path: str) -> str:
        # Tilde must not be shell-quoted or `cd` won't expand it.
        if path.startswith("~/") or path == "~":
            return f"cd {path}"
        return f"cd {shlex.quote(path)}"

    def start(self) -> None:
        if self._proc and self._proc.poll() is None:
            return

        cmd = ["wsl"]
        if self.distro:
            cmd.extend(["-d", self.distro])
        cmd.extend(["-e", "bash", "-l"])

        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        if not self._proc.stdin or not self._proc.stdout:
            raise RuntimeError("Failed to open WSL bash pipes")

        self._reader_stop.clear()
        self._reader_thread = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader_thread.start()

        self._run_internal(
            self._cd_command(self.cwd),
            lambda _s, _d: None,
            timeout=30,
            use_script=False,
        )
        self._use_script = self._detect_script()

    def stop(self) -> None:
        self._reader_stop.set()
        if self._proc and self._proc.poll() is None:
            try:
                if self._proc.stdin:
                    self._proc.stdin.write(b"exit\n")
                    self._proc.stdin.flush()
            except OSError:
                pass
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        self._proc = None

    @property
    def alive(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def run(
        self,
        command: str,
        on_output: OutputCallback,
        timeout: float | None = None,
    ) -> tuple[int, str]:
        with self._lock:
            return self._run_internal(command, on_output, timeout)

    def cd(self, path: str) -> str:
        code, cwd = self.run(self._cd_command(path), lambda _s, _d: None, timeout=30)
        if code != 0:
            raise RuntimeError(f"cd failed with exit code {code}")
        self.cwd = cwd
        return cwd

    def _detect_script(self) -> bool:
        code, _ = self._run_internal(
            "command -v script >/dev/null 2>&1",
            lambda _s, _d: None,
            timeout=10,
            use_script=False,
        )
        return code == 0

    def _reader_loop(self) -> None:
        assert self._proc and self._proc.stdout
        while not self._reader_stop.is_set():
            chunk = self._proc.stdout.read(4096)
            if not chunk:
                break
            with self._stdout_lock:
                self._stdout_buffer.extend(chunk)

    def _drain_buffer(self) -> bytes:
        with self._stdout_lock:
            data = bytes(self._stdout_buffer)
            self._stdout_buffer.clear()
            return data

    @staticmethod
    def _marker_holdback(*markers: str) -> int:
        return max((len(marker) for marker in markers), default=1) - 1

    @staticmethod
    def _emit_new_bytes(
        collected: str,
        emitted_upto: int,
        end: int,
        markers: tuple[str, ...],
        on_output: OutputCallback,
    ) -> int:
        if end <= emitted_upto:
            return emitted_upto

        segment = collected[emitted_upto:end]
        if not segment:
            return emitted_upto

        if any(marker in segment for marker in markers):
            cleaned = segment
            for marker in markers:
                cleaned = cleaned.replace(marker, "")
            if cleaned:
                on_output("stdout", cleaned)
        else:
            on_output("stdout", segment)
        return end

    def _prepare_command(self, command: str, use_script: bool) -> str:
        prepared = command
        if "sudo" in command and "sudo -S" not in command:
            prepared = (
                "if ! sudo -n true 2>/dev/null; then "
                "echo '[wsl-layer] ERROR: sudo 需要密码。"
                "请先在 WSL 里执行: sudo -v' >&2; "
                "exit 1; "
                "fi; "
                f"{command}"
            )
        if use_script:
            return f"script -qfec {shlex.quote(prepared)} /dev/null"
        return prepared

    def _wrap_command(self, command: str, use_script: bool) -> str:
        return self._prepare_command(command, use_script)

    def _run_internal(
        self,
        command: str,
        on_output: OutputCallback,
        timeout: float | None = None,
        use_script: bool | None = None,
    ) -> tuple[int, str]:
        if not self.alive:
            raise RuntimeError("WSL shell is not running")

        assert self._proc and self._proc.stdin
        token = uuid.uuid4().hex
        done_marker = f"__WSL_LAYER_DONE_{token}__:"
        cwd_marker = f"__WSL_LAYER_CWD_{token}__:"
        markers = (done_marker, cwd_marker)
        holdback = self._marker_holdback(*markers)

        if use_script is None:
            use_script = bool(self._use_script)

        payload = base64.b64encode(
            self._wrap_command(command, use_script).encode("utf-8")
        ).decode("ascii")
        script = (
            f"eval \"$(printf '%s' {payload} | base64 -d)\"; "
            f"ec=$?; "
            f"printf '%s%d\\n' '{done_marker}' \"$ec\"; "
            f"printf '%s%s\\n' '{cwd_marker}' \"$(pwd)\"\n"
        )

        self._drain_buffer()
        self._proc.stdin.write(script.encode("utf-8"))
        self._proc.stdin.flush()

        deadline = time.time() + timeout if timeout else None
        collected = ""
        emitted_upto = 0
        exit_code = 1
        new_cwd = self.cwd

        while True:
            if deadline and time.time() > deadline:
                raise TimeoutError(f"Command timed out: {command[:120]}")

            chunk = self._drain_buffer()
            if chunk:
                collected += chunk.decode("utf-8", errors="replace")

            done_idx = collected.find(done_marker)
            if done_idx != -1:
                emitted_upto = self._emit_new_bytes(
                    collected, emitted_upto, done_idx, markers, on_output
                )

                after_done = collected[done_idx + len(done_marker) :]
                line_end = after_done.find("\n")
                if line_end != -1:
                    code_str = after_done[:line_end].strip()
                    try:
                        exit_code = int(code_str)
                    except ValueError:
                        exit_code = 1

                    cwd_idx = collected.find(cwd_marker)
                    if cwd_idx != -1:
                        after_cwd = collected[cwd_idx + len(cwd_marker) :]
                        new_cwd = after_cwd.split("\n", 1)[0].strip() or new_cwd
                    break
            else:
                safe_end = max(emitted_upto, len(collected) - holdback)
                emitted_upto = self._emit_new_bytes(
                    collected, emitted_upto, safe_end, markers, on_output
                )

            if self._proc.poll() is not None:
                raise RuntimeError("WSL shell exited unexpectedly")

            time.sleep(0.01)

        self.cwd = new_cwd
        return exit_code, new_cwd


def ping_wsl(distro: str | None = None) -> str:
    cmd = ["wsl"]
    if distro:
        cmd.extend(["-d", distro])
    cmd.extend(["-e", "bash", "-lc", "echo WSL_LAYER_OK"])
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        err = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(err or "WSL ping failed")
    return result.stdout.strip()
