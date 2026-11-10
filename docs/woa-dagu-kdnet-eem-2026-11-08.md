# dagu：先做 USB（Universal Serial Bus，通用串行总线）上的 KDNET（Kernel Debug Network，内核网络调试）

记录日期：2026-11-08。决定：图形驱动继续停在阶段 22 的系统内存管理单元接口之前，先把内核调试接上。

---

## 1. 决定

下一份要做的工具是 KDNET（Kernel Debug Network，内核网络调试）的传输。传输走 Type-C（USB Type-C，USB C 型接口）上的 EEM（Ethernet Emulation Model，以太网仿真模式），不走无线网络，也不换 WinPE（Windows Preinstallation Environment，Windows 预安装环境）。

接上之后，WinDbg（Windows Debugger，Windows 调试器）停在 `qcdxkm8250.sys` 调用槽 24 的位置，直接看系统内存管理单元接口要的地址。停止码编码先留着，它仍是目前唯一能从一次失败里带回结果的办法。

## 2. 为什么先做这个

阶段 22 的失败发生在写盘之前。伪造槽 24 会变成 WHEA（Windows Hardware Error Architecture，Windows 硬件错误架构）`0x124`；真实走表会让 QHEE（Qualcomm Hypervisor Execution Environment，高通虚拟化执行环境）复位整机，没有转储。每次改垫片都要重启，再靠屏幕上的停止码或回到 B 槽 Linux 读蜂箱。

WinPE（Windows Preinstallation Environment，Windows 预安装环境）启动更短，但复位同样不留转储。覆盖表、垫片和 `qcdxkm8250.sys` 都在现有 Windows 的蜂箱里，换预安装环境还要重做一遍部署。无线网络在进桌面之后能用，引导期的内核调试器不会走无线网卡。

## 3. 要照着学的接法

来源：[Project Aloha 的 KDNET（Kernel Debug Network，内核网络调试）设置](https://aloha.firmware.icu/WindowsDebug/SetupKDNET.html)，同一类参数也写在 [Renegade Project 的 Windows 调试说明](https://renegade-project.tech/en/developers/windows)。

他们改的是 ESP（EFI System Partition，EFI 系统分区）里的 BCD（Boot Configuration Data，启动配置数据）：

```text
bcdedit /store BCD /set "{default}" debug on
bcdedit /store BCD /dbgsettings net hostip:169.254.255.255 port:50000 key:1.1.1.1
```

主机打开 WinDbg（Windows Debugger，Windows 调试器），选择附加到内核、网络，端口 `50000`，密钥 `1.1.1.1`，地址留空。平板用 USB（Universal Serial Bus，通用串行总线）线连上主机后停在 Windows 标志、没有转圈。主机设备管理器里出现网卡 **KdNET EEM**。调试器接上之后，系统才继续加载。

这是 USB（Universal Serial Bus，通用串行总线）以太网仿真，不是平板当前的无线网络，也不是 Linux B 槽上的 RNDIS（Remote Network Driver Interface Specification，远程网络驱动接口规范）`192.168.7.2`。

## 4. 这块板现在缺的一截

| 事实 | 出处 |
|---|---|
| Windows 启动路径上主机看不到 USB（Universal Serial Bus，通用串行总线）设备 | [调试手册](dagu-woa-debug-handbook.md) 第 6 节；[无线与旋转记录](woa-dagu-wifi-bt-rotation-2026-10-28.md) |
| 平板侧 USB（Universal Serial Bus，通用串行总线）串口驱动的 `DriverEntry` 仍是空的 | [USB（Universal Serial Bus，通用串行总线）串口记录](dagu-usb-serial-console.md) |
| UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）的 UsbFn（USB Function，USB 功能）只有单配置、单接口、两条 bulk | 同上。那是减配 CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型），不是 EEM（Ethernet Emulation Model，以太网仿真模式） |
| 仓库的 ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）源码里没有 DBG2（Debug Port Table 2，调试端口表 2） | `port/dagu/` 内无 `DBG2` |

Linux B 槽的 `g_serial`（`0525:a4a7`）和 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）的 `DaguUsbCdcAcmDxe` 已经能在进 Windows 之前出串口。KDNET（Kernel Debug Network，内核网络调试）要的是 Windows 引导期占用同一个 Type-C（USB Type-C，USB C 型接口），让主机出现 KdNET EEM。CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型）和 EEM（Ethernet Emulation Model，以太网仿真模式）不能同时占这个口。

## 5. 第一段工作

1. 从 B 槽 Linux 改 A 槽 ESP（EFI System Partition，EFI 系统分区）里的 BCD（Boot Configuration Data，启动配置数据），参数用第 3 节。先备份原来的 BCD（Boot Configuration Data，启动配置数据）。
2. 调试实验期间不要加载平板侧的 CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型）功能驱动，把口留给 EEM（Ethernet Emulation Model，以太网仿真模式）。
3. 补上引导期能让主机枚举出 **KdNET EEM** 的那一截。微软的 USB（Universal Serial Bus，通用串行总线） EEM（Ethernet Emulation Model，以太网仿真模式）内核调试要求新思 USB（Universal Serial Bus，通用串行总线）3.0 控制器，并用 DBG2（Debug Port Table 2，调试端口表 2）或总线参数指到它。这块板的控制器是已有的 `UsbfnDwc3Dxe`，不新写一套 DWC3（DesignWare USB3 Controller，新思 USB3 控制器）寄存器操作。
4. 验收只用一次已知断点，确认 WinDbg（Windows Debugger，Windows 调试器）在图形驱动碰到系统内存管理单元之前已经接上。断点不要打在会把翻译配成生效的路径上。

`qcsmmu8250.sys` 里槽 24、槽 20 的离线逆向继续用现有的 `tools/winarm/qdis.py`。那一步不另做工具。调试器接上之后，再停在阶段 22 记录的调用点：相对虚拟地址 `0x26772C`。

## 6. 验收

同时满足才算这段做完：

- 主机设备管理器出现 **KdNET EEM**。
- 未打开 WinDbg（Windows Debugger，Windows 调试器）时，平板停在 Windows 标志、没有转圈。
- 调试器接上后系统继续加载，并能在一个不碰 Adreno 系统内存管理单元走表的位置停下。
- 拔掉调试设置后，原来的 Windows 仍能按阶段 22 的方式启动。BCD（Boot Configuration Data，启动配置数据）备份可以还原。

看到网卡但断点进不去，不算完成。只改了 BCD（Boot Configuration Data，启动配置数据）、主机没有 KdNET EEM，也不算完成。

## 7. 不要做

```text
# ❌ 用无线网络当 KDNET（Kernel Debug Network，内核网络调试）
# ❌ 为了调试先做 WinPE（Windows Preinstallation Environment，Windows 预安装环境）
# ❌ 调试期间同时占着 CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型）和 EEM（Ethernet Emulation Model，以太网仿真模式）
# ❌ 手写 DWC3（DesignWare USB3 Controller，新思 USB3 控制器）寄存器，或再开 Mass Storage
# ❌ 调试器还没接上就做下一次槽 24 / 槽 20 上板实验
# ✅ BCD（Boot Configuration Data，启动配置数据）参数照 Aloha：hostip 169.254.255.255，port 50000，key 1.1.1.1
# ✅ 先看到 KdNET EEM，再用已知断点证明接上了
```

## 8. 2026-11-08 已经写进 A 槽、还没进 Windows

平板停在 B 槽 Linux。没有切回 A 槽。这台 Linux 开发机上看不到 KdNET EEM，也没有 WinDbg（Windows Debugger，Windows 调试器）在等。

| 项 | 现在的值 |
|---|---|
| BCD（Boot Configuration Data，启动配置数据）调试类型 | 3，即网络。原来是 4，本地 |
| 主机地址 / 端口 / 密钥 | `169.254.255.255` / `50000` / `1.1.1.1` |
| Windows 11 这一项的内核调试 | 打开。`bootstatuspolicy` 本来就是忽略全部失败 |
| 默认启动项 | 仍是 Windows 11，`{891c662b-d158-11f1-8618-e94c0645019b}` |
| `QCDX` 的 `Start` | 4，不加载。改之前是 3 |
| 垫片 `map` | 蜂箱里没有这个值，驱动默认是 0 |

备份：

- ESP（EFI System Partition，EFI 系统分区）`EFI/Microsoft/Boot/BCD.dagu-safe-20261108`，主机也有一份 `~/dagu-woa/BCD.dagu-safe-20261108`。摘要 `7665f12e2221a95020289f42119269241921fcc1e84409b23212ed98ba4ff0fc`。
- `Windows\System32\config\SYSTEM.dagu-safe-20261108`。摘要 `abd783ccb23ccf8d4249532ecec9a1d51493c8d5e4255956e4a8ac214aeabe9f`。

DBG2（Debug Port Table 2，调试端口表 2）的驱动在 `winarm/overlay/xiaomi-dagu/Driver/DaguKdnetDxe/`。它发布 `0x0A600000` 上的一张表和 `\_SB.URS0`，并在 `ExitBootServices` 时停掉 UsbFn（USB Function，USB 功能）。`DaguUsbCdcAcmDxe` 同样在退出启动服务时放开控制器。这两处都还没编进正在启动的固件，所以下一次进 A 槽仍是「只改了启动配置」的那一试。

下一次进 A 槽之前，另一台 Windows 电脑上的 WinDbg（Windows Debugger，Windows 调试器）要先听端口 `50000`、密钥 `1.1.1.1`。验收命令在 `tools/winarm/kdnet-windbg.txt`。先断 `nt!Phase1Initialization`。这一断不碰 Adreno 的系统内存管理单元。槽 24 的 `qcdxkm8250+0x26772C` 等这一断通过之后再用，垫片 `map` 保持 0。

标志停住并且主机没有 KdNET EEM 时，从 B 槽把 `BCD.dagu-safe-20261108` 拷回 `BCD`。需要人在平板旁进 fastboot，再切回 B 槽。

## 9. 2026-11-08 清盘、QEMU、Windows 已停在调试等待

用 QEMU（Quick EMUlator，快速模拟器）里的 WinPE（Windows Preinstallation Environment，Windows 预安装环境）先格式化了分区 35 和 36，再铺镜像。`qcsmmu8250` 没有装进这套驱动。SPI（Serial Peripheral Interface，串行外设接口）的 SE4 改成了 FIFO（First In First Out，先进先出）。第一次 `bcdedit /debug on` 打在 WinPE（Windows Preinstallation Environment，Windows 预安装环境）自己身上，返回码 1。第二次只重建 BCD（Boot Configuration Data，启动配置数据），`{default}` 上 `debug Yes`。

清盘前的蜂箱和 BCD（Boot Configuration Data，启动配置数据）在主机 `~/dagu-woa/pre-clean-20261108/`。

A 槽已经启动。这台 Linux 开发机的 USB（Universal Serial Bus，通用串行总线）上出现 `045e:064d`，产品名 **KdNet EEM**，接口子类是以太网仿真。平板停在 Windows 标志，没有转圈。调试器还没接上，所以还没有断点。把线换到已经在听 `50000` / `1.1.1.1` 的 Windows 主机上即可。

### 关联文档

[阶段 22（槽 24 / 槽 20）](woa-dagu-gpu-stage22-2026-11-08.md)、
[USB（Universal Serial Bus，通用串行总线）串口](dagu-usb-serial-console.md)、
[调试手册](dagu-woa-debug-handbook.md)、
[图形路线图](woa-dagu-gpu-roadmap.md)。
