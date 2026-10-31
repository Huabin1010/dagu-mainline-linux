# dagu Windows：阶段 13（UEFI 给 GPU CX 上电 + 大核调频修复）（2026-10-31）

阶段 12 的结论是 Windows 下没人给 GPU CX 电源域上电，访问 Adreno SMMU / GMU 即总线不应答。
本阶段在 UEFI（`DaguPlatDxe`）里补上，并顺带修好了一个一直存在的 CPU 降频问题。全部已上板验证。

## 1. 部署链

- 主机重启后 Mu 构建环境被清掉了一部分（docker 镜像、Mu 子模块、sparse checkout 只剩 KonaPkg、
  QUP 固件、edk2-msm、原厂 boot dump）。已全部恢复或绕开：`build-dagu-uefi.sh` 在没有 edk2-msm
  时用 `port/dagu` 的 ASL，没有原厂 dump 时只出 payload。
- 新工具 `tools/winarm/repack-uefi-boot.py`：把 payload 换进从设备 dd 出来的 `boot_a`，其余字节
  原样保留（旧镜像往返测试逐字节一致）。
- 新工具 `tools/winarm/deploy-uefi-a.sh`：从 fastboot 出发，经 B 槽 Linux 备份 `boot_a`、把主机
  `id_rsa.pub` 追加进 Windows 的 `administrators_authorized_keys`（主机重启后原 ED25519 私钥丢了），
  再刷 `boot_a` 切回 A。备份：`~/dagu-woa/boot_a-pre-1031-1524.img`。
- 之后的迭代全部远程完成：Windows 里在 ESP 放 `\dagu-fastboot` 后重启，`DaguPlatDxe` 把平板送进
  fastboot（这条桥本阶段实测可用），主机刷 `boot_a`、切 A、重启。

## 2. 为什么诊断文件从来没写出来

`\dagu-uefi-diag.txt` 从 v1 起就没在 ESP 上出现过。改成把日志同时写进一个易失 UEFI 变量
`DaguDiag`（vendor GUID `d4a9c1e2-7b3f-4c6a-9e51-0da600000001`），Windows 里用
`GetFirmwareEnvironmentVariableW` 读，结果：

```
entry
ready-to-boot mDone=0 early=0      <- ReadyToBoot 先到
...
fs-notify #1 esp=0 / #2 esp=0 / #3 esp=0
fs-notify #4 esp=1                 <- ESP 在 ReadyToBoot 之后才挂上
ready-to-boot mDone=1 ×8
```

dagu 上 ReadyToBoot 在 ESP 文件系统挂载之前就触发了，`WriteEspFile()` 找不到 ESP 就静默返回。
现在改为 ESP 首次出现时（fs-notify）写文件，实测 `diag file write: Success`。
读变量：`tools/winarm/dagu-ps.sh - < tools/winarm/read-uefi-diag.ps1`（脚本里先开 `SeSystemEnvironmentPrivilege`）。绑核基准：`tools/winarm/core-bench.ps1`。

## 3. GPU CX 上电（已验证）

按高通 PEP `G1MD` F0 ENTER 的同一组资源，加主线 `adreno_smmu` 需要的三项，偏移来自主线
`gcc-sm8250.c`/`gpucc-sm8250.c`，基址来自原厂 DT `gpucc@3d90000`：

```
gpu: cfg_ahb cbcr=0x00000001 before          GCC_GPU_CFG_AHB_CLK 已在跑，才继续
gpu: cx_gdscr=0x00222001 before              SW_COLLAPSE=1，CX 关着
gpu: cx_gdscr=0xF8222000 after               PWR_ON
  gcc_gpu_memnoc_gfx / gcc_gpu_snoc_dvm_gfx / gcc_ddrss_gpu_axi /
  gpu_cc_ahb / gpu_cc_cxo / gpu_cc_cx_gmu / gpu_cc_cx_snoc_dvm   全部 on
gpu: hlos1 smmu vote=0x00000001
gpu: adreno smmu IDR0=0x4C017E06             Adreno SMMU 寄存器能读了
```

`0x4C017E06` 是合法的 SMMUv2 IDR0（阶段 12 时同一次读会让总线卡死）。没碰 GX（GPU 核心）。
ESP 上放空文件 `\dagu-no-gpu` 可整段跳过。ExitBootServices 时会在 ReadyToBoot/fs-notify 成功的
前提下重新置位。

## 4. 顺带修好：A77 大核一直跑在低频

旧诊断显示 `epss d1/d2: hw not enabled (0x2), skip`：UEFI 阶段大核簇还没上电，`ENABLE` 读出来
bit0=0，代码就跳过了投票，Windows 把这些核拉起来后它们停在一个很低的默认档位。
绑核单线程依赖链基准（每核 2 亿次乘加）：

| 核 | 修复前 | 修复后 |
|---|---|---|
| A55 ×4（d0） | 253–257 Miter/s | 253–257 |
| A77 ×3（d1） | 228–229 | **693–696（×3.0）** |
| A77 prime（d2） | 273 | **760（×2.8）** |

改法：`ENABLE` bit0=0 时照样投票（EPSS 本身常开，LUT 可读），但要求选中的 LUT 档 ≥500 MHz，
否则放弃。d1 投到 2150 MHz、d2 投到 2361 MHz（`DAGU_CPU_MHZ_D1/D2`，故意不顶满，只靠硬件 LMh 限温）。

## 5. 现状

- `boot_a` = v5（`~/dagu-woa/boot_a-v5-1031.img`），Windows 正常、SSH 可用。
- `QCDX=4`、`qcsmmu=4`、无覆盖表（阶段 12 的保险都还在）。
- GPU 驱动的下一步：GPU CX 已上电，可以重新试 MMU1（Adreno SMMU）和 GPU0（`_CRS` 已改成 SM8250 地址）。
  GX（GPU 核心）还没人上电，qcdx 访问 `GFX_REGS` 时仍可能卡住，需要用"运行时拉起"的测法。
