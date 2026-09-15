#!/usr/bin/env python3
"""PipeWire Video/Source for GNOME Snapshot on dagu.

Lab-only. Default desktop path is libcamera Software ISP + UDMABUF.
This process stays for RAW10 bring-up when libcamera is off.
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

import gi
import numpy as np

gi.require_version("Gst", "1.0")
gi.require_version("GstApp", "1.0")
from gi.repository import GLib, Gst, GstApp  # noqa: E402

MC = "/dev/media0"
NODE_NAME = "dagu-camera"
WIDTH = 510
HEIGHT = 382
FPS = 5
FRAME_BYTES = WIDTH * HEIGHT * 3
REAR_SKIP = 4


def run(cmd):
    return subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )


def entity(prefix):
    out = run(["media-ctl", "-d", MC, "-p"]).stdout
    m = re.search(rf"^- entity \d+: ({re.escape(prefix)} [^ ]+) \(", out, re.M)
    return m.group(1) if m else None


def media_fmt(ent, pad, fmt):
    run(["media-ctl", "-d", MC, "-V", f'"{ent}":{pad}[fmt:{fmt} field:none]'])


def media_link(a, ap, b, bp):
    run(["media-ctl", "-d", MC, "-l", f'"{a}":{ap} -> "{b}":{bp}[1]'])


def setup_rear():
    run(["media-ctl", "-d", MC, "-r"])
    s5k = entity("s5kjn1")
    if not s5k:
        raise RuntimeError("没有 s5kjn1 实体")
    fmt = "SGBRG10_1X10/4080x3060"
    media_link(s5k, 0, "msm_csiphy1", 0)
    media_link("msm_csiphy1", 1, "msm_csid0", 0)
    media_link("msm_csid0", 1, "msm_vfe0_rdi0", 0)
    for spec in (
        (s5k, 0),
        ("msm_csiphy1", 0),
        ("msm_csiphy1", 1),
        ("msm_csid0", 0),
        ("msm_csid0", 1),
        ("msm_vfe0_rdi0", 0),
    ):
        media_fmt(*spec, fmt)
    return {
        "dev": "/dev/video0",
        "fourcc": "pGAA",
        "w": 4080,
        "h": 3060,
        "pattern": "gbrg",
        "size": 15618240,
        "skip": REAR_SKIP,
    }


def packed_bayer8(buf, w, h, skip):
    stride = len(buf) // h
    raw = np.frombuffer(buf, dtype=np.uint8).reshape(h, stride)
    h2 = h // skip
    groups = w // 4
    rs = np.arange(h2, dtype=np.intp)
    rows = (rs // 2) * (skip * 2) + (rs % 2)
    g = raw[rows, : groups * 5].reshape(h2, groups, 5)[:, ::skip, :4]
    return np.ascontiguousarray(g.reshape(h2, g.shape[1] * 4))


def stretch8(u8, gain):
    sample = u8[::8, ::8]
    lo = int(np.percentile(sample, 2))
    hi = int(np.percentile(sample, 99.5))
    if hi <= lo:
        hi = lo + 1
    if gain["lo"] is None:
        gain["lo"], gain["hi"] = lo, hi
    else:
        gain["lo"] = (9 * gain["lo"] + lo) // 10
        gain["hi"] = (9 * gain["hi"] + hi) // 10
    span = max(gain["hi"] - gain["lo"], 1)
    return np.clip(
        (u8.astype(np.int16) - gain["lo"]) * 255 // span, 0, 255
    ).astype(np.uint8)


def bayer_rgb(u8, pattern):
    g = (u8[0::2, 0::2].astype(np.uint16) + u8[1::2, 1::2]) >> 1
    if pattern == "gbrg":
        r = u8[1::2, 0::2]
        b = u8[0::2, 1::2]
    else:
        r = u8[1::2, 1::2]
        b = u8[0::2, 0::2]
    gm = int(g.mean()) + 1
    r8 = np.clip(r.astype(np.uint16) * gm // (int(r.mean()) + 1), 0, 255).astype(
        np.uint8
    )
    b8 = np.clip(b.astype(np.uint16) * gm // (int(b.mean()) + 1), 0, 255).astype(
        np.uint8
    )
    return np.dstack((r8, np.clip(g, 0, 255).astype(np.uint8), b8))


def pw_dump():
    env = os.environ.copy()
    env.setdefault("XDG_RUNTIME_DIR", "/run/user/1001")
    try:
        out = subprocess.check_output(["pw-dump"], env=env, timeout=3)
        return json.loads(out)
    except Exception:
        return []


def our_node_ids(dump):
    ids = set()
    for o in dump:
        props = (o.get("info") or {}).get("props") or {}
        blob = " ".join(
            str(props.get(k, ""))
            for k in ("node.name", "node.description", "application.name", "client.name")
        )
        if NODE_NAME not in blob:
            continue
        typ = o.get("type") or ""
        if typ.endswith("Node") or "Node" in typ:
            ids.add(int(o["id"]))
    return ids


def node_has_peer(dump, ids):
    if not ids:
        return False
    for o in dump:
        typ = o.get("type") or ""
        if "Link" not in typ:
            continue
        info = o.get("info") or {}
        props = info.get("props") or {}
        for key in (
            "output-node-id",
            "input-node-id",
            "link.output.node",
            "link.input.node",
        ):
            val = info.get(key, props.get(key))
            try:
                if int(val) in ids:
                    return True
            except (TypeError, ValueError):
                continue
    return False


class Capture:
    def __init__(self):
        self.lock = threading.Lock()
        self.frame = np.full((HEIGHT, WIDTH, 3), 24, dtype=np.uint8).tobytes()
        self.stop = threading.Event()
        self.thread = None
        self.proc = None
        self.fd = None
        # Stay latched while Snapshot is linked. Do not re-STREAMON every
        # 400 ms if v4l2-ctl dies — that media-ctl -r loop starves UFS.
        self.armed = False

    def latest(self):
        with self.lock:
            return self.frame

    def running(self):
        return self.armed

    def start(self):
        if self.armed:
            return
        self.armed = True
        self.stop.clear()
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()
        print("camss: start 12MP RDI (Snapshot linked)", flush=True)

    def halt(self):
        if not self.armed and not self.thread and not self.proc:
            return
        print("camss: stop", flush=True)
        self.armed = False
        self.stop.set()
        fd = self.fd
        if fd:
            try:
                fd.close()
            except Exception:
                pass
            self.fd = None
        proc = self.proc
        if proc and proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()
        self.proc = None
        if self.thread:
            self.thread.join(timeout=4)
        self.thread = None
        with self.lock:
            self.frame = np.full((HEIGHT, WIDTH, 3), 24, dtype=np.uint8).tobytes()

    def _loop(self):
        fifo = f"/tmp/dagu-pw-cam-{os.getpid()}.raw"
        proc = None
        fd = None
        try:
            cam = setup_rear()
            try:
                os.unlink(fifo)
            except FileNotFoundError:
                pass
            os.mkfifo(fifo)
            proc = subprocess.Popen(
                [
                    "v4l2-ctl",
                    "-d",
                    cam["dev"],
                    f"--set-fmt-video=width={cam['w']},height={cam['h']},pixelformat={cam['fourcc']}",
                    "--stream-mmap",
                    f"--stream-to={fifo}",
                    "--stream-count=0",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.proc = proc
            fd = open(fifo, "rb", buffering=0)
            self.fd = fd
            size = cam["size"]
            buf = bytearray(size)
            mv = memoryview(buf)
            gain = {"lo": None, "hi": None}
            warm = 3
            while not self.stop.is_set():
                got = 0
                while got < size and not self.stop.is_set():
                    n = fd.readinto(mv[got:])
                    if not n:
                        err = ""
                        if proc and proc.poll() is not None and proc.stderr:
                            err = (proc.stderr.read() or "").strip()
                        print(
                            f"camss: fifo eof rc={None if not proc else proc.poll()} {err}",
                            file=sys.stderr,
                            flush=True,
                        )
                        return
                    got += n
                if warm > 0:
                    warm -= 1
                    continue
                u8 = stretch8(
                    packed_bayer8(buf, cam["w"], cam["h"], cam["skip"]), gain
                )
                rgb = bayer_rgb(u8, cam["pattern"])
                if rgb.shape[0] != HEIGHT or rgb.shape[1] != WIDTH:
                    rgb = np.ascontiguousarray(rgb[:HEIGHT, :WIDTH])
                with self.lock:
                    self.frame = rgb.tobytes()
        except Exception as exc:
            print(f"camss: {exc}", file=sys.stderr, flush=True)
        finally:
            if fd:
                try:
                    fd.close()
                except Exception:
                    pass
            try:
                os.unlink(fifo)
            except Exception:
                pass
            if proc and proc.poll() is None:
                proc.send_signal(signal.SIGTERM)


def main():
    Gst.init(None)
    cap = Capture()
    n = {"i": 0}

    caps = (
        f"video/x-raw,format=RGB,width={WIDTH},height={HEIGHT},"
        f"framerate={FPS}/1"
    )
    pipeline = Gst.parse_launch(
        "appsrc name=src is-live=true format=time do-timestamp=true "
        "block=false max-bytes=0 "
        f"! {caps} "
        "! videoconvert "
        "! video/x-raw,format=NV12 "
        "! queue leaky=downstream max-size-buffers=1 "
        f"! pipewiresink name=sink mode=provide client-name={NODE_NAME}"
    )
    appsrc = pipeline.get_by_name("src")
    sink = pipeline.get_by_name("sink")
    props = Gst.Structure.new_empty("props")
    for key, val in (
        ("media.role", "Camera"),
        ("media.class", "Video/Source"),
        ("media.category", "Capture"),
        ("media.type", "Video"),
        ("node.description", "s5kjn1"),
        ("node.nick", "s5kjn1"),
    ):
        props.set_value(key, val)
    sink.set_property("stream-properties", props)
    appsrc.set_property("caps", Gst.Caps.from_string(caps))
    duration = Gst.util_uint64_scale(1, Gst.SECOND, FPS)

    def on_need_data(_src, _length):
        buf = Gst.Buffer.new_wrapped(cap.latest())
        buf.duration = duration
        appsrc.emit("push-buffer", buf)
        n["i"] += 1

    appsrc.connect("need-data", on_need_data)

    live_ok = os.environ.get("DAGU_PW_CAM_LIVE", "0") == "1"

    def poll_links():
        dump = pw_dump()
        ids = our_node_ids(dump)
        live = node_has_peer(dump, ids)
        if live_ok and live and not cap.running():
            cap.start()
        elif (not live or not live_ok) and cap.running():
            cap.halt()
        return True

    loop = GLib.MainLoop()

    def handle_stop(*_a):
        cap.halt()
        pipeline.set_state(Gst.State.NULL)
        loop.quit()

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    GLib.timeout_add(400, poll_links)
    pipeline.set_state(Gst.State.PLAYING)
    print(
        "pw-source: NV12 provide node ready "
        f"(CAMSS={'on-link' if live_ok else 'idle, set DAGU_PW_CAM_LIVE=1 to stream'})",
        flush=True,
    )
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
