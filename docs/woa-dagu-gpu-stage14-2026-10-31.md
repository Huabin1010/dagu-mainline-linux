# dagu Windows GPU：阶段 14（GPU CX 上电后再试 Adreno SMMU：硬件级复位）（2026-10-31）

阶段 13 让 UEFI 给 GPU CX 上电，Adreno SMMU 的 IDR0（`0x4C017E06`）在 UEFI 里能读了。
本阶段在 Windows 下重试 `qcsmmu8250` 驱动 MMU1（Adreno SMMU）。

## 1. 做法（启动不受影响）

- 固件 DSDT 重新 dump（4819 字节，SOSI 8 字节 QWord），存一份到
  `backups/fw-dsdt/dagu-fw-dsdt-rev3-20261031.aml`，以后生成覆盖表不依赖 `/tmp`。
- 覆盖表 = 固件 DSDT + GPU0（阶段 12 改过的 SM8250 地址）+ **只有 MMU1**，
  `build-gpu-overlay.py --allow-boot-hang` 生成，38264 字节，自检全过。
- `qcsmmu=4`、`QCDX=4` 开机：正常进系统。`ACPI\QCOM2509\1` 枚举为
  `ACPI\VEN_QCOM&DEV_2509&REV_0002`（对上 INF），`ACPI\QCOM253A\0` 为 `REV_050E`，都是
  `CM_PROB_DISABLED_SERVICE`。**带 SMMU 节点开机本身不再有问题**（驱动禁用时）。
- 运行时拉起：新脚本 `tools/winarm/rt-start.ps1 -Svc qcsmmu -Id ACPI\QCOM2509\1`
  （SYSTEM 计划任务；设 Start=3、`pnputil /restart-device`、驱动镜像一加载就写回 4 并 flush）。

## 2. 结果

拉起后几秒内整机掉线，不蓝屏、不写 dump。大约 6 分钟后平板自己落回 B 槽 Linux。

| 证据 | 值 |
|---|---|
| `rt-qcsmmu.log` | 只有空白（日志还没刷盘就没了） |
| 离线 hive | `qcsmmu Start=4`（脚本已写回并 flush，说明驱动镜像已加载） |
| MEMORY.DMP / minidump | 无新文件 |
| ntbtlog | 崩溃之后、救援之前**没有任何新的启动记录** |
| System 事件 | 下次正常启动报 41/6008（上次非正常关机） |

也就是说：

1. 驱动在初始化 Adreno SMMU 时触发的不是 Windows 能接住的异常，而是让整颗 SoC 复位的
   硬件级故障（形态与 XPU/安全侧违规由 TZ/QHEE 直接复位一致）。
2. 复位之后，A 槽的几次重试都在 Windows 内核写盘之前就失败了，直到重试耗尽落 B。
   原因未查明：可能是复位进了 ramdump/下载模式（`05c6:*`，本次 USB 轮询没有匹配这个 ID），
   也可能是 SMMU 残留状态影响了 UEFI。B 槽救援后 `to-win` 第一次就正常进系统。

## 3. 线索：Adreno 实例的 INF 参数里有安全上下文

`qcsmmu8250.inf` 给 Adreno SMMU 实例（`Parameters\1`）写的上下文表：

```
CB0 (S1_GPU)        HLOS
CB1 (S1_GPU_P)      CP_PIXEL   <- 内容保护的安全 VMID
CB2 (S1_GPU_ECP)    HLOS
CB3 (S1_GPU_ECP_FW) HLOS
SCLCK Enabled=1     "clock should be controlled by SMMU driver"（经 PoFx/PEP 投票，dagu 没有 PEP）
HYPD  Enabled=0
```

驱动还按 "XBL 已配置的流" 复用上下文（`PopulateXBLEntries` / `GetXBLConfiguredCBForStream`）。
在 dagu 这条 QHEE 链上，HLOS 直接编程属于 CP_PIXEL 的 CB1 很可能就是触发复位的写入。
主线 Linux 能用 Adreno SMMU，是因为它只用 CB0、并且有 qcom 专用实现。这一条**未验证**。

## 4. 结论与选项

- 走高通原版 `qcsmmu` + `qcdx` 这条路，下一道坎是 SMMU 初始化直接复位整机；过了这道坎之后
  还有 GX 上电（GMU 固件 + RPMh GFX 轨投票）、GPU 微码/zap（需要 PIL/SCM）、L81A 面板配置
  （`_ROM`/PCFG）几道，每一道都依赖 TZ/QHEE 服务，dagu 上 RPMh BCM 投票在 Linux 下就已知超时。
- 可选的下一步（按成本从低到高）：
  1. 改 `Parameters\1\S2CB`/`CTXI`，去掉 CB1（CP_PIXEL），只留 HLOS 上下文，再试一次。
     每次失败约 10 分钟，可全程远程恢复。
  2. 逆向 `qcsmmu8250.sys` 的 `SmmuInitHardware`，找出复位前最后一次写的寄存器。
  3. 不用高通 SMMU 驱动：在 UEFI 里把 Adreno SMMU 配成 GPU 流旁路（Linux 侧 Wi-Fi 的 PCIe0
     就是这么做的），GPU0 不声明 `ArmSmmuV2`。需要同时改 ENGS，工作量大。

设备现状：Windows 正常，`qcsmmu=4`、`QCDX=4`、无覆盖表；boot_a 仍是阶段 13 的 v5 UEFI。

## 5. 追加验证：去掉 CP_PIXEL（CB1）仍然复位

按 §3 的线索，把 Adreno 实例（`Parameters\1`）的 `CTXI` 改成只剩 CB0/CB2/CB3、`S2CB` 删掉
映射到 CB1 的条目（只留 HLOS 上下文），再运行时拉起 `qcsmmu`。结果**完全一样**：几秒内整机
复位、无 dump、随后 A 槽重试耗尽落 B。所以触发点不是那一个安全上下文，而是 `qcsmmu` 对 Adreno
SMMU 做寄存器编程这件事本身——与 QHEE 把 SMMU 当受保护资源、越权访问即复位一致（`qcsmmu8250.sys`
全程直接 MMIO，无 SMC/HVC）。`S2CB` 的真实结构是深层子键（`S2CB\<sid>\<mask>\<cb>` 里放 MAP），
不是一条扁平二进制，改起来也更脆。

## 6. 一个操作陷阱：崩溃后必须删覆盖表，不能只禁驱动

qcsmmu 这次硬复位（SoC 级）把 SYSTEM hive 留成了脏状态。之后 `to-win` 回 A 槽时，**覆盖表
还在**（`00000004` 在，但 `qcsmmu`/`QCDX` 都已是 4），Windows 内核在 `ExitBootServices`
（`PROGRESS CODE: V03101019`）之后、画面还没起来时就挂住——屏幕冻在 UEFI 调试日志上，
不复位、不自动回落。拍照确认：`DaguPlat ready-to-boot`、`ESP found, flag open Not Found`、
`bootmgfw.efi`、`ExitBS`、`V03101019`。

同一张覆盖表在 hive 干净时能正常进系统（阶段 14 §1）；脏 hive + 覆盖表一起就挂。结论：
**任何一次 GPU/SMMU 崩溃之后的恢复，都必须 `rm-dsdt` 删掉覆盖表，不能只把驱动 Start 改 4。**
`dagu-rescue.sh` 的 `auto` 已经是先 `rm-dsdt`，手动恢复时要记得。本次恢复：进 fastboot →
B 槽 → `disable-qcsmmu`/`disable-qcdx`/`rm-dsdt` → `to-win`，Windows 正常（脏 hive 由
Windows 自己用 LOG 文件回滚，首个启动偏慢、sshd 晚几分钟才就绪，属正常）。

## 7. 路线判断

GPU CX 已上电（阶段 13），但高通 `qcsmmu` 驱动一碰 Adreno SMMU 就被 QHEE 复位，这是“原版
qcsmmu + qcdx”路线的硬墙。后续只剩三条路，都更重：
1. 逆向 `qcsmmu8250.sys` 的 `SmmuInitHardware`，定位复位前最后一次寄存器写，找能绕开的注册表开关；
2. 不用 qcsmmu：在 UEFI 里把 Adreno SMMU 配成 GPU 流旁路（参考 Linux 侧 PCIe0 的做法），并改
   ENGS 让 qcdx 不要求 `ArmSmmuV2` 接口；
3. 暂时放弃 WDDM GPU，承认当前对“流畅度”最实在的收益是阶段 13 的大核调频修复（A77 ~3 倍），
   显示继续走 BasicDisplay。
