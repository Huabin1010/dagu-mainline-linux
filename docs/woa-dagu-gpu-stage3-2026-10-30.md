# dagu Windows GPU 适配：阶段 3（qcpep 开关逆向 + PEP0 HID 纠错）记录（2026-10-30）

阶段 2 把 PEP 的 `0x101 CLOCK_WATCHDOG_TIMEOUT` 归到“qcpep 接管 CPU 空闲路径”，
并试过三个注册表开关去关掉接管，但仍然 `0x101`。本阶段把 `qcpep8250.sys` 的注册表开关
机制整个逆向清楚，得到三个推翻前阶段假设的结论，并定位了一个真正的 bug：PEP0 节点的
`_HID` 和驱动绑定的 ID 根本不一致。

设备本阶段全程离线（Windows / Linux / fastboot / adb 四条路径都不在），所有结论为静态
逆向 + INF 交叉核对，板上验证留待设备恢复。

## 1. qcpep 的注册表开关是一张整表，不是逐个代码引用

`qcpep8250.sys`（ARM64 PE，2726 个过程）把所有注册表开关放在一张参数表里，表指针存于
`0x140187a20`，每条 24 字节：

```
+0x00  u32  index（特性枚举号，1..0x73）
+0x08  u64  宽字符名指针（UTF-16LE，如 L"DisableIdleCallbacks"）
+0x10  u32  默认值（无注册表项时用它）
+0x14  u8   “已从注册表加载”标志（运行时回填）
+0x15  u8   “已查询”标志
```

所以直接对开关名字符串查 xref 全是空——它们只被这张表引用一次。读取器
`FUN_1400dd5a8(index, *out, ...)` 按 index 定位条目，缺注册表项就返回默认值；真正查注册表的是
`FUN_1400dd3f8`，走 `ZwQueryValueKey(DAT_1401c91b8, name, REG_DWORD)`。

父键句柄 `DAT_1401c91b8` 由 `FUN_1400dd2c8` 打开：以 DriverEntry 存下的驱动注册表路径
`DAT_1401c9188` 为父，打开子键 `L"\\Parameters"`。即
`HKLM\SYSTEM\CurrentControlSet\Services\qcpep\Parameters`——和阶段 2 `pep-nocpu.ps1`
写的路径一致。**写入路径是对的**。

## 2. 115 个开关的二进制默认值全表

把整表解出来（115 条）。与 `0x101` 相关的关键默认值：

| index | 开关 | 二进制默认 |
|---|---|---|
| 0x09 | `EnableProcessorManagement` | 0 |
| 0x0a | `EnableAcpiLpiPEP` | 0 |
| 0x12 | `DisableSystemLPM` | 1 |
| 0x1a | `DisableCCI` | 1 |
| 0x1b | `DisableIdleCallbacks` | 1 |
| 0x29 | `DisablePCE` | 1 |

## 3. 推翻阶段 2 假设之一：那三个开关的二进制默认值本就是“目标值”

阶段 2 为关掉空闲接管设了 `EnableProcessorManagement=0`、`EnableAcpiLpiPEP=0`、
`DisableSystemLPM=1`。对照上表，这三个值**和二进制默认完全相同**。单看二进制，这三次写入
都是 no-op。

## 4. 推翻假设之二：真正生效的是 INF，而 INF 把这些开关反向打开了

INF `qcpep.wd8250.inf` 的 `[PEP_SoftwareDeviceSettings]` 段（被 `[pep_Service_Inst]`
引用，即写进**服务键** `Services\qcpep\Parameters`）用 AddReg 覆盖了二进制默认：

| 开关 | 二进制默认 | INF 写入 | 实际效果 |
|---|---|---|---|
| `EnableProcessorManagement` | 0 | **1** | qcpep 接管处理器性能管理 |
| `EnableACPILPIPEP` | 0 | **1** | qcpep 启用 ACPI LPI |
| `DisableSystemLPM` | 0(INF) | **0** | 系统 LPM 不禁用 |
| `DisableCCI` | 1 | **0** | CCI 不禁用 |
| `DisablePCE` | 1 | **0** | PCE 不禁用 |

也就是说出厂安装后，设备键里这些开关是“全部打开接管”。这解释了 `0x101` 的来源：
INF 把默认关闭的空闲/处理器接管路径全部打开。

## 5. 推翻假设之三：`EnableProcessorManagement` / `EnableAcpiLpiPEP` 运行时根本没被读

决定性验证：把开关读取器 `FUN_1400dd970`（`FUN_1400dd5a8` 的直通包装）的全部 33 个调用者
逐个反编译，扫描它们读取的 index。结果——

- 被读到的 index 覆盖 `0x0..0x73` 的绝大多数（`0,2,3,4,5,8,0xb..0x73` 等）。
- **index 0x09（`EnableProcessorManagement`）和 0x0a（`EnableAcpiLpiPEP`）从未被任何调用者读取。**
  （唯一的间接 index 在 `FUN_140025330`，来自 per-device 结构体 `+0x1c` 字段，不是这两个。）

结论：这两个开关在这版 `qcpep8250.sys`(DriverVer 2024/10/30, 1.0.2140) 里是**死开关**，
设什么值都不影响运行时。阶段 2 试图用它们关掉接管，从机制上就不可能生效——既因为值等于默认，
更因为代码压根不读它们。

## 6. 真正的杠杆：`DisableIdleCallbacks`(0x1b)

`DisableIdleCallbacks` 才是 gate 空闲回调注册的那一个，证据链闭合：

1. `FUN_14007f9f8` 读 index 0x1b，写入全局 `DAT_1401c95dc`。
2. `FUN_1400e30e8` 里：
   ```c
   DAT_1401cc2c8 = MmMapIoSpaceEx(0x90b0000, 0x800, ...);  // 映射 APSS/APCS 区
   if (DAT_1401c95dc == 0) {          // 仅当 DisableIdleCallbacks==0
       FUN_1400e2e70();               // 初始化空闲子系统
       KeInitializeSpinLock(...);
       FUN_1400dd970(0x5e, ...);      // 读 LmhNodeOffset 等，注册空闲路径
       FUN_1400dd970(0x5f, ...);
   }
   ```
   `DAT_1401c95dc != 0`（即 `DisableIdleCallbacks=1`）时，整段空闲回调注册被跳过。

二进制默认 `DisableIdleCallbacks=1`（本就不注册），但 INF 没有写这个键，所以**设备上它保持
默认 1**——那空闲回调本不该注册。这和 `0x101` 仍然发生矛盾，说明 `0x101` 的时钟看门狗
超时**不在 `DisableIdleCallbacks` gate 的这段路径上**，而是来自 `EnableProcessorManagement=1`
+ `EnableACPILPIPEP=1`（INF 打开）后，qcpep 作为 LPI PEP 参与 Windows 处理器电源框架、
接管了 `_LPI` 的进入/退出协调。这条路径由 PoFx/PPM 侧驱动，不读上面那两个死开关。

## 7. 本阶段定位的真正 bug：PEP0 的 `_HID` 和驱动绑定 ID 不一致

交叉核对发现源码 `pep0.asl` 与 qcpep INF 对不上：

| 来源 | GPU/PEP 绑定 ID |
|---|---|
| `qcpep.wd8250.inf` / `qcpep.wp8250.inf` 的 `[QC...]` 段 | `ACPI\QCOM2519`（PEP 主设备）+ 一大批 `QCOM253B..` 温度传感器 |
| dagu 源码 `pep0.asl` | `_HID "QCOM2430"`、`_CID "ACPI\QCOM2430"` |
| 阶段 1/2 的 live 覆盖表 | `PEP0` 用 `QCOM2519`（阶段 1 文档记为 `_HID QCOM2519 / _CID PNP0D80`） |

源码里的 `QCOM2430` 不在 qcpep INF 的任何绑定项里，装上 qcpep 也不会绑定到它。阶段 1/2 的
覆盖表用的是正确的 `QCOM2519`，但那是直接改 live 注册表里的 DSDT 分块，**没回写源码**。
因此当前源码树 `pep0.asl` 构建出的固件，PEP0 节点驱动绑不上。

> 结论性影响：之前“启用 PEP0 就蓝屏”的实验用的是覆盖表里的 `QCOM2519`（能绑定、能加载、
> 然后才崩）。源码 `pep0.asl` 的 `QCOM2430` 是另一套 ID，需要先纠正才能让源码构建的固件
> 与实验一致。

## 8. 对下一步的具体建议（设备恢复后按序验证）

1. **GPU 绑定（与 PEP 解耦，先做）**：写回带 `QCOM253A` 的覆盖表，PEP0 保持禁用。
   阶段 2 已证明 GPU 驱动绑定不依赖 qcpep（PoFx 四函数都是 ntoskrnl 导出），所以这步可独立。

2. **PEP `0x101` 的正确实验**：不要再碰 `EnableProcessorManagement`/`EnableAcpiLpiPEP`
   （死开关）。真正该试的是在**服务键**写 INF 没写、但代码会读的开关：
   - `DisableSystemLPM=1`（idx 0x12，`FUN_140016a50` 实际读取）——关系统级 LPM。
   - 让 qcpep 以“默认 1”的 `DisableIdleCallbacks` 跑（INF 未写，已默认跳过那段，可不动）。
   - 若仍 `0x101`，说明超时来自 LPI PEP 协调本身，需要在 ACPI 侧让 `SYSM/CLUS` 的
     `_LPI` 不把空闲委托给 PEP（即不声明依赖 PEP 的 DRIPS 父状态），回到 dagu
     “只有 C1 WFI 安全”的约束。

3. **`pep0.asl` 的 `_HID` 要和 `0x101` 的解法一起改，不能提前**：
   当前源码的 `QCOM2430` 绑不上 qcpep，等于“PEP0 节点存在但驱动不加载”——这正是
   目前的**安全态**（不触发 `0x101`）。一旦改成能绑定的 `QCOM2519`，源码构建的固件
   就会真的加载 qcpep，在第 2 步的 `0x101` 解决之前会直接蓝屏、无法进系统。所以：
   先用第 2 步在 live 覆盖表里验证出一套能让 qcpep 不超时的 ACPI `_LPI` + 开关组合，
   再把 `QCOM2519` 和那套配置同时写回源码。单独翻 HID 会 brick 启动。

## 9. 本阶段改动的文件

- `docs/woa-dagu-gpu-stage3-2026-10-30.md`（本文件）：qcpep 开关机制逆向 + 三条纠错 + PEP0 HID bug。
- 逆向证据（qcpep8250.sys，sha256 `39fafcd6…24e01`）：参数表 `0x140187a20`、读取链
  `FUN_1400dd5a8/3f8/2c8`、空闲 gate `FUN_14007f9f8 → DAT_1401c95dc → FUN_1400e30e8`、
  死开关结论（33 个调用者无一读 idx 0x09/0x0a）。
