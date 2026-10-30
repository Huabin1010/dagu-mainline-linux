# dagu Windows GPU 适配：阶段 8（补齐 QCOM253A 的引擎与页表描述）（2026-10-30）

阶段 4 在真机上把带 `QCOM253A` 节点的覆盖表写进去、装上 `qcdx8250` 驱动后，Windows 停在启动
阶段，`ntbtlog.txt` 最后一条是 `qcdxkm8250.sys`，没有 minidump。阶段 4 当时列了四个候选原因
（缺 PEP、GPU 未上电、缺 SMMU、`_DEP` 被裁），都没有验证。

本阶段对内核镜像 `qcdxkm8250.sys` 做静态逆向，查清了驱动初始化里一条必过的门控，并据此从
参考板移植了 dagu 节点缺失的 ACPI 数据。全程只改源码、只做离线 iasl 编译，没有对平板写任何
东西。平板保持阶段 4 之后的状态：A 槽 Windows 在线（192.168.1.250），`QCDX` 为
Stopped/Disabled，PEP0 禁用。

分析对象 `winarm/drivers/QC8250/Drivers/Graphics/DXKM/qcdxkm8250.sys`，sha256
`ff4846e4533708e4efd3a18971eefcd2ea438b10d31f266d569c65d9eae70ed5`。这是 INF
`qcdx8250.inf` 里 `QCDX_Service` 段的服务镜像（非 RS3、非 TI 变体）。

## 1. 启动门控：必须找到 GmuInternal 和 GpuInternal

初始化函数 `FUN_1402b4be0`（`0x1402b4be0`）在入口处遍历一张命名内存区表：条目数在
`param_1[0x1d3]`，从 `param_1[0x1d4]` 起每 5 个 qword 一项，第 0 个 qword 是区名字符串、
第 4 个（`+0x1d8`）是要保存的句柄。循环用 `FUN_140131980`（按长度比较）逐项比对三个字面量：

| 区名 | 命中后写入 | 对应标志 |
|---|---|---|
| `GmuInternal` | `param_1[0x2ad]` | `bVar7` |
| `GmuCached` | `param_1[0x2ab]`、`param_1[0x2ac]` | `bVar6` |
| `GpuInternal` | `param_1[0x355]` | `bVar5` |

遍历结束后是三道检查，任一不满足就调 `FUN_140010920` 打日志并跳 `LAB_1402b54c8`
（`FUN_1402b6808(param_1,1)` 后 `return 0`，即不继续初始化）：

- `param_1[0x2ad] == 0`（没找到 `GmuInternal`）→ 日志码 `0xe5f`。
- GPU 型号是 `0x650001` 或 `0x65a001` 且 `param_1[0x2ab] == 0`（没找到 `GmuCached`）→ `0xe68`。
  这一条按型号有条件，不是所有芯片都要求。
- `param_1[0x355] == 0`（没找到 `GpuInternal`）→ 日志码 `0xe71`。

`GmuInternal` 和 `GpuInternal` 对所有型号都是硬要求。dagu 的 Adreno 650 型号码落在上表，
`GmuCached` 一并要求。

## 2. 区名来自 ACPI 的页表条目

命名内存区表由 `FUN_14029b168`（`0x14029b168`）填。它读 ACPI 引擎包里的
`PAGETABLEUSAGE` 项，把 ASL 里的页表名翻译成上面比对的内部区名：

- `GraphicsGlobalPT` → `GpuInternal`
- `GraphicsGmuPT` → `GmuInternal` / `GmuCached`
- `GraphicsPerProcessPT`、`GraphicsSecurePT` 也在同一张表里，门控没有强制检查它们。

上游是 `FUN_14025f0b0`（`0x14025f0b0`），它查 `"ENGINES"` 包并逐个引擎解析。驱动里与之配套
的字符串还有 `"RESOURCE"`、`"MMUINFO"`、`"PAGETABLES"`、`"PAGETABLEUSAGE"`、`"GFX_REGS"`、
`"GPU_CC"` 等，与参考板 DSDT 的 `RESI` / `ENGS` 内容逐一对应。

证据链：

```
ACPI GPU0.ENGS（ENGINES 包）
  -> FUN_14025f0b0  解析 ENGINES
  -> FUN_14029b168  读 PAGETABLEUSAGE，翻译成命名区
       GraphicsGlobalPT -> GpuInternal
       GraphicsGmuPT    -> GmuInternal / GmuCached
  -> FUN_1402b4be0  遍历命名区，缺 GmuInternal(0xe5f) 或 GpuInternal(0xe71) 即失败返回
```

dagu 的 `graphics-qcom253a.asl` 此前只有 `_HID`/`_UID`/`_CLS`/`MON0`/`_STA`/`_CRS`，没有
`ENGS`。驱动因此拿到零个引擎、零张页表，命名区表为空，`param_1[0x2ad]` 与 `param_1[0x355]`
必为 0，门控必然失败返回。这是阶段 4 现象里能确定的一环。

需要说明的边界：门控失败走的是「打日志 + 返回」，是一次干净的失败返回，不等于阶段 4 观察到的
「无 dump 硬卡死」。补上 `ENGS` 让驱动能越过这道门，但越过之后是否还会在别处卡住（电源、时钟、
SMMU 接口），本阶段无法从静态分析断定，只能等板上验证。

## 3. 对前七阶段方向的一个修正：PEP 不是致命依赖

前几阶段一直把 qcpep 的稳定性当成 GPU 的前置条件。本阶段查到：GPU 驱动运行时确实会打开
`\Device\QCOM_PEPDriver`，但这条不是致命依赖。`FUN_1402b9f20`（`0x1402b9f20`）打开失败时
只把 `param_1+0x1080` 处的标志或上 `0x1800000000` 然后返回 void，调用方（门控函数末尾）不检查
它的返回值。所以 PEP 的 `0x101` 不会从这条路径阻塞 GPU 驱动初始化。

这并不否定阶段 2/5 观察到的 PEP 挂死，只是说明「GPU 驱动初始化卡住」和「PEP 没起来」不是同一
条依赖，应分开排查。

## 4. SMMU 接口的性质

驱动里有一批 `VedInitSMMUInterface*` 的 `FATAL` 日志字符串，取接口失败时打 `FATAL` 并让引擎
启动失败。这些字符串在 Venus 视频引擎（`Ved*`）的启动路径上，两处引用点
（`0x140304d24`、`0x14030daec`）分别属于 `FUN_1403041a0` 和 `FUN_14030d1a0`，静态分析没有
解析出它们的调用者，无法从这里断定对整体初始化的影响面。

能确定的是：`ENGS` 表里每个引擎的 `MMUINFO` 都声明 `"ArmSmmuV2"`，参考板 `GPU0._DEP` 也列了
`MMU0`/`MMU1`。dagu 此前把 `smmu.asl` 整个注释掉，SMMU 侧没有被驱动认领的设备，GPU 侧这条
依赖是悬空的。本阶段把 SMMU 设备按参考板 HID 启用，让这条依赖有对象，是必要的一步，但它是否
足以让 Venus 引擎过关，留到板上验证。

## 5. 本阶段的源码改动

### 5.1 graphics-qcom253a.asl：移植 RESI / ENGS / TMDT

从参考板 `winarm/mu_aloha_platforms/Platforms/KonaPkg/Device/qcom-mtp8250/ACPI/DSDT.dsl` 的
`GPU0` 节点移植三个方法：

- **RESI**：给 `_CRS` 的资源按顺序命名（`MDP_REGS` / `GFX_REGS` / `GPU_CC` / `VIDEO_REGS` 等
  15 项）。参考板有 `AINF`/`BINF` 两份按 `\_SB.SIDV` 二选一，反编译确认两份内容除包名外逐字节
  相同；dagu live `SIDV=0x00020000` 固定走 `BINF`，所以只保留一份并命名 `RBUF`，去掉 `SIDV`
  分支，节点不再引用任何外部对象。
- **ENGS**：引擎与页表表。五个引擎（GRAPHICS/MDPBLT/ROTATOR/VIDEO/CRYPTO）、七个 DISPLAY、
  `RESOURCES`、13 项 `PAGETABLES`，以及门控依赖的 `PAGETABLEUSAGE` 四项
  （`GraphicsGlobalPT` / `GraphicsPerProcessPT` / `GraphicsSecurePT` / `GraphicsGmuPT`）。
  原样照搬，不改名——门控比对的是字面名字，改名即失配。每个引擎的 `MMUINFO` 保留 `"ArmSmmuV2"`。
- **TMDT**：热域表，把 GRAPHICS/MDPBLT/ROTATOR 归到 GPU 域。

`PMCL`（参考板约一万行的电源时钟表，引用 `\_SB.SIDT`/`SIDV`/`SOID`）本阶段不移植，先验证能否
越过门控。节点仍不恢复 `_DEP`，避免悬空引用。

反编译核对：`ENGS`、`TMDT` 与参考板规范化后逐行一致；`RESI` 的 `RBUF` 与参考板 `BINF`
字符串序列完全相同。

### 5.2 smmu.asl + dsdt_common.asl：启用 SMMU 设备

- `smmu.asl` 的 `MMU0`/`MMU1` 从社区式 HID `QCOM24C2`/`QCOM24C3` 改为参考板的 `QCOM2509`，靠
  `_UID` 0/1 区分。这与仓库里 `qcsmmu8250.inf` 绑定的 `ACPI\VEN_QCOM&DEV_2509&REV_0001/0002`
  一致；原来的 `QCOM24C2/24C3` 没有任何 INF 认领。`_HRV` 用 `Alias(\_SB.SVMJ, _HRV)`，由
  `AcpiPlatformUpdateLib` 在启动时填成芯片大版本，对上 INF 的 `REV_000x`。地址/长度保留 dagu
  自己 `PlatformMemoryMapLib.c` 的值（`0x15000000`/`0x000D0000`、`0x03DA0000`/`0x00010000`），
  并补上参考板的中断号。
- `dsdt_common.asl` 取消 `Include("smmu.asl")` 的注释。

启用 SMMU 设备不改 UFS0 的 DMA 路径：dagu 不出 IORT，`UFS0` 仍是直通 DMA（和能启动 Windows 的
SM8250 手机 alioth/lmi/elish 一致）。之前注释 SMMU 的理由是「带 MTP IORT 时 UFS0 被映射到
SMMU 后面、启动盘枚举不出来（0x7B/0xC0000034）」，这个风险来自 IORT，本阶段没有引入 IORT。
`_DEP` 本阶段不恢复（参考板 `MMU0._DEP` 指 `MMU1`、`MMU1._DEP` 指 `PEP0`，而 dagu 的 PEP0
当前禁用）。

## 6. 离线编译验证

- 主表 `Dsdt.asl`（现含 `smmu.asl`）：`iasl -ve` 通过，0 Errors 8 Warnings，与启用 SMMU 之前
  的基线警告数一致（8 个均为既有的 `_REG`/空资源模板/`_HID`+`_ADR` 提示）。AML 从 10786 字节
  增加到 11116 字节，增量对应两个 `QCOM2509` 节点。
- `graphics-qcom253a.asl`（单独用 `Scope(\_SB)` 包裹编译）：0 Errors 0 Warnings。
- 占位符宽度核对（直接在生成的 AML 里按 AML 前缀字节检查）：`SOSI` 仍是 8 字节 QWord，
  `SOSN` 8 字节、`SOID`/`SIDV`/`PLST`/`SIDT`/`STOR` 4 字节 DWord、`SVMJ` 2 字节 Word、
  `SIDS`/`SFES` 15 字符字符串，全部未被破坏。

## 7. 下一步（都要在平板能进 fastboot、dagu-rescue.sh 可用的前提下再做）

1. 把本阶段的 `graphics-qcom253a.asl` + SMMU 节点打成 live 覆盖表写回（PEP0 保持禁用），
   `QCDX` 改 `Start=3`，看是否越过 `0xe5f`/`0xe71` 门控、驱动能否完成初始化。
2. 若越过门控后仍卡在 Venus 的 SMMU 接口，再回到第 4 节，查 `FUN_1403041a0`/`FUN_14030d1a0`
   的调用者和失败传播面。
3. 若需要电源/时钟，再评估移植 `PMCL`。

## 8. 本阶段改动的文件

- `port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics-qcom253a.asl`：新增 `RESI`/`ENGS`/`TMDT`。
- `port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/smmu.asl`：`MMU0`/`MMU1` 改 `QCOM2509` + `_UID` + `_HRV` 别名 + 中断。
- `port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/dsdt_common.asl`：取消 `Include("smmu.asl")` 注释。
- `docs/woa-dagu-gpu-stage8-2026-10-30.md`：本文件。
