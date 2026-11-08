# dagu Windows GPU：阶段 22（显示版本门、槽 24/20 与 WHEA 边界，2026-11-08）

本文记录 2026-11-07 夜到 11-08 凌晨这一轮：`_ROM`（ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）只读存储器方法）被证伪、显示版本门被打通、失败点移到 SMMU（System Memory Management Unit，系统内存管理单元）接口的槽 24/20，以及伪造槽 24 触发 WHEA（Windows Hardware Error Architecture，Windows 硬件错误架构）的边界。

---

## 1. 一句话

`_ROM`（ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）只读存储器方法）和 PCFG（Panel Configuration，面板配置）不是当前显示配置的来源；用第 7 处补丁把 qcdx 的显示版本强制成 `major=5` 后，原来的 `0xC0000001` 版本门通过，失败点移到 SMMU（System Memory Management Unit，系统内存管理单元）接口的槽 24/20；伪造槽 24 的对象会让调用方把 0 当地址去访问硬件，触发 WHEA（Windows Hardware Error Architecture，Windows 硬件错误架构），说明再往后需要真实地址模型。

---

## 2. 本轮结论

### 2.1 `_ROM` 与 PCFG 被证伪

- 覆盖表 8 块、53,457 字节、校验和 0，包含 `QCOM253A`、`ENGINES`、`_ROM`（ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）只读存储器方法）、L81A 面板 XML（Extensible Markup Language，可扩展标记语言）。
- 活动 DSDT（Differentiated System Description Table，差异化系统描述表）子键是 `00000004`，确认覆盖表被 ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）采用。
- 但失败链 `0x998 / 0x86D / 0x310D / 0x44B` 一字不差，说明显示配置不是从 `_ROM`（ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）只读存储器方法）读的。

### 2.2 显示版本门

`FUN_1400AC9C0` 在 RVA（Relative Virtual Address，相对虚拟地址）`0xACB80` 执行：

```text
w21 = *(u32 *)descriptor >> 28      // major
w19 = 1                             // minor（未打第 7 处补丁时）
```

然后按 `0x192640` 的表索引：

| major | minor 0 / 1 / 2 |
|---|---|
| 5 | `0x3a` / **`0x2d`** / `0x3a` |
| 6 | `0x3a` / `0x3a` / `0x34` |
| 8 | **`0x39`** / `0x3a` / `0x3a` |
| 0–4、7 | 空指针 |

判据：`major >= 9`、`table[major] == 0`、`table[major][minor] == 0x3a` 都会失败。

第 7 处补丁：

- RVA（Relative Virtual Address，相对虚拟地址）`0xACB80`
- 原指令 `0x531C7D15`（`lsr w21,w8,#0x1c`）
- 补丁后 `0x528000B5`（`mov w21,#5`）

打完以后失败状态从 `0xC0000001` 变成 `0xC0001817`，证明版本门确实是其中一道。

### 2.3 槽 24 与槽 20

`FUN_140267610`（RVA（Relative Virtual Address，相对虚拟地址）`0x267610`）在 `0x26772C` 调槽 24：

```text
handle = slot24(parent_handle = [range+0x28],
                page_aligned_len,
                len - 0xa,
                translated_flags)
if (handle == NULL) -> 0xC0001817
```

拿到句柄后调槽 20（接口偏移 `0xC0`）：

```text
addr = slot20(handle)
if (addr == 1) -> 0xC0000001
descriptor[+8]   = addr
descriptor[+0x10] = page_aligned_len
descriptor[+0x28] = range
descriptor[+0x30] = handle
```

也就是说：槽 24 负责分配/返回句柄，槽 20 负责把句柄翻译成地址；描述符 `+8` 就是调用方后面要访问的地址。

### 2.4 WHEA 边界

第一次实现槽 24 时，垫片返回一个假的 `VA_RANGE` 对象，槽 20 没有实现、返回 0，于是 `descriptor+8 = 0`。调用方拿 0 当地址访问硬件，蓝屏变成 WHEA（Windows Hardware Error Architecture，Windows 硬件错误架构）不可纠正错误 `0x124`。

这证明：

- 槽 24 不是“返回非空就行”，它必须和槽 20 配对；
- 槽 20 必须返回真实可用的物理地址或硬件结构地址；
- 继续伪造对象会把问题推进到真实硬件访问，产生 WHEA（Windows Hardware Error Architecture，Windows 硬件错误架构）。

### 2.5 最后一个实验（结果未确认）

在回滚槽 24 后，又做了一个最小真实地址实验：

- 槽 24 返回一个基址为 `0x9C000000` 的区间（这是 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）已经点亮面板用的保留显存，大小 `0xFA0000`）；
- 槽 20 返回这个区间的基址。

设备从这次启动回到 fastboot 用时约 37 秒，但停止码没有记录下来（用户未拍图），所以结果未确认。当前部署的就是这份垫片。

---

## 3. 诊断方法（本轮建立的工具）

### 3.1 工具链

主机上无 root 安装：

- `clang-cl` / `lld-link`（LLVM 21，解包到 `~/.local/llvm21`）
- `iasl`（解包到 `~/.local/acpica`）

这样可以直接重编垫片和 DSDT（Differentiated System Description Table，差异化系统描述表）覆盖表。

### 3.2 qcdx 日志钩子

- qcdx 的日志包装在 RVA（Relative Virtual Address，相对虚拟地址）`0x10920`，通过 `0x10950` 的 `bl 0x107d8` 转发事件码。
- 垫片把 `0x10950` 重定向到 `LogThunk`，记录最近 16 条事件码和各自调用点 RVA（Relative Virtual Address，相对虚拟地址）。
- 这解决了“失败发生在 FillMode 之前、看不到解析器内部日志”的问题。

### 3.3 停止码编码

- 失败时不再依赖注册表/文件落盘，直接把关键值编进 `KeBugCheckEx` 的停止码。
- 已用过的编码：
  - `0xDA00 | 事件码低 8 位`
  - `0xDA0000 | 事件码低 12 位`
  - `0xDA0000 | 槽号/IRQL（Interrupt Request Level，中断请求级别）/标志`
  - `0xDA0000 | 槽 24 调用点低 12 位`
  - `0xDA0000 | 状态低 12 位`
- 屏幕上的停止码本身就能读出失败阶段，不需要额外参数或读盘。

### 3.4 蜂箱安全

- 失败时的 `Put`/`ZwFlushKey` + bugcheck 会撕裂 SYSTEM 蜂箱，出现 `0xC000014C` / `0xC0000218`。
- 现在 bugcheck 提前到所有注册表写入之前；失败启动不再写蜂箱。
- 已用备份恢复蜂箱两次，恢复后 `bootgen=37`、`step=101`、覆盖表子键 `00000004` 正常。

### 3.5 放弃的诊断通道

- `RecordStatus` 里的直接 `WriteDiag` 被编译器优化掉。
- 系统线程和最大工作项在后期上下文写盘不落地；失败前磁盘缓存还会丢记录。
- 结论：本轮以后统一用停止码编码，不再依赖文件/线程诊断。

---

## 4. 关键坐标

| 项 | 值 |
|---|---|
| 显示版本门指令 | RVA（Relative Virtual Address，相对虚拟地址）`0xACB80`，`lsr w21,w8,#0x1c` |
| 显示版本表 | `0x192640`（major 索引，子表 16 字节一项） |
| 槽 24 调用者 | `0x267610`，调用点 `0x26772C` |
| 槽 24 失败状态字面量 | `0x267818` = `0xC0001817` |
| 槽 20 接口偏移 | `0xC0` |
| 槽 24 接口偏移 | `0xE0` |
| 虚表 | `0x14BFF0 + 0x70` = `0x267820`（另一套对象虚表 `0x14C4D0`） |
| GOP 显存 | 基址 `0x9C000000`，大小 `0xFA0000` |
| 覆盖表 | 8 块、53,457 字节、校验和 0 |
| 活动 DSDT（Differentiated System Description Table，差异化系统描述表） | revision 4 |

---

## 5. 当前设备与部署

| 项 | 状态 |
|---|---|
| 槽位 | B 槽 Linux（`192.168.1.158`），A 槽属性 `0x32`（优先级 2、未激活、retry 6） |
| 蜂箱 | 完整，`bootgen=37`、`step=101`、覆盖表子键 `00000004` |
| 垫片 | 当前部署的是“槽 24 基址 `0x9C000000` + 槽 20 返回基址”的实验版（SHA256 `d3043f8f…`） |
| 覆盖表 | 8 块 / 53,457 字节，已在蜂箱里，不再每次启动重写 |

---

## 6. 未提交改动

- `port/dagu/windows-drivers/dagu-smmushim/dagu-smmushim.c`
  - 日志钩子、16 条日志环
  - 停止码编码
  - 失败时提前 bugcheck（不写蜂箱）
  - 第 7 处补丁（`0xACB80`，`major=5`，诊断用，不是正式修复）
  - 槽 24/20 实验代码
- `port/dagu/windows-drivers/dagu-smmushim/dagu-dsdt-ov.h`（53 KB 覆盖表数组）
- `port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics-qcom253a.asl`（`_ROM`（ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）只读存储器方法）+ L81A PCFG（Panel Configuration，面板配置））

注意：`major=5` 补丁是诊断手段，正式方案应该是让显示版本如实上报 5，而不是长期强制。

---

## 7. 下一步

1. **确认槽 20 实验的停止码**：如果还是 WHEA（Windows Hardware Error Architecture，Windows 硬件错误架构），说明描述符 `+8` 不是普通 DDR 物理地址，而是页表/硬件结构地址，需要真实映射；如果变成我们的 `0xDAxx`，看状态是否继续往后移。
2. **逆 `qcsmmu8250.sys` 的槽 20/24**：该驱动没有导出、没有接口 GUID 字面量（GUID（Globally Unique Identifier，全局唯一标识符）来自注册表 `Parameters\N\Guid`），需要从 WDF（Windows Driver Framework，Windows 驱动框架）接口注册和内部函数表入手。
3. **回到真实映射主线**：如果槽 20 必须是页表/硬件地址，就回到阶段 19 的 GX（Graphics eXtension，图形扩展电源域）/PIL（Peripheral Image Loader，外设镜像加载器）/SMMU（System Memory Management Unit，系统内存管理单元）安全世界与电源域问题。
4. **清理诊断**：正式提交前把第 7 处补丁、停止码编码、槽 24/20 实验从垫片里拆出去，恢复已知可控状态。

### 关联文档

[stage21（问题码 43 与第 25 槽）](woa-dagu-gpu-stage21-2026-11-02.md)、
[stage20（SMMU 接口契约与垫片）](woa-dagu-gpu-stage20-2026-11-02.md)、
[stage19（qcsmmu 复位与时钟假设）](woa-dagu-gpu-stage19-2026-10-31.md)、
[GPU 路线图](woa-dagu-gpu-roadmap.md)。
