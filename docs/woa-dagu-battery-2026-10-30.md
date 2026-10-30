# dagu Windows 电池适配记录（2026-10-30）

小米平板 5 Pro 12.4（dagu，SM8250）的 Windows 11 ARM 之前没有任何电池设备，
`Win32_Battery` 为空，系统不显示电量，低电量时也不会提醒或关机。事件日志里的
41/6008 意外关机就是电池耗尽造成的。本次新增一个自写的 Battery class 微型端口驱动，
让 Windows 显示电量并执行低电量策略。

## 1. 结果

| 项目 | 结果 |
|---|---|
| 设备 | `ACPI\DAGUB001\0`，类 Battery，状态 OK，驱动 `dagu-battery.sys` 1.0.0.2 |
| `Win32_Battery` | 出现，`EstimatedChargeRemaining` 98，`BatteryStatus` 2（接交流电，未在充电） |
| 读数对照 | 和 Linux B 槽 `bms` 一致：满充容量 9150 mAh、设计容量 10000 mAh、循环 309 次、电压 4.36 V、温度约 32 °C |
| 两颗电量计 | 右电芯（gpio28/29）和左电芯（gpio36/37）都读成功，`errs=0` |
| 充电器状态 | PM8150B 通过 SPMI 只读，`spmi ok=1 err=0` |
| 启动影响 | 无。读失败时驱动保留上一次的读数，从未读成功则报告"无电池"，不会阻塞启动 |

## 2. 为什么自己写驱动

- 高通自带的电池栈（`qcbattmngr`/`qcbattminiclass`，HID `QCOM2531`/`QCOM252D`）依赖 PMIC、
  ADC、GLINK 和 SPMI 驱动。dagu 的电量计是外置的两颗 TI BQ27Z561，挂在 I2C 上，高通栈读不到。
- 走微软 SPB + `qci2c8250` 需要 GENI/GPI/SMMU 整套栈，dagu 没有。之前 `qcspi8250` 就因此挂死过启动。
- 键盘驱动 `nanosic-803` 已经证明，直接操作 TLMM 引脚寄存器模拟 I2C（位翻转）在 Windows 下可行。

## 3. 硬件

| 电芯 | SDA / SCL | TLMM 分区 | Linux 对应 |
|---|---|---|---|
| 右（`fuel-gauge-r@55`） | gpio28 / gpio29 | NORTH `0x0F900000` | i2c-0（SE0） |
| 左（`fuel-gauge-l@55`） | gpio36 / gpio37 | SOUTH `0x0F500000` | i2c-13（SE13） |

- 引脚寄存器地址是 `分区基址 + gpio × 0x1000`，`+0` 是配置，`+4` 是输入输出。
- 两颗电量计地址都是 `0x55`，读字为 SMBus 格式，小端。
- gpio117（NORTH）和 gpio91（SOUTH）是电量计隔离脚，拉高会把对应电芯从 SMB5 路径隔离。
  驱动从不驱动这两个脚，只把它们的电平写进诊断文件。实测两脚都是 GPIO 功能、输出低。
- PM8150B 在 SPMI SID 2。驱动用 SPMI 仲裁器观察者通道只读，方式和 `dagu-pwrkey` 读 PON 相同，
  不写任何 PMIC 寄存器。

## 4. 驱动实现（`port/dagu/windows-drivers/dagu-battery/`）

- WDM 驱动，调用 `battc.sys` 的 `BatteryClassInitializeDevice`/`BatteryClassIoctl`/
  `BatteryClassStatusNotify`。头文件 `batclass.h` 在 SDK 的 `shared` 目录。
- 位翻转 I2C：半周期 10 µs（约 50 kHz），用 `CNTVCT_EL0` 计时。每次读字在 DISPATCH_LEVEL 下完成，
  约 1 ms。时钟拉伸最多等 5 ms，一次事务里只要失败过一次就不再等待，所以总线卡死时
  不会在高 IRQL 下长时间自旋。启动时和读失败后执行 9 个时钟脉冲的总线恢复。
- 读取的寄存器（参照 Linux `bq27xxx_battery` 的 bq27z561 表）：温度 `0x06`、电压 `0x08`、
  标志 `0x0A`、剩余容量 `0x10`、满充容量 `0x12`、平均电流 `0x14`、循环 `0x2A`、电量 `0x2C`、设计容量 `0x3C`。
  读数做范围检查（电压 2.5–5 V、电量 ≤100、满充容量 ≤12000 mAh），不合格当作失败。
- 合成规则照搬 Linux `xiaomi-dual-fg.c`：电量 = 两颗剩余容量之和 ÷ 满充容量之和，
  超过 96.00% 显示 100，否则 `(raw + 95) / 96`，最高 99；电压取较大值；电流、容量相加；
  能量按 3.87 V 换算成 mWh。
- "接交流电"判断：PM8150B `USBIN_INT_RT_STS`（`0x1310`）bit4 或 `POWER_PATH_STATUS`
  （`0x110B`）bit0，和 Linux `chg_usbin_present` 一致。SPMI 读不到时退回"电流大于 0"。
- 轮询：每秒读一次充电器，每 5 秒读一次电量计；电量、电源或充满状态变化时通知 Windows，
  另外每 60 秒强制通知一次。超过 60 秒没有成功读数时，容量、电压、功率报告为未知。
- `BATTERY_STATUS.Capacity` 向上取整。Windows 会用 `Capacity / FullChargedCapacity` 再向下取整一次，
  不这样做的话，驱动算出 99% 时系统会显示 98%（1.0.0.1 版就有这个问题）。
- 诊断文件 `C:\Windows\dagu-battery.txt` 每 10 秒重写一次，包含合成结果、两颗电芯原始值、
  PM8150B 寄存器和隔离脚电平。

## 5. ACPI 节点

`battery.asl` 重写为一个无资源的 `BAT0` 节点，`_HID` 为 `DAGUB001`。

- 计划里写的 `DAGUBAT0` 不合法：ACPI ID 必须是 4 个字母加 4 个十六进制数字。
- 不再用 `ACPI0003`，那是交流适配器的 HID，会绑定 `cmbatt`。
- 不声明 `I2cSerialBusV2`，避免拉起 `qci2c8250`，和 `KBD0` 的做法一致。
- 原来的 `FG0/FG1/SMB5/PMP0/PMP1` 桩节点已删除。67 W 快充阶段需要时再加回。

当前生效的 Windows 用注册表覆盖表加载 DSDT（`HKLM\...\ACPI\Parameters\DSDT\QCOMM_\SM8250_\00000004`，
分两块写入，第 0 块 16 字节头 + 7152 字节数据，第 1 块 8 字节头 + 剩余部分）。这次在 GPU 版覆盖表
（`QCOM253A`）后面加上 `BAT0`，表长 8721 字节，校验和 0。写入前两块旧值备份在平板
`C:\dagu\dsdt-backup\0000000{0,1}-pre-bat-1030152555.bin`。源码构建的 `DSDT.aml` 也已重新编译。

## 6. 构建、签名、安装

```bash
# 宿主机 clang/lld-link 21 即可，参数与 build-kmdriver.sh 相同（mu-aloha:v1 镜像已不在本机）
EXTRA_LIBS="battc.lib" bash tools/winarm/build-kmdriver.sh dagu-battery
tools/winarm/sign-driver.sh port/dagu/windows-drivers/dagu-battery/dagu-battery.sys
```

在线安装需要测试签名的目录文件：在平板上对只含 `.inf` 和已签名 `.sys` 的目录执行
`New-FileCatalog -CatalogVersion 2.0`，拉回本地用 `osslsigncode` 和 `tools/winarm/signing/` 里的
测试证书签名，再传回去执行 `pnputil /add-driver dagu-battery.inf /install`。
测试代码签名证书（`B87290C6…3652`）需要在 `TrustedPublisher` 里，否则 pnputil 报
"publisher has not yet been established as trusted"。

`build-kmdriver.sh` 新增可选环境变量 `EXTRA_LIBS`，不设时和原来完全一样。

## 7. 电源策略

`powercfg /a` 显示休眠未启用、只有 S0 低电量待机，所以关键电量动作用"关机"而不是"休眠"。
平衡方案的交流和直流两侧都已设置：

| 设置 | 值 |
|---|---|
| 低电量水平 `BATLEVELLOW` | 10% |
| 低电量动作 `BATACTIONLOW` | 不操作（只提醒） |
| 保留电量 | 7% |
| 关键电量水平 `BATLEVELCRIT` | 5% |
| 关键电量动作 `BATACTIONCRIT` | 关机 |

## 8. 充电功率实测：插着充电器也在放电

| 寄存器 | 值 | 含义 |
|---|---|---|
| `BATTERY_CHARGER_STATUS_1` `0x1006` | `0x03` | FULLON 充电状态 |
| `POWER_PATH_STATUS` `0x110B` | `0x95` | bit0 输入有效 |
| `USBIN_INT_RT_STS` `0x1310` | `0x10` | USB 已插入 |
| `APSD_RESULT_STATUS` `0x1308` | `0x01` | 识别为 SDP（电脑 USB 口类型） |
| `USBIN_CURRENT_LIMIT_CFG` `0x1370` | `0x0A` | 输入限流 500 mA |
| `CHGR_FAST_CHARGE_CURRENT_CFG` `0x1061` | `0x28` | 快充电流 2000 mA |
| `CHGR_FLOAT_VOLTAGE_CFG` `0x1070` | `0x58` | 浮充 4.48 V |

连续 3 次采样（15:39–15:40），电池电流 -258 到 -335 mA，约 -1.1 到 -1.5 W，剩余容量
每分钟少约 2 mAh。原因是 Windows 下没有 Type-C/PD 协商，PM8150B 的 APSD 把充电器识别成 SDP，
输入限流停在硬件默认的 500 mA（5 V 下最多 2.5 W），低于系统功耗。Linux 下同一个充电器
走 USB PD，输入限流 2 A，充电电流 3 A。

结论：硬件默认行为只能减缓放电，插着电也会慢慢掉电，需要启动充电阶段。最小的一步是在
Windows 驱动里按 Linux `pm8150b-charger-dagu.c` 的 `chg_set_icl` 流程把输入限流提到 1.5–2 A
（需要写 PMIC，要先评估 SPMI 读写通道的归属和风险）。67 W PPS 快充仍按
[dagu-67w-充电方案.md](dagu-67w-充电方案.md) 另立阶段。
