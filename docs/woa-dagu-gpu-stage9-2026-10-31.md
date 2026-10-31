# dagu Windows GPU 适配：阶段 9（移植 PMCL 电源/时钟模型与 _HRV）（2026-10-31）

阶段 8 逆向 `qcdxkm8250.sys`，查到启动门控 `FUN_1402b4be0` 必须找到 `GmuInternal`
和 `GpuInternal` 两块命名内存区（否则打 `0xe5f`/`0xe71` 失败返回），并据此给
`graphics-qcom253a.asl` 补上了 `RESI`/`ENGS`/`TMDT`、启用了 `smmu.asl`。阶段 8 当时
**没有**移植参考板的 `PMCL`（约一万行电源/时钟表），理由是"先验证能否越过门控"。

本阶段按同样的做法（从参考板逐字移植）把 `PMCL`、`_HRV`、`_IDT` 也补进 GPU 节点。
全程只改源码、只做离线 iasl 编译，**没有对平板写任何东西**。

## 0. 开工前的设备状态（重要：与阶段 8 的假设不一致）

阶段 8 文档写的是"live 覆盖表是阶段 5 实验 C 版本，电池正常"。本阶段开工前只读登录
A 槽 Windows（`192.168.1.250`）实测，发现 **live 覆盖表已经没了**：

| 项 | 实测值 |
|---|---|
| `...\ACPI\Parameters\DSDT\QCOMM_\SM8250_` 下覆盖子键 | 空（没有 `00000004`） |
| `HKLM\HARDWARE\ACPI\DSDT\QCOMM_\SM8250_` 正在用的表 | `00000003`（固件自带，4819 字节） |
| `QCOM253A` / `QCOM2519` / `DAGUB001` 设备 | 全部 `CM_PROB_PHANTOM`（未枚举） |
| `QCDX` 服务 | `Start=4`（禁用） |
| `Win32_Battery` | 空（电池节点没了，**没有低电量保护**） |
| test-signing | 开 |
| `C:\dagu\asl.exe`、qcdx 驱动（oem80.inf） | 都还在，部署链完好 |

谁、什么时候删的覆盖表不清楚（`dagu-rescue.sh rm-dsdt` 删完就是这样）。结论：现在
平板跑的是纯固件 DSDT，GPU/PEP0/电池都不在。要做板上 GPU 测试，得先把覆盖表重新装回去。
在此期间 Windows 读不到电量，插着电也会慢慢掉电（见
[电池文档](woa-dagu-battery-2026-10-30.md) §8），长时间挂机要留意。

## 1. 参考板 GPU0 相对 dagu 还缺什么

参考板是 `qcom-mtp8250` 的 DSDT（`xiaomi-umi` / `motorola-nio` 逐字节照搬同一份）。
它的 `GPU0`（`_HID QCOM253A`）节点在 `winarm/mu_aloha_platforms/Platforms/KonaPkg/
Device/qcom-mtp8250/ACPI/DSDT.dsl` 第 68113–90235 行，含：

```
RESI 68287   ENGS 68517   TMDT 69512   PMCL 69538   _ROM 79502
_HRV 89854   CHDV 89889   DPCC 89914   DPIN 89919   REGR 89929
_DEP(MMU0/MMU1/IMM0/IMM1/PEP0/PMIC/PILC/RPEN/TREE/SCM0)  _SUB  _IDT  AVS0  _DOD  _LID
```

阶段 8 之后 dagu 已有 `RESI`/`ENGS`/`TMDT`。本阶段补 `PMCL`/`_HRV`/`_IDT`。

## 2. 本阶段移植内容

全部从参考板 DSDT.dsl 逐字节取出，重新缩进到 dagu 的 4 空格基准，未改任何字符串/数值。

### 2.1 PMCL（电源/时钟部件模型，9964 行）

- 来源：DSDT.dsl 第 69538–79501 行（`Method (PMCL, 0, NotSerialized)` 整段）。
- 外部引用：只有 `\_SB.SIDT`（10 次）、`\_SB.SIDV`（11 次）、`\_SB.SOID`（10 次）。
  这三个占位符 dagu 的 `dsdt_common.asl` 已定义（第 13/16/25 行），由固件
  `AcpiPlatformUpdateLib` 启动时按芯片 SKU/版本填入。**没有**对任何设备节点、
  `OperationRegion`、`Field`、`External` 的引用，所以逐字照搬就能独立编译。
- 作用：`qcdxkm8250.sys` 过了阶段 8 的 `GmuInternal`/`GpuInternal` 门控后，会读这张表
  （12 个 `COMPONENT`，含 `PRIMDISPLAY_POWER_STATES`、`HW_BLOCK_MDP`、大量 `PSTATE` /
  `FSTATE` / `BANDWIDTH` / `CORE_CLOCK`）建立各部件的电源状态模型。它与 PEP 侧的
  `G0MD..GLMD` 一一对应（PMCL 描述给图形驱动看，`G?MD` 给 qcpep 实际的板级资源）。

### 2.2 _HRV（硬件版本，35 行）

- 来源：DSDT.dsl 第 89854–89888 行。
- 外部引用：`\_SB.SIDT`、`\_SB.SIDV`、`\_SB.SOID`、`\_SB.SDFE`（dagu 均已有）。
- 作用：按 `TIER|MINO|MAJO|TYPE|FAMI` 算出一个版本号，对应 `qcdx8250.inf` 的
  `REV_xxxx` 硬件 ID。dagu live `SIDV=0x00020000`、`SOID=0x164`，算出的 REV 命中
  `REV_0913`/`REV_0D15`（PAF，名字即 "Qualcomm(R) Adreno(TM) 650 GPU"）。即便算不到
  已知 REV，INF 末尾还有通用 `ACPI\VEN_QCOM&DEV_253A` 兜底，绑定不受影响。

### 2.3 _IDT（SIDT 别名，1 行）

- `Alias (\_SB.SIDT, _IDT)`，与参考板一致。

## 3. 刻意仍未移植（和阶段 8 的边界一致）

- **`_ROM` / `PCFG` 面板表**：参考板内嵌的是 Sharp `LS060R1SX03`（2160x3840），dagu 的
  真面板是 `L81A`（1600x2560 双 DSI + DSC，panel XML 在 `xiaomi-pipa/Binaries/RawFiles/
  Panel_L81A_42_04_0a_dualdsi_dphy_lcd_vid.xml`，是 UEFI 方言，需转成 Windows 的
  `PCFG` 方言）。这部分是"点屏/扫描输出"，不影响驱动绑定与初始化，留后续阶段。
- **`_DEP`**：参考里依赖 `IMM0`/`IMM1`（QCOM259B）、`PILC`/`RPEN`/`TREE`/`SCM0` 等
  dagu 根本没有的节点，恢复了就是悬空引用。`MMU0`/`MMU1` 虽已在 `smmu.asl` 对齐
  (QCOM2509)，但 `_DEP` 暂不恢复。
- **`_SUB`（`Alias \_SB.PSUB`）**：dagu 的 `dsdt_common.asl` 没有定义 `PSUB`，加它会改变
  所有设备的 `SUBSYS` 匹配，本阶段不动。
- `CHDV`/`AVS0`（相机 AVStream 子设备）、`DPCC`/`DPIN`（引用 `\_SB.CCST`/`PINA`）、
  `REGR`、`_DOD` 暂不移植。

## 4. 离线编译验证

把 `graphics-qcom253a.asl` 用一个最小 DSDT 外壳（`Scope(\_SB)` 内放 `SOID`/`SIDV`/
`SIDT`/`SDFE`/`SVMJ` 占位符和一个 `GIO0` 设备，再 `Include` 本文件）独立编译：

```
iasl 20251212
Compilation successful. 0 Errors, 0 Warnings, 42 Remarks, 86 Optimizations, 3 Constants Folded
AML Output: 33143 bytes
```

42 条 Remark 全是 `_HRV` 里 `Name(RESU/TIER/...)` 的"方法内建名效率低"提示，与参考板
一致，无害。节点成员最终顺序：`_HID` → `_IDT` → `_CLS` → `MON0` → `_STA` → `_CRS` →
`RESI` → `ENGS` → `TMDT` → `PMCL` → `_HRV`。

## 5. 板上部署与测试计划（**尚未执行，需本人在平板旁**）

覆盖表是手工拼的（dump live DSDT → iasl -d → 拼入节点 → 定头 OEM rev≥4 → 以
`0xDEADBEEFFFFFFFFF` 编译 SOSI 再二进制回填 `0x0000000080907228` 并清校验 → 切两个
注册表块 → base64 → `asl.exe /loadtable`）。**切记 SOSI 必须是 8 字节 QWord**：阶段 4
的电池表、阶段 8 后两个候选表都把 SOSI 退化成了 4 字节 DWord，一旦 PEP0 启用就 `0x1A`。

建议按"一次只变一项"推进，便于定位：

1. **先测阶段 8（仅门控）**：覆盖表 = 固件 DSDT + `GPU0`(含 `ENGS`/`RESI`/`TMDT`，
   **不含** PMCL) + `MMU0`/`MMU1`(QCOM2509)，PEP0 保持禁用，`QCDX` 改 `Start=3`。
   看是否越过 `0xe5f`/`0xe71`、驱动能否完成初始化。
2. **再测阶段 9（加 PMCL/_HRV）**：若第 1 步过了门控但仍卡在电源/时钟，再把本阶段的
   PMCL+_HRV 一起拼进覆盖表重测。

风险与回滚（务必先确认能物理够到平板）：

- 阶段 4 装 qcdx 后 Windows 停在启动、**无 dump 无蓝屏**。这种"真卡死"不会触发复位，
  A 槽**不会**自动回落 B 槽 Linux（APSS 看门狗在交接时是关的），需要**人工**按
  电源+音量下进 fastboot。开工时平板也**没有**用 USB 接在本机上。
- 软回滚（平板能自己落到 B 槽 Linux 时）：`dagu-rescue.sh disable-qcdx`（`QCDX`→4）、
  `dagu-rescue.sh rm-dsdt`（删整张覆盖表）、`dagu-rescue.sh to-win`（切 A 槽重启）。
- 覆盖表删掉后电池节点也一起没了，和开工时的状态一样。

## 6. 本阶段改动的文件

- `port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics-qcom253a.asl`：
  GPU0 节点新增 `PMCL`（9964 行）、`_HRV`、`_IDT`，并更新文件头注释。1284 → 11298 行。
- `docs/woa-dagu-gpu-stage9-2026-10-31.md`：本文件。
