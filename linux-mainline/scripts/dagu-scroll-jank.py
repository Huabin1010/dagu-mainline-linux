#!/usr/bin/env python3
"""Measure Chrome scroll hitch on dagu. Does not toggle GPU vs CPU raster.

On the tablet (root):
  python3 /usr/local/sbin/dagu-scroll-jank.py
From the host:
  python3 linux-mainline/scripts/dagu-scroll-jank.py --host
"""
from __future__ import annotations

import argparse
import asyncio
import collections
import json
import os
import signal
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
PORT = 8765
CDP = 9222


def is_tablet() -> bool:
    return Path("/sys/class/drm/card0-DSI-1").exists()


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def read_vblank() -> tuple[int, float | None]:
    p = Path("/sys/kernel/debug/dri/0/crtc-0/status")
    text = p.read_text(errors="replace")
    count = -1
    fps = None
    for line in text.splitlines():
        if "vblank" not in line or "count:" not in line:
            continue
        for tok in line.split():
            if tok.startswith("count:"):
                try:
                    count = int(tok.split(":", 1)[1])
                except ValueError:
                    pass
            if tok.startswith("fps:"):
                try:
                    fps = float(tok.split(":", 1)[1])
                except ValueError:
                    pass
    return count, fps


def read_int(path: str) -> int:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return -1


def sample_loop(stop: threading.Event, out: list) -> None:
    while not stop.is_set():
        out.append(
            {
                "t": time.monotonic(),
                "busy": read_int("/sys/class/drm/card0/device/gpu_busy_percent"),
                "freq": read_int("/sys/class/devfreq/3d00000.gpu/cur_freq"),
                "gmin": read_int("/sys/class/devfreq/3d00000.gpu/min_freq"),
                "p4": read_int("/sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq"),
                "p7": read_int("/sys/devices/system/cpu/cpufreq/policy7/scaling_cur_freq"),
                "vbl": read_vblank()[0],
            }
        )
        time.sleep(0.02)


def summarize_samples(samples: list) -> dict:
    if not samples:
        return {}
    dt = samples[-1]["t"] - samples[0]["t"]
    bs = [s["busy"] for s in samples if s["busy"] >= 0]
    fs = [s["freq"] for s in samples if s["freq"] >= 0]
    v0, v1 = samples[0]["vbl"], samples[-1]["vbl"]
    vbl_hz = ((v1 - v0) / dt) if (v0 >= 0 and v1 >= v0 and dt > 0) else None
    fc = collections.Counter(fs)
    return {
        "n": len(samples),
        "sec": round(dt, 3),
        "busy_avg": round(sum(bs) / len(bs), 1) if bs else None,
        "busy_max": max(bs) if bs else None,
        "busy95_pct": round(100 * sum(1 for x in bs if x >= 95) / len(bs), 1) if bs else None,
        "freq_hist": {str(k): v for k, v in fc.items()},
        "drm_vblank_hz": round(vbl_hz, 2) if vbl_hz is not None else None,
        "drm_vblank_delta": (v1 - v0) if (v0 >= 0 and v1 >= 0) else None,
    }


def port_up(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), 0.25):
            return True
    except OSError:
        return False


def wait_port(host: str, port: int, timeout: float = 45.0) -> None:
    t0 = time.time()
    while time.time() - t0 < timeout:
        if port_up(host, port):
            return
        time.sleep(0.2)
    raise SystemExit(f"nothing on {host}:{port}")


def chrome_env() -> dict:
    env = os.environ.copy()
    env.update(
        {
            "XDG_RUNTIME_DIR": "/run/user/1001",
            "WAYLAND_DISPLAY": "wayland-0",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1001/bus",
            "HOME": "/home/dagu",
            "USER": "dagu",
            "LOGNAME": "dagu",
        }
    )
    return env


def start_chrome(url: str) -> None:
    subprocess.run(["pkill", "-u", "dagu", "chrome"], check=False)
    time.sleep(1.0)
    for name in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
        try:
            Path(f"/home/dagu/.config/google-chrome/{name}").unlink()
        except FileNotFoundError:
            pass
    cmd = [
        "sudo", "-u", "dagu", "env",
        "XDG_RUNTIME_DIR=/run/user/1001",
        "WAYLAND_DISPLAY=wayland-0",
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus",
        "HOME=/home/dagu", "USER=dagu", "LOGNAME=dagu",
        "/usr/local/bin/dagu-chrome",
        "--user-data-dir=/tmp/dagu-chrome-jank-profile",
        "--remote-debugging-port=9222",
        "--remote-allow-origins=*",
        "--enable-gpu-benchmarking",
        "--hide-crash-restore-bubble",
        "--new-window",
        url,
    ]
    log = open("/tmp/dagu-scroll-jank-chrome.log", "ab")
    subprocess.Popen(cmd, stdout=log, stderr=log, start_new_session=True)
    wait_port("127.0.0.1", CDP, 25)


def cdp_tabs() -> list:
    with urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5) as r:
        return json.load(r)


async def cdp_call(ws, method, params=None, expr=None):
    import websockets

    async with websockets.connect(ws, max_size=50_000_000) as sock:
        async def send(mid, meth, par=None):
            msg = {"id": mid, "method": meth}
            if par:
                msg["params"] = par
            await sock.send(json.dumps(msg))
            while True:
                raw = json.loads(await sock.recv())
                if raw.get("id") == mid:
                    return raw

        await send(1, "Runtime.enable")
        await send(2, "Page.enable")
        if method == "Page.navigate" or (params and "url" in (params or {})):
            got = await send(3, method, params)
            await asyncio.sleep(1.6)
            return got
        if expr is not None:
            got = await send(3, "Runtime.evaluate", {
                "expression": expr,
                "returnByValue": True,
                "awaitPromise": True,
            })
            return got.get("result", {}).get("result", {}).get("value")
        return await send(3, method, params)


async def cdp_eval(ws, expr: str):
    return await cdp_call(ws, "Runtime.evaluate", expr=expr)


async def cdp_trace_swipe(ws, swipe_cmd: list[str], hold_s: float) -> dict:
    import websockets

    keep_sub = (
        "beginimpl", "drawandswap", "droppedframe", "pipeline", "beginc",
        "scroll", "gesture", "latency", "touchevent", "handleinput",
    )
    events = []
    async with websockets.connect(ws, max_size=80_000_000) as sock:
        mid = 0

        async def send(method, params=None):
            nonlocal mid
            mid += 1
            msg = {"id": mid, "method": method}
            if params:
                msg["params"] = params
            await sock.send(json.dumps(msg))
            return mid

        await send("Tracing.start", {
            "categories": "cc,viz,benchmark,input,latency,disabled-by-default-devtools.timeline",
            "options": "record-until-full",
            "transferMode": "ReportEvents",
        })
        # drain Tracing.started then run swipe in a thread
        started = time.monotonic()
        while time.monotonic() - started < 2.5:
            raw = json.loads(await asyncio.wait_for(sock.recv(), timeout=2.5))
            if raw.get("method") == "Tracing.tracingComplete":
                break
            if raw.get("method") == "Tracing.dataCollected":
                continue
            if raw.get("id"):
                break

        proc = await asyncio.to_thread(
            subprocess.run, swipe_cmd, check=False, capture_output=True, text=True
        )
        await send("Tracing.end")
        t_end = time.monotonic() + 8
        while time.monotonic() < t_end:
            try:
                raw = json.loads(await asyncio.wait_for(sock.recv(), timeout=2))
            except asyncio.TimeoutError:
                break
            if raw.get("method") == "Tracing.dataCollected":
                for ev in raw.get("params", {}).get("value", []):
                    name = str(ev.get("name", ""))
                    if any(s in name.lower() for s in keep_sub):
                        events.append({
                            "name": name,
                            "ph": ev.get("ph"),
                            "ts": ev.get("ts"),
                            "pid": ev.get("pid"),
                            "tid": ev.get("tid"),
                        })
            if raw.get("method") == "Tracing.tracingComplete":
                break
    names = collections.Counter(e["name"] for e in events)

    def series(exact: str) -> dict:
        ts = sorted(
            e["ts"] for e in events
            if e.get("name") == exact and isinstance(e.get("ts"), (int, float))
            and e.get("ph") in ("I", "X", "B", None)
        )
        dts = [(ts[i] - ts[i - 1]) / 1000.0 for i in range(1, len(ts))]
        dts = [d for d in dts if 0.2 < d < 80]
        dts.sort()
        def pct(p):
            return round(dts[min(len(dts) - 1, int(len(dts) * p))], 3) if dts else None
        near8 = sum(1 for d in dts if 6.5 <= d <= 10.5)
        near16 = sum(1 for d in dts if 14.0 <= d <= 20.0)
        return {
            "n": len(ts),
            "med_ms": pct(0.5),
            "p90_ms": pct(0.9),
            "p99_ms": pct(0.99),
            "max_ms": round(dts[-1], 3) if dts else None,
            "hz": round(1000 / (sum(dts) / len(dts)), 2) if dts else None,
            "bins_8ms_pct": round(100 * near8 / len(dts), 1) if dts else None,
            "bins_16ms_pct": round(100 * near16 / len(dts), 1) if dts else None,
            "over_14ms_pct": round(100 * sum(1 for x in dts if x > 14) / len(dts), 1) if dts else None,
            "over_18ms_pct": round(100 * sum(1 for x in dts if x > 18) / len(dts), 1) if dts else None,
        }

    return {
        "swipe_rc": proc.returncode,
        "event_names": dict(names),
        "BeginImplFrame": series("Scheduler::BeginImplFrame"),
        "DrawAndSwap": series("Display::DrawAndSwap"),
        "DrawAndSwapDeadline": series("DisplayScheduler::DrawAndSwap"),
        "GestureScrollUpdate": series("InputLatency::GestureScrollUpdate"),
        "EventLatency": series("EventLatency"),
    }


def himax_cmd(hold: float, oneway: bool = False) -> list[str]:
    script = "/tmp/dagu-himax-swipe.py"
    if not Path(script).exists():
        script = str(ROOT / "scripts/dagu-himax-swipe.py")
    cmd = ["python3", script, "--axis", "x", "--hold", str(hold), "--hz", "120",
           "--log", "/tmp/dagu-himax-path.log"]
    if oneway:
        cmd.append("--oneway")
    return cmd


def follow_gaps() -> dict:
    """Finger moved but scrollY/present did not — the user's symptom."""
    path = Path("/tmp/dagu-himax-path.log")
    if not path.exists():
        return {}
    pts = []
    for line in path.read_text().splitlines():
        bits = line.split()
        if len(bits) < 4 or bits[1] != "move":
            continue
        pts.append((float(bits[0]), int(bits[2]), int(bits[3])))
    if len(pts) < 8:
        return {"inject_n": len(pts)}
    dts = [(pts[i][0] - pts[i - 1][0]) * 1000 for i in range(1, len(pts))]
    gaps = [d for d in dts if d > 20]
    # physical X should change monotonically in oneway
    dx = [abs(pts[i][1] - pts[i - 1][1]) for i in range(1, len(pts))]
    stall = 0
    stall_ms = 0.0
    cur = 0.0
    for i, d in enumerate(dx):
        if d == 0:
            cur += dts[i]
            if cur > stall_ms:
                stall_ms = cur
            if cur >= 24:
                stall += 1
        else:
            cur = 0.0
    return {
        "inject_n": len(pts),
        "inject_med_ms": round(sorted(dts)[len(dts) // 2], 2),
        "inject_max_ms": round(max(dts), 2),
        "inject_over_20ms": len(gaps),
        "inject_x_span": pts[-1][1] - pts[0][1],
        "inject_zero_dx_runs": stall,
        "inject_longest_zero_dx_ms": round(stall_ms, 1),
    }


POSTED: dict = {}


def start_http(docroot: Path) -> ThreadingHTTPServer:
    class H(SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=str(docroot), **k)

        def do_POST(self):
            if self.path != "/jank-report":
                self.send_error(404)
                return
            n = int(self.headers.get("Content-Length", "0"))
            POSTED["page"] = json.loads(self.rfile.read(n) or b"{}")
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_a):
            return

    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def device_main(args) -> int:
    docroot = Path("/usr/local/share/dagu-scroll-jank")
    if not (docroot / "dagu-scroll-jank.html").exists():
        docroot = Path(__file__).resolve().parent
    httpd = start_http(docroot)
    url = args.url or f"http://127.0.0.1:{PORT}/dagu-scroll-jank.html"
    if port_up("127.0.0.1", CDP):
        print("attach existing CDP", file=sys.stderr)
    else:
        start_chrome(url)
    time.sleep(1.0)
    tabs = []
    for _ in range(20):
        try:
            tabs = [t for t in cdp_tabs() if t.get("type") == "page"]
            if tabs:
                break
        except Exception:
            pass
        time.sleep(0.4)
    if not tabs:
        raise SystemExit("no CDP page")
    page = next((t for t in tabs if "scroll-jank" in t.get("url", "") or "8765" in t.get("url", "")), tabs[0])
    ws = page["webSocketDebuggerUrl"]

    try:
        nav = url + ("&" if "?" in url else "?") + "t=%d" % int(time.time())
        asyncio.run(cdp_call(ws, "Page.navigate", {"url": nav}))
        time.sleep(1.4)
        tabs = [t for t in cdp_tabs() if t.get("type") == "page"]
        page = next((t for t in tabs if "scroll-jank" in t.get("url", "")), tabs[0])
        ws = page["webSocketDebuggerUrl"]
        asyncio.run(cdp_eval(ws, "window.__JANK_RESET__ && window.__JANK_RESET__()"))
    except Exception as exc:
        print(f"cdp reset: {exc}", file=sys.stderr)
    samples: list = []
    stop = threading.Event()
    th = threading.Thread(target=sample_loop, args=(stop, samples), daemon=True)
    th.start()
    time.sleep(0.15)
    hold = args.hold
    swipe = himax_cmd(hold, oneway=getattr(args, "oneway", False))
    trace = {}
    if args.idle:
        time.sleep(max(hold, 3.0))
    elif args.trace:
        trace = asyncio.run(cdp_trace_swipe(ws, swipe, hold))
    else:
        subprocess.run(swipe, check=False)
    stop.set()
    th.join(timeout=1)
    page_stats = POSTED.get("page")
    try:
        page_stats = asyncio.run(cdp_eval(ws, "window.__JANK_DUMP__ && window.__JANK_DUMP__()")) or page_stats
    except Exception as exc:
        page_stats = page_stats or {"cdp_error": str(exc)}
    flags = []
    try:
        pid = subprocess.check_output(["pgrep", "-n", "-u", "dagu", "-f", "/opt/google/chrome/chrome --ozone"], text=True).strip()
        flags = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        flags = [x.decode() for x in flags if x]
    except Exception:
        flags = []
    report = {
        "url": url,
        "cdp_url": page.get("url"),
        "page": page_stats,
        "sys": summarize_samples(samples),
        "trace": trace,
        "follow": follow_gaps(),
        "chrome_flags": [f for f in flags if "gpu" in f or "raster" in f or "partial" in f or "angle" in f],
        "vblank_now": read_vblank()[1],
        "note": "rAF ~8.3ms = 120Hz. freezes = scrollY stuck while finger still down.",
    }
    out = Path("/tmp/dagu-scroll-jank.json")
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"wrote {out}", file=sys.stderr)
    httpd.shutdown()
    return 0


def host_main(args) -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    subprocess.run(scp + [
        str(ROOT / "scripts/dagu-scroll-jank.py"),
        str(ROOT / "scripts/dagu-scroll-jank.html"),
        str(ROOT / "scripts/dagu-himax-swipe.py"),
        f"root@{HOST}:/tmp/",
    ], check=True)
    subprocess.run(ssh + [
        "install -m755 /tmp/dagu-scroll-jank.py /usr/local/sbin/dagu-scroll-jank.py; "
        "mkdir -p /usr/local/share/dagu-scroll-jank; "
        "install -m644 /tmp/dagu-scroll-jank.html /usr/local/share/dagu-scroll-jank/; "
        "install -m755 /tmp/dagu-himax-swipe.py /tmp/dagu-himax-swipe.py; "
        f"python3 /usr/local/sbin/dagu-scroll-jank.py --hold {args.hold}"
        + (" --trace" if args.trace else "")
        + (" --idle" if args.idle else "")
        + (" --oneway" if args.oneway else "")
        + (f" --url {args.url}" if args.url else "")
    ], check=False)
    OUT_HOST.mkdir(parents=True, exist_ok=True)
    dest = OUT_HOST / "scroll-jank.json"
    subprocess.run(scp + [f"root@{HOST}:/tmp/dagu-scroll-jank.json", str(dest)], check=False)
    if dest.exists():
        print(dest.read_text())
        print(f"pulled {dest}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", action="store_true")
    ap.add_argument("--hold", type=float, default=6.0)
    ap.add_argument("--trace", action="store_true", help="CDP cc/viz BeginImplFrame")
    ap.add_argument("--idle", action="store_true", help="no swipe; rAF-only baseline")
    ap.add_argument("--oneway", action="store_true", help="hold and drag one direction")
    ap.add_argument("--url", default="")
    args = ap.parse_args()
    if args.host or not is_tablet():
        return host_main(args)
    return device_main(args)


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    raise SystemExit(main())
