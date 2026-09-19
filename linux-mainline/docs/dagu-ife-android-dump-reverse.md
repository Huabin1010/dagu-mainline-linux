# 前置 Display Full：安卓 dump 彻底逆向 + 公开手册 → 可执行步骤

网上**没有**「一键把 Titan 480 IFE（Image Front End，图像前端）dump 还原成 SWI（Software Interface，软件接口手册）」的工具。公开章没有 `0x4460`、没有 Crop 9-word、没有 `viol_id`。能把 chroma 1984 钉死的，是板上已有的原件，不是再搜一篇块图。

本页是 2026-09-19 再搜公开网 + 对照现有 dump 之后的**飞行步骤**。只读 HyperOS `53dcc70` `18d1:4ee7`。禁止刷那块板。Linux 只刷 `ab22268c` B 槽。

## 0. 现在卡在哪（原件，不是猜测）

chroma 1984 的几何：`#499` Y IOVA `0xff000000`（4K 对齐），C `0xff2eba80`。最后一行 chroma 从 `0xff460eb0` 起，**336 字节碰到 4K 页边 `0xff461000` 就停**（336+1984=2320）。`#382` 2304×1296 短 2048 是同一刀：最后一行 256+2048。CAF `update_wm` 线性 `FRAME_INCR=stride×slice_h`、`IMAGE_CFG` 宽高不对齐；4K `ALIGNUP` 只给 UBWC（Universal Bandwidth Compression，高通带宽压缩）。后置 1920×1080 最后一行也跨 4K（384+1536），`#365` 却写满——**不是**通用 AXI（Advanced eXtensible Interface，高级可扩展接口）4K 截断，禁止 `ALIGN_UP FRAME_INCR`。Linux `#499` `/tmp/pix.nv12` **4591616 / 4593600**。`wm4=0x5280910` `wm5=0x2940910` `incr5=0x175d40` 已经是 2320 dest。活 CLC（Camera Logic Core，相机逻辑核）：Crop Y H_STRIPE=`0`（堆原件），Crop C H_STRIPE=`0x90f0000`（`#474` KEEP），MNDS（MN Down Scaler，M/N 下采样器）Y `hst=0x90f0000` / C `hst=0x0`（`#406` dest writel 已撤），`hsz=0xa1f05bf` 相位 Y unity `0xc0200000`、C `0xc0400000`。`#406` 已证伪 C H_STRIPE dest。后置 `#365` 三帧完整。

安卓 Camera ID 1 活流是 `RealTimeFeatureZSLPreviewRaw`：

| 原件 | 尺寸 | 格式 |
|---|---|---|
| 活 WM（Write Master，AXI 写通道）4/5（1MB CDM（Camera Data Mover，相机命令搬运器）opcode 4） | 2592×1952 / 2592×976，stride 3584，`FRAME_INCR` `0x6b4000` / `0x35a000`，packer `0xb` | UBWC（Universal Bandwidth Compression，高通带宽压缩）identity，给 IPE（Image Processing Engine，图像处理引擎） |
| CamX（Camera eXtension，高通相机用户态框架）log `Display full path` | **[0,0,2304,1296]** | 仍标 format=12 UBWC（Universal Bandwidth Compression，高通带宽压缩） |
| CamX（Camera eXtension，高通相机用户态框架）`camxifeds411 MNDS output` | **2314×1314** | 堆里 Crop last `0x0a1f05bf` 的 Q21 来源 |
| CamX（Camera eXtension，高通相机用户态框架）`Applied display full path` | **[0,7,2592,1458]** | 传感器窗，不是 Linux 线性 dest |
| IPE（Image Processing Engine，图像处理引擎）input | 2304×1296 stride 3072 | 禁止抄进 Linux WM（Write Master，AXI 写通道） |

Linux 现在写的是 **MNDS（MN Down Scaler，M/N 下采样器）2314×1314 再垫到 2320×1320**。安卓真正交给 IPE（Image Processing Engine，图像处理引擎）的 Display Full 口是 **2304×1296 UBWC（Universal Bandwidth Compression，高通带宽压缩）**。2320 和 2304 线性都在最后一行 chroma 跨 4K 处停写；后置 1920 同样跨 4K 却写满。下一刀仍要同一包线性 `IMAGE_CFG_0`，禁止用 `ALIGN_UP FRAME_INCR` 或盲改 dest 来「躲 4K」。

后置对照（已过门）：`camera-ife-20260916/wm-live.txt` Camera ID 0，WM（Write Master，AXI 写通道）4 `IMAGE_CFG_0=0x4380780` **1920×1080** UBWC（Universal Bandwidth Compression，高通带宽压缩）（C `0x21c0780` 1920×540）。Linux `#365`  dest 就是这个宽高、压缩机关掉。前置 **没有** 同等 CAM_DBG：1MB opcode 4 是 identity 2592。

## 1. 网上工具打分（0–10，只打「对 chroma 1984 有没有新原件」）

| 工具 | 分 | 能拿到什么 | 不能当什么 |
|---|---|---|---|
| CAF `cam_cdm_util.h` opcode 3 `REG_CONT` + opcode 4 `REG_RANDOM` | **9** | WM（Write Master，AXI 写通道）就是 opcode 4。本树分析器以前只走 opcode 3，**漏了活 BUS** | 不是 CLC（Camera Logic Core，相机逻辑核）9-word 手册 |
| 已拉下来的 `dumps/.../so/camera.qcom.so`（8.9MB，stripped）+ `strings` / Capstone | **8** | 源路径还在：`camxifemnds21titan480.cpp`、`DisplayFullpath %d %d %dx%d`、`MNDS Disp Luma imageSize` | 不是 SWI（Software Interface，软件接口手册） |
| CamX（Camera eXtension，高通相机用户态框架）`autoImageDumpIFEoutputPortMask=0x400000` + `logCtxMask` VERB | **8** | 短时打开前置预览，吐 Display Full 口文件名里的 w/h/stride；VERB 打出 MNDS（MN Down Scaler，M/N 下采样器）Disp 各 word | 预览仍可能是 UBWC（Universal Bandwidth Compression，高通带宽压缩）；文件不是 Linux 线性样板 |
| CAF `cam_vfe_bus_ver3.c`（已归档） | **8** | 线性 `FRAME_INCR = stride × slice_height`；UBWC（Universal Bandwidth Compression，高通带宽压缩）再 `ALIGNUP(..., 4096)+meta`；`IMAGE_CFG_1=h_init` | `#400` 已证伪「把 1984 写进 FRAME_INCR」 |
| `cam_debug_util` `debug_mdl=0x0300800D` + `--reacquire` | **7** | 活 `WM:4/5 en_cfg / image height and width / frame_inc` | STRICT_DEVMEM，没有 MMIO |
| Magisk `LD_PRELOAD` `dagu-cdm-dump.c` | **7** | 扫 dmabuf / malloc 里的 CDM（Camera Data Mover，相机命令搬运器） | 只 dump 1056768 会漏 Display Full 那包；曾经 SIGSEGV |
| Ghidra / IDA（本机现在**没装**，有 Capstone + `objdump`） | **7** | 从格式串 xref 到 `CreateCmdList` 怎么 pack Disp H_STRIPE / V_SIZE | 禁止当 V4L2（Video for Linux 2，Linux 视频接口）热路径重放 |
| Frida hook `CreateCmdList` | **5** | 若 Magisk zygisk 能进 `cameraserver` | 不是默认路径；能 `LD_PRELOAD` 就别上 Frida |
| `msm_media_info.h` UBWC（Universal Bandwidth Compression，高通带宽压缩）stride | **2** | 只用来**认出**安卓文件是压缩口 | 禁止当 Linux dest |
| 公开 `80-88500-4` Spectra 480（Qualcomm Spectra ISP，高通 Spectra 图像信号处理器）/ Topology / CHI（Camera HAL Interface，相机硬件抽象层接口） | **3** | 解释为何 1MB 第一表叠 DISP（Display path，显示通路）+ TAP（Tap / downscale tap，抽头）+ FD（Face Detection，人脸检测）+ stats；产品口停在 IFE（Image Front End，图像前端）→ DDR 线性 | 补不了 1984 字节 |
| `80-88500-3` UBWC（Universal Bandwidth Compression，高通带宽压缩）章 / `80-70022-17` 离线 IFE（Image Front End，图像前端） | **1** | 证明安卓预览压缩是正路 | 禁止 Lite / 离线 / 开压缩机 |
| Qualcomm SpectraSim C7、binwalk、上游 CAMSS（Camera Subsystem，相机子系统）RDI（Raw Dump Interface，原始旁路出口）指南 | **0–1** | JPEG meta / raw dump | 不是 PIX（Pixel path，像素通路）线性 |

**结论：** 彻底逆向 = 补 opcode 4 + 打开 `camera.qcom.so` 里已经编进去的 VERB + 把 Display Full **那一包** CDM（Camera Data Mover，相机命令搬运器）和活 WM（Write Master，AXI 写通道）拆开。不是再爬一篇手册。

## 2. 语法（必须先会，再看 dump）

CAF `cam_cdm_util.h`：

| opcode | 名 | dump 里长什么样 |
|---|---|---|
| `0x3` | `CAM_CDM_CMD_REG_CONT` | `cmd[7:0]=n`，下一 word 是起始 AHB（Advanced High-performance Bus，高级高性能总线）地址，随后 n 个连续值。Crop / MNDS（MN Down Scaler，M/N 下采样器）9-word 走这条 |
| `0x4` | `CAM_CDM_CMD_REG_RANDOM` | n 对 `(addr, val)`。**活 WM（Write Master，AXI 写通道）4/5 走这条** |
| `0x5` | `BUFF_INDIRECT` | 间接再指另一段 CDM（Camera Data Mover，相机命令搬运器） |
| `0x8` | `CHANGE_BASE` | 换 IFE（Image Front End，图像前端）基址 |

Titan 480 BUS：`0xaa00 + 0x200 + n×0x100`。WM（Write Master，AXI 写通道）4 = `0xb000`，WM（Write Master，AXI 写通道）5 = `0xb100`。

`IMAGE_CFG_0` = `(height << 16) | width`。线性 `FRAME_INCR = stride × slice_height`。chroma 高度 /2。packer 线性 Y=`PLAIN_8_LSB_MSB_10`(3)，C=`PLAIN_8`(1)。安卓活口 packer `0xb` = UBWC（Universal Bandwidth Compression，高通带宽压缩），禁止抄。

Topology XML（Extensible Markup Language，可扩展标记语言）一张 DAG（Directed Acyclic Graph，有向无环图）= 1MB 第一表把 identity 2592 + Crop 640 + TAP（Tap / downscale tap，抽头）+ FD（Face Detection，人脸检测）叠在一起。Linux CAMSS（Camera Subsystem，相机子系统）只要 DISP（Display path，显示通路）Y/C（Luma / Chroma，亮度 / 色度）（WM（Write Master，AXI 写通道）4/5）线性。

## 3. 已有原件（不要重拉一遍当进度）

```text
dumps/dagu-android-live/camera-ife-20260916/so/camera.qcom.so
dumps/dagu-android-live/camera-ife-20260917-front/live-cdm-1mb.bin
dumps/dagu-android-live/camera-ife-20260917-front/live-display-2304.txt
linux-mainline/docs/qcom-public/cam_vfe_bus_ver3.c
linux-mainline/docs/qcom-public/cam_isp_ife.h          # FULL_DISP = 0x3000+19
linux-mainline/scripts/dagu-android-ife-analyze.py
linux-mainline/scripts/dagu-cdm-dump.c
```

`live-cdm-1mb.bin` 用 opcode 4 解出来已经是 identity UBWC（Universal Bandwidth Compression，高通带宽压缩）2592，**没有** 2320 线性 WM（Write Master，AXI 写通道）。Display Full Crop `0x0a1f05bf` 只在 heap / `live-display-2304.txt`。分析器 `pack_is_disp_linear()` 只认 opcode 3，所以一直说「第一表没有 Display Full WM（Write Master，AXI 写通道）」——那是解析器洞，不是板上没写。

## 4. 执行顺序（一次一件，只读安卓）

### 4.1 补分析器：opcode 4 → WM（Write Master，AXI 写通道）表

改 `dagu-android-ife-analyze.py` 的 `parse_cdm_ahb()`：opcode 4 按 `(addr,val)` 对解开，输出 `wm4/wm5 IMAGE_CFG_0 / CFG2 / FRAME_INCR / PACKER / ubwc_regs`。离线跑：

```text
python3 linux-mainline/scripts/dagu-android-ife-analyze.py \
  --offline dumps/dagu-android-live/camera-ife-20260917-front \
  --cdm-bin dumps/dagu-android-live/camera-ife-20260917-front/live-cdm-1mb.bin
```

门：报告里必须出现 WM（Write Master，AXI 写通道）4 `0x7a00a20`、WM（Write Master，AXI 写通道）5 `0x3d00a20`、packer `0xb`。这是对照基线，不是 Linux dest。

### 4.2 扩 CDM（Camera Data Mover，相机命令搬运器）dump：所有 looks_cdm，不限 1MB

`dagu-cdm-dump.c` 把 `len==1056768` 写成 `dagu-ife-cdm.bin`，含 `0x0a1f05bf` 的 mapping 另写 `dagu-ife-cdm-disp-*.bin`（最多 8 个 / 8MB）。txt 现在会打 opcode 4 的 `0xb00c`/`0xb10c`/`FRAME_INCR`/`packer`/`burst`。NDK 产物：`linux-mainline/out/android/libdagu-cdm-dump.so`。`dagu-android-ife-verb-dump.sh` 会 push 到 `/data/local/tmp/`。默认**不** `LD_PRELOAD`（曾经 SIGSEGV）。要扫 malloc 才 `DAGU_CDM_PRELOAD=1`。拉回后找 **同一包里同时有 Crop `0x0a1f05bf` 和 `0xb00c`/`0xb10c`** 的 buffer。那才是 Display Full 的 WM（Write Master，AXI 写通道）。

### 4.3 打开 so 里已经编好的 VERB（比 Ghidra 快）

`camera.qcom.so` 带这些串：

```text
DisplayFullpath %d %d %dx%d, Fullpath %d %d %dx%d
MNDS Disp Luma horizontalStripe0 [0x%x]
MNDS Disp Luma horizontalPhase   [0x%x]
MNDS Disp Luma verticalPhase     [0x%x]
MNDS Display Chroma horizontalSize     [0x%x]
MNDS Display Chroma horizontalStripe1  [0x%x]
MNDS Display Chroma verticalPadding    [0x%x]
MNDS Full Luma imageSize         [0x%x]   # identity 2592，不是 Display Full
Path %d[0-FD,1-Full], MNDS output dimension [%d * %d]
```

HyperOS（Magisk，只读）。一键脚本会把 VERB 写进 **`/data/vendor/camera/camxoverridesettings.txt`**（厂商文件 `logInfoMask=0x0` 会吃掉 persist），抓完 **trap 恢复**。禁止留一整晚 VERB。

```text
./linux-mainline/scripts/dagu-android-ife-verb-dump.sh
```

```text
adb -s 53dcc70 shell su -c 'setprop persist.vendor.camera.logInfoMask 0xffffffff'
adb -s 53dcc70 shell su -c 'setprop persist.vendor.camera.logVerboseMask 0xffffffff'
# 若属性被忽略，改 /vendor/etc/camera/camxoverridesettings.txt（重启 cameraserver，不要重启整机刷写）
# FileMask=0x7FFFFFFF
# logCtxMask=0x7FFFFFFF
# logOutputMask=2
```

前置预览 5 秒，立刻：

```text
adb -s 53dcc70 logcat -d -s CamX:V CamX:I | grep -E 'DisplayFullpath|MNDS Disp|MNDS output|IFEOutputPortDisplayFull|horizontalStripe|imageSize'
```

要记下的数字（缺一项就还没逆向完）：

1. `DisplayFullpath` 的 `W×H`（预期 2304×1296）
2. MNDS（MN Down Scaler，M/N 下采样器）Disp Luma `horizontalStripe0` / `horizontalPhase` / `verticalPhase` 的 **hex**（so 里没有 `MNDS Disp Luma imageSize`）
3. MNDS（MN Down Scaler，M/N 下采样器）Display Chroma `horizontalSize` / `horizontalStripe1` 同比。`MNDS Full Luma imageSize` 只当 identity 对照
4. 有没有另一条线性 Display Full（compressor off）。没有就不要假装安卓有 2320 线性样板

抓完把 mask 改回 0。禁止开一整天 VERB。

### 4.4 CamX（Camera eXtension，高通相机用户态框架）图像 dump（只开 Display Full 口）

公开表（[Camx Dump Raw Frames](https://www.iopenv.com/V4AQRIU7Y/Camx-Dump-Raw-Frames)）：

```text
IFEOutputPortDisplayFull = 0x400000
autoImageDumpMask IFE    = 0x1
IFEInstanceName1（满幅 IFE（Image Front End，图像前端）1，前置）= 0x2
```

```text
adb -s 53dcc70 shell su -c 'setprop persist.vendor.camera.autoImageDump 1'
adb -s 53dcc70 shell su -c 'setprop persist.vendor.camera.autoImageDumpMask 0x1'
adb -s 53dcc70 shell su -c 'setprop persist.vendor.camera.autoImageDumpIFEoutputPortMask 0x400000'
adb -s 53dcc70 shell su -c 'setprop persist.vendor.camera.autoImageDumpIFEInstanceMask 0x2'
```

开前置 2 秒。`adb pull` `/data/vendor/camera/` 里带 `DisplayFull` / `DISP` / `w[` 的文件。看文件名 w/h 和体积：

- `w[2592]_h[1952]` 且体积对 UBWC（Universal Bandwidth Compression，高通带宽压缩）stride 3584 → 还是 identity，**扔掉**
- `w[2304]_h[1296]` → 这是安卓 Display Full 口。量 stride。若仍是压缩 meta 平面，只当对照，禁止抄进 `camss-vfe-480.c`
- **没有** `w[2320]_h[1320]` 线性文件 → 2320 是 Linux 垫高，不是安卓活口

立刻 `autoImageDump=0`。禁止 `AllPixelOutput` 把磁盘写爆。禁止 dump IPE（Image Processing Engine，图像处理引擎）/ BPS（Bayer Processing Segment，Bayer 处理段）。

### 4.5 用 Capstone 钉 CreateCmdList 的 Disp pack（本机无 Ghidra 时）

```text
strings -t x dumps/dagu-android-live/camera-ife-20260916/so/camera.qcom.so \
  | grep 'MNDS Disp Luma horizontalStripe'
# 记下 rodata 偏移，Capstone 扫 bl 到打印该串的函数，反出写入 0x4c60 的 9-word 顺序
```

要回答的唯一问题：Display Full 路径上 H_STRIPE / V_SIZE / V_PHASE 哪几个 word 被 pack 成 0、哪几个进 CDM（Camera Data Mover，相机命令搬运器）。Linux overlay 已经按 heap 9-word 抄过；这一步是确认 **2304 dest 会不会写进 H_STRIPE**，而不是再盲写 `0x090f0000`。

### 4.6 对照公开手册（只做过滤，不做 dest）

| 手册 | 用来 | 禁止 |
|---|---|---|
| `80-88500-4-spectra-480` | 产品口停在 IFE（Image Front End，图像前端）→ DDR | 接 IPE（Image Processing Engine，图像处理引擎） |
| `80-88500-4-topology-xml` | 丢掉 TAP（Tap / downscale tap，抽头）/ FD（Face Detection，人脸检测）/ stats | 整表灌 Linux |
| `80-88500-3-ubwc` | 认出安卓预览压缩 | 开压缩机 / 抄 3584 |
| `cam_vfe_bus_ver3.c` | 线性 `FRAME_INCR` 公式 | 再试 `#400` |
| `80-88500-1-ife-clock` | 只有 CAMIF（Camera Interface，相机接口）溢出 | 拿来修 1984 |
| `80-70030-17` | SOT 是 bit2 | `echo 0xf` |

## 5. dump 齐了之后，Linux 只许这样改

门仍是 `/tmp/pix.nv12` ≥3×**完整帧**、UV（chroma，色度）~128、`viol≠19`、无 PIXEL PIPE OVERFLOW、来自 IFE（Image Front End，图像前端）1 PIX（Pixel path，像素通路）+ CLC（Camera Logic Core，相机逻辑核），不是 RDI（Raw Dump Interface，原始旁路出口）。

| dump 结果 | Linux 下一刀（仍一变量） |
|---|---|
| VERB / opcode 4 给出 Display Full **线性** WM（Write Master，AXI 写通道）`IMAGE_CFG_0` 明确 W×H | 只改 WM（Write Master，AXI 写通道）4/5 的 width/height/`FRAME_INCR` 去对齐该 W×H。Crop / MNDS（MN Down Scaler，M/N 下采样器）keep-all 不动，除非同一包 CDM（Camera Data Mover，相机命令搬运器）也改了 dest last |
| 只有 2304×1296 UBWC（Universal Bandwidth Compression，高通带宽压缩），没有线性口 | **不要**把 2304 当线性 dest 交差。继续用 2320 垫高，但用 VERB 的 Disp `imageSize` hex 去对 Linux 遥测 `crop_*` / `mnds_*`。对不上的那一个 word 才是下一刀 |
| Disp `horizontalStripe` hex ≠ Linux `0x090f0000` 且不是 identity `0x0a1f0000` | 才允许写 Crop Y H_STRIPE。禁止盲写 |
| 仍对不上 | 停。不要 Dual-IFE（Image Front End，图像前端）`COMP_CFG`，不要 `#465` H_PHASE，不要 `#411` H_PAD，不要 `#414` identity H_STRIPE，不要 `#406` MNDS（MN Down Scaler，M/N 下采样器）C H_STRIPE dest writel，不要 `#463` `0x7e60` |

刷 Linux：pack `boot-dagu.img` 后 `WAIT=20 ./scripts/flash-boot.sh flash-b`。`fb-usb.py devices` 必须 `timeout 3`。已看见 `18d1:d00d` + `ab22268c` 立刻刷，不等 reboot OKAY。

## 6. 禁止清单（已毁过机 / 已证伪）

```text
# ❌ 再搜一篇公开手册当 chroma 1984 答案
# ❌ Ghidra 出函数就把整张 CreateCmdList 灌进 camss-vfe-480.c
# ❌ autoImageDump 开 AllPixelOutput / IPE / BPS
# ❌ 把 1MB 第一表 opcode 3+4 原样重放
# ❌ 抄 WM packer 0xb / stride 3584 / FRAME_INCR 0x6b4000
# ❌ echo 0xf 解 CSID SOT
# ❌ 刷 53dcc70
# ❌ 无 VERB hex 就写 Crop Y H_STRIPE 0x090f0000 当「继续」
# ❌ 后置已 3×整帧仍把前置 1984 当 4K FRAME_INCR 交差
# ✅ opcode 4 解出 WM 表
# ✅ 同一包 CDM 里 Crop 0x0a1f05bf + WM IMAGE_CFG_0
# ✅ 一刀只动 dump 钉死的那一个寄存器
```

## 7. 2026-09-19 opcode 4 + so 原件（本机，HyperOS 未插）

`parse_cdm_ahb()` 已解 opcode 4。离线报告：`out/camera/ife-android-analyze/opcode4-offline/`。

1MB 第一表 last-write：

| WM（Write Master，AXI 写通道） | cfg0 | 尺寸 | stride | FRAME_INCR | packer |
|---|---|---|---|---|---|
| 4 | `0x7a00a20` | 2592×1952 | 3584 | 7028736 | `0xb` UBWC（Universal Bandwidth Compression，高通带宽压缩） burst `0x13` |
| 5 | `0x3d00a20` | 2592×976 | 3584 | 3514368 | `0xb` burst `0x27` |
| 6 | `0xf40144` | 324×244 | 2816 | 720896 | TAP（Tap / downscale tap，抽头） |
| 8 | `0x1e00280` | 640×480 | 640 | 307200 | FD（Face Detection，人脸检测） |

磁盘上现有 bin **没有** Display Full `IMAGE_CFG_0`（2304/2314/2320）。两份 1MB 只有 identity 2592。`camera-ife-20260918-id1` malloc 对 `0x0a1f05bf` 是 0 命中。`camera.qcom.so` 里 `0xb00c` 只出现一次，在 `0x193ff4`：CDM（Camera Data Mover，相机命令搬运器）窗口描述符（offset `0xb00c`、len `0x44`），不是 dest。同文件和现有 bin **零** 条 `IMAGE_CFG_0` 2304/2314/2320；`0x0a1f05bf` 也不在 so 里（只在 heap）。活 WM（Write Master，AXI 写通道）只走 opcode 4。so IQ 反序列化在流不够长时 `str wzr, [x19, #0xd4]`，和堆里 Stripe0=0 一致。`com.qti.sensormodule.dagu_aac_imx596_front.bin` 只有两个 IFE（Image Front End，图像前端）模式 u32 对：`0x29550` **2592×1952**、`0x2b1c0`/`0x2ce30` **2592×1472**（Crop last `0x0a1f05bf`）。模块里的 1296/1314/1320/1458/1920/1080 跟在 `delayUs` 后面，是 I2C 延时，**不是** dest，也不是 CamX（Camera eXtension，高通相机用户态框架）Applied `[0,7,2592,1458]` 的寄存器原件。2304 是 I2C `0x0900`，2320 是孤立 u16 `0x0910`。**没有** 2304×1296 成对。前置 tuned Chromatix **从未拉过**（只有后置 `s5kjn1`）；Stripe0 hex 在那份 bin 里，不在 sensor module。下一包必须新 dump。`libdagu-cdm-dump.so` 现在会把 2304/2314/2320 的 `IMAGE_CFG` 也落 bin（`disp_wm`）。VERB 脚本会顺手 pull `com.qti.tuned.*imx596*`。

`camera.qcom.so` `CreateCmdList` @ `0x538fc0`：`WriteRegContinuous(cmd, addr, n=9, src)`。

- Crop Y `0x4460` ← `x20+0x18`
- Crop C `0x4660` ← `x20+0x3c`
- `[x20+0xfc]==6` → **Display Full** MNDS（MN Down Scaler，M/N 下采样器）Y `0x4c60` ← `x20+0x60`，C `0x4e60` ← `x20+0x84`
- `==1` → FD（Face Detection，人脸检测）`0x6460` / `0x6660`

so `0x4dbb64`：Disp `horizontalStripe0` 读出来后 `and #0x3fff`（14-bit）。`0x422a50`：MNDS（MN Down Scaler，M/N 下采样器）output 只做 **偶对齐** `and #0xfffffffe`（2314 已是偶数），**不是** Linux 16 对齐到 2320。后置 Display Full 9-word 同样 H_STRIPE=`0`，`#365` 三帧完整——**Stripe0 不是 chroma 1984 的杠杆**。缺的仍是同一包线性 `IMAGE_CFG_0`。

`camera.qcom.so` MNDS（MN Down Scaler，M/N 下采样器）Disp VERB 簇 `@ 0x4dbe80`（不是 `MNDS Disp Luma imageSize`，那串不存在）：

| IQ 偏移 | VERB 名 | 对应 9-word |
|---|---|---|
| `x19+0xcc` | Disp Luma `horizontalSize` | H_SIZE |
| `x19+0xd0` | `horizontalPhase` | H_PHASE |
| `x19+0xd4` | `horizontalStripe0` | H_STRIPE（heap 已是 0） |
| `x19+0xe0` | `verticalSize` | V_SIZE |
| `x19+0xe4` | `verticalPhase` | V_PHASE |
| `x19+0xf8` | Display Chroma `horizontalSize` | C H_SIZE |

`mov w4, #0x900` `@ 0x57aef4` 是 RNF FIR `maxVal`，不是 2304 dest。`DisplayFullpath` 打印点 `@ 0x672978`。

HyperOS `18d1:4ee7` 此刻未插。插上跑 `./linux-mainline/scripts/dagu-android-ife-verb-dump.sh`。Linux 板 `0525:a4a7` 不要当安卓 dump。禁止无 VERB hex 盲写 Crop Y H_STRIPE。
