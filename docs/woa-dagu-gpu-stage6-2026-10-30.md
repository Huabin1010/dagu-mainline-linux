# dagu Windows GPU 适配：阶段 6（逆向 qcpep8250.sys 的参数表与空闲门控）（2026-10-30）

阶段 5 的结论是三组 qcpep 注册表配置都没能消除 `0x101 CLOCK_WATCHDOG_TIMEOUT`，下一步定为逆向
`qcpep8250.sys`，查明它读哪些开关、在哪里读、读完做什么。本阶段是纯静态分析，没有对平板做任何写入。

分析对象：`winarm/drivers/QC8250/Drivers/SOC/PowerManagement/qcpep8250.sys`，
sha256 `39fafcd60536c7d36dd95187dc9f51bfc4af661b614bce4a5e9ec0729fe24e01`，arm64 PE，
imagebase `0x140000000`，2726 个过程。工具是 REA MCP + Ghidra 12.1.4。

## 1. 先纠正上一轮的两个错误

上一轮（见 `docs/woa-dagu-gpu-stage5-2026-10-30.md` 之后的逆向记录）有两处方法错误，导致结论不可靠，本阶段已修正。

### 1.1 参数表基址偏了一个字段，feature 编号整体错位

我上轮把参数表基址当成 `0x140187a48`，实际是 `0x140187a40`（`.data`，文件偏移 `0x185840`）。
判据来自驱动自己的断言：访问器 `FUN_1400dd5a8` 要求 `gRegLookupCache[i].Type == feature`
（`PEP_Utilities.c:443`），初始化函数 `FUN_1400dc718` 还会遍历全表校验
`gRegLookupCache[i].Type == (RegistryStoredFeatures)i`（`PEP_Utilities.c:243`）。实测：

| 基址 | `Type == 下标` 成立的条目 |
|---|---|
| `0x140187a40` | 116 / 116 |
| `0x140187a48` | 0 / 116 |

表大小从 `gRegLookupCacheSize`（`0x1401879f4`）读出是 116，与遍历上界 `0x73`（115）一致。

条目是 24 字节，布局为 `Type(+0x00)`、名称指针 `(+0x08)`、当前值 `(+0x10)`、
已读标志 `(+0x14)`、已访问标志 `(+0x15)`。实测条目 17 的原始字节是
`11000000 00000000 | 709e1740 01000000 | 01000000 00000000`，`Type=17` 与下标一致。
基址错一个字段后，每个 feature 编号都会对应到相邻的名字，所以上轮给出的
「18 = DisableSystemLPM、26 = DisableCCI、27 = DisableIdleCallbacks」全部作废。正确对应是：

| feature | 名称 | 内置默认值 |
|---|---|---|
| 17 | `DisableSystemLPM` | 1 |
| 18 | `DisableVddMin` | 0 |
| 20 | `DisableCpuVdd` | 1 |
| 21 | `DisableCpuRet` | 1 |
| 25 | `DisableCCI` | 1 |
| 26 | `DisableIdleCallbacks` | 1 |
| 27 | `DisableBWMonBusDCVS` | 1 |
| 40 | `DisablePCE` | 1 |
| 8 | `EnableProcessorManagement` | 0 |
| 9 | `EnableAcpiLpiPEP` | 0 |
| 10 | `EnableOxiliBlock` | 0 |

一个直接后果：`FUN_140016a50` 里对 `/pmic/client/rail_cx` 投 `0x80` 的那个判断读的是
`FUN_1400dd970(0x12, …)`，即 **feature 18 = `DisableVddMin`**，不是上轮说的 `DisableSystemLPM`。
该值在设备注册表中不存在，取内置默认 0，所以走的是 `FUN_140103610`（释放客户端）分支，
并没有常驻投票。上轮「`rail_cx` 长期投 0x80」的说法不成立。

### 1.2 只扫了 `.text`，漏掉两个代码段

PE 有 10 个节，可执行的有三个：`.text`（`0x140001000`）、`PAGE`（`0x1401db000`）、
`INIT`（`0x140236000`）。上轮用单一 VA→文件偏移差值扫描，只覆盖 `.text`，所以漏读了
`PAGE`/`INIT` 里的调用点。按节分别映射后，调用 `FUN_1400dd970` / `FUN_1400dd5a8` 的分支点
从 51 个增加到 84 个。

被漏掉的里面有一个要紧的：`EnableProcessorManagement`（f8）在 `0x140215618`（`PAGE`）
确实被读。上轮说它「无任何代码读取点、是死开关」是错的。
`EnableAcpiLpiPEP`（f9）仍然没有找到任何读取点，这一条维持原判。

## 2. 关键发现：空闲开关不走函数调用，走一张静态门控表

84 个调用点里找不到 `DisableSystemLPM`(f17)、`DisableCCI`(f25)、`DisableCpuVdd`(f20)、
`DisableCpuRet`(f21)。共有 38 个 feature 没有直接调用点。原因是这些开关由一张
**LPR（low power resource）模式门控表**间接消费，feature 编号存在数据里，不在指令立即数里。

表在 `.data`，`0x28` 字节步长，有两份内容相同的副本：

- 表 A：`0x1401bd550`（文件偏移 `0x1bb350`），6 项
- 表 B：`0x1401bd640`（文件偏移 `0x1bb440`），6 项

条目布局（偏移由 `FUN_140025330` 的取值指令确认）：资源名指针 `+0x00`、资源名长度 `+0x08`、
模式名指针 `+0x10`、模式名长度 `+0x18`、**feature 编号 `+0x1c`**、**掩码 `+0x20`**、标志字节 `+0x24`。

内容（两表一致）：

| 资源 | LPR 模式 | feature | 内置默认 | 掩码 |
|---|---|---|---|---|
| `K*`（Kryo\*） | `C2` | 21 `DisableCpuRet` | 1 | `0xff` |
| `K*` | `C3` | 20 `DisableCpuVdd` | 1 | `0xff` |
| `K*` | `C4` | 20 `DisableCpuVdd` | 1 | `0xff00` |
| `L3Cluster` | `D2` | 25 `DisableCCI` | 1 | `0x1` |
| `L3Cluster` | `D4` | 25 `DisableCCI` | 1 | `0x2` |
| `plat*` | `DRIPS` | 17 `DisableSystemLPM` | 1 | `0x1` |

资源名通配列表另在 `0x1401bd470`：`Kryo*`、`*`。

**装表的地方**是 `FUN_1400017d0`（断言出自 `Idle_MicroPep_8180.c:185`）：先把
`Kryo*` 列表挂到 `context+0x810`，再读芯片版本（`FUN_1400f1908`），版本等于 `0x10000`
就挂表 B，否则挂表 A，项数都写 6，存到 `context+0x820` / `context+0x828`。
两张表内容相同，所以芯片版本分支在这里不产生差异。

**用表的地方**是 `FUN_140025330`：三层循环遍历（CPU 簇 × 该簇的模式 × 6 个门控项），
用 `FUN_14001d6f8` 做资源名和模式名的通配匹配；命中后从 `+0x1c` 取 feature 编号调
`FUN_1400dd970(feature, &v, 1, 0)` 读注册表值，把结果与 `+0x20` 的掩码相与，
再按 `+0x24` 的标志字节和模式索引做位测试，最后调用 `FUN_1400235e0`
（断言出自 `Idle_MicroPep.c:1159` 和 `:1209`）去设置该 LPR 模式的状态。
`0x140025930` 之后还有一段对 `feature == 0x14`（20 `DisableCpuVdd`）的特判。

由此可知这三个开关不是全局总闸：它们只在「某个资源的某个具名空闲模式」被枚举并匹配到时才起作用，
作用对象限于 `C2`/`C3`/`C4`/`D2`/`D4`/`DRIPS` 这 6 个条目。表里没有任何条目覆盖
CPU 核自己的 `C1`（WFI），也没有条目覆盖 `_LPI` 之外的路径。

这是对阶段 2/5 实验结果的一个可能解释，但还不足以断定因果：要确认「改了开关却没效果」
是因为模式没被匹配到，必须先查清第 3 节说的簇/模式数据来源。

## 3. 一条当时待验证的推论

阶段 7 已经把 `context+0x618` 的来源查完，当前结论以
`docs/woa-dagu-gpu-stage7-2026-10-30.md` 为准。下面保留阶段 6 写下时的判断。

阶段 5 实验 C 把覆盖表里 `SYSM`、`CLUS` 的 `_LPI` 清空，同时又启用 PEP0，结果是挂死、无 dump。
结合第 2 节，有一个合理推论：门控表要靠模式名匹配才能生效，`_LPI` 清空后可供匹配的模式条目消失，
那三个注册表开关就没有作用对象。也就是说实验 C 同时移除了症状的抑制手段和抑制目标，
它的失败不能用来排除 `qcpep` 空闲路径。

必须说明这条还没有验证：`FUN_140025330` 遍历的簇和模式来自 `context+0x618`，是 PEP 自己的
空闲注册结构，我还没有确认它是直接由 ACPI `_LPI` 填充的。在确认这条数据来源之前，
不要把它当作已知事实。

## 4. 其他确认的细节

- **访问器只有一条路径**。`FUN_1400dd5a8` 的唯一调用者是 thunk `FUN_1400dd970`；
  读值由 `FUN_1400dd3f8`（`ZwQueryValueKey`，REG_DWORD）完成，键是服务键下的 `\Parameters`
  （`FUN_1400dd2c8` 打开）。**读不到就保留内置默认值**，这一点与上轮一致。
- **6 项覆盖数组**在 `0x140187a28`（文件偏移 `0x185828`），当 `DAT_1401c91a8 != 0` 时优先生效，
  内容是 feature `{0, 10, 72, 89, 90, 91}` =
  `SystemDefaultState`、`EnableOxiliBlock`、`EnableLTVR`、`DDRFrequencyFloorMHz`、
  `DDRFrequencyCeilMHz`、`DDRFrequencyFixedMHz`。
- **GPU 相关的两个名字**：`EnableOxiliBlock`（f10，Oxili 是 Adreno 的旧代号，默认 0）和
  `EnableGraph`（f76，默认 0）。两个都没有找到读取点，f10 虽然在覆盖数组里，
  但覆盖数组只在该 feature 被请求时才查，没有请求方就不会生效。暂时不作为可用杠杆。
- **`FUN_1400608f8`** 是运行时改写缓存的入口（直接按下标写 `+0x10` 并置 `+0x14`），
  只接受 feature 43、45、46、47（`EnableTsensOffset` 一族），属于温度校准，与空闲无关。
- **INF 与设备实测值的差异**仍然存在：`qcpep.wd8250.inf` 把 `DisableSystemLPM`、`DisableCCI`、
  `DisablePCE` 写成 0，设备上现在是 1（阶段 2/5 手工改的）。`DisableCpuRet` 设备是 `0xff`，
  掩码 `0xff` 相与后非零；`DisableCpuVdd` 设备是 0。`DisableIdleCallbacks` 在设备注册表里不存在，
  取内置默认 1。

## 5. 下一步

1. 确认 `context+0x618` 的簇/模式数据来源，判定第 3 节的推论。这是目前唯一能把
   `_LPI` 声明和 `0x101` 连起来的线索。
2. 阶段 5 已经提出但仍未执行的低风险实验：在 UEFI 里先打开 GPU_CC 的 GDSC 和时钟，
   再让 `QCDX Start=3`、PEP0 保持禁用启动一次，用来区分「缺 PEP」和「GPU 没上电」。
   这条不依赖本阶段的逆向结果，建议先做。
3. `smmu.asl` 在 `dsdt_common.asl` 中仍被注释，对 `qcdxkm8250` 初始化的影响未验证。

## 6. 复现方法

参数表和门控表都可以离线复算，不需要设备：

```bash
F=winarm/drivers/QC8250/Drivers/SOC/PowerManagement/qcpep8250.sys
# 参数表：0x140187a40 -> 文件偏移 0x185840，116 项 x 24 字节
# 门控表：0x1401bd550 -> 文件偏移 0x1bb350，6 项 x 0x28 字节
#   feature 在 +0x1c，掩码在 +0x20
```

注意两点：节的 VA→文件偏移必须逐节映射（`.text` / `PAGE` / `INIT` 都含代码），
名称字符串是 UTF-16LE。

设备当前状态没有改变：A 槽 Windows 在线（`192.168.1.250`），`QCDX Start=4`，
PEP0（`ACPI\QCOM2519`）`ConfigFlags=1` 禁用，live DSDT 覆盖表仍是阶段 5 实验 C 的版本。
