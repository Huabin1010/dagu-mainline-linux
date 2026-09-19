//
// dagu DSDT. OEM ID is SM8250 (kona), not the SDM850 placeholder.
// qcom,msm-id = <0x164 ...> in dumps/dagu-20260826-210700-root/dt/fdt.dts
//
DefinitionBlock("DSDT.AML", "DSDT", 0x02, "QCOMM ", "SM8250 ", 3)
{
    Scope(\_SB_) {
        Include("dsdt_common.asl")
    }
}
