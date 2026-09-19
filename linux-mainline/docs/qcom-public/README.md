# 高通公开相机手册本地副本（对照分析）

本目录是从 `docs.qualcomm.com` 爬下来的**公开章**原文 + 图，给 dagu 前后摄对照用。
不是 Titan 480 的 SWI（Software Interface，软件接口手册），没有 `0x4460`、
没有 Crop 9-word、没有 `viol_id`。排寄存器仍看安卓活 dump 和
`camss-vfe-480.c`。

刷新：`python3 linux-mainline/scripts/dagu-fetch-qcom-public-docs.py`
来源表：[`SOURCES.md`](SOURCES.md)。

## 索引

| 本地文件 | 图 | 硅上前后摄是否同一套 | 用来干什么 | 禁止拿它干什么 |
|---|---|---|---|---|
| [`80-PV086-5P-camera-support.md`](80-PV086-5P-camera-support.md) | [`images/80-PV086-5P-camera-support-01.png`](images/80-PV086-5P-camera-support-01.png) PHY 三种示例 | 接口数量 / 满幅 IFE（Image Front End，图像前端）0/1 规格 **通用**；哪根 CSIPHY（CSI Physical Layer，CSI 物理层）走 D-PHY（MIPI CSI-2 D-PHY，差分物理层）或 C-PHY（MIPI CSI-2 C-PHY，三相物理层）**不通用** | 核对 SoC（System on Chip，片上系统）有 6 路 4-lane CSI（Camera Serial Interface，相机串行接口）、IFE（Image Front End，图像前端）0/1=25MP、5× Lite；解释为何前后都可以上满幅 IFE（Image Front End，图像前端） | 把图里 quadrant 3「前置 D-PHY（MIPI CSI-2 D-PHY，差分物理层）+ 后置 C-PHY（MIPI CSI-2 C-PHY，三相物理层）」抄进小米 pad DT（Device Tree，设备树）；把 GPIO（General Purpose Input/Output，通用输入输出）100 当 CAM_MCLK6 绑 Himax reset |
| [`80-88500-4-spectra-480.md`](80-88500-4-spectra-480.md) | [`images/80-88500-4-spectra-480-01.png`](images/80-88500-4-spectra-480-01.png) 预览/拍照数据通路；[`images/80-88500-4-spectra-480-02.png`](images/80-88500-4-spectra-480-02.png) BPS（Bayer Processing Segment，拜耳处理段） | 块图 **通用**；CamX（Camera eXtension，高通相机用户态框架）图 **不通用** | 产品口停在 IFE（Image Front End，图像前端）→ DDR 线性 NV12；安卓预览多半再进 IPE（Image Processing Engine，图像处理引擎） | 在 Linux 热路径接 IPE（Image Processing Engine，图像处理引擎）/ BPS（Bayer Processing Segment，拜耳处理段）/ Lite |
| [`80-88500-1-ife-clock.md`](80-88500-1-ife-clock.md) | [`images/80-88500-1-ife-clock-01.png`](images/80-88500-1-ife-clock-01.png) [`images/80-88500-1-ife-clock-02.png`](images/80-88500-1-ife-clock-02.png) [`images/80-88500-1-ife-clock-03.png`](images/80-88500-1-ife-clock-03.png) 公式 | 最低 HBI（Horizontal Blanking Interval，水平消隐）64 / VBI（Vertical Blanking Interval，垂直消隐）32 **通用**；传感器 XML（Extensible Markup Language，可扩展标记语言）里的 width/height/pixclk **按模式** | CAMIF（Camera Interface，相机接口）溢出、时钟算低了时 | 用厂商「平均消隐」当最小消隐；把 identity AXI（Advanced eXtensible Interface，高级可扩展接口）静默当成时钟问题 |
| [`80-88500-4-chi.md`](80-88500-4-chi.md) | （无图） | CHI（Camera HAL Interface，相机硬件抽象层接口）框架 **通用**；override / 传感器 XML（Extensible Markup Language，可扩展标记语言） **按模组** | 读懂安卓为何能改 pipeline 而不改驱动 | 在 Linux CAMSS（Camera Subsystem，相机子系统）里重放 CHI（Camera HAL Interface，相机硬件抽象层接口） |
| [`80-88500-4-chi-architecture.md`](80-88500-4-chi-architecture.md) | [`images/80-88500-4-chi-architecture-01.png`](images/80-88500-4-chi-architecture-01.png) `configure_streams` 时序 | 时序 **通用** | 对照 `configure_streams` 怎么选出 DAG（Directed Acyclic Graph，有向无环图） | 当 V4L2（Video for Linux 2，Linux 视频接口） STREAMON 手册 |
| [`80-88500-4-topology-xml.md`](80-88500-4-topology-xml.md) | [`images/80-88500-4-topology-xml-01.png`](images/80-88500-4-topology-xml-01.png) Node / Port / Link | XML（Extensible Markup Language，可扩展标记语言）语法 **通用**；选中哪张图 **按 Camera ID / 用例** | 解释 1MB CDM（Camera Data Mover，相机命令搬运器）为啥把 DISP（Display path，显示通路）+ TAP（Tap / downscale tap，抽头）+ FD（Face Detection，人脸检测）+ stats 叠在同一张第一表 | 把整张 DAG（Directed Acyclic Graph，有向无环图）的 CDM（Camera Data Mover，相机命令搬运器）一次性灌进 Linux 线性 WM（Write Master，AXI 写通道）4/5 |
| [`80-88500-4-camx.md`](80-88500-4-camx.md) | [`images/80-88500-4-camx-01.png`](images/80-88500-4-camx-01.png) 分层 | 分层 **通用**；Feature2 / ZSL（Zero Shutter Lag，零快门延迟） **按用例** | 看清 CamX（Camera eXtension，高通相机用户态框架）= `camx` + `chicdk`，IFE（Image Front End，图像前端）只是 HW node 之一 | 把 UBWC（Universal Bandwidth Compression，高通带宽压缩）+ IPE（Image Processing Engine，图像处理引擎）预览当 Linux 产品口 |

用法细则（Spectra 480（Qualcomm Spectra ISP，高通 Spectra 图像信号处理器）块图）见
[`.cursor/rules/dagu-spectra-480-manual.mdc`](../../../.cursor/rules/dagu-spectra-480-manual.mdc)。

## `80-PV086-5P` camera-support：硅通用，板级不通用

QRB5165 / SM8250 这一档 Spectra 480（Qualcomm Spectra ISP，高通 Spectra 图像信号处理器）：

- 6 个 4-lane CSI（Camera Serial Interface，相机串行接口），每口可 D-PHY（MIPI CSI-2 D-PHY，差分物理层）1.2（2.5 Gbps/lane）或 C-PHY（MIPI CSI-2 C-PHY，三相物理层）1.2。
- 满幅 IFE（Image Front End，图像前端）0、IFE（Image Front End，图像前端）1 各 25MP；5 个 IFE_Lite（Image Front End Lite，轻量图像前端）各 2MP raw。
- 最多 7 路并发。CCI（Camera Control Interface，相机控制接口）占用 GPIO（General Purpose Input/Output，通用输入输出）101–108，默认 CAM_MCLK 19.2 MHz。

图注写明 **example configurations**。三种象限：

1. 全 D-PHY（MIPI CSI-2 D-PHY，差分物理层）四路（兼容老传感器）。
2. 全 C-PHY（MIPI CSI-2 C-PHY，三相物理层）三路（高端）。
3. 混合：CSI_0/1 上 D-PHY（MIPI CSI-2 D-PHY，差分物理层）标 Front，CSI_2 上 C-PHY（MIPI CSI-2 C-PHY，三相物理层）标 Rear。

**dagu 飞行件不是象限 3。** 后置 s5kjn1 走 CSIPHY（CSI Physical Layer，CSI 物理层）1、D-PHY（MIPI CSI-2 D-PHY，差分物理层）4-lane；前置 imx596 走 CSIPHY（CSI Physical Layer，CSI 物理层）4、D-PHY（MIPI CSI-2 D-PHY，差分物理层）4-lane。CamX（Camera eXtension，高通相机用户态框架）色谱表里的 C-PHY（MIPI CSI-2 C-PHY，三相物理层）不是正在跑的 PHY。改前置不得捎带回后置 C-PHY（MIPI CSI-2 C-PHY，三相物理层）。

GPIO（General Purpose Input/Output，通用输入输出）表是 RB5 / QRB5165 **参考板**。本板 Himax `reset-gpios` 禁止绑 GPIO（General Purpose Input/Output，通用输入输出）100（面板 `tp-reset`）。不要把表里的 `CAM_MCLK6` / `#CAM*_RST_N` 直接写进小米 pad DT（Device Tree，设备树）。

前后摄 **共用** 这份硅能力（都能上满幅 IFE（Image Front End，图像前端），都能选 D-PHY（MIPI CSI-2 D-PHY，差分物理层））。前后摄 **不共用** 这份图上的传感器角色标注。

## `80-88500-1` IFE clock：溢出 bring-up，不是 identity 静默

Spectra（Qualcomm Spectra ISP，高通 Spectra 图像信号处理器）要求最小 HBI（Horizontal Blanking Interval，水平消隐）64、最小 VBI（Vertical Blanking Interval，垂直消隐）32。厂商 XML（Extensible Markup Language，可扩展标记语言）经常给的是**平均**消隐；用平均值算 IFE（Image Front End，图像前端）时钟会 CAMIF（Camera Interface，相机接口）溢出。手册要测**最小**消隐（`cam_ife_csid_get_hbi_vbi`，HBI（Horizontal Blanking Interval，水平消隐）bits [11:0]，再把 CSID（CSI Decoder，CSI 解码器）周期换算成传感器 pixclk）。

前后摄公式相同，数字按各自 mode。当前前置 identity 现象是 CAMIF（Camera Interface，相机接口）SOF/EOF 在走、AXI（Advanced eXtensible Interface，高级可扩展接口）WM（Write Master，AXI 写通道）不出字节——那是 CLC（Camera Logic Core，相机逻辑核）和 WM（Write Master，AXI 写通道）没对上，**先不要拿这章改时钟交差**。后置 Display Full 已经出过线性帧，时钟路径不是后置的主缺口。

## `80-88500-4` CHI / Topology / CamX：只读 dump

CHI（Camera HAL Interface，相机硬件抽象层接口）在 HAL3（Hardware Abstraction Layer 3，硬件抽象层第三版）之上再开五块：override 模块、pipeline XML（Extensible Markup Language，可扩展标记语言）、node 扩展（CPU / GPU / DSP）、3A（Auto Exposure / White Balance / Focus，自动曝光 / 白平衡 / 对焦）覆盖、传感器 XML（Extensible Markup Language，可扩展标记语言）。时序图：`open` → `chi_hal_override_entry` → `configure_streams` → 要么 override 出 live pipeline，要么退回默认 DAG（Directed Acyclic Graph，有向无环图）。

Topology XML（Extensible Markup Language，可扩展标记语言）是 Key+Data：key = session + streams，data = 一张 DAG（Directed Acyclic Graph，有向无环图）。`configure_streams` 选出**一整张**图。这就是安卓 1MB CDM（Camera Data Mover，相机命令搬运器）第一表把 identity 2592、Crop 640、FD（Face Detection，人脸检测）、stats 叠在一起的原因——不是「IFE（Image Front End，图像前端）只开 DISP（Display path，显示通路）Y/C（Luma/Chroma，亮度/色度）」。Linux CAMSS（Camera Subsystem，相机子系统）产品口只要线性 DISP（Display path，显示通路）Y/C（Luma/Chroma，亮度/色度）（WM（Write Master，AXI 写通道）4/5）。把整张 DAG（Directed Acyclic Graph，有向无环图）灌进去会把 640 dest 写到 2592 WM（Write Master，AXI 写通道）上，AXI（Advanced eXtensible Interface，高级可扩展接口）卡住。

CamX（Camera eXtension，高通相机用户态框架）分层图：HAL → CHI（Camera HAL Interface，相机硬件抽象层接口）→ IL（buffer/thread/metadata/pipeline/session）→ 软件 node（3A（Auto Exposure / White Balance / Focus，自动曝光 / 白平衡 / 对焦）/ GPU）+ 硬件 node（Sensor / IFE（Image Front End，图像前端）/ Post process）→ CRM（Camera Request Manager，相机请求管理器）。Linux 这一截只对应内核 CAMSS（Camera Subsystem，相机子系统）的 Sensor + IFE（Image Front End，图像前端），没有 CHI（Camera HAL Interface，相机硬件抽象层接口）也没有 Feature2 ZSL（Zero Shutter Lag，零快门延迟）。

NDA 手册 `80-PC212-1`、`80-PN984-4` **不在本目录**。公开章不够当 CHI（Camera HAL Interface，相机硬件抽象层接口）实现指南。

## 对照口诀

```text
# ❌ 图上 Rear=C-PHY → 给 s5kjn1 写 0x0114=0x0301
# ❌ GPIO 表 100=CAM_MCLK6 → Himax reset-gpios = GPIO100
# ❌ Topology 一张 DAG → 1MB CDM 原样灌 Linux WM4/5
# ❌ CamX 预览经 IPE → Linux 热路径接 IPE / 抄 UBWC
# ❌ IFE clock 公式 → 拿来「修」AXI 0 字节
# ✅ PHY 图 = SoC 能做什么；板级以 live CSIPHY 遥测为准
# ✅ 块图 = 产品口停在 IFE→DDR 线性
# ✅ Topology = 解释为何要拆端口，不是重放整图
# ✅ 时钟章 = CAMIF 溢出才用
```

## 第二批：传感器 XML / Linux CAMSS / 排障

这一批比 CamX（Camera eXtension，高通相机用户态框架）分层图更贴近 Linux，**仍然不是 Titan 480 SWI（Software Interface，软件接口手册）**。来源表见 [`SOURCES.md`](SOURCES.md)。

| 本地文件 | 对接下来适配 | 禁止 |
|---|---|---|
| [`80-88500-1-sensor-info-nodes.md`](80-88500-1-sensor-info-nodes.md) | `settleTimeNs` 公式、`Is3Phase`（0=D-PHY（MIPI CSI-2 D-PHY，差分物理层），1=C-PHY（MIPI CSI-2 C-PHY，三相物理层））、mode 的 width/height/`outputPixelClock`。对照安卓 XML（Extensible Markup Language，可扩展标记语言）和 live settle `0x13` | 传感器 + CSID（CSI Decoder，CSI 解码器）已活时再改 `0x0114` / settle 交差 |
| [`80-88500-1-module-config.md`](80-88500-1-module-config.md) | `laneAssign` / `cphydphyComboMode` 解释 CamX（Camera eXtension，高通相机用户态框架）bin 为什么会写 C-PHY（MIPI CSI-2 C-PHY，三相物理层） | 把 `isComboMode` / mixed PHY 抄进 dagu DT（Device Tree，设备树） |
| [`80-88500-1-cci-master.md`](80-88500-1-cci-master.md) | `cam_cci0` master 0/1 = 硬件 0/1；`cam_cci1` master 0/1 = 硬件 2/3。后置 CCI（Camera Control Interface，相机控制接口）0、前置 CCI（Camera Control Interface，相机控制接口）1 | 把 RB5 DTSI 节点名直接贴进本树 |
| [`80-88500-1-cci-speed.md`](80-88500-1-cci-speed.md) / [`80-88500-1-cci-timing.md`](80-88500-1-cci-timing.md) | CCI（Camera Control Interface，相机控制接口）100/400/1000 kHz；NACK / FIFO dump | 传感器已经探上时去改 CCI（Camera Control Interface，相机控制接口）时钟「修」PIX（Pixel path，像素通路） |
| [`80-88500-1-clock.md`](80-88500-1-clock.md) / [`80-88500-1-power-regulator.md`](80-88500-1-power-regulator.md) | 默认 CAM_MCLK 19.2 MHz；VANA/VDIG/VIO 映射 | 改 `vreg_l3a_0p9` 到 1.104 V |
| [`80-70015-17-v4l2.md`](80-70015-17-v4l2.md) / [`80-70020-17-stream-cameras.md`](80-70020-17-stream-cameras.md) | 上游 CAMSS（Camera Subsystem，相机子系统）正路：CSIPHY（CSI Physical Layer，CSI 物理层）→ CSID（CSI Decoder，CSI 解码器）→ VFE（Video Front End，视频前端；硅上是 IFE（Image Front End，图像前端））。官方写明 VFE（Video Front End，视频前端；硅上是 IFE（Image Front End，图像前端））的 RDI（Raw Dump Interface，原始旁路出口）**绕过**图像处理管线 | 把「官方只保证 RDI（Raw Dump Interface，原始旁路出口）」当成产品终点；dagu 飞行件要 PIX（Pixel path，像素通路）线性 NV12（YUV 4:2:0 semi-planar，半平面亮度/色度） |
| [`80-70020-17-camera-overview.md`](80-70020-17-camera-overview.md) | 分清 QMMF / Camera Core（下游）和 CamSS V4L2（Video for Linux 2，Linux 视频接口）（上游）是两套栈 | 在本树接 `qtiqmmfsrc` |
| [`80-70030-17-troubleshoot.md`](80-70030-17-troubleshoot.md) | CSID（CSI Decoder，CSI 解码器）debug 位图：SOF=1、EOF=2、**SOT=4**、EOT=8。`echo 0xf` 会解开 SOT | **禁止** CSID（CSI Decoder，CSI 解码器）SOT `0xffffffff` / bit2 解 mask |
| [`80-88500-4-camera.md`](80-88500-4-camera.md) / [`80-88500-4-capture-encode.md`](80-88500-4-capture-encode.md) | RB5 是 QMMF（Qualcomm Multimedia Framework，高通多媒体框架）+ IMX577，不是小米 pad | 抄 RB5 传感器表或 GStreamer 管道当 CAMSS（Camera Subsystem，相机子系统） |
| [`80-88500-4-isp-tuning.md`](80-88500-4-isp-tuning.md) | 写明 Chromatix **在 driver bringup 完成之后** | 前置 PIX（Pixel path，像素通路）没过门就调参 |
| [`kernel-qcom-camss.html`](kernel-qcom-camss.html) | 上游模型：RDI（Raw Dump Interface，原始旁路出口）旁路、PIX（Pixel path，像素通路）进处理管线再 scale/crop。8x16/8x96，不是 Titan 480 | 把 8x96 Encoder Crop 当 Titan 480 `0x4460` |
| [`qcom-sm8250-camss.yaml`](qcom-sm8250-camss.yaml) | SM8250 CAMSS（Camera Subsystem，相机子系统）时钟 / GDSC（Global Distributed Switch Controller，全局分布式开关控制器）/ CSIPHY（CSI Physical Layer，CSI 物理层）0–5 | 本树 DT（Device Tree，设备树）已经在飞，不要为「对齐 yaml 示例」改时钟名 |
| [`80-PV086-5P-dphy-routing.md`](80-PV086-5P-dphy-routing.md) | 板级 flex 阻抗 / 长度。CSID（CSI Decoder，CSI 解码器）已 SOF/EOF 就不是走线问题 | 用走线表解释 identity AXI（Advanced eXtensible Interface，高级可扩展接口）0 字节 |

公开页点了名但**下不下来**的：`80-PC212-1`、`80-PN984-4`、`80-70020-17A`、C-PHY（MIPI CSI-2 C-PHY，三相物理层）走线章（HTTP 403）、QRB5165 数据手册 PDF。Titan 480 SWI（Software Interface，软件接口手册）从来没公开过。

## 第三批：chroma 1984 还缺什么（2026-09-19 再搜）

前置 Display Full 2320×1320 现况是 `/tmp/pix.nv12` **4591616 / 4593600**，最后一行 chroma 只写了 336 字节。网上能公开拿到的手册**补不了这 1984 字节**。本批新归档：

| 本地文件 | 对 chroma 1984 | 禁止 |
|---|---|---|
| [`80-80022-17-stream-cameras.md`](80-80022-17-stream-cameras.md) | 2026-05-26 官方仍写：V4L2（Video for Linux 2，Linux 视频接口）CAMSS（Camera Subsystem，相机子系统）只保证 raw dump。解释为何上游不写 PIX（Pixel path，像素通路）线性 | 当「停在 SoftISP（Software Image Signal Processor，软件图像信号处理器）」；把 `qtiqmmfsrc` 当 dest |
| [`80-70022-17-offline-ife.md`](80-70022-17-offline-ife.md) | 只适用于 QCS9075：IFE_Lite（Image Front End Lite，轻量图像前端）RDI（Raw Dump Interface，原始旁路出口）→ DDR → 离线 IFE（Image Front End，图像前端） | 拿 Lite / 离线 fetch 修满幅 IFE（Image Front End，图像前端）1 |
| [`80-88500-3-ubwc.md`](80-88500-3-ubwc.md) | 证明安卓预览走 UBWC（Universal Bandwidth Compression，高通带宽压缩）是 QMMF（Qualcomm Multimedia Framework，高通多媒体框架）正路，不是 Linux 线性口 | 抄 UBWC（Universal Bandwidth Compression，高通带宽压缩）stride / 开压缩机 |
| [`cam_isp_ife.h`](cam_isp_ife.h) | `CAM_ISP_IFE_OUT_RES_FULL_DISP` = `0x3000+19`。端口名对上 Display Full | 当寄存器手册 |
| [`cam_vfe_bus_ver3.c`](cam_vfe_bus_ver3.c) | CAF SM8250：WM（Write Master，AXI 写通道）4/5 = FULL_DISP；线性 NV12（YUV 4:2:0 semi-planar，半平面亮度/色度）packer = `PLAIN_8_LSB_MSB_10`；`IMAGE_CFG_1` = `h_init`；Y/C（Luma / Chroma，亮度/色度）C 高度 /2。**已经**和 overlay 对齐；`IMAGE_CFG_1` 非 0、packer 3、Y/C（Luma / Chroma，亮度/色度）C 高度 659 都证伪过 | 再改 packer / `IMAGE_CFG_1` / Dual-IFE（Image Front End，图像前端） `COMP_CFG` 交差 |

网上**搜不到、永远不会公开**的（chroma 1984 真正缺口）：

1. Titan 480 SWI（Software Interface，软件接口手册）：没有 `FRAME_INCR` 对最后一行 chroma 336 字节的说明，没有 `viol_id` 表。
2. CamX（Camera eXtension，高通相机用户态框架）`CreateCmdList` 源码：只在已拉下来的 `camera.qcom.so`（stripped，但 `camxifemnds21titan480.cpp` 的 VERB 格式串还在）。1MB 第一表 opcode 4 是 UBWC（Universal Bandwidth Compression，高通带宽压缩）identity WM（Write Master，AXI 写通道），不是 Display Full 线性。步骤见 [`../dagu-ife-android-dump-reverse.md`](../dagu-ife-android-dump-reverse.md)。
3. HyperOS **线性** Display Full 的 WM（Write Master，AXI 写通道）4/5 AXI（Advanced eXtensible Interface，高级可扩展接口）图：Camera ID 1 活流是 UBWC（Universal Bandwidth Compression，高通带宽压缩）identity 2592 给 IPE（Image Processing Engine，图像处理引擎）。CamX（Camera eXtension，高通相机用户态框架）log 的 Display Full 口是 **2304×1296**，MNDS（MN Down Scaler，M/N 下采样器）是 2314×1314。没有一张 2320×1320 线性 NV12（YUV 4:2:0 semi-planar，半平面亮度/色度）可抄 stride。

板上还能做、网上做不了的下一步：HyperOS 只读开 CamX（Camera eXtension，高通相机用户态框架）VERB（`DisplayFullpath` / `MNDS Disp Luma imageSize`）和 `autoImageDumpIFEoutputPortMask IFEOutputPortDisplayFull=0x400000`。禁止刷 HyperOS 板 `53dcc70`。禁止再试 MNDS（MN Down Scaler，M/N 下采样器）Y H_PHASE `0xc023d82c`、H_PHASE `0xc047b058`、H_SIZE dest、packer 3、`0x7e60`。
