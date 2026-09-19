# dagu 自写 Windows 驱动

没有现成 ARM64 INF（Information file，驱动信息文件）的外设，按网上资料 + 本板 Linux overlay 自己写。  
编 `.sys` 要 Windows WDK（Windows Driver Kit，Windows 驱动工具包）+ Visual Studio，主机 Linux 只维护源码。测试签名，未 WHQL（Windows Hardware Quality Labs，Windows 硬件质量实验室）。

总线：ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）里 `QCOM0C10` / `QCOM0C11` + `I2cSerialBusV2` / `SPISerialBus`。外设走微软 SPB（Simple Peripheral Bus，简单外设总线）Resource Hub，**不要**自己碰 GENI MMIO（Memory-Mapped I/O，内存映射输入输出）（那会踩 QHEE（Qualcomm Hypervisor Execution Environment，高通虚拟化执行环境））。SPMI（System Power Management Interface，系统电源管理接口）子设备走 `QCOM0C09`，同样不要手写仲裁器。

I2C（Inter-Integrated Circuit，内部集成电路）控制器 INF（Information file，驱动信息文件）用 [WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers) **SM8250** 包里的 `ACPI\QCOM0C10`，禁止 nabu SM8150。

## 网上查到的，和我们怎么用

| 芯片 | 网上有什么 | 不能照抄 | 本仓库 |
|---|---|---|---|
| Himax HX83121 | [WOA-Project/HimaxTouch85x](https://github.com/WOA-Project/HimaxTouch85x) 是 HX852x KMDF（Kernel-Mode Driver Framework，内核模式驱动框架）；Himax 新闻说 HX83121-A 在小米 Book S 上走 HID（Human Interface Device，人机接口设备） | 852x 协议不是 83121；dagu 安卓是 SPI（Serial Peripheral Interface，串行外设接口）`0x30` 不是 inbox I2C-HID | `himax-hx83121/` 搬 [`himax-dagu.c`](../../../linux-mainline/overlays/linux/drivers/input/touchscreen/himax-dagu.c)：`[0xF3,0x30,0x00]` + 56 字节，坐标 /8，校验和 mod 256 |
| Nanosic 803 | [NabuNanosicFilter](https://github.com/woa-msmnile/NabuNanosicFilter) 修 Win11 22621+ 触控板 Usage；[map220v/MiPad5-Drivers](https://github.com/map220v/MiPad5-Drivers) 是 nabu **USB** HID（Human Interface Device，人机接口设备） | dagu 是 GENI I2C（Inter-Integrated Circuit，内部集成电路）`@0x4c`，不是 USB | `nanosic-803/` 搬 [`nanosic-dagu.c`](../../../linux-mainline/overlays/linux/drivers/input/keyboard/nanosic-dagu.c)；触控 Usage 用 `0x04`（Touch Screen）避开那个 BSOD（Blue Screen of Death，蓝屏） |
| KTZ8866 | 只有 Linux [`ktz8866.c`](https://github.com/torvalds/linux/blob/master/drivers/video/backlight/ktz8866.c) | 没有 Windows 包 | `ktz8866/`：`0x02=0x52`，亮度 `0x04/0x05`，下限 32，禁止拉 GPIO（General Purpose Input/Output，通用输入输出）139 |
| CS35L41 | [map220v/cs35l41_win](https://github.com/map220v/cs35l41_win) 绑 `ACPI\10133541`，x64 HDA（High Definition Audio，高清音频） | PCM（Pulse Code Modulation，脉冲编码调制）在 dagu 走 ADSP（Audio DSP，音频数字信号处理器）`QCOM24A8`，不是 HDA（High Definition Audio，高清音频） | `cs35l41/` 只绑 `CIRR0041` 做 I2C（Inter-Integrated Circuit，内部集成电路）探测；出声仍靠 ADSP（Audio DSP，音频数字信号处理器） |
| WCD9385 | 公开章只有 SoundWire + ADSP（Audio DSP，音频数字信号处理器）拓扑 | 不要 inbox HDA（High Definition Audio，高清音频） | `wcd9385/` 绑 `QCOM24AA`；复位 GPIO（General Purpose Input/Output，通用输入输出）32；AMIC5 / ADC4 INP5 |
| BQ27Z561 | TI 电量计公开命令 `0x08/0x0C/0x2C` | TI 不提供 Windows 驱动 | `bq27z561/` 双颗 `@0x55`（`IC13` 左 + `IC00` 右） |
| 双电芯合成 | 只有本树 [`xiaomi-dual-fg.c`](../../../linux-mainline/overlays/linux/drivers/power/supply/xiaomi-dual-fg.c) | 不要平均 SoC（State of Charge，荷电状态）当唯一算法 | `dual-fg/`：FCC（Full Charge Capacity，满充容量）加权，`>96%` 显示 100；GPIO（General Purpose Input/Output，通用输入输出）117/91 保持无效 |
| PM8150B SMB5 | Linux [`pm8150b-charger-dagu.c`](../../../linux-mainline/overlays/linux/drivers/power/supply/pm8150b-charger-dagu.c) | 5 V 主路径，不是 PPS（Programmable Power Supply，可编程电源） | `pm8150b-charger/` 绑 `QCOM24B0` |
| BQ25970 | TI [SLUAA33](http://www.ti.com/lit/pdf/sluaa33)：PPS（Programmable Power Supply，可编程电源）在 TCPM（Type-C Port Manager，Type-C 端口管理器），泵自己没有环 | TI 不提供 Windows 驱动 | `bq25970/` 搬 [`bq2597x-dagu.c`](../../../linux-mainline/overlays/linux/drivers/power/supply/bq2597x-dagu.c)：`0x13` ID、`0x0C` bit7 开关 |
| P9418 | [Renesas 短数据手册](https://www.renesas.com/en/document/sds/p9418-short-form-datasheet)；Linux `idtp9418` | 笔本体 HID（Human Interface Device，人机接口设备）不是这颗 TX | `p9418/` 搬 [`p9418-dagu.c`](../../../linux-mainline/overlays/linux/drivers/power/supply/p9418-dagu.c)：在位 = GPIO（General Purpose Input/Output，通用输入输出）145 |
| PS5169 | Parade 公开 ID `0xAC/0xAD` = `0x87/0x69`；Linux [`ps5169-dagu.c`](../../../linux-mainline/overlays/linux/drivers/usb/misc/ps5169-dagu.c) | 产品 `&i2c17` 仍 disabled | `ps5169/` 绑 `PRS5169`；ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）`_STA=0` |
| PM8150B LRA | Linux `pmi632-vib` 同 `0x46`/`0x40` | 不是 GPIO（General Purpose Input/Output，通用输入输出）方波 | `haptics/` 绑 `QCOM24C4` |
| L81A | [`panel-xiaomi-dagu-l81a.c`](../../../linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c) | 不是 elish NT36523 C-PHY（MIPI CSI-2 C-PHY，三相物理层） | `l81a/` 绑 `XIA00001`：1600×2560 120 DSC（Display Stream Compression，显示流压缩） |
| SLPI（Sensor Low Power Island，传感器低功耗岛） | Linux `&slpi` + SEE | 不要 AP I2C（Inter-Integrated Circuit，内部集成电路）猜 LSM6DSO | `slpi/` 只绑 `QCOM24C0`；协议走 SM8250 SSC（Sensors Subsystem Core，传感器子系统核） |
| USB（Universal Serial Bus，通用串行总线） CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型） | Linux `CONFIG_USB_G_SERIAL` `0525:a4a7` | 不要复活 Mass Storage / LSMS（Linux Simple Mass Storage，Linux 简易大容量存储） | 平板侧 `usb-cdc-acm/` 绑 `QCOM24CC`（Windows 进桌面后仍是 stub）；主机侧 [`usb-cdc-acm-host/`](usb-cdc-acm-host/) 把 inbox `usbser.sys` 绑到 `USB\VID_0525&PID_A4A7`。UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）阶段不靠这颗 `.sys`，走 `DaguUsbCdcAcmDxe` |

## 走 WOA-Drivers SM8250、不在本目录重写的

UFS（Universal Flash Storage，通用闪存）`QCOM24A5`、Adreno `QCOM24B4`、CNSS（Connectivity Subsystem，连接子系统）`QCA6390`、URS（USB Role Switch，USB 角色切换）`QCOM24A6`、ADSP（Audio DSP，音频数字信号处理器）`QCOM24A8`、Venus `QCOM24B8`、PEP（Power Engine Plugin，电源引擎插件）`QCOM2430`、GPIO（General Purpose Input/Output，通用输入输出）`QCOM0C22`、SPMI（System Power Management Interface，系统电源管理接口）`QCOM0C09`、SMMU（System Memory Management Unit，系统内存管理单元）、IPCC（Inter-Processor Communication Controller，核间通信控制器）、SMEM（Shared Memory，共享内存）。禁止 nabu SM8150 包。

## 还没做完（板上 + WDK（Windows Driver Kit，Windows 驱动工具包））

- 各 `.c` 的 `DriverEntry` / `EvtDeviceAdd` / HID（Human Interface Device，人机接口设备）miniport 配对还要按 WDK（Windows Driver Kit，Windows 驱动工具包）样本补全才能出 `.sys`
- 亮度要接到 Windows 显示器亮度 IOCTL（Input/Output Control，输入输出控制）
- 67W 要等 Type-C（USB Type-C，USB C 型接口）TCPM（Type-C Port Manager，Type-C 端口管理器）先谈 PPS（Programmable Power Supply，可编程电源）
- 四颗功放的 wmfw 要等 ADSP（Audio DSP，音频数字信号处理器）拓扑，禁止把 x64 HDA（High Definition Audio，高清音频）包装上 ARM64
- PS5169 / QMP（Qualcomm Multi-Protocol PHY，高通多协议物理层）要等 SuperSpeed 训完再把 `_STA` 改成 `0xF`
- 相机 / CAMSS（Camera Subsystem，相机子系统）/ IFE（Image Front End，图像前端）/ CCI（Camera Control Interface，相机控制接口）不在本目录

```text
# ❌ 装 nabu Nanosic USB 滤镜当 dagu 键盘
# ❌ 装 HimaxTouch85x 当 HX83121
# ❌ 装 cs35l41_win x64
# ❌ 外设 KMDF 直接 map 0x990000
# ❌ AP I2C 猜 LSM6DSO
# ✅ QCOM0C10/0C11 + SPB + 本目录协议
```
