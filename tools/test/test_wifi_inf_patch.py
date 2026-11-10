#!/usr/bin/env python3
"""Guards for the QCA6390 INF large-memory-block patch.

Run:

  python3 tools/test/test_wifi_inf_patch.py
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "winarm" / "wifi-install"))

from patch_inf import REG_LINE, REG_SECTION, InfError, patch, patch_bytes  # noqa: E402

INF = (
    "[version]\r\n"
    "Class       = Net\r\n"
    "\r\n"
    "[QcWlan_LITHIUM.ndi.NTARM64]\r\n"
    "Characteristics = 0x84\r\n"
    "AddReg          = QcWlan_os63.reg, M3Needed.reg, FileName.reg\r\n"
    "CopyFiles       = QcWlan.CopyFiles\r\n"
    "\r\n"
    "[QcWlan_LITHIUM.ndi.NTARM64.Services]\r\n"
    "AddService = qcwlan, 2, QcWlan.Service\r\n"
    "\r\n"
    "[QcWlan_LITHIUM.ndi.NTARM64.HW]\r\n"
    "AddReg  = MSI.reg\r\n"
    "\r\n"
    "[M3Needed.reg]\r\n"
    "HKR, , M3Needed, 0x00010001, 1\r\n"
    "\r\n"
    "[SourceDisksNames]\r\n"
    "1 = %DiskDescription%,,,\r\n"
)


def section(text: str, name: str) -> str:
    start = text.index("[" + name + "]")
    nxt = text.find("\r\n[", start + 1)
    return text[start:nxt if nxt >= 0 else len(text)]


class PatchTests(unittest.TestCase):
    def test_install_section_gains_the_reg_section(self):
        out = patch(INF)

        addreg = [l for l in section(out, "QcWlan_LITHIUM.ndi.NTARM64").splitlines() if l.startswith("AddReg")]
        self.assertEqual(addreg, ["AddReg          = QcWlan_os63.reg, M3Needed.reg, FileName.reg, " + REG_SECTION])

    def test_reg_section_writes_the_dword(self):
        out = patch(INF)

        self.assertIn("[" + REG_SECTION + "]\r\n" + REG_LINE + "\r\n", out)
        self.assertLess(out.index("[" + REG_SECTION + "]"), out.index("[SourceDisksNames]"))

    def test_hw_and_services_sections_are_untouched(self):
        out = patch(INF)

        self.assertEqual(section(out, "QcWlan_LITHIUM.ndi.NTARM64.HW"), section(INF, "QcWlan_LITHIUM.ndi.NTARM64.HW"))
        self.assertEqual(
            section(out, "QcWlan_LITHIUM.ndi.NTARM64.Services"),
            section(INF, "QcWlan_LITHIUM.ndi.NTARM64.Services"),
        )

    def test_patch_is_idempotent(self):
        once = patch(INF)

        self.assertEqual(patch(once), once)

    def test_trailing_comment_on_addreg_is_kept(self):
        text = INF.replace("FileName.reg\r\n", "FileName.reg   ; vendor list\r\n")

        out = patch(text)

        self.assertIn("FileName.reg, " + REG_SECTION + "   ; vendor list\r\n", out)

    def test_lf_only_file_keeps_lf(self):
        text = INF.replace("\r\n", "\n")

        out = patch(text)

        self.assertNotIn("\r", out)
        self.assertIn("[" + REG_SECTION + "]\n" + REG_LINE + "\n", out)

    def test_missing_install_section_is_refused(self):
        with self.assertRaises(InfError):
            patch(INF.replace("[QcWlan_LITHIUM.ndi.NTARM64]", "[Other.ndi]"))

    def test_install_section_without_addreg_is_refused(self):
        text = INF.replace("AddReg          = QcWlan_os63.reg, M3Needed.reg, FileName.reg\r\n", "")

        with self.assertRaises(InfError):
            patch(text)

    def test_missing_anchor_is_refused(self):
        with self.assertRaises(InfError):
            patch(INF.replace("[SourceDisksNames]", "[Disks]"))

    def test_conflicting_existing_section_is_refused(self):
        text = INF.replace("[SourceDisksNames]", "[" + REG_SECTION + "]\r\nHKR, , Other, 0x00010001, 0\r\n\r\n[SourceDisksNames]")

        with self.assertRaises(InfError):
            patch(text)

    def test_utf16_bom_is_preserved(self):
        raw = b"\xff\xfe" + INF.encode("utf-16-le")

        out = patch_bytes(raw)

        self.assertTrue(out.startswith(b"\xff\xfe"))
        self.assertIn(REG_LINE, out[2:].decode("utf-16-le"))


if __name__ == "__main__":
    unittest.main()
