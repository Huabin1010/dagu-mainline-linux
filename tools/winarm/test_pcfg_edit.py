#!/usr/bin/env python3
"""Tests for pcfg-edit.py.

  python3 tools/winarm/test_pcfg_edit.py
"""
import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("pcfg", os.path.join(_HERE, "pcfg-edit.py"))
pcfg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pcfg)


def asl_with(xml: bytes) -> str:
    body = "\n".join("            " + ", ".join("0x%02X" % b for b in xml[i:i + 16]) + ","
                     for i in range(0, len(xml), 16))
    return ("    Method (_ROM, 3, NotSerialized)\n    {\n"
            "        Name (PCFG, Buffer (0x%X)\n        {\n%s\n        })\n"
            "        Return (PCFG)\n    }\n") % (len(xml), body)


XML = (b"<?xml version='1.0'?>\n<PanelName>L81A</PanelName>\n"
       b"    <BacklightType>2</BacklightType>\n"
       b"    <PMIPowerPmicNum>1</PMIPowerPmicNum>\n"
       b"    <PMIPowerPmicModel>0x1E</PMIPowerPmicModel>\n"
       b"    <PMIPowerConfig>1</PMIPowerConfig>\n"
       b"    <AdaptiveBrightnessFeature>1</AdaptiveBrightnessFeature>\n\x00\x00")


class PcfgEditTest(unittest.TestCase):
    def test_round_trip_without_edits_keeps_bytes(self):
        asl = asl_with(XML)

        out, gone, old, new = pcfg.rewrite(asl, [])

        self.assertEqual(pcfg.decode(out)[1], XML)
        self.assertEqual((gone, old, new), ([], len(XML), len(XML)))

    def test_drops_whole_tag_lines_and_updates_length(self):
        asl = asl_with(XML)

        out, gone, old, new = pcfg.rewrite(asl, ["PMIPowerPmicNum", "PMIPowerPmicModel", "PMIPowerConfig"])

        data = pcfg.decode(out)[1]
        self.assertNotIn(b"PMIPower", data)
        self.assertIn(b"<BacklightType>2</BacklightType>\n    <AdaptiveBrightnessFeature>", data)
        self.assertTrue(data.endswith(b"\x00\x00"))
        self.assertEqual(new, len(data))
        self.assertIn("Buffer (0x%X)" % new, out)
        self.assertEqual(sorted(gone), ["PMIPowerConfig", "PMIPowerPmicModel", "PMIPowerPmicNum"])

    def test_missing_tag_is_reported_not_fatal(self):
        out, gone, old, new = pcfg.rewrite(asl_with(XML), ["NoSuchTag"])

        self.assertEqual(gone, [])
        self.assertEqual(old, new)

    def test_does_not_touch_tags_that_share_a_prefix(self):
        xml = b"<PMIPowerConfig>1</PMIPowerConfig>\n<PMIPowerConfigEx>7</PMIPowerConfigEx>\n"

        out, gone, _, _ = pcfg.rewrite(asl_with(xml), ["PMIPowerConfig"])

        self.assertEqual(pcfg.decode(out)[1], b"<PMIPowerConfigEx>7</PMIPowerConfigEx>\n")

    def test_declared_length_mismatch_is_rejected(self):
        bad = asl_with(XML).replace("Buffer (0x%X)" % len(XML), "Buffer (0x%X)" % (len(XML) + 1))

        with self.assertRaisesRegex(ValueError, "does not match"):
            pcfg.decode(bad)

    def test_no_pcfg_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "no PCFG"):
            pcfg.decode("Method (_STA) { Return (0xF) }")


if __name__ == "__main__":
    unittest.main()
