# dagu ARM Linux 综合评估

记录日期：**2026-09-16**。  
设备：小米平板 5 Pro 12.4（代号 **dagu**，型号 **22081281AC**，SoC **SM8250-AC / 骁龙 870**）。  
当前每天在跑的系统：Linux **7.0** `#244` + Ubuntu arm64 桌面（userdata），只刷 **B 槽**。A 槽是救援计算机（TWRP / HyperOS）。  
本文件按「ARM Linux 系统综合评估维度表」对照 **原厂安卓硬件能力** 与 **主线 Linux 实机落地**，并单独标出 **Python / CPU 软路径** 的性能短板。板上证据以 `#244` 为准（2026-09-16 12:18 CST）。

对照底稿（不要把本文件当成唯一真相；子系统细账以它们为准）：

- 外设总表：`linux-mainline/docs/dagu-adaptation-status.md`
- Wi‑Fi / GPU / CPU：`linux-mainline/docs/dagu-wifi-gpu-turnip-cpu.md`
- Venus：`linux-mainline/docs/dagu-venus.md`
- Chrome + Venus：`linux-mainline/docs/dagu-chrome-gpu-venus.md`
- 音频 / s2idle：`linux-mainline/docs/dagu-audio-s2idle.md`
- 安卓 dump 清单：`docs/hardware-inventory.md`
- 板级 DT：`linux-mainline/dts/sm8250-xiaomi-dagu.dts`
- CAMSS PIX 审计：`linux-mainline/docs/dagu-camss-pix-audit.md`

场景权重：这是一块 **带屏平板**（GNOME + Chromium + 前后摄预览 + 四声道外放），不是 NVR、不是工控网关。权重最高的是 GPU/合成、120 Hz 直扫、Venus 硬解、相机预览、触控跟手、休眠唤醒。NPU、CAN、TSN、千兆电口对本机无意义。

## 怎么读状态

| 标记 | 含义 |
|------|------|
| **已通** | 实机有遥测，功能可用 |
| **软件已通** | 通路打通，听感 / 画质 / 完整场景还差一截 |
| **部分** | 半条链路或只预览 |
| **DT 已写** | 树里有节点，未验收或缺总线 |
| **有意关闭** | 这套 QHEE 上打开会挂、打回兔子 `18d1:d00d`，或拖死别的子系统 |
| **未做** | 还没接 |
| **软路径** | 硬件存在，Linux 走 CPU / 位bang / 用户态脚本，不是飞行正路 |

Python / 软路径严重程度：

| 等级 | 含义 |
|------|------|
| **P0 热路径** | 像素、音频、输入 IRQ 周期里跑；会饿死 mutter / 掉帧 / 黑预览 |
| **P1 常驻** | systemd 一直开着，轮询 `/proc` 或 evdev；不是像素路径，但会抢调度 |
| **P2 实验室** | 探针、实验室、主机刷写；不要当产品路径 |
| **已迁走** | 曾经 Python / GStreamer，现已换成 C++/Rust/内核 |

---

## 总评分（平板场景）

| 一级维度 | 硬件账面 | Linux 落地 | 平板权重 | 结论 |
|----------|----------|------------|----------|------|
| 1. 核心算力与存储 | 骁龙 870 一线 | CPU/GPU/UFS 已通；NPU/CDSP 关；ICC 关 | 高 | 够用。瓶颈不在核数，在 **无 ICC 带宽投票** 和 **SoftISP 吃 CPU** |
| 2. 多媒体 | Venus + Spectra 480 + Hexagon | Venus 4K60 已通；**Spectra IFE 没接**；相机是 CPU SoftISP | 极高 | 视频正路。相机是最大的软路径洞 |
| 3. 外设与感知 | 120 Hz + 双摄 + 四喇叭 + IMU | 显示/触控/麦/喇叭已通；IMU/ALS 关；DP 未接 | 极高 | 日常能用。传感器和 Type-C 异显缺 |
| 4. 网络 | QCA6390 Wi‑Fi 6 + BT 5.x | ath11k ~600 Mbps；蓝牙 HID 已通；无蜂窝 | 高 | 够用。无以太网、无 5G（本 SKU 本就没有） |
| 5. 总线扩展 | PCIe / USB3 / QUP GENI | PCIe0 只给 Wi‑Fi；**Himax SE4 + CS35L41 SE1/SE3 已走 GENI**；USB3 未训 | 中 | 平板够。工控总线本机没有 |
| 6. 软件生态 | 原厂 4.19 BSP | 主线 7.0 + Ubuntu + 大量 overlay | 极高 | 主线是资产。QHEE 禁的是 **wrapper CSR / ICC / GPI**，不是 GENI SE |
| 7. 功耗热可靠 | PM8150 / 双电芯 / 被动散热 | DVFS 已通；s2idle 电源键可醒；无 RTC | 高 | 能睡。充电/无线充 DT 已写，未专项烤机 |

一句话：这不是「芯片算力不够」。**打回兔子的是 QUPV3 wrapper CSR 和 ICC BCM 投票，不是 GENI。** `#244` 上 uart6 / Himax / CS35L41 都是 per-SE IRAM + `skip-wrapper-fw-init`。主线仍没有 Spectra IFE / Hexagon CDSP，所以相机还是 CPU SoftISP。尚未迁走的只有 KTZ / 电量 / 磁吸键盘的 **i2c-gpio**。

---

## 1. 核心算力与存储

### 1.1 CPU

| 考察点 | 原厂 / 硅 | Linux 实机 |
|--------|-----------|------------|
| 架构 | Kryo 585 = 1× Cortex-A77 Prime + 3× A77 + 4× A55（big.LITTLE） | 同硅。`lscpu` 包装成 Kryo 585 / Snapdragon 870 |
| 主频 | Prime ~3.2 GHz，Gold ~2.42 GHz，Silver ~1.80 GHz | policy7 **844–3187 MHz**，policy4 **710–2419**，policy0 **300–1804** |
| 调频 | 安卓 cpufreq + interconnect 投票 | `qcom-cpufreq-hw` **只用 EPSS LUT**。DT 删掉 `interconnects`（ICC + BCM voter 会 `rpmh_write_batch` 超时） |
| 跑分 | 未在 Linux 上跑 CoreMark / DMIPS 作为交付 | `stress-ng --cpu 8` 8/8 通过；压核 cpu5-top **~84 °C** |
| 实时 | 安卓 4.19-perf | `SMP PREEMPT`，**不是** PREEMPT-RT |

**不是 Python 问题。** 性能天花板是 **禁止 `CONFIG_INTERCONNECT_QCOM_SM8250`**：CPU/GPU/UFS/Venus 都没有 BCM 带宽投票。1080p/4K 解码目前靠 IOMMU 硬扛过了，高码率 4K 或多路并发没有互联保证。

### 1.2 GPU（Adreno 650）

| 考察点 | 原厂 / 硅 | Linux 实机 |
|--------|-----------|------------|
| 型号 | Adreno 650 v3 | Turnip `Adreno (TM) 650`，Mesa 26.0.8，Vulkan **1.3** |
| API | GLES / Vulkan / OpenCL（闭源 blob） | GLES 3.2（msm GBM）+ Vulkan 1.3（Turnip）。**OpenCL / 通用计算未作为产品路径** |
| 合成 | HWC + UBWC 直送 DPU | GNOME 走 msm atomic，主 fb `XR24` `QCOM_COMPRESSED`。不是 llvmpipe |
| 用户态 | 高通 blob | Mesa Turnip。dEQP smoke / compute / draw 核心组 0 失败 |
| 故障 | — | 偶发 `gpu fault status 00800005` + hangcheck recover，能起来 |

Chrome：一线是 `use_v4l2_codec=true` 的 Chromium（`dagu-chromium-native.sh`），`chrome://gpu` Canvas / Compositing / Rasterization / WebGL / Video Decode = Hardware。官方 `/opt/google/chrome/chrome` 是 `USE_V4L2=0`，**禁止**拿它测硬解。

**禁止**（已毁过画面 / 已当软退路）：`--disable-gpu`、`--disable-gpu-rasterization`、`FD_MESA_DEBUG=notile`、给 gnome-shell 装 `libdagu-linear-mod.so`、锁 `governor=performance`。

### 1.3 NPU / AI 加速器

| 考察点 | 原厂 / 硅 | Linux 实机 |
|--------|-----------|------------|
| 算力 | Hexagon 698（CDSP / HVX），账面约 15 TOPS INT8。SM8250 **没有**独立 NPU 砖（那是 8xx 以后的 Hexagon Direct/HTP） | **`&cdsp` disabled**。SNPE / QNN / TFLite Hexagon 委托 **未做** |
| 框架 | 安卓 NNAPI + Hexagon | 无。WebNN 禁止（会掉 TFLite/CPU） |
| 相机 3A / 降噪 | IPE / BPS / IFE 在 Spectra | Linux **没有** Titan ISP 用户态。预览是 libcamera **DebayerCpu** |

平板场景：人脸/超分/离线模型不是当前交付。缺 CDSP 的直接后果是 **相机 ISP 只能吃 CPU**（见 §2.2、§8）。

### 1.4 内存与存储

| 考察点 | 原厂 / 硅 | Linux 实机 |
|--------|-----------|------------|
| RAM | dump `/proc/meminfo` **~8 GB**。SM8250 支持 LPDDR5 64-bit | DT `memory { reg = <0x80000000 0x3bb00000>, <0xc0000000 0x1c0000000> }`，扣 reserved-memory 后约 8 GB。**无 ECC**（消费平板） |
| ROM | **256 GB UFS**（userdata ~228 GiB），fastboot `variant: SM8 UFS` | `&ufs_mem_hc` okay。删 interconnects。**运行时 CLK_SCALING 关掉**（devfreq vs QUERY_ATTR 会 hung_task） |
| 寿命 / TBW | 未测 | 未测。日常桌面负载，不是写放大型 NVR |

存储不是瓶颈。UFS 不能按工控 ECC/TSN 去评。

---

## 2. 多媒体与音视频

### 2.1 VPU（Venus）— 硬件正路，已通

| 考察点 | 硅 / 安卓 | Linux 实机 |
|--------|-----------|------------|
| 节点 | video-codec | `/dev/video14` 解码、`/dev/video15` 编码，`qcom-venus` stateful V4L2 m2m |
| 解码格式 | H.264 / HEVC / VP8 / VP9 / MPEG2。**无 AV1** | 同。CAPTURE `NV12` + `Q08C`；10-bit 走 **P010** |
| 分辨率 | 硅可 4K120 / 8K24 量级 | 验收：**1080p30 H.264/VP8/VP9/HEVC** + **4K60 HEVC dmabuf** 上 Mutter。无 SMMU/SSR |
| 编码 | H.264 / HEVC / VP8 | ffmpeg `h264_v4l2m2m` 烟测通过。Chromium MediaRecorder H.264/VP8/HEVC(/10) 打开 `/dev/video15` |
| 零拷贝 | HWC | `gst-play-1.0 --videosink=waylandsink` → `DMA_DRM`/`NV12`。**mpv 仍是 `v4l2m2m-copy`（CPU 拷）** |
| 驱动生态 | 闭源 omx | 主线 `CONFIG_VIDEO_QCOM_VENUS=m` + ICC stub。GStreamer `v4l2h264dec` 可用。禁止 VA-API、禁止 v4l2 request |

1080p CB `fakesink sync=false` 墙钟约 **1.68 s / 10 s 素材 ≈ 180 fps 吞吐**，8 核约 **16% busy**，`venus_irq` 上升。这是硬解，不是 FFmpeg。

**不是 Python。** 软路径只剩：mpv copy、官方 Chrome 153 软解（非一线）、最大化窗还没有第二块 DPU plane（合成 `WaitForSwap` 掉帧，不是解码）。

### 2.2 ISP（Spectra / Titan）— Linux 最大洞

安卓预览走 **IFE 硬件**：后置全 FOV 约 1920×1080 @30，前置 IFE 1440×1080 @30，带 3A / 降噪。

Linux 只打通了 **CAMSS RDI**（CSIPHY → CSID → VFE RDI → 内存 RAW10）。CSID TPG 出过完整 1 帧（约 15.6 MB），证明 VFE DMA / SMMU / CAMNOC 没问题。

| 相机 | 传感器 | PHY | RAW | Viewfinder（Linux） | 安卓对照 |
|------|--------|-----|-----|---------------------|----------|
| 后置 | s5kjn1，CCI0@0x10，csiphy1 | **D-PHY 4-lane**（live `0x0800=0x02`，`0x0114=0x0300`） | 4080×3060 GBRG packed10 `pGAA` | SoftISP **skip 4×4 → 1020×764** @~30 | IFE 全 FOV，不是中心裁切 |
| 前置 | imx596，CCI1@0x10，csiphy4 | **D-PHY 4-lane**，`0x0114=3` | 2592×1952 BGGR packed10 `pBAA` | SoftISP **skip 2×2 → 1296×976** @~30 | IFE 1440×1080 全 FOV |

**禁止**后置 C-PHY / `0x0114=0x0301`（CSID FIFO 卡住，Snapshot 黑屏）。**禁止** 12MP@30 CPU demosaic 喂预览。

画质增强：

| 项 | 安卓 | Linux |
|----|------|-------|
| 3DNR / HDR / 畸变 | IPE/BPS 硬件 | **无** |
| 3A | CamX + IFE | libcamera IPASoft。预览管线曾把 analog gain 钉死（室内 Y≈47）；loopback 现按 CamX 16× + 33 ms 快门。**不是闭环 3A** |
| 多摄同步 | 安卓有 | **未做** |

这不是「相机没接上」，是 **ISP 整块没接到 Linux**。预览能 30 fps 的前提是 Bayer skip 把像素砍到 1/16（后）或 1/4（前），再让 `DebayerCpu` 在 A77 上跑。活树 `camss-vfe-480.c` 只写 `MODE_MIPI_RAW` RDI，VFE0/1 `line_num=3` 不实例化 `VFE_LINE_PIX`。详见 `dagu-camss-pix-audit.md`。

### 2.3 音频 DSP

| 考察点 | 安卓 | Linux |
|--------|------|-------|
| ADSP | `adsp.mbn` running | **同**，`remoteproc0` `adsp` `running` |
| 外放 | CS35L41 ×4，Halo DSP Protection + Music 调音 | **已通**（GENI I2C SE1/SE3）。TDM 32-bit slot + sample 24、`PCM Source=DSP`、prot.bin。`#244` 四颗都写上 `CAL_SET_STATUS=2`（TL 9524 / TR 9632 / BL 9497 / BR 9696）。Fast Use Case `*-music.txt` 已灌。禁止 softvol |
| 麦 | WCD9385 AMIC5，Fluence AEC/NS | **无 Fluence**。模拟增益 18 dB，喇叭 440 Hz 回录能检出 |
| AEC / ANC / KWS | ADSP Fluence / voice UI | **未做**。会议回声靠 CPU 或应用自己 |
| 3.5 mm | 无 | 无 |
| 蓝牙音频 | A2DP | 控制器已通，**A2DP 听感未测** |

喇叭通路曾被 PipeWire 在 card 0 未就绪时 exit 234 整段会话无声——那是会话管理，不是 DSP 算力。禁止用 PipeWire softvol 把蚊子声拉大。

---

## 3. 外设与感知交互

### 3.1 摄像头与视觉输入

MIPI-CSI：csiphy1（后）+ csiphy4（前），各 4-lane D-PHY。无 DVP。UVC 外接取决于 USB host（OTG 未专项验收）。

App 层产品路径（2026-09-16）：

```
传感器 RAW10
  → CAMSS RDI
  → libcamera simple + DebayerCpu（C++，threads=2，skip 2×2/4×4）
  → dagu-camera-loopback（Rust watch + C++ pack，NEON RGB→YUYV）
  → v4l2loopback /dev/video20 前、/dev/video21 后  默认 1280×720 YUYV
  → Snapshot / 微信 / 腾讯会议 / Chromium
```

PipeWire **关掉** `monitor.libcamera`。Chrome 若走 spa-libcamera，会把 12MP CPU demosaic 打在会话核上，mutter `DL replenish lagged`，触控看起来「死了」（Himax 仍在报点，背光会醒）。

开机 **不要** 双路 STREAMON。`dagu-camera-loopback-watch.service` 只在有客户端打开节点时拉 SoftISP。`CPUAffinity=0-5`；Debayer 线程钉到 CPU4–5（A77），mutter 留 CPU6–7。Little-only 实测预览掉到 **~11 fps**。

### 3.2 显示输出

| 考察点 | 硬件 | Linux |
|--------|------|-------|
| 面板 | L81A IPS，物理 **1600×2560 @ 120 Hz**，DSC dual-DPHY 8 bpc | **已通**。`get_modes()` 只登记 120 Hz，避免 GNOME 选同名 60 Hz |
| 背光 | 双 KTZ8866 | `i2c-gpio`（禁止 GENI i2c9/11）。GNOME 一个 `l81a-wled`。**整次开机不要拉低 GPIO139 HWEN** |
| HDMI / DP / eDP | Type-C DP alt 经 PS5169 | **DT 已写，活树未挂**。无 HDMI 口 |
| 异显 | 安卓可 DP | **未做**。单屏 |
| 合成 | HWC DEVICE + SYNC_FD | Mutter UBWC 主 fb。SM8250 DPU 6.0 **无 inline rotation**；日常 270° 由 Chrome GPU 预旋 |

滑动 kickoff 从早期 63 Hz / 151 ms 洞收到约 **99–106 Hz / p99 18–25 ms**。静置仍可能抽帧。不要关 GPU raster。

### 3.3 麦克风与音频输入

不是 PDM 阵列音箱。模拟 MIC → WCD9385 ADC → SoundWire TX → ADSP → `hw:0,1`（MultiMedia2）。UCM `Built-in Microphone`。无独立 LINE IN。

### 3.4 环境与物理传感器

| 传感器 | 安卓 | Linux |
|--------|------|-------|
| IMU LSM6DSO | SLPI | **`&slpi` disabled**。禁止在 AP I2C 上猜 |
| ALS tcs3701 / rohm_bu27030 | SLPI | 同上 |
| 霍尔 GPIO110/121 | gpio-keys | DT 已写 `SW_LID` / `SW_TABLET_MODE`。**已迁走**：不再装 `dagu-tablet-mode.py` |
| 距离 / 地磁 | 未作为交付 | 未做 |
| 触控 Himax HX83121 | GENI SPI | **已通** `#244`：`990000.spi` / `spi4.0`，`dagu SPI FIFO proto=1 depth=16 width=32 fifo_if_dis=0 skip_wrap=1`。gpio8–11 function qup4，IRQ gpio39 LEVEL_LOW。probe 读 event30 不是全 `0xff`。禁止 GPIO100、禁止 GPI/SE DMA |
| 磁吸键盘 | QUP I2C | DT `i2c-gpio-se2`。未专项验收。禁止未测就开 GENI `&i2c2` |

---

## 4. 网络与通信接口

| 考察点 | 硬件 | Linux |
|--------|------|-------|
| 以太网 | **无** | 无 |
| TSN / 双 MAC | 无 | 无 |
| Wi‑Fi | QCA6390，PCIe0，**Wi‑Fi 6 硅** | ath11k `wlp1s0`。现网 iperf 证据是 **VHT 80 MHz 2SS PHY 866.7 Mbps，TCP 600–665 Mbps**（对端可能是 AC AP）。BDF 必须 `bd_l81a.elf` → `board.bin` |
| 蓝牙 | QCA6390 UART，BT 5.x | uart6 + `hci_qca`，3 Mbps。BLE HOG 鼠标、经典 HID 键盘已通。A2DP 未测 |
| 4G/5G | **22081281AC 无猫** | 无 M.2 |
| Zigbee / LoRa | 无 | 无 |

无 RTC：开机时钟停在 rootfs 构建日，Chrome 会把 CDN 证书判成 **not yet valid**。**已迁走**：`systemd-timesyncd`（阿里云/腾讯/清华 NTP）。不再装 `dagu-time-sync.py`。

---

## 5. 总线扩展与工控

| 考察点 | 硅 | Linux |
|--------|----|-------|
| PCIe | Gen3，多口 | **只开 pcie0**（Wi‑Fi）。pcie1/2 disabled |
| USB | DWC3 HS + SS PHY | HS **gadget** `g_serial` `0525:a4a7` 已通（验收：>30 s 不回兔子）。OTG host / USB3 / DP **未训**。切 host 会掉串口 |
| SATA | 无 | 无 |
| CAN / RS-485 / RS-232 | 无 | 无 |
| QUP GENI SPI/I2C | 原厂总线 | **产品路径已开。** `#244`：`990000.spi` Himax FIFO；`984000.i2c` / `98c000.i2c` 四颗 CS35L41；uart6 仍 SE6 IRAM。禁止 wrapper CSR、`CONFIG_QCOM_GPI_DMA`、ICC。背光 KTZ（se9/11）、电量/充电（se0/13/15/16）、键盘（se2）仍 **i2c-gpio** |
| UART | uart6 蓝牙 | 只把 `qupv3fw.elf` 写进 **SE6 IRAM**。禁止给 `&qupv3_id_0` 加 `firmware-name` |
| GPIO / PWM / ADC | PMIC + TLMM | 音量键、电源键、闪光灯 DT 已写 |

工控维度对本板不适用。扩展税已经不是「GENI 全关」，而是 **KTZ / FG / nanosic 还在 gpio 位bang**，以及 USB3/DP 未训。

板上 `#244` 遥测（不是实验开关）：

```
geni_spi 990000.spi: dagu SPI FIFO proto=1 depth=16 width=32 fifo_if_dis=0 skip_wrap=1
himax-dagu spi4.0: HX83121 1600x2560 irq 193
cs35l41 {1-0040,1-0041,3-0041,3-0043}: SET_STATUS=2
g_serial 0525:a4a7 held >30s；A 槽未动
```

历史挂死路径是 `&qupv3_id_0` 的 wrapper CSR，加上 SPI `geni_can_dma` 给 Himax 帧选 SE DMA。产品构建强制 per-SE `firmware-name` + `qcom,skip-wrapper-fw-init` + FIFO。

---

## 6. 软件生态与安全

| 考察点 | 状态 |
|--------|------|
| 内核 | Linux **7.0** 主线 + `apply-overlays.sh` 重放。不是 4.19 CAF BSP 日常运行 |
| Mainline | SoC 时钟/USB/UFS/GPU/CAMSS/Venus 走主线。面板 / Himax / 双电芯 / 充电泵 / imx596 是树外 overlay |
| PREEMPT-RT | **未启用** |
| Bootloader | 原厂 ABL，解锁 orange。Linux Image 不是 EFI stub（`CONFIG_EFI is not set`）。DTBO 必须 stub，空 DTBO ~6 s 回 fastboot |
| Device Tree | `sm8250-xiaomi-dagu.dts`，单机 MAC 不入库 |
| GPU/VPU 用户态 | Mesa Turnip **开源**；Venus **主线驱动** + 本机签名 `venus.mdt`。a650 zap / ADSP / ath11k BDF **必须本机 dump**（secure boot 验签） |
| 构建 | 自研脚本，不是 Yocto。rootfs 是 Ubuntu 桌面刷进 userdata |
| 发行版 | Ubuntu arm64 桌面。官方没有为 dagu 发主线镜像 |
| TrustZone | **QHEE 已在 ABL 链上跑**。Linux 不装 OP-TEE，不打 KVM（nVHE 会和 QHEE 抢 EL2）。VA_BITS=39 对齐安卓 4.19 |
| Secure Boot | 解锁后 orange。Linux 不写 eFuse |
| 硬件加密 | UFS ICE 随 ufshc；未做 TEE 应用 |

避坑（ARM Linux 典型翻车，这台已经踩过并写进规则）：

- 账面 4K 硬解但用户态没有 V4L2 → 官方 Chrome 153 就是这样，一线改 Chromium `use_v4l2_codec`
- 闭源 blob 换板即挂 → zap / venus / adsp **禁止**用 elish
- 主线开 ICC / wrapper CSR 「更正确」→ 这套 QHEE 上是毁机路径。GENI SE 本身要 per-SE IRAM + skip-wrapper

---

## 7. 功耗、热与可靠性

| 考察点 | 状态 |
|--------|------|
| PMIC | PM8150 / PM8150B / PMI632，ABL 已编程。Linux 接 RPMH 调节器 |
| DVFS | CPU EPSS LUT + GPU devfreq。空闲 GPU min **587 MHz**；触摸由 himax-dagu `freq_qos` / `dev_pm_qos` 和 C 版 `dagu-touch-boost` 抬到 670 / 大核地板 |
| 深度睡眠 | `mem_sleep=[s2idle]` 只有这一种。电源键唤醒已通（睡约 65 min）。**无 `/dev/rtc*`**，`rtcwake` 不可用。日常桌面 mask systemd sleep（背光 HWEN） |
| TDP | 被动散热平板。压核 ~84 °C；玻璃+videotestsrc GPU ~80 °C |
| 工作温度 | 消费级。不是 -40~85、不是 AEC-Q100 |
| 充电 | SMB5 + 双 BQ25970 67W PPS + P9418 无线充探测：**DT+驱动已写，未刷核专项验收** |
| 双电芯 | BQ27Z561 ×2，设计 5000 mAh ×2。脚本可查 `power_supply` |
| 毁机抑制 | 禁止 `DAGU_PRIMARY_ENTRY_PROBE`、禁止 Himax 绑 GPIO100、禁止 `vreg_l3a_0p9=1.104V`、只刷 B 槽 |

可靠性正路：失败要可见（hangcheck 看门狗、CAMSS graph reset、PipeWire start-limit 修复）。禁止吞错掉到 llvmpipe / FFmpeg。

---

## 8. Python 与 CPU 软路径清单（重点）

这是评估表里「能看不能用」最容易藏的地方。硬件解码已经不是 Python；触控总线在 `#244` 也已经不是。**还在热路径上的是相机 SoftISP。**

### 8.1 像素热路径（P0）

| 路径 | 语言 | 现在还在产品里？ | 问题 | 正路 |
|------|------|------------------|------|------|
| libcamera `DebayerCpu` | C++ | **是**。`software_isp.mode: cpu`，`threads: 2` | 没有 Spectra IFE。全幅 12MP@30 会饿死 mutter，点不了窗口。skip 关掉会变成 648×488 或卡死 Snapshot | skip 4×4 / 2×2 全 FOV；Debayer 钉 A77；**不要**开 CDSP 当「先这样」除非签名固件验收 |
| 旧 loopback `gst-launch libcamerasrc ! videoconvert ! v4l2sink` | GStreamer C + **Python watch** | **已迁走**。`.sh` 只留实验室，rootfs/deploy **禁止**同名安装 | `videoconvert` CPU 色域；Python 每 0.5 s 扫 `/proc/*/fd` 会冻 mutter | 产品入口：`/usr/local/sbin/dagu-camera-loopback` Rust+C++ ELF |
| `dagu-camera-pw-source.py` | **Python + NumPy + Gst** | **否**（实验室）。文件头写明 Lab-only | 4080×3060 RAW → skip → **510×382 @ 5 fps** RGB。NumPy percentile / gray-world 每帧。曾当 PipeWire 源 | 删除出默认路径。不要再让 Snapshot 连这个节点 |
| `dagu-camera-preview.py` | **Python + NumPy + GTK4** | 实验室预览 | 同样 CPU 解 Bayer；GTK 上传大 MemoryTexture 会花 CSD | 用 Snapshot / loopback |
| loopback `rgb_to_webcam_yuyv` | C++ NEON | **是** | SoftISP 出 RG24 后再 CPU 转 YUYV + 中心裁切缩放到 1280×720。比 Python 快一个数量级，仍不是 ISP | 可接受的产品胶水。下一步才是 IFE NV12 零拷贝 |
| mpv `v4l2m2m-copy` | C | 若用户开 mpv | 硬解后再 CPU 拷 | `gst-play` waylandsink / Totem |
| 官方 Chrome 153 软解 | C++ FFmpeg | 非一线 | `USE_V4L2=0` | `dagu-chromium` V4L2StatefulVideoDecoder |

`dagu_cam.cpp` 注释原话：Debayer 落在 A55 上 skip-4×4 要 **86 ms/帧**；钉到 A77 才能跟 30 fps。这是 **C++ 仍然不够、必须靠跳像素和绑大核** 的证据，不是再包一层 Python 能救的。

### 8.2 常驻用户态（P1）

| 进程 | 语言 | systemd | 做什么 | 状态 |
|------|------|---------|--------|------|
| `dagu-touch-boost` | **C** | `dagu-touch-boost.service` | Himax evdev → GPU 587↔670、CPU 地板。不扫 `/proc` | **已迁走** Python。刷核后 himax-dagu 也 `freq_qos` 投票 |
| `dagu-camera-loopback watch` | **Rust + C++** | `dagu-camera-loopback-watch.service` | 有客户端才 STREAMON；Debayer 钉 CPU4–5 | **已迁走** `.sh`+Python。双路常驻 service 仍 disable |
| `dagu-tablet-mode.py` | Python | 曾有单元 | 注入 `SW_TABLET_MODE` | **已迁走**。霍尔走 gpio-keys |
| `dagu-power-button` | **C** | `dagu-power-button.service` | 短按 Mutter PowerSaveMode | **已迁走** Python。禁止改回 logind lock |
| `dagu-time-sync.py` | Python | 曾开机一次 | NTP | **已迁走**。`systemd-timesyncd` |
| `dagu-fcitx5-shift-tap.py` | Python + evdev | 曾按需 | 磁吸键盘点 Shift | **已迁走**。`keyd` + `CONFIG_INPUT_UINPUT=y` |

根因：**打回兔子的是 QUPV3 wrapper CSR，不是 GENI SE。** `#244` 产品默认：Himax `990000.spi` FIFO `proto=1 skip_wrap=1`；CS35L41 在 `984000.i2c` / `98c000.i2c`；`g_serial` >30 s。升频救的是 SoftISP，**不能**把 IFE 变出来。

### 8.3 不是性能问题的 Python（P2）

主机刷写 `fb-usb.py`、串口 `dagu-console.py`、内核 `apply-overlays.sh` 里的补丁生成、上百个 `dagu-*-probe.py` / `dagu-pipeline-lab.py`：这些是地面设备。实验室 HUD 曾每帧 `Gtk.Label.set_text` 打爆 ATK，那是测具自扰，不是产品。

**不要**把探针、identity 实验室、`dagu-himax-swipe.py`（往 evdev **写**合成滑动）当成触控/相机性能证据。

### 8.4 不是 Python、但是同类软路径（必须并列）

这些比 Python 更贵，因为它们在 **每个触摸 IRQ / 每颗功放寄存器** 上：

| 软路径 | 本应走的硬件 | 为什么软 | 体感 |
|--------|----------------|----------|------|
| `spi-gpio` 读 Himax | QUP SE4 GENI SPI | **已迁走** `#244`：per-SE IRAM + FIFO，`geni_can_dma` 强制 false（不开 GPI/SE DMA） | 触控走硬件 FIFO，不再 Gold 位bang |
| `i2c-gpio` 喇叭 | QUP GENI I2C | **已迁走** `#242` 起：CS35L41 在 SE1/SE3；`#244` 同镜 | 喇叭 I2C 不再位bang |
| `i2c-gpio` 背光 / 电量 / 键盘 | QUP GENI I2C | `#244` 仍有 `i2c-gpio-se{0,2,8,9,11,13,15,16}`。禁止未测就开 GENI i2c2/9/11 | 背光/键盘 I2C 仍慢 |
| ICC stub（空投票） | `CONFIG_INTERCONNECT_QCOM_SM8250` | BCM `rpmh_write_batch` 超时拖死 USB/MDSS | 高带宽多客户时没有互连 QoS |
| UFS CLK_SCALING off | ufshc devfreq | 与 QUERY_ATTR 死锁 panic | 固定时钟，功耗略差 |
| 无 Fluence | ADSP 语音拓扑 | 主线 mixer 没接 | 免提回声 |
| `&cdsp` / `&slpi` disabled | Hexagon / 传感器枢纽 | 固件签名 / bring-up 未收口 | 无 NPU、无 IMU 自动旋转（旋转靠 Mutter 配置） |

---

## 9. 对照评估表：逐格落地

### 维度 1

| 二级 | 指标 | dagu Linux |
|------|------|------------|
| CPU | A77/A55、8 核、3.2 GHz | **已通**，LUT 调频，无 ICC |
| GPU | Adreno、GFLOPS、GLES/Vulkan/OpenCL | Turnip GLES3.2 + VK1.3 **已通**。OpenCL **未做** |
| NPU | TOPS、TFLite/QNN | **有意关闭** |
| 内存存储 | LPDDR、UFS、ECC | ~8 GB + 256 GB UFS **已通**。无 ECC |

### 维度 2

| 二级 | 指标 | dagu Linux |
|------|------|------------|
| VPU | H.264/HEVC/AV1、4K、多路 | H.264/HEVC/VP8/VP9 **已通**，4K60 HEVC 一条。无 AV1。多路未烤 |
| ISP | 吞吐、多摄、3A/3DNR | RDI **已通**。IFE/IPE **未接**。预览靠 SoftISP skip |
| 音频 DSP | AEC/ANC/KWS | ADSP 播放 **已通**。语音增强 **未做** |

### 维度 3

| 二级 | 指标 | dagu Linux |
|------|------|------------|
| CSI | 口数、lane、带宽 | 2× 4-lane D-PHY **已通** |
| 显示 | HDMI/DP/DSI、异显 | 内屏 120 Hz **已通**。DP **未接** |
| 麦 | PDM / I2S | WCD 模拟麦 **已通**。无 PDM 阵列 |
| 传感器 | ALS/IMU/霍尔 | 霍尔 DT 已写。IMU/ALS **关** |

### 维度 4

| 二级 | 指标 | dagu Linux |
|------|------|------------|
| 有线网 | GbE/TSN | **无此硬件** |
| Wi‑Fi/BT | Wi‑Fi 6、BT 5 | Wi‑Fi **已通** ~0.6 Gbps。BT HID **已通**。A2DP 未测 |
| 广域 | 5G/LoRa | **无此硬件** |

### 维度 5

| 二级 | 指标 | dagu Linux |
|------|------|------------|
| PCIe/USB/SATA | Gen3、USB3 | PCIe0 **已通**。USB3/SATA **无/未训** |
| 工控 | CAN/RS485/PWM | **无此硬件**。Himax/喇叭已走 GENI；其余仍 gpio |

### 维度 6

| 二级 | 指标 | dagu Linux |
|------|------|------------|
| 内核 | 主线 vs BSP、RT | 7.0 主线 + overlay。非 RT |
| 多媒体驱动 | V4L2/DRM/GStreamer | Venus + msm DRM + gst v4l2 **已通**。ISP 只有 RDI |
| 构建 | Yocto/Ubuntu | Ubuntu 自研镜像 |
| 安全 | TZ/Secure Boot/TEE | QHEE 已在；Linux 不控 TEE |

### 维度 7

| 二级 | 指标 | dagu Linux |
|------|------|------------|
| 功耗 | DVFS、深睡 | DVFS **已通**。s2idle 电源键 **已通**。无 RTC |
| 热/环境 | 工业温、被动散热 | 消费被动散热。压核 84 °C 能回来 |

---

## 10. 场景权重（本机该怎么用这张表）

### 智能带屏平板（实际产品）

核心关注：显示 120 Hz、GPU、触控、Venus、相机预览、休眠。

| 项 | 飞行合格？ |
|----|------------|
| 合成 / 触控 | 触控总线合格（GENI SPI FIFO `#244`）。静置仍可能抽帧。SoftISP 开时必须绑核，否则 mutter 被饿死（Himax 仍在报点） |
| GPU UI | 合格（Turnip，禁止软栅格） |
| 硬解 1080p/4K | 合格（Chromium + gst-play） |
| 相机预览 30 fps | **预览合格，画质不合格**（无 IFE 3A/NR，skip 后分辨率低） |
| 四喇叭 | 合格：GENI I2C + Halo `SET_STATUS=2` + Music prot.bin。禁止 softvol |
| 休眠 | 电源键合格；无 RTC 不能远程闹钟 |

### 若拿它当 NVR / 机顶盒

Venus 一条 4K60 已证。缺：多路并发烤机、SATA、电口、ICC 带宽。**不要**用 Python 拉流。

### 若拿它当 AIoT 视觉

NPU **没有**。相机是 CPU SoftISP。弱光/HDR 比不过安卓 IFE。要视觉就先接 Spectra 或接受 skip 预览。

### 若拿它当工控网关

硬件不对口（无 CAN/485/电口），且非 RT、消费温区。不要选这台。

---

## 11. 飞行件结论与下一刀

已经按硬件正路落地、不要倒退：

1. 后置 D-PHY 4-lane + skip 4×4 1020×764；前置 D-PHY + skip 2×2 1296×976  
2. Venus stateful V4L2，Chrome `use_v4l2_codec`，禁止官方 Chrome 软解充数  
3. Turnip + UBWC 主 fb，禁止 llvmpipe / notile  
4. 只刷 B 槽；SM8250 ICC / GPI DMA / wrapper CSR 永不放行；GENI 产品路径是 per-SE IRAM + skip-wrapper  
5. 相机默认走 v4l2loopback，禁止 spa-libcamera 打满会话核  

下一刀按「删软路径」而不是「再包一层 Python」：

| 优先级 | 项 | 删掉的软路径 |
|--------|----|----------------|
| 1 | 板上 `dagu-camera-loopback` 必须是 **Rust ELF** | **已迁走** P0 fd walk / gst |
| 2 | SoftISP 预览保持 skip；StillCapture 全幅另议 | 禁止 12MP CPU 预览 |
| 3 | 扬声器 Halo `CAL_SET_STATUS=2` + Fast Use Case | **已迁走** `#244` 四颗 `SET_STATUS=2`。禁止 softvol |
| 4 | 霍尔走 gpio-keys | **已迁走** `dagu-tablet-mode.py` |
| 5 | Himax GENI SPI FIFO + 内核 `freq_qos` | **已迁走** spi-gpio 与 Python 升频 |
| 6 | CS35L41 GENI I2C SE1/SE3 | **已迁走** 功放 i2c-gpio |
| 7 | KTZ / FG / nanosic 按 uart6 同款收 GENI | 仍 `i2c-gpio-se{0,2,8,9,11,13,15,16}`。一次只迁已测 SE |
| 8 | SLPI：PAS 验签 + 有客户端再 okay | 不要 AP 上猜 I2C。见 PIX 审计笔记 |
| 9 | USB3 + DP | 现在只有 HS gadget |
| 10 | Spectra IFE / CDSP | **PIX no-go**（`dagu-camss-pix-audit.md`）。CDSP 无工作负荷不开 |

**Python 不是这台机器的架构。** `#244` 产品路径：loopback ELF、C 版电源键/触控升频、timesyncd、keyd、霍尔 gpio-keys、Himax GENI SPI FIFO、CS35L41 GENI I2C。仍软的是 **DebayerCpu** 和 KTZ/FG/nanosic 的 **i2c-gpio**。禁止 wrapper CSR / GPI DMA / ICC；失败 `restore-a`。
