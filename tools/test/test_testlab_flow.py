#!/usr/bin/env python3
"""End-to-end TestLab flow unit tests for dagu UEFI bring-up."""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "test"))

from uart_expectations import BUILD_UART_FLAG, DTB_SERIAL0_MMIO, FIRMWARE_UART_PCD  # noqa: E402
from usb_protocol_constants import FILES, PROTOCOL_VERSION  # noqa: E402


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8", errors="replace")


class TestFirmwareUartConfig(unittest.TestCase):
    def test_build_script_enables_uart_by_default(self) -> None:
        text = read("tools/build-dagu-uefi.sh")
        self.assertIn(BUILD_UART_FLAG, text)

    def test_dagu_dsc_sets_uart_pcd(self) -> None:
        text = read("port/dagu/Platform/Xiaomi/sm8250/dagu.dsc")
        self.assertRegex(text, rf"{FIRMWARE_UART_PCD}\|0x{DTB_SERIAL0_MMIO:x}")


class TestFirmwareUsbV2(unittest.TestCase):
    def test_bridge_inf_includes_fat_and_msc(self) -> None:
        text = read(
            "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.inf"
        )
        self.assertIn("TestLabFatDisk.S", text)
        self.assertNotIn("gLinuxSimpleMassStorageGuid", text)
        self.assertIn("SerialPortLib", text)

    def test_bridge_source_v2_files(self) -> None:
        text = read(
            "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabBridgeDxe.c"
        )
        self.assertIn("TESTLAB_BOOT_LOG", text)
        self.assertNotIn("TestLabPublishUsbMassStorage", text)
        self.assertNotIn("gLinuxSimpleMassStorageGuid", text)
        self.assertIn("TestLabReadyToBootCallback", text)
        self.assertIn("TESTLAB_ENABLE_CONOUT_HOOK", text)
        self.assertNotIn("SCREEN.BMP", text)

    def test_guid_header_v2(self) -> None:
        text = read("port/dagu/Silicon/Qualcomm/QcomPkg/Include/Guid/TestLabBridgeGuid.h")
        self.assertIn("BOOT.LOG", text)
        self.assertIn("BOOT.SEQ", text)
        self.assertIn("gTestLabBridgeRamDiskGuid", text)


class TestHostTooling(unittest.TestCase):
    def test_test_lab_json_usb_fields(self) -> None:
        cfg = json.loads(read("test-lab.json"))
        self.assertIn("usb_log_timeout_sec", cfg)
        self.assertIn("usb_log_poll_sec", cfg)

    def test_usb_log_client_exists(self) -> None:
        text = read("tools/test-lab/usb_log.py")
        self.assertIn("BOOT.LOG", text)
        self.assertIn(PROTOCOL_VERSION, text)

    def test_lab_ps1_exposes_usb_log(self) -> None:
        text = read("tools/test-lab/lab.ps1")
        self.assertIn('"usb-log"', text)

    def test_uefi_boot_supports_attach_usb(self) -> None:
        text = read("tools/test-lab/test-uefi-boot.ps1")
        self.assertIn("AttachUsb", text)
        self.assertIn("uefi-usb-boot.log", text)


class TestBootArtifacts(unittest.TestCase):
    def test_latest_boot_image_exists(self) -> None:
        latest = ROOT / "artifacts" / "boot-dagu-latest.img"
        if not latest.exists():
            self.skipTest("boot-dagu-latest.img not built yet")
        self.assertGreater(latest.stat().st_size, 1_000_000)

    def test_fat_disk_template_script(self) -> None:
        text = read("tools/gen-testlab-fat.sh")
        self.assertIn("BOOT.LOG", text)
        self.assertIn("BOOT.SEQ", text)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
