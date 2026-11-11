# dagu Windows GPU：阶段 26（接口补齐、槽 24 对齐之后，停在图形核心电源）（2026-11-11）

阶段 25 把垫片 `dagu-smmushim` 换成真实地址空间以后，2026-11-11 在板上跑了五次 `2-run.cmd`。每一次失败的位置都比上一次靠后，最后停在图形核心 GX 电源域没有上电。本文按顺序记下每一次的证据，以及哪些是修好的，哪些还没有修。

证据全部从 B 槽 Linux 只读挂载 Windows 分区读取：`pagefile.sys` 里的内核转储、`SYSTEM` 配置单元（回放日志后的副本）、`gpu-run.txt`。转储里的读法见 `tools/winarm/dagu-dump-triage.py --qcdx-log`。

---

## 1. 五次运行

| 时间 | 垫片版本 | 结果 | 原因 | 处理 |
|---|---|---|---|---|
| 08:56 | 1.0.2.0 | `0xA` | qcdx 等的四个 SCM（Secure Channel Manager，安全通道管理器）/ TrEE（Trusted Execution Environment，可信执行环境）接口一个都不在：驱动仓库重建时丢了 `dagu-qcif`。启动失败 `0xC00000C0`，qcdx 的回退路径等一个没初始化的互斥体 | `1-install` 重新装 `dagu-qcif`；`2-run` 只在四个接口都在时才启动 qcdx |
| 13:38 | 1.0.3.0 | 未启动 | 预检读 `DeviceClasses` 下的 `Linked`，把在线的接口判成缺失 | 改用 `CM_Get_Device_Interface_List`，和 qcdx 自己的查法一致 |
| 14:12 | 1.0.3.0 | 问题码 31，`0xC00000BB` | 垫片在 qcdx 映像映射时就把 `QCDX Start` 写回 4，PnP（Plug and Play，即插即用）在 `AddDevice` 前又查了一次服务 | 改到 qcdx 第一次向垫片要接口时再写（`StartDevice` 里，`AddDevice` 之后） |
| 14:42 | 1.0.4.0 | `0x124` | 见 §2、§3 | 槽 24 对齐（§2） |
| 15:57 | 1.0.5.0 | `0x124` | 见 §3 | 未修 |

第 1 次的崩溃让 `QCDX Start=3` 留在了配置单元里，下次开机会再加载 qcdx。之后两次 `0x124` 后读到的都是 `Start=4`：垫片的保护生效了。

---

## 2. 槽 24 的对齐（已修）

14:42 那次，垫片内存里的 `gIommuErr = 0x180004`：槽 24 原因 4，返回的块起始地址没有按要求对齐。qcdx 要的是 16 KB、按 16 KB 对齐（对齐码 4，即 2^(4+10)），而 `MmAllocateContiguousMemorySpecifyCache` 只保证 4 KB 对齐。

修法：申请长度取不小于大小和对齐的 2 的幂，并把同一个值作为“不得跨越的边界”传进去，这样拿到的块一定从边界开始。`dagu-iommu.h` 的 `iommu_contig_span`，主机单元测试 23 项全过。

15:57 那次槽 24 → 槽 20 正常：`io_iova = 3`，槽 20 交出 `0xBAE4C000`、`0xBAE48000`。

**更正**：14:42 那次我把 `0x124` 归因于槽 24 失败，这不对。两次 `0x124` 的出错地址相同，失败日志的尾巴也相同（§3），而 15:57 那次槽 24 已经成功。槽 24 对齐是一个真问题，但它不是 `0x124` 的原因。

---

## 3. `0x124` 的真正位置：图形核心电源

### 3.1 硬件错误记录

两次的 WHEA（Windows Hardware Error Architecture，Windows 硬件错误架构）记录只有一个 12 字节的段（GUID `f2a4a152-9c6d-4020-aecf-7695b389251b`），按 32 位异常综合症 + 64 位地址解读：

| | 14:42 | 15:57 |
|---|---|---|
| 异常综合症 | `0xBE000411` | `0xBE000411` |
| 异常类 | `0x2F`（SError，异步系统错误） | 同左 |
| 地址 | `qcdx+0x2D0430` | `qcdx+0x2D0430` |

SError 是异步的，地址只说明错误送达时 CPU 正在执行 qcdx 的哪里（`0x2D0430` 是一个释放资源的收尾函数，在电源初始化失败路径上被调用），不是出错的那一次寄存器访问。段格式是从数值反推的，没有对照文档。

### 3.2 出错前 qcdx 自己的日志

qcdx 的错误/警告环（`--qcdx-log`），两次的尾巴一致：

1. `0xD9570` 依次打开三个电源接口（编号 0、1、2），每次都记 `0x82`（找不到目标），返回 5。接口 GUID 在 qcdx 的 `0x193958` 表里：
   - `{5b9df049-70d3-4698-8e48-85b26c1aa59f}`
   - `{11dc4578-e341-4df9-bce7-516831c853ca}`
   - `{95914420-8c5c-4df4-8dd8-2529fa9c0283}`
2. `0xD8D20` 随后发出的一串电源请求（`0x33D`、`0x34D`、`0x364`、`0x386`、`0x586`、`0x597`、`0x5AD`、`0x5BE`）全部失败。
3. 之后就是 `0x124`。

这三个 GUID 只出现在 `qcpep8250.sys`（电源引擎插件）和 `qcpmic8250.sys` / `QcPmicApps8250.sys`（电源管理芯片驱动）里。Windows 的配置单元里三者都从未注册过：`qcpep` 服务在，但没有 `QCOM2519` 设备（覆盖表故意不加，一加就蓝屏 `0x101` / `0x1A`，见[适配计划](woa-dagu-gpu-adaptation-plan-2026-11-10.md) §2.2）。

结论：qcdx 想通过电源引擎插件给图形核心投票上电，没有人接，于是投票全部失败。它随后碰了图形核心的寄存器，而 GX 电源域没有电，总线返回异步错误。这就是[阶段 19](woa-dagu-gpu-stage19-2026-10-31.md) 记下的 GX / RPMh（Resource Power Manager hardened，硬化资源电源管理器）那一道关。

### 3.3 还没确认的

- 具体是哪一次寄存器访问出的错：异步错误拿不到。要确认需要 KDNET（Kernel Debug Network，内核网络调试）挂上调试器，或在 qcdx 电源失败之后、访问之前停住。
- 恒等地址空间的槽 14 有两次页不一致（`io_idmiss = 2`，期望页号 `0xBAE4C`，实际 `0x19ED93`）：qcdx 把它自己的页映射到垫片分配的地址上。`idlax = 1` 时放行，设备读到的是垫片那块内存，功能上不对。电源这一关过去之前，这个问题碰不到。

---

## 4. 当前状态

| 项 | 状态 |
|---|---|
| 垫片 | 1.0.5.0，SHA256 开头 `5D5F9CA3` |
| `dagu-qcif` | 1.0.1.0，四个接口在线 |
| `QCDX Start` | 4（开机不加载） |
| Windows 分区 | WinPE（Windows Preinstallation Environment，Windows 预安装环境）检查无损坏 |

## 5. 下一步

**本节被 §6 取代。**

## 6. 更正（同日稍后）

§3.2 的结论下错了，原因有两处：

1. **三个接口属于电源管理芯片驱动，不是电源引擎插件。** 按 GUID 查回去，它们是 `qcpmic8250.sys`（ACPI `QCOM252E`，挂在 SPMI（System Power Management Interface，系统电源管理接口）`QCOM250C` 下）发布的。调用它们的是 qcdx 的显示初始化（`0xAC9C0` → `0xADC00` → `0xD9570` / `0xD8D20`），不是图形核心上电。这一串请求是面板和背光的供电（qcdx 的面板配置里有 `BacklightPmic*`、`PMIPowerPmic*`）。dagu 的 Windows 里 `QCOM252E` 和 `QCOM250C` 两个设备都没有，所以接口不存在。
2. **GX 在这块板上不是死墙。** 同一台平板的 Linux 7.0 里，GPU 已经能用：GMU（Graphics Management Unit，图形管理单元）固件 v2.1.8 加载，Turnip（Mesa 的 Adreno Vulkan 驱动）能出图，GX 由 GMU 经它自己的 RSCC（RSC Controller，资源状态协调控制器）上电。超时的是 CPU 侧互连带宽投票，不是 GX。[阶段 19](woa-dagu-gpu-stage19-2026-10-31.md) 把两者混在了一起。

所以 `0x124` 出在显示初始化里，发生在面板供电请求全部失败之后，具体是哪一次访问还没定位。两次的报错地址都是 `qcdx+0x2D0430`，是确定性的。

另外查到一处 ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）资源问题，现在还碰不到，但 GMU 初始化时会碰到：GPU0 的 `_CRS` 和 `RESI` 里没有 `GPU_RSCC`。qcdx 在 `0x2AC61C` 缺这一项时，按 `GFX_REG_CONT + 0x2D000` 推算 RSCC 地址，也就是 `0x3D8D000`。那是 SM8150 的布局。SM8250 的 RSCC 在 `0x3DE0000`：主线 `sm8250.dtsi` 的 `gmu` 节点写的是这个地址，平板上活的设备树 `reg` 读出来也是这个地址。

下一步有两条路，都需要实机验证：

- **定位 SError 的那次访问**：给垫片加调用点面包屑（把 qcdx 显示初始化里几处 `bl` 改到记录站点后再跳回的跳板），转储里读最后进入的函数。
- **补电源管理芯片驱动**：给 Windows 加 `QCOM250C` / `QCOM252E` 两个节点，让 qcdx 的面板供电请求有人接。这一步会碰电源轨，`dagu-battery` 已经在直接访问 SPMI，要先确认两者不冲突。

补充：面板供电这一段由 qcdx 的面板配置决定。`0xADC00` 只在面板配置 `+0xF00` 的 bit 16 置位、`+0x5C`（电源管理芯片型号）非零时才去开这三个接口；随后按配置里的型号去查型号表。dagu 的面板 L81A 用两颗 I2C 背光芯片 KTZ8866，供电不走电源管理芯片的 WLED（White LED，白光背光驱动）/ LAB（LCD 正压）/ IBB（LCD 负压）。所以 qcdx 现在拿到的面板配置不是 dagu 的：要么是参考板的默认值，要么是从 `UEFIDisplayInfo` 固件变量（GUID `{9042a9de-23dc-4a38-96fb-7aded080516a}`，长度 `0x78`）推出来的。

这样排出的第三条路，应该排在前两条之前：

- **给 qcdx 正确的面板配置**：让它知道面板供电不走电源管理芯片，这三个接口就不会去开。先在 Windows 里读一次 `UEFIDisplayInfo` 变量，看它在不在、内容是什么；再顺着 `0xADC00` 的 `+0xF00` / `+0x5C` 往回找，它们是从哪里填进去的。

从 15:57 的转储里读到的（只读）：

| 项 | 值 | 说明 |
|---|---|---|
| qcdx 日志 `#36` | `ERR 0x226`，`qcdx+0xD3EC8`，参数 `0 0x78` | `0xD3D38` 读 `UEFIDisplayInfo` 失败的分支：`ExGetFirmwareEnvironmentVariable` 返回非 0 |
| qcdx 里这份变量的副本（`+0x21F5CC`） | 前 0x28 字节全 0 | 没读到 |
| `BacklightPmicModel` / `BacklightPmicNum` | 2 / 2 | 默认值，不是 dagu 的 |
| `PMIPowerPmicNum` | `0x1E` | 同上 |

dagu 的 UEFI 只有 SimpleFb，没有高通的 `DisplayDxe`，所以不会写这个变量。qcdx 读不到，就用自带的参考板面板默认值：背光走电源管理芯片，于是去开那三个接口。这和 §6 第 1 条对得上，也说明面板配置不对是在接口缺失之前的一环。

下一步：从 `0xD3E08` 往后把这 0x78 字节的布局逆出来（已知 `+0x38`、`+0x40`、`+0x48`、`+0x5C` 被读），在 `DaguPlatDxe` 里按 L81A 的真实参数写出 `UEFIDisplayInfo`。这要刷 A 槽的 UEFI，上板前要确认 KTZ8866 背光不会被 qcdx 改走。

布局补充：变量在 GOP（Graphics Output Protocol，图形输出协议）的 GUID 下，公开资料（Linaro 2019 年 `efi/libstub: detect panel-id` 补丁）给出 `+0x00` 是版本（高 16 位为 `0xAA`），`+0x28` 是面板编号。qcdx 只用其中几项：`+0x38` 存成面板编号，`+0x40` 是亮度（1–100），`+0x48`、`+0x5C` 存进显示状态。面板编号随后被二十多个函数使用，说明 qcdx 是拿它去查自带的面板表。L81A 不大可能在这张表里，所以只写这个变量很可能不够。

还有一条没查的入口：`QDIDriverEntry` 里读注册表 `Miniport\PanelOverride`（以及 `Width`、`Height`）。这可能是不刷 UEFI、直接从注册表给面板参数的正路，应当先逆这一条。

已逆（`0x2C07B8`–`0x2C08BC`）：`PanelOverride` 只读 `Width` 和 `Height` 两个值，接受竖屏 480–1600 × 640–2560 或横屏范围，用于模拟面板的分辨率。它不带背光和供电方式，换不掉面板供电走电源管理芯片这一步。所以要让 qcdx 不去开电源管理芯片接口，还是得给它一个真的面板编号或真的面板配置，正路仍是 `UEFIDisplayInfo` 加 qcdx 自带面板表里的 L81A 条目（如果没有，就要补电源管理芯片栈）。

### 关联文档

[阶段 25](woa-dagu-gpu-stage25-2026-11-10.md)、[阶段 19](woa-dagu-gpu-stage19-2026-10-31.md)、[阶段 15](woa-dagu-gpu-stage15-2026-10-31.md)、[适配计划](woa-dagu-gpu-adaptation-plan-2026-11-10.md)、[路线图](woa-dagu-gpu-roadmap.md)。
