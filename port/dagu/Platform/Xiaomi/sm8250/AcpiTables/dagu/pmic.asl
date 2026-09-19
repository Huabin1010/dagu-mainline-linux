// SPMI arbiter + PM8150 / PM8150B / PM8150L.
// Linux: spmi@c440000; charger@1000 SID2; haptics@c000 SID3; typec; flash@d300
// Do not raise vreg_l3a_0p9 (CX). Volume Up is pm8150 gpio6 (not TLMM).

Device (SPMI)
{
    Name (_HID, "QCOM0C09")
    Name (_UID, 0)
    Name (_DDN, "SM8250 SPMI")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0C440000, 0x00001100)
            Memory32Fixed (ReadWrite, 0x0C600000, 0x02000000)
        })
        Return (RBUF)
    }
}

Device (PM00)
{
    Name (_HID, "QCOM24D0")
    Name (_UID, 0)
    Name (_DDN, "PM8150")
    Method (_STA, 0) { Return (0xF) }
}

Device (PM0B)
{
    Name (_HID, "QCOM24D1")
    Name (_UID, 0)
    Name (_DDN, "PM8150B")
    Method (_STA, 0) { Return (0xF) }
}

Device (PM0L)
{
    Name (_HID, "QCOM24D2")
    Name (_UID, 0)
    Name (_DDN, "PM8150L")
    Method (_STA, 0) { Return (0xF) }
}

Device (WDT0)
{
    Name (_HID, "QCOM24E2")
    Name (_UID, 0)
    Name (_DDN, "APSS WDT")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x17C10000, 0x00001000)
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, , , ) {32}
        })
        Return (RBUF)
    }
}
