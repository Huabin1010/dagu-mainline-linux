#!/usr/bin/env python3
"""Dump chrome://gpu feature status + Video Acceleration tables via CDP."""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
OUT_TXT = ROOT / "out/display-stress/chrome-gpu.txt"
OUT_JSON = ROOT / "out/display-stress/chrome-gpu.json"

EXTRACT_JS = r"""
(function(){
  function walk(n, d) {
    if (!n || d > 14) return "";
    if (n.classList && n.classList.contains && n.classList.contains('copy')) {
      n.style.display = 'inline';
    }
    let t = "";
    if (n.nodeType === 3) t += n.textContent || "";
    if (n.shadowRoot) t += walk(n.shadowRoot, d + 1);
    const kids = n.childNodes || [];
    for (let i = 0; i < kids.length; i++) t += walk(kids[i], d + 1);
    return t;
  }
  const iv = document.querySelector('info-view') || document.documentElement;
  const text = walk(iv, 0);
  return text.length ? text : "empty";
})()
"""


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


def start_chrome() -> None:
    subprocess.run(["pkill", "-u", "dagu", "-f", "chrome|chromium"], check=False)
    t_down = time.time()
    while port_up("127.0.0.1", 9222) and time.time() - t_down < 15:
        time.sleep(0.2)
    time.sleep(0.5)
    profile = Path("/tmp/dagu-chrome-jank-profile")
    subprocess.run(["rm", "-rf", str(profile)], check=False)
    profile.mkdir(exist_ok=True)
    subprocess.run(["chown", "-R", "dagu:dagu", str(profile)], check=False)
    log = open("/tmp/dagu-chrome-gpu-dump.log", "ab")
    env = [
        "sudo", "-u", "dagu", "env",
        "XDG_RUNTIME_DIR=/run/user/1001",
        "WAYLAND_DISPLAY=wayland-0",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
        "HOME=/home/dagu", "USER=dagu", "LOGNAME=dagu",
        f"DAGU_CHROME_VULKAN={os.environ.get('DAGU_CHROME_VULKAN', '0')}",
        f"DAGU_CHROME_GRAPHITE={os.environ.get('DAGU_CHROME_GRAPHITE', '0')}",
    ]
    subprocess.Popen(env + [
        os.environ.get("DAGU_CHROME_BIN", "/usr/local/bin/dagu-chromium"),
        "--user-data-dir=/tmp/dagu-chrome-jank-profile",
        "--remote-debugging-port=9222",
        "--remote-debugging-address=127.0.0.1",
        "--remote-allow-origins=*",
        "--no-first-run",
        "--hide-crash-restore-bubble",
        "chrome://gpu",
    ], stdout=log, stderr=log, start_new_session=True)
    t0 = time.time()
    while time.time() - t0 < 90:
        if port_up("127.0.0.1", 9222):
            return
        time.sleep(0.25)
    raise SystemExit("no CDP")


def parse_gpu_text(text: str) -> dict:
    features: dict[str, str] = {}
    in_features = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("Graphics Feature Status"):
            in_features = True
            continue
        if in_features:
            if not line:
                continue
            if line.startswith("Version Information") or line.startswith("Driver Information"):
                break
            for part in re.split(r"\*\s{2,}", line):
                part = part.strip(" =")
                if ":" not in part or "====" in part:
                    continue
                name, val = part.split(":", 1)
                name, val = name.strip(), val.strip()
                if name and val and len(name) < 80:
                    features[name] = val

    def section_after(title: str) -> str:
        idx = text.find(title)
        if idx < 0:
            return ""
        rest = text[idx + len(title):]
        nxt = re.search(
            r"\n(?:Driver Information|Driver Bug|Problems Detected|"
            r"Version Information|ANGLE Features|Dawn Info|Log Messages|"
            r"Display Compositor|Graphics Feature)\b",
            rest,
        )
        return rest[: nxt.start()] if nxt else rest[:8000]

    video_accel = section_after("Video Acceleration Information")
    problems = section_after("Problems Detected")
    decode_profiles = re.findall(
        r"Decode [a-z0-9 .]+?:\s*\d+x\d+ to \d+x\d+ pixels",
        video_accel, flags=re.I)
    encode_profiles = re.findall(
        r"Encode [a-z0-9 .]+?:\s*\d+x\d+ to \d+x\d+ pixels",
        video_accel, flags=re.I)
    return {
        "features": features,
        "video_acceleration_raw": video_accel.strip()[:8000],
        "decode_profiles": decode_profiles[:40],
        "encode_profiles": encode_profiles[:40],
        "problems": problems.strip()[:4000],
    }


async def dump_gpu(ws: str) -> str:
    import websockets
    async with websockets.connect(ws, max_size=20_000_000) as sock:
        mid = 0

        async def send(meth, par=None):
            nonlocal mid
            mid += 1
            await sock.send(json.dumps({"id": mid, "method": meth, "params": par or {}}))
            while True:
                raw = json.loads(await sock.recv())
                if raw.get("id") == mid:
                    return raw

        await send("Runtime.enable")
        await send("Page.enable")
        await send("Page.navigate", {"url": "chrome://gpu"})
        await __import__("asyncio").sleep(6.0)
        got = await send("Runtime.evaluate", {
            "expression": EXTRACT_JS,
            "returnByValue": True,
        })
        gpu_text = got.get("result", {}).get("result", {}).get("value") or "empty"
        # chrome://gpu is a secure context; do not enable Vulkan to "make" WebGPU.
        webgpu = await send("Runtime.evaluate", {
            "expression": r"""
(async function(){
  const out = {
    isSecureContext: !!window.isSecureContext,
    hasNavigatorGpu: typeof navigator.gpu !== 'undefined',
    adapter: null,
    error: null
  };
  if (!navigator.gpu) return out;
  try {
    let a = await navigator.gpu.requestAdapter();
    if (!a) {
      await new Promise(r => setTimeout(r, 1500));
      a = await navigator.gpu.requestAdapter();
    }
    if (!a) { out.error = 'requestAdapter null'; return out; }
    out.adapter = { vendor: a.info && a.info.vendor, architecture: a.info && a.info.architecture,
                    description: a.info && a.info.description, isFallbackAdapter: !!(a.info && a.info.isFallbackAdapter) };
    const dev = await a.requestDevice();
    out.device = !!(dev && dev.features);
    if (dev) dev.destroy();
  } catch (e) { out.error = String(e); }
  return out;
})()
""",
            "awaitPromise": True,
            "returnByValue": True,
        })
        webgpu_val = webgpu.get("result", {}).get("result", {}).get("value")
        glfeat = await send("Runtime.evaluate", {
            "expression": r"""
(function(){
  const out = {canvas2d: null, webgl2: null};
  const c2 = document.createElement('canvas');
  c2.width = 64; c2.height = 64;
  const ctx = c2.getContext('2d');
  if (!ctx) { out.canvas2d = {ok:false, error:'no 2d'}; }
  else {
    ctx.fillStyle = '#00ff00';
    ctx.fillRect(0,0,64,64);
    const px = ctx.getImageData(32,32,1,1).data;
    out.canvas2d = {ok: px[1] > 200 && px[0] < 40, r:px[0], g:px[1], b:px[2]};
  }
  const g = document.createElement('canvas');
  g.width = 64; g.height = 64;
  const gl = g.getContext('webgl2');
  if (!gl) { out.webgl2 = {ok:false, error:'no webgl2'}; return out; }
  const ext = gl.getExtension('WEBGL_debug_renderer_info');
  const renderer = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  const vendor = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
  out.webgl2 = {
    ok: true,
    version: gl.getParameter(gl.VERSION),
    vendor: vendor,
    renderer: renderer,
    software: /swiftshader|llvmpipe|softpipe|microsoft basic/i.test(String(renderer||''))
  };
  return out;
})()
""",
            "returnByValue": True,
        })
        webcodecs = await send("Runtime.evaluate", {
            "expression": r"""
(async function(){
  const out = {
    isSecureContext: !!window.isSecureContext,
    videoEncoder: typeof VideoEncoder,
    videoDecoder: typeof VideoDecoder,
    configs: {}
  };
  if (typeof VideoEncoder === 'undefined') return out;
  const cfgs = {
    h264: {codec:"avc1.64001f", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"},
    vp8: {codec:"vp8", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"},
    hevc: {codec:"hvc1.1.6.L93.B0", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"},
    hevc10: {codec:"hvc1.2.4.L93.B0", width:1280, height:720, bitrate:800000, framerate:30, hardwareAcceleration:"prefer-hardware"}
  };
  for (const [k, cfg] of Object.entries(cfgs)) {
    try {
      const info = await VideoEncoder.isConfigSupported(cfg);
      out.configs[k] = {supported: !!(info && info.supported), config: info && info.config};
    } catch (e) {
      out.configs[k] = {error: String(e)};
    }
  }
  return out;
})()
""",
            "awaitPromise": True,
            "returnByValue": True,
        })
        return {
            "text": gpu_text,
            "webgpu": webgpu_val,
            "gl_features": glfeat.get("result", {}).get("result", {}).get("value"),
            "webcodecs": webcodecs.get("result", {}).get("result", {}).get("value"),
        }


def device_main() -> int:
    if "--fresh" in sys.argv or not port_up("127.0.0.1", 9222):
        start_chrome()
    tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
    page = next((t for t in tabs if t.get("type") == "page"), None)
    if not page:
        raise SystemExit("no page")
    dumped = __import__("asyncio").run(dump_gpu(page["webSocketDebuggerUrl"]))
    if isinstance(dumped, dict):
        text = dumped.get("text") or "empty"
        parsed = parse_gpu_text(text)
        parsed["webgpu"] = dumped.get("webgpu")
        parsed["gl_features"] = dumped.get("gl_features")
        parsed["webcodecs"] = dumped.get("webcodecs")
    else:
        text = dumped
        parsed = parse_gpu_text(text)
    Path("/tmp/dagu-chrome-gpu.txt").write_text(text + "\n")
    Path("/tmp/dagu-chrome-gpu.json").write_text(
        json.dumps(parsed, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(parsed, indent=2, ensure_ascii=False))
    return 0


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    OUT_TXT.unlink(missing_ok=True)
    OUT_JSON.unlink(missing_ok=True)
    subprocess.run(scp + [str(Path(__file__)), f"root@{HOST}:/tmp/dagu-chrome-gpu-dump.py"], check=True)
    subprocess.run(ssh + [
        "install -m755 /tmp/dagu-chrome-gpu-dump.py /usr/local/sbin/dagu-chrome-gpu-dump.py; "
        # Official /usr/local/bin/dagu-chrome is USE_V4L2=0. Venus dump
        # must use the xtradeb / patched official-152 wrapper.
        "DAGU_CHROME_BIN=/usr/local/bin/dagu-chromium "
        f"DAGU_CHROME_VULKAN={os.environ.get('DAGU_CHROME_VULKAN', '0')} "
        f"DAGU_CHROME_GRAPHITE={os.environ.get('DAGU_CHROME_GRAPHITE', '0')} "
        "python3 /usr/local/sbin/dagu-chrome-gpu-dump.py --fresh"
    ], check=False)
    OUT_TXT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-chrome-gpu.txt", str(OUT_TXT)], check=False)
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-chrome-gpu.json", str(OUT_JSON)], check=False)
    if OUT_JSON.exists():
        print(OUT_JSON.read_text())
        print(f"pulled {OUT_JSON}")
    elif OUT_TXT.exists():
        print(f"pulled {OUT_TXT}")
    return 0


if __name__ == "__main__":
    if "--host" in sys.argv or not Path("/sys/class/drm/card0-DSI-1").exists():
        raise SystemExit(host_main())
    raise SystemExit(device_main())
