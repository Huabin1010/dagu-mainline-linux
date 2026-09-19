# dagu UEFI 移植说明 (edk2-msm)

> 设备：小米平板5 Pro 12.4 (`dagu`, SM8250)  
> 上游：[edk2-porting/edk2-msm](https://github.com/edk2-porting/edk2-msm)

**Mass Storage / LSMS（Linux Simple Mass Storage，Linux 简易大容量存储）路径已放弃：** 自编 Linux gadget 曾导致 USB（Universal Serial Bus，通用串行总线）假死，已从 `dagu` 固件中移除。安装改走 WinPE。历史分析见 [mass-storage-blocker-analysis.md](mass-storage-blocker-analysis.md)。

**Type-C（USB Type-C，USB C 型接口）启动日志：** `DaguUsbCdcAcmDxe` 挂 SM8250 已有的 `UsbfnDwc3Dxe`，枚举 `0525:a4a7`，把 `0x9FFF7000` 环缓回放到 CDC-ACM（Communications Device Class — Abstract Control Model，通信设备类抽象控制模型）。不写 DWC3（DesignWare USB3 Controller，新思 USB3 控制器）寄存器。用法见 [dagu-usb-serial-console.md](dagu-usb-serial-console.md)。

---

## 1. 本仓库已添加的内容

dagu 设备 port 跟踪在 **`port/dagu/`**（构建时打入 edk2-msm）：

| 路径 | 说明 |
|------|------|
| `port/dagu/configs/devices/dagu.conf` | 构建配置 |
| `port/dagu/Platform/Xiaomi/sm8250/dagu.dsc` | 平台 DSC（2560×1600） |
| `port/dagu/Platform/Xiaomi/sm8250/dagu.fdf.inc` | FD 片段、ACPI、DTB |
| `port/dagu/Platform/.../PlatformMemoryMapLib/` | 内存映射已按 Linux `reserved-memory` / iomem 对齐，见 [dagu-woa-linux-source-map.md](dagu-woa-linux-source-map.md) |
| `port/dagu/Platform/.../AcpiTables/dagu/` | DSDT：PEP（Power Engine Plugin，电源引擎插件）/ UFS（Universal Flash Storage，通用闪存）/ Adreno 650 / Himax / Wi‑Fi / 蓝牙 / USB（Universal Serial Bus，通用串行总线）/ 音频 / 键盘 / 电池 / 亮度 / 霍尔 / SLPI（Sensor Low Power Island，传感器低功耗岛）/ Venus / 笔 / Type-C（USB Type-C，USB C 型接口）/ 马达 / MDSS（Mobile Display Subsystem，移动显示子系统）/ CDSP（Compute DSP，计算数字信号处理器）/ SPMI（System Power Management Interface，系统电源管理接口）/ LPASS（Low Power Audio Subsystem，低功耗音频子系统）/ SMMU（System Memory Management Unit，系统内存管理单元）/ IPCC（Inter-Processor Communication Controller，核间通信控制器）/ SMEM（Shared Memory，共享内存）/ 手电筒。相机不进 ACPI（Advanced Configuration and Power Interface，高级配置与电源接口） |
| `port/dagu/.../FdtBlob_compat/dagu.dtb` | HyperOS 活 FDT（Flattened Device Tree，扁平设备树）（`install-dagu-fdt.sh`），不是 Linux 7.0 DTS（Device Tree Source，设备树源码） |

`edk2-msm/`、`vendor/` 由 bootstrap **git clone**，不提交到项目仓库。

---

## 2. 构建环境（本机 Linux）

在仓库根目录操作。首次需要 clone 上游：

```bash
./tools/bootstrap-workspace.sh
```

依赖：

```bash
sudo apt update
sudo apt install -y build-essential uuid-dev iasl git nasm python3 \
  python3-distutils gettext gcc-aarch64-linux-gnu clang llvm device-tree-compiler
```

---

## 3. 编译

```bash
./tools/build-dagu-uefi.sh
# Host without clang uses GCC5 + -std=gnu17 (dagu.dsc). Needs iasl on PATH
# or tools/bin/iasl (see tools/compile-dagu-acpi.sh). Does not flash.
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

```bash
fastboot boot artifacts/boot-dagu-latest.img
```

3. 预期：Renegade Logo / UEFI Shell / SimpleFb 显示  
4. **不要** `fastboot flash boot`，直到 Android 双系统方案就绪

---

## 5. 已知 TODO（按优先级）

源码侧（Linux → UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）/ ACPI（Advanced Configuration and Power Interface，高级配置与电源接口））已在 [dagu-woa-linux-source-map.md](dagu-woa-linux-source-map.md) 补齐。下面仍要**板上**做：

| 优先级 | 项 | 做法 |
|--------|-----|------|
| 已完成 | 替换 `dagu.dtb` | `dumps/.../dt/fdt.dtb` → `FdtBlob_compat/`（校验 dagu + l81a） |
| 已完成 | 校验内存映射 | `tools/dagu-linux-to-uefi-map.py` vs `reserved-memory` / iomem |
| 已完成 | ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）四条 | PEP（Power Engine Plugin，电源引擎插件）/ UFS（Universal Flash Storage，通用闪存）`0x01D84000` / GPU（Graphics Processing Unit，图形处理器）`0x03D00000` / Himax `0x990000` GPIO（General Purpose Input/Output，通用输入输出）39 |
| 已完成 | ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）体验路径 | Wi‑Fi QCA6390 / 蓝牙 UART（Universal Asynchronous Receiver-Transmitter，通用异步收发器）6 / USB（Universal Serial Bus，通用串行总线）/ 音频 / 键盘 / 电池+67W / 亮度 / 霍尔 / SLPI（Sensor Low Power Island，传感器低功耗岛）/ 热 / Venus / 笔 / Type-C（USB Type-C，USB C 型接口）/ 马达 / 显示 DPU（Display Processing Unit，显示处理单元）/ CDSP（Compute DSP，计算数字信号处理器）/ SPMI（System Power Management Interface，系统电源管理接口）/ SoundWire / SMMU（System Memory Management Unit，系统内存管理单元）/ 手电筒 |
| P1 | **面板 SimpleFb** | 链载后确认 2560×1600 与 DSI 节点一致 |
| P2 | **WinPE USB 启动** | UEFI（Unified Extensible Firmware Interface，统一可扩展固件接口）菜单验证 U 盘 / ISO，不走 LSMS |
| P2 | **WinPE 烟雾测试** | 板上验证 ACPI（Advanced Configuration and Power Interface，高级配置与电源接口） |

缺官方 INF（Information file，驱动信息文件）的外设已开始自写：[`port/dagu/windows-drivers/`](../port/dagu/windows-drivers/README.md)。`HIMA8312` 等 `_HID` 对上那些包。

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

**Status：** Linux 出处已写入 `port/dagu/`（内存映射 / ACPI（Advanced Configuration and Power Interface，高级配置与电源接口）/ 活 FDT（Flattened Device Tree，扁平设备树））。本机可 `build-dagu-uefi.sh`。**不要** `fastboot boot` / flash，直到明确进入板上阶段。
