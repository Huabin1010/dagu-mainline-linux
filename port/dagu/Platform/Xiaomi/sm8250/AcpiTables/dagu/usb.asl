// USB DWC3 primary (HS). Linux: usb@a600000 / usb@a6f8800
// sm8250-xiaomi-dagu.dts: dr_mode=otg, default peripheral, SS PHY off.
// iomem: 0a60c100 dwc3@a600000. GIC_SPI 133 -> IRQ 165.
// Windows wants host/OTG; Linux gadget g_serial is not the WoA path.

Device (URS0)
{
    Name (_HID, "QCOM24A6")
    Name (_CID, "PNP0CA1")
    Name (_UID, 0)
    Name (_CCA, 0)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0A600000, 0x00100000)
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, , , ) {165}
        })
        Return (RBUF)
    }

    Device (USB0)
    {
        Name (_ADR, 0)
        Name (_S0W, 3)
        Method (_STA, 0) { Return (0xF) }
    }

    // USB CDC-ACM debug console. Same class as Linux CONFIG_USB_G_SERIAL
    // (host 0525:a4a7 / ttyACM). Device-role only. Not Mass Storage / LSMS.
    Device (ACM0)
    {
        Name (_HID, "QCOM24CC")
        Name (_CID, "USBF0101")
        Name (_UID, 0)
        Name (_DDN, "USB CDC-ACM console")
        Name (VIDP, 0x0525)
        Name (PIDP, 0xA4A7)
        Name (CLSS, 0x02)
        Name (SUBC, 0x02)
        Name (PROT, 0x01)
        Name (BAUD, 115200)
        Method (_STA, 0) { Return (0xF) }
    }
}

Device (VBS0)
{
    Name (_HID, "QCOM24C9")
    Name (_UID, 0)
    Name (_DDN, "OTG VBUS GPIO152")
    Name (BSTG, 152)
    Method (_STA, 0) { Return (0xF) }
}

Device (RDV0)
{
    Name (_HID, "PRS5169")
    Name (_UID, 0)
    Name (_DDN, "PS5169 USB3/DP")
    Name (I2CA, 0x28)
    Name (ENAG, 69)
    Method (_STA, 0) { Return (0x0) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x28, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC17", 0x00, ResourceConsumer, , Exclusive)
        })
        Return (RBUF)
    }
}
