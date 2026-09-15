# 启动链：这台是 boot header v3

证据在 `extracted/boot-headers.json`（从 dump 的 `boot_a.img` / `vendor_boot_a.img` / `dtbo_a.img` 直接解析，不是猜的）。

## boot.img

| 字段 | 原厂 `boot_a.img` |
|------|-------------------|
| magic | `ANDROID!` |
| `header_version`（偏移 40） | **3** |
| `header_size` | **1580**（v3 标准；v2 是 1660） |
| kernel | ~52 MiB raw `Image`（不是 Image.gz） |
| ramdisk | ~18 MiB |
| DTB 字段 | **无**（v3 的 boot 不带 DTB） |

按 v2 去读同一段：`page_size` 会变成 0，地址字段是垃圾。所以不是「写错版本号的 v2」。

## vendor_boot.img

| 字段 | 原厂 `vendor_boot_a.img` |
|------|--------------------------|
| magic | **`VNDRBOOT`**（只有 v3/GKI 才有） |
| `header_version` | **3** |
| `page_size` | 4096 |
| `dtb_size` | 1613904（~1.5 MiB，**DTB 在这里**） |
| vendor ramdisk | 2314 字节 |
| cmdline | `console=ttyMSM0,115200n8` … `androidboot.usbcontroller=a600000.dwc3` |

ABL 从这里选 base DTB（`dtb_idx=0`），再去叠 dtbo。

## dtbo

| 字段 | 原厂 `dtbo_a.img` |
|------|-------------------|
| magic | `0xD7B7AB1E` |
| `dt_entry_count` | **29** |
| 活机选用 | **idx=15**（`board-id 0x33 0`，约 494 KiB CAF 树） |
| 分区大小 | 32 MiB（`0x2000000`） |

这台 HyperOS ABL：**认出合法表之后必须选出并能 apply 一条 overlay**。  
`dtbo-empty.img`（magic 对、`count=0`）→ ~6s 回 fastboot。  
elish 教程是 **erase**（无 magic）；ginkgo 是 **24 MiB 全 0**。都不是我们这种空表。详见 [dagu-dtbo-abl.md](../../linux-mainline/docs/dagu-dtbo-abl.md)。

现行主线刷写用 **`dtbo-stub.img`**（29 条无操作 overlay，board-id 对齐）。

## 和「当成 v2 刷」

从零 `mkbootimg` 打的 v2/v3，这台 ABL 都拒。能跳核的是 magiskboot **拆原厂 v3 再塞** Image / ramdisk / 主线 DTB。不要假设可以改打包成 v2。
