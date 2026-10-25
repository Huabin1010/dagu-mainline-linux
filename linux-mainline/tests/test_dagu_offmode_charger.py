#!/usr/bin/env python3
"""Boot decision and battery-frame checks for off-mode charging.

The desktop must still come up when a USB cable is online. Only a
charger wake (the flash-package androidboot.mode=charger path, a
charger boot reason, or a power-on reason without the power key)
skips it.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from dagu_offmode_charger import (  # noqa: E402
    BLACK,
    FRAME_SEC,
    GREEN,
    RED,
    REST_SEC,
    SWEEP_SEC,
    battery_box,
    bolt_columns,
    draw_fill,
    fill_shades,
    paint_columns,
    sweep_phase,
    vbus_from_flags,
    PON_KPDPWR,
    PON_USB_CHG,
    WHITE,
    BootHints,
    charger_wake,
    draw_battery,
    memory_surface,
    want_charger_mode,
    write_png,
    logical_rgb,
)

# This boot, taken off the tablet while the serial cable was plugged.
# No androidboot.mode=charger. The desktop must start.
LIVE_DESKTOP = (
    "androidboot.serialno=ab22268c androidboot.force_normal_boot=1 "
    "androidboot.slot_suffix=_b"
)


class DecisionTests(unittest.TestCase):
    def test_usb_cable_on_normal_boot_is_desktop(self) -> None:
        h = BootHints(cmdline=LIVE_DESKTOP, charger_online=True, pending=False)
        self.assertFalse(want_charger_mode(h))

    def test_stale_pending_and_usb_still_desktop(self) -> None:
        h = BootHints(cmdline=LIVE_DESKTOP, charger_online=True, pending=True)
        self.assertFalse(charger_wake(h))
        self.assertFalse(want_charger_mode(h))

    def test_mode_charger_enters(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger androidboot.serialno=ab22268c",
            charger_online=True,
        )
        self.assertTrue(want_charger_mode(h))

    def test_mode_charger_unplugged_is_desktop(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger",
            charger_online=False,
        )
        self.assertFalse(want_charger_mode(h))

    def test_warm_reboot_is_desktop_even_if_mode_says_charger(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger androidboot.bootreason=reboot",
            charger_online=True,
        )
        self.assertFalse(want_charger_mode(h))

    def test_power_key_reason_is_desktop(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger androidboot.bootreason=kpdpwr",
            charger_online=True,
        )
        self.assertFalse(want_charger_mode(h))

    def test_pon_power_key_overrides_charger_mode(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger",
            charger_online=True,
            pon_reason=PON_USB_CHG | PON_KPDPWR,
        )
        self.assertFalse(want_charger_mode(h))

    def test_pon_usb_without_key_enters(self) -> None:
        h = BootHints(cmdline=LIVE_DESKTOP, charger_online=True, pon_reason=PON_USB_CHG)
        self.assertTrue(want_charger_mode(h))

    def test_held_power_key_is_desktop(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger",
            charger_online=True,
            pwrkey_held=True,
        )
        self.assertFalse(want_charger_mode(h))

    def test_unknown_online_still_enters_on_mode_charger(self) -> None:
        h = BootHints(cmdline="androidboot.mode=charger", charger_online=None)
        self.assertTrue(want_charger_mode(h))


class VbusTests(unittest.TestCase):
    def test_port_manager_keeps_the_cable(self) -> None:
        self.assertTrue(vbus_from_flags([0, 1]))

    def test_both_absent_is_unplugged(self) -> None:
        self.assertFalse(vbus_from_flags([0, 0]))

    def test_unknown_is_not_an_unplug(self) -> None:
        self.assertIsNone(vbus_from_flags([None, None]))


class ShutdownContractTests(unittest.TestCase):
    """Power-off is a real power-off; ABL's charger boot brings the screen.

    A shutdown delay inhibitor kept logind waiting InhibitDelayMaxSec
    (20 s) on every power-off, and GDM respawned the greeter in that
    window: the "lock screen, then off" the tablet showed.
    """

    def test_nothing_delays_shutdown(self) -> None:
        src = (ROOT / "scripts" / "dagu_offmode_charger.py").read_text()
        self.assertNotIn("--what=shutdown", src)
        self.assertFalse((ROOT / "systemd" / "dagu-offmode-daemon.service").exists())

    def test_logind_keeps_the_default_delay(self) -> None:
        for path in (
            ROOT / "systemd" / "logind-dagu-power.conf",
            ROOT / "scripts" / "rootfs-desktop-setup.sh",
        ):
            self.assertNotIn("InhibitDelayMaxSec", path.read_text(), path)

    def test_rootfs_does_not_enable_the_daemon(self) -> None:
        setup = (ROOT / "scripts" / "rootfs-desktop-setup.sh").read_text()
        self.assertNotIn("dagu-offmode-charger daemon", setup)
        self.assertIn("rm -f /etc/systemd/system/dagu-offmode-daemon.service", setup)

    def test_shutdown_shows_the_console_and_darkens_last(self) -> None:
        # Text console on the panel while services stop; dark only after
        # / is read-only, in the systemd-shutdown hook.
        setup = (ROOT / "scripts" / "rootfs-desktop-setup.sh").read_text()
        block = setup.split("cat >/usr/local/sbin/dagu-shutdown-display", 1)[1]
        block = block.split("\nEOF\n", 1)[0]
        self.assertIn("VT_ACTIVATE", block)
        self.assertNotIn('echo 0 >"$bind"', block)
        self.assertNotIn("bl_power", block)
        final = (ROOT / "systemd" / "dagu-shutdown-final").read_text()
        self.assertIn("bl_power", final)
        self.assertLess(final.index("remount,ro"), final.index("bl_power"))

    def test_unplug_poweroff_is_orderly(self) -> None:
        src = (ROOT / "scripts" / "dagu_offmode_charger.py").read_text()
        body = src.split("def real_poweroff", 1)[1].split("\nclass ", 1)[0]
        calls = [ln for ln in body.splitlines() if "run([" in ln]
        self.assertTrue(calls, body)
        for ln in calls:
            self.assertIn('"poweroff"', ln)
            self.assertNotIn('"--force"', ln)



class PanelDarkTests(unittest.TestCase):
    """Screen-off is dark, and the kernel log never shows at a charger boot."""

    def setUp(self) -> None:
        self.panel = (
            ROOT / "overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c"
        ).read_text()
        self.src = (ROOT / "scripts" / "dagu_offmode_charger.py").read_text()

    def test_blank_turns_the_leds_off(self) -> None:
        self.assertIn("backlight_is_blank(bl)", self.panel)
        self.assertIn("ktz8866_led_off", self.panel)

    def test_first_reset_is_dark_until_video(self) -> None:
        prep = self.panel.split("static int l81a_prepare", 1)[1]
        self.assertLess(prep.index("bl_settling = true"), prep.index("l81a_reset(ctx)"))

    def test_charger_boot_holds_dark_until_the_screen(self) -> None:
        self.assertIn('__setup("androidboot.mode="', self.panel)
        self.assertIn("charger_dark", self.src)
        ui = self.src.split("def cmd_ui", 1)[1].split("\ndef ", 1)[0]
        # Nothing lights the panel before the battery is drawn.
        self.assertNotIn("unblank(saved)", ui[: ui.index("def show_battery")])
        # The slow systemctl reloads come after the first frame.
        body = ui[ui.index("    show_battery()\n") :]
        self.assertIn("hold_consoles", body)
        self.assertNotIn("hold_consoles", ui[: ui.index("    show_battery()\n")])

    def test_asleep_charger_screen_is_powered_down(self) -> None:
        blank = self.src.split("def blank_panel", 1)[1].split("\ndef ", 1)[0]
        self.assertIn("BL_POWER_OFF", blank)


class FrameTests(unittest.TestCase):
    def test_fill_tracks_percent(self) -> None:
        low = memory_surface()
        high = memory_surface()
        draw_battery(low, 40, False, 1.0)
        draw_battery(high, 100, False, 1.0)
        self.assertGreater(high.count(GREEN), low.count(GREEN) * 2)
        self.assertGreater(low.count(GREEN), 1000)
        self.assertLess(low.count(GREEN), high.count(GREEN))
        self.assertGreater(high.count(WHITE), 100)

    def test_charging_draws_a_bolt(self) -> None:
        still = memory_surface()
        moving = memory_surface()
        draw_battery(still, 60, False, 1.0)
        draw_battery(moving, 60, True, 1.0)
        self.assertGreater(moving.count(WHITE), still.count(WHITE))

    def test_animation_never_blanks_the_scanout(self) -> None:
        # Old loop: fill(BLACK) then redraw on the live scanout every
        # 0.35 s, so the panel showed black and half-drawn frames.
        back = memory_surface()
        scan = memory_surface()
        draw_battery(back, 62, True, 0.0)
        back.copy_to(scan)
        black = scan.count(BLACK)
        _x, _y, _bw, _bh, _t, ix, iy, iw, ih = battery_box(back)
        frames = []
        for i in range(40):
            draw_fill(back, 62, True, sweep_phase(i * FRAME_SEC))
            back.copy_to(scan, ix, iy, iw, ih)
            # The level never changes mid-animation: same black area.
            self.assertEqual(scan.count(BLACK), black)
            frames.append(bytes(scan.buf))
        # The highlight actually moves between frames.
        self.assertGreater(len(set(frames)), 20)

    def test_changed_columns_match_a_full_redraw(self) -> None:
        # The UI repaints only the columns that changed (plus the bolt).
        inc = memory_surface()
        iw = battery_box(inc)[7]
        bolt = set(bolt_columns(inc))
        prev = fill_shades(55, True, 0.0, iw)
        draw_battery(inc, 55, True, 0.0)
        for k in range(1, 80, 7):
            phase = sweep_phase(k * FRAME_SEC)
            shades = fill_shades(55, True, phase, iw)
            changed = [i for i in range(iw) if shades[i] != prev[i]]
            # A frame touches the band, not the whole battery.
            self.assertLess(len(changed), iw // 2 + iw // 8)
            paint_columns(inc, shades, changed, not bolt.isdisjoint(changed))
            prev = shades
            full = memory_surface()
            draw_battery(full, 55, True, phase)
            self.assertEqual(bytes(inc.buf), bytes(full.buf), phase)

    def test_region_copy_leaves_the_rest_alone(self) -> None:
        back = memory_surface()
        scan = memory_surface()
        scan.fill(RED)
        draw_battery(back, 50, True, 0.5)
        _x, _y, _bw, _bh, _t, ix, iy, iw, ih = battery_box(back)
        back.copy_to(scan, ix, iy, iw, ih)
        x0, y0, x1, y1 = scan.fb_rect(ix, iy, iw, ih)
        self.assertEqual(scan.count(RED), scan.w * scan.h - (x1 - x0 + 1) * (y1 - y0 + 1))

    def test_resting_sweep_is_the_plain_level(self) -> None:
        a = memory_surface()
        b = memory_surface()
        draw_battery(a, 70, True, sweep_phase(SWEEP_SEC + REST_SEC / 2))
        draw_battery(b, 70, True, 1.0)
        self.assertEqual(bytes(a.buf), bytes(b.buf))

    def test_png_has_battery_and_percent(self) -> None:
        fb = memory_surface()
        draw_battery(fb, 100, False, 1.0)
        w, h, rgb = logical_rgb(fb)
        out = Path(tempfile.mkdtemp()) / "full.png"
        write_png(out, w, h, rgb)
        self.assertGreater(out.stat().st_size, 1000)
        self.assertTrue(out.read_bytes().startswith(b"\x89PNG"))


if __name__ == "__main__":
    unittest.main()
