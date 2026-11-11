# dagu Windows：开机卡在 bootmgfw 之后——SYSTEM.LOG2 的 NTFS 记录让 winload 无限递归（2026-11-11）

## 1. 现象

2026-11-10 23:30 起，A 槽 Windows 连续两次卡在 UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）日志的最后几行，不复位：

```text
[Bds]Booting MsTemp
Loading driver at 0x001FC49E000 EntryPoint=0x001FC4D0370 bootmgfw.efi
PROGRESS CODE: V03058001
ConvertPages: failed to find range 102000 - 102FFF
```

正常开机这之后还会有 `V03101019`（`ExitBootServices`）。这次没有，`ntbtlog.txt`、`bootstat.dat` 都停在 17:52 那一次成功启动。

## 2. 怎么定位的

平板上的 Linux 里用 QEMU（Quick Emulator，开源虚拟机）把同一块 UFS（Universal Flash Storage，通用闪存存储）LUN0 当成 NVMe 盘启动，挂一个丢弃式的 qcow2 覆盖层，所以虚拟机的写入不会落到真盘上。走的是同一份 ESP（EFI System Partition，EFI 系统分区）、同一份 `bootmgfw.efi` 和 `winload.efi`。

1. 虚拟机里同样不动，屏幕黑。CPU 停在 `PC=0x4093CA00`，指令是 `b .`。
2. 在客户机内存里找 PE 头，这个地址属于镜像基址 `0x4093B000`、大小 `0x30E000` 的模块，和 `\Windows\System32\winload.efi` 完全对得上。偏移 `0x1A00` 用微软符号服务器的 `winload_prod.pdb` 解出来是 `BlKernelExceptionHandler`：winload 自己的异常向量，进去就原地死循环。
3. QEMU gdbstub 读异常寄存器：`ESR_EL1 = 0x96000047`（EL1 数据中止、写、第 3 级转换错误），`FAR_EL1 = 0x40080FB0`，而当时 `SP = 0x40081100`。写的是栈下方的保护页，即**栈溢出**。
4. 沿帧指针链回溯 599 层，其中 585 层的返回地址都是 `NtfspLookupAttributeVcnEx+0x410`，往外是：

```text
NtfspLookupAttributeVcnEx   ← 自己调自己 585 次
NtfspLookupAttribute
NtfspInitializeFileEntry
NtfsOpen
FileIoOpen / BlFileOpen
ImgpOpenFile
BlImgLoadImageWithProgress2
OslLoadAndInitializeHive     ← 打开 SYSTEM 配置单元及其日志
OslpLoadSystemHive
OslPrepareTarget
OslMain
```

winload 在打开 SYSTEM 配置单元的文件时，在 NTFS 属性查找里无限递归。

## 3. 根因：SYSTEM.LOG2 的 MFT 记录

解析 `\Windows\System32\config` 下每个文件的 MFT（Master File Table，主文件表）记录，再扫全盘 87296 条记录，只有一条有问题，是 `SYSTEM.LOG2`（记录 79594）：

| 项 | 值 |
|---|---|
| 属性 | `$STANDARD_INFORMATION`、**`$ATTRIBUTE_LIST`**、两个 `$FILE_NAME`、`$DATA`、`$DSC` |
| `$DATA` | 非驻留，`lowest VCN = 0`、`highest VCN = -1`，没有运行表（长度 0） |
| `$ATTRIBUTE_LIST` | `$DATA` 的那一项指回自己这条记录、起始 VCN 0 |

文件长度是 0，但它带着一份属性列表，属性列表又说"VCN 0 的数据在这条记录里"，而这条记录里的 `$DATA` 覆盖范围是空的（highest < lowest）。winload 的 NTFS 驱动找 VCN 0 时，按属性列表跳回同一条记录，找不到，再查属性列表，又跳回来——直到栈溢出。Linux 的 `ntfs-3g` 不按这条路径找，所以 Linux 下文件一切正常（读出来是 0 字节）。

这份 `$ATTRIBUTE_LIST` 是 2026-11-10 19:28 那次写出来的：当时整机异常断电（阶段 22 那次黑屏），随后我在 Linux 里 `ntfsfix -d` 清脏标记、`ntfs-3g` 读写挂载、改写了配置单元并把 `SYSTEM.LOG1`/`SYSTEM.LOG2` 截成 0 字节。Windows 在 17:35、17:47、17:52 都还能启动，说明这条记录当时还没坏成现在的样子；具体是截断时 `ntfs-3g` 留下了这份属性列表，还是之后又被改写，现在已经无法从磁盘上分清。可以确定的是：坏的只有这一条记录，而且出现在 Linux 写过的文件上。

## 4. 修法

`SYSTEM.LOG2` 本来就是空文件（Windows 用它做双日志的第二份，空的表示没有待回放的事务）。所以直接删掉、重建一个空文件就行，内容不变：

- 备份：原记录 79594 和 SYSTEM 的原始 MFT 记录、`SYSTEM`、`SYSTEM.LOG1` 存在平板 `/root/ntfs-fix-20261111-013107/`。
- 删掉再 `: >` 重建以后，同一个记录号 79594 序号变成 2，只剩 `$STANDARD_INFORMATION`、`$FILE_NAME`、`$SECURITY_DESCRIPTOR`、驻留的空 `$DATA`，没有属性列表。
- 全盘再扫一遍，带属性列表又带空 `$DATA` 的记录：0 条。

同时在 `\EFI\Microsoft\Boot\BCD` 的 `{bootmgr}` 上临时加了 `displaybootmenu=yes`（元素 `26000020`，备份 `BCD.pre-menu-20261111-005629`），排查时用来确认不是隐藏的启动菜单在等按键。确认之后可以去掉。

## 5. 以后怎么避免

- 从 Linux 改 Windows 分区时，**不要截断配置单元日志**（`SYSTEM.LOG1`/`LOG2`）。要清日志时，删掉再重建空文件。
- 写完后用 `mftscan.py` 扫一遍：任何带 `$ATTRIBUTE_LIST`、又有空范围非驻留属性的记录都要处理掉。
- `ntfsfix -d` 只在确实需要读写挂载时用，并且改完要让 Windows 正常开关机一次，让它自己的 `chkdsk` 逻辑接管。

## 6. 验证

同一个 QEMU 场景在修复后的盘上重启：winload 越过 `OslLoadAndInitializeHive`，读了 1.2 GB，PC 进入内核地址（`fffff800…`），屏幕出现 Windows 转圈。

## 7. 修好之后的第二个问题：`CRITICAL_STRUCTURE_CORRUPTION`（`0x109`），出错模块 `ndis.sys`

真机越过了 winload，随后蓝屏 `0x109`。页面文件里的转储（2026-11-10 11:01:31 UTC）：

| 项 | 值 |
|---|---|
| 停止码 | `0x109`，参数 4 = `0x1`（被改动的是函数代码） |
| 参数 3 | `0xFFFFF80257DECCF0` |
| 栈上 | `ndis.sys+0x10CCF0` |

`ndis.sys+0x10CCF0` 正是 Wi-Fi 诊断驱动 `qcwlan-dbglog`（`trace.h` 里的 `NDIS_INNER_RVA`）为了记录 AddDevice 状态，在内存里往 ndis 代码头写的 16 字节跳转。内核补丁保护（PatchGuard）定期校验内核模块代码，发现被改就蓝屏 `0x109`。Wi-Fi 调通以后这个诊断驱动还留着开机启动（`Start=0`），一直在冒这个险：这次不是新问题，只是校验的时机碰上了。

修法：`qcwlan-dbglog` 改成 `Start=4`（不启动）。它的任务（看 Wi-Fi 卡在哪）已经完成。离线改配置单元时日志按 §5 的方式删掉重建，改完再扫一遍 MFT：0 条可疑记录，`SYSTEM`/`LOG1`/`LOG2` 都没有属性列表。备份在平板 `/root/hive-qcwlan-dbglog-20261111-081721/`。

**以后要用这个诊断驱动时**，只能临时启动、拿到日志就停。在 ndis 上做代码内联钩子，迟早会被 PatchGuard 抓到。

## 8. 第三个问题：PowerShell 报 `0x80070570`（文件已损坏）

进桌面后运行 `1-install.cmd`，PowerShell 加载 `System.Management.Automation` 程序集失败，`HRESULT 0x80070570` 即 `ERROR_FILE_CORRUPT`：NTFS 层面的损坏，不是 .NET 本身的问题。

最可能的来源是这几天反复在 Linux 里 `ntfsfix -d` 后强制读写挂载。Windows 被蓝屏、复位打断时，元数据还留在它的 NTFS 日志（`$LogFile`）里没写回；`ntfsfix -d` 会清掉"未干净关闭"标记并重置这份日志，Windows 下次开机就不会自己回放日志、也不会跑 `autochk`，没落盘的那部分元数据就丢了。阶段 25 那次 `SYSTEM.LOG2` 的坏记录也是同一类后果。

修法：在 Windows 里用 `chkdsk C: /f` 让它在下次开机时离线修 NTFS，修完再 `sfc /scannow` 补回被删的系统文件。

**规则（替换 §5 里的第三条）**：Windows 分区脏的时候，不要在 Linux 里 `ntfsfix -d`。要么回 Windows 正常关一次机，要么只读挂载。确实必须从 Linux 写时，写完要让 Windows 下次开机跑 `chkdsk`。

GPU 垫片 `dagu-smmushim` 也在 qcdx 里改指令（阶段 22 的七处补丁），qcdx 不是内核模块，PatchGuard 不校验它；但这仍是诊断手段，正式方案要拆掉。

### 工具

- `/tmp/pdbsym.py`：读 PDB 的公共符号，RVA 转函数名（winload 符号来自 msdl）。
- `/root/mftrec.py`、`/root/mftscan.py`：按原始 NTFS 结构读 MFT 记录、扫可疑记录（平板上）。
