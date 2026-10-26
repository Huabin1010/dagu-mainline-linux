# dagu Windows 11 ARM 移植：当前进度与交接说明（2026-10-26 14:00）

本文记录这次 Windows on ARM 移植做到了哪一步、平板和两台电脑现在的状态、正在跑的任务，以及接下来该做什么。工作暂停在这里，下一个人照本文就能接着做。

技术背景（UEFI 移植思路、槽位模型、日志循环）见 [woa-dagu-kona-port.md](woa-dagu-kona-port.md)。

---

## 1. 一句话现状

自己移植的 dagu UEFI 已经能在平板上跑完，并把 Windows 启动管理器（`bootmgfw.efi`）从 UFS 加载起来，winload 也走到了 `ExitBootServices`。之后 Windows 内核在**写任何东西到磁盘之前**就挂了：屏幕变成全屏灰色，然后重启，一直循环。

目前的判断是驱动不全：UFS 控制器依赖电源管理驱动 PEP，而我们注入的驱动里没有 PEP。补驱动的任务已经启动，**结果还没确认**（见第 5 节）。

---

## 2. 设备和电脑的当前状态

### 2.1 平板（dagu，序列号 `ab22268c`）

| 项 | 状态 |
|---|---|
| 位置 | 在公司，USB 接在公司电脑上 |
| 当前运行 | **B 槽 Linux #654**（`slot_suffix=_b`） |
| 网络 | 不在公司局域网里，**SSH 连不上**；只能走 USB 串口 |
| 活动槽位 | `b` |
| `boot_a` | dagu UEFI，带背光驱动（sha256 开头 `c7f5439ac30051b3`） |
| `vendor_boot_a` | 和 Linux #654 原版 vendor_boot 完全相同（`be32b9cd59ebe421`） |
| `dtbo_a` / `vbmeta_a` | stub DTBO / 关闭校验的 vbmeta（早先刷入，未再改） |
| `boot_b` | Linux #654，**从没动过** |
| `vendor_boot_b` | **已改过**：#654 原版加了内核参数 `systemd.debug_shell=/dev/ttyGS0`（`d4b3f04ecffdffea`），只为通过 USB 串口拿 root shell |
| 正在跑 | WinPE 补驱动任务（systemd 单元 `woa-deploy`，QEMU），平板时间 13:50 启动 |

注意：平板的时钟比电脑慢约 10 分钟。

A/B 槽属性（存在 LUN4 `/dev/sde` 的 GPT 属性里，`boot_a` 是第 12 个分区，`boot_b` 是第 37 个）：

| 槽 | 属性字节 | 含义 |
|---|---|---|
| boot_a | `0x22` | 优先级 2，非活动，剩余重试 4，未标记成功 |
| boot_b | `0x77` | 优先级 3，活动，重试 6，已标记成功 |

位定义（Qualcomm ABL）：48-49 优先级，50 活动，51-53 剩余重试次数，54 启动成功，55 无法启动。

### 2.2 UFS 分区（LUN0 `/dev/sda`，4 KiB 扇区）

| 分区 | 名称 | 大小 | 内容 |
|---|---|---|---|
| sda34 | `userdata` | 48 GiB | Ubuntu rootfs（原 106.7 GiB，已离线缩小；GUID/类型/名字都没变） |
| sda35 | `esp` | 512 MiB | FAT32，卷标 `ESP`，序列号 `F822-FDB6`，内有 `EFI\Boot\bootaa64.efi`、`EFI\Microsoft\Boot\BCD` |
| sda36 | `win` | 58.2 GiB | NTFS，卷标 `Windows`，Win11 专业版 26100 ARM64 |

改分区前的 GPT 备份在 `backups/gpt-before-windows-20261026-0836/`（`sgdisk --load-backup` 可以恢复）。

### 2.3 两台电脑

| 电脑 | 地址 | 用途 |
|---|---|---|
| 家里电脑（构建机） | 本仓库所在机器 | 所有构建都在这里做（Mu UEFI、驱动包、WinPE） |
| 公司电脑 | `10.88.0.31`（easytier），用户 `huanghuabin` | 平板接在它的 USB 上；负责刷机和 USB 串口 |

公司电脑上的工作目录是 `~/dagu-woa/`：

| 文件 | 用途 |
|---|---|
| `fb-usb.py` | fastboot 刷机（不用 Google fastboot） |
| `serial-cmd.py`、`t.sh` | 通过 USB 串口在平板上执行命令；`t.sh --push 本地 远端` 传文件（约 8 MB/s） |
| `boot-dagu-uefi-bl.img` | 当前的 UEFI（带背光驱动），即 `boot_a` |
| `boot-dagu-uefi-v3.img` | 没有背光驱动的旧 UEFI |
| `vendor_boot-dagu-uefi.img` | A 槽 vendor_boot |
| `vendor_boot-654-debugshell.img` | 带 USB 串口 root shell 的 vendor_boot |
| `wim/install.wim` | Win11 镜像（3.7 GB，已校验） |

传输速度：easytier 单流约 0.3 MB/s，8 路并行 scp 约 4.9 MB/s；公司电脑访问外网约 3.4 MB/s。

---

## 3. 启动链和已经修掉的问题

启动链：XBL → ABL（A 槽）→ boot_a 里的 Mu UEFI 负载 → BDS → ESP 上的 `bootmgfw.efi` → `winload.efi` → Windows 内核。

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | ABL 不接受 Mu 生成的启动镜像 | ABL 拒收从零生成的 v2/v3 启动镜像 | 用 Linux 的 `build-bootimg.sh`，以原厂 v3 boot 为底，用 magiskboot 重新打包 |
| 2 | `ASSERT [VariableRuntimeDxe]`，原地卡死 | `DxeRngLibConstructor` 找不到 RNG 协议，因为 RngDxe 的加载顺序在后面；上游只编 RELEASE，这个 ASSERT 被编译掉了，所以上游没遇到 | APRIORI 里把 RngDxe 挪到 VariableRuntimeDxe 前面 |
| 3 | `ASSERT AcpiPlatform.c(214)`，接着 Data abort（FAR `0xBB800000`） | 从 pipa 带过来的 `DSDT.aml` 是 0 字节，读到的表长是随机数 | 改用 SM8250 MTP 参考板的 DSDT（umi、nio 用的也是同一份）；构建脚本会拒绝空 DSDT |
| 4 | 屏幕极暗 | 两颗 KTZ8866 背光芯片停在开机画面的亮度，UEFI 和 Windows 里都没有驱动去调 | 新增 `DaguBacklightDxe`：用 GPIO 模拟 I2C（gpio60/61 和 125/126，地址 0x11），按 Linux 驱动的值设为 1500/2047。**真机效果还没确认** |
| 5 | Linux 写出来的 NTFS 上，DISM 报错 193 | 用 mkntfs + wimlib 在 Linux 上写入镜像，后来 Windows 往同一批簇上写了数据，约 530 个文件被覆盖 | 格式化、写入镜像、注入驱动、写引导全部改用 Windows 自己的工具（WinPE） |
| 6 | 拼接虚拟磁盘的写入全部 ENOSPC | nbdkit 的 `split` 插件拒绝写块设备 | 改为整个 LUN0 交给 QEMU，用 `protect` 过滤器，只有 esp/win 两个分区可写 |
| 7 | 公司电脑上 fastboot 报 "Resource busy" | 公司电脑的 adb 服务占住了 USB 接口 | 刷机前先 `pkill -x adb` |
| 8 | USB 串口命令没有回应 | `serial-getty@ttyGS0` 和 debug shell 抢同一个串口 | 每次 Linux 启动后先执行 `systemctl mask --runtime --now serial-getty@ttyGS0.service` |

关于 QEMU：Windows 本身是直接跑在骁龙 870 上的。QEMU 只在安装和维护时临时用一下，相当于一台没有的 Windows 电脑，在平板的 Linux 里跑 WinPE 来用 DISM、bcdboot 这些工具，用完就关。

---

## 4. 当前卡点：Windows 内核起来后挂掉

### 4.1 最后一次启动看到的现象（用户拍照）

- `Loading driver ... bootmgfw.efi`：Windows 启动管理器已经从 ESP 加载。
- `ConvertPages: failed to find range 10000000 - 102C4FFF` 和 `failed to find range 102000 - 102FFF`：bootmgr 想在固定低地址分配内存，失败后会改用别的地址。Mu 平台上通常无害。
- `Memory Type Information settings cannot be saved. OS S4 may fail!`：休眠相关，无害。
- `SetVariableLockType: SOFTWARE_LOCK` / `mVarNameList is null!`：变量锁相关的提示，暂判无害。
- `PROGRESS CODE: V03101019`：表示 `ExitBootServices`（`EFI_SOFTWARE_EFI_BOOT_SERVICE | EFI_SW_BS_PC_EXIT_BOOT_SERVICES`），说明 winload 已经把内核加载好并开始交接。
- 然后屏幕全灰，重启，循环。

### 4.2 从 Linux 读 Windows 分区得到的证据

- `\Windows\ntbtlog.txt` 不存在（BCD 里已经打开了 bootlog）。
- `\Windows\bootstat.dat` 不存在。
- 没有 Minidump，也没有 MEMORY.DMP。
- `SYSTEM` 注册表的修改时间还是 WinPE 写入时的时间。
- ESP 上有 bootmgr 写的 `BOOTSTAT.DAT`。

结论：内核在能写系统盘之前就挂了。

### 4.3 判断：驱动集不完整，UFS 起不来

- DSDT 里 `UFS0`（`_HID QCOM24A5`）带 `_DEP` 依赖 `\_SB.PEP0`（`QCOM2519`）。
- Windows 自带的 `storufs.inf` 能驱动 `ACPI\QCOM24A5`，UFS 驱动本身没问题。
- 但我们用的上游驱动清单 `definitions/Desktop/ARM64/Internal/mtp865.xml` 只有 59 个基础包，**没有 PEP（qcpep），也没有 SMMU、IOMMU、I2C、SPI、UART、USB 控制器**。其他平台的完整清单（mtp855、mtp888）都有 150 到 170 个包。
- 已注入镜像的 DriverStore 里确实找不到 qcpep、qcsmmu、qciommu。
- 没有 PEP 驱动，PEP0 不会启动，依赖它的 UFS0 也就不会启动，Windows 找不到启动盘。这很可能就是 `INACCESSIBLE_BOOT_DEVICE`（0x7B）。

"全屏灰色"可能就是蓝屏，只是背光太暗、颜色失真看不出来。下次的修改关掉了蓝屏后自动重启（见 5.1），到时能直接看到错误代码，这一点就能确认。

---

## 5. 正在进行的任务（结果未确认）

### 5.1 WinPE 补驱动（servicing 模式）

在平板上通过 QEMU 启动 WinPE。介质里放了 `\woa\service` 标记文件，所以这次**不格式化、不重写镜像、不动 BCD**，只做下面三件事：

1. `dism /Add-Driver` 注入 76 个驱动包：原来的 58 个，加上 18 个启动必需的：
   - `qcpep.wd8250`、`qcpepextension8250`
   - `qcsmmu8250`、`qciommu8250`、`qcsyscache8250`、`QcTrEE8250`
   - `qci2c8250`、`qcspi8250`、`qcuart8250`、`qcppx8250`（PCIe）
   - `qcpmicappsext8250`、`qcfgbclext8250`、`qcpilEXT8250`
   - `qcusbfn8250`、`QcUsbFnSsFilter8250`、`ufnserialcomposite`、`QcXhciFilter8250`、`qcursext`
2. 离线修改注册表 `SYSTEM\ControlSet001\Control\CrashControl`：`AutoReboot=0`、`DisplayParameters=1`。蓝屏会停在屏幕上并显示错误参数，不会自动重启。
3. 写日志到 WinPE 介质的 `\woa\deploy.log`。

预计耗时 15 到 20 分钟（WinPE 启动约 4 分钟，加驱动约 10 分钟）。

**确认结果的办法**（在公司电脑 `~/dagu-woa` 下执行）：

```bash
./t.sh --timeout 60 "systemctl is-active woa-deploy; tail -1 /root/woa/run.log"
# 显示 inactive，且最后一行是 "QEMU exit rc=0" 后：
./t.sh --timeout 120 "/root/woa/build-media.sh mount; iconv -f GBK -t UTF-8 /mnt/woa-pe/woa/deploy.log | tr -d '\r' | grep -vE '^ *$' | tail -40; /root/woa/build-media.sh umount"
```

成功的标志：日志里有 `=== service mode`、`找到 76 个要安装的驱动程序包`、`dism rc=0`，`reg add` 显示成功，最后是 `=== DONE`。

---

## 6. 接下来的步骤

1. **确认 5.1 的结果。** 如果 dism 不是 0，看 `\woa\dism-driver.log`。
2. **切到 A 槽启动 Windows：** 平板执行 `systemctl reboot bootloader` 进 fastboot，然后在公司电脑上运行：
   ```bash
   pkill -x adb
   echo <密码> | sudo -S python3 fb-usb.py set-active a
   echo <密码> | sudo -S timeout 3 python3 fb-usb.py reboot
   ```
   `boot_a` 和 `vendor_boot_a` 已经是正确的，不用重刷。
3. **看屏幕：**
   - 停在蓝屏：记下错误代码和参数。0x7B 说明 UFS 还没起来，要查 PEP 依赖的其他驱动或 DSDT 里的资源。
   - 进入"正在准备设备"或 OOBE：说明问题解决了。应答文件会自动建本地管理员 `dagu`（无密码）。
   - 顺便确认背光是不是变亮了（`DaguBacklightDxe` 的效果）。
4. **进系统后：**
   - 读 `\Windows\ntbtlog.txt`，看哪些驱动没加载。
   - 再按组加驱动，每次只加一组：GPU `qcdx8250`、Wi-Fi `qcwlan8250`、子系统 `qcsubsys`、音频、传感器。dagu 是 APQ（没有基带），蜂窝相关的驱动不要加。
5. **A 槽重试次数：** Windows 不会通知 ABL"启动成功"，所以每次启动 A 槽，ABL 都会把重试次数减一，减到 0 就把 A 标为无法启动并切回 B。现在 Windows 一直在崩溃重启，这个机制正好能自动退回 Linux，所以先不改。等 Windows 稳定了，再在 Linux 上用 sgdisk 改 GPT 属性：`boot_a` 设为 `0x7F`（优先级 3、活动、重试 7、成功），`boot_b` 设为 `0x7A`。或者在 UEFI 里加一个驱动来标记启动成功。
6. **补 dagu 自己的 DSDT：** 屏幕面板（L81A）、Himax 触摸、Nanosic 键盘、CS35L41 功放、电量计等设备，参考板 DSDT 里都没有，要以 MTP 的 DSDT 为基础，对照 Linux DTS 来写。
7. 一切正常后：把 `DaguBacklightDxe` 的 DEBUG 设置（`PcdDebugPropertyMask` 0x0f、字体放大两倍）改回去，提交代码，按原计划新建公开仓库。

---

## 7. 远程操作要点

- **USB 串口 shell**：只有 B 槽的 vendor_boot 带 `systemd.debug_shell=/dev/ttyGS0` 时才有。每次 Linux 启动后，先执行几次下面的命令把登录程序停掉，命令一回应就说明 shell 可用：
  ```bash
  ./t.sh --timeout 6 'systemctl mask --runtime --now serial-getty@ttyGS0.service; dmesg -n 1; echo OK""STOP'
  ```
- **刷机前**先 `pkill -x adb`。
- **回 Linux**：平板按住音量下 + 电源进 fastboot，然后 `set-active b`，再 `timeout 3 ... reboot`。
- **平板上的目录 `/root/woa/`**：
  - `winpe.img`：4.8 GB WinPE 介质，GPT 加一个 FAT32 分区，含 install.wim、驱动和应答文件
  - `pe/`：WinPE 的启动文件
  - `run-qemu-deploy.sh`、`build-media.sh`、`qemu-shot.py`
  - `run.log`：QEMU 运行日志
- **看 WinPE 屏幕**：`python3 /root/woa/qemu-shot.py /root/woa/mon.sock /root/woa/shot.png 1`。
- **校验写入的 NTFS**：`tools/winarm/wim-verify.py`，可以配合事先生成的 sha1 清单。

---

## 8. 代码和文件（都还没提交）

`git status` 里有这些改动：

| 路径 | 内容 |
|---|---|
| `winarm/build-dagu-uefi.sh` | 一键构建：pipa 设备目录 + dagu 二进制 + overlay + DSDT + DEBUG 设置，再用 v3 方式重新打包 |
| `winarm/overlay/xiaomi-dagu/` | 内存映射（PStore 在 `0xB0400000`）、APRIORI、`Driver/DaguBacklightDxe`、DTB |
| `winarm/mu-run.sh`、`winarm/docker/` | Mu 构建容器 |
| `tools/winarm/deploy-windows.sh` | `media`、`run`、`log` 三个子命令：准备介质、跑 WinPE、看日志 |
| `tools/winarm/winpe/startnet.cmd` | WinPE 自动脚本，分安装模式和 service 模式 |
| `tools/winarm/winpe/run-qemu-deploy.sh` | 平板端：nbdkit 写保护导出 LUN0，启动 QEMU WinPE |
| `tools/winarm/winpe/build-media.sh`、`qemu-shot.py` | 生成介质、截取 WinPE 屏幕 |
| `tools/winarm/serial-cmd.py` | USB 串口执行命令、批量传文件 |
| `tools/winarm/wim-verify.py` | 逐个文件校验写入结果 |
| `tools/winarm/dagu-uefi-loop.sh` | 刷 A 槽、监视、回滚、读 PStore |
| `linux-mainline/initramfs/init.c`、`scripts/build-initramfs.sh` | 新增编译选项 `DAGU_USERDATA_RESIZE`：一次性离线缩小 userdata，默认值为空，不影响平时使用 |
| `docs/woa-dagu-kona-port.md`、本文 | 文档 |
| `.gitignore` | 忽略 `winarm/drivers/`、`backups/slot-a-*/`、`backups/gpt-*/` |

家里电脑上的大文件，已被 git 忽略：
- `winarm/out/iso/`：从 ISO 解出的 install.wim、boot.wim 和 EFI 文件
- `winarm/out/pe.wim`
- `winarm/out/woa-drivers/`
- `winarm/drivers/windows_qcom_platforms`：WOA 驱动仓库，2.1 GB

还要注意：
- 公司电脑的 `~/dagu-woa/` 里有 3.7 GB 的 install.wim，用完可以删。
- 平板上之前清理了 3.4 GB 的 journal 日志，Linux 的 `dagu-resize-root.service` 已经恢复启用。

---

## 9. 已知风险

- `DaguBacklightDxe` 直接操作 TLMM SOUTH 区（`0x0F500000`）的引脚寄存器，用完会恢复原来的配置。真机上还没确认它确实生效，也没确认没有副作用。
- DSDT 用的是参考板的，dagu 自己的外设在 Windows 里都不存在。
- `vendor_boot_b` 目前是带 debug shell 的版本，不是原版。要恢复原版，刷 `winarm/out/linux-vendor_boot-654.bak.img`。
