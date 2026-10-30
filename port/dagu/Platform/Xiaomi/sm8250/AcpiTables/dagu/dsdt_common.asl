// Chip / boot facts for dagu (SM8250 / kona). Do not copy Linux interconnect
// deletions into ACPI.
//
// These are placeholders, not values. AcpiPlatformUpdateLib (Mu, Sm8250)
// overwrites each one at boot with a fixed-width CopyMem after the AML prefix
// byte (SOID = 356 / 0x164 and PLST = 0x33 come from ChipInfo / PlatformInfo).
// The placeholder must already be encoded at exactly that width: 0xffffffff
// (DWord), 0xffff (Word), a QWord constant, a 15-char string for SIDS (16 bytes
// with NUL). A short encoding such as 0, 1, 356 or "SM8250" gets overrun, the
// AML after it is corrupted, Windows loads no ACPI namespace and the boot disk
// UFS0 never enumerates (bugcheck 0x7B). build-dagu-uefi.sh checks the widths.

Name(SOID, 0xffffffff)
Name(STOR, 0xffffffff)
Name(SIDS, "899800000000000")
Name(SIDV, 0xffffffff)
Name(SVMJ, 0xffff)
Name(SVMI, 0xffff)
Name(SDFE, 0xffff)
Name(SFES, "899800000000000")
Name(SIDM, 0xfffffffff)
Name(SUFS, 0xffffffff)
Name(PUS3, 0xffffffff)
Name(SUS3, 0xffffffff)
Name(SIDT, 0xffffffff)
Name(SJTG, 0xffffffff)
Name(SOSN, 0xaaaaaaaabbbbbbbb)
Name(PLST, 0xffffffff)
Name(EMUL, 0x0)
Name (RMTB, 0xaaaaaaaa)
Name (RMTX, 0xbbbbbbbb)
Name (RFMB, 0xcccccccc)
Name (RFMS, 0xdddddddd)
Name (RFAB, 0xeeeeeeee)
Name (RFAS, 0x77777777)
Name (TCMA, 0xDEADBEEF)
Name (TCML, 0xBEEFDEAD)
Name (SOSI, 0xdeadbeefffffffff)
Name (PRP1, 0xFFFFFFFF)
Name (SKUV, 0x1)

		 Name (ESNL, 20)
		 Name (DBFL, 23)

        // UFS @ 0x01D84000 — linux sm8250.dtsi ufs_mem_hc + iomem ufs_mem
        Include("ufs.asl")

        // Kryo 585 LPI — SM8250 template (elish), eight cores
        Include("Pep_lpi.asl")

        // Adreno 650 — linux gpu@3d00000 / iomem kgsl-3d0
        Include("graphics.asl")

        // TLMM (qcgpio8250, ACPI\QCOM250D). Every GpioInt/GpioIo resource
        // below names \_SB.GIO0, so it comes before its consumers.
        Include("gpio.asl")

        // GENI I2C/SPI controllers first — children use I2cSerialBusV2 / SPI
        Include("i2c.asl")

        // GENI SPI (QUP0 SE4) for the Himax touch — split from i2c.asl so the
        // touch stack (gpio + spi + himax) can be built via DSDT_ONLY alone.
        Include("spi.asl")

        // Himax HX83121 on QUP0 SE4 — dagu-geni-spi-experiment.on.dtsi
        Include("himax.asl")

        // UX / performance: Wi-Fi, BT, USB, audio, keyboard, battery,
        // backlight, hall, SLPI, TSENS. Cameras stay out (CAMSS/IFE).
        Include("pep0.asl")
        Include("pcie.asl")
        Include("bluetooth.asl")
        Include("usb.asl")
        Include("dbg-uart.asl")
        Include("audio.asl")
        Include("keyboard.asl")
        Include("battery.asl")
        Include("buttons.asl")
        Include("backlight.asl")
        Include("sensors.asl")
        Include("thermal.asl")
        Include("venus.asl")
        Include("pen.asl")
        Include("typec.asl")
        Include("haptics.asl")
        Include("display.asl")
        Include("cdsp.asl")
        Include("pmic.asl")
        Include("lpass.asl")
        // SMMU devices (MMU0 apps / MMU1 Adreno, both ACPI\QCOM2509 ->
        // qcsmmu8250.sys, which binds ACPI\VEN_QCOM&DEV_2509&REV_0001/0002).
        // Enabled in stage 8 because the GPU0.ENGS table ported into
        // graphics-qcom253a.asl declares MMUINFO "ArmSmmuV2" for all five
        // engines, and the old HIDs (QCOM24C2/QCOM24C3) matched no INF at all.
        //
        // How far the evidence goes: in qcdxkm8250.sys the SMMU-interface
        // failure logs that were read are all on the Venus video engine path
        // (VedInitSMMUInterface, "Unable to get SMMU Interface"), and their
        // callers were not resolved. So "the GPU cannot init without SMMU" is
        // not established; what is established is that ENGS asks for an
        // ArmSmmuV2 interface that currently has no driver behind it.
        //
        // This only adds the devices. No IORT is added: boot still goes
        // UFS0 -> storufs with direct DMA, as on the SM8250 phones that boot
        // Windows (alioth, lmi, elish ship no IORT). With the MTP IORT in the
        // table set, \_SB.UFS0 is mapped behind the 0x15000000 SMMU and the
        // boot disk never appears (bugcheck 0x7B, 0xC0000034).
        Include("smmu.asl")
        Include("ipcc.asl")
        Include("smem.asl")
        Include("qmp.asl")
        Include("led.asl")
        Include("npu.asl")
        Include("ipa.asl")
