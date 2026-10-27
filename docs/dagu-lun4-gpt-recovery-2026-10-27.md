# dagu：逻辑单元 4 分区表损坏导致无法启动，以及修复过程（2026-10-27）

本文记录一次板子无法进入任何系统、只能停在 fastboot 的故障：现象、原因、修复步骤，以及修复带来的副作用。下一次遇到同样的现象，照本文的判断方法可以在几分钟内定位。

## 1. 现象

- 板子序列号 `ab22268c`，一直停在 fastboot（USB 标识 `18d1:d00d`），重启后仍回到 fastboot。
- `fastboot getvar` 显示两个槽的重试次数都是 7，没有任何一个槽被标为无法启动。
- 在 fastboot 里执行 `continue`，约 8 毫秒就返回 `Failed to load image from partition: Device Error`。8 毫秒内不可能读完一个 192 MiB 的镜像，说明失败发生在读镜像之前。
- 原厂签名的启动镜像、自己的 Linux 镜像、两个槽，表现完全一样。所以问题不在镜像内容。

## 2. 原因

引导程序（Android Boot Loader）的日志（`oem uefilog save` 后用 `oem uefilog UEFILOG0.TXT` 读出）里有这几行：

```text
Active Slot _a is bootable, retry count 6
ValidateSlotGuids: BootableSlot _a does not have valid guids
Boot GUID 77036CD4-03D5-42BB-8ED1-37E5A88BAA34
abl_a GUID 77036CD4-03D5-42BB-8ED1-37E5A88BAA34
Err: line:1666 FindBootableSlot() status: Device Error
```

高通的 A/B 启动方案里，每个分区在分区表（GUID Partition Table，GUID 分区表）里有一个 16 字节的“分区类型标识”：

- 当前启用的槽，`boot_x`、`abl_x` 等分区各自带有互不相同的真实类型标识。
- 未启用的槽，所有分区都带同一个占位值 `77036CD4-03D5-42BB-8ED1-37E5A88BAA34`。
- 引导程序的 `ValidateSlotGuids` 要求要启动的槽里 `boot` 和 `abl` 的类型标识互不相同。两个都是占位值就判为无效，直接返回设备错误。

本次出问题时，被选中启动的槽里 `boot` 和 `abl` 都是占位值，所以每次都在读镜像之前失败。

### 为什么会变成这样

- 为了让 Windows 的启动固件（UEFI）从 A 槽启动，用脚本直接改了逻辑单元 4（`/dev/sde`）分区表里 A、B 两个槽的属性位（优先级、活动、重试次数）。
- 属性位和类型标识是两套数据。引导程序自己的 `set_active` 在换槽时，除了改属性位，还会把 A、B 两边对应分区的类型标识对调，并在 1 号和 2 号启动逻辑单元之间切换。脚本只改了属性位，没有同步类型标识，两边就对不上了。
- 之后为了救板子，连续执行了三次 `set_active`。每执行一次，类型标识对调一次，最终状态是：当前活动槽的 `boot` 和 `abl` 都带占位值，真正互不相同的那一对留在了未活动的槽上。再执行 `set_active` 只会把它们换回来，并不能修复。
- 这是结合日志和引导程序源码（`PartitionTableUpdate.c` 中的 `SwitchPtnSlots`、`SwapPtnGuid`）推出的因果，没有在出问题之前的分区表上直接核对，因为当时没有备份逻辑单元 4。

### 为什么没有备份

出问题前只备份了逻辑单元 0（`/dev/sda`，放 `userdata` 的那块），放在 `backups/gpt-before-windows-20261026-0836/`。逻辑单元 4 放引导链（`abl`、`tz`、`hyp`、`modem`、`dsp`、`boot`、`vendor_boot` 等），没有备份分区表。逻辑单元 0 本身没有问题，`userdata` 上的 Ubuntu 没有受影响。

## 3. 修复

### 3.1 排除的办法

- `set_active a` / `set_active b`：只会对调类型标识，会把仅剩的那一对好值也换走。
- 在 fastboot 里改单个分区的类型标识：引导程序没有这个命令。
- 读回分区表再改 16 字节：引导程序不支持读回分区。
- 紧急下载模式：主机上没有对应工具，不作为方案。

### 3.2 采用的办法

引导程序支持 `flash partition:<逻辑单元号>`，把一个分区表镜像写进指定逻辑单元。官方固件包里正好有逻辑单元 4 的原厂分区表 `gpt_both4.bin`。

固件包：`OS2.0.10.0.ULZCNXM` 的 `dagu_images_*.tgz`，放在 `tools/downloads/dagu-android/`。

先在主机上核对 `gpt_both4.bin`：

- 文件头签名是 `EFI PART`，主、备两份表头的校验和都通过，分区项数组的校验和也通过，共 65 个分区。
- `boot_a`、`abl_a` 的类型标识互不相同，是原厂值；`boot_b`、`abl_b` 是占位值。符合“只有一个槽启用”的预期状态。

再读引导程序的 `WriteGpt`（解出的 `abl` 里能看到对应的错误字符串，源码见高通开源的 `abl_tianocore_edk2`）确认写入方式：

1. 先校验主、备表头。
2. 修正磁盘末尾位置相关的字段（备份表头位置、最后可用扇区）。
3. 擦除整个逻辑单元。
4. 写保护 MBR（Master Boot Record，主引导记录）、主表头、备表头、两份分区项数组。

**第 3 步会擦除逻辑单元 4 上所有分区的内容，包括 `abl`。** 这是这条路唯一的风险：写完分区表之后，在所有分区重刷完成之前，只要连接中断或某个镜像写失败，板子就进不了 fastboot，主机上没有办法救回来。引导程序的代码此时仍在内存里运行，所以只要不重启、不断线，可以继续刷。

### 3.3 要重刷什么

对照官方 `partition.xml` 和本地转储（`dumps/dagu-20260826-210700-root/images/`），逻辑单元 4 的 65 个分区分三类：

| 类别 | 分区 | 镜像来源 |
|---|---|---|
| 转储与官方包逐字节一致 | `aop`、`tz`、`hyp`、`abl`、`bluetooth`、`modem`、`dsp`、`keymaster`、`cmnlib`、`cmnlib64`、`qupfw`、`uefisecapp`、`featenabler`、`imagefv`、`dtbo`、`vbmeta`、`vendor_boot` | 官方包 |
| 转储里没有，官方包有 | `devcfg`、`multiimgoem`、`storsec`、`apdp`、`spunvm` | 官方包 |
| 两边都没有，擦除后为空白 | `bk41_a/b`、`bk42`~`bk44`、`dip`、`uefivarstore`、`secdata`、`vm-keystore`、`vm-data`、`mdtp*`、`multiimgqti_*`、`vm-linux_*`、`gsort`、`msadp`、`limits`、`limits-cdsp` | 无 |

`boot` 和 `vendor_boot` 用自己的 Linux 镜像（`linux-mainline/out/boot-dagu.img`、`vendor_boot-dagu.img`），`dtbo` 用占位的 `dtbo-stub.img`（空的 `dtbo` 会让引导程序约 6 秒后反复重启），`vbmeta` 用关闭校验的 `vbmeta-disabled.img`。

其中 `uefivarstore` 是 Windows 启动固件存放变量的分区，被擦成空白后需要由固件重新生成。

### 3.4 实际执行

镜像总共压缩后 176 MiB。公司网络（easytier）带宽有限，所以走对象存储中转：

1. 在构建机上打包为 `lun4-rescue.tar.zst`，计算 SHA-256。
2. 对象存储网关对单个请求体有大小限制，实测 50 MB 以内可以上传，所以切成 40 MB 一片上传到桶 `temp`。
3. 在接板子的电脑上下载、拼接，用同一份 SHA-256 核对通过。
4. 逐个对照新分区表，确认每个镜像都放得进对应分区，没有超出。
5. 在接板子的电脑上，用 `fb-usb.py`（不用 Google 的 `fastboot flash`）按下面顺序刷，全程不重启：
   1. `flash partition:4 gpt_both4.bin`
   2. 对 `a`、`b` 两个槽，依次刷 `abl`、`aop`、`tz`、`hyp`、`devcfg`、`bluetooth`、`cmnlib`、`cmnlib64`、`modem`、`dsp`、`keymaster`、`featenabler`、`qupfw`、`uefisecapp`、`multiimgoem`、`imagefv`、`dtbo`、`vbmeta`、`vendor_boot`、`boot`
   3. 补刷不分槽的 `storsec`、`apdp`、`spunvm`
6. 总共 44 次写入，全部返回 `OKAY`，没有 `FAIL`。

### 3.5 结果

- 刷完后 `fastboot getvar` 仍能响应，当前槽读到的状态正常。
- `continue` 不再 8 毫秒失败，返回 `OKAY`（用时 0.56 秒）。
- 板子离开 fastboot，约 6 秒后以 Linux 串口设备（USB 标识 `0525:a4a7`）重新出现，串口上出现 `localhost login:` 登录提示。
- 没有读回分区做逐字节校验，因为引导程序不支持。证据是启动日志不再报 `ValidateSlotGuids` 失败，板子真正进入了 Linux。

## 4. 修复的副作用

- A 槽的 `boot_a` 原来放 Windows 用的启动固件，现在被 Linux 镜像覆盖。继续 Windows 适配前，要重新构建并把固件刷回 `boot_a`。
- 上次的串口调试 shell 在旧的 B 槽 `vendor_boot` 里（参数 `systemd.debug_shell=/dev/ttyGS0`）。这次刷的是原版 `vendor_boot`，串口只有登录提示，没有免密 shell。需要时重新带上这个参数的镜像。
- 3.3 节第三类分区已被擦成空白，无法恢复。

## 5. 以后怎么避免

1. **改分区表属性位之前，先备份对应逻辑单元的整张分区表。** 逻辑单元 0 备份过，逻辑单元 4 没有，正是这次不能原样恢复的原因。可以用 `sgdisk --backup`，或者在 Linux 里 `dd` 前 6 个扇区加末尾 5 个扇区。
2. **换槽只用引导程序的 `set_active`，不要自己改属性位。** `set_active` 会同时处理属性位、类型标识和启动逻辑单元；单改其中一项必然对不上。
3. **板子停在 fastboot 且 `continue` 约 8 毫秒就失败时，先读引导日志里的 `ValidateSlotGuids` 和 `Boot GUID` 行**，再决定要不要动镜像。镜像内容通常不是原因。
4. **不要连续多次 `set_active`。** 每次都会对调类型标识，容易越换越乱。
5. **留一份官方分区表。** 官方固件包里的 `gpt_both0.bin` 到 `gpt_both5.bin` 是各个逻辑单元的原厂分区表，已验证 `gpt_both4.bin` 可直接用于恢复。需要时从 `tools/downloads/dagu-android/` 的固件包里取。
6. **写分区表命令会擦整个逻辑单元。** 只有在确认所有分区都有镜像可重刷时才执行；执行后不重启、不断线，一口气刷完。

## 6. 相关文件

- 官方固件包：`tools/downloads/dagu-android/dagu_images_OS2.0.10.0.ULZCNXM_20250701.0000.00_14.0_cn_8b79098f43.tgz`
- 逻辑单元 0 分区表备份：`backups/gpt-before-windows-20261026-0836/`
- 刷机脚本 `flash-lun4.sh` 和打包的镜像放在接板子的电脑上（`~/dagu-woa/lun4/`），没有入库；步骤见 3.4 节。
- 上一份状态文档：[woa-dagu-status-2026-10-26.md](woa-dagu-status-2026-10-26.md)
