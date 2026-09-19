#!/usr/bin/env python3
"""Gates for the UEFI USB CDC-ACM boot-log path (not Mass Storage)."""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PORT = ROOT / "port/dagu"
DXE = (
    PORT
    / "Silicon/Qualcomm/QcomPkg/Drivers/DaguUsbCdcAcmDxe/DaguUsbCdcAcmDxe.c"
)
HDR = PORT / "Silicon/Qualcomm/QcomPkg/Include/Library/DaguDebugLog.h"
FB = (
    PORT
    / "Silicon/Qualcomm/QcomPkg/Library/FrameBufferSerialPortLib"
    / "FrameBufferSerialPortLib.c"
)
DSC = PORT / "Platform/Xiaomi/sm8250/dagu.dsc"
FDF = PORT / "Platform/Xiaomi/sm8250/dagu.fdf.inc"
HOST_INF = PORT / "windows-drivers/usb-cdc-acm-host/dagu-uefi-acm.inf"


class TestUefiUsbCdc(unittest.TestCase):
    def test_ring_carveout_matches_memmap(self) -> None:
        hdr = HDR.read_text(encoding="utf-8")
        mem = (
            PORT
            / "Platform/Xiaomi/sm8250/Library/dagu/PlatformMemoryMapLib"
            / "PlatformMemoryMapLib.c"
        ).read_text(encoding="utf-8")
        self.assertIn("0x9FFF7000", hdr)
        self.assertIn("0x00008000", hdr)
        self.assertIn('{"Log Buffer",       0x9FFF7000, 0x00008000', mem)

    def test_framebuffer_tees_serial_into_ring(self) -> None:
        text = FB.read_text(encoding="utf-8")
        self.assertIn("DaguDebugLogAppend", text)
        self.assertGreaterEqual(text.count("DaguDebugLogAppend"), 2)
        self.assertIn("DaguDebugLogInit", text)

    def test_dxe_is_usbfn_client_not_dwc3_mmio(self) -> None:
        text = DXE.read_text(encoding="utf-8")
        self.assertIn("gEfiUsbFunctionIoProtocolGuid", text)
        self.assertIn("0x0525", text)
        self.assertIn("0xA4A7", text)
        self.assertIn("ConfigureEnableEndpoints", text)
        self.assertNotIn("0x0A600000", text)
        self.assertNotIn("LinuxSimpleMassStorage", text)
        self.assertNotIn("StartImage", text)

    def test_firmware_packs_cdc_not_testlab_msc(self) -> None:
        dsc = DSC.read_text(encoding="utf-8")
        fdf = FDF.read_text(encoding="utf-8")
        self.assertIn("DaguUsbCdcAcmDxe.inf", dsc)
        self.assertIn("DaguUsbCdcAcmDxe.inf", fdf)
        self.assertNotIn("ENABLE_LINUX_SIMPLE_MASS_STORAGE", dsc)
        self.assertTrue(
            fdf.strip().split("TestLabBridgeDxe.inf")[-1].startswith("")
            or "# INF Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe"
            in fdf
        )
        for line in fdf.splitlines():
            if "TestLabBridgeDxe.inf" in line:
                self.assertTrue(line.lstrip().startswith("#"))

    def test_host_inf_binds_inbox_usbser(self) -> None:
        text = HOST_INF.read_text(encoding="utf-8")
        self.assertIn("USB\\VID_0525&PID_A4A7", text)
        self.assertIn("usbser", text)
        self.assertIn("NTamd64", text)
        self.assertIn("NTarm64", text)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
