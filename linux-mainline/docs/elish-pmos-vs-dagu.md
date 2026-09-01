# elish（Pad 5 Pro 11"）pmOS 对照 dagu（12.4"）

Wiki：<https://wiki.postmarketos.org/wiki/Xiaomi_Mi_Pad_5_Pro_(xiaomi-elish)>（站点有 Anubis，抓取常失败；以仓库为准）。

本机克隆（`vendor/` 已 gitignore，不入库）：

| 路径 | 来源 |
|------|------|
| `vendor/pmaports/` | <https://gitlab.postmarketos.org/postmarketOS/pmaports> 稀疏：`device-xiaomi-elish`、`linux-postmarketos-qcom-sm8250`、pipa |
| `vendor/linux-sm8250-pmos/` | 同项目内核 fork，tag `sm8250-7.2.0`，只检出 DTS + USB/PHY |
| `vendor/xiaomi-elish-firmware/` | <https://github.com/lujianhua/xiaomi-elish-firmware> |

pmaports **没有** `xiaomi-dagu`。12.4 不能刷 11" 的 pmOS 镜像。

## 这一代平板怎么分

| 代号 | 产品 | SoC | 主线 / pmOS |
|------|------|-----|-------------|
| **elish** | Pad 5 Pro **11" Wi‑Fi**（2021） | SM8250 | 已进 pmaports testing + 主线 `sm8250-xiaomi-elish-{boe,csot}.dts` |
| **enuma** | Pad 5 Pro **11" 5G** | SM8250 | 共用 `elish-common`，只改 `board-id` / 面板 / Wi‑Fi BDF |
| **dagu** | Pad 5 Pro **12.4"**（`22081281AC`） | SM8250-**AC** | 无 pmOS；我们这套 7.0 + `sm8250-xiaomi-dagu.dts` |
| pipa | Pad **6** | SM8250 | 另一块板，不要当 5 Pro 用 |

elish 能跑通，说明 **SM8250 + 这套 Xiaomi ABL 家族上主线 USB 是可行的**。dagu 不是换 SoC，是板级差 + 启动协议差。

## 硬件差（不能抄 elish 设备树的部分）

| | elish 11" | dagu 12.4" |
|--|-----------|------------|
| `qcom,board-id` | pmOS 7.2：`<0x2f 0>`；主线 7.0 common 曾是 `<0x10008 0>` | 活机 / CAF：`<0x33 0>`（51） |
| 面板 | NT36523 **CPHY**，BOE / CSOT 两份 DTB | **L81A dual-DPHY**，开 elish CPHY 会 SError |
| 触控 | Novatek `nt36523_ts` | Himax HX83121 SPI GPIO39/100 |
| 电池 | 一块 ~8600 mAh（pmOS 写成单 `battery`） | 双 BQ27Z561，各 5000 mAh |
| 键盘 | `usb_2` host + pogo 供电脚 | nanosic@i2c2，不是第二路 DWC3 |
| USB Type-C | HS-only，`dr_mode=otg` + `usb-role-switch` + PM8150B Type-C | 硅上也是 HS + QMP/DP；P0 不要开 USB3/QMP |
| 内存节点 | 跟 sm8250.dtsi / 各机 reserved-memory | dagu 必须自己写 `memory { reg = ... }`，否则 0 RAM panic |

USB 控制器节点 **elish 和我们抄的是同一份**：

```
&usb_1 { qcom,select-utmi-as-pipe-clk; }
&usb_1_dwc3 { dr_mode = "otg"; maximum-speed = "high-speed";
              phys = <&usb_1_hsphy>; phy-names = "usb2-phy"; usb-role-switch; }
```

pmOS 7.2 另外开了 **`usb_2` host**（键盘仓）。dagu dump 里那路是关的，P0 不要开。

## 启动协议差（不能抄 pmOS 打包方式）

**原厂 elish 也是 boot header v3**，不是 v2。线刷包 `elish_images_OS1.0.2.0.TKYCNXM`（Android 13 / HyperOS 1）拆过：`boot.img` `header_version=3` / `header_size=1580`，有 `VNDRBOOT` v3，`dtb_size≈1.5MiB`，dtbo magic `D7B7AB1E`、**29** 条。和 dagu 原厂同一套布局。记录：[devices/elish-stock-OS1.0.2.0.TKYCNXM](../../devices/elish-stock-OS1.0.2.0.TKYCNXM/)。

教程能 `erase dtbo` + `append_dtb`，是 **pmOS 自造 boot**（`deviceinfo` 没写 `header_version`，mkbootimg 默认 **v0** + kernel 后 concat DTB），不是因为 11" 出厂是 v2。格式：[elish-pmos-boot-format.md](elish-pmos-boot-format.md)。为何这套能跳核（ABL gzip 路径、不读 vendor_boot）：[elish-abl-legacy-boot-path.md](elish-abl-legacy-boot-path.md)。

elish `deviceinfo`：

- `generate_bootimg=true`，**没有** `header_version`（不是 v2，也不是 v3）
- `append_dtb=true`（DTB 粘在 `vmlinuz` 后面）
- 内核包是 **Image.gz / EFI ZBOOT**（`CONFIG_EFI_ZBOOT=y`，`VA_BITS_48`）
- cmdline 设备包里只有 `quiet`
- 不写 `vendor_boot`

这在 11" 的 ABL 上通了。**dagu 这台 HyperOS ABL 已经打过对照**：from-scratch `mkbootimg`、`Image.gz`、活机 FDT 当 vendor_boot、四份 DTB concat 都会拒收或秒回 fastboot。dagu 必须：

1. magiskboot 基于原厂 **v3** `boot` / `vendor_boot`
2. **raw Image** + 2MiB stub pad
3. DTB 放 **vendor_boot**（msm-id/board-id 按 ABL 选 DT 的那套）
4. 合法 DTBO（不能 `dt_entry_count=0`），双槽。wiki 的 `erase dtbo_b` ≠ 刷空表，见 [dagu-dtbo-abl.md](dagu-dtbo-abl.md)
5. `VA_BITS_39`，关 EFI stub（和 ginkgo / 活机 4.19 一致）

所以 **不要** 对 dagu 跑 `pmbootstrap install --device xiaomi-elish`，也 **不要** 把 elish 的 boot.img 刷进来。

## 内核配置：pmOS 已经证明对的、我们漏过的

`linux-postmarketos-qcom-sm8250`（7.2）里：

```
CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2=y    # sm8250 HS PHY，不是 QUSB2
CONFIG_USB_DWC3=y
CONFIG_USB_DWC3_QCOM=y
CONFIG_USB_DWC3_DUAL_ROLE=y
CONFIG_USB_GADGET=y
CONFIG_USB_CONFIGFS=m                  # 他们靠发行版 initramfs insmod
CONFIG_USB_CONFIGFS_RNDIS=y
CONFIG_TYPEC_QCOM_PMIC=y
CONFIG_QCOM_WDT=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_POWER_RESET_QCOM_PON=m          # 才能 reboot bootloader
```

我们 ramdisk 没有 `modprobe`，gadget/PHY **必须 =y**。之前 `.config` 里 `FEMTO_V2=m`，DWC3 会一直等 PHY，主机永远看不到 `1d6b:0104`。已改成 =y（与 pmOS 一致）。

他们 gadget 是模块，是因为 **pmOS initramfs 会装模块**。这不是 dagu 该学的；我们继续 builtin。

`POWER_RESET_QCOM_PON` 我们 fragment 里是关掉的，所以 PID1 里 `reboot_bootloader()` 经常是空操作。elish 能「USB 挂了再回 fastboot」，有一部分靠这个。

## 对我们 P0（RNDIS）的含义

1. **USB 拓扑抄 elish 是对的**，不要再改成 `qcom,snps-dwc3` combined，不要开 QMP/DP。
2. **打包方式不能抄 pmOS**，继续 magiskboot v3。
3. PHY 必须 builtin——这点 pmOS 和我们刚修的是同一条。
4. elish 靠 **Type-C TCPM 把角色打成 device** 才出 UDC。我们关掉 `pm8150b_typec`、改 `dr_mode=peripheral`，是为了绕过没 ADSP 的 TCPM；若 FEMTO=y 之后仍无 UDC，下一步是 **把 elish 的 otg + typec 原样加回来** 做一次对照（不要同时开 usb_2）。
5. 固件布局可抄：`qcom/sm8250/xiaomi/<board>/{adsp,slpi,venus,a650_zap}.mbn`。blob **必须用 dagu dump 里签过名的**，不能用 elish 的（secure boot）。
6. 面板/触控/键盘整段换自己的驱动，不要用 elish 的 NT36523。

## 现场怎么用这些树

```bash
# USB 节点（应与我们 include 的 elish-common 一致）
less vendor/linux-sm8250-pmos/arch/arm64/boot/dts/qcom/sm8250-xiaomi-elish-common.dtsi

# 设备包：boot 格式、双面板 DTB 名、initramfs 模块列表
less vendor/pmaports/device/testing/device-xiaomi-elish/deviceinfo
less vendor/pmaports/device/testing/linux-postmarketos-qcom-sm8250/config-postmarketos-qcom-sm8250.aarch64
```
