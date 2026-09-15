# 硬件清单 — dagu (小米平板5 Pro 12.4)

> Golden Baseline 最新采集：**2026-08-26（Magisk root）**  
> 原始数据：`dumps/dagu-20260826-210700-root/`（约 1.9 GiB，gitignore）  
> 说明：`dumps/dagu-20260826-210700-root/README.md`  
> 首次采集（解锁前）：`dumps/dagu-20260719-092500/`

**状态：** ✅ Bootloader 已解锁 · ✅ Magisk 30.7 root · ✅ iomem / live DTB / dmesg / 启动分区已采集

---

## 设备标识

| 字段 | 值 | 来源 |
|------|-----|------|
| 产品名 | Xiaomi Pad 5 Pro 12.4 | `ro.product.marketname` |
| 内部代号 | **dagu** | `ro.product.device` |
| 型号 | **22081281AC** | `ro.product.model` |
| SoC | **SM8250** (骁龙 870) | `ro.soc.model` |
| 平台代号 | **kona** | `ro.board.platform` |
| RAM | **~8 GB** | `/proc/meminfo` |
| 存储 | **256 GB**（userdata ~228 GiB） | fastboot + `df` |
| Android | **14** / OS2.0.10.0.ULZCNXM | getprop |
| 内核 | 4.19.157-perf (2025-07-01) | `uname -a` |
| **Bootloader** | **unlocked** | `ro.secureboot.lockstate` / fastboot |
| Verified Boot | **orange**（已解锁预期状态） | `ro.boot.verifiedbootstate` |
| 当前 slot | **a** | fastboot `current-slot` |
| Root | **Magisk 30.7**（`su` 可用） | `adb shell su -c id` |

---

## 分区布局（fastboot getvar）

完整输出：`dumps/dagu-20260719-094103/fastboot-getvar-all.txt`  
符号链接列表：`dumps/dagu-20260719-094103/partition-by-name.txt`

| 分区 | 大小 (fastboot) | 备注 |
|------|-----------------|------|
| userdata | `0x3879FFB000` (~228 GiB) | 用户数据 |
| super | `0x220000000` (8.5 GiB) | 动态分区 |
| boot_a | `0xC000000` (192 MiB) | 当前备用 slot b |
| vendor_boot_a | `0x6000000` (96 MiB) | |
| boot_a 块设备 | sde12 / boot_b sde37 | 见 partition-by-name |

> WoA 分区改造前请再次 `fastboot getvar all` 备份，并参考 nabu 指南。

---

## SoC 与子系统

| 子系统 | 型号 / 节点 | 证据 | WoA |
|--------|-------------|------|-----|
| CPU | Kryo 585 ×8, ARMv8 atomics | cpuinfo | ⬜ |
| GPU | **Adreno650v3** | kgsl sysfs | ⬜ |
| UFS | **1d84000.ufshc**, SM8 UFS | getprop + fastboot variant | ⬜ |
| USB | **a600000.dwc3** | `/sys/class/udc/` | ⬜ |
| 显示 | **2560×1600** LCD | dumpsys display | ⬜ |
| 面板 DT | `dsi-panel-l81a-42-04-0a` | [MiCode dagu-s-oss](https://github.com/MiCode/kernel_devicetree/tree/dagu-s-oss) | ⬜ |
| 触控 | **himax-touchscreen** + Xiaomi Touch | getevent | ⬜ |
| 音频 | **kona-mtp-snd-card** | getevent；overlay 见 `dagu-audio-overlay.dtsi` | ⬜ |
| Wi-Fi | **cnss_pci** | wlan0 driver | ⬜ |
| IMU | **lsm6dso** (STMicro) | sensorservice | ⬜ |
| 光线 | **tcs3701**, **rohm_bu27030** | sensorservice | ⬜ |

---

## 内存映射 / 设备树

| 资源 | 状态 | 说明 |
|------|------|------|
| `/proc/iomem` | ✅ | `dumps/.../memory/iomem.txt`；UFS `1d84000`、GPU `03d00000`、USB `dwc3@a600000` |
| live FDT | ✅ | `dt/fdt.dtb` + `dt/fdt.dts`（model=`xiaomi dagu`，`qcom,kona-mtp`） |
| `dmesg` | ✅ | `logs/dmesg.txt` |
| 面板 | ✅ | `qcom,mdss_dsi_l81a_42_04_0a_dual_dphy_video` |
| 触控 | ✅ | `himax,hxcommon`；input=`himax-touchscreen` |
| **开源 DT 参考** | ✅ | [MiCode/kernel_devicetree `dagu-s-oss`](https://github.com/MiCode/kernel_devicetree/tree/dagu-s-oss) |

UEFI 内存映射与 ACPI 应对这份 live DTB / iomem，不要再只用临时 elish DTB。

---

## Fastboot 关键变量

```
product: dagu
unlocked: yes
serialno: <android-serial>
current-slot: a
variant: SM8 UFS
verified boot state: orange (post-unlock)
```

完整：`dumps/dagu-20260719-094103/fastboot-getvar-all.txt`

---

## 采集文件索引

| 文件 | 状态 |
|------|------|
| `getprop.txt` / `getprop-full.txt` | ✅ |
| `fastboot-getvar-all.txt` | ✅ 新增 |
| `partition-by-name.txt` | ✅ |
| `getevent-lp.txt` / `dumpsys-display.txt` | ✅ |
| `iomem.txt` / `fdt.dtb` / `fdt.dts` / `dmesg.txt` | ✅ 2026-08-26 root 采集 |

---

## 下一步（Phase 1）

1. [ ] 克隆 [edk2-msm](https://github.com/edk2-porting/edk2-msm)，基于 j716f 模板添加 `dagu` 配置  
2. [ ] 从 [MiCode dagu-s-oss](https://github.com/MiCode/kernel_devicetree/tree/dagu-s-oss) 提取 DTB/内存映射参考  
3. [ ] `fastboot boot boot-dagu.img` 验证 UEFI Shell（**不要 flash boot**）  
4. [ ] （可选）刷入 Magisk 获取 root，补采 `/proc/iomem` 与 live DTB

---

**最后更新：** 2026-08-26（Magisk root 全量 dump）
