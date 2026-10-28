# dagu Windows：原装键盘、CPU 频率、GPU（2026-10-28）

用户反馈：Windows 能进，但没有 Wi-Fi/蓝牙，系统很卡，想要 GPU 驱动和原装键盘。这一轮做了
键盘驱动和 CPU 频率；GPU 的结论是现在做不了，原因写在第 3 节。

## 1. 为什么看不到 Wi-Fi / 蓝牙

这是预期结果。上一轮刷的只是只读探针（读电源轨状态），Windows 里还没有装任何 Wi-Fi/蓝牙
驱动，ACPI 里也没有对应节点。计划见
[woa-dagu-wifi-bt-rotation-2026-10-28.md](woa-dagu-wifi-bt-rotation-2026-10-28.md)。

探针的输出写进了 PStore 内存环（0xB0400000），但从 Windows 回 fastboot 是冷重启，内存没保留，
从 Linux 读出来是乱的（环头偏移 `0x8000a00002000`，区域里找不到任何 UEFI 字符串）。所以这一轮
把探针改成**写文件到 ESP**（见 2.2），冷重启也丢不了。

## 2. 卡顿：CPU 频率没人管

### 2.1 原因

dagu 的 Windows 没有高通 PEP（`qcpep8250` 一装就 0x1D5 卡死），DSDT 里也没有 `_CPC`/`_PSS`。
Windows 因此**完全不调 CPU 频率**，核心一直停在 UEFI 退出时 EPSS 硬件所处的档位。这个档位
没有记录过，可能很低。另外空闲只开了 C1 WFI（`Pep_lpi.asl`），这只影响功耗和发热，不是卡顿
的原因。显示走 BasicDisplay，1600×2560 全靠 CPU 画，CPU 频率低时更明显。

SM8250 EPSS（`sm8250.dtsi` cpufreq_hw，`qcom-cpufreq-hw.c` epss_soc_data）：

| 域 | 基址 | 核心 | LUT 范围（实测，Linux） |
|---|---|---|---|
| 0 | 0x18591000 | A55 ×4 | 300–1805 MHz |
| 1 | 0x18592000 | A77 ×3 | 710–2419 MHz |
| 2 | 0x18593000 | A77 prime | 845–3187 MHz |

寄存器：ENABLE +0x0（bit0），DOMAIN_STATE +0x20（L 值 ×19.2 MHz），DCVS_CTRL +0xB0（bit0 =
每核投票，dagu 读到 0x130，即不是），FREQ_LUT +0x100（每项 4 字节：bit31:30 src，bit7:0 L，
bit18:16 core_count，1 = boost），PERF_STATE +0x320（写 LUT 下标就换档）。Linux 就是这么换的。

### 2.2 DaguPlatDxe

新 UEFI 驱动 `winarm/overlay/xiaomi-dagu/Driver/DaguPlatDxe/`：

- ReadyToBoot 和 ExitBootServices 时，每个域从硬件 LUT 里选 ≤ 目标频率的最高一档，写
  PERF_STATE。目标：A55 1805、A77 2150、prime 2362 MHz（宏 `DAGU_CPU_MHZ_D0/1/2`）。故意不顶到
  最高档，因为 Windows 没有温控策略，只剩硬件 LMh 限温。
- ReadyToBoot 时把**普查结果写到 Windows ESP 根目录 `\dagu-uefi-diag.txt`**：EPSS 改前/改后
  频率；PMIC VREG 协议下 QCA6390 候选轨（S4/S5/S6/S8/L9/L16）的状态和电压，以及每颗 PMIC
  所有打开的轨；gpio20/21（WLAN_EN/BT_EN）。从 Linux 读：
  `mount -o ro /dev/sda35 /mnt/esp && cat /mnt/esp/dagu-uefi-diag.txt`。
- DaguQupDxe 里上一轮加的 `ProbeWcnPower` 已经撤掉（它在 PmicDxe 之前跑，而且只打印到会丢的
  PStore）。

## 3. GPU：现在做不了

仓库里有高通的 Adreno 650 WDDM 驱动包
`winarm/drivers/windows_qcom_platforms/components/QC8250/Drivers/Graphics/DXKM/qcdx8250.inf`
（27.20.2140.0），只绑 `ACPI\VEN_QCOM&DEV_253A`。MTP 参考 DSDT 的 `GPU0`
（`DSDT_8250_MTP.dsl:68113`）依赖：

- `_DEP` 10 项：`MMU0, MMU1, IMM0, IMM1, PEP0, PMIC, PILC, RPEN, TREE, SCM0`；
- IORT 把 GPU0 映射到 SMMU；
- `_CRS` 是显示 + GPU + 视频合一的大节点（MDP、GPU、GPU PDC、GPU_CC、RPMH CPRF、Venus），
  驱动按 `RESI` 名字取资源。

qcdx 靠 PEP 开 GPU 的电源域、GMU 和时钟，靠 SMMU 做 GPU 地址空间。dagu 这两样都没有：PEP 一装
就卡死（0x1D5），SMMU/IORT 一开 UFS 就 0x7B。所以在 PEP 和 SMMU 能工作之前，装 qcdx 只会让
启动卡住，不会变快。dagu 自己的 `graphics.asl` 用的 `QCOM24B4` 也对不上这个 INF。

结论：GPU 是一个单独的大项目，前置是把 PEP + SMMU 跑通（或者自己写 GPU 电源/GMU 上电并改 qcdx
的依赖），不在这一轮。现阶段能做的提速就是 CPU 频率（第 2 节）。

## 4. 原装键盘（Nanosic 803）

### 4.1 硬件和协议

全部来自能用的 Linux 驱动 `linux-mainline/overlays/linux/drivers/input/keyboard/nanosic-dagu.c`：

- I2C 地址 0x4C，SDA gpio115 / SCL gpio116（NORTH，`0x0F973000`/`0x0F974000`），数据线
  gpio83（低 = 有包），供电 vdd 127 / reset 141 / sleep 155（DaguQupDxe `PowerKeyboard` 已经上电）。
- 读：`S 4C/W [4C] Sr 4C/R <68 字节> P`；写：`S 4C/W [4C] <66 字节> P`。
- 包：`[0x57, seq, 长度码 0x39/4A/5B/6C, 记录...]`，记录的类型字节就是 HID 报告 ID：
  0x05 键盘（9 字节），0x06 多媒体键（5），0x02 鼠标（8），0x19 触控板（21），0x22/0x23 厂商。
- 主机→176x 命令 `[32 00 4E 31 80 38 op a b 校验(2..8 之和)]`；初始化顺序 enable-0x26、
  enable-0x23、亮屏 0x25、查版本、查霍尔 0x52。Caps Lock 灯是 0x26。

### 4.2 Windows 驱动

`port/dagu/windows-drivers/nanosic-803/`，和触摸驱动同一个模式：

- HIDCLASS 小端口驱动，不用 SPB/GENI/PEP。I2C 用 TLMM 寄存器位翻转（开漏：OE=1 拉低，OE=0
  放开，支持时钟拉伸），相当于 Linux 的 `i2c-gpio` 备用节点。轮询线程每 2 ms 看一次 gpio83，
  低就读一包；gpio83 一直没变低时退回每 40 ms 读一次。
- 一个 HID 设备三个集合：键盘（ID 5）、多媒体键（ID 6）、鼠标（ID 2），描述符用 MCU 自己的
  （安卓实机导出）。
- 触控板记录 0x19 不是 Windows 精确式触控板，驱动里转成鼠标：单指移动，双指滚动，轻点左键，
  按下触控板是左键。
- HIDCLASS 没有挂读请求时报告先排队（32 项），按键抬起不会丢；重复的序号丢弃。
- ACPI `KBD0`（`NANO0803`）不声明任何资源，避免拉起 `qci2c8250`。
- 诊断：INF 默认写注册表 `NanosicDiag=1`，驱动每约 2 秒写 `C:\Windows\nanosic-diag.txt`
  （读包数、NAK 数、各类记录数、MCU 版本、霍尔状态、最后一包）。调好后改成 0。
- 构建：`tools/winarm/build-kmdriver.sh nanosic-803`，签名
  `tools/winarm/sign-driver.sh port/dagu/windows-drivers/nanosic-803/nanosic-803.sys`。

### 4.3 部署记录

1. WinPE 介质（平板 `/root/woa/winpe.img`）`\woa\drivers` 里只放 `nanosic/`，旧的 `himax/` 和
   `remove-drivers.txt` 挪到 `/root/woa/media-bak/`；保留 `\woa\service`（服务模式，不格式化）。
2. `run-qemu-deploy.sh` 跑了 12 分钟，`deploy.log`：`nanosic-803.inf: 驱动程序包已成功安装`，
   `dism rc=0`。
3. UEFI 用 `DSDT_ONLY="ufs Pep_lpi himax keyboard"` 构建（DSDT 里同时有 `HIMA8312` 和
   `NANO0803`），刷 `boot_a`。

## 5. 待验证（下一次进 Linux）

- `\dagu-uefi-diag.txt`：EPSS 原来在哪一档、改到了哪一档；QCA6390 电源轨状态。
- `C:\Windows\nanosic-diag.txt`：键盘读包、NAK、记录数。
- 用户体感：键盘能不能打字、触控板、Caps 灯；系统是否比之前流畅。
