# dagu：USB（Universal Serial Bus，通用串行总线） CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型）控制台

要的是 Type-C（USB Type-C，USB C 型接口）上出 `/dev/ttyACM*`，不是飞线 USB（Universal Serial Bus，通用串行总线）-TTL（Transistor-Transistor Logic，晶体管逻辑电平）。  
规范就是 USB IF（USB Implementers Forum，USB 实施者论坛）的 CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型），和 Linux `CONFIG_USB_G_SERIAL` 同一套。

## 现在就能用（Linux B 槽）

板子默认 USB（Universal Serial Bus，通用串行总线） **device / peripheral**，`g_serial` 枚举 **`0525:a4a7`**，板内 `ttyGS0`，`console=ttyGS0,115200`。

主机：

```bash
python3 tools/dagu-usb-console.py wait
python3 tools/dagu-usb-console.py log          # 跟 printk / getty
python3 tools/dagu-usb-console.py run 'uname -a'
python3 tools/dagu-usb-console.py shell
```

或原来的 `python3 linux-mainline/scripts/dagu-console.py run '…'`。  
要先 `lsusb` 看见 `0525:a4a7`，且不是兔子 `18d1:d00d`。

## UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）启动日志（现在这条才是）

SM8250 固件里已有 `UsbfnDwc3Dxe`（高通 USB（Universal Serial Bus，通用串行总线）功能控制器）。`DaguUsbCdcAcmDxe` 挂在它上面，**不写** DWC3（DesignWare USB3 Controller，新思 USB3 控制器）寄存器，**不开** Mass Storage。

1. PrePI（Pre-EFI Initialization，EFI 前初始化） / 早期 DXE（Driver Execution Environment，驱动执行环境）的 `SerialPortWrite` 打到屏幕，同时写入 `0x9FFF7000` 环缓  
2. `UsbfnDwc3` 起来后枚举 **`0525:a4a7`**  
3. 环缓回放到 bulk IN；Windows 主机装 [`usb-cdc-acm-host/`](../port/dagu/windows-drivers/usb-cdc-acm-host/) 后应出现 COM（Communications Port，通信端口）（inbox `usbser.sys`）；Linux 仍是 `/dev/ttyACM*`，单接口时可能是 `/dev/ttyUSB*`

```text
# Linux 主机
python3 tools/dagu-usb-console.py log

# 单接口 gadget 没有 ttyACM 时
sudo modprobe usbserial vendor=0x0525 product=0xa4a7

# Windows 主机：右键 dagu-uefi-acm.inf → 安装
# 设备管理器 USB Serial Device (0525:a4a7) → PuTTY 115200 8N1
```

PrePI（Pre-EFI Initialization，EFI 前初始化）最早几行要等 Type-C（USB Type-C，USB C 型接口）枚举完才会从环缓吐出。链载这套 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）之前，主机上看不到。枚举期间 Type-C（USB Type-C，USB C 型接口）是 **device**，不是 USB（Universal Serial Bus，通用串行总线）主机。

EFI（Extensible Firmware Interface，可扩展固件接口） UsbFn（USB Function，USB 功能）协议只保证单配置、单接口、两条 bulk，没有 interrupt / iso。这是减配 CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型），不是再抄一份 Linux `g_serial` 双接口。Windows 靠主机 INF（Information file，驱动信息文件）绑 `usbser.sys`。

## Windows / UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）表

| 层 | 落到 | 说明 |
|---|---|---|
| USB（Universal Serial Bus，通用串行总线）功能 | [`usb.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/usb.asl) `ACM0` `QCOM24CC` | VID（Vendor ID，厂商标识）/ PID（Product ID，产品标识） `0525:A4A7`，class `02/02/01` |
| UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口） DXE（Driver Execution Environment，驱动执行环境） | [`DaguUsbCdcAcmDxe`](../port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/DaguUsbCdcAcmDxe/DaguUsbCdcAcmDxe.c) | 挂 `UsbfnDwc3Dxe`；环缓 `0x9FFF7000` |
| 主机 INF（Information file，驱动信息文件） | [`usb-cdc-acm-host/`](../port/dagu/windows-drivers/usb-cdc-acm-host/) | 电脑上 inbox `usbser.sys` |
| 平板 INF（Information file，驱动信息文件） | [`usb-cdc-acm/`](../port/dagu/windows-drivers/usb-cdc-acm/) | 平板上是 UsbFn（USB Function，USB 功能） **function**；`DriverEntry` 仍是 stub |
| 硬件 UART（Universal Asynchronous Receiver-Transmitter，通用异步收发器） | [`dbg-uart.asl`](../port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/dbg-uart.asl) `UR12` `0x00A90000` IRQ（Interrupt Request，中断请求） 389 | 飞线 TP7308/TP7307，1.8V |
| UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口） PCD（Platform Configuration Database，平台配置库） | `PcdDebugUartPortBase=0xA90000` | 不再用 `0x988000`（键盘 I2C（Inter-Integrated Circuit，集成电路总线）） |

**UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）阶段**走 `DaguUsbCdcAcmDxe` + `UsbfnDwc3Dxe`，不靠 Windows `.sys`。  
**Windows 进桌面之后**还要 SM8250 UsbFn（USB Function，USB 功能） + [`usb-cdc-acm/`](../port/dagu/windows-drivers/usb-cdc-acm/) 才能继续出 `0525:a4a7`；那颗 `DriverEntry` 仍是 stub。

链载并在主机上看到 `0525:a4a7` 之前，不能声称「Windows 电脑已经能读 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）启动日志」。本仓库不刷机。

## 明确不要做

```text
# ❌ 再开 Mass Storage / LSMS（Linux Simple Mass Storage，Linux 简易大容量存储） / TestLab 导出 U 盘日志（已卡死 USB（Universal Serial Bus，通用串行总线））
# ❌ 手写 DWC3（DesignWare USB3 Controller，新思 USB3 控制器） gadget 寄存器当 CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型）
# ❌ 手写 GENI（Generic Interface，高通通用串行引擎） @0xa90000（没 SE（Serial Engine，串行引擎） IRAM（Internal RAM，内部随机存储器） 固件会踩 QHEE（Qualcomm Hypervisor Execution Environment，高通虚拟机监控执行环境））
# ❌ 说 Type-C（USB Type-C，USB C 型接口） SBU（Sideband Use，边带） 已出 UART（Universal Asynchronous Receiver-Transmitter，通用异步收发器）（S7301 未贴）
# ❌ 把 0x988000 当调试串口
# ✅ Linux：g_serial + tools/dagu-usb-console.py
# ✅ UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）：DaguUsbCdcAcmDxe + UsbfnDwc3 + 0x9FFF7000 环缓
# ✅ Windows 主机：usb-cdc-acm-host 绑 usbser.sys 到 0525:a4a7
```
