// Himax HX83121 on dagu.
// Product DT: linux-mainline/dts/dagu-geni-spi-experiment.on.dtsi  &spi4
// Pins: linux-mainline/dts/sm8250-xiaomi-dagu.dts  CAF qupv3_se4_spi @ 0x990000
//       gpio8–11 = QUP L0–L3, IRQ GPIO 39 LEVEL_LOW, coords 1600x2560
// Protocol: linux-mainline/overlays/linux/drivers/input/touchscreen/himax-dagu.c
//           SPI_MODE_3, cmd 0x30, 10 fingers. Do not bind GPIO 100 (panel tp-reset).
//
// _HID HIMA8312 is a placeholder. No official Windows INF. Do not treat
// this node as a working touch stack.

Device (GIO0)
{
    Name (_HID, "QCOM0C22")
    Name (_UID, 0)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0F100000, 0x00900000)
        })
        Return (RBUF)
    }
}

Device (TPAD)
{
    Name (_HID, "HIMA8312")
    Name (_CID, "HIMA8312")
    Name (_UID, 0)
    Name (_DDN, "Himax HX83121")

    Name (XMAX, 1600)
    Name (YMAX, 2560)
    Name (SPIM, 3)
    Name (SPHZ, 4000000)
    Name (IRQG, 39)

    Method (_STA, 0)
    {
        Return (0xF)
    }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            SPISerialBus (0x00, PolarityLow, FourWireMode, 0x08,
                ControllerInitiated, 0x003D0900, ClockPolarityHigh,
                ClockPhaseSecond, "\\_SB.SP04", 0x00, ResourceConsumer)
            GpioInt (Level, ActiveLow, Exclusive, PullUp, 0, "\\_SB.GIO0") {39}
        })
        Return (RBUF)
    }
}
