// Hall folio + tablet mode. Volume/power stay on ButtonsDxe in UEFI.
// Linux: sm8250-xiaomi-dagu.dts &gpio_keys
//   hall_key GPIO110 SW_LID; hall_key1 GPIO121 SW_TABLET_MODE
// Volume Up is pm8150 gpio6 (elish-common), not a TLMM line.
// Windows uses hall for rotation lock / folio.

Device (HALL)
{
    Name (_HID, "ACPI0011")
    Name (_UID, 0)
    Method (_STA, 0) { Return (0xF) }

    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            GpioInt (Edge, ActiveLow, ExclusiveAndWake, PullUp, 0, "\\_SB.GIO0") {110}
            GpioInt (Edge, ActiveHigh, ExclusiveAndWake, PullUp, 0, "\\_SB.GIO0") {121}
        })
        Return (RBUF)
    }
}

// Power / volume: UEFI ButtonsDxe + PM8150 PON. Not TLMM except hall.
Device (PWRB)
{
    Name (_HID, "PNP0C0C")
    Name (_UID, 0)
    Method (_STA, 0) { Return (0xF) }
}

Device (VOLD)
{
    Name (_HID, "PNP0C0E")
    Name (_UID, 0)
    Name (_DDN, "pm8941_resin vol-down")
    Method (_STA, 0) { Return (0xF) }
}

Device (VOLU)
{
    Name (_HID, "PNP0C0E")
    Name (_UID, 1)
    Name (_DDN, "pm8150 gpio6 vol-up")
    Method (_STA, 0) { Return (0xF) }
}
