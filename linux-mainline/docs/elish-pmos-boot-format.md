# elish pmOS：原厂 v3 机上的自造 boot 格式

对照：[elish 原厂线刷包](../../devices/elish-stock-OS1.0.2.0.TKYCNXM/)、[elish vs dagu](elish-pmos-vs-dagu.md)、[空 DTBO](dagu-dtbo-abl.md)、wiki 摘录 [note.md](note.md)。

**不是**「11" 出厂是 v2」。原厂 `elish_images_OS1.0.2.0.TKYCNXM` 已拆过：`boot` header **v3** + `VNDRBOOT` v3 + dtbo **29** 条，和 dagu HyperOS 同一套布局。

教程能刷进去并跳核，是因为 **Xiaomi ABL 仍保留 header &lt; 3 的旧解析分支**。pmOS / Armbian 喂的是一份 **自造旧格式镜像**，再把 B 槽 DTBO 擦掉，让 ABL 不要走 overlay。

口语里常说「刷 v2」。文件头其实是 **v0**（mkbootimg 默认，没写 `--header_version`）。这里说的「旧格式」= DTB 贴在 `boot.img` 的 kernel 载荷里、**不读 `vendor_boot`**。

**为什么选这套、ABL 哪条路径让它成功**（gzip→`DtbOffset`、header&lt;3 不读 vendor_boot、erase 与合法空表）：[elish-abl-legacy-boot-path.md](elish-abl-legacy-boot-path.md)。

## 1. 原厂 vs 自造

| | 原厂安卓（A 槽留下） | pmOS / Armbian（刷进 B 槽） |
|--|--|--|
| `boot.img` magic | `ANDROID!` | `ANDROID!` |
| `header_version` | **3**（`header_size=1580`） | **0**（不传 `--header_version`） |
| kernel 载荷 | raw `Image`（GKI） | `Image.gz` **再 concat 一份 DTB** |
| DTB 在哪 | **`vendor_boot`**（`dtb_size≈1.5MiB`） | **粘在 kernel 后面**（`append_dtb`） |
| ramdisk | GKI generic ramdisk | pmOS initramfs |
| `vendor_boot` | 必须有，ABL 读 cmdline + DTB | **不刷**；分区里仍是原厂，这条路径不用 |
| `dtbo` | 29 条 CAF overlay | **`fastboot erase dtbo_b`**（无 magic，不是空表） |
| 槽 | 双系统时 A = 安卓 | Linux 只用 **B**，`set_active b` |

## 2. 镜像怎么打（pmOS）

来源：`vendor/pmaports/device/testing/device-xiaomi-elish/deviceinfo`（gitignore，不入库），以及 postmarketOS `boot-deploy` 的 `create_bootimg()`。

`deviceinfo` 里和打包有关的字段：

```
deviceinfo_dtb_boe="qcom/sm8250-xiaomi-elish-boe"
deviceinfo_dtb_csot="qcom/sm8250-xiaomi-elish-csot"
deviceinfo_append_dtb="true"
deviceinfo_generate_bootimg="true"
deviceinfo_flash_offset_base="0x00000000"
deviceinfo_flash_offset_kernel="0x00008000"
deviceinfo_flash_offset_ramdisk="0x01000000"
deviceinfo_flash_offset_second="0x00f00000"
deviceinfo_flash_offset_tags="0x00000100"
deviceinfo_flash_pagesize="4096"
```

**没有** `deviceinfo_header_version`。`boot-deploy` 只有该字段等于 `"2"` 时才给 mkbootimg 加 `--header_version 2 --dtb …`。elish 走不到这条。

实际等价命令：

```bash
cat Image.gz sm8250-xiaomi-elish-boe.dtb > vmlinuz-dtb   # 或 csot
mkbootimg \
  --kernel vmlinuz-dtb \
  --ramdisk initramfs \
  --base 0x00000000 \
  --kernel_offset 0x00008000 \
  --ramdisk_offset 0x01000000 \
  --second_offset 0x00f00000 \
  --tags_offset 0x00000100 \
  --pagesize 4096 \
  --cmdline "quiet …" \
  -o boot.img
```

主线 DTB 里给 ABL 选树用的 id（pmOS 7.2 `sm8250-xiaomi-elish-common.dtsi`）：

```
qcom,msm-id = <QCOM_ID_SM8250 0x20001>; /* SM8250 v2.1 */
qcom,board-id = <0x2f 0>;
```

dagu 活机 / CAF 是 `board-id = <0x33 0>`，**不要**把 elish 这份 DTB 刷进 12.4"。

Armbian 的 `packages/bsp/xiaomi-elish/zz-update-abl-kernel` 是同一格式：`gzip -c vmlinuz > Image.gz`，再 `cat Image.gz dtb`，mkbootimg **同样不写** `--header_version`，然后 `dd` 进当前 `boot_*`。

## 3. 刷进去的几种方式（wiki）

Wiki：<https://wiki.postmarketos.org/wiki/Xiaomi_Mi_Pad_5_Pro_(xiaomi-elish)>。站点常被 Anubis 挡住，摘录在 [note.md](note.md)。

**启动链只有一套。** 所谓「多种方式」改的是 **rootfs 分区**，kernel 侧相同：

```
fastboot erase dtbo_b          # dtbo_a 留给安卓
pmbootstrap flasher flash_kernel --partition boot_b
fastboot set_active b
```

| 方式 | rootfs 刷到 | 备注 |
|------|-------------|------|
| 1 | `userdata` | 空间最大，安卓用户数据没了 |
| 2 | `super` | 不擦 userdata |
| 3 | `system_b`（先 `set_active a` 再 `reboot fastboot` 进 fastbootd） | 双系统 |
| 4 | 不刷 kernel 分区 | OrangeFox：把 recovery 改名为 `boot.img`，`fastboot boot`，镜像在 RAM 里 |

都不写 `vendor_boot`。wiki 也没提 `vbmeta`（11" 解锁后 ABL 较松；这台 dagu 自造 boot 必须 `vbmeta flags=3`）。

`fastboot boot` 和写 `boot_b` 走同一套 ABL `BootLinux()`，只是镜像来源是 USB RAM 还是分区。

## 4. ABL 为什么肯收

小米 HyperOS 的 `abl` 闭源。下面是 CAF `QcomModulePkg`（CodeLinaro / 公开 fork）里和真机行为对得上的分支，不是反编译本机 binary。

读头之后：

```c
if (HeaderVersion < BOOT_HEADER_VERSION_THREE) {
    /* kernel / ramdisk / page_size 全从这份 boot.img 读 */
    return;   /* 不打开 vendor_boot */
}
/* 只有 v3：GetImage(..., "vendor_boot")，magic 必须是 VNDRBOOT */
```

DTB：

```
header < 3
  → 不读 vendor_boot
  → kernel 载荷里找 FDT（Image.gz 后面那截 concat 的 DTB）
  → dtbo 无 magic（erase）→ 当 DTBO 无效，不 apply overlay
  → JumpToKernel（用这份主线 DTB）

header == 3（原厂）
  → 必须 vendor_boot
  → 从 vendor_boot 取 base DTB（按 msm-id / board-id 选）
  → dtbo 有表 → 选 overlay 再 libufdt apply
```

CAF 还有一条：base DTB 的 `msm-id` / `board-id` / `pmic-id` **全中** 时 `GetSocDtb()` 把 `DtboNeed = FALSE`（日志 `Exact DTB match found. DTBO search is not required`）。主线树很难和 CAF overlay 对得上，所以 wiki **仍然 erase**，不赌这条。

`erase` 之后分区内容一般是 `0xFF`，**没有** `0xD7B7AB1E`。三种「空」不要混，见 [dagu-dtbo-abl.md](dagu-dtbo-abl.md)：

| 分区里实际是什么 | elish ABL（社区常用） | 这台 dagu HyperOS ABL |
|--|--|--|
| `fastboot erase dtbo_b`（无 magic） | 跳过 overlay | **未单独测** |
| 合法表、`dt_entry_count=0` | （他们不用这个） | **已证** ~6s 回 fastboot |
| 24MiB 全 0（ginkgo 那种） | ginkgo 跳过 | 未当 dagu 默认方案 |

## 5. 和这台 dagu 的差别

11" 证明：**这代 Xiaomi ABL 家族可以走旧分支**。不是 11" 出厂格式不同。

这台 12.4 HyperOS 2 上已经打过的对照：从零 `mkbootimg` 的 v2/v3、`Image.gz`、活机 FDT 当 vendor_boot、四份 DTB concat，都会拒或秒回 fastboot。能稳定 jump 的是 magiskboot **拆原厂 v3 再塞** + stub DTBO。见 [dagu-fastboot-abl-ramdisk.md](dagu-fastboot-abl-ramdisk.md)。

| | elish pmOS | 这台 dagu（现行） |
|--|--|--|
| 喂给 ABL 的格式 | **v0 + Image.gz-dtb** | magiskboot 改原厂 **v3** |
| DTB | concat 在 kernel 后 | 放 **vendor_boot** |
| DTBO | **erase**（无 magic） | **stub** 29 条空 overlay；不要 `count=0` |
| vendor_boot | 不刷 | 必须刷，DTB 在这里 |
| 核载荷 | gzip / EFI ZBOOT | **raw Image** + 2MiB stub |
| `fastboot boot` | OrangeFox 能 RAM 启动 | 这台 **不收**，必须写入槽 |
| `vbmeta` | wiki 未提 | `flags=3` |

旧格式是三件套叠在一起：**header &lt; 3、DTB 粘在 kernel 后、擦掉 DTBO**。缺一件，ABL 就会掉回 v3 / overlay 那条严的路。

不要对 dagu 跑 `pmbootstrap install --device xiaomi-elish`，也不要把 elish 的 `boot.img` 刷进来。本仓库的对照脚本：

```bash
./scripts/build-bootimg-legacy.sh
./scripts/flash-boot-legacy.sh          # 只写 B 槽：erase dtbo_b + boot_b + vbmeta_b
# 救砖回 A：./scripts/flash-boot-legacy.sh restore-a
```

只动 B；A 留 HyperOS。这和 magiskboot v3 + stub 是另一条路径，见 [elish-abl-legacy-boot-path.md](elish-abl-legacy-boot-path.md)。

## 6. 证据分层

| 说法 | 证据 |
|------|------|
| 原厂 elish 是 v3 + vendor_boot + 29 条 dtbo | 线刷包文件头，[devices/elish-stock-OS1.0.2.0.TKYCNXM](../../devices/elish-stock-OS1.0.2.0.TKYCNXM/) |
| pmOS 打 v0 + `append_dtb`、不写 header_version | `deviceinfo` + `boot-deploy` `create_bootimg()` |
| Armbian 同一格式 | `zz-update-abl-kernel` |
| wiki 安装步骤（erase + `boot_b` + `set_active b`） | [note.md](note.md)，不是 ABL 源码 |
| header &lt; 3 不读 vendor_boot | CAF `UpdateBootParamsSizeAndCmdLine` / `CheckImageHeader` |
| 精确匹配则不搜 DTBO | CAF `GetSocDtb()` `DtboNeed = FALSE` |
| dagu 合法空表 6s 回 fastboot | **真机** |
| dagu 从零 mkbootimg 拒 | **真机** |
| dagu 上 `erase dtbo` 是否跳过 overlay | **未测** |
