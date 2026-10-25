#!/usr/bin/env python3
"""Chromium hardware codec test on the tablet (run as root).

Plays H.264 (L5.2 4K60 and 1080p), HEVC Main / Main10 4K60, VP9 4K60 and
VP8 1080p in the dagu V4L2 Chromium, checks through the DevTools Media
domain that the platform (V4L2) decoder ran, counts presented/dropped
frames, compares a seeked frame with the ffmpeg reference, and takes a
GNOME screenshot during playback. Then WebCodecs hardware encode for
H.264, HEVC and VP8, decoded back and compared.

  dagu-chromium-codec-test [workdir]
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import websockets

HERE = Path(__file__).resolve().parent
W = Path(sys.argv[1] if len(sys.argv) > 1 else "/var/tmp/dagu-chrome-test")
PORT_HTTP = 8765
PORT_CDP = 9222
USER = "dagu"
ENV = {
    "XDG_RUNTIME_DIR": "/run/user/1001",
    "WAYLAND_DISPLAY": "wayland-0",
    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1001/bus",
    "HOME": "/home/dagu",
}
S4K = ["-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=60", "-t", "6"]
S1K = ["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30", "-t", "6"]
CLIPS = [
    # name, file, ffmpeg args, reference frame index (t = 1.008 s)
    ("H.264 High L5.2 4K60", "h264-4k60.mp4", S4K + ["-c:v", "libx264", "-preset", "superfast",
     "-profile:v", "high", "-level", "5.2", "-pix_fmt", "yuv420p", "-b:v", "50M", "-g", "60"], 60),
    ("H.264 High 1080p30", "h264-1080p.mp4", S1K + ["-c:v", "libx264", "-preset", "superfast",
     "-profile:v", "high", "-pix_fmt", "yuv420p", "-b:v", "10M", "-g", "60"], 30),
    ("HEVC Main 4K60", "hevc-4k60.mp4", S4K + ["-c:v", "libx265", "-preset", "ultrafast",
     "-pix_fmt", "yuv420p", "-b:v", "40M", "-g", "60", "-tag:v", "hvc1",
     "-x265-params", "log-level=error"], 60),
    ("HEVC Main10 4K60", "hevc10-4k60.mp4", S4K + ["-c:v", "libx265", "-preset", "ultrafast",
     "-pix_fmt", "yuv420p10le", "-b:v", "40M", "-g", "60", "-tag:v", "hvc1",
     "-x265-params", "log-level=error"], 60),
    ("VP9 4K60", "vp9-4k60.webm", S4K + ["-c:v", "libvpx-vp9", "-deadline", "realtime",
     "-cpu-used", "8", "-row-mt", "1", "-tile-columns", "2", "-b:v", "40M", "-g", "60"], 60),
    ("VP8 1080p30", "vp8-1080p.webm", S1K + ["-c:v", "libvpx", "-deadline", "realtime",
     "-cpu-used", "8", "-b:v", "10M", "-g", "60"], 30),
]
ENCODES = [
    ("WebCodecs H.264 1080p", "avc1.640028", 1920, 1080),
    ("WebCodecs H.264 4K", "avc1.640034", 3840, 2160),
    ("WebCodecs HEVC 1080p", "hvc1.1.6.L120.B0", 1920, 1080),
    ("WebCodecs HEVC 4K", "hvc1.1.6.L153.B0", 3840, 2160),
    ("WebCodecs VP8 1080p", "vp8", 1920, 1080),
]
PLATFORM_DECODERS = ("V4L2VideoDecoder", "VDAVideoDecoder", "VaapiVideoDecoder")


def sh(*a, **k):
    return subprocess.run(a, check=True, **k)


def prepare() -> None:
    W.mkdir(parents=True, exist_ok=True)
    (W / "index.html").write_bytes((HERE / "index.html").read_bytes())
    for _, f, args, idx in CLIPS:
        if not (W / f).exists():
            sh("ffmpeg", "-nostdin", "-y", "-v", "error", *args, str(W / f))
        ref = W / (f + ".ref.png")
        if not ref.exists():
            sh("ffmpeg", "-nostdin", "-y", "-v", "error", "-i", str(W / f),
               "-vf", f"select=eq(n\\,{idx})", "-frames:v", "1", str(ref))
    os.system(f"chown -R {USER}:{USER} {W}")


def as_user(cmd: list[str], **k) -> subprocess.Popen:
    env = " ".join(f"{a}={b}" for a, b in ENV.items())
    return subprocess.Popen(["sudo", "-u", USER, "env", *env.split(), *cmd], **k)


def screenshot(path: Path) -> None:
    subprocess.run(["/usr/local/sbin/dagu-gnome-screenshot.sh", "--local", str(path)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)


class Cdp:
    def __init__(self, ws):
        self.ws = ws
        self.n = 0
        self.pending: dict[int, asyncio.Future] = {}
        self.players: dict[str, dict] = {}
        self.order: list[str] = []
        self.task = asyncio.create_task(self.reader())

    async def reader(self):
        async for raw in self.ws:
            m = json.loads(raw)
            if "id" in m and m["id"] in self.pending:
                self.pending.pop(m["id"]).set_result(m)
            elif m.get("method") == "Media.playerPropertiesChanged":
                pid = m["params"]["playerId"]
                if pid not in self.players:
                    self.players[pid] = {}
                    self.order.append(pid)
                for p in m["params"]["properties"]:
                    self.players[pid][p["name"]] = p["value"]
            elif m.get("method") == "Media.playersCreated":
                for pid in m["params"]["players"]:
                    if isinstance(pid, dict):
                        pid = pid.get("playerId")
                    if pid not in self.players:
                        self.players[pid] = {}
                        self.order.append(pid)

    async def call(self, method, **params):
        self.n += 1
        fut = asyncio.get_running_loop().create_future()
        self.pending[self.n] = fut
        await self.ws.send(json.dumps({"id": self.n, "method": method, "params": params}))
        m = await asyncio.wait_for(fut, 120)
        if "error" in m:
            raise RuntimeError(f"{method}: {m['error']}")
        return m["result"]

    async def js(self, expr):
        r = await self.call("Runtime.evaluate", expression=expr, awaitPromise=True,
                            returnByValue=True)
        if "exceptionDetails" in r:
            raise RuntimeError(r["exceptionDetails"])
        return r["result"].get("value")


async def print_gpu() -> None:
    """SystemInfo is only served on the browser target, not on a page."""
    ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT_CDP}/json/version"))
    print(f"Browser: {ver.get('Browser', '?')}")
    async with websockets.connect(ver["webSocketDebuggerUrl"], max_size=None) as ws:
        b = Cdp(ws)
        try:
            info = (await b.call("SystemInfo.getInfo")).get("gpu", {})
        finally:
            b.task.cancel()
    dev = (info.get("devices") or [{}])[0]
    feats = info.get("featureStatus", {})
    print(f"GPU: {dev.get('vendorString', '')} {dev.get('deviceString', '?')}; "
          f"video_decode={feats.get('video_decode', '?')} "
          f"video_encode={feats.get('video_encode', '?')} "
          f"gpu_compositing={feats.get('gpu_compositing', '?')}", flush=True)


async def main() -> int:
    prepare()
    http = as_user(["python3", str(HERE / "serve.py"), str(PORT_HTTP), str(W)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    prof = "/tmp/dagu-cdp-profile"
    subprocess.run(["rm", "-rf", prof])
    chrome = as_user(["/usr/local/bin/dagu-chromium", f"--remote-debugging-port={PORT_CDP}",
                      f"--user-data-dir={prof}", "--no-first-run", "--no-default-browser-check",
                      "--autoplay-policy=no-user-gesture-required", "--disable-session-crashed-bubble",
                      f"http://127.0.0.1:{PORT_HTTP}/index.html"],
                     stdout=subprocess.DEVNULL, stderr=open(W / "chrome.log", "w"))
    fails = 0
    try:
        ws_url = None
        for _ in range(60):
            try:
                tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT_CDP}/json"))
                pages = [t for t in tabs if t.get("type") == "page" and "index.html" in t.get("url", "")]
                if pages:
                    ws_url = pages[0]["webSocketDebuggerUrl"]
                    break
            except OSError:
                pass
            time.sleep(0.5)
        if not ws_url:
            print("FAIL Chromium DevTools page did not come up")
            return 1
        async with websockets.connect(ws_url, max_size=None) as ws:
            cdp = Cdp(ws)
            await cdp.call("Runtime.enable")
            await cdp.call("Media.enable")
            for _ in range(40):
                if await cdp.js("window.ready === true"):
                    break
                await asyncio.sleep(0.25)
            await print_gpu()
            for name, f, _, idx in CLIPS:
                before = len(cdp.order)
                job = asyncio.create_task(cdp.js(
                    f"playTest({json.dumps(f)}, {json.dumps(f + '.ref.png')}, 1.008, 4500, 2500)"))
                # The screenshot stalls the compositor, so take it in the
                # hold after the measured window, while the clip still plays.
                for _ in range(300):
                    if job.done() or await cdp.js("window.stage") == "screenshot":
                        break
                    await asyncio.sleep(0.1)
                shot = W / (f + ".screen.png")
                if not job.done():
                    await asyncio.to_thread(screenshot, shot)
                res = await job
                await asyncio.sleep(0.5)
                props = cdp.players[cdp.order[-1]] if len(cdp.order) > before else {}
                decoder = props.get("kVideoDecoderName", "?")
                platform = props.get("kIsPlatformVideoDecoder")
                hw = decoder in PLATFORM_DECODERS or platform in (True, "true")
                # Steady playback (from 1 s in): at most 1% dropped and
                # 95% of the clip rate. The first second is reported apart.
                good = ("error" not in res and hw and res.get("psnr", 0) >= 30 and
                        res.get("dropped", 1) * 100 <= max(100, res.get("presented", 0) + 99) and
                        res.get("fps", 0) >= 0.95 * idx and
                        res.get("startupMs", 9999) <= 1000)
                msg = (f"{name}: decoder={decoder} platform={platform} "
                       f"{res.get('width')}x{res.get('height')} presented={res.get('presented')} "
                       f"dropped={res.get('dropped')} fps={res.get('fps', 0):.1f} "
                       f"startup={res.get('startupMs')}ms/{res.get('startupDropped')}dropped "
                       f"psnr={res.get('psnr', 0):.1f} dB screen={shot.name}"
                       + (f" error={res['error']}" if "error" in res else ""))
                print(("PASS " if good else "FAIL ") + msg, flush=True)
                fails += not good
            for name, codec, w, h in ENCODES:
                ref = "h264-4k60.mp4.ref.png" if w > 1920 else "h264-1080p.mp4.ref.png"
                res = await cdp.js(f"encTest({json.dumps(codec)}, {w}, {h}, {json.dumps(ref)})")
                good = (res.get("supported") and "error" not in res and
                        res.get("chunks") == 60 and res.get("decoded") == 60 and
                        res.get("psnr", 0) >= 30)
                msg = (f"{name} ({codec}): supported={res.get('supported')} "
                       f"chunks={res.get('chunks')} decoded={res.get('decoded')} "
                       f"encode={res.get('encodeFps', 0):.0f} fps psnr={res.get('psnr', 0):.1f} dB"
                       + (f" error={res.get('error') or res.get('decodeError')}"
                          if res.get("error") or res.get("decodeError") else ""))
                print(("PASS " if good else "FAIL ") + msg, flush=True)
                fails += not good
            total = len(CLIPS) + len(ENCODES)
            await cdp.js(f"done({json.dumps(f'{total - fails}/{total} 通过')})")
            await asyncio.sleep(3)
            cdp.task.cancel()
    finally:
        chrome.terminate()
        http.terminate()
        time.sleep(1)
        subprocess.run(["pkill", "-u", USER, "-f", "--", f"user-data-dir={prof}"])
    total = len(CLIPS) + len(ENCODES)
    print(f"chromium codec test: {total - fails} passed, {fails} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
