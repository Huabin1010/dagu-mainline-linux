// PM8150B Type-C TCPM (Type-C Port Manager, Type-C 端口管理器).
// Linux: sm8250-xiaomi-dagu.dts &pm8150b_typec okay (charge / PD).
// USB graph stays cut: DWC3 default peripheral. Windows host is a later board test.
// Do not raise vreg_l3a_0p9.

Device (TPC0)
{
    Name (_HID, "QCOM24C8")
    Name (_CID, "USBC000")
    Name (_UID, 0)
    Name (_DDN, "PM8150B Type-C")
    Method (_STA, 0) { Return (0xF) }
}
