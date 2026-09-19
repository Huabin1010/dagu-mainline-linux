// Nanosic 803 magnetic keyboard MCU.
// Product: dagu-geni-i2c-experiment.on.dtsi &i2c2 keyboard@4c
// Linux overlay: nanosic-dagu.c  HID 15d9:00a3
// SE2 i2c@988000; IRQ GPIO83 falling; reset 141; wakeup 46; vdd 127; sleep 155
// Do not enable uart2/spi2 (same MMIO).

Device (KBMC)
{
    Name (_HID, "NANO0803")
    Name (_CID, "NANO00A3")
    Name (_UID, 0)
    Name (_DDN, "Nanosic 803")
    Name (I2CA, 0x4C)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            I2cSerialBusV2 (0x4C, ControllerInitiated, 400000,
                AddressingMode7Bit, "\\_SB.IC02", 0x00, ResourceConsumer, , Exclusive)
            GpioInt (Edge, ActiveLow, ExclusiveAndWake, PullUp, 0, "\\_SB.GIO0") {83}
        })
        Return (RBUF)
    }
}
