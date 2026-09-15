#!/usr/bin/env python3
"""Play a local clip in Chrome and dump droppedVideoFrames.

On the tablet (root):  python3 /usr/local/sbin/dagu-video-jank.py
From the host:         python3 linux-mainline/scripts/dagu-video-jank.py --host
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
OUT_HOST = ROOT / "out/display-stress"
PORT = 8766
CDP = 9222
CLIP = Path("/tmp/dagu-video-jank-1080p.mp4")
CODECS = {
    "h264": {
        "path": Path("/tmp/dagu-video-jank-1080p.mp4"),
        "ffmpeg": ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"],
        "name": "h264",
    },
    "hevc": {
        "path": Path("/tmp/dagu-video-jank-1080p-hevc.mp4"),
        "ffmpeg": ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                   "-tag:v", "hvc1", "-x265-params", "log-level=error"],
        "name": "hevc",
    },
    "vp9": {
        "path": Path("/tmp/dagu-video-jank-1080p-vp9.webm"),
        "ffmpeg": ["-c:v", "libvpx-vp9", "-b:v", "2M", "-pix_fmt", "yuv420p",
                   "-deadline", "realtime", "-cpu-used", "8"],
        "name": "vp9",
    },
    "vp8": {
        "path": Path("/tmp/dagu-video-jank-1080p-vp8.webm"),
        "ffmpeg": ["-c:v", "libvpx", "-b:v", "2M", "-pix_fmt", "yuv420p",
                   "-deadline", "realtime", "-cpu-used", "8"],
        "name": "vp8",
    },
    "hevc10": {
        "path": Path("/tmp/dagu-video-jank-1080p-hevc10.mp4"),
        "ffmpeg": ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le",
                   "-profile:v", "main10", "-tag:v", "hvc1",
                   "-x265-params", "log-level=error"],
        "name": "hevc10",
    },
    "vp9p2": {
        "path": Path("/tmp/dagu-video-jank-1080p-vp9p2.webm"),
        "ffmpeg": ["-c:v", "libvpx-vp9", "-b:v", "2M", "-pix_fmt", "yuv420p10le",
                   "-profile:v", "2", "-deadline", "realtime", "-cpu-used", "8"],
        "name": "vp9p2",
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


def port_up(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), 0.25):
            return True
    except OSError:
        return False


def clip_for(codec: str) -> Path:
    spec = CODECS.get(codec, CODECS["h264"])
    return spec["path"]


def ensure_clip(codec: str = "h264") -> Path:
    spec = CODECS.get(codec)
    if not spec:
        raise SystemExit(f"unknown codec {codec}")
    dest = spec["path"]
    if dest.exists() and dest.stat().st_size > 20000:
        return dest
    cmd = [
        "ffmpeg", "-y", "-f", "lavfi",
        "-i", "testsrc=duration=12:size=1920x1080:rate=30",
        *spec["ffmpeg"],
        str(dest),
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return dest


def start_http(docroot: Path) -> ThreadingHTTPServer:
    class H(SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=str(docroot), **k)

        def log_message(self, *_a):
            return

        def do_GET(self):
            if self.path.startswith("/clip."):
                name = Path(self.path.split("?", 1)[0]).name
                if not (docroot / name).exists():
                    src = clip_for(os.environ.get("DAGU_VIDEO_CODEC", "h264"))
                    try:
                        os.symlink(str(src), str(docroot / name))
                    except FileExistsError:
                        pass
                    self.path = "/" + name
                else:
                    self.path = "/" + name
            return super().do_GET()

    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def start_chrome(url: str, overlay: bool = False) -> None:
    subprocess.run(["pkill", "-u", "dagu", "-f", "chrome|chromium"], check=False)
    t_down = time.time()
    while port_up("127.0.0.1", CDP) and time.time() - t_down < 15:
        time.sleep(0.2)
    time.sleep(0.5)
    for base in ("/home/dagu/.config/google-chrome", "/home/dagu/.config/chromium"):
        for name in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
            try:
                Path(f"{base}/{name}").unlink()
            except FileNotFoundError:
                pass
    profile = Path("/tmp/dagu-chrome-jank-profile")
    subprocess.run(["rm", "-rf", str(profile)], check=False)
    profile.mkdir(exist_ok=True)
    subprocess.run(["chown", "-R", "dagu:dagu", str(profile)], check=False)
    log = open("/tmp/dagu-video-jank-chrome.log", "ab")
    env = [
        "sudo", "-u", "dagu", "env",
        "XDG_RUNTIME_DIR=/run/user/1001",
        "WAYLAND_DISPLAY=wayland-0",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
        "HOME=/home/dagu", "USER=dagu", "LOGNAME=dagu",
    ]
    if overlay:
        env.append("DAGU_CHROME_VIDEO_OVERLAY=1")
    subprocess.Popen(env + [
        os.environ.get("DAGU_CHROME_BIN", "/usr/local/bin/dagu-chromium"),
        "--user-data-dir=/tmp/dagu-chrome-jank-profile",
        "--remote-debugging-port=9222",
        "--remote-debugging-address=127.0.0.1",
        "--remote-allow-origins=*",
        "--no-first-run",
        "--autoplay-policy=no-user-gesture-required",
        "--hide-crash-restore-bubble",
        "--enable-logging=stderr",
        "--vmodule=*/media/gpu*=2,*/media/mojo*=1",
        "--new-window", url,
    ], stdout=log, stderr=log, start_new_session=True)
    t0 = time.time()
    while time.time() - t0 < 90:
        if port_up("127.0.0.1", CDP):
            return
        time.sleep(0.25)
    raise SystemExit("no CDP")


def cdp_tabs() -> list:
    with urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5) as r:
        return json.load(r)


async def cdp_call(ws, method=None, params=None, expr=None):
    import websockets
    async with websockets.connect(
            ws, max_size=20_000_000, open_timeout=10, close_timeout=5) as sock:
        mid = 0

        async def send(meth, par=None):
            nonlocal mid
            mid += 1
            msg = {"id": mid, "method": meth}
            if par:
                msg["params"] = par
            await sock.send(json.dumps(msg))
            while True:
                raw = json.loads(await asyncio.wait_for(sock.recv(), 20))
                if raw.get("id") == mid:
                    return raw

        await send("Runtime.enable")
        await send("Page.enable")
        if method == "Page.navigate":
            got = await send(method, params)
            await asyncio.sleep(1.5)
            return got
        got = await send("Runtime.evaluate", {
            "expression": expr,
            "returnByValue": True,
            "awaitPromise": True,
        })
        return got.get("result", {}).get("result", {}).get("value")


def venus_fds() -> list[str]:
    found: list[str] = []
    try:
        pids = os.listdir("/proc")
    except OSError:
        return found
    for pid in pids:
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read()
        except OSError:
            continue
        if b"chromium" not in cmd and b"/opt/google/chrome/chrome" not in cmd:
            continue
        try:
            fds = os.listdir(f"/proc/{pid}/fd")
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(f"/proc/{pid}/fd/{fd}")
            except OSError:
                continue
            if target.startswith("/dev/video"):
                found.append(f"{pid}:{target}")
    return found


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


def read_int(path: str) -> int:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return -1


def device_main(args) -> int:
    subprocess.run(["/usr/local/sbin/dagu-venus-load.sh"], check=False)
    os.environ["DAGU_VIDEO_CODEC"] = args.codec
    clip = ensure_clip(args.codec)
    docroot = Path("/usr/local/share/dagu-video-jank")
    docroot.mkdir(parents=True, exist_ok=True)
    src_html = Path("/usr/local/share/dagu-video-jank/dagu-video-jank.html")
    if not src_html.exists():
        here = Path(__file__).resolve().parent / "dagu-video-jank.html"
        if here.exists():
            src_html.write_bytes(here.read_bytes())
    href = "/clip.mp4" if clip.suffix == ".mp4" else "/clip.webm"
    try:
        dest = docroot / Path(href).name
        if dest.exists() or dest.is_symlink():
            dest.unlink()
        dest.symlink_to(clip)
    except OSError:
        pass
    httpd = start_http(docroot)
    url = f"http://127.0.0.1:{PORT}/dagu-video-jank.html?src={href}&quiet=1"
    if args.fresh or not port_up("127.0.0.1", CDP):
        start_chrome(url, overlay=args.overlay)
    else:
        print("attach CDP", file=sys.stderr)
    tabs = []
    for _ in range(20):
        try:
            tabs = [t for t in cdp_tabs() if t.get("type") == "page"]
            if tabs:
                break
        except Exception:
            time.sleep(0.3)
    if not tabs:
        raise SystemExit("no page")
    page = tabs[0]
    ws = page["webSocketDebuggerUrl"]
    asyncio.run(cdp_call(ws, method="Page.navigate", params={"url": url}))
    time.sleep(1.0)
    tabs = [t for t in cdp_tabs() if t.get("type") == "page"]
    page = next((t for t in tabs if "video-jank" in t.get("url", "")), tabs[0])
    ws = page["webSocketDebuggerUrl"]
    asyncio.run(cdp_call(ws, expr="window.__VIDEO_RESET__ && window.__VIDEO_RESET__()"))
    time.sleep(0.4)
    irq0 = venus_irq()
    t0 = time.monotonic()
    busy = []
    gpu_min = []
    gpu_cur = []
    seen_fds: list[str] = []
    while time.monotonic() - t0 < args.hold:
        busy.append(read_int("/sys/class/drm/card0/device/gpu_busy_percent"))
        gpu_min.append(read_int("/sys/class/devfreq/3d00000.gpu/min_freq"))
        gpu_cur.append(read_int("/sys/class/devfreq/3d00000.gpu/cur_freq"))
        for x in venus_fds():
            if x not in seen_fds:
                seen_fds.append(x)
        time.sleep(0.05)
    cpu_mins = {
        "policy0": read_int("/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq"),
        "policy4": read_int("/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq"),
        "policy7": read_int("/sys/devices/system/cpu/cpufreq/policy7/scaling_min_freq"),
        "policy4_cur": read_int("/sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq"),
    }
    try:
        dump = asyncio.run(cdp_call(
            ws, expr="window.__VIDEO_DUMP__ && window.__VIDEO_DUMP__()"))
    except Exception as exc:
        dump = {"error": str(exc)}
    irq1 = venus_irq()
    decoder = None
    try:
        decoder = asyncio.run(cdp_call(ws, expr="""
          (function(){
            const p = performance.getEntriesByType && [];
            return {
              video: document.querySelector('video') && {
                w: document.querySelector('video').videoWidth,
                h: document.querySelector('video').videoHeight
              }
            };
          })()
        """))
    except Exception:
        decoder = None
    flags = []
    try:
        pid = ""
        for pat in ("/usr/lib/chromium/chromium --ozone",
                    "/opt/google/chrome/chrome --ozone"):
            try:
                pid = subprocess.check_output(
                    ["pgrep", "-n", "-u", "dagu", "-f", pat], text=True).strip()
                if pid:
                    break
            except subprocess.CalledProcessError:
                continue
        if not pid:
            raise RuntimeError("no browser pid")
        flags = [x.decode() for x in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if x]
    except Exception:
        flags = []
    decoder_log = []
    try:
        log = Path("/tmp/dagu-video-jank-chrome.log").read_text(errors="ignore")
        for line in log.splitlines():
            if "Initialized VideoDecoder" in line or "FFmpegVideoDecoder" in line \
                    or "VaapiVideoDecoder" in line or "V4L2VideoDecoder" in line \
                    or "V4L2StatefulVideoDecoder" in line \
                    or "v4l2_stateful_video_decoder.cc" in line \
                    or "Chosen |CAPTURE_queue_| format" in line \
                    or "Using a stateful API" in line:
                decoder_log.append(line[-180:])
    except OSError:
        pass
    fds = list(dict.fromkeys(seen_fds + venus_fds()))
    report = {
        "codec": args.codec,
        "clip": str(clip),
        "url": url,
        "page": dump,
        "gpu_busy_avg": round(sum(x for x in busy if x >= 0) / max(1, sum(1 for x in busy if x >= 0)), 1),
        "gpu_busy_max": max(busy) if busy else None,
        "gpu_min_mhz": sorted({x // 1000000 for x in gpu_min if x > 0}),
        "gpu_cur_mhz_max": max((x // 1000000 for x in gpu_cur if x > 0), default=None),
        "cpu_mins": cpu_mins,
        "venus_irq_delta": (irq1 - irq0) if (irq0 >= 0 and irq1 >= irq0) else None,
        "video14": any(
            x.endswith("/dev/video14") or x.endswith("/dev/video-dec0")
            for x in fds
        ),
        "venus_fds": fds,
        "chrome_features": [f for f in flags if "feature" in f or "angle" in f or "gpu" in f],
        "decoder_hint": decoder,
        "decoder_log": decoder_log[-8:],
    }
    Path("/tmp/dagu-video-jank.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    httpd.shutdown()
    return 0


def host_main(args) -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    clip = CODECS[args.codec]["path"]
    if clip.exists() and clip.stat().st_size > 20000:
        subprocess.run(scp + [str(clip), f"root@{HOST}:{clip}"], check=True)
    subprocess.run(scp + [
        str(ROOT / "scripts/dagu-video-jank.py"),
        str(ROOT / "scripts/dagu-video-jank.html"),
        str(ROOT / "scripts/dagu-venus-load.sh"),
        f"root@{HOST}:/tmp/",
    ], check=True)
    remote = (
        "install -m755 /tmp/dagu-video-jank.py /usr/local/sbin/dagu-video-jank.py; "
        "install -m755 /tmp/dagu-venus-load.sh /usr/local/sbin/dagu-venus-load.sh; "
        "mkdir -p /usr/local/share/dagu-video-jank; "
        "install -m644 /tmp/dagu-video-jank.html /usr/local/share/dagu-video-jank/; "
        f"python3 /usr/local/sbin/dagu-video-jank.py --hold {args.hold} --codec {args.codec}"
        + (" --fresh" if args.fresh else "")
        + (" --overlay" if args.overlay else "")
    )
    dest = OUT_HOST / f"video-jank-{args.codec}.json"
    dest.unlink(missing_ok=True)
    rc = subprocess.run(ssh + [
        "rm -f /tmp/dagu-video-jank.json; " + remote
    ], check=False).returncode
    OUT_HOST.mkdir(parents=True, exist_ok=True)
    pulled = subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-video-jank.json", str(dest)], check=False)
    if pulled.returncode != 0 or not dest.exists():
        print("no tablet /tmp/dagu-video-jank.json (CDP/start failed)")
        return rc or 2
    print(dest.read_text())
    print(f"pulled {dest}")
    return 0 if rc == 0 else rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", action="store_true")
    ap.add_argument("--hold", type=float, default=10.0)
    ap.add_argument("--fresh", action="store_true",
                    help="always kill Chrome and start a new debug session")
    ap.add_argument("--overlay", action="store_true",
                    help="DAGU_CHROME_VIDEO_OVERLAY=1 (WaylandOverlayDelegation)")
    ap.add_argument("--codec", choices=sorted(CODECS), default="h264")
    args = ap.parse_args()
    if args.host or not is_tablet():
        return host_main(args)
    return device_main(args)


if __name__ == "__main__":
    raise SystemExit(main())
