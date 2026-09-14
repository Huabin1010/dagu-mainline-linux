#!/usr/bin/env python3
"""Local dagu compositor/Venus lab. Replaces Bilibili homepage for jank.

On tablet: python3 /usr/local/sbin/dagu-pipeline-lab.py --serve
From host: python3 linux-mainline/scripts/dagu-pipeline-lab.py --host
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.1.158")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
PORT = int(os.environ.get("DAGU_LAB_PORT", "8770"))
SHARE = Path("/usr/local/share/dagu-pipeline-lab")
# Persistent clips (root is 100G+). /tmp is tmpfs and dies on reboot.
CLIPDIR = Path(os.environ.get("DAGU_LAB_CLIPS", "/var/lib/dagu-pipeline-lab"))
LAST_DUMP: dict = {}
DUMP_LOCK = threading.Lock()

H264 = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-tune", "animation", "-g", "30", "-movflags", "+faststart"]
HEVC = ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
        "-tag:v", "hvc1", "-x265-params", "log-level=error", "-movflags", "+faststart"]
VP9 = ["-c:v", "libvpx-vp9", "-b:v", "3M", "-pix_fmt", "yuv420p",
       "-deadline", "realtime", "-cpu-used", "8"]

# High-motion sources. Do not use still colorbars / slow testsrc2.
CLIPS = {
    "lab-chaos-1080.mp4": {
        "inputs": [
            "mandelbrot=s=1920x1080:r=60:maxiter=80",
            "ball=s=1920x1080:r=60",
        ],
        "filter": "[0][1]blend=all_mode=addition:shortest=1,hue=h=t*90:s=1.6,eq=contrast=1.45:saturation=1.7",
        "t": 12,
        "enc": H264,
        "fallback": "testsrc2=s=1920x1080:r=60,scroll=horizontal=0.04:vertical=0.03,hue=h=t*70,eq=contrast=1.5",
    },
    "lab-swarm-720.mp4": {
        "inputs": ["ball=s=1280x720:r=60"],
        "filter": "[0]hue=h=t*120:s=1.8,eq=contrast=1.5:saturation=1.8,unsharp=5:5:1.2",
        "t": 12,
        "enc": H264,
        "fallback": "life=s=1280x720:r=60:ratio=0.2,hue=h=t*50,eq=contrast=1.6",
    },
    "lab-scroll-720.mp4": {
        "inputs": ["testsrc2=s=1280x720:r=60"],
        "filter": "[0]scroll=horizontal=0.06:vertical=0.04,hue=h=t*55,eq=contrast=1.4:saturation=1.5",
        "t": 12,
        "enc": H264,
        "fallback": "rgbtestsrc=s=1280x720:r=60,scroll=horizontal=0.08:vertical=0.05",
    },
    "lab-hevc-720.mp4": {
        "inputs": [
            "mandelbrot=s=1280x720:r=60:maxiter=64",
            "ball=s=1280x720:r=60",
        ],
        "filter": "[0][1]blend=all_mode=screen:shortest=1,hue=h=t*70:s=1.4",
        "t": 10,
        "enc": HEVC,
        "fallback": "testsrc2=s=1280x720:r=60,scroll=horizontal=0.05:vertical=0.04,hue=h=t*40",
    },
    "lab-vp9-720.webm": {
        "inputs": ["life=s=1280x720:r=60:ratio=0.18:mold=0"],
        "filter": "[0]hue=h=t*100,eq=contrast=1.55:saturation=2",
        "t": 10,
        "enc": VP9,
        "fallback": "testsrc2=s=1280x720:r=60,scroll=horizontal=0.07:vertical=0.03",
    },
}


def is_tablet() -> bool:
    return Path("/sys/class/drm/card0-DSI-1").exists()


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def port_up(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), 0.25):
            return True
    except OSError:
        return False


def read_int(path: str) -> int:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return -1


def venus_irq() -> int:
    try:
        for line in Path("/proc/interrupts").read_text().splitlines():
            if "venus" not in line.lower() and "aa00000" not in line:
                continue
            total = 0
            for tok in line.split()[1:]:
                if tok.isdigit():
                    total += int(tok)
                else:
                    break
            return total
    except OSError:
        pass
    return -1


def vblank_fps() -> float | None:
    p = Path("/sys/kernel/debug/dri/0/crtc-0/status")
    if not p.exists():
        return None
    try:
        for line in p.read_text(errors="replace").splitlines():
            if "vblank" in line:
                for tok in line.split():
                    if tok.startswith("fps:"):
                        return float(tok.split(":", 1)[1])
    except (OSError, ValueError):
        return None
    return None


def _ffmpeg(cmd: list[str]) -> bool:
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def ensure_clip(name: str) -> Path:
    spec = CLIPS[name]
    CLIPDIR.mkdir(parents=True, exist_ok=True)
    dest = CLIPDIR / name
    if dest.exists() and dest.stat().st_size > 40000:
        return dest
    cmd = ["ffmpeg", "-y"]
    for src in spec["inputs"]:
        cmd += ["-f", "lavfi", "-i", src]
    cmd += ["-filter_complex", spec["filter"], "-t", str(spec["t"]), *spec["enc"], str(dest)]
    if not _ffmpeg(cmd):
        fb = spec.get("fallback")
        cmd = ["ffmpeg", "-y", "-f", "lavfi", "-i", fb,
               "-t", str(spec["t"]), *spec["enc"], str(dest)]
        if not _ffmpeg(cmd):
            raise RuntimeError(f"ffmpeg failed for {name}")
    return dest


def ensure_all_clips() -> None:
    SHARE.mkdir(parents=True, exist_ok=True)
    here = Path(__file__).resolve().parent
    for name in ("dagu-pipeline-lab.html", "dagu-pipeline-tab.html"):
        src = here / name
        if src.exists():
            (SHARE / name).write_bytes(src.read_bytes())
    for name in CLIPS:
        clip = ensure_clip(name)
        link = SHARE / name
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(clip)


def meminfo() -> dict:
    out = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, _, rest = line.partition(":")
            tok = rest.split()
            if tok and tok[0].isdigit():
                out[k] = int(tok[0])
    except OSError:
        pass
    avail = out.get("MemAvailable", 0) // 1024
    if avail < 400:
        pressure = "abort"
    elif avail < 800:
        pressure = "warn"
    else:
        pressure = "ok"
    return {
        "mem_avail_mb": avail,
        "mem_free_mb": out.get("MemFree", 0) // 1024,
        "swap_free_mb": out.get("SwapFree", 0) // 1024,
        "shmem_mb": out.get("Shmem", 0) // 1024,
        "pressure": pressure,
    }


def chrome_rss_mb() -> int:
    total = 0
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cmd = (proc / "cmdline").read_bytes()
        except OSError:
            continue
        if b"chromium" not in cmd:
            continue
        try:
            rss_pages = int((proc / "statm").read_text().split()[1])
        except (OSError, IndexError, ValueError):
            continue
        total += rss_pages * 4096
    return total // (1024 * 1024)


def video14_open() -> int:
    n = 0
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cmd = (proc / "cmdline").read_bytes()
        except OSError:
            continue
        if b"chromium" not in cmd:
            continue
        fd = proc / "fd"
        try:
            for e in fd.iterdir():
                try:
                    if os.readlink(e) == "/dev/video14":
                        n += 1
                except OSError:
                    pass
        except OSError:
            pass
    return n


def stats() -> dict:
    s = {
        "gpu_busy": read_int("/sys/class/drm/card0/device/gpu_busy_percent"),
        "gpu_hz": read_int("/sys/class/devfreq/3d00000.gpu/cur_freq"),
        "venus_irq": venus_irq(),
        "vblank_fps": vblank_fps(),
        "video14": Path("/dev/video14").exists(),
        "video15": Path("/dev/video15").exists(),
        "video14_open": video14_open(),
        "chrome_rss_mb": chrome_rss_mb(),
        "t": time.monotonic(),
    }
    s.update(meminfo())
    return s


def start_http() -> ThreadingHTTPServer:
    class H(SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=str(SHARE), **k)

        def log_message(self, *_a):
            return

        def _json(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == "/api/stats":
                self._json(stats())
                return
            if path == "/api/dump":
                with DUMP_LOCK:
                    payload = dict(LAST_DUMP)
                host = stats()
                if payload:
                    payload["hw"] = {**payload.get("hw", {}), **host}
                    payload["host"] = host
                else:
                    payload = {"empty": True, "host": host, "hw": host}
                self._json(payload)
                return
            if path in ("/", "/index.html"):
                self.path = "/dagu-pipeline-tab.html"
            return SimpleHTTPRequestHandler.do_GET(self)

        def do_POST(self):
            path = urlparse(self.path).path
            if path != "/api/dump":
                self.send_error(404)
                return
            n = int(self.headers.get("Content-Length", "0") or 0)
            raw = self.rfile.read(max(0, min(n, 1 << 20)))
            try:
                data = json.loads(raw.decode() or "{}")
            except json.JSONDecodeError:
                self._json({"ok": False}, 400)
                return
            data["recv_t"] = time.monotonic()
            with DUMP_LOCK:
                LAST_DUMP.clear()
                LAST_DUMP.update(data)
            self._json({"ok": True})

    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def launch_chrome() -> None:
    # Single clean profile only. Never the session-restore / Bilibili profile.
    url = os.environ.get(
        "DAGU_LAB_URL",
        f"http://127.0.0.1:{PORT}/dagu-pipeline-tab.html",
    )
    profile = "/tmp/dagu-lab-profile"
    subprocess.run(["install", "-d", "-o", "dagu", "-g", "dagu", profile], check=False)
    env = {
        "XDG_RUNTIME_DIR": "/run/user/1001",
        "WAYLAND_DISPLAY": "wayland-0",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1001/bus",
        "HOME": "/home/dagu",
        "LANG": "zh_CN.UTF-8",
    }
    subprocess.Popen(
        ["sudo", "-u", "dagu", "env", *[f"{k}={v}" for k, v in env.items()],
         "/usr/local/bin/dagu-chromium",
         f"--user-data-dir={profile}",
         "--no-first-run",
         "--start-maximized",
         "--lang=zh-CN", url],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    print(url, "profile", profile)


def serve(launch: bool) -> int:
    subprocess.run(["/usr/local/sbin/dagu-venus-load.sh"], check=False)
    ensure_all_clips()
    if not port_up(PORT):
        start_http()
    print(f"http://127.0.0.1:{PORT}/dagu-pipeline-tab.html", flush=True)
    if launch:
        launch_chrome()
    if "--once" in sys.argv:
        return 0
    while True:
        time.sleep(60)


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    subprocess.run(scp + [
        str(ROOT / "scripts/dagu-pipeline-lab.py"),
        str(ROOT / "scripts/dagu-pipeline-lab.html"),
        str(ROOT / "scripts/dagu-pipeline-tab.html"),
        f"root@{HOST}:/tmp/",
    ], check=True)
    subprocess.run(ssh + [
        "install -m755 /tmp/dagu-pipeline-lab.py /usr/local/sbin/dagu-pipeline-lab.py; "
        "mkdir -p /usr/local/share/dagu-pipeline-lab; "
        "install -m644 /tmp/dagu-pipeline-lab.html /usr/local/share/dagu-pipeline-lab/; "
        "install -m644 /tmp/dagu-pipeline-tab.html /usr/local/share/dagu-pipeline-lab/; "
        "pkill -f '/usr/local/sbin/dagu-pipeline-lab.py' || true; "
        "nohup python3 /usr/local/sbin/dagu-pipeline-lab.py --serve "
        ">/tmp/dagu-pipeline-lab.log 2>&1 &"
    ], check=False)
    return 0


def main() -> int:
    if "--host" in sys.argv:
        return host_main()
    if "--serve" in sys.argv:
        return serve(launch="--launch" in sys.argv)
    if is_tablet():
        return serve(launch=True)
    return host_main()


if __name__ == "__main__":
    raise SystemExit(main())
