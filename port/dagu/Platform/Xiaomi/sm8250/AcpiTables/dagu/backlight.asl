// Dual KTZ8866 backlight (L81A). Product: dagu-geni-i2c-experiment.on.dtsi
// SE11 i2c@a8c000 @0x11  +  SE9 i2c@a84000 @0x11
// Overlay: ktz8866.c  display_panel backlight + backlight-aux
// Do not bind Himax reset to GPIO100 (panel tp-reset).

Device (BL0)
{
    Name (_HID, "KTZ8866")
    Name (_UID, 0)
    Name (I2CA, 0x11)
    Name (SEBA, 0x00A8C000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x11, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC11", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}

Device (BL1)
{
    Name (_HID, "KTZ8866")
    Name (_UID, 1)
    Name (I2CA, 0x11)
    Name (SEBA, 0x00A84000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x11, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC09", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}
