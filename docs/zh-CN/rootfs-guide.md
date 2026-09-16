**语言：** [English](../rootfs-guide.md) | 简体中文

# Ubuntu 桌面 rootfs（小米平板 5 Pro 12.4 / dagu）

Ubuntu 在 **userdata**（整机一份，不是 A/B）。刷它会 **清空安卓 `/data`**。内核仍只写 **B 槽**。只适用于 `dagu` / `22081281AC`。

启动链怎么刷：[刷机指南](flash-guide.md)。本页只讲 rootfs。

## 最简单：下预构建桌面镜像

Release 提供压缩后的 GNOME 桌面（Ubuntu 26.04 `resolute`，`dagu-resize-root` 第一次开机扩到整块 userdata）：

| 附件 | 说明 |
|------|------|
| `rootfs-desktop.ext4.zst` | 桌面 userdata 镜像（zstd） |
| `rootfs-desktop.SHA256SUMS` | 校验 |

预构建默认账号（**进桌面后立刻改密码**）：

| 用户 | 密码 | 用途 |
|------|------|------|
| `dagu` | `dagu` | GNOME 自动登录 |
| `root` | `dagu` | USB 串口 / SSH |

仓库和脚本里 **没有** 写死密码；只有这份公开预构建用上面这对，方便第一次开机。不要把你自己的密码推进 git 或 Release。

```bash
git clone https://github.com/Huabin1010/dagu-mainline-linux.git
cd dagu-mainline-linux

gh release download --repo Huabin1010/dagu-mainline-linux --dir linux-mainline/out \
  --pattern 'rootfs-desktop.*' --pattern 'boot-dagu.img' --pattern 'vendor_boot-dagu.img' \
  --pattern 'dtbo-stub.img' --pattern 'vbmeta-disabled.img' --pattern 'SHA256SUMS'

cd linux-mainline/out
sha256sum -c SHA256SUMS
sha256sum -c rootfs-desktop.SHA256SUMS
cd ../..

# 设备已解锁，音量下 + 电源进 fastboot，product 必须是 dagu
python3 linux-mainline/scripts/fb-usb.py getvar product

./linux-mainline/scripts/flash-rootfs.sh          # userdata，安卓 /data 没了
./linux-mainline/scripts/flash-boot.sh flash-b    # 只写 B 槽，然后重启
```

`flash-rootfs.sh` 会解压 `.zst`，再用仓内 `fb-usb.py -S 256M` 稀疏写入（ABL 单次下载上限约 768 MiB，**不要**用 Google platform-tools 37 的 `fastboot`）。

USB gadget `0525:a4a7` 须保持 **>30 秒**。约 6 秒变回兔子 `18d1:d00d` 通常是刷了空 DTBO。

## 刷完之后

| 方式 | 命令 |
|------|------|
| 桌面 | GNOME 自动登录用户 `dagu` |
| USB 串口 | `python3 linux-mainline/scripts/dagu-console.py` |
| USB 串口登录 | `root` / `dagu`（预构建） |
| Wi-Fi SSH | 平板连上网络后，同一密码 |

第一次开机 `dagu-resize-root` 把 8 GiB 镜像扩到 userdata（约 228 GiB）。扬声器和内置麦（WCD9385 AMIC5）已进 UCM。改密码：

```bash
passwd
sudo passwd root
```

## 自己构建

需要：解包过的固件（`./linux-mainline/scripts/stage-firmware.sh`，blob 不入库）、主机 `qemu-user`、一次很长的 qemu apt（GNOME）。

### 桌面（和预构建同一条路径）

```bash
./linux-mainline/scripts/setup-deps.sh
./linux-mainline/scripts/stage-firmware.sh

ROOT_PASSWORD='your-secret' ./linux-mainline/scripts/build-rootfs-desktop.sh
# 产物：linux-mainline/out/rootfs-desktop.ext4 和 .zst

./linux-mainline/scripts/flash-rootfs.sh
./linux-mainline/scripts/flash-boot.sh flash-b
```

`build-rootfs-desktop.sh` 会：Ubuntu 26.04 minbase → `rootfs-desktop-setup.sh`（GNOME、GDM、ALSA UCM、平板会话）→ 打 8 GiB ext4（无洞，避免 journal 被 sparse 跳过）→ zstd。**不要**把 `ROOT_PASSWORD` 或 `out/root-password` 提交进 git。公开预构建请设 `SKIP_HOST_SSH_KEY=1`（脚本默认已是）。

### 只要控制台（没有 GNOME）

```bash
ROOT_PASSWORD='your-secret' ./linux-mainline/scripts/build-rootfs.sh
./linux-mainline/scripts/build-rootfs-image.sh
IMG=linux-mainline/out/rootfs.ext4 ./linux-mainline/scripts/flash-rootfs.sh
```

默认 `SUITE=noble`。桌面预构建用 `resolute`（26.04），和板上 Mesa / mutter 合同一致。

## 不要做

- 把 rootfs 刷进 `boot` / `super` / A 槽
- 用 Google `fastboot` 37 写 4–8 GiB userdata（AMD 主机卡 `USBDEVFS_REAPURB`；也不走 768 MiB 上限）
- userdata 已经是 Ubuntu 后再刷一遍 rootfs（会抹掉你装的软件）
- 把密码、`id_dagu`、persist MAC 放进公开镜像
- 刷完 userdata 立刻 `fastboot reboot` 进当前槽的原厂安卓 `boot`（挂不上 Ubuntu）。先 `flash-boot.sh flash-b`
