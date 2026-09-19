// SLPI (Sensor Low Power Island, 传感器低功耗岛) — IMU / ALS.
// Linux: &slpi slpi.mbn + dagu-ssc / hexagonrpcd. Do not guess IMU on AP I2C.
// Windows rotation / ALS need this + a community SSC client, not Linux hexagonrpcd.

Device (SLPI)
{
    Name (_HID, "QCOM24C0")
    Name (_UID, 0)
    Name (_DDN, "SM8250 SLPI")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x05C00000, 0x00004000)
        })
        Return (RBUF)
    }
}
