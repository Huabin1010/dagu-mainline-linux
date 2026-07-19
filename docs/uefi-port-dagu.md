# dagu UEFI 移植说明 (edk2-msm)

> 设备：小米平板5 Pro 12.4 (`dagu`, SM8250)  
> 上游：[edk2-porting/edk2-msm](https://github.com/edk2-porting/edk2-msm)

---

## 1. 本仓库已添加的内容

dagu 设备 port 跟踪在 **`port/dagu/`**（构建时打入 edk2-msm）：

| 路径 | 说明 |
|------|------|
| `port/dagu/configs/devices/dagu.conf` | 构建配置 |
| `port/dagu/Platform/Xiaomi/sm8250/dagu.dsc` | 平台 DSC（2560×1600） |
| `port/dagu/Platform/Xiaomi/sm8250/dagu.fdf.inc` | FD 片段、ACPI、DTB |
| `port/dagu/Platform/.../PlatformMemoryMapLib/` | 内存映射（**待 iomem 校验**） |
| `port/dagu/Platform/.../AcpiTables/dagu/` | DSDT 源码（**待 dagu 定制**） |
| `port/dagu/.../FdtBlob_compat/dagu.dtb` | **临时** elish.dtb，需替换 |

`edk2-msm/`、`vendor/` 由 bootstrap **git clone**，不提交到项目仓库。

---

## 2. 构建环境（WSL 原生根，git clone）

工作目录：**`~/projects/xiaomi-pad870-win11-arm`**（仅编译时用，见 [windows-wsl-split.md](windows-wsl-split.md)）

```powershell
# 项目 push 到 Git 后，在 WSL clone + 拉 upstream
.\tools\bootstrap-wsl-workspace.ps1 -RepoUrl https://github.com/<you>/xiaomi-pad870-win11-arm.git -RestartLayer
```

依赖安装（在 WSL 工作区内）：

```bash
sudo apt update
sudo apt install -y build-essential uuid-dev iasl git nasm python3 \
  python3-distutils gettext gcc-aarch64-linux-gnu clang llvm device-tree-compiler
```

---

## 3. 编译

```bash
cd ~/projects/xiaomi-pad870-win11-arm
./tools/build-dagu-uefi.sh
```

或手动：

```bash
cd edk2-msm
./build.sh -d dagu --skip-rootfs-gen
# 产物：edk2-msm/boot-dagu.img
```

复制到 `artifacts/` 便于版本管理。

---

## 4. 测试启动（链式引导，不写分区）

1. 平板关机 → **电源 + 音量下** → Fastboot
2. PC 执行：

```powershell
cd E:\Projects\xiaomi-pad870-win11-arm\tools\platform-tools
.\fastboot.exe boot ..\..\artifacts\boot-dagu-latest.img
```

3. 预期：Renegade Logo / UEFI Shell / SimpleFb 显示  
4. **不要** `fastboot flash boot`，直到 Android 双系统方案就绪

---

## 5. 已知 TODO（按优先级）

| 优先级 | 项 | 做法 |
|--------|-----|------|
| P0 | **替换 dagu.dtb** | 从 `boot.img` 提取，或 Magisk root 后 `dd` boot 分区 |
| P0 | **校验内存映射** | 对比 `/proc/iomem` 与 `PlatformMemoryMapLib.c` |
| P1 | **ACPI / DSDT** | 参考 `elish` / `lmi`，按 dagu 外设修改 |
| P1 | **面板 SimpleFb** | 确认 2560×1600 与 DSI 节点一致 |
| P2 | **Mass Storage** | UEFI 菜单验证 UFS 枚举 |
| P2 | **WinPE 烟雾测试** | ACPI 就绪后再做 |

### 提取 dagu.dtb（有 root 后）

```bash
adb shell su -c "dd if=/dev/block/by-name/boot_b of=/sdcard/boot.img"
adb pull /sdcard/boot.img
# 使用 unpack_bootimg / magiskboot 提取 dtb
cp extracted.dtb edk2-msm/Platform/Xiaomi/sm8250/FdtBlob_compat/dagu.dtb
```

---

## 6. 模板选择说明

| 模板 | 选用原因 |
|------|----------|
| **j716f** (Lenovo 小新 Pad Pro 2021) | 同为 SM8250 **2560×1600** 平板；含 WoA 向内存布局 |
| **elish** (Mi Pad 5 Pro 11") | 同品牌 SM8250；DTB/ACPI 参考 |
| **nabu** (Mi Pad 5) | SM8150 WoA 工程流程参考 → [Port-Windows-11-Xiaomi-Pad-5](https://github.com/erdilS/Port-Windows-11-Xiaomi-Pad-5) |

---

## 7. 相关链接

- [Renegade Porting Guide](https://renegade-project.tech/en/porting)
- [edk2-msm j716f 移植 commit](https://github.com/edk2-porting/edk2-msm/commit/fcd382a2815e0e5286a0c4bc150c9f070e270da3)
- [MiCode kernel_devicetree dagu-s-oss](https://github.com/MiCode/kernel_devicetree/tree/dagu-s-oss)
- [硬件调试流程](hardware-debug-workflow.md)

---

**Status：** 骨架已创建，待首次编译与 `fastboot boot` 实测。
