// SMEM already reserved in PlatformMemoryMapLib @ 0x80900000.
// Linux: reserved-memory smem. Do not map as Conv RAM.

Device (SMEM)
{
    Name (_HID, "QCOM00A5")
    Name (_UID, 0)
    Name (_DDN, "SM8250 SMEM")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x80900000, 0x00200000)
        })
        Return (RBUF)
    }
}
