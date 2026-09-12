# dagu 主线 Linux 适配总表

记录日期：**2026-09-11**。  
设备：小米平板 5 Pro 12.4（`dagu` / SM8250 / `22081281AC`）。  
运行系统：Linux 7.0 + Ubuntu（userdata），只刷 **B 槽**。  
内核构建：`DAGU_MINIMAL=1 DAGU_DISPLAY=1`。镜像：`linux-mainline/out/boot-dagu.img`。

本表只写 **当前主线 Linux 实机状态**。仓库里另有 UEFI / Win11 ARM 调研（`docs/uefi-port-dagu.md`、根 `README.md`），那不是现在每天在跑的系统。

相关细账：

- Wi‑Fi / GPU / Turnip / CPU：`linux-mainline/docs/dagu-wifi-gpu-turnip-cpu.md`
- Overlay 驱动清单：`linux-mainline/overlays/README.md`
- 板级 DT：`linux-mainline/dts/sm8250-xiaomi-dagu.dts`
- 安卓 dump 硬件清单（未随主线更新）：`docs/hardware-inventory.md`

## 怎么读状态

| 标记 | 含义 |
|------|------|
| **已通** | 实机有证据，功能可用 |
| **软件已通** | 驱动和通路打通，还缺听感 / 用户确认 / 完整场景 |
| **部分** | probe 或半条链路有了，关键功能未完成 |
| **DT 已写** | 节点或驱动在树里，未验收，或缺总线 |
| **有意关闭** | 这套 QHEE 上打开会挂、打回兔子，或已知会拖死别的子系统 |
| **未做** | 还没接 |

## 铁律（验收时不要破）

- 只刷 B 槽；A 槽 TWRP / HyperOS 不动。救砖：`linux-mainline/scripts/flash-boot-legacy.sh restore-a`
- 刷写用 `linux-mainline/scripts/fb-usb.py` / `flash-boot.sh flash-b`，不要 Google `fastboot reboot`
- **禁止** `DAGU_PRIMARY_ENTRY_PROBE=1`，禁止在 `linux-mainline/linux/arch/arm64/kernel/head.S` 的 `primary_entry` 插 PSCI `SYSTEM_RESET`
- 刷完 `g_serial` `0525:a4a7` 须保持 **>30s**，不能在约 25s 变回兔子 `18d1:d00d`
- **禁止**给 `&qupv3_id_0` 加 `firmware-name`、写 QUPV3 wrapper CSR、`CONFIG_SPI_QCOM_GENI`、`CONFIG_I2C_QCOM_GENI`、`CONFIG_INTERCONNECT_QCOM_SM8250`。uart6 只把 stock `qupv3fw.elf` 写进 SE6 IRAM。
- Himax 走 `spi-gpio`（CAF gpio8–11 + IRQ39），不要绑 GPIO100（面板 `tp-reset`）
- **禁止**把 `vreg_l3a_0p9` 改成 1.104V（CX 轨，会硬复位回兔子）
- 控制台：`python3 linux-mainline/scripts/dagu-console.py`（`/dev/ttyACM0`）
- **适配，不妥协**：Chromium 组件花屏是 **linux-dmabuf 合同撒谎**（ANGLE 按 EGL 全量 modifier 选出 UBWC，mutter `SEND_KMS_MODIFIERS=0` 只广告 LINEAR，客户端仍标 LINEAR）。底层修合成器：`SEND=1` 广告真实 QCOM modifier、`USE_KMS_MODIFIERS=0` 保持主 fb 线性、`disable-direct-scanout` 避免客户端 UBWC 直接上 DPU；**禁止**给 gnome-shell 设 `FD_MESA_DEBUG=notile`（会把 UBWC 当线性导入）。不要关 GPU 栅格 / 2D / zero-copy。应用侧只关 Ozone 在 Wayland 上不能映射的 Vulkan。

---

## 总览

| 子系统 | 状态 | 一句话 |
|--------|------|--------|
| 启动链 / B 槽 Linux | **已通** | 7.0 Image 站住，g_serial >30s |
| UFS + Ubuntu 桌面 | **已通** | userdata ext4，GNOME。内部 UFS 其它 LUN 对 Nautilus / Resources 隐藏，只留 userdata（sda）和 USB |
| USB gadget 串口 | **已通** | `0525:a4a7` / `ttyGS0` |
| 显示 L81A 120Hz | **已通** | 1600×2560，DSC dual-DPHY |
| GPU Adreno 650 / Turnip | **已通** | GMU + Mesa，dEQP 冒烟过 |
| CPU 调频 + 温度 | **已通** | EPSS LUT，stress-ng 8/8 |
| 触控 Himax | **已通** | `spi-gpio`，不要 GENI SPI |
| Wi‑Fi QCA6390 | **已通** | ath11k，iperf 约 600–665 Mbps |
| 扬声器 CS35L41 | **软件已通** | GDM 重启后 ACP 只有 Off（`disable-pro-audio` 再把 Pro 掐掉）→ Dummy Output 无声。已加 `linux-mainline/alsa/50-dagu-alsa-sink.conf` 直开 `hw:0,0` 2ch；重启 PW 后 UCM `HiFi__Speaker__sink` 也会出现。播时四颗 AMP/SPK=On。 |
| 麦克风 | **已通** | `/tmp/mic.wav` 非空（约 192 KB / 2s） |
| 后摄 s5kjn1 | **部分** | probe + C-PHY 寄存器对，STREAMON CCI NACK，0 帧 |
| 前摄 imx596 | **部分** | chip id 读到，开流，0 帧 |
| CAMSS VFE/SMMU | **已通** | CSID TPG 出过完整 1 帧（约 15.6 MB） |
| 蓝牙 | **已通** | QCA6390 uart6：stock `qupv3fw.elf` 只写 SE6；`hci0` `F0:6C:5D:71:3A:2A` Powered: yes。BLE 鼠标走 HOG，需要 `CONFIG_UHID` + `CONFIG_BT_LE` |
| USB OTG Host / DP | **DT 已写** | HS OTG 角色可切；SS PHY / PS5169 未在活 DT 接上。`pm8150b_typec` 已 okay（CC/PD），USB 图仍切断以免 DWC3 等角色 |
| 双电芯电量 | **DT 已写** | 双 BQ27Z561 + `xiaomi-dual-fg`，脚本可查 `power_supply` |
| 充电（SMB5） | **DT+驱动已写** | PM8150B `@1000` overlay；GPIO74 拉低放行 VBUS。未刷核验收 |
| 充电泵 / 无线充 | **DT 已写** | BQ25970 ×2 只做 PPS 快充，P9418 探测；5 V 不靠泵 |
| 霍尔 / 音量键 | **DT 已写** | gpio-keys；未专项验收 |
| 马达 | **DT 已写** | PMI632 LRA；未专项验收 |
| 闪光灯 | **DT 已写** | pm8150l flash；脚本可点 torch |
| 磁吸键盘 | **未做** | overlay 有，活 DT 没接（QUP I2C 不能开） |
| IMU / 光线传感器 | **有意关闭** | `&slpi` disabled，不在 AP I2C 上猜 |
| 视频编解码 Venus | **有意关闭** | 缺/未验 `venus.mbn`，probe 会 stall |
| CDSP | **有意关闭** | `status = disabled` |
| 蓝牙音频 / 耳机口 | **未做** | 板子无 3.5mm；控制器已通，A2DP / 耳机听感未测 |
| RTC | **未做** | 启动后停在 2026-07-27，apt 前需对时 |
| Win11 ARM 日常 | **未做** | 仍是调研 / UEFI 移植，不是当前运行目标 |

---

## 已通

### 启动与存储

| 项 | 证据 / 做法 |
|----|-------------|
| 内核 | Linux 7.0，`head.S` `primary_entry` 直接 `bl record_mmu_state` |
| 槽位 | `flash-boot.sh flash-b`：`dtbo_b` / `vbmeta_b` / `vendor_boot_b` / `boot_b` / `set_active b` |
| USB 稳定 | `0525:a4a7` 保持到 t≥35s，未见兔子 |
| UFS | 枚举后挂 userdata Ubuntu |
| 控制台 | `linux-mainline/scripts/dagu-console.py` |
| ramdisk 回退 | 未刷 ext4 时 RNDIS + minish（P0） |

DTBO 必须用 stub（`linux-mainline/out/dtbo-stub.img`），空 DTBO 约 6s 回 fastboot。

### 显示

- 面板：L81A dual-DPHY，**不是** elish NT36523 C-PHY
- 驱动：`linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c`
- `prepare()` 发 CAF `E2=0x00`（120Hz）；`get_modes()` 只登记 120Hz，避免 GNOME 选同名 60Hz
- 背光：双 KTZ8866。ABL 编程后靠 GPIO139 HWEN 维持，**整次开机不要拉低 HWEN**。GENI `i2c9`/`i2c11` 会 `geni_se_init` 挂死，走 `i2c-gpio`（CAF 焊盘 gpio60/61 + gpio125/126）。GNOME 只看到 `l81a-wled`（两颗 `kinetic,internal` 不进 sysfs，避免只暗一半）；滑条二次方映射后再写 0x04/0x05，**滑条 0 仍保持 11-bit 下限 32 且不清 BL_EN**（否则看不见）。`l81a_disable()`/`l81a_unprepare()` 仍空操作。短按只切 Mutter `PowerSaveMode` 0/3。长按关机。禁止 suspend。
- 分辨率：1600×2560 扫描（竖屏 framebuffer）
- 压测脚本：`linux-mainline/scripts/dagu-display-stress.sh`、`linux-mainline/scripts/dagu-refresh-test.py`
- 滑动窗口花屏 / GNOME 断触：fb0 Himax 测试丝滑。GNOME 主 fb 曾是 **XR30 10bpc**（L81A DSC 是 8bpc），再加 `CLUTTER_PAINT` 全屏重绘会拖死输入。内核 #149 已去掉 plane 10bpc（`linux-mainline/scripts/apply-overlays.sh`），实机 `format=XR24` `modifier=0x0`；用户态去掉 `CLUTTER_PAINT`、`GSK_RENDERER=ngl`、关掉 onboard / linger（`linux-mainline/scripts/rootfs-desktop-setup.sh`）
- Chrome / Electron 组件花屏：Ozone 把 `LINEAR + QCOM_COMPRESSED + QCOM_TILED3 + INVALID` 交给 `gbm_bo_create_with_modifiers`，但 `zwp_linux_buffer_params_v1.add` **永远标 modifier 0,0**。客户端 `linux-mainline/scripts/dagu-linear-mod.c`（`/usr/local/lib/libdagu-linear-mod.so`）把隐式/窗口 GBM 做成真 `GBM_BO_USE_LINEAR`，像素与 LINEAR 标签一致。**不要**关 GPU 栅格。a6xx `BLIT_EVENT_STORE` 仍会把这些缓冲写成 macrotile。Chrome / Mineradio 用 `LD_LIBRARY_PATH=/usr/local/lib/dagu-mesa`（`linux-mainline/patches/mesa-26.0.8-linear-cbuf-sysmem.patch` + `linux-mainline/patches/mesa-26.0.8-linear-sysmem.patch` + `linux-mainline/patches/mesa-26.0.8-tex-seqno-rebuild.patch`）。**不要**把 dagu-mesa / linear-mod 进 gnome-shell。字体花、界面不花：a650 `BLIT_EVENT_STORE` 把 LINEAR 写成 macrotile；大色块还能认，顶栏字形变成 1-bit 块（`linux-mainline/out/display-stress/dagu-fb0-now.ppm`，`font_unique=3` `font_tile32=0.81`），滚动再 store 损坏 tile。GSK 字形带 stencil，unused-depth sysmem 罩不住；LINEAR+stencil 整段 sysmem 会把 mutter scanout 写成全黑。destile 须跳过 event store，在 `RM6_BLIT2DSCALE` 下用上游 scissored `fd6_resolve_tile`（`DAGU_LINEAR_DESTILE=1` 才开）。量化：`linux-mainline/scripts/dagu-fb-score.py` 的 `font_unique>=20` `font_aa>=40` `font_tile32<0.35`。测试页 `linux-mainline/scripts/dagu-font-probe.html`。KMS 特写 `linux-mainline/out/display-stress/probe-glyph-3x.png` 笔画完整，不是 1-bit 砖。任意 Mutter 缩放（本机 `1.0 / 1.25 / 1.333 / 1.667 / 2.0 / 2.5 / 2.667`，无 1.5）：**不要**锁死 scale 2，也**不要**关 `WaylandFractionalScaleV1`（关了之后 Chrome 只按整数 DPR 栅格，mutter 再二次缩放，1.25 会糊成「乱码」）。270° 扫出上 LCD RGB 在逻辑横屏上是错轴，必须灰度：`--disable-lcd-text`、`--font-render-hinting=none`、`linux-mainline/scripts/99-dagu-gray-fonts.conf`（`rgba=none`）、gsettings `font-antialiasing=grayscale`。实机 DPR 跟随缩放（1.25 时 `DPR=1.250`，见 `linux-mainline/out/display-stress/scale-sweep-dpr/unlocked-ui.png`）。扫描脚本 `linux-mainline/scripts/dagu-scale-font-sweep.py`，裁剪 `linux-mainline/scripts/dagu-kms-land-crop.py`。计分读 KMS，不要信 GDM 后的 `/dev/fb0`。锁屏/PowerSave 会挡住窗口，扫图前要 `PowerSaveMode=0` 且 `ScreenSaver.SetActive(false)`。

### GPU（Adreno 650）

- `&gpu` / `&gmu` / `&adreno_smmu` okay
- zap：本机签名 `qcom/sm8250/xiaomi/dagu/a650_zap.mbn`（不要 elish）
- SQE：linux-firmware **31964 字节、word1 `0x112`**；dump 旧 0.93 会被拒
- `gpu-initialized: 1`，`/dev/dri/card0` + `renderD128`，GNOME 走 msm atomic（不是 llvmpipe）
- GNOME Resources 只扫 `/sys/class/drm/card0/device`（DPU，不是 `3d00000.gpu`）。`linux-mainline/overlays/linux/drivers/gpu/drm/msm/msm_gpu_resources_sysfs.c` 提供 `gpu_busy_percent`、`mem_info_vram_*`、`hwmon/freq1_input` / `temp1_input`（来自 devfreq / thermal）。Resources 只认 `hwmon?`，由 `linux-mainline/scripts/dagu-resources-fix.sh` bind 成 `hwmon0`。禁止伪造：UFS 不是 PCIe，硬盘 Link / GPU Slot / Max Power Cap 等没有真实值的项由 `linux-mainline/scripts/dagu-resources-hide-na.c` 藏行。禁止 bind 覆盖 `/sys/class/drm/card0/device/uevent`（假 PCI_ID 会让 Chrome `drmGetDeviceFromDevId` 失败、`--in-process-gpu` 整进程退出）。`linux-mainline/scripts/dagu-chrome.sh` 会清掉已死进程的 Singleton 锁。Wi‑Fi Manufacturer 用发行版 `/usr/share/misc/pci.ids` 复制到 `/usr/share/hwdata/pci.ids`（须双空格）。CPU 名走包装 `lscpu`（Kryo 585 / Snapdragon 870）。
- 用户态：Mesa Turnip，`vkcube` 选中 Adreno 650
- **卡顿（2026-09-12）**：OPP 上限已是硅片 670 MHz，忙时 `simple_ondemand` 会到顶；空闲掉到 305 MHz 后再抬，1600×2560@120 + LINEAR 合成会丢帧。`linux-mainline/scripts/dagu-resources-fix.sh` / `linux-mainline/scripts/dagu-gpu-perf.sh` 把 `min_freq=490M`、`polling_interval=10ms`。不要 `governor=performance`（合成时 ~75°C）。面板目前只有 120Hz 一种 mode。
- dEQP 冒烟 / compute / draw 核心组 0 失败（详见 `linux-mainline/docs/dagu-wifi-gpu-turnip-cpu.md`）

### CPU 调频与温度

- DT 给 `&cpu0`–`&cpu7` 删掉 `interconnects`（ICC + BCM voter 会 `rpmh_write_batch` 超时）
- `qcom-cpufreq-hw` 只用 EPSS LUT，不解析无电压的 DT OPP
- `CONFIG_QCOM_TSENS=y`；`CONFIG_INTERCONNECT_QCOM_SM8250` **保持关闭**

| policy | 核 | 表范围 | 压核峰值 |
|--------|----|--------|----------|
| policy0 | 0–3 A55 | 300–1804 MHz | 1804 |
| policy4 | 4–6 A77 | 710–2419 MHz | 2419 |
| policy7 | 7 A77 Prime | 844–3187 MHz | 3187 |

`stress-ng --cpu 8` 8/8 通过；压核 cpu5-top 约 84°C。

### 触控

- Himax HX83121，`spi-gpio`（gpio8–11 + IRQ39）
- 驱动：`linux-mainline/overlays/linux/drivers/input/touchscreen/himax-dagu.c`
- `&spi4` / `&gpi_dma0` disabled；`# CONFIG_SPI_QCOM_GENI is not set`
- 滑动断触：IRQ 线程里不要 `dev_info`（`ignore_loglevel` 会堵 fbcon/串口）；DT 用 `IRQ_TYPE_LEVEL_LOW`，坏帧（全 0xff）不当抬手
- OSK 连打字母：LEVEL_LOW + spi-gpio 会在一次按住里读到校验失败 / n=0 毛刺，tracking ID 被拆成多次点击。驱动排空 IRQ、校验和、连续空帧才抬手，80ms 超时兜底（`linux-mainline/overlays/linux/drivers/input/touchscreen/himax-dagu.c`）
- Chrome 屏上键盘：`linux-mainline/scripts/dagu-osk-focus@dagu/` 同时闸 `KeyboardManager.open`、`KeyboardActor.open` 和延迟的 `Actor._open`（GNOME 300ms rest timer 会绕过 `open()`）。点标签栏/关标签立刻收起；点地址栏立刻弹出；点网页只在随后有光标时才弹。`linux-mainline/scripts/dagu-snap@local/` 只截屏，禁止再调 `Main.keyboard.open`。改扩展 JS 后 gnome-shell 会缓存模块，需要重新登录才生效；`disable-user-extensions` 必须为 false。

### Wi‑Fi

- QCA6390，`pcie0` + ath11k，接口 `wlp1s0`
- BDF：dump `bd_l81a.elf` → `board.bin`，不要 `board-2.bin`
- 5GHz 80MHz 2SS PHY 约 866.7 Mbps；iperf3 反向 4 流约 **600–665 Mbps**
- SSH 示例：`ssh -i linux-mainline/out/id_dagu root@192.168.1.158`（地址随局域网变）
- SSID/密码只放本机 `tmp/wifi-info.md`，不入库
- 无可用 RTC 时时钟停在 rootfs 构建日（曾为 2026-07-27）。Chrome 能开 `www.bilibili.com` HTML，但 `static.hdslb.com` CSS 证书 **not yet valid**，页面无样式。开机/连上 Wi-Fi 跑 `linux-mainline/scripts/dagu-time-sync.py`（实机 `/usr/local/sbin/dagu-time-sync.py`、`dagu-time-sync.service`）

### 麦克风

- 路由：TX DEC0=`SWR_MIC`，SMIC MUX0=`ADC3`，ADC4 MIXER，ADC4 MUX=`INP5`
- `arecord` 2s → `/tmp/mic.wav` **192044 字节**（非空）
- 脚本：`linux-mainline/scripts/dagu-av-test.sh`

### CAMSS 后端（不含传感器 MIPI）

- CSID TPG 出过完整 1 帧：`/tmp/tpg.raw` 15618240 字节
- 结论：VFE DMA / SMMU / CAMNOC 已通；卡在传感器 HS 进 CSID

---

## 软件已通

### 扬声器（CS35L41 ×4）

- 总线：`i2c-gpio` 模拟 QUP SE1（gpio4/5）和 SE3（gpio119/120），**不开** `I2C_QCOM_GENI`
- 播放：ADSP Q6 + `TERT_TDM_RX_0`，2ch S24_LE 48 kHz，CAF `TDM_MAX_SLOTS=4`
- DAPM：四颗 `TL/TR/BL/BR Main AMP: On`；`speaker-test -l 3` 完整 3 轮 440 Hz
- overlay：`linux-mainline/scripts/apply-overlays.sh` 里 TDM `bit_width` 保持 16/24（slot_width=32）；强行 32 会让 AFE `0x100ef` 返回 `ADSP_EBADPARAM`
- **桌面无声根因（2026-09-12）**：WirePlumber ACP 认不出 Q6 mixer，卡停在 Profile=Off / Dummy Output；临时 `pro-audio` 会把 `hw:0,0` 开成 **8ch**，而 AFE 仍是 2ch。Chrome 看起来在播，喇叭仍可能无声。
- **GDM 后再无声（2026-09-12 10:32）**：`wpctl` 默认 sink 又是 Dummy；`EnumProfile` 只有 Off + pro-audio，`disable-pro-audio=true` 后卡在 Off。UCM `set _verb HiFi` 本身可用。修复：`linux-mainline/alsa/50-dagu-alsa-sink.conf` → `/etc/pipewire/pipewire.conf.d/` 直开 2ch `hw:0,0`；重启 PW 后也会出现 `alsa_output.platform-sound.HiFi__Speaker__sink`。实机 `pw-play` 440 Hz exit 0，播时四颗 AMP/SPK=On。
- **修复**：ALSA UCM2 HiFi（`PlaybackChannels 2`）+ 开机打开 `TERT_TDM_RX_0 Audio Mixer MultiMedia1`。文件：
  - `linux-mainline/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf`
  - `linux-mainline/alsa/ucm2/Xiaomi-dagu/HiFi.conf`
  - `linux-mainline/scripts/dagu-speaker-route.sh`
  - `linux-mainline/alsa/50-dagu-speaker.conf`（装到 `/etc/wireplumber/wireplumber.conf.d/`）
  - `linux-mainline/alsa/50-dagu-alsa-sink.conf`（装到 `/etc/pipewire/pipewire.conf.d/`）
- **听感（对齐安卓，2026-09-12）**：安卓 `mixer_paths_overlay_static.xml` 走 CS35L41 **DSP Protection**（`PCM Source=DSP`、`AMP PCM Gain=18`、`Digital=0 dB`、`DRE=on`、`TL/TR/BL/BR-cs35l41-dsp1-spk-prot.bin`）。Linux 之前切成 ASP 直通，没有 Xiaomi 调音/DRC，所以再加大数字增益也和安卓差一截。`linux-mainline/scripts/dagu-speaker-route.sh` 现按安卓路径 preload 每颗功放的 prot.bin。
- **拉满仍然很小声（2026-09-12）**：不是 GNOME 滑条，也不是再加数字增益。实机 DSP XM：`CAL_R=0`、`CAL_STATUS=0`，Halo Protection 按未校准阻抗限幅。安卓 persist 工厂值约 6.8 Ω（`cal_r` 9497–9696）。wm_adsp 把 `CAL_R` 标成 SYS，ALSA 写不进去。编核后由 `linux-mainline/scripts/apply-overlays.sh` 在 preload 完写 XM，DTS `cirrus,cal-r` / `cirrus,vpbr-config` 在 `linux-mainline/dts/sm8250-xiaomi-dagu.dts`。PipeWire 已是 S24_32LE、音量 1.0；模拟增益 18 也对。`*-music.txt` Fast Use Case 还没接（主线没有该 mixer）。

`&adsp` okay，固件 `qcom/sm8250/xiaomi/dagu/adsp.mbn`。需要 `CONFIG_QRTR_SMD=y`（不要 =m），否则 PDR/APR 起不来。

---

## 部分（相机）

目标仍是：后摄至少 1 帧 + 前摄至少 1 帧。CSID TPG 已证明 ISP 后端没问题。

### 后摄 Samsung s5kjn1（主摄 / csiphy1）

| 项 | 现状 |
|----|------|
| 电源 / MCLK / 复位 / CCI | probe 成功，进 media 图 |
| 预览尺寸 | 4080×3060 GBRG 10-bit，fourcc `pGAA`，`/dev/video0` |
| PHY | CamX 4080 预览是 **C-PHY 3-trio**（`0x0114=0x0301`）；8160 抓拍才是 D-PHY |
| DT | `bus-type = <MEDIA_BUS_TYPE_CSI2_CPHY>`（值为 **1**），`data-lanes = <1 2 3>` |
| CSIPHY | `cphy=1`，`c7=0x52`，`c5=0x2a` |
| CSID | `cfg0` bit24 `PHY_TYPE_SEL` 已置 |
| STREAMON | **失败**：CCI 写 `0x6028` 切 page `0x2400` NACK（`-ENXIO`），`/tmp/rear.raw` 0 字节 |

已踩过、不要退回去的坑：

- `s5kjn1_check_hwcfg` 曾写死 `V4L2_MBUS_CSI2_DPHY`，DT 改 C-PHY 后 probe `-ENXIO`，前摄 link 也建不成
- 曝光默认 3840 > VTS 3164−margin → `init controls` `-ERANGE`
- 主线 init 里 `0x0bcc` 16/8-bit 都 NACK，已从 init_array 拿掉
- 先 `s_power` 再开 CSIPHY 会在 CAM_CC GDSC 起来前使 `cam_cc_mclk0_clk` stuck off
- 把 `vreg_l3a_0p9` 改成 1.104V **禁止**

对照：`dumps/dagu-android-live/camera/com.qti.sensormodule.dagu_qtech_s5kjn1_wide.bin`

### 前摄 Sony IMX596（csiphy4）

| 项 | 现状 |
|----|------|
| 地址 | CAF dtsi 写 `@0x1a`；这颗硅在 **0x10** 读到 chip id `0x0596` |
| 驱动 | `linux-mainline/overlays/linux/drivers/media/i2c/imx596-dagu.c` |
| 尺寸 | 2592×1952 BGGR 10-bit，fourcc `pBAA`，`/dev/video3` |
| PHY | 仍 **D-PHY**（`bus-type = <4>`，4 lane） |
| 开流 | 驱动报 streaming；`phy=0x1 lanes=0x1` 像 2-lane 读回 |
| 抓帧 | `/tmp/front.raw` **0 字节**；CSIPHY4 有 IRQ，HS 仍未进 CSID |

PLL / lane 尚未按 CamX `com.qti.sensormodule.dagu_aac_imx596_front.bin` 对齐。

### SLPI

`&slpi` **disabled**。overlay README：传感器走 SLPI，`stage-firmware.sh` 找到 `slpi.mbn` 后再把 `&slpi` 设 okay。不要在 AP I2C 上猜 IMU/ALS。

---

## DT 已写、未专项验收

节点在 `linux-mainline/dts/sm8250-xiaomi-dagu.dts`，探测脚本：`linux-mainline/scripts/dagu-periph-test.sh`。

| 外设 | 硬件 | 说明 |
|------|------|------|
| 双电芯 | BQ27Z561 ×2 + `xiaomi,dual-fuel-gauge` | overlay `linux-mainline/overlays/linux/drivers/power/supply/xiaomi-dual-fg.c`；设计 5000 mAh ×2 |
| 充电（SMB5） | PM8150B `@1000` | overlay `linux-mainline/overlays/linux/drivers/power/supply/pm8150b-charger-dagu.c`；关 charger wdog、清 USBIN suspend。5 V 路径 ICL **2 A**（墙充常被 APSD 成 SDP，不要 USB51 500 mA）。AICL 仍可折叠。GPIO74 低电平放行 VBUS |
| 充电泵 | BQ25970 ×2 | `bq2597x-dagu.c`，i2c-gpio；67W PPS，不是 5 V 主路径 |
| 无线充探测 | P9418 | `p9418-dagu.c` |
| 霍尔 | GPIO110 lid、GPIO121 tablet | `SW_LID` / `SW_TABLET_MODE`；folio 磁铁拉低 121，空闲应为平板。活 DT 用 `GPIO_ACTIVE_HIGH`。未刷新核前由 `linux-mainline/scripts/dagu-tablet-mode.py` 注入 |
| 音量上 | pm8150 gpio6（elish-common） | |
| 马达 | PM8150B `@c000` LRA | 主线 `qcom,pmi632-vib` |
| 闪光灯 | pm8150l `@d300` | `echo 64 > /sys/class/leds/white:flash/brightness` |
| USB OTG | `dr_mode=otg`，默认 peripheral | 切 host 会掉 g_serial，只能走 Wi‑Fi SSH；`usb_1_qmpphy` **disabled**。`pm8150b_typec` **okay**（充电 / PD），USB 图仍切断 |
| USB3 / DP redriver | PS5169 overlay | 活 DT 未挂节点；`i2c17` 仍 disabled |
| 磁吸键盘 MCU | nanosic overlay | 活 DT 未挂；QUP SE2 I2C 不能开（与 uart2 冲突且 GENI 会挂 QHEE） |

---

## 有意关闭

| 项 | 原因 |
|----|------|
| `CONFIG_SPI_QCOM_GENI` / `&spi4` | `geni_load_se_fw` / `geni_se_init` 写 SE MMIO 挂死这套 QHEE |
| `CONFIG_I2C_QCOM_GENI` | 同上；喇叭/电量改 i2c-gpio |
| 给 `&qupv3_id_0` 加 `firmware-name` / 写 wrapper CSR | 会打回兔子；uart6 只把 stock `qupv3fw.elf` 写进 SE6 IRAM |
| `CONFIG_INTERCONNECT_QCOM_SM8250` | BCM `rpmh_write_batch` 超时，拖死 USB/MDSS/CPU OPP |
| `&usb_1_qmpphy` | P0 只要 HS gadget；SS 未训 |
| Type-C → DWC3 graph | 等 TCPM 曾让 DWC3 停在 otg、无 UDC；节点本身已 okay 做充电 |
| `&venus` / `&cdsp` | 避免缺固件 stall |
| `&slpi` | 未验签名固件前不开 |
| GENI 触控 / 给 `&qupv3_id_0` 加 `firmware-name` | 与 SPI 同一挂点 |

---

## 未做 / 下一步

优先级按用户目标（相机出帧）和「听得到喇叭」：

1. **后摄出 ≥1 帧**：对齐 CamX 的 `0x6028` page `0x2400` 写入时机（或先在 `0x4000` 写完再切页）；不要退回瞎猜的 D-PHY PLL
2. **前摄出 ≥1 帧**：按 CamX imx596 bin 对齐 PLL / lane（读回像 2-lane）
3. **扬声器听感**：桌面应出现 Speakers sink（不是 Dummy）。Chrome 播音乐；也可 `linux-mainline/scripts/dagu-av-test.sh` 听 440 Hz
4. **充电验收**：插 5 V 砖后 `pm8150b-charger` `status=Charging`，`bms` `current_now` 为负（充电）；PD 砖看 TCPM log。67W 泵以后再接
5. OTG host：Wi‑Fi SSH 下切 role，插 U 盘 / HID
6. 霍尔、马达、torch 用 `dagu-periph-test.sh` 点一次
7. 蓝牙音频（A2DP / 耳机）专项听感；控制器本身已通
8. SLPI：固件签名确认后再开 IMU/ALS
9. USB3 + DP + PS5169：先保证 HS gadget 不回退
10. 磁吸键盘：没有安全的 GENI I2C 之前无法走原厂 MCU 总线
11. RTC / 对时
12. Win11 ARM：独立于本表

验收命令备忘：

```bash
# 喇叭 / 麦 / 相机（走 Wi‑Fi SSH，会响 3 轮 440 Hz）
linux-mainline/scripts/dagu-av-test.sh

# GPU / 电量 / OTG / hall / 闪光灯
linux-mainline/scripts/dagu-periph-test.sh
```

---

## 关键路径（仓库内）

| 用途 | 路径 |
|------|------|
| 板级 DT | `linux-mainline/dts/sm8250-xiaomi-dagu.dts` |
| 显示/音频/相机 fragment | `linux-mainline/config/dagu-display.fragment` |
| USB fragment | `linux-mainline/config/dagu-usb.fragment` |
| overlay 打补丁 | `linux-mainline/scripts/apply-overlays.sh` |
| 刷 B | `linux-mainline/scripts/flash-boot.sh flash-b` |
| 救砖 | `linux-mainline/scripts/flash-boot-legacy.sh restore-a` |
| 固件暂存 | `linux-mainline/scripts/stage-firmware.sh` |
| 当前 boot 镜像 | `linux-mainline/out/boot-dagu.img` |

内核源码树 `linux-mainline/linux/` **不入库**；相机/音频对主线驱动的修改都在 `apply-overlays.sh` 里重放。
