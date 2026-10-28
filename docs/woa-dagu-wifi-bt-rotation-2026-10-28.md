# dagu Windows 11 ARM：Wi-Fi / 蓝牙 / 屏幕旋转适配方案

记录触摸屏跑通之后，下一阶段三个功能的硬件事实、已经就位的部分、还要做的事，以及
每一步需要的设备操作。写在动手大改之前，省得每次被上下文清理后又从头考证。

适配顺序：**蓝牙 → Wi-Fi → 旋转**。蓝牙和 Wi-Fi 共用 QCA6390 的上电时序，蓝牙走
UART 最独立、最容易单独验证；Wi-Fi 走 PCIe，最大最难；旋转是探索性的。触摸延迟的
修复（已提交 `1550f3b`）搭下一次设备周期一起验证。

---

## 0. 公共背景：QCA6390 一颗芯片

Wi-Fi、蓝牙、FM 都在 QCA6390 里。两条独立的主机接口：

- **Wi-Fi**：PCIe0（`pcie@1c00000`），subsys `PCI\VEN_17CB&DEV_1101&SUBSYS_010817CB`。
- **蓝牙**：QUP0 SE6 UART（`serial@998000`，3 Mbps），HCI。

上电（Linux `qca6390-pmu` + dagu dts 覆盖）：

- 共用 SoC 轨：`vreg_s6a_0p95`、`vreg_s8c_1p35`、`vreg_s5a`（dagu 改成 2.0V）、
  `vreg_s4a_1p8`。这些轨给很多外设供电，**开机 XBL/ABL 基本都已经打开**。
- `vreg_l16a_3p0`（vddasd，天线开关）：Linux 用一个 pwrseq 补丁**手动**打开，是最
  可能开机没开的一条。
- `WLAN_EN = gpio20`、`BT_EN = gpio21`：func gpio、输出、拉高即打开 QCA6390 内部
  的虚拟 LDO（PMU）。轨没上就拉高只会让芯片"半供电"，不会烧。

TLMM func 号（`pinctrl-sm8250.c`）：gpio16-19 = qup6（BT UART），gpio20/21 = gpio，
gpio79-81 = PCIe0（PERST/CLKREQ/WAKE，CLKREQ func pci_e0）。

---

## 1. UEFI 侧已经就位的部分（DaguQupDxe）

`winarm/overlay/xiaomi-dagu/Driver/DaguQupDxe/DaguQupDxe.c` 为触摸做的那套，顺手也把
蓝牙 UART 的前置都做了：

- `ApplyClock`：打开 `gcc_qupv3_wrap0_s6_clk`（SE6）等 QUP 时钟，并在
  ExitBootServices 时 `KeepClocks` 续上。
- `MuxQup`：把 gpio16-19 设成 func qup6、拉高、2mA；gpio20/21 先设成**输出拉低**
  （等轨投票后再拉高）。
- `LoadSe(SE6_BASE, PROTO_UART, "SE6")`：从 `qupv3fw.elf` 把 UART protocol 固件写进
  SE6 的 IRAM（FIFO 模式，不写 wrapper CSR —— 写了会掉 fastboot）。

也就是说，**SE6 的时钟、引脚、GENI UART 固件都已经好了**，Windows 侧只要有一个
SerCx2 驱动来跑它就行。

### 还缺：QCA6390 上电 + 拉高 enable

这是蓝牙和 Wi-Fi 共同的硬件前置。难点是两件事只有上板子才知道答案：

1. dagu 的 Kona UEFI 到底发布了哪个调压器协议；
2. 开机时哪些轨已经开着，PMIC device index / LDO-SMPS 编号怎么对。

本仓已经确认 `EFI_QCOM_PMIC_VREG_PROTOCOL`（GUID `22d38d3d-…`，见
`edk2-msm/.../Protocol/EFIPmicVreg.h`）被本固件自带的 UFSDxe / UsbConfigDxe 消费，
所以运行期**大概率**能 LocateProtocol 到。协议接口很干净：
`VregControl(dev, id, enable)`、`VregGetStatus`、`VregSetLevelUv`。

Linux 轨名到枚举的推测映射（"a"=PM8150 主 PMIC，"c"=PM8009）：

| Linux 轨 | 猜测 | 作用 |
|---|---|---|
| vreg_s5a（2.0V） | pmic0 `EFI_PM_SMPS_5` | WCN 主轨 |
| vreg_s4a_1p8 | pmic0 `EFI_PM_SMPS_4` | 1.8V |
| vreg_s6a_0p95 | pmic0 `EFI_PM_SMPS_6` | 0.95V |
| vreg_s8c_1p35 | pmic? `EFI_PM_SMPS_8` | 1.35V（PM8009） |
| vreg_l16a_3p0 | pmic0 `EFI_PM_LDO_16` | 天线开关 vddasd |

**先探后写**（和触摸的打法一样）。已经在 DaguQupDxe 里写好一个只读探针
`ProbeWcnPower()`（默认注释掉，和 `ProbeHimax` 一个模式）：

- LocateProtocol 这个 VREG 协议，打不到就打印说明（意味着只能靠 XBL）。
- 对 pmic device 0..3、候选轨 SMPS4/5/6/8 + LDO9/16 逐个 `VregGetStatus` +
  `VregGetLevel`，打印 en / ok / mode / 电压。
- 打印 gpio20/21 当前电平，然后把它们拉高，再读一遍（看芯片 power-good 反馈）。
- 屏幕上 hold 60 秒。

跑一次这个探针（刷一版把 `ProbeWcnPower()` 取消注释的 UEFI），就能确定协议可用性、
哪些轨已经开、编号怎么对，再把最小的 enable 序列写进正常启动路径（大概就是：确保
L16 开 + 拉高 gpio20/21 + 适当延时）。

---

## 2. 蓝牙（第一优先）

### 2.1 目标驱动（已下载，暂存本地不入库）

Microsoft Update Catalog 的 ARM64 QCA6390 蓝牙 UART 传输驱动：
`/tmp/qcacat/r1780_a362c8f6/qcbtfmuart_hst8180.inf`（rev 1.0.1780.3，2022-08），
自带固件 `htbtfw20.tlv` + `htnv20.bin`（和 Linux 的 `qca/htbtfw20.tlv` 同支）。

绑定 ID（关键）：

```
ACPI\VEN_QCOM&DEV_0471&SUBSYS_MTPC8180   (以及 MTPE/MTPF/CLSD/CLSC 8180)
```

Windows ACPI 用 `_HID` + `_SUB` 合成这个 compat id：
- `_HID = "QCOM0471"` → `VEN_QCOM&DEV_0471`
- `_SUB = "MTPC8180"` → `SUBSYS_MTPC8180`

### 2.2 要改 ACPI 拓扑

当前 `edk2-msm/.../AcpiTables/dagu/bluetooth.asl` 是 Linux 式拓扑（UAR6 `_HID
QCOM2470` 带 Memory+IRQ，子节点 BTH0 `_HID QCOM2464`），**不匹配**上面的目录驱动。
要改成 MTP 式：

- 一个 **UART 控制器节点**（SerCx2），`_HID` 用 dagu 自己的（见 2.3），`_CRS` 给
  SE6 的 Memory `0x00998000/0x4000` + Interrupt（GIC SPI 607 → ACPI 639）。
- 一个 **BT 设备节点**：`_HID "QCOM0471"`、`_SUB "MTPC8180"`、`_CRS` 里放一条
  `UARTSerialBus()`（波特率、校验、流控、指向上面的 UART 控制器路径）+ host-wake 的
  `GpioInt` + （可选）`BT_EN` 的 `GpioIo`。

`UARTSerialBus()` 的具体参数（流控/校验/控制器路径）要抄 MTP 参考 DSDT 的 UART+BT
节点。还要把 `bluetooth.asl` 加进 `build-dagu-uefi.sh` 的 `DSDT_ONLY` 白名单一起编。

### 2.3 SE6 的 SerCx2 UART 驱动（蓝牙的关键门槛）

`qcbtfmuart` 只是 HCI 传输层，底下必须有一个把 GENI UART 暴露成 SerCx2 的驱动。

- **先试**库存 `qcuart8250`。但 `qcspi8250` 之前就是一挂到 SE4 就把启动卡死（GENI/
  GPI/SMMU 那套 dagu 没有），`qcuart8250` 很可能同样卡。
- **大概率要自己写**一个 SE6 GENI UART 的 SerCx2 驱动，照微软 SerPL011
  （`/tmp/rpi-iot/drivers/uart/bcm2836/serPL011/`，KMDF+SerCx2，PIO 无 DMA）的骨架，
  寄存器按 `drivers/tty/serial/qcom_geni_serial.c`。WDK 的 `sercx.h` 在
  `.../10.0.26100.0/km/sercx/2.0/`。这和当初写 himax 驱动一个量级的工作量。
  好在 DaguQupDxe 已经把 SE6 时钟/引脚/固件备好，驱动不用碰 PEP/SMMU/GPI。

### 2.4 部署固件

`htbtfw20.tlv` + `htnv20.bin` 跟驱动一起，走 WinPE service mode
（`tools/winarm/deploy-windows.sh`，`startnet.cmd` 里 `dism /Add-Driver /Recurse
/ForceUnsigned`），把驱动目录拷进 `/mnt/woa-pe/woa/drivers/`。

### 2.5 蓝牙步骤小结

1. 刷带 `ProbeWcnPower()` 的 UEFI，拍屏，确定轨状态 + 协议 + 编号。
2. 把最小 enable 序列写进 DaguQupDxe 正常路径。
3. 改 `bluetooth.asl` 成 MTP 拓扑（QCOM0471 + _SUB + UARTSerialBus），加进 DSDT_ONLY。
4. SE6 SerCx2：先试 `qcuart8250`；卡启动就自己写。
5. 部署 `qcbtfmuart_hst8180` + 两个固件，进 Windows 看蓝牙电台起没起来。

---

## 3. Wi-Fi（第二优先）

### 3.1 目标驱动（已下载）

`/tmp/qcacat/b5e721f8/qcwlan6800sc8180.inf` + `qcwlan6800sc81.sys`（ARM64），绑
`PCI\VEN_17CB&DEV_1101&SUBSYS_010817CB` —— dagu subsys `17CB:0108` 正好对上。固件
`WLAN.HST.1.0.1 QCAHSTSWPLZ_V2_TO_X86`（和 Linux 同支）。board data 换成 dagu 的
`bd_l81a.elf`。

### 3.2 要做的

- **UEFI PCIe0 bring-up**（最大块）：按 Linux `pcie-qcom` + `phy-qcom-qmp-pcie` 把
  控制器 + PHY + 时钟 + link training 跑起来（parf `0x01c00000`，dbi `0x60000000`，
  config `0x60100000`，PERST=gpio79，CLKREQ=gpio80，WAKE=gpio81，MSI SPI 141-148）。
  dagu 没有 PEP，和触摸一样得自己做电源/时钟/链路初始化（放 DaguQupDxe 式的 DXE）。
- **ACPI**：写 PCI0（`PNP0A08`）根桥节点（现有 `pcie.asl` 只是 stub）。
- **MCFG**：删掉那条过时的 PCIe1 项（PCIe1/2 本来就 disabled）。
- **部署** `qcwlan6800sc8180` + dagu `bd_l81a.elf`。

风险：MSI vs legacy INTx；没有 SMMU 的情况下 DMA（和 UFS 直连 DMA 一个路子）。

---

## 4. 屏幕旋转（第三优先，探索性）

- **手动旋转**：Windows 走 Microsoft Basic Display（`ROOT\BasicDisplay`），很可能
  在 设置→显示→方向 里直接能转。**先让用户在设置里试一下**，能转就先交付手动。
- **自动旋转（重力感应）**：很可能做不了。加速度计 LSM6DSO 挂在 SLPI 传感器 DSP 的
  内部 SPI（instance 3，CS0，9.6MHz，IRQ122，见
  `dumps/.../sm8250_lsm6dso_0.json`），AP 够不着，要整套 SLPI/SSC/FastRPC，而这又
  依赖 PEP —— dagu 跑不了 PEP。目前没有任何 SM8250 WoA 设备把自动旋转做出来过。
  mount matrix `-1,0,0;0,1,0;0,0,-1`，朝向 -x,+y,-z（真要做时的参数）。

---

## 5. 设备操作 / 部署速查

- 平板接在办公室中转机 `10.88.0.31`（SSH `huanghuabin`/`hhb1010`），从构建机走
  easytier overlay 过去。SSH 要 `ConnectTimeout=30`，overlay 第一次可能超时要重连。
- **UEFI 刷写**需要平板在 fastboot：`winarm/out/boot-dagu-uefi-v3.img`（slot A）。
- **触摸 .sys 快速替换**（约 1 分钟）：平板进 Linux（slot B），
  `ntfsfix -d /dev/sda36; mount -o rw /dev/sda36 /mnt/win-rw`，把新 .sys 覆盖到
  `Windows/System32/drivers/` 和 DriverStore 两处，`sync; umount`。
- **新驱动包部署**：WinPE service mode（`\woa\service`），
  `tools/winarm/deploy-windows.sh`。
- Windows 路径下没有 USB，死机不能靠 USB 判断。
- 一个设备周期建议批处理：fastboot 刷 UEFI → 进 WinPE 塞驱动 → 进 Linux 换触摸
  .sys → 进 Windows 验证。

---

## 6. 现状

- 触摸延迟修复：已提交 `1550f3b`，已编译签名，**待设备验证**（看 himax-diag.txt v3
  的 intervalUs，需把注册表 `HimaxDiag` 置 1 才会写诊断文件）。
- 蓝牙/Wi-Fi/旋转：研究完成，ARM64 QCA6390 驱动已下载暂存 `/tmp/qcacat/`。UEFI 的
  SE6 时钟/引脚/固件早已就位；`ProbeWcnPower()` 已写好待跑。
- 下一个设备周期的第一件事：刷带 `ProbeWcnPower()` 的 UEFI，拍屏确定 QCA6390 轨状态。

---

## 7. 相关文档

- [woa-dagu-touch-2026-10-28.md](woa-dagu-touch-2026-10-28.md)：触摸屏适配全过程、延迟分析
- [dagu-woa-debug-handbook.md](dagu-woa-debug-handbook.md)：WoA 调试手册、避坑清单
- [woa-dagu-status-2026-10-26.md](woa-dagu-status-2026-10-26.md)：移植进度
