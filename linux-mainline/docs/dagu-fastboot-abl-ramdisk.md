# dagu：fastboot 刷写、ABL 收下镜像、ramdisk 卡住的全过程

记录日期：2026-08-30。设备当时在 Linux 7.0 ramdisk 目标（P0：RNDIS `192.168.7.2` + dropbear）上卡着。本文是实验日志，不是「已经跑通」的声明。

## 0. 目标与验收

**目标（未完成）：** 修好两件事，直到镜像被 ABL 收下并停在 P0 ramdisk，或把下一步阻塞点钉死。

1. 主机能 **稳定** 用 fastboot 把镜像刷进平板（不要卡死、不要超时、不要只写一个 slot）。
2. 刷完后 **不要秒回 fastboot**。内核要跳进去，PID1 停在 ramdisk；理想状态是主机能 ping `192.168.7.2` 并 SSH。

**当前验收（2026-08-30 21:55，stub DTBO + 撤回 combined 后的 elish USB）：**

| 项 | 状态 |
|----|------|
| 主机刷写 `boot` / `vendor_boot` / `dtbo` / `vbmeta` 双槽 | **已通**（`scripts/fb-usb.py`） |
| ABL 收下 7.0 Image 并跳转（USB 掉线后 **不再 6 秒回 fastboot**） | **已通**（需原厂 DTBO 或合法 stub DTBO，不能是 0 overlay） |
| ramdisk 站住且 RNDIS 在主机枚举 | **未通**。21:54 干净对照：reboot 后 USB 消失 40s+，无 `1d6b:0104`、ping 不通、不回 fastboot |
| 救砖回 HyperOS | **已通**（原厂 trim boot + vendor_boot + 原厂 dtbo + 原厂 vbmeta） |

**平板现在（写这条时）卡在 7.0 里、USB 全黑。** 长按电源约 10 秒强制关机，再 **按住音量下** 开机进 fastboot。不要短按电源——会再进 7.0 再卡住。

SSH（一旦 RNDIS 起来）：

```bash
ssh -i linux-mainline/out/id_dagu -o StrictHostKeyChecking=no root@192.168.7.2
```

进 fastboot：`adb reboot bootloader`，或关机后 **按住音量下开机**。核卡死、USB 消失时只能长按电源约 10 秒再按住音量下。

**不要用 Google platform-tools 37 的 `fastboot`。** AMD USB 主机上它会在 `USBDEVFS_REAPURB` 挂死。

---

## 1. 设备与仓库

| | |
|--|--|
| 设备 | 小米平板 5 Pro 12.4，代号 **dagu** / `22081281AC` / SM8250-AC |
| 序列号 | `<android-serial>` |
| BL | 已解锁 |
| 原厂系统 | HyperOS OS2.0.10.0.ULZCNXM，Android 14，内核 4.19.157-perf |
| 仓库 | 本仓库 |
| 工作目录 | `linux-mainline/`（Linux **7.0** + ramdisk + 板级 overlay） |
| 对照 | [ginkgo-mainline-linux](https://github.com/Huabin1010/ginkgo-mainline-linux)（Redmi Note 8，同是 7.0，已跑通） |
| 原厂 dump | `dumps/dagu-20260826-210700-root/`（`images/`、活机 FDT `dt/fdt.dts` / `dt/fdt.dtb`） |

主机 USB：AMD 平台上 Google `fastboot` 37 可能卡在 `USBDEVFS_REAPURB`。平板在 USB 上枚举为 `18d1:d00d`（fastboot）或 HyperOS 的 `18d1:4ee7`。

ginkgo 的铁律在 `docs/lessons-from-ginkgo.md`。本文只写 **dagu 上后来用真机打出来的、和 ginkgo 不一样或把 ginkgo 假设推翻的东西**。

---

## 2. 问题拆成两截

一开始看起来是「刷完秒回 fastboot」。后来证明是两件独立的事叠在一起：

```
主机 USB 卡住 / 超时     →  镜像根本没写进去，或 ABL 卡在 download
ABL 拒收 / Load Error    →  USB 掉线后约 6 秒 18d1:d00d 回来（根本没跳内核）
内核跳进去但立刻 SError  →  也是约 6 秒回 fastboot（pstore 空，RNDIS 从未 up）
内核跳进去并站住         →  USB 掉线后 40s+ 都不回 fastboot，但仍无 RNDIS
```

判断口诀：

- **~3–6 秒回 fastboot**：ABL 没跳，或内核入口立刻炸（DTBO 为空、DTB 选错、4 份 DTB concat、MMU off 戳 MMIO、活机 FDT 当 vendor_boot）。
- **~20–25 秒回**：更像看门狗 bark，或旧 ramdisk 去戳 4.19 gadget 把核打死。
- **USB 消失 ≥40 秒还不回来**：ABL 已经 jump，核（或死循环）还在跑。QCOM WDT 被踢着就不会自己回 fastboot。此时 **只能长按电源**。

---

## 3. 主机刷写路径（已修好）

### 3.1 现象

- `fastboot devices` 看得到 `<android-serial>`。
- `fastboot getvar` / `flash` 会永远卡住。
- 主机 dmesg 停在 `USBDEVFS_REAPURB`。
- `fwupd` 把 `18d1:d00d` 认成 Quectel EG25-G 猫。
- USB2 hardware LPM 会把 ABL 的 download 弄死。

Google platform-tools **37** 在这台 Ryzen xHCI 上不能用。不要再试。

### 3.2 解法

| 文件 | 作用 |
|------|------|
| `scripts/fb-usb.py` | 独占 libusb；末字节单独 URB；chunk 256KiB |
| `scripts/fastboot-common.sh` | 所有刷写走 fb-usb，不调 Google fastboot |
| `scripts/flash-boot.sh` | 双槽写 `dtbo` / `vbmeta` / `vendor_boot` / `boot` |
| `scripts/host-usb-fix.sh` | 停 fwupd、关 LPM、装 udev；ABL 卡 download 时对 `usb1-portN/disable` 掉电约 8 秒 |
| `host/99-dagu-fastboot-nolpm.rules` | `USB_QUIRK_NO_LPM` |

不要：

- `fastboot flash -S`（稀疏分包会把 ABL 弄疯）
- 2 字节的假 DTBO
- 把 vendor_boot 填满 96MiB 再传（会超时）。截到 AVB 后约 0.4–1.8MiB 稳定
- 192MiB 填满的 boot 用 Google fastboot；用 fb-usb 可以 OKAY

救砖：

```bash
cd linux-mainline
./scripts/flash-boot.sh restore
# 或手动：
# out/stock-trim-boot_a.img + out/stock-trim-vendor_boot_a.img
# + dumps/.../images/dtbo_a.img + vbmeta_a.img
```

大图超时用 `out/stock-trim-*.img`（截过 AVB 的原厂图）。

刷写本身在修完 fb-usb 之后就稳定了。后面所有「秒回」都不再是 USB 没写进去。

---

## 4. 镜像格式（ABL 认什么）

HyperOS 的 `boot.img` / `vendor_boot.img` 是 **Android boot header v3**：

- **boot**：raw `Image`（不是 `Image.gz`，不是 EFI stub，文件头不是 `MZ`）
- **vendor_boot**：cmdline + vendor ramdisk + **DTB**（内核 DTB 不在 boot 里）
- **dtbo**：独立分区，ABL 按 `androidboot.dtbo_idx` 叠 overlay
- **vbmeta**：AVB。自造 boot 必须 `flags=3`（verify off + hashtree off），否则 hash 对不上

从零 `mkbootimg` 打的 v2/v3，ABL 会拒。现行打包：`scripts/build-bootimg.sh` 用 **magiskboot 拆原厂 v3 再塞进去**。

### 4.1 原厂 Image 头（dump）

```
code0      = b <入口>     # 4.19 入口就在文件前部附近
code1      = 0
text_offset= 0x80000
image_size = 0x3f2a000
flags      = 0xa
无 d00dfeed（没有内嵌空 FDT）
```

活机 `/proc/iomem`：`a0080000-a2bfffff : Kernel code` = `0xA0000000 + 0x80000`。  
XBL 把 `"Kernel"` 区标在 `0xA0000000`，长度 `0x10000000`，`WRITE_BACK_XN`。  
`hyp_region@80000000` 6MiB `no-map`。`UnusableDDRMemoryStartAddr = 0x80000000`。

### 4.2 Linux 7.0 Image 差在哪

- `primary_entry` 在 Image 里大约 **+37MiB**，靠文件开头一条 `b primary_entry` 进去。
- 头里 `text_offset` 字段是 **0**（不是 0x80000）。
- arm64 defconfig 默认 `VA_BITS_52`、EFI stub、`CONFIG_KVM`。活机 4.19 是 `VA_BITS_39`、三级页表、无 KVM、无 `PTR_AUTH_KERNEL`。
- 7.0 会在 Image 里编一个 `__dtb_empty_root`，带 `d00dfeed`。magiskboot 会报 `KERNEL_DTB_SZ`。ABL 可能把第一处 FDT magic 当 x0。打包脚本会把这些 magic 打成 0。

### 4.3 现在 boot 怎么打（`build-bootimg.sh`）

Will Deacon 式 2MiB stub，让真 Image 落在 2MB 对齐的 `0xa0200000`：

- pad = `2MiB - 0x80000` = `0x180000`
- 外层头：`text_offset=0x80000`，`code0 = b +0x180000`
- 在 `file+0x80000` 再放一条 `b`，同时覆盖「跳 Image[0]」和「跳 load+text_offset」两种 ABL
- 内层：`code0 = b primary_entry`，`code1=0`，`text_offset=0`，打掉所有 `d00dfeed`
- `image_size` = pad + 内层 BSS 尺寸
- ramdisk 是自造 gzip cpio（`init.c` + minish + dropbear），不是 HyperOS ramdisk

环境变量 `BOOTIMG` 一旦被设成 `/tmp/skip-boot-dagu.img` 之类，打包会写到错误路径。打包前必须 `unset BOOTIMG VBOOT`。

`TRIM_BOOTIMG=1` 截到 AVB 后再留一点 padding，USB 才传得完。

### 4.4 vendor_boot 怎么打

- **只出一份 DTB**。原厂是 4 个 blob concat（kona v2.1 / v2 / v1 + 173 字节垃圾）。四份拼回去 ABL **Load Error**（连原厂核都不跳）。
- 主线 DTB 用 `fdtput` 改成 `qcom,msm-id = <0x164 0x20001>`、`qcom,board-id = <0 0>`（和原厂 blob[0] 一样，给 ABL 选）。
- cmdline 前加：`clk_ignore_unused pd_ignore_unused fw_devlink=off fw_devlink.sync_state=disabled kpti=off`
- **去掉** `reboot=panic_warm`（panic 会变成瞬间回 fastboot，看不到任何东西）
- 活机 dump 的 cmdline 有 `androidboot.usbcontroller=a600000.dwc3`、`kpti=off`、`kaslr-seed = <0 0>`

### 4.5 原厂 vendor_boot 四份 DTB

| blob | 内容 |
|------|------|
| `[0]` | kona v2.1：`msm-id 164 20001` `board-id 0 0` ← ABL 选这个 |
| `[1]` | v2：`164 20000` |
| `[2]` | v1：`164 10000` |
| `[3]` | 173 字节垃圾 |

CAF USB 节点（blob0）是 **旧 wrapper**：

```
ssusb@a600000 { compatible = "qcom,dwc-usb3-msm"; ...
  dwc3@a600000 { compatible = "snps,dwc3"; dr_mode = "drd"; ... }
}
```

主线 sm8250.dtsi 是：

```
usb@a6f8800 { compatible = "qcom,sm8250-dwc3", "qcom,dwc3";  /* qscratch */
  usb@a600000 { compatible = "snps,dwc3"; ... }
}
```

Linux 7.0 **同时** 编了：

- `dwc3-qcom.c`：只匹配 **`qcom,snps-dwc3`**（combined，reg[0] 当 DWC3 core，qscratch = core+0xf8800）
- `dwc3-qcom-legacy.c`：匹配 **`qcom,dwc3`**（父子节点，of_platform_populate 子 `snps,dwc3`）

所以 **原样 elish DTS 的 fallback `qcom,dwc3` 会走 legacy**，不要改成 `qcom,snps-dwc3`。

### 4.6 原厂 DTBO

- magic `0xD7B7AB1E`，29 个 overlay，表项 `id/rev/custom` 全是 0。ABL 靠 overlay 根上的 `qcom,board-id` 选。
- **idx=15**：`model = "xiaomi dagu"`，`qcom,board-id = <0x33 0>`，约 494KiB，全是 CAF pinctrl/PMIC fragment，`target = <0xffffffff>` + `__fixups__`。
- 活机 FDT 叠完之后 `qcom,board-id` 变成 `0x33`，cmdline 有 `androidboot.dtbo_idx=15`、`androidboot.dtb_idx=0`。
- 原厂 **base DTB 带 `__symbols__`**（`-@` 编出来的）。主线 qcom dtb 默认 **没有** `__symbols__`，phandle overlay 叠不上去。

---

## 5. 内核配置里已经钉死的东西（`config/dagu.fragment`）

这些是为了对齐 dump / 避免秒死，**单独改它们不能让 RNDIS 起来**：

- `VA_BITS_39`，关掉 52/48
- 无 EFI stub / 无 `CONFIG_EFI`
- 无 `KVM`、无 `PTR_AUTH_KERNEL` / `BTI_KERNEL`
- `SM_GCC_8250=y`（defconfig 没有）
- 无 `FB_SIMPLE` / `DRM_MSM` / `POWER_RESET_MSM` / `QCOM_PON`（MSM restart 会把 panic 变成 ~2 秒回 fastboot）
- `CONFIG_QCOM_WDT=y` 内建；`overlays/.../qcom-wdt-early-dagu.c` 在 `early_initcall` 里把 KPSS WDT `@17c10000` 咬合时间拉到 60s（MMU on 之后才能戳）
- **不要** 在 `head.S` `primary_entry`、MMU off 时写 WDT MMIO → SError，已撤回
- USB gadget：`DWC3` + `DWC3_QCOM` + `CONFIGFS_RNDIS` + QUSB2/QMP =y
- P0 DTS：关 mdss/gpu/pcie/UFS/USB3/remoteproc/sound/camss，只留 USB2 + 看门狗

`apply-overlays.sh` 不再补 `head.S` 踢狗。

---

## 6. 实验矩阵（按时间，真机）

计时都是「reboot 命令之后，主机 `lsusb` 看到什么」。USB 口是 `usb 1-6`。

### 6.1 已经排除的（不是主因）

| 实验 | 结果 |
|------|------|
| magiskboot 拆原厂 v3，塞 raw `Image` + 自造 ramdisk | 能刷 OKAY，秒回 |
| 关 EFI stub | 必须关；关了仍回 |
| vbmeta flags=3、空 DTBO | 能刷，仍回（空 DTBO 自己就是致命的） |
| vendor_boot 拼 4 份 DTB | ABL **Load Error**，不跳核 |
| 去掉 `reboot=panic_warm` | 仍回 |
| 原厂核 + 原厂 DTB + 只换 ramdisk | ~25s 回（旧 init 戳 4.19 gadget 把核打死） |
| 截短原厂 boot/vendor_boot/dtbo/vbmeta 整链 | **HyperOS 能起来** |
| 原厂核 + pause PID1 + **原厂 vendor_boot** | USB 消失 ~60s **不回** → ABL **会收**改过的 ramdisk |
| vanilla elish-boe DTB | 仍 6s |
| `nokaslr` `fw_devlink=off` `maxcpus=1` `kpti=off` | 仍 6s |
| 关 DRM_MSM / USB3 / MDSS / UFS / simplefb | 仍 6s |
| `head.S` MMU off 踢 KPSS WDT | 仍 6s；已撤回 |
| 512KiB text_offset 嵌套 stub | 仍 6s；已换成 2MiB stub |
| 打掉 Image 内嵌 `d00dfeed` | magiskboot 不再报 KERNEL_DTB_SZ，行为不变 |
| VA_39 + 关 PTR_AUTH_KERNEL + 关 KVM | 仍 6s（当时还叠着空 DTBO / 坏 vendor_boot） |
| 2MiB−0x80000 pad | 仍 6s（同上） |

### 6.2 活机 FDT 当 vendor_boot（有毒，不要再用）

把 dump 的 `dt/fdt.dtb`（**已经叠过 DTBO#15**）改 `board-id=0,0` 塞进 vendor_boot：

- **原厂 4.19 boot + 这份 vendor_boot + 空 DTBO → 同样 6 秒回 fastboot**
- 所以不是「7.0 Image 单独致命」
- 可能原因：已叠 overlay 的树再给 ABL 叠一次、`fdtput` 改 board-id、截 cmdline、ABL 仍要 4 blob、或还要再叠 idx=15

产物 `out/vendor_boot-livefdt.img` **禁止再刷**。

### 6.3 空 DTBO 是 ABL 拒收（2026-08-30 晚上钉死）

| 组合 | 结果 |
|------|------|
| 空 DTBO（`dt_entry_count=0`，32 字节头垫到 4K）+ 原厂 trim boot + 原厂 trim vendor_boot + vbmeta flags=3 | **6 秒回 fastboot** |
| **原厂 DTBO** + 原厂 trim boot + 原厂 trim vendor_boot + **原厂 vbmeta** | HyperOS，约 15 秒 `adb` up |

空 DTBO 为什么弹回 fastboot（和 elish wiki 的 `erase dtbo_b` 不是一回事）：[docs/dagu-dtbo-abl.md](dagu-dtbo-abl.md)。

`scripts/build-chain-extras.py` 仍会生成 `dtbo-empty.img` 做对照，**默认刷写不要用它**。`flash-boot.sh` 已改成 `dtbo-stub.img`。

### 6.4 7.0 + 原厂 DTBO + 原厂 vendor_boot（ABL 会跳）

刷：

- `dtbo` = dump 的原厂 `dtbo_a.img`（保留）
- `vbmeta` = flags=3
- `vendor_boot` = `stock-trim-vendor_boot_a.img`（CAF 四 blob）
- `boot` = `boot-dagu.img`（7.0 VA_39、KVM off、2MiB stub、打掉 empty_root）

结果：USB 掉线后 **40 秒以上不回 fastboot**，RNDIS 从未 up，pstore 空。  
含义：ABL 收下了 7.0 Image。核在跑或死循环。CAF DTB 上的 `qcom,dwc-usb3-msm` **不会** 绑 7.0 的 dwc3-qcom（新驱动不认这个 compatible，legacy 认的是 `qcom,dwc3` 不是 CAF 那个字符串）。所以 **无 UDC、无 RNDIS 是预期**。QCOM WDT 被内核驱动接着踢，**不会自己回 fastboot**，必须长按电源。

### 6.5 stub DTBO + 主线 DTB，无 `__symbols__`（~3 秒回）

第一版 stub overlay 用 `target-path = "/"`，主线 DTB 没编 `-@`：

- ABL ~3 秒回 fastboot（Load Error / overlay apply 失败）

原厂 overlay 是 `target = <0xffffffff>` + `__fixups__`，base DTB 必须有 `__symbols__`。

### 6.6 stub DTBO + 主线 DTB 带 `-@`（ABL 再收下）

改动：

- `apply-dts.sh` 给 `sm8250-xiaomi-dagu.dtb` 加 `DTC_FLAGS_... := -@`
- stub 改成 `/plugin/; &soc { dagu,dtbo-stub; }`，生成和原厂一样的 `__fixups__ { soc = ... }`
- 29 个 overlay，board-id 从原厂 dtbo 逐条抄（#15 仍是 `0x33 0`）

结果：USB 掉线 **50 秒不回 fastboot**。ABL 叠 stub 成功并跳了 7.0。仍无 RNDIS。

### 6.7 把 USB 改成 `qcom,snps-dwc3` combined（有害，已撤回）

当时误判「legacy 不会 probe」，在 `sm8250-xiaomi-dagu.dts` 里把 `&usb_1` 改成：

- `compatible = "qcom,sm8250-dwc3", "qcom,snps-dwc3"`
- `reg` 改成 core `@a600000` 长度 `0xfc100`
- 关掉子节点 `&usb_1_dwc3`
- 把 Type-C graph 接到父节点

刷完：ABL 仍收下（45 秒不回），RNDIS 仍无，sysrq/`reboot bootloader` 都拉不回来。  
后来发现 7.0 Makefile 里 `CONFIG_USB_DWC3_QCOM` **同时** 编 `dwc3-qcom.o` 和 `dwc3-qcom-legacy.o`。elish 的 `"qcom,dwc3"` fallback **本来就会走 legacy**。改成 `qcom,snps-dwc3` 等于走错驱动，reg 布局也不对。

**已改回** 只在 `&usb_1_dwc3` 上加 `role-switch-default-mode = "peripheral"`，其余 USB 交给 elish-common。

### 6.8 撤回 combined 之后的干净对照（2026-08-30 21:54）

当时设备已在 fastboot（`18d1:d00d` Device 088，`product: dagu`，slot a）。刷的是 **撤回 `qcom,snps-dwc3` 之后重新打的** 主线链，双槽：

| 分区 | 文件 | 内容 |
|------|------|------|
| `dtbo_{a,b}` | `out/dtbo-stub.img` | 10.9 KiB，29 条 board-id stub |
| `vbmeta_{a,b}` | `out/vbmeta-disabled.img` | flags=3 |
| `vendor_boot_{a,b}` | `out/vendor_boot-dagu.img` | 1200 KiB，主线 DTB：`qcom,sm8250-dwc3` + `qcom,dwc3`，子 `snps,dwc3` **未 disabled** |
| `boot_{a,b}` | `out/boot-dagu.img` | 49680 KiB，7.0 + 自造 ramdisk |

全部 `fb-usb.py` OKAY。`reboot` 时刻 **21:54:27**。

主机 `lsusb` 时序：

```
t=0s   18d1:d00d 还在（reboot 命令刚发出）
t=1s   USB 掉线
t=1..40s  无 18d1:d00d、无 1d6b:0104、无 0525:a4a2、ping 192.168.7.2 不通
t=40s  TIMEOUT；主机只剩各总线 root hub
```

**结论：** 这不是刷写失败，也不是 ABL 拒收。elish 默认 USB 拓扑（legacy `qcom,dwc3`）+ stub DTBO + 带 `__symbols__` 的主线 DTB，ABL 会跳、WDT 被踢着、主机永远看不到 gadget。P0 卡在 **7.0 USB gadget / Type-C / PM8150B role-switch / HS PHY**，不是 boot 格式。

DTS 里 USB 相关只剩：

```dts
&usb_1_dwc3 {
	role-switch-default-mode = "peripheral";
};
```

UFS / remoteproc / Himax SPI / display / GPU / PCIe 在 P0 仍 `disabled`。

### 6.9 `dr_mode=peripheral`、关掉 Type-C（2026-08-30 22:02）

假设：elish 的 `dr_mode=otg` + `usb-role-switch` 会等 PM8150B TCPM；P0 关掉 ADSP 后 role 永远不切到 device，UDC 不出现。init 以前只等 10s UDC 就放弃。

改动：

- `&usb_1_dwc3 { dr_mode = "peripheral"; }`，删除 `usb-role-switch`
- `&pm8150b_typec { status = "disabled"; }`
- init：UDC 一直等到出现再绑 RNDIS，失败不再 `reboot bootloader`

DTB 已确认：`dr_mode=peripheral`，无 `usb-role-switch`。22:02:36 双槽刷完 reboot。

结果：与 §6.8 **相同** — USB 1s 掉线，50s 无 `1d6b:0104`、ping 不通、不回 fastboot。

**结论：** 不是「卡在 Type-C role-switch 等 device」。DWC3 要么根本没 probe（PHY/时钟/SError），要么 gadget 起来了但 HS 电气到不了 Type-C（PS5169 / 线路）。

---

## 7. ramdisk（`initramfs/init.c`）

P0 路径：**不** `switch_root` userdata，只起 RNDIS + dropbear，然后 `sleep`。

- 4.19：检测到 `Linux version 4.` 就 **完全不碰** configfs gadget（会 panic → 回 fastboot）。pause PID1 对照用过这个。
- 7.0：`force_usb_device_role` 写 `/sys/class/usb_role/*/role = device`，等 `/sys/class/udc` 最多约 10s，再 configfs RNDIS（vid `1d6b` pid `0104`），`usb0` = `192.168.7.2`。
- 失败则 `sleep 5` 后尝试 `reboot bootloader`，再 `sysrq-trigger b`。  
  **实测拉不回来**：`POWER_RESET_QCOM_PON` 关着，`&pon { mode-bootloader }` 没有驱动；sysrq 要么没跑到（核在 probe 里挂了），要么 gadget 自认为成功所以没走失败路径。
- PID1 **禁止 exit**（会 panic）。

没有 UART。看不见 dmesg 就只能看主机 USB 时序。

---

## 8. 现行文件与默认刷写

| 路径 | 现在干什么 |
|------|------------|
| `scripts/fb-usb.py` | 唯一刷写通道 |
| `scripts/flash-boot.sh` | 默认：`dtbo-stub` + `vbmeta-disabled` + `vendor_boot-dagu` + `boot-dagu`，**双槽** |
| `scripts/flash-boot.sh restore` | 原厂 dump 的 dtbo/vbmeta/vendor_boot/boot |
| `scripts/build-bootimg.sh` | magiskboot v3 + 2MiB stub + 单份主线 DTB |
| `scripts/build-chain-extras.py` | `dtbo-stub.img`（29 条 board-id）+ `vbmeta-disabled`；仍写 `dtbo-empty` 但不默认刷 |
| `scripts/apply-dts.sh` | 安装 dagu DTS，并 `DTC_FLAGS_sm8250-xiaomi-dagu := -@` |
| `dts/sm8250-xiaomi-dagu.dts` | elish-common + CAF 风格 `/memory` + 关 display/UFS/…；USB 走 legacy |
| `config/dagu.fragment` | VA_39、无 KVM/EFI、GCC、gadget、WDT |

产物（`linux-mainline/out/`，不入库）：

| 文件 | 说明 |
|------|------|
| `boot-dagu.img` | 7.0 + 自造 ramdisk |
| `vendor_boot-dagu.img` | 主线 DTB，msm-id/board-id 已补 |
| `dtbo-stub.img` | 29 条无操作 overlay |
| `vbmeta-disabled.img` | flags=3 |
| `stock-trim-boot_a.img` / `stock-trim-vendor_boot_a.img` | 救砖 / 对照 |
| `dtbo-empty.img` | **不要刷** |
| `vendor_boot-livefdt.img` | **不要刷** |

---

## 9. 明确不要再做的事

1. 不要用 Google fastboot 37。
2. 不要刷 `dtbo-empty.img`（0 overlay）。
3. 不要把活机 `fdt.dtb` 当 vendor_boot DTB。
4. 不要把 4 份 CAF DTB concat 进 vendor_boot。
5. 不要在 MMU off 的 `primary_entry` 里写 KPSS WDT。
6. 不要把 `&usb_1` 改成 `qcom,snps-dwc3` combined / 关掉 `&usb_1_dwc3`。
7. 不要只写 A 槽（小米会从 B 槽救回来，表现成「刷了没生效」）。
8. 核站住但 USB 没枚举时，不要以为「又秒回了」——去看是不是 40s+ 都没 `18d1:d00d`。这时长按电源，**按住音量下开机**，不要只短按电源（会再次进 7.0 再卡住）。

---

## 10. 救砖与对照命令

回 HyperOS（确认机器还活着）：

```bash
cd linux-mainline
# 设备必须已经在 fastboot（18d1:d00d）
python3 scripts/fb-usb.py flash dtbo_a ../dumps/dagu-20260826-210700-root/images/dtbo_a.img
python3 scripts/fb-usb.py flash dtbo_b ../dumps/dagu-20260826-210700-root/images/dtbo_b.img
python3 scripts/fb-usb.py flash vbmeta_a ../dumps/dagu-20260826-210700-root/images/vbmeta_a.img
python3 scripts/fb-usb.py flash vbmeta_b ../dumps/dagu-20260826-210700-root/images/vbmeta_b.img
python3 scripts/fb-usb.py flash vendor_boot_a out/stock-trim-vendor_boot_a.img
python3 scripts/fb-usb.py flash vendor_boot_b out/stock-trim-vendor_boot_a.img
python3 scripts/fb-usb.py flash boot_a out/stock-trim-boot_a.img
python3 scripts/fb-usb.py flash boot_b out/stock-trim-boot_a.img
python3 scripts/fb-usb.py set-active a
python3 scripts/fb-usb.py reboot
# 约 15s 应出现 adb device <android-serial>
```

或 `./scripts/flash-boot.sh restore`（写 dump 里未截短的满分区图，USB 更慢但等价）。

刷当前主线链：

```bash
cd linux-mainline
unset BOOTIMG VBOOT
TRIM_BOOTIMG=1 ./scripts/build-bootimg.sh   # 若 DTS/init 刚改过
./scripts/flash-boot.sh flash               # 双槽 stub dtbo + 7.0 boot + 主线 vendor_boot
```

---

## 11. 下一步阻塞点（2026-08-30 21:55）

**不是** 主机刷写，**不是** v3 magiskboot 格式，**不是** ramdisk cpio 对 4.19 的协议（原厂核 + pause 能活），**不是** ABL 拒收 7.0，**不是** 空 DTBO / 活机 FDT / 4 blob concat / combined `qcom,snps-dwc3`。

已经证明：

1. ABL 会跳 7.0 Image（原厂 DTBO+原厂 vendor_boot，或 stub DTBO + 带 `__symbols__` 的主线 DTB）。
2. 主机看不到 RNDIS。无 UART，失败时也几乎拿不到 pstore。
3. 用 combined `qcom,snps-dwc3` 拆掉 legacy 是错的，已撤回。
4. **§6.8 干净对照已做完**：elish USB + legacy `qcom,dwc3` + stub DTBO + 主线 DTB → 仍 40s+ 无 gadget。

阻塞点就是 **7.0 gadget 在这根 Type-C / PM8150B role-switch 上没枚举**（HS PHY、role-switch、qusb2、或 probe 挂死）。没有串口，看不见 dmesg。

下一步（按性价比，不要再碰 VA/KVM/stub 格式）：

1. **让核自己死回 fastboot**，证明 PID1 有没有跑到：把 early WDT 咬合改短（例如 8–15s），或让 init 在等 UDC 失败后走一条 **一定能复位** 的路径。现在 `POWER_RESET_QCOM_PON` 关着，`reboot bootloader` / sysrq-b 拉不回来，分不清是「init 没起来」还是「UDC 没出现但 init 在 sleep」。
2. **对照：原厂 4.19 + 主线 ramdisk（pause，不碰 gadget）** 已经能活。下一步可以试 **原厂 4.19 + 自造 ramdisk 起 RNDIS**（4.19 路径目前故意完全不碰 configfs）。若 4.19 能枚举 RNDIS，说明 Type-C 硬件和 ABL USB 交接没问题，锅在 7.0 驱动；若 4.19 也不出 gadget，锅在 ramdisk/configfs 或 role-switch 用户态。
3. 查主线 elish / sm8250 上 `usb_role`、`qcom,pmic-glink`、`extcon` 在 P0 关掉 remoteproc 之后是否根本没有 role-switch 设备，导致 DWC3 停在 host。
4. 极简核：只留 GCC + QUSB2 + DWC3 + gadget，把其余 probe 砍光，降低「卡在无关驱动」的概率。
5. 找 pstore / ramoops 在 dagu 4.19 活机 FDT 里的地址，看 7.0 崩了能不能留下一行。

不要再在 VA/KVM/嵌套 stub/活机 FDT/空 DTBO/`qcom,snps-dwc3` combined 上打转。
