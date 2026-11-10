// Minimal \_SB.URS0 for the Type-C DWC3 at 0x0A600000.
// The default Windows DSDT does not include usb.asl, so the DBG2
// namepath would not resolve. This SSDT adds only that device.
// No CDC-ACM child: this boot is for KDNET EEM, and the two cannot
// share the port.
DefinitionBlock ("", "SSDT", 2, "DAGU  ", "KDNET   ", 1)
{
    Scope (\_SB)
    {
        Device (URS0)
        {
            Name (_HID, "QCOM24A6")
            Name (_CID, "PNP0CA1")
            Name (_UID, Zero)
            Name (_CCA, Zero)
            Method (_STA, 0) { Return (0x0F) }
            Method (_CRS, 0, Serialized)
            {
                Name (RBUF, ResourceTemplate ()
                {
                    Memory32Fixed (ReadWrite, 0x0A600000, 0x00100000)
                    Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) { 165 }
                })
                Return (RBUF)
            }
        }
    }
}
