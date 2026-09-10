# Xiaomi Pad 5 Pro 12.4 (骁龙 870) — Win11 ARM 原生适配

> 为 **小米平板5 Pro 12.4**（骁龙 870 / SM8250-AC）在 **Windows 11 ARM64** 上实现原生启动、设备驱动与 GPU 加速适配的开源项目。

---

## 设备信息

| 项目 | 规格 |
|------|------|
| 产品名称 | 小米平板5 Pro 12.4 (Xiaomi Pad 5 Pro 12.4) |
| 型号代号 | 22081281AC |
| 内部代号 | dagu |
| 发布时间 | 2022 年 8 月 11 日发布，8 月 24 日开售 |
| SoC | 高通骁龙 870 (Snapdragon 870, SM8250-AC) |
| CPU | 1× Cortex-A77 @ 3.2 GHz + 3× A77 @ 2.42 GHz + 4× A55 @ 1.8 GHz |
| GPU | Adreno 650 |
| 内存 | 6 GB / 8 GB / 12 GB LPDDR5 |
| 存储 | 128 GB / 256 GB / 512 GB UFS 3.1 |
| 屏幕 | 12.4" IPS LCD, 2560×1600 (2.5K), 120 Hz, HDR10 / Dolby Vision |
| 电池 | 10000 mAh, 67 W 有线快充 |
| 接口 | USB Type-C 3.2 Gen 1 (支持 DP 视频输出) |
| 无线 | Wi-Fi 6 (802.11ax), 蓝牙 5.2 |
| 架构 | ARM64 (aarch64) |

---

## 构建环境

UEFI 在 **本机 Linux** 编译（edk2-msm 需要 bash + 交叉工具链）。Windows 仍可用于 adb / fastboot、DriverUpdater、WinPE。

```bash
./tools/bootstrap-workspace.sh   # 首次：clone edk2-msm + vendor
./tools/build-dagu-uefi.sh       # 产物：artifacts/boot-dagu-latest.img
```

主线 Linux（对照 ginkgo）在 [`linux-mainline/`](linux-mainline/README.md)：内核只 `fastboot boot`；Ubuntu 刷 **userdata**，覆盖安卓，不另建分区。


---

> 完整调研见 [docs/solution-research.md](docs/solution-research.md)

**现状：** `dagu` 尚未被 [Renegade Project](https://renegade-project.tech/en/devices) 官方收录。SM8250 在 [edk2-msm](https://github.com/edk2-porting/edk2-msm) 中已有 SoC 层支持（可引导 Linux），但社区反馈 Windows 目前仅能启动极简 WinPE，**尚不足以日常使用**，需完成设备移植。

**推荐路线（按优先级）：**

| 优先级 | 方案 | 说明 |
|--------|------|------|
| 1 | **edk2-msm 新设备移植** | 以 [j716f 移植范例](https://github.com/edk2-porting/edk2-msm/commit/fcd382a2815e0e5286a0c4bc150c9f070e270da3) 为模板，为 `dagu` 添加 UEFI 配置 |
| 2 | **参考小米平板5 (nabu) WoA 流程** | 同系列平板已有成熟方案：[Port-Windows-11-Xiaomi-Pad-5](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5)（分区、双系统、驱动更新） |
| 3 | **WOA-Drivers + DriverUpdater** | 社区 Windows 驱动来自 [WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers)，用 [DriverUpdater](https://github.com/WOA-Project/DriverUpdater) 离线注入 |
| 4 | **Mu-Silicium (Cedros/SM8250)** | [Project Silicium](https://github.com/Project-Silicium/Mu-Silicium) 为新一代 UEFI 栈，SM8250 有 Cedros 支持但 `dagu` 仍需自行移植，作备选 |

**安装方式：** 不再走自编 Linux Mass Storage（该路径曾导致 USB 假死，已从固件中移除）。后续安装改 **Windows PE / USB 启动介质**（见 [Renegade 安装指南](https://renegade-project.tech/en/install)）。  
历史记录：[docs/mass-storage-blocker-analysis.md](docs/mass-storage-blocker-analysis.md)。

**GPU 预期：** 走社区 WDDM 驱动（WOA-Drivers 提取 + INF 适配），**不是** 2025 年底面向 Snapdragon X Elite PC 的 UGD 可下载驱动。

---

## 项目目标

1. **Bootloader 解锁与引导链**
   - 解锁 Xiaomi 设备 Bootloader
   - 构建/适配 UEFI (EDK2) 或 abl 引导链，使设备能启动 Windows 11 ARM64 安装介质

2. **SoC 平台驱动 (Qualcomm SM8250)**
   - 时钟 / 电源管理 (CPR, RPMh, GCC)
   - 存储控制器 (UFS)
   - USB / Type-C (含 DP Alt Mode)
   - 音频 (WCD938x / WSA883x)
   - Wi-Fi / 蓝牙 (QCA6391 或同类)
   - 触摸屏 / 传感器

3. **GPU 原生驱动 (Adreno 650)**
   - 基于 Qualcomm 官方 Win ARM GPU 驱动栈 (如 `qcdx8550` 系列) 进行 SM8250 适配
   - 或移植/逆向社区驱动方案 (如 Turnip/Mesa 在 WoA 上的探索路径)
   - 实现 DirectX 12 / WDDM 兼容，支持桌面合成与基础 3D 加速

4. **ACPI / DSDT 与设备树**
   - 编写或移植 ACPI 表，正确枚举 SoC 外设
   - 参考同平台 (SM8250) 已适配设备 (如部分手机 WoA 项目) 的 DSDT 模板

5. **完整可用性**
   - 正常安装 Win11 ARM64
   - 触控、Wi-Fi、音频、亮度调节、休眠/唤醒
   - GPU 硬件加速 (至少 2D 合成，目标 3D / 视频解码)

---

## 技术背景

### 骁龙 870 与 Win11 ARM

骁龙 870 基于 SM8250 平台，与骁龙 865 同源（ARMv8.1 atomics，可安装较新的 Win11 ARM64 构建）。与已成熟的小米平板5 (nabu, SM8150) 相比，本项目的额外挑战：

- `dagu` 无现成 UEFI/驱动包，需从零做 edk2-msm 设备移植
- SM8250 的 Windows 生态 **弱于 SM8150**（edk2-msm 维护者：目前 WinPE 可进但实用性低）
- Windows on ARM **强依赖 ACPI** — UEFI 提供的 ACPI 表必须与真实硬件一致，否则 QCDX 等驱动易 BSOD
- 平板形态：大屏触控、旋转、亮度、USB-C DP 输出需单独适配（dagu 的 USB 3.2 + DP 是比 nabu 的潜在优势）
- 无基带/通话模块，Modem 相关驱动可省略

**可借鉴的平板先例：** [Renegade — Xiaomi Pad 5 (nabu)](https://renegade-project.tech/en/devices/xiaomi/nabu) 状态为 Supported，安装流程以 [GitHub 官方指南](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5) 为准。

### 引导与安装栈

```
Android Bootloader (ABL/XBL, 已签名)
        ↓ fastboot boot boot-dagu.img
edk2-msm UEFI (Renegade Project)
        ↓ USB 启动 WinPE / ISO（不再使用自编 LSMS）
Windows 11 ARM64 + WOA-Drivers (社区驱动包)
```

关键工具链：[edk2-msm](https://github.com/edk2-porting/edk2-msm) · [WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers) · [DriverUpdater](https://github.com/WOA-Project/DriverUpdater) · [Renegade Porting Guide](https://renegade-project.tech/en/porting)

### GPU 驱动路径

| 方案 | 说明 | 优先级 |
|------|------|--------|
| **社区 WDDM (WOA-Drivers)** | 从高通 WinARM 笔记本提取的 Adreno 驱动二进制，按 SM8250 / dagu 打 INF 补丁 | 高 |
| **Snapdragon X UGD 驱动** | 2025-11 高通面向 X Elite PC 的可下载 GPU 驱动，**不适用于 SM8250** | ❌ |
| **Turnip (Mesa Freedreno)** | 开源 Vulkan，WoA 上仍为实验阶段 | 低 |
| **软件渲染 fallback** | 无 GPU 驱动时的早期 bring-up 手段 | 仅调试 |

Adreno 650 与 865 同代；ACPI 就绪后，优先参考 SM8250 手机 WoA 项目的 GPU INF 修改方式。

---

## 目录结构 (规划)

```
xiaomi-pad870-win11-arm/
├── README.md                 # 本文件
├── docs/                     # 文档与笔记
│   ├── solution-research.md  # 社区方案调研 (2026)
│   ├── hardware-debug-workflow.md  # 硬件快速调试流程
│   ├── bootloader-unlock-guide.md  # BL 解锁指南
│   ├── uefi-port-dagu.md       # dagu UEFI 移植与编译
│   ├── hardware-inventory.md # 硬件清单 (ACPI dump, lsusb 等)
│   ├── boot-guide.md         # 刷机/启动指南
│   └── gpu-driver-notes.md   # GPU 驱动适配笔记
├── acpi/                     # ACPI/DSDT 源码与编译脚本
├── drivers/                  # 自研或修改过的驱动 INF/二进制
│   └── gpu/                  # Adreno 650 GPU 驱动相关
├── port/dagu/                # dagu UEFI 覆盖层（打入 edk2-msm）
├── edk2-msm/                 # bootstrap 后 git clone，不入库
├── vendor/kernel_devicetree/ # 同上
├── artifacts/                # boot-dagu-*.img 编译产物
├── tools/                    # 辅助脚本 (打包、签名、刷写)
    ├── downloads/            # Mi Unlock / platform-tools 官方 zip
    ├── mi-unlock-cn/         # 已解压的国行 Mi 解锁工具
    ├── platform-tools/       # adb / fastboot
    ├── test-lab/               # 可恢复测试实验室 → [docs/test-lab-workflow.md](docs/test-lab-workflow.md)
    ├── bootstrap-workspace.sh # clone edk2-msm + vendor
    ├── build-dagu-uefi.sh    # Linux 编译 boot-dagu.img
    ├── extract-dagu-dtb.ps1  # 从 boot.img 提取 DTB 指引
    ├── collect-hw-dump.sh    # Golden Baseline 一键采集 (Linux/macOS)
    └── collect-hw-dump.ps1   # Golden Baseline 一键采集 (Windows)
```

> 当前仓库处于 **项目初始化阶段**，上述目录将随开发进度逐步填充。

---

## 开发路线图

- [x] **Phase 0 — 调研 / 硬件摸底**
  - [x] 调研 SM8250 WoA 社区方案 → [docs/solution-research.md](docs/solution-research.md)
  - [x] 按 [硬件调试流程](docs/hardware-debug-workflow.md) 完成 Golden Baseline 采集 → `dumps/dagu-20260719-092500/`
  - [x] 填写 [hardware-inventory.md](docs/hardware-inventory.md)（BL 已解锁；fastboot 已采集）
  - [x] Bootloader 已解锁（`fastboot getvar unlocked` = yes）
  - [ ] 补采 iomem/DTB（需 Magisk root 或使用 MiCode 开源 DT）

- [ ] **Phase 1 — UEFI (edk2-msm)**
  - [ ] 基于 j716f 模板创建 `dagu` 设备配置，编译 `boot-dagu.img` → [docs/uefi-port-dagu.md](docs/uefi-port-dagu.md)（**首版已编出**，待 fastboot 实测）
  - [ ] fastboot 链式引导 → UEFI Shell / SimpleFb 显示（用 `tools/test-lab/lab.ps1 test-uefi`）
  - [ ] 验证 USB 启动 WinPE / ISO（不使用 Mass Storage）

- [ ] **Phase 2 — Windows 部署**
  - [ ] 参考 nabu 流程改造 GPT 分区（双系统）
  - [ ] WinPE / USB 方式部署 Win11 ARM64
  - [ ] WOA-Drivers extract + DriverUpdater 灌入基础驱动

- [ ] **Phase 3 — ACPI 与外设**
  - [ ] 编写/移植 dagu ACPI（基于 SM8250 / Cedros）
  - [ ] 触摸屏、Wi-Fi / 蓝牙、音频、USB-C DP

- [ ] **Phase 4 — GPU 与日常可用**
  - [ ] Adreno 650 社区 WDDM 驱动适配，验证 DWM 加速
  - [ ] 亮度、旋转、休眠/唤醒
  - [ ] 发布 dagu 完整安装文档（对标 nabu 指南结构）

---

## 前置条件与风险

### 你需要

- 一台 **小米平板5 Pro 12.4** (Xiaomi Pad 5 Pro 12.4, 型号 22081281AC)
- **已解锁 Bootloader**（当前为 **locked**，见 [解锁指南](docs/bootloader-unlock-guide.md)）
- Windows PC（可选：DriverUpdater、WinPE、adb/fastboot）
- Linux 环境（编译 edk2-msm / UEFI）
- 备用 Android 系统 / 完整备份 (刷机失败可恢复)
- 基本嵌入式/驱动开发经验

### 风险声明

> ⚠️ 刷入第三方固件与 Windows 可能导致 **设备变砖**、**失去官方保修**、**数据丢失**。  
> 本项目仅供学习与研究，作者不对任何设备损坏负责。操作前请完整备份并了解救砖流程。

---

## 参考资源

### 核心

- [Bootloader 解锁指南](docs/bootloader-unlock-guide.md) — 国行 HyperOS 流程 + 本仓库已下载工具
- [Bootloader Fastboot 与 fastbootd](docs/fastboot-vs-fastbootd.md) — 物理分区 vs 动态分区、主线刷写该用哪种 fastboot
- [硬件快速调试流程](docs/hardware-debug-workflow.md) — 分层验证、Golden Baseline、日常实验循环
- [dagu EDL 救砖完整流程](docs/dagu-edl-recovery-full-playbook.md) — 9008 诊断、授权、线刷与恢复记录（2026-07-21）
- [「魔改 boot」与假死/9008 原因分析](docs/why-boot-modification-caused-dead-device.md) — 链式引导 vs 写分区、LSMS 与 EDL 演化链
- [可恢复测试实验室](docs/test-lab-workflow.md) — Golden 备份、UEFI 自动测试、一键 recover
- [dagu UEFI 移植与编译](docs/uefi-port-dagu.md) — bootstrap、依赖与 `build-dagu-uefi.sh`
- [Renegade Project](https://renegade-project.tech/) — 安装 / 移植 / FAQ
- [edk2-porting/edk2-msm](https://github.com/edk2-porting/edk2-msm) — SM8250 UEFI 固件
- [edk2-porting/WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers) — 社区 Windows 驱动包
- [WOA-Project/DriverUpdater](https://github.com/WOA-Project/DriverUpdater) — 离线驱动注入工具

### 平板参考

- [erdilS/Port-Windows-11-Xiaomi-Pad-5](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5) — 小米平板5 (nabu) WoA 完整指南
- [Renegade — Xiaomi Pad 5](https://renegade-project.tech/en/devices/xiaomi/nabu) — 官方设备页

### 备选 / 进阶

- [Project-Silicium/Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium) — Project Mu UEFI（含 Cedros/SM8250）
- [Project-Silicium/Silicium-ACPI](https://github.com/Project-Silicium/Silicium-ACPI) — ACPI 表源码
- [edk2-msm Issue #300](https://github.com/edk2-porting/edk2-msm/issues/300) — SM8250 社区讨论
- [Renegade 游戏/应用兼容性表](https://docs.google.com/spreadsheets/d/1XYuoySgYQE0HL573sA-0RGMX7I4lt5rWJuQ8Z8yRJNY/edit)

---

## 贡献

欢迎提交 Issue、硬件 dump、驱动补丁与文档改进。  
请在本机实测后再提交 PR，并注明设备批次与系统版本。

---

## 许可证

待定 (建议 MIT 或 GPL-2.0，驱动部分需遵循 Qualcomm 驱动原有许可)。

---

**Status:** ✅ Bootloader 已解锁 · 🚧 dagu UEFI port 骨架已加入 edk2-msm，待 Linux 编译与 fastboot 实测
