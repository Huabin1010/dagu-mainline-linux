// Speakers CS35L41 x4 + WCD9385 mics. ADSP firmware adsp.mbn.
// Product I2C: dagu-geni-i2c-experiment.on.dtsi
//   SE1 i2c@984000  BR@40 IRQ7  BL@41 IRQ67
//   SE3 i2c@98c000  TL@41 TR@43
// WCD9385 reset GPIO32. Do not use Softvol / Fluence as the product path.

Device (ADSP)
{
    Name (_HID, "QCOM24A8")
    Name (_UID, 0)
    Method (_STA, 0) { Return (0xF) }
}

Device (WCD0)
{
    Name (_HID, "QCOM24AA")
    Name (_CID, "WCD9385")
    Name (_UID, 0)
    Name (RSTG, 32)
    Method (_STA, 0) { Return (0xF) }
}

Device (SPK0)
{
    Name (_HID, "CIRR0041")
    Name (_CID, "CS35L41")
    Name (_UID, 0)
    Name (_DDN, "CS35L41-BR")
    Name (I2CA, 0x40)
    Name (SEBA, 0x00984000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x40, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC01", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}

Device (SPK1)
{
    Name (_HID, "CIRR0041")
    Name (_CID, "CS35L41")
    Name (_UID, 1)
    Name (_DDN, "CS35L41-BL")
    Name (I2CA, 0x41)
    Name (SEBA, 0x00984000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x41, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC01", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}

Device (SPK2)
{
    Name (_HID, "CIRR0041")
    Name (_CID, "CS35L41")
    Name (_UID, 2)
    Name (_DDN, "CS35L41-TL")
    Name (I2CA, 0x41)
    Name (SEBA, 0x0098C000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x41, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC03", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}

Device (SPK3)
{
    Name (_HID, "CIRR0041")
    Name (_CID, "CS35L41")
    Name (_UID, 3)
    Name (_DDN, "CS35L41-TR")
    Name (I2CA, 0x43)
    Name (SEBA, 0x0098C000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x43, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC03", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}
