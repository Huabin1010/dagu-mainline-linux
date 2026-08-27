# dagu 救砖记录 — 分区改动、9008 与降级小包

> 设备：小米平板5 Pro 12.4（`dagu`，256GB，HyperOS OS2.0.10.0.ULZCNXM）  
> 记录时间：2026-07-21  
> **结果（2026-07-21）：✅ EDL 线刷成功，设备已恢复。**  
> - 完整救砖流程：[dagu-edl-recovery-full-playbook.md](dagu-edl-recovery-full-playbook.md)  
> - 「魔改 boot」为何导致假死/9008：[why-boot-modification-caused-dead-device.md](why-boot-modification-caused-dead-device.md)

---

## 1. 我们实际改动了什么（仓库证据）

| 层级 | 是否写入 UFS 分区 | 做了什么 |
|------|-------------------|----------|
| **Android boot / super / userdata** | **否** | 实验期约定只用 `fastboot boot boot-dagu.img`，**未** `fastboot flash boot` |
| **GPT / userdata 大小** | **否（未执行）** | WoA 路线规划了参考 nabu 的 GPT 改造，但 **Mass Storage 未打通**，PC 侧未成功改盘 |
| **dtbo 分区** | **否** | DTB 改动在 UEFI 构建树内（`patch-dagu-dtb-for-msc.sh` → `dagu-msc.dtb`），随 `boot-dagu.img` **RAM 加载**，不写 dtbo |
| **UEFI / LSMS 实验** | **仅 RAM** | 多次 `fastboot boot` 自定义 UEFI + LinuxSimpleMassStorage；失败表现为黑屏、自动回 Android |
| **Bootloader 解锁** | **是（devinfo）** | 2026-07-19 解锁，`fastboot getvar unlocked` → `yes`（救砖后需再验证） |

**结论：** 本仓库 **没有** 对 UFS 做「resize super / 新建 WIN 分区」这类持久化魔改。  
若 GPT 已损坏，更可能来自：

1. **WoA 前置目标**（MSC 改 GPT）曾尝试但失败/半成品（无 PC 侧成功日志）  
2. **反复 UEFI/LSMS 链式引导** 导致 slot、metadata、misc 或启动链状态异常  
3. **救砖/刷机操作本身** 在 EDL 未完成时中断  

---

## 2. 砖机形态（救砖前）

> 已于 2026-07-21 通过 EDL 完整刷机恢复，以下为救砖前快照。

- PC 识别：**Qualcomm HS-USB QDLoader 9008 (COM20)**  
- 驱动：oem48 正常（无 Code 52）  
- **Sahara**：断电重进 EDL 后可上传 firehose ✅  
- **Firehose 刷写**：官方 loader 报 `Only nop and sig tag can be received before authentication` ❌  
  → 需要 **MiFlash + 小米账号 EDL 授权**，或 **解锁版 sm8250 firehose**

---

## 3. 降级小包是什么

路径：`D:\Download\Edge\小米平板5Pro12.4降级小包\`

| 文件/特征 | 说明 |
|-----------|------|
| `flash_all.bat` | **Fastboot 脚本**（设备能进 fastboot 时用）；**注释掉了** `flash super` |
| `super.img` | **约 270KB**（sparse 壳），不是完整系统；用于占位/重建 super 元数据 |
| `rawprogram0.xml` + `gpt_*.bin` | **EDL 写 GPT 主/备份表**（LUN0–5），这是「分区魔改后救砖」的核心 |
| `rawprogram4.xml` | 写 **xbl / abl / boot / vendor_boot / tz / hyp …** 等启动链 |
| `boot.img` 等 | 2023-04 旧版镜像（**低于** 当前 HyperOS 14） |
| `crclist.txt` | **缺失** → `flash_all.bat` 在 fastboot 下会 early fail |
| `flash_all_lock.bat` | 无（小包通常不含锁 BL 脚本） |

**适用场景：** GPT/启动链损坏、无法进 Android/fastboot，需要先 **EDL 恢复分区表 + 底层固件**，再刷完整 ROM。

**不适用：** 单独用它恢复完整 HyperOS 14（没有 8GB `super.img`）。

---

## 4. 推荐救砖顺序（不锁 BL）

### 阶段 A — 降级小包（EDL，MiFlash 选项 3）

1. 拔 USB → 长按电源 30s → 插 USB 2.0 → 确认 9008  
2. MiFlash **登录小米账号**（与解锁 BL 同账号）  
3. 选择目录：`D:\Download\Edge\小米平板5Pro12.4降级小包`  
4. **选项 3**，确认 **不要** 任何带 lock 的脚本  
5. 若弹出 EDL 授权 → 同意后再刷  
6. 预期：GPT + xbl/abl/boot 等恢复；**super 仅为壳**，系统仍不完整  

### 阶段 B — 完整 HyperOS（EDL，同一 Mi 账号）

1. 再次进 9008（或若已能进 fastboot 也可用完整包 fastboot 刷）  
2. ROM：`D:\rom\dagu-recovery\dagu_images_OS2.0.10.0.ULZCNXM\...\dagu_images_OS2.0.10.0.ULZCNXM_14.0`  
3. `flash_all.bat`（**已禁用** `flash_all_lock.bat`）  
4. 刷完验证：`fastboot getvar unlocked` → 应为 **`yes`**

### 备选 — Qualcomm 直刷（需先过授权）

```powershell
# 阶段 A
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\Projects\xiaomi-pad870-win11-arm\tools\flash-dagu-edl.ps1" `
  -RomDir "D:\Download\Edge\小米平板5Pro12.4降级小包"

# 阶段 B（换完整 ROM 目录再跑一遍）
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\Projects\xiaomi-pad870-win11-arm\tools\flash-dagu-edl.ps1"
```

---

## 5. 2026-07-21 实测（降级小包）

| 步骤 | 结果 |
|------|------|
| 包结构 / dagu 分区 XML | ✅ 与 SM8250 UFS 6-LUN 布局一致 |
| `super.img` 大小 | 270404 B（小包） vs 8605591056 B（完整 ROM） |
| Sahara + 小包 firehose | 在 **新鲜 EDL** 下与官方包相同（需授权） |
| fh_loader configure | ❌ `authentication`（与完整 ROM 相同，非包损坏） |

**结论：降级小包可用，但当前瓶颈仍是 EDL 授权，不是包选错。**

---

## 6. EDL 授权与 SM8250 解锁 firehose（2026-07-21 核实）

### 6.1 官方 stock firehose **确实要授权**

以下路径的 **原厂** `prog_ufs_firehose_sm8250_ddr_5.elf` 均会在 configure 阶段失败：

- 完整 HyperOS ROM `images\`
- 降级小包 `images\`
- MiFlash 状态：`edl authentication` → `authentication` / `Only nop and sig tag...`

这是小米 **EDL Auth（SLA）**：firehose 跑起来后，必须收到合法 **sig** 才允许 program/read/erase。  
与「ROM 版本新旧」无关，**换官方包不能绕过**。

### 6.2 dagu 可用的社区方案（同 SM8250 + DDR5 UFS）

dagu 与 **Poco F3 / 红米 K40** 同属 **SM8250**，线刷包内 firehose 文件名一致：

`prog_ufs_firehose_sm8250_ddr_5.elf`

社区已验证可用的资源（需自行从 XDA 下载，**不要**从不明网盘买「解锁服务」）：

| 资源 | 链接 | 说明 |
|------|------|------|
| 解锁 firehose 使用指南 | [XDA: unlocked firehose guide](https://xdaforums.com/t/guide-how-to-edl-flash-using-an-unlocked-firehose-loader-xiaomi.4720330/) | 重命名后放入 ROM `images\` |
| loader + sig 附件 | [XDA attachment loader-and-sig.zip](https://xdaforums.com/attachments/loader-and-sig-zip.6214576/) | Poco F3 用，dagu 可试同名替换 |
| Patched MiFlash（SD870） | [XDA: Patched MiFlash Poco F3](https://xdaforums.com/t/patched-miflash-for-poco-f3-edl-flash-no-internet-required.4723044/) | 无需登录；先报 auth 等 ~30s 再自动刷 |
| Renate EDL + sig.bin | [XDA: Complete EDL Access](https://xdaforums.com/t/complete-edl-access-thanks-to-renate.4729287/) | 命令行 `edl /w sig.bin` 跳过授权 |

**推荐顺序（成功率最高）：**

1. 下载 **Patched MiFlash for Poco F3** + **loader-and-sig.zip**
2. 备份 ROM `images\` 里两个 stock firehose → 移到别处
3. 把解锁 loader **重命名**为 `prog_ufs_firehose_sm8250_ddr_5.elf` 放进 `images\`
4. 新鲜 EDL（拔线 → 长按电源 30s → USB 2.0）
5. Patched MiFlash 选 ROM → 刷机 → 若先出现 auth 错误 **等 30 秒别拔线**
6. 刷完再 `fastboot getvar unlocked`

**注意：** 不要用普通 MiFlash + stock firehose 反复试；HyperOS 账号 EDL 授权对很多国行账号不可用。

---

## 7. 救砖后 WoA 实验纪律（避免再砖）

1. **只用** `fastboot boot`，禁止 `fastboot flash boot` 直到有 golden 备份  
2. **禁止** 在 MSC 未稳定前改 GPT  
3. DTB/UEFI 改动保持在 `boot-dagu.img` 构建链，不写 dtbo  
4. 任何 EDL 刷机前确认：`flash_all_lock.bat` 已禁用  

相关：[hardware-debug-workflow.md](hardware-debug-workflow.md) · [mass-storage-blocker-analysis.md](mass-storage-blocker-analysis.md)
