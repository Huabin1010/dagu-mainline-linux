// IDT P9418 Smart Pen TX coil. Not tablet Qi RX.
// Linux: sm8250-xiaomi-dagu.dts wls_i2c_se8  pen-charger@3b
// Product path is still i2c-gpio (gpio24/25), CAF qupv3_se8. Do not invent GENI.
// IRQ GPIO113 falling; enable GPIO47; det GPIO145.

Device (PEN0)
{
    Name (_HID, "IDTP9418")
    Name (_UID, 0)
    Name (_DDN, "P9418 Smart Pen TX")
    Name (I2CA, 0x3B)
    Name (IRQG, 113)
    Name (ENAG, 47)
    Name (DETG, 145)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x3B, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC08", 0x00, ResourceConsumer, , Exclusive)
            GpioInt (Edge, ActiveLow, ExclusiveAndWake, PullUp, 0, "\\_SB.GIO0") {113}
        })
        Return (RBUF)
    }
}
