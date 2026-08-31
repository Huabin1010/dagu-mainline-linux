# 真机对照目录

每台平板单独一个子目录，不把 1.9 GiB 的 `dumps/` 拷进来，只存 **身份、启动链解析、结论**。原始 dump 路径写在各机 `03-dumps.md`。

| 目录 | 哪一台 | 系统 | 状态 |
|------|--------|------|------|
| [`dagu-1-53dcc70-hyperos-os2/`](dagu-1-53dcc70-hyperos-os2/) | 第一台 Pad 5 Pro 12.4 | HyperOS **OS2.0.10.0.ULZCNXM**（Android 14） | 已整理 |
| （待建）`dagu-2-*-miui14/` | 第二台，MIUI 14 | 待采集 | 对照用 `dagu-1/.../06-compare-with-next.md` |

两台都应是 `dagu` / `22081281AC`。第二台重点看：**boot header 是不是也是 v3、ABL 对空 DTBO 是否一样严、cmdline / dtbo_idx、有没有 UART 驱动**。
