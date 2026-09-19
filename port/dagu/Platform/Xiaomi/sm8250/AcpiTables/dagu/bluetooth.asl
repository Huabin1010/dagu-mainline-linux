// QCA6390 Bluetooth on GENI UART6.
// Linux: sm8250-xiaomi-dagu.dts &uart6  serial@998000
//        compatible qcom,qca6390-bt; max-speed 3000000
//        BT_EN via qca6390-pmu GPIO21 pwrseq — not enable-gpios on this node
//        firmware qca/htbtfw20.tlv + htnv20.bin; do not set firmware-name
// GIC_SPI 607 -> ACPI IRQ 639
// Do not put firmware-name on &qupv3_id_0.

Device (UAR6)
{
    Name (_HID, "QCOM2470")
    Name (_UID, 6)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x00998000, 0x00004000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {639}
        })
        Return (RBUF)
    }

    Device (BTH0)
    {
        Name (_HID, "QCOM2464")
        Name (_CID, "QCA6390")
        Name (_UID, 0)
        Name (SPHZ, 3000000)
        Name (ENAG, 21)
        Method (_STA, 0) { Return (0xF) }
    }
}

Device (WCN1)
{
    Name (_HID, "QCOM24D5")
    Name (_UID, 0)
    Name (_DDN, "QCA6390 PMU")
    Name (BTEN, 21)
    Method (_STA, 0) { Return (0xF) }
}
