# dagu 视频编解码修复记录（2026-10）

记录日期：**2026-10-25**。内核 `#649`（slot B），Chromium official-152 V4L2 自编版本。  
目标：所有硬件编解码在 GStreamer 和 Chromium 里都通过测试，画面正常。  
相关文档：`dagu-venus.md`（Venus 点亮）、`dagu-chrome-gpu-venus.md`（Chromium V4L2 构建）、`dagu-adaptation-status.md`（总表）。

---

## 1. 结论

| 测试 | 结果 |
|---|---|
| `dagu-codec-test`（GStreamer，对比 ffmpeg 软解） | 12/12 通过 |
| `dagu-chromium-codec-test`（Chromium 播放 6 项 + WebCodecs 硬件编码 5 项） | 11/11 通过，连跑 3 轮 |
| 编码器空闲 30 s 后关闭，再连续编码（之前必崩） | 两轮 4 次全部正常，0 次 SMMU fault |
| 暂停后跳转压测（7 种格式 × 20 次） | 140 次 0 卡住 |

Chromium 播放（稳态 = 开始播放 1 s 之后的 4.5 s）：

| 片源 | 解码器 | 稳态帧率 | 丢帧 / 270 | 启动（首帧 / 丢帧） | PSNR |
|---|---|---|---|---|---|
| H.264 High L5.2 4K60 | V4L2VideoDecoder | 60.0 | 0 | 250–340 ms / 1–2 | 46.8 dB |
| HEVC Main 4K60 | V4L2VideoDecoder | 60.0 | 0–2 | 200–260 ms / 1–2 | 46.8 dB |
| HEVC Main10 4K60 | V4L2VideoDecoder | 59.7–60.0 | 0–2 | 460–600 ms / 2–3 | 39.1 dB |
| VP9 4K60 | V4L2VideoDecoder | 60.0 | 0–3 | 150–190 ms / 2–4 | 46.8 dB |
| H.264 High 1080p30 | V4L2VideoDecoder | 30.0 | 0 | 70–135 ms / 0–1 | 46.8 dB |
| VP8 1080p30 | V4L2VideoDecoder | 29.7–30.0 | 0–1 | 90–110 ms / 0–1 | 46.5 dB |

Main10 的 39 dB 来自 10-bit → 8-bit 画布读回，不是解码误差（GStreamer 对比 10-bit 原始数据是 55 dB）。

Chromium WebCodecs 硬件编码（60 帧，解码回来和源帧比）：

| 编码 | 编码速度 | PSNR |
|---|---|---|
| H.264 1080p `avc1.640028` | 80–97 fps | 37.3 dB |
| H.264 4K `avc1.640034` | 31–32 fps | 37.5 dB |
| HEVC 1080p `hvc1.1.6.L120.B0` | 98–107 fps | 38.9 dB |
| HEVC 4K `hvc1.1.6.L153.B0` | 32–34 fps | 38.3 dB |
| VP8 1080p | 76–84 fps | 35.3 dB |

用同一张图、同一码率对比：硬件编码 33.1 dB，Chromium 软件编码 33.6 dB，基本相当（这组数字来自另一个探针，和上表不可直接比）。编码速度包含网页里画画布和 `VideoFrame` 拷贝。

GStreamer（`dagu-codec-test`，对比 ffmpeg 输出的原始 I420）：

| 项目 | 结果 |
|---|---|
| 解码 H.264 L5.2 4K60 / H.264 1080p / HEVC 4K60 / VP9 4K60 / VP8 1080p | 逐位一致，134 / 480 / 286 / 219 / 633 fps |
| 解码 HEVC Main10 4K60 | 55 dB，214 fps |
| 解码 MPEG-2 1080p（软件） | 逐位一致，318 fps |
| 编码 H.264 4K L5.2 / H.264 1080p / HEVC 4K / HEVC 1080p / VP8 1080p | 48.3 / 43.5 / 41.2 / 43.5 / 51.7 dB |

GStreamer 编码速度含读原始文件的时间，稳态 4K 编码在 100 fps 以上。

**不支持的格式**：AV1 没有硬件（SoC 限制），走 dav1d 软解（4K60 测试片约 46 fps，1080p60 约 121 fps）。MPEG-2 硬件输出错误，已隐藏，走软解（见 §3.2）。

---

## 2. 测试工具

### 2.1 `dagu-codec-test`（GStreamer）

- 源码：`linux-mainline/scripts/dagu-codec-test.sh`，平板上是 `/usr/local/sbin/dagu-codec-test`，工作目录 `/var/tmp/dagu-codec`。
- 运行：`systemctl stop dagu-camera-loopback-watch; dagu-codec-test; systemctl start dagu-camera-loopback-watch`（摄像头回环会占 Venus）。
- 参考数据是 ffmpeg 软解出的原始 I420，和 Venus 输出的原始 I420 比 PSNR。不要拿封装文件当参考，帧会对不上。
- 编码测试直接送 NV12。前面加 `videoconvert` 会套一次 BT.601→BT.709 矩阵，所有编码器都只剩 24 dB。
- 不要用 `fakesink`，它会拷帧（`gst_video_frame_copy`）。用 `fakevideosink` 或 `waylandsink`。

### 2.2 `dagu-chromium-codec-test`（Chromium）

- 源码：`linux-mainline/scripts/dagu-chromium-codec-test/`（`run.py`、`index.html`、`serve.py`），平板上是 `/usr/local/share/dagu-chromium-codec-test/`。
- 运行（root）：`cd /usr/local/share/dagu-chromium-codec-test && python3 run.py`，约 3 分钟。
- 流程：
  1. 用 ffmpeg 生成 6 s 测试片和第 60/30 帧的参考 PNG，放在 `/var/tmp/dagu-chrome-test`。
  2. 以 dagu 用户起 `serve.py`（支持 HTTP Range）和 `/usr/local/bin/dagu-chromium --remote-debugging-port=9222`。
  3. 通过 DevTools 的 Media 域确认用的是 `V4L2VideoDecoder`（`kIsPlatformVideoDecoder=true`）。
  4. 每段片源：等到 `HAVE_ENOUGH_DATA` 再播放，记录首帧时间；第 1 s 起计 4.5 s 稳态帧数和丢帧；再播 2.5 s 时截屏（截屏会卡合成器，所以放在计时区间外）；最后暂停、跳到 1.008 s，和参考 PNG 比 PSNR。
  5. WebCodecs `prefer-hardware` 编码 60 帧，再解码回来比第 0 帧。
- 通过标准：硬件解码器；PSNR ≥ 30 dB；稳态丢帧 ≤ 1%（270 帧允许 3 帧）；稳态帧率 ≥ 片源的 95%；首帧 ≤ 1 s。
- 页面顶部有一行大字显示当前测试项。测试窗口背景是黑色，编码项不显示视频，看起来像黑屏是正常的。
- 截图在 `/var/tmp/dagu-chrome-test/*.screen.png`。

---

## 3. 问题与修复

### 3.1 H.264 Level 5.2 被拒绝

- **现象**：H.264 L5.2 4K60 片源在 GStreamer 里无法解码。
- **根因**：venus 驱动 H.264 level 菜单最大只到 5.1，`HFI_H264_LEVEL_52` 也没有映射到 V4L2。
- **修复**：vdec/venc 的菜单上限改为 5.2，补上映射。overlay 标记 `dagu: H.264 level 5.2`。
- **提交**：`bbce3f9`。

### 3.2 MPEG-2 硬件解码画面错位

- **现象**：MPEG-2 1080p 解码后，在 x=192–320、512–640……每 320 px 一组的 128 px 宽列带里，隔行的像素来自右边 128 px 处。对比 ffmpeg 只有 8.8 dB。
- **排除**：
  - 旧的 compose 裁到 1792 只能遮住一条列带，还丢了真实像素。
  - 强制线性 DPB-only（`ubwc=false`）时固件给出 `opb=3 fmt=0x2 dpb=0x0`，GStreamer 读不出数据。
  - 反复 rmmod/insmod venus 会 oops（`of_node_release` 引用计数、`kernfs_find_and_get_ns` 空指针）并卡死平板。**不要 rmmod venus。**
- **修复**：在 Iris2 上不再上报 MPEG-2 解码格式（`vdec_codec_ok()`，overlay 标记 `dagu: no MPEG-2 decoder on Iris2`）。GStreamer 和 Chromium 自动改用软件解码，结果逐位一致，1080p30 约占一个核的 25%。
- **遗留**：vdec.c 里旧的 MPEG-2 裁剪、stride、work_route 补丁现在走不到了，还没删。
- **提交**：`22a1873`。

### 3.3 Chromium WebCodecs 硬件编码全部"不支持"

- **现象**：`VideoEncoder.isConfigSupported({... hardwareAcceleration: 'prefer-hardware'})` 对 H.264、HEVC、VP8 全部返回 `false`。strace 显示 GPU 进程确实打开了 `/dev/video-enc0` 并枚举出 H.264 / VP8 / HEVC。
- **根因**：`V4L2Device::GetSupportedRateControlMode()` 只有在 `kChromeOSHWVBREncoding` 开启时才上报 VBR，而这个开关在 ARM 上默认关闭。WebCodecs 和 MediaRecorder 默认请求 VBR，`IsAcceleratedConfigurationSupported()` 找不到支持 VBR 的配置，就全部拒绝。不带码率的配置能返回 `true`，可以印证这一点。
- **修复**：`dagu-chromium-native.sh` 和 `rootfs-desktop-setup.sh` 的 `--enable-features` 里加上 `ChromeOSHWVBREncoding`。Venus 本身支持 VBR。
- **提交**：`8df8b99`。

### 3.4 Chromium 硬件编码画面错位、固件崩溃、整机卡死

- **现象**：
  - 开启 VBR 后编码能出数据，但 PSNR 只有 18–22 dB，解码出来色度整体错位，顶部多一条绿边。
  - 第五次编码时 SMMU 报 `Unhandled context fault ... SID=0x2100`，固件报 `SFR ... Exception`，恢复失败（`recovery failed to init HFI`），随后整机卡死。
- **根因**：我们给 Linux 开的 V4L2 编码补丁（`chromium-152-v4l2-encode-linux.patch`）把网页的帧内存直接以 USERPTR 交给 Venus。网页帧按自己的尺寸排布（1920×1080 NV12 的 UV 从第 1080 行开始），Venus 按 S_FMT 协商的布局读（UV 从第 1088 行开始，共 sizeimage 字节）。于是色度读错，还会读到帧后面的内存。
- **修复**：Linux 上编码输入一律改用驱动分配的 MMAP 缓冲区，每帧用 libyuv 按 S_FMT 布局拷贝（NV12 直接拷，I420 转 NV12）。拷贝前检查 stride 和平面大小，越界就报错，不交给硬件。
- **补丁**：`linux-mainline/patches/chromium-152-v4l2-encode-mmap-input.patch`（`media/gpu/v4l2/v4l2_video_encode_accelerator.{cc,h}`）。
- **验证**：测试页编码 PSNR 从 18–22 dB 升到 37–39 dB；解码画面和源图一致，没有绿边和色度错位。
- **提交**：`8df8b99`。

### 3.5 编码器空闲后关闭，下一次编码固件崩溃

- **现象**：修好 3.4 以后仍能复现：网页创建编码器、编几帧后不关、空闲约 30 s 再 `close()`，下一次编码时出现和 3.4 一样的 SMMU fault 与固件崩溃。
- **定位**：打开 `iommu:map/unmap` tracepoint 记录 Venus 的映射。fault 地址 `0xce5b6a00` 落在上一个编码会话的内部缓冲区里（`0xce000000`，18.75 MB）。这块缓冲区在 fault 前 0.25 s 已经被 unmap。
- **根因**：venc 的 `stop_streaming` 直接用通用的 `venus_helper_vb2_stop_streaming()`，没有拿 runtime PM 引用（vdec 的 `vdec_stop_streaming()` 会先 `vdec_pm_get_put()`）。编码器空闲 2 s 后自动挂起，关闭时固件处于断电状态，收不到 session stop / unset buffers。每个 `hfi_session_unset_buffers()` 等满 1 s 超时，驱动随后照样释放了内部缓冲区。固件恢复供电后还在使用这些地址，于是访问到已释放的内存。
- **修复**（overlay 标记 `dagu: venc STREAMOFF holds runtime PM`、`dagu: keep unreleased internal buffers`）：
  - 新增 `venc_stop_streaming()`，调用通用停止流程前先 `venc_pm_get()`，结束后 `venc_pm_put(..., true)`。
  - `intbufs_unset_buffers()`：固件还活着但没确认释放的内部缓冲区，宁可泄漏也不还给分配器。系统错误（固件已死）后照常释放。
- **验证**：空闲 30 s 后关闭，再编码 2 次，重复 2 轮，0 次 fault。
- **提交**：`695e6d5`。

### 3.6 固件崩溃后整机卡死

- **现象**：3.4 / 3.5 触发固件崩溃后，平板很快失去响应，`systemctl reboot` 也卡住，只能长按电源键。
- **根因**：`venus_sys_error_handler()` 恢复失败后每 10 ms 重试一次，没有上限。每次重试都重启固件、重新打开中断。Venus 中断是电平触发，固件起不来时中断风暴约 9 万次/秒，压满 CPU0；UFS 中断也在 CPU0 上，存储 IO 卡住，journald、jbd2、sync 全部进入 D 状态。
- **修复**（overlay 标记 `dagu: bounded sys-error recovery`）：重试间隔改为 `100 ms << n`，最多 4 次。仍失败就 `venus_shutdown()`，编解码停用到下次重启，系统其余部分照常运行。
- **验证**：`#648` 上再次触发固件崩溃，日志只出现一次 `recovery failed ... (attempt 1)`，系统继续响应。但这次有 `hfi_core_init` 等完成量时持有 `core->lock`，新打开 `/dev/video15` 的进程被挂起超过 120 s 的告警。所以根本修复还是 3.5，避免固件崩溃。
- **提交**：`38a8398`。
- **应急**：如果仍遇到 venus 中断风暴，先把中断移出 CPU0 再重启：
  ```sh
  echo 80 > /proc/irq/$(awk -F: '/venus/{gsub(/ /,"",$1); print $1}' /proc/interrupts)/smp_affinity
  sync; echo b > /proc/sysrq-trigger
  ```

### 3.7 暂停后跳转偶发卡住

- **现象**：暂停后设置 `currentTime`，大约每 3 轮 20 次跳转会有一次停在 `readyState=1`，`seeked` 永远不来。关掉硬件解码（`--disable-accelerated-video-decode`）后不出现。
- **根因**：我们之前给 Chromium 加了一处 Venus 专用逻辑：CAPTURE 队列开始工作前，OUTPUT 队列里同时只放一个码流缓冲区（否则 Venus 不吐第一帧）。在这个阶段，下一个缓冲区要等 Venus 退回上一个才能送。但 `WaitOnceForEvents()` 只等 `POLLIN | POLLPRI`，没有任何事件在"OUTPUT 缓冲区已退回"时唤醒解码器；而媒体管线已经用完了解码请求配额，不会再调 `Decode()`。日志里最后一条是 `Holding bitstream until capture is streaming`，此后再无动作。
- **修复**：处在这个阶段时同时等 `POLLOUT`，收到后调 `OnOUTPUTBufferDone()` 回收缓冲区并送下一个。
- **补丁**：`linux-mainline/patches/chromium-152-v4l2-decode-held-bitstream-wakeup.patch`（`media/gpu/v4l2/v4l2_stateful_video_decoder.{cc,h}`）。
- **验证**：7 种格式各 20 次跳转，0 次卡住。
- **提交**：`8df8b99`。

### 3.8 4K 播放丢帧

- **现象**：第一轮 Chromium 测试里 H.264 4K 丢 7 帧，VP9 4K 丢 27 帧，HEVC Main10 4K 只有 43 fps、丢 15 帧。
- **定位**：
  - 按 100 ms 统计帧数，丢帧几乎全部集中在开始播放后的 0.2–0.6 s，稳态是每 100 ms 6 帧、不丢。
  - 播放前多等 2 s 再 `play()`，开头不再丢帧。
  - Chromium trace：起播时 `MojoVideoDecoder::Decode` 一次耗时 340 ms，GPU 主线程 `SkiaOutputSurfaceImplOnGpu::SwapBuffers` 卡 98 ms。
  - strace：CAPTURE 队列 `REQBUFS` 152 ms、`STREAMON` 167 ms；关闭时 GPU 进程每个 `close()` 15–20 ms，连续二十多个。
  - 内核采样：GPU 进程时间主要花在 `arm_smmu_tlb_inv_range_s1`（每页一次同步 TLB 失效）、`__pi_clear_page` 和 `free_frozen_pages`。
- **根因**：
  1. **IOMMU 严格模式**（`CONFIG_IOMMU_DEFAULT_DMA_STRICT=y`）。每 unmap 一个 4K 页就同步刷一次 SMMU TLB。4K 10-bit 流要映射约 1 GB 的 Venus 缓冲区，分配和释放都要逐页做。释放上一段视频时 GPU 主线程被卡约 300 ms，新解码器启动也有约三分之一的时间花在这上面。
  2. **测试页本身的问题**：
     - 视频元素 `remove()` 后，解码器和 4K 帧池要等垃圾回收才释放。连续播几段 4K 后可用内存从约 4 GB 降到约 600 MB，开始换页，GPU BO 也被换出（`shmem_swapin_folio`），gnome-shell 的 `MSM_GEM_SUBMIT` 一次 43 ms。
     - `loadeddata` 后立即 `play()`，此时只缓冲了一帧，前约 200 ms 是在等数据，不是解码慢。
     - 截屏放在计时区间里，截屏会让合成器停顿 100 ms 以上。
- **修复**：
  - 内核命令行加 `iommu.strict=0`（DMA-FQ，批量刷新 TLB，x86 和 Android 的默认做法），见 `scripts/build-bootimg.sh`。提交 `8b08357`。
  - 测试页：播放完显式 `pause(); removeAttribute('src'); load(); remove()` 释放播放器；等 `canplaythrough` 再播放；第一秒单独报告；截屏挪到计时区间之后。提交 `34b01c2`。
- **排除**（实测无效或变差，没有采用）：
  - CPU / GPU 调速器改 performance：丢帧没有变化。
  - `WaylandExternalBeginFrameSource`：rAF 帧间隔变差。
  - 关 `WaylandLinuxDrmSyncobj`：没有改善。
  - 关 `dagu-present-pump` 扩展：H.264 和 Main10 丢帧变多。
  - 关 msm GEM eviction：在内存充足时没有区别；内存问题的根因在测试页。
- **验证**：3 轮全部通过，稳态 4K60 都在 59.7–60.0 fps，丢帧 0–3 / 270。

---

## 4. 提交

| 提交 | 内容 |
|---|---|
| `bbce3f9` | fix(venus): H.264 level 5.2 |
| `91cfe59` | test(venus): GStreamer 硬件编解码测试 |
| `22a1873` | fix(venus): Iris2 隐藏 MPEG-2 硬件解码 |
| `38a8398` | fix(venus): 系统错误恢复重试设上限 |
| `695e6d5` | fix(venus): STREAMOFF 时保持编码器上电；未确认释放的内部缓冲区不释放 |
| `8b08357` | perf(boot): `iommu.strict=0` |
| `8df8b99` | fix(chromium): 开启 VBR、编码输入改 MMAP、跳转唤醒 |
| `34b01c2` | test(codec): Chromium 编解码测试；GStreamer 测试 MPEG-2 走软件 |
| `35ae1d4` | docs: 编解码覆盖范围 |

内核修改全部在 `scripts/apply-overlays.sh`（按 overlay 标记查找）。Chromium 修改以补丁形式放在 `patches/`。

---

## 5. 部署

### 5.1 内核

```sh
cd linux-mainline
DAGU_MINIMAL=1 DAGU_DISPLAY=1 ./scripts/build-kernel.sh && ./scripts/build-bootimg.sh
ssh root@<tablet> 'sync; systemd-run --no-block --on-active=2 /usr/sbin/reboot bootloader'
# 等 lsusb 出现 18d1:d00d
WAIT=20 ./scripts/flash-boot.sh flash-b
```

检查：`uname -v` 和 `out/kernel/.version` 一致；`/proc/cmdline` 含 `iommu.strict=0`；`cat /sys/kernel/iommu_groups/*/type` 里 `aa00000.video-codec` 所在组是 `DMA-FQ`。

venus 模块从 ramdisk 的 `extra/` 装到 `/lib/modules/$KVER/extra`。只改模块时可以把 `.ko` 放到平板 `/root/venus-new/` 再重启，`dagu-venus-load.sh` 会优先加载它；验证完要删掉该目录。

### 5.2 Chromium

Chromium 树在 `linux-mainline/out/chromium-v4l2-src/official-152`。在 `chromium-152-v4l2-encode-linux.patch` 和之前的 dagu 改动之上打本次两个补丁（补丁头注释之后是标准 unified diff）：

```sh
cd linux-mainline/out/chromium-v4l2-src/official-152
patch -p1 < ../../../patches/chromium-152-v4l2-encode-mmap-input.patch
patch -p1 < ../../../patches/chromium-152-v4l2-decode-held-bitstream-wakeup.patch
PATH=$PWD/third_party/llvm-build/Release+Asserts/bin:$HOME/.local/bin:$PATH ninja -C out/dagu chrome
```

增量编译约 1 分钟。部署：把 `out/dagu/chrome` 装成平板的 `/usr/lib/chromium/chromium`，`out/dagu/v8_context_snapshot.bin` 装到 `/usr/lib/chromium/`（两者必须同一次编译）。再装 `scripts/dagu-chromium-native.sh` 为 `/usr/local/bin/dagu-chromium-native`。旧二进制备份在平板 `/var/tmp/chromium-backup/`。

---

## 6. 遗留

- **发布镜像**：v0.1.6 镜像里的 Chromium 二进制和包装脚本还是旧版，需要重新打包才能带上本次修复。当前平板上的 Chromium 是手动替换的。
- **MPEG-2 旧补丁**：vdec.c 里 MPEG-2 的裁剪、stride、work_route 补丁已走不到，可以清理。
- **固件崩溃时 `core->lock`**：3.6 只限制了重试次数。恢复过程中 `hfi_core_init()` 持锁等待，期间打开编解码设备的进程会被挂起。这个问题在 3.5 修复后没有再触发，但恢复路径本身还没改。
- **起播成本**：4K 10-bit 首帧仍需约 0.5 s，主要是分配 20 个 CAPTURE 缓冲区（约 1 GB）并清零。可以考虑减少 CAPTURE 缓冲区数量，没有做。
- **mpv**：仍只能用 `v4l2m2m-copy`。
