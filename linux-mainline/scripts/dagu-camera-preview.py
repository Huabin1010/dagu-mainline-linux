#!/usr/bin/env python3
"""dagu 前后摄预览。

Bayer 必须 CPU 解包（RDI RAW10，没有 ISP）。窗口不能吃 4K MemoryTexture：
GSK ngl 把 LINEAR 大图和 HeaderBar 的 R8 字图集画进同一张 UBWC 窗缓冲，
顶行 128px tile 正好盖住 CSD，标题栏就闪、花。打包 RAW 按下采，GSK 走 gl，
CSD 占满一行 tile，像素只在 GTK 主线程上传。
"""
import os
import re
import signal
import subprocess
import sys
import threading
import time

# Identity 实验室同一条 GL 路径。不要 cairo，不要 llvmpipe。
os.environ.setdefault("GSK_RENDERER", "gl")

import gi
import numpy as np

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Gtk

# SM8250 UBWC 竖向 tile 常是 32/128。CSD+状态栏必须独自占满一行，
# 否则 Picture 损伤会 destile 到标题栏。
CHROME_TILE_PX = 128
# 打包 RAW10 按 Bayer 格子下采（2/4/8）。没有 ISP，不能走 Venus。
REAR_SKIP = 4
FRONT_SKIP = 2

MC = "/dev/media0"


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


def setup_cam(which):
    run(["media-ctl", "-d", MC, "-r"])
    s5k = entity("s5kjn1")
    imx = entity("imx596-dagu") or entity("imx596")
    if which == "rear":
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
            "label": f"后置 {s5k}",
            "dev": "/dev/video0",
            "fourcc": "pGAA",
            "w": 4080,
            "h": 3060,
            "pattern": "gbrg",
            "size": 15618240,
            "skip": REAR_SKIP,
        }
    if not imx:
        raise RuntimeError("没有 imx596 实体")
    fmt = "SBGGR10_1X10/2592x1952"
    media_link(imx, 0, "msm_csiphy4", 0)
    media_link("msm_csiphy4", 1, "msm_csid1", 0)
    media_link("msm_csid1", 1, "msm_vfe1_rdi0", 0)
    for spec in (
        (imx, 0),
        ("msm_csiphy4", 0),
        ("msm_csiphy4", 1),
        ("msm_csid1", 0),
        ("msm_csid1", 1),
        ("msm_vfe1_rdi0", 0),
    ):
        media_fmt(*spec, fmt)
    return {
        "label": f"前置 {imx}",
        "dev": "/dev/video3",
        "fourcc": "pBAA",
        "w": 2592,
        "h": 1952,
        "pattern": "bggr",
        "size": 6340096,
        "skip": FRONT_SKIP,
    }


def packed_bayer8(buf, w, h, skip):
    """MIPI RAW10 只取每像素高 8 位，并按 Bayer 2×2 格子下采。"""
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
    g = ((u8[0::2, 0::2].astype(np.uint16) + u8[1::2, 1::2]) >> 1)
    if pattern == "gbrg":
        r = u8[1::2, 0::2]
        b = u8[0::2, 1::2]
    else:
        r = u8[1::2, 1::2]
        b = u8[0::2, 0::2]
    gm = int(g.mean()) + 1
    r8 = np.clip(r.astype(np.uint16) * gm // (int(r.mean()) + 1), 0, 255).astype(np.uint8)
    b8 = np.clip(b.astype(np.uint16) * gm // (int(b.mean()) + 1), 0, 255).astype(np.uint8)
    return np.dstack((r8, np.clip(g, 0, 255).astype(np.uint8), b8))


def rgb_to_rgba_blob(rgb):
    h, w, _ = rgb.shape
    rgba = np.empty((h, w, 4), dtype=np.uint8)
    rgba[:, :, :3] = rgb
    rgba[:, :, 3] = 255
    return w, h, rgba.tobytes()


class Preview(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="dagu 相机")
        self.set_default_size(1400, 1100)
        self.cam = None
        self.proc = None
        self.stop = threading.Event()
        self.thread = None
        self.frames = 0
        self.t0 = time.time()
        self.last_unique = 0
        self.err = ""
        self._busy = False
        self._fifo_fd = None
        self._in_flight = threading.Event()
        self._keep = []

        hb = Gtk.HeaderBar()
        hb.set_size_request(-1, CHROME_TILE_PX // 2)
        self.set_titlebar(hb)
        box = Gtk.Box(spacing=8, orientation=Gtk.Orientation.HORIZONTAL)
        self.btn_rear = Gtk.ToggleButton(label="后置")
        self.btn_front = Gtk.ToggleButton(label="前置")
        self.btn_front.set_group(self.btn_rear)
        self.btn_rear.connect("toggled", self.on_rear)
        self.btn_front.connect("toggled", self.on_front)
        box.append(self.btn_rear)
        box.append(self.btn_front)
        hb.pack_start(box)

        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.status = Gtk.Label(xalign=0, label="正在打开后置…")
        self.status.set_margin_start(12)
        self.status.set_margin_top(6)
        self.status.set_margin_bottom(6)
        self.status.set_size_request(-1, CHROME_TILE_PX // 2)
        self.picture = Gtk.Picture()
        self.picture.set_hexpand(True)
        self.picture.set_vexpand(True)
        self.picture.set_size_request(960, 720)
        self.picture.set_content_fit(Gtk.ContentFit.CONTAIN)
        self.picture.set_can_shrink(True)
        v.append(self.status)
        v.append(self.picture)
        self.set_child(v)

        GLib.timeout_add(1000, self.refresh_status)
        GLib.idle_add(self.start_cam, "rear")

    def on_rear(self, btn):
        if self._busy or not btn.get_active():
            return
        if self.cam and self.cam["dev"] == "/dev/video0":
            return
        self.start_cam("rear")

    def on_front(self, btn):
        if self._busy or not btn.get_active():
            return
        if self.cam and self.cam["dev"] == "/dev/video3":
            return
        self.start_cam("front")

    def start_cam(self, which):
        print(f"start_cam {which}", flush=True)
        if self._busy:
            return False
        self._busy = True
        self.stop_stream()
        self.err = ""
        self.frames = 0
        self.t0 = time.time()
        try:
            self.cam = setup_cam(which)
        except Exception as e:
            self.err = str(e)
            self.status.set_text(f"失败: {e}")
            self._busy = False
            return False
        self.btn_rear.set_active(which == "rear")
        self.btn_front.set_active(which == "front")
        self.stop.clear()
        self._in_flight.clear()
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()
        self._busy = False
        return False

    def stop_stream(self):
        self.stop.set()
        fd = self._fifo_fd
        if fd:
            try:
                fd.close()
            except Exception:
                pass
            self._fifo_fd = None
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=2)
            except Exception:
                self.proc.kill()
        self.proc = None
        if self.thread:
            self.thread.join(timeout=4)
        self.thread = None

    def loop(self):
        cam = self.cam
        fifo = f"/tmp/dagu-cam-{os.getpid()}.raw"
        try:
            os.unlink(fifo)
        except FileNotFoundError:
            pass
        os.mkfifo(fifo)
        cmd = [
            "v4l2-ctl",
            "-d",
            cam["dev"],
            f"--set-fmt-video=width={cam['w']},height={cam['h']},pixelformat={cam['fourcc']}",
            "--stream-mmap",
            f"--stream-to={fifo}",
            "--stream-count=0",
        ]
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.proc = proc
        fd = open(fifo, "rb", buffering=0)
        self._fifo_fd = fd
        size = cam["size"]
        buf = bytearray(size)
        mv = memoryview(buf)
        warm = 4
        gain = {"lo": None, "hi": None}
        try:
            while not self.stop.is_set():
                got = 0
                while got < size and not self.stop.is_set():
                    n = fd.readinto(mv[got:])
                    if not n:
                        return
                    got += n
                if warm > 0:
                    warm -= 1
                    continue
                if self._in_flight.is_set():
                    continue
                try:
                    u8 = stretch8(
                        packed_bayer8(buf, cam["w"], cam["h"], cam["skip"]), gain
                    )
                    rgb = bayer_rgb(u8, cam["pattern"])
                    tw, th, blob = rgb_to_rgba_blob(rgb)
                    self.last_unique = int(u8[::16, ::16].ptp())
                    self.frames += 1
                    self.err = ""
                    self._in_flight.set()
                    GLib.idle_add(self.show_frame, tw, th, blob)
                except Exception as e:
                    self.err = str(e)
        finally:
            try:
                fd.close()
            except Exception:
                pass
            try:
                os.unlink(fifo)
            except Exception:
                pass
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)

    def show_frame(self, w, h, blob):
        try:
            b = GLib.Bytes.new(blob)
            fmt = getattr(
                Gdk.MemoryFormat, "R8G8B8A8", Gdk.MemoryFormat.R8G8B8A8_PREMULTIPLIED
            )
            tex = Gdk.MemoryTexture.new(w, h, fmt, b, w * 4)
            self._keep = [b, tex, *self._keep[:2]]
            self.picture.set_paintable(tex)
        except Exception as e:
            self.err = str(e)
        finally:
            self._in_flight.clear()
        return False

    def refresh_status(self):
        cam = self.cam
        dt = max(0.001, time.time() - self.t0)
        fps = self.frames / dt
        if not cam:
            self.status.set_text(self.err or "未打开")
            return True
        msg = (
            f"{cam['label']}  {cam['dev']}  {cam['fourcc']} "
            f"{cam['w']}x{cam['h']} bin={cam['skip']}  "
            f"帧={self.frames}  {fps:.1f} fps  ptp={self.last_unique}"
        )
        if self.err:
            msg += f"  | {self.err.strip()[:180]}"
        self.status.set_text(msg)
        return True

    def do_close_request(self):
        self.stop_stream()
        return False


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="local.dagu.camera")

    def do_activate(self):
        w = Preview(self)
        w.present()


if __name__ == "__main__":
    sys.exit(App().run(sys.argv))
