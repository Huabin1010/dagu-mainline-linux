# dagu Windows GPU：阶段 23（拿到 Linux 对 Adreno SMMU 的真实配置：CB0 走 TTBR1 拆分页表）（2026-11-10）

本阶段的目标是照 Linux 的做法补齐 Windows 缺的那三块里的第一块：SMMU。做法改成读 Linux
**驱动自己**维护的结构，不碰硬件寄存器。结果拿到了 GPU 上下文（CB0）的完整配置，并确认它和
Windows 侧垫片现在的做法差在哪。

---

## 1. 方法：用 kprobe 读驱动内部状态，不读寄存器

- 上一轮直接在 Linux 用户态用 `/dev/mem` 映射 `0x03DA0000` 只读，把整机总线卡死（网络、串口
  全无响应，需人工进 fastboot）。**这条路作废**：SMMU 有运行时电源管理，空闲时读它会挂总线。
- 改成 `bpftrace` 的 kprobe：只在内核函数被调用时读它自己的结构体，不产生任何 SMMU 寄存器访问。
- 运行内核没有开 `CONFIG_FUNCTION_TRACER`，`available_filter_functions` 不存在，bpftrace 需要
  `--traceable-functions <文件>` 显式给出符号才能挂上。
- 触发方式：`echo 3d00000.gpu > /sys/bus/platform/drivers/adreno/unbind`，让 GPU 的 domain 走一次
  `arm_smmu_destroy_domain_context`，其中会调用 `arm_smmu_write_context_bank`。

## 2. 拿到的真实配置（Adreno SMMU `0x03DA0000`，Linux 7.0）

```text
WRITE ioaddr=0x3da0000 idx=0 ttbr0=0 ttbr1=0x1047bf000 tcr0=0xb5100080 tcr1=0 mair0=0xf404ff44 mair1=0
WRITE ioaddr=0x3da0000 idx=1 ttbr0=0x10001017b8000 ttbr1=0x1000000000000 tcr0=0x803510 tcr1=0 mair0=0xf404ff44 mair1=0
WRITE ioaddr=0x3da0000 idx=2..4 ttbr0=0 ttbr1=0 tcr0=0 tcr1=0 mair0=0 mair1=0        （未分配，SCTLR=0）
```

**CB0 是 GPU 的上下文，它用的是 TTBR1 拆分页表**：

| 字段 | 值 | 含义 |
|---|---|---|
| `ttbr0` | `0` | 低半地址空间不用 |
| `ttbr1` | `0x1047bf000` | 页表基址（Linux 现分配，每次启动不同） |
| `tcr0` | `0xb5100080` | `T0SZ=0`、`EPD0=1`（TTBR0 关闭）；`T1SZ=16` → **48 位 VA**；`TG1=2` → 4 KB 页；`IRGN1/ORGN1=WBWA`；`SH1=inner shareable` |
| `tcr1` | `0` | 见下方更正 |
| `mair0` | `0xf404ff44` | Linux 的标准 MAIR 表 |

> **更正（阶段 24）**：`tcr1=0` 和 `mair1=0` 是读法造成的假象，不是 Linux 写进硬件的值。kprobe 打在
> `arm_smmu_write_context_bank` 上、由 unbind 触发，走的是 destroy 路径。`struct arm_smmu_cb` 是按
> `0x28` 字节、`u32 tcr[2]` 手算偏移读的，`$cb+2` 是 `uint64*` 运算，`*(uint32*)($cb+2)>>32` 对 32 位值
> 右移 32 永远是 0。按源码 `arm_smmu_init_context_bank()` + `arm_smmu_lpae_tcr2()`，36 位 IPA 时
> `TCR2 = PASIZE(1) | SEP(7) | AS = 0x00038011`。阶段 24 写测用的是这个值。

配合 `/sys/kernel/debug/dri/0/gpu` 里 GPU 的 IOVA（`0x0001000000001000` 这类高位地址）可以确认：
**Linux 给 GPU 的地址空间落在 TTBR1 覆盖的高半区，不是 Windows 垫片假设的低地址窗口。**

对照 Linux 源码 `arm-smmu.c::arm_smmu_write_context_bank()` 与
`arm-smmu-qcom.c::qcom_adreno_smmu_init_context()`：GPU 走
`IO_PGTABLE_QUIRK_ARM_TTBR1` 拆分页表，CB0 固定分给 GPU（`qcom_adreno_smmu_alloc_context_bank`
里 `start=0, count=1`），SCTLR 由 `qcom_adreno_smmu_write_sctlr()` 追加 `HUPCF`。

## 3. 这决定了 Windows 垫片的改法

现在的 `ProgramGpuStream()` 只做三件事：`S2CR[0]=translate→CB0`、`SMR[0]=valid,ID=0`、可选写
`CB0.TTBR0`。缺的是**页表本身和 TTBR1 那一半**，所以槽 20 只能返回假地址。

要按 Linux 的做法补齐，垫片需要：

1. **IOVA 分配器**：在 TTBR1 覆盖的高半区分配 IOVA，而不是现在返回的假区间对象。
2. **真实页表**：在非分页内存里建 AArch64 4 KB 页表，把 qcdx 要映射的物理页写进 PTE，
   把表基址写进 `CB0.TTBR1`。
3. **CB0 其余寄存器**：`TCR`（`tcr0=0xb5100080` 这一组语义）、`MAIR0`、`SCTLR`（含 `HUPCF`）、
   `CBAR`（stage-1 translate）。
4. **IOTLB 失效**：`TLBIALLNSNH` + `TLBGSYNC`（阶段 18 已验证可写、不复位）。

阶段 18 已逐条验证过 SMR（真 SID）、S2CR（translate）、CB0.TTBR0、CBAR、sCR0、sCR2、TLB
同步都能从 Windows 写进去且不复位；**`CB0.TTBR1` / `CB0.TCR` / `CB0.MAIR0` / `CB0.SCTLR`
还没单独测过**，是下一步上板前要先补的四项写测（用现成的 `dagu-smmuwt` 逐个加 test 号）。

## 4. 本轮的事故记录（避免重犯）

| 动作 | 后果 | 教训 |
|---|---|---|
| 用户态 `/dev/mem` 映射 `0x03DA0000` 只读 | 总线卡死，整机失联 | SMMU 空闲时被运行时电源管理关掉，读它会挂总线。只能通过内核驱动访问 |
| `echo 3d00000.gpu > .../adreno/unbind` 后 bind 失败（`-28 ENOSPC`） | 显示子系统绑不上 GPU，随后 `systemctl reboot` 后系统卡在启动（sshd 监听但不出 banner） | 不要在运行中的 GNOME 会话里解绑 GPU。要拿配置应改在驱动里加一次性日志，或接受从启动日志里抓 |

## 5. 下一步

1. 平板恢复后，先用 `dagu-smmuwt` 补测 `CB0.TTBR1/TCR/MAIR0/SCTLR` 四项写是否需要（阶段 18 的方法）。
   → 已做成阶段 24 的 `test=100`，见 [阶段 24](woa-dagu-gpu-stage24-2026-11-10.md)。
2. 四项都放行后，按 §3 在垫片里实现页表和 IOVA 分配，槽 20 返回真实 IOVA。
3. 再进 zap / GMU 和显示模式两块（见 [适配计划](woa-dagu-gpu-adaptation-plan-2026-11-10.md)）。

### 关联文档

[适配计划](woa-dagu-gpu-adaptation-plan-2026-11-10.md)、[阶段 18（写测）](woa-dagu-gpu-stage18-2026-10-31.md)、
[阶段 19](woa-dagu-gpu-stage19-2026-10-31.md)、[阶段 22](woa-dagu-gpu-stage22-2026-11-08.md)。
