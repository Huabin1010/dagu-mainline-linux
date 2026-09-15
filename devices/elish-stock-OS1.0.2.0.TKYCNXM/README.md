# elish 原厂线刷包（不是 pmOS）

来源：`~/下载/elish_images_OS1.0.2.0.TKYCNXM_20240507.0000.00_13.0_cn_f8476ce7cc (2).tgz`  
版本：**OS1.0.2.0.TKYCNXM**（Android 13 / HyperOS 1，2024-05-07）  
机型：Pad 5 Pro **11" Wi-Fi**（`elish`），不是 dagu。

2026-09-01 只从包里抽出 `boot.img` / `vendor_boot.img` / `dtbo.img` 看文件头（镜像在 `/tmp`，不入库）。解析：`extracted/boot-headers.json`。

## 结论

**原厂也是 boot header v3 + vendor_boot v3 + 29 条 dtbo**，和第一台 dagu HyperOS OS2 同一套。不是 v2。

pmOS 教程的 `append_dtb` / `erase dtbo_b` 是自造 boot（header **v0** + kernel 后 concat DTB），不能拿来推断 11" 出厂格式。记录：[elish-pmos-boot-format.md](../../linux-mainline/docs/elish-pmos-boot-format.md)。为何 ABL 收得下：[elish-abl-legacy-boot-path.md](../../linux-mainline/docs/elish-abl-legacy-boot-path.md)。
