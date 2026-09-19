// PM8150L flash LED @d300. Linux: &pm8150l_flash led-0 white:flash.
// Torch only. Not CAMSS / IFE / CCI. Do not bind a camera sensor here.

Device (LED0)
{
    Name (_HID, "QCOM24E8")
    Name (_UID, 0)
    Name (_DDN, "white:flash torch")
    Name (SIDN, 0xA)
    Name (OFFS, 0xD300)
    Name (IMAX, 500000)
    Name (FMAX, 1500000)
    Method (_STA, 0) { Return (0xF) }
}
