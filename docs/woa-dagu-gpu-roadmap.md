# dagu Windows GPU 适配路线图（截至阶段 9，2026-10-31）

这份文档把散在 `woa-dagu-gpu-stage0..9` 里的东西收拢成一张地图：**现在到哪了、
看别人（参考板）看出来啥、怎么适配、下一步怎么走**。细节仍以各阶段文档为准，这里只给
主线和决策树。活文档，随进度更新。

---

## 1. 现在到哪一步了

### 1.1 阶段进度一句话

| 阶段 | 做了什么 | 结果 |
|---|---|---|
| 0 | 验证 live DSDT 覆盖表机制（测试设备 `DAGU0FFF` 能枚举），建 qcdx 依赖表 | 机制通；顺手修好一次 BCD 事故 |
| 1 | 第一版 PEP0（`QCOM2519`） | qcpep `CORE_VERIFY` 直接 `KeBugCheckEx(0x14B)`；发现 STND 名字是反着读的 |
| 2 | 写 minidump triage 解析器；定位 `0x1A` | 根因=iasl 把 `SOSI` 编码成 4 字节 DWord；全仓 INF 扫描→**只有 `QCOM253A` 有驱动**；据此建 `graphics-qcom253a.asl` |
| 3 | 逆 qcpep 参数表 | 发现 `pep0.asl` 用的 `QCOM2430` 没有任何 INF 绑定 |
| 4 | **上板**：装 `QCOM253A` 覆盖表 + `qcdx8250.inf` | `QCOM253A` 枚举成 "Adreno 640"，但 Windows 启动**无 dump 卡死**，`ntbtlog` 末条是 `qcdxkm8250.sys` |
| 5 | PEP 实验 A/B/C | `0x101`/`0x1A` 反复；实验 C（清空 `_LPI`）在 PEP0 禁用时能启动 |
| 6 | 更正 qcpep 参数表特征号 | 设备上 `f8 EnableProcessorManagement=0` |
| 7 | 逆 PEP 处理器回调注册 | `f8=0` 时 LPI 门控路径根本不激活，实验 C 卡死仍未解释 |
| 8 | 逆 `qcdxkm8250.sys` 启动门控 | 找到 `GmuInternal`/`GpuInternal` 硬门控；补 `ENGS`/`RESI`/`TMDT`，启用 `smmu.asl`（`QCOM2509`） |
| 9 | 按参考板移植 `PMCL`/`_HRV`/`_IDT` | 离线 iasl 0 error；**板上未验证** |

### 1.2 当前设备状态（2026-10-31 实测，只读）

- A 槽 Windows 在线 `192.168.1.250`；正在用**纯固件 DSDT**（`HKLM\HARDWARE\ACPI\DSDT\
  QCOMM_\SM8250_\00000003`，4819 字节）。
- **live 覆盖表已不在**（`...\Services\ACPI\Parameters\DSDT\QCOMM_\SM8250_` 下无
  `00000004`）。所以 `QCOM253A`/`QCOM2519`/`DAGUB001` 全 `CM_PROB_PHANTOM`，`QCDX`
  `Start=4`，`Win32_Battery` 为空（**无低电量保护，长时间挂机留意电量**）。
- 部署链完好：test-signing 开、`C:\dagu\asl.exe` 在、qcdx 驱动（`oem80.inf`）已 staged。

### 1.3 源码现状：`graphics-qcom253a.asl` 的 GPU0 节点

已有：`_HID(QCOM253A)` `_IDT` `_CLS` `MON0` `_STA` `_CRS(BBUF)` `RESI` `ENGS` `TMDT`
`PMCL` `_HRV`。
还缺（相对参考板，见 §2.3）：`_ROM/PCFG`（面板）、`_DEP`、`_SUB`、`CHDV/AVS0`、
`DPCC/DPIN`、`REGR`、`_DOD`、一堆画质方法。
注意：此文件**只用于 live 覆盖表**，没进固件（`dsdt_common.asl` 里包的是 `graphics.asl`
的 `QCOM24B4`，两套互斥）。

---

## 2. 看别人（参考板）看出来啥

### 2.1 有效参考板只有一份

- `winarm/mu_aloha_platforms/.../Device/` 下 `qcom-mtp8250`、`xiaomi-umi`、`motorola-nio`
  的 `DSDT.aml` **逐字节相同**（umi/nio 直接抄 MTP），`qcom-qrd8250` 只差 `PSUB`。
- **`xiaomi-pipa`（小米平板6，和 dagu 最近的兄弟）的 `DSDT.aml` 是 0 字节**——这个
  checkout 里 pipa 没有 ACPI 可参考。所以 SM8250 的有效参考就是 **MTP 那份 DSDT**。
- 反汇编在 `qcom-mtp8250/ACPI/DSDT.dsl`（仓库自带，约 447 万字节）。GPU0 在第
  **68113–90235** 行。

### 2.2 方向性结论：只认"单体式" `QCOM253A`

全仓库 INF 扫描的硬结论：

- 真正存在的 GPU 驱动是 `winarm/drivers/QC8250/Drivers/Graphics/DXKM/qcdx8250.inf`，
  只绑 **`ACPI\VEN_QCOM&DEV_253A`**（及 `REV_xxxx` / `SUBSYS_MTP08250` 变体）。
- 这是高通 MTP 的**单体模型**：一个 `QCOM253A` 节点的 `_CRS` 里同时声明显示(MDSS
  `0x0AE00000`)、视频(Venus `0x0AA00000`)、GPU 时钟(GPU_CC `0x02C90000`)、GMU、GPU
  SMMU 的全部 MMIO。
- dagu 原来的 `graphics.asl`/`display.asl`/`venus.asl` 走的是"社区分离式"HID
  （`QCOM24B4` GPU、`QCOM24B9` GMU、`QCOM24B5` MDSS、`QCOM24B8` Venus…），**这些 HID
  没有任何 INF 绑定**，枚举出来也永远"无驱动"。要用仓库自带驱动，GPU 的 `_HID` 必须是
  `QCOM253A`。这条是整个 GPU 适配的地基。

### 2.3 参考板 GPU0 节点全貌（照着抄的清单）

| 成员 | DSDT.dsl 行 | 作用 | dagu 状态 |
|---|---|---|---|
| `_HID QCOM253A` / `_SUB` / `_IDT` | 68115–68117 | 绑定点 / 子 ID / 芯片 ID 别名 | `_HID`✓ `_IDT`✓ `_SUB`✗(缺 PSUB) |
| `_UID` / `_CLS` / `MON0` | 68118–68127 | — | ✓ |
| `_DEP`（10 项） | 68128–68140 | 依赖 MMU0/MMU1/IMM0/IMM1/PEP0/PMIC/PILC/RPEN/TREE/SCM0 | ✗（会悬空） |
| `_CRS`（ABUF/BBUF 按 SIDV 选） | 68141–68286 | 11 段 MMIO + 2 IRQ + 2 GPIO | ✓（固定 BBUF） |
| `RESI` | 68287 | 给 `_CRS` 各段资源命名 | ✓(阶段8) |
| `ENGS`（995 行） | 68517 | 引擎/页表表，**门控靠它** | ✓(阶段8) |
| `TMDT` | 69512 | 热域 | ✓(阶段8) |
| `PMCL`（9964 行） | 69538 | 电源/时钟部件模型 | ✓(阶段9) |
| `_ROM`（9924 行，PCFG..PCF5） | 79502 | **面板配置**（Sharp `LS060R1SX03` 2160x3840） | ✗ |
| 画质方法 PIGC/PPCC/PGCT/PLGC/HSIC/… | 89426+ | 画质/背光 | ✗ |
| `_HRV` | 89854 | 算 REV id | ✓(阶段9) |
| `CHDV`/`AVS0`/`DPCC`/`DPIN`/`REGR`/`_DOD`/`_LID` | 89889+ | 相机子设备/显示回调/寄存器覆写 | ✗ |

### 2.4 驱动初始化门控（阶段 8 逆向，最关键的一条）

`qcdxkm8250.sys`（sha256 `ff4846e4…0ed5`）的 `FUN_1402b4be0` 在初始化入口遍历一张命名
内存区表，必须同时找到：

- `GmuInternal`（缺→日志 `0xe5f`，失败返回）
- `GpuInternal`（缺→`0xe71`）
- 型号 `0x650001`/`0x65a001` 还要 `GmuCached`（缺→`0xe68`）

这些名字由 `FUN_14029b168` 从 ACPI `ENGS` 的 `PAGETABLEUSAGE` 翻译而来：
`GraphicsGlobalPT→GpuInternal`、`GraphicsGmuPT→GmuInternal/GmuCached`。**没有 `ENGS`
就一定过不了门控**——这是阶段 8 补 `ENGS` 的直接依据。

边界：门控失败是"打日志后干净返回"，不等于阶段 4 那种无 dump 硬卡死，两者关系未证实。

### 2.5 PMCL ↔ PEP 的对应

参考板 `GPU0.PMCL`（图形驱动读）的 12 个 `COMPONENT`，和 `PEP0` 里
`GPMD`→`G0MD..GLMD`（qcpep 读，第 3728–38609 行）的 12 个一一对应：PMCL 描述部件电源
状态，`G?MD` 给 qcpep 实际的板级电源资源（如 `mdss_core_gdsc`、`LDO5_A`、TLMM GPIO、
WLED——**这些是 MTP 板的值，照搬到 dagu 需要换成 dagu 的轨/脚**）。

### 2.6 依赖驱动栈（`_DEP` 的 10 个节点各绑谁）

| ACPI 设备 | HID | INF / 服务 | 启动 |
|---|---|---|---|
| PEP0 | QCOM2519 | qcpep.wd8250 / qcpep | boot(0) |
| MMU0/MMU1 | QCOM2509 | qcsmmu8250 / qcsmmu | demand(3) |
| IMM0/IMM1 | QCOM259B | qciommu8250 / qciommu | demand |
| PMIC | QCOM252E | qcpmic8250 | boot |
| PILC | QCOM251B | qcpil8250 | demand |
| RPEN | QCOM2533 | qcrpen8250 | demand |
| TREE | QCOM2576 | QcTrEE8250 | boot |
| SCM0 | QCOM250B | qcscm8250 | boot |
| ABD | QCOM2527 | qcabd | demand |

dagu 现在只有 `MMU0`/`MMU1`（阶段 8 对齐了 HID），其余节点都没有。所以恢复完整 `_DEP`
之前会悬空。

### 2.7 面板怎么喂给驱动

- **Windows 侧**：唯一通路是 `GPU0._ROM(offset, len, panelId)`，内含 6 份静态面板 XML
  （`PCFG..PCF5`，按 `Arg2` 选）。参考板里是 Sharp `LS060R1SX03`。
- **UEFI 侧**：各设备 `DXE.inc` 内嵌 `Panel_*.xml`，由高通 `DisplayDxe` 消费。
- **dagu 的真面板**：`L81A`（`dsi_display0=qcom,mdss_dsi_l81a_42_04_0a_dual_dphy_video`，
  见 `devices/dagu-hyperos-os2/extracted/cmdline.txt`）。它的 XML 已经在
  `xiaomi-pipa/Binaries/RawFiles/Panel_L81A_42_04_0a_dualdsi_dphy_lcd_vid.xml`
  （1600x2560、双 DSI、DSC、120Hz），但那是 **UEFI 方言**，要转成 `_ROM` 的 **Windows
  PCFG 方言**（多 `EDID Configuration`/`Detailed Timing` 组、Assertive Display 参数）。

### 2.8 固件 / zap

- `qcdx8250.inf` 带两个固件进 `System32`：`qcdxkmsuc8250.mbn`（14256 字节，ELF DSP6，
  **test-attestation 签名**）、`qcvss8250.mbn`（约 116 万字节）。
- 没有独立的 `a650_sqe`/`a650_gmu`/`a650_zap` 文件；微码看来编进了 KMD。
- 风险：零售小米设备**可能需要 OEM 签名的 zap**，现成的 test 签名未必过安全启动校验。未证实。

### 2.9 IORT 的坑（为什么被删）

MTP 的 IORT 把 `\_SB.UFS0`（启动盘）映射到 `0x15000000` 的 apps SMMU 后面，Windows 就要
qcsmmu+PEP 先起来启动盘才出现，否则 `0x7B`/`0xC0000034`。能启动 Windows 的 SM8250 手机
（alioth/lmi/elish）**都不出 IORT**。所以 `build-dagu-uefi.sh` 从 `ACPI.inc` 里删掉了
IORT 和 MCFG。

**更正（阶段 10 板测）**：原来这里写"启用 SMMU 设备本身不碰 UFS DMA"，不成立。没有 IORT
时 UFS 的直通靠 QHEE 留在 APPS SMMU（`0x15000000`）里的旁路流配置；`MMU0` 一枚举，
`qcsmmu8250.sys` 就会在早期加载并复位 SMMU，旁路很可能被清掉。阶段 10 带 `MMU0` 的 Step A
卡在启动日志落盘之前（ntbtlog 没有段落、无 dump），比阶段 4 更早。在找到让 qcsmmu 保留 UFS
旁路的办法前，**覆盖表里不要放 `MMU0`**。`MMU1`（Adreno SMMU `0x03DA0000`）UFS 不在后面，可以单独试。

---

## 3. 怎么适配（方法与机制）

### 3.1 两条注入路径

| | 固件 DSDT | live 覆盖表（实验用） |
|---|---|---|
| 怎么来 | `winarm/build-dagu-uefi.sh`，`DSDT_ONLY` 白名单（默认只 `ufs Pep_lpi gpio himax keyboard bluetooth`） | 手工拼 AML，`asl.exe /loadtable` 写注册表 |
| 改一次要 | 重新编 UEFI、刷 slot A boot | 只改注册表 + 重启 |
| GPU 用哪条 | 稳定后才进固件 | **先走覆盖表试**，快、可回滚 |

GPU 迭代一律走覆盖表；验证稳了再考虑进固件（届时还要补 `DSDT_ONLY` 白名单，且慎防
`DSDT_ONLY=all` 触发 `0xA5`）。

### 3.2 覆盖表制作流程（已工具化：`tools/winarm/build-gpu-overlay.py`）

**不要再手工拼表**——历史上手工流程反复把 `SOSI` 退化成 DWord（§3.3）、漏/多节点。
现在用 `build-gpu-overlay.py` 一条命令生成并自检：

```bash
# 先只读 dump 固件 DSDT（任何时候都安全）：
#   GetSystemFirmwareTable('ACPI','DSDT') -> base64 -> fw-base.aml
A=port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu
# 步骤 A（ENGS-only + SMMU，先测门控）：GPU0 取阶段 8 版本
git show f4797c8:$A/graphics-qcom253a.asl > /tmp/gpu0-stepA.asl
python3 tools/winarm/build-gpu-overlay.py --base fw-base.aml \
  --gpu /tmp/gpu0-stepA.asl --smmu $A/smmu.asl --out ov-stepA.aml
# 步骤 B（加 PMCL/_HRV）：GPU0 取当前版本
python3 tools/winarm/build-gpu-overlay.py --base fw-base.aml \
  --gpu $A/graphics-qcom253a.asl --smmu $A/smmu.asl --out ov-stepB.aml
```

工具的关键选择（为什么这样最稳）：

- **不反编译固件、只在 AML 层追加**。固件 DSDT 带 UEFI 回填的定宽占位符（15 字符
  `SIDS` 序列号），`iasl -d` 会把它反编译成 `Name(SIDS,"")` + 一串游离 `Zero`，
  **不能重新编译**（且会级联报假的 `\_SB.SIDV does not exist`）。所以工具把新节点单独
  编成 `Scope(\_SB){GPU0 [MMU0 MMU1]}`（用 `External` 引用芯片符号，不产生 AML），
  再把这段 `ScopeOp` **二进制追加**到 live 固件 AML 后面（多个 `\_SB` 作用域合法合并），
  只改外层 DSDT 长度 / OEM rev / 校验和。**固件区字节 0 改动**（已自检）。
- **SOSI 完全不碰**。live 固件 DSDT 里 SOSI 本就是正确的 8 字节 QWord
  `0x0000000080907228`（UEFI 回填过），追加法不动它，§3.3 的地雷在这条路径上消失。
- **不含 PEP0(QCOM2519)**，所以 Step A/B 不可能触发 qcpep 的 `0x1A`/`0x101`。
- 自检项：长度字段、校验和归零、rev≥4、SOSI 为 QWord、`QCOM253A`/`QCOM2509` 在、
  `QCOM2519` 不在、`ENGINES`/`GraphicsGmuPT`/`GraphicsGlobalPT` 在、`iasl -d` 能反汇编。

部署（**需本人在平板旁**，见 §3.5）：传 `ov-stepX.aml` 到 `C:\dagu\` →
`asl.exe /loadtable C:\dagu\ov-stepX.aml`（asl 自己切 `00000000/00000001/...` 注册表块）
→ `QCDX Start=3` → 重启。删：`asl.exe /loadtable /d`，或 `dagu-rescue.sh rm-dsdt`。

### 3.3 SOSI 地雷（反复踩）

`qcpep` 会读 `SOSI+5` 的 8 字节并 `MmMapIoSpaceEx(addr, 0xb0, 2)`。iasl 默认把
`SOSI` 编成 4 字节 DWord，读越界 → `0x1A MEMORY_MANAGEMENT`。**阶段 4 电池表、阶段 8 两个
候选表都把 SOSI 退化成 DWord 了**。规则：覆盖表里 `SOSI` 必须是 8 字节 QWord；PEP0 禁用时
不会立刻爆，但只要哪天启用 PEP0 就炸。每次拼表后务必按 AML 前缀字节核对宽度。

### 3.4 开关与注册表键

- 覆盖表：`HKLM\SYSTEM\CurrentControlSet\Services\ACPI\Parameters\DSDT\QCOMM_\SM8250_\
  00000004`（值 `00000000`/`00000001`）。
- GPU 服务：`...\Services\QCDX\Start`（0 boot /1 system /2 auto /3 demand /4 disabled）。
  GPU 测试设 **`Start=3`**。
- PEP0 设备：`...\Enum\ACPI\QCOM2519\2&daba3ff&0\ConfigFlags`（0 启用 / 1 禁用）。
- qcpep 参数：`...\Services\qcpep\Parameters`。

### 3.5 回滚 / 救援（动手前必读）

- **槽机制**：A=Windows UEFI，B=Linux。ABL 每次 A 启动递减重试计数，Windows 从不标记成功，
  计数到 0 自动切 B。
- **关键**：只有 A 启动以**复位**收尾（蓝屏自动重启、SoC 复位）才会自动落到 B。阶段 4 那种
  **无 dump 真卡死不会复位**（APSS 看门狗交接时是关的），**需要人工**按电源+音量下进
  fastboot，再 `fb-usb.py set-active b`。所以测 GPU 必须有人能够到平板。
- `dagu-rescue.sh` 子命令：`status` / `wait` / `rm-dsdt`（删整张覆盖表）/
  `set-pep N` / `disable-pep0` / `disable-qcdx`（`QCDX`→4）/ `to-win`（切 A 重启）/
  `auto`（落到 B 就删覆盖表并切回 A）/ `hive-run`。前提：平板能落到 B 槽 Linux 且 Wi-Fi/SSH 可达。
- `dagu-rescue.sh` 默认 `LINUX_IP` 会变，脚本靠 `dagu-find-linux.sh` 扫网段重定位。

### 3.6 部署前 readiness 检查

test-signing=On、`C:\dagu\asl.exe` 在、qcdx 驱动 staged、确认当前 `QCDX Start` 和 PEP0
`ConfigFlags`、确认有人能物理够到平板。（当前这些都满足，只差覆盖表没装。）

### 3.7 纪律：一次只变一项

每个阶段只改一处再上板，便于把现象归因到具体改动。不要一次把 ENGS+PMCL+面板+_DEP 全塞
进去测——阶段 0–8 全是这么一步步逼近的。

---

## 4. 接下来要咋办（决策树）

> 前提每一步都成立：平板能进 fastboot、`dagu-rescue.sh` 可用、有人在旁。
> 调试期只 `fastboot boot`，**不** `fastboot flash boot`。

```
【阶段 13】UEFI v5 在交给 Windows 前给 GPU CX 上电（Adreno SMMU IDR0=0x4C017E06 可读），并修好大核调频（A77 约 3 倍）。
【阶段 14】CX 上电后运行时拉起 qcsmmu（只 MMU1）→ 整机硬件级复位、无 dump，之后 A 槽重试耗尽落 B。
  Adreno 实例 INF 参数含 CP_PIXEL 安全上下文 CB1，疑为触发点（未验证）。见 stage14。
【阶段 12】Test G1（只有 MMU1）→ 启动转圈硬卡死。结论：任何 QCOM2509 都会让 qcsmmu 启动时卡总线，
  在 UEFI 给 GPU_CX_GDSC + GPU_CC 时钟上电前禁止加 SMMU 节点（设备上已 qcsmmu Start=4）。
  另发现 GPU0 _CRS 的 GFX_REGS/GFX_REG_CONT/GPU_CC 是 SM8150 的 0x02Cxxxxx，已改成 SM8250 的 0x03Dxxxxx。
  见 docs/woa-dagu-gpu-stage12-2026-10-31.md。
【阶段 10】Step A 带 MMU0/MMU1 → 启动日志落盘前硬卡死（qcsmmu 复位 APPS SMMU 断了 UFS）。
【阶段 11】Test G（GPU0+ENGS，无 SMMU，运行时拉起）→ 蓝屏 0x3B c0000005，首个可分析 dump。
  崩溃在 qcdxkm8250+0x262904，一个包遍历器 ldrh [devctx->field_38+0xc]（非 NULL 无效指针），
  在 WDDM init 的资源/DxKMD 注册表解析路径上。RESI/ENGS/PMCL 首元素都是 0x03，Test G 缺 PMCL。
  → 下一步 Test GP = GPU0 全量(含 PMCL/_HRV)，仍无 SMMU。
  见 docs/woa-dagu-gpu-stage11-2026-10-31.md（含可远程回滚的"运行时拉起"测法 + dump 分诊工具）。

步骤 A（= 阶段 8，最小步）
  覆盖表 = 固件DSDT + GPU0(ENGS/RESI/TMDT，不含PMCL)   ← 不再带 MMU0
  PEP0 禁用，QCDX Start=3，重启，盯屏幕/ntbtlog
  ├─ 过了门控、驱动完成初始化（dxgkrnl 加载、进桌面）→ 去 步骤 C
  ├─ 仍无 dump 卡死 / 卡在 qcdxkm8250.sys    → 去 步骤 B
  └─ 退回门控失败（0xe5f/0xe71 之类）        → 查 ENGS 拼写、PAGETABLEUSAGE 名字、
                                                SOSI 宽度、SIDV 是否仍是 0x00020000

步骤 B（= 阶段 9，加电源/时钟）
  在 A 的覆盖表里加 PMCL + _HRV（已在 graphics-qcom253a.asl 里）
  ├─ 起来了               → 去 步骤 C
  ├─ 卡在 Venus SMMU 接口 → 回阶段 8 §4：查 FUN_1403041a0 / FUN_14030d1a0 的调用者与
  │                          失败传播；评估是否需要真正的 qcsmmu 驱动起来
  └─ 仍卡在供电/时钟      → 可能需要 UEFI 侧先开 GPU_CC GDSC + 时钟，再 QCDX Start=3

步骤 C（面板点屏，驱动起来之后）
  把 L81A 的 UEFI 方言 XML 转成 Windows PCFG，填进 GPU0._ROM 的 PCFG
  （见 §2.7；参考 _ROM 的 Arg2 选择逻辑和 PCFG 结构）
  目标：内屏实际点亮、有加速输出

步骤 D（按需，最难）
  若上面证明确实需要 PEP/更多依赖：
  - 恢复 GPU0._DEP（先只加已存在的 MMU0/MMU1；IMM0/PILC/RPEN/TREE/SCM0 要先建节点）
  - 启用 PEP0(QCOM2519) + qcpep（历史上这里最容易 0x101/0x1A，见阶段 5–7）
  - 这步务必最后做、单独做
```

每步统一动作：**改一处 → 拼覆盖表(核对 SOSI) → `asl.exe /loadtable` → 设 `QCDX Start=3` →
重启 → 看屏幕帧缓冲/`ntbtlog.txt`/minidump → 不行就 `dagu-rescue.sh disable-qcdx` +
`rm-dsdt` 回滚**。

---

## 5. 未决的阻塞与假设

- **qcdx 卡死（阶段 4）**：`ntbtlog` 末条 `qcdxkm8250.sys`、`dxgkrnl` 未加载、无 dump。候选：
  (a) 缺 PEP 的 PoFx 响应——阶段 8 证明"打开 PEP 设备失败不致命"，此项权重降低；
  (b) GPU_CC/GX 未上电导致总线 hang（最像"无蓝屏卡死"）；
  (c) 没有 SMMU 驱动兑现 `ENGS` 里的 `ArmSmmuV2`；
  (d) `_DEP` 被裁；
  (e) `PMCL` 当时没移植（阶段 9 已补）；
  (f) 面板 blob 被裁（影响点屏不影响绑定）。
- **PEP**：`0x101`（多核轮流）、实验 C 无 dump 卡死仍未解释；`f8=0` 使 LPI 门控路径不激活。
  qcpep `CORE_VERIFY` 会 `0x14B`，无"仅记录"开关。
- **SOSI 退化**反复出现（见 §3.3）。
- **SMMU 无 IORT** 的组合板上未验证；带 MTP IORT 必 `0x7B`。
- **电量**：Windows 下充电器被识别成 SDP 限流 500mA，插着电也掉电约 1.1–1.5W（见
  [电池文档](woa-dagu-battery-2026-10-30.md) §8）；覆盖表没装时电池节点也不在，更要留意。

---

## 6. 关键坐标速查

| 项 | 值 |
|---|---|
| 参考 DSDT | `winarm/mu_aloha_platforms/Platforms/KonaPkg/Device/qcom-mtp8250/ACPI/DSDT.dsl`，GPU0 第 68113 行 |
| dagu GPU 源（覆盖表用） | `port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics-qcom253a.asl` |
| GPU 驱动 INF | `winarm/drivers/QC8250/Drivers/Graphics/DXKM/qcdx8250.inf`（绑 `ACPI\VEN_QCOM&DEV_253A`，Adreno650=`REV_0913`/`REV_0D15`→PAF） |
| KMD / 固件 | `qcdxkm8250.sys`、`qcdxkmsuc8250.mbn`(zap,test签名)、`qcvss8250.mbn` |
| dagu 面板 XML（UEFI 方言） | `.../xiaomi-pipa/Binaries/RawFiles/Panel_L81A_42_04_0a_dualdsi_dphy_lcd_vid.xml` |
| 门控函数 / 日志码 | `FUN_1402b4be0`；`0xe5f`(GmuInternal) `0xe68`(GmuCached) `0xe71`(GpuInternal) |
| qcdx 崩溃点 / 根因 | `+0x262904`(`ldrh [x19]`,x19=0xc)；配置解析器 `0x262c70` 缓存复用空 `field_38`（名字先于填充成功被缓存）→ 缺 `DCVS` GPU 配置对象，详见 [stage15](woa-dagu-gpu-stage15-2026-10-31.md) |
| qcdx RE 工具 | `tools/winarm/qdis.py`（RVA 反汇编+串解析）、`tools/winarm/dagu-dump-triage.py`（ARM64 转储） |
| 覆盖表注册表键 | `HKLM\SYSTEM\CurrentControlSet\Services\ACPI\Parameters\DSDT\QCOMM_\SM8250_\00000004`（值 `00000000`/`00000001`） |
| 正在用的表 | `HKLM\HARDWARE\ACPI\DSDT\QCOMM_\SM8250_\0000000X` |
| SOSI | 占位 `0xDEADBEEFFFFFFFFF`，回填 `0x0000000080907228` |
| 块切分 | 第一块 7168 字节（头 16 字节 + AML[0,7152)），第二块余下 |
| QCDX / PEP0 开关 | `Services\QCDX\Start`（测试=3）；`Enum\ACPI\QCOM2519\2&daba3ff&0\ConfigFlags`（0 启/1 禁） |
| 救援 | `tools/winarm/dagu-rescue.sh`（`disable-qcdx` / `rm-dsdt` / `to-win` / `auto`） |
| 设备值 | `SIDV=0x00020000`、`SOID=0x164`、`SVMJ=2` |
| 常见 bugcheck | `0x7B`(启动盘) `0xA5`(ACPI) `0x1A`(SOSI) `0x101`(PEP 时钟) `0x14B`(qcpep CORE_VERIFY) `0x1D5`(qcpep PnP) |

---

### 关联文档
阶段细节：[stage8（门控逆向）](woa-dagu-gpu-stage8-2026-10-30.md)、
[stage9（PMCL/_HRV）](woa-dagu-gpu-stage9-2026-10-31.md)、
[stage5–7（PEP）](woa-dagu-gpu-stage5-2026-10-30.md)、
[stage13（CX+大核调频）](woa-dagu-gpu-stage13-2026-10-31.md)、
[stage14（SMMU/QHEE 墙）](woa-dagu-gpu-stage14-2026-10-31.md)、
[stage15（qcdx 崩溃根因）](woa-dagu-gpu-stage15-2026-10-31.md)。
调试/救援：[debug handbook](dagu-woa-debug-handbook.md)。
