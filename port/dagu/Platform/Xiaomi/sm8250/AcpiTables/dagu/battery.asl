// Dual BQ27Z561 + PM8150B SMB5 5 V charge + BQ25970×2 67 W PPS.
// Product I2C: dagu-geni-i2c-experiment.on.dtsi  SE0/SE13 FG @0x55
// Overlay: xiaomi-dual-fg.c + pm8150b-charger-dagu.c
// Linux: battery_l/r 5000 mAh / 3.4–4.45 V. Do not raise vreg_l3a_0p9.

Device (BMS0)
{
    Name (_HID, "ACPI0003")
    Name (_UID, 0)
    Name (_DDN, "dagu dual FG")
    Name (DSGN, 10000)
    Name (VMIN, 3400)
    Name (VMAX, 4450)
    Name (DIS0, 117)
    Name (DIS1, 91)
    Method (_STA, 0) { Return (0xF) }
    Method (_PCL, 0) { Return (Package() { \_SB }) }
    Method (_PSR, 0) { Return (0x1) }
}

Device (FG0)
{
    Name (_HID, "BQ270561")
    Name (_UID, 0)
    Name (_DDN, "BQ27Z561-L")
    Name (I2CA, 0x55)
    Name (SEBA, 0x00A94000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x55, ControllerInitiated, 100000,
                AddressingMode7Bit, "\\_SB.IC13", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}

Device (FG1)
{
    Name (_HID, "BQ270561")
    Name (_UID, 1)
    Name (_DDN, "BQ27Z561-R")
    Name (I2CA, 0x55)
    Name (SEBA, 0x00980000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x55, ControllerInitiated, 100000,
                AddressingMode7Bit, "\\_SB.IC00", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}

Device (SMB5)
{
    Name (_HID, "QCOM24B0")
    Name (_UID, 0)
    Name (_DDN, "PM8150B SMB5")
    Method (_STA, 0) { Return (0xF) }
}

Device (PMP0)
{
    Name (_HID, "BQ270970")
    Name (_UID, 0)
    Name (_DDN, "BQ25970-M")
    Name (I2CA, 0x66)
    Name (SEBA, 0x00884000)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x66, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC15", 0x00, ResourceConsumer, , Exclusive)
            GpioInt (Edge, ActiveLow, Exclusive, PullUp, 0, "\\_SB.GIO0") {68}
        })
        Return (RBUF)
    }
}

Device (PMP1)
{
    Name (_HID, "BQ270970")
    Name (_UID, 1)
    Name (_DDN, "BQ25970-S")
    Name (I2CA, 0x66)
    Name (SEBA, 0x00888000)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x66, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC16", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}
