# 从 Kernel-Build（ginkgo）带到 dagu 的约束

ginkgo 已经用 Linux 7.0 跑通。dagu 不重复那些实验，只搬结论。

## 启动就会死

1. **SoC GCC 必须 `=y`。** ginkgo 的 `CONFIG_SM_GCC_6125` 没进 defconfig，无时钟则秒回 fastboot。Linux 7.0 arm64 defconfig 同样**没有** `SM_GCC_8250`（只有 DISPCC/GPUCC）。dagu fragment 显式 `=y`。
2. **VA 位数要对 CPU。** ginkgo Kryo 260 被 defconfig 的 `VA_BITS_52` 打死。dagu 是 Kryo 585（A77/A55），没有 FEAT_LVA。Linux 7.0 默认仍是 52，fragment 钉成 **48**。
3. **`qcom,board-id` 必须等于活机。** ginkgo 主线曾写 0x16，真机是 0x22，ABL 不选 DTB。dagu 活机是 **0x33**。主线 elish-common 写的是 `0x10008`（不是 CAF 的 0x2f），已覆盖。
4. **不要把 CAF DTB/DTBO 叠到主线。** 原厂 DTBO 会改主线节点。优先 `fastboot boot` 带 **header v2 + 镜像内 DTB**。本机 HyperOS `boot.img` 是 **header v3**（DTB 在 vendor_boot）。用 v3 不带 DTB 会继续用 CAF DTB。
5. **UFS/USB PHY 不能是 module。** ramdisk 回退时还没有 `/lib/modules`。`SCSI_UFS_QCOM`、`PHY_QCOM_QMP*` 全部 `=y`。
6. **ramoops 地址要对以后才能从 Android recovery 捞 log。** elish 用 `0xb0000000` 4M，和本机 `ramoops_memreserve=4M` 同量级；P0 沿用 elish-common。
7. **`DRM` / `CFG80211` 依赖链必须 `=y`。** 只写 `DRM_MSM=y` 不够：`DRM_KMS_HELPER=m` 会把 MSM 卡成 module。Wi‑Fi 同理要 `CFG80211=y` `MAC80211=y`。

## 这台平板额外的

8. **没有可用 UART 焊点文档。** ginkgo 靠 1.8V TTL。dagu 第一路径是 **USB RNDIS + simplefb**，不是等串口。
9. **Ubuntu 刷 userdata，不要安卓。** 与 ginkgo 一样：`fastboot flash userdata out/rootfs.ext4`，init 挂 ext4 再 `switch_root`。不另建独立分区。未刷过时 ramdisk 回退。
10. **不要 `fastboot flash boot` / `boot_a` / `boot_b`。** dagu 是 A/B；`fastboot flash boot` 会写当前 slot。试内核只用 `fastboot boot`。userdata **没有** slot，刷 Ubuntu 只动这一块，启动链还在。空 DTBO 只刷 `dtbo_$slot`，另一边留着。
11. **不要抄 elish 的面板。** 同 SoC ≠ 同屏。elish NT36523 **CPHY** 3-lane，dagu L81A **dual-DPHY** 4-lane。时序按 dump 每路 800×2560、hbp/hfp=60、hpw=40，合成 1600 时 **不要把 porch 再乘二**（对齐 NT36523 写法）。
12. **Wi‑Fi BDF 不要乱包。** ginkgo 用 raw `board.bin` 而不是错误的 `board-2.bin`。dagu 板级文件是 dump 里的 `bd_l81a.elf` → `ath11k/QCA6390/hw2.0/board.bin`。厂 MAC persist `<wlan-mac>`。
13. **cmdline** 带 `clk_ignore_unused pd_ignore_unused`。不要带安卓的 `lpm_levels.sleep_disabled`。
14. **Himax 在主线没有驱动。** CAF hxchipset 是 4.19 的 19k 行，不能直接编进 7.0。overlay `himax-dagu.c`（SPI CPHA、IRQ39、RST100）。
15. **GPU zap 用本机路径** `qcom/sm8250/xiaomi/dagu/`，不要 elish。

## 调试环

ramdisk：minish（`dmesg`/`cat`/`ls`）+ dropbear。主机 `usb-connect.sh` → `192.168.7.2`，`ssh-run.sh` 用 `out/id_dagu`。
