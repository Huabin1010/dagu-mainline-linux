# dagu Windows GPU：阶段 15（qcdx 崩溃根因定位：缓存复用空指针）（2026-10-31）

阶段 11 发现 `qcdxkm8250.sys` 在绑定时 `BugCheck 0x3B`（`SYSTEM_SERVICE_EXCEPTION`，
P1=`0xC0000005`），崩溃点恒定在 `qcdxkm8250.sys+0x262904`。阶段 11–13 反复换地址、换 `PMCL`、
开关 GPU CX 都复现同一个崩溃，说明它跟 GPU 硬件和 ACPI 地址内容无关。本阶段把这个崩溃彻底逆向
到根因，并给出一个可测的候选修复。工具：`tools/winarm/qdis.py`（capstone，imagebase
`0x140000000`，RVA 寻址、带字符串解析）。

## 1. 崩溃现场（崩溃转储寄存器确认）

从 A 槽拉起 qcdx（GP 覆盖表、阶段 12 修正地址、CX 已上电、无 SMMU）后，拿到内核转储
`MEMORY-qcdx2.DMP`，用 `tools/winarm/dagu-dump-triage.py`（ARM64 SDMPDUMP 解析器）定位：

- 出错指令：`qcdxkm8250.sys+0x262904`：`ldrh w8, [x19]`。
- 崩溃时寄存器：**X19=0xc、X20=0、X21=0xc**。
- 即：读 `[0xc]` 这个近空地址，页错误 → `0xC0000005`。

`0x262904` 在一个包遍历函数 `0x2628e0` 里，`x19` 是它要遍历的 `ACPI_EVAL_OUTPUT_BUFFER`
的 `Argument[0]` 指针。`Argument[0] = 缓冲区 + 0xc`（头是 Signature/Length/Count 各 4 字节
=0xc）。X19=0xc 说明**缓冲区指针本身是 0**，`0 + 0xc = 0xc`。

## 2. 调用链与那个致命的“复用”分支

崩溃函数（`0x2628e0`）由解析器 `0x262c70` 调用（`0x262d5c: bl 0x2628e0`）。`0x262c70`
是一个“按反斜杠分段的配置路径解析器”：

1. `0x262ca4`：`bl 0x2629f0` 把输入路径（`x22`）按 `\`（0x5c）切出第一段，写到栈 `sp+8`。
   `0x2629f0` 是个 `\` 分隔的分词器（跳过前导 `\`，取到下一个 `\` 或结尾，最多 0x80 字节）。
2. `0x262cc0`：`ldr x8,[0x14a318]` → **`RtlCompareMemory`**（已解析 IAT 确认），
   `blr x8(sp+8, devctx+0x10, 4)`：把这一段的前 4 字节和**上次缓存在 `devctx+0x10` 的名字**比。
3. `0x262cdc`：`cmp x0,#4; b.eq 0x262d20`——**4 字节全等就跳过重新求值，直接复用缓存**。
4. 走到 `0x262d28`：`ldr x8,[x19,#0x38]`（取 `field_38`），`x21 = field_38 + 0xc`，交给
   `0x262d5c: bl 0x2628e0` 遍历。

关键在第 3 步：匹配就复用 `field_38`，**但从不检查 `field_38` 是不是 NULL**。

## 3. 名字被缓存、但缓冲区没被填上

填充 `field_38` 的是 `0x262ac0`，只在第 2 步“不匹配”的回落路径里被调用；而**名字是在调用填充
之前就先写进 `devctx+0x10` 的**（`0x262d0c: bl 0x1334c8` 拷 4 字节名字）。填充函数 `0x262ac0`：

- `0x262af8: bl 0x25e000` 用一个签名为 **`"EvEx"`**（`0x78457645`）的求值器求值，
  入参缓冲是 `ACPI_EVAL_INPUT_BUFFER_COMPLEX` 形态，池标记 `"qDXB"`/`"qDX4"`。
- 返回 `STATUS_SUCCESS`（0）或 `STATUS_BUFFER_OVERFLOW`（`0x80000005`，=`0x262c60`）时才
  分配并写 `field_38`（`devctx+0x38`）。
- 返回**其它错误**（例如对象不存在 → 既不是成功也不是 overflow）时：`0x262b0c: b.ne 0x262c44`
  直接带错误码返回，`field_38` 保持 NULL。

于是毒化序列是：

| 次序 | 发生的事 | `devctx+0x10`(名字) | `field_38` | 结果 |
|---|---|---|---|---|
| 第一次解析名字 X | `EvEx` 求值失败（对象缺失，非 overflow） | 已写成 X | NULL | 解析器返回错误，**不崩** |
| 第二次解析名字 X | `RtlCompareMemory` 命中 → 走复用分支 | X | 仍 NULL | `ldr [field_38]`=0 → `0+0xc` → **崩** |

所以崩溃是一个**缓存一致性 bug**：名字先于填充成功被缓存，第一次求值失败后缓存里留下
“名字有效但缓冲为空”的状态；第二次同名请求信任缓存、复用了空指针。X19=0xc 正好对上。

## 4. 触发物：dagu 的 GPU 节点缺了一个配置对象

`0x262c70` 恒定不被静态调用（全二进制里 `0x262c70` 只作为 `.pdata` 的函数入口出现一次，
`0x1c7948`），说明它是运行时注册的回调——高通的“配置路径解析”回调。被解析的路径里有现成的格式串
**`"DCVS\%s"`**（RVA `0x343b88`）和 **`"%s\%s"`**（RVA `0x342858`），还有一个裸的 4 字节
`"DCVS"` 标签（RVA `0x343970`，上下文 `DCVS\0\0\0\0Targ…`）。`DCVS` 正好 4 字节，与
`RtlCompareMemory(...,4)` 对得上。

也就是说：qcdx 在绑定时去解析 `DCVS\<子项>` 这类 GPU 动态调频（Dynamic Clock Voltage
Scaling）配置；**dagu 移植的 GPU0 节点没有提供这个配置对象**，第一次 `EvEx` 求值失败→名字被
缓存→同名再查→空指针崩溃。真机 WoA SM8250 的 GPU 节点（或高通属性库）会提供它，我们从 MTP
裁出来的最小 GPU0 节点没有。

> 注意：`EvEx`/`qDXB` 不是标准 Windows ACPI IOCTL 签名，`0x25e000` 末尾调用的 `[0x14a590]`
> 也不在导入表里（紧挨 IAT 之后，运行时填的内部函数指针）。所以这层“求值”更像高通**自建的属性库**
> 包装，底层数据源（ACPI `_DSM`/包、还是注册表/INF）尚未坐实——INF 里 grep 不到 `DCVS`，倾向
> ACPI 侧。这一点**未验证**，是下一步要做实的。

## 5. 结论：两道墙都还在

- **qcdx 空指针**（本阶段）：根因是高通驱动的缓存复用 bug + dagu 缺 `DCVS` GPU 配置对象。
  候选修复是给 `graphics-qcom253a.asl` 的 GPU0 节点补上 qcdx 期望的 `DCVS` 配置（方法/包），
  让首次求值成功、`field_38` 被填上，绕过空指针路径。**待验证**。
- **SMMU/QHEE 墙**（阶段 14）：即便 qcdx 不再崩，下一步 `qcsmmu` 一编程 Adreno SMMU 就被
  QHEE 复位整颗 SoC，这是 stock HyperOS 固件上的硬墙。所以 WDDM GPU 加速在当前固件下仍被卡在
  SMMU 层。

因此，就“让 Windows 跑得流畅”这个目标，目前最实在、已交付的收益仍是阶段 13 的大核调频修复
（A77 ~3 倍，已验证）；WDDM GPU 这条路两道墙都需要固件侧（QHEE/TZ）配合才可能走通。

## 6. 下一步（按成本从低到高）

1. 坐实 `DCVS` 的数据源：逆 `0x25e000` 末尾 `[0x14a590]` 与 `devctx+0x10` 的来源，确认是 ACPI
   还是注册表；若 ACPI，给 GPU0 补 `DCVS` 方法/包，重建覆盖表、运行时拉起 qcdx 验证是否过崩溃点。
2. 即便过了崩溃点，仍要面对阶段 14 的 SMMU/QHEE 复位墙——需要 UEFI 侧把 Adreno SMMU 配成 GPU
   流旁路（阶段 14 §7 路线 2），工作量大且 UEFI 侧已知“写 GR0 不生效/被规格化”（阶段 14、v8 探针）。
3. 维持现状：显示走 BasicDisplay，交付大核调频收益。

## 7. 速查坐标（qcdx RE）

| 项 | RVA | 说明 |
|---|---|---|
| 崩溃指令 | `0x262904` | `ldrh w8,[x19]`，x19=0xc |
| 包遍历函数 | `0x2628e0` | 遍历 `Argument[0]` |
| 配置路径解析器（回调） | `0x262c70` | `\` 分段 + 缓存复用分支 |
| 复用判定 | `0x262cdc` | `cmp x0,#4; b.eq 0x262d20` |
| `RtlCompareMemory` IAT | `0x14a318` | ntoskrnl 导入 |
| `field_38` 填充函数 | `0x262ac0` | 求值 + 分配 |
| `EvEx` 求值器 | `0x25e000` | 签名 `"EvEx"`，池标记 `"qDXB"` |
| 分词器（按 `\`） | `0x2629f0` | 跳 `\`、取段、≤0x80 |
| `"DCVS\%s"` 格式串 | `0x343b88` | 构造配置路径 |
| 裸 `"DCVS"` 标签 | `0x343970` | 4 字节方法名 |
| 关键状态码 | — | `0x80000005` overflow / `0xc0000017` 资源不足 / `0xc000003a` 路径不存在 |

工具：`tools/winarm/qdis.py`（本阶段入库）、`tools/winarm/dagu-dump-triage.py`（阶段 11）。

### 关联文档
[stage11（崩溃定位）](woa-dagu-gpu-stage11-2026-10-31.md)、
[stage13（CX 上电+大核调频）](woa-dagu-gpu-stage13-2026-10-31.md)、
[stage14（SMMU/QHEE 复位墙）](woa-dagu-gpu-stage14-2026-10-31.md)、
[roadmap](woa-dagu-gpu-roadmap.md)。
