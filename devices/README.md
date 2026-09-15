# 真机对照目录

每台平板单独一个子目录，不把 1.9 GiB 的 `dumps/` 拷进来，只存 **身份、启动链解析、结论**。原始 dump 路径写在各机 `03-dumps.md`。

| 目录 | 哪一台 | 系统 | 状态 |
|------|--------|------|------|
| [`dagu-hyperos-os2/`](dagu-hyperos-os2/) | 第一台 Pad 5 Pro 12.4 | HyperOS **OS2.0.10.0.ULZCNXM**（Android 14） | 已整理 |
| [`dagu-stock-V14.0.10.0.TLZCNXM/`](dagu-stock-V14.0.10.0.TLZCNXM/) | dagu **MIUI 14 原厂线刷包**（Chrome 下载，不是第二台真机） | **V14.0.10.0.TLZCNXM**（Android 13） | boot **v3**，与 OS2 同布局 |
| [`elish-stock-OS1.0.2.0.TKYCNXM/`](elish-stock-OS1.0.2.0.TKYCNXM/) | 11" elish **原厂线刷包**（不是真机 dump） | HyperOS 1 **OS1.0.2.0.TKYCNXM**（Android 13） | boot **v3**，与 dagu 同布局 |
| （待建）`dagu-2-*-miui14/` | 第二台 dagu，MIUI 14 | 待采集 | 对照用 [`dagu-hyperos-os2/06-compare-with-next.md`](dagu-hyperos-os2/06-compare-with-next.md) |

dagu 两台都应是 `22081281AC`。第二台重点看：**boot header 是不是也是 v3、ABL 对空 DTBO 是否一样严、cmdline / dtbo_idx、有没有 UART 驱动**。

elish 原厂包已证明 **11" 出厂也是 v3 + vendor_boot + 29 条 dtbo**；pmOS 的 `append_dtb` 是自造 **header v0** 镜像，不是原厂 v2。格式：[linux-mainline/docs/elish-pmos-boot-format.md](../linux-mainline/docs/elish-pmos-boot-format.md)。ABL 路径：[linux-mainline/docs/elish-abl-legacy-boot-path.md](../linux-mainline/docs/elish-abl-legacy-boot-path.md)。
