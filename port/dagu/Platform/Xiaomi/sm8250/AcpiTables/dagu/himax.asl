// Himax HX83121 on dagu.
// Product DT: linux-mainline/dts/dagu-geni-spi-experiment.on.dtsi  &spi4
// Pins: linux-mainline/dts/sm8250-xiaomi-dagu.dts  CAF qupv3_se4_spi @ 0x990000
//       gpio8–11 = QUP L0–L3, IRQ GPIO 39 LEVEL_LOW, coords 1600x2560
// Protocol: linux-mainline/overlays/linux/drivers/input/touchscreen/himax-dagu.c
//           SPI_MODE_3, cmd 0x30, 10 fingers. Do not bind GPIO 100 (panel tp-reset).
//
// _HID HIMA8312 binds the self-contained himax-hx83121.sys HIDCLASS
// minidriver (port/dagu/windows-drivers/himax-hx83121). That driver owns SE4
// itself: it MmMapIoSpace()s the GENI block at 0x990000 and runs the FIFO SPI
// transfer directly, and polls gpio39's TLMM level register at 0x0F527000.
// So TPAD declares NO resources on purpose -- an SPISerialBus("\_SB.SP04")
// here would drag in qcspi8250, whose GENI/GPI/SMMU stack dagu lacks and which
// hangs the kernel at ExitBootServices. DaguQupDxe (UEFI) already clocked and
// firmware-loaded SE4 and keeps the clocks across ExitBootServices, so the
// minidriver finds SE4 live without PEP/SMMU/GPI. GPIO100 (panel reset) must
// not be touched.

Device (TPAD)
{
    Name (_HID, "HIMA8312")
    Name (_CID, "HIMA8312")
    Name (_UID, 0)
    Name (_DDN, "Himax HX83121")

    Method (_STA, 0)
    {
        Return (0xF)
    }

    // No resources: the minidriver maps SE4 (0x990000) and the gpio39 TLMM
    // register (0x0F527000) itself and polls, so it needs neither a SPB
    // controller (SP04/qcspi8250) nor a GpioInt provider (GIO0).
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate () {})
        Return (RBUF)
    }
}
