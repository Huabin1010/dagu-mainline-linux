# dagu identity 120 fps：DPU `dpu_enc_kickoff` 周期性空洞（问题专文）

简洁说明（机制、已排除、v1–v7、板上现状）：

- `linux-mainline/docs/dagu-typeb-kickoff-hole.md`

本文只陈述**现象、实验台、已经做过的调查、以及洞仍然在的事实**。  
不写改法、不写下一刀、不写「应该 poke 哪条指令」。

实验流水账（带 insn / A/B 表）仍在：

- `linux-mainline/docs/dagu-idle-pipeline.md`

本文把那条线收成一份「问题到底是什么、我们做了什么、现在还卡在哪」。

日期：2026-09-13。板子：Xiaomi Pad 5 Pro 12.4（dagu / SM8250 / L81A）。

---

## 1. 问题一句话

实验室页在 **Mutter identity（transform 0）+ Chrome GL 预旋 270° + 2 路 Venus 硬解** 下，页面 rAF 中位已经是 **8.3 ms（120 Hz 形）**，面板 vblank 也约 **119–120 Hz**，但 DPU **`dpu_enc_kickoff` 并不能稳满 ~120 Hz**：大约每 1–2 秒出现一次 **50–250 ms** 的提交空洞。`gaps_gt_50ms` 日常是 **3–10**，不是 0。

屏没有黑、没有复位。空洞里硬件仍在扫**上一张** framebuffer。用户看见的是动画/视频抽一下。

验收缺口（当前**没有**达到）：

| 项 | 实验室已看到 | 仍缺 |
|----|--------------|------|
| 页面 rAF `p50` | 经常 8.3–8.4 ms | 会振荡到 16.6 ms（掉成 ~60 fps），重开 identity 才回来 |
| 面板 vblank | ≈119–120 Hz | 偶发 33–66 ms，不是每个 kickoff 洞都有 |
| Venus | `video14_open=2`，`venus_irq` 上升，`software_decode=false` | 个别实验会把 `video14_open` 打到 0 |
| DPU `dpu_enc_kickoff` | 常见 **80–105 Hz** | **不是**稳满 ~120 Hz |
| kickoff 间隙 `max` | 常见 117–258 ms | 远大于 8.3 ms |
| `gaps_gt_50ms`（约 8 s 窗） | 常见 **3–10** | **不是 0** |

「稳满」在这里的硬数字是：同一 8 s 窗里 kickoff 次数 / 时间跨度 ≈ 120，且 `gaps_gt_50ms=0`。现在两边都不成立。

---

## 2. 实验台（我们把问题缩到哪一个场景）

### 2.1 机器与会话

| 项 | 值 |
|----|-----|
| 设备 | Xiaomi Pad 5 Pro 12.4，内部名 dagu，SoC SM8250 |
| 面板 | L81A，物理 mode **1600×2560@120**，DSC 1.1 双路 |
| 内核 | 本树 mainline + dagu overlay，只刷 **B 槽** |
| 合成 | GNOME Shell 50.1，`libmutter-18-0:arm64 50.1-0ubuntu2.2` |
| 浏览器 | `/usr/lib/chromium/chromium` official-152，约 469 MB，**未 strip** |
| BuildID | `858b8197c2ea8f42e85174323b0fa5ee49eeaae1` |
| 主机同份 ELF | `linux-mainline/out/chromium-v4l2-src/official-152/out/dagu/chrome` |
| SSH | `ssh -i linux-mainline/out/id_dagu root@192.168.7.2` |
| 会话用户 | `dagu` uid=1001，Wayland `wayland-0` |

实验室入口：

- 板上实验室：`/usr/local/sbin/dagu-pipeline-lab.py --serve` → `http://127.0.0.1:8770`
- identity 重开：`/usr/local/sbin/dagu-lab-identity-120.sh`
- 包装：`linux-mainline/scripts/dagu-chromium-native.sh` → `/usr/local/bin/dagu-chromium`
- 验收只读 dump：`http://127.0.0.1:8770/api/dump`（板上无 `curl`，用 python `urllib`）
- DPU 节拍：ftrace `events/dpu/dpu_enc_kickoff`，必须 `tracing_on=1`

identity 实验室的显示合同：

- Mutter `ApplyMonitorsConfig` **transform 0**、scale **1.0**
- Chrome `DAGU_CHROME_PANEL_ROTATE=270`（aura 根图层预旋，像素进物理 1600×2560 `wl_buffer`）
- `experimental-features=@as []`（关 `scale-monitor-framebuffer`）
- 测 lab **不开** `dagu-scanout@local`（8 ms 泵会把旧缓冲再 destile，kickoff 高但页面不是 120 fps）
- light 页：2 路 720p Venus（H.264 + HEVC），干净 profile `/tmp/dagu-lab-profile`

日常桌面仍是 1.25 / transform 3（270° shadowfb destile）。本文的洞是 **identity 实验室里仍然在的那批**，不是日常 270° destile 地板。

### 2.2 硬路径约束（问题定义的一部分）

这条线从一开始就把「能播」和「硬件一线」分开。下面几条**不是交付**，因此也不能拿它们当「洞已经没了」：

- Chrome / 网页视频退回 CPU 栅格或 FFmpeg 软解
- `--disable-gpu-rasterization`、`--disable-accelerated-video-decode`、强制 `FFmpegVideoDecoder`
- 用 VA-API 冒充 Venus。Venus 是 `/dev/video14` **stateful V4L2 m2m**，不是 libva，不是 v4l2 request
- 16/24 ms Ozone 令牌、`libdagu*` 进 gnome-shell
- 锁 `governor=performance`、钉大核来「补」软解或补洞
- 默认 Vulkan / `WaylandOverlayDelegation`

因此：rAF 数字好看、掉帧百分比下降、截图「看起来流畅」，只要 `dpu_enc_kickoff` 仍有 ≥50 ms 洞，或 Venus 没打开 `/dev/video14`，问题就还在。

### 2.3 活二进制怎么对

源码行号多次对不上活路径。实际做法是：

1. 拷板上正在跑的 so / chrome（或用主机同 BuildID 的 ELF）
2. `aarch64-linux-gnu-objdump -d` 把 C 的 `if / return / bl` 对到 `cbz / b / ret`
3. 确认 `r-xp` maps 基址 + 文件偏移后再读 `/proc/<pid>/mem`
4. Chrome RX `PT_LOAD`：`p_offset=0x2ba0000`，`p_vaddr=0x2bb0000`。  
   `runtime = maps_start + (elf_va - 0x2bb0000)`。按 file offset 直接 peek 会偏 **64 KiB**。
5. 写 `/usr/lib/chromium/chromium` 会 **ETXTBSY**：必须先 `pkill` 再 `pwrite`。进程 poke 用 `/proc/<pid>/mem`。主进程和 GPU 进程地址空间不是同一份。

本 boot 曾稳定看到（ASLR 未变时）：

| 进程 | 路径 | `r-xp` |
|------|------|--------|
| gnome-shell | `/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0` | `0x7f93450000`（file offset 0） |
| gnome-shell | `/usr/lib/aarch64-linux-gnu/mutter-18/libmutter-clutter-18.so.0.0.0` | `0x7f93760000` |

Chrome / GPU 的 maps 每次 identity 重开都会变，对象地址（`WaylandFrameManager`、`DisplayScheduler`）必须用 vtable 重扫，不能沿用上一轮的堆指针。

---

## 3. 问题长什么样（用户可见 + 仪器可见）

### 3.1 用户可见

- 实验室页 CSS 滚动 / 两路循环视频在播，多数时间顺。
- 每隔大约 1–2 秒，整页（含视频）一起顿一下，时长肉眼约一到两帧以上，仪器上是 **50–250 ms** 无新 DPU 提交。
- 不是触摸引起的：手指离开后 CSS / 视频 / 惯性仍抽。触摸 IRQ 另文：`linux-mainline/docs/dagu-touch-irq-jitter.md`。
- 不是花屏、不是闪退兔子、不是整机复位。

### 3.2 仪器：两套钟对不齐

同一段时间里同时存在：

| 钟 | 典型值 | 含义 |
|----|--------|------|
| 面板 vblank / `dpu_crtc_vblank_cb` | ≈119–120 Hz，p50 8.33 ms | 扫描没停，在扫旧 fb |
| 页面 rAF | p50 经常 8.3 ms，但 p99/max 可到 90–250 ms | Chrome 主线程多数时候按 120 形在走，洞时会冻 |
| DPU `dpu_enc_kickoff` | **80–105 Hz**，p50 仍约 8.3 ms，但 max 117–258 ms | **没有新 atomic commit** 的间隙 |
| lab `fps` / `holes` | fps 常 70–110，`holes` 累计上百 | dump 计数器，和 kickoff 洞同一类事件 |

2026-09-13 夜间 identity 重开后的一份 8 s 窗（`linux-mainline/scripts/dagu-hole-peek-46.py` 板上跑）：

| 项 | 值 |
|----|-----|
| lab `p50` | 8.4 |
| `video14_open` | 2 |
| `software_decode` | false |
| `vblank_fps` | 111–118 |
| `dpu_enc_kickoff` n / span | 834 / 7.943 s → **105.0 Hz** |
| kickoff p50 / max | 8.35 / **124.0 ms** |
| `gt50` | **5**（124.0 / 120.2 / 89.1 / 77.9 / 58.2 ms） |
| 页面 `holes` 累计 | 255→261 |

更早的 identity 基线窗（`linux-mainline/docs/dagu-idle-pipeline.md` §19 起）同样是：

- kickoff **73–103 Hz**
- max **117–242 ms**
- `gt50` **3–13**

vblank 全程可以是 **120.0 Hz / max 8.4 / gt50=0**（§20），同时 kickoff 仍有洞。  
**屏在扫，编码器没被踢。**

### 3.3 空洞里硬件在做什么

多次 ftrace（`dpu_enc_kickoff` / `dpu_crtc_vblank_cb` / `dpu_enc_frame_done_timeout` / underrun）：

- 洞里 **没有** `dpu_enc_frame_done_timeout`、没有 underrun、没有 `vblank timeout: 400000` 成对出现在每个 1–2 s 洞上。
- `prepare_kickoff` 与 `kickoff` **次数相同**。硬件队列没有「prepare 了踢不出去」。
- 大洞（~200 ms）里 vblank 有时也在约 14 ms 后停；较小洞里 vblank 仍在走。两种都发生过。
- `dpu_kms_commit` / `complete_flip` 出现在**洞结束**那一次 kickoff，不是洞中间。

结论（已反复对过）：这不是 DPU 卡死，是 **用户态没有新的 KMS atomic commit**。

`vblank timeout: 400000`（`BIT(22)` = DSC flush）本 boot 仍会隔 5–15 分钟打一对。它解释不了每 1–2 秒的 kickoff 洞。见 `linux-mainline/docs/dagu-idle-pipeline.md` 开篇「嫌疑人 C」。

---

## 4. 问题不是什么（已经排除的误诊）

下面每一条都做过对照或活体读取。它们可以是别的场景的问题，但**不是**当前 identity 120 fps 周期性 kickoff 洞的充分条件。

### 4.1 不是 CPU/GPU 掉到最低 OPP

- `/sys/class/devfreq/3d00000.gpu` 没有 `performance` governor（`echo performance` → EINVAL）。
- 空闲地板已经是 **587 MHz**；播片/按住时 `dagu-touch-boost.py` 会抬到 670。
- 锁 CPU `performance` 后 vblank 仍约 119 Hz，静置长帧还在。
- 洞里 GPU **busy 经常掉到 0**，频率仍在 587/670。洞中间 **不是** destile shader 正在啃 178 ms。

记录：`linux-mainline/docs/dagu-idle-pipeline.md` 嫌疑人 A；`linux-mainline/scripts/dagu-gpu-perf.sh`。

### 4.2 不是触摸 IRQ / SYN 抖动

手指离开后 CSS / 视频仍抽。触摸备忘停在 `linux-mainline/docs/dagu-touch-irq-jitter.md`。

### 4.3 不是 DSC 切片算错 / idle_pc 关 DSC 钟

- L81A slice 800×20，mixer 各 800×2560，本 boot 没有 `pic_width` 必须是 slice 倍数的 `pr_err`。
- Video 模式进 IDLE 只关 encoder IRQ，不关 DSC 时钟。`ENTER_IDLE=0` 的窗里洞照样在。
- 不存在模块参数 `msm.dpu_disable_dsc_clock_gating`。

### 4.4 不是「缺 drm-syncobj 协议」本身

GNOME Shell 50.1 已广告 `wp_linux_drm_syncobj_manager_v1`。  
日常包装 **ENABLE** `WaylandLinuxDrmSyncobj`。  
关掉 syncobj（`DAGU_CHROME_NO_SYNCOBJ=1`）后 kickoff 仍有洞，且常更差（max 233 ms 级）。  
协议在；洞也在。

### 4.5 不是 Chrome 没有 V4L2 / 只能软解

identity light 页：

- `video14_open=2`
- `venus_irq` 持续上升
- dump `software_decode=false`
- 进程打开 `/dev/video14`

官方包 `USE_V4L2=0` 那条老假说对**这块板上的 official-152 包**不成立。硬解在走，kickoff 洞仍在。  
`?novid=1`（关掉页内 video）后 kickoff 仍 **104 Hz / max 209 / gt50=9**。洞**不依赖** Venus 循环重启。

### 4.6 不是 270° destile 互锁本身（identity 已拆掉这条）

日常 1.25 + transform 3：最大化 UBWC 窗必须走 Mutter shadowfb 270° destile（SM8250 DPU 6.0 **没有** `DPU_SSPP_INLINE_ROTATION`）。那是另一条地板。

identity 实验室：

- KMS `rotation=1`（ROTATE_0）
- 只有 **plane-0**，fb 是 gnome-shell 1600×2560 `XR24` / `XB24`，`modifier=0x0500000000000001`（`QCOM_COMPRESSED`）
- **没有**第二块 Chrome 直扫 plane

去掉 270° destile 之后，首页慢滑 max 从约 178 ms 收到约 125 ms，**`gt50` 仍是 4**。identity + 预旋之后，周期性 kickoff 洞**仍然在**。

### 4.7 不是空 `unobscured_region` / 非 primary 那条 270° cull

`libmutter-18.so.0.0.0` `update_area`（VA `0x160f70`）两条丢 damage 的路都在 identity 上 poke 过（空 unobscured `0x160f78`、空 intersection `0x161010`、再 NOP `is_view_primary` `0x1673c8`）。kickoff 仍 95–103 Hz，`gt50` 8–13。

identity 全屏已经不是「被算成挡光所以不发 frame callback」。

### 4.8 不是 `#dumpbox` 1 Hz 整页重排 / 内存不够

`#dumpbox` 已 `display:none` 且不再每秒 `textContent`。`MemAvailable≈2.4 GiB` 时洞仍在。另有 hang 策略：`linux-mainline/scripts/dagu-hang-watch.py`。OOM/硬挂是**另一类**事故（§18），不是每 1–2 s 的 kickoff 洞。

### 4.9 不是内核 CRTC out-fence 卡 lifecycle

`dpu_crtc` 的 pageflip / out-fence 跟 **atomic commit 的 complete_flip** 走，不跟每一拍 vblank 走。没有新 commit 就不会有新的待 signal fence；上一拍的 fence 在当次 `complete_flip` 已经 signal。

洞里 `dma_fence_wait_*` 几乎全是已 signal 的空 fence（约 8 ms 一拍），**没有** 50–150 ms 的 CRTC out-fence。`kernel_verdict` 多次是 `userspace-no-commit`。

记录：`linux-mainline/out/display-stress/hole-blame-20260913-081120/blame.json`。

### 4.10 不是卡在一把 pthread mutex / `WaitForFenceAvailable`

洞里 ptrace：

| 线程 | wchan | 用户态 |
|------|-------|--------|
| `VizCompositorTh` | `futex_do_wait` | `MessagePumpDefault::Run` → `WaitableEvent::TimedWait` |
| `Chrome_ChildIOT` | `do_epoll_wait` | `MessagePumpEpoll`（当时没有 Wayland/mojo 事件） |
| `gnome-shell` | `poll_schedule_timeout` | 合成钟没排下一拍 |

`/proc/<tid>/syscall` 的 PC 是 libc `svc`，对不上 Ozone C 行号。  
`futex_do_wait` 是合成线程**空转等下一档 delayed task**，不是卡在 `MaybeProcessPendingFrame` 里的 mutex。

### 4.11 不是 `WaylandExternalBeginFrameSource` 默认在拖

该 flag **默认关**。打开后（`DAGU_CHROME_WAYLAND_BFS=1`）快滑更差（62 Hz，max 249，`gt50=7`）。日常包装保持关。

### 4.12 不是 `wait_for_all_surfaces_before_draw_`

DisplayScheduler `+636` 全程 **0**。8.3 ms deadline 被打成 `kLate`，不是无限等所有 surface。

---

## 5. 我们做了什么（调查时间线）

按时间把「做了什么、当时看到什么、洞还在哪」写清楚。数字来自 `linux-mainline/docs/dagu-idle-pipeline.md` 与 `linux-mainline/out/display-stress/`。

### 5.1 把场景从「日常 270° 首页」缩到「identity 实验室」

做过的环境收缩：

1. 确认日常最大化窗是 Mutter shadowfb destile，不是 DPU 硬件转。
2. 关 `scale-monitor-framebuffer`、scale 1.0、transform 0，Chrome 预旋 270°。
3. 实验室页从 21 路 `<video>` 收到 5 路再收到 light 2 路，避免 Venus 把 5.4 GiB 吃穿。
4. 关掉页内 `#dumpbox` 重排。
5. 接上 `wl_output.refresh` → Display 120 Hz；关掉 Linux `use_preferred_interval_`（60 fps 片把 BeginFrame 钉成 16.7 ms）。
6. 第一份「p50=8.3 / fps=111 / video14=2」dump：`linux-mainline/out/hang-20260913/lab-dump-nopref60.json`。  
   **同一天夜里 kickoff 仍不是 120、`gt50` 仍不是 0。**

做过、后来确认会**掩盖或恶化**测量的东西：

- `dagu-scanout@local` 每 8 ms `queue_redraw`：kickoff 可变高（~115 Hz），但是在 destile **旧** Chrome 缓冲，页面 HUD 可以仍是 9.5 fps。
- `dagu-present-pump@local` 的 1×1 dirty：静置能抬 kickoff，叠在滑动 destile 上打出 243–616 ms 洞。
- 16/24 ms Ozone 令牌：把互锁换成整窗 destile 尖峰。
- `libdagu*` preload 进 gnome-shell：更差或不可验收。

### 5.2 换过发行版 Mutter，再换回去

交叉编 50.1 + skipped-paint discard + 强制 `wl_surface.frame`，只换 `libmutter-18.so.0.0.0`。

| 窗 | so | kickoff Hz | max / gt50 |
|----|----|------------|------------|
| identity 基线 | stock 50.1-0ubuntu2.2 | 103 | 122 / 8 |
| dagu discard | 自编 | 75–82 | 233–241 / 11–14 |

vblank 全程 120 Hz，Venus 仍 2 路。洞**更大更稀**。  
板上已恢复 stock：`/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2` → `/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0`。

第一次漏打 Ubuntu clutter vfunc 时 class size 对不上，gnome-shell 起不来，用 `systemctl restart gdm` 救回。这是换包事故，不是 kickoff 洞本身。

### 5.3 读过活 Chrome Ozone / Viz，并对过指令

对上的对象与字段（官方包，未 strip）：

**GPU 进程 `viz::DisplayScheduler`**（vtable ELF `0xfc6f180`）：

| 字段 | 偏移 | 洞里主态 |
|------|------|----------|
| `next_swap_id_` | +600 | 大洞里整段不动 |
| `pending_swaps_` | +604 | **顶在 2** |
| `max_pending_swaps` | +608 | **2**（`GetBufferCount()-1`，至少 3 个 GBM 槽） |
| `inside_begin_frame_deadline_interval_` | +595 | 大洞里经常 **0** |
| `observing_begin_frame_source_` | +639 | 多数仍是 1 |
| `wait_for_all_surfaces_before_draw_` | +636 | 全程 0 |
| `BeginFrameSource::is_gpu_busy_` | 源 +16 | 常 1 |
| `gpu_busy_response_state_` | 源 +32 | 大洞里出现 **2=停发 BeginFrame** |

`OnPresentationFeedback`（ELF `0xbc4dd5c`）**不**减 `pending_swaps_`。只有 `DidReceiveSwapBuffersAck`（`0xbc4edf8`）减。ack 来自 Ozone `OnSubmission`。

**浏览器主进程 `ui::WaylandFrameManager`**（`WaylandWindow::frame_manager_` 在 **+248**；用 `WaylandToplevelWindow` vtable ELF `0xf60e2d8` 找）：

| 字段 | 偏移 | 洞里主态 |
|------|------|----------|
| `pending_frames_` | +8 | **经常 0** |
| `submitted_frames_` | +40 | **2–3** |
| `video_capture_count_` | +296 | 0 |
| `frame_callback_freeze_detected_` | +300 | 0 |
| `should_skip_frame_callbacks_` | +301 | 0 |
| `should_ack_swap_without_commit_` | +302 | 未强制 |

`WaylandFrame`：

| 字段 | 偏移 | 最老帧 | 最新帧 |
|------|------|--------|--------|
| `submitted_buffers` begin/end | +512 / +520 | **mapn=1**（非空） | mapn=1 |
| `wl_frame_callback` | +544 | 常 0 | 0 或 1 |
| `submission_acked` | +568 | 1 | 0 |
| `feedback.has_value`（已 present） | +656 | **1** | 0 |
| `presentation_acked` | +664 | 0 或 1 | 0 |

`WaylandBufferHandle`：`id` +8（这是 Chrome **内部槽号 1/2/3**，不是 Wayland 协议 id）、`buffer()` +24、`sync_method` +32。  
活体 **`sync_method=2`（`kSyncobj`）**。协议 `wl_buffer` id 要从 `buffer()+16` 读（例如 hid 1/2/3 → wlid **60/58/57**）。

`MaybeProcessSubmittedFrames`（ELF `0x35330a4`）：`0x3533294` `b.ne` —— `submitted_buffers` **非空就不给下一帧 `OnSubmission`**。

`SkipWaitAfterPresented` **已经在板上包里**。它看的是 `submitted.back()` 的 feedback，不是最老一帧。`FreezeTimeout()` 在 official-152 里被 DCE 掉。`FrameCallbackTimeout`（`0x3534348`）在 `video_capture_count_==0` 时只清 skip 后 `ret`，**不清 map**。

**GPU `GbmSurfacelessWayland`**（vtable ELF `0xf60f838`）：洞里 `submitted` 等 OnSubmission 的队列长度常为 **2**。`OnSubmission` 空队列或 `frame_id` 不匹配则 `0x3574334` `ret`。`OnPresentation` 不闸 `MaybeSubmitFrames`。

### 5.4 读过活 Mutter 缓冲

`MetaWaylandBuffer`（stock `libmutter-18.so.0.0.0`）：

| 字段 | 偏移 | 洞里（2026-09-13 夜，wlid 60/58/57） |
|------|------|--------------------------------------|
| `use_count` | +64 | 已 present 的那张（wlid 60）**已经是 0** |
| `type` | +72 | 4 = DMA_BUF |
| `release_points` | +152，`len` 在 GPtrArray +8 | 已 present 那张 **rplen=1 还留着** |
| `surface->buffer` / `buffer_held` | +104 / +112 | 表面还能对上 |
| `transaction.first_committed` | +440 | 洞里主态 **0**（transaction **没有**排着不 apply） |
| `fifo_barrier` | +472 | 0 |

`meta_wayland_buffer_dec_use_count`：`use_count` 到 0 时会 `wl_buffer_send_release`，然后若 `release_points->len` 则 `handle_release_points`。  
`handle_release_points`（`0x167d04` `tbnz`）：`cogl_context_get_latest_sync_fd()<0` **直接 ret，不清 `release_points`**。这与「use=0 且 rplen=1」同时成立。

`has_dependencies` 里 `buf_sources` 非空会挡住 apply（stock `0x18e3dc` `cbnz`）。洞里主态 `first_committed=0`，偶发 `first=1` 且 `buf_sources` n=3，**不是主态**。

### 5.5 在活指令上做过、测完写回的对照（洞都还在）

下面是已经发生过的事：每条都对过 opcode，测完写回 stock。表里的「之后」是问题还在或更差的证据，不是建议。

#### Chrome / Viz

| 做了什么 | 之后 kickoff（约） | 洞还在的表现 |
|----------|-------------------|--------------|
| NOP Ozone `0x3532314`（无 present 也 attach） | 93.8 Hz，max 233，gt50=5 | 尖峰更大 |
| 忽略 gpu-busy，busy 时仍发 BeginFrame | 91.6 Hz，max 225，gt50=9 | `pending_swaps_` 仍 ≥2，无新 `wl_buffer` |
| NOP `0x3533294`（不等上一帧 release 就 OnSubmission；曾误 poke 到 GPU 进程，后在主进程重做） | 主进程 76.3 Hz，gt50=6 | 提前 ack，destile 更挤；GPU 曾对不上 `frame_id` |
| `DAGU_CHROME_NO_SYNCOBJ=1` | 97.9 Hz，max 233，gt50=6 | 丢掉 acquire，洞仍在 |
| NOP `pending>=max` 仍 `DrawAndSwap`（`0xbc4d678`） | GPU 进程立刻消失 | 3 槽池没有第 4 张可画的缓冲 |
| `MaxPendingSwaps` 返回 5（`0xbc4e4cc`） | gpu-process 没了，`video14_open=0` | 同上，抽空 GBM |
| NOP `FrameCallbackTimeout` 的 `video_capture` 门 | 87 Hz，gt50=6 | 与基线同类 |
| NOP `!will_attach` 仍建 `wl_surface.frame` | 78.2 Hz，max 142 | 无新 attach，Mutter 不 destile |
| 同 `buffer_id` 也 `will_attach=true` | 84.6 Hz | 洞没满 |
| NOP Host `size==1` 才强制 ack 队首（`0x353310c`） | 78.0 Hz | 顺序改了，洞还在 |
| NOP GPU `frame_id` 必须对上（`0x357411c`） | 94.6 Hz，max 225 | 同上 |
| SkipWait 改看 `submitted.front()` | 96.4 Hz，gt50=7 | Hz 回升，**gt50 更差** |
| NOP `ScheduleBeginFrameDeadline` 的 `!inside` 门（`0xbc4eae0`） | **69.5 Hz**，max 200 | 钟能排，`pending_swaps_` 仍是 2 |
| 失败 Draw 走 missed-retry（`0xbc4c9e4`） | max 265，rAF p50 掉到 16.6 | 未满 120 |
| flush timer 160 ms → 8 ms（`0x353516c`） | **76.5 Hz** | 只冲 `OnPresentation`，不减 `pending_swaps_` |
| NOP `OnWlBufferRelease` 指针失配（`0x3534684`） | 95.9 Hz，max 184 | 最老帧仍 `fb=1 mapn=1`，release **没来**（或没进 find） |
| `kSyncobj` 也 `wl_proxy_add_listener`（`0x350d8b4` + miss 当 ret） | 89.8 Hz，gt50=6 | 听 `wl_buffer.release` 之后洞仍在 |
| HandlePresentationFeedback 里把已 present 帧的 map **end=begin**（两条 insn：`0x3534e90` / `0x3534e98`） | kickoff **31.5 Hz**，max 859，`video14_open=0`，rAF p50=25 | **GPU/Venus 死**。`fb=1` 只说明上过屏，缓冲仍可能在扫 |

#### Mutter / Clutter

| 做了什么 | 之后 kickoff（约） | 洞还在的表现 |
|----------|-------------------|--------------|
| 空 unobscured / 空 intersection / NOP `is_view_primary` | 95–103 Hz，gt50 8–13 | identity 不是这条 cull |
| 自编 skipped-paint discard + 强制 frame callback | 74–82 Hz，gt50 11–14 | 比 stock 更差，已换回 stock |
| idle 也 `schedule_update`（clutter `0x67c00`） | 78.9 Hz，gt50=9，rAF p50 **16.6** | 空转 destile 风暴 |
| 强制 triple buffering（`0x671a0`） | 90.6 Hz，gt50=10 | 多 destile |
| NOP `apply_state` 空 callback 不排钟（`0x165164`） | 85.6 Hz，gt50=4 | 钟多走一点，洞还在 |
| 空 callback 改看 `newly_attached`（`0x165160`） | 75.9 Hz，max 242 | 更稀更大 |
| `on_after_update` 已有 `ready_time` 也 emit（`0x169698`） | 82.2 Hz，max 225 | 几乎不动 |
| `after_update` 一律立刻 emit（`0x169668`） | 92.6 Hz，gt50=7，max 225 | 空更新反馈环 |
| NOP `finish_frame` 的 `!needs_flush` → IDLE（`0x1dcf98`） | 82.8 Hz，gt50=8 | 钟在 IDLE 时 `finish_frame` 根本不跑 |
| 跳过 paint-box 几何（`0x1e1f1c`） | **72.8 Hz** | **仍只有 plane-0**，没有直扫 |
| SIGNALED + Transfer + NOP `0x167d04`（三条一起） | 90.7 Hz，gt50=5 | Chrome `TIMELINE_WAIT` 醒不过来；`libdagu-cogl-syncfd` 假 fd 同类 |

所有上表条目在文档里都写了「已写回 stock」。当前板上身份实验室默认是 **stock mutter + stock chrome 指令**（除尚未写回的实验外，§45 两条已写回）。

### 5.6 读过、但没有当成「已经修掉」的结构事实

1. `kPresentationFlushTimerDuration` 在官方包里是 **160 ms**。它只冲 `OnPresentation`，不 ack swap。
2. Host `HandlePresentationFeedback` 在写完 `+656` 之后会 `bl MaybeProcessSubmittedFrames`。present 之后会再走一遍「map 空才 OnSubmission」的门。
3. Chrome `kSyncobj` 在 `WaylandBufferHandle::OnWlBufferCreated`（ELF `0x350d85c`）里：`sync_method==2` 走 `WaylandSyncobjReleaseTimeline::Create`，**跳过** `wl_proxy_add_listener`。implicit / dmafence 才加 listener。
4. §29 曾改 `OnWlBufferCreated` 让 `kSyncobj` 也 `wl_proxy_add_listener`，8 s 窗仍 ~90 Hz / gt50=6。那次**没有**证明「release 派发进回调之后仍不够」——见 §13。
5. 无 `linux-mainline/out/chromium-v4l2-src/official-152/out/dagu/build.ninja`，**不能增量编 Chrome**。活体实验只能 poke 已对上的指令。

---

## 6. 现在还在的问题（活体互锁，2026-09-13 夜）

下面是 identity 重开、`p50=8.3–8.4`、`video14_open=2`、`software_decode=false`、mutter/chrome 指令为 stock 时，洞里**同时**成立的事实。

### 6.1 DPU 侧

- kickoff 约 **105 Hz**（更好的窗）到 **80–95 Hz**（更常见）。
- 8 s 内仍有 **4–9** 个 >50 ms 间隙，最长常见 **120–250 ms**。
- 洞里没有 frame_done timeout / underrun。
- **没有新 atomic commit。**

### 6.2 Viz / GPU 进程侧

8 s 直方图（同一轮 peek）主态：

| `(pending_frames_, submitted, gpu pending_swaps_)` | 次数 |
|-----------------------------------------------------|------|
| `(0, 2, 2)` | 379 |
| `(0, 3, 2)` | 338 |
| `(0, 2, 1)` | 210 |

含义：

- 浏览器 Host **经常没有** `pending_frames_`（`MaybeProcessPendingFrame` 直接 ret）。
- 已经提交给 Wayland 的帧堆了 **2–3** 个。
- GPU `pending_swaps_` **顶在 2**（等于 `max_pending_swaps`）。
- `AttemptDrawAndSwap` 在 `pending >= max` 时 **不** `DrawAndSwap`（`0xbc4d678` `b.ge`）。
- 因此：**没有第 4 张 GPU 帧**，没有新的 `wl_buffer` attach 合同。

大洞里还经常同时看到：

- `inside_begin_frame_deadline_interval_=0` 且 deadline 为空（8.3 ms 那一档没排上）。
- `gpu_busy_response_state_=2`（BeginFrame 停发）。
- 偶发 `observing=0`（`ShouldDraw()==false` → 停观察 BeginFrame）。
- 偶发 **`pending_swaps_=0` 仍冻 100 ms+**（能画却等不到 BeginFrame）。同一条互锁解释不了这一例。

### 6.3 Chrome Host `WaylandFrameManager` 侧

洞里 / 日常顶满（同一 root surface）：

| 帧 | submission_acked | 已 present (`fb`) | `wl_surface.frame` (`cb`) | `submitted_buffers` 条目数 |
|----|------------------|-------------------|---------------------------|----------------------------|
| 最老 | 1 | **1** | 0 | **1** |
| 中间或最新 | 0 | 0 | 0 或 1 | 1 |

更早一轮（chrome 253395）同一结构：最老 `ack=1 fb=1 mapn=1`，最新 `ack=0 fb=0 mapn=1`，两边 `cb=0`。

含义：

- **不是**在等 `wl_surface.frame`（主态 `cb=0`）。
- 最老帧 **已经收到 presentation feedback**。
- 最老帧的 `submitted_buffers` **仍有 1 条**（kSyncobj，同一 root，另一张 `wl_buffer` 还在 map 里）。
- `MaybeProcessSubmittedFrames` 因此 **break**，不给下一帧 `OnSubmission`。
- GPU 那一侧 `pending_swaps_` 就减不下来。

`HandlePresentationFeedback` 把 `fb=1` 当成「可以从 map 里抹掉、让 GPU 复用这张缓冲」时（§45），kickoff 掉到 31 Hz，Venus 打开数掉到 0。  
**`fb=1` ≠ 缓冲已经离开扫描器。** 上过屏和可以复用不是同一件事。

### 6.4 Mutter 缓冲侧（与 6.3 同一批协议 id）

Chrome 内部槽号不是协议 id。活体对应：

| Chrome `handle.id` | `wl_buffer` 协议 id | Mutter `use_count` | `release_points->len` |
|--------------------|---------------------|--------------------|------------------------|
| 1（当时最老、已 present） | 60 | **0** | **1** |
| 2 | 58 | 1 | 0 |
| 3 | 57 | 1 | 1 |

与 §28 同类：

- Mutter **已经**把最老张的 `use_count` dec 到 0。
- 按源码，这时 **已经** `wl_buffer_send_release`。
- `release_points` 仍留 1 条：`handle_release_points` 在 `sync_fd<0` 时 ret，**timeline 没 signal、数组没清**。
- Chrome `kSyncobj` **默认不** `wl_buffer_add_listener`，等的是 syncobj timeline。
- §29 改过挂 listener 的指令，洞仍在；§12 表明那批 `wl_buffer.release` 走的是 `discarded`，§29 **没有**证明回调已经接到事件。
- 强行 SIGNALED + Transfer（§28）之后，Chrome `TIMELINE_WAIT` **仍然醒不过来**，kickoff 洞仍然在。

`first_committed=0`（§31 与本轮一致）：Wayland transaction **不是**卡在 `buf_sources` / 时间约束上不 apply。  
「下一张没 apply 所以没 dec」**不是**当前主态。dec 已经发生了。

### 6.5 Mutter 合成钟侧

活 `ClutterFrameClock`：`refresh_rate=120`。

- 日常：`DISPATCHED_ONE`（等 present）。
- `next_swap_id` 停 ≥45 ms 的大洞：钟在 **IDLE**，`pending_reschedule=0`，同时 Chrome `pending_swaps_=2`。
- gnome-shell wchan：`poll_schedule_timeout`。

空转钟 / 强制 triple / 空 callback 也 `schedule_update` / `after_update` 立刻 emit / 无 flush 也 atomic：要么 kickoff 更稀，要么 destile 更多，**`gt50` 都不归零**。

洞里钟在 IDLE 时，`finish_frame` 根本不会跑到「再 post 一次」的路径。

### 6.6 把 6.1–6.5 收成一条链（仍是问题描述）

当前**同时**成立、且互相咬住的事实：

1. GPU `pending_swaps_ = max = 2` → 不再 `DrawAndSwap` → 没有新的 GPU 帧。
2. Host 最老帧 **已经 present**（`fb=1`），但 `submitted_buffers` **非空**（`mapn=1`，`kSyncobj`）。
3. 下一帧已经 PlayBack / commit，但 **没有** `OnSubmission`，因为要等最老 map 变空。
4. map 变空在官方包里靠 `wl_buffer.release` 或 syncobj timeline。
5. Mutter 侧最老张 **`use_count` 已经是 0**（release 协议事件按源码已发出），但 `release_points` 仍在，timeline **没 signal**（`sync_fd<0`）。
6. Chrome `kSyncobj` **设计上**不给 `wl_buffer` 挂 listener（与 implicit release 互斥）。协议事件会被 libwayland 打 `discarded` 丢掉。官方期望的醒来路径是 **release timeline + `drmSyncobjEventfd(WAIT_AVAILABLE)`**。§28 强行 SIGNALED+Transfer 之后 `TIMELINE_WAIT` / eventfd **仍没叫醒**——这才是主路上还没闭合的矛盾。
7. 把 `fb=1` 直接当成 released 清 map（§45）会让 GPU **复用仍在扫的缓冲**，Venus/GPU 死。
8. Mutter 大洞里合成钟 **IDLE**，没有新 attach 就没有新 destile / 没有新 KMS commit → DPU kickoff 停。
9. 面板 vblank 多数时候还在 120 Hz 扫旧帧 → 用户看见抽帧，不是黑屏。

这条链解释了**大多数** 80–250 ms kickoff 洞。它**没有**解释：

- 同一窗里偶发 `pending_swaps_=0` 仍冻 100 ms+（§31）。
- identity 中途 rAF `p50` 自己掉到 **16.6**（BeginFrame 被钉回 60 Hz 形），kickoff 数字会跟着变脏。
- 个别窗 kickoff 只有 1 个 gt50（例如 258 ms 一次），多数窗是 5–9 个。洞是**周期性的，不是每个 8.3 ms 都坏**。

---

## 7. 仍未闭合的矛盾（问题内部的裂缝）

这些不是改法，是调查停在这里时**对不上的事实**。

### 7.1 「release 已经发出」vs「Chrome 仍 mapn=1」

Mutter `use_count=0` ⇒ 源码路径会 `wl_buffer_send_release`。  
Chrome 最老帧仍 `mapn=1`。

可能同时为真的读法（都还没被活指令唯一钉死）：

- `kSyncobj` 没挂 listener，事件发出了但没人收（§28）。
- §29 改过 `OnWlBufferCreated` 的跳转，但 §12 的 920/920 `discarded` 说明 libwayland 仍判定该 proxy **没有 listener**。§29 没把这批消息接住，不能用来推断「接到 release 也不够」。
- NOP 指针失配（§44）之后 mapn 仍是 1 ⇒ 当时更像是 **release 根本没进 `OnWlBufferRelease`**，不是 `handle->buffer()` 比错指针。

三种读法在文档里都出现过。2026-09-13 23:15 用 `WAYLAND_DEBUG=1` 对齐 `dpu_enc_kickoff` 之后，§7.1 的「发没发」已经有协议线证据，见 **§12**。

### 7.2 「transaction 没卡住」vs「没有新 kickoff」

`first_committed=0`：apply 已经发生。  
DPU 仍没有新 kickoff。

说明「没 apply」不是主因。剩下的是：apply 过的那帧没有变成新的 KMS commit（钟 IDLE、`needs_flush=0`、没有新 damage、或 destile 用的还是旧 fb），和/或 Chrome 不再交出下一张可 destile 的缓冲。

### 7.3 「3 张 wl_buffer」vs「max_pending_swaps=2」

活体有 3 个 Chrome 槽（hid 1/2/3）和 3 个 mutter DMA-BUF。  
Viz 允许的 in-flight swap 是 **2**。  
把上限抬到 5 或 NOP `pending>=max`：GPU 进程没了。  
问题表现为：**第三张已经在 Wayland 上，第二张的 OnSubmission 过不去，第一张的 map 空不了。** 不是「只有双缓冲」。

### 7.4 「kSyncobj 等 timeline」vs「关 syncobj 同样有洞」

关 syncobj 走 implicit `wl_buffer.release`，kickoff 洞仍在，且常更差。  
所以「只要 timeline signal 就满 120」**不成立**。  
§29 不能当成「听 release 仍不满 120」的证据；那次改动没有让这批消息离开 `discarded`。  
release/syncobj 是链上的一环，**不是充分条件**。

### 7.5 「8.3 ms deadline 停钟」vs「强行排 deadline 更稀」

洞里 `inside=0` 且 `deadline=0` 对得上「没有新 BeginFrame 时 8.3 ms 钟被停」。  
NOP 那个门之后：deadline 有了，`pending_swaps_` 仍是 2，kickoff **更稀**（69.5 Hz）。  
停钟是洞的**伴随现象**；单独把钟叫醒填不满 `dpu_enc_kickoff`。

### 7.6 页面 rAF 与 DPU kickoff 不是同一只钟

存在过：

- kickoff ~115 Hz，页面 HUD 9.5 fps（scanout 泵 destile 旧缓冲）。
- 页面 p50=8.3，kickoff 80–105 Hz（当前 identity 主态）。
- 页面 p50=16.6，kickoff 数字跟着脏。

dump 的 `fps` / `p50` **不能**单独当「DPU 已满 120」的证据。

---

## 8. 周期性长什么样（时间尺度）

| 尺度 | 观察到的 |
|------|----------|
| 8.3 ms | vblank / rAF 中位 / kickoff 中位（洞以外） |
| 16.6 ms | identity 中途 rAF 振荡；部分 poke 后整窗掉到这里 |
| 50–80 ms | 多数 `gt50` 条目的下沿 |
| 100–125 ms | 最常见的「抽一下」 |
| 200–260 ms | 大洞；有时伴随 vblank 也停 |
| 1–2 s | 这些洞出现的间隔（不是每个 interval 都坏） |
| 5–15 min | DSC `vblank timeout: 400000` 一对（另一类，对不上 1–2 s 洞） |
| 冷启动 / OOM | 5 路 Venus + destile shmem 吃穿 5.4 GiB：另一类事故 |

「周期性」指的是 **1–2 s 一次的 kickoff 空洞**，不是 DSC timeout，不是 8.3 ms 抖动。

---

## 9. 验收时仍然失败的具体数字（抽样）

全部是 identity + 预旋 + 2 路 Venus + stock 指令（或已写回）的窗。完整表在 `linux-mainline/docs/dagu-idle-pipeline.md`。

| 窗 / 记录 | kickoff Hz | max (ms) | gt50 | 备注 |
|-----------|------------|----------|------|------|
| `listen-ident-rot-fs-20260913-1959` | 103 | 122 | 8 | identity 基线 |
| `listen-nodumpbox-20260913-2016` | 97.4 | 125 | 10 | 关 dumpbox |
| `listen-novid-nodumpbox-20260913-2018` | 104.4 | 209 | 9 | 无 video 仍有洞 |
| §22 10 s 调度窗 | 90.6 | 222.8 | 10 | `pending=2` 主态 |
| §25 8 s DPU 事件 | 84.9 | 199.9 | 8 | 无 timeout / underrun |
| §43 同进程基线 | 92.9 | 118 | 9 | flush 实验前 |
| §44 同进程基线 | 93.0 | 134 | 7 | release 失配实验前 |
| peek-46（2026-09-13 夜） | 105.0 | 124.0 | 5 | p50=8.4，Venus=2 |

**没有任何一扇 identity 8 s 窗同时满足：kickoff ≈120 Hz 且 `gt50=0`。**

---

## 10. 调查用过的文件（只列已经发生的）

### 10.1 文档

- `linux-mainline/docs/dagu-idle-pipeline.md` — 静置/实验室流水账 §1–§44（§45 present-as-released 在会话里做过，尚未补进该文件）
- `linux-mainline/docs/dagu-a650-linear-destile.md` — 270° destile / UBWC
- `linux-mainline/docs/dagu-venus.md` / `linux-mainline/docs/dagu-chrome-gpu-venus.md` — Venus 一线
- `linux-mainline/docs/dagu-scroll-jank.md` — WaitForSwap 不是「缺 explicit sync」
- `linux-mainline/docs/dagu-touch-irq-jitter.md` — 触摸已排除
- `linux-mainline/docs/dagu-adaptation-status.md` — 适配总表

### 10.2 实验室与探针

- `linux-mainline/scripts/dagu-pipeline-lab.py` / `dagu-pipeline-lab.html` / `dagu-pipeline-tab.html`
- `linux-mainline/scripts/dagu-lab-identity-120.sh`
- `linux-mainline/scripts/dagu-lab-identity-native.sh`
- `linux-mainline/scripts/dagu-native-lab.py`
- `linux-mainline/scripts/dagu-native-hole-probe.py`
- `linux-mainline/scripts/dagu-chromium-native.sh`
- `linux-mainline/scripts/dagu-idle-pipeline-probe.py`
- `linux-mainline/scripts/dagu-dpu-jank-capture.py`
- `linux-mainline/scripts/dagu-dpu-hole-blame.py`
- `linux-mainline/scripts/dagu-dpu-timeout-watch.sh`
- `linux-mainline/scripts/dagu-chrome-ozone-stack.py`
- `linux-mainline/scripts/dagu-use-count-hole.py`
- `linux-mainline/scripts/dagu-hole-peek-46.py`（FM vtable + 洞里帧；mutter 缓冲需用协议 wlid 不是 handle.id）
- `linux-mainline/scripts/dagu-mutter-orientation.py`
- `linux-mainline/scripts/dagu-hang-watch.py`

### 10.3 抓痕（JSON）

目录：`linux-mainline/out/display-stress/`

其中包括（不完整）：`idle-pipeline.json`、`jank-capture-*`、`hole-blame-*`、`dagu-sched-holes.json`、`dagu-ozone-ack-holes.json`、`dagu-syncobj-signaled-ab.json`、`dagu-syncobj-listen-ab.json`、`dagu-deadline-inside-ab.json`、`dagu-host-empty-break-ab.json`、`dagu-flush8-ab.json`、`dagu-release-cmp-ab.json`，以及各节 A/B 的 `dagu-*-ab.json`。

夜间 peek 原稿：`/tmp/dagu-hole-peek-46.json`（主机）。

### 10.4 活 ELF / 源（读过，不是「已经改对」）

- 板上 `/usr/lib/chromium/chromium`
- 板上 `/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0`
- 板上 `/usr/lib/aarch64-linux-gnu/mutter-18/libmutter-clutter-18.so.0.0.0`
- 主机拷贝 `/tmp/dagu-mutter-bin/libmutter-18.so.0.0.0`
- stock 源 `/tmp/mutter-50.1-orig/`（`meta-wayland-transaction.c`、`meta-wayland-buffer.c`、`meta-wayland-surface.c`）
- Chrome 源（若在树里）`wayland_frame_manager.cc` / `display_scheduler.cc` / `gbm_surfaceless_wayland.cc` / `wayland_buffer_handle`（本工作区曾用 `linux-mainline/out/chromium-v4l2-src/official-152/`；源树可能被清掉，**ELF 还在**）

### 10.5 补丁与扩展（存在于仓库，identity 洞没有因它们归零）

- `linux-mainline/patches/mutter-50-unobscured-damage.patch`
- `linux-mainline/patches/mutter-50-skipped-paint-discard.patch`
- `linux-mainline/patches/mutter-50-pending-release-tick.patch`
- `linux-mainline/patches/mutter-50-unobscured-damage.patch` 对应的 `dagu-mutter-damage.c`
- `linux-mainline/scripts/dagu-present-pump@local/`
- `linux-mainline/scripts/dagu-scanout@local/`（测 identity 时关闭）

---

## 11. 一句话收束

问题不是「120 Hz 模式没开」「Venus 没接上」「DPU 死了」「触摸抖」「缺 syncobj 协议」「270° destile 没拆」。

问题是：在这些都已经按实验室合同跑起来之后，**Chrome 三缓冲管线在「最老帧已 present、map 仍非空、GPU pending=2」处周期性咬死几十到两百毫秒；Mutter 合成钟在同一段时间进 IDLE；DPU 因此没有新的 `dpu_enc_kickoff`，而面板仍在 120 Hz 扫旧帧。**

§16 的 GTK 孪生页（无 Chrome）同一合同下 kickoff 仍是 **103–109 Hz / gt50=5–7**。Chrome 那条互锁可以解释 Chrome 窗，**解释不了**「没有 Ozone 也掉 kickoff」。

已经对过指令、做过几十次单点对照，**没有任何一次把 `gaps_gt_50ms` 做到 0 且 kickoff 稳满 ~120 Hz。**  
把「已 present」直接当成缓冲可复用，会把 Venus/GPU 打死——说明咬死处和「还能不能复用这张缓冲」不是同一件事。

这就是当前还在的问题。

---

## 12. 协议线：`wl_buffer.release` 在洞里出现了，但全部是 `discarded`（2026-09-13 23:15）

`DAGU_WAYLAND_DEBUG=1` 起 identity Chrome（official-152 静态链了 `WAYLAND_DEBUG` / `wl_closure_print`，不依赖系统 `libwayland-client.so`）。stderr 是 Ozone 格式：`[ms] discarded wl_buffer#78.release()`，对象号是 `#` 不是 `@`。

用 `wp_presentation_feedback.presented(0, tv_sec, tv_nsec, …)` 的内核单调钟和 `dpu_enc_kickoff` ftrace（`trace_clock=mono`）做线性拟合，残差中位 **0.1 ms**。

10 s 窗（WAYLAND_DEBUG 把 rAF `p50` 压到 16.7，洞仍在）：

| 项 | 值 |
|----|-----|
| kickoff | 872 / 87.3 Hz / max 233.2 / **gt50=7** |
| `wl_buffer#N.release()` 出现 | **920** |
| 其中 `discarded` | **920** |
| 真正派发给 listener 的 `wl_buffer.release` | **0** |
| 丢弃的 id | 主表面 `#60/#74/#78` 各 ~297；另有 `#83/#56/#57` 各 10 |
| 7 个 kickoff 洞里 | **7/7** 都有 `discarded …release()`；**0/7** 有派发；7/7 洞里仍有 `attach`/`commit` |

脚本：

- `linux-mainline/scripts/dagu-lab-identity-120.sh`（`DAGU_WAYLAND_DEBUG=1` 才带 `WAYLAND_DEBUG`）
- `linux-mainline/scripts/dagu-wayland-release-capture.py`

抓痕：

- `linux-mainline/out/display-stress/dagu-wayland-release-align.json`
- `linux-mainline/out/display-stress/dagu-wayland-release-report.json`
- 板上切片曾在 `/tmp/dagu-wayland-release-cap/`

§7.1 的「发没发」：Mutter **发出了**，Chrome 主进程 **从 socket 读到了**（不是卡在 epoll 没 flush）。读到之后 libwayland 打 `discarded` 并丢掉分发——**`OnWlBufferRelease` 根本没被调用**。这不是处理逻辑写错，是该 `wl_buffer` proxy 从未挂 listener。洞里仍有 `attach`/`commit`，Wayland 连接没停死。设计意图见 §13。

---

## 13. `discarded` 排除的是旁路；主路是 timeline，§28 才是还没闭合的矛盾

### 13.1 §29 不能写成「收到 release 仍不够」

`OnWlBufferCreated`（ELF `0x350d85c`）活指令：

```text
350d894  ldr w8,[x19,#32]          ; sync_method
350d898  cbz w8, 350d8e0           ; kNone：什么都不挂
350d89c  cmp w8,#2
350d8a0  b.ne 350d8cc              ; 不是 kSyncobj → wl_proxy_add_listener
350d8a4  bl WaylandSyncobjReleaseTimeline::Create
                                   ; kSyncobj：只建 release timeline，不挂 listener
350d8cc  bl wl_proxy_add_listener  ; implicit / dmafence
```

`kSyncobj==2` 跳过 `wl_proxy_add_listener` 是**注册时机上的互斥**，不是「要不要处理 erase」的布尔写错。这批 `wl_buffer` 从创建起，libwayland 的 proxy listener 就是 NULL。底层收到 `release` opcode 的行为就是打印 `discarded` 然后丢掉——**轮不到** Chrome C++ 的 `OnWlBufferRelease`。

因此：

- §12 的 920/920 `discarded` = 这批消息在 **libwayland dispatch** 被丢，不是在 `OnWlBufferRelease` 里比错指针。
- §44 NOP 失配、§29 改跳转，都默认「事件已经进了 Chrome 回调」。§12 说明默认不成立。
- §29 洞还在，只说明**那次改动没有让这批消息离开 `discarded`**（挂的位置/时机没成为这批 proxy 的 listener）。它**不能**证明「回调接到 release 之后仍不满 120」。

### 13.2 官方给 kSyncobj 准备的醒来路径

Chrome 侧（同一 ELF）：

| 符号 | ELF | 活行为 |
|------|-----|--------|
| `WaitForFenceAvailableAtCurrentSyncPoint` | `0x3548ce0` | `+40==0` 时 `eventfd` + `WatchFileDescriptor`，再 `DrmSyncobjIoctlWrapper::SyncobjEventfd(..., flags=4)` |
| flags `#4` | | `DRM_SYNCOBJ_WAIT_FLAGS_WAIT_AVAILABLE`：等**该 point 上有 fence**，不是等 `wl_buffer.release` |
| `OnFileCanReadWithoutBlocking` | `0x3548b94` | eventfd 可读 → `ExportCurrentSyncPointToSyncFd` → OnceCallback |
| `IncrementSyncPoint` | `0x3548a2c` | `+32++`，清 `+40` |

Mutter 侧（stock `libmutter-18.so.0.0.0`）：

`dec_use_count` 到 0 时**两件事连着做**：`wl_buffer_send_release`（Chrome 丢弃）+ `handle_release_points`。后者要 `cogl_context_get_latest_sync_fd()>=0`，再 `meta_drm_timeline_set_sync_point`：

```text
c455c  mov x1,#0                 ; drmSyncobjCreate flags=0
c456c  bl drmSyncobjCreate
c4580  bl drmSyncobjImportSyncFile(tmp, sync_fd)
c4584  cbz w0, c45e8             ; 只有 Import **成功** 才 Transfer
c4588  Destroy + g_set_error     ; Import 失败：毁掉 tmp，**不** Transfer
c45e8  bl drmSyncobjTransfer     ; 把 tmp 接到 Chrome 那条 timeline 的 point 上
```

`0x167d04` `tbnz`：`sync_fd<0` 在 Create 之前就 `ret`，`release_points` 不清。这与洞里 `use_count=0` 且 `rplen=1` 同时成立。

§12 洞里 **7/7** 都有 `discarded …release()`：`dec_use_count` **已经跑过**，`handle_release_points` 跟着进门，然后 stock 在 `sync_fd<0` 处返回——**Transfer 没发生**，Chrome 的 `SyncobjEventfd(WAIT_AVAILABLE)` 等不到 point 上的 fence。

同一窗洞里主表面仍在 `set_release_point`（timeline `#61/#70/#44` 的 point 在涨）和 `attach`/`commit`。Wait 是异步 eventfd，Chrome 还能把已经在 `submitted_frames_` 里的帧 commit 出去；GPU `pending_swaps_=2` 卡的是**下一张新画的帧**。

### 13.3 §28 为什么是现在这条证据链上真正该盯的矛盾

§28 三条组合（gnome-shell，已写回）：

1. `0xc455c` `mov x1,#0` → `#1`（`DRM_SYNCOBJ_CREATE_SIGNALED`）
2. `0xc4584` `cbz` → `b c45e8`（Import 失败也 Transfer）
3. `0x167d04` `tbnz` → `nop`（`fd<0` 仍进 `set_sync_point`）

按源码，这应当在「没有 cogl fd」时仍往 **Chrome 正在等的那条 timeline / 那个 point** 上 Transfer 一个已 SIGNALED 的临时 syncobj，eventfd 应醒，`OnExplicitRelease` 应能擦 map。测到的是 kickoff 仍 ~90 Hz / gt50=5，进程没崩。

和 §12 对上之后，§28 失败不再是「旁路没挂好」，而是：

- 设计主路（timeline Transfer → `WAIT_AVAILABLE`）在强行补 fence 之后**仍然没叫醒 Chrome**；或
- 叫醒了但没有变成新的 `OnSubmission` / 新的 KMS kickoff。

还没有一份活体同时证明这三件事：Transfer 的 errno、Chrome 当时 `eventfd`/`+32` point、以及 `OnFileCanRead` 有没有进。`libdagu-cogl-syncfd` 假 fd 与 SIGNALED+Transfer 是同一类，在这套 msm 上同样没把这条主路走通。

---

## 14. 三方案取舍与点号对账（2026-09-13 23:20）

文案：`linux-mainline/docs/solutions/solution1.md` / `solution2.md` / `solution3.md`。

| 方案 | 问的问题 | 对本夜证据的增量 | 可行性 |
|------|----------|------------------|--------|
| 1 release 端到端 | Mutter 发没发、Chrome 擦没擦 map | §12 已闭合：920/920 `discarded`，`OnWlBufferRelease` 未进。再对账是旁路 | 低 |
| 2 A–G 单钟链 | 事件卡在 flush / dispatch / signal / wait 哪一截 | A–E 已被 WAYLAND_DEBUG 覆盖；official-152 **静态链** wayland，uprobe 系统 `libwayland-client` 会空打 | 中（只剩 F/G 有用，全链重） |
| 3 点号对账 | Mutter 喊的号 ?= Chrome 等的号 | §28 还没排除的假说；Mutter 不必重编 | **高** |

方案 3 按「只加日志、不改逻辑」写成交叉编 `libmutter-18`。本仓库换过 dagu so 比 stock 更差，这一刀改成 **活体 peek**：Chrome / Mutter 字段已对上指令（见下），不换包。

### 14.1 字段（objdump）

Chrome `WaylandSyncobjReleaseTimeline`（ELF `0x3548784` Create / `0x3548a2c` Increment）：

| 偏移 | 含义 |
|------|------|
| +16 | `DrmSyncobj*`，handle 在再 +8 |
| +24 | `wp_linux_drm_syncobj_timeline_v1*`，协议 id 在 proxy +16 |
| +32 | 当前 point（`IncrementSyncPoint` `+32++`） |
| +40 | `fence_available_` |
| +144 | eventfd（`-1` = 未建） |
| +152 | `OnceCallback` |
| handle +48 | 指向本对象；vptr ELF `0xf60e1a8` |

Mutter stock `handle_release_points` `0x167d54` `ldp x0,x1,[x0,#24]`：

| 对象 | 偏移 |
|------|------|
| `MetaWaylandSyncPoint` | +24 timeline*，+32 `sync_point` |
| `MetaWaylandSyncobjTimeline` | +24 `MetaDrmTimeline*` |
| `MetaDrmTimeline` | +24 drm fd，+32 `drm_syncobj` handle（`0xc45f0`） |

### 14.2 8 s 窗（identity，`p50=8.3`，`video14_open=2`）

探针：`linux-mainline/scripts/dagu-timeline-point-audit.py`  
抓痕：`linux-mainline/out/display-stress/dagu-timeline-point-audit.json`

kickoff 115.9 Hz / max 116.8 / **gt50=4**。洞里 `gpu_pend=2`。Chrome `vptr_ok=true`，三张主缓冲 wlid **74/80/58**，timeline `#67/#82/#59`，**drm handle 与 Mutter 相同（6/9/1）**。`n_cands=1`，不是扫错对象。

| 观察 | 次数（洞内 pair） | 方案 3 表 |
|------|-------------------|-----------|
| `\|mutter_point - chrome_point\| == 1` | **0** | 点号错位 **排除** |
| 号相等且 Transfer 已证实发出 | **0** | 第一行未出现 |
| `rplen=1` 且 Mutter 号 **大于** Chrome 号（+20…+247） | 4 | 不是 ±1；Mutter 记的是更新的 commit 点 |
| `rplen=0` 且 Chrome `available=0` / `cb=1` / `eventfd>=0` | 2 | 数组已清（`sync_fd>=0` 才清）但 Wait **仍武装** |
| 洞里一张 `available=1`、`cb=0` | 1 | Chrome 自认 fence 已到，仍占 `submitted` |

`handle_release_points`：`sync_fd<0` 在 `0x167d04` **直接 ret、不清数组**。因此 **`rplen=0` 表示已经拿到 cogl fd 并跑完 for + `g_ptr_array_remove_range`**，Transfer **至少被调用过**。Chrome 此时仍 `WaitForFenceAvailable`（eventfd + callback），对应方案 3 表第一行的后半句：**号的量级对得上、对象对得上，信号侧已经动手，等的人没醒**。

`rplen=1` 且 Mutter 超前：这一张的最新 `set_release_point` 还没 Transfer。协议上 signal 高点会带上低点，所以超前本身 **解释不了**「等不到」——除非 Transfer 没发生（`sync_fd<0`）或发生了但 `WAIT_AVAILABLE` / eventfd 不火。后者与 §28、与 `rplen=0` 仍 waiting **是同一条缝**。

### 14.3 这一刀钉死的 / 没钉死的

钉死：

- 不是 off-by-one。
- Chrome 在等 **这条** timeline（handle 对上、Wait 已 `eventfd`+callback）。
- 洞里同时存在「还没 Transfer」和「Transfer 已走、Chrome 不醒」。

没钉死（方案 3 表第一行剩下的）：

- Transfer 的返回值 / 点值当时是多少；
- `DRM_SYNCOBJ_EVENTFD` + `WAIT_AVAILABLE` 有没有把 eventfd 写 1；
- `OnFileCanReadWithoutBlocking` 进没进。

下一步只盯 **Chrome 已武装的 eventfd 为什么不被这套 msm 的 Transfer 叫醒**，不要再编 Mutter 只为打点号，也不要再追 `wl_buffer.release`。

---

## 15. 零超时 `TIMELINE_WAIT`：fence 已经 signal，投递丢了

探针：`linux-mainline/scripts/dagu-syncobj-fence-probe.py`  
抓痕：`linux-mainline/out/display-stress/dagu-syncobj-fence-probe.json`

`pidfd_getfd` 从 Chrome 主进程 fd **28** dup 出 `/dev/dri/renderD128`（`how=pidfd_getfd`）。对 Chrome 正在等的 `(handle, point)` 发 `DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT`：

- `flags=0` timeout=0：已 signal → 0；点上还没有 fence 时这套 msm 回 **EINVAL (22)**，不是 ETIME
- `flags=WAIT_AVAILABLE (4)`：与 Chrome `SyncobjEventfd` 同一语义；无 fence → ETIME

没 poke Mutter Transfer，没改 Chrome Wait。

### 15.1 判定

第一条采样（实验室仍 `p50=8.3` / fps 110，尚未被探针打吵）：

| wlid | handle | point | Chrome `available` / `cb` | wait0 | wait4 |
|------|--------|-------|---------------------------|-------|-------|
| 74 | 6 | 34581 | **0 / 1** | **ok** | **ok** |
| 80 | 9 | 34580 | **0 / 1** | **ok** | **ok** |

同一对 `(6, 34581)` 立刻做 **200 ms 绝对超时阻塞 wait**：`block=ok`，**14.95 ms** 返回。

整窗 Chrome 仍在等的样本（`available=0` 且 `cb=1`，n=186）：

| ioctl | 计数 |
|-------|------|
| wait0 `ok` | **64** |
| wait0 `e22`（点上无 fence） | 122 |
| wait4 `ok` | **84** |
| wait4 `etime` | 102 |

按判定表：

| 采样 | 结论 |
|------|------|
| 已 signal（wait0=ok）且 Chrome 仍 `available=0` | **投递丢了** |
| 外部阻塞 wait **能返回** | **不是** msm `TIMELINE_WAIT` 内核挂死；责任在 Chrome `SyncobjEventfd` / eventfd / UI 线程消费 |
| 全程 ETIME 后洞尾才 0 | 不是主形态。新点会先 `e22`/`etime`，随后变 `ok`，Chrome 仍不把 `available_` 置 1 |

「identity 直扫、cogl GL fence 永不完成」这一支 **不能**解释 wait0=ok。fence **活着而且已经 signal**。§28 SIGNALED+Transfer 仍不满 120，现在读成：内核侧点已经亮，Chrome 的 Wait 没把亮写进 `OnFileCanRead`。

### 15.2 探针会打吵 kickoff

8 ms 一轮 peek+ioctl 会把 kickoff 压到 ~11 Hz / gt50=61。停探针后实验室回到 `p50=8.4`、`video14_open=2`。**不要**把这支探针当日常挂件。首帧 + 一次阻塞 wait 已经够二分。

### 15.3 还没做（且不要再 poke Transfer）

- 板上那次 `SyncobjEventfd(handle, point, eventfd, WAIT_AVAILABLE)` 的返回值
- 点已经 signal 之后再挂 eventfd，这套 msm 会不会补一次计数（错过窗口）
- `WatchFileDescriptor` 是否真的盯着 `+144` 那个 eventfd；`OnFileCanReadWithoutBlocking`（ELF `0x3548b94`）进没进

---

## 16. 系统层 GTK 孪生页：没有 Chrome 也有同样的 kickoff 洞（2026-09-13 23:52）

把 HTML light 的慢滑 + 两块飞瓦做成 **GTK4 / GSK `gl` / 无 Chromium** 全屏页，同一套 identity 合同（Mutter transform 0、scale 1.0、关 `dagu-scanout@local`）。没有 Ozone、没有 Viz、`video14_open=0`。

脚本：

- `linux-mainline/scripts/dagu-native-lab.py`
- `linux-mainline/scripts/dagu-lab-identity-native.sh`

板上：`/usr/local/sbin/dagu-lab-identity-native.sh`，验收 `python3 /usr/local/sbin/dagu-native-lab.py --measure`。

抓痕：

- `linux-mainline/out/display-stress/dagu-native-lab-20260913-235207.json`（kickoff **109.0 Hz / max 109.1 / gt50=7**）
- `linux-mainline/out/display-stress/dagu-native-lab-20260913-235235.json`（kickoff **102.7 Hz / max 184.3 / gt50=5**）
- 同目录 `dagu-native-lab-20260913-235235.png`

| 钟 | native GTK（两窗） | identity Chrome 日常窗 |
|----|-------------------|------------------------|
| 页面 rAF `p50` | 8.33–8.34 | 8.3–8.4 |
| 页面 rAF `fps` | 106–113 | 常 70–110 |
| 面板 vblank | **120.12 Hz / max 8.5 / gt50=0** | ≈119–120，gt50 常 0 |
| DPU `dpu_enc_kickoff` | **103–109 Hz** | 80–105 Hz |
| kickoff `gt50` | **5–7** | 3–10 |
| `chrome` | **false** | true |
| Venus | 未开（对齐 `?novid=1`） | 2 路或 `?novid=1` 仍有洞 |

判定：同一 8 s 验收（kickoff ≈120 且 `gt50=0`）在 **没有 Chrome 的系统层页上仍然失败**。vblank 满 120、kickoff 不满、洞长 58–184 ms——和 identity Chrome 是同一类「屏在扫、没有新 atomic commit」。

这不能写成「洞只在 Chrome / Ozone / `pending_swaps_=2`」。Chrome 可以把洞变得更稀或更大，但 **Mutter + GTK 客户端已经在掉 `dpu_enc_kickoff`**。

未对齐 HTML 的地方（事实，不是改法）：飞瓦没有旋转、没有 Venus `<video>`；`overlay.get_height()` 曾报 3936（24 张卡的自然高度），`feed_max=0` 所以自动慢滑位移是 0，运动主要来自两块飞瓦。早期误开整窗 `queue_draw` 时 kickoff 掉到 ~14 Hz（测量伪影，已去掉）。

---

## 17. native 洞里在干什么（2026-09-14 00:04，无 Chrome）

探针：`linux-mainline/scripts/dagu-native-hole-probe.py`  
抓痕：`linux-mainline/out/display-stress/dagu-native-hole-probe-20260914-000429.json`

活 `ClutterFrameClock` 这次在 `0x55a5880720`（同一 gnome-shell `128256`，旧 hint `0x55a4b090d0` 已失效）。对板上 `libmutter-clutter-18.so.0.0.0` `objdump`：

| 字段 | 偏移 | 活指令 |
|------|------|--------|
| `refresh_rate` | +28 | `0x66d18` `ldr s0,[x0,#28]`，值 **119.99985**（不是精确 120.0） |
| `refresh_interval_us` | +32 | **8333** |
| `state` | +88 | `0x675e8` `ldr w2,[x5,#88]` |
| `mode` | +92 | `0` = FIXED |
| `pending_reschedule` | +396 | `0x67bf4` `ldr w20,[x0,#396]` |
| `inhibit_count` | +404 | 全程 0 |
| `maybe_reschedule_update` | `0x67c00` | `0xb40001e0` `cbz`，**stock** |

8 s 窗：kickoff **107.9 Hz / max 115.1 / gt50=6**，vblank **120.12 / max 8.4 / gt50=0**。`dpu_crtc_complete_flip` 次数与 kickoff **相同**（862），洞里的 flip 间隙也是那 6 个 90–117 ms。

6 个洞（抽样 115 / 108 / 95 ms）同时成立：

| 观察 | 值 |
|------|-----|
| `vblank_n` | 11–14（~120 Hz 还在扫） |
| `flip_n` | **1**（洞结束那一次） |
| `kernel_verdict` | **`userspace-no-commit`**（4/4 再测窗也是） |
| plane | **只有 plane-0**，1600×2560 `XR24` `modifier=0x0500000000000001` |
| GTK `wchan` | `poll_schedule_timeout` |
| GTK syscall | **73 = ppoll**（等 Wayland/时钟，不是在画） |
| gnome-shell | `poll_schedule_timeout` 或 running |
| `gpu_busy` | 洞中段经常掉到 **0** |
| 合成钟 | 洞里主态 **`DISPATCHED_TWO`**（不是 IDLE） |

整窗钟直方图（1589 次）：`DISPATCHED_TWO` 1510，`DISPATCHED_ONE*` 74，**`IDLE` 只有 5**。

和 identity Chrome 洞的差别（都是「没有新 kickoff」）：

- Chrome 大洞：钟在 **IDLE**，`pending_reschedule=0`，Host `pending_swaps_=2`
- GTK 洞：钟在 **`DISPATCHED_TWO`**（已经派出两帧、不能再派第三帧），在等 `notify_presented`

`schedule_update` 在 `DISPATCHED_TWO` 只置 `pending_reschedule` 然后 `return`（`0x675e8` 之后的 `cmp #5` / 更高态）。present 晚到期间 **不会有新 atomic**，DPU 就不 kickoff，GTK 的 frame clock 也没有事件，两边都在 `ppoll`。

这就是用户看见的「和浏览器一样偶尔卡一下」：系统层已经会停 80–120 ms 不提交，屏继续扫旧 fb。

---

## 18. 系统层洞拆成两段（2026-09-14）

对板上 stock `libmutter-18.so.0.0.0`（md5 `49a6422fcc5f11ba4894fa6dd82116b1`）反编译，字段对上：

| 对象 | 偏移 / VA | 活指令 |
|------|-----------|--------|
| `posted_frame` | onscreen **+72** | `0x1c224c` `str x0,[x23,#72]`；`0x1c1220` promote `ldr x20,[x0,#72]` |
| `next_frame` | onscreen **+88** | `0x1c47f8` `ldr x0,[x0,#88]` |
| `render_source` | +144 | 全程 **0**（不是 NVIDIA render source） |
| `do_handle_update` 等 fence | **`0x1bd9ac`** | `tbnz w20,#31,0x1bda00`（`sync_fd<0` 才立刻 `update_ready`） |
| `notify_view_crtc_presented` `peek_head==NULL` | `0x1c4474` `cbz` → `0x1c4550` | 8 s 窗 **0 次**（不是这条 abort） |
| `page_flip_feedback_flipped` | `0x1c4584` | 与 `flipped_in_impl` 同时到 |
| `maybe_post_next_frame` | `0x1c1b20` | `posted!=NULL` 直接 return |

8 s 窗里洞的主形态（无 Chrome，identity GTK）：

- `posted_frame` 与 `next_frame` **同时非空**
- `dpu_crtc_complete_flip` 相对 kickoff 的 p50 **3.7–5.4 ms**，max ~10 ms，**gt50=0**
- `drm_vblank_event_delivered` 跟着 complete_flip
- 但 `meta_kms_page_flip_data_flipped_in_impl`（`0x1bd2c0` 一带）经常要再过 **70–250 ms** 才进
- 主线程 `page_flip_feedback_flipped` 与 `flipped_in_impl` **同一毫秒**（不是 main 排队晚）

KMS 线程是 `SCHED_OTHER`，deadline timer **关**。`do_handle_update` 在 `sync_fd>=0` 且 `g_poll` 不可读时 `register_fd` 等到该 fd，期间不跑 `drmHandleEvent`。`gpu_busy` 洞中段经常是 0：fence 不是在等真 GPU 活。

把 `0x1bd9ac` 改成无条件 `b 0x1bda00`（立刻 `update_ready`，不关 implicit GEM sync）之后：

- `flipped_in_impl` 回到 complete_flip 后 **~5–10 ms**
- 第一刀消掉的是「内核已 flip、用户态 100 ms 才 promote」这一段

剩下的洞换成另一种：impl / promote **准时**，`maybe_post` 要到 **+65–220 ms** 才进（当时 `next_frame` 是空的，第二帧没 swap）。8 s 窗 kickoff 常见 **106–117 Hz**，`gt50` 仍有 **1–3**，max 仍可到 100–220 ms。验收（kickoff≈120 且 `gt50=0`）**还没到**。

`peek_head==NULL` 整段 abort、`schedule_update_now` 在 `next_frame==NULL` 时强排下一拍，这两条在活 so 上测过，**消不掉**剩下的洞。

---

## 19. 第一刀之后剩下的两类洞（2026-09-14 续）

第一刀（`0x1bd9ac` 无条件 `update_ready`）仍在活 gnome-shell `128256` 与磁盘 so 上。`complete_flip`、`drm_vblank_event_delivered`、`flipped_in_impl`（`0x1bd2c0`）现在跟 kickoff **同一毫秒到 +4 ms**。KMS 线程不再堵 fence。

对活映射 inode 打 uprobe（磁盘 so 已 `replace`，路径 uprobe 打不中）后，8 s 窗里剩余空洞是两种，**不是** `after_update` 推迟 `wl_surface.frame`（`0x16969c` delay 整窗 0 次，`emit` 与 swap 对齐）：

| 类 | 洞内相对 kickoff | 含义 |
|----|------------------|------|
| B-main | flip / delivered / impl **+1–4 ms**，`notify_view_crtc_presented`（`0x1c4440`）**+75–229 ms**，然后立刻 `maybe_post` / 下一记 kickoff | 内核与 KMS 线程准时。主线程晚跑 page-flip 闭包，`maybe_post` 才晚 |
| B-kick | flip / impl / nview / `maybe_post` 走通（`0x1c1c04`）都在 **+2–5 ms**，下一记 kickoff 要 **+100–111 ms** | 用户态已经 post，DPU 仍空一截 |

`finish_frame` IDLE（`0x1dcfa4`）与 `assign_next`（`0x1dd064`）整窗 0 次。钟主态仍是 `DISPATCHED_TWO` + `posted`，`next` 有时空、有时非空。

把 `maybe_post` 里拷到 KMS update 的 `sync_fd` 两条 NOP 掉（不往 atomic 写 IN_FENCE）之后，8 s 窗 **更差**（gt50 到 8–10），已写回。不要再清 IN_FENCE。

验收（kickoff≈120 且 `gt50=0`）还没到。用户看见的「抽一下」就是这两类剩余洞。

---

## 20. wakeup 与精化第一刀之后（2026-09-14 续）

`meta_thread_queue_callback`（`0x1d6e40`）在 B-main 洞里相对 kickoff **+3–7 ms**，和 `flipped_in_impl` 同一毫秒。缺的不是「KMS 没 queue」，是主线程晚 dispatch `notify_view_crtc_presented`。GLib 2.88 在 `ready_time` 已是 0 时 `set_ready_time(0)` 直接 return，不 `g_wakeup_signal`。

旧第一刀 `0x1bd9ac` 无条件跳到 `update_ready`，**没跑** `DISABLE_IMPLICIT_SYNC` 循环（`0x1bd9c0` `orr #4`）。atomic 的 `IN_FENCE_FD` 只在该旗标下用 signaled dummy，不是 Cogl fd。

8 s 窗（identity GTK，gnome-shell `128256`）最好一档：kickoff **110.6 Hz**，`gt50=5`，max **116.9 ms**（wakeup + 精化第一刀）。250 ms 尖峰没了。`gt50=0` 且 ≈120 Hz **还没到**。

测过更差、已撤：强制 deadline timer、无条件 DISABLE、`schedule_process` 在 deadline 关时 flush `pending_update`。不要再开。

---

## 21. wait_flush 不是洞；nopend 更差（2026-09-14 续）

gnome-shell 仍是 `128256`。留下 wakeup cave + 精化第一刀。`dpu_encoder_phys_vid_wait_for_commit_done` 活地址 `ffffffda6f827548`，`STRICT_DEVMEM=y`，`/dev/mem` 读内核 text 是 EPERM。

8 s 窗给 `drm_msm_atomic` 的 `wait_flush` / `commit_tail` / `flush_commit` 打点之后：

- 每个洞里 `wait_flush_ms` 只有 **0–6 ms**（不是 50 ms 卡死）
- `dpu_enc_wait_event_timeout` 整窗 **0 次**
- `msm_atomic_commit_tail_start` 和 `drmModeAtomicCommit` 一样，落在洞的**末尾**
- 上一帧 `commit_tail_finish` 在 kickoff 后 **+3–5 ms** 就结束

所以「atomic 已成功、内核晚 kickoff」在这一档里并不成立：用户态根本还没进下一记 `commit_tail`。`vblank timeout: 400000` 仍是 5–15 min 一对，对不上 1–2 s 洞。不要刷 8 ms `wait_for_commit_done`。

`update_ready` `0x1bd7d4` `cbnz pending_page_flip → queue_update` 改 NOP（deadline 关时立刻 `do_process_update`）第一窗 112.8 Hz / gt50=3，第二窗 **103.9 Hz / gt50=10**：`atomic` +8 ms 但 `commit_tail_start` 到 +100 ms（DRM 未完成 flip 叠提交）。已写回 stock `0x350002c0`。不要再开。

写回后 8 s：kickoff **111.0 Hz**，gt50=4，max **250**。4 个洞里 3 个是 **B-main**（`qcb` +2–4 ms，`nview` +65–245 ms），1 个 nview 准时、`maybe_post` 晚。验收（≈120 且 gt50=0）还没到。

---

## 22. B-main 是第二条 invoke，不是 qcb 没进（2026-09-14 续）

对活 so 打 `callback_source_dispatch`（`0x1d5d00`）和 `invoke_page_flip_closure_flipped`（`0x1b9548`）。每帧 **2 次** invoke（`inv_n ≈ 2 × kickoff`）：

1. `do_process` 加的 crtc listener（KMS `thread_context`）→ 洞里相对 kickoff **+4–6 ms**
2. onscreen `page_flip_listener_vtable`（`add_page_flip_listener(..., NULL)` → `g_main_context_default()`）→ **+58–113 ms** 才进，随后立刻 `nview` / `maybe_post`

`qcb` 两条都在 **+4–6 ms** 进了（`flipped_in_impl` 循环连 queue 两次）。缺的不是 queue，是 **default 那条 source 的下一次 dispatch**。cave 已 `wakeup(callback_source+128)`。`GLib` `set_ready_time` 在 `ready_time` 已相等时直接 return；`G_SOURCE_BLOCKED` 时也不 `g_wakeup_signal`。

B-kick-kernel 仍在少数洞：`nview`/`mgo`/`atomic` 都 +3–9 ms，`commit_tail_start` 在洞末。`wait_flush` 仍是 0–6 ms。

8 s（重开 native lab 后）：kickoff **108.4 Hz**，gt50=7，max 117.2。B-main×5 + B-kick-kernel×2。验收没到。

---

## 23. 洞里主线程在 `dri_flush` 上等上一帧 fence（2026-09-14 续）

洞中采样 gnome-shell **128256**：不是卡在 `ppoll` 丢 wakeup。83 ms 洞里 35/37 个样点 syscall=`running`。gdb 栈（活映射）：

`clutter_frame_clock_dispatch` → `cogl_onscreen_swap_buffers_with_damage` → `meta_onscreen_native_swap_buffers_with_damage`（`blr` 之后 `cogl_context_get_latest_sync_fd` @ 文件 `0x1c4ba4`）→ EGL → **`dri_flush`** → `fence_finish(..., OS_TIMEOUT_INFINITE)`。

活 `libgallium-26.0.8-1ubuntu0.3.so` r-xp `0x7ee8ea0000`，`dri_flush` 节流段（objdump 对上 Mesa 源码）：

- `0x1cf734` `ldr x2,[x19,#440]` = `drawable->throttle_fence`
- `0x1cf740` `mov x3,#-1` + `0x1cf74c` `blr x4` = `screen->fence_finish` 无限等
- 上一帧 GPU fence 常跟 scanout BO implicit sync，要等下一记 kickoff 才信号 → 主线程出不了 clock dispatch → default 闭包（nview）晚 65–220 ms

`timeout=0` 仍进用户态等循环（栈顶 `0xc9acb0`）。再 NOP 掉 `0x1cf74c`。8 s：kickoff **109.7 Hz**，gt50=5，max 116.6。B-main 从 5 降到 **1**；多出 nview 准时、`maybe_post` 晚 ~100 ms 的洞，以及 B-kick-kernel。验收（≈120 且 gt50=0）没到。

不要把 onscreen listener 改到 KMS context（`notify_presented` / `cogl_onscreen_bind` 必须在 GL 主线程）。

---

## 24. 跳过 sync_fd G_IO_IN 更差（2026-09-14 续）

`maybe_post_if_gl_finished` @ `0x1c4380`：`next` 在 render_source 里且 `sync.revents` 没有 `G_IO_IN` 就直接 `ret`（`0x1c43f4` `tbnz w0,#0,post`）。这是 nview 准时、`maybe_post` 晚的候选。

`0x1c43f4` → `b 0x1c43b8`（不等 fence 就 post）8 s：kickoff **108.1 Hz**，gt50=5，max **225.5**。出现 `atomic` +185 ms 和 B-kick 225 ms。已写回 stock `0x3707fe20`。不要再开。

写回后一窗 106.0 Hz / gt50=9（方差大）。留下 wakeup + 精化第一刀 + `dri_flush` NOP。验收没到。

---

## 25. `st_context_flush` 第二处 `fence_finish(-1)` 更差（2026-09-14 续）

活 gallium 在 `0x27215c` `mov x3,#-1` / `0x272168` `blr x4` 还有一处无限等（`st_context_flush` / `dri_create_fence_fd` 路径）。NOP 后 8 s：kickoff **110.8 Hz**，gt50=4，但出现 **232 ms** B-main。已只写回这两处，保留 `0x1cf74c` NOP。不要再开。

抓痕：`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-012751.json`

---

## 26. 去掉 `ATOMIC_NONBLOCK` 不稳，已撤（2026-09-14 续）

活 so `0x1b4820` `mov w22,#0x200` 是 page-flip 的 `DRM_MODE_ATOMIC_NONBLOCK`。改成 `#0` 后 `commit_tail_start` 与 `drmModeAtomicCommit` 对齐，**B-kick-kernel 整窗 0**。旧实验室连续两窗 **117.4 / 118.5 Hz，gt50=0，max 16.7–33.3**。第三窗和重开 `dagu-lab-identity-native.sh` 后掉回 **109.5 Hz / gt50=6 / max 241**，洞变成 nview 准时、`maybe_post` 晚 56–240 ms（KMS 线程堵在阻塞 ioctl 里）。已写回 `0x52804016`。不要再开。

写回后 8 s：kickoff **112.4 Hz**，gt50=3，max 116.6。洞是 2×B-kick-kernel（`atomic` +8 ms，`tail_s` +98–103 ms）+ 1×B-main。验收没到。

脚本保持 restore：`linux-mainline/scripts/dagu-mutter-atomic-block-install.sh`。

---

## 27. B-kick-kernel 是 `system_unbound_wq` 晚开工，不是 fence / wait_flush（2026-09-14 续）

`drmModeAtomicCommit(NONBLOCK)` 走 `queue_work(system_unbound_wq)`。`card0-crtc0` 已是 `SCHED_FIFO 50`，但 page-flip **不**走这条 kthread，走 `kworker/u32:*`（`SCHED_OTHER`）。

洞里对活 trace：

- `dma_fence_wait_start/end` 几乎全是 `driver=detached-driver timeline=signaled-timeline`（mutter 的 dummy `IN_FENCE_FD`），时长 ~0–5 µs
- `>=1 ms` 的 fence wait 整窗只有 0–1 条
- 每个 kickoff 洞里 **第一条** `dma_fence_wait_start`（helper `commit_tail` 的第一句）和 `msm_atomic_commit_tail_start` **同一毫秒**，都在洞末 +66–166 ms

所以 worker 一旦跑起来，`wait_for_fences` 和 `wait_for_dependencies` 都是立刻完成。90 ms 空档是 **work 已 queue、kworker 没被调度**。不是 implicit scanout fence，也不是 `wait_flush`。

`chrt -f 15` 抬所有 `kworker/u32`：B-kick-kernel 整窗 0，但变成 B-main / `maybe_post` 晚，kickoff **105.9 Hz**，gt50=7，max **225**。已 `chrt -o 0` 写回。不要再抬 unbound kworker。

`dri_create_fence_fd` @ 文件 `0x1cf980` 在 `fd==-1` 时 `bl st_context_flush` `0x2720c0`（flags=`ST_FLUSH_FENCE_FD`）。全局 NOP `0x27215c` 已否。

洞中 gdb（gnome-shell **128256**）：至少一档 55 ms 洞里主线程在 `ppoll` / `g_main_loop_run`，不是 `fence_finish`。B-kick-kernel 可以在主线程空闲时发生，单纯是 unbound wq 没被叫醒。

抓痕：`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-014006.json`（kworker FIFO，已撤）

---

## 28. B-kick-kernel：洞中无 DRM kworker；`default_affinity_scope=system` 消掉这类洞（2026-09-14 续）

本内核 `CONFIG_KPROBES is not set`，没有 `kprobe_events` / function tracer。用 `trace_pipe` 对齐真 `dpu_enc_kickoff` 洞再采栈（`linux-mainline/scripts/dagu-hole-kworker-stack.py`）：8 s 内 kickoff **916**（≈114 Hz），5 次 ≥50 ms 洞里 **4 次没有任何 `kworker/u*` 在 `commit_tail` / `wait_for_commit_done` / `drm_crtc_commit_wait`**，gnome-shell 与 KMS 都在 `ppoll`。第 5 次在 52 ms 采到 `kworker/u32` 刚进 `dpu_encoder_prepare_for_kickoff`（`msm_atomic_commit_tail` 开头）。

所以 90 ms 空档不是上一帧 `flip_done` 卡住，也不是 `dpu_encoder_phys_vid_wait_for_commit_done` 的 50 ms timeout（`linux-mainline/patches/dpu-vid-commit-done-8ms.patch` 仍保持 REJECTED）。work 已在 `drmModeAtomicCommit` 里 `queue_work(system_unbound_wq)`，**unbound worker 没被叫醒**。

当时 `workqueue.default_affinity_scope=cache`。改成 `system`（任意醒着的 CPU 可跑 commit_work），**不要**再 `chrt` 全部 `kworker/u32`：

| 窗 | 文件 | Hz | gt50 | kinds |
|----|------|----|------|--------|
| 改前基线 | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-014243.json` | 112.2 | 3 | B-kick-kernel×2 + B-main×1 |
| affinity=system | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-014937.json` | 115.7 | 2 | B-kick-kernel **0**，B-main×1 + B-post-late×1 |
| 第二窗 | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-015022.json` | 114.2 | 2 | 同上 |

B-kick-kernel 两窗都是 0。验收仍没到：还剩 **B-main**（`nview`/`maybe_post` 一起晚 70 ms）和 **B-post-late**（`nview`/`ifgl` 准时，`next_frame==NULL` 所以没进 `maybe_post`，swap 后 `mgo` 晚 100 ms）。

活 sysfs：`/sys/module/workqueue/parameters/default_affinity_scope`。脚本 `linux-mainline/scripts/dagu-wq-affinity.sh`（restore 写回 `cache`）。开机：`linux-mainline/systemd/dagu-wq-affinity.service`。

---

## 29. B-post-late：`notify_presented` 准时但 `schedule_update` 晚 ~90ms；promote-first 崩溃已撤（2026-09-14 续）

frame clock 在 `libmutter-clutter-18.so`（gnome-shell r-xp `7f93760000`），不是 `libmutter-18.so`。活偏移（dynsym / `paciasp` 已对上）：

| 符号 | 文件偏移 |
|------|----------|
| `clutter_frame_clock_notify_presented` | `0x67cc4` |
| `clutter_frame_clock_schedule_update` | `0x675a0` |
| `clutter_frame_clock_schedule_update_now` | `0x6732c` |
| `clutter_frame_clock_dispatch` | `0x73c0c` |

8 s 抓痕 `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-015333.json`（kickoff 110.5 Hz，gt50=4；当时 identity 仍在旧 pid **128256**）：

- **B-post-late 99.9 ms**：`nview` / `npresent` +5.5 ms，`sched` +96.3，`fcdisp` +96.5，`mgo` +97.4。`schednow` 整窗 **0**。presented 之后 `maybe_reschedule_update` 没有立刻 `schedule_update`（`pending_reschedule==0` 且没有 clutter timeline），约 90 ms 后客户端/Wayland 才 `schedule_update`。
- **B-main ×3**：`qcb` 准时，default 上 `nview`/`npresent`/`fcdisp` 一起晚 100–109 ms。

`notify_view` 活反编译：`0x1c44d4 bl notify_complete@0x1ba4a0`，`0x1c44dc bl promote@0x1c1220`（`posted` +72），然后 `b ifgl@0x1c4380`。把 promote 调到 notify 前（`0x97fff355` / `0x97ffd7f1`）后 gnome-shell **128256** 立刻没了，GDM 重开 ubuntu 会话。已 `restore`。脚本保持 restore：`linux-mainline/scripts/dagu-mutter-promote-first-install.sh`。不要再 apply。

新 gnome-shell 是 **413669**（`--mode=ubuntu`），磁盘 so 仍带 infence / wakeup / `dri_flush`，promote 已写回 stock。重开实验室后基线 `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-015528.json`：kickoff **111.1 Hz**，gt50=3，max **250.7**（B-post-late×2 + B-main×1）。B-kick-kernel 仍是 0。验收没到。

---

## 30. `maybe_reschedule` 无条件 `schedule_update` 已否（2026-09-14 续）

活 clutter `maybe_reschedule_update` @ `0x67be0`（`notify_presented` / `notify_ready` 都 `bl` 这里）：

| VA | insn | C |
|----|------|---|
| `0x67bf4` | `ldr w20,[x0,#396]` | `pending_reschedule` |
| `0x67bf8` | `cbnz w20,0x67c04` | 有 pending → `schedule_update` |
| `0x67bfc` | `ldr x0,[x0,#408]` | `timelines` |
| `0x67c00` | `cbz x0,0x67c3c` | 都空 → deferred / 常 `ret` |
| `0x67c38` | `b schedule_update@0x675a0` | |

`0x67bf8` `cbnz` → `b 0x67c04`（活 only，磁盘未改）：presented 后总会 `schedule_update`（不是 now）。gnome-shell **413669** 没崩。

`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-015717.json`：kickoff **107.3 Hz**（掉了），gt50=2，max 115.6。`fcdisp` 从 889 翻到 **1773**（空 paint）。B-post-late / B-main 分类变成 0，但 kickoff 次数更少。一档 `sched` +3.6 而 `fcdisp` +76（钟排了、主线程 70ms 才 dispatch）。已 restore。脚本保持 restore：`linux-mainline/scripts/dagu-clutter-resched-always-install.sh`。不要再 apply。不要再改 `0x169668` / `0x169698`（after_update emit 已否）。

---

## 31. emit 真的发出了 callback；`stage_schedule_update` 早退从未命中；a11y 关了 Hz 更差（2026-09-14 续）

gnome-shell 仍是 **413669**。活 clutter `0x67bf8` 是 stock `0x35000074` `cbnz`。`dri_flush` / wakeup / 精化第一刀 / `affinity=system` 仍在。

对活 so 打点（`linux-mainline/scripts/dagu-bmain-probe.py`）：

| 符号 | 文件偏移 | 所在 so |
|------|----------|---------|
| `emit_frame_callbacks_for_stage_view` | `0x167340` | `libmutter-18.so.0.0.0` |
| `wl_callback_send_done`（真发出） | `0x1673f0` | 同上 |
| `meta_wayland_actor_surface_apply_state` | `0x165124` | 同上 |
| `clutter_stage_schedule_update` | `0x9db50` | `libmutter-clutter-18.so.0.0.0`（deleted inode） |
| 过了 `update_scheduled && !first_event` | `0x9db94` | 同上 |

`wayland_display` 在 compositor **+32**（`meta_wayland_compositor_get_wayland_display` `ldr x0,[x0,#32]`）。`prepare` 里已有 `wl_display_flush_clients`（`WaylandEventSource+96`）。

8 s 窗：

| 文件 | Hz | gt50 | 要点 |
|------|----|------|------|
| `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-020215.json` | 105.7 | 7 | emit/apply：B-post-late 里 `apply`/`sched`/`emit` 都在洞末 +103–109；B-main 里 lab=`ppoll`、shell=`running` |
| `linux-mainline/out/display-stress/dagu-hole-pc-20260914-020319.json` | 111.5 | 5 | 3/5 洞 **两边主线程都在 `libc.so.6+0x95aec` `ppoll`** |
| `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-020532.json` | 109.6 | 7 | **`stsked==stgo==1754`**：`update_scheduled && event_queue` 早退整窗 0 次 |
| `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-020608.json` | 112.2 | 3 | **`sendcb==emit==kickoff`（897）**。B-post-late 本窗 0。一档 `apply`/`stsked` +5.5 而 `fcdisp` +72.7（钟已排、主线程晚 dispatch）。`sendcb_before_ms` 1.9–11.0（上一拍 callback 已发出） |
| `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-020718.json` | **103.8** | 4 | `toolkit-accessibility` 当场改 `false`（未重启 gnome-shell）：B-main 0，但 Hz 掉、B-kick-kernel×2 + B-post-late×1。已改回 `true` |

`clutter_stage_schedule_update` 早退不是这条洞。`emit` 入口空 list 也会进；`0x1673f0` 证明每拍都有一次真 `send_done`。B-post-late 不是「callback 没发出」：`sendcb` 在 T0 前 7–15 ms，`apply` 却要到 +98–107。

洞中 gdb（停进程，只采一帧）：

- gnome-shell 主线程：`libatspi.so.0` **+0x21808**（`dbus_connection_get_dispatch_status` 的 GSource `prepare`），`toolkit-accessibility` 当时为 `true`。抓痕 `linux-mainline/out/display-stress/dagu-bmain-stack-20260914-0207.json`。
- identity GTK `415498`：`recvmsg` → `wl_display_read_events` → libgtk-4 → `g_main_context_iteration`。

`affinity=system` 之后 B-kick-kernel **又出现**（atomic +6–8 ms，`tail_s` +86–199）。验收（kickoff≈120 且 `gt50=0`）没到。

---

## 32. 钟是 120Hz 且 `ready_time=now`；HUD 每帧 `set_text` 已限到 4Hz（2026-09-14 续）

活 frame clock（`x5=0x55cb1e88a0`，`schedule_update` `0x67714` 写入 `next_update_time_us`）：

| 字段 | 值 |
|------|-----|
| `refresh_rate` | **120.0** |
| `refresh_interval_us` | **8333** |
| `mode` | 0（FIXED） |
| `state`（窗末 peek） | 9（`DISPATCHED_TWO`） |

`dagu_rdyt` 洞里 `rdyt_delta_ms` 都是 **0**（`set_ready_time` 排的是 now，不是 +70 ms）。晚 `fcdisp` 不是算错下一拍。

`gdk_frame_clock_request_phase`（GTK `0x5733d0`）一档洞在 T0 **+0.5 ms** 就进了，`apply` 却到 +114：GTK 已经要画，合成器/提交仍空一截。该档 lab=`running`、shell=`ppoll`。

identity 实验室热路径每帧 `Gtk.Label.set_text`（ATK/AT-SPI）。改成 ≥250 ms 才更新 HUD，动画/滚动仍每 tick。只重开 `dagu-native-lab.py`，gnome-shell **413669** 没动。板上：`/usr/local/sbin/dagu-native-lab.py`。

| 窗 | 文件 | Hz | gt50 | kinds |
|----|------|----|------|-------|
| 改前（同探针） | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-021047.json` | 113.7 | 2 | other×1 + B-kick-kernel×1 |
| HUD 4Hz | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-021149.json` | **114.8** | **1** | B-post-late **0**，B-kick-kernel **0**，B-main×1（max 75.3） |
| 第二窗 | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-021213.json` | 114.7 | 2 | B-post-late **0**，B-kick-kernel **0**，B-main×2 |

第二窗一档 B-main：`apply`/`sched`/`rdyt` **+0.5**（now），`fcdisp`/`nview` **+78**；lab=`ppoll`，shell=`running`。GTK 已提交、钟已排，主线程 78 ms 才 dispatch。

验收（kickoff≈120 且 `gt50=0`）没到。约 115 Hz 还缺 ~5 Hz 的 16.6 ms 单帧跳过（不算 gt50）。

---

## 33. B-main 洞中主线程在 GJS `JS_GC`；clock priority / `JS_MaybeGC` 都不是交付（2026-09-14 续）

活 clutter `init_frame_clock_source`：`0x745d8` `mov w1,#0x96` 后 `bl g_source_set_priority`，clock GSource priority **150**（`CLUTTER_PRIORITY_REDRAW`）。Wayland 事件源是 `META_PRIORITY_EVENTS+1`=1。活对象 `clk=0x55cb1e88a0` `src=0x55cbc11f50` 当时 prio=150，`hz=120`，`mode=0`。

`g_source_set_priority(src, 0)`（gdb `call`，只改活 source）后 8 s：`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-021902.json` kickoff **115.3 Hz**，gt50=2，max 108.1。B-main 仍在（`apply`/`sched` +1.0，`fcdisp` +59，shell=`running`）。另出一档 B-kick-atomic-late（`nview`/`mgo` +5，`atomic` +107）。priority 0 没有消洞。

按「`schedule_update` 之后没有 `fcdisp`」冻主线程（`linux-mainline/scripts/dagu-bmain-freeze-bt.py`，抓痕 `linux-mainline/out/display-stress/dagu-bmain-freeze-bt-20260914-022120.json`）：

`g_main_loop` → GSource dispatch → **`JS_GC(JSContext*, JS::GCReason)`**（`libmozjs-140.so`）。

活 `libgjs.so.0.0.0` r-xp 当时 `0x7fb92c0000`，GSource 回调文件偏移：

| VA | insn |
|----|------|
| `0xa8638` | `str wzr,[x0,#88]` |
| `0xa8640` | `ldr x1,[x19,#408]` |
| `0xa8644` | `tbz w1,#17, skip` |
| `0xa8648` | `mov w1,#0x23`（`JS::GCReason` **35 = MEM_PRESSURE**） |
| `0xa864c` | `bl JS_GC@plt` stock `0x97fdf489` |

把 `0xa864c` 改成 `bl JS_MaybeGC@plt`（`0x97fdfc95`）后，同窗 kickoff **n=0**。随后 gnome-shell **413669** 全线程 `futex_wait`（含 KMS / JS Helper），DPU 无 kickoff。`JS_GC` 已写回 stock。`kill -9 413669` 后 GDM 重开 ubuntu 会话。不要再对这条 `JS_GC` 改 `JS_MaybeGC`，也不要再 gdb `call g_source_set_priority`（`set150` 曾 8 s timeout）。

新会话 gnome-shell **440934**，identity lab **442227**。磁盘 poke（infence / wakeup / `dri_flush` NOP）仍在。8 s `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-022450.json`：kickoff **108.3 Hz**，gt50=2，max 108.4。B-main×1 + B-post-late×1。B-main 里 shell=`running`。

验收没到。

---

## 34. skip-hammer 已否；`JS_GC`→增量 slice cave 未稳住 Type B（2026-09-14 续）

gnome-shell 仍是 **440934**。第二次冻栈 `linux-mainline/out/display-stress/dagu-bmain-freeze-bt-20260914-022750.json` 抓到两种 B-main：

1. `JS_GC` BIG_HAMMER（`libgjs+0xa8650`）
2. `clutter_actor_queue_redraw_with_clip` 风暴（116 ms 空档）

`0xa8644` `tbz` → `b a8670`（跳过 BIG_HAMMER，只走 `gjs_gc_if_needed`）后：`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-022729.json` kickoff **110.3 Hz**，gt50=3，max **175**。已 `restore-live`。脚本保持 restore：`linux-mainline/scripts/dagu-gjs-skip-hammer-install.sh`。不要再 apply。

活 `libgjs.so.0.0.0` `0xa864c` 改成 `b cave@0xb00a0`（4096 字节零洞，无 xref）。cave 对板上 `libmozjs-140.so.140.8.0` 反编译后直跳：

| 符号 | 文件偏移 |
|------|----------|
| `JS::IsIncrementalGCInProgress` | `0x61c6e0` |
| `JS::StartIncrementalGC` | `0x62dca0` |
| `JS::IncrementalGCSlice` | `0x62dda0` |
| `JS::SliceBudget::SliceBudget(TimeBudget)` | `0x60c1e0` |
| `TicksFromMilliseconds` | `0xbe3820` |
| `g_idle_add_full@plt` | `0x26d30` |

`JS_GC` 自己构造 unlimited SliceBudget（type=2），即使 `JSGC_INCREMENTAL_GC_ENABLED`（gjs key 5 = 1）也会一次跑完。`0x23` 在 mozjs 140 是 **`MEM_PRESSURE`**，不是可切片原因。cave 后改成 1 ms TimeBudget + `EAGER_ALLOC_TRIGGER`/`INTER_SLICE_GC`，未完成则 `g_idle_add_full(200)`，未完成不清 `m_force_gc`。只 `apply-live`，磁盘 so 未写。脚本：`linux-mainline/scripts/dagu-gjs-inc-slice-install.sh`。

| 窗 | 文件 | Hz | gt50 | kinds |
|----|------|----|------|-------|
| MEM_PRESSURE + 2 ms（第一窗） | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-023334.json` | **110.7** | **0** | holes **0**（未稳住） |
| 同 poke 第二窗 | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-023421.json` | 108.5 | 6 | B-main×3 + B-kick-kernel×2 + B-post-late×1 |
| EAGER + 1 ms | `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-023519.json` | 112.3 | 4 | B-main×1 + B-kick-kernel×1 + B-post-late×1 + other×1 |

第一窗 `gt50=0` 但 kickoff 不是 ≈120（缺 16.6 ms 单帧）。第二窗 Type B 回来。增量 cave **没有**把 B-main / B-post-late 钉死成 0。`JS_MaybeGC` / skip-hammer 不要再开。

验收（同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`）没到。

冻栈 `linux-mainline/out/display-stress/dagu-bmain-freeze-bt-20260914-023606.json`（增量 cave 仍在，113.6 ms）：主线程不在 `JS_GC`，在 `XFlush` → `recvmsg`（`libmutter-18.so` `0x125400 bl XFlush@plt`，X11 GSource prepare）。把 `0x125400` NOP 后：`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-023648.json` kickoff **110.1 Hz**，gt50=3，max **216.8**，B-main 仍在。已 `restore-live`。脚本保持 restore：`linux-mainline/scripts/dagu-mutter-xflush-install.sh`。不要再 apply。gdb 冻栈抓到的 `XFlush` 不能当主因（NOP 后更差）。

---

## 35. redraw 每矩形循环 / `schedule_update` wakeup 都已否；洞中多数在 `ppoll`（2026-09-14 续）

冻栈 `022750` 的 `queue_redraw_with_clip+288` 对上活 `libmutter-18.so.0.0.0` `meta_surface_actor_update_area`：`0x16109c bl queue_redraw_with_clip`，`0x1610a0 cmp` 后 `b.ne` 按 intersection 每个 cairo 矩形转一圈。空 unobscured / 空 intersection 仍是 stock（`0x160f74=0x34000320`，`0x161010=0x17ffffdc`），`libdagu-mutter-damage.so` 未加载。

把非空 intersection 从逐矩形改成一次 full-clip（`0x160ff8` `cbz` 目标 `0x161064` → `0x161014`）后：`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-023901.json` kickoff **104.9 Hz**，gt50=2，B-main 仍在。已 `restore-live`。脚本：`linux-mainline/scripts/dagu-mutter-update-area-onerect-install.sh`。不要再 apply。这和日常 270° 空 unobscured→整窗 destile 是同一类「多画」惩罚，不是 identity 的 Type B 主因。

无 gdb 的 PC 采样 `linux-mainline/out/display-stress/dagu-hole-pc-20260914-023919.json`（kickoff 112.3 Hz，gt50=3）：

| 洞 | shell | 活 PC |
|----|-------|--------|
| 108.4 ms | syscall **73 `ppoll`** 28/28 | `libc.so.6+0x95aec` |
| 91.7 ms | 两边都 `ppoll` | 同上 |
| 117.4 ms | `running`（`kstkeip` 采不到用户 PC） | lab 在 `ppoll` |

`running` 那档才是 GC / redraw；**多数 Type B 是钟已 `ready_time=now`、主线程却在 `ppoll` 里睡 90–110 ms**。

`clutter_frame_clock_schedule_update` 两条 `set_ready_time`（`0x67618 bl` / `0x67744 b`）后加 `g_main_context_wakeup(source+128)`（cave `0x61e40`）后：`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-024104.json` B-main **0**，但 kickoff **104.7 Hz**，gt50=3，B-post-late×2。已 `restore-live`。脚本：`linux-mainline/scripts/dagu-clutter-sched-wakeup-install.sh`。不要再 apply。和「无条件 `maybe_reschedule`」一样：分类变了、Hz 掉了。

活 poke 仍在：gjs 增量 cave（`0xa864c`）。XFlush / onerect / sched-wakeup 已撤。验收没到。

---

## 36. 洞中 `ppoll` 超时是数秒级；钟 `ready_time=-1` 且 timerfd 已撤（2026-09-14 续）

gnome-shell 仍是 **440934**，identity lab **442227**。gjs 增量 cave 仍活（`0xa864c` `b cave`）。探针：`linux-mainline/scripts/dagu-ppoll-timeout-probe.py`（`/proc/<pid>/syscall` 解 `ppoll` timespec + pollfd，并 peek 活 clock GSource）。

活 glib 2.88 对上的布局（主机 so `/tmp/dagu-so/libglib-2.0.so.0.8800.0`）：

| 项 | 值 |
|----|-----|
| `GSource.context` | `+32`（不是 mutter wakeup cave 用的 `+128`） |
| `ready_time` | `*(GSource+88)+16` |
| `SOURCE_BLOCKED` | flags `+0x2c` bit 6 |
| `g_poll` | `0x719a0` 尾跳 `poll@plt`（libc 再进 syscall 73） |
| `g_main_context_default` 槽 | glib VA `0x180a90` |

`libc.so.6+0x95aec` 是通用 `svc` 返回，不能单独当「这是 poll」。洞中 syscall 号才是 73。

clock GSource 挂在 **default context**（`g_source_attach(NULL)` @ clutter `0x745f4`；活对象 `ctx=0x55b669b1f0` 与 default 同一指针）。`clutter_frame_clock` 的 unix timerfd 在 GSource `+104`，活 fd **25**。clock source `prepare` @ clutter `0x701a0`：`ready_time<0` 时 `timerfd_settime` 撤成 `(0,0)`，`*timeout=-1`。

洞中采到的事实（不是「钟已 `ready_time=now`、poll 超时 100ms」）：

| 窗 | 文件 | Hz | gt50 | 洞里钟 | shell `ppoll` 剩余超时 | lab |
|----|------|----|------|--------|------------------------|-----|
| 8s | `linux-mainline/out/display-stress/dagu-ppoll-timeout-20260914-024541.json` | 109.8 | 2 | `ready=-1`，未 blocked | **~10 s**（10053 / 9573 ms） | （未采） |
| 12s | `linux-mainline/out/display-stress/dagu-ppoll-timeout-20260914-024731.json` | 111.3 | 3 | 两档 `-1`，一档已过期 | 一档剩余约 23 h；另两档 shell=`running` | running 或 `ppoll` 300–880 ms |
| 12s+PC | `linux-mainline/out/display-stress/dagu-ppoll-timeout-20260914-024815.json` | 107.7 | 6 | 五档 `-1`，一档过期 | ~5 s 或约 23 h | 多数 `ppoll` 500–880 ms |
| 8s+pollfd | `linux-mainline/out/display-stress/dagu-ppoll-timeout-20260914-024859.json` | 110.7 | 4 | 全档 `-1` | 2.0–6.1 s | `ppoll` 450–874 ms |

窗末 `timerfd` 25 `fdinfo`：`it_value=(0,0)` `it_interval=(0,0)`（已撤）。`settime flags=01`（`TFD_TIMER_ABSTIME`）。

洞里两边 pollfd（`events=POLLIN`，`revents=0`，没有可读）：

- gnome-shell：wakeup `eventfd`、若干 `timerfd`（含钟 fd 25）、`eventpoll`、unnamed `socket`；55 ms 那档多一个 `anon_inode:sync_file`。
- lab：`eventfd` + 两个 unnamed stream（inode `2080946` / `2078308`）。Wayland listen 在 compositor 的 `/run/user/1001/wayland-0`（inode `2080948`），不是 lab 这两个 inode。

100–220 ms 的空洞结束时，**不是**这次 `ppoll` 超时到点（超时还剩数秒到一天），而是某个 fd 先就绪。钟在这些洞里经常是 **未排**（`ready_time=-1`、timerfd 已撤），主循环按别的 GSource 算出 2–10 s / 更长超时。另有一档壳在 `running`、钟 `ready` 已过期数毫秒到十几毫秒（主线程没去 `fcdisp`）；`kstkeip` 采不到用户 PC。

验收（同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`）没到。

---

## 37. GTK commit 与 `schedule_update` state=9 只挂 pending（2026-09-14 续）

新 ubuntu 会话 gnome-shell **468357**（旧 440934 已不在）。identity 用 `linux-mainline/scripts/dagu-lab-identity-native.sh` 重开，lab **470723**（本窗 `videos=0`）。gjs 增量 cave 是 live-only，新进程里不在。磁盘 poke（infence / wakeup / `dri_flush`）仍在。

探针 `linux-mainline/scripts/dagu-gtk-commit-probe.py`：

整窗 **1:1**：`sendcb=apply=dec=gsk=qrender=updarea=kickoff`。不是 buffer `use_count` 卡死。`IncrementalGCSlice` / gjs cave 整窗 **0**。`XFlush` 很密（约 7 次/帧），NOP 已否。

洞内（旧会话 440934，`linux-mainline/out/display-stress/dagu-gtk-commit-20260914-025440.json`，108.7 Hz，gt50=5）常见顺序：

1. T0 前几毫秒：`gsk` / `apply` / `dec` / `sendcb`（上一拍已闭环）
2. T0+4–8 ms：又一次 `fcdisp`→`sendcb`→`gsk`→`apply`→`sched`
3. 之后 80–110 ms **两边 `ppoll`，没有第二次 `fcdisp`**

活 clutter `schedule_update` @ `0x675a0`：`state` 在 **+88**。`state==9`（`DISPATCHED_TWO`）走 `0x67644` `cmp #9` → `0x6764c` 只 `pending_reschedule=1`（+396）然后 `ret`，**不** `set_ready_time`。GTK `apply` 落在当拍 `after_update` / `maybe_reschedule` 之后时，钟保持 `ready_time=-1`，timerfd 保持撤，直到一次不会来的 present。

把 `0x67648` `b.ne 0x676bc` 改成 `b 0x676bc`（state 9 也算 deadline / `set_ready_time`）后：`linux-mainline/out/display-stress/dagu-gtk-commit-20260914-025646.json` kickoff **113.7 Hz**，gt50=2，`fcdisp` **208682**（空 dispatch）。已 `restore-live`。脚本保持 restore：`linux-mainline/scripts/dagu-clutter-sched-dispatched-install.sh`。不要再 apply。与无条件 `maybe_reschedule` / sched-wakeup 同类。

验收没到。

---

## 38. state=9 强改 SCHEDULED 崩壳；同一只钟；IDLE 泵一帧无效（2026-09-14 续）

新 ubuntu 会话在本轮被两刀打崩后，GDM 重开 **479005**，再崩后 **486179**。identity 用 `linux-mainline/scripts/dagu-lab-identity-native.sh` 重开（lab **482421** / **487814**）。`0x67648` 新进程是磁盘 stock `0x540003a1`。gjs 增量 cave 不在。

### 已否：state=9 → SCHEDULED（崩）

`DISPATCHED_TWO`（state 9）上两帧还在飞。`schedule_update` 只挂 `pending` 是为了防三缓冲重入。把 `0x67648` 改成 `b.eq 0x67604`（`set_ready_time(now)` + `state=2`）或 cave 做同样的事：

- `linux-mainline/scripts/dagu-clutter-sched-state9-now-install.sh` — apply 后 gnome-shell **468357** 立刻没了
- `linux-mainline/scripts/dagu-clutter-sched-state9-cave-install.sh` — apply 后 **475152** 立刻没了

**不要再 apply。** 空 dispatch 风暴（`b 0x676bc`）和崩壳是同一条状态机：state 9 必须等 `notify_presented` 落到 `DISPATCHED_ONE`。

### 同一只钟

探针 `linux-mainline/scripts/dagu-clock-same-probe.py`，抓痕 `linux-mainline/out/display-stress/dagu-clock-same-20260914-030332.json`（stock，kickoff **116.27 Hz**，gt50=2）：

整窗只有 **一只** clutter 钟 `0x55a4804b50`。`sched` / `npresent` / `maybe_reschedule` / `fcdisp` 都是它。`inhibit_count` 全程 0。

两类 ≥50 ms 洞：

1. **等 present（~75 ms）**：T0 前 `sched` state=9 挂 pending → `npresent` TWO→ONE 吃 pending → `fcdisp` state=6。洞内 **0** 事件。下一拍 `npresent` 在 T0+73。软件已按时 schedule，卡在这一帧的 present。
2. **IDLE + GTK 晚（~117 ms，有一窗正好 100.0）**：连续两次 present，`pending=0`，`maybe_reschedule` 把钟落到 **IDLE**。之后 90–110 ms 没有 `sched`，直到 GTK `schedule_update` 从 state=1 再来。`dagu-native-lab.py` 的动画只靠 `Gtk.Widget.add_tick_callback`；GDK Wayland 在 `wl_surface.frame` 未到时 `gdk_surface_freeze_updates`（`awaiting_frame_frozen`）。Mutter 空闲后不再 dispatch，也就不再发 frame callback，tick 停，直到某个 ~100 ms 源把 GTK 叫醒。

`npresent` 与 `kickoff` 仍约 1:1（本窗 929）。vblank 继续扫旧 fb 的判定不变。

### 已否：IDLE 路径强挂 pending（泵一帧）

`notify_presented` state=5→IDLE @ clutter `0x683d8`（`mov x0,x19` 后 `bl maybe_reschedule`）。cave `0x61e40` 在 `maybe_reschedule` 前写 `pending=1`。

第一刀 `str` 编码写成 `b9018c60`（Rn=x3），踩内存，**479005** 崩。正确是 `b9018e60`（`str w0,[x19,#396]`）。

第二刀编码对上、壳还在：`linux-mainline/out/display-stress/dagu-clock-same-20260914-030622.json` kickoff **114.97 Hz**，gt50=2（100.0 / 123.9）。IDLE 洞里确实立刻多了一次 `fcdisp` state=2，但 `iface->frame` 回了 **IDLE**（`notify_ready`，不是 present），钟再次 idle，GTK 仍晚 ~93 ms。已 `restore-live`。脚本：`linux-mainline/scripts/dagu-clutter-idle-pump-install.sh`。不要再 apply。

### `sendcb` 跟 dispatch，不跟 present

`linux-mainline/out/display-stress/dagu-clock-same-20260914-030751.json`（stock idle-pump 已撤）：`sendcb=kickoff=fcdisp=897`。`sendcb` 在 `fcdisp` 之后几毫秒（maybe_post），**present→IDLE 那一路没有 `sendcb`**。IDLE 洞里 T0+5 ms present 落到 state=1 后，要到 T0+100 ms 才有下一次 `sched`/`sendcb`。GDK 在等 `wl_surface.frame` 才 `thaw_updates`；mutter 空闲后不再 dispatch 就不再发 callback，tick 停约 100 ms。

下一刀：present→IDLE 时补发 frame callback（或对上 GDK freeze 超时），不要再改 state 9→2。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 39. GDK after_paint 不解冻：81 Hz / gt50=27（2026-09-14 续）

活 `libgtk-4.so.1.2200.4` `on_frame_clock_after_paint` @ `0x518c80`：`frame_callback` 且 `pending_frame_counter` 对得上就 `orr #0x20`（`awaiting_frame_frozen`）并尾跳 `gdk_surface_freeze_updates` @ `0x5a31b0`。

只 poke identity lab（**487814**，不碰 gnome-shell）：`0x518cc8` `cbz` → `b` 直接 `ret`。壳与 lab 都还在。

`linux-mainline/out/display-stress/dagu-clock-same-20260914-031134.json`：kickoff **81.49 Hz**，gt50=**27**，max 158。`sendcb` 565 < kickoff 635。无 vsync 的 commit 把 compositor destile。已 `restore-live`。脚本：`linux-mainline/scripts/dagu-gdk-nofreeze-install.sh`。不要再 apply。

结论：Type B 的 100 ms 洞**不是**「GTK 冻住所以不 commit，解开就丝滑」。freeze 是必要的 pacing；解开比 stock（116 Hz / gt50=2）差一截。不要再改 GDK freeze / `0x169668` 一律 emit。

ubuntu **486179** / lab **487814** 仍在，clutter `0x67648`/`0x683d8` 与 GDK `0x518cc8` 均为 stock。`tracing_on=1`。验收没到。

---

## 40. 100 ms 不是 GTK 定时器：kernel flip 准时、nview 晚 95 ms（2026-09-14 续）

活 so 对过：`gdk_surface_thaw_updates` @ GTK `0x5a4da0`；`on_frame_clock_after_paint` 仍 stock `0x518cc8=0xb40000c0`。GTK 里 `g_timeout_add(100)` 只在 drag / editable，不是 frame clock。`gdk_frame_clock_get_refresh_info` 默认间隔是 **16667 µs（60 Hz）**，不是 100 ms。

探针 `linux-mainline/scripts/dagu-lab-wake-probe.py`，抓痕 `linux-mainline/out/display-stress/dagu-lab-wake-20260914-031701.json`（112.08 Hz / gt50=3）：

- `thaw=896` 且 **`thaw_who` 全是 `wl_frame_cb`（`0x518a44`）**，没有 force_commit / idle 旁路
- `sendcb=thaw=gsk=kickoff≈896`，`reqph=2688`（每帧 3 个 phase）
- mutter 空帧 GSource `0x167440` **一次都没 dispatch**
- 本窗三个 ≥50 ms 洞都是 **等 present**：GTK 在 T0 前已 `sendcb→thaw→reqph→gsk`，钟在 state=9，下一拍 `npresent` 晚 65–245 ms

探针 `linux-mainline/scripts/dagu-present-late-probe.py`，抓痕 `linux-mainline/out/display-stress/dagu-present-late-20260914-031840.json`（117.24 Hz / gt50=1，洞 100.2）：

| 源 | n | Hz | gt50 |
|---|---|---|---|
| `dpu_enc_kickoff` | 937 | 117.24 | 1（100.2） |
| `dpu_crtc_complete_flip` | 937 | 117.25 | 1（100.0） |
| `dpu_crtc_vblank_cb` | 960 | **120.13** | **0** |

该 100.2 ms 洞：vblank 仍按 ~8.33 ms 走了 **12** 拍。`atomic` 在 T0−0.31，`complete_flip` 在 **T0+2.57（准时）**，`nview`/`npresent` 在 **T0+97**。软件在 T0−1.75 已 `sched` state=9 `pending=1`。Type B：flip 准时，用户态 present 晚 ~95 ms。

`linux-mainline/scripts/dagu-ppoll-timeout-probe.py` 同型洞（`linux-mainline/out/display-stress/dagu-ppoll-timeout-20260914-031920.json`）：gnome-shell 主线程在 `ppoll`，超时 **2–6 s**（不是 100 ms），clutter 钟 `ready_time=-1`。主线程 poll 集没有 `/dev/dri/card0`（card0 是 fd 12–15）。KMS 线程 **486196** 的 ppoll 才是 `eventfd` + **`/dev/dri/card0`** + `timerfd`。

仍在的磁盘 poke（不要当新刀叠）：infence skip-poll、wakeup cave、`dri_flush` NOP、`default_affinity_scope=system`。不要再 apply GDK 解冻 / state9→2 / IDLE pending 泵 / `0x169668` 一律 emit。

`linux-mainline/scripts/dagu-bmain-probe.py` 同会话（探针本身把 Hz 打到 108.71 / gt50=7，**不当基线**）`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-032118.json` 把洞拆成三类：

1. **B-post-late**：`flip`/`nview`/`inv` 在 T0+5 已到，GTK `reqph` 却在 **+98**，且这一拍的 `sendcb` 更晚（+109）。GTK **没等 frame callback** 就 `request_phase`，才是「~100 ms 谁叫醒」：不是 mutter empty-frame，也不是 `g_timeout_add(100)`。
2. **B-main**：`qcb`/`inv` 第一次在 +2，`nview` 要等第二次 `inv`（+62）。主线程洞中 `running`，不是 ppoll。wakeup cave 仍在，这条还在。
3. **B-kick-kernel**：`atomic` 在 +8～+10 已提交，下一拍 kickoff 仍晚 86–109。`default_affinity_scope=system` 仍在，这条复发。

下一刀只改能验收的一处：B-post-late 要对上 GTK 在无 `sendcb` 时谁调 `request_phase`（idle clock / tick）；不要再解冻。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 41. infence skip-poll restore 更差；轻窗洞是等 present（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。只 live restore `0x1bd9d8`：`b update_ready`（`0x1400000a`）→ stock `mov w1,#1`（`0x52800021`）。`0x1bd9ac` 保持 stock `tbnz` `0x37f802b4`（不要恢复旧无条件跳、会关 DISABLE）。

`linux-mainline/scripts/dagu-present-late-probe.py` 抓痕 `linux-mainline/out/display-stress/dagu-present-late-20260914-032434.json`：kickoff **111.24 Hz**，gt50=**5**（112.9 / 109.6 / 108.5 / 108.3 / 66.8）。比 skip-poll 在时的轻窗（117.24 / gt50=1）差。vblank 仍 120.13 / gt50=0。洞里常见 `atomic` 在 T0−0.3，`nview` +61～+102。已立刻 live 写回 `0x1400000a`。**不要再 restore skip-poll。**

轻探针 `linux-mainline/scripts/dagu-lab-wake-probe.py` `linux-mainline/out/display-stress/dagu-lab-wake-20260914-032320.json`（110.88 Hz / gt50=4）：洞内几乎没有 `reqph`，GTK 在 T0 前已画完。`reqph_who` 只有正常三元组（phase 16/4/8），没有 idle/timeout 旁路。上一轮「对上无 sendcb 的 reqph」在轻窗上没复现；100 ms 也不是 GTK `g_timeout_add`。

wakeup cave 仍在：活 so `queue_callback` mutex `+0x60`、`callbacks +136`、`needs_flush +144`、`main_context +128`，cave `ldr x0,[x19,#128]` + `g_main_context_wakeup` 对得上。`dri_flush` NOP（`0x1cf740=mov x3,#0` / `0x1cf74c=nop`）仍在。

下一刀：对 `drmModeAtomicCommit` / `drmHandleEvent` 的 fd 和两条 `invoke` 的 tid（KMS vs 主线程）打轻探针，不要上重 `dagu-bmain-probe`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 42. fd 已对上；轻窗洞是 nview 准时后不 post，或主线程第二条 inv 晚（2026-09-14 续）

探针 `linux-mainline/scripts/dagu-inv-fd-probe.py`，抓痕 `linux-mainline/out/display-stress/dagu-inv-fd-20260914-032853.json`（探针本身 106.66 Hz / gt50=4，不当基线）：

| 项 | 值 |
|---|---|
| `atomic` fd | **12**（852/852） |
| `drmHandleEvent` fd | **12**（853/853），tid=KMS **486196** |
| `inv` | 853 KMS + 853 主线程，1:1 |
| `nview` | **全部**主线程 486179 |

四个 `/dev/dri/card0`（fd 12–15）里，commit 与 page-flip event 都走 fd 12。**不是 fd 错位。**

同窗 4 个 ≥50 ms 洞：

1. **B-kick-or-post**（100.3 / 110.1）：`nview` 在 T0+6 已到，下一记 `atomic` 要 +8.5（已 post，kickoff 仍晚）或 +99（`next_frame==NULL`，没 post）。
2. **other / B-kick-kernel**（108.1）：`atomic` 在 T0−0.5，下一记 `complete_flip` 到 +106。
3. **B-main**（108.4）：`complete_flip` / KMS `hev` / `qcb` / 第一条 `inv` 在 +2.3，主线程第二条 `inv` 与 `nview` 在 **+103**。wakeup cave 仍在。

`maybe_post_if_gl_finished` @ `0x1c4380`：`next==NULL` 在 `0x1c4388` 直接 `ret`。`CLUTTER_FRAME_RESULT_PENDING_PRESENTED=0` / `IDLE=1` / `IGNORED=2`。after_update `0x169668` `cbz` 只对 PENDING 立刻 emit；IDLE 走 deadline，空帧 GSource `0x167440` 轻窗仍 0 次。

已否：live `0x169668` `cbz`→`tbz w0,#1`（PENDING|IDLE 都立刻 emit，不动 IGNORED）。`linux-mainline/out/display-stress/dagu-present-late-20260914-033157.json` kickoff **108.36 Hz**，gt50=5，max **247.8**。已 restore-live `0x34000220`。不要再 apply，也不要再 `b emit`（`dagu-mutter-framecb-now-install.sh`）。

ubuntu **486179** / lab **487814** 仍在。skip-poll / wakeup / `dri_flush` NOP / `affinity=system` 仍在。`tracing_on=1`。验收没到。

下一刀：B-main 要对上主线程在 qcb 已入队后 100 ms 在忙什么（hole PC，不要 SIGSTOP 崩壳）；B-kick 是 `atomic` 已提交、kworker 晚开工复发。不要再改 after_update emit / skip-poll / GDK 解冻。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 43. 洞中 KMS 在 poll card0；主线程要么 ppoll 6–9s，要么 running；JS_GC / can_recurse 已否（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。

`linux-mainline/scripts/dagu-hole-pc-sample.py` `linux-mainline/out/display-stress/dagu-hole-pc-20260914-033421.json`（114.51 Hz / gt50=2）和 `...-033545.json`（110.34 / gt50=4）：**全部** ≥50 ms 洞 `complete_flip` 在 T0+3～+6（Type B）。主线程：

- 多数洞：syscall **73 ppoll**，`wchan=poll_schedule_timeout`，超时 **6–9.5 s**，nfds=14–15。不是 100 ms timer。
- 少数洞：整段 `running`，`kstkeip` 采不到用户 PC。

KMS **486196**（`/tmp/dagu-kms-hole-sample.py` → `linux-mainline/out/display-stress/dagu-kms-hole-*.json`）：洞中 100% 也在 ppoll。活 poll 集是 **eventfd 11 + `/dev/dri/card0` fd 12 + timerfd 100**，timeout 指针 NULL（无限等）。KMS **在 poll card0**；flip 准时后仍睡，说明要么 event 已在 +4 被吃掉、之后在等下一记（nview 准时 / B-kick），要么 fd 12 当时不可读。

`JS_GC`（活 gjs `0xa864c` 仍是 stock `bl`）整窗 **1 次**，8 个洞里只有 1 个沾边。`linux-mainline/out/display-stress/dagu-gc-hole-*.json`。不要再 apply `dagu-gjs-inc-slice-install.sh` / MaybeGC。

已否：wakeup cave 里给 callback source `flags|=G_SOURCE_CAN_RECURSE`（`+0x2c` bit1）。`linux-mainline/out/display-stress/dagu-present-late-20260914-033859.json` **112.42 Hz / gt50=4**。洞里常见 nview/+atomic 已在 +6～+8，下一记 kickoff 仍晚（B-kick）。已 restore 回只 wakeup 的 cave。不要再叠 can_recurse。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` 仍在。`tracing_on=1`。验收没到。

下一刀：B-kick（`atomic` +8 已提交、kickoff 晚）和「nview 准时、`next==NULL` 不 post」。不要再 JS_GC / can_recurse / after_update emit / skip-poll restore。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 44. wakeup(NULL→default) 已否；qcb 准时仍 nview 晚 85 ms（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。GLib 2.88 `g_main_context_wakeup` @ `0x5cee4`：`x0==NULL` 走 `g_main_context_default`。crtc_frame 的 qcb 用 KMS `thread_context`（`+128`），onscreen 用 default。只 live 加长 wakeup cave：`set_ready_time` + `wakeup(+128)` + `wakeup(NULL)`（`0x1d6f24 mov x0,#0` / `0x1d6f28 bl wakeup`）。没写磁盘。

`linux-mainline/scripts/dagu-present-late-probe.py` 加了 `dagu_qcb` @ `0x1d6e40`。抓痕 `linux-mainline/out/display-stress/dagu-present-late-20260914-034616.json`：kickoff **114.58 Hz**，gt50=**3**（105.7 / 101.0 / 92.8）。vblank 仍 120.13 / gt50=0。`qcb=4580`（每 flip 约 5 次）。已 restore 回只 `wakeup(+128)`。**不要再叠 wakeup(NULL)。**

同窗三个 ≥50 ms 洞：

1. **B-kick**（105.7 / 101.0）：`qcb`/`nview`/`mpost` 在 T0+5，`atomic` 在 +8，下一记 kickoff 仍晚。
2. **B-main / Type B**（92.8）：`complete_flip` 在 +4.61，`qcb` 在 **+4.68 / +4.70**（已入队），`nview`/`mpost` 要到 **+89.7**。default wakeup 没把主线程这条 invoke 提前。

所以「主线程 ppoll 6–9 s 是因为 +128 叫醒了 KMS 没叫醒 default」不成立。qcb 已发生，主线程 85 ms 没跑 `notify_view_crtc_presented`。不要再叠 cave wakeup。

`cpu_intensive_thresh_us=1000000`，`power_efficient=Y`，板上无 cpuidle sysfs。`system_unbound_wq` 仍是 page-flip worker。

ubuntu **486179** / lab **487814** 仍在。skip-poll / 只-wakeup cave / `dri_flush` NOP / `affinity=system` 仍在。`tracing_on=1`。验收没到。

下一刀：B-kick（atomic +8 已提交）和「qcb 已入队、主线程 85 ms 不 nview」。不要再 wakeup(NULL) / can_recurse / after_update emit / skip-poll restore / JS_GC。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

`power_efficient` sysfs 是 `-r--r--r--`，改不了。`commit_work` = `ffffffda6f79dda0`。探针 `linux-mainline/scripts/dagu-wq-commit-probe.py`，抓痕 `linux-mainline/out/display-stress/dagu-wq-commit-20260914-034751.json`（探针本身 111.5 Hz / gt50=4，不当基线）：`atomic=queue=exe_start=kickoff=891`（1:1）。拆洞内 `dt>2`：

| 洞 | atomic | queue | exe_start | q→exe | 形态 |
|----|--------|-------|-----------|-------|------|
| 108.5 / 108.5 / 108.6 | **+108** | +108 | +108 | 0.02 | 用户态没 commit，不是 kworker |
| 112.0 | **+4.76** | +4.84 | **+111.77** | **106.93** | 真 B-kick：work 已 queue，worker 晚 107 ms |

三种洞都还在：maybe_post 整段不来、qcb 准时 nview 晚、queue 准时 execute 晚。`affinity=system` 消不掉最后一种。不要再 `chrt` 全部 `kworker/u32`。

---

## 45. qcb→nview 间隙 PC：主洞是 nview 准时后不 post；next==NULL emit 已否（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。`dri_flush` NOP 仍在 Mesa `libgallium-26.0.8-1ubuntu0.3.so`（基址 `0x7f00ea0000`）`0x1cf740` / `0x1cf74c`，不是 mutter。wakeup cave 只 `wakeup(+128)`。`affinity=system`。`tracing_on=1`。

探针 `linux-mainline/scripts/dagu-qcb-gap-sample.py` 现在在 **qcb 后、nview/atomic 前** 采主线程 syscall / wchan / poll 集。抓痕 `linux-mainline/out/display-stress/dagu-qcb-gap-20260914-035535.json`（探针本身 107.72 Hz / gt50=5，不当基线）：

| 洞 | kind | nview | atomic | 间隙里主线程 |
|----|------|-------|--------|--------------|
| 108.5 / 108.1 / 224.8 | **nview-no-post** ×3 | **+4.4～+5.7** | **+108 / +224** | 几乎全程 **ppoll**，timeout 1–8 s，PC=`libc+0x95aec` |
| 88.2 | nview-no-post | +5.76 | +87.82 | **running** 73/74（`kstkeip` 采不到用户 PC） |
| 66.5 | qcb-early-nview-late | **+64** | +66 | **running** 42/43，1 次 futex |

主线程 poll 集（14 fds）：eventfd **3**、若干 timerfd / eventpoll / socket / pipe **110**。**没有** `/dev/dri/card0`。所以 B-main 再叠 wakeup 也改变不了「nview 已经到了、没有 next 可 post」。

活 so 对上：`MetaOnscreenNative.next_frame` **+88**，`view` **+136**，`render_source` **+144**。`maybe_post_if_gl` @ `0x1c4380` 在 `0x1c4388` `cbz x1, 0x1c4404 ret`。uprobe `ifgl`：onscreen `0x55a24240c0`，`next=NULL`，`[onscreen+136]=0x559f139120`（与 `emit` 的 x1 同一只 view）。`emit_frame_callbacks_for_stage_view` @ `0x167340` 的 x0 整窗都是 compositor `0x559f0eaeb0`。

已试：`0x1c4404 ret` → cave `0x1d2b80`（`ldr view; mov compositor; bl 0x167340`）。脚本 `linux-mainline/scripts/dagu-mutter-null-next-emit-install.sh`（只 live ubuntu，不写磁盘）。抓痕 `linux-mainline/out/display-stress/dagu-present-late-20260914-035828.json`：kickoff **113.73 Hz**，gt50=**2**（108.3 / 108.4），vblank 仍 120.13 / gt50=0，`fcdisp=kickoff=909`（不是空风暴）。两个洞仍是 **nview +5.6、sched +104**（钟 state=1 IDLE）。present 当下 `frame_callback_surfaces` 多半还是空的：GTK 还在画下一帧、还没 `wl_surface.frame`。emit 是空转。已 restore `0x1c4404=ret`、cave 清零。**不要再叠 next==NULL 立刻 emit。**

`queue_frame_callbacks` 入口在活 so 是 vfunc（`0x1653c4` / `0x16eee0` / `0x16ef60` 整窗 0 次）。§46 说明 **不要** 再往「GTK 入队后再 schedule」上叠：emit/sendcb/GTK frame-cb/thaw 已经 1:1，主洞回到 nview 晚。

验收仍没到。同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 46. emit/sendcb/thaw 已 1:1；主洞仍是 nview 晚或 atomic 后 kickoff 晚（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。`0x1c4404` 已是 stock `ret`。wakeup / skip-poll / `dri_flush` NOP / `affinity=system` 仍在。`tracing_on=1`。

探针 `linux-mainline/scripts/dagu-addcb-probe.py`：

- `linux-mainline/out/display-stress/dagu-addcb-20260914-040123.json`（117.05 Hz / gt50=1）：`0x16eee0` 整窗 **0** 次。`emit=thaw=apaint=kickoff`。唯一洞 nview +7.1，thaw +98，emit +107（这一窗像 GTK 晚醒；不当唯一模型）。
- `linux-mainline/out/display-stress/dagu-addcb-20260914-040323.json`（111.7 Hz / gt50=3）：`emit=sendcb@0x1673f0=fcb@GTK 0x518a40=thaw=apaint=atomic=nview=893` **1:1**。view-primary **没有** 吞掉 identity 的 sendcb。GTK 收到 frame-cb 就立刻 thaw。

同窗三个 ≥50 ms 洞：

| 洞 | 分类 | 证据 |
|----|------|------|
| 116.6 | **Type B / nview 晚** | flip +6.91，emit/sendcb/thaw **+0.6**，apaint +3.8（GTK 已在动），**nview +115.5**，atomic +116 |
| 158.4 | **Type B / nview 晚** | flip +6.98，nview/emit/thaw/atomic 都在 **+157** |
| 99.9 | **B-kick**（误标 nview-no-post） | nview/emit/thaw +8，**atomic +16.3**，下一记 kickoff +99.9 |

所以「GTK 入队 frame callback 后再拉钟 / 空源」对不上当前主洞：sendcb 已经发出，GTK 已经 thaw。缺的是主线程晚跑 `notify_view_crtc_presented`，或 `atomic` 已提交、kickoff 仍晚。`queue_callback` 里 x19 是 callback source：mutex +96、callbacks +136、needs_flush +144、cave `wakeup([x19,#128])` 就是 `main_context`（GSource 大 96）。GLib `g_source_get_context` 读的是 source **+32**，和 +128 应是同一只 context。不要再叠 wakeup(NULL) / next==NULL emit / GDK 解冻 / after_update IDLE emit。

下一刀回 **B-main**（qcb 已入队、主线程 100 ms 不 nview；GTK 已解锁的那一档尤其能排除「在等 sendcb」）。B-kick 仍不要 `chrt` 全员 kworker。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 47. `callback_source` 无 `.check`；补上也不提前主线程 dispatch（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。活 `libmutter-18.so.0.0.0` 对上：

| 符号 | 文件偏移 | 活 opcode / 指针 |
|------|----------|------------------|
| `callback_source_prepare` | `0x1d37b0` | `*timeout=-1`，`return !!callbacks`（`+136`） |
| `callback_source_check` | **NULL**（`GSourceFuncs` @ `0x2b2da8+8`） | GLib 文档：NULL check ≡ 恒 FALSE |
| `callback_source_dispatch` | `0x1d5d00` | steal `+136` 再跑闭包 |
| `queue_callback` | `0x1d6e40` | cave 仍 `set_ready_time(0)` + `wakeup(+128)` |
| GLib `g_main_context_wakeup` | `libglib-2.0.so.0.8800.0` `0x5cee0` | `[ctx+152]` → `g_wakeup_signal` write eventfd |
| default context wakeup fd | **eventfd 3**（`GWakeup+4 == -1`） | 主线程 ppoll 14 fds **含 fd 3**，超时秒级 |

探针 `linux-mainline/scripts/dagu-cbs-dispatch-probe.py`，抓痕 `linux-mainline/out/display-stress/dagu-cbs-dispatch-20260914-040918.json`（106.86 Hz / gt50=5，探针不当基线）：

- `inv` : `nview` ≈ 2:1。KMS 那次 `dispatch`/`inv` 在 flip **+5 ms**；主线程那次 `dispatch`/`inv`/`nview` 在 **+84～+102**。
- 不是「qcb 没入队」，是 **default 上的 `callback_source_dispatch` 晚 80–100 ms**。

已试：cave `0x1d2b80` 写 `gboolean check(GSource*){ return !!callbacks; }`，`funcs.check` 填 cave。脚本 `linux-mainline/scripts/dagu-mutter-cbs-check-install.sh`（只 live，不写磁盘）。抓痕 `linux-mainline/out/display-stress/dagu-cbs-dispatch-20260914-041023.json`：kickoff **113.05 Hz**，gt50=**4**（116.8 / 111.4 / 108.2 / 69.9）。形态不变：qcb +4.6，KMS `inv` +4.7，主线程 `nview` +107。已 restore `funcs.check=NULL`、cave 清零。**不要再叠 NULL-check cave。**

default 的 wakeup 就是主线程正在 poll 的 eventfd 3；再叠 wakeup / `.check` 都没把主线程那次 dispatch 提前。

又试：只把 `0x1d6edc` `mov x1,#0` 改成 `mov x1,#1`（`set_ready_time(1)`，避免 GLib 把 `ready_time==0` 当未改）。抓痕 `linux-mainline/out/display-stress/dagu-cbs-dispatch-20260914-041321.json`：kickoff **109.11 Hz**，gt50=**6**，更差。已写回 `0xd2800001`。**不要再改 `set_ready_time` 的立即值。**

`0x1c4404` 仍是 stock `ret`。wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` 仍在。`tracing_on=1`。验收没到。

---

## 48. nview 跟的是显式 default 的 qcb；真 CAN_RECURSE 也不提前 dispatch（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。`queue_callback` 入口 `x1` 三分（抓痕 `linux-mainline/out/display-stress/dagu-cbs-dispatch-20260914-041747.json`，kick=831）：

| `x1` | 次数 | 谁 |
|------|------|----|
| `0x0` | = kickoff | onscreen C 源码传 NULL，函数里再换成 default |
| `0x559e7e61f0` | 2× kick | **显式 default**（nview 走这只 source） |
| `0x559ea966a0` | 2× kick | KMS `thread_context` |

B-main 洞里 KMS + 显式 default 的 qcb 已经在 flip **+4.6 ms** 入队；KMS 那次 `inv` 同期到；`nview` 要到 **+86～+106**。只盯 `x1=0` 的 `dagu-qcb-now-sample` 会对错对象。

活 callback source（uprobe `0x1d6ee4`，必须在 `mov x0,x19` **之后**）：

| source | context | prio | flags | id |
|--------|---------|------|-------|----|
| default `0x559ec1ace0` | `0x559e7e61f0` | **-99** | **0x3**（稳态，idle 也是） | 16 |
| KMS `0x559e7f1030` | `0x559ea966a0` | -99 | 0x3 | 2 |

`flags=0x3` = hook `ACTIVE|IN_CALL`。GLib 2.88 `G_SOURCE_CAN_RECURSE` 是 **bit5 = 0x20**（`G_HOOK_FLAG_USER_SHIFT=4`），不是以前 cave 叠过的 +0x2c bit1。bit6 `BLOCKED` 没置。

已试：只把 default source `+44` 写成 `0x23`（真 CAN_RECURSE）。抓痕 `linux-mainline/out/display-stress/dagu-cbs-dispatch-20260914-041923.json`：kickoff **109.61 Hz**，gt50=**5**（233 / 110 / 108.3 / 84.4 / 67.1）。形态不变。已写回 `0x3`。**不要再叠 bit5 CAN_RECURSE，也不要再叠错位的 bit1。**

同窗洞已拆开：108 / 110 ms 是 nview **+4.4**、atomic **+108**（B-kick）；67 ms 才是 qcb default +5.5、nview +63（B-main）。不要再补 `.check`、不要再改 `set_ready_time` 立即值、不要再 wakeup(NULL)。

探针：`linux-mainline/scripts/dagu-qcb-ctx-sample.py`（default-x1 当下读 `GMainContext.owner` / `waiters` / `in_check`）。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 49. owner 一直是主线程；没有任何 GSource dispatch ≥2ms；prio=-200 已否（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。`flags` 已从 `0x23` 写回 `0x3`。

GLib 2.88 活 `libglib-2.0.so.0.8800.0` 对上：

| 字段 | 偏移 | 依据 |
|------|------|------|
| `owner` | ctx **+24** | `g_main_context_is_owner` `ldr x21,[x19,#24]` |
| `owner_count` | **+32** | `g_main_context_acquire` |
| `waiters` | **+40** | release 路径 `g_slist` |
| `ref` | **+48** | wakeup `ldar [ctx,#0x30]` |
| `in_check_or_prepare` | **+112** | prepare 非 0 就打 log |
| `wakeup` | **+152** | 已对上 eventfd 3 |
| GSource `name` | **+80** | `g_source_get_name` |
| dispatch `blr` | **`0x60b34`** | `x28`=source；之后 `g_source_get_name` |

抓痕 `linux-mainline/out/display-stress/dagu-qcb-ctx-20260914-042239.json`（探针 108.36 Hz / gt50=6，不当基线）：1732 次 default-x1 qcb **全部** `owner=0x559e7dafe0`（与 idle 同一只主线程 GThread）、`waiters=0`、`ocnt=2`。没有第二只线程占着 default。

B-main 洞（109.5 ms，nview +100.7）：qcb default 在 **-0.22 / +7.47** 时已经 `cb≠0`、`flush=1`、`ready=0`、`efd3=4～5`，主线程 **running**。同一只 list 头挂了 7.7 ms 都没被 `callback_source_dispatch` steal。不是「没 wakeup / 错 context / 别人持锁」。

抓痕 `linux-mainline/out/display-stress/dagu-gsrc-long-20260914-042449.json`：主线程 8 s 内 **114962** 次 `g_main_context_dispatch` 里的 `blr`（`0x60b34`/`0x60b38` 成对），**0 次 ≥2 ms**。B-main 不是卡在某一只 GSource 的 dispatch。探针本身把 kickoff 打到 97 Hz，qcb 事件被冲掉，只当「没有长 dispatch」用。

GLib 单轮 dispatch 用 `source.prio > first_prio` 截断（`0x60ab8 cmp` / `0x60abc b.gt`）。假设 -100 的源每轮都 ready、把 -99 的 callback 挤掉。已试：只改 default source `+40` **-99 → -200**。抓痕 `linux-mainline/out/display-stress/dagu-cbs-dispatch-20260914-042521.json`：kickoff **109.52 Hz**，gt50=**5**（209 / 110 / 107 / 105 / 82）。5 个洞里 4 个 nview 已在 +2～+7（B-kick），1 个仍是 qcb +3.7、nview +77（B-main）。已写回 **-99**。**不要再改 callback source priority。**

还没闭合：主线程 running、cb 已挂、ready=0，但 90 ms 不进 `callback_source_dispatch`。`0x60b34` 后来对上是 **prepare** 不是 dispatch（§50）。不要再叠 CAN_RECURSE / `.check` / `set_ready_time` 立即值 / wakeup(NULL) / prio。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` 仍在。`tracing_on=1`。验收没到。

---

## 50. `0x60b34` 是 prepare；NOP 优先级截断过不了轻窗验收（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。§49 的 114962 次 `blr` 对上的是 `GSourceFuncs.prepare`（`[source+16]+0`），不是 dispatch。真 dispatch 在 `g_main_context_dispatch` 内部 **`0x606f4 blr x27`**（`funcs+16`），只走 `ctx+64` 那份 `pending_dispatches`。

prepare 走访里 `0x60ab8 cmp prio,w24` / **`0x60abc b.gt 0x60cd8`**：本轮已经有一只 ready 源之后，更差（数字更大）的优先级整段不 prepare。只改一只 source 的 `+40` 改不了同桶里先被走到的 -99 源，所以 §49 的 -200 刀不够。

已试：只 live NOP `0x60abc`（`0x540010ec` → `0xd503201f`）。带 uprobe 的两窗：

| 抓痕 | Hz | gt50 | 洞 |
|------|----|------|----|
| `linux-mainline/out/display-stress/dagu-cbs-dispatch-20260914-042815.json` | 104.24 | 2 | 都是 nview +4 / +7，atomic +110 / +16（B-kick） |
| `...-042833.json` | 115.06 | 1 | nview +2.25，atomic +108（B-kick） |

两窗都没有 B-main。但 **关掉 uprobe 的轻 8 s**：kickoff **111.49 Hz**，gt50=**4**（209 / 108.5 / 100.7 / 92.2）。验收门没过。已写回 `0x540010ec`。**不要再 NOP `0x60abc`。**

B-main 在重探针下像被压住、轻窗又回来，说明截断不是稳定主因，或者多 prepare 的税把 kickoff 打稀了。不要再叠 prio / CAN_RECURSE / `.check` / cutoff NOP。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` 仍在。`tracing_on=1`。验收没到。

---

## 51. B-main 洞里主线程在一只长 GSource dispatch 里：钟 217ms 或 GJS `0xa8624`（2026-09-14 续）

ubuntu **486179** / lab **487814** 未重启。`0x60abc` 已写回 stock `b.gt`。探针改打真 dispatch `0x606f4`（`x19`=source），长于 8ms 当场读 ident。

抓痕 `linux-mainline/out/display-stress/dagu-gsrc-long-20260914-043014.json`（107.49 Hz / gt50=2，探针不当基线）：两个 B-main 洞都被一只 ≥75ms 的 dispatch 盖住。

| 洞 | nview | 长 dispatch | 当场 ident |
|----|-------|-------------|------------|
| 75.3 | +73.2 | **79.23 ms** @ −6.11 | source `0x55a1da7bd0`，prio **300**（`G_PRIORITY_LOW`），`dispatch=libglib+0x623e4`（timeout/idle 调用户函数） |
| 216.8 | +209.3 | **217.17 ms** @ −7.89 | **`[mutter] Clutter frame clock`** id 3193 prio 150，`libmutter-clutter-18.so.0.0.0+0x744c0` → `clutter_frame_clock_dispatch@0x73c0c` |

`0x623e4` 是 `blr x1` 调用户回调。下一窗 `...-043104.json` 在 34ms 那次 idle 上采到 **`idle_x1=libgjs.so.0.0.0+0xa8624`**（§33 的 `JS_GC` 在 `0xa864c`，同一函数）。不要再 apply MaybeGC / `dagu-gjs-inc-slice-install.sh` / skip-hammer。

所以 B-main 的「running、cb 已挂、不 nview」是：**flip 的 qcb 进 default 时，主线程已经在上一只 GSource 的 dispatch 里**（钟 paint 或 GJS GC），等它返回才轮到 callback source。不是 prepare 截断，也不是 wakeup。B-kick（nview 准时、atomic +108）仍在。

探针：`linux-mainline/scripts/dagu-gsrc-long-probe.py`（`0x606f4` + `0x62408 x1`）。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 52. 钟 dispatch 拆开后轻窗 <8ms；GJS 65ms 一档 B-main；qcb 里打断 JS 已崩（2026-09-14 续）

ubuntu 当时仍是 **486179** / lab **487814**。`dri_flush` NOP / wakeup / skip-poll / `affinity=system` 仍在。

活 clutter `clutter_frame_clock_dispatch` @ `0x73c0c`，GSource 外壳 `0x744c0`/`0x744f4`。vfunc：`0x73fb0` new_frame、`0x74058` before、`0x74244` frame；mutter paint `0xc52a8`、swap `0xc5a34`。探针 `linux-mainline/scripts/dagu-clock-dispatch-split.py`。

| 抓痕 | kickoff | gt50 | 长钟 | 长 GJS | 洞 |
|------|---------|------|------|--------|----|
| `linux-mainline/out/display-stress/dagu-clock-split-20260914-043325.json`（关在 `0x74244` 返回，漏了后半段） | 95.85 | 4 | 0 | 未计 | 2×nview-late + 2×nview-ok |
| `linux-mainline/out/display-stress/dagu-clock-split-20260914-043413.json`（整段 wrapper） | 111.98 | 5 | **0**（无 ≥8ms） | **65.51 ms** | nview-ok×3 + nview-late×2（其一 GJS @ −5.81） |

所以 **217ms 钟不是稳态**。`dri_flush` NOP 之后轻窗里钟自己很少再堵 50ms。B-main 仍是「上一只 GSource 还在跑」：GJS `0xa8624` / 其它 prio 300 idle，或尚未 ident 的长 dispatch。

同进程 `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-043523.json`（110.95 Hz / gt50=2）：

| 洞 | kind | 证据 |
|----|------|------|
| 116.7 | **B-main** | apply/sched **+2.6**，qcb/inv **+4.6**，nview/mgo **+109.5**，shell=`running`，lab=`ppoll` |
| 111.0 | **B-kick-kernel** | nview/mgo **+8.1**，atomic **+12.5**，`tail_s` **+110.8**，两边 `ppoll` |

`JS_GC`（mozjs `0x44c6e0`）手写 SliceBudget：`mov x5,#INT64_MAX` / `budget+32=2`（unlimited）。`JS_RequestInterruptCallback` @ `0x44f780`。

已试：`linux-mainline/scripts/dagu-gjs-interrupt-on-qcb-install.sh` 在 wakeup cave 后 `b 0x1d2b80`，从 KMS `queue_callback` 读 `gjs+0x1a0fc0` → JSContext+16 → `blr RequestInterrupt`。**apply-live 立刻把 486179 打死**，gdm autologin 拉起新 ubuntu **561579**。磁盘 poke（wakeup / skip-poll / `dri_flush`）还在；live-only 的 interrupt cave 随旧进程没了。**不要再 apply。**

新会话 identity `DAGU_NATIVE_VIDEO=1 /usr/local/sbin/dagu-lab-identity-native.sh`（lab **563461**）。刚起来轻 8s `linux-mainline/out/display-stress/dagu-light-8s-20260914-044100.json`：kickoff **101.16 Hz**，gt50=**7**，max **232.3**（不当稳态基线）。

稳住后再测 `linux-mainline/out/display-stress/dagu-light-rr-20260914-044200.json`：基线 **113.14 Hz / gt50=3 / max 115.5**。`debug_force_rr_cpu=Y` 变成 **109.54 / gt50=5 / max 216.9**，已写回 `N`。**不要再开 rr CPU。**

不要再 MaybeGC / inc-slice / skip-hammer / 从 KMS 调 JS / `debug_force_rr_cpu`。B-kick 仍不要 `chrt` 全员 kworker。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 53. 主线程 4ms `JS_GC` 预算已否；`cpu_dma_latency=0` 已否；下一刀 `system_highpri_wq`（2026-09-14 续）

新 ubuntu **561579** / lab **563461**。磁盘 poke（wakeup / skip-poll / `dri_flush`）仍在。`cpuidle.off=1` 已在 cmdline。

`JS_GC` 手写 SliceBudget：`0x44c730 mov x5,#INT64_MAX` / `0x44c734 mov w4,#2`（unlimited）。cave `0x410038` 改成 4ms TimeBudget（ticks=ns，`setDeadlineFromNow` @ `0x60c1a0`），只 live。脚本 `linux-mainline/scripts/dagu-mozjs-gc-budget-install.sh`。壳没崩。两窗轻 8s：

| 窗 | Hz | gt50 | max | 抓痕 |
|----|----|------|-----|------|
| 稳住基线 | 113.14 | 3 | 115.5 | `.../dagu-light-rr-20260914-044200.json` |
| 4ms budget | 110.44 | **6** | 114.4 | `.../dagu-light-gc-budget-20260914-044500.json` |
| 第二窗 | 111.62 | **5** | 110.1 | `.../dagu-light-gc-budget-20260914-044520.json` |

已 `restore-live`。**不要再开 4ms JS_GC budget。** 没有 200ms 洞，但 gt50 升了。

`/dev/cpu_dma_latency=0` 按住 8s：108.36 Hz / gt50=6 / max 111.9（`.../dagu-light-dma-20260914-044600.json`）。cmdline 已有 `cpuidle.off=1`，再禁深 C 无益。已松开。

B-kick 不是 cpuidle。`drm_atomic_helper_commit` 的 `queue_work(system_unbound_wq)` 改 `system_highpri_wq`（不要 `chrt` 全员）。源码 `linux-mainline/linux/drivers/gpu/drm/drm_atomic_helper.c`。增量 `Image.gz` + `linux-mainline/scripts/build-bootimg.sh` → `linux-mainline/out/boot-dagu.img`。上一份镜像备份 `linux-mainline/out/boot-dagu-pre-highpri.img`。只刷 B。`0525:a4a7` 保持。内核 `7.0.0-dirty` #172。

轻 8s `linux-mainline/out/display-stress/dagu-light-highpri-20260914-044900.json`：

| 窗 | Hz | gt50 | max |
|----|----|------|-----|
| 1 | **115.37** | **2** | 124.9 |
| 2 | **117.85** | **1** | 83.4 |

分类（探针税，不当基线）`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-044922.json`：**B-kick-kernel = 0**。剩下 B-main（nview +64 / +219，shell=`running`）和一档 flip 晚的 other。验收仍没到。下一刀只打 B-main（不要再从 KMS 调 JS / 4ms budget / MaybeGC）。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 54. Big Hammer 等钟空闲；B-main 分类 0，轻窗一度 gt50=0（2026-09-14 续）

ubuntu **1156** / lab **3394**（`--video`）未重启。活 gjs 对上：

| 偏移 | 含义 |
|------|------|
| `0xa8624` | `trigger_gc_if_needed`：清 `m_auto_gc_id`（+88），bit17=`m_force_gc` 则 `JS_GC(MEM_PRESSURE)`，否则 `gjs_gc_if_needed` @ `0xdc484` |
| `0xa9480` / `0x754c8` | `schedule_gc*`：`g_timeout_add_seconds_full(G_PRIORITY_LOW=300, **10**, trigger)`，不是 idle |
| 钟 GSource | `0x558adc3a50` prio 150，`priv+16` = `ready_time`（IDLE 为 -1） |

skip-hammer 只跳过 `JS_GC`、仍走 `gjs_gc_if_needed`（RSS 高时可 SHRINK），且 10s 定时器会在 120fps 的 IDLE 缝里开火。未再 apply MaybeGC / inc-slice / KMS interrupt / 4ms budget / skip-hammer。

未试过的一刀（只 live）：`linux-mainline/scripts/dagu-gjs-gc-idle-defer-install.sh`

- `0xa8638` `str wzr,[x0,#88]` → `b` cave `0xb00a0`
- 最近一次 `queue_callback` 的 `g_get_monotonic_time`（mutter cave `0x1d6f28` → `0x1d2b80` 写入 gjs rw `slot`）不到 250ms，或钟 `ready_time != -1`：不 GC、不消 `force_gc`、`return 1` 续期 10s
- 连续两次 10s 都看到钟 IDLE 才走原来的 `JS_GC` / `gjs_gc_if_needed`
- 不写磁盘 so

轻 8s（无 uprobe）：

| 抓痕 | Hz | gt50 | max |
|------|----|------|-----|
| 改前 | 116.01 / 111.14 | 2 / 5 | 108.4 / 116.7 |
| `.../dagu-light-gc-idle-defer-20260914-045800.jsonl` 窗1 | **118.86** | **0** | **16.9** |
| 同文件 窗2 | 110.57 | 3 | 116.7 |
| `.../dagu-light-gc-idle-defer-w2-*.jsonl` | 116.36 / 110.68 | 2 / 1 | 116.5 / 113.2 |

窗1 是到目前最接近验收的轻窗（gt50=0，max 一帧半），Hz 仍不是 ≈120。探针税 `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-045855.json`：**B-main = 0**。剩下 B-kick-kernel×2（`atomic` +8、`tail_s` +115）、B-post-late×1、other×4（flip/nview/atomic 一起 +108）。

同 poke 后续轻窗掉到 **102.31 Hz / gt50=4 / max 217**（像 defer 攒压后再一次 BIG_HAMMER / 长钟）。已 `restore-live`（`0xa8638` / `0x1d6f28` 回 stock）。wakeup cave 只留 `set_ready_time`+`wakeup(+128)`。写回后轻 8s：113.76 Hz / gt50=4。**不要再开 idle-defer**（短窗能把 B-main 压成 0，长会话会攒出 200ms 洞）。不要再 MaybeGC / skip-hammer / 4ms budget / KMS 调 JS。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq 仍在。`tracing_on=1`。验收仍没到。下一刀仍打 B-main：要在 **主线程** 让 `JS_GC` 让出 GLib（嵌套 `g_main_context_iteration`），不要再 defer 到空闲。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 55. 主线程 4×2ms slice + 嵌套 `g_main_context_iteration` 已否（2026-09-14 续）

ubuntu **1156** 未重启。`0xa864c` 仍是 stock `bl JS_GC`。idle-defer 已撤。

未试过的一刀（只 live）：`linux-mainline/scripts/dagu-gjs-gc-iter-slice-install.sh`。`0xa864c` → cave `0xb00a0`：最多 4 次 `IncrementalGCSlice` / `StartIncrementalGC`（2ms TimeBudget，reason `EAGER_ALLOC_TRIGGER` / `INTER_SLICE_GC`），每次之后 `g_main_context_iteration(NULL, FALSE)`，未完成再 `g_idle_add_full(200)`、不清 `m_force_gc`。活偏移：mozjs `IsIncrementalGCInProgress` `0x61c6e0`、`Start` `0x62dca0`、`Slice` `0x62dda0`、`SliceBudget(TimeBudget)` `0x60c1e0`、gjs `g_main_context_iteration@plt` `0x25660`。不写磁盘。

轻 8s `linux-mainline/out/display-stress/dagu-light-gc-iter-slice-20260914-050200.jsonl`：

| 窗 | Hz | gt50 | max |
|----|----|------|-----|
| 1 | 112.15 | 4 | 116.6 |
| 2 | 114.97 | **1** | **225.2** |

壳没崩。225ms 洞说明在 GC 里嵌套 iteration 不稳（或 StartIncremental 本身仍是长段）。已 `restore-live`。写回后轻 8s：112.02 Hz / gt50=3 / max 115.8。**不要再开 iter-slice / 嵌套 iteration。** 也不要再 idle-defer / MaybeGC / skip-hammer / 4ms budget / KMS 调 JS / inc-slice（只 idle 续）。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq 仍在。`tracing_on=1`。验收仍没到。下一刀不要再改 JS_GC 调度；B-kick 可试 `WQ_UNBOUND|WQ_HIGHPRI` 专用队列（不要 `chrt` 全员）。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 56. `dagu_commit` unbound+highpri 已否（2026-09-14 续）

`drm_atomic_helper_commit` 非阻塞路径改成懒分配 `alloc_workqueue("dagu_commit", WQ_UNBOUND|WQ_HIGHPRI|WQ_MEM_RECLAIM, 0)`，失败回退 `system_highpri_wq`。源码当时在 `linux-mainline/linux/drivers/gpu/drm/drm_atomic_helper.c`。增量刷 B：`linux-mainline/out/boot-dagu.img`（#173），回退镜像 `linux-mainline/out/boot-dagu-pre-unbound-hp.img`（#172 highpri）。`head.S` 仍是 `primary_entry` → `bl record_mmu_state`。`0525:a4a7` 约 3s 出现并保持 35s，未回 `18d1:d00d`。

板上 `7.0.0-dirty` **#173**。`dagu_commit` 已开工（`kworker/u33:0-dagu_commit` / `kworker/R-dagu_commit`）。新会话 ubuntu **1134** / identity lab **3552**（`DAGU_NATIVE_VIDEO=1 /usr/local/sbin/dagu-lab-identity-native.sh`）。磁盘 poke 对上：wakeup cave `0x1d6ee4=bl 0x1d6f10`、`0x1d6f28=ret`、infence skip-poll `0x1bd9d8`、`0x1c4404=ret`、Mesa `dri_flush` NOP、gjs `0xa8638=str wzr` / `0xa864c=bl JS_GC`。`affinity=system`，`tracing_on=1`。无 uprobe。

轻 8s `linux-mainline/out/display-stress/dagu-light-unbound-hp-20260914-050800.jsonl`：

| 窗 | Hz | gt50 | max |
|----|----|------|-----|
| lab 后 10s | 111.84 / 108.72 | 4 / 5 | 108.3 / 225.4 |
| 再稳两窗 | 105.52 / 109.08 | **7** / **5** | **233.4** / **216.9** |
| #172 highpri 对照 | 115.37 / **117.85** | 2 / **1** | 124.9 / 83.4 |

vblank 仍 120 / gt50=0。200ms 级洞仍像 B-main，但整体比 per-CPU highpri 差。源码已写回 `queue_work(system_highpri_wq, …)`。**不要再开专用 `dagu_commit` unbound+highpri。** 也不要 `chrt` 全员 kworker。刷回 `linux-mainline/out/boot-dagu-pre-unbound-hp.img`。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq 仍是下一刀底子。不要再改 JS_GC 调度。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 57. 刷回 #172 后轻窗基线；洞中 PC 仍是 running / 长 ppoll（2026-09-14 续）

已刷回 `linux-mainline/out/boot-dagu-pre-unbound-hp.img`。板上 `7.0.0-dirty` **#172**。ubuntu **1146** / identity lab **3888**（`DAGU_NATIVE_VIDEO=1 /usr/local/sbin/dagu-lab-identity-native.sh`）。磁盘 poke 对上：wakeup cave、`0x1d6f28=ret`、skip-poll、`0x1c4404=ret`、`dri_flush` NOP、gjs stock `JS_GC`。无 `dagu_commit` worker。`affinity=system`，`tracing_on=1`。无 uprobe。

轻 8s（板上 `/tmp/dagu-light-172-restore.json`，主机 `linux-mainline/out/display-stress/dagu-light-172-restore-20260914-051300.json`）：

| 窗 | Hz | gt50 | max |
|----|----|------|-----|
| 1 | 114.83 | 2 | 115.1（108.3 / 115.1） |
| 2 | 105.15 | **5** | **228.5**（228.5 / 133.3 / 117.0 / 116.4 / 100.1） |

vblank 仍 120 / gt50=0。窗1 接近 #172 highpri 常态；窗2 带 200ms 级洞。验收没到。

洞中 PC（无额外 uprobe）`linux-mainline/out/display-stress/dagu-hole-pc-20260914-051411.json`（探针税 113.76 / gt50=3）：

| 洞 | flip | 主线程 |
|----|------|--------|
| 116.4 | +5.82（准） | **running** 71/72，用户 PC 采不到 |
| 91.9 | +4.51（准） | **running** 50/50 |
| 116.7 | **+112.15（晚）** | **ppoll** 76/77，timeout **~4.7s**，lab 也在 ppoll |

前两档仍是 B-main（flip 准、主线程在上一只 GSource 里）。第三档是 flip 晚 + 两边睡、GLib 超时秒级——不是 100ms `g_timeout_add`。不要再开 idle-defer / iter-slice / unbound `dagu_commit` / `chrt` 全员 kworker。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq 仍在。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 58. page-flip 闭包改走 KMS context 已否（kickoff=0）（2026-09-14 续）

ubuntu **1146** / 新 lab **10107**（只重开实验室，未重启 gnome-shell）。活 so 对上：`maybe_post_next` 在 `0x1c2230` `mov x3,#0` 调 `meta_kms_update_add_page_flip_listener`（`0x1bbc50`）；`x3==NULL` 时 `0x1bbce0` `bl g_main_context_default`，所以 nview 进 default、等主线程。`ifgl` 只从 nview 尾 `b 0x1c4380` 进来；`promote`（`0x1c1220`）把 posted+72 清掉之后才能 post。

已试（只 live）：`linux-mainline/scripts/dagu-mutter-flip-kms-ctx-install.sh`。`0x1c2230` → cave `0x1d2b80`：从 crtc `get_device`/`get_kms` 取 impl+24 当 GMainContext。壳没崩。两窗轻 8s：**kickoff n=0**，vblank 仍 120 / gt50=0（最后一帧在扫，不再提交）。已 `restore`（`0x1c2230=mov x3,#0`，cave 清零）。写回后 kickoff 仍 0，重开 `DAGU_NATIVE_VIDEO=1 /usr/local/sbin/dagu-lab-identity-native.sh` 后 3s 内 kickoff **339**（约 113 Hz），壳仍是 **1146**。

**不要再把 page-flip listener 改到 KMS context**（nview/notify 在 KMS 线程上会卡死提交）。也不要再 idle-defer / iter-slice / unbound `dagu_commit` / `chrt` 全员 kworker。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq 仍在。`tracing_on=1`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 59. KMS 上 promote+ifgl 钩错对象已否（2026-09-14 续）

ubuntu **1146** / lab **10107** 未重启。#172 轻窗基线约 **115.8 / gt50=2**。

`add_page_flip` 分配 0x30：`+8=crtc`、`+16=vtable@0x2aacd0`、`+24=default context`、`+32=user_data`、`+40=g_object_unref`。`maybe_post_next` 写入的 user_data 是 **`[onscreen,#136]`（ClutterStageView）**，不是 onscreen。`page_flip_feedback_flipped`（`0x1c4584`）把 x4=view 交给 `nview`，`nview` 再 `bl clutter_stage_view_get_onscreen@plt`（clutter `0xa1240`：`priv=-224`，`ldr [view+priv+40]`）。

第一刀（`linux-mainline/scripts/dagu-mutter-kms-promote-ifgl-install.sh`）在 `flipped_in_impl` warning 路径 `0x1bd348` 把 `[x20,#32]` 当成 onscreen 做 promote+ifgl。那是 view。轻 8s：**106.62 / gt50=3** 与 **117.01 / gt50=1**。已 restore。`0x1bd348` 回 `ldr x1,[x20,#8]`，cave `0x1d2b80` 清零。

活 view `0x5568e0e1b0` → onscreen `0x55658a0150`：`+88`（next）经常非空，`+72`（posted）也非空，`+144=0`。`maybe_post_next` 在 `+72!=NULL` 时直接 return，必须先 `promote`（`0x1c1220` `stp posted,xzr,[onscreen,#64]`）才能 post。Type B 不是「没有 next」，是 **next 已经在、promote/ifgl 等主线程 nview**。

不要再把 listener+32 当 onscreen。也不要再 idle-defer / iter-slice / KMS context 整段 nview / unbound `dagu_commit` / `chrt` 全员 kworker。

---

## 60. 对上 onscreen 后 KMS 内 ifgl 仍差（2026-09-14 续）

同一会话改 cave：`get_onscreen(view)` → `promote` → `ifgl`。壳没崩。3s kickoff **320**（约 107 Hz）。轻 8s：**113.09 / gt50=1 / max 100** 与 **114.48 / gt50=3 / max 116.9**，不如基线 115.8。已 restore。

`ifgl` 只从 nview / `0x1c4644` / `0x1c46a0` 进来，都会走到 `maybe_post_next`（atomic）。在 `flipped_in_impl` 里同步 post，等于在 KMS flip 处理中重入提交，Hz 掉。`0x1c4644` 还带 `notify_complete`，不能当「只 post」用。

**不要再在 `flipped_in_impl` 里同步调用 ifgl/maybe_post_next。** 也不要把 listener+32 当 onscreen，不要 KMS context 整段 nview。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq 仍在。`tracing_on=1`。验收仍没到。

---

## 61. `post_impl_task` 延迟 ifgl 已否（2026-09-14 续）

ubuntu **1146** / lab **10107**。在 `flipped_in_impl` 里同步 ifgl 会重入 atomic（§60）。改成 `meta_thread_post_impl_task`（`0x1d7500`）：`x0=kms(x22)`、`x1=cave task`、`x2=view`。task 只 `get_onscreen`+`promote`+`ifgl`，不 `notify_complete`。`blr` 调 task（`1d6fcc`），无 PAC。只 live。脚本仍是 `linux-mainline/scripts/dagu-mutter-kms-promote-ifgl-install.sh`。

3s kickoff **333**（约 111 Hz），壳还在。轻 8s：

| 窗 | Hz | gt50 | max |
|----|----|------|-----|
| 1 | 116.12 | 2 | 116.9（116.9 / 91.6） |
| 2 | 115.09 | 3 | 116.6（116.6 / 108.4 / 75.0） |
| #172 基线 | 115.8 | 2 | 108–117 |

和基线同一档，100 ms 级洞还在。延迟一帧 post 最多盖 ~8 ms，盖不住 75–117 ms。已 restore（`0x1bd348=ldr`，cave 清零）。

**不要再在 flip 路径上 post/ifgl**（同步或 `post_impl_task` 都无效）。也不要把 listener+32 当 onscreen，不要 KMS context 整段 nview。

wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq 仍在。`tracing_on=1`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 62. 卸 dock/ding/tiling 更差（2026-09-14 续）

未重启 gnome-shell，只 `gnome-extensions disable` `ubuntu-dock` / `ding` / `tiling-assistant`。轻 8s：**111.66 / gt50=3 / max 125** 与 **111.56 / gt50=3 / max 233.5**。已 enable 回去，`enabled-extensions` 写回 `ding` / `ubuntu-dock` / `tiling-assistant` / `dagu-osk-focus`。不要再靠卸扩展消 Type B。

---

## 63. 命名源 IN_CALL 盖不住洞；轻探针下多数洞是 nview 准时后的 100ms（2026-09-14 续）

ubuntu **1146** / identity lab **24315**（`DAGU_NATIVE_VIDEO=1 /usr/local/sbin/dagu-lab-identity-native.sh`，中途实验室掉过，已重开）。#172，磁盘 poke 仍在：wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq。`tracing_on=1`。不要再 SIGSTOP 后才 gdb（attach 窗口已经离开洞）；`/proc/syscall` 的 `running` 在 ppoll 里会误报。

### 命名 GSource IN_CALL 跟长（无 uprobe）

活 default ctx `0x556436c1f0`。只盯有名字的 mutter/gjs 源，`flags&3==3` 才算 IN_CALL：

| 源 | 跟长 max | ≥20ms |
|----|----------|-------|
| `[mutter] Clutter frame clock` `0x5568b80c40` | **7.4 ms** | 0 |
| KMS callback source `0x55647afcf0` prio −99 | 4.0 ms | 0 |
| `[mutter] Wayland events` | 4.2 ms | 0 |
| `[gjs] Garbage Collection`（地址会变，现 `0x55661ca3e0`） | **0**（本窗未 IN_CALL） | 0 |

堆扫描里 `flags&2` 且无名的对象是假源，不要当主因。

### `gsrc-long`（glib `0x606f4`）对上的例外

抓痕 `linux-mainline/out/display-stress/dagu-gsrc-long-20260914-054347.json`（探针税，109 Hz / gt50=7，不当基线）：

- **一洞**被钟 dispatch **108.61 ms** 盖住（`0x744c0`）。`dri_flush` NOP 之后钟仍可能偶尔 ≥100 ms，不是稳态「钟<8ms」。
- **其余 nview-late 洞 `long` 为空**：主线程没有 ≥2 ms 的 GSource 盖住 90–225 ms。不是又卡在 `JS_GC` / 钟 paint。

### callback `ready_time` 与 ppoll

KMS callback source `priv+16`：8 s 里 **−1 占 2127 / 0 占 90**。钟 `ready_time` 几乎一直是 **−1**（IDLE）。ppoll timespec 常见 9 s 倒计时，那是 gjs `g_timeout_add_seconds(10)` 的下限，唤醒来自 fd，不是 100 ms 定时器本身。

若 default qcb 在 flip+4 就 `set_ready_time(0)` 且 nview 晚 90 ms，`ready_time` 应保持 0 约 90 ms。样本对不上，更像 **qcb 的 ready 和 nview 一起晚，或洞根本不是 B-main**。

### 轻探针：只 `queue_callback` / `nview` / `flipped_in_impl` / kickoff

`dagu_qcb` 活偏移 `0x1d6e40` 能装上。每帧约 3 次 qcb：`x1=KMS ctx 0x556462b370`、`x1=default 0x556436c1f0`、`x1=0`，**两套 context 的时间戳成对，都在 flip 当下**。

抓痕 `linux-mainline/out/display-stress/dagu-light-qcb-nview-20260914-054600.json`（kickoff **109.84 Hz / gt50=6**）：

| 洞 ms | in-gap flip | in-gap nview | 分类（相对 in-gap flip，不要用「有过 early nview」） |
|-------|-------------|--------------|-----------------------------------------------------|
| 91.8 | +6.62 | +6.72 | **nview 准时**，之后 ~85 ms 无 kickoff |
| **100.0** | +4.26 | +4.34 | **nview 准时**，下一 kickoff 整 **100.0 ms** |
| **100.0** | +2.93 | +3.02 | 同上 |
| 83.3 | +6.24 | **+82.37** | flip 准时、nview 晚（旧分类误标 nview-ok） |
| 116.9 | **+109.51** | +109.94 | flip 与 nview 一起晚 |
| 108.3 | **+106.69** | +106.90 | 同上 |

本窗多数洞已经不是「qcb 入队、主线程卡在上一只 GSource」。KMS 与 default 的 `queue_callback` 都在 flip 当下。剩下：

1. **B-post-late / B-kick**：nview/ifgl 已过，下一帧 kickoff 隔 ~100 ms（两洞数字是整 100.0）。钟 `ready_time=-1`，`maybe_reschedule` 没有立刻 `schedule_update`。不要再把 listener+32 当 onscreen，不要再 KMS 整段 nview / 同步 ifgl / `post_impl` ifgl。
2. **偶发长钟**（108 ms）和 **flip 本身晚 100 ms**。

不要再改 JS_GC 调度（MaybeGC / skip-hammer / budget / interrupt / idle-defer / iter-slice）。不要再卸扩展、`chrt` 全员 kworker、unbound `dagu_commit`。下一刀对准 **nview 准时之后谁把下一帧排到 100 ms**（GTK / clutter `schedule_update_later` / 未送出的 wl_frame），只改一处活指令。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 64. ifgl `next==NULL` 改 `schedule_update_now` 已否（2026-09-14 续）

ubuntu **1146** / lab 当时 **24315**。§63 后下一刀：`maybe_post_if_gl` 在 `next==NULL` 走 `0x1c4404 ret`。立刻 emit 已否（空 `frame_callback_surfaces`）。改成只 live：`0x1c4404` → cave `0x1d2b80`，`ldr view,[onscreen,#136]`，`bl clutter_stage_view_schedule_update_now@plt`（`0x629f0`）。不写磁盘。脚本 `linux-mainline/scripts/dagu-mutter-null-next-schednow-install.sh`。

活 so 对过：`0x1c4384 ldr x1,[x0,#88]`，`0x1c4388 cbz → 0x1c4404`，x0 仍是 onscreen。`schedule_update_now` 在 IDLE 会 `set_ready_time`，在 `DISPATCHED_TWO` 只挂 `pending_reschedule_now`。壳没崩。

轻 8s 无 uprobe：**107.53 Hz / gt50=8 / max 199.9**（75 / 108.3 / 108.1 / 83.3 / 100.1 / 199.9 / 108.3 / 58.6）。vblank 仍 120 / gt50=0。比 #172 基线 115.8 / gt50=2 差。和 IDLE pending 泵 / 无条件 `maybe_reschedule` 同类：空 dispatch 把钟打稀。

已 `restore`（`0x1c4404=ret`，cave 清零）。写回后同会话仍 destile（107–106 Hz）。只重开实验室（未重启 gnome-shell）：

| 窗 | Hz | gt50 | max | 抓痕 |
|----|----|------|-----|------|
| poke | 107.53 | 8 | 199.9 | `linux-mainline/out/display-stress/dagu-light-null-schednow-20260914-055000.json` |
| 写回未重开 lab | 107.87 / 106.14 | 6 / 7 | 203 / 242 | 同目录 `...-restore-*.json` |
| 重开 lab **32006** | **115.72** | **1** | 108.3 | `...-lab-reopen-20260914-055200.json` |

**不要再 apply `next==NULL` → `schedule_update_now`。** 也不要再 emit / GDK 解冻 / IDLE pending / after_update IDLE emit。下一刀不要再从 ifgl 空 next 去泵钟；要对上 **100.0 ms 整洞** 是谁在 GTK / frame-callback GSource 的 timerfd 上醒来。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 65. 100.0 ms 整洞：不是 lab timeout / frame-deadline / 双 freeze（2026-09-14 续）

ubuntu **1146** / identity lab **32006** 未重启。#172，磁盘 poke 仍在：wakeup cave / skip-poll / `dri_flush` NOP / `affinity=system` / highpri wq。`0x1c4404=ret`，cave `0x1d2b80` 空。`tracing_on=1`。

### lab GSource 不是 100 ms 闹钟

堆扫描（default ctx `0x30fa01f0`）只有：

| 源 | 间隔 | 洞中 remaining |
|----|------|----------------|
| timeout#12 `libffi` | **1000 ms**（lab `write_dump`） | 洞中 370–620 ms，对不上 |
| timeout#20 `libgtk-4.so+0x622c84` | **15 s**（`g_timeout_add_seconds`） | 洞中 0.7–12 s |
| `[gtk] sleep serial` | 无 timer（只探测 main loop 是否睡过） | 不是唤醒源 |
| `[gtk] gdk_frame_clock_frame` | 每帧 `g_timeout_add_full(GDK_PRIORITY_REDRAW=120, interval)` | 8 s 里 **913 次 interval 全是 0** |

`0x56efb0 mov w0,#0x78` 是优先级 120，不是 120 ms。gtk 文件 `0x63d938` 的 `100000` 对不上 frame 路径。

### sendcb / thaw / freeze 与两类洞

轻探针 `sendcb@0x1673f0` / `nview@0x1c4440` / `thaw@0x5a4da0`（抓痕思路同 `linux-mainline/scripts/dagu-lab-wake-probe.py`）：

| 洞 | nview | sendcb / thaw | 含义 |
|----|-------|---------------|------|
| 116.7 | −5.8 然后 +112 | **+0.6 / +0.77** | 已解冻，GTK 仍 ~111 ms 不提交 |
| 91.8 | **+4.3 准** | **+87.5 / +87.7** | nview 准时，emit 晚 |

`gdk_surface` `+96` freeze_count：freeze 之后恒为 **1**，thaw 之前恒为 **1**。不是双 freeze。`_gdk_frame_clock_inhibit_freeze`（`0x5735ec`）每次 thaw 都是 count **0→1** 并走 `start()`（`0x573684`）。`maybe_start_idle`（`0x56eee4`）时 `paint_idle_id` 恒 **0**。

### after_update 从不是 deadline 路径

活 `on_after_update`（`libmutter-18.so` `0x169664`）：`clutter_frame_get_result` **867/867 都是 0**（`PENDING_PRESENTED` → `0x1696ac` 立刻 `emit`）。`0x169684` 的 deadline 比较 **一次都没进**。`[mutter] Wayland frame callbacks for stage view (%p)` 的 timerfd **不是** 100.0 ms 整洞。

无 uprobe 轻窗仍见整 **100.0 / 100.3** ms 洞（`linux-mainline/out/display-stress/dagu-lab-freeze-20260914-062000.json`、deadline 窗探针税 107 Hz）。

### 洞中 lab 在等 wayland fd

`dagu-hole-pc` / 本轮采样：洞中 lab 几乎全是 syscall **73 ppoll**，PC `libc.so.6+0x95aec`。timespec remaining **440–775 ms**（对上 1 s `write_dump` 下限），**不是** 100 ms `g_timeout_add`。GTK 主循环在睡 wayland fd；下一帧要等 mutter 再 `sendcb`。

`after_update` 只要钟 dispatch 就 emit。空 pre 的 100 ms 洞里 **没有** `res`/`sendcb`：这 100 ms 钟没 dispatch。有 pre sendcb 的洞是解冻后 GTK/mutter 仍隔 ~100 ms 才下一帧。

洞中 `clutter_frame_clock_schedule_update`（clutter `0x675a0`）的 LR：常态是 `notify_presented` 里 `maybe_reschedule`（`0x682a8`，842 次）和 `clutter_stage_schedule_update` 对每个 view 的 `clutter_stage_view_schedule_update`（`0x9dbb4`，1748 次）。整 100.0 ms 洞常常 **pre 为空**，直到 +92–93 ms 才出现 `0x9dbb4`。有的 114 ms 洞在 **+4 / +8 ms 已经 schedule**，仍要再等 ~100 ms 才 kickoff——钟被叫醒了也不出帧。抓痕 `linux-mainline/out/display-stress/dagu-sched-who-20260914-062400.json`。

不要再 apply：ifgl 空 next 泵钟、after_update IDLE emit、GDK 解冻、listener+32、KMS 整段 nview、JS_GC 调度、卸扩展、`chrt` 全员、unbound `dagu_commit`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 66. 一只钟；`finish_frame` assign 为 0；洞里 paint/swap 各能卡 107ms（2026-09-14 续）

ubuntu **1146** / identity lab **32006** 未重启。#172。活 `libmutter-18.so` 基址 `0x7f9f220000`。磁盘 poke 对上（`0x1c4404=ret`、cave `0x1d2b80` 空、`0x1dd128=b 0x1dd04c`、`0x1dcfa8=mov w1,#1`）。`tracing_on=1`。无残留 uprobe。

活 so 对上 `meta_onscreen_native_finish_frame` @ `0x1dceac`：

| 路径 | 偏移 | 本窗次数 |
|------|------|----------|
| `posted && next==NULL` → `assign_next` @ `0x1c47e0` 再 `set_result(PENDING)` | 入口 `0x1dd064`，PENDING 与真 post 共用 `0x1dd054` | **0**（`dagu_ffasgn` 未触发） |
| `!has_kms_update && (!needs_flush \|\| posted)` → IDLE | `0x1dcfa4` `mov w1,#1` | 未计 |
| 真 `post_nonprimary` → PENDING | `0x1dd050` | 未与 assign 分开计 |

抓痕 `linux-mainline/out/display-stress/dagu-disp2-ghost-20260914-060821.json`（探针税 113.47 Hz / gt50=4）：

- 整窗只有 **一只** clutter 钟 `0x5568e7d280`（4511 次），不是两只 view 钟混在一起。
- `ifgl`：`next!=0 && posted==0` = **901**；`next==0 && posted==0` = **7**（与 `npres/st5=7`、`csched/st1=7`、`disp/st2=7` 对齐）。
- 稳态是 DISP2 / `disp` 从 st6 进：`csched/st9=1760`、`npres/st9=901`、`disp/st6=901`。
- `swap`≈`nview`≈`disp`≈907–908。`finish_frame` 鬼 PENDING **不是**本窗主因。

108.5 ms 洞（同抓痕）：`nview`+3.01 时钟已是 DISP1（st5）`pend=0`，`ifgl next==0` → 钟落到 IDLE；之后 **~98 ms 无 csched/disp**，到 +101.15 才从 st1 再 `schedule_update`。这是 present 把队列抽空后 `maybe_reschedule`（`pending=0` 且无 timeline）不武装 `ready_time`。不要再 apply IDLE pending 泵 / ifgl 空 next `schedule_update_now`（空 dispatch 会打稀）。

另几档洞不是这条 IDLE：有的 `disp` 之后 100 ms 才 `swap`，有的 `nview` 晚 100 ms。

`linux-mainline/out/display-stress/dagu-clock-split-20260914-061013.json`（探针更重，107.37 Hz / gt50=8）把钟 dispatch 拆开：

| 长段 | 在哪 | dt |
|------|------|-----|
| 1 | `clutter_stage_paint_view@plt`（mutter `0xc52a8`） | paint **107.69 ms**，swap 1.37 |
| 2 | `cogl_onscreen_swap_buffers_with_damage@plt`（`0xc5a34`） | paint 1.78，swap **107.95 ms** |
| 3 | gjs `0xa8624` | **73.76 ms**（盖住 75 ms 洞） |

同窗仍有 **没有** 长 `frm` 的 108 ms 洞（nview 准时或晚）。Type B 在本会话里至少三条并行：IDLE 抽空、paint/swap 各能卡 ~108 ms、偶发 GJS。

`linux-mainline/out/display-stress/dagu-paint-swap-wait-20260914-061114.json`（较轻，115.08 Hz / gt50=3，含整 **100.0**）：8 s 里只抓到 **一次** 长等待，在 `cogl_onscreen_swap_buffers_with_damage` 入口之后，主线程 **syscall 73 ppoll**、`wchan=poll_schedule_timeout`、`nfds=0xe`（14，像 GLib default 那一把 fd，不是单 fence）。采样时钟和 ftrace 可能错位，`open_ms=211` 只能说明「swap 还没看到 ret 时线程在 ppoll」，不能当 211 ms 真宽。

探针脚本：`linux-mainline/scripts/dagu-disp2-ghost-probe.py`、`linux-mainline/scripts/dagu-clock-dispatch-split.py`、`linux-mainline/scripts/dagu-paint-swap-wait-probe.py`。验收仍没到。不要 poke `0x1dd128` 改 IDLE（assign 本窗为 0，且与真 post 共用 PENDING）。也不要再 IDLE 泵 / 空 next 泵钟 / GDK 解冻 / JS_GC 调度。

---

## 67. swap 内 egl/lock_front/mpost 都不长；ifgl_null 列表非空，emit 已否（2026-09-14 续）

ubuntu **1146** / lab **32006** 未重启。#172。`0x1c4404` 已写回 `ret`，cave 清零。`tracing_on=1`。

`linux-mainline/out/display-stress/dagu-swap-split-20260914-061405.json`（111.01 Hz / gt50=6）把 `cogl_onscreen_swap_buffers_with_damage` 拆开：`assign_next` @ `0x1c4968`、EGL 父类 `blr` @ `0x1c4b9c`、`maybe_post` @ `0x1c4ce0`、`gbm_surface_lock_front_buffer` @ `0x1c25dc` **各 887 次、≥8 ms 为 0**。唯一长段是 `clutter_stage_paint_view` **107.18 ms**（盖住一档 108.3）。其余 5 档 ≥50 ms **没有** 长 paint/swap。上一窗 swap 里 14-fd ppoll 不能当稳态（时钟错位或漏了 ret）。不要再改 eglSwap / lock_front / maybe_post 等缓冲。

`linux-mainline/out/display-stress/dagu-idle-list-20260914-061522.json`：compositor `0x5564c7ef20`，`frame_callback_surfaces` 在 **+88**。`after_update` 865 次列表指针都非 0。`ifgl_null` 6 次，`nlist` = **2/1/1/1/1/1**（不是空）。108.5 / 91.8 ms 洞在 `npres` st5 后立刻 `ifn`，之后约 90 ms 才有 `au`/`send`。另几档是 `npres` 仍 st9、`nview` 晚 75–107 ms，没有 `ifn`。

已试只 live：`linux-mainline/scripts/dagu-mutter-null-next-emit-install.sh`。`0x1c4404` → cave `0x1d2b80`：`ldr view,[onscreen,#136]`，`x0=compositor`（`after_update` x20 采到 `0x5564c7ef20`），`bl emit_frame_callbacks_for_stage_view@0x167340`。壳没崩。无 uprobe 两窗：**113.42 / gt50=4 / max 116.7** 与 **112.88 / gt50=5**（118.2 / 108.3 / 75.1），与 #172 基线同档。已 `restore`（`0x1c4404=ret`，cave 清零）。

§64 说「立刻 emit 空列表」是钩错对象或看错时机；这次列表非空，补发仍消不掉整窗 gt50。多数洞是 **st9 上等 present / 偶发 paint_view 107 ms**，不是 ifgl_null。不要再 apply ifgl 空 next emit / `schedule_update_now`。也不要再 IDLE 泵 / GDK 解冻 / JS_GC / egl-lock 等。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 68. st9 洞：vblank 满、flip 准时；mgo→atomic 紧，晚在 nview 之后（2026-09-14 续）

ubuntu **1146** / lab **32006** 未重启。#172。磁盘 poke 仍是 wakeup cave / infence skip-poll / `0x1c4404=ret` / Mesa `dri_flush` NOP / gjs stock。`tracing_on=1`。

`linux-mainline/out/display-stress/dagu-present-late-20260914-061750.json`（探针税 116.87 Hz / gt50=1 / max 114.8）：洞内 **vblank 14 次、gt50=0**。`complete_flip` 只在 −4.74 / +3.6。`nview` +3.79、`fcdisp` +4.15、`mgo` +3.90，之后静到 `atomic` +114.51 才下一拍 kickoff。硬件扫上一张，不是缺 vblank。

`linux-mainline/out/display-stress/dagu-mgo-atomic-20260914-062029.json`（107.94 Hz / gt50=5）把 `mgo@0x1c1c04` → `post_update@0x1aaeec` → `process_async_update_in_impl@0x1affd0` → `drmModeAtomicCommit@0x1b4878` 拆开：五档洞的这四步都挤在洞末 **<4 ms**，计数各 862–863。本窗 **不是** KMS 线程 / ioctl 排队 100 ms。分类全是 `atomic-on-time-then-late-kick`（名字按「首个 mgo 之后立刻 atomic」；真正的洞在 mgo 之前）。

两档是 **nview 准时、mgo 晚**：

| gap | nview | mgo / postul / async / atomic |
|-----|-------|-------------------------------|
| 100.0 | +4.96 | +95.99 / +96.08 / +96.16 / +99.57 |
| 216.7 | +5.17 | +214.15 / +214.23 / +214.32 / +216.32 |

其余是 nview 与 mgo 一起晚到洞末。活 so `notify_view` 尾 `b 0x1c4380`（`maybe_post_if_gl`）。`ifgl` 三路：`0x1c4404` next==NULL；`0x1c4400` next 在 render_source 且 `!is_ready`；否则 `b 0x1c1b20`。

`linux-mainline/out/display-stress/dagu-nview-mgo-20260914-062143.json`（112.45 Hz / gt50=4）：整窗 `ifnr=0`（不是等 GL ready），`paint_ge8` 全空（本窗 paint 0.1–0.2 ms）。`ifn` 13 次。四档洞里 **三档** 是 nview +2～+3 立刻 `ifn`（next==NULL），然后 **90–193 ms 无 fcdisp**，再 `fcdisp`→paint→mgo：

| gap | nview / ifn | 下一 fcdisp / mgo |
|-----|-------------|-------------------|
| 200.9 | +3.15 / +3.19 | +195.8 / +196.51 |
| 108.8 | +2.36 / +2.39 | +102.86 / +103.75 |
| 99.8 | +2.08 / +2.11 | +94.12 / +95.09 |

一档 83.4 是 nview 到 +76.44 才来，没有 `ifn`。

`linux-mainline/out/display-stress/dagu-ifn-sched-20260914-062245.json`（110.81 Hz / gt50=4）：`0x16517c` 是 wayland commit 后 `clutter_stage_schedule_update@plt`。四档里两档 **ifn-then-idle**：

| gap | nview / ifn | 下一 sched（钟状态） | 同刻 wlsched |
|-----|-------------|----------------------|--------------|
| 109.1 | +6.57 / +6.6 | +104.49 **st=1 IDLE** pend=0 | +104.52 |
| 116.7 | +3.72 / +3.74 | +107.08 **st=1 IDLE** pend=0 | +107.11 |

ifn 之后 98–103 ms **没有任何** sched / fcdisp / au / emit / wlsched。钟掉在 IDLE，被 GTK/Wayland 提交叫醒。另两档没有 ifn：一档 nview 晚到 +140；一档 nview +3.81 后立刻 dispatch/emit，+10.15 钟 **st=9 pend=1**，再静到洞末（等 present / 未 kickoff）。

`linux-mainline/out/display-stress/dagu-hole-pc-20260914-062324.json`（无 uprobe，110.43 Hz / gt50=6）：六档 flip 都在 −3.8～+6.8（准时）。洞中主线程不是一种状态：

| gap | gnome-shell | identity lab |
|-----|-------------|--------------|
| 116.9 / 100.8 | ppoll `nfds=14/15`，timeout 4–9 s，`wchan=poll_schedule_timeout` | 116.9 多为 running；100.8 也是 ppoll |
| 108.2 / 75.3 / 66.7 | `syscall=running`（`/proc/pid/stat` eip 采不到） | ppoll |

`tracing_on=1`，无残留 uprobe。活 poke 仍 stock：`0x1c4404=ret`、`0x169668=cbz`、`0x169698=b.ne`、wakeup cave、`0x1c2230=mov x3,#0`。不要再改 `drmModeAtomicCommit` NONBLOCK、不要再 `chrt` / unbound `dagu_commit`。也不要再 apply ifgl 空 next emit / `schedule_update_now` / JS_GC。验收仍没到。

---

## 69. GTK `paint_idle`/`gsk` 都不长；ifn 后是等 tick，sendcb 准时也会 110ms 才 paint（2026-09-14 续）

ubuntu **1146** / lab **32006**。#172。

`linux-mainline/out/display-stress/dagu-gtk-tick-20260914-062642.json`（109.36 Hz / gt50=6）：`nview=emit=sendcb=idle=gsk=adj=kickoff=874`（1:1）。`ifn` 8 次。`gtk_fixed_move` 1748（每 tick 两块）。四类洞：

| gap | 形态 |
|-----|------|
| 100.0 | ifn +5.92 → **79 ms 无任何 GTK/mutter** → lab `paint_idle` +85.24 先醒，emit/sendcb +92 |
| 108.2 | ifn +2.85 → **104 ms 全静** → emit +106.6 |
| 117.6 | **无 ifn**，nview +7.11，**sendcb +8.44 准时**，lab `paint_idle` 到 +118.95 |
| 113.4 | nview +3.55，emit 到 +114.7（合成没 dispatch） |
| 120.5 | lab gsk +2.19 准时，nview +111.7（等 present） |
| 83.5 | nview 晚到 +79.9 |

`linux-mainline/out/display-stress/dagu-gtk-idle-dur-20260914-062810.json`：uretprobe `paint_idle@0x573a64` 与 `gsk_renderer_render@0x5dfc40` **各 930 次、≥8 ms 为 0**。GTK 画一帧本身不卡 100 ms；洞在 **paint_idle 入场之前**。本窗只 1 档 ≥50 ms（108.3，nview/sendcb 在洞末，无 ifn）。

ifn 那几档像「mutter IDLE + GTK 等下一记 `wl_surface.frame`」，靠 GDK 约 80 ms 超时解开。117.6 是 callback 已 `sendcb` 而实验室主循环 110 ms 没跑 `request_phase`。

已试只 live：`linux-mainline/scripts/dagu-mutter-null-next-sched-install.sh`。`0x1c4404` → cave `0x1d2b80`：`ldr view,[onscreen,#136]`，`bl clutter_stage_view_schedule_update@plt`（`0x68200`，**不是** `_now`）。壳没崩。无 uprobe 两窗：**117.36 / gt50=1 / max 75.2** 与 **113.32 / gt50=3 / max 208.3**，与 #172 基线同档。已 `restore`（`0x1c4404=ret`，cave 清零）。**不要再 apply ifgl 空 next `schedule_update` / `schedule_update_now` / emit。** 验收仍没到。

---

## 70. GDK interval 恒 0；nview-late 是主线程 running/futex，源已 ready（2026-09-14 续）

ubuntu **1146** / lab **32006** 未重启。#172。`0x1c4404=ret`，cave 空，`tracing_on=1`。

### GDK 不是 80 ms 闹钟

活 GTK 4.22：`maybe_start_idle` 两路 `g_timeout_add_full` 对过板图：

| 站点 | 偏移 | 含义 |
|------|------|------|
| paint | `0x56efb4` | prio 120，`w1=interval_ms` |
| flush | `0x56f02c` | prio 1，`w1=interval_ms` |
| delay | `0x56f0ac` | `min_interval_us`（`min_next_frame_time!=0` 才进） |

`linux-mainline/out/display-stress/dagu-gdk-toadd-20260914-063607.json`（探针税 108.45 Hz / gt50=7）：`paint_to` **867/867 interval=0**，`flush_to=0`，`delay_us=0`（`min_next_frame_time` 本窗恒 0）。§65 只计了 paint 路，结论一样。

| 形态 | 洞内顺序 |
|------|----------|
| **nview-ifn**（200 / 109.9 / 100.0） | nview+ifn +3～+5 → 80–195 ms 无 GTK → `sendcb`/`thaw`/`paint_to(0)`/`idle` 挤在洞末 |
| **nview-late**（108.0 / 93.4 / 50.3） | 上一帧 `sendcb`/`thaw`/`idle` 在 −3 已跑完，qcb +2～+4，nview 到 +47～+103 |
| 一档 100.2 | ifn +3.57 后 **thaw +84.74 早于 sendcb +92.82**（另一 surface 的 `wl_frame_cb`，不是 GDK timeout） |

`linux-mainline/out/display-stress/dagu-lab-wake-20260914-063700.json` 思路同 `linux-mainline/scripts/dagu-lab-wake-probe.py`：整窗 `thaw_who` **857/857 = `wl_frame_cb@0x518a44`**。GTK 只在 mutter `send_done` 后解冻。ifn-IDLE 是「钟抽空 + 实验室冻住等下一记 frame」，不是 `min_interval=80`。不要再 poke GDK timeout / 解冻（§65 已否 destile）。

脚本：`linux-mainline/scripts/dagu-gdk-toadd-probe.py`。

### nview-late：qcb 已 arm，主线程不 dispatch

`linux-mainline/scripts/dagu-qcb-between-probe.py` 只在 **flip 后 8 ms 内的 qcb** 开始采（第一刀误把 kickoff 前的 qarm 当 present）。

`linux-mainline/out/display-stress/dagu-qcb-between-20260914-063813.json`（115.63 Hz / gt50=2 / 83.2、116.6）：

- 两档都是 flip −3 准时 nview，**洞中第二记 flip +5.3**，qcb +5.5～+5.9，nview 到 +78 / +107。
- qcb `x1`：`0x556462b370` / `0x556436c1f0`（listener+8）各 2×kick，另有 `x1=0`（`0x1af6fc`）1×kick。`0x1d6e98` hit = qcb，不是 miss（`0x1d6ef4` 是成功 epilogue，第一刀误钩）。
- flip 后 12–55 ms：主线程 **`sys=running`**，`ocnt=2`，源 **`ready=0` `flush=1`**，`efd3=2`（wakeup 已写入）。一档 +59.43 **`futex_do_wait`**，+63.67 才 `ready=-1` `flush=0`（源被收掉），nview 仍在其后。

所以 B-main 不是「没 wakeup / 没 set_ready_time / GDK 睡 80 ms」。源已经 ready，主线程在 **嵌套 acquire（ocnt=2）里跑用户态，再偶发 futex**，不回到这只 qcb 的 dispatch。不要再 apply wakeup / ready_time / check / prio / CAN_RECURSE / JS_GC / ifgl 空 next 泵钟。

下一刀：flip+qcb 之后、nview 之前，对 **running 主线程采用户态 PC / 持有的 futex**（不要 SIGSTOP 整壳超过一帧），对准那一处指令再 live poke。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 71. nview-late 用户态 PC：Incremental GC 占主线程 12–88ms（2026-09-14 续）

ubuntu **1146** / lab **32006**。#172。`PTRACE_SEIZE` 主线程 + 短 `INTERRUPT` 读 `user_pt_regs`（pc / x30 / x29），再沿 FP 链走 12 帧。KMS 未 seize。脚本 `linux-mainline/scripts/dagu-qcb-pc-probe.py`。

`/proc/stat` eip 和 `libc+0x95aec` 都只是 **syscall wrapper 的 `svc; ret`**（`nm` 会误标成 `sem_trywait`）。`lr=libc+0x88440` 是 cancellable syscall 包装返回点，不能当业务 PC。

### 12s 窗

`linux-mainline/out/display-stress/dagu-qcb-pc-20260914-064143.json`（110.94 Hz / gt50=4）：

| gap | 形态 | 含义 |
|-----|------|------|
| 108.4 | nview +3.62 准 | ifn-IDLE / B-post-late |
| 108.6 | flip +4.6，qcb +4.64，nview +103.6 | qcb 已入队 |
| 116.8 | flip +3.07，qcb +3.15，nview +109.4 | 同上；本窗 PC 采到的就是它 |
| 100.1 | flip +3.03，**下一记 qcb 到 +95.8** | present 回调晚入队，不是 GC 挡住已就绪源 |

116.8 洞 flip+qcb 之后 **+12.4～+88.8** 六记全是 `sys=running`，PC 在 **libmozjs-140**：

| dt | PC（nm -D） |
|----|----------------|
| 12.4 | libc syscall wrapper（进 JS 前） |
| 12.4 | `JSScript::needsBodyEnvironment` 附近 |
| 30 / 75 | **`JS::AbortIncrementalGC` +0xa7c / +0xa84** |
| 46 | `JSRuntime::traceSelfHostingStencil` |
| 60 | `js::gc::LockStoreBuffer` |
| 88 | `JS::Zone::findSweepGroupEdges` |

FP 链 6/6 相同（JIT 无 FP，走到的是外层）：`g_source` idle `blr` `glib+0x6240c` → dispatch `+0x606f8` → iterate → `meta_context_run_main_loop` 里 `g_main_loop_run` 返回点 `mutter+0xfa634`（整进程常驻，不是这一刀的调用者）→ gjs `+0x5e350`。

这是 **Incremental GC 一整段 70ms+ 不回到 GLib**，qcb 源 ready 也 dispatch 不了。不是 0xa8624 那条 BIG_HAMMER 入口，但是同一类 JS GC。**不要再 poke `JS_GC` / MaybeGC / budget / interrupt-on-qcb / idle-defer / iter-slice。**

### 不要再 apply

JS_GC 调度、wakeup / ready_time / check / prio、ifgl 空 next 泵钟、GDK 解冻。`PTRACE_SEIZE` 本窗有税（110 Hz），验收窗不要挂着。

下一刀打 **非 GC** 的两档：① 100.1 这类 **flip 后 90ms 才 qcb**（谁没 `queue_callback`）；② nview 准时后的 ifn-IDLE。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 72. 「flip 后 90ms 才 qcb」不是 KMS 漏读；ifn-IDLE 的 send_done 晚 99ms（2026-09-14 续）

ubuntu **1146** / lab **32006** 未重启。#172。`0x1bd9ac` 仍是 stock `tbnz` `0x37f802b4`；`0x1bd9d8` 仍是 infence skip-poll `b 0x1bda00`（`0x1400000a`）。`0x1c4404=ret`，cave 空，`tracing_on=1`。KMS **1187**。

活指令对过板图：`drmHandleEvent` 入口 `0x1b19a0` `paciasp`、调用点 `0x1b1a2c` `bl drmHandleEvent@plt`、`flipped_in_impl` `0x1bd2c0` `paciasp`、`queue_callback` `0x1d6e40`。`notify_view_crtc_presented`（`0x1c4440`）**不**调 emit，尾 `b 0x1c4380`（`maybe_post_if_gl`）。`wl_callback_send_done` 在 emit 里 `0x1673f0` `bl wl_resource_post_event`。

脚本：`linux-mainline/scripts/dagu-flip-qcb-late-probe.py`。

### 12s 窗 1（只钩 hev/impl/qcb/nview）

`linux-mainline/out/display-stress/dagu-flip-qcb-late-20260914-064555.json`（112.18 Hz / gt50=6）：

| 计数 | n |
|------|---|
| kickoff / flip / vbl / hev / impl / nview | 1338 / 1339 / 1339 / 1339 / 1339 / 1338 |
| qcb | 6692（tid 全是 KMS **1187**，这是入队，不是 dispatch） |
| hev | tid=1187、fd=**12**，与 flip **1:1** |
| KMS snaps | **0**（没有一记 flip 后 8ms 内还没有 hev） |

六档洞修正后只剩两类：

| 形态 | 本窗 |
|------|------|
| nview-late | 4：flip/hev/impl/qcb 在 +3～+5（或上一帧 −4 的 leftover），nview 到 +82～+107 |
| ifn-idle | 2：nview +3 准，下一记 kickoff 92–117 ms |

没有「内核 complete_flip 准时、用户态 90ms 才 `drmHandleEvent` / `queue_callback`」。§71 那档 100.1「下一记 qcb +95.8」是探针只列出窗内前几记 qcb、加上 kickoff 前 leftover flip 造成的错觉；同形态在本窗是 **nview-late（qcb 已在 +4）** 或 **上一帧 flip 的 leftover**。

### 12s 窗 2（加 ifn / sendcb）

`linux-mainline/out/display-stress/dagu-flip-qcb-late-20260914-064656.json`（113.04 Hz / gt50=4 / max **258.5**）：

| 计数 | n |
|------|---|
| flip / hev / impl / nview / sendcb | 各 **1335**（1:1） |
| ifn | **16**（next==NULL 少见） |

| gap | 形态 | flip / hev / qcb / nview / ifn / sendcb |
|-----|------|----------------------------------------|
| 108.4 | **ifn-idle** | +2.31 / +2.37 / +2.39 / +2.44 / **+2.51** / **+101.93**（send 比 nview 晚 **99.49 ms**） |
| 258.5 | nview-late | +2.39 / +2.45 / +2.47 / **+255.77** / 无 / +258.36 |
| 100.1 | nview-late | +5.38 / +5.43 / +5.45 / +96.94 / 无 / 窗内只有 −1.78 leftover |
| 108.4 | nview-late | +5.27 / +5.32 / +5.33 / +104.41 / 无 / +104.38（与 nview 同毫秒） |

hev 相对本帧 flip 恒 **0.05–0.06 ms**。KMS 读 DRM event、`flipped_in_impl`、`queue_callback` 都准时。B-main 仍是主线程晚跑 nview（§71 Incremental GC）。ifn-IDLE 仍是 nview 立刻 `next==NULL`，**`send_done` 要再过 ~100 ms**（与 §68 `au`/`send` 晚 90 ms、§69 emit 晚 104 ms 同一条缝）。不要再当「KMS 漏 qcb」打 `drmHandleEvent` / skip-poll / listener。

`notify_view` 路径上没有 emit：ifn 之后钟 IDLE，要等下一次 `after_update`（`0x1696c0` / 尾 `0x169794`）才 `send_done`。空 next emit / `schedule_update` / `_now` / GDK 解冻已否（§67–§69）。不要再从 `0x1c4404` 泵钟或补发。

### sendcb 一旦发出，实验室立刻 paint

`linux-mainline/scripts/dagu-lab-paint-late-probe.py` → `linux-mainline/out/display-stress/dagu-lab-paint-late-20260914-064935.json`（114.96 Hz / gt50=4）：`nview` / `sendcb` / `paint_idle` 各 **1379**（1:1:1）。三档 ifn-idle 都是 nview/ifn +3～+6，**sendcb +97～+106，idle 再 +0.2～+0.3 ms**。本窗 **0** 档「sendcb 准时、paint 晚 110 ms」（§69 那档 117.6 本窗没再现）。`n_snaps=0`。GTK 不是在等 80 ms 闹钟；卡在 mutter 晚 `post_event`。不要再 poke GDK timeout / 解冻。

验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。117.85 / gt50=1 与已撤的 118.86 / gt50=0 **都不算过**。

---

## 73. ifn 时 emit 的 (comp, view, list) 已与 +99ms after_update 相同；补发 + 跳过 visibility 仍不 send（2026-09-14 续）

ubuntu **1146** / lab **32006**。#172。`0x1c4404` / cave / `0x1673c8` 测完已写回 stock。`tracing_on=1`。

### ifn 当下的列表不是空的

`linux-mainline/scripts/dagu-ifn-emit-list-probe.py` → `linux-mainline/out/display-stress/dagu-ifn-emit-list-20260914-065317.json`（探针税 110.61 Hz / gt50=9）：

| 站点 | 本窗 |
|------|------|
| ifn | **17**，`onscreen+136` view **全非 0**（`0x5568218ea0`） |
| compositor+88 | ifn **17/17 n=1**，surface `0x556721a980`，actor 非 0，`+476=0` |
| compositor+368 | ifn **17/17 空** |
| emit / au / sendcb | 各 **1326**（1:1），`comp=0x5564c7ef20`、`view=0x5568218ea0`、同一 surface |

四档 ifn-idle：nview/ifn +5～+9，**emit/au/sendcb 挤在 +81～+105**（与 §72 同一条缝）。+99ms 那次 emit 的三元组与 ifn 当下 **字节级相同**。不是钩错 compositor / view 为空 / 列表为空。

### 再 apply 已否

1. 只 `ifn-emit`（`linux-mainline/scripts/dagu-mutter-null-next-emit-install.sh`）：`linux-mainline/out/display-stress/dagu-lab-paint-late-20260914-065227.json` **107.82 Hz / gt50=5**，ifn-idle 的 sendcb 仍晚 68–88 ms。已 restore。
2. `0x1673c8` `cbz`→`nop`（`linux-mainline/scripts/dagu-mutter-emit-noskip-install.sh`）+ ifn-emit：有 ifn uprobe 时 108.7 / gt50=10。怀疑 uprobe 吃掉 `b cave`，再在 **不钩 `0x1c4404`** 下复测：`linux-mainline/out/display-stress/dagu-nview-send-only-20260914-065430.json` **109.43 Hz / gt50=5**，`send_after_n_le8=0`（nview +2.8～+6.5，sendcb 仍 +88～+104）。已两条都 restore。

`notify_view` 仍不调 emit。ifn 里 `bl emit` 的目标对过 `0x167340`，cave 里的 compositor 立即数也是 `0x5564c7ef20`。补发走得到 `0x1673f0` 才会有 sendcb；本窗没有。不要再叠 ifn-emit / `0x1673c8` nop / 空 next 泵钟。也不要再 poke `JS_GC`。

验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 74. ifn 时 +88 常空；活 emit 路径 actor/vis 从不失败；轻窗 113.44 / gt50=4（2026-09-14 续）

ubuntu **1146** / lab **32006**。#172。`0x1c4404=ret`、cave `0x1d2b80` 空、`0x1673c8=cbz` stock。`tracing_on=1`，无残留 uprobe。

### 活 after_update emit：`get_actor` / visibility 整窗不失败

`linux-mainline/scripts/dagu-ifn-actor-list-probe.py` → `linux-mainline/out/display-stress/dagu-ifn-actor-list-20260914-065650.json`（探针税 **117.44 Hz / gt50=2**）：

| 计数 | 本窗 |
|------|------|
| emit / get_actor@`0x1673b0` / vis@`0x1673c8` / sendcb | 各 **1408** |
| `actor_zero` / `vis_zero` | **0 / 0** |
| `empty` | 先 0 后 1（send 再 destroy，正常） |
| ifn | **19**（洞只有 2 档） |
| ifn 当下 `comp+88` | **15/19 n=0**；4 次有 callback 且 `cblist empty=false` |

真正跑到的 after_update emit 里 `get_actor` 从不空、visibility 恒 1。`+48` 非空 ≠ `get_actor` 非空（`0x18750c` 还做 GType 检查），但本窗活路径用不到那条失败。surface 的 callback `wl_list` = `role + (-48) + 16`（GType priv，活偏移 `0x2b51a0` 读到 **-48**）。

本窗两档洞 nview/ifn 都在 0–20ms 窗外（**nview-late**），没有 ifn-idle。`next==NULL` 也会出现在非洞帧，不能当 ≥50ms 的充要条件。ifn 当下 `+88` 多数已空：cave 里 `bl emit` 会在 `0x167368` 空链表直接返回，这能解释 §73 补发走不到 `0x1673f0`。§73 那窗 17/17 n=1 是 ifn-idle 更多时的采样，两窗不矛盾。

### 无 uprobe 轻窗

`linux-mainline/out/display-stress/dagu-kick-only-20260914-065720.json`：**113.44 Hz / gt50=4 / max 108.4**（kickoff=flip=907）。vblank 仍不是瓶颈。117.85 / gt50=1 与已撤的 118.86 / gt50=0 **都不算过**。

不要再叠 ifn-emit / vis-nop / 空 next 泵钟 / `JS_GC` 家族。下一刀：nview-late 里谁进 `62cee0`（不是 BIG_HAMMER `0xa8624` 也要钉 LR），只改一处未否指令。

验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 75. nview-late：整窗 `JS_GC`/`62cee0` 各 1 次；洞中 PC 仍可在 mark 走位（2026-09-14 续）

ubuntu **1146** / lab **32006**。#172。无 poke。`tracing_on=1`。

### 12s 只读入口

`linux-mainline/scripts/dagu-nview-gc-entry-probe.py` → `linux-mainline/out/display-stress/dagu-nview-gc-entry-20260914-070043.json`（112.83 Hz / gt50=7）：

| 入口 | 整窗 n |
|------|--------|
| `JS_GC` `0x44c6e0` | **1** |
| `JS_MaybeGC` | 4 |
| `IncrementalGCSlice` / `StartIncrementalGC` | **0 / 0** |
| `62cee0`（gcCycle） | **1**，LR=`mozjs+0x44c754`（`JS_GC` 返回点），`w3=0x23`=`MEM_PRESSURE` |
| gjs hammer `0xa8624` | **1**（与上面同一记） |

七档洞：2×ifn-idle（nview/ifn +2～+3，无任何 GC 入口）+ 5×nview-late。只有 **83.5** 那档在洞内 +2ms 进 hammer/`JS_GC`/`62cee0`（nview +79）。66.4 档看到的 +185 是同一记漏到下一档窗口。其余三档 nview-late（108.1 / 110.6 / 58.4）**洞内没有** `JS_GC` / `MaybeGC` / `62cee0`。

`IncrementalGCSlice` 整窗 0：不是官方 slice API，是 `JS_GC` 一次 `bl 62cee0`，或洞开始前就已经在 GC 体里。

### 同日另一 12s：洞中 PC

`linux-mainline/out/display-stress/dagu-qcb-pc-20260914-070125.json`（116.31 Hz / gt50=3，全是 nview-late）：

| 洞 | +12ms 样本 | 之后 |
|----|------------|------|
| 99.9 / 100.1 | `libc+0x95aec`（`x8=73`） | 各 1 记，未再采到 |
| 108.3 | mozjs | +29～+74 四记都在 **`0x62e880` mark 走位**（`0x62e904` `bl 0x61f8e0`），不是 `AbortIncrementalGC` 本体（该函数 `0x62dea0`～`0x62def4` 就返回） |

FP 链 6/6 仍带 `gjs+0x5e350` / `+0x5ebb8` / ffi / `mutter+0xfa634`：§71 已标常驻，不能当这一刀的调用者。`nm`/`objdump` 会把 `0x62e904` 错标成 `AbortIncrementalGC+0xa64`。

### 含义

- 12s 里 BIG_HAMMER 大约 1 次，能解释 **一档** 70–80ms nview-late，解释不了同窗另外 3–6 档。
- 被 PTRACE 抓到中段的那档，主线程确实在 Incremental GC mark（`0x62e880`），即使没看到 `62cee0` 入口（slice 可能在 flip 前已 `bl 62cee0`）。
- ifn-idle **没有** GC 入口。不要把所有 Type B 都写成 `JS_GC`。
- **不要再 poke `JS_GC` / MaybeGC / budget / interrupt / idle-defer / iter-slice / skip-hammer。**

下一刀：对「无 `62cee0` 入口」的 nview-late 加密 PC（+15/+45/+75），并读 `JSRuntime+4680`（`IsIncrementalGCInProgress`）看是 slice 已在跑还是非 GC。ifn-idle 仍不要叠 emit。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

### 加密窗（+15/+45/+75 + 入口 −200ms）

`linux-mainline/scripts/dagu-nview-late-pc-probe.py` → `linux-mainline/out/display-stress/dagu-nview-late-pc-20260914-070357.json`（PTRACE 税 110.22 Hz / gt50=7）：`JS_GC`/`62cee0`/hammer 仍各 **1**。种类 **2×nview-late + 5×ifn-idle**。

| 洞 | 形态 | 入口 | PC |
|----|------|------|-----|
| 108.5 | nview-late | hammer/`JS_GC`/`62cee0` 全在 +2.3 | +7 `0x31aecc`（mark 辅助），+37/+67 `0x62e880` blob |
| 108.4 | nview-late | **无** | +7.34 **`libc ioctl` `0xf2010`，LR=`libdrm+0x7148`（`drmIoctl` 里 `bl ioctl` 返回点）** |
| 118–216 | ifn-idle | 无 | nview/ifn +3～+5（114.1 的 nview +0.87 且 ifn=null，分类过宽，可能是 nview 准、未撞 `0x1c4404`） |

无 `JS_GC` 的那档 nview-late，+7ms 曾采到 **`drmIoctl` 返回点**。复测 `linux-mainline/out/display-stress/dagu-nview-late-pc-20260914-070451.json`：无 `JS_GC` 的 91.6 / 325.3 只在 flip±0.3ms 采到 `fcntl`（`x8=73`，`fd=2`，`x1=0xf`），不是 `MODE_ATOMIC`。上一窗单记 `drmIoctl` 不能当 100ms 阻塞。PTRACE 税把本窗打成 110 Hz / 一半 ifn-idle，验收窗不要再 seize。不要再 poke `JS_GC` 家族。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 76. ifn-emit 的 cave 会进 emit，但 send 仍晚；钩 cave/`0x1c4404` 会吃活指令（2026-09-14 续）

`0x1c4388` `cbz next` 跳到 `0x1c4404` 时**还没有** `paciasp`，x0 仍是 onscreen。磁盘 `0x1c4404` 是 `ret`，cave `0x1d2b80` 是 0。对这两处下 uprobe 会执行**文件里的旧指令**，不是 live poke。

钩 cave 的 12s（`linux-mainline/out/display-stress/dagu-ifn-cave-path-20260914-070702.json`）：`n_cave=2`、`cave_then_emit=0`，kickoff 掉到 **31.64 Hz**（3773 / 1909 ms）。文件偏移 `0x1d2b80` 是 0，uprobe 之后按 UDF 跑。ubuntu **1146 没了**，GDM 重开 **93509**。已 restore（新进程本来就是 stock）。**禁止再对 `0x1c4404` / `0x1d2b80` 下 uprobe。**

新会话 `DAGU_NATIVE_VIDEO=1 /usr/local/sbin/dagu-lab-identity-native.sh` → lab **95899**。轻窗 `linux-mainline/out/display-stress/dagu-kick-only-20260914-070730.json`：**106.35 Hz / gt50=8 / max 203**（新壳，不当旧 113 基线）。

### 不钩 poke 点：cave 真的 `bl emit`

`linux-mainline/scripts/dagu-mutter-null-next-emit-install.sh` apply（comp=`0x55ac1d6fb0`）+ 只钩 stock 的 emit/head/send/nview/au：

`linux-mainline/out/display-stress/dagu-ifn-cave-path-20260914-070834.json`（112.46 Hz / gt50=6）：`n_emit=1362`、`n_send=n_au=n_nview=1349`（**13 次多余 emit**）。四档 ifn-idle：nview +4～+6 后立刻 emit，`head` 非空，**没有 send**（一档 +2.95 的 send 带 au，是上一拍 after_update）。洞末 send/au 仍 +96～+117。

### 多余 emit 死在 visibility

`linux-mainline/out/display-stress/dagu-cave-emit-why-20260914-070920.json`：cave-like 两档 `get_actor` 非 0（`0x55ae3b97e0`），**vis w0=0**，不到 `0x167404` / `0x1673f0`。after_update 走 `+476!=0` 可跳过 vis；cave 的 `+476=0`，用 onscreen+136 的 view 做 vis 失败。

再叠 vis-nop（`linux-mainline/scripts/dagu-mutter-emit-noskip-install.sh`，**不钩 `0x1673c8`**）：`linux-mainline/out/display-stress/dagu-cave-emit-why-20260914-071002.json` 三档 cave-like **emit 有、actor/empty/send 都没有**——这窗 `+88` 空，`0x167368` 直接返回。vis-nop 用不上。

两条都已 restore。`0x1c4404=ret`、`0x1673c8=cbz`、cave 空。**不要再 apply ifn-emit / vis-nop。** 也不要再 poke `JS_GC` 家族。

验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 77. 无 GC 的 nview-late 不在 paint / 钟 / ≥8ms GSource（2026-09-14 续）

ubuntu **93509** / lab **95899**（后换成 **101658**）。#172。无 poke。`tracing_on=1`。禁止再钩 `0x1c4404` / cave。

### paint / 钟 cover

`linux-mainline/scripts/dagu-nview-cover-probe.py` → `linux-mainline/out/display-stress/dagu-nview-cover-20260914-071128.json`（113.32 Hz / gt50=4）：

| 函数 | n | ≥8ms |
|------|---|------|
| `clutter_stage_paint_view` `libmutter-clutter-18.so` `0x959d0` | 1359 | **0** |
| `clutter_frame_clock_dispatch` `0x73c0c` | 1359 | **0** |
| `JS_GC` / hammer `0xa8624` | 1 | 82ms，只盖 91.8 那档 nview-late |

四档洞：2×ifn-idle（nview/ifn +3～+6，无任何 ≥8ms cover）+ 1×nview-late **117ms 无 paint/clock/JS_GC**（nview +109.89）+ 1×nview-late 91.8 被 hammer 盖住。

无 GC 的 117ms：主线程不在 paint、不在钟 dispatch、不在 `JS_GC`。

### GSource ≥8ms 配对为 0

`linux-mainline/scripts/dagu-gsrc-hole-probe.py` → `linux-mainline/out/display-stress/dagu-gsrc-hole-20260914-071213.json`（111.89 Hz / gt50=6）：`n_long=0`。连那档 `JS_GC` 82ms 也没成对——嵌套 `g_main_context_iteration` 会用内层 `ge` 提前合上 `pending`，**不能**据此说「没有任何长 dispatch」。只说明不能靠 ≥8ms 配对找盖子。

种类：3×nview-late + 2×ifn-idle + 1×nview-ok（nview +3.76、无 ifn，仍 116.9ms）。

### mgo / ifnr

`linux-mainline/scripts/dagu-nview-mgo-probe.py` → `linux-mainline/out/display-stress/dagu-nview-mgo-20260914-071244.json`（114.64 Hz / gt50=3）：`dagu_ifnr`（`0x1c4400` `!is_ready`）整窗 **0**。116.6 那档被标成 `nview-mpost-no-mgo`，其实洞内第一记 nview 在 **+112.27**，是 nview-late；洞前 −2ms 的 mpost/mgo 是上一拍。109.0 是标准 ifn-idle（nview/ifn +3.5，fcdisp/mgo +102）。**不要再打 `is_ready` / fence wait。**

下一刀：无 GC 的 nview-late 计 `0x606f4` 次数（不对 duration）+ `/proc/<pid>/syscall`（不 seize）；ifn-idle 仍抓 +99ms 谁 `schedule_update`。不钩 `0x1c4404` / cave。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 78. nview-late：洞前 8–10 次短 dispatch 后主线程 ppoll/futex；ifn-idle 仍是 +100ms wlsched（2026-09-14 续）

`linux-mainline/scripts/dagu-nview-starve-probe.py` → `linux-mainline/out/display-stress/dagu-nview-starve-20260914-071445.json`（111.07 Hz / gt50=7）。不钩 `0x1c4404` / cave。`0x1bd35c` 整窗 qcb=null（事件被 gs 挤掉或只是一个 call site），不能当「没 queue」。

| 洞 | 类 | nview | gs_before | +20ms 主线程 | wlsched / sched0 |
|----|----|-------|-----------|--------------|------------------|
| 75.3 | nview-late | +72.5 | 10 | **running** | +1.96（`clutter+0x9dbb4`） |
| 116.6 | nview-late | +110.5 | 8 | **futex** `FUTEX_WAIT_PRIVATE` `0x55ab7f61f0` | +2.28 |
| 116.8 | nview-late | +109.3 | 9 | **ppoll** 14 fd `0x7fa9405aec` | +1.06 |
| 116.7 | nview-late | +111.3 | 9 | **ppoll** 14 fd 同上 | +3.78 |
| 108.4 | ifn-idle | +5.6 / ifn +5.7 | 3 | （nview 已到，未采） | **+104.3** |
| 216.8 | ifn-idle | +3.8 / ifn +3.8 | 4 | | **+212.8** |
| 50.1 | ifn-idle | +6.4 / ifn +6.5 | 3 | | +40.2 |

nview-late 的 `gs_top` 都是短源：`[mutter] MetaThread 'KMS thread' callback` 2–4 次、未名 `0x37939020`、Wayland events、KMS fd。**不是**一只 ≥8ms GSource 盖住。GTK 在 +2ms 已经 `wlsched`（钟已 schedule）。缺的是 +110ms 才到的 nview。

ifn-idle：ifn 之后仍无 sched，直到 GTK/Wayland `0x16517c` 在 +100 / +200ms 叫醒。**不要再 emit / vis-nop / schedule_now。**

wakeup cave 仍在（`0x1d6ee4=bl 0x1d6f10`，`wakeup(source+128)`）。`wakeup(NULL)` 已否。aarch64 `x8=73` 是 **ppoll**，不是 fcntl。

下一刀：只钩 `queue_callback` `0x1d6e40` + `drmHandleEvent` + `flipped_in_impl` + nview（不钩 `0x1c4404`、不加 gs），看 present qcb 是 +3 还是 +100。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 79. 「nview-late」里有一档其实是 kickoff 后 107ms 才 complete_flip（2026-09-14 续）

`linux-mainline/scripts/dagu-flip-qcb-late-probe.py` 已改：ifn 走 `0x1c4388`，**不钩** `0x1c4404`。

`linux-mainline/out/display-stress/dagu-flip-qcb-late-20260914-071701.json`（115.98 Hz / gt50=2）。hev/impl/qcb/nview **1:1** 跟 flip。qcb 全部在 KMS tid **93527**，每 kick 约 5 次。

| 洞 | 分类 | flip / hev / impl / nview | sendcb | 含义 |
|----|------|---------------------------|--------|------|
| 100.2 | ifn-idle | **+6.4 / +6.5 / +6.5 / +6.6**，ifn +6.7 | **+93.3** | HW 准时；缺 wl_frame |
| 108.3 | kick-late | 0–20ms **无** flip；**+107.3** 才 hev/impl/nview | +110 | 上一拍 kickoff 的 complete_flip 晚了 107ms |

`drm_vblank_event_delivered` 与 flip **同数**（只跟 page-flip，不是每拍 CRTC vblank）。不要把「vblank 空 109ms」写成面板停振。

starve 窗里那些 nview +110、wlsched +2 的「nview-late」，更像是 **等这次 late flip**（GTK 已 schedule，钟 st=9），不是主线程没 dispatch 已入队的 present qcb。present qcb 跟 flip 同一毫秒（+107）。+0.3ms 的 qcb 是别的 KMS callback。

wakeup cave 仍在，解释不了 kick-late。`wakeup(NULL)` / `set_ready_time(1)` 已否。不要再 emit。

下一刀：kickoff 后 20ms 无 `complete_flip` 时采 KMS / DPU irq / kworker（无 mutter uprobe）。ifn-idle 仍是 +90ms 才 sendcb。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 80. 无 uprobe：10 档洞里 9 档 flip 准时，面板 vblank 仍 119 fps（2026-09-14 续）

`linux-mainline/scripts/dagu-kick-noflip-kstack.py` → `linux-mainline/out/display-stress/dagu-kick-noflip-20260914-071827.json`（108.54 Hz / gt50=10）。无 mutter uprobe。内核 `#172`。

`/sys/kernel/debug/dri/0/crtc-0/status`：**vblank fps:119**（count 在涨）。面板没停。

| 类 | n | 含义 |
|----|---|------|
| flip-ok（+2.6～+6.6ms 就 `complete_flip`） | **9** | HW 已完成；缺的是下一记 kickoff（ifn-idle / 未 post） |
| flip-late（+112ms） | 1 | 少见；+20ms 时 KMS 在 ppoll 等 drm event，`crtc_event`/`card0-crtc*` kthread 空闲 |

9 档 flip-ok 的 `flip_late` +103～+121 是**下一拍**的 flip，不要当成这一拍 IRQ 晚。§79 的 kick-late 是少数档。

主洞仍是：**flip/nview 准时 → next==NULL → 90–100ms 才 sendcb / 下一 kickoff**。不要再 emit / vis-nop / schedule_now / wakeup(NULL)。下一刀对 after_update `+476` 与 ifn 时刻的差异（为什么 +99ms 那条能 send、ifn 不能），只改一处未否指令。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 81. ifn 时 +88 空是真的：GTK `queue_frame_callbacks` 要到 +90ms 才 prepend（2026-09-14 续）

ubuntu **93509** / lab **95899**。#172。compositor `0x55ac1d6fb0`。不钩 `0x1c4404` / cave。

活 `emit` `0x167340`：`ldr [comp,#88]`；`surface+476` 是 `flush_frame_callbacks`（`cbnz` 则跳过 `is_view_primary@0x166360`）。`0x1673c8` 是 primary，不是 obscured。`on_after_update` 的 `+368` 是 `barrier_surfaces`。`0x165448` 是 `assigned()`，不是每帧入队。

真 `queue_frame_callbacks`：`0x164f20`，`g_list_prepend` 在 **`0x164fa4`**。

`linux-mainline/scripts/dagu-ifn-au-list-probe.py` → `linux-mainline/out/display-stress/dagu-ifn-au-list-20260914-072324.json`（探针税 101.65 Hz / gt50=11）：

| 计数 | n |
|------|---|
| kick / add `0x164fa4` / au / send | **1219 = 1:1:1:1** |
| ifn（next==NULL） | 18 |

两档 ifn-idle：

| gap | nview / ifn | **add** | au / send | ifn 时 +88 |
|-----|-------------|---------|-----------|------------|
| 100.1 | +1.06 / +1.12 | **+90.52** | +91.7 | **0** |
| 100.0 | +1.08 / +1.14 | **+94.66** | +95.7 | **0** |

au 处读到 +88=0 是竞态：`0x1696c0` 钩的是 `bl emit`，读 mem 时 emit 已经删完。ifn 时没有并发 emit，**空表是真的**。

ifn 时 mutter **没有**可 send 的 `wl_resource`。ifn-emit / vis-nop / 置 +476 都不会变出 callback。GTK 在 +90ms **先** `queue_frame_callbacks`（未等 sendcb），然后 after_update 才 send。这 90ms 是 **GTK 没 commit**，不是 mutter 没 emit。

`gtk` 文件 `0x63d938` 的 `100000` 仍对不上 frame 路径（§65）。不要再 apply emit / vis-nop / schedule_now。下一刀对 lab/GTK：ifn 之后、add 之前，谁在 ~90ms 叫醒 commit（不 seize 验收窗）。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 82. ifn-idle：+90ms 是 GTK 自己 after_paint commit，不是 mutter 先回事件（2026-09-14 续）

ubuntu **93509** / lab **95899**。#172。cave / `0x1c4404` 仍 stock。实验室 dump 当时 **`videos=0` / `video14_open=0`**（板上无 `gtk4paintablesink`，`--video` 只在 cmdline 里）；洞在纯 GTK tick + GSK gl 下仍在。

`linux-mainline/scripts/dagu-lab-add-why-probe.py` → `linux-mainline/out/display-stress/dagu-lab-add-why-20260914-072648.json`（115.53 Hz / gt50=4）：

| 项 | 值 |
|----|-----|
| n_force `0x516e20` | **0** |
| toadd `0x56efb4` w1 | 洞内第一记是 **0**（paint 里重挂 0ms idle，不是 100ms 闹钟） |
| +20ms lab syscall | 三档都是 **ppoll** / `poll_schedule_timeout`，nfds=3 |
| ifn-idle 100.2 | nview/ifn +5.3/+5.4，**add +92.57，send +94.85**，thaw/idle +95 且 `thaw_who=wl_frame_cb` |
| ifn→add 之间 lab glib | **1** 次，名 `GDK Wayland Event source (wayland-0)` |

`linux-mainline/scripts/dagu-wl-opcode-probe.py` → `linux-mainline/out/display-stress/dagu-wl-opcode-20260914-072940.json`（114.27 Hz / gt50=5；3×ifn-idle + 2×nview-late）：

三档 ifn-idle 同一条缝：

| gap | nview/ifn | 洞内 mutter `post` | **lab 先 `marshal`** | add / send / rel |
|-----|-----------|-------------------|----------------------|------------------|
| 100.0 | +3.4 / +3.47 | +3.42 `wp_presentation_feedback` op0+op1；下一记 inbound 已是 **+90.89** | **+90.44** `wl_surface.frame` LR `0x51aeb8` | +95.72 / +96.71 / +95.67 |
| 108.5 | +4.81 / +4.87 | +4.83 标成 `wl_callback`（**不是** `0x1673f0` send） | **+98.76** 同一串 after_paint | +103.95 / +106.11 / +103.85 |
| 118.9 | +4.72 / +4.82 | +4.76 presentation | **+110.36** 同一串 | +115.62 / +116.77 / +115.56 |

lab 在 +90 发出的是 GDK after_paint 整串（活 `libgtk-4.so.1.2200.4`）：

1. `wl_surface.frame` op3，LR `0x51aeb8`（`0x51ae60` request_frame）
2. `wp_presentation.feedback` op1，LR `0x51af2c`
3. `wl_surface` op10，LR `0x503c18`
4. attach / damage_buffer / commit（op1 / op9 / op6）
5. `wl_display.sync` op0

`+90.89` 那记 mutter `post` 发生在 lab 已经开始 marshal **之后**，iface 读失败，对得上 `wl_display.sync` 的 callback.done，不是 frame done。`wl_buffer.release` 与 `0x1673f0` send 都在 add 之后。nview 当下的 presentation / 偶发 `wl_callback` **没有**立刻让 GTK commit。

ifn→add 的 ~90ms 里 mutter **没有**先给 lab 写一记能解冻的协议事件。叫醒 commit 的是 GTK 自己的 after_paint；`0x5a4da0` 那次 `wl_frame_cb` thaw 是 **这记 commit 之后** mutter 才 send 的下一拍。不要再 apply emit / vis-nop / 100ms timeout poke。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

`linux-mainline/scripts/dagu-pres-refresh-probe.py` → `linux-mainline/out/display-stress/dagu-pres-refresh-20260914-073304.json`（探针税 109.79 Hz / gt50=11；8×ifn-idle）：

| 项 | 值 |
|----|-----|
| `presented.refresh`（`0x169c98` x5） | 全部 **8333344 ns = 120.0 Hz**，洞内第一记跟 nview +0.03 ms |
| `g_timeout_add_full` `0x56efb4` w1 | 洞内全部 **0**（不是 90/100 ms 闹钟） |
| ifn-idle 的 `paint_idle` | 仍在 **send 之后**（+81～+104），不是 +90 那记 commit 的入口 |
| 两档 108.4 | **`request_frame 0x51ae60` 比 `paint_idle` 早 ~6 ms**（+96.74 vs +103.63） |

mutter 送给客户端的 refresh 是对的 120 Hz，不要 poke presented 周期。`paint_idle` 重挂间隔也是 0。+90 commit 可以不经过 `0x573a64`。不要再 apply 100ms / refresh 刀。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

`linux-mainline/scripts/dagu-wl-flush-probe.py` → `linux-mainline/out/display-stress/dagu-wl-flush-20260914-073418.json`（flush uprobe 税 102.78 Hz / 洞拉到 233 ms，验收窗不要再挂 `0x84e0`）：

| 项 | 值 |
|----|-----|
| `wl_connection_flush` `0x84e0` | ifn-idle 第一记就在 nview **+0.1 ms**，ifn→add 之间还有 7–21 次。**不是** +90 才 flush |
| `request_frame` 第一记 LR | 全部 **`0x503c24` cairo_after_scale**（wayland cairo/gl present 里 `set_buffer_scale` 之后） |

nview 当下 presentation 已经 `post`+`flush` 到 socket。lab 不是在等 mutter 晚写 fd。不要再 apply flush-after-presented。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 83. +90 的 window render / `gtk_fixed_move` 不是叫醒；ifn→add 之间 **0** 次 Mesa swap（2026-09-14 续）

ubuntu **93509** / lab **95899**。#172。cave / `0x1c4404` 仍 stock。`tracing_on=1`。不钩 `0x84e0`。

活 `libgtk-4.so.1.2200.4`：`gsk_renderer_render` `0x5dfc40` 唯一调用点 `0x33a4ec`（`gtk_window` render `0x33a184`）。`gtk_widget_queue_resize` `0x323800` 里 `bl queue_draw` 返回 **`0x323870`**。`gtk_fixed_move` **`0x18aa80`** → `gtk_fixed_layout_child_set_transform` `0x18a5ec` → `gtk_layout_manager_layout_changed` `0x1c9a0c`（tail-call `queue_resize`，LR **`0x18a650`**）。部分 nview-late 第一记 qres LR 是 **`0x1d0ee0`**（`gtk_label_set_text` `0x1d0e60`+）。`gdk_surface_freeze_updates` **`0x5a31b0`**（`[surface+#96]++`，首次则 `b 0x5736c4` 冻钟）。`gdk_surface_thaw_updates` 仍是 **`0x5a4da0`**。`gdk_draw_context_end_frame` `0x575260` 整窗 **0**（GSK 走 vfunc，不走这层 C API）。cairo present 入口 **`0x503b2c`**，由 **`0x56f3c0`** `blr` vfunc+144 打进，返回点 **`0x56f414`**。Mesa Wayland WSI 提交入口 **`libEGL_mesa.so.0.0.0` `0x2ce20`**，内部 `0x2d024` `mov w1,#6` / `bl wl_proxy_marshal_flags`（`wl_surface.commit`）。

`linux-mainline/scripts/dagu-cairo-present-caller-probe.py` → `linux-mainline/out/display-stress/dagu-cairo-present-caller-20260914-073720.json`（112.02 Hz / gt50=5）：

| ifn-idle | nview/ifn | 第一记 qdraw | win render | add / send / idle |
|----------|-----------|--------------|------------|-------------------|
| 93.9 | +4.05 / +4.11 | **+88.11 `0x323870`** | +88.31 widget_thunk | +86.43 / +87.83 / +87.95（add **早于** qdraw） |
| 108.6 | +5.25 / +5.31 | **+97.55 `0x323870`** | +97.83 | +104.5 / +106.46 / +106.75 |

`linux-mainline/scripts/dagu-qresize-lr-probe.py` → `linux-mainline/out/display-stress/dagu-qresize-lr-20260914-073825.json`（探针税 102.16 Hz / gt50=9；2×ifn-idle）：`n_fmove=2450`、`n_laych=2450`、`n_qres=2494`（约每帧 2 次 `gtk_fixed_move`，对得上 lab `arena.move` 两块飞贴）。layout_changed LR 全是 **`0x18a650`**。

| ifn-idle | nview/ifn | add | send / idle | fmove / laych / qres | win |
|----------|-----------|-----|-------------|----------------------|-----|
| 91.9 | +8.06 / +8.12 | **+86.96** | +88.26 / +88.51 | **+88.81～+88.85** `0x18a650` | +89.23 |
| 83.3 | +6.32 / +6.38 | **+79.6** | +81.5 / +81.73 | **+81.99～+82.03** | +82.35 |

ifn→add 的 ~80ms 里 **没有** `gtk_fixed_move`。tick / resize / window render 跟在 send/idle **之后**，是 thaw 后的下一拍动画，不是叫醒 +90 commit 的那一下。不要把 `arena.move` 当 Type B 主因。

`linux-mainline/scripts/dagu-ifn-commit-lr-probe.py` → `linux-mainline/out/display-stress/dagu-ifn-commit-lr-20260914-074155.json`（113.2 Hz / gt50=5；1×ifn-idle）：

| 计数 | n |
|------|---|
| kick / freeze / thaw / cairo present / op6 marshal | **1358 / 1357 / 1357 / 1357 / 1357** |
| `gdk_draw_context_end_frame` | **0** |
| freeze LR | 全部 **`libgobject-2.0.so+0x15774`**（`g_signal` 打进 `0x5a31b0`，after-paint） |
| thaw LR | 全部 **`0x518a44` wl_frame_cb** |
| 钩到的 op6 | 全部 **`libEGL_mesa.so+0x2d028`**（WSI `wl_surface.commit` 返回点） |

ifn-idle 100.3：nview/ifn +5.12/+5.18；**上一拍** thaw −10.3 / freeze −9.31（洞前已冻钟）；add **+91.96**；thaw +93.41；idle +93.46；fmove +93.98；cairo present / request_frame / Mesa commit / 再 freeze 在 **+96.8～+97.1**（这是 thaw **之后** 的下一帧，不是叫醒）。

`linux-mainline/scripts/dagu-mesa-swap-add-probe.py` → `linux-mainline/out/display-stress/dagu-mesa-swap-add-20260914-074327.json`（探针税 98.29 Hz / gt50=10；4×ifn-idle）。`n_swap=n_pres=1178`。swap 调用者几乎全是 **`libEGL_mesa.so+0x22f98`**（EGL 里 `blr` swap vfunc 的返回）。present `0x56f3c0` 调用者全是 **`libgtk-4.so+0x62e430`**（`gsk_gpu_renderer`）。

四档 ifn-idle **同一条缝**：

| gap | nview/ifn | add | thaw / idle / fmove | pres / Mesa swap | **ifn→add 的 swap 次数** |
|-----|-----------|-----|---------------------|------------------|--------------------------|
| 217.0 | +4.14 / +4.19 | +208.17 | +211.56 / +217.74 / +218.46 | +222.46 / +222.53 | **0** |
| 100.1 | +7.77 / +7.84 | +97.6 | +99.61 / +99.67 / +99.87 | +102.32 / +102.38 | **0** |
| 92.4 | +7.73 / +7.79 | +89.03 | +91.05 / +91.12 / +91.67 | +94.94 / +94.99 | **0** |
| 91.7 | +5.89 / +5.95 | +88.45 | +89.89 / +89.98 / +90.21 | +91.51 / +91.53 | **0** |

上一拍 Mesa swap 在 kick **−7～−13 ms**（已经 commit + freeze）。ifn 之后、mutter `queue_frame_callbacks` 之前，lab **没有** `0x2ce20` swap，也没有 `0x56f3c0` GSK present。§82 在 +90 看到的 after_paint marshal（`wl_surface.frame` / attach / damage / commit）**不是** 这一拍 eglSwap。add 比 send/thaw 早 1–3 ms，比 GSK present / Mesa swap 早 3–14 ms。

读法：钟在洞前 after-paint 已冻；tick/`fixed_move`/GSK/Mesa 都要等 `wl_frame_cb` thaw。叫醒 +88 的那记 mutter add，来自 **冻钟期间、没有 Mesa swap 的 GTK Wayland commit**（§82 的 after_paint 串），不是 tick，不是 `eglSwapBuffers`。不要再 apply GDK 整段解冻（曾把 destile 打到 81 Hz）。不要再挂 `0x84e0`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 84. `request_frame` 全是 cairo present；`after_paint` 自己的 commit **整窗 0**（2026-09-14 续）

ubuntu **93509** / lab **95899**。#172。不钩 cave / `0x1c4404` / `0x84e0` / Mesa。

活 GTK 里 `bl 0x51ae60` 只有四处：

| 返回 LR | 函数 | 本窗 |
|---------|------|------|
| `0x5036f0` | simple after_paint `0x5035d0` | **0** |
| `0x503c24` | cairo present `0x503b2c` | **全部** |
| `0x503e50` | cairo commit `0x503c28` | **0** |
| `0x523eac` | wl GL present `0x523dd0` | **0** |

`linux-mainline/scripts/dagu-reqfr-path-probe.py` → `linux-mainline/out/display-stress/dagu-reqfr-path-20260914-074534.json`（110.43 Hz / gt50=9；4×ifn-idle）：`n_reqfr=1325` 全是 **cairo_present**。`n_sap=n_ccom=n_glp=0`。

| ifn-idle | nview/ifn | add | 第一记 reqfr |
|----------|-----------|-----|--------------|
| 91.6 | +3.07 / +3.13 | **+86.59** | **+90.67**（add **之后**） |
| 100.0 | +4.52 / +4.58 | **+94.55** | **+100.36**（add 之后） |
| 108.5 | +2.91 / +2.97 | +102.41 | **+97.11**（add **之前**） |
| 108.4 | +2.49 / +2.58 | +101.01 | **+95.75**（add 之前） |

同一类洞里，cairo present 的 `request_frame` 可以在 add 前或后。add 在 reqfr 之前的那两档，**不是** 这记 `0x51ae60` 叫醒的。`0x51b00c` 的 opcode 6 是 request_frame 里给 **subsurface** 做的 commit，主 surface 不走这里。

活 `on_frame_clock_after_paint` 是 **`0x518c60`**：`0x518c78` `ldr freeze_count [surface,#96]`，非 0 则跳过 commit；`0x518cac` 才是这条路径的 `wl_surface.commit`；随后 `0x518d10` `b freeze_updates`。

`linux-mainline/scripts/dagu-after-paint-freeze-probe.py` → `linux-mainline/out/display-stress/dagu-after-paint-freeze-20260914-074657.json`（112.04 Hz / gt50=7；本窗 **0×ifn-idle**，7 档几乎全是 nview-late，其中 4 档 gap **恰好 116.6 ms**）：

| 项 | n |
|----|---|
| after_paint `0x518c7c` | 1343，**freeze_count 全部 0** |
| after_paint 自己的 commit `0x518cac` | **0** |
| hide/null-buffer commit `0x51b4f0` | **0** |
| `request_frame` | 1343 |

after_paint 进门时钟 **没有** 冻着（count=0），但 bits `0xc`（ack_configure / force_next_commit）也从未置上，所以 **从不** 走 `0x518cac`。§83 钩到的每帧 freeze 是 after_paint **末尾** `0x518d10` 等 frame.done，不是进门时已经冻着。不要再把「after_paint 自己 commit」写成 +90 叫醒。也不要再 apply 整段 GDK 解冻。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 85. +90 的 mutter `apply_state` **没有**对上任何已钩的 lab `wl_surface.commit`（2026-09-14 续）

ubuntu **93509** / lab **95899**。#172。cave / `0x1c4404` 仍 stock。`tracing_on=1`。不钩 `0x84e0` / 全量 marshal。

活 `0x165124`（actor `apply_state`）唯一返回点是 **`0x194168`**：`0x19410c` 里 `ldr x2,[class,#160]; blr x2`。`0x19410c` 的唯一返回点是 **`0x191a14`**：`0x1919a8` 里同样 `blr` 父类 `apply_state`。`queue_frame_callbacks` 仍只从 `0x165124` 进 `0x164fa4`。

`linux-mainline/scripts/dagu-add-commit-site-probe.py` → `linux-mainline/out/display-stress/dagu-add-commit-site-20260914-075106.json`（107.85 Hz / gt50=11；5×ifn-idle + 6×nview-late）：

| 计数 | n |
|------|---|
| kick / apply `0x165124` / add / reqfr / Mesa `0x2ce20` | **1293 = 1:1:1:1:1** |
| apply LR | 全部 **`0x194168`** |
| request_frame 子面 `0x51af84` / `0x51b00c` | **0**（无 subsurface） |
| after_paint 自 commit `0x518cac` / hide `0x51b4f0` | **0** |
| cairo2 `0x5046e4` / cursor `0x5161ec` / toplevel present `0x51dd44` / prop `0x51a848` | **0** |

四档 ifn-idle（另一档 Mesa 在 add 前 5 ms）同一条缝：`ifn` +3.8～+5.3 → **`apply`/`add` +82～+96，中间 0 次已钩 lab commit**。上一拍 Mesa 在 kick **−9～−16 ms**；这一拍 Mesa / `request_frame` 在 add **之后** 4–5 ms（thaw 后下一帧）。

`linux-mainline/scripts/dagu-mesa-alt-commit-probe.py` → `linux-mainline/out/display-stress/dagu-mesa-alt-commit-20260914-075350.json`（112.48 Hz / gt50=7；2×ifn-idle）：

| 计数 | n |
|------|---|
| kick / wrap `0x19410c` / apply / add / Mesa `0x2ce20` | **1349 = 1:1:1:1:1** |
| wrap LR | 全部 **`0x191a14`** |
| Mesa 另一条 WSI `0x2bf8c` / 其 commit `0x2c06c` | **0** |
| popup `0x522dc0` / xdg opcode6 `0x51e4d4` | **0** |

两档 ifn-idle：`ifn` +1.1 / +4.9 → wrap/apply/add **+90.6 / +91.8**，ifn→add 的 Mesa / malt / mcom 仍是 **0**。

读法：+90 叫醒 +88 的那记 `g_list_prepend`，是 mutter 角色 `apply_state` 链（`0x1919a8` → `0x19410c` → `0x165124`），**不是** lab 已钩过的 GTK/Mesa `wl_surface.commit`。§82 的 after_paint marshal 串对不上这条缝。不要再把 Mesa `0x2ce20`、cairo present、`0x518cac`、subsurface、`0x2bf8c` 写成 +90 叫醒。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

`linux-mainline/scripts/dagu-apply-wrap-lr-probe.py` → `linux-mainline/out/display-stress/dagu-apply-wrap-lr-20260914-075450.json` 与 `linux-mainline/out/display-stress/dagu-apply-wrap-lr-20260914-075538.json`：

活 `0x18e364`（把 pending 打进 role `apply_state`，内含 `0x18eb94 blr` → `0x1919a8`）的调用点：

| LR | 本窗 n | 含义 |
|----|--------|------|
| **`0x16e7f4`** | **1298** | `0x16e70c` GSource：`g_poll` 最多 4 个 unix fd（timeout 0）之后 `ldp x2,x0,[src,#96]; blr x2` |
| `0x18ff14` | 9 | 同文件里的即时 `bl 0x18e364` |
| `0x163934` / `0x169608` | 0 | 队列 `g_queue_pop_head` / after_update +472 这两路本窗没进 |

ifn-idle 的 +90 apply（100.1：ifn +5.98 → applyc +90.19；216.8：ifn +4.12 → applyc +209.96）LR **全是 `0x16e7f4`**。文件 `0x16e7f0` 是 `blr x2`，不是 `bl 0x18e364`。

读法：+90 的 apply/add 是这条 **fd-poll GSource 晚才 dispatch** 打进的 `0x18e364`，不是 lab 当场再 marshal 一记 commit。不要再把 leftover GTK `mov w1,#6` 站点写成叫醒。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 86. +90 GSource 是隐式 dma-buf `EXPORT_SYNC_FILE` 等 fence，不是 `drmSyncobjEventfd`；poll=0 立刻 apply 已否（2026-09-14 续）

ubuntu **93509** / lab **95899**。#172。cave / `0x1c4404` / `0x1bd9d8` skip-poll 仍 stock。`tracing_on=1`。不钩 `0x1c4404` / cave / `0x84e0`。

活 so 与 [GNOME mutter `meta-wayland-dma-buf.c`](https://raw.githubusercontent.com/GNOME/mutter/main/src/wayland/meta-wayland-dma-buf.c) `meta_wayland_dma_buf_create_source` 对上：名字 `[mutter] DmaBuf readiness source`，`g_poll` timeout 0（`mtk_is_fd_readable`），不就绪则 `DMA_BUF_IOCTL_EXPORT_SYNC_FILE`（`DMA_BUF_SYNC_READ`）+ `g_source_add_unix_fd`。显式 `drmSyncobjEventfd` 在 `meta_wayland_drm_syncobj_create_source`（`0x18faac`），本实验室 **整窗 0 次**。

`linux-mainline/scripts/dagu-dmabuf-ready-probe.py` → `linux-mainline/out/display-stress/dagu-dmabuf-ready-20260914-075852.json`（钩错显式站点，`n_syse=n_ipoll=0`）与 `linux-mainline/out/display-stress/dagu-dmabuf-ready-20260914-080042.json`（改钩隐式 `0x18fdbc`）：

| 项 | 12 s 窗 |
|----|---------|
| kick | 1355，113.59 Hz，gt50=5 |
| 隐式 `g_poll` `0x18fdbc` | **1352**；**n=0 共 1343**，n=1 仅 **9** |
| `g_source_new` `0x18ff40` / attach `0x18fe78` / dispatch `0x16e70c` | **1343 = 1:1:1** |
| 显式 `0x18faac` | 0 |

洞档 `first_pair(ipoll)` 落在 add **之后**（下一拍 GTK commit 再建 source），不是卡住的那一拍。+90 的 `disp`/`add` 来自 **上一拍 attach 的 GSource**。ifn-idle 四档 add 在 +81～+230，与 disp 对齐。

活 `0x18fdbc` 文件/板上均为 `340000a0` `cbz w0, 0x18fdd0`。只改这一处为 `34000480` `cbz w0, 0x18fe4c`（poll=0 也当就绪、不建 source）：`linux-mainline/scripts/dagu-mutter-dmabuf-ipoll0-install.sh apply`。无 uprobe 8 s：kick **108.69 Hz / gt50=7**（224.2 / 191.7 / 108.2 / 76.9 / 66.8 / 66.7 / 50.1），vblank 仍 120.12 / gt50=0。比基线更差。已 `restore` 回 `340000a0`。不要再 poke `0x18fdbc`，也不要 restore `0x1bd9d8`。

读法：几乎每帧隐式 poll 都是 0，mutter 用 sync_file 等 writer fence；多数 GSource 在一帧内 dispatch，洞是 **同一条 fence 晚 80–230 ms 才可读**。立刻 apply 未消洞。GTK GSK gl **没有**走 `wp_linux_drm_syncobj` 的 acquire 源。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

`linux-mainline/out/display-stress/dagu-dmabuf-ready-20260914-080423.json`（12 s，108.63 Hz / gt50=11）attach→disp：

| 等待 | n |
|------|---|
| **<2 ms** | **1252** |
| 2–8 ms | 26 |
| 8–16 ms | 9 |
| 80–120 ms | **8**（= wait_gt50） |
| p50 / max | **0.53 ms** / 107.6 ms |

`add_unix_fd` 能读到的名字：`anon_inode:sync_file` 373，其余 922 读 `/proc/93509/fd` 已空（<2 ms 已 close）。ifn-idle 的 prev_attach 在 kick 前 6–10 ms，`wait_ms` 91–101。板上 `libEGL_mesa.so.0` / `libgtk-4.so.1` **无** `wp_linux_drm_syncobj` 串；`libvulkan_freedreno.so` 有，但实验室是 `GSK_RENDERER=gl`。

`linux-mainline/out/display-stress/dagu-dmabuf-ready-20260914-080629.json`（8 s，`pidfd_getfd` + `SYNC_IOC_FILE_INFO`）：能抓到的 fence 只有两类——

| driver / obj | n | 含义 |
|--------------|---|------|
| `drm_sched` / `ring0` | 43 | MSM GPU scheduler，名字形如 `drm_sched-ring0182-<seq>` |
| `detached-driver` / `signaled-timeline` | 21 | 已经 signal 的 stub |

两条 wait>50 对上的 FILE_INFO：一条 **`drm_sched` `ring0` status=0**（还没 signal）等了 **213.8 ms**；一条 stub 已 signal 却仍记了 62.3 ms（可能是 fd 复用对错，或主循环没立刻 dispatch）。67.0 ms 的 nview-late 洞里 addfd 也是 **`drm_sched-ring0182-779320` status=0**。

读法：偶发 Type B 洞里 mutter 等的不是 100 ms 软件定时器，是 **MSM `drm_sched` ring0 这条 implicit writer fence 晚 signal**。立刻 apply 已否。验收仍未到。

---

## 87. 洞中采 `dri/0/gpu` 会自伤；hangcheck 250 ms 对不上 80–120 ms（2026-09-14 续）

ubuntu **93509** / lab **95899**。#172。cave / `0x1c4404` / `0x18fdbc` / `0x1bd9d8` stock。`tracing_on=1`。

`/sys/kernel/debug/dri/0/hangcheck_period_ms` = **250**。本 boot `hangcheck recover` 只有 **07:50** 一条，不是 80–120 ms 洞。`rbbm` 空闲时 ring0 只超前约 2 个 fence。`gpu_busy_percent` 约 18%。不要打开 `hangrd` / `rd`（不 hang 会一直堵）。

`linux-mainline/scripts/dagu-gpu-ring-snap-probe.py` → `linux-mainline/out/display-stress/dagu-gpu-ring-snap-20260914-080955.json`：每 2 ms 读 `dri/0/gpu` 头 512 B，10 s 窗 kick **1.93 Hz / gt50=7**（洞到 3008 ms）。这是探针锁 GPU debugfs，不是基线。自伤窗里 `rbbm=0x0` 且 `inflight` 卡在 4，retired 不涨。停探针后 2 s 轻窗回到 119.46 / gt50=0；紧接着无 uprobe 8 s：**114.91 Hz / gt50=3**（116.8 / 112.4 / 100.1），vblank 120.12 / gt50=0。不要再扫 `gpu` debugfs。

实验室 `python3` 只有 3 个 `renderD128`，fd 表里看不到 dma-buf（commit 后在 mutter）。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

`libgallium-26.0.8-1ubuntu0.3.so` **没有** `wp_linux_drm_syncobj`（EGL/GL WSI 不会给 mutter 显式 acquire）。只杀 lab、`GSK_RENDERER=vulkan` + `VK_ICD_FILENAMES=freedreno_icd.json`（maps 只有 `libvulkan_freedreno.so`，无 lvp）：无 uprobe 8 s kick **106.13 Hz / gt50=6**（216.6 / 108.6 / 108.3 / 108.2 / 103.2 / 91.9），vblank 仍 120.12 / gt50=0。比 GSK gl 基线更差。已把实验室改回 `GSK_RENDERER=gl`。不要用 lavapipe，也不要把 GSK vulkan 当交付。

---

## 88. 洞中 `gpu_busy_percent`（devfreq last_status，约 10 ms 窗）：ifn-idle 不空闲（2026-09-14 续）

ubuntu **93509** / lab **145648**（`GSK_RENDERER=gl`）。不读 `dri/0/gpu` / `hangrd`。`gpu_busy_percent` 来自 `linux-mainline/linux/drivers/gpu/drm/msm/msm_gpu_resources_sysfs.c` 的 `devfreq->last_status`（`dagu-gpu-perf.sh` 把 polling 设成 10 ms），不是 1 s 平均。

`linux-mainline/scripts/dagu-gpu-busy-hole-probe.py` → `linux-mainline/out/display-stress/dagu-gpu-busy-hole-20260914-081256.json`（10 s，**107.42 Hz / gt50=7**，探针没自伤）：

| gap | kind | nview/ifn | disp/add | busy min/max | zero 占比 |
|-----|------|-----------|----------|--------------|-----------|
| 91.6 | **ifn-idle** | +6.81 / +6.88 | +85.15 / +85.22 | **3 / 67** | **0** |
| 100.1 | **ifn-idle** | +5.12 / +5.18 | +92.71 / +92.80 | 0 / 59 | 0.09 |
| 116.9 | nview-late | +108.49 | +114.48 | 0 / 31 | **0.73** |
| 114.7 | nview-late | +109.9 | +116.88 | 0 / 16 | **0.81** |
| 124.8 | nview-late | +57.29 | +0.88 | 0 / 19 | **0.77** |

读法：Type B **ifn-idle** 等 fence 的 85–93 ms 里 Adreno **不是** 全空（devfreq 窗几乎一直有 busy）。nview-late 多数样本 busy=0，是另一类。§83 已证 ifn→add **没有** 新的 lab Mesa swap，所以这段 busy 不是实验室新提交，是上一拍 job 还在飞，或 gnome-shell 在用 GPU。验收仍未到。

---

## 89. ifn-idle 的 85 ms 里 **没有** 未完成的 `msm_gpu_submit`；下一记 ioctl 才在 +81 且 0.7 ms 就 retire；lab/shell never-defer 已否（2026-09-14 续）

ubuntu **93509** / lab **145648**。#172。cave / `0x1c4404` / `0x18fdbc` / `0x1bd9d8` stock。不读 `dri/0/gpu` / `hangrd`。不钩 `0x1c4404` / cave / `0x84e0`。

内核已有 `drm_msm_gpu:msm_gpu_submit` / `submit_flush` / `submit_retired`（带 client `pid`）和 `gpu_scheduler:drm_sched_job_{queue,run,done}`。活 `libgallium-26.0.8-1ubuntu0.3.so`：`msm_submit_flush` 序言 **`0xc9f208`**，`flush_submit_list` **`0xc9fb04`**（无 `bl` 直调，走函数指针），`fd_submit_sp_flush` **`0xca13c4`**。defer 门槛是 **`0xca15d0` `350004a0` `cbnz w0, 0xca1664`**（随后 `deferred_cmds > 128` 在 `0xca15ec`）。

`linux-mainline/scripts/dagu-msm-submit-hole-probe.py` → `linux-mainline/out/display-stress/dagu-msm-submit-hole-20260914-081658.json`（12 s，108.59 Hz / gt50=6；`n_submit=n_flush=n_retired≈5210`，lab:shell **2605:2604**）：

| gap | kind | nview/ifn | add | kick 前最后一记 | ifn→add 的 submit/flush | 洞内第一记 flush / retire |
|-----|------|-----------|-----|-----------------|-------------------------|---------------------------|
| 92.0 | **ifn-idle** | +8.28 / +8.33 | **+82.54** | shell −23.6 已 retire（elapsed 0.01） | **lab 2 / 2** | lab **+81.59** / **+82.38 elapsed 0.69** |
| 111.1 | nview-late | +110.1 | +117.24 | lab −5.7 已 retire | 到 +115 才有下一记 | shell +115.4 / +116.4 elapsed 0.87 |
| 108.5 | nview-late | +101.56 | +107.75 | lab −22.0 已 retire | 到 +105 才有下一记 | shell +105.9 / +106.9 elapsed 0.87 |
| 116.7 | nview-late | +109.77 | +1.84 | shell −2.3 已 retire | kick 后立刻 lab 2 记 | lab +0.50 / +1.70 elapsed 1.14 |

ifn-idle：**从 kick 到 +77 没有任何 GEM_SUBMIT / flush / retire**。上一拍 job 在 kick **−22 ms** 已经结束。+81 的实验室 ioctl 不是 leftover 在飞，是洞末才发出的新 job，硬件只要 **0.69 ms**。§83 的「ifn→add 无 Mesa `0x2ce20` swap」仍然成立：这记 ioctl **不是** `eglSwapBuffers`。

`fd_submit_sp_flush` 会在 ioctl 前把同一把 `deferred_submits_fence` 挂到 BO 上。只改一处、已 restore：

| 刀 | 活 insn | 8 s 无 uprobe | 分类 |
|----|---------|---------------|------|
| 只 poke 实验室 `0xca15d0` → `14000025` `b 0xca1664` | `linux-mainline/scripts/dagu-mesa-nodefer-install.sh` | **114.01 Hz / gt50=3**（125.0 / 110.4 / 108.5），vblank 120.13 / gt50=0 | 10 s 轻钩仍有 **2×ifn-idle**（108.3 / 92.1） |
| 只 poke gnome-shell 同一处 | 同上脚本思路 | **114.65 Hz / gt50=3**（116.9 / 91.8 / 84.5），vblank 120.12 / gt50=0 | 91.8 / 84.5 仍是 ifn-idle 形 |

两边 never-defer **都已 restore 回 `350004a0`**。不要再 poke `0xca15d0`。§88 的 busy≠0 对不上「有未完成的 ioctl job」；devfreq 10 ms 窗看的是残留/别的计数，不是这 85 ms 里还在排队的 `msm_gpu_submit`。

读法：Type B ifn-idle 等的 `drm_sched` `ring0` fence **不是** 一记已经 submit、还在 GPU 上跑了 80 ms 的 job。EXPORT_SYNC_FILE 快照到的那条 fence 在 GPU 空闲时保持 status=0，直到洞末实验室另一次（非 swap）ioctl 前后才可读。立刻 apply、GSK vulkan、lab/shell 禁止 defer 都已否。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 90. attach 时 fence seq 对的是 lab `drm_sched` ctx 274；已 signaled 仍可晚 110 ms 才 dispatch；ifn 里 `g_main_context_iteration` 未消洞（2026-09-14 续）

ubuntu **93509** / lab **145648**。#172。不读 `dri/0/gpu`。不钩 `0x1c4404` / cave / `0x84e0`。

`linux-mainline/scripts/dagu-fence-seq-probe.py` → `linux-mainline/out/display-stress/dagu-fence-seq-20260914-082432.json`（12 s，112.08 Hz / gt50=6）。FILE_INFO 名字是 **`drm_sched-ring0274-<seq>`**（274 = 实验室 drm_sched context，不是设备 182）。MSM `submit_retired` seq（~5e6）和这条 **不是** 同一号空间；应对 `drm_sched_job_{queue,done}` 的 `fence=274:seq`。

| 洞 | kind | prev addfd | 该 seq queue / done | disp/add |
|----|------|------------|---------------------|----------|
| 108.3 | **ifn-idle** | −12.3 **无 sfi**（fd 已空） | 上一记 shell ctx 110 在 kick **−8.3 已 done** | **+104** |
| 108.3 | **ifn-idle** | −16.6 无 sfi | shell −9.9 已 done | **+105** |
| 108.3 | nview-late | −8.25 **`ring0274-171070` status=0** | lab queue −8.49 / **done −4.58（kick 前已 signaled）** | **+112** |

`klass_n`：1324 次 addfd 里 1228 读不到 FILE_INFO（fd 转瞬即关），89 次 `queued-not-done`，7 次 `never-queued`。能对上 seq 的那档 nview-late：**fence 在 kick 前 4.6 ms 已经 done，GSource 仍拖到 +112 才 dispatch**。两条 ifn-idle 的上一拍 GPU 同样在 kick 前结束，disp 仍在 +104。

活 `0x1c4388` `b40003e1` `cbz x1, 0x1c4404` 改成 `cbz x1, cave@0x1d2b80`，cave 里 `g_main_context_iteration(NULL, FALSE)` 再 `ret`。**不改 `0x1c4404`（仍是 `d65f03c0`）**。`linux-mainline/scripts/dagu-mutter-ifn-iter-install.sh`。

| 窗 | 条件 | kick |
|----|------|------|
| 8 s 无 uprobe | poke 后第一次 | 115.65 Hz / gt50=2（115.0 / 83.3） |
| 10 s 钩 `0x1c4388` | 卸 uprobe **会把 0x1c4388 写回文件原字** | 分类见过 0×ifn-idle，不可靠 |
| 8 s 无 uprobe | 重新 apply 后 | **116.95 Hz / gt50=1**（108.4），vblank 120.13 / 0 |
| 10 s 只钩 nview + `0x1c4398`（不钩 poke 点） | poke 仍在 | 114.0 Hz / gt50=4，**仍有 2×ifn-idle**（115.7 / 108.5，nview +6.9 / +6.3） |

**不要对已 poke 的 `0x1c4388` 下 uprobe**（卸载会恢复成 `b40003e1`，cave 会成孤儿）。ifn 当下 `iteration` **没有**消掉 ifn-idle：有的 fence 在 +6 还没 readable，要等 +99 那记实验室非 swap ioctl。已 signaled 却晚 dispatch 的那类，iteration 只能盖住一部分。验收仍未到。

当前活字（未 restore）：`0x1c4388=b4073fc1`，`0x1c4404=d65f03c0`，cave 7 条 insn。下一步仍是 8 s kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 91. +99 lab ioctl 是 thaw 后下一帧；DmaBuf `can_recurse` + ifn-iter 崩壳（2026-09-14 续）

ubuntu **93509** / lab **145648**（随后 recurse 崩壳）。#172。不读 `dri/0/gpu`。不钩 `0x1c4388` / cave / `0x1c4404`。

`linux-mainline/scripts/dagu-lab-flush-lr-probe.py` → `linux-mainline/out/display-stress/dagu-lab-flush-lr-20260914-082928.json`（12 s，探针税 108.64 Hz / gt50=6；4×ifn-idle + 2×nview-late）：

| 项 | 值 |
|----|-----|
| `fd_submit_sp_flush` / `flush_submit_list` / `msm_gpu_submit` | 各 2608，全是 **python3** 主线程，不是 `gdrv` / `ir3q` |
| `fd_submit_sp_flush` LR | 全部 `libgallium+0xbf1d0c` |
| `flush_submit_list` LR | 全部 `libgallium+0xca0ebc` |
| ifn-idle **`n_spfl_mid` / `n_swap_mid`** | **全部 0** |
| ifn-idle add vs 下一记 lab swap | add **早 2–8 ms**（234.7→237.0；56.38→61.46；193.55→201.81；106.87→110.70） |

§89 看到的 kick **+81 / +99** `msm_gpu_submit` 是 **thaw 之后下一帧**，不是叫醒 DmaBuf GSource 的那一下。ifn→add 中间实验室没有 flush / swap。GSource 晚 dispatch，不是 leftover job 跑了 80 ms。

ifn-iter 理论缺口：DmaBuf GSource 默认 `can_recurse=0`，嵌套 `g_main_context_iteration` 派发不了**正在 dispatch 的同一只** source。只改一处、活 `0x18ff40` `mov x26,x0` → `bl cave@0x1d1bd8`（`g_source_set_can_recurse(src, TRUE)`），**不碰** `0x1d2b80` / `0x1c4388`：`linux-mainline/scripts/dagu-mutter-dmabuf-recurse-install.sh apply`。

apply 后约 3 s **gnome-shell 93509 消失**（新壳 **161892** 为 stock）。实验室 log：`Lost connection to Wayland compositor.` 读法：ifn-iter 嵌套 iteration 一旦能 dispatch DmaBuf apply，会再进 nview / ifn / iteration，**同 source 重入把栈打爆**。已否，**不要再 apply `can_recurse`，也不要和 ifn-iter 叠**。

崩后会话：`linux-mainline/scripts/dagu-lab-identity-native.sh` 重开实验室 **163810**（无 `--video`；洞本来就不依赖片）。未 poke。8 s 无 uprobe：`linux-mainline/out/display-stress/dagu-stock-after-crash-8s-20260914.json` kick **106.52 Hz / gt50=7**（225.2 / 191.8 / 114.8 / 108.3 / 91.7 / 91.6 / 84.4），vblank 120.13 / 0。活字全 stock：`0x18ff40=aa0003fa`，`0x1c4388=b40003e1`，`0x1c4404=d65f03c0`，`0x1d2b80` / `0x1d1bd8` 空。

不要再 poke `0x18ff40` / `0xca15d0` / `0x18fdbc`。ifn-iter 单独未否尽（最好 116.95 / gt50=1），崩壳后已丢，可单独再 apply，**禁止**再叠 recurse。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 92. ifn-idle 在 kick 时已有未 dispatch 的 DmaBuf GSource；崩后会话 stock 更差（2026-09-14 续）

新壳 **161892** / lab **163810**（`dagu-lab-identity-native.sh`，无 `--video`）。identity / scale=1 / transform=0。GPU `simple_ondemand` 地板 587 MHz。ifn-iter 已 restore。`tracing_on=1`。

崩后无 uprobe：`linux-mainline/out/display-stress/dagu-stock-after-crash-8s-20260914.json` **106.52 Hz / gt50=7**。只 apply ifn-iter：`linux-mainline/out/display-stress/dagu-ifniter-only-8s-20260914.json` **106.33 Hz / gt50=9**，这窗帮不上，已 restore。不要和 recurse 叠。

`linux-mainline/scripts/dagu-dmabuf-pending-probe.py` 思路（只钩 `0x1c4440` / `0x1c4398` / `0x18fe78` / `0x16e70c`，不钩 `0x1c4388`）→ `linux-mainline/out/display-stress/dagu-dmabuf-pending-20260914.json`（109.4 Hz / gt50=7；**7×ifn-idle**，`n_hasnext=0`）：

| 洞 | attach 相对 kick | 上一记 disp | 下一记 disp | pending |
|----|------------------|------------|------------|---------|
| 6/7 ifn-idle | **−1.3～−11.5** | −8～−19（早于 attach） | **+87～+134** | **是** |
| 1/7（116.6） | −6.55 | −5.68（已 disp） | +2.2 | 否 |

活 so：`g_source_new` funcs prepare/check = NULL，dispatch `0x16e70c` 里对 sync fd 再 `g_poll(timeout=0)`，POLLIN 才 `blr` apply。attach `0x18fe78` **之后没有** `set_ready_time`。identity 整窗 `0x1c4398` 0 次：好帧也是 next==NULL，差别只在 GSource 8 ms 内 dispatch 还是拖 90 ms。

下一刀只改 `0x18fe78`：attach 后若 `[src+152]` 已 POLLIN 则 `g_source_set_ready_time(src, 0)`，不 iteration、不 can_recurse。脚本 `linux-mainline/scripts/dagu-mutter-dmabuf-rdyt0-install.sh`。不要再 poke `0x18ff40`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 93. attach 后 sync fd 已 POLLIN 才 `set_ready_time(0)`：109.38 / gt50=6，已 restore（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。不叠 ifn-iter / recurse。不钩 `0x18fe78`（poke 点）。

`linux-mainline/scripts/dagu-mutter-dmabuf-rdyt0-install.sh apply`：活 `0x18fe78` `bl attach` → `bl cave@0x1d1bd8`。cave 先 `g_source_attach`，再对 `[src+152]` `g_poll(timeout=0)`，POLLIN 才 `g_source_set_ready_time(src, 0)`。壳未崩。

8 s 无 uprobe：`linux-mainline/out/display-stress/dagu-rdyt0-8s-20260914.json` kick **109.38 Hz / gt50=6**（152.7 / 114.9 / 108.5 / 93.0 / 92.0 / 83.3），vblank 120.13 / 0。和崩后 stock / pending 探针窗同量级，**没有**把洞收成 0。已 `restore` 回 `97fb5576`，cave 清零。

读法：洞档在 attach 当下 sync fd **多半还不是 POLLIN**（否则 ready_time=0 应在下一圈 mainloop 就 dispatch）。§90 的 FILE_INFO status=0 和 `g_poll` 不是同一回事。不要再叠 rdyt0 / recurse / poll=0 apply。下一刀对 attach 时 sync fd 的 poll vs FILE_INFO vs 谁在 +90 才让 fd 可读。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 94. FILE_INFO 0=未 signal；一档洞是 DPU `drm_sched` 已 queue 95 ms 不 run（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。stock。不钩 `0x1c4388`。

UAPI `linux-mainline/linux/include/uapi/linux/sync_file.h`：**status 1=signaled，0=active**。§90 把 0 写成「已 signal」是反的。

`linux-mainline/scripts/dagu-syncfd-poll-probe.py` → `linux-mainline/out/display-stress/dagu-syncfd-poll-20260914-084026.json`（109.63 Hz / gt50=7；4×ifn-idle + 3×nview-late）。同一只 dup 上 poll + FILE_INFO：

| 桶 | 全窗 addfd | 洞的 prev addfd |
|----|------------|-----------------|
| steal-fail（fd 已关） | 1065 | 4 |
| st0_poll0（active，不可读） | 54 | **2**（83.5 / 91.7，名 `drm_sched-ring0368-*`） |
| st1_poll0 | 66 | 0 |
| st1_poll1（已 signal 且 POLLIN） | 117 | **1**（108.4，`detached-driver-signaled-timeline`，仍 disp +105） |

整窗 **没有 st0_poll1**。ctx **368=lab / 324=shell**，`drm_sched_job_run` 的 dev 是 **`ae01000.display-controller` ring0**（不是 `3d00000.gpu`）。好帧 queue→run p50=0.04 ms、max=0.58 ms。

`linux-mainline/out/display-stress/dagu-sched-dep-20260914.json` 10 s 8 洞：

| gap | pending | 要点 |
|-----|---------|------|
| 100.1 | 4 | shell 两记 **deps=[]** 仍 q −9.7 / **run +95**；lab 依赖 `shell:139776` 同样到 +90 才 run |
| 118.4 | 1 | 该 job 在 kick 前已 run |
| 其余 6 | 0 | kick 时 sched 空，不是 leftover ioctl；+90 另说 |

两档 ifn-idle：**(A)** 显示控制器 `drm_sched` 把无依赖 job 挂 ~95 ms 才 `run`；**(B)** 无 pending job，GSource 仍晚 dispatch（含已 POLLIN 的 108.4）。不要再按「FILE_INFO 0 = 已 signal」写刀。下一刀只改 `0x18fe78`：attach 后 `g_main_context_wakeup(NULL)`（不 iteration / 不 can_recurse）。脚本 `linux-mainline/scripts/dagu-mutter-dmabuf-wakeup-install.sh`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 95. attach 后 `wakeup(NULL)`：107.25 / gt50=8，已 restore（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。不叠 ifn-iter / recurse / rdyt0。不钩 `0x18fe78`。

`linux-mainline/scripts/dagu-mutter-dmabuf-wakeup-install.sh apply`：活 `0x18fe78` → cave `g_source_attach` + `g_main_context_wakeup(NULL)`。壳未崩。

8 s 无 uprobe：`linux-mainline/out/display-stress/dagu-wakeup-8s-20260914.json` kick **107.25 Hz / gt50=8**（116.8 / 116.6 / 108.4 / 108.3 / 108.1 / 100.0 / 91.8 / 83.6），vblank 120.13 / 0。不优于 stock。已 `restore` 回 `97fb5576`。

读法：B 档（已 POLLIN / 无 pending job）不是「attach 时 default context 的 ppoll 还是旧 fd 集」。wakeup(NULL) 盖不住 A 档（`drm_sched` 95 ms 不 run），也叫不醒 B 档。不要再叠这条 wakeup。下一刀对 **为什么 `ae01000.display-controller` ring0 无依赖 job 要到 +95 才 `drm_sched_job_run`**，以及 B 档 +90 仍不是 POLLIN 的那只 fence。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 96. Type A 不是 credit/ENOSPC；`queue_work` 后 ring0 worker 近 100 ms 不 execute（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。stock。`CONFIG_KPROBES is not set`。不钩 `0x1c4388`。

`drm_sched_job_queue` 的 `hw job count` 就是 `credit_count`，`job count` 是 push **之前** 的 entity 队列深度（0 = first，会 `drm_sched_wakeup`）。

`linux-mainline/scripts/dagu-sched-credit-probe.py` → `linux-mainline/out/display-stress/dagu-sched-credit-20260914-085605.json`（100.7 Hz / gt50=8；A×4 / B×4）：

| 项 | 值 |
|----|----|
| 全窗 jobs | 3216，**只有** shell 1608 + lab 1608，没有第三 ctx 占信用 |
| `n_unsched` | **0**（`drm_sched_job_unschedulable` 整窗没打） |
| Type A `hw_q` | **全是 0**（credit_limit=8，不是 ENOSPC） |
| Type A `n_first` | 每洞 1（头 job `job_count=0`，应当 wakeup） |
| Type A first run | +90～+103 ms |
| Type B | kick 时 pending=0、inflight=0 |

`linux-mainline/linux/drivers/gpu/drm/scheduler/sched_main.c`：`drm_sched_select_entity` 把 `ERR_PTR(-ENOSPC)` 收成 **NULL** 后 `run_job_work` **直接 return、不 requeue**。本窗 Type A 的 `hw_q=0`，对不上这条。

`linux-mainline/scripts/dagu-sched-wq-probe.py` → `linux-mainline/out/display-stress/dagu-sched-wq-20260914-090013.json`（112.13 Hz / gt50=4）。真 Type A 一档 **101.3**：shell 两记 + lab 两记 `q −9.7 / −8.4`，`jc=0` 那记对应 `workqueue_queue_work` **−9.67**（`drm_sched_run_job_work`），但 kick 前最后一次 `execute_start` 是 **−14.26**，`drm_sched_job_run` 要到 **+95.87**。不是 worker 卡在 `msm_job_run` 里（那会先打 `job_run`）。是 **ordered `ring0` WQ 对已 queue 的 `work_run_job` 拖了 ~105 ms 才 execute**。板上 `kworker/u32:*-ring0` 空闲时栈是 `worker_thread`。GPU `msm_gpu_suspend` 多在 +57～+91，是洞的**结果**（66 ms autosuspend），不是原因；`power/control=on` 已否。

116.6 那档 pending 两记 shell 在 kick **−0.7 已 run**，算错成 A：GPU 准时，仍是 compositor IDLE（B）。

---

## 97. attach 后无条件 `set_ready_time(0)` + `wakeup(NULL)`：113.33 / gt50=4，已 restore（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。不叠 ifn-iter / recurse / rdyt0。不钩 `0x18fe78`。

`linux-mainline/scripts/dagu-mutter-dmabuf-ready-always-install.sh apply`：cave `attach` + **无条件** `g_source_set_ready_time(src, 0)` + `g_main_context_wakeup(NULL)`。壳未崩。

8 s 无 uprobe：`linux-mainline/out/display-stress/dagu-ready-always-8s-20260914.json` kick **113.33 Hz / gt50=4**（113.6 / 110.7 / 83.6 / 75.3），vblank **117.0 / gt50=3**（比日常 120 / 0 差）。未消洞，且伤了 vblank。已 `restore` 回 `97fb5576`，cave 清零。

读法：rdyt0（仅 POLLIN）和 wakeup 单独已否；二者叠上且 **不管 fd 是否可读都 ready_time(0)** 仍盖不住 A 档 WQ 晚 execute，也没把 B 档收到 gt50=0。不要再叠这条。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 98. ring0 FIFO 更差；DmaBuf `prepare` 8 ms 回查 116.85 / gt50=2，已 restore（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。stock 后再试。不钩 `0x1c4388`。

ring0 `kworker/u32:*-ring0` `chrt -f 1`（不碰 `kworker/R-ring0`）：`linux-mainline/out/display-stress/dagu-ring0-fifo-8s-20260914.json` kick **96.5 Hz / gt50=3 / max 186.9**，vblank 116.21 / gt50=1。不是「worker 可跑但 SCHED_OTHER 排不上」。已写回 SCHED_OTHER。不要再 `chrt` ring0。

`linux-mainline/scripts/dagu-sched-wq-probe.py` 加 inflight / long_run 后再采：`linux-mainline/out/display-stress/dagu-sched-wq-20260914-091001.json` 唯一 gt50=**256.4** 档 GPU 在 kick **−0.4 已 run、dur 0.7–1.6 ms**，`long_run=[]`。这是 **B-idle**（合成停、fence 不挡），不是 Type A WQ 挂死。A 档 `queue_work` 晚 execute 仍是上一窗的事实，不是每个洞都有。

GNOME mutter 50.1 `meta_wayland_dma_buf_source_funcs` 活表：`prepare`/`check` = NULL，dispatch `0x16e70c` @ `0x2b2bc8`（rw）。`linux-mainline/scripts/dagu-mutter-dmabuf-prepare8-install.sh apply`：`prepare` → cave `0x1d1bd8`（`*timeout=8`；`[src+152]` POLLIN 则 TRUE）。壳未崩。

8 s 无 uprobe：`linux-mainline/out/display-stress/dagu-prepare8-8s-20260914.json` kick **116.85 Hz / gt50=2**（116.7 / 75.1），vblank **119.37 / gt50=1**（58.3）。比崩后 stock 好，**不是** ≈120 且 gt50=0；vblank 还出了 50 ms+。已 `restore` prepare=NULL、cave 清零。`0x18fe78` 仍 `97fb5576`。

读法：8 ms 回查盖不住「fence 90 ms 才 signal」和「没有 GSource 的 IDLE」。不要再叠这条 prepare。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 99. FIFO 残留已撤；当前洞全是 B-idle，且 kick 时 DmaBuf GSource 已 disp；IDLE+deadline 立刻 emit 更差（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。`cpuidle.off=1`，`default_affinity_scope=system`。磁盘+活仍在：infence skip-poll `0x1bd9d8=0x1400000a`、wakeup cave、`dri_flush` NOP（shell 与实验室 gallium 都是 `0x1cf740=mov x3,#0` / `0x1cf74c=nop`）。`0x1c4388` / `0x1c4404` / `0x18fe78` / prepare 表 / cave 空。`GSK_RENDERER=gl`。

FIFO 测试留下 `kworker/u32:*-ring0` **SCHED_FIFO**（87274 / 185395），已 `chrt -o 0` 写回 SCHED_OTHER。不要再 `chrt` ring0。

测 8 s 前必须确认 `events/dpu/dpu_enc_kickoff/enable=1`：有一窗 kickoff 被关，只剩 vblank 120.12 / gt50=0，**不能当验收**。

FIFO 撤后无 uprobe：`linux-mainline/out/display-stress/dagu-fifo-restore-8s-20260914.json` kick **112.86 Hz / gt50=3**（250.0 / 116.8 / 75.0），vblank 120.12 / 0。加 `drm_sched_job_{queue,run}`（不扫 workqueue）：`linux-mainline/out/display-stress/dagu-fifo-restore-sched-20260914.json` **113.0 / gt50=3**，三档全是 **B-idle**（kick 时无 inflight、无 late_run）。Type A 本窗 0。

`linux-mainline/scripts/dagu-dmabuf-pending-probe.py`（补了 sendcb，卸 uprobe 时关 `events/uprobes`）→ `linux-mainline/out/display-stress/dagu-dmabuf-pending-20260914-092842.json`（110.95 Hz / gt50=6，探针税）。`n_hasnext=0`，**6/6 `pending_at_kick=false`**（kick 前一记 attach 已经 disp）。nview 全在 +0.0～+0.11。洞不是「kick 时卡住的 DmaBuf GSource」，分成三档：

| gap | nview | sendcb | attach/disp after | 读法 |
|-----|-------|--------|-------------------|------|
| 108.0 / 75.2 | +0.1 | **+68～+108** | +73～+116 | GTK 冻到洞末才 commit |
| 83.3 | +0.08 | **+0.06** | attach **+0.81** / **disp +82.97** | sendcb 准时，**kick 后**才 attach，fence 等 82 ms |
| 108.2 | +0.11 | **+109** | attach +0.22 / disp **+0.93** | 已 apply，**没 emit** |
| 114.9 / 113.9 | +0.0 | +3～+8 | attach +2～+6 / disp +4～+7 | apply+sendcb 都早，**下一记 kick 仍晚 100 ms** |

GNOME mutter 50.1 `on_after_update`（活 `0x169668`）：PENDING 立刻 emit；IDLE 若 `frame_deadline` 在未来则 `g_source_set_ready_time` 交给空帧 GSource `0x167440`。轻窗这条 GSource 仍 0 次 dispatch。已否过 `0x169668` `cbz`→`tbz/#1` 与 `b emit`（108 Hz destile）。本轮只改 **IDLE+未来 deadline** 那条：`0x16968c mov x0,x19` → `b 0x1696ac`（不碰 IGNORED）。脚本 `linux-mainline/scripts/dagu-mutter-idle-deadline-emit-install.sh`。壳未崩。

8 s 无 uprobe：`linux-mainline/out/display-stress/dagu-idle-deadline-emit-8s-20260914.json` kick **105.86 Hz / gt50=9**（208.5 / 116.8 / …），vblank 仍 120.12 / 0。比 FIFO 撤后基线差。已 `restore` `0x16968c=0xaa1303e0`。**不要再 apply。**

下一刀只打 83.3 那档（kick 后 attach、disp 晚 80 ms）或 114.9 那档（apply 后钟 IDLE 不 kick），不要再 after_update emit。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 100. apply_state `schedule_update` 后 wakeup：114.9/83.3 档基本没了；轻窗仍 gt50=1–4，剩余以 nview-late / 嵌套 acquire 为主（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。`cpuidle.off=1`，`default_affinity_scope=system`。`GSK_RENDERER=gl`。`3d00000.gpu` `power/control=auto` delay=66ms。活 mutter `0x7fb1ee0000`。

磁盘+活仍在（不要 restore）：infence skip-poll `0x1bd9d8=0x1400000a`、wakeup cave `0x1d6ee4=bl` 近址、`dri_flush` NOP（shell 与实验室 gallium `0x1cf740=mov x3,#0` / `0x1cf74c=nop`）。`0x1c4388` stock `cbz`，`0x1c4404=ret`，`0x18fe78` stock，`0x169668`/`0x16968c` stock。`0x1c43f4` stock `tbnz`。

### apply-wakeup 仍在

只打 Wayland `apply_state` 里那条 `bl clutter_stage_schedule_update@plt@0x66374`（`0x16517c`），改 `bl cave@0x1d2b80`：仍调 `schedule_update`，再 `g_main_context_wakeup(NULL)`。不是全员 `set_ready_time` 后 wakeup（`dagu-clutter-sched-wakeup-install.sh` 已否 destile）。脚本 `linux-mainline/scripts/dagu-mutter-apply-sched-wakeup-install.sh`。活字 `0x16517c=0x9401b681`。**不要对已 poke 的 `0x16517c` 下 uprobe。**

FIFO 撤后基线：`linux-mainline/out/display-stress/dagu-fifo-restore-8s-20260914.json` **112.86 Hz / gt50=3**。

apply-wakeup 后无 uprobe：

| 窗 | 文件 | Hz | gt50 | max | vblank |
|----|------|----|------|-----|--------|
| a | `linux-mainline/out/display-stress/dagu-apply-sched-wakeup-8s-20260914.json` | 115.47 | 2 | 116.7 | 120.12 / 0 |
| b | `linux-mainline/out/display-stress/dagu-apply-sched-wakeup-8s-b-20260914.json` | 116.96 | 2 | 91.7 | 120.12 / 0 |
| 3×8s | `linux-mainline/out/display-stress/dagu-apply-wakeup-3x8s-20260914.json` | 104.84 / **117.63** / 103.8 | 4 / **1** / 3 | 114.7 / 116.7 / 150.1 | 三窗都 120.12 / 0 |

比 FIFO 撤后好过一阵，**不是**稳满 ≈120 且 gt50=0。一窗 impl+nview 探针碰巧 119.4 / gt50=0 / max 18.6（`linux-mainline/out/display-stress/dagu-apply-wakeup-impl-nview.json` 板上 `/tmp`），关 uprobe 立刻回来。117.63 / gt50=1 **不算过**。

### 轻分类（不钩 `0x16517c` / 不钩 `0x1d6ee4`）

`linux-mainline/out/display-stress/dagu-apply-wakeup-flip-nview-20260914.json`（kickoff+`complete_flip`+nview，探针税 113.98 / gt50=3）：三档全是 **kernel flip +4.8～+6.2，nview +104～+110**。kick=flip=nview=911。vblank 仍 120.12 / 0。不是 kick-late。

sendcb 窗 `linux-mainline/out/display-stress/dagu-send-before-20260914.json`（113.49 / gt50=3）：`n_send=n_thaw=n_idle=n_kick`。三档 nview +105～+110，上一记 send/thaw/idle 在 kick **之前**（−1.5～−14），下一记挤在洞末。一档 attach +1.07 仍 nview +110。

钩 `queue_callback`（4568 次，税）会改洞的形态，不当基线：`linux-mainline/out/display-stress/dagu-apply-wakeup-qcb-nview-20260914.json` 出现 nview-ok-post-late 与一档 kick-late。

### KMS callback 源：qcb 已入队，主线程 90ms 不 dispatch

进程内源 `[mutter] MetaThread 'KMS thread' callback source` 在 `0x557f053bf0`，prio **−99**，`main_context` 与 default `0x557ec901f0` 同一只。只读 `/proc/<pid>/mem`，不 uprobe。

`linux-mainline/out/display-stress/dagu-apply-wakeup-kms-src-poll-20260914.json`（税 107.3 / gt50=6）：6 档里 4 档从 +1 ms 到 +90 ms 都是

- 主线程 `sys=running`，`ocnt=2`
- 源 `ready=0`、`needs_flush=1`、`callbacks` **同一只指针卡住**
- 源自身 `flags=0x1`（ACTIVE，**不是** IN_CALL）

和 §70 同一句话：wakeup / `set_ready_time` 已经发生，GLib 不回到这只源的 dispatch。一档 130.4 在 +13 ms 已 `ready=-1`/`cbs=0`（dispatch 过了）下一记 kick 仍晚；一档 108.4 整段 `ppoll` 且 `cbs=0`（present 回调没入队）。

### 卡住时主线程 PC（短 INTERRUPT，KMS 未 seize）

源 `callbacks` 非空且 `ready=0` 超过 ~20 ms 才采。壳仍是 **161892**。

`linux-mainline/out/display-stress/dagu-apply-wakeup-stuck-pc-20260914.json` 一记落在 `libEGL_mesa+0x13d84`（`cogl_onscreen_swap_buffers_with_damage` 栈）。

`linux-mainline/out/display-stress/dagu-apply-wakeup-stuck-pc2-20260914.json` 三记：

| dt_stuck | PC | FP |
|----------|----|----|
| 23.9 / 23.7 | libc syscall wrapper（§71 说过不能当业务 PC） | glib iterate → `meta_context_run_main_loop` `0xfa634` → gjs `+0x5e350` → mozjs `+0x1706b0` |
| **118.3** | **`libmozjs-140+0x61dc84`** | glib idle `blr` `+0x6240c` → dispatch `+0x606f8` → 同上 gjs/mozjs |

KMS thread 都是 `ppoll`（回调已入队）。JS Helper 在 `futex`。这还是 §71 那类 **Incremental GC 占着 default 的 IN_CALL**，不是 apply-wakeup 没叫醒。不要再 apply `JS_GC` / MaybeGC / idle-defer / iter-slice / KMS interrupt / 4ms `JS_GC` budget。

不要再 apply：after_update emit、IDLE+deadline emit、全员 sched-wakeup、GDK 解冻、DmaBuf prepare 8ms、ring0 FIFO、CAN_RECURSE / callback prio / `.check`。apply-wakeup **留着**。

验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 101. `JS_GC` 体 `0x62cee0` 不调 `checkOverBudget`；1ms budget / always-over / inc-slice / 跳过 trigger 都没把轻窗钉到 ≈120 / gt50=0（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。apply-wakeup 仍在（`0x16517c=0x9401b681`）。GC 试验都只 live，已全部 restore。gjs `0xa864c` stock `bl JS_GC`，mozjs `0x44c730` stock unlimited，`checkOverBudget` stock。

卡住 PC `libmozjs-140+0x61dc84` 是 `js::gc::EdgeNeedsSweepUnbarrieredSlow<JSAtom>`。`JS_GC`（`0x44c6e0`）在 `0x44c750` **一次** `bl 0x62cee0`（约 3136 字节）。`0x62cee0` 里 **0 次** `bl SliceBudget::checkOverBudget@0x60c220`。所以给 `JS_GC` 换 TimeBudget 或把 `checkOverBudget` 改成永远 true，都切不进这条 sweep。`checkOverBudget` 的调用点在 `0x657ab0` 一类 mark/sweep 辅助函数，走的是 `IncrementalGCSlice`，不是这条 BIG_HAMMER。

| 刀 | 脚本 | 轻 3×8s（无 uprobe） | 处理 |
|----|------|---------------------|------|
| `JS_GC` 1ms TimeBudget | `linux-mainline/scripts/dagu-mozjs-gc-budget-1ms-install.sh` | 115.25/gt50=2；117.72/1；113.65/3 max **166.8** | 已 restore |
| `checkOverBudget` 永远 true | `linux-mainline/scripts/dagu-mozjs-overbudget-always-install.sh` | 115.5/3；117.79/1；111.59/4 max **208.4** | 已 restore |
| inc-slice + apply-wakeup | `linux-mainline/scripts/dagu-gjs-inc-slice-install.sh` | 115.47/2；116.39/2；114.69/2 max **216.7** | 已 restore |
| `0xa8644` `tbz`→`b a8650`（trigger 两条 GC 都不走） | 只 live | 111.8/2 max **232.9**；112.16/2；**117.87 / gt50=0 / max 17.4** | 已 restore。第三窗 gt50=0 但 Hz 不是 ≈120；前两窗更差。剩余 Type B **不是**只靠这条 trigger |

抓痕：

- `linux-mainline/out/display-stress/dagu-gc-budget-1ms-3x8s-20260914.json`
- `linux-mainline/out/display-stress/dagu-overbudget-always-3x8s-20260914.json`
- `linux-mainline/out/display-stress/dagu-inc-slice-awake-3x8s-20260914.json`
- `linux-mainline/out/display-stress/dagu-skip-trigger-gc-3x8s-20260914.json`
- restore 后 `linux-mainline/out/display-stress/dagu-awake-after-gc-restore-2x8s-20260914.json`：112.16 / gt50=4 与 110.86 / gt50=4

不要再 apply：4ms/1ms `JS_GC` budget、`checkOverBudget` 永远 true、inc-slice、iter-slice、idle-defer、MaybeGC、skip-hammer、KMS interrupt、跳过 trigger 两条 GC。apply-wakeup **留着**。

验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 102. GLib `g_main_dispatch` 进入/离开：Type B 不是单一 IN_CALL（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。apply-wakeup 仍在（`0x16517c=0x9401b681`）。infence skip-poll / wakeup cave / `dri_flush` NOP 仍在。不 poke。不钩 `0x16517c` / `0x1d6e40`。

活 `libglib-2.0.so.0.8800.0`：`g_main_context_dispatch` 里对 `GSourceFuncs.dispatch` 的 `blr x27` 仍在 **`0x606f4`**（`0xd63f0360`），下一指令 **`0x606f8`** 为离开。idle/timeout 跳板 `0x623e4` / `blr x1` `0x62408` 仍在。Mutter `callback_source_dispatch` `0x1d5d00`、`notify_view_crtc_presented` `0x1c4440` 仍是 stock `PACIASP`。

探针 `linux-mainline/scripts/dagu-glib-enter-leave-probe.py`：用栈配对 gs/ge（不再用单变量 `pending`）。抓痕 `linux-mainline/out/display-stress/dagu-glib-enter-leave-20260914-101837.json`（探针税 kickoff **113.2 Hz / gt50=4**，不当验收）。测完 `tracing_on=1`、`dpu_enc_kickoff/enable=1`、uprobe 空。

整窗：

| 项 | 值 |
|----|-----|
| `n_gs` / `n_ge` | **4513 / 4513**，`n_mismatch=0` |
| `max_depth` | **1**（没有嵌套 `g_main_dispatch`） |
| ≥2 ms 的 dispatch | 35 |
| ≥8 ms 且能 ident | 一只无名 **prio 300** idle（`libglib+0x623e4`），一只 prio 0 |

`ocnt=2` 不是「dispatch 套 dispatch」。本窗主线程一次只在一只 GSource 的 `dispatch` 里。

四档 ≥50 ms 洞拆成两类，**不能**都写成「上一只 GSource 占着 IN_CALL」：

| gap | kind | flip | nview / `callback_source_dispatch` | kick 时是否在 dispatch 里 |
|-----|------|------|--------------------------------------|---------------------------|
| 123.4 | nview-ok-post-late | −1.3 / **+7.0** | nview **+10.3**（准时），下一记 kick 在洞末 | 有一只 cover，age 0.57 ms，不到 2 ms 就离开，盖不住 123 ms |
| 91.6 | **B-nview-late** | **+4.0** | **+82.8**（cbs 与 nview 同一毫秒） | **`ncover=0`**，洞内也没有 ≥8 ms dispatch |
| 91.7 | nview-ok-post-late | **+4.2** | **+4.3** 准时，下一记 kick 仍晚 87 ms | `ncover=0` |
| 90.7 | **B-nview-late** | **+3.0** | **+83.7** | 无名 prio **300** idle：enter −0.08，leave **+83.58**（83.66 ms），nview 在 leave 后 **0.08 ms** |

读法：

1. **有一档 Type B 就是 GLib 合作式 dispatch。** 90.7 ms 洞：prio 300 idle 从 kick 附近进到 +83.58 才 `ge`，−99 的 KMS callback 只能等。leave 和 nview/cbs 对齐到 0.1 ms。
2. **另一档 Type B 的 80 ms 不在任何 `g_main_dispatch` 里。** 91.6 ms 洞 flip 准时，kick 时栈空，整洞没有 ≥8 ms 的 gs/ge，直到 +82.8 才进 `callback_source_dispatch` 并立刻 nview。空档在 **两次 dispatch 之间**（`ppoll` / iterate 的 wait），不是正在跑的那只 source。
3. **nview 准时仍可以没有下一记 kickoff**（123.4 / 91.7）。GLib 已经把 present 派完，卡在 `maybe_post` / 钟 IDLE，不是「callback 源进不去」。

§51 的「B-main = 上一只长 GSource」只覆盖本窗 4 洞里的 1 档。§49 用 prepare `blr` 数出「没有 ≥2 ms dispatch」是钩错站点。本窗 `max_depth=1`，不要再用嵌套 dispatch 解释 `ocnt=2`。

不要再 apply GC 刀 / CAN_RECURSE / callback prio。apply-wakeup **留着**。本刀只计时，没有 poke。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 103. Sysprof 50 compositor marks：洞要么没有钟，要么钟晚到后卡在 `eglSwapBuffers`（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。apply-wakeup / infence skip-poll / wakeup cave / `dri_flush` NOP 仍在。不 poke，不 LD_PRELOAD gnome-shell。板上新装 `sysprof` **50.0-1**。必须用会话用户 `dagu` 的 `DBUS_SESSION_BUS_ADDRESS` 跑 `sysprof-cli --gnome-shell`；root 只录到 Scheduler，没有 Compositor。`org.gnome.Shell` 的 `org.gnome.Sysprof3.Profiler` 已在。polkit agent 断言失败不影响 compositor fd。

对齐窗（10 s，税不当验收）：kickoff **111.26 Hz / gt50=7**（119.5 / 116.3 / 108.6 / 108.4×2 / 91.5 / 66.7）。抓痕：

- `linux-mainline/scripts/dagu-sysprof-align.py`
- `linux-mainline/out/display-stress/dagu-sysprof-align-20260914.syscap`
- `linux-mainline/out/display-stress/dagu-sysprof-align-20260914.json`
- `linux-mainline/out/display-stress/dagu-sysprof-align-summary-20260914.json`
- `linux-mainline/out/display-stress/dagu-sysprof-align-holes-20260914.json`

另一次 10 s（只 compositor）：`linux-mainline/out/display-stress/dagu-sysprof-gs-20260914.syscap`。

Compositor 每帧站点次数约 **1077–1078**（约 108 Hz），与 kickoff 同量级。KMS 线程 `do_process` p50 **0.14 ms**、max **5.13 ms**；`atomic_page_flip_handler` 可忽略。`maybe_post_next_frame` p50 **0.011 ms**、max **0.09 ms**（它跑的时候不堵）。`presented()` 本对齐窗 p50 **0.01 ms**、max **0.04 ms**。`paint_view` max **0.47 ms**。

整窗 compositor mark p50 **0.014 ms**、p99 **1.25 ms**。≥50 ms 的 span **12** 条，全部来自 **两记** 嵌套的钟 dispatch：

`FrameClock::dispatch` → `FrameListener::frame` → `redraw_view_primary` → `swap_framebuffer` → `swap_buffers` → **`egl_swap_buffers_with_damage` ≈107 ms**。message：`DSI-1, dispatched 43–44 µs late`（deadline 几乎准时，函数体却跑了 108 ms）。

与 kickoff 洞对钟（同一 `CLOCK_MONOTONIC`）：

| gap | 洞前 80–100 ms 有无 compositor ≥2 ms | 读法 |
|-----|--------------------------------------|------|
| 116.3 接着 108.4 | 无，然后 **+101** 才进 `dispatch`/`egl_swap` 107 ms，跨进下一洞 | 先空转，再一记超长 swap 吃掉下一记 kick |
| 91.5 接着 108.4 | 无，**+80** 才进同样的 108 ms swap | 同上 |
| 108.6 / 119.5 / 66.7 | **整洞 0 条** compositor ≥2 ms | 钟没在跑；不是 paint/swap 慢 |

Sysprof 没有 GLib idle 源名字（那要 USDT/`--speedtrack` preload，本刀没往 gnome-shell 打 preload）。它确认的是 Mutter 这一层：

1. 长洞里 **KMS 线程不慢**。
2. `maybe_post` 本身不是 80 ms 函数。
3. 有 compositor 活动的洞，长栈顶是 **`eglSwapBuffers`**，而且往往在 kick 后 **80–101 ms** 才开始——前面那段空白就是 §102 的「两次 dispatch 之间」。
4. 另有整洞 compositor 安静，对应 nview 已过仍不 kick / 主循环在 poll。

`dri_flush` NOP 仍在，对齐窗仍出现 107 ms `egl_swap`，所以无限等 `throttle_fence` 不是这一档的全部。测完 `tracing_on=1`、`dpu_enc_kickoff/enable=1`、uprobe 空。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 104. dma-fence + DRM/DPU ftrace：`eglSwapBuffers` 不在 `dma_fence_wait` 里堵（2026-09-14 续）

ubuntu **161892** / lab **163810**。#172。不 poke。板上没有 `trace-cmd`，用 debugfs ftrace。没有 `drm:drm_atomic_commit`，用 `drm_msm_atomic` 的 `commit_tail` / `wait_flush`。没有 `msm_dpu` 子系统，DPU 在 `events/dpu/`。

探针 `linux-mainline/scripts/dagu-fence-drm-probe.py`。开了：`dma_fence_wait_{start,end}`、`dma_fence_signaled`、`drm_vblank_event` / `delivered`、`dpu_enc_kickoff` / `prepare_kickoff` / `complete_flip` / `vblank_cb` / `frame_done_cb`、`msm_atomic_commit_tail_{start,finish}`、`msm_atomic_wait_flush_{start,finish}`。未开 `dma_fence_init/emit`（量太大）。测完只留 kickoff + vblank_cb，`tracing_on=1`。

12 s 窗 `linux-mainline/out/display-stress/dagu-fence-drm-20260914-104530.json`（8 s 窗 `...-104505.json` 只有 1 个 66.9 ms 洞，形态相同）：

| 项 | 12 s |
|----|------|
| kickoff | **112.54 Hz / gt50=4**（116.8 / 108.5 / 100.0 / 83.5） |
| vblank | **120.08 Hz / gt50=0** |
| `dma_fence_wait_start/end` | **1349 / 1349**（与 kickoff 1:1） |
| `dma_fence_signaled` | 16188 |
| `wait` ≥8 ms | **0** |
| wait 的 comm | 全是 `kworker/*H`，**没有 gnome-shell** |
| wait timeline | 全是 **`signaled-timeline`** |

四档洞共同：vblank 仍按 ~8.3 ms 扫（11–15 拍）。`dma_fence_wait` 只在 commit worker 上碰到已 signal 的 dummy fence，对不上 80–110 ms。gnome-shell 整窗 **0** 次 `dma_fence_wait_start`。Sysprof 里 107 ms 的 `eglSwapBuffers` **不是**内核 `dma_fence_wait`。

洞内 KMS/DPU：

| gap | flip / delivered | `wait_flush` | 下一记 `commit_tail_start` |
|-----|------------------|--------------|---------------------------|
| 108.5 | **+4.0** | +0.01 → **+4.04**（~4 ms） | **+108.3** |
| 100.0 | +7.6 | +0.01 → +7.55 | **+99.8** |
| 83.5 | +7.4 | +0.01 → +7.38 | **+83.2** |
| 116.8 | **+111.2** | +0.01 → **+111.2**（**111 ms**） | +116.6 |

前三档：本帧 `prepare`/−0.1、kick、`frame_done`/`complete_flip`/`delivered` 都在 +4～+8 ms 结束，下一记 `prepare`/`commit_tail` 在洞末。内核已经做完，用户态没交下一笔 atomic。`wait_flush` 不是 50 ms 卡死。

116.8 那档是少数内核档：`commit_tail` 从 −0.2 跑到 +111，`wait_flush` 第二段 111 ms，`complete_flip` 跟着到 +111。这是 **CTL flush `wait_event`**，不是 `dma_fence_wait`。`frame_done_cb` 已在 +7.2。不要把这档写成 egl 等 fence；也不要据此去刷已否的 8 ms `wait_for_commit_done`（§21 多数洞仍是 0–6 ms）。

结论：用户点的 fence 同步链在 Type B 主导档上是空的。`eglSwapBuffers` 若再堵，要看用户态 poll/syncobj/ioctl，不是 `dma_fence_wait_*`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 105. 内核档：每帧 `dpu_encoder_prep_dsc` 重绑 DSC（2026-09-14）

Mainline 在 `linux-mainline/linux/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c` 的 `dpu_encoder_prepare_for_kickoff()` 里，**每一记 kickoff** 都跑 `dpu_encoder_prep_dsc()`。`dpu_encoder_dsc_pipe_cfg()` 会：

1. `dsc_config` + `dsc_config_thresh` 重写 PPS
2. `dsc_bind_pingpong_blk(hw_dsc, hw_pp->idx)` — 日志 `Binding dsc:0 to pp:0` / `Binding dsc:1 to pp:1`
3. `enable_dsc`
4. `update_pending_flush_dsc` → `pending_flush_mask` 带 **bit22 DSC**（现场一直是 `0x4218c0`）

解绑只在 disable 的 `dpu_encoder_unprep_dsc()`。L81A 面板 `linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c` 写死 `dsc_enabled = true`，120 Hz 双 DSC。

这解释 **少数内核档**（§104 的 116.8 ms：`wait_flush` 111 ms；bpftrace 约 7600 次 commit 里 7 次 107–219 ms `WAIT_FLUSH≈COMMIT_TAIL`）。**不要**把 Type B 主档（用户态 `ppoll` 空等、下一记 `commit_tail` 晚到）写成 DSC。也不要关 DSC、不要降 60 Hz。

落地：`linux-mainline/scripts/apply-overlays.sh` marker `dagu: skip redundant DSC prep`；笔记 `linux-mainline/patches/dpu-skip-redundant-dsc-prep.patch`。enable / `hw_reset` / runtime resume 仍 bind；后续 kickoff 跳过。

### 刷入 #175（2026-09-14 11:26 CST）

`DAGU_PRIMARY_ENTRY_PROBE=0 DAGU_MINIMAL=1 DAGU_DISPLAY=1` 编 `linux-mainline/scripts/build-kernel.sh`，`linux-mainline/scripts/build-bootimg.sh`，只刷 B：`linux-mainline/scripts/flash-boot.sh flash-b`。`linux-mainline/linux/arch/arm64/kernel/head.S` `primary_entry` 仍直接 `bl record_mmu_state`。USB `0525:a4a7` 保持，未返 `18d1:d00d`。

| 项 | 结果 |
|----|------|
| DRM debug 0x14（printk=8，~3–15 s atomic） | `drm_atomic_nonblocking_commit` 有；**`Binding dsc` = 0**（boot enable 之后不再绑） |
| `pending_flush_mask` | **`0x218c0`**（137408），**没有 bit22 DSC**；此前每帧 `0x4218c0` |
| 8 s identity 轻窗 `linux-mainline/out/display-stress/dagu-native-lab-20260914-113121.json` | kickoff **105.18 Hz / gt50=7**（208.7 / 208.4 / 116.8 / 115.3 / 108.4 / 99.9 / 83.4）；vblank 120.12 / gt50=0 |
| 25 s bpftrace `linux-mainline/out/display-stress/dagu-dpu-flush-bt-20260914-1132-dscskip.txt` | 约 2700+ `wait_flush` 里 **1 次 110 ms**，pend 仍是 `0x218c0`；`dpu_hw_dsc_bind_pingpong_blk` 8 s **0 次** |

每帧重绑 DSC 是真的、已经停掉；**它不是 Type B 主档**（用户态仍不交下一笔 atomic）。去掉 DSC flush 之后 **110 ms `WAIT_FLUSH` 仍能出现**，所以 111 ms 内核档也不是「只有 DSC 消化不良」。不要关 DSC、不要降 60 Hz。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 106. Looking Glass / `Meta.add_verbose_topic(KMS)`（2026-09-14 11:57）

GNOME 50.1 `Eval` 被拒（`unsafe_mode=false`）。`Main.lookingGlass` 要 Alt+F2 `lg` 才创建，本会话一直 `present=false`。没有 `gnome-shell --replace`。

把 Looking Glass 会开的话题写进已扫描的 `dagu-snap@local`：`Meta.add_verbose_topic(KMS)` + `KMS_DEADLINE`，`Clutter.add_debug_flags(PAINT_MAX_RENDER_TIME)`。脚本 `linux-mainline/scripts/dagu-lg@local/`。12 s 窗 identity lab 仍是 pid 4958。测完 restore snap 原文、`org.gnome.shell disable-user-extensions=true`，KMS journal 已静音。

| 项 | 结果 |
|----|------|
| kickoff | **91.88 Hz / gt50=6**（KMS printk 本身把帧率打下来） |
| vblank_cb | 115.16 Hz |
| journal 到的 commit | 79（限速）；flags **全是** `ATOMIC_NONBLOCK\|PAGE_FLIP_EVENT` |
| `IN_FENCE_FD` | **每笔都是 99** |
| FRR dispatch | completed p50 533 µs / max 2605 µs，距 vblank 起最少 1824 µs；**0 次错过** |
| Page flip callback | 与 journal commit 1:1 |

结论：Looking Glass 的 KMS 话题与 §事件投递 的 ioctl 一致——能看到的 commit 都订了 flip。FRR 在扫前做完，**不是 Type B 主档**。每帧 `IN_FENCE_FD=99` 说明 `linux-mainline/patches/mutter-50-msm-no-explicit-infence.patch` 重启后没了；本窗未重上。不要把 Type B 写成「忘订 PAGE_FLIP_EVENT」或「KMS deadline 错过 vblank」。

完整记录：`linux-mainline/out/display-stress/dagu-lg-looking-glass-20260914-1157.md`、`linux-mainline/out/display-stress/dagu-lg-kms-20260914-1157.journal`。

---

## 107. offwaketime：flip 之后谁叫醒主线程（2026-09-14 12:10）

网上对口工具是 BCC **`offwaketime`**（Brendan Gregg：睡着的栈 + 叫醒者栈）。板上 `offwaketime-bpfcc` 需要 `/sys/kernel/debug/tracing/available_filter_functions`，没有（`FUNCTION_TRACER` 未开）。同一观测用 `linux-mainline/scripts/dagu-offwake-main.bt`：`sched_switch`/`sched_wakeup` + **`kprobe:try_to_wake_up`**。只 `sched_wakeup` 会把叫醒者记成 `swapper`（远程 `ttwu` 在目标 CPU 上走 IPI `sched_ttwu_pending`）。

未重启 gnome-shell。12 s：`linux-mainline/out/display-stress/dagu-offwake-ttwu-20260914-1210.txt`（kick 1391 / hole 6，税不当验收）。

≥40 ms 那一觉的 **`try_to_wake_up` 真实调用者**只有两个：

1. **identity lab python3 4958**：`gsk_renderer_render` → `wl_display_flush` → `unix_stream_sendmsg` → 合成器 wayland fd。
2. **KMS thread 1253**：`drmHandleEvent` → `meta_thread_queue_callback` → `g_source_set_ready_time` → `eventfd_write`。

洞分两档，都对得上：

- **npr 准时（+3 ms）、`schedule_update` 在洞末**：钟 IDLE，主线程在 `ppoll` 等客户端；叫醒者是实验室的 `wl_display_flush`。
- **qcb 准时、cbs/npr 晚，或 qcb 自己就晚**：叫醒者是 KMS 的 `queue_callback` eventfd。

该叫醒却没在 +5 ms 叫的，不是 DPU，是这两条互锁：present 之后没有立刻 `schedule_update` / `sendcb`，GTK 也不画。不要再叠 `wakeup(NULL)`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

---

## 108. 已否：`notify_view` 尾 emit frame callback（2026-09-14 12:16）

live poke：`notify_view_crtc_presented` 在 promote 之后、`maybe_post` 之前调 `meta_wayland_compositor_emit_frame_callbacks`（`0x167340`）。site `0x1c44f8` stock `b 0x1c4380`，cave `0x1d1bd8`。compositor 从 `after_update` `x20` 读到 `0x55af8f0520`。脚本 `linux-mainline/scripts/dagu-mutter-nview-idle-emit-install.sh`。不写磁盘 so。未重启 gnome-shell。

8 s 无 uprobe identity lab 仍是 pid 4958：

| 窗 | kickoff | gt50 | max | vblank |
|----|---------|------|-----|--------|
| 第一窗 | **115.08 Hz** | **1**（225.1） | 225.1 | 120.12 / 0 |
| 干净窗 `linux-mainline/out/display-stress/dagu-nview-idle-emit-8s-20260914.json` | **114.0 Hz** | **3**（108.3 / 100.4 / 89.2） | 108.3 | 120.12 / 0 |

未到 kickoff≈120 且 `gt50=0`。Type B 还在。已 `restore`，`0x1c44f8` 回到 `0x17ffffa2`，cave 清零。**不要再 apply。** 这和 `after_update` 立刻 emit 一样，补发点仍绑不上 IDLE 互锁（list 在 after_update PENDING 时已经空了，nview 再 emit 是空操作）。不要再叠这条，也不要再 `0x169668` / `0x16968c`。

---

## 109. 结合起来看：同一只钟上的互锁（2026-09-14 12:22）

不是再找一根断线。把 `sendcb` / `thaw` / `npr` / `sch` / `qcb` / `nview` 钉在**同一记 kickoff** 上，看每个 ≥50 ms 洞里「T0 之前最后一次」（pre）和 **T0 之后第一次**（first）。脚本 `linux-mainline/scripts/dagu-interlock.bt`。未 poke、未重启 gnome-shell。MAIN **1236**，LAB **4958**。探针税不当验收。

原始输出：

- `linux-mainline/out/display-stress/dagu-interlock-20260914-1222.txt`
- 先跑的 last-only 对照 `linux-mainline/out/display-stress/dagu-interlock-lastonly-20260914-1220.txt`

12 s：kick 1407 / hole **3**。数字是相对 **T0** 的毫秒；`9999` 表示没有。`last` 靠近 `gap` 的是下一帧 `after_update`，不当成洞中事件。

| gap | sendcb pre/first | thaw | npr first | nview first | qcb first | sch first/last | 合读 |
|-----|------------------|------|-----------|-------------|-----------|-----------------|------|
| **116** | **−6 / 109** | −6 / 110 | **+1** | **+1** | **+1** | +1 / 115 | 回调在 kickoff **之前**就花完；present 准时；GTK 冻到洞末才 thaw |
| **75** | −2 / 68 | −2 / 69 | **+67** | **+67** | **+4** | 0 / 73 | KMS 已 `queue_callback`；主线程到 +67 才 `nview`/`npr`/`sendcb` |
| **114** | −2 / **6** | −2 / 6 | **+5** | **+5** | +5 | 0 / **7** | 握手在 +6 已经走完，仍 114 ms 才下一记 kickoff |

### 一张图（主档 116 ms）

```
T0−6   after_update sendcb + GTK thaw     这一帧的 wl_callback 已发出、已花掉
       frame_callback_surfaces 已空
T0     dpu_enc_kickoff                    这一帧踢是准时的
T0+1   qcb → nview → npr                 flip 回执到了；钟 maybe_reschedule 后 IDLE
       此后 100 ms：没有 sendcb，没有 thaw
T0+109 sendcb / thaw                     下一拍握手（实验室终于 flush）
T0+116 下一记 kickoff
```

每一截单独看都「对」：

- KMS 订了 flip，qcb 在 +1 入队。
- `notify_presented` 见 list 空、`pending_reschedule=0`，进 IDLE。
- GTK `awaiting_frame_frozen`：这一帧的 callback 在 T0−6 已经用过，正在等**下一记** `wl_surface.frame`。
- 空帧 GSource 只在 `after_update` 里 arm；present→IDLE 不进 `after_update`，不会再 `send_done`。

所以这不是「没看见 qcb」或「没看见 npr」。是 **PENDING 时把 callback 付清，PRESENT 时双方都认为该对方先动**。§108 对空 list 再 emit 是空操作，对得上这张图。

### 另外两档也是同一把锁的不同卡住点

- **75 ms（B-main）**：锁的右边（KMS→主线程）晚了。qcb 在 +4 已经写了 eventfd，nview/npr/sendcb/thaw 绑在一起迟到 +67。叫醒者仍是 §107 的 KMS `queue_callback`。
- **114 ms（握手已成）**：+5～+6 已经 npr+sendcb+thaw，`sch` 最后一记在 +7，然后 107 ms 没有 `schedule_update`。这不是「没发 callback」。结合看它是互锁解开之后**仍没有下一笔 atomic/kickoff**——要么 GTK thaw 完立刻又冻上且没有 commit，要么少数内核 `wait_flush`。不要把它写回「一根断了的 sendcb」。

### 结合看完，下一刀该动哪一截

动握手，不要再单点补发：

1. **PENDING `after_update` 不要把 identity 的 `frame_callback_surfaces` 发空**（回调跟 presented 走，而不是跟 apply 走）；或
2. **present → IDLE 时若客户端仍 `awaiting_frame_frozen`，排下一拍钟 / 保留 list**。

不要再：nview 空 emit、GDK 解冻、`wakeup(NULL)`、`schedule_update_now(next==NULL)`。验收仍是同一 8 s 窗 kickoff≈120 且 `gaps_gt_50ms=0`。

## 110. web 对照后的 mutter v1–v7（2026-09-14 13:40）

网上修法（Weston post-repaint / KWin `hasFrameCallbacks` / Mutter !2823）落地在 `linux-mainline/out/mutter-50.1/src/wayland/meta-wayland.c`，交叉编 `linux-mainline/scripts/dagu-mutter-cross.sh`，部署 `linux-mainline/scripts/dagu-mutter-deploy.sh`。完整表：`linux-mainline/out/display-stress/dagu-typeb-mutter-fix-debug-20260914.md`。

- **v1–v3 推迟 PENDING emit**：kickoff 102 / 104 / **55**，已否。Weston 不是 defer done。
- **v4–v5** 保留 emit + GSource：kickoff 107–109，gt50=4–5，未过。
- **v6** keep_alive=12：GTK **120–132 Hz、p99 17ms**（客户端 100ms 洞消了），kickoff **103.73 / gt50=4**。过发 `wl_callback.done`。
- **v7** GSource 非空 list 再 `schedule_update`：kickoff **91.62**，更差。

kprobe `dpu_encoder_wait_for_commit_done` 8s 窗 max **8.2ms**。当前 Type B **不是** CTL flush 等 50ms。#175 DSC skip 后这条核路径干净。

**板上已 restore stock**（13:40）。v6 证明互锁的 GTK 一侧能用「付完 done 不要拆 GSource」解开；剩下的 100ms 是 mutter 有帧却不 `dpu_enc_kickoff`。不要再 defer emit，也不要再 GSource 泵 `schedule_update`。


