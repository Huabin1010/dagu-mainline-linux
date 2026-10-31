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
| 1 | SMR[0] | 0x80000F00 | 0x00000000 | **被丢弃**（QHEE 占 SMR） | 否 |
| 2 | S2CR[0] bypass | 0x00010000 (type=1) | 0x00020000 (type=2) | **规格化回 fault** | 否 |
| 3 | S2CR[0] translate | 0x00000000 (type=0→CB0) | 0x00000000 | **写进去了（stuck）** | 否 |
| 5 | 先 S2CR=translate 再 SMR=valid | — | S2CR 进、SMR 仍 0 | SMR 顺序无关，仍被占 | 否 |
| 4 | sCR0 同值 | 0x00260406 | 0x00260406 | stuck | 否 |
| 6 | sCR0 清 USFCFG | 0x00260006 | 0x00260406 | **被还原**（bit10 保持 1） | 否 |
| 7 | CB0.SCTLR 同值 | 0x32622100 | 0x32622100 | stuck | 否 |
| 8 | CB0.TTBR0 改值 | pre^0x1000 | = 写入值 | **改进去了（stuck）** | 否 |

CB0.TTBR0 读到的原值 `0x4ef3eeca`——QHEE 给这个上下文组装了真实的页表基址，而我能改它。

## 3. 结论：墙不是“每写必复位”

从 Windows EL1 对 Adreno SMMU 的单寄存器写**都不会复位**。QHEE 的保护是“**静默还原特定寄存器**”，
不是“复位”：
- **占住不让写**：SMR（流匹配，还原成 0）、sCR0.USFCFG（还原成 1）、S2CR 的 bypass 类型（规格化成 fault）。
- **放行可写**：S2CR 的 translate 类型、CB 的 SCTLR、**CB 的 TTBR0（改值生效）**。

也就是说：**HLOS 能给 GPU 流配 translate、能改上下文组的页表基址**，只是不能自己加流匹配项（SMR）、
不能把流设成 bypass、不能关 USFCFG。

## 4. 这推翻了阶段 14/17 的因果，重开垫片路

阶段 14 看到的 qcsmmu 运行时“整机复位”，**不是**单条寄存器写被 XPU 拦下——因为上面每一类写都放行了。
真正的复位源还没定位，候选：qcsmmu 的**完整序列**里某一步（全局 TLB 失效 + sTLBGSYNC 轮询半配置态
挂死、或 enable 后对半配置的流做翻译、或中断风暴），而不是“碰一下 GR0 就死”。需要用 `dagu-smmuwt`
继续把 sCR2、TLB 失效+同步、以及“改 CB 翻译配置后触发一次走表”这些**序列**补测，才能定位。

更重要的是：既然 S2CR-translate 和 CB-TTBR 都能从 HLOS 写进去，**自写一个保守 SMMU 垫片**（模仿主线
`arm-smmu-qcom`：不重写全局、不碰 SMR、只把 GPU 流 S2CR 设 translate 并把 CB 指向我们建的页表）就有了
现实依据，不再是纯猜测。悬而未决点：GPU 流靠什么匹配到 S2CR 项（SMR 写不进；可能这颗 SMMU 走
StreamID 直接索引 S2CR，待确认），以及改 CB 页表后 QHEE 是否在实际走表时才复位。

## 5. 仍要正视后面的墙

即便 SMMU 配通，WDDM 后面还串着 GX 上电（GMU 固件 + RPMh VDD_GFX，dagu 上 RPMh BCM 投票在 Linux
已超时）、zap 微码（PIL/SCM，TZ）。SMMU 这一步的进展是真的，但不等于 GPU 立刻能渲染。

## 6. 设备状态

8 次写测全部存活，每次都还原了寄存器。Windows 正常，`QCDX=4`、`qcsmmu=4`，无覆盖表，boot_a v8。

### 关联文档
[stage14](woa-dagu-gpu-stage14-2026-10-31.md)、[stage16](woa-dagu-gpu-stage16-2026-10-31.md)、
[stage17](woa-dagu-gpu-stage17-2026-10-31.md)、[roadmap](woa-dagu-gpu-roadmap.md)。
