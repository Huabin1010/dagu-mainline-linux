#!/usr/bin/env python3
"""Unit tests for UART serial log capture tool (dagu-specific)."""
from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "test-lab"))
sys.path.insert(0, str(ROOT / "tools" / "test"))

import serial_log  # noqa: E402
from uart_expectations import (  # noqa: E402
    DTB_SERIAL0_MMIO,
    DTB_SERIAL0_NODE,
    NO_COM_IS_NORMAL_WITHOUT_TTL,
    SERIAL_BAUD,
    UART_IS_USB_CDC,
    UART_REQUIRES_USB_TTL,
)


class FakeSerial:
    def __init__(self, chunks: list[bytes]) -> None:
        self._chunks = list(chunks)
        self.closed = False
        self.in_waiting = 0

    def read(self, size: int) -> bytes:
        if not self._chunks:
            return b""
        chunk = self._chunks.pop(0)
        return chunk[:size]

    def close(self) -> None:
        self.closed = True


class TestSerialLogTool(unittest.TestCase):
    def test_dagu_uart_is_not_usb_cdc(self) -> None:
        self.assertFalse(UART_IS_USB_CDC)
        self.assertTrue(UART_REQUIRES_USB_TTL)

    def test_default_baud_from_config(self) -> None:
        self.assertEqual(serial_log.default_baud(), SERIAL_BAUD)

    def test_pick_port_explicit(self) -> None:
        self.assertEqual(serial_log.pick_port("COM9"), "COM9")

    def test_pick_port_single_detected(self) -> None:
        with mock.patch.object(serial_log, "default_port", return_value=""):
            with mock.patch.object(serial_log, "list_serial_ports", return_value=["COM3"]):
                self.assertEqual(serial_log.pick_port(None), "COM3")

    def test_pick_port_none_raises_with_helpful_message(self) -> None:
        with mock.patch.object(serial_log, "default_port", return_value=""):
            with mock.patch.object(serial_log, "list_serial_ports", return_value=[]):
                with self.assertRaisesRegex(RuntimeError, "no serial ports found"):
                    serial_log.pick_port(None)

    def test_list_exits_nonzero_when_no_ports(self) -> None:
        with mock.patch.object(serial_log, "list_serial_ports", return_value=[]):
            buf = io.StringIO()
            with mock.patch("sys.stdout", buf):
                rc = serial_log.cmd_list()
            self.assertEqual(rc, 1)
            self.assertIn("no serial ports", buf.getvalue().lower())

    def test_preflight_not_ready_without_ports(self) -> None:
        with mock.patch.object(serial_log, "default_port", return_value=""):
            with mock.patch.object(serial_log, "list_serial_ports", return_value=[]):
                report = serial_log.build_preflight_report()
                self.assertFalse(report.ready)
                self.assertEqual(report.detected_ports, [])
                self.assertIn("Type-C", NO_COM_IS_NORMAL_WITHOUT_TTL)

    def test_preflight_ready_with_configured_port(self) -> None:
        with mock.patch.object(serial_log, "default_port", return_value="COM7"):
            with mock.patch.object(serial_log, "list_serial_ports", return_value=["COM7"]):
                report = serial_log.build_preflight_report()
                self.assertTrue(report.ready)
                self.assertEqual(report.configured_port, "COM7")

    def test_preflight_json_output(self) -> None:
        with mock.patch.object(serial_log, "default_port", return_value=""):
            with mock.patch.object(serial_log, "list_serial_ports", return_value=[]):
                buf = io.StringIO()
                with mock.patch("sys.stdout", buf):
                    rc = serial_log.cmd_preflight(as_json=True)
                self.assertEqual(rc, 1)
                data = json.loads(buf.getvalue())
                self.assertEqual(data["firmware_pcd_hex"], f"0x{DTB_SERIAL0_MMIO:08x}")
                self.assertFalse(data["uart_is_usb_cdc"])

    def test_watch_writes_stdout_and_log(self) -> None:
        fake = FakeSerial([b"ERROR: SimpleFb failed\r\n", b"Shell>\r\n"])
        with mock.patch.object(serial_log, "open_serial", return_value=fake):
            with tempfile.TemporaryDirectory() as tmp:
                log_path = Path(tmp) / "boot.log"
                buf = io.BytesIO()
                with mock.patch("sys.stdout", mock.Mock(buffer=buf)):
                    rc = serial_log.cmd_watch(
                        serial_log.SerialConfig(port="COM3"),
                        out_log=log_path,
                        follow=False,
                        duration_sec=None,
                        quiet=False,
                    )
                self.assertEqual(rc, 0)
                self.assertIn(b"ERROR: SimpleFb", buf.getvalue())
                self.assertIn(b"ERROR: SimpleFb", log_path.read_bytes())

    def test_dsc_uart_pcd_matches_dtb(self) -> None:
        dsc = (ROOT / "port/dagu/Platform/Xiaomi/sm8250/dagu.dsc").read_text(
            encoding="utf-8", errors="replace"
        )
        self.assertIn(f"PcdDebugUartPortBase|{DTB_SERIAL0_MMIO:#x}", dsc)
        self.assertIn("TestLabBridgeDxe.inf", dsc)
        self.assertIn("DaguUsbCdcAcmDxe.inf", dsc)

    def test_dtb_blob_mentions_serial0_node(self) -> None:
        dtb = ROOT / "port/dagu/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb"
        self.assertTrue(dtb.exists())
        blob = dtb.read_bytes()
        self.assertIn(DTB_SERIAL0_NODE.encode("ascii"), blob)
        self.assertIn(b"serial0", blob)

    def test_testlab_driver_mirrors_conout_to_serial(self) -> None:
        src = (
            ROOT
            / "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.c"
        ).read_text(encoding="utf-8", errors="replace")
        self.assertIn("TestLabAppendLog", src)
        self.assertIn("TESTLAB_BOOT_LOG", src)
        self.assertNotIn("TestLabPublishUsbMassStorage", src)
        self.assertNotIn("SCREEN.BMP", src)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
