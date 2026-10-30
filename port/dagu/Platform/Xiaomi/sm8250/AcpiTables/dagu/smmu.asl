// =============================================================================
// SMMU: APPS @0x15000000 + Adreno @0x03DA0000
// =============================================================================
//
// 阶段 8（见 docs/woa-dagu-gpu-stage8-2026-10-30.md）把 HID 对齐参考板。
//
// 此前这两个节点用的是社区式 HID QCOM24C2 / QCOM24C3。全仓库扫描确认：
// winarm/drivers/QC8250/Drivers/SOC/SMMU/qcsmmu8250.inf 只绑定
//   ACPI\VEN_QCOM&DEV_2509&REV_0001
//   ACPI\VEN_QCOM&DEV_2509&REV_0002
// 也就是说 QCOM24C2/QCOM24C3 没有任何驱动 INF 认领，设备会枚举但停在无驱动。
// 参考板 qcom-mtp8250 的 MMU0/MMU1 同用 _HID "QCOM2509"，靠 _UID 0/1 区分，
// 与上面 INF 一致，所以这里照搬。
//
// REV_ 后缀来自 _HRV。参考板用 Alias(\_SB.SVMJ, _HRV)，SVMJ 由
// AcpiPlatformUpdateLib 在启动时填成芯片大版本（SM8250 v1 -> 1，v2 -> 2），
// 正好对上 INF 的 REV_0001/REV_0002。dsdt_common.asl 已有 SVMJ 占位符
// （Name(SVMJ, 0xffff)，2 字节 Word，宽度不可改），所以这里也用 Alias。
//
// 地址与长度取自 dagu 自己的 PlatformMemoryMapLib.c：
//   "SMMU"         0x15000000 0x000D0000
//   "ADRENO SMMU"  0x03DA0000 0x00010000
// 参考板 MMU0 写的是 0x00100000，比 dagu memmap 里的 0x000D0000 大。保留 dagu
// 的长度，避免声明一段 UEFI 没有映射的区间。
//
// 为什么现在能启用：
// 之前注释掉这两个节点的理由是启动盘。那条风险来自 IORT——表集里带 MTP 的 IORT
// 时 \_SB.UFS0 被映射到 0x15000000 SMMU 后面，启动盘枚举不出来（0x7B /
// 0xC0000034）。dagu 不出 IORT，UFS0 仍是直通 DMA，这一点本次没有改动。
// 单独存在 SMMU 设备节点不会改变 UFS0 的 DMA 路径。
//
// 为什么现在改：
// graphics-qcom253a.asl 的 ENGS 表里 5 个引擎的 MMUINFO 都声明 "ArmSmmuV2"，
// 驱动镜像里也有 "SMMUINTERFACEID" 字符串，说明它要向 SMMU 驱动取一个接口。
// 参考板的 GPU0._DEP 同样列了 MMU0/MMU1。原来的 QCOM24C2/QCOM24C3 没有任何
// INF 认领，这个接口背后根本没有驱动。
//
// 证据到哪一步为止：qcdxkm8250.sys 里读到的 SMMU 接口失败日志（
// VedInitSMMUInterface、"Unable to get SMMU Interface"）都在 Venus 视频引擎
// 路径上，这两处的调用者没有解析出来。所以「没有 SMMU 则 GPU 必然初始化失败」
// 并未被证实，已证实的只是 ENGS 声明了一个当前无驱动的接口。
//
// 本阶段不恢复 _DEP：参考板 MMU0._DEP 指向 \_SB.MMU1、MMU1._DEP 指向 \_SB.PEP0，
// 而 dagu 的 PEP0 当前是禁用状态，写进去会产生悬空引用。
// =============================================================================

Device (MMU0)
{
    Name (_HID, "QCOM2509")   // qcsmmu8250.inf: ACPI\VEN_QCOM&DEV_2509&REV_000x
    Name (_UID, 0)            // 0 = APPS SMMU
    Alias (\_SB.SVMJ, _HRV)   // 芯片大版本 -> INF 的 REV_0001 / REV_0002
    Name (_DDN, "APPS SMMU")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x15000000, 0x000D0000)
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x00000081 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x00000082 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x00000083 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x00000084 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x00000170 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x00000171 }
        })
        Return (RBUF)
    }
}

Device (MMU1)
{
    Name (_HID, "QCOM2509")   // 与 MMU0 同 HID，靠 _UID 区分（照搬参考板）
    Name (_UID, 1)            // 1 = Adreno SMMU
    Alias (\_SB.SVMJ, _HRV)
    Name (_DDN, "Adreno SMMU")
    Method (_STA, 0) { Return (0xF) }
    Method (_CRS, 0x0, NotSerialized)
    {
        Name (RBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x03DA0000, 0x00010000)
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x000002C6 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x000002C7 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x000002C8 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x000002C9 }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x000002CA }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x000002CB }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x000002CC }
            Interrupt (ResourceConsumer, Edge, ActiveHigh, Exclusive, ,, ) { 0x000002CD }
        })
        Return (RBUF)
    }
}
