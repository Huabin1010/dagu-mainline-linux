# dagu Windows GPU：阶段 27（PMIPower=0 之后仍是 0x124：日志、调用上下文与尚未到达的路径）（2026-11-11）

本文记录 17:45 黑屏之后的离线分析：在确认 ECD901FA 新覆盖表已经加载、qcdx 解析到 `PMIPower*=0` 的前提下，追查为何仍然出现 `0x124`。分析只使用本机已有转储输出、`qcdxkm8250.sys` 和项目里现成的反汇编工具，没有再操作平板、没有重新挂盘、没有部署。

时间均为北京时间（Asia/Shanghai）。

---

## 1. 结论先行

- 17:45:05 仍是 WHEA `0x124`（P1=`0x12`，综合症 `0xBE000411`，类 `0x2F` SError）。转储在 `pagefile.sys`，没有拷到 `MEMORY.DMP`。
- 新表已经加载，且 qcdx 按新配置解析：`PMIPowerPmicModel/Num/Config` 均为 0。打开 qcpmic 三个接口的代码没有走到。这一段修复是成立的。
- **ERR `0x6e6` 不是新根因，也不是致命返回。** 它在 17:31（旧表）和 17:45（新表）里都有。含义是：显示初始化里类型为 2 的分支上，一份 16 槽列表全为空，`0xAEC68` 返回非 0，记一条错然后继续往下走。
- **SError 落点 `qcdx+0x2D0430` 不能当成故障访存。** 这是一个 112 字节的释放函数入口（`ExFreePoolWithTag` 风格，池标签 `qDx3`），用来释放显示对象 `+0x7A0` / `+0x7B0` 上的两块池内存。异步 SError 在函数第一指令处被记下，说明出错的访问发生在进入释放之前，在某个调用者里。
- `BacklightPmic*` 默认值 2/2 仍在解析结果里，但打开 qcpmic 接口的函数 `0xD9570` / `0xD8D20` / `0xD84D8` **只有** `0xADC00` 这一处调用者。17:45 没有 `0x261` 等后续日志，说明没有走进 `0xADC00` 的接口体。背光小端口 `Miniport\BACKLIGHT`（`0xB0018` / `0xB6548`）在 `0x6e6` 之前就被 `0xAC9C0` 调用过，走的是注册表，不经过那三个接口；两次转储都没有 `0x6B4` / `0x6BE`。
- **GPU RSCC（`0x2AC3C0`，缺项时回退到 `GFX_REG_CONT+0x2D000` → `0x3D8D000`）这次没有到达。** 该函数没有静态 `bl` 调用者，两次转储都没有回退警告 `0x339`。不能把阶段 26 写下的 RSCC 地址问题当成 17:45 的已证原因。显示侧 `MDSS_RSCC_REGS` 的 ACPI 资源查找（`0xD5D48`）在两次启动里都已经跑过（它在 `0x226` 之前），成功与否日志里看不出来，也没有写死的回退地址。
- 现有证据还不能离线定位那一次真正的寄存器访问，因此本阶段没有改 PCFG、没有补 PMIC 节点、没有启用 qcpep、没有改底层寄存器，也没有部署诊断补丁。下面给出一个可回滚的面包屑方案，供下次实机验证时使用。

---

## 2. 证据从哪里来（可复现）

对象：

- 转储：17:45 用 `pagefile.sys`（SystemTime 17:45:05.677，`bugcheck=0x124`，P2=`0xffffa30e55acf688`，页表基址 `0x194b52000`）；17:31 用 `MEMORY.DMP`（17:31:16.361，P2=`0xffffb509d8cdb078`）。分析输出已保存在本机 `tmp/evidence-20261111-1745/dagu-dump-compare.out`、`dagu-whea-1745.out`。
- 驱动：`tmp/gpu-1110/pkg/qcdx/qcdxkm8250.sys`，与 `winarm/drivers/windows_qcom_platforms/components/QC8250/Drivers/Graphics/DXKM/qcdxkm8250.sys` 相同，SHA256 `ff4846e4533708e4…`。
- 工具：`tools/winarm/qdis.py`（需设置 `QDIS_PE` 为上面的路径；脚本默认路径 `winarm/drivers/QC8250/...` 在本树不存在）、已有全量反汇编 `/tmp/qall.txt`（11-10）、函数表与调用图 `/tmp/qx.pkl`（由 `/tmp/qx.py` 生成，函数起始表在 PE `.pdata`，文件偏移 `0x1C4000`）。

本机复盘命令示例（不接触设备）：

```bash
export QDIS_PE=$PWD/tmp/gpu-1110/pkg/qcdx/qcdxkm8250.sys
python3 tools/winarm/qdis.py 0xaee10 0xaf0e0   # 记 0x6e6 的函数
python3 tools/winarm/qdis.py 0xaec68 0xaee10   # 0x6e6 的判定
python3 tools/winarm/qdis.py 0xadc00 0xadea0   # PMIPower 门
python3 tools/winarm/qdis.py 0x2d0430 0x2d04a0 # SError 落点（释放函数）
```

调用关系用 `/tmp/qx.pkl` 的 `calls` / `callees` 查询；函数指针表在 `.rdata`（例如 `0x14C728`、`0x14C858`）。

取证副本不要当成全部完整：本机 `tmp/evidence-20261111-1745/overlay-00000004.aml` 曾是 0 字节，不能当证据；可用 `ov-gpu0.aml` 或 `overlay-00000004.from31.aml`（SHA256 开头 `ecd901fa633ba007`）。本机 `SYSTEM` 在写本文时仍可能在从 10.88.0.31 拷贝中；31 上 `/tmp/dagu-evidence-20261111-1745/SYSTEM.recovered.restored` 是完整回放结果。pagefile / MEMORY.DMP 没有整包拉回。

---

## 3. `0x6e6` 的含义和分支

记录位置：`qcdx+0xAF084`，也就是 `bl 0x10920`（ERR 环）的返回地址。事件号在 `0xAF07C`：`mov w0, #0x6e6`，参数 `0xCA..0xCE`，与两份转储一致。

所在函数是 `0xAEE10`（720 字节），**只被显示初始化 `0xAC9C0` 调用**（调用点 `0xAD0CC`）。它先按一张类型表 `0x191F60` 取出类型：

- 类型 == 2：走 `0xAEF00`。这里会对照白名单 `0x190250` 过滤一份最多 16 项的列表，做一次 0x44 字节的拷贝/计数/排序，然后调用 `0xAEC68`。**`0x6e6` 只出现在这条分支。** 17:31 和 17:45 都记了 `0x6e6`，所以两次都走了类型 2。
- 类型 == 3：先调 `0xAEC68`，可能再走一个回调，把一个标志写成 2。
- 其它：直接返回。

`0xAEC68` 的返回值：

- 入参 `x0 == 0`：记 ERR `0x644`，返回 2。两次转储都没有 `0x644`，所以入参不是空指针。
- 入参非空，但 `x0+0x48` 起 16 个字全为 0（计数写在 `x0+0x44` 为 0）：返回 3。
- 计数非 0：排序后返回 0。

`0xAEE10` 在类型 2 分支里：`bl 0xAEC68` 之后 `cbz w0, #0xAF084`——返回 0 就跳过日志；非 0 才记 `0x6e6`。记完之后函数**并不返回失败**，而是根据列表是否仍为空写一个 1/2 状态，然后正常 `ret`。`0xAC9C0` 在这之后还会调用 `0xD7778`、`0xD9A98`、`0xAF0E0`、`0xD9E10` 等，最后才到 `0xADC00`。

因此：`0x6e6` 表示「类型 2 这条路上，那份 16 槽列表是空的」。两次启动都是这样，不能解释为什么 17:45 在去掉 PMIPower 之后仍然 `0x124`。

（附近反汇编注释里出现过 “Did you call RpeInit()?”，那是字符串收集把 RPE 断言文案沾到了邻近函数上。`0xAEC68` 的正文里没有调用 RPE，也没有打出那条断言。）

---

## 4. `0xAC9C0` 里和这次日志对应的顺序

显示初始化 `0xAC9C0` 只被 `0x301A0` 调用，再往上是 `QDIDriverEntry` 一侧的小端口启动。与两份 qcdx 日志对得上的顺序是：

| 顺序 | 调用点 | 函数 | 日志 | 17:31 | 17:45 |
|---|---|---|---|---|---|
| 早 | `0xACB3C` | `0xD5D48` 按名查找 MDP/DSI/MDSS_RSCC 等 ACPI 资源 | 无 | 已执行（后面还有 `0x226`） | 同左 |
| | `0xACC50` | `0xD3D38` 读 `UEFIDisplayInfo` | ERR `0x226` | 有 | 有 |
| | （经 `0xE3AB8` 等） | 解析 `_ROM` / PCFG | WRN `0xA08`×6 | 有 | 有（此时已解析出 PMIPower） |
| | `0xACD04` | `0xB0018` `Miniport\BACKLIGHT` | 失败才会有 `0x6B4`/`0x6BE` | 无这两条 | 无这两条 |
| | `0xACF6C` | `0xAB230` | WRN `0x102`/`0x10B` | 有 | 有 |
| | `0xAD0CC` | `0xAEE10` | ERR `0x6e6` | 有 | 有（17:45 的最后一条） |
| 中 | 若干无日志调用 | `0xD7778`、`0xD9A98`、`0xAF0E0`、`0xD9E10` 等 | 无 | 静默通过（因为后面到了 `0xADC00`） | 未知：可能通过，也可能就死在这里 |
| | `0xAD30C` | `0xADC00` PMIPower 门 | 非 0 型号才会有 `0x261`/`0x271`/`0x276` 和 `0x82`/`0x33D`… | 有整串 | **没有**（早退或没走进来） |
| 后 | `0xAD42C` | 若某标志 bit 17 置位则 `0xB1C98` | 无（失败路径的 `0x191`/`0x189` 等两次都没有） | 可能调用 | 若已走过 `0xADC00`，则同样可能 |

`0xAD2FC` 的 ERR `0x19D` 只在 `w19 != 0` 时打出，并且会**跳过** `0xADC00`。两次都没有 `0x19D`，所以 17:31 必然走了 `0xADC00`。17:45 若执行到这里，也会走进 `0xADC00`，然后因型号为 0（或 `+0xF00` bit 16 清零）从 `0xADC40` / `0xADCF4` 返回 0，不打 `0x261`。这与「PMIPower 修复生效」一致，但不能 100% 排除 17:45 死在 `0x6e6` 与 `0xADC00` 之间的静默函数里——17:31 同样经过这些函数且没有日志，所以更可能是走进了 `0xADC00` 并早退，然后在后面的 `0xB1C98` 或更后面的函数指针回调里出问题。

---

## 5. `0xADC00` 的门，以及 BacklightPmic 有没有被拿去开接口

`0xADC00`（调用者：`0xAC9C0` 和另一条 `0x354A8`）开头：

1. 读面板对象 `+0xF00`，bit 16 为 0 则直接返回 0（`0xADCF4`）。
2. 否则读 `+0x5C`（型号）。`0xADC40`：`cbz w1, #0xADCEC`——型号为 0 则把 `+0x60` 写成 0 并返回 0。这就是阶段 26 说的「型号为 0 则在 `0xADC40` 返回」。
3. 只有型号非 0 且能在表 `0x193FD0` 里命中，才会调用 `0xD9570`（开接口，失败记 `0x261`/`0x271`/`0x276`）和 `0xD8D20`（后续电源请求，失败记 `0x33D`/`0x34D`/…）。

`0xD9570`、`0xD8D20`、`0xD84D8` 的静态调用者只有 `0xADC00`。17:45 没有这些日志，说明接口体没有执行。

`BacklightType=2`、`BacklightPmicControlType=2`、以及 panel 脚本读到的 `BacklightPmicModel/Num=2` 仍是默认值，两次一样。它们**没有**再走上述接口函数。`0xB0018` / `0xB6548` 读的是注册表 `Miniport\BACKLIGHT`，而且在 `0x6e6` 之前就已经调用过；两次都没有对应的失败日志。因此不能把「默认 BacklightPmic 值还在」理解成「17:45 又去开了 qcpmic 接口」。这些默认值以后会不会在别的路径上被用到，现有转储还不能排除，但不是这次已经看到的 `0x82` 链。

---

## 6. `qcdx+0x2D0430` 的真实上下文

函数从 `0x2D0430` 到 `0x2D04A0`，第一句就是 `stp x19, x20, [sp, #-0x10]!`。正文：

- 若对象 `+0x7A0` 非空，通过 IAT 槽 `0x14A528`（INIT 段存根，典型内核导入，参数为指针 + 立即数 `0x33784471`，ASCII `qDx3`）释放，然后清零；
- 对 `+0x7B0` 做同样的事；
- 清 `+0x7A8`、`+0x794`，返回。

这就是阶段 26 说的「释放资源的收尾」。SError 记在**函数入口**，不是记在那两次 `blr` 释放上。异步错误的访问发生在 `bl 0x2D0430` 之前。

三个静态调用者：

| 函数 | 谁调用它 | 在做什么 |
|---|---|---|
| `0x2CA710` | `0x2C9EB0`（字符串 `WriteEDIDToReg` / `PanelEdid` / `Display`；自身没有 `bl` 调用者，函数指针在 `.rdata 0x14C858`） | 先释放 `+0x538`，再 `bl 0x2D0430`，然后继续拆 `+0x698` 等。这是显示/EDID 侧的拆除。 |
| `0x2CEAD0` | 无静态 `bl`；函数指针在 `.rdata 0x14C728` 一张显示相关虚表里 | `w20==0` 时直接 `bl 0x2D0430` 做清理；`w20!=0` 时走 `0x2D0128`。 |
| `0x2D0128` | 由 `0x2CEAD0` 调用 | 一进来先 `bl 0x2D0430` 释放旧块，再重新分配 `+0x7B0` 等；失败时再次释放。 |

它们都不在 `0xAC9C0` 的直接 callee 里，而是后来通过函数指针走进来的显示对象状态切换/拆除。这与「显示初始化失败之后的收尾」相符，仍然**不能**指出失败前最后一次 MMIO。

`0xAC9C0` 本身也不调用 `0x2D0430`。

---

## 7. RSCC：这次有没有走到

分两路，不要混：

**GPU / GMU RSCC（阶段 26 写的 `0x3D8D000` vs `0x3DE0000`）**

- 处理函数是 `0x2AC3C0`（字符串 `GPU_RSCC`、`GFX_REG_CONT`、`GFX_REGS`、`GPU_CC` 等）。缺 `GPU_RSCC` 时在 `0x2AC61C` 用 `GFX_REG_CONT + 0x2D000` 推地址，并打 WRN `0x339`。
- 没有静态 `bl` 调用者。`.rdata 0x14B130` 里是函数范围对（`0x2AC3C0..0x2ACCE0`），不是调用点。
- 17:31 和 17:45 的 qcdx 日志都没有 `0x339`。

结论：这一路**没有执行到**。不能用它解释 17:45 的 `0x124`。

**显示 MDSS RSCC**

- `0xD5D48`（只被 `0xAC9C0` 在 `0xACB3C` 调用）按名字对照 ACPI 资源：`MDP_REGS`、`MIPI_DSI_REGS`、`HDMI_REGS`、`SE_CTRL_REGS`、`MMSS_MISC_REGS`、`DP_PHYMODE_REGS`、`DP_PHY_REGS`、`MDSS_RSCC_REGS`、`USB4_HOST_ROUTER_REGS`。找到就写入 `0x21F5A0` 附近的基址槽，找不到就试下一个，**没有写死的回退地址，也没有单独的失败日志**。
- 两次启动都执行了这个查找（它在 `0x226` 之前）。某项是否命中，现有日志看不出来；本轮按授权没有重新挂盘去读转储里的基址槽。

---

## 8. 现有面包屑能排除什么，还缺什么

已经能排除或降权的：

- 「新表没加载 / qcdx 仍按 PMIPower=0x1E 去开 qcpmic 接口」——内存 DSDT 头、解析字段、以及 17:45 缺失的 `0x261`/`0x82` 链，三者一致。
- 「`0x6e6` 是 17:45 新出现的致命错」——17:31 同样有，且函数随后正常返回。
- 「SError 地址就是出错的那条访存」——地址是释放函数入口。
- 「GPU RSCC 错误基址已经在这次被碰到」——没有 `0x339`，函数没有被静态调用到。
- 「BacklightPmic 默认值再次打开了那三个 qcpmic 接口」——那三个函数只有 `0xADC00` 会调，17:45 没进接口体。

还不能离线确定的：

- 17:45 是否一定走过了 `0xADC00` 的早退（还是死在它前面的静默函数）。
- `0xB1C98` 以及 `WriteEDIDToReg` / `0x2CEAD0` 在 17:45 有没有真正执行、执行到哪一句。
- 显示侧 `MDP_REGS` / `MIPI_DSI_REGS` / `MDSS_RSCC_REGS` 是否都从 ACPI 拿到了正确基址。
- 那一次导致 SError 的 MMIO 是什么。

因此没有足够依据做「改 PCFG / 改寄存器 / 补节点」这种修复，也没有在本阶段改源码或部署。

---

## 9. 最小可回滚的诊断变更（先报告，不部署）

沿用阶段 26 已经提出、但还没做的办法：在 qcdx 显示初始化后半段和 `0x2D0430` 的调用点加**调用点面包屑**（把几处 `bl` 改成「先记下站点再跳回」的跳板），下次 `0x124` 的转储里读最后进入的函数。推荐记在现有垫片 `dagu-smmushim` 的参数区（或一块转储里能读到的已知槽），这样不必再发明新的通信路径。回滚方式：不要安装新垫片，或改回上一份已签名的垫片包。

建议记录的站点（都是本次已经对上号的 RVA，不是盲打点）：

1. `0xAEE10` 返回之后、`0xADC00` 进入/返回、`0xB1C98` 进入/返回、`0xAC9C0` 返回。
2. 函数指针回调 `0x2C9EB0`（`WriteEDIDToReg`）、`0x2CA710`、`0x2CEAD0`、`0x2D0128` 的进入，以及各自 `bl 0x2D0430` 的前一条指令。
3. 可选：`0xD5D48` 查完后，把写入 `0x21F5A0` 附近的 `MDP_REGS` / `MIPI_DSI_REGS` / `MDSS_RSCC_REGS` 基址一并记下来（只读记录，不改基址）。

预期区分：

- 最后停在 `0x6e6` 之后、`0xADC00` 之前：17:45 死在中间那些静默函数，需要再拆 `0xD7778` / `0xD9E10` / `0xAF0E0`。
- 进入并离开了 `0xADC00`，死在 `0xB1C98`：焦点转到显示启动的后半段。
- 最后是 `0x2C9EB0` / `0x2CA710`：EDID 写寄存器或其拆除。
- 最后是 `0x2CEAD0` / `0x2D0128`、尚未完成 `0x2D0430`：状态切换/重分配路径，看 `0x2D0430` 之前的工作。
- 若出现 `0x339` 或 GPU RSCC 站点：再回头处理 `0x3D8D000` / `0x3DE0000`。
- 基址记录若显示某块 ACPI 资源缺失或明显不对：再考虑只补显示资源，而不是补 PMIC 节点。

在用户明确批准部署之前，不装到 A 槽，不重启进 Windows。

一致性预检（开机已加载覆盖表 vs 注册表存储表）和更可靠的 `gpu-run.txt` 刷新仍然值得做，但**修不了这次 0x124**，而且预检必须在实际 Windows 上才能证实加载表；离线 SYSTEM 不能冒充已加载 ACPI。本阶段为避免用辅助脚本代替根因调查，没有改 `gpu.ps1`。

---

## 10. 本阶段没有做的事

- 没有再切槽、重启、挂盘、刷写或部署。
- 没有改 PCFG、没有补 `QCOM250C` / `QCOM252E`、没有启用 qcpep、没有盲改寄存器。
- 没有提交、没有推送。工作区在写入本文 §1–§10 之前是干净的 `main` @ `0aa50c0`。
- 同日稍后（北京时间约 18:40–18:50）按既有记录机制做了**离线诊断源码与构建**，见 §11。仍然没有部署到平板。

---

## 11. 复用既有方法后的补充取证，以及离线诊断构建（2026-11-11 18:50，北京时间）

本节是对用户「继续定位、参考之前怎么做的」的落实：先回读已验证的垫片记录通道和转储脚本，再从已在 31 上的完整副本提取注册表，而不是再挂盘或再拷一份 pagefile。诊断代码明确不是根因修复，也没有装到平板。

### 11.1 复用了哪些已经验证过的方法

- **调用环 / 最后调用点**：`dagu-smmushim.c` 里已有 `gLastSite` / `gNcall` / `gRing` / `gSiteRing` / `WriteDiag` / `RecordStatus` / `LogThunk`。注册表只每 16 次调用或失败钩子才 `ZwFlushKey`；可靠的落盘通道是 `\SystemRoot\dagu-shim.bin`（`DIAG_MAGIC 'DDAG'`）。`0x124` 是 WHEA SError，通常**走不到** StartDevice 失败尾的 `RecordStatus`，所以注册表里的 `ncall=0` / `fsite=0` **不能**证明内存里的环也是空的。
- **从转储读垫片全局量**：`/tmp/shimdump.py`（11-11 14:47）。用 `dagu-dump-triage.py` 的 `Dump.module("dagu-smmushim.sys")` + RVA。把 14:52 的 `dagu-smmushim.obj` 用原链接选项加 `/MAP` 重链后，1.0.5.0 的 RVA 与这份脚本一致（`gNcall=0x130ec`、`gLastSite=0x130d0`、`gLogRing=0x11020`、`gSiteRing=0x11060`、`gRing=0x133e0`、`gLogInstall=0x130f8`、`gQcdxBase=0x131a0`）。**不要**把这张表直接套到 1.0.3.0 / 1.0.4.0 上；先对转储里的 `.text` 做摘要比对。
- **从转储恢复调用栈 / 返回地址**：`/tmp/trapf.py` 在 bugcheck `CONTEXT` 的栈页里搜 ELR。`0x124` 的 header CONTEXT 是 `ntoskrnl!KeBugCheck`，不是 SError 现场，所以还要在已存在的转储页里搜 `qcdx+0x2D0430` 以及四个 `bl 0x2D0430` 的返回地址。WHEA 12 字节段只有 synd+addr，没有额外 CPU 上下文。
- **KDNET**：`docs/woa-dagu-kdnet-eem-2026-11-08.md` 是另一条实机调试路径，本轮没有启用（不需要为了读已有转储去改调试器）。
- **注册表**：31 上完整的 `SYSTEM`（11 534 336，SHA256 `5589457f9b8ae4…`）和 `SYSTEM.recovered` 用已有 `hivexget` 读出，没有再开一条竞争 scp。`SYSTEM.recovered.restored` 的头hivex 打不开，但 `SYSTEM.recovered` 可以；与未回放的 `SYSTEM` 相比，`dagusmmu\Parameters` **206 个值全部相同**。

### 11.2 新证据支持或排除什么

从已取回、且校验过的远端副本里还能确定：

- 17:45 转储里垫片已加载：`dagu-smmushim.sys` 基址 `0xfffff80039140000`，`SizeOfImage=0x16000`（与 1.0.3 / 1.0.4 / 1.0.5 都相符，**单凭大小不能定版本**）。qcdx 基址 `0xfffff80037c00000`，WHEA 地址 `0xfffff80037ed0430` = qcdx+`0x2D0430`。
- 回放前后的垫片参数一致：`bootgen=2`，`step=0x30`，`rstonfail=1`，`map=0`，`ncall=0`，`fail=0`，`fsite=0`，`qpatch=0`，`loginst=0`，`logseen=0`，`hist*=0`，`io_maps=0`。这与 17:44:58 `2-run` 在 `restart-device` **之前**打出来的快照一致，说明 **17:45 的 SError 没有走到失败钩，也没有 FlushRing**。它**不能**排除 LogHook 已在内存里装上，也**不能**说明 `0xADC00` / `0x2D0430` 的调用关系。
- `C:\Windows\dagu-shim.bin` 在 31 和本机证据目录里都没有副本；上次只读挂载时没拷这个文件。
- 新的反汇编（同一份 `qcdxkm8250.sys`，SHA256 `ff4846e4…`）找到 **四处** 直接 `bl 0x2D0430`，都在 `PAGE` 段：`0x2CA8E0`（函数 `0x2CA710` 内，返回 `0x2CA8E4`）、`0x2CEB8C`、`0x2D0148`，以及先前没单独点名的 `0x2D03A0`。`0xADC00` 的静态调用点是 `0xAD30C`（显示路径附近）和 `0x355FC`（另一处）。`0xD5D48` 由 `0xACB3C` 调用（就在 `0xAC9C0` 里）；返回值在 `w0`，可以区分查找成功/失败。这些是调用关系，**不是** 17:45 已证实的执行轨迹。
- 仍不能根据现有副本认定故障访存是 RSCC 或 Backlight；GPU RSCC 日志 `0x339` 在 17:45 仍然没有。

本机 18:12 开始的那条 scp（PID 1068507）在 18:50 仍在传输 `SYSTEM`（本机当时 10 444 800 / 11 534 336）。没有另开竞争拷贝，也没有把未传完的本地 `SYSTEM` 当证据。31 上的完整哈希见上。`overlay-00000004.aml` 本地 0 字节仍不是证据，以 `overlay-00000004.from31.aml` / 31 上那份为准（SHA256 `ecd901fa…`）。

### 11.3 仍缺的页和只读取证方式

原始 `pagefile.sys` 没有整包传回，平板 Windows 盘保持卸载。要用历史方法读垫片环或搜返回地址，缺的是这些（都在 17:45 转储的地址空间里）：

- 转储本身：`C:\pagefile.sys`，`dirbase=0x194b52000`。
- 垫片映像 22 页：`0xfffff80039140000`–`0xfffff80039155fff`。其中数据页最要紧：`gLogRing` 所在 `0xfffff80039151000`，`gNcall` / `gLogInstall` / `gRing` 在 `0xfffff80039153000`。先读头页并对 `.text` 做摘要，才能在 1.0.3/1.0.4/1.0.5 里选对 RVA。
- 指针搜索（在**已存在的转储页**里搜，缺页要记下来，不要编造命中）：`0xfffff80037ed0430`（WHEA PC）、`0xfffff80037eca8e4` / `0xfffff80037eceb90` / `0xfffff80037ed014c` / `0xfffff80037ed03a4`（四个 free 返回地址）、以及已经解析过的 WHEA 记录 `0xffffa30e55acf688`（没有更多 CPU 上下文）。
- 文件：`C:\Windows\dagu-shim.bin`；`DriverStore\FileRepository\dagu-smmushim.inf_arm64_72b10ae4f0d341cc\dagu-smmushim.sys` 的 SHA256（17:30 的 1-install 只带了新覆盖表，**不能假定** 14:52 的 1.0.5.0 已经装上）。

只需一次**只读、不回放日志**的挂载（`ntfs-3g -o ro`，不要 `ntfsfix`），在平板上跑 `tools/winarm/dagu-shim-dumpwalk.py --dump /mnt/w/pagefile.sys`，并拷出 `dagu-shim.bin` 和 DriverStore 里那份 `.sys`。本轮没有擅自再挂载。

离线可读脚本已写好并通过自测：`tools/winarm/dagu-shim-dumpwalk.py --self-test`（区分三个垫片 `.text` 摘要，解析 DIAG v2/v3，打印上述缺页清单）。

### 11.4 诊断源码、测试和构建（未部署）

在已验证的 `WriteQcdx` +「先核对 `bl` 编码再改跳转」机制上，加了 **PathThunk**（普通 AAPCS 包装：记下进入、调用原目标、记下返回值，不改控制流）。八个站点都是本节对上的编码：

| id | `bl` 站点 | 原目标 | 能区分什么 |
|----|-----------|--------|------------|
| 1 | `0x301D4` | `0xAC9C0` | 是否进入/离开显示初始化 |
| 2 | `0xAD30C` | `0xADC00` | 显示路径是否调用了 PMIPower 门，返回值是什么 |
| 3 | `0x355FC` | `0xADC00` | 另一处静态调用是否发生 |
| 4 | `0xACB3C` | `0xD5D48` | 资源查找的 `w0`（命中/失败） |
| 5–8 | `0x2CA8E0` / `0x2CEB8C` / `0x2D0148` / `0x2D03A0` | `0x2D0430` | 哪个拆除路径进来的；若只有 ENTER 没有 LEAVE，SError 发生在 free 体内 |

`0xADC00` 的两条早退路径开头没有合适的 `bl`，没有去改第一条 `stp`（那不属于已验证机制）。四个 free 站点在 `PAGE` 段：安装时若页不在，对应 `PathInstall` 位保持 0，qcdx 原指令不动。

`DIAG_REC` 升到 v3（前 304 字节与 v2 兼容），写入同一份 `dagu-shim.bin`。INF 版本改为 `1.0.6.0`。注释写明这是诊断测量，不是修复。

测试与构建（全部在本机已有工具链上，没有装大依赖、没有扩权限、没有云端）：

- `cc -O1 -Wall -Wextra tests/test_diag.c`：3/3 通过（结构体大小 568、v3 往返、嵌套 enter/leave）。
- 已有 `tests/test_iommu.c`：23/23 通过。
- `dagu-shim-dumpwalk.py --self-test`：0 失败。
- `port/dagu/windows-drivers/dagu-smmushim/build.sh`（clang-cl + lld-link + 已有 `sign-driver.sh`）：成功。签名后 `tmp/shim-build/dagu-smmushim.sys` 67248 字节，SHA256 `62ed28f6e8efa455…`，证书表 VA `0xfa00` size 3248。未跑 `build.sh install`，未更新 `tmp/step7-deploy`。1.0.5.0 包仍在 `tmp/fix-1111d/pkg/shim/`（`5d5f9ca3…`）。

完整性 / 签名风险：ARM64 内核驱动必须测试签名，设备已是 `testsigning=on` 并信任仓库测试根证书 `EB968A1A…`。未签名的 `.sys` 会静默不能加载。即使签了名，换垫片仍会换 DriverStore 目录，需要一次批准后的安装；回滚是装回 `5d5f9ca3` 那一份。本轮**没有**部署、切槽、重启或改注册表。平板保持 B 槽，Windows 分区未挂载。没有提交、没有推送。

### 11.5 下一轮最小实验（先批准再部署或再只读挂盘）

两个互不替代、可单独做的步骤：

**A. 只读挂盘，不再改驱动。** 预期：若 1.0.5.0 且 LogHook 已装上，转储里 `gLogInstall=1`、`gLogRing` 应能看到 `0x6e6`；`ncall`/`gRing` 仍可能为 0（显示路径未必走过 SMMU 槽）。指针搜索若命中某个 `bl 0x2D0430` 返回地址，就能指出 17:45 的拆除调用者；若四个返回地址都找不到、只在 WHEA 段里看到 `+0x2D0430`，仍然不能指定调用者。`dagu-shim.bin` 若没有 17:45 那条记录，与「RecordStatus 没跑起来」一致，不是矛盾。

**B. 在批准后安装 1.0.6.0 诊断垫片，再复现一次 0x124（仍不改 PCFG / 寄存器 / PMIC 节点）。** 用转储数据页或 `dagu-shim.bin` 读 Path 环，区分：

- 没有 id 1 的 LEAVE：死在 `0xAC9C0` 体内。再看 id 2/4 有没有 ENTER/LEAVE。
- id 2 从未出现、id 1 已 LEAVE：PMIPower 门不是这条显示路径上的下一步，焦点转到 `0xAC9C0` 返回之后。
- id 4 的 `PathRet` 非 0（典型 `0xC0000001`）或为 0：资源查找失败 vs 成功；成功仍 0x124 则不是「没拿到 MDSS 基址」这一条。
- 只有 id 5–8 之一 ENTER、没有 LEAVE：与「SError 落在 `0x2D0430` 体内」相符，并指出是哪一个调用者。
- 若出现 `0x339` 或 GPU RSCC 站点：再回头看 `0x3D8D000`；本诊断包没有在那些点插桩。

在用户明确批准之前，不装 1.0.6.0，不进 A 槽，不重启。
