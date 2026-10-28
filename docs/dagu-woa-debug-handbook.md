# dagu：Windows 启动调试速查手册（2026-10-27）

本文把调试 Windows 启动时反复要查的东西放在一处：板子现在是什么状态、怎么刷、怎么登录 Linux、怎么读日志、哪些做法已经证明走不通。目的是下次不用重新翻聊天记录。

板子序列号 `ab22268c`。板子直接接在这台开发电脑上，不再经过公司电脑。

## 1. 先看 USB 状态判断板子在哪

执行 `lsusb | grep -iE '0525|18d1|05c6'`：

| USB 标识 | 含义 |
|---|---|
| `18d1:d00d` | 引导程序的 fastboot 模式 |
| `0525:a4a7` | B 槽 Linux 已启动，串口设备是 `/dev/ttyACM0` |
| `05c6:*` | 高通紧急下载模式 |
| 什么都没有 | Windows 固件已接管，或者板子在重启中。Windows 路径下固件不会提供任何 USB 设备，所以看不到不代表死机 |

板子卡在 Windows 时，长按电源键加音量下键回到 fastboot。

## 2. 刷机和换槽：只用 `fb-usb.py`

脚本：`linux-mainline/scripts/fb-usb.py`。子命令有 `devices`、`getvar 变量名`、`flash 分区 文件`、`erase 分区`、`set-active a|b`、`reboot`。

```bash
cd ~/Projects/xiaomi-pad870-win11-arm
python3 linux-mainline/scripts/fb-usb.py getvar current-slot
python3 linux-mainline/scripts/fb-usb.py set-active b
timeout 3 python3 linux-mainline/scripts/fb-usb.py reboot
```

注意事项：

- Google 的 `fastboot` 在这台电脑上会卡死（读写 USB 时挂住，进程状态是 `D`）。`fb-usb.py` 文件开头有原因说明。不要用 `fastboot oem uefilog`，两次都卡住，输出只有 51 字节空白。
- 如果 `fb-usb.py` 报 `claim interface: Resource busy`，说明有卡住的 `fastboot` 进程占着接口。先用 `pkill -9 -x fastboot` 杀掉再重试。
- `fb-usb.py` 没有 `oem` 子命令，所以读不了引导程序日志。
- 换槽只做一次 `set-active`，不要连续多次。每次换槽，引导程序会对调两个槽的分区类型标识，连续换会把分区表弄乱（经过见 [dagu-lun4-gpt-recovery-2026-10-27.md](dagu-lun4-gpt-recovery-2026-10-27.md)）。
- 两个槽的分工：A 槽放 Windows 用的 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口），B 槽放 Linux 回退镜像。“dagu 只刷 B 槽”的规则按你的要求移除了；我在仓库 `.cursor/rules/` 里搜不到它，所以它应该不在仓库里，现在刷 A 槽没有规则限制。
- A 槽每启动一次，重试计数减一，减到 0 引导程序会自动切回 B 槽。Windows 崩溃重启时这个机制就是自动退路。

从 Windows 退回 Linux：进 fastboot，`set-active b`，`reboot`，十几秒后 `lsusb` 出现 `0525:a4a7`。

从 Linux 进 Windows：进 fastboot，`set-active a`，`reboot`。`fb-usb.py` 没有 `continue` 子命令；今天 19:48 用 Google `fastboot continue` 成功过一次（返回 `OKAY`），但这个工具整体会卡死，不建议依赖。

## 3. 登录 Linux

### 密码在哪

Linux 的 root 密码存在 `linux-mainline/out/root-password`（5 个字节，已被 `.gitignore` 忽略，不会入库）。**不要把密码写进文档或提交说明。**

聊天里给过的另一个密码（公司电脑那一组）登录 Linux 串口时被拒绝了，它不是这块板子 Linux 的 root 密码。该密码不记录在文档里。

### 串口命令

脚本：`tools/winarm/serial-cmd.py`，默认设备 `/dev/ttyACM0`。

```bash
python3 tools/winarm/serial-cmd.py --timeout 20 'uname -r; id'
python3 tools/winarm/serial-cmd.py --push 本地文件 /远端/路径    # 经 base64 传文件，约 8 MB/s
python3 tools/winarm/serial-cmd.py --raw --timeout 3 ''           # 只看串口上现在输出了什么
```

仓库里另外有 `linux-mainline/scripts/dagu-console.py` 和 `tools/dagu-usb-console.py`，说明见 [dagu-usb-serial-console.md](dagu-usb-serial-console.md)。前者会自己从 `out/root-password` 读密码；这次调试我没有用它，没有验证过。

### 串口会话的坑

- 刚启动时串口是登录提示，不是 shell。`serial-cmd.py` 不会登录。用 `--raw` 逐步发：先发 `root`，等到出现 `密码：`，再发密码文件里的内容。每一步之间读一下输出确认提示符。
- 内核日志会不停地刷在串口上，会插进你的输入。登录和命令分开发，不要一次塞多行。
- 多行 heredoc（`<<EOF`）发不过去，shell 会停在续行提示符 `>`。要运行脚本，用 `--push` 传成文件，再用单行命令执行。
- 不要通过 `--raw` 发 Ctrl-D，它会让 shell 登出，要重新登录。
- 串口 shell 被占用时，可以先 `systemctl mask --runtime --now serial-getty@ttyGS0.service`，防止登录程序和调试 shell 抢同一个串口（只在有调试 shell 的镜像里有这个问题）。

## 4. 读日志

### 4.1 Windows 有没有往系统盘写东西

这是判断“内核到底跑到哪”最可靠的办法。登录 Linux 后：

```bash
mkdir -p /mnt/w /mnt/e
mount -t ntfs-3g -o ro /dev/sda36 /mnt/w     # Windows 分区（NTFS）
mount -o ro /dev/sda35 /mnt/e                # 启动分区（FAT32）
find /mnt/w -newermt '2026-10-27 04:09' 2>/dev/null | head
ls -l --time-style=full-iso /mnt/w/Windows/System32/config/SYSTEM
ls -lt --time-style=long-iso /mnt/e/EFI/Microsoft/Boot | head
```

- 内核没有挂 `ntfs3`（`mount: 未知的文件系统类型“ntfs3”`），要用 `ntfs-3g`，挂上去显示的类型是 `fuseblk`。
- 分区里的 `MEMORY.DMP`、`bootstat.dat`、`ntbtlog.txt`、`Minidump` 日期是 2024-04-01，来自原始镜像，不是我们的启动。看日期，不要看文件是否存在。
- 判断标准：系统分区里没有晚于最近一次部署的修改，说明内核在能写磁盘之前就停了。

2026-10-27 20:00 的结果：没有任何新写入。`SYSTEM` 注册表的修改时间停在 04:08，启动分区上最新的是 08:16。

### 4.2 固件（UEFI）启动日志

目前没有可靠办法读到完整的固件日志。试过的路线：

| 路线 | 结果 |
|---|---|
| `fastboot oem uefilog` | 卡死，输出空白 |
| 启动 Linux 后读 DDR 里的日志环 | Linux 起来后内容已被覆盖，找不到 `DaguWdt` 等关键字，写入偏移也是乱码 |
| 拍屏幕 | 可用。固件把日志同时画在屏幕上 |

日志环位置：物理地址 `0xB0400000`，大小 `0x200000`，用 `/dev/mem` 的 `mmap` 读（`read()` 会返回 `EFAULT`）。脚本 `tools/winarm/dagu-uefi-loop.sh readlog` 做的就是这件事，但需要 SSH 和一份 Linux 网络，这次没走通。

现阶段最有效的办法是拍卡住的屏幕。照片放在 `~/下载/`（不是 `~/Downloads`，这台电脑上目录名是中文）。

### 4.3 引导程序日志

引导程序的日志可以用 `oem uefilog save` 保存，再用 `oem uefilog UEFILOG0.TXT` 读出，2026-10-27 上午这样读到过 `ValidateSlotGuids` 的错误（见 [dagu-lun4-gpt-recovery-2026-10-27.md](dagu-lun4-gpt-recovery-2026-10-27.md)）。当时具体用的哪台电脑、哪个 fastboot 工具我没有核实。这台电脑上 Google `fastboot oem uefilog` 会卡死，`fb-usb.py` 又没有 `oem` 子命令，所以目前这台电脑上没有已验证的读法。可行的下一步是给 `fb-usb.py` 加一个 `oem` 子命令。

## 5. Windows 已经能启动（2026-10-27 20:52，突破）

**用精简 DSDT 的固件，Windows 11 ARM 第一次在 dagu 上启动成功。**

决定性的改动是把 DSDT 砍到只剩启动必需的设备：

```bash
cd winarm
DSDT_ONLY="ufs Pep_lpi" ./build-dagu-uefi.sh
# 只刷 A 槽，保留 B 槽 Linux 回退：
python3 ../linux-mainline/scripts/fb-usb.py flash boot_a out/boot-dagu-uefi-v3.img
python3 ../linux-mainline/scripts/fb-usb.py reboot
```

- 完整 DSDT（30+ 个设备）仍然卡在 `PROGRESS CODE: V03101019`（`ExitBootServices`），内核接管后太早就挂，连蓝屏都画不出来。
- 精简 DSDT（只 `ufs.asl` + `Pep_lpi.asl`，和 alioth/lmi/elish 启动 Windows 用的最小集一致）直接进系统。所以让内核卡住的是完整 DSDT 里某一个设备，不是核心表（MADT/FADT/内存图）或交接本身。
- 这次能成，有两处前置修复也到位：`Pep_lpi.asl` 把除每核 WFI（C1）外的空闲状态 `Flags` 全设 0（避免深度空闲 PSCI 组合态被 TZ 拒绝导致的 `bugcheck 0xA0`）；`dsdt_common.asl` 把芯片事实 `Name()` 全改成定宽占位值（`0xffffffff`、15 字符串等），因为 `AcpiPlatformUpdateLib` 启动时用定宽 `CopyMem` 覆盖它们，短编码会冲掉后面的 AML、命名空间损坏、UFS0 枚举不出来（`bugcheck 0x7B`）。
- `DaguWdtProbeDxe` 证实交给 Windows 时 APSS 看门狗已关（`EN 0`），所以之前的重启不是它咬的。

已归档的可启动固件见 [backups 目录](../backups/)：`boot-dagu-uefi-v3.img`，`DSDT_ONLY="ufs Pep_lpi"` 构建，sha256 记在该目录的 `SHA256SUMS` 和 `README.md` 里，对应提交见 git log。

### 接下来

1. **逐组加回设备**：在 `dsdt_common.asl` 的 `Include()` 里，从最小集开始，一次加一组（graphics、gpio+i2c+himax 触摸、usb、battery/buttons/backlight…），每次只加一组、重刷、看能不能进系统，定位出让内核挂住的那个设备。找到后单独修它的 ASL，而不是整个排除。
2. 进系统后读 `\Windows\ntbtlog.txt`，看启动驱动加载到哪、缺哪些。
3. A 槽重试计数：Windows 不会向 ABL 报“启动成功”，每启动一次 A 槽重试减一，减到 0 会自动切回 B。等 Windows 稳定了再在 Linux 上用 sgdisk 把 `boot_a` 属性设成成功（见 [woa-dagu-status-2026-10-26.md](woa-dagu-status-2026-10-26.md) 第 6 节）。

## 6. 已经证明走不通的做法

- 用 Google `fastboot` 读写（卡死）。
- 连续多次 `set-active`（把槽位的类型标识搞乱）。
- 用公司电脑的密码登录 Linux 串口（被拒绝），要用 `linux-mainline/out/root-password` 里的。
- 用 `mount -t ntfs3`（内核不支持）。
- 在 Linux 里写 NTFS 来部署 Windows 镜像（会被 Windows 覆盖，用 WinPE 里的 Windows 自带工具）。
- 靠 USB 状态判断 Windows 是否死机（Windows 路径下本来就没有 USB 设备）。

## 7. 相关文档

- [woa-dagu-status-2026-10-26.md](woa-dagu-status-2026-10-26.md)：移植进度和启动链上已修掉的问题
- [woa-dagu-touch-2026-10-28.md](woa-dagu-touch-2026-10-28.md)：Himax 触摸屏在 Windows 上的适配过程、驱动构建和快速替换方法、延迟问题
- [woa-dagu-wifi-bt-rotation-2026-10-28.md](woa-dagu-wifi-bt-rotation-2026-10-28.md)：Wi-Fi / 蓝牙 / 屏幕旋转适配方案和分步计划
- [dagu-lun4-gpt-recovery-2026-10-27.md](dagu-lun4-gpt-recovery-2026-10-27.md)：分区表损坏和恢复
- [dagu-usb-serial-console.md](dagu-usb-serial-console.md)：串口控制台
- [early-boot-troubleshooting.md](early-boot-troubleshooting.md)：早期启动现象对照
