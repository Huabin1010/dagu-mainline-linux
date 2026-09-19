// PEP0 — Windows power / PEP (Power Engine Plugin, 电源引擎插件) bind.
// Linux: qcom-cpufreq-hw + EPSS LUT (do not copy interconnect deletions).
Device (PEP0)
{
    Name (_HID, "QCOM2430")
    Name (_CID, "ACPI\\QCOM2430")
    Name (_UID, 0)
    Method (_STA, 0) { Return (0xF) }
}
