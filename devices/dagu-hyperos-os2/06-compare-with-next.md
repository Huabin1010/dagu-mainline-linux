# 第二台（MIUI 14）对照表

第二台目录建好后，把右列填上。采集脚本可复用 `tools/_collect_hw_full.sh`（要 root）或至少 `fastboot getvar all` + 拆 `boot`/`vendor_boot`/`dtbo` 头。

| 检查项 | 第一台（本目录） | 第二台 MIUI 14 |
|--------|------------------|----------------|
| 代号 / 型号 | dagu / 22081281AC | |
| 序列号 | <android-serial> | |
| `ro.build.version.incremental` | OS2.0.10.0.ULZCNXM | |
| Android | 14 | |
| 内核 | 4.19.157-perf | |
| `boot.img` magic / header_version / header_size | ANDROID! / **3** / **1580** | |
| 是否有 `vendor_boot` | 有，VNDRBOOT v3 | |
| vendor_boot `dtb_size` | 1613904 | |
| dtbo magic / count | D7B7AB1E / **29** | |
| `androidboot.dtbo_idx` | 15 | |
| `qcom,board-id`（叠完） | 0x33 0 | |
| 面板 `msm_drm.dsi_display0` | l81a_42_04_0a dual_dphy | |
| cmdline `console=` | ttyMSM0,115200n8 | |
| `/dev/ttyMSM*` | **无** | |
| `/proc/tty/drivers` 有无 geni console | 无，只有 ttyHS | |
| 空 DTBO count=0 | 6s 回 fastboot | **不要先刷；先对比头** |
| 全 0 dtbo / erase dtbo | 未测 | 若 ABL 更老，可能和 ginkgo/elish 一样跳过 |

若第二台 **没有** `vendor_boot`、boot 头是 v2：启动协议不同，不能直接套现在的 magiskboot v3 脚本。  
若仍是 v3 + 29 条 dtbo：多半是同一套 HyperOS 系 ABL，只是系统版本不同，空表仍然危险。
