// GENI SPI controller for the Himax touch (QUP0 SE4 @ 0x990000).
// Split out of i2c.asl so the touch stack (gpio + spi + himax) can be
// included on its own via DSDT_ONLY without dragging in the 14 I2C nodes.
//
// qcspi8250.inf binds ACPI\QCOM250F. SE4 = global _UID 5 (QUP0 s0..s7 = 1..8,
// so SE4 = 5; see the _UID note in i2c.asl). No _DEP: \_SB.PEP0 is a
// placeholder; UEFI leaves the SE clock and IRAM set up. Child \_SB.TPAD
// (himax.asl) consumes this controller via SPISerialBus("\\_SB.SP04").

Device (SP04)
{
    Name (_HID, "QCOM250F")
    Name (_UID, 5)
    Name (_CCA, Zero)
    Name (_DDN, "QUP0 SE4 SPI Himax")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00990000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {637}
        })
        Return (RBUF)
    }
}
