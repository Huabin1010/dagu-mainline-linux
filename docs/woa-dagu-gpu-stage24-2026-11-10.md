# dagu Windows GPU：阶段 24（从 Windows 按 Linux 的方式编程 Adreno SMMU 的 CB0：写测）（2026-11-10）

阶段 23 拿到了 Linux 给 GPU 上下文（CB0）配的值，并列出了阶段 18 没测过的四个寄存器。本阶段把这四个和 Linux 还会写的另外四个合成一次写测（`dagu-smmuwt` 的 `test=100`），先逐个单写、逐个还原，再按 Linux 的顺序整体配一遍、置 `SCTLR.M=1`，但**不路由任何流**。

---

## 1. 为什么先测这个，再改垫片

垫片要返回真实地址，前提是 Windows 能把 CB0 配成 Linux 那样：`TTBR1` 指向自己建的页表，`TCR` 打开 TTBR1 那一半。阶段 18 只证明了 `SMR`、`S2CR`、`TTBR0`、`SCTLR`（同值）能写，`CBAR` 改值会被静默还原。`CBAR` 被还原这一条特别要紧：Linux 每次 attach 都写 `CBAR`，如果 Windows 写的 `CBAR` 一定被还原，CB0 的类型就只能是 QHEE（Qualcomm Hypervisor Execution Environment，高通虚拟机管理程序执行环境）留下的那个，要先知道它是什么。

阶段 19 的复位发生在“配成生效翻译之后真正走表”的时刻，不是寄存器写本身。本测试只建空页表（512 个无效项），不写 `SMR`/`S2CR`，所以没有任何事务会走这张表。

## 2. 测什么

Linux 7.0 `arm-smmu.c::arm_smmu_write_context_bank()` 加上 `arm-smmu-qcom.c` 对 Adreno 的补充，在 CB0 上依次写：

| 顺序 | 寄存器 | Linux 的值 | 来源 |
|---|---|---|---|
| 1 | `CB0.ACTLR` | `0x303` | `qcom,adreno` 的 `PREFETCH_DEEP | CPRE | CMTLB` |
| 2 | `CBA2R[0]` | `0x1` | `VA64`，VMID 0 |
| 3 | `CBAR[0]` | `0x1F300` | 类型 1（S1 翻译、S2 旁路），`BPSHCFG=NSH`，`MEMATTR=WB` |
| 4 | `CB0.TCR2` | `0x00038011` | `PASIZE=1`（36 位）、`SEP=7`、`AS` |
| 5 | `CB0.TCR` | `0xB5100080` | 阶段 23 实抓 |
| 6 | `CB0.TTBR0` / `TTBR1` | `0` / 页表物理地址 | ASID 0 |
| 7 | `CB0.MAIR0` / `MAIR1` | `0xF404FF44` / `0` | 阶段 23 实抓 |
| 8 | `CB0.SCTLR` | `0x1167` | `CFIE|CFRE|AFE|TRE|M|ASIDPNE` + `HUPCF` |

`test=100` 的流程：

1. 先确认 GPU CX 和 SMMU 的三条时钟都在（阶段 12、16 的教训：没电时读 SMMU 会卡总线），否则什么都不碰（`step=0x01A2`）。
2. 只读快照 `s30_*`：ID 寄存器、`sCR0`、6 组 `SMR`/`S2CR`、5 个 CB 的 `CBAR`/`CBA2R`/`SCTLR`/`FSR`、CB0 的全部配置。
3. 子测试 31–38：每个寄存器单独写一次 Linux 的值（`SCTLR` 用不带 `M` 的 `0x1166`），立刻读回、50 毫秒后再读一次，再写回原值。
4. 子测试 40：所有子测试都还原成功，且没有任何有效 `SMR` 已经翻译到 CB0 时，按上表顺序整体写，`SCTLR.M=1`，做一次 `TLBIASID` + `TLBSYNC`，读回、100 毫秒后读 `FSR`/`sGFSR`，然后先关 `M`、再同步、再逐项写回。
5. 只读快照 `s99_*`，释放页表页。

每次写之前都把 `step=(子测试号 << 8) | 阶段` 刷进注册表。如果整机复位，从 B 槽 Linux 读离线配置单元里的 `step` 就知道停在哪一笔写上。

## 3. 怎么跑

文件已经放在 Windows 分区：`C:\dagu-gpu\3-smmuwt.cmd`、`smmuwt.ps1`、`smmuwt\dagu-smmuwt.sys`（SHA256 前缀 `6be51b21`）。

- 平板上：右键 `3-smmuwt.cmd` → 以管理员身份运行。屏幕上会打出每个寄存器的结果，写进 `C:\dagu-gpu\smmuwt-run.txt`，15 秒后自动重启进 fastboot。
- 主机上：切 B 槽 Linux，`python3 smmuwt-verdict.py <SYSTEM 配置单元>` 读结果并给判定（`stuck` / `reverted` / `RESET during this write`）。解析逻辑有单元测试 `tools/winarm/gpu-bringup/test_smmuwt_verdict.py`。

驱动服务 `daguwt` 是按需启动，`DriverEntry` 永远返回失败、跑完即卸载，所以复位之后下一次开机不会自己再跑。

## 4. 怎么读结果、决定下一步

| 结果 | 含义 | 下一步 |
|---|---|---|
| 31–38 全部 `stuck`，40 的 `SCTLR.M` 留住、`FSR=0` | CB0 能从 Windows 完全按 Linux 配置 | 垫片实现 TTBR1 页表 + IOVA 分配，槽 20 返回真实 IOVA |
| `CBAR` `reverted`，其余 `stuck` | CB0 类型由 QHEE 固定 | 看 `s30_cbar0` 是什么类型；如果已经是 S1 翻译，照用即可 |
| `TTBR1` 或 `TCR` `reverted` | QHEE 不让 HLOS 打开 TTBR1 半区 | 改用 TTBR0（阶段 18 已证明可改），IOVA 落在低半区，同时改 `ENGS` 的 VA 布局 |
| 某一步复位 | 那一笔写被 QHEE 拦下 | 从 `step` 定位，去掉那一项再测 |

## 5. 第一次上板结果（2026-11-10 17:50，Windows 存活，无复位）

原始值存在 `logs/smmuwt-stage24-run1.txt`。GPU CX 电源域已上电（`cx_gdscr=0xf8222000`），三条时钟都在跑。

| 寄存器 | 原值 | 写入 | 读回 | 结论 |
|---|---|---|---|---|
| `CB0.TTBR1` | `0xcff7017bdb62eb11` | `0x1fff7f000` | 同写入 | 写进去了，可还原 |
| `CB0.TCR` | `0x0d8c5634` | `0xb5100080` | 同写入 | 写进去了，可还原 |
| `CB0.TCR2` | `0x8065` | `0x38011` | `0x38071` | 写进去了；bit 5、6（TBI0/TBI1，忽略地址最高字节）读出来固定是 1，原值里也是 1 |
| `CB0.MAIR0` | `0x7cb026a3` | `0xf404ff44` | 同写入 | 写进去了，可还原 |
| `CB0.SCTLR` | `0x32620100` | `0x1166` | `0x0166` | 写进去了；bit 12（ASIDPNE）读出来固定是 0 |
| `CB0.ACTLR` | `0x3` | `0x303` | 同写入 | 写进去了，可还原 |
| `CBA2R[0]` | `0` | `0x1` | 同写入 | 写进去了，可还原 |
| `CBAR[0]` | `0` | `0x1F300` | 同写入 | **写进去了，但改不回 0**，停在 `0x1F300` |

三点新认识：

1. **CB0 不是 QHEE 预先配好的**。`TTBR0`/`TTBR1`/`MAIR1` 这类值（`0x4fff772d4efbeecb`、`0x5f575647`）没有任何意义，`SCTLR.M=0`、`CBAR=0`，是上电后没人初始化过的随机内容。阶段 18 把 `TTBR0=0x4ef3eeca` 读成“QHEE 组装好的页表基址”，是读错了。CB0 完全归 HLOS 自己配。
2. **Linux 配 CB0 要写的每一个寄存器，Windows 都写得进**，没有一笔复位，也没有触发全局故障（`sGFSR=0`）。阶段 18 里 `CBAR` 被还原，是因为那次改的是 VMID 字段（低 8 位），不是类型。
3. `CBAR` 能从类型 0（只有第二阶段翻译，归虚拟机管理程序管）改成类型 1（第一阶段翻译、第二阶段旁路），却改不回去。说明 QHEE 不许 HLOS 把上下文组配成第二阶段类型，这和“第二阶段归虚拟机管理程序”一致。对我们没有影响：Linux 要的就是类型 1，而这时 `SCTLR.M=0`，CB0 没有启用。

整体配置（子测试 40）这次被跳过了：它要求所有单写都能还原，`CBAR` 改不回 0 被判成“还原失败”。驱动已改成 `CBAR` 停在 Linux 值也算还原成功（SHA256 前缀 `b315277f`），脚本结果改写到 `smmuwt-run.txt`，因为旧的 `smmuwt-result.txt` 在 Windows 缓存里没刷盘，在 NTFS 上成了坏条目。

## 6. 第二次上板结果（2026-11-10 17:52，整体配置，Windows 存活，无复位）

原始值存在 `logs/smmuwt-stage24-run2.txt`。8 个单写结果和第一次一致，`single_fails=0`，子测试 40 跑完。

按 Linux 顺序整体写完、`SCTLR.M=1` 之后读回：

| 寄存器 | 读回 | 说明 |
|---|---|---|
| `ACTLR` | `0x303` | 与 Linux 一致 |
| `CBA2R[0]` | `0x1` | `VA64` |
| `CBAR[0]` | `0x1F300` | S1 翻译、S2 旁路 |
| `TCR2` | `0x38071` | 写 `0x38011`，TBI0/TBI1 固定为 1 |
| `TCR` | `0xB5100080` | 与 Linux 一致 |
| `TTBR0` / `TTBR1` | `0` / `0x1ff86f000`（我们分配的页表页） | 与写入一致 |
| `MAIR0` / `MAIR1` | `0xF404FF44` / `0` | 与 Linux 一致 |
| `SCTLR` | `0x167`，100 毫秒后仍是 `0x167` | **翻译开关 `M` 留住了**；`HUPCF`、`CFIE`、`CFRE`、`AFE`、`TRE` 都在，`ASIDPNE` 固定为 0 |
| `FSR` | `0x400` | 只有 `FORMAT=AArch64` 两位，没有任何故障位 |
| `TLBIASID` + `TLBSYNC` | 立即完成 | 开启和关闭时各一次 |
| 全局故障 `sGFSR` | 前后快照都是 0 | 子测试 40 里那一项记成 `0xffffe08a00000000`：低 32 位（寄存器本身是 32 位）是 0，高 32 位来路还没查清，以前后两次快照为准 |

关掉 `M`、逐项写回后，10 个字段全部回到原值（`restored=1`），`s99` 快照和 `s30` 一致。

**结论：在原厂安全固件下，Windows 能把 Adreno SMMU 的 CB0 配成和 Linux 完全一样的生效状态。** 阶段 23 的缺口清单里，第 3 项（`TCR`、`MAIR0`、`SCTLR`、`CBAR`）和第 4 项（IOTLB 失效）已经验证可行。剩下的是垫片本身的工作：

1. 垫片里建真实 AArch64 4 KB 页表，按 qcdx 的布局（每进程区在 bit 39 以下、全局区从 bit 39 起）决定用 TTBR0 还是 TTBR1、`TCR2.SEP` 取什么值。
2. 槽 24 / 槽 20 返回页表里真实映射过的 IOVA，不再返回假对象或 `0x9C000000`。
3. 再把 SID 0 路由到 CB0（阶段 18 已验证可写）。到这一步，阶段 19 说的“真实走表”才会发生，要在调试通道可用时做。

## 7. 附带发现：qcdx 的 GPU 全局地址空间正好是 TTBR1 拆分的形状

`graphics-qcom253a.asl` 的 `ENGS` → `PAGETABLES`：

| 页表 | 基址 | 大小 |
|---|---|---|
| `GraphicsGlobalPT` | `0x80_0000_0000` | `0x8_0000_0000`（32 GB） |
| `GraphicsPerProcessPT` | `0x40_0000` | `0x7F_FFC0_0000` |
| `GraphicsSecurePT` | `0x80_0000_0000` | `0xA_0000_0000` |

全局区从 bit 39 开始，每进程区在 bit 39 以下。按 SMMU v2 规范，`TCR2.SEP`（Sign Extension Position，符号扩展位）编码 `0b010` 就是 bit 39。这是高通 Windows 驱动的“每进程走 TTBR0、全局走 TTBR1”的布局，和 Linux 的拆分页表是同一个机制，只是拆分位不同（Linux 用 `SEP=7`、48 位）。垫片做真实映射时，`TCR2.SEP` 应按 qcdx 的布局取值，而不是照抄 Linux 的 `SEP=7`。这一点要等写测结果出来、确认 `TCR2` 放行后再定。

---

### 关联文档

[阶段 23（Linux 的 CB0 配置）](woa-dagu-gpu-stage23-2026-11-10.md)、[阶段 18（写测方法）](woa-dagu-gpu-stage18-2026-10-31.md)、[阶段 19（走表复位）](woa-dagu-gpu-stage19-2026-10-31.md)、[阶段 22（槽 24 / 20）](woa-dagu-gpu-stage22-2026-11-08.md)、[适配计划](woa-dagu-gpu-adaptation-plan-2026-11-10.md)。
