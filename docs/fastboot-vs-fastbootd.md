# Bootloader Fastboot 与 fastbootd 的区别

> 适用设备：小米平板 5 Pro 12.4（`dagu` / SM8250）及同类 Android 10+ 动态分区机型  
> 关联：[bootloader 解锁指南](bootloader-unlock-guide.md) · [dagu 主线刷写说明](../linux-mainline/docs/comman.md) · [ABL 与 ramdisk](../linux-mainline/docs/dagu-fastboot-abl-ramdisk.md) · [早期启动排查](early-boot-troubleshooting.md)

两者的本质区别在于**运行环境的层级**与**对动态分区（Dynamic Partitions）的读写能力**。

---

## 1. 两种 Fastboot 是什么

| | Bootloader Fastboot | fastbootd |
|---|---------------------|-----------|
| **`fastboot getvar is-userspace`** | `no` | `yes` |
| **运行环境** | ABL（Android Bootloader）固件 / UEFI，裸机引导层 | Linux 内核 + Recovery ramdisk 中的用户空间守护进程 |
| **Linux 内核** | **未加载** | **已加载并运行** |
| **USB 标识** | 通常 `18d1:d00d`（Google fastboot） | 同为 fastboot 协议，但主机侧 `is-userspace: yes` |
| **典型界面** | 橙色/兔子 **FASTBOOT** 字样（高通 ABL） | Recovery 菜单里的「Enter fastboot」或 `fastboot reboot fastboot` 后的 fastboot 模式 |

**Bootloader Fastboot** 只能识别和读写 UFS 上的**底层物理静态分区**。

**fastbootd** 拥有完整 Linux 驱动栈与 `device-mapper`，用于解析 `super` 内的**逻辑动态分区**（`system`、`vendor` 等）。

---

## 2. 核心特性对比

| 维度 | Bootloader Fastboot (`is-userspace: no`) | fastbootd (`is-userspace: yes`) |
|------|------------------------------------------|-----------------------------------|
| **运行环境** | ABL 固件 / UEFI | Linux 内核 + Recovery 用户空间 Daemon |
| **Linux 内核状态** | 未加载 | 已加载并运行 |
| **进入方式** | 关机后 **音量下 + 电源**；或 `adb reboot bootloader` | `fastboot reboot fastboot`；Recovery 菜单「Enter Fastboot」 |
| **可操作分区** | **物理分区**：`boot`、`boot_a/b`、`dtbo`、`init_boot`、`recovery`、`vbmeta`、`super`、`modem`、`abl`、`xbl` 等 | **逻辑分区**：`system`、`vendor`、`product`、`system_ext`、`odm` 等（在 `super` 内） |
| **动态分区支持** | ❌ 无法解析 `super` 内部逻辑卷 | ✅ 依赖 `liblp` / `dm-linear` 映射与调整逻辑分区大小 |
| **USB 驱动** | Bootloader 自带精简 USB 栈 | 标准 Linux Android USB Gadget（ConfigFS） |
| **掉电/刷写风险** | 相对较低（固件保护区较多） | 需注意逻辑分区元数据损坏 |

### 如何确认当前是哪一种

```bash
fastboot getvar is-userspace
# no  → Bootloader Fastboot（刷 boot、dtbo、vbmeta 用这个）
# yes → fastbootd（刷 system、vendor 等逻辑分区用这个）
```

在安卓 / TWRP 里：

```bash
# ✅ 进 ABL fastboot（刷物理分区）
adb reboot bootloader

# ❌ 不要用这个来刷 boot_b / dtbo_b（那是 fastbootd）
adb reboot fastboot
```

---

## 3. 在主线 Linux 适配中的意义（dagu）

高通骁龙 870（SM8250）出厂即 **动态分区 + A/B + boot header v3**。主线 bring-up 阶段主要动的是**物理分区**，必须在 **Bootloader Fastboot** 下操作。

### 3.1 刷写主线内核与引导链

调试主线时，常见目标是 `boot`、`dtbo`、`vbmeta`（均为**物理分区**）：

```bash
# 示例（分区名按 A/B 槽位带后缀）
fastboot flash boot_b boot.img
fastboot flash dtbo_b dtbo.img
fastboot flash vbmeta_b vbmeta.img

# 临时引导（不写闪存，若 ABL 支持）
fastboot boot boot.img
```

本仓库推荐脚本（**仅 Bootloader Fastboot**）：

| 脚本 | 作用 |
|------|------|
| `linux-mainline/scripts/flash-boot-legacy.sh` | elish 风格 header-0，**只写 B 槽**（`boot_b`、`dtbo_b`、`vbmeta_b`） |
| `linux-mainline/scripts/flash-boot.sh` | magiskboot v3 路径，双槽写 `boot` / `dtbo` / `vendor_boot` / `vbmeta` |
| `linux-mainline/scripts/fb-usb.py` | 同上，经 USB 协议封装（避免部分 host `fastboot` 版本问题） |

**不要**在 fastbootd 里执行 `fastboot flash boot_b`——通常无效或行为不符合预期。

### 3.2 根文件系统（Rootfs）放在哪

原厂 `system`、`vendor` 位于 `super` 物理分区内的**逻辑卷**。ABL 阶段**看不到**名为 `system` 的分区。

主线移植初期通常**避开动态分区**：

| 方式 | 说明 |
|------|------|
| **A（推荐）** | 将 minimal rootfs 打进 `initramfs.cpio.gz`，随 `boot.img` 的 ramdisk 载入内存；本仓库 `linux-mainline/initramfs/` 即此路径 |
| **B** | 外置存储（OTG U 盘 / SD）或空闲**物理分区**（如 `userdata`）格式化为 ext4，cmdline 指定 `root=/dev/block/...` |
| **C（后期）** | 在已启动的 Linux 用户空间内用 `liblp` 管理 `super` 内逻辑分区——需要完整 Android 栈或自行实现，**不是** ABL fastboot 阶段的工作 |

本仓库 P0 约定：userdata 可刷 ext4 rootfs（`flash-rootfs.sh`），**不修改** `boot_a` / `super` 启动链，救砖仍可从 A 槽或 EDL 恢复。见 [hardware-debug-workflow.md](hardware-debug-workflow.md)。

### 3.3 与 A/B、Recovery 的关系

- **`boot_a` / `boot_b`**：物理分区，Bootloader Fastboot 可刷；dagu 上 B 槽常用于试验主线，A 槽留 HyperOS / TWRP。
- **`recovery` / TWRP**：若已固化进 `boot_*`，从 fastboot `reboot recovery` 进的是 Recovery ramdisk 里的 Linux，**不是** Bootloader Fastboot。
- **刷完 B 槽自动回到兔子 fastboot**：多为 ABL 拒收镜像或内核早期失败，属于 **Bootloader Fastboot**（`is-userspace: no`），不是 fastbootd。

### 3.4 崩溃日志与 Recovery

- **pstore / ramoops**：需内核 `CONFIG_PSTORE_RAM` **且** DTS `reserved-memory` 或 cmdline `ramoops_memreserve`；日志在 **warm reboot** 后由**已启动 Linux 的 Recovery** 读取（`/sys/fs/pstore/`）。
- TWRP 跑在 Linux 上，可读 pstore；但 **Bootloader Fastboot 下没有** `/sys/fs/pstore`。
- 若 B 槽主线秒回 fastboot，往往来不及写 ramoops；优先用 USB RNDIS + initramfs `dmesg` 抓现场。见 DTS 中 `ramoops@b0000000` 与 [lessons-from-ginkgo.md](../linux-mainline/docs/lessons-from-ginkgo.md)。

---

## 4. 速查

```
需要刷 boot / dtbo / vbmeta / 线刷救砖
  → Bootloader Fastboot（is-userspace: no）
  → adb reboot bootloader 或 音量下+电源

需要刷 system / vendor / product（super 内逻辑分区）
  → fastbootd（is-userspace: yes）
  → Recovery 里进 fastboot，或 fastboot reboot fastboot

主线 dagu 日常调试
  → 只用 Bootloader Fastboot + 本仓库 flash-boot*.sh
  → 避免 adb reboot fastboot
```

---

*文档整理自 dagu 主线 bring-up 实践与社区通用说明，随工具链更新可增补 PR。*
