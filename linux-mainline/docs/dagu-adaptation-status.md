# dagu 主线 Linux 适配总表

记录日期：**2026-09-12**。  
设备：小米平板 5 Pro 12.4（`dagu` / SM8250 / `22081281AC`）。  
运行系统：Linux 7.0 + Ubuntu（userdata），只刷 **B 槽**。  
内核构建：`DAGU_MINIMAL=1 DAGU_DISPLAY=1`。镜像：`linux-mainline/out/boot-dagu.img`。

本表只写 **当前主线 Linux 实机状态**。仓库里另有 UEFI / Win11 ARM 调研（`docs/uefi-port-dagu.md`、根 `README.md`），那不是现在每天在跑的系统。

相关细账：

- Wi‑Fi / GPU / Turnip / CPU：`linux-mainline/docs/dagu-wifi-gpu-turnip-cpu.md`
- Adreno 650 LINEAR destile / 毛玻璃花屏（稳定底稿）：`linux-mainline/docs/dagu-a650-linear-destile.md`
- 图形同步 / Mineradio 白屏 / CS35L41 硬件音量：`linux-mainline/docs/dagu-deep-hardware-reclamation.md`
- 触控 IRQ / SYN 抖动（已停抓）：`linux-mainline/docs/dagu-touch-irq-jitter.md`
- 静置掉帧 / 锁频对照 / DPU vblank timeout：`linux-mainline/docs/dagu-idle-pipeline.md`
- Overlay 驱动清单：`linux-mainline/overlays/README.md`
- 板级 DT：`linux-mainline/dts/sm8250-xiaomi-dagu.dts`
- 安卓 dump 硬件清单（未随主线更新）：`docs/hardware-inventory.md`
- ARM Linux 七维评估（含 Python / CPU 软路径）：`linux-mainline/docs/dagu-arm-linux-eval.md`
- CAMSS VFE PIX 审计（IFE no-go）：`linux-mainline/docs/dagu-camss-pix-audit.md`

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
- **适配，不妥协**：旧「花屏合同」是 Ozone 标 LINEAR + GBM 却选 UBWC。official-152 已把 `gbm_bo_get_modifier()` 如实交给 `zwp_linux_buffer_params_v1.add`。2026-09-13 已撕合同：Chrome **不再** `LD_PRELOAD libdagu-linear-mod.so`，窗口 2477×1560 / 标签 1823×88 均为 `QCOM_COMPRESSED`。Mutter 去掉 `disable-direct-scanout`（主 fb 仍 UBWC）。`DAGU_TEAR_CONTRACT=1` 走 Turnip，`chrome://gpu` Vulkan=Enabled，Venus 仍 `/dev/video14`。**禁止**给 gnome-shell 设 `FD_MESA_DEBUG=notile` / `dagu-mesa` / `libdagu-linear-mod.so`。不要关 GPU 栅格。包装：`linux-mainline/scripts/dagu-chromium-native.sh`。

---

## 总览

| 子系统 | 状态 | 一句话 |
|--------|------|--------|
| 启动链 / B 槽 Linux | **已通** | 7.0 Image 站住，g_serial >30s |
| UFS + Ubuntu 桌面 | **已通** | userdata ext4，GNOME。内部 UFS 其它 LUN 对 Nautilus / Resources 隐藏，只留 userdata（sda）和 USB |
| USB gadget 串口 | **已通** | `0525:a4a7` / `ttyGS0` |
| 显示 L81A 120Hz | **已通** | 1600×2560，DSC dual-DPHY |
| GPU Adreno 650 / Turnip | **已通** | GMU + Mesa。LINEAR GMEM store/fetch **FIXED**。主 fb UBWC，Chrome LINEAR GMEM 共存。hangcheck `00800005` 仍会偶发 recover |
| CPU 调频 + 温度 | **已通** | EPSS LUT，stress-ng 8/8 |
| 触控 Himax | **已通** | `spi-gpio`，不要 GENI SPI |
| Wi‑Fi QCA6390 | **已通** | ath11k，iperf 约 600–665 Mbps |
| 扬声器 CS35L41 | **软件已通** | ADSP `running`（`adsp.mbn`）。SoundWire 扫到 WCD9385 RX/TX，**没有** WSA88xx（外放是 CS35L41×4）。`aplay -l` card 0 `Xiaomi-dagu-CS35L41-WCD9385`。PW 默认 Speakers。见 `linux-mainline/docs/dagu-audio-s2idle.md` |
| 麦克风 | **已通** | 安卓 speaker-mic：AMIC5 / ADC4 INP5。UCM HiFi Mic，`hw:0,1`。喇叭 440 Hz 回录 |
| 后摄 s5kjn1 | **已通（预览）** | live D-PHY 4-lane RAW10 `pGAA` 4080×3060，SoftISP skip 4×4 → 1020×764 @~30fps |
| 前摄 imx596 | **已通（预览）** | D-PHY 4-lane RAW10 `pBAA` 2592×1952，SoftISP skip 2×2 → 1296×976 @~30fps |
| CAMSS VFE/SMMU | **已通** | CSID TPG 出过完整 1 帧（约 15.6 MB） |
| 蓝牙 | **已通** | QCA6390 uart6：stock `qupv3fw.elf` 只写 SE6；`hci0` `<bt-mac>` Powered: yes。DT 对照 elish/`qcom,qca6390-bt`：`max-speed` 3 Mbps + PMU LDO，BT_EN 走 pmu pwrseq。BLE 鼠标走 HOG（`CONFIG_UHID` + `CONFIG_BT_LE`）。经典 HID：`ClassicBondedOnly=false` + `UserspaceHID=persist`。寻呼带 clock offset，HID 主机 Central + FastConnectable，sniff 6–18。Page Timeout 拆 unset-handle ACL。GNOME Settings 是配对 UI：6390 去掉 `HCI_QUIRK_SIMULTANEOUS_DISCOVERY`，type 7 由内核分时 LE/Inquiry；`dagu-bt-hid-host.sh` 保持 Pairable/PSCAN。`TemporaryTimeout=180`。保留 sniff / UART RPM / IBS / WakeAllowed |
| USB OTG Host / DP | **DT 已写** | HS OTG 角色可切；SS PHY / PS5169 未在活 DT 接上。`pm8150b_typec` 已 okay（CC/PD），USB 图仍切断以免 DWC3 等角色 |
| 双电芯电量 | **DT 已写** | 双 BQ27Z561 + `xiaomi-dual-fg`，脚本可查 `power_supply` |
| 充电（SMB5） | **DT+驱动已写** | PM8150B `@1000` overlay；GPIO74 拉低放行 VBUS。未刷核验收 |
| 充电泵 / 无线充 | **DT 已写** | BQ25970 ×2 只做 PPS 快充，P9418 探测；5 V 不靠泵 |
| 霍尔 / 音量键 | **DT 已写** | gpio-keys；未专项验收 |
| 马达 | **DT 已写** | PMI632 LRA；未专项验收 |
| 闪光灯 | **DT 已写** | pm8150l flash；脚本可点 torch |
| 磁吸键盘 | **未做** | overlay 有，活 DT 没接（QUP I2C 不能开） |
| IMU / 光线传感器 | **有意关闭** | `&slpi` disabled，不在 AP I2C 上猜 |
| 视频编解码 Venus | **软件已通（4K60 HEVC dmabuf）** | `#169`：1080p H.264 + **4K60 HEVC** `DMA_DRM`/`NV12` 上 Mutter，无 SMMU/SSR。日常播放器：`gst-play-1.0 --videosink=waylandsink`。mpv 仍是 `v4l2m2m-copy`。**禁止**开 SM8250 ICC。见 `linux-mainline/docs/dagu-venus.md` |
| CDSP | **有意关闭** | `status = disabled` |
| 蓝牙音频 / 耳机口 | **未做** | 板子无 3.5mm；控制器已通，A2DP / 耳机听感未测 |
| S2Idle | **电源键可唤醒** | `mem_sleep=[s2idle]`，`echo mem` 睡约 65 min，`success=1`。DPU UBWC、Venus 节点、ADSP 都在，无 hangcheck/SSR。远程无 RTC/USB 唤不醒。见 `linux-mainline/docs/dagu-audio-s2idle.md` |
| RTC | **没有设备** | 无 `/dev/rtc*`，`rtcwake` 不可用。用户态时钟靠 NTP |
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
- 滑动窗口花屏 / GNOME 断触：fb0 Himax 测试丝滑。GNOME 主 fb 曾是 **XR30 10bpc**（L81A DSC 是 8bpc），再加 `CLUTTER_PAINT` 全屏重绘会拖死输入。内核 #149 已去掉 plane 10bpc（`linux-mainline/scripts/apply-overlays.sh`），实机主 fb 现为 `format=XR24` `modifier=0x050000000000001`（`QCOM_COMPRESSED`，`MUTTER_DEBUG_USE_KMS_MODIFIERS=1`）；用户态去掉 `CLUTTER_PAINT`、`GSK_RENDERER=ngl`、关掉 onboard / linger（`linux-mainline/scripts/rootfs-desktop-setup.sh`）
- Chrome / Electron 组件花屏：**FIXED**。Ozone 把 `LINEAR + QCOM_COMPRESSED + QCOM_TILED3 + INVALID` 交给 `gbm_bo_create_with_modifiers`，但 `zwp_linux_buffer_params_v1.add` **永远标 modifier 0,0**。客户端 `linux-mainline/scripts/dagu-linear-mod.c`（`/usr/local/lib/libdagu-linear-mod.so`）只把窗口级 AR24/XR24（任一边 >1024）做成真 `GBM_BO_USE_LINEAR`；`GBM_FORMAT_R8` 与两边都 ≤1024 的 UI 图集原样 TILE/UBWC（无差别 LINEAR 会把 Skia 图集打成 1-bit 砖）。dagu-mesa 4bpp 钩子只在宽和高都 >1024 时动手（躲开 Skia `3840×360` 图集），见 `linux-mainline/patches/mesa-26.0.8-atlas-passthrough.patch`。dagu-mesa 按官方 blob 补了 a650 event-store（`LAST=2`）和 UCHE GMEM 基址 0，LINEAR 窗可以进 GMEM。正式补丁：`linux-mainline/patches/0001-freedreno-a6xx-fix-event-store-linear-layout.patch`、`linux-mainline/patches/0002-freedreno-a6xx-fix-gmem-fb-read-linear-base-offset.patch`。Chrome / Mineradio 用 `LD_LIBRARY_PATH=/usr/local/lib/dagu-mesa`。**不要**把 dagu-mesa / linear-mod 进 gnome-shell。历史字体花：旧 `BLIT_EVENT_STORE` 把 LINEAR 写成 macrotile；大色块还能认，顶栏字形变成 1-bit 块（`linux-mainline/out/display-stress/dagu-fb0-now.ppm`，`font_unique=3` `font_tile32=0.81`），滚动再 store 损坏 tile。GSK 字形带 stencil；**不要**给 gnome-shell 开 `DAGU_LINEAR_SYSMEM`（会把 scanout 写黑）。`DAGU_LINEAR_DESTILE` 保持关。量化：`linux-mainline/scripts/dagu-fb-score.py` 的 `font_unique>=20` `font_aa>=40` `font_tile32<0.35`。测试页 `linux-mainline/scripts/dagu-font-probe.html`。KMS 特写 `linux-mainline/out/display-stress/probe-glyph-3x.png` 笔画完整，不是 1-bit 砖。任意 Mutter 缩放（本机 `1.0 / 1.25 / 1.333 / 1.667 / 2.0 / 2.5 / 2.667`，无 1.5）：**不要**锁死 scale 2，也**不要**关 `WaylandFractionalScaleV1`（关了之后 Chrome 只按整数 DPR 栅格，mutter 再二次缩放，1.25 会糊成「乱码」）。270° 扫出上 LCD RGB 在逻辑横屏上是错轴，必须灰度：`--disable-lcd-text`、`--font-render-hinting=none`、`linux-mainline/scripts/99-dagu-gray-fonts.conf`（`rgba=none`）、gsettings `font-antialiasing=grayscale`。实机 DPR 跟随缩放（1.25 时 `DPR=1.250`，见 `linux-mainline/out/display-stress/scale-sweep-dpr/unlocked-ui.png`）。扫描脚本 `linux-mainline/scripts/dagu-scale-font-sweep.py`，裁剪 `linux-mainline/scripts/dagu-kms-land-crop.py`。计分读 KMS，不要信 GDM 后的 `/dev/fb0`。锁屏/PowerSave 会挡住窗口，扫图前要 `PowerSaveMode=0` 且 `ScreenSaver.SetActive(false)`。Mineradio 是 Electron（`/opt/Mineradio/resources/app/desktop/main.js`）+ `THREE.WebGLRenderer`（r128，`antialias:false` `alpha:true`）粒子/歌词 Shader + 大量 CSS `backdrop-filter`，主窗 `transparent:true`。包装器 `linux-mainline/scripts/dagu-mineradio.sh` 与 Chrome 同一套分数 DPR / 灰度 / LINEAR；**禁止** `FD_MESA_DEBUG=notile`（tiled WebGL 会 CCU hang）。对照页 `linux-mainline/scripts/dagu-mineradio-probe.html`。毛玻璃专页 `linux-mainline/scripts/dagu-glass-probe.html`。2026-09-12：GMEM store/restore/同 batch FB fetch 真线性（UCHE 采 cbuf 0）。UBWC 桌面下 Chrome hunt `sys=0 fbread=1` 68 条。`dagu-chrome.sh` **不设** `DAGU_LINEAR_SYSMEM` / `DAGU_LINEAR_DESTILE`。金样 `linux-mainline/out/display-stress/glass-gmem-fbread-full.png`。全程见 `linux-mainline/docs/dagu-a650-linear-destile.md` §9.6 / §9.7。**不要**把 `DAGU_LINEAR_SYSMEM` / dagu-mesa / linear-mod 给 gnome-shell。
- Chrome 页内矢量 / iconfont：必须 GPU raster。Chrome 153 / Skia `4f574af` `AtlasPathRenderer` 用 instanced VS 画进 A8 图集。autotune 曾把小 A8 逼去 CCU sysmem（写成条纹）；现强制 GMEM event-store。8× 金样：`linux-mainline/out/display-stress/chrome-msaa-resolve-shouye-8x.png`。BO dump：`linux-mainline/out/display-stress/path-atlas/`。源码：`a local Chromium checkout/`。说明：`linux-mainline/patches/mesa-26.0.8-icon-upload.md`。
- Chrome 自己的标签栏 / 后退前进刷新 / 网站设置：页内 SVG 修好后这几个还花。Views 把 `CreateVectorIcon` 画进 ≤128² cache；GPU 写的是 **TILE6_3**（destile 锐利），工具栏却按 **LINEAR** 去采。现改 LINEAR + GMEM 真线性。8×：`linux-mainline/out/display-stress/chrome-ui-linicon-toolbar-8x.png`、`linux-mainline/out/display-stress/chrome-ui-linicon-tabbar-8x.png`。窗口 `2477×1560` **不要**强制 GMEM（拖动掉帧）。仍禁止 `--disable-gpu-rasterization`。

### GPU（Adreno 650）

- `&gpu` / `&gmu` / `&adreno_smmu` okay
- zap：本机签名 `qcom/sm8250/xiaomi/dagu/a650_zap.mbn`（不要 elish）
- SQE：linux-firmware **31964 字节、word1 `0x112`**；dump 旧 0.93 会被拒
- `gpu-initialized: 1`，`/dev/dri/card0` + `renderD128`，GNOME 走 msm atomic（不是 llvmpipe）
- GNOME Resources 只扫 `/sys/class/drm/card0/device`（DPU，不是 `3d00000.gpu`）。`linux-mainline/overlays/linux/drivers/gpu/drm/msm/msm_gpu_resources_sysfs.c` 提供 `gpu_busy_percent`、`mem_info_vram_*`、`hwmon/freq1_input` / `temp1_input`（来自 devfreq / thermal）。Resources 只认 `hwmon?`，由 `linux-mainline/scripts/dagu-resources-fix.sh` bind 成 `hwmon0`。禁止伪造：UFS 不是 PCIe，硬盘 Link / GPU Slot / Max Power Cap 等没有真实值的项由 `linux-mainline/scripts/dagu-resources-hide-na.c` 藏行。禁止 bind 覆盖 `/sys/class/drm/card0/device/uevent`（假 PCI_ID 会让 Chrome `drmGetDeviceFromDevId` 失败、`--in-process-gpu` 整进程退出）。`linux-mainline/scripts/dagu-chrome.sh` 会清掉已死进程的 Singleton 锁。Wi‑Fi Manufacturer 用发行版 `/usr/share/misc/pci.ids` 复制到 `/usr/share/hwdata/pci.ids`（须双空格）。CPU 名走包装 `lscpu`（Kryo 585 / Snapdragon 870）。
- 用户态：Mesa Turnip，`vkcube` 选中 Adreno 650
- **卡顿（2026-09-13）**：B 站滑动 kickoff 从 63 Hz / 151 ms 洞收到 **99–106 Hz / p99 18–25 ms**（`jank-capture-20260913-073051` / `073805`）。首页慢滑基线仍是 `074651`：**87 Hz / max 178 / >50=4**。Chrome Ozone 等的是 `wl_surface.frame`（`WaitForFrameCallback`），不是 viz TRACE 名。NOP 非 primary 也发 callback（`085900`/`090107`）和空 unobscured 整窗 destile（`090343`）都把慢滑打到 52–56 Hz、洞更多；日常 **已卸** `libdagu-mutter-frame-flush.so` / `libdagu-mutter-damage.so`。底稿 `linux-mainline/docs/dagu-idle-pipeline.md` §5 / §8–§13。不要关 GPU raster，不要锁 `governor=performance`。仍禁止 Chrome LINEAR 直扫 DPU。
- **Chrome 播视频抽帧（2026-09-13）**：官方 Chrome 153 `USE_V4L2=0`，只能软解。一线是 **official-152 V4L2** `/usr/local/bin/dagu-chromium`（`linux-mainline/scripts/dagu-chromium.sh`）。`chrome://gpu` Video Decode = Hardware；1080p30 **H.264 / VP9 / HEVC / VP8**（NV12，irq 530 / 597 / 891 / 581）以及 **HEVC Main10 / VP9 profile2**（**P010**，irq **883** / **628**）都打开 `/dev/video14`（`V4L2StatefulVideoDecoder`，不是 FFmpeg）。10-bit 必须丢掉 NV12 候选并补 P010 stride，否则 QBUF EIO / GPU `exit_code=5`。official-152 还修了 HEVC `NOTIMPLEMENTED` 和 VP8 的 32-buffer CHECK/分配。Video Encode：MediaRecorder **H.264 irq=203 / VP8 irq=208 / HEVC Main irq=229 / HEVC Main10 irq=238** 打开 `/dev/video15`。掉帧是 270° 下整窗合成的 `WaitForSwap`（花屏合同已撕：窗口已是 UBWC，Mutter 已允许直扫，但最大化窗还没有第二块 DPU plane）。不要 VA-API，不要关 GPU 栅格。Vulkan/Turnip：`DAGU_TEAR_CONTRACT=1`。验收：`linux-mainline/out/display-stress/chrome-gpu-accept.json`。底稿 `linux-mainline/docs/dagu-chrome-gpu-venus.md`。
- **hangcheck**：本 boot 见过数次 `gpu fault status 00800005` + recover，能起来。这是 CCU/CP 指令流故障，不是温控墙（空闲 GPU ~50–58°C；35s 玻璃+videotestsrc 升到 ~80°C、670 MHz，recover 计数仍为 4）。`/sys/kernel/debug/dri/0/hangrd` 在未 hang 时 `EBUSY`。`linux-mainline/scripts/dagu-gpu-hangwatch.sh` 盯 `hangcheck recover` 再 dump 到 `/var/log/dagu-gpu/`。压测：`linux-mainline/scripts/dagu-gpu-stress.sh`。
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
- IRQ 亲和：`dagu-himax-irq-affinity.service` 把 himax IRQ 持久绑到 CPU4–7（Gold）。不要跟 SoftISP 抢 CPU0。
- Snapshot 开后置点不了：Himax 仍报点（背光会醒），mutter 被 12MP CPU SoftISP 饿死。默认关掉常驻 `dagu-camera-loopback` 双路 STREAMON；Viewfinder Bayer skip（后置 /4、前置 /2），StillCapture 仍全幅。SoftISP cpuset CPU0–3。板上推送：`linux-mainline/scripts/dagu-snapshot-touch-deploy.sh`。libcamera 源码：`dagu-libcamera-softisp.sh`。验收：预览实时且关窗口跟手。
- 滑动断触：IRQ 线程里不要 `dev_info`（`ignore_loglevel` 会堵 fbcon/串口）；DT 用 `IRQ_TYPE_LEVEL_LOW`，坏帧（全 0xff）不当抬手
- OSK 连打字母：LEVEL_LOW + spi-gpio 会在一次按住里读到校验失败 / n=0 毛刺，tracking ID 被拆成多次点击。驱动排空 IRQ、校验和、连续空帧才抬手，80ms 超时兜底（`linux-mainline/overlays/linux/drivers/input/touchscreen/himax-dagu.c`）
- 滑动微跳帧（2026-09-13）：静置仍抽帧，停抓 SYN。`vblank timeout: 400000` 是 **DSC_IDX=22**（L81A 双 DSC），不是幽灵 `SSPP_CURSOR0`。`MUTTER_DEBUG_DISABLE_HW_CURSORS=1` 早已生效。细账 `linux-mainline/docs/dagu-idle-pipeline.md`。
- Chrome 屏上键盘：`linux-mainline/scripts/dagu-osk-focus@dagu/` 同时闸 `KeyboardManager.open`、`KeyboardActor.open` 和延迟的 `Actor._open`（GNOME 300ms rest timer 会绕过 `open()`）。点标签栏/关标签立刻收起；点地址栏立刻弹出；点网页只在随后有光标时才弹。`linux-mainline/scripts/dagu-snap@local/` 只截屏，禁止再调 `Main.keyboard.open`。改扩展 JS 后 gnome-shell 会缓存模块，需要重新登录才生效；`disable-user-extensions` 必须为 false。

### Wi‑Fi

- QCA6390，`pcie0` + ath11k，接口 `wlp1s0`
- BDF：dump `bd_l81a.elf` → `board.bin`，不要 `board-2.bin`
- 5GHz 80MHz 2SS PHY 约 866.7 Mbps；iperf3 反向 4 流约 **600–665 Mbps**
- SSH 示例：`ssh -i linux-mainline/out/id_dagu root@192.168.7.2`（地址随局域网变）
- SSID/密码只放本机 `tmp/wifi-info.md`，不入库
- 无可用 RTC 时时钟停在 rootfs 构建日。产品路径用 `systemd-timesyncd`，不再装 `dagu-time-sync.py`。

### 麦克风

- 安卓 `mixer_paths_overlay_static.xml` speaker-mic：TX DEC0=`SWR_MIC`，SMIC MUX0=`ADC3`，ADC4 MIXER，ADC4 MUX=`INP5`（WCD9385 AMIC5 / MIC BIAS3）
- 主线还要 `ADC4 Switch` + `TX3 MODE=ADC_NORMAL` 才能打开 SoundWire ADC 口。无 Fluence，模拟增益 12（18 dB）
- 采集 FE 是 MultiMedia2（`hw:0,1`），不跟喇叭 MM1 抢 PCM。UCM `HiFi` → `Built-in Microphone`
- 喇叭 440 Hz → 麦克风 Goertzel 检出。推送：`linux-mainline/scripts/dagu-mic-deploy.sh`
- 脚本：`linux-mainline/scripts/dagu-mic-route.sh`、`linux-mainline/scripts/dagu-av-test.sh`

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
- **GDM 后再无声（2026-09-12 10:32）**：`wpctl` 默认 sink 又是 Dummy；`EnumProfile` 只有 Off + pro-audio，`disable-pro-audio=true` 后卡在 Off。UCM `set _verb HiFi` 本身可用。曾用 `pipewire.conf.d` 直开 2ch `hw:0,0`。
- **整段会话无声（2026-09-13）**：不是功放掉线。登录瞬间 `/proc/asound/cards` 还没有 card 0，`context.objects` 打开 `hw:0,0` 失败 → PipeWire **exit 234** → `pipewire.socket` `start-limit-hit`，6 小时都没有 PW。dmesg 里 ADSP/CS35L41 仍正常。修复：撤掉致命的 `pipewire.conf.d/50-dagu-alsa-sink.conf`；`linux-mainline/scripts/dagu-audio-up.sh` 等 `/dev/snd/pcmC0D0p` 再拉 PW，UCM 出 `HiFi__Speaker__sink`；用户单元 `linux-mainline/systemd/dagu-audio-up.service`；`linux-mainline/systemd/pipewire-dagu-restart.conf` 防止再被限频。本机无 `pactl`。
- **修复**：ALSA UCM2 HiFi（`PlaybackChannels 2`）+ 开机打开 `TERT_TDM_RX_0 Audio Mixer MultiMedia1`。文件：
  - `linux-mainline/alsa/ucm2/conf.d/sm8250/Xiaomi-dagu-CS35L41-WCD9385.conf`
  - `linux-mainline/alsa/ucm2/Xiaomi-dagu/HiFi.conf`
  - `linux-mainline/scripts/dagu-speaker-route.sh`
  - `linux-mainline/alsa/50-dagu-speaker.conf`（装到 `/etc/wireplumber/wireplumber.conf.d/`）
  - `linux-mainline/alsa/50-dagu-alsa-sink.conf`（装到 `/etc/pipewire/pipewire.conf.d/`）
- **听感（对齐安卓，2026-09-12）**：安卓 `mixer_paths_overlay_static.xml` 走 CS35L41 **DSP Protection**（`PCM Source=DSP`、`AMP PCM Gain=18`、`Digital=0 dB`、`DRE=on`、`TL/TR/BL/BR-cs35l41-dsp1-spk-prot.bin`）。Linux 之前切成 ASP 直通，没有 Xiaomi 调音/DRC，所以再加大数字增益也和安卓差一截。`linux-mainline/scripts/dagu-speaker-route.sh` 现按安卓路径 preload 每颗功放的 prot.bin。
- **拉满仍然很小声（2026-09-12）**：不是 GNOME 滑条，也不是再加数字增益。四颗 CS35L41 **在通路里**（DSP 已载 L81A Music prot.bin，`Analog PCM=18` `Digital PCM=0 dB`）。`-110` 是 PMD 关断超时，不是没上电。安卓 tinymix 里 Halo `CAL_SET_STATUS=2`；现网内核只写到 `CAL_STATUS=1`。主线没有 Fast Use Case mixer，`*-music.txt` 还没灌。控件名已对齐主线（`Analog PCM` 不是 `Analog PCM Volume`）。底稿 `linux-mainline/docs/dagu-deep-hardware-reclamation.md`。禁止 softvol。
- **拉满仍然很小声（2026-09-15）**：通路、sink、Analog 18 / Digital 817、Fast Use Case music.txt 都在。主线 `cs35l41_pcm_hw_params` 把 `params_width`（S24_LE=24）写进 `ASP_WIDTH_RX`，而 Q6 TDM 是 **32-bit slot × 4**。安卓 CAF DAGU 是 `ASP_WIDTH=params_physical_width`（32）+ `RX_WL=24`。槽宽差 8 bit → MSB 空约 **-48 dB**。overlay 已按 CAF 拆开 slot/sample；Class-H tracking mixer 对齐安卓 `Enable=1` / `Target=0`。禁止 Digital PCM / softvol 补响。

`&adsp` okay，固件 `qcom/sm8250/xiaomi/dagu/adsp.mbn`。需要 `CONFIG_QRTR_SMD=y`（不要 =m），否则 PDR/APR 起不来。

---

## 部分（相机）

目标仍是：后摄至少 1 帧 + 前摄至少 1 帧。CSID TPG 已证明 ISP 后端没问题。

### 后摄 Samsung s5kjn1（主摄 / csiphy1）

| 项 | 现状 |
|----|------|
| 电源 / MCLK / 复位 / CCI | probe 成功，进 media 图。上电顺序 VIO → VANA → VDIG → MCLK → XSHUTDOWN |
| 预览尺寸 | 4080×3060 GBRG 10-bit，fourcc `pGAA`，`/dev/video0` |
| PHY | 安卓预览 **D-PHY 4-lane**（live CSIPHY `0x0800=0x02` / `0x0814=0xD5`，`0x0114=0x0300`）。CamX 4080 表的 C-PHY `0x0301` 会让 CSID/VFE 黑屏 |
| DT | `bus-type = <MEDIA_BUS_TYPE_CSI2_DPHY>`（本树 = 4），`data-lanes = <1 2 3 4>`，`clock-lanes = <7>` |
| CSIPHY | csiphy1 D-PHY settle `0x13`（安卓 dump）；不要用 C-PHY `0x12` 跑 4080 预览 |
| STREAMON | 先写 page `0x4000` 传感器/PLL；MCU `0x2400` 按 10/20/50/100 ms 扫描，NACK 不判失败。验收：`/tmp/rear.raw` 约 15.6 MB |

已踩过、不要退回去的坑：

- `s5kjn1_check_hwcfg` 曾写死 `V4L2_MBUS_CSI2_DPHY`，DT 改 C-PHY 后 probe `-ENXIO`，前摄 link 也建不成
- 曝光默认 3840 > VTS 3164−margin → `init controls` `-ERANGE`
- 主线 init 里 `0x0bcc` 16/8-bit 都 NACK，已从 init_array 拿掉
- 先 `s_power` 再开 CSIPHY 会在 CAM_CC GDSC 起来前使 `cam_cc_mclk0_clk` stuck off
- 把 `vreg_l3a_0p9` 改成 1.104V **禁止**
- STREAMON 不要因 `0x0005` 帧计数为 0 直接 `-ENXIO`（可能只是第一帧还没到）

对照：`dumps/dagu-android-live/camera/com.qti.sensormodule.dagu_qtech_s5kjn1_wide.bin`

### 前摄 Sony IMX596（csiphy4）

| 项 | 现状 |
|----|------|
| 地址 | CAF dtsi 写 `@0x1a`；这颗硅在 **0x10** 读到 chip id `0x0596` |
| 驱动 | `linux-mainline/overlays/linux/drivers/media/i2c/imx596-dagu.c` |
| 尺寸 | 2592×1952 BGGR 10-bit，fourcc `pBAA`，`/dev/video3` |
| PHY | **D-PHY** 4-lane，`bus-type = <MEDIA_BUS_TYPE_CSI2_DPHY>`（本树 = 4）。`0x0114=3` 在 group hold 释放后再写一次 |
| CSIPHY | csiphy4 用 T_hs 公式（678.4 MHz），**不要**抄后摄 settle `0x13` |
| SoftISP | 安卓预览是 IFE 1440×1080 全 FOV @30fps。Linux Viewfinder skip 2×2 → **1296×976** 全 FOV。`DebayerCpu::sizes()` 必须把 processed max 卡在 skip 尺寸，否则 PipeWire 1920×1080 会 skip 1×1 卡死 Snapshot。CSID SOT/EOT（bits 0–7）保持 mask，禁止 `0xffffffff` |
| 抓帧 | 验收 `/tmp/front.raw` 约 6.3 MB；预览 `dagu skip 2x2 in 2592x1952 out 1296x976` 且 fps≈30 |

PLL：CamX OP 19.2 MHz / 3 × `0xD4` = 1.3568 Gbps，DT `link-frequencies = 678400000`。

### App 层（SoftISP / Snapshot / loopback）

- `CONFIG_UDMABUF=y`，`/dev/udmabuf`，udev `90-dagu-udmabuf.rules`
- libcamera simple + Software ISP 出 NV12。WirePlumber **关掉** `monitor.libcamera`（Chrome 走 spa-libcamera 会把 12MP CPU demosaic 打在会话核上，mutter `DL replenish lagged` 卡死）。桌面相机只暴露 `v4l2loopback` `/dev/video20/21`。Python `dagu-camera-pw-source.py` 不再作为默认源
- Snapshot「No Camera Found」：CAMSS 可变链路 `csiphyN→csid0` 在 `cam`/WP 被杀后仍 ENABLED，内核关 fd 不清。下一轮 `CameraManager` `EBUSY`，PipeWire 无 Video/Source。`dagu-camss-graph-reset.sh` 在 pipewire/wireplumber `ExecStartPre` 做 `media-ctl -r`。扬声器路由只 `try-restart pipewire`（WP `BindsTo`），禁止只重启 WP。soname 必须是 `libcamera-base.so.0.7` → `libcamera-base.so.0.7.0`，不能留 `.dagu` stub
- Viewfinder 默认不是传感器 max：后置 4080→1020（4× skip）、前置 2592→1296（2× skip），FOV 靠 Bayer skip 不是中心裁切。拍照 StillCapture 仍全幅。`dagu-libcamera-softisp.sh`。`/etc/libcamera/configuration.yaml` `software_isp.threads=2`
- `v4l2loopback` `/dev/video20` 前、`/dev/video21` 后。`dagu-camera-loopback-watch.service` 只在有人打开节点时 STREAMON。开机 **不要** 双路 SoftISP。不是 Spectra ISP

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
| 霍尔 | GPIO110 lid、GPIO121 tablet | `SW_LID` / `SW_TABLET_MODE`；folio 磁铁拉低 121，空闲应为平板。活 DT 用 `GPIO_ACTIVE_HIGH`。不再注入 `dagu-tablet-mode.py` |
| 音量上 | pm8150 gpio6（elish-common） | |
| 马达 | PM8150B `@c000` LRA | 主线 `qcom,pmi632-vib` |
| 闪光灯 | pm8150l `@d300` | `echo 64 > /sys/class/leds/white:flash/brightness` |
| USB OTG | `dr_mode=otg`，默认 peripheral | 切 host 会掉 g_serial，只能走 Wi‑Fi SSH；`usb_1_qmpphy` **disabled**。`pm8150b_typec` **okay**（充电 / PD），USB 图仍切断 |
| USB3 / DP redriver | PS5169 overlay | 活 DT 未挂节点；`i2c17` 仍 disabled |
| 磁吸键盘 MCU | nanosic overlay | 活 DT `i2c-gpio-se2` gpio115/116 @0x4c；IRQ 83 / wakeup 46 / vdd 127 / reset 141 / sleep 155。虚拟 HID 15d9:a3/a2/a1/a4（触控板 2560×1600 来自安卓 dump）。禁止开 GENI `&i2c2` |

---

## 有意关闭

| 项 | 原因 |
|----|------|
| `CONFIG_SPI_QCOM_GENI` / `&spi4` | `geni_load_se_fw` / `geni_se_init` 写 SE MMIO 挂死这套 QHEE |
| `CONFIG_I2C_QCOM_GENI` | 同上；喇叭/电量改 i2c-gpio |
| 给 `&qupv3_id_0` 加 `firmware-name` / 写 wrapper CSR | 会打回兔子；uart6 只把 stock `qupv3fw.elf` 写进 SE6 IRAM |
| `CONFIG_INTERCONNECT_QCOM_SM8250` | BCM `rpmh_write_batch` 超时，拖死 USB/MDSS/CPU OPP。Venus 用 ICC stub + 删 DT interconnects，不要靠开 provider |
| `&usb_1_qmpphy` | P0 只要 HS gadget；SS 未训 |
| Type-C → DWC3 graph | 等 TCPM 曾让 DWC3 停在 otg、无 UDC；节点本身已 okay 做充电 |
| `&cdsp` | 继续 disabled；不要顺手跟 Venus 一起开 |
| `&slpi` | 未验签名固件前不开 |
| GENI 触控 / 给 `&qupv3_id_0` 加 `firmware-name` | 与 SPI 同一挂点 |

---

## 未做 / 下一步

优先级按用户目标（相机出帧）和「听得到喇叭」：

1. **后摄出 ≥1 帧**：`v4l2-ctl` `/tmp/rear.raw` 约 15.6 MB。MCU `0x2400` 扫描已在驱动里；不要退回瞎猜的 C-PHY PLL
2. **前摄出 ≥1 帧**：`0x0114` 在 group hold 后再写；csiphy4 不抄后摄 settle；`/tmp/front.raw` 约 6.3 MB
3. **SoftISP / Snapshot**：`/dev/udmabuf` + libcamera NV12。Viewfinder skip/bin，禁止 12MP@30 CPU demosaic 喂预览。`dagu-libcamera-softisp.sh`。禁止 meson `-Dipmbs`
4. **v4l2loopback**：`/dev/video20/21` 按需，`dagu-camera-loopback-watch.service`。不是 ISP
5. **扬声器听感**：功放已醒，缺 Halo `CAL_SET_STATUS=2`（下次编核）和 Fast Use Case。见 `linux-mainline/docs/dagu-deep-hardware-reclamation.md`。禁止 softvol。`linux-mainline/scripts/dagu-av-test.sh`
6. **充电验收**：插 5 V 砖后 `pm8150b-charger` `status=Charging`，`bms` `current_now` 为负（充电）；PD 砖看 TCPM log。67W 泵以后再接
5. OTG host：Wi‑Fi SSH 下切 role，插 U 盘 / HID
6. 霍尔、马达、torch 用 `dagu-periph-test.sh` 点一次
7. 蓝牙音频（A2DP / 耳机）专项听感；控制器本身已通
8. SLPI：固件签名确认后再开 IMU/ALS
9. USB3 + DP + PS5169：先保证 HS gadget 不回退
10. 磁吸键盘：活 DT 已挂 i2c-gpio-se2。刷核后查 `Xiaomi Keyboard` / `Xiaomi Touch`，`nanosic-803` irq 上升。不要开 GENI i2c2
11. **S2Idle**：电源键唤醒已通一轮（65 min）。没有 RTC 时不要再远程 `echo mem`。日常桌面仍 mask systemd sleep（背光 HWEN）。底稿 `linux-mainline/docs/dagu-audio-s2idle.md`
12. **Venus**：4K60 HEVC dmabuf + Overview 已通（`dagu-venus-4k-ecosystem`）。日常用 `gst-play-1.0 --videosink=waylandsink` / Totem。下一步若要烤电影级高码率 4K 或让 mpv 也零拷贝，再谈 FFmpeg `drm_prime`；不要开 ICC，不要 VA-API，不要 v4l2 request。底稿 `linux-mainline/docs/dagu-venus.md`
13. Win11 ARM：独立于本表
14. **Chrome 动态花屏 / Mineradio 白屏**：安卓 HWC+SYNC_FD 基线已抓。Linux 关 `PartialSwap`、开 `WaylandLinuxDrmSyncobj`，看门狗盯 fd/hangcheck。`linux-mainline/scripts/dagu-chrome-fence-probe.sh`、`linux-mainline/scripts/dagu-mineradio-watch.sh`

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
| 深水区排雷底稿 | `linux-mainline/docs/dagu-deep-hardware-reclamation.md` |
| Chrome fence 探针 | `linux-mainline/scripts/dagu-chrome-fence-probe.sh` |
| Mineradio 看门狗 | `linux-mainline/scripts/dagu-mineradio-watch.sh` |
| 安卓只提取 | `linux-mainline/scripts/dagu-android-extract.sh` |

内核源码树 `linux-mainline/linux/` **不入库**；相机/音频对主线驱动的修改都在 `apply-overlays.sh` 里重放。
