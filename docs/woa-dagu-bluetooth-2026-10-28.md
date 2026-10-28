# dagu Windows 11 ARM：蓝牙（QCA6390 / SE6 UART）

QCA6390 的蓝牙走 QUP0 serial engine 6（`serial@998000`，GIC_SPI 607 → ACPI
639）的 GENI UART，HCI。上层是高通现成的传输驱动
`qcbtfmuart_hst8180.sys`（`ACPI\QCOM0471`，`_SUB MTPC8180`），自带固件
`htbtfw20.tlv` + `htnv20.bin`。它通过 ACPI 的 `UartSerialBusV2` + Resource Hub
打开 UART，所以底下必须有一个把 GENI UART 暴露成 SerCx2（Serial Framework
Extension v2，串口类扩展）的控制器驱动。

## 为什么不能用高通自己的 qcuart8250

`qcuart8250.sys`（绑 `ACPI\QCOM2518`）能枚举、能起来（设备管理器里是
`COM1`、无叹号），但 `qcbtfmuart` 一 `CreateFile` 打开它就返回
`STATUS_DEVICE_NOT_READY`（`0xC00000A3`），传输层 Code 10 失败。原因：qcuart
依赖高通电源引擎 PoFx/`qcpep8250` 在 open 时给 SE 上电，而 dagu 装不了那个
PEP（装了就 0x7B / 0x1D5 起不来，UFS0 等 31 个设备会 `_DEP` 它）。

## 自写 SerCx2 PIO 控制器 `dagu-geni-uart`

`port/dagu/windows-drivers/dagu-geni-uart/`：KMDF + SerCx2，PIO/FIFO，不碰
PEP、不碰 GPI DMA、不碰 QUP wrapper CSR、不碰 GCC。它只直接驱动 SE 本地的
GENI UART 寄存器，寄存器序列抄 mainline `qcom_geni_serial.c` 的 FIFO 路径。

依赖 UEFI 阶段留好的环境（和触摸/键盘同一套 `DaguQupDxe`）：

- SE6 已经被 `DaguQupDxe` 载入 UART 协议固件（`GENI_FW_REVISION_RO` proto ==
  UART），GPIO16..19 已 mux 到 qup6；
- QUP0 wrapper AHB/core 时钟和 `gcc_qupv3_wrap0_s6_clk` 还开着（Windows 没有
  高通时钟驱动，没人去关它）；
- QCA6390 已上电，`BT_EN`（gpio21）已被 `DaguPcieDxe` 拉高。

驱动做的：映射 SE6 MMIO（`_CRS` 的 `Memory32Fixed 0x998000/0x4000`）、接
GIC 中断 639、按 `UartSerialBusV2` 描述符配波特率/格式、跑 GENI 的
START_TX / START_READ FIFO 命令、ISR+DPC 把 TX/RX ready 通过 SerCx2 回上去。

### 时钟 / 波特率这一个坑

Windows 侧没有时钟驱动，改不了 `gcc_qupv3_wrap0_s6_clk` 的源频率（而且写
GCC/QUP wrapper CSR 会把 dagu 掉进 fastboot）。只能改 SE 本地
`GENI_SER_M/S_CLK_CFG` 里的分频。所以源频率必须能分出想要的波特率：

- `DaguQupDxe` 原来把 s6 设成 19.2 MHz（TCXO）——分不出 115200 也分不出
  3.2 Mbps，不能用。
- 已改成 **102.4 MHz**（`GPLL0_OUT_EVEN × 128/375`，是 s0 频率表里的真实项）：
  oversampling 16 下 3.2 Mbps 整除（÷32）、115200 误差 0.8%（÷56）。
- `DaguQupDxe` 会把实际拿到的频率打到 PStore 串口环里。如果时钟驱动做不出
  102.4 MHz（退到 100 MHz），3.2 Mbps 会有 2.3% 误差。那时**不用重编**，把
  驱动服务 `Parameters` 下的 `Se6SourceHz`（REG_DWORD）改成实际频率、重载
  `.sys` 即可（和 himax 的调参方式一样）。

### ACPI

`bluetooth.asl`（`port/dagu/...` 和 `edk2-msm/...` 两份保持一致）：

- `UAR6`：`_HID "DAGU0006"`（我们自己的 id，和 qcuart 的 `QCOM2518` 不冲突），
  `_CRS` = `Memory32Fixed 0x998000/0x4000` + `Interrupt 639`。去掉了之前试过
  但没用的 GPIO46 wake 中断（dagu Linux 里本来就没有 BT host-wake GPIO）。
- `BTH0`：`_HID "QCOM0471"` + `_SUB "MTPC8180"`，`_CRS` 里
  `UartSerialBusV2(115200, 8N1, FlowControlHardware, … "\\_SB.UAR6")`。
- 两个节点都**没有** `_DEP PEP0`。

## 构建 / 签名

```bash
tools/winarm/fetch-wdk.sh                         # 只需一次（~1.5 GB，已忽略）
tools/winarm/build-geni-uart.sh                   # 输出 dagu-geni-uart.sys（未签名）
tools/winarm/sign-driver.sh \
    port/dagu/windows-drivers/dagu-geni-uart/dagu-geni-uart.sys
```

`build-geni-uart.sh` 和 himax 的区别：这是 KMDF + SerCx2 驱动，所以链接
`wdfdriverentry.lib wdfldr.lib sercxstubs.lib` + `bufferoverflowfastfailk.lib`，
PE 入口是 `FxDriverEntry`（KMDF loader shim，再调我们的 `DriverEntry`）。
`sign-driver.sh` 的 `Current == Calculated digest` 相同即签名正确；末尾
`Signature verification: failed` 只是我们自签根 CA 不在 osslsigncode 的信任库里，
Windows 侧靠 WinPE 导入的根 CA 信任（和其它 dagu 驱动一样）。

## 部署（需要一次 reflash + 一次 WinPE servicing）

因为 HID 从 `QCOM2518` 改成了 `DAGU0006`、且 `DaguQupDxe` 时钟改了，必须先
重编 UEFI 并刷 `boot_a`（见 `tools/winarm/dagu-uefi-loop.sh`，要 fastboot）。
然后进 WinPE service 模式（`\woa\service`，见 `tools/winarm/winpe/startnet.cmd`）：

1. 把签名后的 `dagu-geni-uart.sys` + `dagu-geni-uart.inf` 放进 `\woa\drivers`
   （`qcbtfmuart_hst8180` 的 `.sys/.inf/.cat` + 两个固件也一起放，固件进
   DriverStore 同目录）；
2. `startnet.cmd` 的 `dism /Add-Driver /Recurse /ForceUnsigned` 会把它们装进
   离线镜像，根 CA 已信任；
3. 进 Windows 看设备管理器：`ACPI\DAGU0006` 应为我们的
   “dagu QCA6390 Bluetooth UART (GENI SE6)”、无叹号；`ACPI\QCOM0471` 的
   “Qualcomm(R) Bluetooth UART Transport Driver” 应从 Code 10 变成正常，
   蓝牙电台出现。

诊断：驱动用 `DbgPrintEx`（`DPFLTR_IHVDRIVER_ID`），用 DebugView 抓
（和 `tools/winarm/wifi-debug/` 同一套）；关掉把 `Parameters\DebugPrint`
设 0。

## 现状（2026-10-28）

- 驱动、INF、ACPI、`DaguQupDxe` 时钟改动都已写好；`.sys` 已交叉编译 + 测试
  签名通过，DSDT 编译 0 error。
- **尚未上板验证**：当前平板在 Windows（`192.168.1.187`），没有接 fastboot
  主机，改了 HID/时钟要先刷 UEFI 才能测。下次有 fastboot 通路时按上面的
  部署步骤走一遍，重点看 PStore 里 `DaguQup clk gcc_qupv3_wrap0_s6_clk` 实际
  拿到多少 Hz，必要时调 `Se6SourceHz`。
