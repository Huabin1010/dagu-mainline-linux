// LPASS macros + SoundWire for WCD9385 mics (AMIC5 / ADC4 INP5).
// Linux: rxmacro@3200000, soundwire@3250000, vamacro, swr1/swr2 okay.
// Speakers stay TDM to CS35L41. No 3.5mm jack. A2DP is SLIMBUS_7_RX.

Device (LPAS)
{
    Name (_HID, "QCOM24A9")
    Name (_UID, 0)
    Name (_DDN, "SM8250 LPASS")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x03200000, 0x00010000)
            Memory32Fixed (ReadWrite, 0x03250000, 0x00002000)
        })
        Return (RBUF)
    }
}

Device (SWR0)
{
    Name (_HID, "QCOM24AB")
    Name (_UID, 0)
    Name (_DDN, "SoundWire")
    Method (_STA, 0) { Return (0xF) }
}
