# 身份

来源：`dumps/dagu-20260826-210700-root/identity/`（2026-08-26 Magisk root）。  
摘录：`extracted/misc.txt`、`extracted/getprop-selected.txt`、`extracted/uname.txt`。

| 字段 | 值 |
|------|-----|
| 产品名 | Xiaomi Pad 5 Pro 12.4 |
| 代号 | **dagu** |
| 型号 | **22081281AC** |
| SoC | SM8250（骁龙 870），平台 **kona** |
| 序列号 | **<android-serial>** |
| `androidboot.cpuid` | `<cpuid>` |
| `androidboot.hwversion` | 10.9.0 |
| `androidboot.hwc` | CN |
| `androidboot.hwlevel` | MP |
| `androidboot.baseband` | apq（Wi-Fi 平板，无蜂窝） |
| 系统 | Android **14** / **OS2.0.10.0.ULZCNXM**（HyperOS 2） |
| fingerprint | `Xiaomi/dagu/dagu:14/UKQ1.240624.001/OS2.0.10.0.ULZCNXM:user/release-keys` |
| 内核 | `4.19.157-perf-gb57830672689`（2025-07-01） |
| BL | **unlocked**，verified boot **orange** |
| dump 时 slot | `_a`（7 月 fastboot 日志里曾是 `current-slot:b`，以 8 月 getprop 为准） |
| 面板 cmdline | `msm_drm.dsi_display0=qcom,mdss_dsi_l81a_42_04_0a_dual_dphy_video`（L81A dual-DPHY） |
| 活机 FDT | `qcom,msm-id = <0x164 0x20001>`，叠完 DTBO 后 `qcom,board-id = <0x33 0>` |
| cmdline dt 下标 | `androidboot.dtb_idx=0` `androidboot.dtbo_idx=15` |

存储：UFS `1d84000.ufshc`，`super` 约 8.5 GiB，userdata 约 228 GiB。USB 控制器 `a600000.dwc3`。
