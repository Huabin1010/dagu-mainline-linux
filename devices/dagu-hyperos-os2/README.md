# 第一台：Xiaomi Pad 5 Pro 12.4（dagu）

采集时系统：**HyperOS OS2.0.10.0.ULZCNXM**（Android 14），不是 MIUI 14。  
序列号 **`<android-serial>`**。BL 已解锁。Magisk 30.7。

| 文件 | 内容 |
|------|------|
| [01-identity.md](01-identity.md) | 型号、SoC、槽位、面板 |
| [02-boot-chain.md](02-boot-chain.md) | 为何是 boot **v3**、vendor_boot、DTBO |
| [03-dumps.md](03-dumps.md) | 原始 dump 在哪、拉了什么、没拉什么 |
| [04-uart.md](04-uart.md) | 串口软件侧 / 没有焊点图 |
| [05-bringup.md](05-bringup.md) | 主线 7.0 P0 卡在哪 |
| [06-compare-with-next.md](06-compare-with-next.md) | 第二台 MIUI 14 要对照的字段 |
| [extracted/](extracted/) | 从小文件抽出的头、cmdline、getprop |

长实验记录仍在 `linux-mainline/docs/`（不重复粘过来）：

- [dagu-dtbo-abl.md](../../linux-mainline/docs/dagu-dtbo-abl.md)
- [dagu-fastboot-abl-ramdisk.md](../../linux-mainline/docs/dagu-fastboot-abl-ramdisk.md)
- [abl-vs-lk.md](../../linux-mainline/docs/abl-vs-lk.md)
