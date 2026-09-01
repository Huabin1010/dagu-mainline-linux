# dagu：空 DTBO 为什么会弹回 fastboot

对照 [elish pmOS wiki 摘录](note.md) 里的 `fastboot erase dtbo_b`，以及本机 HyperOS ABL 上已经打过的实验。他们自造的 boot 格式（v0 + `append_dtb`，不是原厂 v2）：[elish-pmos-boot-format.md](elish-pmos-boot-format.md)。ABL / LK 背景见 [abl-vs-lk.md](abl-vs-lk.md)。

## 1. 先把两件不同的事分开

wiki 写的是：

```
Before installing rootfs, please erase dtbo_b (dtbo_a reserved for android)
$ fastboot erase dtbo_b
```

那是 **Pad 5 Pro 11"（elish）** 的 pmOS 安装步骤：Linux 放在 **B 槽**，A 槽留给安卓，所以只擦 **B 槽的 DTBO**。目的是让 ABL **不要**再把 CAF overlay 叠到主线 DTB 上。

我们刷的「空 DTBO」是另一回事：

```
out/dtbo-empty.img
magic = 0xD7B7AB1E   # 合法 dt_table 头
dt_entry_count = 0   # 表里一条 overlay 都没有
整文件 4KiB（头 32 字节，后面全 0）
```

**擦分区**和 **刷一份 count=0 的合法表**，在 ABL 眼里不是同一种状态。elish wiki 的做法不能原样搬到 dagu 的 `dtbo-empty.img` 上。

## 2. Android / ABL 启动时 DTBO 干什么

Android 9 起，高通机子的设备树是两截：

| 从哪来 | 是什么 |
|--------|--------|
| `vendor_boot` 里的 DTB（boot header v3） | SoC + 板级 **base DT** |
| `dtbo` 分区 | 若干 **overlay**（DTO），按机型再补一层 |

ABL 大致顺序：

1. 从 `vendor_boot` 取出 base DTB（按 `qcom,msm-id` / `qcom,board-id` 选 blob）。
2. 读 `dtbo` 分区头 `dt_table_header`（magic `0xD7B7AB1E`）。
3. 按板级 id 或 `androidboot.dtbo_idx` **选出至少一条** overlay。
4. 用 libufdt 把 overlay **apply** 到 base DT（需要 base 带 `__symbols__`，overlay 带 `__fixups__`）。
5. 把结果交给内核，并在 cmdline 写上 `androidboot.dtbo_idx=…`。

AOSP 还要求：VTS 检查 `androidboot.dtbo_idx` **至少指出一个有效下标**。量产 ABL 往往把「选不到 overlay / apply 失败」直接当成 **Load Error**，不跳内核，回到 fastboot。

dagu 活机 dump：

- 原厂 `dtbo_a.img`：magic 正确，**29** 条 overlay，page=4096。
- 第 **15** 条：`model = "xiaomi dagu"`，`qcom,board-id = <0x33 0>`，约 494 KiB CAF pinctrl/PMIC fragment。
- 叠完之后 cmdline 有 `androidboot.dtbo_idx=15`、`androidboot.dtb_idx=0`，根上 `qcom,board-id` 变成 `0x33`。

这台 ABL **默认就会去 apply idx=15**。不是可选项。

## 3. 弹回 fastboot 的机制（为什么是 ~6 秒）

USB 在 reboot 后约 **3–6 秒** 重新出现 `18d1:d00d`，表示 **内核根本没跳进去**（或入口立刻炸）。和「核卡住、USB 全黑、只能长按」不是一类。

对空 DTBO，路径是：

```
ABL 读到 magic 0xD7B7AB1E
        ↓
dt_entry_count == 0
        ↓
选不出 overlay（idx=15 越界 / 表空）
        ↓
Load Error（不 JumpToKernel）
        ↓
ABL 自己回到 fastboot 协议栈
        ↓
主机 ~6 秒再看到 18d1:d00d
```

2026-08-30 对照（**原厂 trim boot + 原厂 trim vendor_boot**，只换 DTBO）：

| DTBO | 结果 |
|------|------|
| `dtbo-empty.img`（count=0） | **6 秒回 fastboot** |
| dump 的原厂 `dtbo_a.img`（29 条） | HyperOS 起来 |

所以不是 7.0 Image 的问题：原厂核也会被空表挡在门外。Konrad / SoMC 那种「只写一个 0 overlay 头」在 **这台 Xiaomi ABL 上不够**。

apply 失败（主线 DTB 没 `-@`、overlay 的 `__fixups__` 对不上）是另一条路，大约 **3 秒** 回 fastboot，同样是 ABL 没跳核。

## 4. 三种「空」不要混

| 操作 | 分区里实际是什么 | 这台 ABL 会怎样 |
|------|------------------|-----------------|
| `fastboot erase dtbo_b`（elish wiki） | 擦掉，通常 **没有** `0xD7B7AB1E` | 多数高通 ABL **跳过** overlay（pmOS 社区常用）。**dagu 上还没单独对照过 erase** |
| 刷 `dtbo-empty.img` | **有**合法 magic，`count=0` | **已证明**：当「表在、条目为零」→ 选 overlay 失败 → ~6s 回 fastboot |
| 刷 2 字节 / 截断垃圾 | 头都不是表 | 解析失败，同样不跳核 |
| 刷原厂 DTBO 到主线 DTB | 29 条真 overlay，#15 是整份 CAF 树 | ABL **会跳**，但 overlay 会改主线节点，核很容易挂 |
| 刷 `dtbo-stub.img` | 29 条 **无操作** overlay，board-id 从原厂逐条抄，#15 仍是 `0x33 0` | ABL 能选、能 apply；主线 DTB 必须 `-@` |

elish 可以 erase B 槽，还因为他们：

- Linux 只用 **B 槽**，A 槽 DTBO 留给安卓；
- boot 镜像是 **mkbootimg + `append_dtb`**，不走我们这种「vendor_boot 里一份主线 DTB + ABL 再叠 DTBO」的 HyperOS v3 路径。

dagu 这台 HyperOS ABL：**只要认出 DTBO 是一张表，就要求表里能选出可 apply 的 overlay。**

## 5. stub 在补什么

`scripts/build-chain-extras.py` 生成的 `dtbo-stub.img`：

- 条目数、每条的 `qcom,board-id` 与原厂一致（保证 idx=15 仍匹配 dagu）。
- overlay 本体只是 `/plugin/; &soc { dagu,dtbo-stub; }`，不搬 CAF pinctrl。
- 主线 `sm8250-xiaomi-dagu.dtb` 用 `DTC_FLAGS_... := -@` 带 `__symbols__`，否则 apply 会 Load Error（~3s）。

默认 `flash-boot.sh` 刷 stub，不要刷 empty。对照实验才用 `./scripts/make-empty-dtbo.sh flash`。恢复原厂：`./scripts/make-empty-dtbo.sh restore`。

## 6. 和「内核卡住」怎么区分

| 主机 USB | 含义 |
|----------|------|
| ~3–6s `18d1:d00d` 回来 | ABL 没跳：空 DTBO、apply 失败、DTB 选错、Load Error |
| 掉线 ≥40s，不回 fastboot | 已经 Jump；卡在内核 / PID1。**不是**空 DTBO 这条路径 |

空 DTBO 只会制造第一种。它不能修好 RNDIS，也不能当「没刷 rootfs」的替代品。

## 7. 若还想试 wiki 那种 erase

那是 **擦除**（分区内容变成 0xFF，没有 `D7B7AB1E`），不是刷 `dtbo-empty.img`。elish 上 ABL 往往因此 **跳过 overlay**；dagu 上这条路径还没单独测过。

`scripts/fb-usb.py` 目前只有 `flash` / `reboot` / `set-active`，**没有 erase**。不要用 Google platform-tools 37。只动当前 Linux 那个 slot，另一边留着救砖。

成功判据：reboot 后 **不是** 6 秒回 `18d1:d00d`。失败立刻刷回 dump：

```bash
python3 scripts/fb-usb.py flash dtbo_a ../dumps/dagu-20260826-210700-root/images/dtbo_a.img
python3 scripts/fb-usb.py flash dtbo_b ../dumps/dagu-20260826-210700-root/images/dtbo_b.img
```

在 erase 被这台 ABL 验证之前，P0 仍用 **stub DTBO**。

## 8. 这些结论是不是从源码推出来的

**小米 HyperOS 的 `abl` 闭源，仓库里没有、我们也没有反编译它。** 分层如下。

| 说法 | 证据 |
|------|------|
| dagu 刷 `count=0` 合法空表会 ~6s 回 fastboot | **真机**：原厂 trim boot + 原厂 vendor_boot，只换 DTBO |
| stub 29 条能让 ABL jump | **真机** |
| elish 用 `fastboot erase dtbo_b` + `append_dtb` | **pmOS wiki + pmaports `deviceinfo`**，不是读 11" 的 ABL 源码 |
| erase 后 ABL「跳过 overlay」 | CAF 上 *有可能* 走「magic 不对就不当 DTBO」；**dagu 上 erase 还没测** |
| 表格式、选条目、apply overlay | **AOSP + CAF ABL 公开代码**（小米 fork 的祖先，不是本机 binary） |

公开源码能对上「空表为什么挂」的是 CAF ABL `GetBoardDtb()`（CodeLinaro `QcomModulePkg/Library/BootLib/LocateDeviceTree.c`）：

```c
DtboTableEntriesCount = fdt32_to_cpu (DtboTableHdr->DtEntryCount);
for (DtboCount = 0; DtboCount < DtboTableEntriesCount; DtboCount++) {
    /* 用 qcom,board-id 等做 VARIANT_MATCH */
    ...
}
if (!BestDtbInfo.Dtb) {
    DEBUG ((EFI_D_ERROR, "Unable to find the Board Dtb\n"));
    return NULL;   /* 调用方当 Load Error，不 JumpToKernel */
}
```

`count=0` 时循环一次都不进，直接 `NULL`。这和 dagu 上「合法空表 → 6 秒回 fastboot」一致。  
头里的 magic 是 AOSP/CAF 的 `DTBO_TABLE_MAGIC 0xD7B7AB1E`（`LocateDeviceTree.h`）。`GetBoardDtb()` 本身**不先校验 magic**，只按 `DtEntryCount` 扫；调用方若先 `LoadImage` 再当表解析，擦成 0xFF 和刷一张 count=0 的合法头就不是同一条路径。

CAF 里还有另一条「可以不找 DTBO」：base DTB 已经 SoC **精确匹配** 时把 `DtboNeed = FALSE`（`GetSocDtb()` 里 `Exact DTB match found. DTBO search is not required`）。那是「内核镜像里的 DTB 已经够了」，对应 elish 的 `append_dtb`，不是对应 `dtbo-empty.img`。

AOSP 文档也写：`dtbo` 分区用 `dt_table_header`；哪怕只有一份 overlay，`dt_entry_count` 也是 **1**，没有把 `0` 定义成「请跳过」。VTS 还检查 cmdline 里的 `androidboot.dtbo_idx` 要能指到有效下标。

**stub 不是 CAF 里的现成功能**，是我们按「表必须能选出 idx=15」在 `scripts/build-chain-extras.py` 里造的 29 条空 overlay。
