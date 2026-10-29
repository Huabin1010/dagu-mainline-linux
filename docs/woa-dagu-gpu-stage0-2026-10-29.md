# dagu Windows GPU 适配：阶段 0 记录（2026-10-29）

目标是让 Adreno 650 在 Windows 上用高通 `qcdx8250` 驱动。本阶段只做两件事：整理 `qcdx8250` 的依赖，
以及找一个不用重刷 UEFI 就能改 ACPI 的测试方法。

## 1. qcdx8250 的依赖

参考表来自 `winarm/mu_aloha_platforms/Platforms/KonaPkg/Device/qcom-mtp8250/ACPI/DSDT.dsl`
（提交 ecac086），驱动包来自 `winarm/drivers/QC8250`（提交 22221a0）。`GPU0` 的 `_DEP` 有 10 项，
加上 PMIC 依赖的 SPMI，一共 12 个节点。

| 节点 | HID | 驱动（INF） | 自身 `_DEP` | dagu 启动用 DSDT 里 | 平板上的驱动服务 |
|---|---|---|---|---|---|
| GPU0 | QCOM253A | qcdx8250 | 下面 10 项 | 没有（`graphics.asl` 是 QCOM24B4，未编进去） | 没装 |
| MMU0 | QCOM2509 | qcsmmu8250 | MMU1 | 没有（`smmu.asl` 用 QCOM24C2，未编进去） | 已装，Start=3 |
| MMU1 | QCOM2509 | qcsmmu8250 | PEP0 | 同上（QCOM24C3） | 同上 |
| IMM0/IMM1 | QCOM259B | qciommu8250 | 无 | 没有 | 已装，Start=3 |
| PEP0 | QCOM2519 | qcpep.wd8250 | 无 | 没有（`pep0.asl` 是 QCOM2430 占位） | 已装，Start=0 |
| PMIC | QCOM252E | qcpmic8250 | SPMI | 没有（`pmic.asl` 用 QCOM0C09/24D0） | 已装，Start=0 |
| SPMI | QCOM250C | qcspmi8250 | 无 | 没有 | 已装，Start=0 |
| PILC | QCOM251B | qcpil8250 | 无 | 没有 | 包在 DriverStore，没有服务 |
| RPEN | QCOM2533 | qcrpen8250 | 无 | 没有 | 已装，Start=3 |
| TREE | QCOM2576 | QcTrEE8250 | 无 | 没有 | 已装，Start=0 |
| SCM0 | QCOM250B | qcscm8250 | 无 | 没有 | 已装，Start=0 |

结论：除 `qcdx8250` 外，依赖链上的驱动都已经在 DriverStore 里。缺的是 ACPI 节点，HID 也要改成驱动认的值。
SMMU 只依赖 PEP0，所以 PEP0 是整条链的根。

## 2. 参考 PEP0 有多大

- `Device (PEP0)` 本体约 2160 行：`_SUB`、10 个中断的 `_CRS`、一个接到 `\_SB.ABD` 的 I2C 字段，
  以及 `INTR`、`STND`、`CTPM`、`PPPM`（61 个 PMIC 电源资源）、`PPRR` 等表。
- 另外有 15 个 `Scope (\_SB.PEP0)`，共约 6.5 万行，每个方法是一组设备的电源配置。
  `G0MD` 到 `GLMD` 共 12 个方法只管 `\_SB.GPU0`，约 3.5 万行；`SDMD` 管 UFS0、SDC2、USB 等，约 9700 行；
  `BSMD` 管各个串口、I2C、SPI 引擎。
- PEP0 引用的外部对象有 `\_SB.ABD`、`AGR0`、`DPP0/1`、`MPP0/1`、`PSUB`、`SOID`、`PLST`、`SVMJ`
  和几十个 `TZ*` 温控区。dagu 现在的 DSDT 只有 `SOID`、`PLST`、`SVMJ`。

所以阶段 1 的做法是：PEP0 本体照搬，per-device 表只留 GPU0（`G0MD` 到 `GLMD`），其余设备的表留空，
这样 qcpep 不会去管 UFS0 等现在能用的设备。外部对象缺什么补什么。

## 3. 不刷 UEFI 改 DSDT：注册表覆盖

Windows 在开着测试签名时，会用注册表里修订号更高的 DSDT 替换固件给的 DSDT。实测在 dagu 上有效：

```powershell
# 平板上，管理员。C:\dagu\asl.exe 来自 WDK 的 tools\10.0.26100.0\arm64\acpiverify\asl.exe
C:\dagu\asl.exe /loadtable C:\dagu\ov.aml      # 写入 HKLM\SYSTEM\...\ACPI\Parameters\DSDT\QCOMM_\SM8250_\00000004
C:\dagu\asl.exe /loadtable /d C:\dagu\ov.aml   # 删除
```

- 固件 DSDT 是 `QCOMM ` / `SM8250 ` / 修订号 3，覆盖表必须用修订号 4 或更高。
- 覆盖表在 Linux 上用 `iasl` 编译即可：先取平板上现在的 DSDT（`HKLM\HARDWARE\ACPI\DSDT`），反编译、
  修改、把 `DefinitionBlock` 的修订号改成 4 再编译。
- 验证：在覆盖表里加了一个测试设备 `DAGU0FFF`，重启后它出现在 PnP 里（状态 Error，因为没有驱动），
  删掉覆盖后它消失。生效时 `HKLM\HARDWARE\ACPI\DSDT\QCOMM_\SM8250_` 下面的子键是 `00000004`。
- `asl.exe /loadtable /d` 只删值，不删键，所以 `...\SM8250_\00000004` 这个空键还留着，不影响启动。

这样 PEP、SMMU、GPU0 的节点都可以先用覆盖表试，确认能启动后再写进 `port/dagu/.../AcpiTables/dagu/`
并编进 UEFI。

### 回滚

覆盖表让 Windows 起不来时，从 B 槽 Linux 离线删掉注册表值：

```bash
mount -t ntfs-3g /dev/sda36 /mnt/w
hivexsh -w /mnt/w/Windows/System32/config/SYSTEM   # cd ControlSet001\Services\ACPI\Parameters\DSDT\QCOMM_\SM8250_\00000004，删值后 commit
```

不要用"关掉测试签名的启动项"来回滚。这次试过用 `bcdedit /copy` 建一个 `testsigning No` 的 `dagu-safe`
启动项，结果它变成了默认项，平板进了那个系统后网络起不来，只能回 Linux 离线修 BCD：

- 把 ESP 上的 `EFI/Microsoft/Boot/BCD` 拷回本机，用 `hivexsh` 把 `{bootmgr}` 的 `23000003`（默认项）
  改回 `Windows 11` 的 `{891c662b-d158-11f1-8618-e94c0645019b}`，再写回 ESP。
- 原文件保存在 ESP 的 `EFI/Microsoft/Boot/BCD.dagu-safe-20261029`。
- `dagu-safe` 条目还在 `displayorder` 里，但启动管理器超时是 0，不会显示。

## 4. 工具

`tools/winarm/dagu-ps.sh`：把 PowerShell 脚本转成 UTF-16LE 后用 `-EncodedCommand` 传给平板，
避开 ssh 和 PowerShell 两层引号。ssh 断线时自动重试。

## 5. 当前状态

- Windows 在 A 槽正常启动，DSDT 是固件的修订号 3，覆盖表已删除。
- 下一步：用覆盖表加入 PEP0（只带 GPU0 的电源表），看 qcpep 是否还 0x1D5。
