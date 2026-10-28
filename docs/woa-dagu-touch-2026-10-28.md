# dagu Windows 触摸屏适配记录（2026-10-27 至 10-28）

本文记录 Himax HX83121 触摸屏在 dagu 的 Windows 11 ARM 上从“完全没反应”到“能用”的全过程：每一步怀疑什么、怎么验证、结论是什么，包括走错的路。最后一节是还没解决的延迟问题。

前情：Windows 第一次在 dagu 上启动成功的经过见 [dagu-woa-debug-handbook.md](dagu-woa-debug-handbook.md) 第 5 节。

---

## 1. 结论

2026-10-28 中午，触摸在 Windows 里可以正常点击和滑动，但延迟明显（见第 6 节）。

最终能用的方案由下面几部分组成，缺一部分都不行或者没有验证过可以去掉：

| 部分 | 内容 |
|---|---|
| SPI 传输 | 不用 GENI SE4 硬件 SPI，改用 GPIO 软件模拟 SPI（bit-bang）：gpio8=MISO、gpio9=MOSI、gpio10=SCK、gpio11=CS（低有效），SPI 模式 3。和 Linux 正式版 DTS 的 `spi-gpio` 节点一致 |
| 驱动形式 | 自写的 HIDCLASS 小驱动 `himax-hx83121.sys`，内核线程每 2 ms 读一帧，按校验和判断帧是否有效 |
| HID 报告描述符 | 10 指并行模式触摸屏；X/Y 带物理尺寸和单位；触点数上限（Contact Count Maximum）用单独的特性报告 ID 2 |
| PnP / 电源请求 | 全部向下转发给 ACPI 设备（`hid->NextDeviceObject`）。**这是最后补上、补完触摸就能用的一处** |
| 签名 | 自建两级测试证书（根 CA + 代码签名证书），`osslsigncode` 嵌入签名；根证书导入离线镜像，BCD 开 testsigning |
| 构建 | Linux 上交叉编译：mu-aloha 容器里的 clang 18 + lld-link，头文件和库来自 NuGet 的 WDK/SDK 包 |

---

## 2. 过程

### 2.1 第一版：GENI 硬件 SPI，Windows 启动就挂

最早的方案沿用 Windows 的高通驱动：DSDT 里放 `SP04`（SE4 SPI 控制器）给 `qcspi8250`，触摸设备 TPAD 依赖它。

- 加上 SPI 设备后 Windows 启动卡死。二分法定位：只加 GPIO 能启动，加上 SPI 就挂，问题在 SP04 / qcspi8250。
- 发现 qcspi8250 把 SE4 设成 GPI DMA 模式，GPI DMA 需要 SMMU，dagu 没有可用的 SMMU 驱动。把 INF 改成 FIFO 模式（注意 INF 是 UTF-16，要按 UTF-16 改），提交 `f271f99`。
- 用 WinPE 重新注入 FIFO 版 qcspi8250 后还是挂。离线读 SYSTEM 注册表确认 FIFO 设置已经生效，所以不是模式的问题。放弃 qcspi8250。

### 2.2 第二版：自写 HID 驱动，直接操作 SE4

写了一个不依赖 qcspi8250 的 HIDCLASS 小驱动，自己映射 SE4 寄存器、用 FIFO 收发。同时搭好了测试签名流程（`tools/winarm/sign-driver.sh`），DSDT 里的 TPAD 的 `_CRS` 留空，不再依赖 SP04。提交 `8261658`。

Windows 能启动，驱动也绑定上了（没有错误码），但触摸没有任何反应。

### 2.3 在 UEFI 里先把硬件读通

Windows 里没有 USB、没有调试器，只能离线读日志，太慢。于是先在 UEFI 的 `DaguQupDxe` 里加一个探测函数，把读到的数据直接画在屏幕上停 60 秒拍照。中间踩了几个坑：

| 现象 | 原因 | 处理 |
|---|---|---|
| 探测结果一闪而过，拍不到 | DXE 早期 `MicroSecondDelay` 是空操作 | 新写 `DaguStallMs`，直接读 ARM 通用定时器 `CNTVCT_EL0` 忙等 |
| 屏幕显示 `SE4: clocks off, MMIO skipped` | 时钟检查用的名字和 UEFI 时钟协议对不上，`ClockOn()` 误报关闭，跳过了加载 SE4 固件 | 总线时钟门判断改为 `Bus = TRUE`（AHB/core 时钟实际是开的） |
| SE4 加载了，按压时中断线会拉低，但数据全是 `0xFF` | 见下一行 | — |
| 全 `0xFF` | Linux 驱动 `himax-dagu.c` 里有一句注释，把全 `0xFF` 归因于 MOSI/MISO/CLK/CS 顺序或 CS 极性。再看 Linux 正式版 DTS，用的是 `compatible = "spi-gpio"`，GENI 版本只是一个关掉的实验文件 | 改用 GPIO 软件模拟 SPI |

换成软件模拟 SPI 后，UEFI 探测第一次读到真实坐标：中断线拉低 96 次、有效数据 12 字节，两个触点换算后是 (349,1725) 和 (614,1046)，在 1600×2560 范围内。硬件通路到这里确认是好的。

### 2.4 Linux 上交叉编译 Windows 驱动

要把软件模拟 SPI 移植进 Windows 驱动，需要能自己编译 `.sys`：

- 从 NuGet 下载 `microsoft.windows.wdk.arm64`、`microsoft.windows.sdk.cpp`、`microsoft.windows.sdk.cpp.arm64`（10.0.26100.4204）。
- 这些头文件互相 `#include` 时大小写不统一，只在不区分大小写的文件系统上能用。做法是把所有路径和 `#include` 里的文件名都改成小写。现在由 `tools/winarm/fetch-wdk.sh` 完成。
- `tools/winarm/build-himax-sys.sh` 在 mu-aloha 容器里用 clang 18 编译、lld-link 链接。

### 2.5 驱动读到了数据，Windows 不理

软件模拟 SPI 移植进 Windows 驱动后，触摸还是没反应。为了不再瞎猜，驱动加了诊断：每 128 次轮询把计数器写到 `C:\Windows\himax-diag.txt`，回到 Linux 后挂载 Windows 分区读出来。

第一份诊断就说明数据通路是好的：

```
flags=15 iter=8192 irqlow=500 spiok=8192 evtok=8135 readirp=380 complete=379 active=196
```

线程在跑、SPI 每次都成功、帧校验通过、Windows 发来读请求、驱动也交了报告、检测到了触点。之后加了坐标记录，让用户按左上角和右下角：

```
touch=382 lastN=1 xy=1563,2483 xrange=69-1563 yrange=67-2555
```

坐标范围覆盖整块屏，解码正确。也就是说，**驱动交给 Windows 的报告是对的，但 Windows 没有把它当触摸处理**。

这一步也顺带改了两处：驱动自己配置 gpio39（中断线）为输入加上拉，不再依赖 UEFI；轮询不再以 gpio39 电平为前提，每次都读，由校验和决定帧是否有效。

### 2.6 三次修描述符和特性报告，都不是关键

| 次序 | 改动 | 依据 | 结果 |
|---|---|---|---|
| 1 | X/Y 加物理最小/最大值、单位、单位指数（面板约 6.57″×10.51″，即 657×1051，单位 0.01 英寸） | 微软触摸屏规范要求这些项，缺了“设备不会正常工作” | 没变化 |
| 2 | `IOCTL_HID_GET_FEATURE` 改为按 `HID_XFER_PACKET` 填 `reportBuffer` | 旧代码把输入缓冲区当成裸字节写，写坏了结构体 | 没变化。后来的诊断显示 `feat=0`：Windows 从来没调用过这个请求 |
| 3 | 触点数上限的特性报告改用单独的报告 ID 2 | 微软示例描述符就是这么做的 | 没变化 |

第 3 条当时我用 Linux 的 uhid 做了验证：旧描述符没有生成输入设备，新描述符生成了，于是认定这是根因。**这个结论是错的。** 那次对比同时改了两个变量：第一版测试程序不回应 `GET_REPORT`，第二版回应了。事后补做对照：保留共用报告 ID 1、但回应 `GET_REPORT`，hid-multitouch 一样能生成输入设备。所以 uhid 实验里起作用的是“回应特性报告请求”，不是报告 ID。三处改动都留在代码里（它们本身符合规范，没有坏处），但都不是触摸失效的原因。

### 2.7 确认 Windows 根本没有创建触摸屏设备

改用更可靠的证据：

1. 把 SYSTEM 注册表和 `SYSTEM.LOG2` 拉回构建机，用 regipy 回放事务日志（138 处改动）后查看：`ACPI\HIMA8312\0` 绑定了驱动、`ConfigFlags=0`，但 `ControlSet001\Enum\HID` 整个不存在。
2. 怕注册表快照不准（硬重启会丢没刷盘的数据），又在 Windows 启动文件夹放了 PowerShell 脚本，登录桌面后把设备列表写到 `C:\Users\Public\touchdiag.txt`，并强制刷盘。结果：`HIDClass` 类只有一个设备，就是 `ACPI\HIMA8312\0` 本身，状态 OK，没有任何设备报错。

结论：HIDCLASS 加载在我们的设备上，也在收报告，但从来没有枚举出“HID 兼容触摸屏”这个子设备。没有子设备，Windows 的触摸栈就不会来读报告，所以 `feat=0`。

### 2.8 真正的问题：PnP 和电源请求没往下传

回头检查驱动里一直没怀疑过的部分，发现 `PnpDispatch` 和 `PowerDispatch` 把所有请求都在本层完成，从不交给下层的 ACPI 设备：

- `IRP_MN_START_DEVICE`：自己启动硬件后直接完成，ACPI 设备没有被启动。
- 其他 PnP 请求（包括查询子设备的 `IRP_MN_QUERY_DEVICE_RELATIONS`）：直接用 IRP 里原有的状态完成。
- 电源请求：直接返回成功，没有 `PoCallDriver`。

`hidport.h` 里写明了 HID 小驱动要把请求发给 `NextDeviceObject`。改法：

- START：先用 `IoForwardIrpSynchronously` 交给下层，成功后再启动触摸硬件。
- 其他 PnP 请求：`IoSkipCurrentIrpStackLocation` 后 `IoCallDriver` 往下传。
- 电源请求：`PoStartNextPowerIrp`、`IoSkipCurrentIrpStackLocation`、`PoCallDriver`。

改完这一处，触摸就能用了。

具体是哪个请求导致子设备不被创建，我没有验证。这一版驱动的诊断文件会记录收到的每个 PnP 请求号、查询子设备请求到达时 IRP 里原有的状态、下层 START 的返回值，下次回到 Linux 读 `C:\Windows\himax-diag.txt` 就能看到（`pnp=`、`qdrInStatus=`、`lowerStart=` 几项）。

---

## 3. 驱动现在的结构

源文件 `port/dagu/windows-drivers/himax-hx83121/himax-hx83121.c`：

- `DriverEntry` 调 `HidRegisterMinidriver`，`DevicesArePolled = FALSE`。
- `StartDevice` 映射三块寄存器：gpio8-11 所在的 TLMM NORTH（`0x0F908000`）、gpio39 所在的 TLMM SOUTH（`0x0F527000`）、SE4（`0x00990000`，现在只是可选，软件 SPI 用不到）。然后起一个内核线程。
- 线程每 2 ms：软件 SPI 发 `[0xF3, 0x30, 0x00]`，收 56 字节；全 `0xFF` 或校验和不为 0 的帧丢弃；有效帧按 Linux 驱动的格式解码（10 个触点，每个 4 字节，坐标除以 8，触点数在第 52 字节）。
- 有触点时完成挂起的读请求；从有触点变成无触点时发一个触点数为 0 的报告。
- `IOCTL_HID_GET_FEATURE` 返回报告 ID 2、触点上限 10。
- 诊断写入 `\SystemRoot\himax-diag.txt`。

INF 不变（`himax-hx83121.inf`，硬件 ID `ACPI\HIMA8312`）。已安装在 Windows 里的是 `oem76.inf`。

UEFI 侧 `winarm/overlay/xiaomi-dagu/Driver/DaguQupDxe/DaguQupDxe.c`：保留 `Bus = TRUE` 的修正和探测代码，`ProbeHimax()` 调用已注释掉，正常启动不会再停 60 秒。

---

## 4. 工具和流程

### 4.1 构建和签名

```bash
tools/winarm/fetch-wdk.sh                      # 只需一次，约 1.5 GB，放在 winarm/wdk/（已忽略）
tools/winarm/build-himax-sys.sh                # 输出 port/dagu/windows-drivers/himax-hx83121/himax-hx83121.sys
tools/winarm/sign-driver.sh port/dagu/windows-drivers/himax-hx83121/himax-hx83121.sys
osslsigncode verify port/dagu/windows-drivers/himax-hx83121/himax-hx83121.sys   # Current/Calculated digest 应相同
```

注意 `sign-driver.sh` 要带 `.sys` 路径作参数，不带参数它只生成证书，不签名，也不报错。

### 4.2 换驱动：直接替换文件，约 1 分钟

一开始每次换驱动都跑 WinPE + DISM（QEMU 软件模拟，13 到 15 分钟）。后来改为在 Linux 里直接覆盖文件，因为驱动已经装好，INF、服务、注册表、信任的证书都不变，只有 `.sys` 在变，而 Windows 加载时只检查嵌入的签名：

```bash
ntfsfix -d /dev/sda36                 # Windows 没有正常关机，NTFS 脏标记会让 ntfs-3g 拒绝读写挂载
mount -o rw /dev/sda36 /mnt/win-rw
cp himax-hx83121.sys /mnt/win-rw/Windows/System32/drivers/
cp himax-hx83121.sys /mnt/win-rw/Windows/System32/DriverStore/FileRepository/himax-hx83121.inf_arm64_ec034b565dc2d29d/
sync; umount /mnt/win-rw
```

清脏标记的前提是 Windows 每次都冷启动，不是从休眠或快速启动恢复，否则 Windows 会用内存里的旧状态覆盖我们的改动。分区根目录下有 `hiberfil.sys`，我没有检查它的内容；能确认的是每次替换的驱动在下次启动时都生效了（诊断文件每次重新生成），说明没有从休眠恢复。

改了 INF 或要新增驱动时，仍然要走 WinPE（`\woa\service` 模式，见 [woa-dagu-status-2026-10-26.md](woa-dagu-status-2026-10-26.md)）。

### 4.3 平板接在中转电脑上时

平板接在另一台电脑（经 easytier 访问）的 USB 上时，`tools/winarm/sc.sh` 放在那台电脑的 `~/dagu-touch/`，和 `serial-cmd.py`、`fb-usb.py` 一起用：

```bash
echo '命令' | ssh 用户@中转机 'bash ~/dagu-touch/sc.sh cmd 超时秒数'
printf '按键' | ssh 用户@中转机 'bash ~/dagu-touch/sc.sh raw 超时秒数'
ssh 用户@中转机 'bash ~/dagu-touch/sc.sh push 本地 远端'
```

- 串口命令从标准输入读，避开 ssh 引号转义。
- sudo 密码从环境变量 `DAGU_SUDO_PW` 或 `~/dagu-touch/.sudo-pw` 读，不进仓库。
- 平板重启后串口可能变成 `ttyACM1`（旧节点残留），`sc.sh` 总是选编号最大的那个。
- 登录要分两步：先发 `root`，等出现密码提示再发密码。一次发完，密码会被 `login` 清掉的输入缓冲吞掉。

### 4.4 从 Linux 回 fastboot

```bash
python3 -c "import ctypes;ctypes.CDLL('libc.so.6').syscall(142,0xfee1dead,0x28121969,0xA1B2C3D4,b'bootloader')"
```

刚写过大量 NTFS 数据后执行，有一次内核卡在关机过程中（串口只剩 `ufshcd ... WB disabled` 的刷屏），只能长按电源键强制关机。在新启动的 Linux 上执行没有出过问题。另外试过往 `misc` 分区写 `bootonce-bootloader` 再用 sysrq 重启：重启是干净的，但引导程序不认这个标记，回到了 Linux。

### 4.5 诊断文件

| 文件 | 写入方 | 内容 |
|---|---|---|
| `C:\Windows\himax-diag.txt` | 驱动，每 128 次轮询和每次按下 | 计数器、最后一帧原始数据、坐标范围、PnP 请求记录 |
| `C:\Users\Public\touchdiag.txt` | 启动文件夹里的 `touchdiag.bat` → `touchdiag.ps1`，登录桌面后 | PnP 设备列表、HIMA8312 的属性、Kernel-PnP 事件 |

`touchdiag.bat` 放在 `ProgramData\Microsoft\Windows\Start Menu\Programs\Startup`（注意是 `Startup`，ntfs-3g 区分大小写）和 `Users\dagu\AppData\Roaming\...\Startup`。触摸问题解决后应删掉。

---

## 5. 走过的弯路和教训

- **先确认硬件，再写驱动。** UEFI 探测把“硬件能不能读”和“Windows 驱动对不对”分开了。GENI 返回全 `0xFF` 这件事，Linux 的代码和 DTS 早就给了答案，应该更早去读。
- **一次实验只改一个变量。** 2.6 节的 uhid 对比同时改了两处，得出了错误的“根因”，又多花了一轮重启。
- **先拿到 Windows 自己的状态。** 驱动诊断只能说明驱动做了什么；“Windows 有没有创建触摸屏设备”要看设备树。注册表加事务日志回放、启动脚本导出设备列表，这两个手段应该更早用。
- **先查最基本的框架约定。** PnP/电源请求必须向下传，是 WDM 驱动最基本的要求。前面几轮一直在查描述符和数据格式，没有回头看这部分。
- **每一轮重启的成本要先压下来。** 从 WinPE 注入（15 分钟）换成直接替换文件（1 分钟）之后，迭代快了很多。

---

## 6. 还没解决：触摸延迟大

用户反馈能触摸但延迟明显。还没有测量，下面是看代码能确定的几个原因，按我估计的影响从大到小：

1. **轮询间隔不是 2 ms。** `KeWaitForSingleObject` 的相对超时按系统时钟周期取整，默认周期是 15.6 ms，除非有别的组件调高了时钟精度。实际可能只有约 64 次/秒，平均多出 8 ms 左右的等待。
2. **按下时同步写诊断文件。** 每次从无触点变成有触点，线程先调 `WriteDiag`（`ZwCreateFile` + `ZwWriteFile`，同步写盘），然后才把第一份报告交给 Windows。每 128 次轮询也会写一次，期间不读触摸。
3. **只接受一个挂起的读请求。** HIDCLASS 通常同时发两个读请求，第二个被返回 `STATUS_DEVICE_BUSY`。读到新帧时如果没有挂起的请求，这一帧直接丢掉。
4. **不看中断线、空闲时也一直读。** 每帧 59 字节、约 1900 次寄存器访问，空闲时也在做，占 CPU。

建议的修改顺序：去掉按下时的写文件，诊断改成按需（比如注册表开关）；改用中断线触发，或者用 `ExSetTimerResolution` / 高精度定时器把轮询真正降到 2 到 5 ms；读请求改成队列。改之前先测一下：在诊断里记录两次轮询之间的实际间隔（`KeQueryPerformanceCounter`）。

---

## 7. 涉及的文件

| 路径 | 说明 |
|---|---|
| `port/dagu/windows-drivers/himax-hx83121/himax-hx83121.c` | Windows 触摸驱动 |
| `winarm/overlay/xiaomi-dagu/Driver/DaguQupDxe/DaguQupDxe.c` | UEFI：`Bus = TRUE` 修正、`DaguStallMs`、软件 SPI 探测（默认不调用） |
| `tools/winarm/build-himax-sys.sh` | Linux 交叉编译驱动 |
| `tools/winarm/fetch-wdk.sh` | 下载并整理 WDK/SDK |
| `tools/winarm/sign-driver.sh` | 测试签名（已有） |
| `tools/winarm/sc.sh` | 中转电脑上的串口包装脚本 |
| `.gitignore` | 忽略 `winarm/wdk/` 和编译出的 `.sys` |

没有入库的：`winarm/wdk/`（1.5 GB）、`tools/winarm/signing/`（私钥）、编译出的 `.sys`、`/tmp` 下的 uhid 测试程序和诊断脚本。
