# dagu Windows GPU：阶段 18（受控写测推翻“每写必复位”——Adreno SMMU 大部分可从 HLOS 写）（2026-10-31）

阶段 14/17 的结论是“非安全侧一写 Adreno SMMU 就被 QHEE 复位”。本阶段写了一个每次只做**一次**预先
声明的寄存器写的内核驱动 `dagu-smmuwt`，从 Windows（与 qcsmmu 同特权 EL1）逐个试，结果**推翻了这个
结论**：8 个写测全部没有复位，SMMU 的大部分寄存器都能从 HLOS 写进去。

## 1. 方法

`port/dagu/windows-drivers/dagu-smmuwt/dagu-smmuwt.c`：读自己 `Services\daguwt\Parameters` 里的
`test` DWORD，只做一次对应的写，写前把 `step` flush 到注册表（万一复位，离线读 hive 的 `step` 定位
停在哪）。`DriverEntry` 返回错误即卸载。主机侧 `/tmp/dagu/wt.ps1` 设 `test` → `sc start` → 读回结果。
每次运行后 ping 确认 Windows 存活。无覆盖表、qcsmmu 保持 `Start=4`，复位也能自恢复，风险可控。

## 2. 结果（Adreno SMMU @ 0x03DA0000，CX 已上电）

| test | 写什么 | 写入值 | 读回 | 结论 | 复位？ |
|---|---|---|---|---|---|
| 0 | 只读快照 | — | SMR0=0, S2CR0=0x07fea0ff, sCR0=0x00260406 | 与探针一致 | 否 |
| 1 | SMR[0] 假 ID | 0x80000F00 (ID=0xF00) | 0x00000000 | 被丢弃（ID 不是真实流） | 否 |
| 9 | **SMR[0] 真 ID** | **0x80000000 (valid,ID=0)** | **0x80000000** | **写进去了（stuck）！** | 否 |
| 2 | S2CR[0] bypass | 0x00010000 (type=1) | 0x00020000 (type=2) | **规格化回 fault** | 否 |
| 3 | S2CR[0] translate | 0x00000000 (type=0→CB0) | 0x00000000 | **写进去了（stuck）** | 否 |
| 5 | 先 S2CR=translate 再 SMR=valid | — | S2CR 进、SMR 仍 0 | SMR 顺序无关，仍被占 | 否 |
| 4 | sCR0 同值 | 0x00260406 | 0x00260406 | stuck | 否 |
| 6 | sCR0 清 USFCFG | 0x00260006 | 0x00260406 | **被还原**（bit10 保持 1） | 否 |
| 7 | CB0.SCTLR 同值 | 0x32622100 | 0x32622100 | stuck | 否 |
| 8 | CB0.TTBR0 改值 | pre^0x1000 | = 写入值 | **改进去了（stuck）** | 否 |

CB0.TTBR0 读到的原值 `0x4ef3eeca`——QHEE 给这个上下文组装了真实的页表基址，而我能改它。

> 读回陷阱：PowerShell 的 `[uint32]$k.GetValue()` 会把高位置 1 的值（如 `0x80000000`）藏掉不显示，
> 必须用 `reg query` 看。test=9 正是这样才看到 `smr_rb=0x80000000`。

GPU 的真实 StreamID 来自主线 DT `iommus = <&adreno_smmu 0 0x401>` → **SID 0**（GMU 是 SID 5）。
test=1 失败是因为写了假 ID 0xF00；换成真实 SID 0（test=9）SMR 就写进去了。

## 3. 结论：墙不是“每写必复位”，而且 GPU 流能被 HLOS 完整路由

从 Windows EL1 对 Adreno SMMU 的单寄存器写**都不会复位**。QHEE 的保护是“**静默还原非法写**”，不是“复位”：
- **放行**：SMR（真实 SID 的 valid 项）、S2CR 的 translate、CB 的 SCTLR、**CB 的 TTBR0（改值生效）**。
- **挡住（静默还原，不复位）**：SMR 填假 ID、sCR0.USFCFG 清零、S2CR 设 bypass。

**关键结论：GPU 流（SID 0）可以从 HLOS 完整路由**——SMR[0]=valid/ID0 匹配 + S2CR[0]=translate→CB0 +
CB0.TTBR0 可改。这三件都验证了能写进去、都不复位。换句话说 Adreno SMMU 的 GPU 通路是**可配置的**，
阶段 14“一碰就复位”的前提是错的（当时只试了假 ID 的 SMR 和 bypass 的 S2CR，正好都是被还原的那几类）。

## 4. 这推翻了阶段 14/17 的因果，重开垫片/UEFI 预配路

阶段 14 看到的 qcsmmu 运行时“整机复位”，**不是**单条寄存器写被 XPU 拦下——GPU 流的 SMR/S2CR/CB 三类
写都放行了。真正的复位源还没定位，候选在 qcsmmu 的**完整序列**：sCR2 改写、全局 TLB 失效 + sTLBGSYNC
在半配置态轮询挂死、或 enable 后对某条流做翻译走表进了 QHEE 保护内存才复位、或中断风暴。要用
`dagu-smmuwt` 继续补测 sCR2、TLB 失效+同步来定位。

**既然 GPU 流能从 HLOS 完整路由，两条现实可做的路：**
1. **UEFI 预配**：`DaguPlatDxe` 在 ExitBootServices 前就把 SMR[0]/S2CR[0]/CB0 配好（阶段 14 的 UEFI 写测
   只试了被还原的那两类，没试 translate/真 SID/CB-TTBR，需重验 UEFI 侧也放行）。
2. **保守 SMMU 垫片**：自写驱动注册 qcdx 等的接口 `{36079AE4-...}`，只做上面验证过的写，不碰会复位的全局序列。
两条都绕开 qcsmmu 的原版 `SmmuInitHardware` 全量流程。

## 5. 仍要正视后面的墙

即便 SMMU 配通，WDDM 后面还串着 GX 上电（GMU 固件 + RPMh VDD_GFX，dagu 上 RPMh BCM 投票在 Linux
已超时）、zap 微码（PIL/SCM，TZ）。SMMU 这一步的进展是真的，但不等于 GPU 立刻能渲染。

## 6. 设备状态

8 次写测全部存活，每次都还原了寄存器。Windows 正常，`QCDX=4`、`qcsmmu=4`，无覆盖表，boot_a v8。

### 关联文档
[stage14](woa-dagu-gpu-stage14-2026-10-31.md)、[stage16](woa-dagu-gpu-stage16-2026-10-31.md)、
[stage17](woa-dagu-gpu-stage17-2026-10-31.md)、[roadmap](woa-dagu-gpu-roadmap.md)。
