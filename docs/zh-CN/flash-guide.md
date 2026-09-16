**语言：** [English](../flash-guide.md) | 简体中文

# 刷机指南（小米平板 5 Pro 12.4 / dagu）

只适用于小米 **平板 5 Pro 12.4**（代号 **dagu** / `22081281AC` / SM8250）。不要刷到 nabu、elish、pipa、ginkgo。

需要 **解锁 bootloader**。**A 槽是救援计算机**（TWRP / 原厂）。本树日常只写 **B 槽**。

## 下载什么

GitHub [Release](https://github.com/Huabin1010/dagu-mainline-linux/releases) 提供启动链：

| 附件 | 刷到 | 说明 |
|------|------|------|
| `boot-dagu.img` | `boot_b` | Linux 7.0 Image + DTB + initramfs |
| `vendor_boot-dagu.img` | `vendor_boot_b` | 主线 vendor_boot |
| `dtbo-stub.img` | `dtbo_b` | 带 board-id 的 stub。**禁止**刷 `dtbo-empty.img` |
| `vbmeta-disabled.img` | `vbmeta_b` | 关掉 verified boot |
| `SHA256SUMS` | — | 刷之前先校验 |
| `rootfs-desktop.ext4.zst` | `userdata` | GNOME 桌面。**会清空安卓 `/data`** |

Ubuntu 在 **userdata**（不是 A/B）。刷入或自己编：[rootfs 教程](rootfs-guide.md)。

## 电脑 USB

**不要**用 Google platform-tools 37 的 `fastboot`（AMD 主机上会卡在 `USBDEVFS_REAPURB`）。刷写走仓内工具：

```bash
linux-mainline/scripts/fb-usb.py
# 包装：
linux-mainline/scripts/flash-boot.sh flash-b
```

进 fastboot：音量下 + 电源，或安卓里 `adb reboot bootloader`。

```bash
# product 必须是 dagu
python3 linux-mainline/scripts/fb-usb.py getvar product
```

`product` 不是 `dagu` 就停手。

## 首次安装（会清空安卓 userdata）

```bash
git clone https://github.com/Huabin1010/dagu-mainline-linux.git
cd dagu-mainline-linux
./linux-mainline/scripts/setup-deps.sh
./linux-mainline/scripts/setup-kernel.sh
./linux-mainline/scripts/stage-firmware.sh   # blob 从你自己的 dump 来，不入库

cp linux-mainline/dts/local-addresses.dtsi.example \
   linux-mainline/dts/local-addresses.dtsi
# 按本机 persist 填 MAC / 蓝牙。不要提交这个文件。

DAGU_MINIMAL=1 DAGU_DISPLAY=1 ./linux-mainline/scripts/build-kernel.sh
./linux-mainline/scripts/build-bootimg.sh

# 桌面 userdata：从 Release 下 rootfs-desktop.ext4.zst，或自己编：
ROOT_PASSWORD=... ./linux-mainline/scripts/build-rootfs-desktop.sh
./linux-mainline/scripts/flash-rootfs.sh          # userdata，安卓 /data 没了
./linux-mainline/scripts/flash-boot.sh flash-b    # 只写 B：dtbo / vbmeta / vendor_boot / boot
```

也可以直接下 Release（启动链 + 桌面 rootfs）：

```bash
gh release download --repo Huabin1010/dagu-mainline-linux --dir linux-mainline/out
cd linux-mainline/out && sha256sum -c SHA256SUMS && sha256sum -c rootfs-desktop.SHA256SUMS
cd ../..
./linux-mainline/scripts/flash-rootfs.sh
./linux-mainline/scripts/flash-boot.sh flash-b
```

`flash-b` 会重启。USB gadget `0525:a4a7` 须保持 **>30 秒**。若约 6 秒变回兔子 `18d1:d00d`，是 ABL 拒镜像（空 DTBO 最常见）。

## 只更新内核（保留 Ubuntu）

userdata 已经是 Ubuntu，**不要再刷 userdata**。

```bash
# 设备在 fastboot
./linux-mainline/scripts/flash-boot.sh flash-b
```

写入 `dtbo_b`、`vbmeta_b`、`vendor_boot_b`、`boot_b`，再 `set_active b`。A 槽不动。

内置麦克风的 UCM 在 rootfs 里。旧 Ubuntu 只刷了内核时，再推用户态：

```bash
DAGU_HOST=<平板Wi-Fi地址> ./linux-mainline/scripts/dagu-mic-deploy.sh
```

## 开机之后

| 方式 | 命令 |
|------|------|
| USB 串口 | `python3 linux-mainline/scripts/dagu-console.py`（`/dev/ttyACM0`，`0525:a4a7`） |
| USB RNDIS SSH | `ssh -i linux-mainline/out/id_dagu root@192.168.7.2` |
| Wi-Fi SSH | 平板局域网地址，同一把钥匙 |

**预构建**桌面账号是 `dagu` / `dagu`（root 相同），进系统后改掉。本机编镜像用 `ROOT_PASSWORD`，不要提交。

桌面：GNOME Speakers + **Built-in Microphone**（WCD9385 AMIC5，对齐安卓 speaker-mic）。userdata 细节：[rootfs 教程](rootfs-guide.md)。

## 救砖

A 槽保持原厂 / TWRP。切回去：

```bash
./linux-mainline/scripts/flash-boot-legacy.sh restore-a
```

Logo 卡住就长按电源，再按住音量下进 fastboot。

EDL 9008 + 官方 `flash_all`：[EDL 流程](../dagu-edl-recovery-full-playbook.md)。**不要 lock**。

## 不要做

- 写 A 槽，或日常用 `flash-boot.sh flash`（双槽）
- 用 Google `fastboot` 37 写分区
- 刷 `dtbo-empty.img`（`dt_entry_count=0`，约 6 秒回 fastboot）
- userdata 已是 Ubuntu 后再 `fastboot reboot` 进当前槽的原厂安卓 `boot`
- 把 `vreg_l3a_0p9` 改成 1.104V、Himax reset 绑 GPIO100、或 `DAGU_PRIMARY_ENTRY_PROBE=1`
- 把你自己的密码、SSH 钥匙、persist MAC 放进公开镜像
