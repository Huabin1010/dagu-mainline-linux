// IPCC mailbox. Live iomem: 00408000-00408fff qcom,ipcc@408000
// Used by QRTR / remoteproc. Not CAMSS.

Device (IPCC)
{
    Name (_HID, "QCOM24E4")
    Name (_UID, 0)
    Name (_DDN, "SM8250 IPCC")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00408000, 0x00001000)
        })
        Return (RBUF)
    }
}
