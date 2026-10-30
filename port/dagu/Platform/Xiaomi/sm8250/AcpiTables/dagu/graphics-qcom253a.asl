// =============================================================================
// dagu GPU 节点 —— 高通 MTP 单体模型 (QCOM253A)
// =============================================================================
//
// 背景（stage2 调查结论，见 docs/woa-dagu-gpu-stage2-2026-10-30.md）：
//
// 仓库里实际存在的 GPU 驱动是 winarm/drivers/QC8250/Drivers/Graphics/DXKM/
// qcdx8250.inf，它只绑定一个硬件 ID：ACPI\VEN_QCOM&DEV_253A（及若干 REV_ 变体）。
// 这是高通 MTP 的“单体式”GPU 模型：一个 QCOM253A 节点的 _CRS 里同时声明
// 显示(MDSS)、视频(Venus)、GPU 时钟(GPU_CC)、GMU、GPU SMMU 的全部 MMIO。
//
// dagu 现有的 graphics.asl / display.asl / venus.asl 走的是另一套“社区分离式”
// HID（QCOM24B4 GPU、QCOM24B9 GMU、QCOM24B5 MDSS、QCOM24B8 Venus ……）。
// 经全仓库 INF 扫描确认：这些分离式 HID 没有任何驱动 INF 绑定，所以用它们时
// 设备会枚举出来但永远停在“无驱动”。要让仓库自带的 qcdx8250 驱动能加载，
// GPU 节点的 _HID 必须是 QCOM253A。
//
// 地址来源：参考板 qcom-mtp8250 的 QCOM253A 节点 _CRS（BBUF 分支）。dagu 与
// MTP8250 同为 SM8250，下列 11 段 MMIO 与 dagu 的 PlatformMemoryMapLib 逐一吻合
// （MDSS 0x0AE00000、Venus 0x0AA00000、GPU_CC 0x02C90000 等）。参考 _CRS 用
// \_SB.SIDV 在 ABUF/BBUF 间二选一；dagu live 的 SIDV=0x00020000，SIDV<0x20000
// 为假，本就返回 BBUF，故此处直接固定为 BBUF，省去无用分支。
//
// 相对参考节点做的裁剪：
//   - 去掉 9923 行面板配置 blob（_ROM/_DOD/_LID/_HRV/AVS0），那是面板点亮逻辑，
//     与“驱动能否绑定”无关，且引用大量 dagu 不存在的对象。
//   - 去掉 _DEP（参考里依赖 MMU0/MMU1/IMM0/PEP0/SCM0/TREE 等 dagu 覆盖表中
//     不存在的节点，保留会导致 _DEP 悬空）。
//
// 状态：已注入 live 覆盖表、iasl 编译通过(rev 5)、SOSI 保持 8 字节 QWord、
// 校验和归零、双分块打包还原一致。板上“驱动是否成功绑定”尚未验证（测试时
// 设备离线）。两套模型互斥：启用本文件时必须停用 graphics.asl 里的 GPU0/GMU0。
//
// 另注：GPU 驱动运行时会打开 \Device\QCOM_PEPDriver（qcpep 提供），因此即使
// 驱动能绑定，完整出图仍可能依赖 PEP；而 PEP 当前卡在 0x101（见 stage2）。
// 本节点先解决“驱动绑定”这一独立问题。
// =============================================================================

Device (GPU0)
{
    Name (_HID, "QCOM253A")  // 高通 MTP 单体 GPU/显示/视频驱动绑定点（qcdx8250.inf）
    Name (_UID, Zero)
    Name (_CLS, Package (0x03) { 0x03, 0x00, 0x00 })  // PCI 类码：显示控制器

    Device (MON0)
    {
        Method (_ADR, 0, NotSerialized)
        {
            Return (Zero)
        }
    }

    Method (_STA, 0, NotSerialized)
    {
        Return (0x0F)
    }

    Method (_CRS, 0, NotSerialized)
    {
        Name (BBUF, ResourceTemplate ()
        {
            Memory32Fixed (ReadWrite, 0x0AE00000, 0x00140000)  // MDSS 显示控制器
            Memory32Fixed (ReadWrite, 0x088E0000, 0x000F4000)  // MDP throttle
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, ,, ) { 0x00000073 }
            Memory32Fixed (ReadWrite, 0x02C00000, 0x0003F010)  // GMU
            Memory32Fixed (ReadWrite, 0x02C60000, 0x0003F000)  // GMU PDC
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, ,, ) { 0x0000014C }
            Memory32Fixed (ReadWrite, 0x0B290000, 0x0000FFFF)  // GPU SMMU
            Memory32Fixed (ReadWrite, 0x0B490000, 0x00010000)
            Memory32Fixed (ReadWrite, 0x02C90000, 0x00009000)  // GPU_CC
            Memory32Fixed (ReadWrite, 0x0C200000, 0x0000FFFF)
            Memory32Fixed (ReadWrite, 0x0AA00000, 0x00200000)  // Venus 视频编解码
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, ,, ) { 0x000000CE }
            Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive, ,, ) { 0x000000CF }
            GpioIo (Exclusive, PullUp, 0x0000, 0x0000, IoRestrictionNone,
                "\\_SB.GIO0", 0x00, ResourceConsumer, , ) { 0x0007 }
            GpioIo (Exclusive, PullUp, 0x0000, 0x0000, IoRestrictionNone,
                "\\_SB.GIO0", 0x00, ResourceConsumer, , ) { 0x0006 }
        })
        Return (BBUF)
    }
}
