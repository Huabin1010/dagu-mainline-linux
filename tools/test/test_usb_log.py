#!/usr/bin/env python3
"""Unit tests for TestLab USB v2 host client."""
from __future__ import annotations

import io
import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "test-lab"))
sys.path.insert(0, str(ROOT / "tools" / "test"))

import usb_log  # noqa: E402
from usb_protocol_constants import FILES, LEGACY_FILES, PROTOCOL_VERSION  # noqa: E402


class TestUsbLogClient(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "TESTLAB"
        self.root.mkdir()
        (self.root / FILES["boot_log"]).write_text("UEFI: boot start\n", encoding="utf-8")
        (self.root / FILES["boot_seq"]).write_text("1", encoding="utf-8")
        (self.root / FILES["command_in"]).write_text("", encoding="utf-8")
        (self.root / FILES["command_ack"]).write_text("OK", encoding="utf-8")
        (self.root / FILES["status_json"]).write_text(
            '{"seq":1,"usb":"ready","bridge":"v2"}', encoding="utf-8"
        )
        self.paths = usb_log.UsbLogPaths(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_is_v2_volume_rejects_legacy_screenshot(self) -> None:
        self.assertTrue(usb_log._is_v2_volume(self.root))
        (self.root / LEGACY_FILES[2]).write_bytes(b"BM")
        self.assertFalse(usb_log._is_v2_volume(self.root))

    def test_discover_nested_testlab(self) -> None:
        found = usb_log.discover_testlab_root([Path(self.tmp.name)])
        self.assertEqual(found, self.root)

    def test_watch_streams_boot_log(self) -> None:
        buf = io.StringIO()
        with mock_patch_stdout(buf):
            rc = usb_log.cmd_watch(self.paths, out_log=None, follow=False, poll_sec=0.05)
        self.assertEqual(rc, 0)
        self.assertIn("UEFI: boot start", buf.getvalue())

    def test_dump_boot_log(self) -> None:
        dest = Path(self.tmp.name) / "out.log"
        rc = usb_log.cmd_dump(self.paths, dest)
        self.assertEqual(rc, 0)
        self.assertIn("boot start", dest.read_text(encoding="utf-8"))

    def test_status_json(self) -> None:
        rc = usb_log.cmd_status(self.paths)
        self.assertEqual(rc, 0)

    def test_send_command(self) -> None:
        self.paths.file("command_ack").write_text("OLD", encoding="utf-8")

        def delayed_ack() -> None:
            time.sleep(0.1)
            self.paths.file("command_ack").write_text("OK map", encoding="utf-8")

        threading.Thread(target=delayed_ack, daemon=True).start()
        rc = usb_log.cmd_send(self.paths, "map -r", timeout_sec=2.0)
        self.assertEqual(rc, 0)

    def test_firmware_uses_boot_log_paths(self) -> None:
        hdr = (
            ROOT / "port/dagu/Silicon/Qualcomm/QcomPkg/Include/Guid/TestLabBridgeGuid.h"
        ).read_text(encoding="utf-8")
        self.assertIn("BOOT.LOG", hdr)
        self.assertIn("BOOT.SEQ", hdr)
        self.assertNotIn("SCREEN.BMP", hdr)

    def test_firmware_does_not_start_usb_msc(self) -> None:
        src = (
            ROOT
            / "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.c"
        ).read_text(encoding="utf-8")
        hdr = (
            ROOT / "port/dagu/Silicon/Qualcomm/QcomPkg/Include/Guid/TestLabBridgeGuid.h"
        ).read_text(encoding="utf-8")
        self.assertNotIn("TestLabPublishUsbMassStorage", src)
        self.assertNotIn("gLinuxSimpleMassStorageGuid", src)
        self.assertIn("TestLabReadyToBootCallback", src)
        self.assertIn("EfiCreateEventReadyToBootEx", src)
        self.assertIn("TESTLAB_ENABLE_CONOUT_HOOK", hdr)
        self.assertNotIn("TESTLAB_ENABLE_AUTO_USB_MSC", hdr)
        self.assertIn("#define TESTLAB_ENABLE_CONOUT_HOOK  0", hdr)
        self.assertIn("ERR msc-removed", src)

    def test_gen_fat_template_v2(self) -> None:
        text = (ROOT / "tools/gen-testlab-fat.sh").read_text(encoding="utf-8")
        self.assertIn("BOOT.LOG", text)
        self.assertIn('"bridge":"v2"', text)
        self.assertNotIn("SCREEN.BMP", text)


def mock_patch_stdout(buf: io.StringIO):
    from unittest import mock

    return mock.patch("sys.stdout", mock.Mock(write=buf.write, flush=buf.flush))


if __name__ == "__main__":
    raise SystemExit(unittest.main())
