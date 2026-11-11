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

照[适配计划](woa-dagu-gpu-adaptation-plan-2026-11-10.md) §2.1：先在 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）里**只读**探测 GX 电源域和 GMU（Graphics Management Unit，图形管理单元）的状态，确认 Windows 接手时它们是什么状态。不要伪造这三个电源接口去“报成功”：那只会让 qcdx 更早地碰没电的硬件。也不要在没弄清 RPMh（Resource Power Manager hardened，硬化资源电源管理器）投票之前写电源控制寄存器。

### 关联文档

[阶段 25](woa-dagu-gpu-stage25-2026-11-10.md)、[阶段 19](woa-dagu-gpu-stage19-2026-10-31.md)、[阶段 15](woa-dagu-gpu-stage15-2026-10-31.md)、[适配计划](woa-dagu-gpu-adaptation-plan-2026-11-10.md)、[路线图](woa-dagu-gpu-roadmap.md)。
