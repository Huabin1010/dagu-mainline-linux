// Product GENI I2C/SPI controllers. Windows SPB needs QCOM0C10 / QCOM0C11.
// IRQ = GIC_SPI + 32 from sm8250.dtsi. Do not firmware-name the wrapper.

Device (IC00)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 0)
    Name (_DDN, "QUP0 SE0 I2C FG-R")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00980000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {633}
        })
        Return (RBUF)
    }
}

Device (IC01)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 1)
    Name (_DDN, "QUP0 SE1 I2C CS35L41")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00984000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {634}
        })
        Return (RBUF)
    }
}

Device (IC02)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 2)
    Name (_DDN, "QUP0 SE2 I2C Nanosic")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00988000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {635}
        })
        Return (RBUF)
    }
}

Device (IC03)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 3)
    Name (_DDN, "QUP0 SE3 I2C CS35L41")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0098C000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {636}
        })
        Return (RBUF)
    }
}

Device (SP04)
{
    Name (_HID, "QCOM0C11")
    Name (_UID, 4)
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

Device (IC08)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 8)
    Name (_DDN, "QUP1 SE0 I2C P9418 CAF")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00A80000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {385}
        })
        Return (RBUF)
    }
}

Device (IC09)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 9)
    Name (_DDN, "QUP1 SE1 I2C KTZ-B")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00A84000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {386}
        })
        Return (RBUF)
    }
}

Device (IC11)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 11)
    Name (_DDN, "QUP1 SE3 I2C KTZ-A")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00A8C000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {388}
        })
        Return (RBUF)
    }
}

Device (IC13)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 13)
    Name (_DDN, "QUP1 SE5 I2C FG-L")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00A94000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {390}
        })
        Return (RBUF)
    }
}

Device (IC15)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 15)
    Name (_DDN, "QUP2 SE1 I2C BQ25970-M")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00884000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {615}
        })
        Return (RBUF)
    }
}

Device (IC16)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 16)
    Name (_DDN, "QUP2 SE2 I2C BQ25970-S")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00888000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {616}
        })
        Return (RBUF)
    }
}

Device (IC17)
{
    Name (_HID, "QCOM0C10")
    Name (_UID, 17)
    Name (_DDN, "QUP2 SE3 I2C PS5169")
    Method (_STA, 0) { Return (0x0) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0088C000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {617}
        })
        Return (RBUF)
    }
}
