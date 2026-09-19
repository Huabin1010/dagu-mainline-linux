// Adreno 650 on dagu (SM8250).
// Linux: linux-mainline/linux/arch/arm64/boot/dts/qcom/sm8250.dtsi gpu@3d00000
//        reg = <0 0x03d00000 0 0x40000>
//        interrupts = <GIC_SPI 300> -> ACPI IRQ 332
// Live: dumps/dagu-20260826-210700-root/memory/iomem.txt  03d00000-03d3ffff : kgsl-3d0
// Board: linux-mainline/dts/sm8250-xiaomi-dagu.dts &gpu / &gmu / &gpu_zap_shader
//
// _HID is the SM8250 community QCDX bind (WOA-Drivers). Not Snapdragon X UGD.
// This table is source-complete only; WDDM on-device is a later board test.

Device (GPU0)
{
    Name (_HID, "QCOM24B4")
    Name (_CID, Package() { "QCOM027E", "ACPI\\QCOM24B4" })
    Name (_UID, 0)
    Name (_HRV, 0x650)

    Method (_STA, 0)
    {
        Return (0xF)
    }

    Device (MON0)
    {
        Method (_ADR) { Return (0) }
    }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x03D00000, 0x00040000)
            Memory32Fixed (ReadWrite, 0x02C7D000, 0x00002000)
            Memory32Fixed (ReadWrite, 0x02C90000, 0x0000A000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {332}
        })
        Return (RBUF)
    }
}

Device (GMU0)
{
    Name (_HID, "QCOM24B9")
    Name (_UID, 0)
    Name (_DDN, "Adreno 650 GMU")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x02C7D000, 0x00002000)
            Memory32Fixed (ReadWrite, 0x02C90000, 0x0000A000)
        })
        Return (RBUF)
    }
}
