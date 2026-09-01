# ABL 是什么，以及为什么还有机器用 LK

对照：[ginkgo 启动约束](lessons-from-ginkgo.md)、[空 DTBO 与 ABL](dagu-dtbo-abl.md)、[elish vs dagu](elish-pmos-vs-dagu.md)。

ginkgo（Redmi Note 8）**也有 ABL**。感觉「ginkgo 不需要 ABL」是因为那代 ABL 松、还有 UART；不是启动链里没有这一层。

## 1. ABL 在启动链上干什么

**ABL** = Android Boot Loader。高通 UEFI 启动链里、专门负责 Android 的那一段。分区名一般是 `abl`。

上电顺序：

```
PBL（片上 ROM）
  → XBL（eXtensible Boot Loader，代替老的 SBL）
    → ABL（UEFI 应用）
      → Linux 内核
```

ABL 做的事：

- 音量下开机时提供 **fastboot**（USB `18d1:d00d`）
- 读 `boot` / `vendor_boot` / `dtbo` / `vbmeta`，按 `qcom,msm-id` / `qcom,board-id` 选 DTB，再 apply DTBO
- 在 MDSS 上画 **开机 Logo**，然后 `JumpToKernel`
- 离开时可能还留着 KPSS 看门狗

它 **不是** 内核，也不是 HyperOS 系统。Logo 冻住只说明 ABL 已经画过 splash；主线核暂时 modeset 不了这块屏，图就不会换。

dagu（小米平板 5 Pro 12.4 / SM8250 / HyperOS）走的就是这条链。

## 2. LK 是更早的一代

**LK** = Little Kernel。一个很小的嵌入式内核，高通早年拿它当 Android 的 `aboot`。分区里常见 `aboot` / `emmc_appsboot.mbn`。

老链：

```
PBL → SBL → LK（aboot）→ Linux
```

LK 自己实现 fastboot、读 `boot.img`、跳内核。代码来自 CAF，体积小，社区改起来相对容易。

大约从 **SDM845 / SM8150** 起，高通把这条换成 **XBL + UEFI ABL**，为的是 AVB、A/B、`vendor_boot` / `dtbo`、TrustZone / QHEE，以及 OEM 在 UEFI 里塞 Logo、充电动画、fastbootd。没有「某年全行业一起切」；几条线一直并存。

## 3. 为什么现在还有机器是 LK

1. **老高通 SoC 没换过**  
   MSM8916、MSM8953、SDM660 这类出厂就是 SBL+LK，后面也不给刷成 ABL。2016–2018 很多机子现在还是 LK。

2. **联发科一直是 LK**  
   MediaTek 的 Android 启动器是自己 fork 的 Little Kernel，不是高通 ABL。Helio / 不少 Dimensity 机子说的 LK 是这个。

3. **社区故意再用一次：`lk2nd`**  
   postmarketOS 在 **OEM 启动器之后** 再链一级 Little Kernel（例如 OnePlus 6：ABL 先起来，再加载 lk2nd，然后才是主线核）。选 LK 是因为它能自己编、能提供干净的 fastboot / 选 DT；ABL 源码基本不开放。

4. **叫法混用**  
   有人口语里把所有「进 fastboot 的那坨」都叫 LK。ginkgo（SM6125）文档里写的是 ABL，它已经是 XBL+ABL，不是 2015 年那种 `aboot`。

## 4. ginkgo 不是「没有 ABL」

Redmi Note 8 同样是高通 + Xiaomi ABL。`xiaomi-ginkgo-mainline` 里还用 UART 抓到过 ABL 报 DTBO overlay 失败。差别是 **那代 ABL 好说话，而且有串口**。

| | 典型 LK 机 | ginkgo（Note 8 / SM6125） | dagu（Pad 5 Pro 12.4 / SM8250 HyperOS） |
|--|--|--|--|
| 启动器 | `aboot`（Little Kernel） | 已是 **ABL**（较老、较松） | **HyperOS ABL**（严） |
| 试内核 | 很多能 `fastboot boot` | 能 `fastboot boot`，不写分区 | 这台 **不收** 只 `fastboot boot`，必须双槽刷进去 |
| boot 格式 | 多为 header v0/v1/v2，DTB 在 `boot.img` 里 | header **v2**，DTB 贴在镜像里 | 原厂 header **v3**，DTB 在 **vendor_boot**，再强制叠 **dtbo**。elish pmOS 另走自造 **v0 + append_dtb**，见 [elish-pmos-boot-format.md](elish-pmos-boot-format.md) |
| 空 DTBO | 常常直接跳过 | 刷 24 MiB 全 0，ABL **跳过** overlay | 刷合法空表（`count=0`）→ Load Error，约 6 秒回 fastboot |
| 调试 | 看机子 | 板子上有 **1.8V UART**，能看 ABL 和内核 printk | **没有**可用串口文档，只能靠 USB RNDIS |
| 开机图 | 核起来后通常能抢屏 | 主线面板通了，能看到 Linux | ABL 把 Logo 画在 MDSS 上就不管了；主线暂时 modeset 不了，**Logo 一直冻着** |
| 源码 | CAF LK 能编 | ABL 闭源 | ABL 闭源 |

所以：

- 不是 ginkgo 不经过 ABL，而是它允许「空 DTBO + 镜像内 DTB + RAM 启动」，失败了还能从串口读原因。
- dagu 这台 HyperOS ABL 更严：镜像格式、DTBO、看门狗、开机图都由它卡住。核已经在跑，屏上却还是那张 Logo。
- 两边槽都刷了主线时，看门狗复位往往 **warm reset 再进同一套核**，看起来像 Logo 永远不消失。只能长按电源约 10 秒，再按住音量下进 fastboot。救砖：`./scripts/flash-boot.sh restore`。

## 5. 和本仓库其它文档的分工

| 文档 | 写什么 |
|------|--------|
| 本文 | ABL / LK 是什么、为何并存、ginkgo 为何「看起来没有」 |
| [dagu-dtbo-abl.md](dagu-dtbo-abl.md) | 这台 ABL **如何选、如何叠 DTBO**；空表为何 6 秒回 fastboot |
| [dagu-fastboot-abl-ramdisk.md](dagu-fastboot-abl-ramdisk.md) | 刷写、镜像格式、P0 ramdisk 实验日志 |
| [lessons-from-ginkgo.md](lessons-from-ginkgo.md) | 从 ginkgo 搬过来的内核/打包约束（VA、GCC、不要 CAF overlay） |
