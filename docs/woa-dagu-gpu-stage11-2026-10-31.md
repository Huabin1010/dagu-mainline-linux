# dagu Windows GPU 适配：阶段 11（运行时拉起 GPU + 首个崩溃 dump 精确定位）（2026-10-31）

阶段 10 的 Step A 带 `MMU0` 在启动日志落盘前就硬卡死（疑 APPS SMMU 断了启动盘）。本阶段
换了一个**可远程回滚**的测法，第一次拿到 GPU 驱动的真实崩溃 dump，并把崩溃点精确定位到
`qcdxkm8250.sys` 内的一条指令。

## 1. 可远程测试的方法：运行时拉起，不在启动时加载

用户不在平板旁，所以不能用"开机加载 GPU 驱动"的测法（启动期真卡死不一定复位、够不到）。
改成：

1. 覆盖表照装，但 `QCDX Start=4`（禁用）——这正是阶段 4 验证过能正常进系统的配置。
2. 进系统、SSH 可达后，用计划任务以 SYSTEM 跑 `gpu-rt.ps1`：设 `Start=3`、
   `pnputil /restart-device ACPI\QCOM253A\0` 拉起驱动，驱动镜像一加载就把 `Start` 写回 4
   并 flush。
3. 这样崩溃/复位后下次开机回到 `Start=4` 安全态；即便 PnP 线程卡住，系统主体还活着能远程处置。

实测这条路是**全自动可恢复**的：Test G 崩溃后平板自己复位、A 槽重试计数耗尽、落回 B 槽
Linux，我在主机侧经 Wi-Fi 登录 B 槽 Linux 离线改注册表（`disable-qcdx` + `rm-dsdt`）再
`to-win`，全程没碰平板。

## 2. Test G：GPU0(RESI/ENGS/TMDT，无 PMCL、无 SMMU)

覆盖表 = 固件 DSDT + `Scope(\_SB){ GPU0(RESI/ENGS/TMDT) }`，**不带 MMU0/MMU1**，9276 字节
（`build-gpu-overlay.py` 生成，固件区字节 0 改动、SOSI 8 字节 QWord、无 PEP0）。
`QCDX Start=4` 开机 → 正常进系统（证明不带 SMMU 时覆盖表不破坏启动）；运行时拉起 GPU →
约 1 秒内崩溃，`gpu-rt.log` 停在 `pnputil /restart-device` 之后一行没有。

和前面对比：

| 测试 | 内容 | 结果 |
|---|---|---|
| 阶段 4 | GPU0（无 ENGS） | 晚期卡死，ntbtlog 末条 `qcdxkm8250.sys`，**无 dump** |
| 阶段 10 Step A | GPU0+ENGS+**MMU0/MMU1** | 启动日志落盘前硬卡死，**无 dump**（SMMU 断盘） |
| 阶段 11 Test G | GPU0+ENGS，**无 SMMU** | **蓝屏 0x3B，有完整 dump**（盘没断，崩溃能写盘） |

ENGS 让驱动过了阶段 8 的门控、走进 WDDM 初始化，然后在那里崩。去掉 SMMU 让盘活着，于是
第一次拿到了可分析的 dump。

## 3. dump 精确定位（无 WinDbg）

平板的 dump 是 `PAGEDU64` 外层 + `SDMPDUMP` 位图内核 dump，stage-2 的 triage.py（针对
triage minidump）不适用。本阶段写了 `tools/winarm/dagu-dump-triage.py`：解析位图把物理页
映射回文件、做 ARM64 4 级 4KB 页表翻译、遍历 `PsLoadedModuleList`、读崩溃 `CONTEXT`、
并在给定驱动镜像里反汇编崩溃指令。

结论：

```
BugCheck 0x3B SYSTEM_SERVICE_EXCEPTION, P1=0xC0000005 (ACCESS_VIOLATION)
Pc = qcdxkm8250.sys+0x262904
Lr = qcdxkm8250.sys+0x262d60
调用链（全是 qcdxkm8250 帧，从 dxgkrnl 的 WDDM start DDI 下来）：
  +0x262d60 -> +0x1311f4 -> +0x27039c/+0x2703f8 -> +0x26e414 -> +0x29383c ...
相邻帧引用的字符串：DxKMD Miniport 注册表项（MaxPreemptionOffsets /
  DriverManagesResidency / LeafPTPacking / EnableIndependentFlip ...）、
  \REGR\%s、\REGISTRY\MACHINE\Software\QCOM\Drivers\DxKMD
```

崩溃函数 `0x2628e0` 是一个"包遍历器"：

```asm
0x2628f8: mov  x19, x1          ; arg1 = 某结构指针
0x262900: cbz  x19, #end        ; arg1==NULL 则优雅返回
0x262904: ldrh w8, [x19]        ; <<< 崩溃：arg1 非 NULL 但指向未映射内存
0x262908: cmp  w8, #3           ; 期望首元素 == 3
```

调用方把 `arg1 = [devctx+0x38] + 0xc` 传进来。也就是说 `devctx->field_38` 这个指针**非
NULL 但无效**（+0xc 落在未映射区）。简单"缺某个 ACPI 方法"会得到 NULL、被 `cbz` 兜住、
不会崩；得到非 NULL 无效指针，说明某个**本应被填好的结构没填对**。

## 4. 下一步假设：缺 PMCL

`ldrh [x19]; cmp #3` 里的 `3` 是首元素标签。我们的 `RESI`/`ENGS`/`PMCL` 三张包的首元素
**都是 `0x03`**。`RESI`/`ENGS` 在 Test G 里都在；唯独 **`PMCL` 不在**（Test G 用的是阶段 8
版本）。若这个遍历器读的是电源/部件（PMCL）数据，而 PMCL 缺席导致 `field_38` 没被正确
初始化成指向 PMCL 解析结果的指针，就正好是"非 NULL 无效指针"。

因此下一个板测是 **Test GP = GPU0(RESI/ENGS/TMDT/PMCL/_HRV，仍无 SMMU)**：
- 若崩溃点变化/更靠后/能起来 → PMCL 是关键，继续往"步骤 C 点屏"推进。
- 若仍崩在 `+0x262904` → PMCL 不是主因，回去查 `field_38` 由谁写、来自哪张 ACPI 表。

`MMU0`（APPS SMMU）在找到保留 UFS 旁路的办法前仍然不放进覆盖表；`MMU1`（Adreno SMMU）
UFS 不在其后，可作为后续单独变量。

## 5. 本阶段改动/产物

- `tools/winarm/dagu-dump-triage.py`：ARM64 `SDMPDUMP` 内核 dump 分诊器（新增）。
- `docs/woa-dagu-gpu-stage11-2026-10-31.md`：本文件。
- `docs/woa-dagu-gpu-roadmap.md`：§4 决策树补 Test G 结果与 Test GP。
- 设备：已离线回滚（`QCDX Start=4`、覆盖表删除），崩溃 dump 已取回主机
  （`/tmp/dagu/MEMORY.DMP`，483MB，不入库）。
