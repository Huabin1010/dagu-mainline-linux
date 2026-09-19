#!/usr/bin/env python3
"""Unit tests for Nanosic 803 leftover vs real KEY_UP.

Locks KEY_UP reports that shipped as leftover:

- Ctrl+C then C up while Ctrl stays held is a real HID boot KEY_UP
  (modifier=LCtrl, keys=00). Dropping it leaves C down; mutter 50
  compositor-repeat then fires Ctrl+C until Ctrl is released.
- Fast unmodified taps (ji / baidu) release in 30–60ms with seq +1
  and GPIO83 high. The old 80ms empty debounce dropped that KEY_UP
  so the last letter (i / u) stayed down and compositor-repeat fired.
- GENI leftover empty 0x05 after 0x22 / GPIO-low / bounce / stale
  seq is still leftover and must drop.
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
HID_A = 0x04
HID_B = 0x05
HID_C = 0x06
HID_D = 0x07
HID_I = 0x0c
HID_J = 0x0d
HID_T = 0x17
HID_U = 0x18


def _old_always_drop_mod_only(report: bytes) -> bool:
    """The shipped rule that left C down after one Ctrl+C."""
    keys_zero = all(b == 0 for b in report[3:9])
    return bool(keys_zero and report[1])


def _old_80ms_debounce_drops_fast_empty(*, have_kbd_down: bool) -> bool:
    """The shipped 80ms empty debounce that left i/u down after a fast tap."""
    return have_kbd_down


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
                int(in_vendor_bounce),
            )
        )

    def kbd_empty(self, report: bytes) -> bool:
        return bool(self._empty(report))

    def inject_stream(self, stream: tuple[bytes, ...]) -> list[bytes]:
        injected: list[bytes] = []
        last: bytes | None = None
        have_down = False
        for report in stream:
            if self.ghost(report, have_kbd_down=have_down):
                continue
            if last == report:
                continue
            last = report
            injected.append(report)
            have_down = not self.kbd_empty(report)
        return injected


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

    def test_fast_chord_key_up_is_still_real(self) -> None:
        self.assertFalse(
            self.lib.ghost(_rpt(HID_LCTRL)),
            "a fast chord KEY_UP must reach HID",
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

    def test_true_empty_gpio_pending_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(), gpio_pending=True))

    def test_true_empty_vendor_bounce_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(), in_vendor_bounce=True))

    def test_true_empty_stale_seq_is_ghost(self) -> None:
        self.assertTrue(self.lib.ghost(_rpt(), rx_seq_delta=0))

    def test_true_empty_no_prior_key_is_real(self) -> None:
        self.assertFalse(self.lib.ghost(_rpt(), have_kbd_down=False))

    def test_old_80ms_debounce_is_the_fast_tap_bug(self) -> None:
        """Board #524: ji I-up seq=52 d=1 gpio=0 at +33ms was leftover."""
        empty = _rpt()
        self.assertTrue(
            _old_80ms_debounce_drops_fast_empty(have_kbd_down=True),
            "document the 80ms window that dropped a 33ms tap KEY_UP",
        )
        self.assertFalse(
            self.lib.ghost(empty, have_kbd_down=True, rx_seq_delta=1),
            "seq +1 empty with GPIO high is the MCU KEY_UP",
        )

    def test_fast_tap_key_up_is_real(self) -> None:
        self.assertFalse(
            self.lib.ghost(_rpt(), have_kbd_down=True, rx_seq_delta=1),
            "fast unmodified KEY_UP must reach HID or mutter repeats the letter",
        )

    def test_ji_stream_injects_i_key_up(self) -> None:
        """Board #524: J, I+J, I, empty. Empty was dropped; I stayed down."""
        stream = (
            _rpt(0, HID_J),
            _rpt(0, HID_I, HID_J),
            _rpt(0, HID_I),
            _rpt(),
        )
        injected = self.lib.inject_stream(stream)
        self.assertEqual(injected, list(stream))
        self.assertTrue(self.lib.kbd_empty(injected[-1]))

    def test_baidu_stream_injects_u_key_up(self) -> None:
        """Board #524: ... U+D, U, empty. Empty at +60ms was leftover."""
        stream = (
            _rpt(0, HID_B),
            _rpt(0, HID_B, HID_A),
            _rpt(0, HID_A),
            _rpt(0, HID_I, HID_A),
            _rpt(0, HID_I),
            _rpt(),
            _rpt(0, HID_D),
            _rpt(0, HID_U, HID_D),
            _rpt(0, HID_U),
            _rpt(),
        )
        injected = self.lib.inject_stream(stream)
        self.assertEqual(injected, list(stream))
        self.assertEqual(injected[-2][3], HID_U)
        self.assertTrue(self.lib.kbd_empty(injected[-1]))

    def test_ctrl_c_stream_injects_c_key_up(self) -> None:
        """Ctrl down, C down, C up while Ctrl held: three injects, last is C up."""
        stream = (
            _rpt(HID_LCTRL),
            _rpt(HID_LCTRL, HID_C),
            _rpt(HID_LCTRL),
        )
        injected = self.lib.inject_stream(stream)
        self.assertEqual(injected, list(stream))
        self.assertEqual(injected[-1][1], HID_LCTRL)
        self.assertEqual(injected[-1][3:], bytes(6))
        self.assertFalse(self.lib.kbd_empty(injected[-1]))

    def test_vendor_leftover_after_ctrl_c_does_not_inject(self) -> None:
        """0x22 keepalive leftover with Ctrl still in p[1] stays leftover."""
        self.assertTrue(
            self.lib.ghost(
                _rpt(HID_LCTRL),
                seen_vendor=True,
                have_kbd_down=True,
            )
        )

    def test_vendor_leftover_after_fast_tap_does_not_inject(self) -> None:
        self.assertTrue(
            self.lib.ghost(_rpt(), seen_vendor=True, have_kbd_down=True)
        )


if __name__ == "__main__":
    unittest.main()
