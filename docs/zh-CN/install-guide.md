**语言：** [English](../install-guide.md) | 简体中文

# 完整安装教程：小米平板 5 Pro 12.4 刷入 Ubuntu 桌面

按本教程从头走一遍，平板会得到一台完整的 Ubuntu 26.04 GNOME 桌面：主线 Linux 7.0 内核，屏幕、触摸、磁吸键盘、Wi-Fi、蓝牙、扬声器、麦克风、前后摄像头、硬件视频解码、充电和休眠都能用。

本教程对应 Release **v0.1.6**。只想升级已经装好的系统，直接看[第 8 节](#8-已经装过-ubuntu只升级)。

## 1. 先看清楚

- 只适用于 **小米平板 5 Pro 12.4**（代号 `dagu`，型号 `22081281AC`，骁龙 870）。nabu、elish、pipa 等别的平板**不能刷**。
- 刷 Ubuntu 会**清空安卓的全部用户数据**（`/data`）。照片、聊天记录先备份。
- 需要先**解锁 bootloader**。解锁本身也会清空数据。
- 平板有 A、B 两个槽。本项目只写 **B 槽**，A 槽留着原厂系统或 TWRP 当救援。不要改 A 槽。
- **不要重新上锁 bootloader**。装了 Ubuntu 再上锁会变砖。

## 2. 准备工作

### 2.1 解锁 bootloader

按小米官方流程解锁，详见 [bootloader 解锁指南](../bootloader-unlock-guide.md)。解锁完成后进 fastboot（关机状态下按住 **音量下 + 电源**），屏幕会出现 FASTBOOT 兔子。

### 2.2 一台 Linux 电脑

推荐 Ubuntu 24.04 / 26.04 或 Debian 13（x86_64 或 arm64）。Windows 用户可以用 WSL2 加 usbipd，但不保证能跑；最稳的是装了 Linux 的实体机。

安装依赖：

```bash
sudo apt update
sudo apt install -y git python3 libusb-1.0-0 zstd curl android-sdk-platform-tools-common
```

`android-sdk-platform-tools-common` 提供 USB 权限规则（`18d1:d00d`），装了以后普通用户也能访问 fastboot。再装一条本项目的规则，避免部分 AMD 主板 USB 节能导致刷写卡住：

```bash
git clone https://github.com/Huabin1010/dagu-mainline-linux.git
cd dagu-mainline-linux
sudo cp linux-mainline/host/99-dagu-fastboot-nolpm.rules /etc/udev/rules.d/
sudo udevadm control --reload
```

**不要**用 Google platform-tools 37 自带的 `fastboot` 刷这些镜像：它在部分主机上会卡死，也写不了超过 768 MiB 下载上限的 userdata。后面所有刷写都用仓库里的 `fb-usb.py` 和它的包装脚本。

## 3. 下载并校验

在仓库目录里执行（没装 `gh` 也可以去 [Release 页面](https://github.com/Huabin1010/dagu-mainline-linux/releases/tag/v0.1.6) 手动下载到 `linux-mainline/out/`）：

```bash
mkdir -p linux-mainline/out
gh release download v0.1.6 --repo Huabin1010/dagu-mainline-linux --dir linux-mainline/out
cd linux-mainline/out
sha256sum -c SHA256SUMS
sha256sum -c rootfs-desktop.SHA256SUMS
cd ../..
```

两条校验都要显示 `OK`，有一个不对就重新下载，不要刷。

| 附件 | 用途 |
|------|------|
| `rootfs-desktop.ext4.zst` | Ubuntu 桌面系统，写入 userdata |
| `boot-dagu.img` | 内核 + 设备树 + initramfs，写入 `boot_b` |
| `vendor_boot-dagu.img` | 写入 `vendor_boot_b` |
| `dtbo-stub.img` | 写入 `dtbo_b` |
| `vbmeta-disabled.img` | 写入 `vbmeta_b`，关掉验证启动 |
| `dagu-userspace-v0.1.6.tar.gz` | 已装系统的升级包（第 8 节） |
| `SHA256SUMS`、`rootfs-desktop.SHA256SUMS` | 校验和 |

## 4. 进 fastboot 并确认设备

平板关机，按住 **音量下 + 电源** 进 fastboot，用 USB 线连电脑：

```bash
python3 linux-mainline/scripts/fb-usb.py getvar product    # 必须是 dagu
python3 linux-mainline/scripts/fb-usb.py getvar unlocked   # 必须是 yes
```

`product` 不是 `dagu`，或者 `unlocked` 不是 `yes`，到此为止，不要继续。

## 5. 刷入 Ubuntu 系统（清空安卓数据）

```bash
./linux-mainline/scripts/flash-rootfs.sh
```

脚本会先把 `.zst` 解压成约 10 GiB 的镜像，再按 256 MiB 一段写进 userdata。USB 2.0 口大约要 5 到 10 分钟，过程中不要拔线、不要碰平板。

## 6. 刷入启动链（只写 B 槽）

平板仍在 fastboot：

```bash
./linux-mainline/scripts/flash-boot.sh flash-b
```

脚本依次写 `dtbo_b`、`vbmeta_b`、`vendor_boot_b`、`boot_b`，把 B 设为活动槽，等 5 秒再重启。每一步都应该显示 `OKAY`。

重启后电脑上会出现一个 USB 串口设备 `0525:a4a7`（`lsusb` 能看到）。它稳定存在 **30 秒以上**说明内核起来了。如果约 6 秒后又回到兔子 `18d1:d00d`，是 bootloader 拒绝了镜像，先重新执行一遍第 6 步。

## 7. 第一次开机

- 第一次开机会把 10 GiB 的系统分区扩到整个 userdata（约 106 GiB），然后自动登录 GNOME 桌面，前后大约一到两分钟。
- 预置账号（**进桌面后马上改密码**）：

  | 用户 | 密码 | 用途 |
  |------|------|------|
  | `dagu` | `dagu` | 桌面自动登录 |
  | `root` | `dagu` | USB 串口 / SSH |

  ```bash
  passwd
  sudo passwd root
  ```

- 在右上角菜单连 Wi-Fi。系统默认用 NTP 校时（平板没有 RTC），联网后时间才对。
- 屏幕默认横屏、缩放 1.25。输入法是 fcitx5，点一下 Shift 切换中英文。
- 磁吸键盘吸上就能用。屏幕键盘只在需要输入文字时弹出。

系统已经按我们日常用的配置调好，不需要再手动设置：

| 项目 | 默认行为 |
|------|----------|
| Wi-Fi | 插电时关闭省电（到路由器延迟约 2.4 ms），用电池时开省电 |
| 蓝牙 | 开机约 9 秒可用；搜索时经典蓝牙和低功耗蓝牙设备轮流扫，鼠标键盘回连不需要手动操作 |
| 闪存 | 每天自动 TRIM，保持闪存的写入加速缓存可用 |
| 相机 | 走硬件图像处理（ISP），打开应用后约 0.5 秒出画面，30 fps |
| 充电 | 和原厂一样由电源芯片判断充满和回充（截止电流 230 mA，4.40 V 回充） |
| 休眠 | 合上保护套或按电源键进浅休眠，可以用 Wi-Fi 魔术包远程唤醒 |
| 关机 | 关机时显示滚动的系统日志，文件系统写完后才黑屏 |
| 浏览器 | 预装适配过的 Chromium（硬件解码、Wayland、中文输入），在 Dock 第一位 |
| 系统更新 | 我们改过的包（Chromium、mutter/gnome-shell、PipeWire、Mesa、libcamera、BlueZ、设置面板）已锁定版本，`apt upgrade` 不会把它们换成官方版本 |

## 8. 已经装过 Ubuntu，只升级

userdata 已经是 Ubuntu 时**不要再刷 rootfs**（会清掉你装的软件和文件）。只做两步：

1. 平板进 fastboot，刷启动链：

   ```bash
   ./linux-mainline/scripts/flash-boot.sh flash-b
   ```

2. 开机后把升级包拷到平板上安装：

   ```bash
   scp linux-mainline/out/dagu-userspace-v0.1.6.tar.gz dagu@<平板IP>:
   ssh dagu@<平板IP>
   tar xzf dagu-userspace-v0.1.6.tar.gz
   sudo ./dagu-userspace-v0.1.6/install.sh
   sudo reboot
   ```

开机后在平板终端里核对 `uname -v`，应该是 `#645`。

## 9. 现在的状态

能用：屏幕（120 Hz）、触摸、磁吸键盘、Wi-Fi、蓝牙（鼠标、键盘、耳机）、四个扬声器、麦克风、前后摄像头、硬件视频解码（GStreamer 和自带的 V4L2 Chromium）、GPU（Turnip Vulkan / Freedreno OpenGL）、USB 有线充电、关机充电界面、休眠唤醒。

已知问题：

- **重力和光线传感器暂时不可用**，所以没有自动旋转和自动亮度。传感器协处理器开机后只读一个平台信息文件，不读传感器配置，原因还在查。
- 部分蓝牙鼠标第一次连接时会在 3 秒后断开，系统会自动重连，之后正常。
- mpv 播放视频走的是"硬解后拷回内存"的方式，CPU 占用比浏览器高。
- 内核里的 Wi-Fi / 蓝牙 MAC 地址是固定的。家里有两台装了本系统的平板时，需要自己编内核并填写各自的 MAC（见[刷机指南](flash-guide.md)）。

## 10. 救砖和回安卓

- 卡在小米 logo：长按电源键强制关机，再按住 **音量下 + 电源** 进 fastboot，重新执行第 6 步。
- 启动后马上回到 fastboot：执行一次 `python3 linux-mainline/scripts/fb-usb.py set-active b`，再重新执行第 6 步。
- 想回安卓：用 A 槽的原厂系统，或者按 [EDL 救援流程](../dagu-edl-recovery-full-playbook.md) 刷官方线刷包。**不要上锁**。

## 11. 不要做

- 写 A 槽，或用 `flash-boot.sh flash`（会写双槽）
- 用 Google `fastboot` 37 刷 userdata
- 刷 `dtbo-empty.img`（开机约 6 秒回 fastboot）
- Ubuntu 装好之后再刷 rootfs（数据全没）
- 装好 Ubuntu 后从 fastboot 直接启动原厂安卓的 `boot`（安卓读不了 ext4 的 userdata）

更多细节：[刷机指南](flash-guide.md) · [rootfs 说明](rootfs-guide.md)
