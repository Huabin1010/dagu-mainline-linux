# dagu Windows GPU 适配：阶段 7（簇/模式数据来自 PPM LPI 通知）（2026-10-30）

阶段 6 第 3 节留下的问题是：门控表遍历的簇和模式（`context+0x618`）是不是由 ACPI `_LPI` 填进去的。
本阶段把这条调用链查完。仍然是纯静态分析，没有对平板做任何写入。

分析对象与阶段 6 相同：`qcpep8250.sys`，sha256
`39fafcd60536c7d36dd95187dc9f51bfc4af661b614bce4a5e9ec0729fe24e01`。
通知编号对照 WDK 10.0.16299 的 `pepfx.h`，插件结构对照 10.0.14393 的 `pep_x.h`。

## 1. 填充函数挂在 PPM 通知 0x23 上

`context+0x618` 的写入者是 `FUN_1400e0e88`（`Idle_AcpiLpiPep.c:207`），它只被
`FUN_14007fee0`（`PEP_Proc.c:393`）调用。后者把 Windows 传进来的状态数组交给
`FUN_1400e0f68`（`Idle_AcpiLpiPep.c:241`），按每项 `0x50` 字节拷进簇条目。

`FUN_14007fee0` 没有直接调用者。它出现在 `.data` 派发表 `0x140187250` 的第 `0x23` 槽。
表共 `0x2c` 项，每项 16 字节：`+0` 是通知编号，`+8` 是处理函数。派发函数是
`FUN_14007fab0`：编号小于 `0x2c` 且槽非空时调用 `handler(Data, Handle)`。

这张表的编号与 `pepfx.h` 的 `PEP_NOTIFY_PPM_*` 一一对应。和本阶段有关的几项是：

| 编号 | 宏 | 处理函数 |
|---|---|---|
| `0x22` | `PEP_NOTIFY_PPM_LPI_SUPPORTED` | `FUN_14007feb0` |
| `0x23` | `PEP_NOTIFY_PPM_LPI_PROCESSOR_STATES` | `FUN_14007fee0` |
| `0x24` | `PEP_NOTIFY_PPM_LPI_COORDINATED_STATES` | `FUN_1400801d0` |

`0x23` 的数据是 `PEP_PPM_LPI_PROCESSOR_STATES`。`Count` 在 `+0`，状态数组从 `+8` 开始，
单项 `PEP_PPM_PROCESSOR_LPI_STATE` 长 `0x50`，`StateName` 在单项的 `+0x48`
（第 0 项的名字落在整包的 `+0x50`）。`FUN_1400e0f68` 读的偏移与这个布局一致：
`+0x10` 的 bit0 是 `Flags.Enabled`，`+0x50` 起是名字指针。

## 2. 名字必须是「资源.模式」

两个拷贝函数都按 UTF-16 的 `.`（`0x2e`）切分：

- `FUN_1400e08e8` 拷贝 `.` 之前的一段，写入簇名。`FUN_1400e0f68` 只对第 0 项的
  `StateName` 调它一次，所以一个处理器通知里的所有模式都挂在第 0 项名字的前缀下面。
- `FUN_1400e0b60` 要求字符串里有 `.`，拷贝 `.` 之后的一段作为模式名。没有 `.` 就
  `KeBugCheckEx(0x14e, 0x71706530, 0x38, 0)`。

阶段 6 的门控表按资源名 `K*` / `L3Cluster` / `plat*` 和模式名
`C2` / `C3` / `C4` / `D2` / `D4` / `DRIPS` 做通配。能命中的前提是 Windows 送来的
`StateName` 形如 `Kryo.C2`、`L3Cluster.D2`、`platform.DRIPS` 这种「资源.模式」。

## 3. 整条 PPM 回调由 EnableProcessorManagement 决定是否注册

注册点在 `FUN_140214c18`（`PAGE`，`0x140215618` 附近）。它调用
`PoFxRegisterPluginEx`（导入槽 `0x14016a260`），传入的 `PEP_INFORMATION` 是版本 2、大小 `0x20`：

- `+0x08` `AcceptDeviceNotification` = `FUN_14006c310`
- `+0x10` `AcceptProcessorNotification` = `FUN_14007fab0`，仅当 feature 8
  `EnableProcessorManagement` 读出来非 0；否则这里写 NULL
- `+0x18` 保持 0

版本 2 的结构只有设备回调和处理器回调两个指针（`pep_x.h`），第三槽是多出来的 8 字节，保持为空。
`EnableAcpiLpiPEP`（feature 9）在全镜像里仍然没有读取点。LPI 这条路径的开关是 feature 8，不是 feature 9。

`0x22` 的处理函数 `FUN_14007feb0` 只有一条赋值：把 `PEP_PPM_LPI_SUPPORTED.OverrideLpiStates` 写成 0。
处理器回调一旦注册，PEP 告诉 Windows 继续使用 ACPI `_LPI`，不改用 PEP 自己提供的状态。
随后 Windows 用 `0x23` 把这些 `_LPI` 状态送回来，`FUN_1400e0f68` 再抄进 `context+0x618`。

驱动内置默认和设备上的实测值都是 `EnableProcessorManagement = 0`。因此当前设备上，
`PoFxRegisterPluginEx` 会以 NULL 处理器回调完成注册，Windows 不会投递 `0x22`/`0x23`，
`context+0x618` 保持空表。阶段 6 的门控遍历没有簇、没有模式可以匹配，
`DisableSystemLPM`、`DisableCCI`、`DisableCpuVdd`、`DisableCpuRet` 不会被这条路径读到。
这解释了阶段 2/5 里改这几个值没有观察到效果。

## 4. 阶段 6 第 3 节的推论不成立

实验 C 在 `EnableProcessorManagement = 0` 的前提下清空 `_LPI` 并启用 PEP0。
处理器回调当时没有注册，门控表没有数据可匹配，清空 `_LPI` 不会通过这条路径改变 PEP 的行为。
实验 C 的挂死要另找原因。

门控表本身的安装不看 feature 8。`DriverEntry` 一段（`FUN_1401db000`，`0x1401dba28`）
直接调用 `FUN_14001d148`，后者无条件调用 `FUN_1400017d0` 把 6 项门控表挂上。
表挂上了，但在 feature 8 为 0 时没有数据可遍历。

`FUN_140015360`（注册 `L3Cluster` 的 CCI 回调和 `platform`/`DRIPS`）也从同一段
`DriverEntry` 入队，但不是当场执行。`FUN_14001f990` → `FUN_1400217f8`
（`Idle_MicroPep.c:868`）把它推进 `context+0x800` 的 `IdleInitializedCbList`，
只有 `context+0x808` 已经非 0 时才立刻排空。`+0x808` 的写入者这次没有查到。

## 5. 设备状态与下一步

本阶段结束时：A 槽 Windows SSH 在线（`192.168.1.250`），没有 `/dev/ttyACM*`，
`lsusb` 里没有平板。`QCDX` 仍是禁用，PEP0 仍是禁用。UEFI 上电实验还是要等平板进 fastboot，
用 `fastboot boot`，不要 `fastboot flash boot`。

下一步：

1. 查 `context+0x808` 谁把它置位，以及置位之后 `FUN_140015360` 会不会在 feature 8 为 0 时
   仍向内核注册 DRIPS/CCI。这是 PEP 启用后 `0x101` 仍可能走的路径。
2. UEFI 里先打开 GPU_CC 的 GDSC 和时钟，再 `QCDX Start=3`、PEP0 保持禁用启动一次。
3. `smmu.asl` 仍被注释，对 `qcdxkm8250` 初始化的影响未验证。
