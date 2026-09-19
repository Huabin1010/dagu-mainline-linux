#!/usr/bin/env python3
"""Unit tests for Nanosic 803 leftover vs real KEY_UP.

Locks the chord KEY_UP that shipped as leftover once:

- Ctrl+C then C up while Ctrl stays held is a real HID boot KEY_UP
  (modifier=LCtrl, keys=00). Dropping it leaves C down; mutter 50
  compositor-repeat then fires Ctrl+C until Ctrl is released.
- GENI leftover empty 0x05 after 0x22 / GPIO-low / bounce / stale
  seq is still leftover and must drop.
- True empty (no modifier) still uses the 80ms KEY_DOWN debounce.
  Modifier-only must not: a fast chord KEY_UP lands inside 80ms.
"""
from __future__ import annotations

import ctypes
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OVERLAY_KBD = ROOT / "overlays" / "linux" / "drivers" / "input" / "keyboard"
HOST_C = Path(__file__).resolve().parent / "nanosic_kbd_ghost_host.c"
HEADER = OVERLAY_KBD / "nanosic-kbd-ghost.h"

HID_LCTRL = 0x01
HID_LSHIFT = 0x02
HID_C = 0x06
HID_T = 0x17


def _old_always_drop_mod_only(report: bytes) -> bool:
    """The shipped rule that left C down after one Ctrl+C."""
    keys_zero = all(b == 0 for b in report[3:9])
    return bool(keys_zero and report[1])


def _rpt(mod: int = 0, *keys: int) -> bytes:
    slot = list(keys) + [0] * (6 - len(keys))
    return bytes([0x05, mod, 0x00, *slot[:6]])


class GhostLib:
    def __init__(self, path: Path) -> None:
        self._so = ctypes.CDLL(str(path))
        fn = self._so.nanosic_ghost_empty_host
        fn.argtypes = [
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
        ]
        fn.restype = ctypes.c_int
        self._fn = fn
        empty = self._so.nanosic_kbd_empty_host
        empty.argtypes = [ctypes.c_char_p]
        empty.restype = ctypes.c_int
        self._empty = empty

    def ghost(
        self,
        report: bytes,
        *,
        seen_vendor: bool = False,
        have_kbd_down: bool = True,
        have_vendor: bool = False,
        rx_have_prev_seq: bool = True,
        rx_seq_delta: int = 1,
        gpio_pending: bool = False,
        in_empty_debounce: bool = False,
        in_vendor_bounce: bool = False,
    ) -> bool:
        if len(report) != 9:
            raise ValueError(f"boot report is 9 bytes, got {len(report)}")
        return bool(
            self._fn(
                report,
                int(seen_vendor),
                int(have_kbd_down),
                int(have_vendor),
                int(rx_have_prev_seq),
                int(rx_seq_delta),
                int(gpio_pending),
                int(in_empty_debounce),
                int(in_vendor_bounce),
            )
        )

    def kbd_empty(self, report: bytes) -> bool:
        return bool(self._empty(report))


def compile_ghost_lib() -> Path:
    if not HEADER.is_file():
        raise FileNotFoundError(HEADER)
    if not HOST_C.is_file():
        raise FileNotFoundError(HOST_C)
    tmp = Path(tempfile.mkdtemp(prefix="nanosic-kbd-ghost-"))
    so = tmp / "nanosic_kbd_ghost.so"
    subprocess.check_call(
        [
            "cc",
            "-shared",
            "-fPIC",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-DNANOSIC_GHOST_HOST",
            f"-I{OVERLAY_KBD}",
            "-o",
            str(so),
            str(HOST_C),
        ]
    )
    return so


class TestNanosicKbdGhost(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.lib = GhostLib(compile_ghost_lib())

    def test_old_always_drop_mod_only_is_the_ctrl_c_bug(self) -> None:
        report = _rpt(HID_LCTRL)
        self.assertTrue(
            _old_always_drop_mod_only(report),
            "document the rule that dropped C KEY_UP",
        )
        self.assertFalse(
            self.lib.ghost(report),
            "replacement must inject C KEY_UP while Ctrl is held",
        )

    def test_ctrl_c_release_c_while_ctrl_held_is_real_key_up(self) -> None:
        """MCU after Ctrl+C: modifier=LCtrl, keys=00. That releases C."""
        report = _rpt(HID_LCTRL)
        self.assertFalse(self.lib.kbd_empty(report))
        self.assertFalse(
            self.lib.ghost(report),
            "C KEY_UP while Ctrl is held must reach HID or mutter repeats Ctrl+C",
        )

    def test_fast_chord_key_up_inside_80ms_debounce_is_still_real(self) -> None:
        """A tap Ctrl+C KEY_UP lands inside the empty-report debounce."""
        self.assertFalse(
            self.lib.ghost(_rpt(HID_LCTRL), in_empty_debounce=True),
            "80ms empty debounce must not eat a modifier-only chord KEY_UP",
        )

    def test_ctrl_shift_n_style_mod_only_is_real_key_up(self) -> None:
        self.assertFalse(self.lib.ghost(_rpt(HID_LCTRL | HID_LSHIFT)))

    def test_ctrl_only_first_press_is_not_ghost(self) -> None:
        self.assertFalse(
            self.lib.ghost(_rpt(HID_LCTRL), have_kbd_down=False)
        )

    def test_ctrl_c_down_is_not_ghost(self) -> None:
        self.assertFalse(self.lib.ghost(_rpt(HID_LCTRL, HID_C)))

    def test_ctrl_t_down_is_not_ghost(self) -> None:
        self.assertFalse(self.lib.ghost(_rpt(HID_LCTRL, HID_T)))

    def test_leftover_mod_only_after_vendor_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(HID_LCTRL), seen_vendor=True))

    def test_leftover_mod_only_gpio_pending_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(HID_LCTRL), gpio_pending=True))

    def test_leftover_mod_only_vendor_bounce_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(HID_LCTRL), in_vendor_bounce=True))

    def test_leftover_mod_only_stale_seq_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(HID_LCTRL), rx_seq_delta=0))
        self.assertTrue(self.lib.ghost(_rpt(HID_LCTRL), rx_seq_delta=-1))
        self.assertTrue(self.lib.ghost(_rpt(HID_LCTRL), rx_seq_delta=3))

    def test_mod_only_seq_plus_two_is_real_key_up(self) -> None:
        self.assertFalse(self.lib.ghost(_rpt(HID_LCTRL), rx_seq_delta=2))

    def test_true_empty_key_up_after_hold_is_real(self) -> None:
        self.assertTrue(self.lib.kbd_empty(_rpt()))
        self.assertFalse(self.lib.ghost(_rpt()))

    def test_true_empty_after_vendor_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(), seen_vendor=True))

    def test_true_empty_inside_80ms_debounce_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(), in_empty_debounce=True))

    def test_true_empty_gpio_pending_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(), gpio_pending=True))

    def test_true_empty_no_prior_key_is_real(self) -> None:
        self.assertFalse(self.lib.ghost(_rpt(), have_kbd_down=False))

    def test_ctrl_c_stream_injects_c_key_up(self) -> None:
        """Ctrl down, C down, C up while Ctrl held: three injects, last is C up."""
        stream = (
            _rpt(HID_LCTRL),
            _rpt(HID_LCTRL, HID_C),
            _rpt(HID_LCTRL),
        )
        injected: list[bytes] = []
        last: bytes | None = None
        have_down = False
        for report in stream:
            self.assertFalse(
                self.lib.ghost(report, have_kbd_down=have_down),
                f"stream dropped {report.hex()}",
            )
            if last == report:
                continue
            last = report
            injected.append(report)
            have_down = not self.lib.kbd_empty(report)
        self.assertEqual(injected, list(stream))
        self.assertEqual(injected[-1][1], HID_LCTRL)
        self.assertEqual(injected[-1][3:], bytes(6))
        self.assertTrue(have_down, "Ctrl still held after C KEY_UP")

    def test_vendor_leftover_after_ctrl_c_does_not_inject(self) -> None:
        """0x22 keepalive leftover with Ctrl still in p[1] stays leftover."""
        self.assertTrue(
            self.lib.ghost(
                _rpt(HID_LCTRL),
                seen_vendor=True,
                have_kbd_down=True,
            )
        )


if __name__ == "__main__":
    unittest.main()
