# dagu Venus 硬件编解码（`dagu-venus-ignition`）

记录日期：**2026-09-12**。  
设备：小米平板 5 Pro 12.4（`dagu` / SM8250，`androidboot.serialno=<linux-serial>`）。  
相关总表：`linux-mainline/docs/dagu-adaptation-status.md`。

---

## 1. 一句话

ICC 没有 SM8250 provider，Venus 也不再因此 `-EPROBE_DEFER`。  
`CONFIG_VIDEO_QCOM_VENUS=m`，DT `&venus` 为 `okay`，固件走本机签名的 `venus.mdt`。  
手动 `insmod` 后出现：

- `/dev/video14` `qcom-venus-decoder`
- `/dev/video15` `qcom-venus-encoder`

HFI / TZ PAS 过了。**1080p H.264 headless 已出 NV12**（`dagu-venus-dec-baseline`）。  
**Venus NV12 `dma-buf` 已上 Mutter**（`dagu-venus-dmabuf-scanout` / `dagu-venus-4k-ecosystem`）：1080p H.264 与 **4K60 HEVC** 都协商到 `DMA_DRM`/`NV12`；`gst-play-1.0 --videosink=waylandsink` 是日常零拷贝播放器。无 ICC 投票，无 SMMU fault。  
**禁止**开 `CONFIG_INTERCONNECT_QCOM_SM8250`。不要套 VA-API。不要为了 mpv 去开 v4l2 request（那是无状态 API，Venus 是 stateful m2m）。

---

## 2. 源码核对（动手前）

`linux-mainline/linux/drivers/media/platform/qcom/venus/pm_helpers.c` 的 `load_scale_bw()` **只**对已经拿到的 `core->video_path` 调 `icc_set_bw()`，没有第二次 `devm_of_icc_get`。

真正卡探针的是 `linux-mainline/linux/drivers/media/platform/qcom/venus/core.c`：

```c
core->video_path = devm_of_icc_get(dev, "video-mem");
core->cpucfg_path = devm_of_icc_get(dev, "cpu-cfg");
```

没有 SM8250 provider 时这里会 `-EPROBE_DEFER`。  
`linux-mainline/linux/drivers/interconnect/core.c` 里 `icc_set_bw(NULL, …)` 直接 `return 0`。  
DT 删掉 `interconnects` 之后，`of_icc_get()` 返回 **NULL**（不是 ERR），stub 分支不会打 warn，后续投票仍是空操作。

SM8250 无 `video-firmware` 子节点 → `use_tz = true` → `qcom_mdt_load` + `qcom_scm_pas_auth_and_reset(VENUS_PAS_ID=9)`。  
`video_mem` 在 `linux-mainline/dts/dagu-reserved-memory-stock.dtsi` 的 `0x86e00000` / 5 MB；本机 MDT+`.b*` 合计约 943 KB。

---

## 3. 本轮改动

| 文件 | 作用 |
|------|------|
| `linux-mainline/scripts/apply-overlays.sh` | 给 `core.c` 打 ICC stub；CAMSS `Kconfig` `select` 无 prompt 的 mem2mem / vb2-contig / h264 / vp9，否则 Venus=`m` 链不上 |
| `linux-mainline/patches/kernel-sm8250-venus-icc-stub.patch` | 同一份 stub 的独立补丁 |
| `linux-mainline/config/dagu-display.fragment` | `CONFIG_VIDEO_QCOM_VENUS=m`，`CONFIG_SM_VIDEOCC_8250=y`（bringup 会关掉 VIDEOCC） |
| `linux-mainline/dts/sm8250-xiaomi-dagu.dts` | `&venus` `okay`，`firmware-name = qcom/sm8250/xiaomi/dagu/venus.mdt`，`/delete-property/` interconnects |
| `linux-mainline/scripts/build-kernel.sh` | 验收 `VENUS=m` / `VIDEOCC=y` / stub 标记 / **禁止** SM8250 ICC；编 `venus-*.ko` |

`pm_helpers.c` 不用改。

活核 `#169 SMP PREEMPT Sat Sep 12 15:51:41 CST 2026`。  
`g_serial` `0525:a4a7` 重启后稳住（uptime >60s，无兔子 `18d1:d00d`）。  
`head.S` `primary_entry` 仍是 `bl record_mmu_state`。

---

## 4. 刷写注意（这台板）

USB 上可能同时出现另一台 `adb` 序列号 `<android-serial>`（`18d1:4ee7`）。  
对它 `adb reboot bootloader` + `fb-usb.py` 会刷错机器；本机 `androidboot.serialno=<linux-serial>`。

本轮是在 **已 SSH 上的本机** 上对 B 槽 `dd`（镜像尺寸与分区一致）：

```text
/dev/disk/by-partlabel/vbmeta_b       <- linux-mainline/out/vbmeta-disabled.img   (128 KiB)
/dev/disk/by-partlabel/dtbo_b         <- linux-mainline/out/dtbo-stub.img         (8.2 KiB stub)
/dev/disk/by-partlabel/vendor_boot_b  <- linux-mainline/out/vendor_boot-dagu.img  (96 MiB)
/dev/disk/by-partlabel/boot_b         <- linux-mainline/out/boot-dagu.img         (192 MiB)
```

只写 B。A 槽未动。救砖：`linux-mainline/scripts/flash-boot-legacy.sh restore-a`。  
进 ABL 后用 `linux-mainline/scripts/fb-usb.py` 刷也可以，但必须确认 fastboot 序列号就是这台板。

模块已放在 userdata（重启后仍在）：

- `/lib/modules/7.0.0-dirty/extra/venus-{core,dec,enc}.ko`
- `/root/venus-ko/`（副本）
- 主机 `linux-mainline/out/modules/venus/`

**不要**写 `modules-load.d`：TZ/PAS 若炸，模块失败即可，不要绑进 Image 启动路径。

```bash
insmod /lib/modules/7.0.0-dirty/extra/venus-core.ko
insmod /lib/modules/7.0.0-dirty/extra/venus-dec.ko
insmod /lib/modules/7.0.0-dirty/extra/venus-enc.ko
```

---

## 5. 烟测（2026-09-12，#169）

| 项 | 结果 |
|----|------|
| DT `video-codec@aa00000` | `status=okay`，`firmware-name=…/venus.mdt`，无 `interconnects` |
| `CONFIG_VIDEO_QCOM_VENUS` | `=m` |
| `CONFIG_SM_VIDEOCC_8250` | `=y`（`sm8250-videocc` 在） |
| `CONFIG_INTERCONNECT_QCOM_SM8250` | **is not set** |
| 加载前 `dmesg` | `platform aa00000.video-codec: Adding to iommu group 5` |
| 加载后 | `qcom-venus aa00000.video-codec: non legacy binding` |
| ICC stub warn | 无（属性已删，`of_icc_get` 返回 NULL） |
| tz/scm 报错 | 无（`qcom_scm` 仍是 `convention: smc arm 64`） |
| `/dev/video14` | `qcom-venus-decoder`，驱动 `qcom-venus` |
| `/dev/video15` | `qcom-venus-encoder`，驱动 `qcom-venus` |

解码器 OUTPUT（码流）：`H264` `VP80` `VP90` `HEVC` `MPG2`。  
解码器 CAPTURE：`NV12`、`Q08C`（QCOM Compressed），128–8192。  
编码器：进 `NV12`，出 `H264` / `VP80` / `HEVC`。

固件仍在：

- 平板 `/lib/firmware/qcom/sm8250/xiaomi/dagu/venus.mdt` + `venus.b00`…  
- 主机 `linux-mainline/firmware/dagu/lib/firmware/qcom/sm8250/xiaomi/dagu/`  
- 备份 `linux-mainline/out/gpu-checkpoint-20260912/venus/dagu-venus-full.tar.gz`

**禁止**用 `vendor/xiaomi-elish-firmware/sm8250/venus.mbn`。

---

## 6. 解码基线（`dagu-venus-dec-baseline`，2026-09-12）

无 Wayland / Mutter。GStreamer 1.28 `v4l2h264dec`（`gstreamer1.0-plugins-good` 已有；`h264parse` 来自本轮装的 `gstreamer1.0-plugins-bad`）。  
`v4l2h264dec` 的 `device` 属性不可写，由插件自己绑到 `/dev/video14`。

素材（平板 `/tmp/`）：

| 文件 | 规格 |
|------|------|
| `/tmp/test-1080p.mp4` | 10s 1920×1080@30，x264 **Constrained Baseline**（`-preset ultrafast` 会把 high 压成 CB） |
| `/tmp/test-1080p-high.mp4` | 3s 1920×1080@30，x264 **High** |

管线：

```bash
gst-launch-1.0 -e \
  filesrc location=/tmp/test-1080p.mp4 \
  ! qtdemux ! h264parse ! v4l2h264dec \
  ! fpsdisplaysink video-sink=fakesink text-overlay=false sync=false
```

| 项 | 结果 |
|----|------|
| 10s CB `fakesink sync=false` | EOS，`rc=0`，墙钟 **1.68s**（约 180 fps 吞吐） |
| 3s High | EOS，`rc=0`，墙钟 **0.55s** |
| `checksumsink` | 每帧 SHA1 不同，时间戳走到 `0:00:09.966` |
| NV12 dump | 940032000 字节 = **300 × 1920×1088×1.5**（1080 按 16 对齐到 1088） |
| `venus` IRQ（GICv3 206） | 618 → 1229（checksum 一轮）→ 2016（High 后再加） |
| 8 核窗口 CPU | 约 **16% busy**（含 demux/parse；不是软解满核） |
| `qcom-venus: SSR` | 无 |
| `arm-smmu: Unhandled context fault` | 无 |
| 新 dmesg Venus 行 | 无（只有开机那条 `non legacy binding`） |

ICC stub + 无带宽投票：这一路 IOMMU group 5 能把 1080p 帧吐完。

## 7. DMA-BUF 上桌（`dagu-venus-dmabuf-scanout`，2026-09-12）

不走 VA-API。V4L2 m2m 导出 `dma-buf`，经 `zwp_linux_dmabuf_v1` 交给 Mutter，a650 / Turnip 当 GLES 纹理采样，叠在 UBWC 主缓冲上。

平板会话：`dagu` uid=1001，`XDG_RUNTIME_DIR=/run/user/1001`，`WAYLAND_DISPLAY=wayland-0`。必须用桌面用户，不要 root 连 compositor。

### 7.1 GStreamer 零拷贝（探路，已通）

```bash
sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 HOME=/home/dagu \
  gst-launch-1.0 -e \
    filesrc location=/tmp/test-1080p.mp4 \
    ! qtdemux ! h264parse \
    ! v4l2h264dec capture-io-mode=dmabuf \
    ! waylandsink sync=true fullscreen=false
```

脚本：`linux-mainline/scripts/dagu-venus-waylandsink.sh`（平板副本 `/tmp/dagu-venus-waylandsink.sh`）。

`GST_DEBUG=waylandsink:4` 关键一行：

```text
set caps video/x-raw(memory:DMABuf), format=(string)DMA_DRM, width=(int)1920,
height=(int)1080, drm-format=(string)NV12
```

完整日志：`linux-mainline/out/display-stress/venus-wayland-caps.log`。

| 项 | 结果 |
|----|------|
| 协商 | `memory:DMABuf` + `DMA_DRM` / `NV12`；广告高度 **1080**（合成裁掉 1088 对齐尾） |
| `videoconvert` / shm fallback | 无 |
| `sync=true` 10s CB | EOS，`rc=0`，墙钟约 10.8s |
| 该窗口 8 核 CPU | 约 **5.9% busy**（低于 headless `fakesink` 冲刺的 16%） |
| 主 fb modifier | 仍是 `0x0500000000000001`（`QCOM_COMPRESSED`） |
| Mutter 广告 NV12 | `NV12(LINEAR)` 与 `NV12(0x0500000000000001)` 都在 |
| SSR / SMMU fault / hangcheck | 无 |
| 画面 | `linux-mainline/out/display-stress/venus-dmabuf-waylandsink.png`：彩条完整，**无底部绿带**，顶栏/Dock/壁纸正常 |

`sync=false` 会在 ~0.7s 内 EOS（跟 180 fps 吞吐一致），截图必须 `sync=true` 且窗口还在。

### 7.2 mpv 实用化（Venus 已用，零拷贝未谈成）

Ubuntu `mpv` **0.41.0** / FFmpeg **8.0.1** 的 `--hwdec=help` **只有** `v4l2m2m-copy`，没有 `v4l2m2m`，也没有可绑定的 `drm` hwdec。任务书里的 `--hwdec=v4l2m2m` 会打 `Unsupported hwdec: v4l2m2m` 并掉进软解。

已通：

```bash
sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 HOME=/home/dagu \
  mpv --hwdec=v4l2m2m-copy --vo=gpu --gpu-context=wayland /tmp/test-1080p-15s.mp4
```

脚本：`linux-mainline/scripts/dagu-venus-mpv.sh`。日志：`linux-mainline/out/display-stress/mpv-venus.log`。

| 项 | 结果 |
|----|------|
| 解码 | `Using hardware decoding (v4l2m2m-copy)`；OSD `hwdec=v4l2m2m-copy` |
| 设备 | FFmpeg `h264_v4l2m2m` → `/dev/video14` `qcom-venus`，`capture=NV12` |
| VO | `[gpu] 1920x1080 nv12`，`gpu-context=wayland`，`GL_RENDERER=FD650` |
| 8 核 CPU | 约 **10.4% busy**（进程 `%cpu` ~58，单核拷贝+上传） |
| 主 fb | 仍是 `QCOM_COMPRESSED` |
| 画面 | `linux-mainline/out/display-stress/venus-mpv-v4l2m2m-copy.png`：彩条 + 桌面共存，无绿带、无花屏 |

试过但失败（预期内，不是 Venus 挂）：

| 命令 | 结果 |
|------|------|
| `--hwdec=v4l2m2m --vo=gpu` | `Unsupported hwdec`，软解 |
| `--hwdec=drm --vo=gpu` | 同上 |
| `--vd=h264_v4l2m2m --vo=dmabuf-wayland` | Venus 解开了，但帧是 CPU `nv12`；`hwupload` 到 `drm_prime` 失败 |

零拷贝跨进程这条，以 GStreamer `waylandsink` 为准。库存 mpv 会先把 Venus NV12 memcpy 再当普通纹理喂 GPU。

### 7.3 还没做（已由 §9 接走）

4K HEVC、Overview、日常播放器见 **§9 `dagu-venus-4k-ecosystem`**。  
VP9 / 高码率电影级 4K、`ffmpeg -c:v h264_v4l2m2m` 对照仍未跑。  
Mesa 没有 Freedreno VA-API。CDSP / SLPI 走 PAS + FastRPC / SEE，不是 Venus 的依赖。

---

## 8. 和 Turnip 的边界

| 组件 | 做什么 |
|------|--------|
| Turnip / dagu-mesa | 3D / Chrome LINEAR GMEM，已通 |
| Venus / `qcom-venus` | H.264 / HEVC 编解码；**1080p + 4K60 NV12 dmabuf 已上 Mutter** |

---

## 9. 4K 压测与日常零拷贝（`dagu-venus-4k-ecosystem`，2026-09-12）

无 `CONFIG_INTERCONNECT_QCOM_SM8250`。码流侧很轻（testsrc + x265 CRF28），压的是 **4K60 NV12 原始吞吐**（约 3840×2160×1.5×60 ≈ 746 MiB/s）和 Mutter 合成。

### 9.1 素材

主机没有 `ffmpeg`。平板 `libx265` 用 **ultrafast**（默认 medium 在 Kryo 上要数小时）：

```bash
# linux-mainline/scripts/dagu-venus-make-4k.sh
ffmpeg -y -f lavfi -i testsrc=duration=10:size=3840x2160:rate=60 \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 /tmp/test-4k.mp4
```

| 项 | 值 |
|----|-----|
| 规格 | HEVC **Main** 8-bit 4:2:0，3840×2160@60，10s，600 帧 |
| 编码 | 平板 47.8s，12.6 fps，281 kb/s |
| 副本 | 平板 `/tmp/test-4k.mp4`；主机 `linux-mainline/out/display-stress/test-4k.mp4` |

### 9.2 4K HEVC 零拷贝

```bash
sudo -u dagu env XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 HOME=/home/dagu \
  gst-launch-1.0 -e \
    filesrc location=/tmp/test-4k.mp4 \
    ! qtdemux ! h265parse \
    ! v4l2h265dec capture-io-mode=dmabuf \
    ! waylandsink sync=true fullscreen=false
```

`GST_DEBUG=waylandsink:4`：

```text
set caps video/x-raw(memory:DMABuf), format=DMA_DRM, width=3840, height=2160,
framerate=60/1, drm-format=NV12
```

日志：`linux-mainline/out/display-stress/venus-4k-wayland.log`。

| 项 | 结果 |
|----|------|
| headless `fakesink sync=false` | EOS，墙钟 **10.56s**（≈57 fps 吞吐，接近 4K60） |
| `waylandsink sync=true` | EOS，墙钟 **10.000s**（贴着 10s 片长，按时钟满帧走完） |
| 播放中 8 核 CPU | 约 **8.1% busy** |
| `venus` IRQ（GICv3 206） | fakesink 一轮约 10265 → 12055 |
| 主 fb | 仍是 `0x0500000000000001`（`QCOM_COMPRESSED`） |
| SSR / SMMU `Unhandled context fault` / hangcheck | **无** |
| 画面 | `linux-mainline/out/display-stress/venus-4k-waylandsink.png`：彩条完整，无绿带、无花屏 |

ICC stub + 无带宽投票：4K60 NV12 跨 Venus → a650 这一路没有把 IOMMU group 5 打穿。  
高码率电影级 4K（几十 Mbps、10-bit、B 帧更密）还没烤。

### 9.3 Mutter 交互

GNOME 50.1 的 `org.gnome.Shell.Eval` / `FocusSearch` / `ShowApplications` 被拒；**`OverviewActive` 可写**。

```bash
gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
  --method org.freedesktop.DBus.Properties.Set \
  org.gnome.Shell OverviewActive "<true>"
```

| 场景 | 证据 | 结果 |
|------|------|------|
| 1080p dmabuf + Overview | `linux-mainline/out/display-stress/venus-overview-1080p.png` | 搜索栏 + 圆角缩略图，彩条仍在更新，桌面无花屏 |
| 4K60 dmabuf + Overview | `linux-mainline/out/display-stress/venus-overview-4k.png` | 同上 |
| Overview 连切 3 次 | dmesg | 无 hangcheck |
| Himax 注入滑动 | `evemu-event` `/dev/input/event3`（0–1599 × 0–2559） | 播放未死；waylandsink **没有标题栏**，窗口没被拖走。无 `/dev/uinput`（`CONFIG_INPUT_UINPUT is not set`），不能 Super+拖 |

### 9.4 日常零拷贝播放器（路径 A，已定）

库存 mpv 0.41 只有 `v4l2m2m-copy`（§7.2）。**不**为此交叉编译 FFmpeg。  
**不要**走 v4l2 request API（无状态，Venus 不是这条）。**不要**走 libcamera（相机栈）。

| 播放器 | 命令 | 零拷贝证据 |
|--------|------|------------|
| **`gst-play-1.0`（日常）** | `--videosink=waylandsink` | 1080p 与 4K 均为 `memory:DMABuf` / `DMA_DRM` / `NV12`。日志：`linux-mainline/out/display-stress/gst-play-1080p.log`、`…/gst-play-4k.log` |
| **Totem 43.2** | `totem /tmp/test-1080p-15s.mp4` | `v4l2h264dec` + `/dev/video14` + 进程里多个 `/dmabuf:` fd。画面：`linux-mainline/out/display-stress/venus-totem-1080p.png`。走 GTK 窗口而不是 `waylandsink`，caps 行不如 gst-play 干净 |
| mpv | `--hwdec=v4l2m2m-copy` | Venus 在干活，有拷贝 |

脚本：

- `linux-mainline/scripts/dagu-venus-waylandsink.sh` — 按文件名选 h264/h265
- `linux-mainline/scripts/dagu-venus-gst-play.sh` — 日常 gst-play
- `linux-mainline/scripts/dagu-venus-make-4k.sh` — 生成 4K HEVC
- `linux-mainline/scripts/dagu-venus-mpv.sh` — 仍是 copy 路径

`gsettings org.gnome.totem force-software-decoders` 为 **false**。

### 9.4.1 HTML5：官方 Chrome 软解；一线走 Chromium + Venus

官方 Chrome 153.0.8010.36 `USE_V4L2=0`，只能 FFmpeg。**不要**套 VA-API。一线是 xtradeb Chromium 152 + `linux-mainline/scripts/dagu-chromium.sh`。

| 项 | 官方 Chrome 153 | Chromium 152（`dagu-chromium`） |
|----|-----------------|--------------------------------|
| `/dev/video14` | 不打开 | H.264 / VP9 / HEVC 都打开 |
| `venus_irq_delta` | 0 | 418 / 456 / 431（各 8s 1080p30） |
| 掉帧 | 9.61% 基线 | 2.69% / 1.54% / 4.58% |
| JSON | `linux-mainline/out/display-stress/video-jank-baseline.json` | `video-jank-h264.json` / `video-jank-vp9.json` / `video-jank-hevc.json` |

Video Encode：`chrome://gpu` 在开了 `AcceleratedVideoEncoder` 后标 Hardware，但是上游 `CreateV4L2VEA()` 只在 ChromeOS 返回真编码器。干净 `MediaRecorder`：`irq_delta=0`、没有 `/dev/video15`。见 `linux-mainline/docs/dagu-chrome-gpu-venus.md`。

时钟：`linux-mainline/scripts/dagu-touch-boost.py` 认 Chromium / `/dev/video14`。不要 `governor=performance`，不要钉大核。

### 9.5 附带：GStreamer registry 坏目录

`dmesg` 里 `EXT4-fs error … deleted inode referenced: 149213`，对应 `/home/dagu/.cache/gstreamer-1.0/registry.aarch64.bin`（`ls` 全问号，`rm` 报 `Structure needs cleaning`）。已挪到 `/home/dagu/.cache/gstreamer-1.0.bad-1789203410`，新 cache 目录已建。这是 userdata 上的陈旧 dentry，不是 Venus/SMMU。未做在线 `fsck`。
