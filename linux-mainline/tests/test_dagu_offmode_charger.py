#!/usr/bin/env python3
"""Unit tests for dagu off-mode charger boot decision.

Run:
  python3 linux-mainline/tests/test_dagu_offmode_charger.py
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from dagu_offmode_charger import (  # noqa: E402
    PON_CBLPWR,
    PON_HARD_RESET,
    PON_KPDPWR,
    PON_USB_CHG,
    BootHints,
    _gate_should_wait,
    bootreason_token,
    parse_pon_reason,
    parse_shutdown_mode,
    want_charger_mode,
)


class CmdlineTests(unittest.TestCase):
    def test_mode_charger(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger androidboot.serialno=x",
            charger_online=True,
        )
        self.assertTrue(want_charger_mode(h))

    def test_mode_charger_unplugged_goes_desktop(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger",
            pending=True,
            charger_online=False,
        )
        self.assertFalse(want_charger_mode(h))

    def test_mode_charger_pwrkey_goes_desktop(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=charger",
            charger_online=True,
            pwrkey_held=True,
        )
        self.assertFalse(want_charger_mode(h))

    def test_mode_normal_wins_over_pending(self) -> None:
        h = BootHints(
            cmdline="androidboot.mode=normal",
            pending=True,
            charger_online=True,
        )
        self.assertFalse(want_charger_mode(h))

    def test_bootreason_usb(self) -> None:
        h = BootHints(cmdline="androidboot.bootreason=usb", charger_online=True)
        self.assertTrue(want_charger_mode(h))

    def test_bootreason_usb_but_charger_gone(self) -> None:
        h = BootHints(cmdline="androidboot.bootreason=usb", charger_online=False)
        self.assertFalse(want_charger_mode(h))

    def test_bootreason_kpdpwr(self) -> None:
        h = BootHints(
            cmdline="androidboot.bootreason=kpdpwr",
            pending=True,
            charger_online=True,
        )
        self.assertFalse(want_charger_mode(h))

    def test_bootreason_reboot_charger(self) -> None:
        h = BootHints(
            cmdline="androidboot.bootreason=reboot,charger",
            charger_online=True,
        )
        self.assertEqual(bootreason_token(h.cmdline), "charger")
        self.assertTrue(want_charger_mode(h))

    def test_warm_reboot(self) -> None:
        h = BootHints(
            cmdline="androidboot.bootreason=reboot",
            pending=True,
            charger_online=True,
        )
        self.assertFalse(want_charger_mode(h))


class PonTests(unittest.TestCase):
    def test_usb_without_key(self) -> None:
        h = BootHints(pon_reason=PON_USB_CHG, charger_online=True)
        self.assertTrue(want_charger_mode(h))

    def test_cblpwr(self) -> None:
        h = BootHints(pon_reason=PON_CBLPWR)
        self.assertTrue(want_charger_mode(h))

    def test_kpdpwr_wins_over_usb(self) -> None:
        h = BootHints(
            pon_reason=PON_KPDPWR | PON_USB_CHG,
            pending=True,
            charger_online=True,
        )
        self.assertFalse(want_charger_mode(h))

    def test_hard_reset(self) -> None:
        h = BootHints(pon_reason=PON_HARD_RESET, charger_online=True, pending=True)
        self.assertFalse(want_charger_mode(h))

    def test_parse_hex(self) -> None:
        self.assertEqual(parse_pon_reason("0x10"), 0x10)
        self.assertEqual(parse_pon_reason("80"), 0x80)
        self.assertIsNone(parse_pon_reason(""))


class PendingFallbackTests(unittest.TestCase):
    def test_pending_with_charger(self) -> None:
        h = BootHints(pending=True, charger_online=True)
        self.assertTrue(want_charger_mode(h))

    def test_pending_without_charger(self) -> None:
        h = BootHints(pending=True, charger_online=False)
        self.assertFalse(want_charger_mode(h))

    def test_charger_without_pending_is_normal_boot(self) -> None:
        # Power button while a cable is already in: GNOME, not charger UI.
        h = BootHints(pending=False, charger_online=True)
        self.assertFalse(want_charger_mode(h))

    def test_pwrkey_held_blocks_pending(self) -> None:
        h = BootHints(pending=True, charger_online=True, pwrkey_held=True)
        self.assertFalse(want_charger_mode(h))

    def test_empty_is_graphical(self) -> None:
        self.assertFalse(want_charger_mode(BootHints()))


class ShutdownParseTests(unittest.TestCase):
    def test_poweroff(self) -> None:
        text = "USEC=1\nWARN_WALL=1\nMODE=poweroff\n"
        self.assertEqual(parse_shutdown_mode(text), "poweroff")

    def test_reboot(self) -> None:
        self.assertEqual(parse_shutdown_mode("MODE=reboot\n"), "reboot")


class GateWaitTests(unittest.TestCase):
    def test_normal_boot_does_not_wait(self) -> None:
        self.assertFalse(_gate_should_wait("", False, None))

    def test_pending_waits(self) -> None:
        self.assertTrue(_gate_should_wait("", True, None))

    def test_abl_charger_mode_waits(self) -> None:
        self.assertTrue(_gate_should_wait("androidboot.mode=charger", False, None))


if __name__ == "__main__":
    unittest.main()
