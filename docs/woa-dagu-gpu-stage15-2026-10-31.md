# dagu Windows GPU：阶段 15（qcdx 空指针根因 = 缺 REGR；补上后撞上 SMMU 接口依赖）（2026-10-31）

阶段 11 起 `qcdxkm8250.sys` 一绑定就 `BugCheck 0x3B`，崩溃点恒定在 `+0x262904`，换地址、加
`PMCL`、开关 GPU CX 都不变。本阶段把它逆向到根因，补上 GPU0 缺的 `REGR` 方法，实测**崩溃消失**，
驱动往前走到了 SMMU 初始化，然后卡在“等 qcsmmu 的设备接口”这一步。

工具：`tools/winarm/qdis.py`（capstone，RVA 寻址，imagebase `0x140000000`；本阶段打开了
`skipdata`，否则 capstone 遇到代码里的数据字就停，会漏掉调用点）、`tools/winarm/dagu-dump-triage.py`
（本阶段加了非 0x3B 蓝屏的处理和全模块栈扫描）。

> 更正：本文件第一版（`cbd7d38`）说“方法名是 `DCVS`”、“`0x262c70` 没有静态调用者”，两条都错。
> 后者是 capstone 没开 `skipdata` 漏扫；前者是猜测。正确结论见下文。

## 1. 0x3B 崩溃现场

转储 `MEMORY-qcdx2.DMP`：出错指令 `+0x262904`：`ldrh w8,[x19]`，**X19=0xc**。
`x19` 是 `ACPI_EVAL_OUTPUT_BUFFER` 的 `Argument[0]`（缓冲区 + 0xc），所以缓冲区指针本身是 0。

## 2. 调用链

| 层 | RVA | 作用 |
|---|---|---|
| 读整数配置 | `0x270340..` | 用格式串 **`"\REGR\%s"`**（`0x3428f8`）拼出路径，调 `0x262e08` |
| `0x262e08` | | 校验对象签名 `0x55AA55AA`，调解析器，再按键名查值 |
| 解析器 `0x262c70` | | 按 `\` 切出第一段（`0x2629f0`），即方法名 `REGR`；和缓存名比较后求值 |
| 填充 `0x262ac0` | | 求值 `REGR`，成功才把输出缓冲写进 `devctx+0x38`（`field_38`） |
| 求值 `0x25e000` | | 拼 `ACPI_EVAL_INPUT_BUFFER_COMPLEX`，调 `[iface+0x10]`（`DXGKRNL_INTERFACE.DxgkCbEvalAcpiMethod`，`DeviceUid=-1` 即适配器自己的 ACPI 节点 GPU0） |

## 3. 根因：缓存名先写、缓冲后填，失败后留下“名字有效但缓冲为空”

`0x262c70` 里：

1. `0x262cc0`：`RtlCompareMemory(段名, devctx+0x10, 4)`（IAT `0x14a318`）。
2. `0x262cdc`：`cmp x0,#4; b.eq 0x262d20`：4 字节相等就**直接复用缓存的 `field_38`，不判空**。
3. 不相等：释放旧缓冲 → `0x262d10` **先把新名字写进 `devctx+0x10`** → 再调 `0x262ac0` 求值。

`0x262ac0` 只在求值返回 `STATUS_SUCCESS` 或 `STATUS_BUFFER_OVERFLOW`（`0x80000005`）时分配并写
`field_38`；其它错误（例如 GPU0 下根本没有 `REGR`）直接返回，`field_38` 保持 NULL。于是：

| 次序 | 发生的事 | 缓存名 | `field_38` | 结果 |
|---|---|---|---|---|
| 第 1 次读 `\REGR\xxx` | 求值 `REGR` 失败（对象不存在） | `REGR` | NULL | 返回错误，驱动当作“键不存在”继续 |
| 第 2 次读 `\REGR\yyy` | 名字相等 → 复用分支 | `REGR` | NULL | `0 + 0xc` → `ldrh [0xc]` → **0x3B** |

## 4. 修复：GPU0 补上 REGR（已验证）

参考板 SM8250 MTP DSDT 的 `\_SB.GPU0.REGR`（`KonaPkg/Device/qcom-mtp8250/ACPI/DSDT.dsl` 与
`SurfaceDuoACPI/QcomACPI/8250/src/DSDT_8250_MTP.dsl` 两份逐字相同）原样移植进
`port/dagu/.../graphics-qcom253a.asl`（TMDT 之后）。它是驱动的“注册表配置包”：`ForceMaxPerf`、
`GPU64bAddrEnabled`、`ZeroPageLowAddr` 等，外加 `GRAPHICS\DCVS`、`GRAPHICS\A6x`、`VIDEO`、
`CRYPTO`、`DISPLAY` 子包。唯一的硬地址 `ZeroPageLowAddr 0x85F40000` 落在 dagu 实际 UEFI 内存图
（`KonaPkg/Device/xiaomi-dagu` 的 `RAM Partition 0x85E00000+0x200000`，Reserv）里。

覆盖表：`build-gpu-overlay.py --base backups/fw-dsdt/dagu-fw-dsdt-rev3-20261031.aml`，39269 字节，
自检全过（SOSI 未动，无 QCOM2509）。`asl /loadtable` → 重启 → 活动 DSDT 确认含 `REGR`。

运行时拉起 `QCDX`（`rt-start.ps1 -Svc QCDX -Id ACPI\QCOM253A\0`，18:39:02）：

```
driver state=Running after 0s
dev=OK prob=CM_PROB_NONE ... drv=Running   (持续到 18:39:11 脚本结束)
```

**`+0x262904` 的 0x3B 不再出现**，这是 qcdx 第一次在 dagu 上进入 `Running`/`CM_PROB_NONE`。

## 5. 下一道墙：qcdx 硬依赖 qcsmmu 的设备接口

约 2 分 50 秒后（18:41:5x）整机蓝屏重启：`BugCheck 0xA`（IRQL_NOT_LESS_OR_EQUAL），读地址 0，
IRQL 2，PC=`ntoskrnl+0x25a428`。用转储里 qcdx 自己的错误日志环（`qcdx+0x1c6b80` 处的 ERR/WRN/INF
三个环，每条 0x28 字节：时间戳、序号、返回地址、5 个参数、事件码）还原了过程：

1. `0x2aa240`（引用 `"InitSMMUDisplay"`，按引擎循环 8 次）→ `0x265298` → `0x2654e0`：
   为引擎的 `MMUINFO`（ENGS 里声明的 `ArmSmmuV2`）建立 SMMU 接口。
2. `0x284e38`：`IoRegisterPlugPlayNotification(EventCategoryDeviceInterfaceChange, INCLUDE_EXISTING,
   GUID)`，然后 `KeWaitForSingleObject` 等 30 秒（`0x7530` ms）。等的接口 GUID 从转储里 `qDXA` 池块读出：
   **`{36079AE4-78E8-452D-AF50-0CFF78B2F1CA}`**，正是 `qcsmmu8250.inf` 给 SMMU 实例写的 `Parameters\0\Guid`。
3. 日志：`0x1e7`（等待超时）+ `0x1ae`（`STATUS_UNSUCCESSFUL`）**连续 4 轮**，随后一串 `c000000d`
   （`0x2dc4`/`0x3039`/`0x086d`/`0x0998`/`0x3450`/`0x34e9`…）是启动失败后的回退路径。
4. 回退路径 `0x2934b0 → 0x29cdd8 → 0x2c1370 → 0x2c3008 → 0x2c7728`：对 `ctx+0x1050+0x48` 调
   `KeWaitForSingleObject`。这个 KMUTEX 只在 `0x2c0230`（后面的初始化阶段）里 `KeInitializeMutex`，
   这条路上还没跑到，对象全 0，内核遍历等待链表时读到空的 Blink → `0xA`。这是 qcdx 的第二个
   错误路径 bug，但触发它的前提是 SMMU 接口缺失。

Windows 侧确认：`DeviceClasses\{36079AE4-…}` 不存在（`qcsmmu Start=4`，没人注册这个接口）；另一个
在等的 `{48192C45-…}` 是 `qcsyscache` 的接口，属于带回调的非阻塞等待，不是这次的阻塞点。

## 6. 结论

- **第一道墙（qcdx 空指针）拆掉了**：根因是缺 `REGR`，补上后已验证。
- **第二道墙就是 SMMU**：qcdx 不只是“想要” SMMU，它在启动时**阻塞等待 qcsmmu 的设备接口**，等不到
  就失败（并在回退路径蓝屏）。而 `qcsmmu` 一编程 Adreno SMMU 就被复位整颗 SoC（阶段 14）。ENGS 的
  `MMUINFO` 只认 `ArmSmmuV2`/`ArmSmmuV500` + `Miniport`/`Engine`，二进制里没有“无 MMU”模式的字符串。
  所以绕不开 qcsmmu，必须让它在 dagu 上不复位。
- 线索（**未验证**）：主线 Linux 在同一套 QHEE 固件上能驱动 Adreno SMMU。`arm-smmu-qcom` 针对“写 S2CR
  BYPASS 会被固件改成 FAULT”的平台有专门处理（保留一个关掉翻译的 context bank 来模拟旁路），
  这和 v8 UEFI 探针看到的现象（S2CR bypass 被规格化成 fault）一致。另一个可能是 Windows 下 qcsmmu
  访问 Adreno SMMU 时时钟/电源不在（INF `SCLCK Enabled=1` 要靠 PoFx/PEP 投票，dagu 没有 PEP）。
  两条都需要再做实验区分。

## 7. 设备状态

蓝屏后 Windows 自己重启进系统（18:41:56），`QCDX=4`、`qcsmmu=4`。已删除 `rtqcdx` 计划任务和
`DSDT\QCOMM_\SM8250_\00000004` 覆盖表键（下次启动生效，当前这次启动仍在用带 REGR 的表，不影响使用）。
boot_a 仍是 v8 UEFI。

## 8. 速查坐标

| 项 | RVA / 值 | 说明 |
|---|---|---|
| 0x3B 崩溃指令 | `0x262904` | `ldrh w8,[x19]`，x19=0xc |
| 配置路径格式串 | `0x3428f8` | `"\REGR\%s"` |
| 解析器 / 复用判定 | `0x262c70` / `0x262cdc` | `RtlCompareMemory`(IAT `0x14a318`)==4 即复用 |
| 填充 / 求值 | `0x262ac0` / `0x25e000` | `DxgkCbEvalAcpiMethod` |
| SMMU 接口等待 | `0x2654e0` → `0x284e38` | 30 s × 4 轮 |
| 等待的接口 | `{36079AE4-78E8-452D-AF50-0CFF78B2F1CA}` | qcsmmu `Parameters\0\Guid` |
| 0xA 蓝屏 | `ntoskrnl+0x25a428` | 回退路径等未初始化的 KMUTEX（`ctx+0x1098`） |
| qcdx 日志环 | `qcdx+0x1c6b80`（缓冲指针）/ `+0x1c6b7c`（计数） | ERR 256 条、WRN 48 条、INF 16 条 |

### 关联文档
[stage11（崩溃定位）](woa-dagu-gpu-stage11-2026-10-31.md)、
[stage13（CX 上电+大核调频）](woa-dagu-gpu-stage13-2026-10-31.md)、
[stage14（SMMU/QHEE 复位墙）](woa-dagu-gpu-stage14-2026-10-31.md)、
[roadmap](woa-dagu-gpu-roadmap.md)。
