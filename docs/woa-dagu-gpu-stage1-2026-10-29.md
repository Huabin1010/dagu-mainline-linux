# dagu Windows GPU 适配：阶段 1（PEP）记录（2026-10-29）

阶段 0 的结论是：`qcdx8250`（GPU 驱动）的依赖链上，除它自己之外的驱动都已经在平板的 DriverStore 里，
缺的只是 ACPI 节点，而整条链的根是 `PEP0`（高通电源引擎插件，驱动是 `qcpep8250.sys`）。
本阶段要让 `qcpep` 能加载而不让系统起不来。

## 1. 先确认 PEP 是不是真的绕不开

把 GPU 内核驱动的导入表列出来，三个变体都调用了 Windows 电源框架（PoFx）接口：

| 文件 | 调用的 PoFx 接口 |
|---|---|
| `qcdxkm8250.sys` | `PoFxRegisterCrashdumpDevice`、`PoFxRegisterComponentPerfStates`、`PoFxIssueComponentPerfStateChange`、`PoFxPowerOnCrashdumpDevice` |
| `qcdxkmrs38250.sys` | `PoFxRegisterComponentPerfStates`、`PoFxIssueComponentPerfStateChange` |
| `qcdxkmti8250.sys` | 同 `qcdxkm8250.sys` |

`PoFxRegisterComponentPerfStates` 要求设备有一个已注册的电源引擎插件来接收性能状态请求，
而在高通平台上提供这个插件的就是 `qcpep8250.sys`。所以 PEP 是硬依赖，不能跳过。

`qcdx8250.inf` 本身不写 `_DEP`，依赖关系全在 ACPI 的 `GPU0` 节点里。

## 2. 用注册表覆盖 DSDT 加入 PEP0：第一次尝试

做法见阶段 0 文档第 3 节。这次的覆盖表（修订号 4）在 `\_SB` 下加了：

- `Device (PEP0)`，`_HID` 是 `QCOM2519`，`_CID` 是 `PNP0D80`，照搬参考 DSDT 的 `_CRS`（10 个中断）、
  `INTR`、`CTPM`、`PPPM`（61 个 PMIC 电源资源）、`PPRR`、`PGDS`、`FPMD` 等表。
- `STND` 只列两项（`DMPO`、`MMVD`），per-device 电源表全部留空，不让 qcpep 去管任何现有设备。
- 桩对象：`PSUB`、`DPP0/DPP1`、`MPP0/MPP1`、`AGR0`。
- 去掉了参考 DSDT 里对 `\_SB.ABD`（I2C）和几十个 `TZ*`（温控区）的引用。

编译后 8320 字节，用 `C:\dagu\asl.exe /loadtable` 写入，重启。

### 结果：驱动加载失败，但系统没崩

```
Kernel-PnP 219: 驱动程序 \Driver\qcpep 加载失败。Device: ACPI\QCOM2519\2&daba3ff&0 状态: 0xC000026C
设备问题状态: 0xC0000034
```

`0xC0000034` 是 `STATUS_OBJECT_NAME_NOT_FOUND`。查下来原因跟 ACPI 无关：DriverStore 里的
`qcpep8250.sys` 在之前的调试中被改名成了 `qcpep8250.sys.off`，文件根本不在。
所以这一轮只证明了覆盖表里的 PEP0 节点语法没问题、PnP 能匹配上驱动。

## 3. 把文件名改回来：第二次尝试

文件复原后重启，Windows 在启动过程中挂掉，没写出任何 dump，平板自动落回 B 槽 Linux。
`ntbtlog.txt` 的时间戳停在上一轮启动，说明挂死发生得很早，在启动日志刷盘之前。

从 Linux 离线把 `qcpep` 的 `Start` 改成 4（禁用）后，A 槽恢复正常。

### `STND` 的方法名规律

qcpep 的二进制里只直接出现了 `STND`、`PPPM`、`PPRR`、`CTPM`、`DVMM` 这几个名字，
per-device 的表名是从 `STND` 返回的列表里拿的，并且名字要倒过来读：

| `STND` 里的名字 | 实际要定义的方法 | 管的设备 |
|---|---|---|
| `DM0G` … `DMLG` | `G0MD` … `GLMD` | `\_SB.GPU0` |
| `DMSB` | `BSMD` | 各串口、I2C、SPI 引擎 |
| `DMDS` | `SDMD` | UFS0、SDC2、USB、ADSP |
| `DMPO` | `OPMD` | 空表 |
| `MMVD` | `DVMM` | 空表 |

所以要让 qcpep 只管 GPU，`STND` 里就只放 `DM0G` 到 `DMLG`。

## 4. 两个踩过的坑

### `hivexsh setval` 会清空整个键

离线禁用 qcpep 时我用了：

```
cd ControlSet001\Services\qcpep
setval 1
Start
dword:4
commit
```

`setval N` 的语义是“这个键下面总共有 N 个值”，所以除 `Start` 以外的
`Type`、`Group`、`ImagePath`、`ErrorControl`、`DisplayName` 全被删掉了。
服务键不完整时 Windows 仍能启动（因为驱动被跳过），但后面再想启用就起不来了。

正确做法是把该键下所有值一起写回，见 [tools/winarm/dagu-rescue.sh](../tools/winarm/dagu-rescue.sh)
的 `set-pep` 子命令。

### `Start=3`（手动）挡不住 PnP

把服务改成手动启动并不能阻止加载：ACPI 里存在 `QCOM2519` 节点时，PnP 在开机阶段照样会加载驱动。
要真正不加载，只有两条路：把 `Start` 改成 4（禁用），或者把 DSDT 覆盖表删掉。

### 崩溃后 NTFS 是脏的

Windows 异常断电后，`ntfs-3g` 会拒绝可写挂载。要先 `ntfsfix -d`，再用
`ntfs-3g -o force,remove_hiberfile` 挂载。

## 5. qcpep 的断言是硬蓝屏

`CORE_VERIFY` 失败时走的是：

```c
DbgPrintEx(0x65, 3, "CORE_VERIFY (%s)\r\n", msg);
KeBugCheckEx(0x14B, ...);   // 0x14B = SOC_SUBSYSTEM_FAILURE
```

没有“只打日志不蓝屏”的开关，二进制里一共 469 处引用这个函数。
已经确认会走断言的地方有 `AcpiObject.c`、`Idle_AcpiLpiPep.c`、`Acpi_CoreTopologyData.c`、
`PEP_Utilities.c:243`、`Idle_MicroPep_8180.c:185`。

从 `Idle_*` 这几个文件名看，CPU 空闲路径是断言的集中区。而 GPU 只需要 PEP 提供设备电源和
性能状态，不需要它管 CPU 空闲。INF 里正好有对应开关：

| 值 | 平板当前 | 含义 |
|---|---|---|
| `EnableProcessorManagement` | 1 | 接管 CPU 性能状态 |
| `EnableACPILPIPEP` | 1 | 接管 ACPI 低功耗空闲状态（`_LPI`） |
| `DisableSystemLPM` | 0 | 系统级低功耗模式 |
| `DisablePCE` | 0 | 电源协调引擎 |

下一步就是把前两个关掉、`DisableSystemLPM` 打开，再带 PEP0 节点启动。

## 6. 自动救援

试错过程中平板会反复在 A 槽（Windows）和 B 槽（Linux）之间来回，手工救援太慢。
实际上这个过程可以全自动：A 槽连续启动失败后引导程序会自己回落到 B 槽，而 B 槽的 Linux 有
Wi‑Fi 和 ssh（`192.168.1.75`，root 密码 `dagu`），能挂载 Windows 分区离线改注册表。

[tools/winarm/dagu-rescue.sh](../tools/winarm/dagu-rescue.sh) 把这套流程固定下来：

```bash
tools/winarm/dagu-rescue.sh status              # 看哪个槽在跑
tools/winarm/dagu-rescue.sh wait 300            # 等任意一侧上线，输出 windows / linux
tools/winarm/dagu-rescue.sh auto                # 落到 Linux 就删覆盖表并切回 A 槽
tools/winarm/dagu-rescue.sh rm-dsdt             # 只删 DSDT 覆盖表
tools/winarm/dagu-rescue.sh set-pep 4           # 改 qcpep 的 Start（会写回全部值）
tools/winarm/dagu-rescue.sh to-win              # 进 fastboot，切 A 槽，重启
tools/winarm/dagu-rescue.sh hive-run <脚本>     # 把脚本推到 Linux 上以 root 执行
```

改注册表前会把 SYSTEM 备份到平板 Linux 的 `/root/SYSTEM.bak-*`。

## 7. 当前状态

- A 槽 Windows 正常，DSDT 是固件的修订号 3，覆盖表已删除，`PEP0` 节点不存在。
- `qcpep` 服务键已修复完整，`Start=3`。
- Wi‑Fi、UFS、蓝牙、触摸、键盘都正常，显示仍是 Microsoft Basic Display。
- 下一步：关掉 qcpep 的 CPU 管理开关，再带 PEP0 节点启动。
