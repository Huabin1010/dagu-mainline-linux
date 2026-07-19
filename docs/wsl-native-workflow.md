# WSL 构建环境 bootstrap（可选）

> 本文档面向 **需要在 WSL 里编译 edk2-msm** 的场景。  
> 日常文档、adb/fastboot 等 **仍在 Windows** 做 → 见 [windows-wsl-split.md](windows-wsl-split.md)。

---

## 工作目录

```
~/projects/xiaomi-pad870-win11-arm   # WSL ext4，仅 Linux 构建用
```

通过 **git clone** 创建，**不**从 `/mnt/e` rsync。

## Bootstrap

```powershell
.\tools\bootstrap-wsl-workspace.ps1 -RepoUrl https://github.com/<you>/xiaomi-pad870-win11-arm.git
```

会自动：

1. `git clone` 项目
2. `git clone --recursive` edk2-msm
3. `git clone -b dagu-s-oss` vendor/kernel_devicetree
4. `tools/apply-dagu-port.sh`

## 编译

```bash
cd ~/projects/xiaomi-pad870-win11-arm
sudo apt install -y build-essential uuid-dev iasl git nasm python3 \
  python3-distutils gettext gcc-aarch64-linux-gnu clang llvm device-tree-compiler
./tools/build-dagu-uefi.sh
```

## 与 Windows 同步

Windows 改完 push 后，WSL 侧：

```bash
cd ~/projects/xiaomi-pad870-win11-arm && git pull && ./tools/apply-dagu-port.sh
```

Windows 仓库 **保留**，无需删除。
