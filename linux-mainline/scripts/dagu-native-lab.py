#!/usr/bin/env python3
"""GTK4 system-layer twin of dagu-pipeline-lab.html (light / slow).

Same compositor contract as identity Chrome lab:
  Mutter transform 0, scale 1.0, no dagu-scanout pump.
No Chromium / Ozone / Viz. One Wayland toplevel, GSK ngl.

Default scene matches HTML slow:
  3 stacked cards auto-scrolling, 2 flying tiles with the same vx/vy.
Rotation is omitted (GTK widget transform is integer move only).

On tablet:
  /usr/local/sbin/dagu-lab-identity-native.sh
  python3 /usr/local/sbin/dagu-native-lab.py --measure
From host:
  python3 linux-mainline/scripts/dagu-native-lab.py --host
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HOST = os.environ.get("DAGU_SSH_HOST", "192.168.7.2")
ROOT = Path(__file__).resolve().parents[1]
KEY = Path(os.environ.get("DAGU_SSH_KEY", str(ROOT / "out/id_dagu")))
DUMP = Path("/tmp/dagu-native-lab-dump.json")
TR = Path("/sys/kernel/debug/tracing")
CLIPDIR = Path(os.environ.get("DAGU_LAB_CLIPS", "/var/lib/dagu-pipeline-lab"))

FLY = (
    {"key": "scroll", "w": 280, "h": 160, "vx": 4.2, "vy": 2.6, "clip": "lab-scroll-720.mp4"},
    {"key": "hevc", "w": 240, "h": 140, "vx": -3.6, "vy": 3.1, "clip": "lab-hevc-720.mp4"},
)
# HTML light uses 3 cards on a landscape CSS viewport. Identity native is
# physical 1600×2560, so stack enough cards that 慢滑 actually travels.
CARD_N = 24
CARD_COLORS = (
    ("#1a3a8a", "#6a1b4a", "#14532d"),
    ("#16306e", "#7a2458", "#0f3d24"),
    ("#12285c", "#8a2c66", "#0b2e1b"),
)


def ssh_base() -> list[str]:
    return [
        "ssh", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=12",
        f"root@{HOST}",
    ]


def is_tablet() -> bool:
    return Path("/sys/class/drm/card0-DSI-1").exists()


def read_int(path: str) -> int | None:
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return None


def vblank_fps() -> float | None:
    p = Path("/sys/kernel/debug/dri/0/crtc-0/status")
    if not p.is_file():
        return None
    for line in p.read_text(errors="replace").splitlines():
        if "vblank" not in line:
            continue
        for tok in line.split():
            if tok.startswith("fps:"):
                try:
                    return float(tok.split(":", 1)[1])
                except ValueError:
                    return None
    return None


def venus_irq() -> int | None:
    irq = Path("/proc/interrupts")
    if not irq.is_file():
        return None
    total = 0
    hit = False
    for line in irq.read_text(errors="replace").splitlines():
        if "venus" not in line.lower() and "venus" not in line:
            continue
        hit = True
        for tok in line.split()[1:]:
            if tok.isdigit():
                total += int(tok)
    return total if hit else None


def video14_open() -> int:
    n = 0
    if not Path("/dev/video14").exists():
        return 0
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        fd = proc / "fd"
        try:
            for e in fd.iterdir():
                try:
                    if os.readlink(e) == "/dev/video14":
                        n += 1
                        break
                except OSError:
                    pass
        except OSError:
            pass
    return n


def chrome_running() -> bool:
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cmd = (proc / "cmdline").read_bytes()
        except OSError:
            continue
        if b"/usr/lib/chromium/chromium" in cmd:
            return True
    return False


def mem_avail_mb() -> int | None:
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        return None
    return None


def hw_stats() -> dict:
    return {
        "gpu_busy": read_int("/sys/class/drm/card0/device/gpu_busy_percent"),
        "gpu_hz": read_int("/sys/class/devfreq/3d00000.gpu/cur_freq"),
        "venus_irq": venus_irq(),
        "vblank_fps": vblank_fps(),
        "video14": Path("/dev/video14").exists(),
        "video14_open": video14_open(),
        "chrome": chrome_running(),
        "mem_avail_mb": mem_avail_mb(),
        "gsk": os.environ.get("GSK_RENDERER"),
        "t": time.monotonic(),
    }


def hw_stats_light() -> dict:
    """UI-thread safe: no /proc fd walk, no DPU debugfs."""
    return {
        "gsk": os.environ.get("GSK_RENDERER"),
        "t": time.monotonic(),
        "chrome": False,
        "video14_open": 0,
    }


def pct(vals: list[float], p: float) -> float | None:
    if not vals:
        return None
    s = sorted(vals)
    i = min(len(s) - 1, max(0, int(len(s) * p)))
    return s[i]


def _trace_ts(raw: str, ev: str) -> list[float]:
    ts: list[float] = []
    for line in raw.splitlines():
        if ev not in line or line[:1] == "#":
            continue
        for p in line.split():
            if p.endswith(":") and p[:-1].replace(".", "", 1).isdigit():
                try:
                    ts.append(float(p[:-1]))
                    break
                except ValueError:
                    pass
    return ts


def _gap_summary(ts: list[float]) -> dict:
    gaps = [1000.0 * (b - a) for a, b in zip(ts, ts[1:]) if b >= a]
    over = [g for g in gaps if g > 50]
    span = (ts[-1] - ts[0]) if len(ts) > 1 else 0
    return {
        "n": len(ts),
        "hz": round(len(ts) / span, 2) if span > 0 else 0,
        "max": round(max(gaps), 1) if gaps else None,
        "p50": round(sorted(gaps)[len(gaps) // 2], 2) if gaps else None,
        "gt50": len(over),
        "gt50_ms": [round(x, 1) for x in sorted(over, reverse=True)[:10]],
        "span": round(span, 3),
    }


def kickoff_window(seconds: float = 8.0, quiet: bool = True) -> dict:
    if not quiet:
        (TR / "tracing_on").write_text("0\n")
        (TR / "buffer_size_kb").write_text("8192\n")
        (TR / "events/dpu/dpu_enc_kickoff/enable").write_text("1\n")
        vblank_ev = TR / "events/dpu/dpu_crtc_vblank_cb/enable"
        if vblank_ev.parent.is_dir():
            vblank_ev.write_text("1\n")
        (TR / "tracing_on").write_text("1\n")
    (TR / "trace").write_text("")
    time.sleep(seconds)
    raw = (TR / "trace").read_text(errors="replace")
    kick = _gap_summary(_trace_ts(raw, "dpu_enc_kickoff"))
    kick["vblank"] = _gap_summary(_trace_ts(raw, "dpu_crtc_vblank_cb"))
    kick["quiet"] = quiet
    return kick


def verdict_of(kick: dict, dump: dict, hw: dict) -> dict:
    hz = kick.get("hz") or 0
    gt50 = kick.get("gt50")
    chrome = bool(hw.get("chrome"))
    p50 = dump.get("p50")
    system_ok = (hz >= 115.0) and (gt50 == 0)
    system_hole = (hz < 110.0) or (gt50 is not None and gt50 >= 3)
    if chrome:
        blame = "chrome-still-running"
    elif system_ok:
        blame = "chrome-suspect"
    elif system_hole:
        blame = "system-hole"
    else:
        blame = "ambiguous"
    return {
        "target_kickoff_hz": 120,
        "system_ok": system_ok,
        "system_hole": system_hole,
        "blame": blame,
        "p50_ok": p50 is not None and p50 <= 9,
        "chrome": chrome,
        "note": (
            "system-ok + no chrome → hole is on the Chrome/Ozone path; "
            "system-hole → Mutter/DPU/client commit path already drops kickoffs"
        ),
    }


def load_dump() -> dict:
    if not DUMP.is_file():
        return {}
    try:
        return json.loads(DUMP.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def on_device_measure(seconds: float = 8.0) -> dict:
    dump0 = load_dump()
    kick = kickoff_window(seconds)
    dump1 = load_dump()
    hw0 = hw_stats()
    hw1 = hw0
    out = {
        "kind": "native-identity",
        "seconds": seconds,
        "dump_before": dump0,
        "dump_after": dump1,
        "hw_before": hw0,
        "hw_after": hw1,
        "kickoff": kick,
        "verdict": verdict_of(kick, dump1, hw1),
    }
    dest = Path("/tmp/dagu-native-lab-measure.json")
    dest.write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return out


def host_main() -> int:
    ssh = ssh_base()
    scp = [
        "scp", "-i", str(KEY), "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
    ]
    here = Path(__file__)
    ident = ROOT / "scripts" / "dagu-lab-identity-native.sh"
    orient = ROOT / "scripts" / "dagu-mutter-orientation.py"
    subprocess.run(scp + [
        str(here), str(ident), str(orient), f"root@{HOST}:/tmp/",
    ], check=True)
    subprocess.run(ssh + [
        "install -m755 /tmp/dagu-native-lab.py /usr/local/sbin/dagu-native-lab.py; "
        "install -m755 /tmp/dagu-lab-identity-native.sh /usr/local/sbin/dagu-lab-identity-native.sh; "
        "install -m755 /tmp/dagu-mutter-orientation.py /usr/local/sbin/dagu-mutter-orientation.py; "
        "/usr/local/sbin/dagu-lab-identity-native.sh"
    ], check=True)
    for _ in range(20):
        time.sleep(1)
        r = subprocess.run(
            ssh + ["test -s /tmp/dagu-native-lab-dump.json"],
            check=False,
        )
        if r.returncode == 0:
            break
    else:
        subprocess.run(ssh + ["echo '--- native log ---'; tail -80 /tmp/dagu-native-lab.log"], check=False)
        print("native lab did not write dump", file=sys.stderr)
        return 2
    time.sleep(3.0)
    proc = subprocess.run(
        ssh + ["python3 /usr/local/sbin/dagu-native-lab.py --measure"],
        check=False,
    )
    out_host = ROOT / "out" / "display-stress"
    out_host.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = out_host / f"dagu-native-lab-{stamp}.json"
    subprocess.run(
        scp + [f"root@{HOST}:/tmp/dagu-native-lab-measure.json", str(dest)],
        check=False,
    )
    shot = Path("/usr/local/sbin/dagu-gnome-screenshot.sh")
    subprocess.run(ssh + [
        f"test -x {shot} && {shot} --local /tmp/dagu-native-lab.png || true"
    ], check=False)
    subprocess.run(
        scp + [f"root@{HOST}:/tmp/dagu-native-lab.png", str(out_host / f"dagu-native-lab-{stamp}.png")],
        check=False,
    )
    if dest.is_file():
        print(dest.read_text())
    return proc.returncode


def try_gst_paintable(clip: Path):
    try:
        import gi
        gi.require_version("Gst", "1.0")
        from gi.repository import Gst
    except (ImportError, ValueError):
        return None, None
    Gst.init(None)
    sink = Gst.ElementFactory.make("gtk4paintablesink", None)
    if sink is None:
        return None, None
    play = Gst.ElementFactory.make("playbin", None)
    if play is None:
        return None, None
    play.set_property("uri", clip.resolve().as_uri())
    play.set_property("video-sink", sink)
    play.set_property("flags", 0x00000001 | 0x00000040)
    play.set_state(Gst.State.PLAYING)

    def _loop(_bus, msg, pipeline):
        if msg.type == Gst.MessageType.EOS:
            pipeline.seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH, 0)
        return True

    bus = play.get_bus()
    bus.add_signal_watch()
    bus.connect("message", _loop, play)
    try:
        paintable = sink.get_property("paintable")
    except Exception:
        paintable = None
    return play, paintable


def run_app() -> int:
    os.environ.setdefault("GDK_BACKEND", "wayland")
    os.environ.setdefault("GSK_RENDERER", "gl")
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, GLib, Gtk

    want_video = "--video" in sys.argv
    scene = "slow"
    auto = 0.7
    view_y = 0.0
    last_us = 0
    last_hud_us = 0
    dts: list[float] = []
    holes: list[dict] = []
    hw: dict = {}
    pipelines: list = []
    dbg = {"feed_max": 0.0, "win_h": 0, "auto": 0.0}

    css = Gtk.CssProvider()
    css.load_from_data(b"""
    window.dagu-native-lab { background: #020309; }
    .dagu-hud {
      background: rgba(4,6,12,0.92);
      padding: 8px 10px;
      border-bottom: 1px solid #2a3350;
    }
    .dagu-meter {
      color: #3dff9a;
      font-family: monospace;
      font-weight: 700;
      font-size: 13px;
    }
    .dagu-card {
      border-radius: 18px;
      min-height: 160px;
      margin-top: -18px;
    }
    .dagu-card:first-child { margin-top: 8px; }
    .dagu-card label {
      color: #f4f7ff;
      font-weight: 900;
      font-size: 20px;
      padding: 110px 0 12px 14px;
    }
    .dagu-flyer {
      border-radius: 12px;
      background: #1a3a8a;
    }
    button.dagu-btn {
      background: #1a2233;
      color: #e8edf7;
      font-weight: 800;
      padding: 5px 10px;
      border-radius: 6px;
      border: none;
    }
    button.dagu-btn.on { background: #2ad47a; color: #044114; }
    """)
    Gtk.StyleContext.add_provider_for_display(
        Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )

    def set_scene(name: str, buttons: dict):
        nonlocal scene, auto
        scene = name
        auto = 0.7 if name == "slow" else (1.6 if name == "chaos" else 0.0)
        for key, btn in buttons.items():
            if key == name:
                btn.add_css_class("on")
            else:
                btn.remove_css_class("on")

    def snapshot() -> dict:
        s = dts[:]
        p50 = pct(s, 0.5)
        p99 = pct(s, 0.99)
        fps = (1000.0 / (sum(s) / len(s))) if s else None
        return {
            "kind": "native",
            "scene": scene,
            "n": len(s),
            "videos": sum(1 for p in pipelines if p is not None),
            "fps": None if fps is None else round(fps, 1),
            "p50": None if p50 is None else round(p50, 2),
            "p99": None if p99 is None else round(p99, 2),
            "max": None if not s else round(max(s), 2),
            "holes": len(holes),
            "y": round(view_y, 1),
            "feed_max": dbg["feed_max"],
            "win_h": dbg["win_h"],
            "auto": dbg["auto"],
            "hw": hw,
            "chrome": hw.get("chrome"),
        }

    def write_dump(_=None):
        nonlocal hw
        try:
            hw = hw_stats_light()
        except Exception:
            hw = {}
        snap = snapshot()
        try:
            DUMP.write_text(json.dumps(snap) + "\n")
        except OSError:
            pass
        return True

    def reset_stats():
        dts.clear()
        holes.clear()
        return False

    def on_activate(app: Gtk.Application):
        nonlocal view_y
        win = Gtk.ApplicationWindow(application=app, title="dagu-native-lab")
        win.add_css_class("dagu-native-lab")
        win.set_decorated(False)
        win.set_resizable(False)
        win.set_default_size(1600, 2560)
        win.set_size_request(1600, 2560)
        win.fullscreen()

        overlay = Gtk.Overlay()
        overlay.set_hexpand(True)
        overlay.set_vexpand(True)
        overlay.set_size_request(1600, 2560)
        overlay.set_overflow(Gtk.Overflow.HIDDEN)
        win.set_child(overlay)

        feed = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        feed.set_margin_start(10)
        feed.set_margin_end(10)
        feed.set_margin_top(88)
        for i in range(CARD_N):
            a, b, c = CARD_COLORS[i % len(CARD_COLORS)]
            card = Gtk.Box()
            card.add_css_class("dagu-card")
            card.set_size_request(1560, 160)
            card.set_hexpand(True)
            lab = Gtk.Label(label=f"GPU 图层 {i:02d}", xalign=0)
            card.append(lab)
            color = Gtk.CssProvider()
            color.load_from_data(
                f".dagu-card-{i} {{ background: linear-gradient(135deg,{a},{b} {30 + (i % 6) * 12}%,{c}); }}"
                .encode()
            )
            card.add_css_class(f"dagu-card-{i}")
            card.get_style_context().add_provider(color, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
            feed.append(card)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.NEVER)
        scroll.set_hexpand(True)
        scroll.set_vexpand(True)
        scroll.set_child(feed)
        overlay.set_child(scroll)
        vadj = scroll.get_vadjustment()

        arena = Gtk.Fixed()
        arena.set_hexpand(True)
        arena.set_vexpand(True)
        overlay.add_overlay(arena)

        flock = []
        for i, spec in enumerate(FLY):
            box = Gtk.Box()
            box.add_css_class("dagu-flyer")
            box.set_size_request(spec["w"], spec["h"])
            color = Gtk.CssProvider()
            hue = "#2ad47a" if i == 0 else "#ff5d7a"
            color.load_from_data(f".dagu-flyer-{i} {{ background: {hue}; }}".encode())
            box.add_css_class(f"dagu-flyer-{i}")
            box.get_style_context().add_provider(color, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
            if want_video:
                clip = CLIPDIR / spec["clip"]
                if clip.is_file():
                    play, paintable = try_gst_paintable(clip)
                    pipelines.append(play)
                    if paintable is not None:
                        pic = Gtk.Picture.new_for_paintable(paintable)
                        pic.set_size_request(spec["w"], spec["h"])
                        pic.set_can_shrink(True)
                        pic.set_content_fit(Gtk.ContentFit.COVER)
                        box.append(pic)
            x = 36 + i * 70
            y = 112 + i * 50
            arena.put(box, x, y)
            flock.append({
                "w": spec["w"], "h": spec["h"],
                "vx": spec["vx"], "vy": spec["vy"],
                "x": float(x), "y": float(y),
                "widget": box,
            })

        hud = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        hud.add_css_class("dagu-hud")
        hud.set_hexpand(True)
        meters = Gtk.Label(xalign=0)
        meters.add_css_class("dagu-meter")
        meters.set_hexpand(True)
        hud.append(meters)
        btns = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        buttons = {}
        for name, label in (("idle", "静置"), ("slow", "慢滑"), ("chaos", "乱窜")):
            b = Gtk.Button(label=label)
            b.add_css_class("dagu-btn")
            b.connect("clicked", lambda _w, n=name: set_scene(n, buttons))
            buttons[name] = b
            btns.append(b)
        hud.append(btns)
        set_scene("slow", buttons)
        overlay.add_overlay(hud)
        hud.set_halign(Gtk.Align.FILL)
        hud.set_valign(Gtk.Align.START)

        def feed_max() -> float:
            return max(0.0, vadj.get_upper() - vadj.get_page_size())

        def on_tick(widget, clock):
            nonlocal last_us, last_hud_us, view_y, auto
            now = clock.get_frame_time()
            if last_us:
                dt = (now - last_us) / 1000.0
                dts.append(dt)
                if len(dts) > 180:
                    dts.pop(0)
                if dt > 50:
                    holes.append({"t": now // 1000, "dt": round(dt, 1)})
                # Label set_text every frame walks ATK/AT-SPI on the GTK
                # thread (~90ms hitch). HUD is 4 Hz; rAF still counted.
                if not last_hud_us or now - last_hud_us >= 250_000:
                    p50 = pct(dts, 0.5)
                    meters.set_text(
                        f"rAF {dt:.1f}ms   FPS {1000.0 / dt:.1f}   "
                        f"p50 {p50:.1f}   >50 {len(holes)}   "
                        f"v14 {hw.get('video14_open', '—')}   "
                        f"chrome {int(bool(hw.get('chrome')))}   "
                        f"{scene}"
                    )
                    last_hud_us = now
            last_us = now
            ww = overlay.get_width() or 1600
            hh = overlay.get_height() or 2560
            dbg["win_h"] = hh
            dbg["feed_max"] = feed_max()
            dbg["auto"] = auto
            scale = 1.6 if scene == "chaos" else (0.35 if scene == "idle" else 0.85)
            for f in flock:
                f["x"] += f["vx"] * scale
                f["y"] += f["vy"] * scale
                if f["x"] < -20 or f["x"] > ww - f["w"] + 20:
                    f["vx"] *= -1
                if f["y"] < 70 or f["y"] > hh - f["h"] + 20:
                    f["vy"] *= -1
                f["x"] = max(-40.0, min(ww - 20.0, f["x"]))
                f["y"] = max(70.0, min(hh - 20.0, f["y"]))
                arena.move(f["widget"], int(f["x"]), int(f["y"]))
            if auto:
                view_y += auto * 8.0
                top = feed_max()
                if view_y >= top or view_y <= 0:
                    auto = -auto
                    view_y = max(0.0, min(top, view_y))
                vadj.set_value(view_y)
            return True

        overlay.add_tick_callback(on_tick)
        GLib.timeout_add(1000, write_dump)
        GLib.timeout_add(2000, reset_stats)
        write_dump()
        win.present()

    app = Gtk.Application(application_id="dev.dagu.nativelab")
    app.connect("activate", on_activate)
    return app.run([])


def main() -> int:
    if "--host" in sys.argv:
        return host_main()
    if "--measure" in sys.argv:
        on_device_measure()
        return 0
    if not is_tablet() and "--app" not in sys.argv:
        return host_main()
    return run_app()


if __name__ == "__main__":
    raise SystemExit(main())
