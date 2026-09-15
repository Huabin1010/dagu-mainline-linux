# dagu USB Mass Storage 阻塞问题 — 完整技术分析

> **2026-08：该路径已放弃。** 自编 LSMS / MSC DTB / 进内核前释放 USB 的 hack 已从固件移除，菜单不再提供 USB Mass Storage。下文保留为当时实验记录，不要再按文中命令重编 LSMS。
>
> 设备：Xiaomi Pad 5 Pro 12.4（`dagu`，SM8250-AC）  
> 日期：2026-07-19  
> 当时镜像指纹：`KEYFIX-16 NO-FB`  
> 当时状态：**UEFI 交互菜单可用；Mass Storage 路径未打通** → **现已拆除**

---

## 0. 先回答你的两个问题

### 0.1 「进去后过一会就黑屏」说明什么？

在 `KEYFIX-16`（已关闭 LSMS 内核 framebuffer）下：

| 现象 | 含义 |
|------|------|
| 选 Mass Storage 后屏幕变黑 | **预期**：内核不再写屏；UEFI GOP 在 `ExitBootServices` 后失效 |
| PC 始终看不到 U 盘 | **真实失败点**：USB gadget / UFS / 内核 early boot 未成功枚举 |
| 过一会自动回 Android | 内核 panic / oops / 高通 watchdog → ABL 重启进原系统 |

所以：**黑屏本身不是新 bug**；它只证明「显示栈已经交出去了」。真正坏的是 **Linux MSC 在无调试通道的情况下悄悄死掉，且没有把存储暴露给 PC**。

### 0.2 我们现在遇到的最大问题在哪方面？

**一句话：最大问题不在 UEFI 菜单/按键，而在「UEFI → ExitBootServices → 专用 Linux MSC 内核」这条链上的 SM8250/dagu 平台 bring-up，且几乎没有可观测性。**

分层看：

```
┌─────────────────────────────────────────────────────────────┐
│  L0  目标：PC 通过 Type-C 看到 UFS 分区（装 Win / 改分区）   │
└────────────────────────────┬────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────┐
│  L1  UEFI（edk2-msm / dagu port）                            │
│      ✅ 已基本可用：显示、音量/电源键、BootManager 菜单       │
└────────────────────────────┬────────────────────────────────┘
                             │ 选 “USB Mass Storage”
┌────────────────────────────▼────────────────────────────────┐
│  L2  交接：Install gFdtTableGuid + 释放 UEFI USB + EBS       │
│      ⚠️ 已反复修补，但仍无法证明交接后内核活着               │
└────────────────────────────┬────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────┐
│  L3  LinuxSimpleMassStorage（自编 5.15.69 SM8250-minimal）   │
│      ❌ 最大阻塞层：early boot / USB gadget / Type-C / UFS   │
│      ❌ 无串口、无 printk 到屏幕 → 只能看到黑屏/重启         │
└────────────────────────────┬────────────────────────────────┘
                             │ 成功时才有
┌────────────────────────────▼────────────────────────────────┐
│  L4  PC 枚举 USB Mass Storage / SCSI UFS 分区                │
│      ❌ 从未在 dagu 上观察到                                  │
└─────────────────────────────────────────────────────────────┘
```

**最大问题所属方面：L3 平台内核 bring-up（USB DWC3 gadget + Type-C/PMIC + 时钟/互联 + 可选 UFS），外加 L3 的可观测性为零。**  
不是「再改一处菜单字符串」能解决的问题。

---

## 1. 我们为什么要做 Mass Storage？

Renegade / edk2-msm 生态里，装 Windows 的常见第一步是：

1. `fastboot boot` 进 UEFI  
2. 启动 **LinuxSimpleMassStorage（LSMS）**  
3. 平板以 USB 大容量设备形式出现在 PC 上  
4. 在 PC 上用 DiskGenius / `diskpart` 等改 GPT、写入 ESP / Windows  

对 `dagu` 而言，这是通往 Win11 ARM 的**安装介质入口**之一。  
UEFI Shell / Simple Init 能用，**不能替代**「把整盘 UFS 暴露给 PC」这一能力（除非改用 Android 下 `adb`/`dd`、或 WinPE 其它路径）。

---

## 2. 当前已证明「能工作」的部分（不要再怀疑这些）

| 能力 | 证据 | 结论 |
|------|------|------|
| `fastboot boot` 链式引导 | 多次 OKAY，未 flash boot 分区 | 安全可回 Android |
| SimpleFb + 旋转/缩放 | 菜单文字清晰、全屏可用 | UEFI 显示 OK |
| 音量 ± / 电源键 | 可导航、可确认 | ButtonsDxe.dagu + BootManagerMenu OK |
| 交互式 BootManager 菜单 | 标题指纹 `KEYFIX-*` | BDS 路径 OK |
| 注册 Mass Storage 启动项 | 菜单可见 “USB Mass Storage” | FV 内 `.efi` 被 LoadImage |
| FDT 配置表安装 | PlatformBm 安装 `gFdtTableGuid` | EFI stub 有 DTB 可读 |

**结论：Phase-1 UEFI bring-up 的「能进菜单、能选东西」已经过关。卡点在菜单之后。**

---

## 3. Mass Storage 启动时实际发生的时序

```
用户选 USB Mass Storage
        │
        ▼
BootManagerMenu / PlatformBm
  ├─ PlatformDaguEnsureFdtConfigurationTable()
  │    ├─ 从 FV 取 sm8250-generic-msd.dtb（优先，mainline qcom,dwc3）
  │    ├─ 扩展 FDT、关 MDSS/GPU、注入/拷贝 /memory
  │    └─ InstallConfigurationTable(gFdtTableGuid)
  ├─ 释放 UEFI UsbFn / Usb2Hc（DisconnectController）
  └─ EfiBootManagerBoot(LinuxSimpleMassStorage.efi)
        │
        ▼
Linux EFI stub（Image 即 .efi）
  ├─ 读取 gFdtTableGuid
  ├─ ExitBootServices()     ← 屏幕上曾出现 “EFI stub: Exiting boot services...”
  ├─ 安装虚拟地址映射
  └─ 跳转内核
        │
        ▼
Linux 5.15.69+ (sm8250-minimal)
  ├─ 解析 DTB、时钟、RPMh、pinctrl、interconnect
  ├─ 探测 DWC3 + QUSB/QMP PHY + Type-C
  ├─ 挂 UFS，configfs Mass Storage
  └─ 等待 PC 枚举
        │
        ▼
失败时：oops/panic/watchdog → 黑屏一段时间 → 重启进 Android
成功时：PC 设备管理器出现磁盘（dagu 上尚未发生）
```

---

## 4. 根因链：我们修过什么、各自解决了什么

每一版 KEYFIX 都修了**真实 bug**，但都只是通往 L3 的台阶，不是终点。

| 版本 | 修的问题 | 现象变化 | 是否解决 MSC |
|------|----------|----------|--------------|
| KEYFIX-8 | 缺 `gFdtTableGuid` | `[Bds] Unable to boot` → 能 LoadImage | 否 |
| KEYFIX-9/10 | TestLab 1MiB ramdisk OOR 抢内存 | 去掉 TestLab | 否 |
| KEYFIX-11 | USB 角色 / CAF DTB HS-peripheral | 仍花屏重启 | 否 |
| KEYFIX-12 | `/memory` 被 GetMemoryMap 写坏毒化 EBS | 仍挂 | 否 |
| KEYFIX-13 | CAF `qcom,dwc-usb3-msm` ≠ 内核 `qcom,dwc3`；改用 mainline elish DTB | 仍立刻花屏 | 否 |
| KEYFIX-14 | mainline `memory@` size=0；MDSS 开着导致花屏 | 仍挂 | 否 |
| KEYFIX-15 | **自编** SM8250 LSMS + `sm8250-generic-msd.dtb` | 红竖线（efifb stride） | 否 |
| KEYFIX-16 | 关掉 LSMS `CONFIG_FB` | **黑屏**（显示安静），仍无 U 盘 | 否 |

### 4.1 已钉死的技术事实

1. **CAF `dagu.dtb` 不能直接喂给 mainline LSMS**  
   - CAF USB：`qcom,dwc-usb3-msm`  
   - LSMS / mainline：`qcom,dwc3` / `qcom,sm8250-dwc3`  
   - 绑定不上 → EBS 后立刻死

2. **mainline 树里没有 `dagu` DTS**  
   - 最接近：`sm8250-xiaomi-elish`（同 SoC，11" Pad 5 Pro，OLED）  
   - dagu：12.4" **L81A LCD**，面板/保留内存/部分供电可能不同  
   - 我们生成的是 **借来的** `sm8250-generic-msd.dtb`，不是「为 dagu 验证过的板级 DT」

3. **上游 LSMS 官方 config 只有 sdm845 / msm8998 / qemu**  
   - 没有 sm8250  
   - 仓库自带 EFI 是别人编的 6.1 multi-SoC 二进制  
   - 我们已自编：`tools/lsms/sm8250-minimal.config` → 5.15.69 + SM8250 时钟/pinctrl/icc/DWC3_QCOM

4. **成功机型的惯例是 `*-generic-msd.dtb`**  
   - 例：`sdm845-generic-msd.dtb`、`sm7125-generic-msd.dtb`  
   - SM8250 小米机（alioth/elish/dagu）长期只有 CAF/设备 DTB，**没有官方 generic-msd**

5. **花屏 / 红竖线 / 黑屏 的显示语义不同**

| 屏幕 | 常见原因 |
|------|----------|
| 花屏/彩条 | 内核或驱动乱写 MDSS / 错误 panel |
| 一排红色竖线 | efifb/simplefb 用横屏 GOP 尺寸写竖屏物理 FB（stride 错位） |
| 黑屏（KEYFIX-16） | 内核不再碰 FB；**不能**据此判断 MSC 成功 |
| 重启回 Android | panic / watchdog（`PANIC_TIMEOUT` 等） |

---

## 5. 当前最大阻塞 — 展开说明

### 5.1 核心矛盾

我们需要同时满足：

1. **内核**能在 SM8250 上跑过 early boot（时钟、RPMh、PDC、SMMU、CPU）  
2. **DTB** 与 dagu 板级硬件足够接近（尤其 USB PHY、Type-C、VBUS、UFS）  
3. **UEFI 释放** DWC3 后，内核能以 **peripheral / gadget** 模式重新初始化  
4. **PC 侧**能看到 configfs mass-storage 功能  

其中任意一环失败，表现都几乎一样：**黑屏 → 一会回 Android，PC 无盘**。  
在没有日志时，这几环**无法区分**。

### 5.2 为什么「自编 LSMS + generic-msd」仍不够

| 项 | 现状 | 风险 |
|----|------|------|
| 内核版本 | 5.15.69（LSMS submodule） | 比 stock 6.1 旧；SM8250 USB/Type-C 边角可能仍缺 |
| DTB 来源 | elish mainline 裁剪 | 不是 dagu；Type-C/PMIC/UFS 供电节点可能错或不全 |
| Type-C | `TYPEC_QCOM_PMIC` + `UCSI_ACPI` | 平板走 DT PMIC 路径；ACPI UCSI 在无 ACPI OS 时可能无用 |
| 调试 | `# CONFIG_PRINTK`（minimal）且无 FB console | **完全瞎** |
| 显示 | 已关 FB | 避免红竖线，但失去唯一「穷人调试器」 |

### 5.3 可观测性真空（第二大问题，几乎与第一并列）

平板在 UEFI 之后：

- 没有可用 TTL/UART 接到 PC（或未接线）  
- LSMS minimal 关闭了 printk / TTY  
- KEYFIX-16 关闭了 FB  
- TestLab USB 调试桥因 OOR 已硬禁用  

因此迭代方式被迫变成：

> 改配置 → 编镜像 → fastboot boot → 盯屏幕/盯 PC → 猜  

这在 L3 上效率极低，也是 KEYFIX-8～16 看起来「一直失败」的方法论原因。

---

## 6. 仓库内关键路径（便于对照）

| 用途 | 路径 |
|------|------|
| 启动菜单 / FDT / USB 释放 | `port/dagu/Platform/RenegadePkg/Library/PlatformBootManagerLib/PlatformBm.c` |
| 弹窗菜单 | `port/dagu/Common/edk2/.../BootManagerMenuApp/` |
| FDF 嵌入 DTB | `port/dagu/Platform/Xiaomi/sm8250/dagu.fdf.inc` → `sm8250-generic-msd.dtb` |
| DSC 开关 | `port/dagu/Platform/Xiaomi/sm8250/dagu.dsc` → `-DENABLE_LINUX_SIMPLE_MASS_STORAGE` |
| LSMS 配置 | `tools/lsms/sm8250-minimal.config` |
| LSMS 构建 | `tools/lsms/build-lsms.sh` → 安装到 `edk2-msm/.../LinuxSimpleMassStorage.efi` |
| MSD DTB 构建 | `tools/build-sm8250-generic-msd-dtb.sh` |
| 一键编译 | `tools/build-dagu-uefi.sh` |
| 链式引导 | `tools/boot-dagu.ps1`（Windows）或 `fastboot boot artifacts/boot-dagu-latest.img` |
| 门禁 | `tools/test-lab/test-dagu-boot-gates.sh` |
| stock EFI 备份 | `.../LinuxSimpleMassStorage.efi.stock-backup` |

构建缓存：

- LSMS 源码：`~/.cache/dagu-lsms/linux-simple-mass-storage`  
- mainline DTS：`~/.cache/dagu-mainline-dtb/linux`

---

## 7. 与「装 Windows」总目标的关系

```
解锁 BL ✅
    → UEFI 能起、菜单能用 ✅   ← 你们现在在这里（L1 完成）
        → 把分区暴露给 PC / 或其它安装通道  ❌  ← 当前最大墙
            → 写 ESP + Windows
                → ACPI / 驱动 / GPU …
```

Mass Storage **不是** Win11 本身，只是安装通道。  
若 MSC 长期打不通，应并行评估：

| 备选通道 | 说明 | 代价 |
|----------|------|------|
| Android 下 adb/fastboot + 用户空间写分区 | 不依赖 LSMS | 需解锁+小心分区表；部分操作仍要自定义 |
| Simple Init / 其它 Linux 工具链 | 可能有不同 USB 栈 | 仍要 DT/驱动 |
| WinPE 从其它介质引导 | 绕过「平板当 U 盘」 | 需要能启动的 WinPE 镜像与驱动 |
| 有线串口 / 高通调试口 | 打开 L3 黑盒 | 硬件/焊接或专用线 |

---

## 8. 建议的下一步（按性价比排序）

### P0 — 先恢复「能看见内核死在哪」（否则继续盲猜）— **KEYFIX-17 已落地**

1. **`sm8250-debug.config`**：`PRINTK` + **物理** `simple-framebuffer`（1600×2560 @ `0x9c000000`，**不用** FB_EFI）+ `PSTORE_RAM`  
2. 选 Mass Storage 后：**盯屏幕**是否出现内核英文日志（像看 `docker logs`）  
3. 若仍重启回 Android：立刻跑 `.\tools\pull-msc-logs.ps1` 捞 `/sys/fs/pstore`  
4. PC 侧可并行：`USBPcap` / 设备管理器，看是否出现过瞬态未知设备

### P1 — 对准 USB gadget 最小闭环

1. 对照 mainline `sm8250.dtsi` + elish DT 的 `usb@a6f8800`、qusb2、qmp、pm8150b Type-C  
2. 用 CAF `dagu` DT 反查：同一物理 USB 的时钟、复位、电源、phy handle  
3. 确认 UEFI 释放后 DWC3 寄存器/时钟未被关机（必要时在 EBS 回调里保持 USB GDSC）  
4. 先追求 PC 看到 **任意** gadget（甚至只是 `CDC` / 空 mass-storage），再挂 UFS

### P2 — DTB 从「借 elish」进化到「dagu-msd」

1. 以 `sm8250-generic-msd.dtb` 为底  
2. 从 stock `dagu.dtb` 移植：UFS、USB PHY、PMIC Type-C、reserved-memory  
3. 保持 mainline compatible（`qcom,dwc3`），不要回到 CAF `dwc-usb3-msm`  
4. 产出命名：`dagu-msd.dtb`，替代纯 elish 裁剪版

### P3 — 内核版本策略

1. 评估把 LSMS kernel submodule 升到 **6.1.x**（对齐曾内置的 j0sh1x 二进制）  
2. 或维护一份「仅 gadget+UFS」的 out-of-tree 最小内核，减少无关驱动踩雷  

### P4 — 若 1～2 周仍无盘：切换安装策略

明确把 MSC 标为 **blocked**，改主路径为 Android/adb 分区手术或 WinPE，避免无限 KEYFIX。

---

## 9. 验收标准（以后怎样才算「MSC 打通」）

必须**同时**满足：

1. 菜单指纹为约定 `KEYFIX-*`（证明镜像正确）  
2. 选 Mass Storage 后 **≥ 60s 不自动回 Android**  
3. Windows 设备管理器或「磁盘管理」出现新磁盘/卷（即使未分配）  
4. 可选：能读到 GPT 或至少一个分区  

仅「黑屏不花屏」**不算**成功。

---

## 10. 给决策者的结论

| 问题 | 答案 |
|------|------|
| UEFI 是不是废了？ | **不是。** 菜单/按键/显示已过关。 |
| Mass Storage 是不是差一点？ | **不是差一点配置。** 是 SM8250/dagu 上 MSC 内核+DT 未验证闭环。 |
| 最大问题在哪方面？ | **L3：EBS 后的 Linux USB gadget / 板级 DT bring-up + 零可观测性。** |
| 黑屏是不是倒退？ | KEYFIX-16 的黑屏是「不再用错误 FB 写屏」；失败本质未变。 |
| 下一步最该做什么？ | **先开调试通道（printk/串口/USB 抓包），再改 USB/DT；不要继续无日志 KEYFIX。** |

---

## 11. 附录：相关命令

```powershell
# Windows：仅 boot 已有 artifacts（需设备可进 fastboot）
.\tools\boot-dagu.ps1
```

```bash
# Linux：强制重编 SM8250 LSMS 并编译 UEFI
FORCE_LSMS_REBUILD=1 ./tools/lsms/build-lsms.sh
./tools/build-sm8250-generic-msd-dtb.sh
./tools/build-dagu-uefi.sh

# 门禁
./tools/test-lab/test-dagu-boot-gates.sh
fastboot boot artifacts/boot-dagu-latest.img
```

指纹核对：菜单标题必须看到 `KEYFIX-16 NO-FB`（或后续约定指纹），否则测的是旧镜像。

---

*本文档描述截至 KEYFIX-16 的工程结论，供后续调试与路线决策使用。随 P0 调试通道建立后，应更新第 5、8 节的「当前最大阻塞」具体到寄存器/节点级根因。*
