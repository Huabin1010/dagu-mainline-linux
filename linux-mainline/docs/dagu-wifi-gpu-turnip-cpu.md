# dagu：Wi‑Fi / GPU / Turnip / CPU 调频验收

记录日期：2026-09-11。设备：小米平板 5 Pro 12.4（`dagu` / SM8250 / 22081281AC）。  
内核：Linux 7.0 `#101`，`DAGU_MINIMAL=1 DAGU_DISPLAY=1`。刷入 B 槽 `linux-mainline/out/boot-dagu.img`。  
`g_serial` 保持 `0525:a4a7` 超过 60s，没有掉回兔子 `18d1:d00d`。

相关提交：

- `641ae18` — 打开 120Hz、Adreno、QCA6390 Wi‑Fi
- 本文同批 — CPU 删 interconnects + EPSS LUT + TSENS，否则 `cpufreq` 空、没有热点温度

SSID / 密码只放本机 `tmp/wifi-info.md`（已 gitignore），不要写进仓库。

## 怎么刷

```bash
cd linux-mainline
DAGU_MINIMAL=1 DAGU_DISPLAY=1 ./scripts/build-kernel.sh
./scripts/build-bootimg.sh
# 确认 linux/arch/arm64/kernel/head.S 直接 bl record_mmu_state，没有 SYSTEM_RESET
./scripts/flash-boot.sh flash-b    # 只用 fb-usb.py；不要 Google fastboot reboot
```

救砖：`linux-mainline/scripts/flash-boot-legacy.sh restore-a`（A 槽 TWRP 不动）。

串口：`linux-mainline/scripts/dagu-console.py`。Wi‑Fi 起来之后可用：

```bash
ssh -i linux-mainline/out/id_dagu -o StrictHostKeyChecking=no root@192.168.1.158
```

平板 RTC 没有，启动后时钟停在 2026-07-27，`apt` 会报 Release「尚未生效」。先：

```bash
ssh ... "date -u -s '$(date -u +%Y-%m-%d\ %H:%M:%S)'"
```

外网 GitHub 平板直连不通；CTS / 源码在**主机**下（Mihomo 能出网），再 `scp` 到平板。Ubuntu 包走清华 `ubuntu-ports`。

## Wi‑Fi（QCA6390 / pcie0 / ath11k）

接口 `wlp1s0`，MAC `f0:6c:5d:71:3a:2b`，NetworkManager 配置名 `cmcc-5g`。  
5GHz CH36、80MHz。压测时：

```
tx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2
rx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2
```

这就是 802.11ac 80MHz 2SS 的 PHY 上限（约 866Mbps）。  
iperf3 对端是主机有线 `192.168.1.157:5201`（`enp11s0` 1000Mb/s）。反向 4 流 TCP 约 **600–665 Mbps**（PHY 的 70–77%，正常）。UDP 打 900M 会丢包，空口已经顶住。

BDF 继续用 dump `bd_l81a.elf` → `linux-mainline/firmware/dagu/lib/firmware/ath11k/QCA6390/hw2.0/board.bin`，不要 `board-2.bin`。

蓝牙：`uart6` / `hci_qca` / QCA6390。内核 #158 起 uart6 把 stock `qupv3fw.elf` 只写进 SE6 IRAM（`linux-mainline/dts/sm8250-xiaomi-dagu.dts`），**禁止**给 `&qupv3_id_0` 加 `firmware-name`。`local-bd-address` 按 DT 小端写 `[2a 3a 71 5d 6c f0]`（人读 `F0:6C:5D:71:3A:2A`，与 Wi‑Fi `…:3A:2B` 相邻）。实机 `hci0` 已 `QCA setup on UART is completed`，`bluetoothctl` Powered: yes。固件：`linux-mainline/firmware/dagu/lib/firmware/qcom/sm8250/xiaomi/dagu/qupv3fw.elf`（`dumps/.../qupfw_a.img`）、`qca/htbtfw20.tlv`、`qca/htnv20.bin`。

BLE 鼠标（如 MCHOSE A7 Pro，UUID `00001812` HID）走 BlueZ HOG：GATT 连上不等于能用。必须 `CONFIG_UHID=y`（`/dev/uhid`）和 `CONFIG_BT_LE=y`，否则 `bluetoothd` 报 `input-hog profile accept failed`，GNOME 显示 Connected，指针不动，鼠标一直闪配对灯。经典 BR/EDR HID 另外需要 `CONFIG_BT_HIDP=y`（不要只编成 `=m` 却不装模块）。

经典键盘（Logitech K380，`LegacyPairing: yes`，UUID `00001124` HID）：BlueZ 5.64+ 默认 `ClassicBondedOnly=true`，`hidp_add_connection()` 会 `Rejected connection from !bonded device`。GNOME 设置里能点上、甚至显示 Connected，但 `/proc/bus/input/devices` 没有键盘节点，按键全无。配对 PIN 要在键盘上输入，HID 必须在 bonding 完成前放行。rootfs 写 `linux-mainline/bluetooth/input.conf` → 设备 `/etc/bluetooth/input.conf`：`ClassicBondedOnly=false`，`UserspaceHID=persist`（BlueZ #737：键盘睡醒第一键不被吃掉；不要 `UserspaceHID=false`，会 `br-connection-create-socket`）。配对后应看到 `Paired: yes` `Bonded: yes` 以及 `input: Keyboard K380`。

K380 连上后按键很钝：内核默认 sniff 是 **80–800 slot（50–500 ms）**，那是通用 ACL，不是 HID。标准做法是**继续 sniff**（键鼠电台能睡、也能把平板从 s2idle 唤醒），只把间隔改成 HID 量级 **6–18 slot（3.75–11.25 ms）**：BlueZ `MinSniffInterval` / `MaxSniffInterval`（`linux-mainline/scripts/rootfs-desktop-setup.sh` 写进 `/etc/bluetooth/main.conf`），内核默认同样改在 `linux-mainline/scripts/apply-overlays.sh` → `linux-mainline/linux/net/bluetooth/hci_core.c`。对端发起 sniff 时内核仍保留 `HCI_CONN_POWER_SAVE`，主机 LED/输出报告可以 Exit Sniff，不是关 sniff。**不要**清掉 `HCI_LP_SNIFF`、**不要**把 uart6 `power/control` 钉成 `on`、**不要**关 QCA IBS。

K380 点连接失败、体感比手机慢：鼠标是 BLE 广播，K380 是经典 BR/EDR 寻呼。Linux 默认 `Create Connection` 在 inquiry 缓存 >60 s 后用 **R2 + clock offset 0**，实机 `btmon` 就是这条然后 **Page Timeout (0x04)**。手机把 clock offset 留在配对记录里。正路：ACL 一起来就 `Read Clock Offset` 写入 inquiry 缓存，寻呼在本地 CLKN 连续期间（最长约 15 min）带上真实 offset；HID 主机 `HCI_LM_MASTER`（进来的 Accept 变成 Central）；page scan 用 **交错扫描**，BlueZ `FastConnectable=true`（HCI **Page** Scan Activity `0x0100/0x0012`，不要用 Inquiry Scan 的 OCF `0x1d` 去读）。**不要**把 HID `00001124` 放进 `ReconnectUUIDs`：主机盲寻呼会占住电台、关掉 page scan，键盘按键来连会对不上。GNOME 蓝牙面板开着会一直 INQUIRY，用完关掉。K380 三通道：适配器 power-cycle 后要长按**当初配对的那颗**通道键灯闪再连。`PageTimeout=16384`。不关睡眠。

## GPU / GMU / Turnip

`&gpu` / `&gmu` / `&adreno_smmu` 为 okay。zap：`qcom/sm8250/xiaomi/dagu/a650_zap.mbn`（本机签名，不要 elish）。

SQE 必须用 linux-firmware 那份 **31964 字节、word1 `0x112`（≥ 0.95）**：

- 主机暂存：`linux-mainline/firmware/dagu/lib/firmware/qcom/a650_sqe.fw`（blob 不进 git）
- 设备：`/lib/firmware/qcom/a650_sqe.fw`

dump 里旧 SQE 是 0.93，内核会拒。GMU：`qcom/a650_gmu.bin`，dmesg `Loaded GMU firmware v2.1.8`。  
`gpu-initialized: 1`，revision 650，`/dev/dri/card0` + `renderD128`。GNOME 走 msm atomic，不再是 llvmpipe。

用户态（Ubuntu 26.04 Mesa 26.0.8）：

```
deviceName = Turnip Adreno (TM) 650
driverName = turnip Mesa driver
conformanceVersion = 1.2.7.1
```

`vkcube --wsi display` 选中 Turnip。EGL GBM 驱动名 `msm`。

fb0 Himax 测试丝滑，GNOME 花屏+断触是合成器：L81A DSC 8bpc，mutter 却扫 **XR30**；`CLUTTER_PAINT` 全屏 120Hz 重绘会拖死触摸。内核 #149 已去掉 plane 10bpc（`linux-mainline/scripts/apply-overlays.sh`），现 gnome-shell 主 fb 为 **XR24 `QCOM_COMPRESSED`**（`MUTTER_DEBUG_USE_KMS_MODIFIERS=1`）。用户态（Ubuntu 26.04 Mesa 26.0.8）Freedreno FD650。Chromium 窗口仍真 LINEAR（`linux-mainline/scripts/dagu-linear-mod.c` + `/usr/local/lib/dagu-mesa/libgallium-26.0.8-1ubuntu0.3.so`），GMEM store/fetch 已 **FIXED**。正式补丁：`linux-mainline/patches/0001-freedreno-a6xx-fix-event-store-linear-layout.patch`、`linux-mainline/patches/0002-freedreno-a6xx-fix-gmem-fb-read-linear-base-offset.patch`。`dagu-chrome.sh` 已不设 `DAGU_LINEAR_SYSMEM` / `DAGU_LINEAR_DESTILE`。底稿：`linux-mainline/docs/dagu-a650-linear-destile.md` §9.6 / §9.7。不要给 gnome-shell 设 `FD_MESA_DEBUG=notile` 或 `dagu-mesa`（`linux-mainline/scripts/rootfs-desktop-setup.sh`、`linux-mainline/scripts/dagu-chrome.sh`）。

面板：`linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c` 在 `prepare()` 发 CAF `E2=0x00`（120Hz），`get_modes()` 只登记 120Hz，避免 GNOME 选同名 60Hz。

## dEQP（Khronos CTS）

主机交叉编译（`DEQP_TARGET=vulkan_headless`，`DE_CPU_ARM_64`）：

- 源码：`tools/downloads/VK-GL-CTS/`（gitignore）
- 产物：`tools/downloads/deqp-build/external/vulkancts/modules/vulkan/deqp-vk`
- 设备：`/opt/deqp/deqp-vk` + `/opt/deqp/vulkan/`（shader / amber 数据，缺了会 `ResourceError`）

```bash
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.json
cd /opt/deqp
./deqp-vk --deqp-case='dEQP-VK.api.smoke.*' \
  --deqp-log-filename=/tmp/deqp.qpa --deqp-surface-type=fbo --deqp-log-images=disable
```

2026-09-11 实测（0 失败算过；NotSupported 不算坏）：

| 套件 | 结果 |
|------|------|
| `dEQP-VK.api.smoke.*` | 6/6 通过（含 triangle） |
| `dEQP-VK.api.version_check.*` | 3/3 通过（Vulkan 1.3.0） |
| `dEQP-VK.api.device_init.*` | 216 通过 / 0 失败 / 8 NotSupported（protected memory） |
| `dEQP-VK.compute.pipeline.basic.*` | 66 通过 / 0 失败 / 6 NotSupported |
| `dEQP-VK.draw.renderpass.simple_draw.*` | 4/4 通过 |
| `dEQP-VK.draw.renderpass.indexed_draw.*` | 160/160 通过 |
| `dEQP-VK.info.*` | 16 通过；2 条 CTS 1.3.10 不认识 Mesa 26 的 `VK_KHR_surface_maintenance1` / `VK_KHR_maintenance8` |

info 那两条是套件比驱动旧，不是 GPU 坏。完整 mustpass 仍要数小时，本轮用的是质量冒烟 + 计算/绘制核心组。

## CPU 调频 + 温度 + stress-ng

`DAGU_MINIMAL=1` 会 merge `linux-mainline/config/dagu-bringup.fragment`，把 `CPUFREQ_HW` / `TSENS` / `INTERCONNECT_QCOM_SM8250` 关掉。显示 fragment 再打开前两项，**ICC 仍然关**（BCM voter 的 `rpmh_write_batch()` 在这套 QHEE 上超时，会拖死 USB/MDSS）。

CPU 节点带着 `interconnects` 时，`dev_pm_opp_of_find_icc_paths()` 在 `_allocate_opp_table()` 里 `EPROBE_DEFER`，连 LUT 的 `dev_pm_opp_add()` 都建不出表，dmesg `Failed to add OPPs`，`/sys/devices/system/cpu/cpufreq` 为空。

做法：

1. `linux-mainline/dts/sm8250-xiaomi-dagu.dts` 给 `&cpu0`–`&cpu7` `/delete-property/ interconnects`
2. `linux-mainline/scripts/apply-overlays.sh` 让 `qcom-cpufreq-hw.c` **不要**解析 DT OPP（那些 opp 没有电压，频率也和 EPSS LUT 对不上），只用 LUT
3. `linux-mainline/config/dagu-display.fragment` 打开 `CONFIG_QCOM_TSENS`

验收（`schedutil`）：

| policy | 核 | 表范围 | 压核峰值 |
|--------|----|--------|----------|
| policy0 | 0–3 A55 | 300–1804 MHz | 1804 |
| policy4 | 4–6 A77 | 710–2419 MHz | 2419 |
| policy7 | 7 A77 Prime | 844–3187 MHz | 3187 |

```bash
stress-ng --cpu 8 --cpu-method all --verify --timeout 45s --metrics-brief --tz
```

8/8 通过，0 失败。压核时 cpu5-top **84.2°C**，结束后频率回到最低档。无 oops / hung_task。热区：`cpu0-thermal`、`cpu7-top-thermal`、`gpu-top-thermal`、`mem-thermal`、`wlan-thermal` 等（`/sys/class/thermal/thermal_zone*`）。

## 不要再做

- `DAGU_PRIMARY_ENTRY_PROBE=1`，或在 `head.S` `primary_entry` 插 PSCI `SYSTEM_RESET`
- `CONFIG_SPI_QCOM_GENI`、给 `&qupv3_id_0` 加 `firmware-name`、往 QUPV3 wrapper CSR 写（uart6 只装 SE RAM）
- 打开 `CONFIG_INTERCONNECT_QCOM_SM8250` 给 CPU 投票
- Himax 绑 GPIO100（那是面板 `tp-reset`）
- 刷 A 槽 / Google `fastboot reboot`
- 把 `tmp/wifi-info.md` 提交进仓库
- GPU zap 用 elish；Wi‑Fi `board-2.bin`

## 改动文件

- `linux-mainline/dts/sm8250-xiaomi-dagu.dts`
- `linux-mainline/config/dagu-display.fragment`
- `linux-mainline/scripts/apply-overlays.sh`
- `linux-mainline/scripts/build-kernel.sh`
- `linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c`（已在 `641ae18`）
- `.cursor/rules/dagu-boot-safety.mdc`（已在 `641ae18`）
