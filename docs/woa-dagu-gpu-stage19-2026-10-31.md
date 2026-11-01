# dagu Windows GPU：阶段 19（证伪时钟假设：qcsmmu 关掉自管时钟仍复位；复位在"活配置"序列里）（2026-10-31）

阶段 18 发现 Adreno SMMU 的 GPU 流能从 HLOS 完整路由、单寄存器写无一复位；阶段 16 也排除了时钟/电源。
但 `qcsmmu8250.inf` 的 Adreno 实例写着 `SCLCK Enabled=1`（"clock should be controlled by SMMU
driver"），dagu 没 PEP，怀疑 qcsmmu 自己去 gate SMMU 时钟再访问 → 总线挂 → 复位。本阶段直接测了。

## 1. 做法

- 覆盖表 = 固件 DSDT + GPU0(含 REGR) + **只含 MMU1**（`/tmp/dagu/mmu1-only.asl`，不放 MMU0——APPS SMMU
  会断 UFS 启动，阶段 10）。`build-gpu-overlay.py ... --smmu mmu1-only.asl --allow-boot-hang`，39450 字节，自检全过。
- 注册表改 `qcsmmu\Parameters\1\SCLCK\Enabled=0`（不让 qcsmmu 自管时钟）+ `qcsmmu\Parameters\PowerManaged=0`
  （关 PoFx，阻止它 gate 时钟）。`QCDX`/`qcsmmu` 开机都保持 `Start=4`。
- `asl /loadtable` 应用覆盖表 → 重启。开机正常，`ACPI\QCOM2509\1` 枚举为 `CM_PROB_DISABLED_SERVICE`，
  REGR 在、SCLCK=0 确认。
- 计划任务 SYSTEM 身份运行 `rt-start.ps1 -Svc qcsmmu -Id ACPI\QCOM2509\1` 运行时拉起。

## 2. 结果

拉起后约 **15–20 秒整机掉线**、无蓝屏、无 dump；`rt-qcsmmu.log` 空（复位太早，日志没刷到盘，与阶段 14
一致）。约 1 分钟后落 B 槽 Linux（192.168.1.51）。`rm-dsdt` + `to-win` 恢复，Windows 正常。

**关 SCLCK/PowerManaged 后 qcsmmu 仍复位 → 时钟/PoFx 假设被证伪。**

## 3. 结论：复位不在"单写"也不在"时钟"，在 qcsmmu 的"活配置"序列

把阶段 16/18/19 合起来看：

| 已排除 | 证据 |
|---|---|
| 时钟/电源没上电 | 阶段16：Windows 下 SMMU 时钟全开、正常应答 |
| 单寄存器写被 XPU 拦 | 阶段18：SMR(真SID)/S2CR-translate/CB-TTBR/CBAR/sCR0/sCR2/TLB 同步，没有一条单写复位 |
| qcsmmu 自管时钟 gate | 本阶段：SCLCK=0 + PowerManaged=0 仍复位 |

剩下的复位源只能在 qcsmmu init 的**完整活配置序列**里，最可能是两者之一：
1. 它把 SMR+S2CR+CB 配成一套**生效的**翻译，之后 SMMU 真正对某条 GPU/GMU（SID 0/5）事务**走表**，
   QHEE 在走表时才判违规复位——这和"单写能过、活配置才死"完全吻合（单写我都还原了，从没形成生效配置）。
2. 它连了 SMMU 的 context-fault 中断（DT GIC SPI 672–685）后立刻来一发 fault。

这两者都**不是注册表旋钮能关掉的**，也无法用孤立写复现——需要一套生效配置 + 一笔真实事务才触发，
而那笔事务又要 GPU/GMU 实际在跑（GX 上电 + GMU 固件）。

## 4. GPU WDDM 的诚实判断

到此，GPU 这条链的每一个可以从非安全侧动的地方都试过了：
- qcdx 崩溃（阶段15）——已修。
- GPU CX 上电、时钟（阶段13/16）——已通。
- Adreno SMMU 的 GPU 流从 HLOS 可配（阶段18）——已证明。
- 但 qcsmmu 一旦把 SMMU 配成生效态就复位（本阶段），而这几乎肯定是 QHEE 在**真实走表**时的保护动作；
  要越过它需要 GX 上电（GMU 固件 + RPMh VDD_GFX 轨，dagu 上 RPMh BCM 投票在 Linux 已超时）和 zap 微码
  （PIL/SCM，TZ）——全是 stock 安全世界说了算，非安全侧改不动。

**结论：在 stock HyperOS 固件下，WDDM GPU 加速走不通，卡点是 QHEE/TZ 对 GPU SMMU 走表与 GX/RPMh/zap
的独占。** 这不是再写几行驱动能解决的，需要替换/重配安全世界（超出本仓库范围）。GPU 侧已交付的实在
收益仍是阶段 13 的大核调频（A77 ~3 倍，已验证），显示走 BasicDisplay。

## 5. 设备状态

恢复干净：Windows 正常，`QCDX=4`、`qcsmmu=4`，无覆盖表，SCLCK 已还原为 1，计划任务已删，boot_a v8。

### 关联文档
[stage16](woa-dagu-gpu-stage16-2026-10-31.md)、[stage17](woa-dagu-gpu-stage17-2026-10-31.md)、
[stage18](woa-dagu-gpu-stage18-2026-10-31.md)、[roadmap](woa-dagu-gpu-roadmap.md)。
