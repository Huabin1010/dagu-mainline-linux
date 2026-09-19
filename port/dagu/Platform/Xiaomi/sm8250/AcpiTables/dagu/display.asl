// L81A + SM8250 MDSS / DPU. Linux: display-subsystem@ae00000, dpu@ae01000
// dsi@ae94000 / dsi@ae96000 dual-DPHY, panel-xiaomi-dagu-l81a.c 1600x2560 120Hz DSC
// GIC_SPI 83 -> IRQ 115. Not elish NT36523 C-PHY. SimpleFb is UEFI only.

Device (MDSS)
{
    Name (_HID, "QCOM24B5")
    Name (_UID, 0)
    Name (_DDN, "SM8250 MDSS")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0AE00000, 0x00001000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {115}
        })
        Return (RBUF)
    }

    Device (DPU0)
    {
        Name (_ADR, 1)
        Name (_HID, "QCOM24B6")
        Name (_DDN, "SM8250 DPU")
        Method (_STA, 0) { Return (0xF) }
        Method (_CRS, 0x0, NotSerialized)
        {
            Name (RBUF, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x0AE01000, 0x0008F000)
                Memory32Fixed (ReadWrite, 0x0AEB0000, 0x00003000)
            })
            Return (RBUF)
        }
    }

    Device (DSI0)
    {
        Name (_ADR, 2)
        Name (_HID, "QCOM24B7")
        Name (_UID, 0)
        Method (_STA, 0) { Return (0xF) }
        Method (_CRS, 0x0, NotSerialized)
        {
            Name (RBUF, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x0AE94000, 0x00000400)
            })
            Return (RBUF)
        }
    }

    Device (DSI1)
    {
        Name (_ADR, 3)
        Name (_HID, "QCOM24B7")
        Name (_UID, 1)
        Method (_STA, 0) { Return (0xF) }
        Method (_CRS, 0x0, NotSerialized)
        {
            Name (RBUF, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x0AE96000, 0x00000400)
            })
            Return (RBUF)
        }
    }
}

Device (PNL0)
{
    Name (_HID, "XIA00001")
    Name (_UID, 0)
    Name (_DDN, "L81A 1600x2560 120Hz")
    Name (XRES, 1600)
    Name (YRES, 2560)
    Name (RFSH, 120)
    Name (DSCB, 1)
    Name (RSTG, 75)
    Name (TPRG, 100)
    Name (HWEG, 139)
    Method (_STA, 0) { Return (0xF) }
}
