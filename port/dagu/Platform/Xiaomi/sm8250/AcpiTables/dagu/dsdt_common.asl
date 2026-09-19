// Chip / boot facts for dagu (SM8250 / kona).
// SOID 356 = 0x164 from live FDT qcom,msm-id.
// STOR=1 UFS. Do not copy Linux interconnect deletions into ACPI.

Name(SOID, 356)
Name(STOR, 0x1)
Name(SIDS, "SM8250")
Name(SIDV, 0x00020001)
Name(SVMJ, 0x0002)
Name(SVMI, 0x0001)
Name(SDFE, 0x0000)
Name(SFES, "SM8250")
Name(SIDM, 0x0)
Name(SUFS, 0x0)
Name(PUS3, 0x1)
Name(SUS3, 0x0)
Name(SIDT, 0x0)
Name(SJTG, 0x0)
Name(SOSN, 0x0)
Name(PLST, 0x33)
Name(EMUL, 0x0)
Name (RMTB, 0x0)
Name (RMTX, 0x0)
Name (RFMB, 0x0)
Name (RFMS, 0x0)
Name (RFAB, 0x0)
Name (RFAS, 0x0)
Name (TCMA, 0x0)
Name (TCML, 0x0)
Name (SOSI, 0x0)
Name (PRP1, 0x00000001)
Name (SKUV, 0x1)

		 Name (ESNL, 20)
		 Name (DBFL, 23)

        // UFS @ 0x01D84000 — linux sm8250.dtsi ufs_mem_hc + iomem ufs_mem
        Include("ufs.asl")

        // Kryo 585 LPI — SM8250 template (elish), eight cores
        Include("Pep_lpi.asl")

        // Adreno 650 — linux gpu@3d00000 / iomem kgsl-3d0
        Include("graphics.asl")

        // GENI I2C/SPI controllers first — children use I2cSerialBusV2 / SPI
        Include("i2c.asl")

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
        Include("smmu.asl")
        Include("ipcc.asl")
        Include("smem.asl")
        Include("qmp.asl")
        Include("led.asl")
        Include("npu.asl")
        Include("ipa.asl")
