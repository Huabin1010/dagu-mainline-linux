#!/usr/bin/env python3
"""Built-in microphone record / playback for dagu.

Uses PipeWire (管道线) pulse (the same path Tencent Meeting captures).
WCD9385 AMIC5 → MultiMedia3 hw:0,2 S16LE mono → dagu-builtin-mic.
Q6 S24_LE is not spa S24_32LE (that was the 电流声). Not Dummy, not CPU loopback.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dagu_mic_lib import (  # noqa: E402
    AUDIBLE_PEAK_MIN,
    EMPTY_PEAK_MAX,
    RATE,
    peak_from_db,
    wav_peak_s16,
)

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gst", "1.0")
from gi.repository import Gio, GLib, Gst, Gtk

APP_ID = "org.dagu.MicTest"
SOURCE = "dagu-builtin-mic"
SINK = "alsa_output.platform-sound.HiFi__Speaker__sink"


def wav_path() -> Path:
    d = Path.home() / "录音"
    d.mkdir(parents=True, exist_ok=True)
    return d / "mic-test.wav"


class Meter(Gtk.DrawingArea):
    def __init__(self):
        super().__init__()
        self.level = 0.0
        self.set_content_height(56)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

    def set_level(self, v: float):
        self.level = max(0.0, min(1.0, v))
        self.queue_draw()

    def _draw(self, _area, cr, w, h):
        cr.set_source_rgb(0.12, 0.12, 0.14)
        cr.rectangle(0, 0, w, h)
        cr.fill()
        if self.level < 0.015:
            cr.set_source_rgb(0.45, 0.45, 0.48)
        elif self.level > 0.92:
            cr.set_source_rgb(0.86, 0.18, 0.12)
        else:
            cr.set_source_rgb(0.18, 0.78, 0.32)
        cr.rectangle(0, 0, w * self.level, h)
        cr.fill()


class MicTest(Gtk.ApplicationWindow):
    def __init__(self, app: Gtk.Application):
        super().__init__(application=app, title="麦克风测试")
        self.set_default_size(720, 520)
        self.rec = None
        self.play = None
        self.t0 = 0.0
        self.wav = wav_path()
        self._build()
        GLib.timeout_add(200, self._tick)
        self.connect("close-request", self._on_close)

    def _build(self):
        css = Gtk.CssProvider()
        css.load_from_data(
            b"""
            window { font-size: 20px; }
            button { min-height: 80px; font-size: 24px; margin: 6px; }
            .status { font-size: 18px; }
            .peak { font-size: 28px; font-weight: bold; }
            """
        )
        Gtk.StyleContext.add_provider_for_display(
            self.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=12,
            margin_top=20,
            margin_bottom=20,
            margin_start=24,
            margin_end=24,
        )
        self.set_child(box)

        title = Gtk.Label(label="对着平板说话，再点播放听自己")
        title.set_wrap(True)
        box.append(title)

        self.meter = Meter()
        box.append(self.meter)

        self.peak_l = Gtk.Label(label="峰值 0")
        self.peak_l.add_css_class("peak")
        box.append(self.peak_l)

        self.status = Gtk.Label(label="就绪")
        self.status.add_css_class("status")
        self.status.set_wrap(True)
        box.append(self.status)

        self.btn_rec = Gtk.Button(label="开始录音")
        self.btn_rec.connect("clicked", self._toggle_rec)
        box.append(self.btn_rec)

        self.btn_play = Gtk.Button(label="播放录音")
        self.btn_play.connect("clicked", self._toggle_play)
        box.append(self.btn_play)

        hint = Gtk.Label(
            label="录音文件：~/录音/mic-test.wav\n"
            "采集走系统默认麦克风，和腾讯会议同一条输入"
        )
        hint.set_wrap(True)
        hint.add_css_class("status")
        box.append(hint)

    def _set_status(self, text: str):
        self.status.set_text(text)

    def _idle(self) -> bool:
        return self.rec is None and self.play is None

    def _stop_pipe(self, pipe, send_eos: bool):
        if pipe is None:
            return
        if send_eos:
            pipe.send_event(Gst.Event.new_eos())
            bus = pipe.get_bus()
            bus.timed_pop_filtered(
                2 * Gst.SECOND,
                Gst.MessageType.EOS | Gst.MessageType.ERROR,
            )
        pipe.set_state(Gst.State.NULL)
        pipe.get_state(Gst.CLOCK_TIME_NONE)

    def _toggle_rec(self, _btn):
        if self.rec:
            self._stop_rec()
            return
        if self.play:
            self._stop_play()
        self._start_rec()

    def _toggle_play(self, _btn):
        if self.play:
            self._stop_play()
            return
        if self.rec:
            self._stop_rec()
        self._start_play()

    def _start_rec(self):
        self._prep_mixer()
        path = self.wav
        try:
            path.unlink(missing_ok=True)
        except TypeError:
            if path.exists():
                path.unlink()
        desc = (
            f'pulsesrc client-name="麦克风测试" ! '
            f"audioconvert ! audioresample ! "
            f"audio/x-raw,rate={RATE},channels=1,format=S16LE ! "
            f"tee name=t "
            f"t. ! queue ! wavenc ! filesink location=\"{path}\" "
            f"t. ! queue ! level interval=50000000 post-messages=true ! "
            f"fakesink sync=false"
        )
        pipe = Gst.parse_launch(desc)
        bus = pipe.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._on_bus, "rec")
        if pipe.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            self._set_status("打不开麦克风（PipeWire 源失败）")
            pipe.set_state(Gst.State.NULL)
            return
        self.rec = pipe
        self.t0 = time.monotonic()
        self.btn_rec.set_label("停止录音")
        self.btn_play.set_sensitive(False)
        self._set_status("正在录音…对着麦克风说话")

    def _stop_rec(self):
        self._stop_pipe(self.rec, send_eos=True)
        self.rec = None
        self.btn_rec.set_label("开始录音")
        self.btn_play.set_sensitive(True)
        n = self.wav.stat().st_size if self.wav.exists() else 0
        pk = wav_peak_s16(self.wav)
        if n < 1024 or pk < EMPTY_PEAK_MAX:
            self._set_status("录音几乎是空的，麦克风没有进数据")
            self.meter.set_level(0)
            self.peak_l.set_text("峰值 0")
            return
        sec = max(0, (n - 44) / (RATE * 2))
        self.peak_l.set_text(f"峰值 {pk}")
        if pk < AUDIBLE_PEAK_MIN:
            self._set_status(
                f"已录 {sec:.1f} 秒，峰值 {pk}，太轻。靠近底边麦克风再录一次。"
            )
        else:
            self._set_status(f"已录 {sec:.1f} 秒，峰值 {pk}。点播放听自己。")

    def _start_play(self):
        if not self.wav.exists() or self.wav.stat().st_size < 1024:
            self._set_status("还没有可用的录音")
            return
        desc = (
            f'filesrc location="{self.wav}" ! wavparse ! '
            f"audioconvert ! audioresample ! "
            f'pulsesink client-name="麦克风测试回放"'
        )
        pipe = Gst.parse_launch(desc)
        bus = pipe.get_bus()
        bus.add_signal_watch()
        bus.connect("message", self._on_bus, "play")
        if pipe.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            self._set_status("打不开喇叭")
            pipe.set_state(Gst.State.NULL)
            return
        self.play = pipe
        self.t0 = time.monotonic()
        self.btn_play.set_label("停止播放")
        self.btn_rec.set_sensitive(False)
        self._set_status("正在从喇叭回放…")

    def _stop_play(self):
        self._stop_pipe(self.play, send_eos=False)
        self.play = None
        self.btn_play.set_label("播放录音")
        self.btn_rec.set_sensitive(True)
        self._set_status("回放结束。听得到自己 = 麦克风正常。")
        self.meter.set_level(0)

    def _on_bus(self, _bus, msg, kind: str):
        if msg.type == Gst.MessageType.EOS:
            if kind == "play":
                GLib.idle_add(self._stop_play)
            elif kind == "rec":
                GLib.idle_add(self._stop_rec)
            return
        if msg.type == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            GLib.idle_add(self._gst_error, kind, str(err), dbg or "")
            return
        if msg.type != Gst.MessageType.ELEMENT:
            return
        s = msg.get_structure()
        if not s or s.get_name() != "level":
            return
        peaks = s.get_value("peak")
        lin = peak_from_db(peaks)
        GLib.idle_add(self._show_peak, lin)

    def _show_peak(self, lin: float):
        self.meter.set_level(lin)
        self.peak_l.set_text(f"峰值 {int(lin * 32767)}")
        return False

    def _gst_error(self, kind: str, err: str, dbg: str):
        if kind == "rec":
            self._stop_pipe(self.rec, send_eos=False)
            self.rec = None
            self.btn_rec.set_label("开始录音")
            self.btn_play.set_sensitive(True)
        else:
            self._stop_pipe(self.play, send_eos=False)
            self.play = None
            self.btn_play.set_label("播放录音")
            self.btn_rec.set_sensitive(True)
        self._set_status(f"失败：{err}")
        return False

    def _tick(self):
        if self.rec:
            dt = time.monotonic() - self.t0
            self._set_status(f"正在录音 {dt:.0f} 秒…对着麦克风说话")
        elif self.play:
            dt = time.monotonic() - self.t0
            self._set_status(f"正在回放 {dt:.0f} 秒…")
        return True

    def _prep_mixer(self):
        route = "/usr/local/sbin/dagu-mic-route.sh"
        if os.access(route, os.X_OK):
            subprocess.run([route], check=False, capture_output=True)

    def _on_close(self, *_a):
        self._stop_pipe(self.rec, send_eos=True)
        self._stop_pipe(self.play, send_eos=False)
        self.rec = None
        self.play = None
        return False


class App(Gtk.Application):
    def __init__(self):
        super().__init__(
            application_id=APP_ID,
            flags=Gio.ApplicationFlags.FLAGS_NONE,
        )

    def do_activate(self):
        win = self.props.active_window
        if not win:
            win = MicTest(self)
        win.present()


def main():
    Gst.init(None)
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    return App().run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
