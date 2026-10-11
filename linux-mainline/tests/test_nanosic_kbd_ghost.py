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
- FN+= / FN+- is consumer report 0x06. Usage 0xE9/0xEA is the press.
  Usage 0 is the release, and it is all zeros. The old padding filter
  and the 400ms keepalive window both dropped that release, so
  KEY_VOLUMEUP stayed down and mutter ran the slider to the rail.
  A fresh seq with GPIO83 high must inject it. A zero report with
  nothing latched is still padding and must drop.
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
CONSUMER_VOL_UP = 0x00E9
CONSUMER_VOL_DOWN = 0x00EA


def _old_always_drop_mod_only(report: bytes) -> bool:
    """The shipped rule that left C down after one Ctrl+C."""
    keys_zero = all(b == 0 for b in report[3:9])
    return bool(keys_zero and report[1])


def _old_80ms_debounce_drops_fast_empty(*, have_kbd_down: bool) -> bool:
    """The shipped 80ms empty debounce that left i/u down after a fast tap."""
    return have_kbd_down


def _old_drop_zero_consumer(report: bytes) -> bool:
    """The shipped rule: any all-zero consumer report is padding.

    A real FN+volume release is usage 0, so this dropped the KEY_UP.
    """
    return all(b == 0 for b in report[1:])


def _cons(usage: int = 0) -> bytes:
    return bytes([0x06, usage & 0xFF, (usage >> 8) & 0xFF, 0x00, 0x00])


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
        usage = self._so.nanosic_consumer_usage_host
        usage.argtypes = [ctypes.c_char_p]
        usage.restype = ctypes.c_int
        self._usage = usage
        cons = self._so.nanosic_consumer_inject_host
        cons.argtypes = [
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
        ]
        cons.restype = ctypes.c_int
        self._cons = cons

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

    def consumer_usage(self, report: bytes) -> int:
        if len(report) != 5:
            raise ValueError(f"consumer report is 5 bytes, got {len(report)}")
        return int(self._usage(report))

    def consumer_inject(
        self,
        report: bytes,
        *,
        leftover_window: bool = False,
        have_consumer_down: bool = False,
        seen_vendor: bool = False,
        rx_have_prev_seq: bool = True,
        rx_seq_delta: int = 1,
        gpio_pending: bool = False,
    ) -> bool:
        if len(report) != 5:
            raise ValueError(f"consumer report is 5 bytes, got {len(report)}")
        return bool(
            self._cons(
                report,
                int(leftover_window),
                int(have_consumer_down),
                int(seen_vendor),
                int(rx_have_prev_seq),
                int(rx_seq_delta),
                int(gpio_pending),
            )
        )

    def consumer_stream(
        self, steps: tuple[tuple[bytes, bool], ...]
    ) -> list[bytes]:
        """steps: (report, leftover_window). Tracks the latched usage."""
        injected: list[bytes] = []
        last: bytes | None = None
        down = False
        for report, leftover in steps:
            if not self.consumer_inject(
                report, leftover_window=leftover, have_consumer_down=down
            ):
                continue
            if last == report:
                continue
            last = report
            injected.append(report)
            down = self.consumer_usage(report) != 0
        return injected

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

    def test_enter_up_after_keepalive_is_real_key_up(self) -> None:
        """Board: seq 72 Enter down, seq 73 0x22, seq 74 empty d=1 gpio=0.

        The empty report is inside the 16ms keepalive bounce and was
        dropped. Mutter then repeated KEY_ENTER into the focused
        connection control.
        """
        self.assertFalse(
            self.lib.ghost(
                _rpt(),
                have_kbd_down=True,
                have_vendor=True,
                in_vendor_bounce=True,
                rx_seq_delta=1,
                gpio_pending=False,
            )
        )

    def test_true_empty_vendor_bounce_with_gpio_pending_is_ghost(self) -> None:
        self.assertTrue(
            self.lib.ghost(
                _rpt(),
                in_vendor_bounce=True,
                gpio_pending=True,
            )
        )

    def test_true_empty_vendor_bounce_stale_seq_is_ghost(self) -> None:
        self.assertTrue(
            self.lib.ghost(_rpt(), in_vendor_bounce=True, rx_seq_delta=0)
        )

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

    def test_consumer_usage_is_little_endian(self) -> None:
        self.assertEqual(self.lib.consumer_usage(_cons(CONSUMER_VOL_UP)), CONSUMER_VOL_UP)
        self.assertEqual(
            self.lib.consumer_usage(_cons(CONSUMER_VOL_DOWN)), CONSUMER_VOL_DOWN
        )
        self.assertEqual(self.lib.consumer_usage(_cons(0)), 0)

    def test_old_drop_zero_consumer_is_the_volume_bug(self) -> None:
        release = _cons(0)
        self.assertTrue(
            _old_drop_zero_consumer(release),
            "document the padding rule that dropped the volume KEY_UP",
        )
        self.assertTrue(
            self.lib.consumer_inject(
                release,
                leftover_window=True,
                have_consumer_down=True,
            ),
            "FN+= release inside the keepalive window must reach HID",
        )

    def test_volume_release_after_keepalive_is_injected(self) -> None:
        """Press, 0x22 keepalive, usage 0. Window is open; release still lands."""
        press = _cons(CONSUMER_VOL_UP)
        release = _cons(0)
        injected = self.lib.consumer_stream(
            (
                (press, False),
                (release, True),
            )
        )
        self.assertEqual(injected, [press, release])

    def test_volume_down_release_is_injected(self) -> None:
        press = _cons(CONSUMER_VOL_DOWN)
        release = _cons(0)
        injected = self.lib.consumer_stream(((press, False), (release, True)))
        self.assertEqual(injected, [press, release])

    def test_padding_zero_consumer_with_nothing_latched_is_dropped(self) -> None:
        self.assertFalse(
            self.lib.consumer_inject(_cons(0), leftover_window=True),
            "GENI zero 0x06 with no volume key down must not reach the seat",
        )

    def test_volume_press_inside_leftover_window_is_dropped(self) -> None:
        self.assertFalse(
            self.lib.consumer_inject(
                _cons(CONSUMER_VOL_UP), leftover_window=True
            )
        )

    def test_volume_release_while_gpio_pending_is_dropped(self) -> None:
        self.assertFalse(
            self.lib.consumer_inject(
                _cons(0),
                have_consumer_down=True,
                gpio_pending=True,
            )
        )

    def test_volume_release_same_envelope_as_vendor_is_dropped(self) -> None:
        self.assertFalse(
            self.lib.consumer_inject(
                _cons(0),
                have_consumer_down=True,
                seen_vendor=True,
            )
        )

    def test_volume_release_stale_seq_is_dropped(self) -> None:
        self.assertFalse(
            self.lib.consumer_inject(
                _cons(0),
                have_consumer_down=True,
                rx_seq_delta=0,
            )
        )

    def test_volume_press_outside_window_is_injected(self) -> None:
        self.assertTrue(self.lib.consumer_inject(_cons(CONSUMER_VOL_UP)))


if __name__ == "__main__":
    unittest.main()
