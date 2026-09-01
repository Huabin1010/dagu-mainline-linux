# 启动链（原厂包）

| | elish OS1.0.2.0.TKYCNXM | dagu OS2.0.10.0.ULZCNXM |
|--|--|--|
| `boot.img` magic | `ANDROID!` | 同 |
| `header_version` | **3** | **3** |
| `header_size` | **1580** | **1580** |
| kernel_size | 54835216 | 54849552 |
| ramdisk_size | 19848135 | 18944605 |
| `vendor_boot` magic | **`VNDRBOOT`** | 同 |
| vendor_boot version | **3** | **3** |
| `dtb_size` | 1613832 | 1613904 |
| `dtb_addr` | `0x1f00000` | `0x1f00000` |
| dtbo magic | `0xd7b7ab1e` | 同 |
| `dt_entry_count` | **29** | **29** |
| vendor cmdline 开头 | `console=ttyMSM0,115200n8 androidboot.hardware=qcom …` | 同结构 |

按 v2 读 `boot.img`：`page_size=0`，字段对不上。
