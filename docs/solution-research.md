# 方案调研 — 小米平板5 Pro 12.4 (dagu / SM8250)

> 调研时间：2026 年 7 月  
> 目标设备：小米平板5 Pro 12.4（内部代号 `dagu`，SoC 骁龙 870 / SM8250-AC）

本文档汇总当前社区在 Qualcomm 手机/平板上运行 Windows 11 ARM64 的主流方案，并针对本设备给出推荐技术路线。

---

## 1. 现状结论（先说重点）

| 维度 | 现状 |
|------|------|
| **Renegade 官方设备列表** | `dagu` **未收录**；同系列仅 [小米平板5 (nabu)](https://renegade-project.tech/en/devices/xiaomi/nabu) 有完整 WoA 支持 |
| **SM8250 SoC 层支持** | [edk2-msm](https://github.com/edk2-porting/edk2-msm) 已有 SM8250 Silicon 代码，可引导 Android/Linux |
| **Windows 可用性** | 维护者明确表示：SM8250 目前只能启动 **极简 WinPE**，**尚不足以日常使用**；完整 Windows 需自行完成设备移植 + ACPI + 驱动 |
| **最接近的成功案例** | 小米平板5 (nabu, SM8150) — [Port-Windows-11-Xiaomi-Pad-5](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5) 提供成熟分区、UEFI、驱动、双系统流程 |
| **本项目定位** | 在 SM8250 平台层之上，为 `dagu` 做 **新设备移植**，并参考 nabu 平板项目的工程化流程 |

---

## 2. 社区方案对比

### 2.1 Renegade Project + edk2-msm（**推荐主路线**）

**是什么：** 将 EDK2 UEFI 伪装成 Linux boot.img，通过 fastboot 链式加载，再启动 Windows 安装介质或已部署的系统。

**仓库与文档：**

- UEFI 固件：[edk2-porting/edk2-msm](https://github.com/edk2-porting/edk2-msm)
- 安装总指南：[Renegade Project Installation Guide](https://renegade-project.tech/en/install)
- 移植指南：[Renegade Project Porting Guide](https://renegade-project.tech/en/porting)
- Windows 驱动包：[edk2-porting/WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers)
- 离线驱动注入：[WOA-Project/DriverUpdater](https://github.com/WOA-Project/DriverUpdater)

**对本项目的适用性：**

- SM8250 已在 `Silicon/` 与 `Platform/` 中存在基础支持
- 新增 `dagu` 设备可参考 edk2-msm 维护者给出的 [j716f 移植 commit](https://github.com/edk2-porting/edk2-msm/commit/fcd382a2815e0e5286a0c4bc150c9f070e270da3)：复制相近设备配置，替换内存映射、DTB、屏幕分辨率等设备特有项
- 需从 Android 侧收集：`/proc/iomem`、`/sys/firmware/fdt` 或 boot.img 中的 DTB、分区布局

**优点：**

- SM8250 有现成 SoC 层，不必从零写时钟/PMIC 框架
- 文档、工具链、驱动提取脚本（`extract.ps1` / `extract.sh`）成熟
- 同品牌平板 nabu 已有可复用的分区与双系统方法论

**缺点 / 风险：**

- SM8250 的 **Windows 驱动生态弱于 SM8150/SDM845**，GPU/Wi-Fi/触控等需大量手工适配
- ACPI 表必须与真实硬件一致，否则易 BSOD（Renegade 文档强调的核心难点）
- 社区 Issue 反馈：SM8250 WinPE 可进但实用性低

---

### 2.2 Project Silicium / Mu-Silicium（**备选 / 长期方向**）

**是什么：** 基于 Microsoft [Project Mu](https://microsoft.github.io/mu/) 的新一代 ARM64 UEFI 固件，Renegade 部分工作已向其迁移。

**仓库：**

- [Project-Silicium/Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium)
- [Project-Silicium/Guides](https://github.com/Project-Silicium/Guides)
- [Project-Silicium/Silicium-ACPI](https://github.com/Project-Silicium/Silicium-ACPI)

**对本项目的适用性：**

- Mu-Silicium v3.7+ 已加入 **Cedros**（SM8250 平台代号）Silicon 支持
- `dagu` 设备本身 **尚未** 出现在官方支持列表，仍需按 Guides 做设备级移植
- XDA 社区反馈：新平台移植应优先关注 **ClockDxe** 等 DXE 驱动补丁；Mu-Silicium Discord 是活跃求助渠道

**优点：**

- 2025–2026 年持续更新（Mass Storage、Secure Boot、Project Mu 同步等）
- 架构更现代，新 SoC（SM8450+）支持更好

**缺点：**

- `dagu` 无开箱即用支持
- 平板 + SM8250 + Windows 三重重叠，成熟度仍低于 edk2-msm + nabu 参考路径
- 学习曲线高于直接跟 edk2-msm 移植

**建议：** Phase 1 以 edk2-msm 为主；若 edk2-msm 在显示/时钟上卡住，再评估 Mu-Silicium Cedros 基线。

---

### 2.3 参考项目：小米平板5 (nabu) WoA（**工程流程模板**）

虽然 nabu 为骁龙 860 (SM8150-AC)，与本机 SM8250-AC 不同，但同属小米平板5 系列，**工程流程高度可借鉴**：

| 环节 | nabu 成熟方案 | dagu 需额外工作 |
|------|---------------|-----------------|
| UEFI | Project Aloha / edk2-msm 已维护 | 新增 `dagu` 设备 port |
| 分区改造 | [erdilS 官方指南](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5)（parted / 双系统） | 验证 dagu 分区表差异（128/256/512GB） |
| 驱动包 | [MiPad5-Windows-Releases](https://github.com/remtrik-stuff/MiPad5-Windows-Releases) | 需基于 WOA-Drivers 为 SM8250 + dagu 硬件重新打包 |
| 安装方式 | Mass Storage + WinInstaller；**禁止仅看视频教程** | 待 UEFI 可用后复用流程 |
| 已知坑 | 旧版驱动/UFS 风险、GPT 与 Win11 24H2+ 兼容性 | 移植时直接采用最新驱动策略 |

Renegade 官网对 nabu 的说明也明确：**安装请跟 GitHub 指南，不要只用官网通用文档**。

---

## 3. 推荐技术栈（按优先级）

### Phase A — UEFI 引导（必须先过）

```
1. 解锁 Bootloader，完整备份 Android + 分区表截图
2. 克隆 edk2-msm，以 j716f (SM8250) 或相近小米设备为模板创建 dagu 配置
3. 注入 dagu DTB、内存映射、屏幕 2560×1600 参数
4. fastboot boot boot-dagu.img → 目标：看到 Renegade Logo 或 UEFI Shell
5. 验证 USB OTG、SimpleFb 显示、Mass Storage Mode
```

### Phase B — Windows 部署

两种社区公认安装路径（[Renegade Install Guide](https://renegade-project.tech/en/install)）：

| 方法 | 适用条件 | 工具 |
|------|----------|------|
| **Mass Storage Mode** | UEFI 菜单中有 Mass Storage | DISM / Dism++ 部署镜像；DriverUpdater 离线灌驱动 |
| **Windows PE 启动** | Mass Storage 不可用或卡死 | 自定义 PE，向 boot.wim 注入驱动后再安装 |

**Windows 版本建议：**

- SM8250 支持 ARMv8.1 atomics，理论上可使用较新的 Win11 ARM64 构建（不像 SD835 被锁死在 22621–22623）
- 实际版本应以 **驱动包测试通过** 为准；nabu 社区已有 Win11 24H2 GPT 修复经验，dagu 移植时应一并验证
- 安装后通常需开启 **Test Signing**（测试签名）以加载社区修改版驱动

### Phase C — 驱动与 ACPI

**驱动来源（社区方案，非 OEM 官方）：**

1. [WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers) — 从高通 WinARM 笔记本提取的二进制，按设备代号 `extract.ps1 dagu` 解包
2. [DriverUpdater](https://github.com/WOA-Project/DriverUpdater) — 对已有 Windows 分区离线更新驱动
3. 参考 SM8250 手机项目（如 Mi 10 系列社区 port）的 INF/QCDX 补丁

**ACPI：**

- Windows on ARM **强依赖** UEFI 提供的 ACPI 表描述硬件
- 可 fork [Silicium-ACPI](https://github.com/Project-Silicium/Silicium-ACPI) 中 Cedros (SM8250) 表项，再按 dagu 外设（触控 IC、音频、Wi-Fi）修改
- 不可直接套用 WoA 笔记本 DSDT，否则 QCDX 等驱动易 BSOD

**GPU (Adreno 650) 现实预期：**

- 社区路径：WOA-Drivers 中的 Qualcomm WDDM 二进制 + 设备专用 INF 修改（同代 Adreno 650 可参考 SM8250 手机 port）
- **不适用** 2025 年底高通为 **Snapdragon X Elite** 推出的 UGD 可下载驱动模型（仅 X 系列 PC 芯片）
- Turnip/Mesa 在 WoA 上仍为实验性质，不作为主线
- 早期 bring-up 可接受软件渲染，目标为 DWM 2D 合成 → 基础 3D

### Phase D — 平板特有功能

| 功能 | nabu 经验 | dagu 注意点 |
|------|-----------|-------------|
| 触控 | NovaTek NT36523 驱动已适配 | dagu 触控 IC 可能不同，需硬件清单确认 |
| 屏幕 | 2560×1600 @ 120Hz | 同分辨率，Panel/DSI 初始化可能不同 |
| 音频 | WCD938x 系列 | 需 ACPI + ADSP 固件路径 |
| Wi-Fi/BT | QCA 系列 | dagu 为 Wi-Fi 6，芯片型号待 dump 确认 |
| USB-C DP | nabu 仅 USB 2.0 | **dagu 支持 USB 3.2 Gen1 + DP**，理论上 WoA 外接显示器潜力更好 |
| 传感器/亮度/旋转 | 社区驱动 + ACPI _HID | 平板日常体验关键路径 |

---

## 4. 方案选型矩阵

| 方案 | 成熟度 (dagu) | Windows 可行性 | 开发量 | 推荐 |
|------|---------------|----------------|--------|------|
| edk2-msm 新 port | 中（SoC 有、设备无） | 中（需完整驱动链） | 高 | **首选** |
| Mu-Silicium Cedros port | 中低 | 中 | 很高 | 备选 |
| 直接套用 nabu 固件/驱动 | 不可行（SoC 不同） | 否 | — | ❌ |
| 仅 Linux UEFI 引导 | 较高 | 不适用 | 中 | 可作为 UEFI 调试里程碑 |

---

## 5. 推荐仓库清单

### 必读

- [edk2-porting/edk2-msm](https://github.com/edk2-porting/edk2-msm) — UEFI 固件
- [renegade-project.tech](https://renegade-project.tech/en/install) — 安装与移植文档
- [erdilS/Port-Windows-11-Xiaomi-Pad-5](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5) — 平板 WoA 工程模板
- [edk2-porting/WOA-Drivers](https://github.com/edk2-porting/WOA-Drivers) — 驱动二进制
- [WOA-Project/DriverUpdater](https://github.com/WOA-Project/DriverUpdater) — 离线驱动更新

### 参考

- [Project-Silicium/Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium) — 新一代 UEFI
- [Project-Silicium/Silicium-ACPI](https://github.com/Project-Silicium/Silicium-ACPI) — ACPI 源码
- [edk2-msm Issue #300](https://github.com/edk2-porting/edk2-msm/issues/300) — SM8250 讨论
- [Renegade 游戏/应用测试表](https://docs.google.com/spreadsheets/d/1XYuoySgYQE0HL573sA-0RGMX7I4lt5rWJuQ8Z8yRJNY/edit) — 软件兼容性
- [Renegade Doc — SM8250](https://renegade-doc.readthedocs.io/en/latest/devices/sm8250/) — SoC 文档（内容较少，待社区补充）

### 硬件信息

- [Xiaomi Kernel OpenSource (cepheus/sm8250)](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/tree/cepheus-r-oss) — 设备树/驱动参考（Mi 10 系列，同 SM8250）

---

## 6. 本项目建议路线图（基于调研修订）

- [x] **调研社区方案**（本文档）
- [x] **Phase 0 — 硬件摸底（源码侧）**
  - [x] 分区表 / `/proc/iomem` / 活 DTB（Device Tree Blob，设备树二进制）已在 `dumps/`；对照见 [dagu-woa-linux-source-map.md](dagu-woa-linux-source-map.md)
  - [x] 触控 Himax HX83121、Wi-Fi QCA6390、音频 CS35L41 已由 Linux 总表确认
  - [x] Bootloader 解锁与 EDL 救砖路径已有文档
- [ ] **Phase 1 — UEFI (edk2-msm)**
  - [x] 创建 `dagu` 设备配置；内存映射 / ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）/ 活 FDT（Flattened Device Tree，扁平设备树）已按 Linux 补齐（不刷机）
  - [x] 本机编译 `boot-dagu.img`（`build-dagu-uefi.sh`，GCC5；**未** flash / **未** `fastboot boot`）
  - [ ] fastboot 链式引导 → UEFI Shell / SimpleFb（**尚未做**）
  - [x] Mass Storage Mode **已放弃**（改 WinPE）
- [ ] **Phase 2 — Windows bring-up**
  - [ ] 参考 nabu 流程改造 GPT 分区
  - [ ] PE 方式部署 Win11 ARM64（不走 LSMS）
  - [ ] WOA-Drivers extract + DriverUpdater 灌入基础驱动
- [ ] **Phase 3 — ACPI 与外设**
  - [x] dagu ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）源码：PEP（Power Engine Plugin，电源引擎插件）/ UFS（Universal Flash Storage，通用闪存）/ GPU（Graphics Processing Unit，图形处理器）/ Himax / Wi‑Fi / 蓝牙 / USB（Universal Serial Bus，通用串行总线）/ 音频 / 键盘 / 电池 / 亮度 / 霍尔 / SLPI（Sensor Low Power Island，传感器低功耗岛）/ 热 / Venus / 笔 / Type-C（USB Type-C，USB C 型接口）/ 马达（未上板；相机不进表）
  - [ ] 触控真正出点、Wi‑Fi、音频、USB（Universal Serial Bus，通用串行总线）主机口（板上）
- [ ] **Phase 4 — GPU 与体验**
  - [ ] Adreno 650 WDDM 社区驱动适配
  - [ ] 亮度、旋转、休眠；双系统切换工具
- [ ] **Phase 5 — 文档化**
  - [ ] 发布 dagu 安装指南（对标 erdilS nabu 指南结构）

---

## 7. 风险与预期管理

1. **SM8250 Windows 生态弱于 SM8150** — 这是调研中最一致的社区结论，需有长期 bring-up 预期。
2. **ACPI 错误 = BSOD** — 应小步迭代，每加一个设备节点就测试启动。
3. **分区操作不可逆风险** — 必须备份默认分区标签；参考 nabu 社区因 partition 操作丢 userdata 的案例。
4. **驱动法律与签名** — WOA-Drivers 含 Qualcomm 二进制，需遵守仓库 EULA；社区驱动通常需测试签名模式。
5. **高通 UGD 驱动不适用于本机** — 2025 年 11 月发布的可下载 GPU 驱动针对 Snapdragon X PC 平台，不能套用到 SM8250 平板。

---

## 8. 调研来源

- [Renegade Project — Devices / Install / Porting / FAQ](https://renegade-project.tech/)
- [Xiaomi Pad 5 (nabu) — Renegade Device Page](https://renegade-project.tech/en/devices/xiaomi/nabu)
- [erdilS/Port-Windows-11-Xiaomi-Pad-5](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5)
- [edk2-msm Issue #300 — SM8250 支持讨论](https://github.com/edk2-porting/edk2-msm/issues/300)
- [Project-Silicium/Mu-Silicium Releases](https://github.com/Project-Silicium/Mu-Silicium/releases)
- [Qualcomm Windows on Snapdragon 性能更新 (2025-11)](https://www.qualcomm.com/news/onq/2025/11/windows-on-snapdragon-performance-boosts) — 仅适用于 X 系列
