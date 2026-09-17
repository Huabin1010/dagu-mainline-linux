# Titan 480 IFE PIX 线性 NV12：已做尝试与为何仍 0 帧

记录日期：**2026-09-17**。  
板上内核：不刷机复测时是 `7.0.0-dirty #336`（`SMP PREEMPT Thu Sep 17 08:48:31 CST 2026`），只刷 **B 槽**。A 槽 HyperOS 救援机 `18d1:4ee7` / `53dcc70` 未动。  
CLC 切法与 `#333` 同一 overlay；`#334`–`#336` 是键盘等其它提交，PIX 签名未变。  
源码：`linux-mainline/overlays/linux/drivers/media/platform/qcom/camss/camss-vfe-480.c`  
测试：`linux-mainline/scripts/dagu-ife-pix-test.sh`（IFE1，后置 s5kjn1，NV12 1920×1080，STREAMON 12s）  
安卓对照：`dumps/dagu-android-live/camera-ife-20260916/` + `camera.qcom.so` PackIQ / CreateCmdList  
不刷机抓包：`linux-mainline/out/camera/ife-pix-336-dmesg.txt`

本文只写 **已经在 B 槽刷过、有板上遥测的切法**。不是计划，不是「还能再试一遍」的清单。

## 1. 目标

### 1.1 最终产品（飞行交付，不是本文的 3 帧门）

这块板是带屏平板。用户摸的是 Snapshot / 微信 / 腾讯会议 / Chromium 里的预览，不是 `/tmp/pix.nv12`。最终交付是把 **Spectra Titan 480 IFE** 接到 Linux 像素热路径上：传感器 Bayer 在 IFE 里完成 demosaic / 缩放 / 打包，DDR 里直接是 **线性 NV12**，合成器和摄像头应用吃这份 DMA，**CPU 不再解 Bayer**。

今天的产品预览仍是这条软路径（飞行合格，但是洞）：

```text
传感器 RAW10
  → CAMSS RDI
  → libcamera DebayerCpu（后 skip 4×4 → 1020×764；前 skip 2×2 → 1296×976）
  → loopback NEON RGB→YUYV，中心裁到 1280×720
  → v4l2loopback /dev/video20 前、/dev/video21 后
```

最终要换成这条硬路径（后置先打通，前置同一套架构跟上）：

```text
s5kjn1 RAW10 4080×3060 GBRG，D-PHY `r0114=0x300`
  → CSIPHY1 4-lane D-PHY
  → CSID1 IPP（无 horizontal_bin）
  → IFE1 CAMIF 2ppc
  → CLC：Demux → Demosaic → CST → Crop → Display MNDS → RoundClamp
  → BUS DISP WM4/5 线性 NV12 packer 3（PLAIN，不是安卓 UBWC `0xB`）
  → V4L2 dmabuf NV12 1920×1080 @~30 全 FOV
  → Snapshot / PipeWire / Chromium（不再经 DebayerCpu / RGB→YUYV）
```

对齐安卓 live 的是 **硅和几何**，不是包装：

| 项 | 最终 Linux | 安卓 live（对照，不是照抄） |
|----|------------|------------------------------|
| PHY | 后置 D-PHY 4-lane，`0x0114=0x300` | 同。CamX 色谱表 C-PHY **禁止** |
| IFE | Titan 480 PIX，后置走 **IFE1** | 同（IFE0 闲） |
| 后置预览 | **全 FOV** 1920×1080 @~30，MNDS 缩小，不是中心裁、不是 skip | 同尺寸；出口是 UBWC NV12 + DS4 给 IPE |
| 前置预览（后置门过后再做） | csiphy4 / imx596，IFE 全 FOV，对标安卓 1440×1080 @30 | IFE 1440×1080；Linux 现在 skip 2×2 是门前预览 |
| 像素出口 | V4L2 **线性** NV12（Mesa / DPU / libcamera 能吃的 PLAIN） | HWC **UBWC** NV12 + WM6/7 PD10 |
| 3A / IPE / BPS | 出帧之后的画质层，**不是**把 SoftISP 踢出热路径的前提 | CamX + IPE |
| 用户态 | 主线 CAMSS + libcamera，**禁止** CamX blob / `-Dipmbs` | `camera.qcom.so` |
| 替身 | **禁止** CDSP「AI 降噪」、GPU EGL SoftISP、llvmpipe | 无此旁路 |

最终合格（缺一项即产品没交付，不只是实验室出过帧）：

- 后置 Viewfinder 走 IFE NV12 **1920×1080 全 FOV ~30 fps**，室内有可辨图像，不是 0 缓冲、不是花屏、不是只有 SOF
- 前置同一硬路径跟上（几何按 imx596 / 安卓 1440×1080，不拿后置寄存器「修」前置）
- `DebayerCpu` 和 loopback `rgb_to_webcam_yuyv` **离开预览热路径**。v4l2loopback 若还在，只当应用不会吃 NV12 dmabuf 的胶水，不再是解 Bayer 的引擎
- 预览开着时 mutter 可点、Himax 跟手，不必再把 Debayer 钉 A77 才能 30 fps
- 传感器仍是 live D-PHY；CSID SOT 保持 mask；`g_serial` `0525:a4a7` >30s；只刷 B 槽
- **不要**为了出帧去开 ICC、写 QUPV3 wrapper CSR、解 SOT、改 `0x0114=0x0301`

还不是最终、但允许晚于 IFE 出帧的：闭环 3A、IPE 3DNR/HDR、多摄同步。没有它们预览仍然是硬件 ISP；有它们才接近安卓画质。本文不把 IPE 当第一刀。

### 1.2 本文阶段门（通向最终的硬门槛）

最终路径的第一块砖：IFE1 后置 **线性 NV12 真的从 BUS 写到 DDR**。测法是 `scripts/dagu-ife-pix-test.sh`（IFE1，s5kjn1，1920×1080，STREAMON 12s）。缺一项即本阶段失败：

- `STREAMON` 至少 **3 帧非零 NV12**（`/tmp/pix.nv12` 不是 0 字节）
- 传感器 `r0114=0x300`（后置 D-PHY，禁止改成 C-PHY `0x0301`）
- `g_serial` `0525:a4a7` 稳住 >30s
- 这 3 帧来自 IFE PIX，不是 RDI + `DebayerCpu`

过了这扇门，才允许讨论把 Viewfinder 切离 SoftISP。**没过之前，skip 4×4 / 2×2 仍是飞行预览，不是终点，也不准关 skip 来「补」ISP。**

### 1.3 当前

**阶段门没过，最终更没到。** `#336` 不刷机复测 `/tmp/pix.nv12` 仍是 **0 字节**，`streamon_rc=124`。桌面继续 SoftISP。

卡在哪：后置总图 [`dagu-ife-pipeline-status.md`](dagu-ife-pipeline-status.md)；前置本刀 [`dagu-ife-front-pipeline-status.md`](dagu-ife-front-pipeline-status.md)。

禁止当「先这样」：

- 只开 BUS DISP、不编程 CLC（会卡 CAMNOC）
- 解 CSID SOT mask、改 `0x0114`、开 ICC、写 QUPV3 wrapper CSR
- 空 EN 的 GTM / LIN / PDPC11 / HDR / DSX `0x5e00`
- 没有真实 DSX10 程序就 `STREAMON` WM6/7
- 把 Bayer 塞进 `CORE_CFG_0` bit24/25（那是 DSP streaming）
- 把 identity CLC、3 帧 dump、或继续 skip 预览写成产品终点

## 2. 安卓在跑什么，Linux 想对齐什么

第 1.1 节是产品终点。下表是 **本文阶段**（IFE1 后置线性 NV12 出帧）要对齐的寄存器类，不是把安卓 UBWC+IPE 整图搬进 Linux。

HyperOS 后置预览（IFE1，不是 IFE0）：

| 项 | 安卓 live | Linux `#333` 目标 |
|----|-----------|-------------------|
| 传感器 | s5kjn1 RAW10 4080×3060 GBRG，`r0114=0x300` | 同 |
| CSID IPP CFG0 | `0x802b20e3`（无 horizontal_bin bit2） | 同，已对齐 |
| IFE | Titan 480 PIX | 同 |
| 预览出口 | WM4/5 **UBWC NV12** 1920×1080，顺带 WM6/7 PD10（DSX10 + DISP R2PD **开**） | WM4/5 **线性** NV12 packer 3，R2PD **关**，WM6/7 EN=0 |
| `CORE_CFG_0` | `0x60000800`（operating_mode + VID R2PD off，DISP R2PD on） | `0x78000800`（DISP R2PD 也 off） |
| CLC | CamX CDM 完整 IQ | 内核按 CreateCmdList 重打包 identity / keep-all |
| 3A / IPE | 有 | 本阶段只要线性 NV12 出帧 |

Linux 不跟 UBWC 预览。V4L2 要的是 PLAIN NV12。安卓开 DSX/R2PD 是因为还要 DS4 给 IPE，不是线性 NV12 的必要条件——这一点已经用空 DSX EN=EPIPE、R2PD-on 无 DSX 仍 `as0=0` 两边打过。

## 3. `#333` 失败签名（每次 STREAMON 都长这样）

| 探针 | 读回 | 含义 |
|------|------|------|
| `r0114` | `0x300` | 传感器 D-PHY 在出数 |
| CSID IPP `cfg0` | `0x802b20e3` | 和安卓 IPP 一致；VC=3 是日志里的 pad 参数，IPP CFG0 **不写** CSI VC |
| CAMIF MODULE | `0x3000101` | EN + IFE_OUT + GBRG pattern 粘住 |
| CAMIF 计数 | `pix=4080 line=1530` | Titan 480 **2ppc**：3060 行进 CAMIF 后计数停在 1530。像素到了 CAMIF |
| PIXEL PIPE OVERFLOW | `irq0 bit31`，`viol_id=0` | 管线末行溢；`viol_id=0` **不是**「像素没到 MNDS」的证明 |
| WM4/5 `cfg` | `0x1` | EN=1，`MODE_QCOM_PLAIN` |
| packer | `3` / `3` | CamX `get_packer_fmt(NV12)=PLAIN_8_LSB_MSB_10` |
| packer FSM `dbg` | 空闲 `0x20a`，溢后 `0x2ea` | **bit8 从未置位**（packer 没拿到 valid） |
| `as0` | `0` | 从未消耗 IMAGE_ADDR |
| `as3` | ping 地址已锁 | 缓冲区给过 BUS，BUS 没写出去 |
| CAMNOC `IFE_LINEAR` fill | `0` | AXI 零突发 |
| `/tmp/pix.nv12` | 0 字节 | 用户态 0 帧 |

一句话：**传感器和 CAMIF 在跑；CLC→packer→DDR 这条没交出过一个字节。**

读遥测时不要搞反：

- `as0=0` + `as3` 有值 = 地址锁了、没消耗，不是「没配 buffer」
- CLC `+0x1F4` 全 0 不能当「像素没进 CLC」——CAF 只把 CAMIF debug 映到 `0x27F4`
- `viol_id=0` 是窗口检查类，不是「MNDS 没像素」
- 寄存器读回 0 可能是 **write-only**（BLS PIXEL、Pedestal `0x2c5c`），不能当没写上

### 3.1 `#336` 不刷机复测（2026-09-17 08:57，现核 STREAMON 12s）

没改 overlay、没编核、没刷 B。`g_serial` `0525:a4a7` 仍在，loopback-watch 已拉回。`streamon_rc=124`，`/tmp/pix.nv12` 0 字节。CSID1 IRQ 706，VFE1 IRQ **6**（溢一次之后 PIX 不再收，CSID 还在 SOF/EOF）。

| 探针 | `#336` 读回 | 怎么用 |
|------|-------------|--------|
| `r0114` | `0x300` | D-PHY 仍在出数 |
| IPP `cfg0` | `0x802b20e3` | 无 hbin，与安卓一致 |
| `CORE_CFG_0` | `0x78000800` | DISP/VID R2PD 全 off |
| CAMIF MODULE | `0x3000101` | GBRG + EN + IFE_OUT |
| CAMIF `0x27F4` | `pix=4080 line=1530` | 满幅进门。`dbg1=0x82d68008` 未解码 |
| `overflow clcstat` | camif/bls/demux/demo/crop/mnds/post **全 0** | **不能当级间探针**。CAMIF `+0x04` 也是 0，但 `0x27F4` 已满计数，所以 hw_status 不是像素进度 |
| `TOP_DEBUG` | `0x0 / 0x55555555 ×3` | mux=`TOP_DEBUG_CFG=1` **盲**。`0x55555555` 是空探针，不是 CLC 停在某一级 |
| BUS `comp` rst/clr/go/ovf | **`0x0/0x0`** | `COMP_CFG_0/1` 从未写成安卓那张 `0xF0`。文档「#312 没改 mask、mask 卡在 WM4–7」在这两颗寄存器上不成立 |
| WM6/7 | `cfg=0x10`，`addr=0`，`as3=0` | EN=0，DS 完全没上电。`0x10` 不是 EN |
| packer | 编程时 `0x20a/0x206`，溢后 `0x2ea/0x2e6` | bit8 仍未置位 |
| `as0` / `as3` | `0` / ping 已锁 | 与 `#333` 同 |
| CAMNOC `IFE_LINEAR` | fill=0 | AXI 零突发 |
| BUS `top` | cfg=5（client 4），status=0 | DISP Y 调试口也无活动 |
| `fh0`/`fh4` | 0 | 线性路径无 frame header，符合 CAF |

结论（不刷机就能定的）：

1. `#336` 与 `#333` 同一卡死点：CAMIF 满计数，packer 无 valid，0 帧。键盘核没有改变 PIX。
2. **不要**再用 `clcstat` 或 `TOP_DEBUG=1` 去猜「卡在 Demux 还是 POST」——这两路当前是盲的。要级间定位，先从 CamX 拿到 `TOP_DEBUG_CFG` 的 mux 编码再读，那是下一刀的前置，仍不必刷 CLC 窗。
3. **`COMP_CFG` 读回 0/0 是对的，不要往里写 WM 掩码。** CAF `cam_vfe_bus_ver3_start_comp_grp` 只在 `is_dual` 时写 `comp_cfg_0/1`，位是 `bit(grp)` 和 `bit(grp+14)`（Dual-IFE 地址同步）。安卓后置预览是单 IFE1，Linux 保持 0 与 CAF 一致。软件 `composite_mask 0xF0` 是「这组里有哪些 client」的内存位图，不是 0xAA0C 的现态。往 `COMP_CFG` 塞 `0xF0`/`0x30` 属于把 Bayer 塞进 `CORE_CFG` 那一类。client→`COMP_GRP_1` 在 `cam_vfe480.h` 表里硬线（WM4–7 共用 COMP_DONE），那条要用 **完整 DSX10** 证伪，不是改 Dual-IFE 寄存器。
4. MID RoundClamp 已经 EN（`mid_y/c=0x3c01`）。`dagu-android-ife-analyze.py` 里「MID 仍 EN=0」过时，不是剩下的卡死点。

## 4. 已经接通、板上能证明的一段

这些不再是「没接上」：

1. **媒体图**：`csiphy1 → csid1 pad4 → vfe1_pix`，IFE1 不是 IFE0。
2. **CSID IPP**：RAW10 decode、crop、pix_store、**没有** bit2 水平 bin。曾经 bin 过会把 CAMIF 宽度卡在 2040。
3. **CAMIF 2ppc**：`CROP` 4079×1529 粘住；Bayer GBRG 在 MODULE bit24–26，不在 `CORE_CFG_0`。
4. **CLC 时钟**：`CGC_OVD` 全开；`PWR_ISO=0`。
5. **Display MNDS**：尺寸读回 `hsz=0x77f0fef vsz=0x43705f9`（1920×1080 keep-all 编码粘住）。MODULE 写 `0x103` 读回 `0x101`（bit1 掉，和 Crop 同类）。
6. **Crop11 / RoundClamp PRE·MID·POST·OUT**：PIXEL/LINE keep-all 粘住。
7. **CST** BT.601 Q10 矩阵粘住。
8. **CC / WB / Gamma** identity（Q10 1.0 或 identity DMI）粘住。
9. **BUS**：packer 3、UBWC static LPDDR5 `0x1036`、IMAGE_ADDR 在 `camif_go` 之后才 EN。
10. **RDI SoftISP** 一直能出 RAW：SMMU / CAMNOC / CSID RX 不是「整颗 IFE 死了」。

卡死点在 **CAMIF 之后、WM packer 之前**。

## 5. 怎么切、怎么判死刑

每一刀只改一处 CamX 有出处的寄存器类，刷 B，跑 PIX：

| 板上现象 | 判定 |
|----------|------|
| `line=0` / `pix=0` | 空砖墙（empty EN 或错误 LUT）。**立刻撤回**，persist 禁止 |
| `STREAMON EPIPE -32` | 编程了安卓 TAP/DSX 空模块。撤回 |
| 编码读回截断 / 弹成 0 或 1-bit | 寄存器不是我们以为的窗。记录，不要把读回当 keep-all |
| `line=1530` 且 `as0=0` 且编码粘住 | 这一项 **不是剩下的 AXI 卡死点**（证伪） |
| 3 帧非零 NV12 + `r0114=0x300` | 门过了 |

`line=1530` 的切法仍然留在树上（keep-all / identity），因为它们是正路编程，只是单独拆出来都不够打通 packer。

## 6. 按模块：做过什么，证伪了什么

### 6.1 传感器 / CSID / 图

| 尝试 | 结果 |
|------|------|
| 后置改 C-PHY / `0x0114=0x0301` | 禁止。CSID FIFO 卡、Snapshot 黑。live PHY 是 D-PHY |
| IPP CFG0 bit2 当 TIMESTAMP | Titan 480 这 bit 是 **horizontal_bin**。4080→2040，CAMIF 对不上。已关掉 |
| 图接到 IFE0 | 安卓预览是 IFE1。Linux 现跟 IFE1 |
| IPP drop pattern=0 period=1 | 与 RDI 相同极性；RDI 能出帧，IPP `cfg0` 已等于安卓 |

**不是卡死点。** `#333` IPP `cfg0=0x802b20e3`。

### 6.2 `CORE_CFG` / R2PD / WM6/7

| # | 尝试 | 结果 |
|---|------|------|
| | Bayer 塞进 `CORE_CFG_0` bit24/25 | 变成 DSP streaming（`0x63000800`）。禁止。Bayer 在 CAMIF MODULE + Demux |
| 310 | `CORE_CFG_0=0x60000800`（跟安卓，DISP R2PD **on**）无 DSX | 仍 `as0=0` `line=1530` |
| 312 | DISP R2PD **off**（`0x78000800`）+ WM6/7 EN=0 | 仍 `as0=0`。空 DS / R2PD-on-无 DSX 都不是「单独剩下的那一个」 |
| | 空 `vfe_480_crop(CLC_DSX=0x5e00)` | **#318 STREAMON EPIPE -32**。persist 禁止 |
| 317/320 | 把 Crop 写进 DS411 TAP `0x5408` | 那是 DMI_CFG；crop 进了 LUT。禁止 |

线性 NV12 继续 R2PD-off、WM6/7 不开。完整「真实 DSX10 DMI + R2PD-on + WM6」**还没有作为一套程序打过**（空 DSX 禁止；identity DSX LUT 很大，未刷）。

### 6.3 CAMIF

| # | 尝试 | 结果 |
|---|------|------|
| 322 | MODULE `0x3000101`（GBRG<<24 \| 0x101） | **粘住**。缺 Bayer 不是卡死点 |
| 324 | `CAMIF_CROP_HEIGHT=pipe_h-1=1529` | **粘住**。写成 3059 时 3059 行永远到不了（2ppc） |
| | CAMIF EN 在 IMAGE_ADDR 之前 | 首帧 SOF 就溢。现改为 `camif_go` 在 DISP_C 地址之后 |
| | skip/period keep-all `0xffffffff` / `0x00010001` | 计数满幅，说明没把像素 skip 掉 |

CAMIF 在出 4080×1530。**不是卡死点。**

### 6.4 空 EN = 砖墙（`line=0`，已禁）

这些 EN=1 但不填 identity IQ 时，CAMIF 计数停在行 0——像素在 CLC 入口就被砖掉：

| 模块 | 现象 | 现状 |
|------|------|------|
| PDPC11 `0x2800` 空 EN | line=0 | EN=0 旁路 |
| LIN `0x2a00` 空 EN；#308 identity DMI+knee | 仍 line=0 | EN=0，persist 禁 `vfe_480_lin` |
| GTM/WB/Gamma 空 EN | line=0 | 改为 identity 后回到 line=1530 |
| HDR `0x2400` 空 EN | 同类，禁止 | EN=0 |
| DSX `0x5e00` 空 Crop EN | EPIPE | 禁止 |

结论：CLC 里 **有些块 EN=0 是旁路，有些空 EN=1 是砖**。不能靠「全部打开碰运气」。

### 6.5 CLC 窗 / identity（粘住，仍 `as0=0`）

下面每一项都在板上 **粘住过 keep-all 或 identity**，且仍是 `line=1530 as0=0`。单独拆出来都不是剩下的 AXI 卡死点：

| 模块 | CamX 出处 | 板上 |
|------|-----------|------|
| Demux period + DMI + `0x3068` | Demux13 | 粘 |
| Demux 尾 `0x30ac` Crop11 | #321 | EN+LINE 粘；PIXEL 6-bit 截断。空尾窗证伪 |
| Demosaic compact MODULE | 只 pack `0x3860×1` | 粘。额外 interp `0x3878` 禁止 |
| WB13 `0x3868×4` Q10 0x400 | #329 CreateCmdList `@0x546be8` | **粘住 0x400×4**。零增益不是卡死点 |
| LSC40 `0x3668×11` 16×12×256×128 + Q14/Q20 inv | #330 PackIQ `@0x537e6c` | **网格粘住**。空网格证伪。compact MODULE 只有 BIT(0)；不要写 `0x3658=1` 却不填 bank1 |
| CC 3×3 Q10 单位阵 | CC13 | 粘。全零矩阵会乘黑 |
| GTM10 / Gamma identity DMI | GTM10 / Gamma16 | 粘 |
| CST BT.601 | CST12 | 粘 |
| Crop11 Y/C ×9 | Crop11 | PIXEL/LINE 粘。MODULE 写 `0x3` 读回 `0x1`（#323，bit1 只写） |
| RoundClamp PRE/MID/POST/OUT 窗 | #313/#316 | 粘。OUT EN=0 不是剩下的卡死点 |
| MNDS Display Y/C | `@0x5391fc`，**不是** Video `0x6c00` | 尺寸粘 |
| PDPC30 identity DMI + Q10 gain | #331 关 DMI_CFG 后再写 AHB | 粘 |
| ABF compact EN=1，**不**清零 `0x3268` | 复位 `0x8000/0x1000100` | 清零是空 kernel，禁止 |
| ABF bank2 identity DMI + EN | #328 `0x3408` | MODULE 粘。空 AHB+EN 不是 line-0，也不是剩下的 AXI 卡死 |
| BLS 4-bank DMI 正确 n | #325 `0x100/0x100/0x80/0xa8` | 错把 CamX **offset** `0x280` 当 count（#315）已证伪 |
| BLS Crop11 + DMI_CFG=0 | #327 | MODULE **cfg=0x1 粘住**。PIXEL 仍 write-only 弹 0 |

### 6.6 编码写错、读回拆穿（不是窗）

| # | 写入 | 读回 | 结论 |
|---|------|------|------|
| 314 | BLS `+0x68` Crop11 | 0 | write-only / 弹。不能靠读回证明窗落地 |
| 332 | Pedestal `0x2c68` 当 14-bit 行窗写 1529 | `0x01f90000`（10-bit `[25:16]` 截成 505） | **不是 V 窗**。PackIQ 14-bit 来自 chromatix +552，不是 `pipe_h-1`。#333 已改回 0 |
| 332 | Pedestal `0x2c5c` Crop11 4079 | 弹 0 | 13-bit 对、write-only（BLS PIXEL 类）。keep-all 可能写进去了，仍 `as0=0` |
| 333 | ABF `0x3270/0x3274` 当 PackIQ 12-bit 区域窗 | **`0x10000/0x10000`**（只留 bit16） | 硅上是 **1-bit**，不是 12-bit 窗。4079/1529 为奇数所以 bit16=1 |

`#333` 没有 line-0，也没有打通 packer。空 ABF 12-bit 区域 **不能**再当「剩下的那一个」——因为 keep-all 根本没落到 12-bit 字段上。

## 7. 刷机时间线（#308 起有编号）

更早还有：IFE1 图、packer 3、debug mux、CGC、CAMIF 延后 EN、CC/Gamma/WB identity、Pedestal DMI、Demux period。从 LIN 起编号如下。

| 内核 | 切法 | 板上 |
|------|------|------|
| 308 | LIN identity DMI n=36 + knee | **line=0**，撤回 |
| 345 | live DMI36 + 16 AHB from 0x2a64 | **line=0**，2a64=0 / 2a68 truncated。撤回 |
| 309 | 撤回 LIN | 回到 line=1530 |
| 310 | `CORE_CFG` 跟安卓 R2PD-on | as0=0 |
| 311 | Demosaic extra interp | as0=0 |
| 312 | R2PD-off，WM6/7 EN=0 | as0=0 |
| 313 | RoundClamp PRE 窗 | 粘，as0=0 |
| 314 | BLS +0x68 两字窗 | 弹 0 |
| 315 | BLS DMI sel4 n=0x280 | 那是 offset。line=1530 as0=0 |
| 316 | OUT RoundClamp 窗 | 粘，as0=0 |
| 317 | DS411 `0x5408` 当 crop | TAP DMI，弹 |
| 318 | 空 Crop EN `0x5e00` | **EPIPE -32** |
| 319 | 撤回 0x5e00 | 遥测恢复 |
| 320 | 停写 DS411 crop | TAP stuffing 证伪 |
| 321 | Demux `0x30ac` Crop11 | 空尾窗证伪 |
| 322 | CAMIF Bayer | 粘，as0=0 |
| 323 | Crop MODULE 0x3 | 读回 0x1，as0=0 |
| 324 | CAMIF HEIGHT 1529 | 粘，as0=0 |
| 325 | BLS 四 bank 正确 n | as0=0 |
| 326 | BLS Crop11 ×9 | PIXEL 仍 0 |
| 327 | BLS 先关 DMI_CFG | MODULE 粘住 0x1，as0=0 |
| 328 | ABF bank2 DMI+EN | as0=0 |
| 329 | WB13 Q10 unity | 粘 0x400，as0=0 |
| 330 | LSC40 网格 | 网格粘，as0=0 |
| 331 | Pedestal/PDPC 关 DMI_CFG | AHB 落地，as0=0 |
| 332 | Pedestal `0x2c5c/0x2c68` 当窗 | `0x2c5c` 弹；`0x2c68` 10-bit 截断 |
| **333** | ABF `0x3270` 当 12-bit 区域；撤回 `0x2c68` HEIGHT | **`3270=0x10000` 1-bit**。仍 0 帧 |
| 337 | compact Demux 7 字；FULL `0x3068` 不写；ABF Crop11 `0x3270` | compact 粘住。`3270=0x10000` last=1 |
| **338** | 撤回 ABF `0x3270` Crop11 | `3270=0x1000` 复位。仍 0 帧，packer `0x2ea` |
| **339** | Pedestal compact：不写 `0x2c5c`/`0x2c68` | `2c68` 复位仍 0。仍 0 帧 |
| **340** | PDPC compact：不写 `0x2e68` Q10 AHB | `2e68=0/0/0` 复位。仍 0 帧，packer `0x2ea` |
| **341** | ABF bank2 compact：不写 `0x3458`/`0x3468`，MODULE `0xc101` | `3468=0/0` 复位。仍 0 帧，packer `0x2ea` |
| **342** | BLS 停 Crop11：`0x2268×0x2e` 是 IQ 不是窗 | `bls=0x1/0/0/0`。仍 0 帧，packer `0x2ea` |

全程（#318 除外）USB / `g_serial` 保住。#318 是 PIX EPIPE，不是打回兔子。

## 8. 为什么还是不行（第一性原理）

不是「驱动没 probe」。PIX 子设备在、IPP 在、CAMIF 在计数、一长串 CLC 的 keep-all/identity 粘住、WM 开着、地址锁过。

卡死的物理图像是：

```text
传感器 RAW10 ──▶ CSID IPP ──▶ CAMIF（4080×1530 已证明）
                                      │
                                      ▼
                              CLC 像素管线
                                      │
                          这里没有 valid 交给 packer
                                      │
                                      ▼
                         WM4 packer FSM 停在 0x2ea
                         as0=0  CAMNOC fill=0  NV12=0
```

所以「还不行」不是分辨率写错、不是没开 WM、不是 SMMU 整段拒绝（RDI 能写 RAW）、也不是 `r0114` 走了 C-PHY。

更具体的三种可能，**都还没被一套完整程序证伪**：

1. **CLC 里仍有一块在系列上，EN=1 但 IQ 不是 identity**  
   空窗类我们已经按 CamX compact 路径补了一批；FULL 路径还有大段 AHB（BLS 46 字里 PackIQ 只填约 9 个 12-bit 字、ABF `0x3268×19` compact 不 pack）。compact 在安卓上能出预览，所以「必须 FULL」不是默认答案，但 Linux 没跑 CamX compact 的同一份 CDM。

2. **Display Full → WM4 的握手还缺安卓那条 DS 支路的完整程序**  
   CAF 表里 WM4–7 同属 `COMP_GRP_1`（COMP_DONE IRQ），安卓 WM6/7 EN=1。Linux 把 6/7 关掉以免空 DSX 卡 CAMNOC。#310/#312 说明「只拨 R2PD 位 / 只关 WM6」不够。`#336` 已证明不要动 Dual-IFE `COMP_CFG`。没证明的是：**dsx10setting 的 DMI（`0x5c08` sel 1–13）+ `0x5e68×9` + DISP R2PD-on + WM6/7 一起开**。空 `0x5e00` EN 已经毁过 STREAMON。LUT 不是 `(i<<8)|i`：CreateCmdList `@0x509548` 的 n 是 `0x30, 0x100×5, 0x40×2, 0x100×5`，系数来自 `IFEDSX10GetInitializationData`。没有 live CDM / 没有 port setting，不许刷。

3. **packer 3 要的位宽/对齐和当前 CLC 出口不一致**  
   RoundClamp 按 10-bit 0–0x3ff 编程了。packer 3 是 CamX 给线性 NV12 的枚举。这条假设弱：安卓预览实际是 UBWC packer `0xB`，不是 3；我们坚持线性是产品约束。没有「改 packer 魔数碰绿」的资格，除非 CamX 对 PLAIN NV12 另有枚举且 Linux 写错——目前 `get_packer_fmt(NV12)=3` 对得上。

还没有证据支持的叙事（不要再当根因讲）：

- 「IFE 没时钟」——CGC 全开，CAMIF 在数行
- 「像素从没离开传感器」——`r0114=0x300`，IPP IRQ SOF/EOF，CAMIF 4080×1530
- 「buffer 没配」——`as3` 锁了 ping
- 「必须 ICC」——这套 QHEE 上 BCM voter 会打死 USB/MDSS；DT 删了 camss interconnect。RDI 能写，说明「没 ICC 就完全不能进 CAMNOC」不成立
- 「再 skip 一点 / 再绑大核」——那是 SoftISP，不是 IFE

## 9. 禁止再做（已经毁过机或证伪）

`apply-overlays.sh` 对 `camss-vfe-480.c` 的 persist 就是这份黑名单的机器版。人读重点：

- 空 EN：PDPC11 / LIN / HDR / GTM 空 / `0x5e00`
- 空/Q10 `vfe_480_lin`（#308）；`vfe_480_mnds(0x6c00)`（那是 Video MNDS）；DS411 crop 写 `0x5408`
- Bayer 进 `CORE_CFG_0`；猜写 `CORE_CFG_1` / MAXWR
- 清零 ABF `0x3268` / `0x3468`；LSC `0x3658=1` 不填 bank1
- Demosaic 写 `0x3878` interp
- UBWC packer `0xB` 当 V4L2 NV12
- WM 在 IMAGE_ADDR=0 时 EN；CAMIF 在 buffer 前 EN
- IPP horizontal_bin；CSID SOT 解 mask；ICC

写错编码的切法（#332 `0x2c68` 当行高、#333/#337 `0x3270` 当 Crop11）不要再刷第二遍。compact Pedestal 只 `0x2c60×1`，不要再写 `0x2c5c`/`0x2c68`。

## 10. 下一刀必须满足的条件

只接受 **CamX CreateCmdList / PackIQ 有 MOVZ 地址 + 字段宽度** 的完整程序，并且：

- 能解释为什么 `#338` 的 CAMIF 满计数却 packer 无 valid
- 空 IQ 不会变成 line-0 / EPIPE
- 占 `linux-mainline/tmp/kernel-build/lock` 编核，只刷 B，`g_serial>30s`

候选（未作为完整程序证伪，不是「先试这个」的承诺）：

- Pedestal compact（`#339`）：`@0x540a30` 只 `0x2c60×1` + 零 LUT。`2c68` 复位就是 0，不是剩下的卡死点
- PDPC30 compact（`#340`）：`@0x537048` 只 `0x2e60×1`。`2e68` 复位 0，不是剩下的卡死点
- ABF bank2 compact（`#341`）：`@0x528688` 只 `0x3460×1`。`3468` 复位 0，不是剩下的卡死点
- BLS Crop11 at `0x2268`（`#342`）：CreateCmdList 是 `0x2268×0x2e` IQ。停写后 PIXEL 仍弹 0，不是剩下的卡死点。没有 live 对象+0x18 不许打 46 字
- CST compact（`#344`）：`@0x52d178` 只 `0x4060×1`。overflow `cst=0x1/0x0/0x0`。EN=1+矩阵 0 把 RGB 乘 0。live FULL IQ+0x1c 12 字在 `live-cst12.txt`（vtable `0x8bb7d0`）。`#347` 打这 12 字，仍禁自猜 BT.601
- LIN live AHB 图（`#345`）：DMI 36 + 16 knee 从 `0x2a64` EN=1 → **line=0**，`2a64` 读回 0、`2a68` 截断。撤回。字节仍在 unused helper / `live-lin-dmi36.txt`。没有 CreateCmdList 目的地址不许再 EN
- DSX10：chromatix `dsx10_ife_video_full_dc4` 只有 18 个 0.996 float。compact `@0x52e8e0` Display Full **不打** DSX（只 TAP 3/5/6）。`@0x509548` DMI sel1–13 + `0x5e68×9` 无 BL xref；`0x8bba10` 是 BPS `0x6c58`。没有 LUT 字节 **禁止**空 EN / `(i<<8)|i` / 写 Dual-IFE `COMP_CFG` / 开 WM6/7
- HDR FULL 影子在 `[ctx+0xc0]+0x2460`，不是 type-`0x18` 堆对象。没有影子不许打 `0x2460`（#345 同类）。live 字段在 `live-hdr30-ahb.txt`
- `COMP_CFG_0/1`：**禁止再当下一刀。** CAF 仅 Dual-IFE 写；单 IFE 保持 0。软件 `0xF0` 不是这两颗寄存器

## 11. 和别的文档的关系

| 文档 | 角色 |
|------|------|
| 本文 | PIX NV12 尝试与证伪 |
| `dagu-ife-pipeline-status.md` | 后置两路分叉 + IFE 卡死点 mermaid |
| `dagu-ife-front-pipeline-status.md` | 前置 imx596 PIX 卡死点 mermaid（本刀） |
| `dagu-camss-pix-audit.md` | 审计入口；飞行预览仍是 DebayerCpu |
| `dagu-arm-linux-eval.md` | 七维评估：相机仍是最大软路径洞 |
| `.cursor/rules/dagu-camera-rear.mdc` | 后置 D-PHY / skip 4×4 飞行合格，禁止捎带回 C-PHY |

直到第 1.2 节的阶段门过了，**不要**把 Viewfinder 切到 IFE NV12，**不要**关 SoftISP skip 来「补」ISP。第 1.1 节的最终交付还要再过前置硬路径和踢掉 Debayer 热路径，3 帧 dump 不等于产品完工。
