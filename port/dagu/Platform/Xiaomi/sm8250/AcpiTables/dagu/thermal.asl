// TSENS so Windows can thermal-throttle instead of guessing.
// Linux: CONFIG_QCOM_TSENS; dagu-adaptation-status.md CPU 温度已通.

Device (TSNS)
{
    Name (_HID, "QCOM24E0")
    Name (_UID, 0)
    Name (_DDN, "SM8250 TSENS")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0C222000, 0x00001000)
            Memory32Fixed (ReadWrite, 0x0C263000, 0x00000200)
        })
        Return (RBUF)
    }
}
