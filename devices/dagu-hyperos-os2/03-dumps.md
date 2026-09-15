# 原始 dump（不复制进本目录）

`dumps/` 已 gitignore。本目录只放解析结果。

## 目录

| 路径 | 何时 | 条件 | 用途 |
|------|------|------|------|
| `dumps/dagu-20260719-092500/` 等 | 2026-07-19 | 解锁前 / 无 root | getprop、分区名；`iomem` 几乎空 |
| `dumps/dagu-20260719-094103/` | 同日 | fastboot | `fastboot-getvar-all.txt` |
| **`dumps/dagu-20260826-210700-root/`** | 2026-08-26 | Magisk 30.7 | **主资料** ~1.9 GiB |
| `dumps/dagu-20260826-linux-bringup/` | 同日 | 从 FDT/vendor 再切 | 写主线 DTS、ath11k blob |

全量 dump 清单：`dumps/dagu-20260826-210700-root/README.md`。

## 全量里有的

- 活机 FDT：`dt/fdt.dtb` + `dt/fdt.dts`（已叠 DTBO#15）
- `/proc/iomem`、dmesg、`config.gz`、cmdline
- 启动链镜像：`boot_*` `vendor_boot_*` `dtbo_*` `vbmeta_*` `xbl` `abl` `tz` …
- 外设 sysfs：显示 / 触控 / USB / GPU / UFS / Wi-Fi / 音频 / 充电

## 没拉 / 空的

- `super`、完整 `userdata`（体积；P0 也不挂）
- `modem_b` 不完整
- debugfs gpio/pinctrl/clk（量产核没开）
- `/dev/ttyMSM0`（量产核没有 console UART 驱动）

## 固件切片

`dumps/dagu-20260826-linux-bringup/wireless/blobs/`：QCA6390、BT、persist MAC。
