# dagu Windows GPU：阶段 20（qcdx↔SMMU 接口契约，以及不碰 APPS SMMU 的垫片）

阶段 15 停在 `qcdx` 阻塞等待设备接口。本阶段把等待之后的调用约定从 `qcdxkm8250.sys` 里逆出来，并按这个约定写了 [`dagu-smmushim`](../port/dagu/windows-drivers/dagu-smmushim/dagu-smmushim.c)。原版 `qcsmmu8250` 仍然不加载。

## 1. qcdx 在等什么

`ENGS` 里每个引擎的 `SMMUID` 就是设备接口类 GUID，不是查询接口的类型 GUID。

| 引擎 | 设备接口 GUID（SMMUID） | 谁的 SMMU |
|---|---|---|
| GRAPHICS | `{9833C712-3292-4FFB-B0F4-2BD20E1F7F66}` | Adreno `0x03DA0000`，INF `Parameters\1` |
| ROTATOR / CRYPTO / MDPBLT（SHAREDSMMU） | `{36079AE4-78E8-452D-AF50-0CFF78B2F1CA}` | 显示侧，INF `Parameters\0`，背后是 APPS SMMU `0x15000000` |
| VIDEO | `{665E0F8E-ADD3-49D1-91BC-5540C5F57FBA}` | 另一份接口，不写 APPS、也不写 Adreno |

阶段 15 转储里的 `{36079AE4-...}` 是显示引擎先等到的那个。写 `0x15000000` 会拆掉 UFS 启动盘（阶段 10），垫片只注册接口、不映射这段地址。

等待函数在 `qcdx` PAGE 段 `0x284e38`：`IoRegisterPlugPlayNotification(EventCategoryDeviceInterfaceChange, INCLUDE_EXISTING, GUID, ...)`，然后 `KeWaitForSingleObject` 30 秒。GUID 来自引擎对象 `+0x18`，拷进池标签 `qDXA` 的块首。

## 2. 接口出现之后

`0x285988`：

1. `IoGetDeviceInterfaces` / 使用到达通知里的符号链接。
2. `IoGetDeviceObjectPointer(link, GENERIC_READ|GENERIC_WRITE)`。
3. `WdfIoTargetCreate`，再 `WdfIoTargetOpen`，类型 `WdfIoTargetOpenByName`（2），DesiredAccess `0xC0000000`，ShareAccess 3。
4. `WdfIoTargetQueryForInterface`（KMDF 1.25 函数表下标 177）：

| 参数 | 值 |
|---|---|
| InterfaceType | ACPI `SMMUINTERFACEID`；全 0 时用 `{C178BD17-15DC-4145-A907-61327EC6284D}`（`qcdx` RVA `0x194be0`） |
| Size | `0x1A0` |
| Version | 2（引擎对象 `+0xD8` 初值） |
| InterfaceSpecificData | NULL |

VIDEO 的 `SMMUINTERFACEID` 不是 0，查询 GUID 是 `{1C3FC0E8-0B11-4EE0-BE89-3E21420A865F}`。

返回后 `qcdx` 读 `INTERFACE.Size`。`Size <= 0x1A0` 才收下；更大就改用 `{FBF4F730-5D06-4B12-A3E3-83BD94ED1A45}`、长度 `0x198` 再查一次。

收下之后的第一枪是接口缓冲偏移 **`0x180`**（第 44 槽）。返回值低 8 位写进引擎对象 `+0x47f8`。`0x37d0` 只在这个字节为 0 时才调用偏移 **`0x198`**（第 47 槽，参数是 context、一个字节、一个 dword）；非 0 就跳过它。`0x198` 为空则改调偏移 **`0x28`**。

ARM64 上 `INTERFACE` 头是：`Size`/`Version` 在 0，`Context` 在 `+8`，`InterfaceReference` 在 `+0x10`，`InterfaceDereference` 在 `+0x18`。自定义函数从 `+0x20` 起，所以上面三个偏移分别是第 44、47、1 号槽。

`qcsmmu8250.sys` 里没有 `{C178BD17-...}`。它用 WDF 按注册表 `Parameters\N\Guid` 注册设备接口，查询接口的类型 GUID 由 `qcdx` 这一侧决定。垫片直接回答 `qcdx` 会送来的那三个 GUID。

## 3. 垫片做了什么、不做什么

[`dagu-smmushim`](../port/dagu/windows-drivers/dagu-smmushim/dagu-smmushim.c) 是根枚举的 WDM 设备（`root\DAGUSMMU`，服务 `dagusmmu`），不绑定 `QCOM2509`。

- 注册并启用上面三个设备接口，让等待返回。
- `IRP_MN_QUERY_INTERFACE` 填满 `0x1A0`。`0x180` 返回 0，这样 `qcdx` 才会走进 `0x198`。其余槽也返回 `STATUS_SUCCESS`。前 8 次调用按 `sN`/`aN`/`bN`/`cN`/`dN` 记进注册表，`ncall` 是次数。
- **不映射、不写 `0x15000000`。**
- Adreno 流只在同时满足时才写：槽是 `0x198`、这次查询不是 VIDEO、`Services\dagusmmu\Parameters\map` 为 1。写的内容是阶段 18 验证过的 `S2CR[0]=0`（翻译到 CB0）和 `SMR[0]=0x80000000`（SID 0）。不写 `sCR0`、`sCR2`、`CBAR`，不连 context-fault 中断。`ttbrlo`/`ttbrhi` 都非 0 时才写 CB0.`TTBR0`。默认 `map=0`，因为走表会整机复位（阶段 19），而这个槽的参数里还没有可以信任的页表地址。

注册表键：`HKLM\SYSTEM\CurrentControlSet\Services\dagusmmu\Parameters`。`step` 在每个阶段 `ZwFlushKey`。`0x10` 进入、`0x20` AddDevice、`0x30` 接口已启用、`0x40` 查询已回答、`0x60` 有槽被调用、`0x80` 起才是 Adreno 写。`seen0`/`seen1` 是被调用槽的位图。

## 4. 构建

`dagu-smmushim.sys` 已用 `build-kmdriver.sh` 编出（ARM64 PE），并用 `sign-driver.sh` 测试签名。覆盖表 `/tmp/dagu-ov-shim.aml` 只含 `GPU0`（`QCOM253A`），校验确认没有 `QCOM2509` / `QCOM2519`，`SOSI` 未改。

## 5. 上板

14:35 从 fastboot 切到 A 槽重启后，屏幕停在 UEFI 日志：`DaguPlat: ESP found, flag open Not Found`（没有 fastboot 旗标，属正常路径），随后 `bootmgfw.efi`、`ExitBootServices`（`V0310019`），画面冻住。这和阶段 14 的症状一样：覆盖表还在，内核在 `ExitBootServices` 之后挂住，不复位。

从 B 槽 Linux（`192.168.1.72`）删掉残留的 `00000004`（里面有 `MMU1` / `QCOM2509`）后，Windows 能正常起来。随后装上垫片（`ROOT\DAGUSMMU\0000`，`step=0x30`）和只含 `GPU0` 的覆盖表。第一次运行时拉起 `QCDX`，垫片收到了查询（`qsize=0x1A0`、`qver=2`）。当时 `0x180` 返回 1，所以 `0x198` 没被调用。实际打到的是槽 44（探测）、槽 42（`0x170`）和槽 6（`0x50`）。槽 6 的参数是 `0x100000`、`0xfff00000`、0、一个内核指针：`0x26320c` 把小于 1MB 的长度抬到 1MB，再按 1MB 对齐。`ACPI\QCOM253A\0` 随后被禁用。

第二次把 `0x180` 改成返回 0（新的 `dagu-smmushim.sys` 21168 字节，已换进 DriverStore，服务重新起来后 `step=0x30`），15:54 再次运行时拉起 `QCDX`。`map` 仍是 0，没有写 Adreno 寄存器。拉起后平板蓝屏 `IRQL_NOT_LESS_OR_EQUAL`（`ntoskrnl.exe`），因为收尾没跑完，hive 里 `QCDX` 的 `Start` 停在 3，下一次开机又加载了它。

离线读到的调用记录：`ncall=90`，`seen` 只有槽 2、6、39、44、47。前几次是探测（44）→ 映射（47，参数 context、1、0 或 3）→ 槽 2 → 槽 39（context、`0xF79CE000`、`0xFFFFFFFF`）。最后一次仍是槽 47，第三个参数是 `0xC`。映射槽被调用了，但 `map=0`，垫片没有写寄存器；`qcdx` 拿着成功返回值继续往下走，然后在高 IRQL 上读到空指针。16:12 已从 B 槽把 `QCDX` 的 `Start` 改回 4。`qcsmmu` 仍是 4。

UEFI 画面上的 30 秒不是在等设备。`DaguPcieDxe` 在 PCIe 日志打完后无条件 `Stall` 30 秒，方便人眼读屏。照片里 `first failing step 0` 表示没有失败步骤，链路是起来的。源码里的暂停已改为 0；已经刷进启动分区的那份固件还是旧的，这次没有刷 `boot`。

## 6. 上板边界

覆盖表只追加带 `REGR` 的 `GPU0`，不要 `MMU0`/`MMU1`。`qcsmmu` 保持 `Start=4`。`QCDX` 按需启动，用运行时拉起，不要设成开机启动。过关标准是越过 `InitSMMUDisplay`，不蓝屏 `0xA`，不整机复位。没过关就删覆盖表，不要改去加载原版 `qcsmmu`。

### 关联文档

[stage15](woa-dagu-gpu-stage15-2026-10-31.md)、[stage18](woa-dagu-gpu-stage18-2026-10-31.md)、[stage19](woa-dagu-gpu-stage19-2026-10-31.md)。
