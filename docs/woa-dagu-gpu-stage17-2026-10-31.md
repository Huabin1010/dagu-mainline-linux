# dagu Windows GPU：阶段 17（qcsmmu 写寄存器全图：复位源是 HLOS 直写 hyp 保护的 SMMU 全局寄存器）（2026-10-31）

阶段 14 要“逆向 `SmmuInitHardware`，定位复位前最后一次寄存器写”。本阶段静态逆向（零风险，不碰设备）
把 `qcsmmu8250.sys` 对 Adreno SMMU 的全部 MMIO 写列清楚了，坐实复位的驱动侧根因。

## 1. MMIO 访问器

`qcsmmu` 用 `MmMapIoSpaceEx` 映射 SMMU（无 `WRITE_REGISTER_*` 导入），读写都走两个包装：

- 读 `0x11aa0` ← `0x11ad0(base, arid, off)`
- 写 **`0x11ba8(base, arid, off, val)`**

寻址都是 `addr = base + arid*0x1000 + off`（每个 ARID 占一个 4KB GR 窗口；Adreno 实例 arid=0）。

## 2. 全部写寄存器调用点（backtrack `0x11ba8` 的 off 参数）

| 包装 fn | off | 寄存器（ARM SMMUv2 GR0） | 被谁调 |
|---|---|---|---|
| `0x11ce8` | `0x000` | **sCR0**（全局控制） | `SmmuInitHardware 0x22280` |
| `0x11d68` | `0x008` | **sCR2**（全局安全配置） | `SmmuInitHardware 0x22280` |
| `0x11f48` | `0x800+4n` / `0xc00+4n` | **SMR[n] + S2CR[n]**（流匹配+路由） | `0x1faa8`←`0x21b90`←`0x22280` |
| `0x120a8` | `0x800+4n` | SMR[n] | `0x22280` |
| `0x12110` / `0x122f8` | `0x000` | sCR0（另一路，enable/reset） | `0x19a38` / `0x19f18` |
| `0x124c8` | `0x000` | sCR0 | `0xa5f8` / `0xaa88` |
| 其它 | `0x4/0x10/0x30/0x38/0x3c/0x400/0x618/0x7f0` | sCR1/sACR/CB 内部等 | 各 reset/CB 路径 |

## 3. 启动链

```
OnPrepareHardware() [0x4de0, WDF 设备启动回调]
  └─ SmmuInitHardware() [0x22280]
       ├─ reg@0  0x11ce8 → 写 sCR0   (GR0+0x0)
       ├─ reg@8  0x11d68 → 写 sCR2   (GR0+0x8)
       ├─ SMR-only 0x120a8 → 写 SMR[n]
       └─ 0x21b90 → 0x1faa8 → 0x11f48 → 写 SMR[n]+S2CR[n]
          （= ProgramStreamGroupForHLOSAssignedContextBank：把 GPU 流路由到 HLOS 上下文组）
```

## 4. 结论：复位源是 HLOS 直写 hyp 保护的 SMMU 全局寄存器

`qcsmmu` 在 `OnPrepareHardware` 里**用普通 MMIO（无 SMC/HVC）直接写 Adreno SMMU 的全局控制寄存器
sCR0/sCR2，以及 GPU 流的 SMR/S2CR**。在 dagu 的 stock QHEE 上，这颗 SMMU 的 GR0 是受 hypervisor
保护的资源，非安全侧（无论 UEFI-EL1 还是 Windows 内核 EL1）一写就触发 XPU/hyp 违规、整颗 SoC 复位。

三个阶段的证据一致指向同一堵墙：

| 阶段 | 证据 |
|---|---|
| 14 | UEFI(EL1) 写 SMR/S2CR 不生效（被规格化回 fault），不是普通寄存器 |
| 16 | Windows 下 SMMU 时钟/电源全在、正常应答 → 复位不是掉电/失钟 |
| 17 | 驱动用裸 MMIO 写 GR0 全局（sCR0/sCR2），无 hypercall → 一写即被 QHEE 拦 |

**墙的性质是架构级的：stock 安全世界（QHEE/TZ）独占 GPU SMMU，不把它委托给非安全 OS。** 补 PEP、改
ENGS 的上下文表、换地址都不触及这一点（阶段 10–16 已逐一排除）。

## 5. 为什么主线 Linux 能用、我们仍过不去

主线 Linux 在同一套 QHEE 固件上能驱动这颗 `adreno_smmu`，用的是 `arm-smmu-qcom` 针对高通安全
SMMU 的专用实现：它**不做全量全局 reset、保留固件留下的流映射**，并通过 `qcom,adreno-smmu` 让
GPU 自管上下文组。而高通原版 Windows `qcsmmu8250` 走的是通用 `SmmuInitHardware` 流程——上来就重写
sCR0/sCR2 全局控制，这正是 QHEE 不允许的。换句话说：
- Linux 侧之所以行，是因为它的 qcom 实现刻意避开了 QHEE 保护的全局写；
- Windows 侧 `qcsmmu` 没有等价的“保守模式”注册表开关（阶段 14 已查，INF 只有 `HYPD Enabled=0`、
  `SCLCK` 等，没有“不要写全局/不要 reset”的旋钮）。

理论上唯一的 Windows 侧出路是**自写一个 SMMU 驱动/垫片**，模仿 Linux：不写 sCR0/sCR2 全局，只把 GPU
的 SMR/S2CR 路由到 QHEE 预置的上下文组（阶段 16 看到 5 个 CB 的 SCTLR 已被 QHEE 预置）。但阶段 14 的
UEFI 写测显示：从 EL1 连 SMR/S2CR 都写不进（被规格化）。也就是说 QHEE 很可能连流路由也不放行，
这条垫片路大概率也堵死——需要一次**受控的单寄存器写测**从 Windows 内核确认（有设备复位风险，可远程恢复）
才能最终定论。

## 6. GPU 整条链的现实判断

即便 SMMU 这堵墙被绕过，WDDM 后面还串着同源的安全世界依赖：
1. **GX 上电**：GMU 固件 + RPMh VDD_GFX 轨投票（dagu 上 RPMh BCM 投票在 Linux 已知超时）；
2. **GPU 微码 / zap shader**：要 PIL/SCM（TZ 服务）加载并鉴权；
3. 面板 `_ROM`/PCFG。

每一道都依赖 QHEE/TZ。**在 stock HyperOS 固件下，不替换/重配安全世界，WDDM GPU 加速这条链走不通。**
GPU 侧目前能交付的实在收益仍是阶段 13 的大核调频（A77 ~3 倍，已验证），显示继续走 BasicDisplay。

## 7. 设备状态

本阶段全程静态逆向，没碰设备。Windows 正常，`QCDX=4`、`qcsmmu=4`，无覆盖表，boot_a v8。

### 关联文档
[stage14（QHEE 复位墙）](woa-dagu-gpu-stage14-2026-10-31.md)、
[stage15（qcdx REGR + 接口依赖）](woa-dagu-gpu-stage15-2026-10-31.md)、
[stage16（时钟/电源排除）](woa-dagu-gpu-stage16-2026-10-31.md)、
[roadmap](woa-dagu-gpu-roadmap.md)。
