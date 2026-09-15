# Chrome GPU 一线 + Venus（禁止软解了事）

日期：2026-09-12。设备 `dagu` / SM8250。  
规则：`.cursor/rules/dagu-no-soft-fallback.mdc`。

## 源码结论（Chrome 153.0.8010.36）

`media/mojo/services/gpu_mojo_media_client_linux.cc`：

- `kAcceleratedVideoDecodeLinux` 的 **feature 名是 `AcceleratedVideoDecoder`**。关掉就返回 `VideoDecoderType::kUnknown` → FFmpeg。
- `GetActualPlatformDecoderImplementation()` **有** `kV4L2` 分支，GLES 还要 `AcceleratedVideoDecodeLinuxGL`。
- 真正选 VA-API 还是 V4L2 的是 `ActiveLinuxVideoDecoderType()`（`media/base/decoder.h`）：只看编译期 `USE_VAAPI` / `USE_V4L2_CODEC`。两边都编了才看 `kPreferV4L2VideoAcceleration`。

官方 `/opt/google/chrome/chrome` 字符串：`USE_V4L2=0`、`PreferV4L2=0`、`/dev/video-dec=0`。  
**不能**靠开关让这份 Google Chrome 打开 Venus。一线路径是 **`use_v4l2_codec=true` 的 Chromium**（amazingfate 已在 QCOM Venus stateful 上跑通：<https://github.com/amazingfate/chromium-libv4l2-patches>）。

`media/gpu/v4l2/v4l2_device.cc`：ChromeOS 扫 `/dev/video-dec*`，通用 Linux 扫 `/dev/video*`。Armbian 在 SM8250 上给 `qcom-venus-decoder` 做了 `video-dec` 符号链接。

禁止：VA-API 冒充 Venus、v4l2 request、`--disable-gpu-rasterization`、把 FFmpeg 软解当交付。

## 已落地（2026-09-12 夜）

xtradeb / Debian arm64 **Chromium 152.0.7977.82**（`use_v4l2_codec`，二进制有 `V4L2StatefulVideoDecoder` / `Using a stateful API`）。包装：`linux-mainline/scripts/dagu-chromium.sh`。

| 项 | 证据 |
|----|------|
| Video Decode | **Hardware accelerated**（`linux-mainline/out/display-stress/chrome-gpu.txt`） |
| 播 1080p30 H.264 | `venus_irq_delta=418`，fd → `/dev/video14`，掉帧 7/260（**2.69%**） |
| VP9 | `irq=456`，fd `/dev/video14`，4/259（**1.54%**） |
| HEVC Main `hvc1` | `irq=431`，fd `/dev/video14`，12/262（**4.58%**）。`chrome://gpu` 加速表**没写** Decode hevc，但实机打开了 Venus |
| 对照软解 | 官方 Chrome 1080p30 掉帧 9.61% |
| 画面 | `linux-mainline/out/display-stress/chromium-gpu-or-video.png` |

官方 `google-chrome` 153 仍然没有 V4L2，**不要**再拿它测硬解。

## chrome://gpu 验收（2026-09-13 04:08）

结构化表：`linux-mainline/out/display-stress/chrome-gpu.json`、`linux-mainline/out/display-stress/chrome-gpu-accept.json`。全量文本：`linux-mainline/out/display-stress/chrome-gpu.txt`。  
截图：`linux-mainline/out/display-stress/chromium-gpu-or-video.png`（Mutter UBWC destile 会拧字，以 JSON 为准）。

| 特性 | chrome://gpu | 实机 |
|------|----------------|------|
| Canvas / Compositing / Rasterization / OpenGL / WebGL | Hardware | WebGL 2.0 GLES3 |
| WebGPU / interop | Hardware | `vendor=qualcomm` `adreno-6xx` `isFallbackAdapter=false`（没开 Vulkan） |
| Video Decode | Hardware | H.264 irq=530 / VP9 irq=597 / HEVC irq=891 / VP8 irq=581（NV12）以及 **HEVC Main10 irq=883 / VP9 profile2 irq=628**（**P010**），均 `/dev/video14` + `V4L2StatefulVideoDecoder`。10-bit：过滤 NV12/QC08C，并补 P010 单平面 stride，否则 QBUF EIO / GPU `exit_code=5` |
| Video Encode | Hardware | H.264 irq=203 + VP8 irq=208 + HEVC Main irq=229 + **HEVC Main10 irq=238** 均 `/dev/video15`。HEVC 需 `PLATFORM_HAS_OPTIONAL_HEVC_ENCODE_SUPPORT=1`、`InitControlsHEVC`，以及 MediaRecorder 允许 `hvc1.2.4`（上游只认 Main） |
| Vulkan / Direct Rendering Display Compositor | **Vulkan Enabled**（`DAGU_TEAR_CONTRACT=1`） | 花屏合同已撕：窗口 `QCOM_COMPRESSED`，WebGL = Turnip a650。DRDC 仍 Disabled：270° 下 Chrome 窗没拿到第二块 DPU plane |
| Skia Graphite / Raw Draw / TreesInViz / WebNN | Disabled | 不是 CPU 退路，是未接线的实验项 |

掉帧仍在（H.264 2.82%、VP9 4.05%、HEVC 0.63%、VP8 1.57%、**HEVC10 3.44%**、**VP9p2 2.21%**）：合成 `WaitForSwap`，不是软解。不要关 GPU raster。  
GNOME Shell **50.1** 已广告 `wp_linux_drm_syncobj_manager_v1:1`，Chrome 包装已 ENABLE `WaylandLinuxDrmSyncobj`。`official-152` 的 bind 门槛是内核 **≥6.11**，平板 `uname=7.0.0-dirty`。  
**2026-09-13 撕花屏合同**：official-152 的 `gbm_bo_get_modifier()` 已回报真实 `QCOM_COMPRESSED`（`0x0500000000000001`）。`libdagu-linear-mod.so` 不再默认装进 Chrome。Mutter 已去掉 `disable-direct-scanout`（主 fb 仍 UBWC）。`DAGU_TEAR_CONTRACT=1` / `linux-mainline/scripts/dagu-chromium-native.sh`：`--use-angle=vulkan`，`chrome://gpu` **Vulkan = Enabled**，WebGL `ANGLE (Qualcomm, Vulkan 1.3.335 (Turnip Adreno 650))`，1080p30 H.264 仍 `/dev/video14` irq=443。Ozone 仍打 “Wayland not compatible with Vulkan” 日志，但 `CreateVulkanImplementation` 照样返回 `VulkanImplementationWayland`。270° 下最大化窗还没有第二块 DPU plane（仍 GPU 合成）。探针：`linux-mainline/scripts/dagu-ubwc-reclaim-probe.sh`。

逐项实机（`linux-mainline/scripts/dagu-chrome-gpu-dump.py`，2026-09-13 04:12）：

| 项 | 证据 |
|----|------|
| Canvas 2D | `getImageData` 绿块 `ok` |
| WebGL 2 | `ANGLE (angleisbroken, FD650, OpenGL ES 3.2)`，`software=false` |
| WebGPU | `requestAdapter` + `requestDevice`：`qualcomm` / `adreno-6xx` / `isFallbackAdapter=false` |
| 解码器 | 日志 `V4L2StatefulVideoDecoder` CAPTURE **NV12 1920x1088**（不是 FFmpeg） |

`DAGU_CHROME_GRAPHITE=1`（`--enable-skia-graphite --skia-graphite-dawn-backend=opengles`）实机：**Graphite 仍 Disabled**，且 **Venus 编解码表被清空、WebGPU `requestAdapter` 变 null**。已恢复默认 Ganesh GLES。不要为「全绿」默认开 Graphite。  
WebNN：Linux 没有 Venus/Turnip 后端，打开会走 CPU/TFLite，禁止。

## Video Encode 为什么假绿

上游 `media/gpu/gpu_video_encode_accelerator_factory.cc` 的 `CreateV4L2VEA()`：`IS_CHROMEOS` 才 `new V4L2VideoEncodeAccelerator`，Linux 直接 `nullptr`。`media/gpu/v4l2/BUILD.gn` 也只在 `is_chromeos` 编进编码器。平板 `/usr/lib/chromium/chromium` **没有** `V4L2VideoEncodeAccelerator` 字符串。`--enable-features=AcceleratedVideoEncoder` 只清掉 “disabled via flags”，`chrome://gpu` 会标 Hardware，但 **VEA 配置表空、不会打开 Venus `/dev/video15`**。

硬件编码本身已通：平板 `ffmpeg -c:v h264_v4l2m2m` 使用 `/dev/video-enc0`（`qcom-venus`），产出 `/tmp/venus-enc-smoke.mp4`。缺的是 Chromium 编进 VEA。

Debian 152 源码已下载到 `linux-mainline/out/chromium-v4l2-src/`（`chromium_152.0.7977.82.orig.tar.xz`）。补丁已在解出的 `CreateV4L2VEA` / `BUILD.gn` / `debian/rules` 上对过：

- `linux-mainline/scripts/dagu-chromium-v4l2-encode-build.sh`
- `linux-mainline/patches/chromium-152-v4l2-encode-linux.patch`

交叉编已开（2026-09-12 23:32，勿杀）：

- 树：`linux-mainline/out/chromium-v4l2-src/official-152`（官方 lite 152.0.7977.82）
- GN：`linux-mainline/out/chromium-v4l2-src/official-152/out/dagu/args.gn`（`use_v4l2_codec=true`、`use_vaapi=false`、HEVC parser、`use_av1_hw_decoder=false`：SM8250 Venus 无 AV1，bullseye sysroot 也没有 AV1 V4L2 uapi）
- 补丁已打：`CreateV4L2VEA()` 在 Linux 也 `new V4L2VideoEncodeAccelerator`；`media/gpu/v4l2/BUILD.gn` 无条件编进 encode `.cc`。VEA 默认 `V4L2_MEMORY_USERPTR`（`kShmem` / MediaRecorder canvas），与平板 `ffmpeg h264_v4l2m2m` 同一路；`kGpuMemoryBuffer` 才会走 DMABUF（crbug 901264）
- `chrome://gpu` 不列 Decode hevc 的原因：`kV4L2CodecPixFmtToProfileCID` 只登记了无状态 `V4L2_PIX_FMT_HEVC_SLICE`。Venus 报的是 stateful `V4L2_PIX_FMT_HEVC`。已在 `official-152/media/gpu/v4l2/v4l2_utils.cc` 补上（编 `media/gpu` 之前）
- ninja：`ninja -C out/dagu -j8 chrome chrome_sandbox`（约 93818 步）
- 换上：`linux-mainline/scripts/dagu-chromium-v4l2-encode-deploy.sh`（先确认二进制有 `V4L2VideoEncodeAccelerator`；经平板 `/tmp` 替换 `/usr/lib/chromium/chromium`）
- 编完自动换+测：`linux-mainline/scripts/dagu-chromium-v4l2-encode-wait.sh`（盯 `linux-mainline/out/chromium-v4l2-src/ninja-chrome.log`）
- 编码探针：`linux-mainline/scripts/dagu-chrome-encode-probe.py --host --codec h264|vp8|hevc|hevc10`（必须 `/dev/video15` + `venus_irq`，假绿不算）。画布 **1280×720**。H.264 irq=203、VP8 irq=208、HEVC Main irq=229、**HEVC Main10 irq=238** 已通（`linux-mainline/out/display-stress/chrome-encode-probe-hevc10.json`）。换板只拷 chrome/sandbox/pak，禁止 scp locales。
- 硬件编码器已在：`/dev/video15` → H264 / VP80 / HEVC，128²–8192²（`v4l2-ctl --list-formats-ext`）

平板根分区约 968MB 空，不要在板上编。不要拿 MediaRecorder 软编交差。

## 探针 / 包装

- 日常硬解：`/usr/local/bin/dagu-chromium`（`linux-mainline/scripts/dagu-chromium.sh`）
- dump：`linux-mainline/scripts/dagu-chrome-gpu-dump.py --host`
- 播片：`linux-mainline/scripts/dagu-video-jank.py --host --fresh --codec h264|hevc|vp9|vp8|hevc10|vp9p2`
- 时钟：`linux-mainline/scripts/dagu-touch-boost.py` 认 Chromium + `/dev/video14` fd（不要钉大核）
