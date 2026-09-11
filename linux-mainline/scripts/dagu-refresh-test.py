#!/usr/bin/env python3
"""Fullscreen high-damage GTK4 animation for dagu scanout stress.

Moving black/white stripes plus a cyan bar force gnome-shell to upload a
new UBWC XR30 frame every ~8 ms — the same class of update that garbles
Settings while scrolling.
"""
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk

try:
    import cairo
except ImportError:  # python3-gi-cairo
    from gi.repository import cairo


def paint(cr, w, h, t):
    period = 48
    off = (t * 16) % (period * 2)
    x = -period * 2 + off
    while x < w + period:
        if (int(x + off) // period) % 2 == 0:
            cr.set_source_rgb(1, 1, 1)
        else:
            cr.set_source_rgb(0, 0, 0)
        cr.rectangle(x, 0, period, h)
        cr.fill()
        x += period
    cr.set_source_rgb(0.0, 0.75, 1.0)
    cr.rectangle(0, (t * 10) % max(h, 1), w, 24)
    cr.fill()
    cr.set_source_rgb(1.0, 0.2, 0.0)
    cr.select_font_face("Sans")
    cr.set_font_size(48)
    cr.move_to(48, 96)
    cr.show_text(f"dagu refresh test frame {t}")


class Anim(Gtk.DrawingArea):
    def __init__(self):
        super().__init__()
        self.t = 0
        self.saved = False
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.set_draw_func(self.on_draw)
        GLib.timeout_add(8, self.tick)

    def tick(self):
        self.t += 1
        self.queue_draw()
        return True

    def on_draw(self, _area, cr, w, h, *_):
        if w <= 0 or h <= 0:
            return
        paint(cr, w, h, self.t)
        if self.saved or self.t < 30:
            return
        self.saved = True
        try:
            img = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
            paint(cairo.Context(img), w, h, self.t)
            img.write_to_png("/tmp/dagu-client-frame.png")
        except Exception as exc:
            Path("/tmp/dagu-client-frame.err").write_text(repr(exc))


def on_activate(app):
    win = Gtk.ApplicationWindow(application=app, title="dagu-refresh-test")
    win.set_decorated(False)
    win.fullscreen()
    win.set_child(Anim())
    win.present()


def main():
    app = Gtk.Application(application_id="dev.dagu.refresh")
    app.connect("activate", on_activate)
    app.run()


if __name__ == "__main__":
    main()
