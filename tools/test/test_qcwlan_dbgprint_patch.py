#!/usr/bin/env python3
"""The Wi-Fi debug sink branch becomes a no-operation and the checksum matches.

Run:

  python3 tools/test/test_qcwlan_dbgprint_patch.py
"""
from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "winarm" / "qcwlan-dbglog"))

from patch_dbgprint import NOP, SINK_BRANCH, patch, pe_checksum  # noqa: E402

SYS = Path("/tmp/qcwlan6800sc81.sys")


class PatchTests(unittest.TestCase):
    def test_stock_checksum_matches_the_header(self):
        data = SYS.read_bytes()
        e = struct.unpack_from("<I", data, 0x3C)[0]
        stored = struct.unpack_from("<I", data, e + 24 + 64)[0]
        self.assertEqual(pe_checksum(data), stored)

    def test_branch_becomes_nop_and_checksum_follows(self):
        original = SYS.read_bytes()
        patched = patch(original)
        self.assertEqual(patched[0x7370:0x737C], SINK_BRANCH[:12])
        self.assertEqual(patched[0x737C:0x7380], NOP)
        self.assertEqual(patched[0x282448:0x28244C], (0xFF).to_bytes(4, "little"))
        self.assertEqual(patched[0x282450:0x282454], (0xFF).to_bytes(4, "little"))
        self.assertEqual(patched[0x28244C:0x282450], (0xFFFFFFFF).to_bytes(4, "little"))
        self.assertEqual(patched[0x282454:0x282458], (0xFFFFFFFF).to_bytes(4, "little"))
        self.assertEqual(pe_checksum(patched), struct.unpack_from("<I", patched, struct.unpack_from("<I", patched, 0x3C)[0] + 24 + 64)[0])
        self.assertNotEqual(patched[0x737C:0x7380], original[0x737C:0x7380])

    def test_a_missing_site_is_refused(self):
        with self.assertRaises(ValueError):
            patch(b"not a driver")


if __name__ == "__main__":
    unittest.main()
