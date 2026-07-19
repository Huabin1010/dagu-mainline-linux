# Windows + WSL 分工说明

> **原则：** 不需要 Linux 的继续在 Windows 做；**只有**必须 WSL/Linux 的才去 WSL 原生目录做。  
> **不是**整仓迁移，**不是** rsync `/mnt` 复制，**不用**删掉 `E:\Projects\...`。

---

## 1. 在哪里做什么

| 任务 | 在哪里做 | 说明 |
|------|----------|------|
| 写文档、改 README、硬件清单 | **Windows** `E:\Projects\...` | Cursor 正常编辑 |
| adb / fastboot、采集 dumps | **Windows** `tools\platform-tools\` | 已在此目录 |
| **可恢复 UEFI 测试** | **Windows** `tools\test-lab\lab.ps1` | Golden 备份 + recover |
| 解锁指南、方案调研 | **Windows** | 纯文档 |
| **edk2-msm 编译** `boot-dagu.img` | **WSL** `~/projects/...` | 必须 Linux + ext4 |
| apt 装 iasl/nasm/gcc 交叉链 | **WSL** | 包管理只在 Linux |
| 长时间编译、bash 脚本 | **WSL** | 通过 wsl-layer 或 WSL 终端 |

---

## 2. 两个目录的关系

```
Windows（主仓库，日常开发）
E:\Projects\xiaomi-pad870-win11-arm
  docs/  tools/  port/  README  …
        │
        │  git push / git pull（同一远程仓库）
        ▼
WSL（仅 Linux 构建用，git clone 到 ext4）
~/projects/xiaomi-pad870-win11-arm
  + edk2-msm/          ← bootstrap 时 git clone
  + vendor/            ← bootstrap 时 git clone
  + artifacts/         ← 编译产物
```

- Windows 侧：**不**在 `/mnt/e` 里跑 `./build.sh`
- WSL 侧：**不**用来改文档再手动拷回 Windows — 两边通过 **git** 同步同一仓库

---

## 3. 一次性：初始化 WSL 构建环境

Windows 仓库先推到 Git（GitHub/GitLab 等），然后：

```powershell
cd E:\Projects\xiaomi-pad870-win11-arm
# 若尚未 push：
# git add . && git commit -m "..." && git push

.\tools\bootstrap-wsl-workspace.ps1 -RepoUrl https://github.com/<you>/xiaomi-pad870-win11-arm.git -RestartLayer
```

bootstrap 会在 WSL 里 `git clone` 项目，并 clone `edk2-msm`、`vendor`，再执行 `apply-dagu-port.sh`。

---

## 4. 日常流程

### 在 Windows（默认）

- 改代码、写 `docs/`、跑 fastboot/adb
- `git commit` / `git push`

### 需要编译 UEFI 时

```powershell
# 1. 确保 WSL 侧已 pull 最新代码
.\tools\wsl-layer\layer.ps1 run "cd ~/projects/xiaomi-pad870-win11-arm && git pull"

# 2. 编译（在 WSL 工作区，不在 /mnt）
.\tools\wsl-layer\layer.ps1 run "cd ~/projects/xiaomi-pad870-win11-arm && ./tools/build-dagu-uefi.sh"
```

或在 WSL 终端：

```bash
cd ~/projects/xiaomi-pad870-win11-arm
git pull
./tools/build-dagu-uefi.sh
```

编译产物在 WSL 的 `artifacts/`，需要 fastboot 时可从 WSL 拷到 Windows 或直接用 Windows fastboot 指向 WSL 路径。

---

## 5. wsl-layer 是干什么的

从 **Windows** 遥控 **WSL 里的持久 shell**（默认 cwd = `~/projects/xiaomi-pad870-win11-arm`）：

```powershell
.\tools\wsl-layer\layer.ps1 run "uname -a"
.\tools\wsl-layer\layer.ps1 run "./tools/build-dagu-uefi.sh"
Get-Content -Wait .wsl-layer\live.log   # 看长任务实时日志
```

纯 Windows 任务 **不必** 开 wsl-layer。

---

## 6. 配置

`wsl-layer.json`：

```json
{
  "wsl_distro": "Ubuntu-22.04",
  "wsl_workspace": "~/projects/xiaomi-pad870-win11-arm",
  "initial_cwd": "~/projects/xiaomi-pad870-win11-arm"
}
```

---

## 7. 相关脚本

| 脚本 | 用途 |
|------|------|
| `tools/bootstrap-wsl-workspace.ps1` | 首次在 WSL clone 项目 + upstream |
| `tools/build-dagu-uefi.sh` | 仅在 WSL ext4 内编译 |
| `tools/wsl-layer/layer.ps1` | 从 Windows 在 WSL 里跑命令 |
| `tools/platform-tools/` | 留在 Windows 做 adb/fastboot |

---

**总结：** Windows 仓库继续当主战场；WSL 只是 **Linux 编译机**，需要时再 `git pull` + build。
