// QCA6390 Bluetooth on QUP0 GENI UART SE6 (serial@998000).
//
// Two sibling nodes, MTP-style, with no _DEP on PEP0 (dagu has no working
// Qualcomm PEP):
//
//   UAR6 - the UART controller. Bound by our own SerCx2 PIO driver
//          (port/dagu/windows-drivers/dagu-geni-uart, ACPI\DAGU0006), NOT the
//          stock qcuart8250. qcuart "starts" but every open returns
//          0xC00000A3 because it needs qcpep8250 to power the SE at open time,
//          and dagu cannot load that PEP. Our driver drives the SE-local GENI
//          UART FIFO directly instead.
//
//   BTH0 - the QCA6390 radio. Bound by the stock transport
//          qcbtfmuart_hst8180 (ACPI\QCOM0471, _SUB MTPC8180), which speaks HCI
//          and loads htbtfw20.tlv/htnv20.bin. It opens UAR6 through the
//          UartSerialBusV2 connection + Resource Hub.
//
// Pre-reqs done in UEFI before Windows: DaguQupDxe loads the UART protocol
// firmware into SE6, muxes GPIO16..19 to qup6 and leaves the QUP clocks on
// (gcc_qupv3_wrap0_s6_clk at a UART-friendly rate); DaguPcieDxe powers QCA6390
// and asserts BT_EN GPIO21.
//
// Linux resources: 0x00998000/0x4000, GIC_SPI 607 -> ACPI interrupt 639.
// There is no dagu-specific BT host-wake GPIO in the Linux board description,
// so there is no GpioInt here (MTP's GPIO46 was tried and did not help).

Device (UAR6)
{
    Name (_HID, "DAGU0006")      // our dagu-geni-uart SerCx2 controller
    Name (_UID, 6)
    Name (_CCA, Zero)
    Method (_STA, 0) { Return (0x0F) }

    Method (_CRS, 0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00998000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , )
            {
                639
            }
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
            // Initial speed is 115200. The QCA transport raises it (up to
            // 3.2 Mbps) via IOCTL_SERIAL_SET_BAUD_RATE after ROM sync; our
            // dagu-geni-uart driver reprograms the GENI serial divider.
            UartSerialBusV2 (115200, DataBitsEight, StopBitsOne,
                0xC0, LittleEndian, ParityTypeNone, FlowControlHardware,
                0x20, 0x20, "\\_SB.UAR6",
                0x00, ResourceConsumer, , Exclusive,
                )
        })
        Return (RBUF)
    }
}
