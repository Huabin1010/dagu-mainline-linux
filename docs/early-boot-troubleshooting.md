# dagu 早期启动排查（~6 秒回 fastboot vs 黑屏常驻）

> 对照「ABL 校验 / Earlycon / 冷启动」三维度，结合本仓库真机时序实验。  
> 关联：[fastboot-vs-fastbootd](fastboot-vs-fastbootd.md) · [dagu ABL 与 ramdisk](../linux-mainline/docs/dagu-fastboot-abl-ramdisk.md) · [UART](dagu-uart-debug-guide.md)

---

## 1. 先分清是哪一种失败

USB 掉线后的**时间**是最便宜的判据（见 `linux-mainline/docs/dagu-fastboot-abl-ramdisk.md` §2）：

| 现象 | 含义 | ramoops 有用吗 |
|------|------|----------------|
| **~3–6 秒** 回到 `18d1:d00d` fastboot | ABL **没跳进内核**，或入口立刻 SError | ❌ 内核未初始化 pstore |
| **~20–25 秒** 回 fastboot | 看门狗 bark，或 ramdisk 戳坏 4.19 gadget | 偶尔 |
| **≥40 秒** USB 仍黑、**不回** fastboot | ABL **已 jump**，核在跑或死循环，WDT 被踢 | ❌ 无 panic 则不写；需 RNDIS / 串口 |
| Logo 冻住 + 长按电源才能回 fastboot | 同上，核已 jump | 同上 |

**2026-09-09 真机实验（B 槽 `boot-dagu-legacy.img`）：** `fastboot set_active b` → `reboot` 后 **90 秒内未再出现 `18d1:d00d`**，主机无 RNDIS。  
→ **排除「ABL 6 秒拒收」**；属于 **已跳内核、USB gadget 未起来或 PID1 未连通主机** 这一类。

---

## 2. 维度一：ABL 校验 / boot 镜像结构

### 2.1 何时怀疑 ABL

- 刷写后 **~6 秒** 必回兔子 fastboot（`is-userspace: no`）。
- `fastboot boot boot.img` 报 `Failed to load/authenticate boot image`（与 slot / vendor_boot 状态有关）。

### 2.2 本仓库 B 槽 legacy 路径（已用）

| 项 | 状态 |
|----|------|
| `boot_b` | header **v0**，kernel = `gzip(Image) \|\| DTB` |
| `dtbo_b` | **erase**（无 magic，走 appended DTB 分支） |
| `vbmeta_b` | `vbmeta-disabled.img`（flags=3，关闭 verify + hashtree） |
| BL 解锁 | `unlocked: yes` |

**镜像自检（`out/boot-dagu-legacy.img`）：**

- `ANDROID!` / `header_version=0` / kernel 以 `\x1f\x8b` 开头
- DTB 尾附：`model = Xiaomi Pad 5 Pro 12.4`，`qcom,board-id = 0x33`
- `ramoops@b0000000` 已在 DTB `reserved-memory` 内

若仍 **6 秒回 fastboot**，再查：

1. `dtbo_b` 是否误刷 `dtbo-empty.img`（count=0 合法表 → 这台 ABL 会拒跳）
2. `vbmeta_b` 是否仍为原厂（未 disable verification）
3. 是否用了 header v3 + 缺 `vendor_boot` 的「从零 mkbootimg」包

**不需要**对 header-0 legacy 镜像再跑 `avbtool` 签 boot——验证由 **vbmeta 链** 控制；已刷 `vbmeta-disabled` 且解锁即可。

---

## 3. 维度二：Earlycon（最早期的串口日志）

### 3.1 内核侧

`dagu.fragment` 已开：

- `CONFIG_SERIAL_QCOM_GENI_CONSOLE=y`
- `CONFIG_SERIAL_EARLYCON=y`

### 3.2 仍缺什么

- **cmdline 未带 `earlycon=`**（`build-bootimg-legacy.sh` 当前只有 `console=tty0`）。
- **无公开 UART 焊点**；软件上 uart12 `@a90000` GPIO 34/35，1.8V TTL（见 `devices/.../04-uart.md`）。

有飞线条件时可在 cmdline 追加（示例，需与 DT `stdout-path` 一致）：

```
earlycon=msm_geni_serial,0x0a90000 console=ttyMSM0,115200n8
```

无串口时，**Earlycon 无法替代 RNDIS**；P0 仍靠 USB gadget + initramfs `dbg_post_host()`。

---

## 4. 维度三：冷启动 / 掉电

- 完整断电再开机会清部分 RAM；**pstore 在冷启动后常为空**。
- 要事后在 TWRP 读 `/sys/fs/pstore/`，需 **panic 后 warm reboot**（`reboot=panic_warm`），且地址与 TWRP 一致（`0xb0000000` 4MB）。
- **当前瓶颈不是冷启动**：核已 jump 且未 panic 回 fastboot，TWRP 里 pstore 为空是预期。

---

## 5. 为何 TWRP 里看不到 7.0 日志

| 路径 | 内容 |
|------|------|
| `/sys/fs/pstore/*` | **空** — 7.0 未 panic 写盘，或回 TWRP 前 RAM 已清 |
| `/cache/recovery/last_kmsg` | **TWRP 4.19 核**自己的启动 log，不是 Linux 7.0 |

ramoops DTS 已加对 **7.0 侧**；要读到内容需：**先让 7.0 panic**，再 warm reboot 进 TWRP，或 **在线** 用 RNDIS/SSH 看 `dmesg`。

---

## 6. 当前结论与下一步

**结论（2026-09-09）：**

1. **不是**截图里的「6 秒 ABL 拒收 / AVB 卡 boot」主因。
2. **是**「ABL 已接受 legacy boot → 内核早期跑起来 → USB/RNDIS 未 up → 黑屏常驻」——与 `dagu-fastboot-abl-ramdisk.md` P0 阻塞一致。
3. pstore/ramoops **已配置**，但对**无 panic 的黑屏**帮助有限；TWRP 捞不到是正常现象。

**建议下一步（按优先级）：**

1. 黑屏时 **长按电源 ~10s** 回 fastboot，保持 **A 槽 TWRP / HyperOS** 作救砖锚点。
2. 主机侧盯 **RNDIS**（`./linux-mainline/scripts/usb-connect.sh`）与 initramfs 调试口。
3. 有硬件则 **UART + earlycon cmdline**（见 §3）。
4. 勿把「能进 fastboot」和「6 秒回 fastboot」混为一谈：后者才是 ABL 拒跳；手动长按进 fastboot 可能是从 jump 后的挂死状态恢复。

---

*随 B 槽对照实验更新。*
