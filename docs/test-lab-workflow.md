# 可恢复测试实验室（Test Lab）

> 目标：**UEFI 实验可回滚、失败可查日志、一条命令救砖。**

---

## 1. 设计原则

| 层级 | 策略 |
|------|------|
| **L0 预防** | 调试期只用 `fastboot boot`，**不** `fastboot flash boot` |
| **L1 快速恢复** | 链式引导失败 → `lab.ps1 recover`（reboot 回 Android） |
| **L2 分区恢复** | 若误 flash boot → 从 Golden 备份 `restore-boot` / `restore-all` |
| **L3 硬救砖** | fastboot 无响应 → EDL 线刷（`lab.ps1 recover edl`） |

---

## 2. 目录结构

```
test-lab.json                 # 配置（分区列表、镜像路径）
backups/golden/               # Golden 备份（gitignore）
  20260719-120000/
    boot_a.img boot_b.img ...
    manifest.json
    fastboot-getvar-all.txt
  latest.txt                  # 指向最新备份
logs/test-lab/sessions/       # 每次测试/恢复会话日志
  20260719-120500-uefi-boot/
    manifest.json
    fastboot-getvar-all.txt
    fastboot-boot.log
tools/test-lab/
  lab.ps1                     # 统一入口
  backup-golden.ps1
  recover.ps1
  test-uefi-boot.ps1
```

---

## 3. 一次性 Setup

```powershell
cd E:\Projects\xiaomi-pad870-win11-arm

# 1. 平板进 fastboot（关机 + 电源 + 音量下）
.\tools\test-lab\lab.ps1 status

# 2. 黄金备份（强烈建议，在第一次 UEFI 测试前）
.\tools\test-lab\lab.ps1 backup

# 3. 确认 boot-dagu 镜像存在
Test-Path artifacts\boot-dagu-latest.img
```

---

## 4. 日常自动化流程

```powershell
# 自动化 UEFI 链式引导 + 全量日志
.\tools\test-lab\lab.ps1 test-uefi

# 失败时自动 reboot 回 Android
.\tools\test-lab\test-uefi-boot.ps1 -AutoRecover

# 查看最近一次日志
.\tools\test-lab\lab.ps1 logs
```

### 测试时你会看到什么

1. PC 端记录 `fastboot getvar all` 快照  
2. 执行 `fastboot boot boot-dagu-latest.img`  
3. 等待 30s 观察平板（Logo / 黑屏 / UEFI）  
4. 日志写入 `logs/test-lab/sessions/<timestamp>-uefi-boot/`

---

## 5. 恢复命令（由轻到重）

```powershell
# 大多数情况：链式引导后卡住 / 黑屏
.\tools\test-lab\lab.ps1 recover

# 当前 slot boot 损坏，切换 A/B
.\tools\test-lab\lab.ps1 recover slot-other

# 误 flash 了 boot，从 golden 恢复当前 slot
.\tools\test-lab\lab.ps1 recover restore-boot

# 恢复所有已 fetch 成功的分区
.\tools\test-lab\lab.ps1 recover restore-all

# fastboot 完全无响应
.\tools\test-lab\lab.ps1 recover edl
```

---

## 6. 失败日志在哪

| 场景 | 路径 |
|------|------|
| 最近一次 UEFI 测试 | `logs/test-lab/sessions/<最新目录>/` |
| fastboot 输出 | `fastboot-boot.log` / `fastboot-getvar-all.txt` |
| 恢复操作 | `*-recover-*/manifest.json` |
| UEFI 编译失败 | `./tools/build-dagu-uefi.sh` 终端输出 |

```powershell
.\tools\test-lab\lab.ps1 logs
explorer logs\test-lab\sessions
```

---

## 7. 与 WoA 调试阶段的关系

```
[Golden backup]  →  lab.ps1 test-uefi  →  观察
                         ↓ 失败
                   lab.ps1 recover (quick)
                         ↓ 仍无法进 Android
                   recover restore-boot
                         ↓ fastboot 死
                   recover edl → Mi Flash 线刷
```

实验记录请同步到 `docs/hardware-debug-workflow.md` 的实验日志模板。

---

## 8. 配置项（test-lab.json）

| 字段 | 说明 |
|------|------|
| `partitions_to_backup` | Golden 备份分区列表 |
| `uefi_test_image` | 默认 UEFI 测试镜像 |
| `post_test_auto_reboot_android` | 测试后提示 |
| `mi_flash_rom_path` | 线刷包路径（EDL 用） |

---

**Status：** Test Lab 脚本已就绪；首次 UEFI 实测前请执行 `lab.ps1 backup`。
