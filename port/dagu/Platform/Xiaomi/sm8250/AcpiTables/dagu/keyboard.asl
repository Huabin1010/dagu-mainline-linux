// Nanosic 803 magnetic keyboard MCU (Xiaomi Pad 5 Pro 12.4 folio keyboard).
// Linux: linux-mainline/overlays/linux/drivers/input/keyboard/nanosic-dagu.c
//        I2C 0x4c on gpio115 (SDA) / gpio116 (SCL), IRQ GPIO83 falling,
//        vdd 127, reset 141, sleep 155 (powered by DaguQupDxe PowerKeyboard).
//
// _HID NANO0803 binds port/dagu/windows-drivers/nanosic-803, a self-contained
// HIDCLASS minidriver that bit-bangs I2C on gpio115/116 through the TLMM
// registers and polls the GPIO83 data line, like the Linux i2c-gpio fallback
// node and the Himax touch driver. So KBD0 declares NO resources on purpose:
// an I2cSerialBusV2("\_SB.IC02") would pull in qci2c8250 and the GENI/GPI/
// SMMU stack dagu lacks (the qcspi8250 analogue hung the boot).

Device (KBD0)
{
    Name (_HID, "NANO0803")
    Name (_CID, "NANO0803")
    Name (_UID, 0)
    Name (_DDN, "Xiaomi Keyboard (Nanosic 803)")

    Method (_STA, 0)
    {
        Return (0xF)
    }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate () {})
        Return (RBUF)
    }
}
