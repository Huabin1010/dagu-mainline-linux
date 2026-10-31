# dagu Windows GPU 适配：阶段 10（板上测 Step A：启动卡死，且比阶段 4 更早）（2026-10-31）

本阶段第一次把阶段 8 的成果上板。覆盖表用新工具 `tools/winarm/build-gpu-overlay.py`
生成（固件区字节 0 改动、SOSI 保持 8 字节 QWord、不含 PEP0），内容是：

```
固件 DSDT（rev 3，4819 字节） + Scope(\_SB){ GPU0(RESI/ENGS/TMDT)  MMU0  MMU1 }
OEM rev 4，9276 字节，sha256 0c8edec0…a68425
```

`QCDX Start=3`，PEP0 不存在，bootlog 开。

## 1. 结果

重启后 Windows 没有上线。之后平板落回 B 槽 Linux（`192.168.1.68`）。

| 证据 | 值 |
|---|---|
| ABL 槽状态 | `boot_a retry=0 unbootable=1`，`boot_b active successful` |
| `ntbtlog.txt` | **这次启动没有留下任何段落**（文件里 49 段启动记录，Step A 那次缺失） |
| minidump / MEMORY.DMP | 没有新的（最新仍是 10-30 17:27） |
| `bootstat.dat` | 有一次写入，时间与 Step A 那次启动吻合（bootmgr 阶段写的） |

对比阶段 4（10-30 09:16，覆盖表只有 GPU0，没有 ENGS，也没有 MMU0/MMU1）：

| | 阶段 4 | 阶段 10 Step A |
|---|---|---|
| ntbtlog 段落 | 有，168 行，最后一条 `qcdxkm8250.sys` | 没有 |
| 卡在哪 | 晚期 PnP（`dxgkrnl`、`monitor` 之后） | 启动日志落盘之前 |

`ntbtlog.txt` 是内核在启动卷可写之后才落盘的。阶段 4 那次能落盘，说明当时磁盘 I/O 是好的，
卡在后面加载 `qcdxkm8250.sys` 时。这次连一行都没落盘，说明卡得更早，或者磁盘 I/O 本身断了。

## 2. 判断：多半是 MMU0（APPS SMMU）把启动盘的 DMA 断了

Step A 相对阶段 4 多了两样：GPU0 的 `RESI/ENGS/TMDT`，以及 `MMU0`/`MMU1` 两个 `QCOM2509` 节点。

- `qcdxkm8250.sys` 在阶段 4 是晚期才加载的（排在 `dxgkrnl`、`monitor` 之后）。只给它加几个
  ACPI 方法，不会让它跑到启动日志落盘之前。
- `qcsmmu8250.sys`（INF `Class=System`，`StartType=3`）以前从没出现在任何一段 ntbtlog 里，
  因为以前没有 `QCOM2509` 设备。这次 `MMU0` 一枚举，PnP 就会在早期把它拉起来。
- `MMU0` 是 `0x15000000` 的 APPS SMMU。dagu 不出 IORT，UFS0 的 DMA 是靠 QHEE 留下的
  旁路流配置直通的，Windows 不知道 UFS 在这个 SMMU 后面。SMMU 驱动接管时一般会复位 SMMU、
  清掉旁路 SMR、把未匹配流设为 fault（ARM SMMUv2 `sCR0.USFCFG`）。这样 UFS 的 DMA 直接被挡，
  启动盘没了，内核既写不了 ntbtlog 也写不了 dump，表现就是无蓝屏、无日志的硬卡死。
- Linux 侧有同类记录：`arm_smmu_device_reset()` 会关掉所有启动期 context bank，MDP 扫描输出
  26ms 后停（`linux-mainline/dts/sm8250-xiaomi-dagu.dts` 第 937 行附近的注释）。

这和"无日志"的现象完全对得上，但**还没有单变量验证**。阶段 8 §5.2 / 路线图 §2.9 写的
"启用 SMMU 设备本身不碰 UFS DMA"只考虑了 IORT，没考虑 SMMU 驱动加载后会复位硬件，**这句不成立**，
已在路线图里改掉。

这一轮违反了"一次只变一项"：Step A 同时加了 ENGS 和 SMMU，所以只能说 SMMU 嫌疑最大。

## 3. 回滚（已完成）

从 B 槽 Linux 离线：`dagu-rescue.sh disable-qcdx`（`QCDX Start=4`）、`rm-dsdt`（覆盖表子键清空），
hive 备份在平板 Linux `/root/SYSTEM.bak-*`。`to-win` 切回 A 槽，Windows 正常启动。

注意：A 槽的重试计数这次刚好用到 0，所以卡死后第一次复位就落回了 B 槽。`to-win` 会把计数重置为 7，
下一次如果再卡死，复位后 ABL 还会继续进 A 槽，**不会自动回落**。要手动：电源+音量下进 fastboot，
主机 `python3 linux-mainline/scripts/fb-usb.py set-active b`、`reboot`。

## 4. 下一步：拆开两个变量

两张覆盖表已经生成并传到平板 `C:\dagu\`：

| 测试 | 内容 | 预期判读 |
|---|---|---|
| **G** `ov-gpu-testG.aml` | 固件 + GPU0(RESI/ENGS/TMDT)，**无 SMMU** | = 阶段 4 + ENGS，只差一个变量。若 ntbtlog 有段落且末条是 `qcdxkm8250.sys` 后卡住，说明 ENGS 没改变阶段 4 的卡点；若进桌面，看 PnP 问题码 |
| **G1** `ov-gpu-testG1.aml` | 固件 + GPU0 + **只有 MMU1**（Adreno SMMU `0x03DA0000`） | UFS 不在这个 SMMU 后面。G 之后再做，看 GPU 是否需要 SMMU 驱动 |

先做 G。应用（不会自动重启）：

```powershell
powershell -ExecutionPolicy Bypass -File C:\dagu\apply-one.ps1 -Aml C:\dagu\ov-gpu-testG.aml
```

`MMU0`（APPS SMMU）在找到让 qcsmmu 保留 UFS 旁路流的办法之前不要再放进覆盖表。

## 5. 本阶段改动的文件

- `tools/winarm/build-gpu-overlay.py`：覆盖表生成器（上一提交）。
- `docs/woa-dagu-gpu-stage10-2026-10-31.md`：本文件。
- `docs/woa-dagu-gpu-roadmap.md`：§2.9 更正 SMMU 结论，§4 决策树改为先拆 SMMU。
