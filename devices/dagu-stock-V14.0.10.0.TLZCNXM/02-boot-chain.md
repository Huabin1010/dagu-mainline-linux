# 启动链：MIUI 14 原厂也是 v3

| | dagu **MIUI 14** V14.0.10.0.TLZCNXM | dagu HyperOS OS2 | elish OS1 |
|--|--|--|--|
| `boot.img` magic | `ANDROID!` | 同 | 同 |
| `header_version` | **3** | **3** | **3** |
| `header_size` | **1580** | 1580 | 1580 |
| kernel_size | 52748304 | 54849552 | 54835216 |
| ramdisk_size | 18531292 | 18944605 | 19848135 |
| `vendor_boot` | **`VNDRBOOT` v3** | 同 | 同 |
| `dtb_size` | 1613832 | 1613904 | 1613832 |
| `dtb_addr` | `0x1f00000` | 同 | 同 |
| dtbo magic / count | `D7B7AB1E` / **29** | 29 | 29 |
| vendor cmdline | `console=ttyMSM0,115200n8 androidboot.hardware=qcom …` | 同结构 | 同结构 |

按 v2 读 `boot.img`：`page_size=0`，对不上。

**结论：** MIUI 14 的 dagu 原厂已经是 GKI **v3 + vendor_boot**，不是 v2。第二台若还停在 MIUI 14，启动格式和现在这台 HyperOS 2 **同一套**；空 DTBO / from-scratch mkbootimg 仍可能被 ABL 拒（要真机再测 ABL 松紧，不能靠 header 版本猜）。
