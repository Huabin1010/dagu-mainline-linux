# dagu Windows GPU：阶段 16（排除时钟/电源假设：Windows 下 Adreno SMMU 已上电且就绪）（2026-10-31）

阶段 14 留了个悬念：`qcsmmu8250` 一编程 Adreno SMMU 就复位整颗 SoC，怀疑之一是“访问时 SMMU 的
时钟/电源不在”（dagu 没有 PEP，`SCLCK Enabled=1` 要靠 PoFx/PEP 投票）。本阶段写了一个**只读**内核
驱动 `dagu-gpuprobe`，在跑起来的 Windows 里按安全顺序（GCC→GPU_CC→SMMU）读 GPU 时钟树和 Adreno
SMMU 全局寄存器，直接证伪了这个假设。

## 1. 做法

`port/dagu/windows-drivers/dagu-gpuprobe/dagu-gpuprobe.c`：WDM 驱动，`DriverEntry` 里

1. `MmMapIoSpaceEx` GCC（`0x00100000`），读 4 个 GPU 相关 CBCR；
2. 只有 `gcc_gpu_cfg_ahb` 在跑才映射 GPU_CC（`0x03D90000`）读 CX GDSC + 各 CBCR；
3. 只有 CX 已上电且三条 SMMU 时钟（ahb / memnoc_gfx / snoc_dvm_gfx，取自主线 `adreno_smmu` 的
   `clock-names = "ahb","bus","iface"`）都在跑，才映射 SMMU（`0x03DA0000`）读 IDR/sCR0/SMR/S2CR/CB。

全程**不写任何硬件**；每步前把 `step` 写进 `Services\daguprobe\Parameters` 并 flush，万一某步读挂了，
靠离线读 hive 的 `step` 定位。结果全落 REG_DWORD。`DriverEntry` 最后返回 `STATUS_UNSUCCESSFUL`
让它读完即卸载。交叉编译 + 测试签名同其它自写驱动（`build-kmdriver.sh` / `sign-driver.sh`）。

`sc create daguprobe type=kernel start=demand ...; sc start daguprobe` 跑了一次，没蓝屏、没复位。

## 2. 结果（板上，boot_a v8，UEFI 已给 CX 上电）

| 寄存器 | 值 | 解读 |
|---|---|---|
| `gcc_gpu_cfg_ahb` | `0x00000001` | bit0 使能、bit31 CLK_OFF=0 → 在跑 |
| `gcc_gpu_memnoc_gfx` | `0x00004221` | 在跑 |
| `gcc_gpu_snoc_dvm_gfx` | `0x00000001` | 在跑 |
| `gcc_ddrss_gpu_axi` | `0x00100001` | 在跑 |
| `gpucc_cx_gdscr` | `0xf8222000` | bit31 PWR_ON=1 → **CX 域已上电** |
| `gpucc_gx_gdscr` | `0x00222001` | bit31=0 → GX 未上电（本就没碰，符合预期） |
| `gpucc_ahb` / `cx_gmu` / `cxo` | `1` / `0x4221` / `1` | 在跑 |
| `gpucc_hlos1_smmu` | `0x00000001` | HLOS1 SMMU 投票时钟使能 |
| `smmu_idr0 / idr1` | `0x4c017e06 / 0x20000005` | SMMU 应答，与 UEFI 探针完全一致 |
| `smmu_scr0` | `0x00260406` | CLIENTPD=0、USFCFG=1（未匹配流 fault，非全局旁路） |
| `smr00..05` | 全 `0` | 6 个流匹配寄存器全 invalid |
| `s2cr00..05` | `0x07fea0ff` 等 | 全 type=2（fault）、cb=0xff |
| `cb_sctlr00..04` | `0x32622100` 等非零 | 5 个上下文组的 SCTLR 已被 QHEE 预置 |
| `cbar00..04` | 全 `0` | 但没有任何流被路由到这些 CB |

## 3. 结论

- **时钟/电源假设被证伪**：Windows 跑起来时，GPU CX 域已上电、Adreno SMMU 需要的三条时钟全在跑、
  SMMU 块正常应答。所以 `qcsmmu` 编程它时触发的复位，**不是因为访问了没上电的块**。
- SMMU 停在 **XBL 交出来的原始态**：GPU 流一个没配（SMR 全 invalid、S2CR 全 fault），但 5 个上下文组
  的 SCTLR 已由 QHEE 预置。这说明 QHEE 自己初始化了 CB 内部，等 HLOS 只去写 SMR/S2CR 把流路由到
  这些现成的 CB；而阶段 14 的 UEFI 写测显示：从 EL1 写 SMR/S2CR 不生效（被规格化回 fault），
  `qcsmmu` 在运行时写则直接复位。两者一致地指向**同一堵墙：QHEE 把 SMMU GR0/CB 当受保护资源**，
  HLOS（无论 UEFI-EL1 还是 Windows 内核）去编程就被 XPU/hyp 拦下。
- 因此复位的根因确定是 QHEE 的 SMMU 保护，不是 dagu 缺 PEP 导致的时钟问题。补 PEP 投票不会解决它。

## 4. 这对路线意味着什么

能想到的、还没堵死的方向只剩 Windows 侧的“接口垫片”：写一个驱动注册 qcdx 在等的设备接口
`{36079AE4-78E8-452D-AF50-0CFF78B2F1CA}`（阶段 15），把 ARID/CB 元数据喂给 qcdx，但**不去写会被
QHEE 拦的 SMR/S2CR**——赌 QHEE 已经替 GPU 建好了 stage-2（CB 的 SCTLR 非零是旁证），qcdx 只要拿到
元数据就能用预置的翻译。可行性取决于 `qcsmmu`↔`qcdx` 的接口契约（下一步逆向确认），而且即便过了
这堵墙，后面还有 GX 上电（GMU 固件 + RPMh GFX 轨，dagu 上 RPMh BCM 投票在 Linux 已知超时）、
GPU 微码 zap（要 PIL/SCM，TZ 服务）等几道同源的 TZ/QHEE 依赖。实话实说：GPU 这条链是一串 QHEE/TZ
依赖，SMMU 只是第一道。

## 5. 设备状态

只读探针跑完即卸载，没动任何硬件，没加覆盖表。Windows 正常，`QCDX=4`、`qcsmmu=4`，boot_a 仍 v8。

### 关联文档
[stage14（SMMU/QHEE 复位墙）](woa-dagu-gpu-stage14-2026-10-31.md)、
[stage15（qcdx REGR + 接口依赖）](woa-dagu-gpu-stage15-2026-10-31.md)、
[roadmap](woa-dagu-gpu-roadmap.md)。
