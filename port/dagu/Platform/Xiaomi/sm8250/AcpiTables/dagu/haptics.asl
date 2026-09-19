// PM8150B LRA haptics @ SID 3 0xc000.
// Linux: sm8250-xiaomi-dagu.dts pmic@3 haptics@c000  qcom,pmi632-vib
// Overlay probe: pm8xxx_vib_ffmemless. No AP MMIO.

Device (VIB0)
{
    Name (_HID, "QCOM24C4")
    Name (_UID, 0)
    Name (_DDN, "PM8150B LRA")
    Name (SPMI, 0xC000)
    Method (_STA, 0) { Return (0xF) }
}
