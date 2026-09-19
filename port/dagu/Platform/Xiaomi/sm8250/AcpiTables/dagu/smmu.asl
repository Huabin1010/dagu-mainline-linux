// SMMU: apps @15000000 (already in memmap) + Adreno @3da0000.
// Linux: apps_smmu, adreno_smmu okay with gpu.

Device (MMU0)
{
    Name (_HID, "QCOM24C2")
    Name (_UID, 0)
    Name (_DDN, "APPS SMMU")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x15000000, 0x000D0000)
        })
        Return (RBUF)
    }
}

Device (MMU1)
{
    Name (_HID, "QCOM24C3")
    Name (_UID, 1)
    Name (_DDN, "Adreno SMMU")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x03DA0000, 0x00010000)
        })
        Return (RBUF)
    }
}
