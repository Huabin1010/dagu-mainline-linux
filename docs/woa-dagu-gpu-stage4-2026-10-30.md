# dagu Windows GPU 适配：阶段 4（qcdx8250 绑定 QCOM253A 后启动挂死）记录（2026-10-30）

阶段 3 建议先把 GPU 绑定和 PEP 解耦：写回带 `QCOM253A` 的覆盖表，PEP0 保持禁用，
单独验证 `qcdx8250` 能不能起来。本阶段在真机上做了这一步。结论：设备能枚举、驱动能绑定，
但驱动加载时 Windows 启动挂死。目前 GPU 驱动服务被禁用，系统可以正常启动。

## 1. 做了什么

1. 覆盖表 rev 4（`HKLM\SYSTEM\CurrentControlSet\Services\ACPI\Parameters\DSDT\QCOMM_\SM8250_\00000004`）
   写入带 `QCOM253A` 节点的 DSDT（节点源码 `graphics-qcom253a.asl`）。重启后
   `ACPI\QCOM253A\0` 枚举出来，名称 "Adreno 640 GPU"。
2. PEP0（`ACPI\QCOM2519`）保持禁用，问题码 22。
3. 安装 `C:\dagu\qcdx\qcdx8250.inf`，系统里是 `oem80.inf`，服务名 `QCDX`，内核镜像
   `qcdxkm8250.sys`（DriverStore 目录 `qcdx8250.inf_arm64_a5505ccbf9897acf`）。

## 2. 现象

- 装上驱动后重启，Windows 停在启动阶段，不进桌面，SSH 也连不上。
- `ntbtlog.txt` 最后一条加载记录是 `qcdxkm8250.sys`，`dxgkrnl.sys` 是 NOT_LOADED。
- 没有生成新的 minidump。说明不是蓝屏，而是驱动在初始化里卡住（等待某个永远不来的事件，
  或访问了没上电的寄存器块导致总线挂死）。

## 3. 恢复方法

Windows 起不来时，从 B 槽 Linux 离线改注册表：

```bash
# 在平板 Linux（B 槽）上
mount /dev/sda36 /mnt/w
hivexsh -w /mnt/w/Windows/System32/config/SYSTEM
#   cd \ControlSet001\Services\QCDX
#   setval 1  →  Start = dword:4      （setval 会覆盖整个键，必须把该键所有值一起写回）
```

改完用 `tools/winarm/dagu-rescue.sh to-win` 切回 A 槽。注册表备份在平板 Linux 的 `/root/`。
之后 Windows 正常启动，`ACPI\QCOM253A\0` 显示 Error，问题码 32（服务已禁用）。

注意：`dagu-rescue.sh` 的 `linux_up` 只用 ping 判断，局域网里别的设备占用同一个地址时会误报。
本次 Linux 的 Wi-Fi 地址是 192.168.1.106，需要用 `LINUX_IP=192.168.1.106` 指定。

## 4. 挂死原因的候选

按可能性排序，均未验证：

1. **缺 PEP**：`qcdxkm8250` 通过 PoFx 向 PEP 请求 GPU 电源域（GX/CX）和时钟。PEP0 禁用时，
   请求可能一直等不到完成。阶段 2 证明 PoFx 四个函数是 ntoskrnl 导出、绑定本身不依赖 qcpep，
   但"不依赖绑定"不代表"不依赖 PEP 响应"。
2. **GPU 寄存器块没上电**：UEFI 没有打开 GPU_CC/GX 电源，驱动读写 `0x02C90000` 一带时总线挂死，
   表现为无蓝屏的硬卡死，和现象一致。
3. **缺 SMMU**：`smmu.asl` 在 `dsdt_common.asl` 里仍是注释掉的，驱动可能在映射 GPU 页表时卡住。
4. **`_DEP` 被裁掉**：参考板的 QCOM253A 依赖 PEP0、SMMU 等节点，dagu 版本为了能枚举去掉了 `_DEP`，
   驱动启动时依赖设备还没就绪。

## 5. 下一步

1. 先解决 PEP 的 `0x101 CLOCK_WATCHDOG_TIMEOUT`（阶段 3 第 8 节：服务键写 `DisableSystemLPM=1`，
   必要时去掉 `SYSM/CLUS` 里依赖 PEP 的 `_LPI` 状态），让 qcpep 能稳定加载。
2. PEP 稳定后再把 `QCDX` 的 `Start` 改回 3，看驱动能否完成初始化。
3. 想区分候选 1 和 2，可以在 UEFI 里先把 GPU_CC GDSC 打开，再禁用 PEP 启动一次。
4. `pep0.asl` 的 `_HID` 改成 `QCOM2519` 必须和第 1 步的解法一起提交，单独改会让源码构建的固件
   在启动时蓝屏。

## 6. 本阶段文件

- `docs/woa-dagu-gpu-stage2-2026-10-30.md`、`docs/woa-dagu-gpu-stage3-2026-10-30.md`：前两阶段记录，本次一起提交。
- `port/dagu/Platform/Xiaomi/sm8250/AcpiTables/dagu/graphics-qcom253a.asl`：QCOM253A 节点源码。
  目前只用于覆盖表，没有加入 `dsdt_common.asl`。
- 当前覆盖表还包含电池节点 `BAT0`（`DAGUB001`），见 [woa-dagu-battery-2026-10-30.md](woa-dagu-battery-2026-10-30.md)。
