// dagu battery: two BQ27Z561 gauges (2x 5000 mAh, 3.4-4.45 V) behind PM8150B.
// Linux: xiaomi-dual-fg.c combines fuel-gauge-r@55 (gpio28/29, SE0) and
//        fuel-gauge-l@55 (gpio36/37, SE13); pm8150b-charger-dagu.c charges.
//
// _HID DAGUB001 binds port/dagu/windows-drivers/dagu-battery, a WDM Battery
// class miniport that bit-bangs I2C on the gauge pins through the TLMM
// registers and reads charger status via SPMI observer reads, like
// nanosic-803 and dagu-pwrkey. So BAT0 declares NO resources on purpose:
// I2cSerialBusV2("\_SB.IC00"/"\_SB.IC13") would pull in qci2c8250 and the
// GENI/GPI/SMMU stack dagu lacks. ACPI0003 is not used: that HID is the AC
// adapter and would bind cmbatt.
//
// fg-disable gpio117/gpio91 must stay low (high isolates a cell); the driver
// never drives them. Charging stays on PM8150B hardware defaults; 67 W PPS
// (BQ25970 x2 on SE15/SE16) is a separate stage.

Device (BAT0)
{
    Name (_HID, "DAGUB001")
    Name (_UID, 0)
    Name (_DDN, "dagu Dual BQ27Z561 Battery")

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
