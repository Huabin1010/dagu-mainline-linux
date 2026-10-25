# dagu-mainline-linux

**语言：** [English](README.md) | 简体中文

小米 **平板 5 Pro 12.4**（代号 **dagu**，高通 **SM8250** / 骁龙 870）的主线 Linux 适配仓库。

本仓库编译 Linux 7.0 + Ubuntu arm64 桌面，并刷到平板上。内核写 **B 槽**；Ubuntu 在 **userdata**。A 槽留给救援（TWRP / 原厂）。L81A dual-DPHY 真机上，显示、触控、Wi-Fi、GNOME、Adreno 650（Turnip）、Venus、前后摄像头均已打通。

| 阶段 | 目标 | 状态 |
|------|------|------|
| P0 | USB gadget 串口 / ramdisk | 已完成（`0525:a4a7`） |
| P1 | UFS + userdata 上的 Ubuntu | 已完成 |
| P2 | CPUFreq + TSENS | 已完成 |
| P3 | L81A 120 Hz DSC dual-DPHY | 已完成 |
| P4 | Himax SPI 触控 | 已完成 |
| P5 | QCA6390 Wi-Fi（ath11k） | 已完成 |
| P6 | Adreno 650 / Turnip + GNOME | 已完成 |
| P7 | CS35L41 扬声器 + WCD9385 麦克风 | 已通 |
| P8 | Venus 4K60 + 前后摄 | 已完成（图像前端硬件通路） |

硬件说明和 bring-up 记录在 [`linux-mainline/docs/`](linux-mainline/docs/dagu-adaptation-status.md)。外设总表：[`linux-mainline/docs/dagu-adaptation-status.md`](linux-mainline/docs/dagu-adaptation-status.md)。从解锁到相机走上硬件通路的完整适配记录和心得：[`linux-mainline/docs/dagu-mainline-adaptation-handbook.md`](linux-mainline/docs/dagu-mainline-adaptation-handbook.md)。

Windows on ARM / edk2-msm 移植在 [`port/dagu/`](port/dagu/) 和 [`docs/uefi-port-dagu.md`](docs/uefi-port-dagu.md)，**不是**现在每天在跑的系统。

**完整安装教程（从安卓到 Ubuntu 桌面）：** [简体中文](docs/zh-CN/install-guide.md) · [English](docs/install-guide.md)
**刷机指南：** [简体中文](docs/zh-CN/flash-guide.md) · [English](docs/flash-guide.md)
**Rootfs / 桌面镜像：** [简体中文](docs/zh-CN/rootfs-guide.md) · [English](docs/rootfs-guide.md)
**最新镜像：** [GitHub Releases](https://github.com/Huabin1010/dagu-mainline-linux/releases)（`v0.1.7`）

## 最近更新（`v0.1.7`）

相对 `v0.1.6`（2026-10-25）。内核 `#654`。

- **蓝牙配对和安卓一样：** 罗技 K380（在键盘上输 PIN）和低功耗蓝牙鼠标在 GNOME 设置里点一下就配上，马上能用。QCA6390 的天线开关电源（VDD_ASD，PM8150 L16）现在会打开，以前寻呼别的设备 10 次失败 10 次；修了一个让搜索一直回 Busy（设置里一个设备都没有）的内核竞争；BlueZ 在绑定完成后才开始 GATT，鼠标不用再等 30 秒。之前的蓝牙绕法全部撤掉，BlueZ 用默认配置。记录：[`dagu-bluetooth-pairing-2026-10.md`](linux-mainline/docs/dagu-bluetooth-pairing-2026-10.md)。
- **视频：** H.264 硬解硬编支持到 5.2 级（4K60）；Chromium WebCodecs 硬件编码（H.264、HEVC、VP8）；暂停后跳转不再卡住；4K60 稳态 60 fps，第一秒之后丢帧不超过 1%；IOMMU 改为延迟失效，去掉了开播时那 300 ms 的卡顿。MPEG-2 因为芯片硬解输出有错，走软解。编解码测试 GStreamer 12/12、Chromium 11/11。记录：[`dagu-codec-fixes-2026-10.md`](linux-mainline/docs/dagu-codec-fixes-2026-10.md)。
- **稳定性：** 视频编码器空闲一段时间后不再把固件弄崩；固件恢复不了时也不会再无限重试、中断刷屏把平板卡死。
- **新镜像：** `rootfs-desktop.ext4.zst` 带新的 Chromium 和 BlueZ；升级包也会在已装系统上装好这两个。

全新安装按 [完整安装教程](docs/zh-CN/install-guide.md)。已装好的系统：只刷 B 槽启动链，再在平板上解开 `dagu-userspace-v0.1.7.tar.gz` 运行 `sudo ./install.sh`。预构建账号 `dagu` / `dagu`（第一次进桌面请改掉）。

已知问题：重力和光线传感器暂不可用（没有自动旋转和自动亮度）。

## 快速开始

```bash
# 1. 安装依赖（需 sudo，一次性）
./linux-mainline/scripts/setup-deps.sh

# 2. 拉取内核源码（一次性）
./linux-mainline/scripts/setup-kernel.sh

# 3. 从本机 dump 暂存固件（blob 不入库）
./linux-mainline/scripts/stage-firmware.sh

# 4. 可选：写入本机 persist 的 Wi-Fi / 蓝牙地址
cp linux-mainline/dts/local-addresses.dtsi.example \
   linux-mainline/dts/local-addresses.dtsi
# 按本机 persist 填写。不要提交这个文件。

# 5. 编译内核 + dagu DTB
./linux-mainline/scripts/build-kernel.sh

# 6. 打包 boot.img
./linux-mainline/scripts/build-bootimg.sh

# 7. userdata 上的 Ubuntu 桌面（或从 Release 下 rootfs-desktop.ext4.zst）
ROOT_PASSWORD=... ./linux-mainline/scripts/build-rootfs-desktop.sh

# 8. 刷机（设备进入 fastboot）。用仓内 USB 工具，不要用 Google fastboot 37。
./linux-mainline/scripts/flash-rootfs.sh          # userdata，会清空安卓 /data
./linux-mainline/scripts/flash-boot.sh flash-b    # 只写 B 槽
```

内核源码（`linux-mainline/linux/`）和构建产物（`linux-mainline/out/`）不入库。

## 刷机铁律

- **只写 B 槽。** A 槽是救援计算机。
- **不要用 Google `fastboot` 37**（AMD 主机上会卡在 `USBDEVFS_REAPURB`）。刷写走 `linux-mainline/scripts/fb-usb.py` / `flash-boot.sh`。
- 空 DTBO（`dt_entry_count=0`）约 6 秒回 fastboot，不要刷。
- userdata 已是 Ubuntu 后，**不要** `fastboot reboot` 进当前槽的原厂安卓 `boot`。用仓内脚本。
- 每次 `set_active`（`flash-b` 也会做）都把 B 槽重置成 7 次重试、`slot-successful:b: no`。没有标记成功的话，每次开机（包括关机充电唤醒）扣一次，第 8 次 ABL 把 B 标成 unbootable 并停在 fastboot。`dagu-boot-success.service` 每次开机都会标记成功，必须保持 enabled。卡在 fastboot 且 `slot-unbootable:b: yes` 时：`python3 linux-mainline/scripts/fb-usb.py set-active b`，再 `timeout 3 python3 linux-mainline/scripts/fb-usb.py reboot`。
- 救砖：音量下 + 电源进 fastboot，或 9008 EDL 刷官方 `flash_all`（**不要 lock**）。见 [EDL 流程](docs/dagu-edl-recovery-full-playbook.md)。

登录：USB ACM `ttyACM0`，或 USB RNDIS SSH（`root@192.168.7.2`）/ 平板 Wi-Fi 地址。**预构建**桌面账号是 `dagu` / `dagu`。本机编镜像：导出 `ROOT_PASSWORD`，或写到已忽略的 `linux-mainline/out/root-password`。

## 目录结构

```
linux-mainline/config/     内核 config fragment
linux-mainline/dts/        板级 DTS（单机 MAC 不入库）
linux-mainline/overlays/   树外驱动（面板、Himax、相机等）
linux-mainline/scripts/    编译、刷写、USB、桌面脚本
linux-mainline/docs/       bring-up 与子系统记录
linux-mainline/firmware/   暂存目录；blob 不入库
port/dagu/                 edk2-msm 设备覆盖层（WoA，非日常）
docs/                      解锁、UART、EDL、硬件清单
devices/                   原厂 boot 头笔记（不含 dump 二进制）
```

## 硬件（L81A）

| 项目 | 规格 |
|------|------|
| 产品 | 小米平板 5 Pro 12.4（`22081281AC`） |
| SoC | SM8250-AC，Adreno 650 |
| 面板 | L81A 1600×2560，120 Hz，DSC dual-DPHY |
| 触控 | Himax，`spi-gpio`（不是 GENI SPI） |
| Wi-Fi / 蓝牙 | QCA6390，ath11k + uart6 / hci_qca |
| 摄像头 | 前置 imx596 skip 2×2（1296×976），后置 s5kjn1 skip 4×4（1020×764） |
| 解码 | Venus stateful V4L2（`/dev/video14`） |

禁止把后置改成 C-PHY / `0x0114=0x0301`。禁止把 Himax `reset-gpios` 绑 GPIO100。禁止把 `vreg_l3a_0p9` 改成 1.104V。

## 环境变量

见 `linux-mainline/scripts/env.sh`：

| 变量 | 默认 | 说明 |
|------|------|------|
| `KERNEL_TAG` | v7.0 | 内核版本 |
| `KBUILD_OUTPUT` | `linux-mainline/out/kernel` | 构建输出目录 |
| `ROOT_PASSWORD` | （未设置） | 镜像 root / 桌面用户密码 |
| `DAGU_SSH_HOST` | `192.168.7.2` | 探针脚本 SSH 目标（USB RNDIS） |
| `DAGU_ADB_SERIAL` | （必须设置） | 安卓提取机的序列号 |

## 本仓库不含

- 内核 git clone 和 `out/` 镜像
- 高通 / 小米固件 blob（从你自己的 dump 暂存）
- 设备序列号、persist MAC / 蓝牙地址、局域网 IP、SSH 密钥、密码
- 编辑器 / agent 工作区（`.cursor/`、`.vscode/`）

## 许可证

本仓库的构建脚本、overlay 和原创文档使用 [GPL-2.0-only](LICENSE)，与 Linux 内核一致。设备树文件保留各自 SPDX（多为 BSD-3-Clause，与上游高通 DTS 一致）。设备固件为专有二进制，仅供在提取它的那台设备上运行 Linux，且不入库。

`port/dagu/` 下的 UEFI 片段遵循 edk2-msm 许可。
