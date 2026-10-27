// SM8250 TLMM for Windows. qcgpio8250.inf binds ACPI\QCOM250D (boot start,
// GPIOClx0101); the old QCOM0C22 placeholder matched no driver, so every
// GpioInt / GpioIo pointing at \_SB.GIO0 had no provider.
//
// Copied from the SM8250 MTP DSDT (SurfaceDuoACPI/QcomACPI/8250/src/
// DSDT_8250_MTP.dsl, Device GIO0). Base 0x0F100000 is the SM8250 west tile
// (linux sm8250.dtsi tlmm reg west/south/north); 0xF0 = GIC_SPI 208 + 32, the
// TLMM summary interrupt. OFNI is read by qcgpio.sys: 0xB4 = 180 pins.
// _AEI (GPU pin 189) and _SUB (MTP PSUB) are left out: dagu has no GPU0
// event handler and the INF matches on _HID only.

Device (GIO0)
{
    Name (_HID, "QCOM250D")
    Name (_CID, "QCOMFFE3")
    Name (_UID, Zero)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0F100000, 0x00DDC000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) {0xF0}
            Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) {0xF0}
            Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) {0xF0}
            Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) {0x242}
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Shared, , , ) {0x25B}
            Interrupt (ResourceConsumer, Level, ActiveHigh, Shared, , , ) {0x259}
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, , , ) {0x22C}
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, , , ) {0x24E}
        })
        Return (RBUF)
    }

    Method (OFNI, 0, NotSerialized)
    {
        Name (RBUF, Buffer (0x02) { 0xB4, 0x00 })
        Return (RBUF)
    }

    Name (GABL, Zero)
    Method (_REG, 2, NotSerialized)
    {
        If ((Arg0 == 0x08))
        {
            GABL = Arg1
        }
    }
}
