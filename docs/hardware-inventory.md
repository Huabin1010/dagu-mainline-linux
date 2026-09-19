# 硬件清单 — dagu (小米平板5 Pro 12.4)

> Golden Baseline 最新采集：**2026-08-26（Magisk root）**  
> 原始数据：`dumps/dagu-20260826-210700-root/`（约 1.9 GiB，gitignore）  
> 说明：`dumps/dagu-20260826-210700-root/README.md`  
> 首次采集（解锁前）：`dumps/dagu-20260719-092500/`

**状态：** ✅ Bootloader 已解锁 · ✅ Magisk 30.7 root · ✅ iomem / live DTB / dmesg / 启动分区已采集

---

## 设备标识

| 字段 | 值 | 来源 |
|------|-----|------|
| 产品名 | Xiaomi Pad 5 Pro 12.4 | `ro.product.marketname` |
| 内部代号 | **dagu** | `ro.product.device` |
| 型号 | **22081281AC** | `ro.product.model` |
| SoC | **SM8250** (骁龙 870) | `ro.soc.model` |
| 平台代号 | **kona** | `ro.board.platform` |
| RAM | **~8 GB** | `/proc/meminfo` |
| 存储 | **256 GB**（userdata ~228 GiB） | fastboot + `df` |
| Android | **14** / OS2.0.10.0.ULZCNXM | getprop |
| 内核 | 4.19.157-perf (2025-07-01) | `uname -a` |
| **Bootloader** | **unlocked** | `ro.secureboot.lockstate` / fastboot |
| Verified Boot | **orange**（已解锁预期状态） | `ro.boot.verifiedbootstate` |
| 当前 slot | **a** | fastboot `current-slot` |
| Root | **Magisk 30.7**（`su` 可用） | `adb shell su -c id` |

---

## 分区布局（fastboot getvar）

完整输出：`dumps/dagu-20260719-094103/fastboot-getvar-all.txt`  
符号链接列表：`dumps/dagu-20260719-094103/partition-by-name.txt`

| 分区 | 大小 (fastboot) | 备注 |
|------|-----------------|------|
| userdata | `0x3879FFB000` (~228 GiB) | 用户数据 |
| super | `0x220000000` (8.5 GiB) | 动态分区 |
| boot_a | `0xC000000` (192 MiB) | 当前备用 slot b |
| vendor_boot_a | `0x6000000` (96 MiB) | |
| boot_a 块设备 | sde12 / boot_b sde37 | 见 partition-by-name |

> WoA 分区改造前请再次 `fastboot getvar all` 备份，并参考 nabu 指南。

---

## SoC 与子系统

| 子系统 | 型号 / 节点 | 证据 | WoA（Windows on ARM，ARM 上的 Windows）源码 |
|--------|-------------|------|-----|
| CPU | Kryo 585 ×8, ARMv8 atomics | cpuinfo | [`Pep_lpi.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/Pep_lpi.asl) + [`pep0.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pep0.asl) |
| GPU（Graphics Processing Unit，图形处理器） | **Adreno650v3** | kgsl sysfs | [`graphics.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics.asl) |
| UFS（Universal Flash Storage，通用闪存） | **1d84000.ufshc**, SM8 UFS（Universal Flash Storage，通用闪存） | getprop + fastboot variant | [`ufs.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/ufs.asl) |
| USB（Universal Serial Bus，通用串行总线） | **a600000.dwc3** | `/sys/class/udc/` | [`usb.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/usb.asl) + [`typec.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/typec.asl)；UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）日志走 [`DaguUsbCdcAcmDxe`](../port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/DaguUsbCdcAcmDxe/DaguUsbCdcAcmDxe.c) `0525:a4a7` |
| 显示 | **2560×1600** LCD | dumpsys display | [`display.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/display.asl) + SimpleFb + [`backlight.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/backlight.asl) |
| 面板 DT（Device Tree，设备树） | `dsi-panel-l81a-42-04-0a` | [MiCode dagu-s-oss](https://github.com/MiCode/kernel_devicetree/tree/dagu-s-oss) | `dagu.dsc` 1600×2560 |
| 触控 | **himax-touchscreen** + Xiaomi Touch | getevent | [`himax.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/himax.asl) 占位 |
| 音频 | **kona-mtp-snd-card** | getevent；overlay 见 `dagu-audio-overlay.dtsi` | [`audio.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/audio.asl) |
| Wi-Fi | **cnss_pci** | wlan0 driver | [`pcie.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pcie.asl) QCA6390 |
| 蓝牙 | **qca6390-bt** uart6 | DT（Device Tree，设备树）`&uart6` | [`bluetooth.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/bluetooth.asl) |
| 键盘 | **nanosic,803** | overlay HID（Human Interface Device，人机接口设备）`15d9:00a3` | [`keyboard.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/keyboard.asl) |
| 电池 | 双 BQ27Z561 + SMB5 | dual-fg / charger overlay | [`battery.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/battery.asl) |
| IMU（Inertial Measurement Unit，惯性测量单元） | **lsm6dso** (STMicro) | sensorservice | [`sensors.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/sensors.asl) SLPI（Sensor Low Power Island，传感器低功耗岛） |
| 光线 | **tcs3701**, **rohm_bu27030** | sensorservice | 同上 SLPI（Sensor Low Power Island，传感器低功耗岛） |
| 视频 | Venus `aa00000` | [`dagu-venus.md`](../linux-mainline/docs/dagu-venus.md) | [`venus.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/venus.asl) |
| CDSP（Compute DSP，计算数字信号处理器） | Hexagon 698 `cdsp.mbn` | Linux `&cdsp` | [`cdsp.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/cdsp.asl) |
| SPMI（System Power Management Interface，系统电源管理接口） | `spmi@c440000` | iomem `0c440000` | [`pmic.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pmic.asl) |
| LPASS（Low Power Audio Subsystem，低功耗音频子系统） | rxmacro / SoundWire | 麦克风 AMIC5 | [`lpass.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/lpass.asl) |
| SMMU（System Memory Management Unit，系统内存管理单元） | `apps` + Adreno | iomem `15000000` / `03da0000` | [`smmu.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/smmu.asl) |
| 霍尔 / 按键 | GPIO（General Purpose Input/Output，通用输入输出）110/121 + PON | gpio-keys | [`buttons.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/buttons.asl) |
| 笔充 | IDT P9418 | overlay | [`pen.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pen.asl) |
| 马达 | PM8150B LRA | `haptics@c000` | [`haptics.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/haptics.asl) |
| 手电筒 | `white:flash` | `pm8150l_flash` | [`led.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/led.asl)（不是相机） |
| USB3 redriver | PS5169 | 产品 DT（Device Tree，设备树）disabled | [`usb.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/usb.asl) `RDV0` `_STA=0` |

---

## 内存映射 / 设备树

| 资源 | 状态 | 说明 |
|------|------|------|
| `/proc/iomem` | ✅ | `dumps/.../memory/iomem.txt`；UFS `1d84000`、GPU `03d00000`、USB `dwc3@a600000` |
| live FDT | ✅ | `dt/fdt.dtb` + `dt/fdt.dts`（model=`xiaomi dagu`，`qcom,kona-mtp`） |
| `dmesg` | ✅ | `logs/dmesg.txt` |
| 面板 | ✅ | `qcom,mdss_dsi_l81a_42_04_0a_dual_dphy_video` |
| 触控 | ✅ | `himax,hxcommon`；input=`himax-touchscreen` |
| **开源 DT 参考** | ✅ | [MiCode/kernel_devicetree `dagu-s-oss`](https://github.com/MiCode/kernel_devicetree/tree/dagu-s-oss) |

UEFI 内存映射与 ACPI 应对这份 live DTB / iomem，不要再只用临时 elish DTB。

---

## Fastboot 关键变量

```
product: dagu
unlocked: yes
serialno: <android-serial>
current-slot: a
variant: SM8 UFS
verified boot state: orange (post-unlock)
```

完整：`dumps/dagu-20260719-094103/fastboot-getvar-all.txt`

---

## 采集文件索引

| 文件 | 状态 |
|------|------|
| `getprop.txt` / `getprop-full.txt` | ✅ |
| `fastboot-getvar-all.txt` | ✅ 新增 |
| `partition-by-name.txt` | ✅ |
| `getevent-lp.txt` / `dumpsys-display.txt` | ✅ |
| `iomem.txt` / `fdt.dtb` / `fdt.dts` / `dmesg.txt` | ✅ 2026-08-26 root 采集 |

---

## 下一步（Phase 1）

源码侧对照已在 [dagu-woa-linux-source-map.md](dagu-woa-linux-source-map.md)：内存映射 / ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）/ 活 FDT（Flattened Device Tree，扁平设备树）。

1. [x] `dagu` 设备配置 + Linux reserved-memory 内存映射  
2. [x] 活 FDT（Flattened Device Tree，扁平设备树）替换临时 elish DTB（Device Tree Blob，设备树二进制）  
3. [ ] `fastboot boot boot-dagu.img` 验证 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）Shell（**不要 flash boot**；本阶段不链载）  
4. [x] Magisk root 已采 `/proc/iomem` 与 live DTB（Device Tree Blob，设备树二进制）

---

**最后更新：** 2026-09-19（WoA（Windows on ARM，ARM 上的 Windows）ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）对照加宽；dump 日期仍是 2026-08-26）
