// Venus (Qualcomm video codec, 高通视频编解码器) — Windows video, not SoftISP.
// Linux: sm8250.dtsi video-codec@aa00000; sm8250-xiaomi-dagu.dts &venus
//        firmware qcom/sm8250/xiaomi/dagu/venus.mdt
// GIC_SPI 174 -> ACPI IRQ 206. Do not use FFmpeg / CPU decode as the path.

Device (VEN0)
{
    Name (_HID, "QCOM24B8")
    Name (_CID, "QCOM24B8")
    Name (_UID, 0)
    Name (_DDN, "SM8250 Venus")
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0AA00000, 0x00100000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {206}
        })
        Return (RBUF)
    }
}
