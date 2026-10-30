# dagu Windows GPU 适配：阶段 2（崩溃根因 + GPU 节点）记录（2026-10-30）

阶段 1 把 PEP0 节点加进覆盖表后，`qcpep` 一加载就蓝屏。本阶段用离线转储解析把三个
蓝屏逐一定位到根因，并纠正了阶段 1 的一个错误判断，最后构造出驱动真正能绑定的 GPU 节点。

## 1. 无调试器解析内核 triage minidump

本机 WDK 不含调试器（`cdb.exe`/`kd.exe` 都没有，`aka.ms/windbg` 返回 403），所以写了
`/tmp/dagu/triage.py` 直接按 triage dump 的二进制布局解析：bugcheck 参数、模块表、ARM64
上下文、栈上代码地址。关键偏移（26100 内核）：

- triage 头在文件偏移 `0x2000`，头里 `ctx`/`stack`/`driver`/`pool` 的偏移都是**文件绝对偏移**。
- 驱动表项 144 字节：`+0x00` 名字偏移（绝对）、`+0x38` 加载基址、`+0x48` 映像大小。
- 字符串池项 = `ULONG 字符数` + UTF-16LE。
- ARM64 CONTEXT 在绝对偏移 `0x348`：`Pc=+0x108`、`Sp=+0x100`、`Lr=+0xF8`、`Fp=+0xF0`。

把栈上落在各模块地址区间内的返回地址符号化，三份 `0x1A` 转储的调用栈**逐字节一致**：
`ACPI.sys` → qcpep 多层 → ntoskrnl 内存管理 → `KeBugCheckEx`。

## 2. `0x1A` 根因：SOSI 被压成 1 字节

蓝屏 `0x1A MEMORY_MANAGEMENT`，参数 `(0x1243, 0x5052500880907, 0, 0)`，稳定复现。

沿栈往内反汇编 qcpep：它在 `0x1400f1a08` 这个函数里扫 DSDT 找一个 4 字节签名 `SOSI` 的
对象，从 `SOSI+5` 取 64 位物理地址，然后 `MmMapIoSpaceEx(addr, 0xb0, 2)`（映射 176 字节
SoC info 结构）。返回地址 `qcpep+0xf1b08` 正是这个 `blr` 的下一条。

把生效覆盖表 dump 出来反汇编，`SOSI` 的 AML 是：

```
53 4f 53 49 0c 28 72 90 80 08 50 52 50 31 ...
S  O  S  I  ^DWordConst  ^下一个对象 "PRP1"
```

`0x0c` 是 DWordConst（4 字节）。qcpep 不看 opcode，直接从 `SOSI+5` 读 8 字节，于是把真实
值 `0x80907228` 和后续字节 `08 50 52 50`（下一个对象 "PRP"）拼成 `0x5052500880907228`。

算术完全闭合：

```
qcpep 读到 x0   = 0x5052500880907228
x0 >> 12 (PFN)  = 0x5052500880907   = 蓝屏参数 2   ✓
真实 DWord      = 0x80907228        落在 SMEM 0x80900000..0x80b00000 之内  ✓
```

根因：源码 `dsdt_common.asl` 里 `Name (SOSI, 0xdeadbeefffffffff)` 是对的（8 字节占位，
UEFI 启动时回填真实地址），但 **iasl 会按数值大小选最小编码**——真实值 `0x80907228` 能放进
32 位，就被压成 DWord。qcpep 硬按 8 字节读，于是读穿到下一个对象。

修法：覆盖表里把 `SOSI` 强制成 QWord。先用占位符 `0xDEADBEEFFFFFFFFF` 编译（强制 8 字节），
再二进制回填真实地址 `0x0000000080907228`。

> 仓库侧同样的 bug：提交的构建产物 `DSDT.aml` 里 `SOSI` 是 1 字节 `Zero`（`opcode 0x00`），
> 是过期产物。本阶段用 `tools/compile-dagu-acpi.sh` 从源码重建，`SOSI` 恢复成 8 字节 QWord。

## 3. 修好后变 `0x101`：qcpep 接管 CPU 空闲超时

`SOSI` 修好、启用 PEP0 重启后，蓝屏从 `0x1A` 变成 **`0x101 CLOCK_WATCHDOG_TIMEOUT`**
（参数 `(0x18, 0, PRCB, 核号)`，不同次崩在不同核）。这说明 `SOSI` 修复生效、qcpep 走得更深，
现在卡在 CPU 空闲管理：某个核进入 qcpep 接管的低功耗空闲后没按时响应时钟中断。

关掉 `EnableProcessorManagement=0`、`EnableACPILPIPEP=0`、`DisableSystemLPM=1` 后仍然 `0x101`。
原因在 `Pep_lpi.asl`：dagu 的 CPU `_LPI` 所有状态 `Flags=0`（本就全禁用，注释记录 elish 的
`0xB300` 组合会让 TZ 返回 -2 触发 `0xA0`，所以只留 C1 WFI）。qcpep 一旦接管空闲路径，
就会尝试它自己那套 LPI，和 dagu 这份“只有 WFI 安全”的约束冲突。PEP 的 `0x101` 仍未解决。

## 4. 纠正阶段 1 的错误判断：PoFx 不是 qcpep 提供的

阶段 1 说“`PoFxRegisterComponentPerfStates` 由 qcpep 提供，所以 GPU 硬依赖 PEP”。本阶段核对
导入表发现：这四个 `PoFx*` 函数都是 **ntoskrnl.exe 的导出**，不是 qcpep 的。GPU 驱动
`qcdxkm8250.sys` 的导入模块只有 `ntoskrnl.exe / HAL.dll / ksecdd.sys / WDFLDR.SYS`。

但 GPU 驱动的 `.data` 里确实有字符串 `\Device\QCOM_PEPDriver` 和 `PEPLTVRGFXRestrictionCB`
回调名，说明它运行时会**打开 qcpep 的设备对象**做性能/热限制协调。所以关系是：
驱动绑定、基本枚举**不**需要 qcpep；完整出图和 DVFS 协调**可能**需要。这样就能把两件事拆开：
先独立验证“GPU 驱动能不能绑定”，不必等 PEP 的 `0x101` 解决。

## 5. 决定性发现：dagu 的 GPU HID 没有任何驱动绑定

全仓库 INF 扫描（INF 是 UTF-16LE，需先转码）结果：

| HID | dagu 哪个表在用 | 有驱动绑定吗 |
|---|---|---|
| `QCOM253A` | 无 | **有**：`qcdx8250.inf`、`qcdx_ffu8250.inf`、`qdcmlib8250.inf` |
| `QCOM24B4` (GPU) | `graphics.asl` | 无 |
| `QCOM24B9` (GMU) | `graphics.asl` | 无 |
| `QCOM24B5/B6/B7` (MDSS/DPU/DSI) | `display.asl` | 无 |
| `QCOM24B8` (Venus) | `venus.asl` | 扩展 INF，非 DXKM |

dagu 现有的 `graphics.asl`/`display.asl`/`venus.asl` 走的是“社区分离式”HID，而仓库里实际
存在的 GPU 驱动是高通 MTP 的“单体式”——一个 `QCOM253A` 节点的 `_CRS` 同时声明显示、视频、
GPU 时钟、GMU、SMMU 的全部 MMIO。用分离式 HID，设备能枚举但永远停在“无驱动”。

平板实测枚举：没有任何 `253A`/`24B4`/`24B9` 设备，Display 类为空。生效的 ACPI 表里（覆盖表
rev 4）只有 19 个 Device，GPU 相关一个都没有。

## 6. 构造 QCOM253A 节点

从参考板 `qcom-mtp8250` 的 `QCOM253A` 节点取 `_CRS`。它用 `\_SB.SIDV` 在 ABUF/BBUF 两套
资源间二选一；dagu live `SIDV=0x00020000`，`SIDV < 0x20000` 为假，走 BBUF。把 BBUF 的 11 段
MMIO 与 dagu `PlatformMemoryMapLib` 逐一核对，全部吻合（同为 SM8250）：

| MMIO | 用途 |
|---|---|
| `0x0AE00000` (0x140000) | MDSS 显示控制器 |
| `0x088E0000` (0xF4000) | MDP throttle |
| `0x02C00000` / `0x02C60000` | GMU / GMU PDC |
| `0x0B290000` / `0x0B490000` | GPU SMMU |
| `0x02C90000` (0x9000) | GPU_CC 时钟控制 |
| `0x0AA00000` (0x200000) | Venus 视频编解码 |

中断 `0x73`（显示）、`0x14C`、`0xCE`/`0xCF`；两个 GpioIo 引脚 7/6 引用 `\_SB.GIO0`（覆盖表里有）。

相对参考节点的裁剪：
- 去掉 9923 行面板配置 blob（`_ROM`/`_DOD`/`_LID`/`_HRV`/`AVS0`）——面板点亮逻辑，与“驱动能否
  绑定”无关，且引用大量 dagu 不存在的对象。
- 去掉 `_DEP`——参考依赖 `MMU0/MMU1/IMM0/PEP0/SCM0/TREE` 等 dagu 覆盖表里没有的节点。
- `_CLS` 必须是 3 字节 Package（iasl 不接受参考里的整数写法）。

成品节点存为 `port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics-qcom253a.asl`。

注入 live 覆盖表后：iasl 编译通过、rev 提到 5、`SOSI` 保持 8 字节 QWord、校验和归零、
双分块打包还原一致。**板上“驱动是否绑定”尚未验证**——写回时平板离线。

## 7. 待验证 / 下一步

1. 设备恢复后：写回带 `QCOM253A` 的覆盖表（PEP0 保持禁用），装 `qcdx8250` 驱动，看
   `QCOM253A` 是否枚举、qcdx 能否绑定、`CM_PROB_*` 是多少。脚本已备：`/tmp/dagu/apply-gpu.ps1`、
   `/tmp/dagu/install-gpu-driver.ps1`。
2. 若绑定成功但无法出图 → 回到 PEP 的 `0x101`：需要让 qcpep 的空闲路径和 dagu 的
   “只有 WFI 安全”约束共存（研究 `DisablePCE`、或让 qcpep 完全不接管空闲只做设备电源）。
3. 两套 GPU 模型互斥：启用 `graphics-qcom253a.asl` 时必须停用 `graphics.asl` 的 `GPU0/GMU0`。

## 8. 本阶段改动的文件

- `port/dagu/.../AcpiTables/dagu/graphics-qcom253a.asl`（新增）：驱动能绑定的 GPU 节点。
- `port/dagu/.../AcpiTables/dagu/DSDT.aml`（重建）：修掉 `SOSI` 被压成 1 字节的过期产物。
- `/tmp/dagu/triage.py`：无调试器的内核 triage dump 解析器（放 tmp，不提交）。
