// QCA6390 Bluetooth on QUP0 GENI UART SE6 (serial@998000).
//
// Two sibling nodes, MTP-style, with no _DEP on PEP0 (dagu has no working
// Qualcomm PEP):
//
//   UAR6 - the UART controller, ACPI id QCOM2518. This is the id the stock
//          qcuart8250 binds, and the node Windows' ACPI validated and booted
//          with. We keep this exact node (a brand-new _HID bugchecked acpi.sys
//          with ACPI_BIOS_ERROR 0xA5) and instead REPLACE the driver: our own
//          SerCx2 PIO driver (port/dagu/windows-drivers/dagu-geni-uart) binds
//          ACPI\QCOM2518 after qcuart8250 is uninstalled. qcuart cannot work
//          on dagu -- it needs qcpep8250 to power the SE at open time, so every
//          CreateFile returns 0xC00000A3 -- but the ACPI node itself is fine.
//          _UID 0x12 is qcuart's "Instance 18" (Bluetooth, PIO); harmless to
//          our driver, kept so the AML is identical to the booting image.
//
//   BTH0 - the QCA6390 radio, bound by the stock transport qcbtfmuart_hst8180
//          (ACPI\QCOM0471, _SUB MTPC8180), which speaks HCI and loads
//          htbtfw20.tlv/htnv20.bin. It opens UAR6 through the UartSerialBusV2
//          connection + Resource Hub.
//
// Pre-reqs done in UEFI before Windows: DaguQupDxe loads the UART protocol
// firmware into SE6, muxes GPIO16..19 to qup6 and sets gcc_qupv3_wrap0_s6_clk
// to 100 MHz (a UART-friendly rate in the QUP s2 freq table); DaguPcieDxe
// powers QCA6390 and asserts BT_EN GPIO21.
//
// Linux resources: 0x00998000/0x4000, GIC_SPI 607 -> ACPI interrupt 639.

Device (UAR6)
{
    Name (_HID, "QCOM2518")
    Name (_UID, 0x12)
    Name (_CCA, Zero)
    Method (_STA, 0) { Return (0x0B) }

    Method (_CRS, 0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00998000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , )
            {
                639
            }
            GpioInt (Edge, ActiveHigh, Exclusive, PullNone, 0,
                "\\_SB.GIO0", 0, ResourceConsumer, , ) { 46 }
        })
        Return (RBUF)
    }
}

Device (BTH0)
{
    Name (_HID, "QCOM0471")
    Name (_SUB, "MTPC8180")
    Name (_UID, Zero)
    Name (_PRW, Package () { Zero, Zero })
    Name (_S4W, 0x02)
    Name (_S0W, 0x02)
    Method (_STA, 0) { Return (0x0F) }

    Method (_CRS, 0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            // 115200 8N1 hardware flow. The transport may raise the baud after
            // ROM sync; our dagu-geni-uart driver reprograms the GENI divider.
            UartSerialBusV2 (115200, DataBitsEight, StopBitsOne,
                0xC0, LittleEndian, ParityTypeNone, FlowControlHardware,
                0x20, 0x20, "\\_SB.UAR6",
                0x00, ResourceConsumer, , Exclusive,
                )
        })
        Return (RBUF)
    }
}
