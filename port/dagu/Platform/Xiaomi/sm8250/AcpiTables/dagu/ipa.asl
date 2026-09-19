// IPA firmware carveouts. Linux: pil_ipa_fw@86800000 + pil_ipa_gsi@86810000.
// Live iomem has no IPA CSRs in the HyperOS dump. Do not invent 0x1e40000.

Device (IPA0)
{
    Name (_HID, "QCOM24CB")
    Name (_UID, 0)
    Name (_DDN, "SM8250 IPA PIL")
    Name (PILB, 0x86800000)
    Name (PILS, 0x00010000)
    Name (GSIB, 0x86810000)
    Name (GSIS, 0x0000A000)
    Method (_STA, 0) { Return (0xF) }
}
