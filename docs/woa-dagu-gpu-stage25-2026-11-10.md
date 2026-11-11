# dagu Windows GPU：阶段 25（垫片换成真实地址空间：IOVA 分配 + AArch64 页表 + CB0 编程）（2026-11-10）

阶段 24 证明 Windows 能把 Adreno SMMU（System Memory Management Unit，系统内存管理单元）的 CB0（Context Bank 0，第 0 号上下文组）配成 Linux 那样的生效状态。本阶段把垫片 `dagu-smmushim` 从“返回假对象”换成真实的地址空间实现：每个地址空间有自己的 IOVA（I/O Virtual Address，设备侧虚拟地址）分配器和 AArch64 第一阶段页表，GPU 那两个地址空间的页表接到 CB0 的 `TTBR0`/`TTBR1` 上。

---

## 1. 先把 qcdx 怎么用这些槽弄清楚

qcdx 不直接调接口槽，它包了一层对象，虚表在 `0x14BFE8`。逐个方法反汇编后得到这张对应表（以前只知道其中几个）：

| 虚表偏移 | 方法 RVA | 调的槽 | 作用 |
|---|---|---|---|
| `+0x30` | `0x266580` | 6 / 7 | 建 / 删地址空间。参数是 `ENGS` `PAGETABLES` 一项的基址和大小 |
| `+0x48` | `0x2670D0` | 17 | 释放一批句柄 |
| `+0x60` | `0x2672D0` | 22 → 28 → 27 | 在地址空间上开一个区间窗口，取长度、取基址 |
| `+0x70` | `0x267610` | **24 → 20** | **分配一个新 IOVA，再翻成地址**（阶段 22 卡在这里） |
| `+0x78` | `0x267820` | 25 | 在指定 IOVA 上建子区间（例如 UEFI 帧缓冲 `0x9C000000`） |
| `+0x80` | `0x267A60` | 11 | 释放 IOVA 句柄 |
| `+0x98` | `0x267F70` | 14（+29） | **把一份 MDL（Memory Descriptor List，内存描述符列表）映射到 IOVA** |
| `+0xA0` | `0x268150` | 30 + 15 | 取消映射 |

槽 24 的参数（`0x26771C` 起）：`x0` = 区间句柄，`x1` = 按页对齐的大小，`w2` = `max(对齐位数, 12) - 10`，`w3` = 换算过的访问标志。返回空即 `0xC0001817`。槽 20 返回 1 即失败，否则这个值写进描述符 `+8`，就是设备要访问的地址。

槽 14 的第二个参数是 `0x2AB5D8` 按页号造的标准 MDL：`+0x20` 是 `MdlFlags/Size`，`+0x28` 是字节数，`+0x30` 起是页帧号数组。

槽 24 的调用者全在显示路径里（`0x2648D0`、`0x2649A8`、`0x29F3E4`），用的是适配器 `+0x41B0`/`+0x41D8`/`+0x41E0`，也就是 `MdpNonSecurePT` 等显示地址空间。

## 2. 每个地址空间怎么落地

只有 Adreno SMMU 的 CB0 归我们配（阶段 24）。`ENGS` 描述的其它地址空间要么在应用处理器 SMMU 后面（显示 MDP（Mobile Display Processor，移动显示处理器）、加密），要么在我们没接管的上下文组上（GMU（Graphics Management Unit，图形管理单元）是 SID 5，安全区归 CP_PIXEL）。那些设备现在由 UEFI 留在旁路状态，也就是设备看到的地址就是物理地址。所以按地址空间分四种：

| 种类 | 哪些地址空间 | 设备看到的地址 | 槽 24 交出什么 |
|---|---|---|---|
| 恒等 | `MdpNonSecurePT`、`MdpSecurePT`、加密、视频等所有未列名的 | 物理地址 | 4 GB 以下真实分配的连续内存的物理地址 |
| TTBR0 | `GraphicsPerProcessPT`（`0x40_0000` 起） | 经 CB0.TTBR0 的页表翻译 | 页表里的 IOVA，槽 14 写 PTE |
| TTBR1 | `GraphicsGlobalPT`（`0x80_0000_0000` 起） | 经 CB0.TTBR1 的页表翻译 | 同上 |
| 私有 | `GraphicsSecurePT`、`GraphicsGmuPT` | 暂时没有硬件走这张表 | 页表里的 IOVA，只记账 |

恒等地址空间是阶段 22 WHEA（Windows Hardware Error Architecture，Windows 硬件错误架构）`0x124` 的直接修正：那次槽 20 返回 0、或者返回一个没人分配过的地址，设备拿去访问就出硬件错误。现在交出的是这块驱动自己分配的、真实存在的 DDR。

恒等地址空间的槽 14 有一个问题：qcdx 给的 MDL 如果不是槽 24 分出来的那块内存，恒等映射就没法让设备看到 qcdx 想要的页。垫片会检查每一页，不一致时记 `io_idmiss` 和第一处的期望/实际页号（`io_idwant`/`io_idgot`）。`Parameters\idlax=1` 时仍然报成功（设备访问的是垫片自己分配的那块，内存安全，但功能上是错的），这是诊断开关，用来看清后面一道门；`idlax=0` 时返回 `STATUS_NOT_SUPPORTED`。

## 3. 页表格式和 CB0 的值

`dagu-iommu.h` 是不依赖 Windows 的页表和 IOVA 分配器，主机单元测试 `tests/test_iommu.c` 跑的就是驱动里那份代码（19 项全过，带 AddressSanitizer）。

- 4 KB 粒度，每个 TTBR 半区 39 位（`T0SZ = T1SZ = 25`），三级页表（L1 `38:30`、L2 `29:21`、L3 `20:12`），只用 4 KB 叶子页。
- 叶子描述符与 Linux `io-pgtable-arm` 一致：`AF`、`nG`、`AP[1]=1`（非特权可访问），可缓存内存用 `AttrIndx=1` + `SH=inner shareable`，只读时置 `AP[2]`。
- 新建下级表时先写满表内容再写指向它的描述符；取消映射后对 CB0 做 `TLBIASID` + `TLBSYNC`。
- CB0：`TCR = 0xB5193519`（两个半区都开，字段与 Linux 相同，只是 `T0SZ/T1SZ` 从 16 改成 25），`TCR2 = PASIZE 36 位 | SEP = bit 39 | AS`，其余 `ACTLR/CBA2R/CBAR/MAIR0/SCTLR` 用阶段 24 验证过的 Linux 值。
- `TTBR0` 指向第一个每进程地址空间的页表，`TTBR1` 指向全局地址空间的页表。任一出现或删除时重写一次 CB0。

**这一版仍然不写 `SMR`/`S2CR`，不把 GPU 的流 SID 0 路由到 CB0**（`map` 保持 0）。也就是说页表建好、CB0 打开，但没有任何硬件事务会走这张表。阶段 19 的复位发生在真实走表的时刻，这一步留到下一阶段、单独上板。

## 4. 风险边界

- SMMU 只在 qcdx 第一次查询接口时才映射（`2-run.cmd` 运行时），开机路径不读 GPU_CC（Graphics Clock Controller，图形时钟控制器）也不读 SMMU。映射前先确认 GPU CX 电源域和三条时钟都在，否则 `cb0_state=0xA2`，什么都不碰。
- `Parameters\cb0=0` 可以关掉 CB0 编程，只保留地址分配。
- 不认识的句柄继续走阶段 21 的老路径（假区间对象），已验证的槽 22/25 行为不会退化。
- 在高 IRQL 下释放连续内存是非法的，这种情况只计数（`io_leak`），不释放。

## 5. 上板要看的遥测

`Services\dagusmmu\Parameters`，每 16 次槽调用刷一次：

| 值 | 含义 |
|---|---|
| `io_kinds` | 每 4 位一个地址空间的种类（1 恒等、2 TTBR0、3 TTBR1、4 私有） |
| `io_iova` / `io_maps` | 交出的 IOVA 句柄数 / 成功的槽 14 次数 |
| `io_err` | 最后一次失败：`(槽号 << 16) | 原因` |
| `io_idmiss` / `io_idwant` / `io_idgot` | 恒等映射里 MDL 页和 IOVA 对不上的次数和第一处 |
| `cb0_state` / `cb0_on` / `cb0_sync` / `cb0_fsr` | SMMU 映射结果、CB0 是否已编程、最后一次同步、故障状态 |
| `ttbr0_*` / `ttbr1_*` / `pt*_tables` / `pt*_mapped` | 两张页表的根地址、表页数、已映射页数 |

过关标准：适配器初始化越过阶段 22 的槽 24 / 20（`fail` 不再是 `0xC0001817`），没有 WHEA `0x124`，没有整机复位。

### 关联文档

[阶段 24（CB0 写测）](woa-dagu-gpu-stage24-2026-11-10.md)、[阶段 22（槽 24 / 20）](woa-dagu-gpu-stage22-2026-11-08.md)、[阶段 21（槽 25）](woa-dagu-gpu-stage21-2026-11-02.md)、[阶段 19（走表复位）](woa-dagu-gpu-stage19-2026-10-31.md)。
