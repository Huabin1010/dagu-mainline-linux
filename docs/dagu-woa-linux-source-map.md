# dagu：Linux 源码 → Windows 11 ARM 对照

本阶段只补 [`port/dagu/`](../port/dagu/) 描述，不改 [`linux-mainline/linux/`](../linux-mainline/linux/)、不改 overlay、不刷机。  
校验：`python3 tools/dagu-linux-to-uefi-map.py`。活 FDT（Flattened Device Tree，扁平设备树）：`./tools/install-dagu-fdt.sh`。

Windows 11 ARM 真机能进桌面、GPU（Graphics Processing Unit，图形处理器）出图、Himax 能点，都要板上验证。本文件不是飞行合格证明。

## 三层出处

| 层 | 路径 | 改？ |
|----|------|------|
| git 入库 | [`linux-mainline/dts/`](../linux-mainline/dts/)、[`linux-mainline/overlays/`](../linux-mainline/overlays/)（只读）、[`linux-mainline/docs/`](../linux-mainline/docs/) | 禁止改 |
| 克隆树 | [`linux-mainline/linux/`](../linux-mainline/linux/)（`setup-kernel.sh` 之后） | 禁止改 |
| dumps | [`dumps/dagu-20260826-210700-root/`](../dumps/dagu-20260826-210700-root/) | 禁止当 Linux 7.0 DTS（Device Tree Source，设备树源码）编进 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口） |

UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）FDT（Flattened Device Tree，扁平设备树）用 HyperOS 活树，不用 Linux 7.0 产品 DTS（Device Tree Source，设备树源码）。

## 内存映射

出处：[`linux-mainline/dts/dagu-reserved-memory-stock.dtsi`](../linux-mainline/dts/dagu-reserved-memory-stock.dtsi)、[`linux-mainline/dts/sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) `memory { reg }`、[`dumps/dagu-20260826-210700-root/memory/iomem.txt`](../dumps/dagu-20260826-210700-root/memory/iomem.txt)。  
落地：[`port/dagu/Platform/Xiaomi/sm8250/Library/dagu/PlatformMemoryMapLib/PlatformMemoryMapLib.c`](../port/dagu/Platform/Xiaomi/sm8250/Library/dagu/PlatformMemoryMapLib/PlatformMemoryMapLib.c)。

| UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）名 | 基址 / 长度 | Linux 符号 |
|---|---|---|
| Hypervisor | `0x80000000` / `0x600000` | `hyp_region@80000000` |
| XBL AOP | `0x80600000` / `0x260000` | `xbl_aop_region@80600000`（不再在 `0x80600000` 开 HLOS（High Level Operating System，高层操作系统）1） |
| AOP CMD DB | `0x80860000` / `0x20000` | `reserved-memory@80860000` |
| Removed Mem | `0x80B00000` / `0x5300000` | `removed_region@80b00000` |
| PIL Reserved | `0x86200000` / `0xC500000` | `camera@86200000` … `cdsp_secure@8e100000` 上沿 `0x92700000` |
| Display Reserved | `0x9C000000` / `0x2300000` | `cont_splash_region@9c000000` |
| PSTORE | `0xB0000000` / `0x400000` | `sm8250-xiaomi-dagu.dts` `ramoops@b0000000` |
| Disp rdump | `0xB0400000` / `0x1000000` | `disp_rdump_region@b0400000` |
| RAM Partition | `0xD0000000` / `0x1B0000000` | bank1 `0xC0000000+0x1C0000000` 减 DXE（Driver Execution Environment，驱动执行环境）/ FD |
| UFS HC | `0x01D84000` / `0x1C000` | `ufshc@1d84000`；iomem `01d84000-01d86fff`（Linux 窗 `0x3000`，ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）保持 SM8250 模板 `0x1C000`） |
| GPU KGSL | `0x03D00000` / `0x40000` | `gpu@3d00000`；iomem `03d00000-03d3ffff : kgsl-3d0` |
| PCIE0 PARF | `0x01C00000` / `0x4000` | 克隆树 `sm8250.dtsi` `pcie@1c00000` `parf` |
| PCIE0 MEM | `0x60000000` / `0x4000000` | 同上 `ranges` / DBI（Device Base address register Interface，设备基址寄存器接口）+ BAR（Base Address Register，基址寄存器）窗 |
| VENUS | `0x0AA00000` / `0x100000` | 克隆树 `sm8250.dtsi` `video-codec@aa00000` |
| MDSS | `0x0AE00000` / `0xC0000` | `display-subsystem@ae00000`；活 iomem 未开时钟时可能看不见 |
| CDSP PAS | `0x08300000` / `0x10000` | `&cdsp` `cdsp.mbn` |
| SLPI PAS | `0x05C00000` / `0x4000` | `&slpi` `slpi.mbn` |
| ADRENO SMMU | `0x03DA0000` / `0x10000` | `&adreno_smmu`；iomem `03da0000-03daffff` |
| LPASS RX | `0x03200000` / `0x52000` | `rxmacro@3200000` + SoundWire |

旧表 `PIL Reserved` 停在 `0x8BF00000`，会踩 ADSP（Audio DSP，音频数字信号处理器）/ SLPI（Sensor Low Power Island，传感器低功耗岛）/ CDSP（Compute DSP，计算数字信号处理器）secure。已拉到 `0x92700000`。

## CPU

| 取 | 文件 | 落到 |
|----|------|------|
| 八核在位 | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) `&cpu0`–`&cpu7` | [`Pep_lpi.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/Pep_lpi.asl) `CPU0`–`CPU7` `_HID ACPI0007` |
| 删 interconnects | 同上（QHEE（Qualcomm Hypervisor Execution Environment，高通虚拟化执行环境）规避） | **不要**写进 ACPI（Advanced Configuration and Power Interface，高级配置与电源接口） |
| EPSS（Epochal Precise Scaling System，高通 CPU 调频硬件）LUT（Look-Up Table，查找表） | [`dagu-wifi-gpu-turnip-cpu.md`](../linux-mainline/docs/dagu-wifi-gpu-turnip-cpu.md)、[`apply-overlays.sh`](../linux-mainline/scripts/apply-overlays.sh) ~L699、克隆树 `drivers/cpufreq/qcom-cpufreq-hw.c` | 只读；Windows 调频走 PEP（Power Engine Plugin，电源引擎插件） |
| `qcom,msm-id = <0x164 …>` | `dumps/.../dt/fdt.dts` | [`dsdt_common.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/dsdt_common.asl) `SOID=356` |
| 已通结论 | [`dagu-adaptation-status.md`](../linux-mainline/docs/dagu-adaptation-status.md) | 对照，不抄用户态 |

## GPU（Graphics Processing Unit，图形处理器）

| 取 | 文件 | 落到 |
|----|------|------|
| `gpu@3d00000` `reg` `0x03d00000/0x40000` GIC_SPI 300 | 克隆树 `sm8250.dtsi` | [`graphics.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics.asl) `_CRS` + IRQ 332 |
| `&gpu` `&gmu` zap `a650_zap.mbn` | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts)、[`firmware/dagu/README.md`](../linux-mainline/firmware/dagu/README.md) | 表注释；blob 不入库 |
| `kgsl-3d0` | dumps `iomem.txt` | 同基址 |
| 节点是 `3d00000.gpu` | [`msm_gpu_resources_sysfs.c`](../linux-mainline/overlays/linux/drivers/gpu/drm/msm/msm_gpu_resources_sysfs.c) | 不要当 QCDX INF（Information file，驱动信息文件） |
| 1600×2560 | [`panel-xiaomi-dagu-l81a.c`](../linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c)、[`dagu.dsc`](../port/dagu/Platform/Xiaomi/sm8250/dagu.dsc) | SimpleFb PCD（Platform Configuration Database，平台配置库），不是 WDDM（Windows Display Driver Model，Windows 显示驱动模型） |

**不要取：** [`dagu-a650-linear-destile.md`](../linux-mainline/docs/dagu-a650-linear-destile.md) 当 Windows GPU（Graphics Processing Unit，图形处理器）做法；Mesa Turnip；Snapdragon X UGD。

## 硬盘 UFS（Universal Flash Storage，通用闪存）

| 取 | 文件 | 落到 |
|----|------|------|
| `ufs_mem_hc` okay | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) | [`ufs.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/ufs.asl) `UFS0` |
| `0x01d84000` | 克隆树 `sm8250.dtsi` `ufshc@1d84000`；iomem `ufs_mem` | `_CRS Memory32Fixed 0x1D84000` |
| `CONFIG_SCSI_UFS_QCOM` | [`dagu.fragment`](../linux-mainline/config/dagu.fragment) / [`dagu-display.fragment`](../linux-mainline/config/dagu-display.fragment) | 只证明 Linux 主机是 `ufs-qcom` |
| userdata / 分区名 | [`dagu-adaptation-status.md`](../linux-mainline/docs/dagu-adaptation-status.md)、`dumps/dagu-20260719-094103/fastboot-getvar-all.txt` | 本阶段只建表，不改 GPT |
| CLK_SCALING 规避 | [`apply-overlays.sh`](../linux-mainline/scripts/apply-overlays.sh) ~L6624 | **不要**搬进 Windows |

`STOR=1`、`PUS3=1` 在 [`dsdt_common.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/dsdt_common.asl)。

## 触控 Himax

| 取 | 文件 | 落到 |
|----|------|------|
| **产品口** `&spi4` | [`dagu-geni-spi-experiment.on.dtsi`](../linux-mainline/dts/dagu-geni-spi-experiment.on.dtsi) | [`himax.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/himax.asl) `TPAD` |
| `0x990000` gpio8–11 IRQ 39 | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) 注释 + 克隆树 `spi4: spi@990000` | `_CRS` SE（Serial Engine，串行引擎）窗 + `GpioInt {39}` |
| mode 3、`0x30`、10 指 | [`himax-dagu.c`](../linux-mainline/overlays/linux/drivers/input/touchscreen/himax-dagu.c) | `SPIM=3`；协议留给以后的 KMDF（Kernel-Mode Driver Framework，内核模式驱动框架） |
| `990000.spi proto=1` | [`dagu-adaptation-status.md`](../linux-mainline/docs/dagu-adaptation-status.md) | 产品结论 |
| Linux IRQ 193 = GPIO（General Purpose Input/Output，通用输入输出）39 | [`dagu-touch-irq-jitter.md`](../linux-mainline/docs/dagu-touch-irq-jitter.md) | 只用 39；文内 spi-gpio 是旧快照 |

**不要取：** 空 stub [`dagu-geni-spi-experiment.dtsi`](../linux-mainline/dts/dagu-geni-spi-experiment.dtsi)；`himax_spi: spi-gpio` 当产品总线；GPIO（General Purpose Input/Output，通用输入输出）100；给 `&qupv3_id_0` 加 `firmware-name`。

## Wi‑Fi / PCIe（Peripheral Component Interconnect Express，高速外设互连）

| 取 | 文件 | 落到 |
|----|------|------|
| `&pcie0` `&pcie0_phy` okay，`&pcie1/2` disabled | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) | [`pcie.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pcie.asl) `PCI0` / `WCN0` |
| `parf` `0x01c00000`，BAR（Base Address Register，基址寄存器）`0x60000000`，GIC_SPI 140 → IRQ 172 | 克隆树 `sm8250.dtsi` `pcie@1c00000` | `_CRS` |
| `wifi@0`，`board.bin` = `bd_l81a.elf` | 同上 `&pcieport0`；[`firmware/dagu/README.md`](../linux-mainline/firmware/dagu/README.md) | 表注释；**不要** `board-2.bin` |
| QCA6390 | [`dagu-wifi-gpu-turnip-cpu.md`](../linux-mainline/docs/dagu-wifi-gpu-turnip-cpu.md) | `_HID QCOM24D4` / `_CID QCA6390` |

**不要取：** nabu SM8150 CNSS（Connectivity Subsystem，连接子系统）包当本板 INF（Information file，驱动信息文件）。

## 蓝牙

| 取 | 文件 | 落到 |
|----|------|------|
| `&uart6` `serial@998000`，`qcom,qca6390-bt`，`max-speed 3000000` | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) | [`bluetooth.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/bluetooth.asl) `UAR6` / `BTH0` |
| GIC_SPI 607 → IRQ 639 | 克隆树 `sm8250.dtsi` `uart6` | `_CRS` |
| BT_EN 是 `qca6390-pmu` GPIO（General Purpose Input/Output，通用输入输出）21 | 同上 | 不在本节点写 `enable-gpios` |
| 固件 `qca/htbtfw20.tlv` + `htnv20.bin` | 板上 / 固件 README | **不要**给 `&qupv3_id_0` 加 `firmware-name` |

## USB（Universal Serial Bus，通用串行总线）

| 取 | 文件 | 落到 |
|----|------|------|
| `usb@a600000` `dwc3`，GIC_SPI 133 → IRQ 165 | 克隆树 `sm8250.dtsi`；iomem `dwc3@a600000` | [`usb.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/usb.asl) `URS0` |
| `dr_mode=otg`，默认 peripheral，SS PHY（Physical Layer，物理层）关 | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) `&usb_1_dwc3` | 表注释；Windows 主机口是板上阶段 |
| `&pm8150b_typec` okay（充电 / PD（Power Delivery，功率传输）） | 同上 | [`typec.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/typec.asl) `TPC0` |
| Linux gadget `g_serial` `0525:a4a7` | [`dagu-adaptation-status.md`](../linux-mainline/docs/dagu-adaptation-status.md)；[`dagu-usb.fragment`](../linux-mainline/config/dagu-usb.fragment) | [`usb.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/usb.asl) `ACM0` + [`usb-cdc-acm/`](../port/dagu/windows-drivers/usb-cdc-acm/)；主机 [`tools/dagu-usb-console.py`](../tools/dagu-usb-console.py) |
| UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）启动日志 | 同上 `0525:a4a7`；环缓 `Log Buffer` `0x9FFF7000` | [`DaguUsbCdcAcmDxe`](../port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/DaguUsbCdcAcmDxe/DaguUsbCdcAcmDxe.c) 挂 `UsbfnDwc3Dxe`（高通 USB（Universal Serial Bus，通用串行总线）功能控制器）；禁止手写 DWC3（DesignWare USB3 Controller，新思 USB3 控制器）寄存器；Windows 主机 INF（Information file，驱动信息文件）[`usb-cdc-acm-host/`](../port/dagu/windows-drivers/usb-cdc-acm-host/) |

**不要取：** 重接 Type-C（USB Type-C，USB C 型接口）→ DWC3（DesignWare USB3 Controller，新思 USB3 控制器）graph（那是 Linux P0 规避）；`&usb_1_qmpphy` 当已训 SuperSpeed。

## 音频

| 取 | 文件 | 落到 |
|----|------|------|
| `&adsp` `adsp.mbn` | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) | [`audio.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/audio.asl) `ADSP` |
| WCD9385 reset GPIO（General Purpose Input/Output，通用输入输出）32 | 同上 `qcom,wcd9385-codec` | `WCD0` `RSTG=32` |
| CS35L41 ×4：SE（Serial Engine，串行引擎）1 `@40/@41`，SE（Serial Engine，串行引擎）3 `@41/@43` | [`dagu-geni-i2c-experiment.on.dtsi`](../linux-mainline/dts/dagu-geni-i2c-experiment.on.dtsi) | `SPK0`–`SPK3` `CIRR0041` |

**不要取：** Softvol / Fluence 当产品口。

## 键盘 / 霍尔

| 取 | 文件 | 落到 |
|----|------|------|
| `&i2c2` `keyboard@4c` `nanosic,803`，IRQ GPIO（General Purpose Input/Output，通用输入输出）83 | [`dagu-geni-i2c-experiment.on.dtsi`](../linux-mainline/dts/dagu-geni-i2c-experiment.on.dtsi)；overlay `nanosic-dagu.c` HID（Human Interface Device，人机接口设备）`15d9:00a3` | [`keyboard.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/keyboard.asl) `KBMC` |
| `hall_key` GPIO（General Purpose Input/Output，通用输入输出）110 / `hall_key1` GPIO（General Purpose Input/Output，通用输入输出）121 | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) `&gpio_keys` | [`buttons.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/buttons.asl) `HALL` |
| 音量上 pm8150 gpio6 | 同上注释 / elish-common | [`buttons.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/buttons.asl) `VOLU` + UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）`ButtonsDxe`，不写假 TLMM（Top Level Mode Multiplexer，顶层引脚复用）线 |

**不要取：** 同 MMIO 上再开 `uart2` / `spi2`。

## 电池 / 充电 / 亮度

| 取 | 文件 | 落到 |
|----|------|------|
| 双 BQ27Z561 `@0x55`：SE（Serial Engine，串行引擎）0 `0x00980000` + SE（Serial Engine，串行引擎）13 `0x00A94000` | [`dagu-geni-i2c-experiment.on.dtsi`](../linux-mainline/dts/dagu-geni-i2c-experiment.on.dtsi)；overlay `xiaomi-dual-fg.c` | [`battery.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/battery.asl) `FG0`/`FG1` |
| PM8150B SMB5 `charger@1000` | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts)；overlay `pm8150b-charger-dagu.c` | `SMB5` |
| BQ25970 ×2 `@0x66`：`i2c15` `0x00884000` IRQ 68 + `i2c16` `0x00888000` | 同上 `.on.dtsi`；克隆树 `sm8250.dtsi` | `PMP0`/`PMP1`（67W PPS（Programmable Power Supply，可编程电源）不是 5 V 主路径） |
| 双 KTZ8866 `@0x11`：`i2c11` `0x00A8C000` + `i2c9` `0x00A84000` | [`dagu-geni-i2c-experiment.on.dtsi`](../linux-mainline/dts/dagu-geni-i2c-experiment.on.dtsi)；overlay `ktz8866.c` | [`backlight.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/backlight.asl) `BL0`/`BL1` |

**不要取：** 把 `vreg_l3a_0p9` 改成 1.104V；Himax reset 绑 GPIO（General Purpose Input/Output，通用输入输出）100。

## 传感器 / 热 / 视频 / 笔 / 马达

| 取 | 文件 | 落到 |
|----|------|------|
| `&slpi` `slpi.mbn`；LSM6DSO / tcs3701 在 SLPI（Sensor Low Power Island，传感器低功耗岛）总线，不在 AP I2C（Inter-Integrated Circuit，内部集成电路） | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts)；[`dagu-adaptation-status.md`](../linux-mainline/docs/dagu-adaptation-status.md) | [`sensors.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/sensors.asl) `SLPI` |
| `CONFIG_QCOM_TSENS` | [`dagu-adaptation-status.md`](../linux-mainline/docs/dagu-adaptation-status.md) | [`thermal.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/thermal.asl) `TSNS` |
| `&venus` `venus.mdt` `0x0aa00000` GIC_SPI 174 → IRQ 206 | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts)；克隆树 `sm8250.dtsi`；[`dagu-venus.md`](../linux-mainline/docs/dagu-venus.md) | [`venus.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/venus.asl) `VEN0` |
| IDT P9418 `@0x3b` IRQ GPIO（General Purpose Input/Output，通用输入输出）113（产品仍 i2c-gpio se8，不是机身 Qi） | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) `wls_i2c_se8` | [`pen.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pen.asl) `PEN0` |
| PM8150B LRA `@c000` | 同上 `pmic@3 haptics@c000` | [`haptics.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/haptics.asl) `VIB0` |
| PEP（Power Engine Plugin，电源引擎插件）绑定 | [`dagu-wifi-gpu-turnip-cpu.md`](../linux-mainline/docs/dagu-wifi-gpu-turnip-cpu.md) | [`pep0.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pep0.asl) `PEP0` `QCOM2430` |

**不要取：** 在 AP I2C（Inter-Integrated Circuit，内部集成电路）上猜 IMU（Inertial Measurement Unit，惯性测量单元）；用 FFmpeg / CPU 软解当 Venus 路径；把闪光灯绑进 CAMSS（Camera Subsystem，相机子系统）/ IFE（Image Front End，图像前端）。

## 显示 / 计算 DSP（Digital Signal Processor，数字信号处理器）/ 电源 / 总线

| 取 | 文件 | 落到 |
|----|------|------|
| `&mdss` `&mdss_dsi0/1` dual-DPHY L81A 1600×2560 120 | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts)；[`panel-xiaomi-dagu-l81a.c`](../linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c) | [`display.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/display.asl) `MDSS`/`DPU0`/`DSI0`/`DSI1`/`PNL0` |
| `&cdsp` `cdsp.mbn` | 同上 | [`cdsp.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/cdsp.asl) `CDSP`；禁止 WebNN（Web Neural Network，网页神经网络） |
| `spmi@c440000` + PM8150 / PM8150B / PM8150L + `watchdog@17c10000` | 同上；iomem `0c440000` / `17c10000` | [`pmic.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pmic.asl) |
| LPASS（Low Power Audio Subsystem，低功耗音频子系统）`rxmacro` + SoundWire | 克隆树 + [`dagu-adaptation-status.md`](../linux-mainline/docs/dagu-adaptation-status.md) 麦克风 | [`lpass.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/lpass.asl) |
| `&adreno_smmu` + `apps_smmu` | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts)；iomem `03da0000` / `15000000` | [`smmu.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/smmu.asl) |
| IPCC（Inter-Processor Communication Controller，核间通信控制器）`@408000` | dumps `iomem.txt` | [`ipcc.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/ipcc.asl) |
| SMEM（Shared Memory，共享内存）`0x80900000` | reserved-memory | [`smem.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/smem.asl) |
| `&usb_1_qmpphy` disabled | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) | [`qmp.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/qmp.asl) `_STA=0` |
| `white:flash` `@d300` | 同上 `&pm8150l_flash` | [`led.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/led.asl) 只做手电筒，不是相机 |
| PS5169 `@0x28` GPIO（General Purpose Input/Output，通用输入输出）69 | [`sm8250-xiaomi-dagu-full.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu-full.dts)；产品 DT（Device Tree，设备树）`&i2c17` disabled | [`usb.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/usb.asl) `RDV0` + [`i2c.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/i2c.asl) `IC17` 都 `_STA=0` |
| OTG（On-The-Go，主从切换）VBUS GPIO（General Purpose Input/Output，通用输入输出）152 | 板级 pinctrl | [`usb.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/usb.asl) `VBS0` |
| QCA6390 PMU GPIO（General Purpose Input/Output，通用输入输出）21 | [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) | [`bluetooth.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/bluetooth.asl) `WCN1` |
| TSENS（Temperature Sensor，温度传感器）`0xc222000` / `0xc263000` | dumps iomem | [`thermal.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/thermal.asl) `_CRS` |
| Adreno GMU（Graphics Management Unit，图形管理单元）`0x02C7D000` | memmap / `graphics.asl` | [`graphics.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics.asl) `GMU0` |

## UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）FDT（Flattened Device Tree，扁平设备树）

| 取 | 不要取 |
|----|--------|
| `dumps/dagu-20260826-210700-root/dt/fdt.dtb`（`model` 含 dagu，面板含 l81a） | 用 `dtc` 编 Linux 7.0 [`sm8250-xiaomi-dagu.dts`](../linux-mainline/dts/sm8250-xiaomi-dagu.dts) |
| [`tools/install-dagu-fdt.sh`](../tools/install-dagu-fdt.sh) → [`FdtBlob_compat/dagu.dtb`](../port/dagu/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb) | 临时 elish DTB（Device Tree Blob，设备树二进制） |

哈希旁路：同目录 `dagu.dtb.sha256`。

## 驱动对照（不装机）

| 子系统 | Linux 节点 | ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）`_HID` | WOA-Drivers / INF（Information file，驱动信息文件） |
|--------|------------|---|---|
| CPU | `&cpu0`–`&cpu7` / PEP（Power Engine Plugin，电源引擎插件）LPI | `ACPI0007` + `ACPI0010`（[`Pep_lpi.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/Pep_lpi.asl)） | 高通 inbox / SM8250 PEP（Power Engine Plugin，电源引擎插件）包 |
| PEP（Power Engine Plugin，电源引擎插件） | `qcom-cpufreq-hw` / EPSS（Epochal Precise Scaling System，高通 CPU 调频硬件） | `QCOM2430`（[`pep0.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pep0.asl)） | SM8250 PEP（Power Engine Plugin，电源引擎插件） |
| UFS（Universal Flash Storage，通用闪存） | `ufs_mem_hc` `1d84000.ufshc` | `QCOM24A5`（[`ufs.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/ufs.asl)） | [WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers) SM8250 / Cedros UFS（Universal Flash Storage，通用闪存） |
| GPU（Graphics Processing Unit，图形处理器） | `gpu@3d00000` Adreno 650 | `QCOM24B4`（CID `QCOM027E`） | 社区 QCDX；**不是** Snapdragon X UGD；**不是** Mesa Turnip |
| 触控 | `&spi4` `himax,hx83121-dagu` | `HIMA8312` | 自写 [`himax-hx83121/`](../port/dagu/windows-drivers/himax-hx83121/)（协议来自 `himax-dagu.c`；不是 HimaxTouch85x） |
| 显示分辨率 | L81A 1600×2560 | SimpleFb PCD（Platform Configuration Database，平台配置库）+ `XIA00001`（[`display.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/display.asl)） | UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）帧缓冲 + 自写 [`l81a/`](../port/dagu/windows-drivers/l81a/)；不是 Snapdragon X WDDM（Windows Display Driver Model，Windows 显示驱动模型） |
| GPIO（General Purpose Input/Output，通用输入输出） | TLMM（Top Level Mode Multiplexer，顶层引脚复用）`0x0F100000` | `QCOM0C22`（[`himax.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/himax.asl) `GIO0`） | SM8250 GPIO（General Purpose Input/Output，通用输入输出）/ TLMM（Top Level Mode Multiplexer，顶层引脚复用） |
| Wi‑Fi | `pcie0` + QCA6390 | `PNP0A08` + `QCOM24D4` / `QCA6390`（[`pcie.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pcie.asl)） | SM8250 CNSS（Connectivity Subsystem，连接子系统）/ QCA6390；**不要** nabu SM8150 包 |
| 蓝牙 | `&uart6` `qcom,qca6390-bt` | `QCOM2470` + `QCOM2464`（[`bluetooth.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/bluetooth.asl)） | 同芯片 QCA6390 BT（Bluetooth，蓝牙）UART（Universal Asynchronous Receiver-Transmitter，通用异步收发器） |
| USB（Universal Serial Bus，通用串行总线） | `dwc3@a600000` | `QCOM24A6`（[`usb.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/usb.asl)） | SM8250 URS（USB Role Switch，USB 角色切换）/ DWC3（DesignWare USB3 Controller，新思 USB3 控制器） |
| Type-C（USB Type-C，USB C 型接口） | `&pm8150b_typec` | `QCOM24C8`（[`typec.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/typec.asl)） | PM8150B TCPM（Type-C Port Manager，Type-C 端口管理器）；充电先于主机口 |
| 音频 | ADSP（Audio DSP，音频数字信号处理器）+ WCD9385 + CS35L41×4 | `QCOM24A8` / `QCOM24AA` / `CIRR0041`（[`audio.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/audio.asl)） | ADSP（Audio DSP，音频数字信号处理器）走 SM8250 包；功放自写 [`cs35l41/`](../port/dagu/windows-drivers/cs35l41/)（不要 map220v x64 HDA（High Definition Audio，高清音频）） |
| 键盘 | `&i2c2` `nanosic,803` | `NANO0803`（[`keyboard.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/keyboard.asl)） | 自写 [`nanosic-803/`](../port/dagu/windows-drivers/nanosic-803/)；不要 nabu USB 滤镜 |
| 电池 | 双 BQ27Z561 + SMB5 + BQ25970×2 | `BQ270561` / `QCOM24B0` / `BQ270970` / `ACPI0003`（[`battery.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/battery.asl)） | 自写 [`bq27z561/`](../port/dagu/windows-drivers/bq27z561/) + [`dual-fg/`](../port/dagu/windows-drivers/dual-fg/) + [`pm8150b-charger/`](../port/dagu/windows-drivers/pm8150b-charger/)；67W [`bq25970/`](../port/dagu/windows-drivers/bq25970/) |
| 霍尔 | GPIO（General Purpose Input/Output，通用输入输出）110 / 121 | `ACPI0011`（[`buttons.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/buttons.asl)） | inbox GPIO（General Purpose Input/Output，通用输入输出）按键 / 平板模式 |
| 背光 | 双 KTZ8866 | `KTZ8866`（[`backlight.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/backlight.asl)） | 自写 [`ktz8866/`](../port/dagu/windows-drivers/ktz8866/) |
| 传感器 | `&slpi` LSM6DSO / tcs3701 | `QCOM24C0`（[`sensors.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/sensors.asl)） | SM8250 SLPI（Sensor Low Power Island，传感器低功耗岛）/ SSC（Sensors Subsystem Core，传感器子系统核）客户端；**不要** Linux `hexagonrpcd` |
| 热 | TSENS（Temperature Sensor，温度传感器） | `QCOM24E0`（[`thermal.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/thermal.asl)） | SM8250 热区 / PEP（Power Engine Plugin，电源引擎插件）限频 |
| 视频 | `&venus` `0x0aa00000` | `QCOM24B8`（[`venus.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/venus.asl)） | SM8250 Venus；**禁止** CPU 软解当交付 |
| 手写笔充电 | IDT P9418 `@0x3b` | `IDTP9418`（[`pen.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/pen.asl)） | 自写 [`p9418/`](../port/dagu/windows-drivers/p9418/)；侧吸不是 Qi |
| 马达 | PM8150B `@c000` LRA | `QCOM24C4`（[`haptics.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/haptics.asl)） | 自写 [`haptics/`](../port/dagu/windows-drivers/haptics/) |
| 显示 MDSS（Mobile Display Subsystem，移动显示子系统） | `&mdss` DPU（Display Processing Unit，显示处理单元）/ DSI（Display Serial Interface，显示串行接口） | `QCOM24B5` / `QCOM24B6` / `QCOM24B7` | SM8250 QCDX / 社区显示包；面板自写 [`l81a/`](../port/dagu/windows-drivers/l81a/) |
| CDSP（Compute DSP，计算数字信号处理器） | `&cdsp` | `QCOM24C1` | SM8250 FastRPC；禁止 WebNN（Web Neural Network，网页神经网络） |
| SPMI（System Power Management Interface，系统电源管理接口）/ PMIC（Power Management Integrated Circuit，电源管理芯片） | `spmi@c440000` | `QCOM0C09` / `QCOM24D0`–`D2` / `QCOM24E2` | SM8250 SPMI（System Power Management Interface，系统电源管理接口）包 |
| LPASS（Low Power Audio Subsystem，低功耗音频子系统） | `rxmacro` + SoundWire | `QCOM24A9` / `QCOM24AB` | 跟 ADSP（Audio DSP，音频数字信号处理器）走；麦克风 [`wcd9385/`](../port/dagu/windows-drivers/wcd9385/) |
| SMMU（System Memory Management Unit，系统内存管理单元） | `apps_smmu` / `adreno_smmu` | `QCOM24C2` / `QCOM24C3` | SM8250 IOMMU（Input-Output Memory Management Unit，输入输出内存管理单元） |
| IPCC（Inter-Processor Communication Controller，核间通信控制器） | `ipcc@408000` | `QCOM24E4` | SM8250 QRTR（Qualcomm IPC Router，高通核间路由） |
| SMEM（Shared Memory，共享内存） | `0x80900000` | `QCOM00A5` | inbox |
| USB3 QMP（Qualcomm Multi-Protocol PHY，高通多协议物理层） | `&usb_1_qmpphy` disabled | `QCOM24A7` `_STA=0` | 不要宣称 SuperSpeed |
| PS5169 | `&i2c17` disabled | `PRS5169` `_STA=0` | 自写 [`ps5169/`](../port/dagu/windows-drivers/ps5169/)；未训 SuperSpeed |
| 手电筒 | `pm8150l_flash` | `QCOM24E8` | 不是相机通路 |
| 传感器客户端 | `&slpi` | `QCOM24C0` | [`slpi/`](../port/dagu/windows-drivers/slpi/) 只绑 HID（Hardware ID，硬件标识）；协议走 WOA-Drivers SSC（Sensors Subsystem Core，传感器子系统核） |

提取时用设备名 `dagu`，不要 `extract.ps1 elish` / `nabu`。

## 全板覆盖（Linux 已通 vs 本树源码）

对照 [`dagu-adaptation-status.md`](../linux-mainline/docs/dagu-adaptation-status.md) 总览，不只 CPU（Central Processing Unit，中央处理器）/ GPU（Graphics Processing Unit，图形处理器）/ 触控。

| Linux 子系统 | ACPI（Advanced Configuration and Power Interface，高级配置与电源接口） | 自写 INF（Information file，驱动信息文件） | 板上 Windows 仍缺 |
|---|---|---|---|
| 启动 / UFS（Universal Flash Storage，通用闪存） | `ufs.asl` | WOA-Drivers | 分区 / WinPE 未刷 |
| L81A 120Hz | `display.asl` | `l81a/` | WDDM（Windows Display Driver Model，Windows 显示驱动模型）未上板 |
| Adreno 650 | `graphics.asl` + `smmu.asl` | QCDX | 社区包未装 |
| Himax | `himax.asl` | `himax-hx83121/` | `DriverEntry` 仍 stub |
| QCA6390 Wi‑Fi / 蓝牙 | `pcie.asl` / `bluetooth.asl` | SM8250 CNSS（Connectivity Subsystem，连接子系统） | 未装 |
| CS35L41 + WCD9385 + ADSP（Audio DSP，音频数字信号处理器） | `audio.asl` / `lpass.asl` | `cs35l41/` `wcd9385/` | PCM（Pulse Code Modulation，脉冲编码调制）靠 ADSP（Audio DSP，音频数字信号处理器）拓扑 |
| 键盘 / 霍尔 / 电源音量 | `keyboard.asl` / `buttons.asl` | `nanosic-803/` | 音量在 PM8150，不是 TLMM（Top Level Mode Multiplexer，顶层引脚复用） |
| 双电芯 / SMB5 / 67W | `battery.asl` | `bq27z561/` `dual-fg/` `pm8150b-charger/` `bq25970/` | 67W 要 TCPM（Type-C Port Manager，Type-C 端口管理器）先谈 PPS（Programmable Power Supply，可编程电源） |
| KTZ8866 | `backlight.asl` | `ktz8866/` | 亮度 IOCTL（Input/Output Control，输入输出控制）未接 |
| P9418 | `pen.asl` | `p9418/` | 笔 HID（Human Interface Device，人机接口设备）不是这颗 |
| 马达 | `haptics.asl` | `haptics/` | 震感未测 |
| SLPI（Sensor Low Power Island，传感器低功耗岛）/ CDSP（Compute DSP，计算数字信号处理器）/ Venus | `sensors.asl` / `cdsp.asl` / `venus.asl` | `slpi/` + SM8250 包 | 固件 / FastRPC 未上板 |
| Type-C（USB Type-C，USB C 型接口）/ USB HS | `typec.asl` / `usb.asl` | SM8250 URS（USB Role Switch，USB 角色切换） | SuperSpeed `_STA=0` |
| 手电筒 | `led.asl` | — | 不是相机 |
| TSENS（Temperature Sensor，温度传感器）/ SPMI（System Power Management Interface，系统电源管理接口）/ 看门狗 | `thermal.asl` / `pmic.asl` | SM8250 | — |
| S2Idle | PEP（Power Engine Plugin，电源引擎插件）`Pep_lpi.asl` | inbox | 板上未测 |
| NPU（Neural Processing Unit，神经网络处理器）PIL（Peripheral Image Loader，外设镜像加载器） | `npu.asl` | — | 无活 MMIO（Memory-Mapped I/O，内存映射输入输出），只记 `0x86900000` 固件窗 |
| IPA（IP Accelerator，IP 加速器）PIL（Peripheral Image Loader，外设镜像加载器） | `ipa.asl` | — | 无活 CSR（Control and Status Register，控制和状态寄存器）；不要编 `0x1e40000` |

板上**没有**、不要编造的：NFC（Near Field Communication，近场通信）、指纹、独立 GNSS（Global Navigation Satellite System，全球导航卫星系统）芯片、3.5mm、机身 Qi、`/dev/rtc*`。

## 明确不要当本阶段出处

- [`camss-vfe-480.c`](../linux-mainline/overlays/linux/drivers/media/platform/qcom/camss/camss-vfe-480.c) 与全部 `dagu-ife-*.md` — CAMSS（Camera Subsystem，相机子系统）/ IFE（Image Front End，图像前端）/ CCI（Camera Control Interface，相机控制接口）不进 ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）
- 把 `pm8150l_flash` 当成 CAMSS（Camera Subsystem，相机子系统）闪光同步（手电筒节点可以有）
- 把 PS5169 / `&i2c17` / QMP（Qualcomm Multi-Protocol PHY，高通多协议物理层）写成已经训出 SuperSpeed（表里 `_STA=0`）
- 整份 Linux 7.0 DTS（Device Tree Source，设备树源码）当 `FdtBlob_compat/dagu.dtb`
- [`elish-pmos-vs-dagu.md`](../linux-mainline/docs/elish-pmos-vs-dagu.md) 已说明同 SoC（System on Chip，片上系统）不同板，禁止把 elish ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）当 dagu 终稿（`Pep_lpi.asl` 只借用 SoC（System on Chip，片上系统）LPI（Low Power Idle，低功耗空闲））
- nabu SM8150 CNSS（Connectivity Subsystem，连接子系统）/ Nanosic USB 滤镜 / HimaxTouch85x / cs35l41_win x64
- Coresight / ETM（Embedded Trace Macrocell，嵌入式跟踪宏单元）调试块当产品口
- `CONFIG_INTERCONNECT_QCOM_SM8250` / QUPV3 wrapper `firmware-name`

## 主机验收

```bash
./tools/install-dagu-fdt.sh
python3 tools/dagu-linux-to-uefi-map.py
./tools/compile-dagu-acpi.sh
# 可选：./tools/build-dagu-uefi.sh   # 只编，不 flash / 不 fastboot boot
```
