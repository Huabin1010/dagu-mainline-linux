// USB SuperSpeed QMP PHY. Linux &usb_1_qmpphy is disabled; HS only.
// _STA=0 until SuperSpeed is trained. Do not claim DP/USB3 ready.

Device (QMP0)
{
    Name (_HID, "QCOM24A7")
    Name (_UID, 0)
    Name (_DDN, "USB1 QMP PHY")
    Method (_STA, 0) { Return (0x0) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x088E2000, 0x00001000)
        })
        Return (RBUF)
    }
}
