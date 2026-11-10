#!/usr/bin/env python3
"""Guards for the QCA6390 firmware reload tool.

Run:

  python3 tools/test/test_wifi_fw_reload.py
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "winarm" / "wifi-fw-reload"))

from fw_candidate import FW_DEST, LINUX_SHA256_PREFIXES, M3_DEST, Reject, decide  # noqa: E402

ELF = b"\x7fELF\x02\x01"
WINDOWS_FW = "97e5a52db1a4a494" + "ab" * 24
WINDOWS_M3 = "26f5f9cdf346ed2c" + "cd" * 24
OTHER = "0123456789abcdef" + "11" * 24


class DecideTests(unittest.TestCase):
    def test_fw_goes_to_both_names_the_driver_can_open(self):
        got = decide("fw", r"D:\lab\wlanfw20.mbn", 3_645_088, ELF, WINDOWS_FW)
        self.assertEqual(got, FW_DEST)

    def test_m3_goes_only_to_m3(self):
        got = decide("m3", r"D:\lab\m3.bin", 266_684, ELF, WINDOWS_M3)
        self.assertEqual(got, M3_DEST)

    def test_linux_amss_name_is_refused(self):
        with self.assertRaises(Reject):
            decide("fw", "/lib/firmware/amss.bin", 3_628_672, ELF, OTHER)

    def test_linux_directory_is_refused_even_after_rename(self):
        with self.assertRaises(Reject):
            decide(
                "fw",
                "/lib/firmware/ath11k/QCA6390/hw2.0/wlanfw20.mbn",
                3_645_088,
                ELF,
                OTHER,
            )

    def test_board_file_is_refused(self):
        for name in ("bdwlan.elf", "bdwlan.eff", "bd_l81a.elf", "board.bin"):
            with self.assertRaises(Reject):
                decide("fw", f"D:\\lab\\{name}", 3_645_088, ELF, OTHER)

    def test_measured_linux_hashes_are_refused(self):
        for prefix in LINUX_SHA256_PREFIXES:
            digest = prefix + "00" * 24
            with self.assertRaises(Reject):
                decide("fw", r"D:\lab\renamed.mbn", 3_645_088, ELF, digest.upper())

    def test_non_elf_is_refused(self):
        with self.assertRaises(Reject):
            decide("fw", r"D:\lab\wlanfw20.mbn", 3_645_088, b"\x00\x01\x02\x03", OTHER)

    def test_size_bands_do_not_overlap(self):
        with self.assertRaises(Reject):
            decide("fw", r"D:\lab\wlanfw20.mbn", 266_684, ELF, OTHER)
        with self.assertRaises(Reject):
            decide("m3", r"D:\lab\m3.bin", 3_645_088, ELF, OTHER)

    def test_swapped_roles_are_refused(self):
        with self.assertRaises(Reject):
            decide("fw", r"D:\lab\m3.bin", 3_645_088, ELF, OTHER)
        with self.assertRaises(Reject):
            decide("m3", r"D:\lab\wlanfw20.mbn", 266_684, ELF, OTHER)

    def test_short_digest_is_refused(self):
        with self.assertRaises(Reject):
            decide("fw", r"D:\lab\wlanfw20.mbn", 3_645_088, ELF, "97e5a52d")

    def test_unknown_role_is_refused(self):
        with self.assertRaises(Reject):
            decide("board", r"D:\lab\wlanfw20.mbn", 3_645_088, ELF, OTHER)


if __name__ == "__main__":
    unittest.main()
