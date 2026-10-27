# dagu Windows 11 ARM — 第一个能启动的 UEFI 固件（2026-10-27 20:52）

这是 Windows 11 ARM 第一次在 dagu（小米平板 6S Pro 12.4，SM8250）上**成功启动**所用的固件镜像快照，留档以便源码漂移或构建环境损坏时能原样刷回。

## 镜像

| 文件 | 说明 |
|---|---|
| `boot-dagu-uefi-v3.img` | 刷进 `boot_a` 的 UEFI 启动镜像（v3 重打包）。**就是它让 Windows 起来的。** |
| `vendor_boot-dagu-uefi.img` | 配套 `vendor_boot_a`（与 Linux #654 原版 vendor_boot 相同）。 |
| `xiaomi-dagu-uefi-debug.img` | Mu 原始负载（shim + FD），非刷机用，留作比对。 |

校验值见 `SHA256SUMS`（`boot` 镜像 sha256 开头 `36876af7`）。

## 怎么构建出来的

关键点：**必须用精简 DSDT**。完整 DSDT（30+ 设备）会让内核在 `ExitBootServices`（`PROGRESS CODE: V03101019`）之后立刻挂死；只保留 `ufs` + `Pep_lpi` 两个设备就能进系统。

```bash
cd winarm
DSDT_ONLY="ufs Pep_lpi" ./build-dagu-uefi.sh
# 产物：out/boot-dagu-uefi-v3.img（+ vendor_boot-dagu-uefi.img）
```

直接跑 `./build-dagu-uefi.sh`（不带 `DSDT_ONLY`）会编出完整 DSDT 的固件，**不能启动**。

对应源码状态见本次提交（git log 里标题含 “first Windows 11 ARM boot”）。背景与后续步骤见
[docs/dagu-woa-debug-handbook.md](../../docs/dagu-woa-debug-handbook.md) 第 5 节。

## 怎么刷（只刷 A 槽，保留 B 槽 Linux 回退）

板子进 fastboot（`18d1:d00d`）后：

```bash
python3 linux-mainline/scripts/fb-usb.py flash boot_a        backups/woa-first-windows-boot-20261027/boot-dagu-uefi-v3.img
python3 linux-mainline/scripts/fb-usb.py flash vendor_boot_a backups/woa-first-windows-boot-20261027/vendor_boot-dagu-uefi.img
python3 linux-mainline/scripts/fb-usb.py reboot
```

**不要**用 `flash-boot.sh flash`：它会同时写两个槽，会把 B 槽的 Linux 回退覆盖掉。

> 注：`*.img` 被 `.gitignore` 忽略，所以这几个镜像文件只在本机留档，不进 git；只有本 README 和 `SHA256SUMS` 入库。
