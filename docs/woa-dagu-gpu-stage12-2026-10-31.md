# dagu Windows GPU 适配：阶段 12（G1 卡在转圈 → 根因、救回、两处修正）（2026-10-31）

## 1. 现象

阶段 11 之后做 Test G1：覆盖表 = 固件 DSDT + GPU0(RESI/ENGS/TMDT) + **只有 MMU1**
（Adreno SMMU，`QCOM2509 _UID 1`，`0x03DA0000`），`QCDX Start=4`（GPU 驱动不加载）。
重启后 Windows 停在启动转圈界面，30 分钟以上不动、不蓝屏、不复位，A 槽不会自动回落。

## 2. 救回过程

1. 用户按电源+音量下进 fastboot（`18d1:d00d`），主机 `fb-usb.py set-active b` + `reboot`，
   15 秒后 B 槽 Linux 上线（`192.168.1.68`）。
2. 离线读证据：ntbtlog 最后一段只有 132 行（正常 165 行）、没有 `qcsmmu`/`qcdx` 行、
   没有新 dump。卡在启动中段，日志没来得及刷盘。
3. 离线修复（hive 备份在平板 Linux `/root/SYSTEM.bak-*`）：
   - `dagu-rescue.sh rm-dsdt`：删除覆盖表（`SM8250_` 下子键清空）。
   - `QCDX Start=4`（本来就是 4）。
   - **新增保险：`qcsmmu Start=4`**（6 个值全部写回，读回核对一致）。
4. `to-win` 切回 A 槽，Windows 约 30 秒后上线（ping 通、sshd 在 22 端口应答）。

## 3. 根因：任何 QCOM2509 节点都会让 qcsmmu 在启动时卡死总线

两次卡死的共同点只有一个：DSDT 里出现了 `QCOM2509`。

| 测试 | SMMU 节点 | 结果 |
|---|---|---|
| 阶段 10 Step A | MMU0 + MMU1 | 启动日志落盘前硬卡死 |
| 阶段 11 Test G / GP | 无 | 正常开机（GPU 运行时拉起才 0x3B） |
| 阶段 12 Test G1 | 只有 MMU1 | 启动转圈硬卡死 |

`qcsmmu8250.inf` 绑 `ACPI\VEN_QCOM&DEV_2509`，服务是 `Class=System` 的 PnP 驱动，设备一
枚举就在启动阶段加载。`qcsmmu8250.sys` 导入表里只有 `MmMapIoSpaceEx`、`PoFx*` 等，**没有 SMC/HVC
指令**（全部代码节扫描为 0），也就是说它直接读写 SMMU 寄存器、不经过 TZ/QHEE。字符串显示它在
`Init()` 里读 `MaxCB`/`MaxSMRS`，再 `PopulateXBLEntries()`、`SmmuInitHardware()` 重编 SMR/S2CR。

- **MMU0（APPS SMMU `0x15000000`）**：dagu 没有 IORT，UFS 等的 DMA 靠 QHEE 留下的旁路流直通。
  qcsmmu 重编 SMR/S2CR 会破坏启动盘 DMA，或者访问被 QHEE 截获。
- **MMU1（Adreno SMMU `0x03DA0000`）**：地址对（原厂 DT `kgsl-smmu@3da0000`），但这个块挂在
  GPU CX 电源域下（原厂 DT `gdsc@3d9106c`/`gdsc@3d9100c`，主线 `power-domains = <&gpucc GPU_CX_GDSC>`）
  并需要 GPU_CC AHB 时钟。Windows 下没有 PEP、UEFI 也没给 GPU 上电，访问未上电/未开时钟的
  寄存器块在高通 SoC 上表现为总线不应答——CPU 停住、看门狗交接时已关、不蓝屏不复位，
  完全对应"一直转圈"。

结论：**在 Windows 能把 GPU_CX_GDSC + GPU_CC 时钟打开之前，不能给 DSDT 加任何 `QCOM2509` 节点。**

## 4. 修正一：GPU0 `_CRS` 里三段地址是 SM8250 的错地址

查原厂 DT（`port/dagu/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb`）和 B 槽 Linux 的
`/proc/iomem`：

| RESI 名 | 参考板 BBUF | dagu 原厂 DT | 判定 |
|---|---|---|---|
| MDP_REGS | 0x0AE00000 | mdss_mdp@ae00000 | ✓ |
| VSYNC_INTERRUPT | 0x73 | SPI 0x53 (+32=0x73) | ✓ |
| **GFX_REGS** | **0x02C00000** | **kgsl-3d0@3d00000** | ✗ SM8150 地址 |
| **GFX_REG_CONT** | **0x02C60000** | cx_dbgc 0x3d61000、gmu@3d6a000 | ✗ SM8150 地址 |
| GFX_INTERRUPT | 0x14C | SPI 0x12c (+32=0x14C) | ✓ |
| GPU_PDC_SEQ_MEM / REGS | 0x0B290000 / 0x0B490000 | gmu pdc 0xb290000 / 0xb490000 | ✓ |
| **GPU_CC** | **0x02C90000** | **gpucc@3d90000** | ✗ SM8150 地址 |
| GPU_RPMH_CPRF | 0x0C200000 | 原厂 DT 无对应节点 | 未核实，保留 |
| VIDEO_REGS | 0x0AA00000 | vidc@aa00000 | ✓ |

原厂 DT 在 `0x02C00000..0x02D00000` 范围内**没有任何设备**。`0x02C00000`/`0x02C90000` 正是主线
SM8150 的 `gpu@2c00000`/`gpucc@2c90000`。所以 Aloha 的 "qcom-mtp8250" DSDT（以及 qrd8250）的
GPU0 资源是从 SM8150 抄过来没改的。qcdxkm8250 按 `RESI` 名字取 `GFX_REGS`/`GPU_CC` 去 map，
等于在读写一段悬空总线地址。这可能也和阶段 4 的无 dump 卡死、阶段 11 的 0x3B 有关（读回垃圾值后
算出的结构指针无效），但这两条**没有验证**。

已改 `graphics-qcom253a.asl`：`0x02C00000→0x03D00000`、`0x02C60000→0x03D60000`、
`0x02C90000→0x03D90000`，长度和顺序不动（RESI 按顺序配名字）。离线 iasl 0 error 0 warning，
编译产物里不再有 `0x02Cxxxxx`。

同样的 SM8150 地址也在 UEFI 内存映射里：`winarm/overlay/xiaomi-dagu/.../PlatformMemoryMapLib.c`
的 `GPU_GMU_CX_BLK 0x02C7D000`、`GPU_CC 0x02C90000`（所有 Kona 设备目录都是同一份）。这只影响
UEFI 自己的映射表，本阶段没动固件。

## 5. 修正二：工具层面的防呆

- `build-gpu-overlay.py`：带 `--smmu` 时直接拒绝，除非显式加 `--allow-boot-hang`。
- `dagu-rescue.sh disable-qcsmmu`：离线把 `qcsmmu Start=4`（全量写回 6 个值并备份 hive）。
  设备上已经执行过同样的修改。

## 6. 现状与遗留

- Windows 正常开机：覆盖表已删、`QCDX=4`、`qcsmmu=4`。
- **主机到 Windows 的 SSH 密钥丢了**：主机重启后 `/tmp/dagu-agent.sock` 里那把
  `huanghuabin06@gmail.com (ED25519)` 私钥随 agent 一起消失，磁盘上只有它的公钥。
  需要用户重新把那把私钥加回 agent，或者让平板再进一次 fastboot，由 B 槽 Linux 离线把
  主机的 `id_rsa.pub` 追加到 `C:\ProgramData\ssh\administrators_authorized_keys`（追加不改 ACL）。
- GPU 下一步的真正前置条件：**UEFI 侧打开 GPU_CX_GDSC（0x3D9106C）+ GPU_CC AHB 时钟**，
  否则 qcdx/qcsmmu 一碰 GPU 寄存器块就会卡总线。之后再用修正后的地址做 Test GP。
