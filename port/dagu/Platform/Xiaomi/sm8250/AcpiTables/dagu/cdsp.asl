// CDSP (Compute DSP, 计算数字信号处理器) Hexagon 698.
// Linux: remoteproc@8300000 cdsp.mbn + fastrpc. Do not use for IFE or WebNN.

Device (CDSP)
{
    Name (_HID, "QCOM24C1")
    Name (_UID, 0)
    Name (_DDN, "SM8250 CDSP")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x08300000, 0x00010000)
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, , , ) {610}
        })
        Return (RBUF)
    }
}
