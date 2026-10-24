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
    GREEN,
    vbus_from_flags,
    PON_KPDPWR,
    PON_USB_CHG,
    WHITE,
    BootHints,
    charger_wake,
    divert_shutdown,
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


class ShutdownTests(unittest.TestCase):
    def test_poweroff_with_cable_stays_on_battery(self) -> None:
        self.assertEqual(divert_shutdown("poweroff", True), "ui")

    def test_poweroff_without_cable_really_powers_off(self) -> None:
        self.assertEqual(divert_shutdown("poweroff", False), "allow")

    def test_reboot_is_not_diverted(self) -> None:
        self.assertEqual(divert_shutdown("reboot", True), "allow")


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
