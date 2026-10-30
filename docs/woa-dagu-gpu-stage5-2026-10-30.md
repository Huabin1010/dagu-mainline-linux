# dagu Windows GPU 适配：阶段 5（先稳 PEP，实验 A/B/C 均未成功）记录（2026-10-30）

阶段 4 判断 `qcdx8250` 启动卡死可能是因为没有 PEP（高通电源引擎插件 `qcpep`，设备
`ACPI\QCOM2519`）响应，所以本阶段先尝试让 PEP0 在 Windows 上稳定加载。三组实验都没有成功，
GPU 驱动 `QCDX` 保持禁用（`Start=4`），没有进入启用 GPU 的步骤。系统当前可以正常启动，PEP0 处于禁用状态。

## 1. 实验结果

| 实验 | 改动 | 结果 |
|---|---|---|
| A | `qcpep\Parameters\DisableSystemLPM=1` + 启用 PEP0 | 阶段 2 已做（10-29 23:56），`0x101 CLOCK_WATCHDOG_TIMEOUT`，本阶段未重做 |
| B | A 的基础上加 `DisableCCI=1`、`DisablePCE=1` | 见下文 2、3 节：先被 SOSI 问题干扰，修正后仍然 `0x101` |
| C | B 的基础上，覆盖表里把 `SYSM`、`CLUS` 的 `_LPI` 清空（只保留 3 个元素，状态数 0） | Windows 启动失败，没有新 dump，平板回落到 B 槽 Linux |

实验 C 之前单独验证过：只换清空 `_LPI` 的新表、PEP0 保持禁用时，Windows 正常启动。所以 C 的失败来自启用 PEP0，不是 `_LPI` 清空本身。

## 2. 实验 B 第一次被 SOSI 问题干扰

第一次实验 B 的 dump（`103026-9687-01.dmp`，16:00）是 `0x1A MEMORY_MANAGEMENT`，参数
`(0x1243, 0x5052500880907, 0, 0)`，和阶段 2 修复前的 `SOSI` 症状一致。检查 live 覆盖表后发现，
电池阶段写入的表里 `SOSI` 是 1 字节（opcode `0x0c`），不是 8 字节 QWord。原因是该表是用
真实地址直接编译的，编译器把小常量压缩成了短编码。

修法与阶段 2 相同：先用占位符 `0xDEADBEEFFFFFFFFF` 编译（强制 8 字节），再回填真实地址
`0x0000000080907228`，并把校验和归零。重编译的表（8725 字节）写入后，`SOSI` 是 `0x0e` 开头的 8 字节常量。

## 3. 修正 SOSI 后的实验 B

重启后平板落回 B 槽 Linux。取回的 dump `103026-9671-01.dmp`（17:12）是
`0x101`，参数 `(0x18, 0, PRCB, 7)`，PC 在 `ntoskrnl.exe+0x25c5fc`，栈上没有非内核模块
（`crashdmp.sys`、`storport.sys` 只是转储路径）。和阶段 2 的 `0x101` 同类。也就是说仅靠 `qcpep` 的三个注册表开关无法避免超时。

## 4. 实验 C

覆盖表脚本把 `SYSM`、`CLUS` 的 `_LPI` 改为 `Package{0, 0x01000000, 0}`（状态数 0）。
`_LPI` 包至少要有 4 个元素才符合规范，iasl 会报 error 6106 但仍会生成 AML，可以通过。
CPU0~CPU7 自己的 `_LPI`（C1 WFI 等）保留。表长 8472 字节，校验和为 0。

启用 PEP0 重启后，Windows 没起来，也没有新 dump，平板回落到 B 槽。区别于 B 的 `0x101`：
这次是挂死或自动回落，没有蓝屏记录。

## 5. 当前状态

- 覆盖表是实验 C 的版本（`SYSM`/`CLUS` 的 `_LPI` 已清空，`SOSI` 8 字节）。它不影响启动，
  电池节点 `DAGUB001` 正常（电量 92%）。源码 `Pep_lpi.asl`、`pep0.asl` 没有改动，所以源码与 live 表在 `_LPI` 上不一致。
- PEP0 `ConfigFlags=1`（离线禁用），`qcpep\Parameters` 里 `DisableSystemLPM`、`DisableCCI`、`DisablePCE` 都是 1。
- `QCDX` `Start=4`。
- 本阶段注册表备份：`C:\dagu\backup\stage5-*-155308.reg`；覆盖表备份：`C:\dagu\dsdt-backup\*-pre-s5-*`、`*-pre-s5c-*`。

## 6. 救援流程的两个修复

1. NTFS 脏卷时 `ntfs-3g` 退回只读挂载却返回 0，`hivexsh commit` 报"只读文件系统"，
   救援脚本以为成功。`mount_win` 现在先 `ntfsfix -d`，再 `ntfs-3g -o force,remove_hiberfile` 挂载，
   最后用 `touch` 实测能否写入，失败就退出。
2. `linux_up` 以前只 ping。局域网里别的设备占用同一地址（192.168.1.75、192.168.1.106 都出现过误报）时会误判。
   现在改成 ssh 实际登录。B 槽 Linux 的 Wi-Fi 地址会变，本次是 192.168.1.51，用 `LINUX_IP` 指定。

另外新增子命令 `dagu-rescue.sh disable-qcdx`，离线把 `QCDX` 的 `Start` 设为 4，写入前备份 SYSTEM hive。

平板在 B 槽 Linux 时 Wi-Fi 可能没连上。这时可以用 USB 串口：`tools/winarm/serial-cmd.py`
操作 `/dev/ttyACM0`（`0525:a4a7`）。

## 7. 结论与下一步

`0x101` 在三种配置下都没有消除，说明问题可能不在 `qcpep` 的开关和 ACPI `_LPI` 声明上。可能的方向：

1. **`qcpep` 自己访问了未初始化的硬件**：它映射了 `0x90b0000`（APSS/APCS），并通过 TZ/RPMh 协调。
   `0x101` 的核号每次不同，符合某个核进入 `qcpep` 路径后没被唤醒。需要逆向 `qcpep` 在 DriverEntry 之后做了什么，或者抓内核调试输出。
2. **自己写一个最小 PEP**：只响应 GPU 需要的 PoFx 设备电源请求，不接管处理器空闲。
3. **绕开 PEP 直接验证 GPU**：在 UEFI 里先打开 GPU_CC 的 GDSC 和时钟，再用 `QCDX Start=3`（PEP0 保持禁用）启动，区分"缺 PEP"和"GPU 没上电"。
   这条路风险较低，建议下一阶段先做。
4. 同时检查 `smmu.asl`（仍被注释）对 GPU 驱动初始化的影响。

PEP0 `_HID` 改成 `QCOM2519` 的源码改动仍然不能提交：改了就会让源码构建的固件加载 `qcpep` 并卡死。
