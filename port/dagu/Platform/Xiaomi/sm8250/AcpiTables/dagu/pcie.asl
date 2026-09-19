// PCIe0 + QCA6390 Wi-Fi (ath11k on Linux).
// Linux: sm8250.dtsi pcie@1c00000; sm8250-xiaomi-dagu.dts &pcie0 / &pcieport0/wifi@0
// iomem: 60300000-63ffffff : qcom,pcie@1c00000
// BDF: dumps bd_l81a.elf → board.bin. Do not use board-2.bin.
// WOA-Drivers: SM8250 CNSS / QCA6390, not nabu SM8150.

Device (PCI0)
{
    Name (_HID, "PNP0A08")
    Name (_CID, "PNP0A03")
    Name (_UID, 0)
    Name (_SEG, 0)
    Name (_BBN, 0)
    Name (_CCA, 1)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            WordBusNumber (ResourceProducer, MinFixed, MaxFixed, PosDecode,
                0x0000, 0x0000, 0x00FF, 0x0000, 0x0100)
            Memory32Fixed (ReadWrite, 0x01C00000, 0x00004000)
            Memory32Fixed (ReadWrite, 0x60000000, 0x04000000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {172}
        })
        Return (RBUF)
    }

    Device (WCN0)
    {
        Name (_ADR, 0x00000000)
        Name (_HID, "QCOM24D4")
        Name (_CID, "QCA6390")
        Method (_STA, 0) { Return (0xF) }
    }
}
