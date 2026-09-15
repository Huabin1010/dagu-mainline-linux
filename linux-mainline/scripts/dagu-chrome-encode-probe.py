#!/usr/bin/env python3
"""Clean-session MediaRecorder vs Venus /dev/video15. Host: --host."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
CODECS = {
    "h264": ["video/webm;codecs=h264", "video/mp4;codecs=avc1"],
    "vp8": ["video/webm;codecs=vp8"],
    "hevc": [
        'video/mp4;codecs="hvc1.1.6.L93.B0"',
        'video/mp4;codecs="hvc1.1.6.L186.B0"',
        "video/mp4;codecs=hvc1.1.6.L93.B0",
        "video/mp4;codecs=hvc1.1.6.L186.B0",
        'video/x-matroska;codecs="hvc1.1.6.L186.B0"',
        "video/x-matroska;codecs=hvc1.1.6.L186.B0",
        'video/mp4;codecs="hev1.1.6.L93.B0"',
        "video/mp4;codecs=hev1.1.6.L93.B0",
    ],
    "hevc10": [
        'video/mp4;codecs="hvc1.2.4.L93.B0"',
        'video/mp4;codecs="hvc1.2.4.L186.B0"',
        "video/mp4;codecs=hvc1.2.4.L93.B0",
        "video/mp4;codecs=hvc1.2.4.L186.B0",
        'video/mp4;codecs="hev1.2.4.L93.B0"',
        "video/mp4;codecs=hev1.2.4.L93.B0",
    ],
}


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def port_up() -> bool:
    try:
        socket.create_connection(("127.0.0.1", 9222), 0.25).close()
        return True
    except OSError:
        return False


def irq() -> int:
    try:
        for line in Path("/proc/interrupts").read_text().splitlines():
            if "venus" in line.lower() or "aa00000" in line:
                return int(line.split()[1])
    except OSError:
        pass
    return -1


def video_fds() -> list[str]:
    found: list[str] = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read()
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


def start_chrome() -> None:
    subprocess.run(["pkill", "-u", "dagu", "-f", "chrome|chromium"], check=False)
    t_down = time.time()
    while port_up() and time.time() - t_down < 15:
        time.sleep(0.2)
    time.sleep(0.5)
    profile = Path("/tmp/dagu-chrome-jank-profile")
    subprocess.run(["rm", "-rf", str(profile)], check=False)
    profile.mkdir(exist_ok=True)
    subprocess.run(["chown", "-R", "dagu:dagu", str(profile)], check=False)
    log = open("/tmp/dagu-chrome-encode-probe.log", "ab")
    subprocess.Popen([
        "sudo", "-u", "dagu", "env",
        "XDG_RUNTIME_DIR=/run/user/1001",
        "WAYLAND_DISPLAY=wayland-0",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
        "HOME=/home/dagu", "USER=dagu", "LOGNAME=dagu",
        "/usr/local/bin/dagu-chromium",
        "--user-data-dir=/tmp/dagu-chrome-jank-profile",
        "--remote-debugging-port=9222",
        "--remote-debugging-address=127.0.0.1",
        "--remote-allow-origins=*",
        "--no-first-run",
        "--hide-crash-restore-bubble",
        "--enable-logging=stderr",
        "--vmodule=*v4l2*=2,*video_encode*=2,*media_recorder*=2,*gpu_video*=2",
        "about:blank",
    ], stdout=log, stderr=log, start_new_session=True)
    t0 = time.time()
    while time.time() - t0 < 90:
        if port_up():
            return
        time.sleep(0.25)
    raise SystemExit("no CDP")


JS = r"""
(async function(){
  const wanted = "__DAGU_CODEC__";
  const types = {
    h264: ["video/webm;codecs=h264", "video/mp4;codecs=avc1"],
    vp8: ["video/webm;codecs=vp8"],
    hevc: [
      'video/mp4;codecs="hvc1.1.6.L93.B0"',
      'video/mp4;codecs="hvc1.1.6.L186.B0"',
      "video/mp4;codecs=hvc1.1.6.L93.B0",
      "video/mp4;codecs=hvc1.1.6.L186.B0",
      'video/x-matroska;codecs="hvc1.1.6.L186.B0"',
      "video/x-matroska;codecs=hvc1.1.6.L186.B0",
      'video/mp4;codecs="hev1.1.6.L93.B0"',
      "video/mp4;codecs=hev1.1.6.L93.B0"
    ],
    hevc10: [
      'video/mp4;codecs="hvc1.2.4.L93.B0"',
      'video/mp4;codecs="hvc1.2.4.L186.B0"',
      "video/mp4;codecs=hvc1.2.4.L93.B0",
      "video/mp4;codecs=hvc1.2.4.L186.B0",
      'video/mp4;codecs="hev1.2.4.L93.B0"',
      "video/mp4;codecs=hev1.2.4.L93.B0"
    ]
  }[wanted] || ["video/webm;codecs=h264"];
  const c=document.createElement("canvas");
  // Linux VideoTrackRecorder skips VEA below 640x480 (software encoder exists).
  c.width=1280; c.height=720;
  document.body.appendChild(c);
  const ctx=c.getContext("2d");
  let i=0;
  const timer=setInterval(()=>{ ctx.fillStyle="hsl("+(i*7)%360+",80%,50%)"; ctx.fillRect(0,0,1280,720); i++; }, 33);
  const stream=c.captureStream(30);
  const supported = Object.fromEntries(types.map(t=>[t, MediaRecorder.isTypeSupported(t)]));
  let mime = types.find(t => MediaRecorder.isTypeSupported(t)) || "";
  let mode = "mediarecorder";
  let error = null;
  let webcodecs = null;
  try {
    if (typeof VideoEncoder !== "undefined") {
      const cfg = {
        h264: {codec:"avc1.42001f", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"},
        vp8: {codec:"vp8", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"},
        hevc: {codec:"hvc1.1.6.L93.B0", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"}
      }[wanted];
      const info = await VideoEncoder.isConfigSupported(cfg);
      webcodecs = {supported: !!(info && info.supported), config: info && info.config};
    }
  } catch (e) { webcodecs = {error: String(e)}; }
  if (mime) {
    const rec=new MediaRecorder(stream, {mimeType:mime, videoBitsPerSecond:800000});
    rec.start(200);
    await new Promise(r=>setTimeout(r, 4000));
    rec.stop();
    await new Promise(r=>setTimeout(r, 300));
  } else if (webcodecs && webcodecs.supported) {
    mode = "webcodecs";
    const cfg = {
      h264: {codec:"avc1.42001f", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"},
      vp8: {codec:"vp8", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"},
      hevc: {codec:"hvc1.1.6.L93.B0", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"}
    }[wanted];
    let chunks = 0;
    const enc = new VideoEncoder({
      output: () => { chunks++; },
      error: (e) => { error = String(e); }
    });
    enc.configure(cfg);
    for (let n = 0; n < 120; n++) {
      const bmp = await createImageBitmap(c);
      const frame = new VideoFrame(bmp, {timestamp: n * 33333});
      enc.encode(frame, {keyFrame: n === 0});
      frame.close();
      bmp.close();
      await new Promise(r => setTimeout(r, 33));
    }
    await enc.flush();
    enc.close();
    webcodecs.chunks = chunks;
  } else {
    error = "no MediaRecorder mime and no WebCodecs hardware config";
  }
  clearInterval(timer);
  return {codec: wanted, href: location.href, hasVideoEncoder: typeof VideoEncoder, mime, mode, supported, webcodecs, error};
})()
"""


def parse_codec(argv: list[str]) -> str:
    codec = os.environ.get("DAGU_ENCODE_CODEC", "h264")
    if "--codec" in argv:
        i = argv.index("--codec")
        if i + 1 < len(argv):
            codec = argv[i + 1]
    codec = codec.lower()
    if codec not in CODECS:
        raise SystemExit(f"unknown codec {codec}; choose {sorted(CODECS)}")
    return codec


def device_main(codec: str) -> int:
    print(f"device_main codec={codec}", flush=True)
    start_chrome()
    tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
    page = next(t for t in tabs if t.get("type") == "page")
    import asyncio
    import websockets

    async def run():
        async with websockets.connect(page["webSocketDebuggerUrl"], max_size=8_000_000) as sock:
            mid = 0

            loaded = False

            async def send(meth, par=None):
                nonlocal mid, loaded
                mid += 1
                await sock.send(json.dumps({"id": mid, "method": meth, "params": par or {}}))
                while True:
                    raw = json.loads(await sock.recv())
                    if raw.get("method") == "Page.loadEventFired":
                        loaded = True
                    if raw.get("id") == mid:
                        return raw

            await send("Runtime.enable")
            await send("Page.enable")
            await send("Page.navigate", {
                "url": "data:text/html,<!doctype html><html><head><meta charset=utf-8><title>dagu-encode</title></head><body><canvas></canvas></body></html>",
            })
            t0 = time.time()
            while not loaded and time.time() - t0 < 8:
                raw = json.loads(await sock.recv())
                if raw.get("method") == "Page.loadEventFired":
                    loaded = True
            await send("Runtime.evaluate", {
                "expression": (
                    f"window.__DAGU_ENCODE_CODEC={json.dumps(codec)};"
                    "{href:location.href, videoEncoder: typeof VideoEncoder, mediaRecorder: typeof MediaRecorder}"
                ),
                "returnByValue": True,
            })
            irq0 = irq()
            seen: list[str] = []
            stop = False

            def poll():
                while not stop:
                    for x in video_fds():
                        if x not in seen:
                            seen.append(x)
                    time.sleep(0.15)

            th = __import__("threading").Thread(target=poll, daemon=True)
            th.start()
            got = await send("Runtime.evaluate", {
                "expression": JS.replace("__DAGU_CODEC__", codec),
                "awaitPromise": True, "returnByValue": True,
            })
            stop = True
            th.join(timeout=1.0)
            fds = list(dict.fromkeys(seen + video_fds()))
            return {
                "result": got.get("result", {}).get("result", {}).get("value"),
                "irq_delta": irq() - irq0 if irq0 >= 0 else None,
                "fds": fds,
                "has_video15": any(
                    x.endswith("/dev/video15") or x.endswith("/dev/video-enc0")
                    for x in fds),
            }

    report = asyncio.run(run())
    Path("/tmp/dagu-chrome-encode-probe.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report.get("has_video15") and report.get("irq_delta") else 2


def host_main(codec: str) -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    out = ROOT / "out/display-stress" / f"chrome-encode-probe-{codec}.json"
    out.unlink(missing_ok=True)
    subprocess.run(scp + [str(Path(__file__)), f"root@{HOST}:/tmp/dagu-chrome-encode-probe.py"], check=True)
    rc = subprocess.run(ssh + [
        "rm -f /tmp/dagu-chrome-encode-probe.json; "
        "install -m755 /tmp/dagu-chrome-encode-probe.py /usr/local/sbin/dagu-chrome-encode-probe.py; "
        f"DAGU_ENCODE_CODEC={codec} python3 /usr/local/sbin/dagu-chrome-encode-probe.py --codec {codec}"
    ], check=False).returncode
    out.parent.mkdir(parents=True, exist_ok=True)
    pulled = subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-chrome-encode-probe.json", str(out)], check=False)
    if pulled.returncode != 0 or not out.exists():
        print("no tablet /tmp/dagu-chrome-encode-probe.json (CDP/start failed)")
        return rc or 2
    print(out.read_text())
    print(f"pulled {out}")
    return 0 if rc == 0 else rc


if __name__ == "__main__":
    codec = parse_codec(sys.argv)
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        raise SystemExit(host_main(codec))
    raise SystemExit(device_main(codec))
