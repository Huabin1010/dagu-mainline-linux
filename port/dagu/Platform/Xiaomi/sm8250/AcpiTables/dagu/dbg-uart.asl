// Hardware debug UART. Live FDT: qcom,qup_uart@a90000 (QUP12 / GPIO34+35).
// interrupts = <0 0x165 4> -> GIC_SPI 357 -> ACPI 389.
// 1.8V TP7308/TP7307. Not USB. Not 0x988000 (keyboard I2C SE2).
// Type-C SBU mux S7301 is NM — do not claim UART on the Type-C plug.

Device (UR12)
{
    Name (_HID, "QCOM2470")
    Name (_UID, 12)
    Name (_DDN, "debug UART12")
    Name (TXGP, 34)
    Name (RXGP, 35)
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00A90000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {389}
        })
        Return (RBUF)
    }
}
