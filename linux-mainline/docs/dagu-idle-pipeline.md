# dagu 静置动画掉帧：渲染 / DPU（不是触摸）

**问题专文（只陈述现象与已做调查，不写改法）：**  
`linux-mainline/docs/dagu-identity-kickoff-hole-problem.md`

手指离开后 CSS / 视频 / 惯性仍抽帧 → 坐标 IRQ 不是主因。  
触摸备忘停在 `linux-mainline/docs/dagu-touch-irq-jitter.md`（IRQ 193、`HIMAX_IRQ_DRAIN`），不再抓 SYN。

探针：`linux-mainline/scripts/dagu-idle-pipeline-probe.py`  
数据：`linux-mainline/out/display-stress/idle-pipeline.json`  
空闲 rAF 旧基线：`linux-mainline/out/display-stress/scroll-jank-idle.json`

不要关 GPU 栅格，不要 VA-API，不要默认 Vulkan / `WaylandOverlayDelegation`。  
不要把 `governor=performance` 当交付（`linux-mainline/scripts/dagu-gpu-perf.sh`：120 Hz LINEAR 合成会把管芯顶到约 75°C）。

## 嫌疑人 A：Devfreq / Cpufreq — 锁频对照已做，不是「掉到 257 MHz」

实机 `/sys/class/devfreq/3d00000.gpu`：

| 项 | 值 |
|----|----|
| available_governors | **`userspace simple_ondemand`**（没有 `performance`） |
| `echo performance` | **EINVAL**，写不进去 |
| OPP | 305 / 400 / 442 / 490 / 525 / **587** / **670** MHz |
| 空闲地板 | `min_freq=587000000`（`linux-mainline/scripts/dagu-resources-fix.sh`、`dagu-gpu-perf.sh`） |

2026-09-13 A/B（8 s × 2，无 Chrome）：

| | schedutil + ondemand | CPU `performance` |
|--|----------------------|-------------------|
| GPU | **一直 587**，busy 0 | **一直 587**，busy 0 |
| CPU0 | 691–1805 MHz | 钉死 1805 |
| DPU vblank | **119.7 Hz** | sysfs 仍约 119 |
| 新的 vblank timeout | 无 | 无 |

旧空闲 HUD（`scroll-jank-idle.json`）GPU 也是 587（偶 670），rAF 中位 8.3 ms，**最长 125 ms**。  
地板已经在 587，不是 257；CPU 钉满也拉不走「静置仍偶发长帧」。A 结案：**不是心跳骤停到最低 OPP**。  
`dagu-touch-boost.py` 按住/播片时把 GPU 地板抬到 670，不改 governor。已恢复 `schedutil` / `simple_ondemand` / min 587。

## 嫌疑人 B：Fence / Ozone — 协议在，错旗会害 DPU

GNOME Shell 50.1 已广告 `wp_linux_drm_syncobj_manager_v1`。  
`linux-mainline/scripts/dagu-chromium.sh` / `dagu-chrome.sh` 默认 **ENABLE** `WaylandLinuxDrmSyncobj`，**DISABLE** Vulkan 与 `WaylandOverlayDelegation`。  
`WaitForSwap` 不是「缺 explicit sync」（`linux-mainline/docs/dagu-scroll-jank.md`）。

本 boot 曾见到 `/tmp/dagu-chrome-jank-profile` 的 Chromium 带着 `--use-angle=vulkan` 和 `WaylandOverlayDelegation,HardwareOverlays,Vulkan`（`DAGU_TEAR_CONTRACT` / `dagu-chromium-native.sh` 的拆合同路径）。那是花屏合同，不是日常一线。测完应 `pkill -u dagu -f chrome|chromium`。

Settings vs Chrome 手感对照这次没做。下一步若要分全局/局部：GNOME 设置里滚列表 vs `dagu-chromium`（GLES）开同一 CSS 动画。

## 嫌疑人 C：`vblank timeout: 400000` — 是 DSC flush，不是幽灵光标

`dmesg`（本 boot 仅此一次，**06:20:30**，uptime ~1212 s，连打两下，`-110` = `ETIMEDOUT`）：

```text
[drm:dpu_encoder_phys_vid_wait_for_commit_done:547] [dpu error]vblank timeout: 400000
[drm:dpu_kms_wait_for_commit_done:525] [dpu error]wait for commit done returned -110
```

`0x400000` = `BIT(22)`。同一颗位在 `linux-mainline/linux/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_ctl.c` 里有**两个名字**：

| 符号 | 行号附近 | 何时置位 |
|------|----------|----------|
| `#define DSC_IDX 22` | 55 | `dpu_hw_ctl_update_pending_flush_dsc_v1()`：`pending_flush_mask \|= BIT(DSC_IDX)`，再写 `CTL_DSC_FLUSH` |
| `SSPP_CURSOR0` | 235–236 | 老 SSPP 表；SM8250 catalog **没有**这个块 |

L81A 面板走 DSC 1.1（`linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c`）。  
实机 `/sys/kernel/debug/dri/0/state`：`dsc=89 89`（DSC_0/1 绑在 crtc-0），`sspp` 只有 **sspp_8/sspp_9 = DMA0/DMA1** 在扫主 fb。DMA2/DMA3（带 `DPU_SSPP_CURSOR`）是空的。  
主 plane `format=XR24` **`modifier=0x050000000000001`（`QCOM_COMPRESSED`）**，不是 LINEAR。mixer 各 800×2560。

高通自己的补丁说明 CTL_FLUSH bit 22 就是 DSC（lore：Kuogee Hsieh *set DSC flush bit correctly*，`DSC_IDX` 不是字面值 `0x22`）。  
Dmitry 把 timeout 打成 flush 值，是为了认哪块没清，不是点名光标。

### 用户态关硬件光标 — 早已开着，timeout 仍出现

`MUTTER_DEBUG_DISABLE_HW_CURSORS=1` 已在：

- `/etc/systemd/system/gdm.service.d/dagu-kms.conf`
- `/etc/environment.d/dagu-mutter.conf`
- `/etc/systemd/user/org.gnome.Shell@.service.d/dagu-kms.conf`
- 仓库：`linux-mainline/scripts/rootfs-desktop-setup.sh`

gnome-shell（pid 实机查过）environ 里已有该变量。`crtc plane_mask=1`，只有 plane-0；plane-1…7 `fb=0`。  
**关光标之后仍然打出 `400000`，幽灵 CURSOR0 死锁不成立。** 不要再重启 GNOME 灌同一条环境变量，也不要把 `SSPP_CURSOR0` 改写成 DMA2 flush（DMA2 已经是 `BIT(24)`）。

### DPU 270° — 属性在，当前是 `rotation=1`（ROTATE_0）

`/sys/kernel/debug/dri/0/state` 每个 plane 都是 `rotation=1`。CRTC mode 就是面板原生 **1600×2560@120**。  
横屏是 Mutter 逻辑 transform 270°（`linux-mainline/docs/dagu-a650-linear-destile.md`），不是 KMS 拒了 `DRM_MODE_ROTATE_270` 才退回 GPU。  
不要放宽 Atomic Check「硬放行旋转」：UBWC + 旋转对齐更严，乱放行会 underflow/花屏。真要硬件转，是另开一条 KMS 横屏 mode（已有 `linux-mainline/scripts/dagu-kms-land-crop.py`），不是把 check 拆掉。

## DSC 双路：切片数学 / idle_pc / 抓痕（2026-09-13）

### 1. Slice math — 对齐，没有漏网 WARN

L81A（`linux-mainline/overlays/linux/drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c`）：slice **800×20**，`slice_count=1` / INTF，8bpc/8bpp。  
`dpu_encoder_phys_vid.c` 在 split 时先 `hdisplay >>= 1`（800），再 `DIV_ROUND_UP(800*8, 24)=267`（已打补丁；截断是 266，DSI 对不上会 lock 不住）。  
mixer 各 800×2560，正好一块 slice。`2560 % 20 == 0`，`1600 % 800 == 0`。

`linux-mainline/linux/drivers/gpu/drm/msm/dsi/dsi_host.c` 的 mode_valid 会 `pr_err`「pic_width 必须是 slice 的倍数」。本 boot **没有**这条。  
`dpu_hw_dsc.c` **没有**「slice 必须偶数」的 `WARN_ON`，只写 PPS：`(slice_width+2)%3` 进 last_group。

Video 模式每帧编 **整幅** mixer 输出，不是 Mutter 的 damage/`clip_rect`。`MESA_EXTENSION_OVERRIDE` 已关掉 `EGL_*partial_update`。局部动画不会改 DSC 切片合同。

SM8250 用 `dpu_hw_dsc.c`（DPU 6.0），不是 `dpu_hw_dsc_1_2.c`。

### 2. Ping-Pong / 时钟 — 没有那个模块参数

**不存在** `msm.dpu_disable_dsc_clock_gating`。`/sys/module/msm/parameters` 只有 dumpstate / modeset / rd_full / `dpu_use_virtual_planes` 等。

`has_idle_pc=true`。`IDLE_TIMEOUT` = `66-16/2` = **58 ms**（`linux-mainline/linux/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.h`）。  
**Video 模式**进 IDLE 只 `_dpu_encoder_irq_disable`，回来只 `_dpu_encoder_irq_enable`，**不会关 DSC 时钟**。CMD 模式才 `resource_disable`。  
不要编造 CAF 开关去「常开 DSC 时钟」。

Master/Slave：`dpu_encoder_helper_split_config` + `split_flush_en`。超时两次间隔 56 ms，像同一次 commit 的 master/slave 各等一次 50 ms。

### 3. ftrace — 已刷上（#170，2026-09-13）

`linux-mainline/config/dagu-display.fragment`：`CONFIG_FTRACE=y` + `CONFIG_SCHED_TRACER=y`（拉 `GENERIC_TRACER` → `TRACING` → `EVENT_TRACING`）。  
**禁止** `FUNCTION_TRACER`（每个函数插 nop 会扰动 120 Hz）。  
板上：`/sys/kernel/debug/tracing` 与 `/sys/kernel/tracing` 都在，`events/dpu/` 有 `dpu_enc_trigger_flush` / `dpu_enc_rc`。  
`ignore_loglevel` 下不要开 `hw_log_mask`（DSC=`1<<11`）的寄存器 printk，会堵 120 Hz。

探针：`linux-mainline/scripts/dagu-dpu-timeout-watch.sh`（`--host` 武装 / `--pull` 取回 / `--stop`）。  
12 s 窗口：`linux-mainline/scripts/dagu-dpu-jank-capture.py`（`--host`）。

### 4. 2026-09-13 07:17 B 站窗口（#170）

数据：`linux-mainline/out/display-stress/jank-capture-20260913-071722/`  
3 s 静置首页 + 6 s Himax `--axis x --hold 6` + 3 s 松手。

| | `dpu_crtc_vblank_cb` | `dpu_enc_kickoff` |
|--|----------------------|-------------------|
| 次数 | 1494（≈120 Hz） | 841（编码器 33） |
| p50 间隙 | **8.33 ms** | 8.4 ms |
| p99 / max | 8.37 / 16.7 ms | **79 / 151 ms** |
| >16.7 ms | **0** | 210 |
| >50 ms | 0 | **18** |

18 个 >50 ms 的 kickoff 洞里，vblank 仍在走（151 ms 洞里 18 次）。屏没停，只是没新帧。  
RC 一直 `ON`，`ENTER_IDLE=0`，`vblank timeout=0`。1682 次 `trigger_flush` 都带 DSC `BIT(22)`，成对间隔约 12 µs。  
**这一窗的卡顿不是 DSC timeout，是合成提交洞**（`WaitForSwap` / 整窗 270°）。静置首页就已经有 134 ms 洞。

板上 9 月 12 日 `venus-*.ko` 对 #170 `insmod` 失败（`struct module` 尺寸变了）。播片前换 `linux-mainline/out/modules/venus/`。不要改走软解。

### 5. 2026-09-13 已落地：present pump + video 保 IRQ（#171）

根因（不是触摸、不是 GPU 掉到 257 MHz、不是缺 syncobj）：

1. SM8250 DPU 6.0 **没有** `DPU_SSPP_INLINE_ROTATION`。最大化 UBWC 窗必须走 Mutter shadowfb 270° destile，不能第二块 DPU plane 直扫。  
2. Mutter 以为没 dirty 时，frame clock 掉到 **100–150 ms**（静置久了可见 **~600 ms**）。Chrome `WaitForSwap` 等 `wl_buffer.release` / drm_syncobj → 滑动中间出现 50–151 ms kickoff 洞。屏仍 120 Hz 扫旧帧。  
3. Video 模式 `delayed_off_work`（`IDLE_TIMEOUT=58 ms`）只 `_dpu_encoder_irq_disable`，会饿下一次 commit 的 vblank，并和双 DSC flush 赛跑（`vblank timeout: 400000`）。

空 `queue_redraw` **不会**产生 KMS kickoff。1×1 真实 damage 能把静置拉到 ~99 Hz，但叠在滑动 destile 上会打出 243–616 ms 洞。所以泵要分模式。

用户态：GNOME 扩展 `dagu-present-pump@local`

- 源：`linux-mainline/scripts/dagu-present-pump@local/{metadata.json,extension.js}`  
- 安装：`linux-mainline/scripts/rootfs-desktop-setup.sh` 的 `install_dagu_present_pump`  
- 板上：`/home/dagu/.local/share/gnome-shell/extensions/dagu-present-pump@local/`（优先于 `/usr/share/gnome-shell/extensions/dagu-present-pump@local/`）  
- 手指按下 / 移动：**只** `stage.queue_redraw()`（8 ms，HOLD 800 ms，覆盖惯性）  
- 焦点窗最大化/全屏：1×1 `St.Bin` 弄脏，逼 Mutter 真正 commit  
- 不要 `systemctl restart org.gnome.Shell@*`；热重载 `gnome-extensions disable/enable`。新 uuid 首次加载才需要 `systemctl restart gdm`。

内核 #171（2026-09-13 07:37，只刷 B，`androidboot.serialno=<linux-serial>`）：

- `linux-mainline/scripts/apply-overlays.sh` 在 `dpu_encoder.c` `FRAME_DONE` 里：`is_vid_mode` 则 **不要** `queue_delayed_work(delayed_off_work)`（marker `dagu: video mode keep IRQs`）  
- `head.S` 仍直接 `bl record_mmu_state`，无 `SYSTEM_RESET`  
- `# CONFIG_FUNCTION_TRACER is not set`  
- 刷后 `g_serial` `0525:a4a7` 已稳住 >30 s  
- 本 boot `ENTER_IDLE=0`，`vblank timeout=0`  
- Venus：`linux-mainline/out/modules/venus/`（`/dev/video14` `/dev/video15` 已在）

| 窗 | 条件 | 滑动 Hz | 滑动 p99 / max | 滑动 >50 ms |
|----|------|---------|----------------|-------------|
| `jank-capture-20260913-071722` | #170 基线 | 62.8 | 75 / **151** ms | **10** |
| `jank-capture-20260913-072614` | 关 syncobj（更差） | 82.7 | 66 / 183 ms | 9 |
| `jank-capture-20260913-073051` | 仅 touch `queue_redraw` | **99.0** | **25 / 93** ms | **1** |
| `jank-capture-20260913-073159` | touch + 最大化 `queue_redraw` | **99.0** | **21 / 50** ms | **1** |
| `jank-capture-20260913-073805` | 分模式泵（暖机 #170） | **105.7** | **18 / 117** ms | **3** |
| `jank-capture-20260913-074207` | #171 + 分模式泵 | 82.7 | 42 / 335 ms | 4 |

`074207` 冷开机 load≈3.5；同一窗 **idle2** 已是 **101.6 Hz**、p99 18.6 ms、>50 ms **0**。vblank 全程 ≈120 Hz。  
A/B：关 `WaylandLinuxDrmSyncobj` 更差，已恢复。不要默认 Vulkan / `WaylandOverlayDelegation`。不要锁 `governor=performance`。不要关 GPU raster。

### 6. 首页慢滑 + 快滑（禁止点进视频）

旧 `dagu-himax-swipe.py` 会在 `(820, 1480)` **点按**，B 站封面正好在那里，会进播放器；`--hold` 还只在同一段 820 px 里来回搓，不是刷首页。

现在：`--profile slow|fast|homepage --no-tap`，立刻拖、单向抬手，刷出新卡片。探针 `linux-mainline/scripts/dagu-dpu-jank-capture.py --host`。

数据：`linux-mainline/out/display-stress/jank-capture-20260913-074651/`  
截图（仍是 `bilibili.com` 网格，不是播放器）：

- 前：`linux-mainline/out/display-stress/homepage-before-scroll.png`
- 后：`linux-mainline/out/display-stress/homepage-after-scroll.png`

| 段 | kickoff Hz | p99 / max | >50 ms |
|----|------------|-----------|--------|
| idle1 | 116.5 | 17 / 17 ms | 0 |
| **慢滑**（40 Hz，48 步 ×4） | **87** | **30 / 178** ms | **4** |
| **快滑**（120 Hz，12 步 ×12） | **96** | **19 / 20** ms | **0** |
| idle2 | 71 | 84 / 224 ms | 5 |

慢滑刷新封面时 destile 跟不上，这才是首页抽帧。快滑（短 flick）反而干净。`400000` 两条是 07:43:57，不是这一窗。

### 7. 178 ms 洞死在谁手里（2026-09-13 07:50）

探针：`linux-mainline/scripts/dagu-dpu-hole-blame.py --host`  
数据：`linux-mainline/out/display-stress/hole-blame-20260913-075004/blame.json`  
对照窗：`linux-mainline/out/display-stress/jank-capture-20260913-074651/`

KMS：`rotation=1`（ROTATE_0），只有 plane-0，fb 是 gnome-shell 的 1600×2560 XR24 `QCOM_COMPRESSED`。DPU **没有**在转 270°，也没有第二块 Chrome plane。

`074651` 里 4 次慢滑洞（178 / 84 / 119 / 108 ms）：

| 洞里 | 事实 |
|------|------|
| `dpu_crtc_vblank_cb` | 10–21 次，屏还在 120 Hz 扫**旧帧** |
| `dpu_kms_commit` | 洞结束才来一次 |
| Chrome / Mutter / `dav1d` 事件 | **3/4 次 = 0**（用户态没提交） |
| `vblank timeout` / `400000` | 无 |

`075004` 慢滑再抓（`dma_fence` + 40 ms wchan）：

| 洞 | gpu_busy | gnome-shell | chrome-gpu / gdrv0 |
|----|----------|-------------|-------------------|
| 109 ms | 28→24→**0→0**→18 | `poll_schedule_timeout` | `futex_do_wait` |
| 66 ms | 26→29→**0** | 同上 | 同上 |
| 125 ms | 33→20→61→**0** | 同上 | 同上 |

`dma_fence_wait_*` 几乎都是 `detached-driver / signaled-timeline`（已经 signal 的空 fence，约 8 ms 一拍），**没有** 50–150 ms 的 GPU blit 等待。`gdrv0` 全程停在 `futex_do_wait`，不是在啃 178 ms destile shader。

**结论：抽帧不是 DPU 卡死，不是 DSC `400000`，也不是单次 178 ms 的 270° destile / Skia GPU 栅格。**  
洞中间 GPU busy=0，Mutter 在 `poll_schedule_timeout`（frame clock 停车），Chrome GPU 在 `futex_do_wait`（`WaitForSwap` / syncobj）。新封面解码+出 tile 的间隙里 Chrome 交不出下一帧 → Mutter 以为没 dirty → 双方空等 80–180 ms → 你看见旧画面抽一下。快 flick 不解码新图，clock 喂得上，所以 p99 20 ms。

`dav1d-worker` 在全程出现（首页预览 AV1），但不在洞内。不要关 GPU raster，不要 VA-API，不要锁频。

### 8. 破互锁三条路 A/B（2026-09-13 07:55）

用户模型成立：`WaitForSwap` / `wl_buffer.release` 对上 Mutter `poll_schedule_timeout`。再抓 `linux-mainline/out/display-stress/hole-blame-20260913-075832/`：4 个 54–92 ms 洞，GPU busy 掉到 0，gnome-shell `poll_schedule_timeout`，chrome `gdrv0` / Viz `futex_do_wait`，fence 几乎全是已 signal。不是 destile shader 啃 178 ms。

**方向一 Chrome 加深队列：推荐开关不存在或更差。**

| 开关 | official-152 事实 | 本轮 |
|------|-------------------|------|
| `--max-pending-swaps=2` | **二进制里没有这个 CLI**。只有 viz `PendingSwapParams` / `max_pending_swaps`（embedder，不是启动参数） | 不能加 |
| `--double-buffer-compositing` | **有**，把队列收成 1 | **禁止** |
| 默认缓冲 | 已经是 triple buffer（帮助文本相对 double-buffer） | 日常保持 |
| `WaylandOverlayDelegation` | 已 A/B 更差 | 仍在 DISABLE |
| `WaylandExternalBeginFrameSource` | **默认 OFF**（`FEATURE_DISABLED_BY_DEFAULT`）。打开后 Chrome 跟 Mutter `wl_surface.frame` 节拍，互锁更紧 | `DAGU_CHROME_WAYLAND_BFS=1` 仅 A/B |

`jank-capture-20260913-075915`（BFS ON，冷启动首页）：

| 段 | Hz | p99 / max | >50 ms |
|----|----|-----------|--------|
| 慢滑 | 89.5 | 33 / **174** | 2 |
| **快滑** | **62** | **131 / 249** | **7** |

日常不要开 BFS。要在 Chrome 侧真正加深队列，得改 Ozone Wayland buffer 池（本树没有 `ui_base_features.cc` 可补丁的源），不是加启动参数。

**方向二 Mutter frame clock：空 redraw 破不了 release；1×1 叠滑动就是 100–340 ms destile。**

| 窗 | 泵 | 慢滑 Hz | 慢滑 p99 / max | 慢滑 >50 |
|----|----|---------|----------------|----------|
| `074651` | touch `queue_redraw` | 87 | 30 / **178** | 4 |
| `075542` | `schedule_update` + 24 ms 1×1 | **101** | 42 / 117 | 5 |
| `075626` | `schedule_update` + 50 ms 1×1 | 100 | 42 / 119 | 4（快滑冒出 **342**） |
| `075724` | **只 `schedule_update`** | 88 | 35 / 116 | 5 |

24/50 ms 的 1×1 把互锁洞换成整窗 270° shadowfb destile（洞稳定在 108–119 ms）。已撤回。触摸只 `stage.schedule_update()`（`libmutter-18` 有 `clutter_stage_schedule_update`），最大化静置仍 1×1。

`gsettings set org.gnome.mutter experimental-features "[]"` **没有重启 session**（`075755`）：慢滑 p99 21 / max 87，但同一窗 idle1 223 ms、快滑 308 ms，且 `scale-monitor-framebuffer` 多半仍在运行中的 Mutter 里。已恢复 `['scale-monitor-framebuffer']`。不要为了试这个 `systemctl restart gdm`。

真正要补的是 Mutter C：`clutter-frame-clock.c` 在 Wayland surface 仍有 pending buffer / `frame_callback` 时 **不要** `CLUTTER_FRAME_RESULT_IDLE` 进 `poll_schedule_timeout`，并在该拍发出 presentation / `wl_buffer.release`。扩展泵做不到「无 destile 的 release」。

**方向三 绕开 270° shadowfb：本轮不落地。**  
SM8250 DPU 6.0 无 `DPU_SSPP_INLINE_ROTATION`。KMS 不能硬放行 UBWC+270。正路是 Mutter `orientation=normal`，Chrome 在 GPU raster 顶点矩阵里转 270° 交 1600×2560。见 `linux-mainline/docs/dagu-a650-linear-destile.md`。

源与板上：

- `linux-mainline/scripts/dagu-present-pump@local/{extension.js,metadata.json}`
- `linux-mainline/scripts/rootfs-desktop-setup.sh` 的 `install_dagu_present_pump`
- 板上 `/home/dagu/.local/share/gnome-shell/extensions/dagu-present-pump@local/`（ACTIVE）
- `linux-mainline/scripts/dagu-chromium-native.sh`（`DAGU_CHROME_WAYLAND_BFS=1` 仅实验）

不要关 GPU raster，不要默认 Overlay / Vulkan / BFS，不要锁频。

### 9. 方向三基线：Mutter `normal`（2026-09-13 08:05）

`ApplyMonitorsConfig` transform **0**，scale 仍 **1.25**，**不重启 gdm**。截图 1600×2560（270° 日常是 2560×1600）。测完已恢复 transform **3**（`right`）。

工具：

- `linux-mainline/scripts/dagu-mutter-orientation.py`（`--host get|set-normal|set-right`）
- `linux-mainline/scripts/dagu-himax-swipe.py --native-portrait`（竖滑走物理 Y）
- `linux-mainline/scripts/dagu-dpu-jank-capture.py --host --native-portrait`（finally 必须 `set-right` + 点 Keep，否则 20 s 确认框会退回）

| 窗 | 方向 | 慢滑 Hz | p99 / max | >50 |
|----|------|---------|-----------|-----|
| `jank-capture-20260913-074651` | 270° | 87 | 30 / **178** | 4 |
| `jank-capture-20260913-080413` | normal，确认框挡住 | 42 | — / 226 | 无效 |
| `jank-capture-20260913-080558` | **normal，已 Keep** | **91** | **25 / 125** | **4**（58 / 125 / 109 / 92） |

图：`linux-mainline/out/display-stress/homepage-normal-before.png`、`homepage-normal-after.png`。

**Normal 没有拆掉互锁。** 慢滑仍是 4 个 50–125 ms 洞。DPU 仍只有 plane-0，主 fb 仍是 gnome-shell 1600×2560 `QCOM_COMPRESSED`，`rotation=1`。`scale-monitor-framebuffer` + 1.25 还在，Mutter **没有**把 Chrome 交给第二块 plane。去掉 270° destile 只是把 max 从 178 收到 125，闭环还在。

Chrome 二进制里：

- `--force-device-scale-factor` 只改 DPR，不转
- `wl_surface.set_buffer_transform` / `preferred_buffer_transform` **跟着 output transform**，没有「Mutter normal、Chrome 自己交 270° 缓冲」的 CLI
- 横屏 UX + 无 shadowfb 必须改 official-152 Ozone，或接受竖屏桌面

兜底 C 补丁草稿（**不要现在换 mutter deb**）：

- `linux-mainline/patches/mutter-50-pending-release-tick.patch`
- 对 gnome-50 / Ubuntu `50.1-0ubuntu2.2`：skipped paint 时若还有 `frame_callback` / `use_count>0` 就 `schedule_update`；纹理已上传则 `dec_use_count` 放行 release。不要在这条路径上弄脏 1×1。

## 下一步（一线）

1. 要真 pass-through：先试 **scale=1.0 + 关 `scale-monitor-framebuffer`**（仍不重启 gdm；确认框必须 Keep），看最大化 Chrome 有没有第二块 DPU plane。  
2. 横屏 UX：official-152 补 Ozone 顶点 270°（无现成开关）。  
3. 兜底：按 `linux-mainline/patches/mutter-50-pending-release-tick.patch` 打 mutter 50.1，**另开窗口换包**，不要当日常。  
4. 日常保持 270° / scale 1.25 / `/usr/local/bin/dagu-chromium` GLES。

### 10. 内核 fence 定性：不是 MSM 卡 lifecycle（2026-09-13 08:11）

用户怀疑「DPU 要等下一次 commit 才 signal 上一帧 fence」，所以 Mutter 一停 clock 内核也冻住。用现有 `dma_fence` + `dpu` ftrace 对洞做了对齐。**结论：锅在用户态，不是驱动 fence 卡死。**

探针：`linux-mainline/scripts/dagu-dpu-hole-blame.py --host`（已报 `vblank_n` / `flip_n` / `wait_live_n` / `kernel_verdict`）  
数据：

- `linux-mainline/out/display-stress/hole-blame-20260913-075004/`
- `linux-mainline/out/display-stress/hole-blame-20260913-075832/`
- `linux-mainline/out/display-stress/hole-blame-20260913-081120/blame.json`

源码（本树 #171）：`linux-mainline/linux/drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c`

- `dpu_crtc_vblank_callback()`（约 644）只 `drm_crtc_handle_vblank()`，**不** `_dpu_crtc_complete_flip()`
- pageflip / CRTC out-fence 在 `dpu_crtc_complete_commit()` → `_dpu_crtc_complete_flip()` → `drm_crtc_send_vblank_event()`（约 758 / 597）
- 这是主线 DPU 的设计（flip 从每拍 vblank 挪到 FRAME_DONE，避免撕页）。**out-fence 按 atomic commit 收，不按硬件扫屏收。** 没有新 commit 就不会有新的待 signal fence；上一拍的 fence 在当次 `complete_flip` 已经 signal。

| 窗 | 洞 | vblank | complete_flip | 活 fence wait | wait_max | verdict |
|----|----|--------|---------------|---------------|----------|---------|
| `075832` | 58 / 92 / 60 / 54 ms | 7 / 11 / 7 / 6 | 各 1（洞结束那次 kickoff） | **0** | **2–7 µs** | `userspace-no-commit` |
| `075004` | 109 / 66 / 125 ms | 13 / 8 / 15 | 各 1 | **0** | **1–5 µs** | 同上 |
| `081120` | **125** / 64 / 58 ms | **15** / 8 / 7 | 各 1 | **0** | **2–5 µs** | 同上 |

`081120` 全程 `kick_n=574`、`flip_n=575`（1:1）。洞里 GPU busy 掉到 0，chrome `gdrv0` / Viz `futex_do_wait`，gnome-shell `poll_schedule_timeout` 或空转。

`dma_fence_wait_*` **全部**是 `detached-driver/signaled-timeline`（已经 signal 的空 fence，跟 kickoff 对齐的 8 ms 空等）。`dma_fence_signaled` 是 `drm_sched/ring0`、`msm/gpu-ring-0`、`stub`，不是一张拖了 50–125 ms 的 CRTC out-fence。

对照三条嫌疑：

1. **vblank 与 fence 错位 / 靠下次 commit 收割** — 否。洞里硬件 vblank 照走（125 ms 里 15 次），没有未 signal 的 CRTC wait；`complete_flip` 只在洞结束的新 commit 上出现，那是新帧，不是旧 fence 迟到。  
2. **UBWC + SYNCOBJ 休眠唤醒** — 否。若内核 `DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT` 睡 50–120 ms，会看到活的 `msm`/`syncobj` `wait_start` 贯穿整个洞。没有。`futex_do_wait` 是 Chrome 等 Mutter `wl_buffer.release` / destile，GPU 环已经在 signal。  
3. **plane-1 atomic_check -EINVAL** — 没有 dmesg 刷屏。`msm.dpu_use_virtual_planes=1` 已在 cmdline，8 块 plane 在；只有 plane-0 有 fb。这是 Mutter shadowfb / `scale-monitor-framebuffer` 不走直扫，不是驱动把 overlay 判死。SM8250 仍无 `DPU_SSPP_INLINE_ROTATION`。

「标准 DRM 只要每拍 vblank 都 signal，就不该静默 120 ms」把 **CRTC out-fence（每 commit 一次）** 和 **Wayland buffer release（Mutter 合成完才发）** 收成了一件事。内核该 signal 的已经 signal；卡死的是 Mutter 不 commit、不 destile、不 release。

不要为这条去改 DPU fence、不要锁频、不要关 GPU raster。

### 11. Normal+1.0+FS 仍无 plane；强制 dec_use_count 更差（2026-09-13 08:33）

这一轮把「真 pass-through」和「Mutter 空转 release」都落到实机上了。**互锁还在；乱 dec 会把洞拉到秒级。日常已卸 hook。**

#### 11.1 `has_shadowfb` 不是挡板

GNOME 50 `should_force_shadow_fb()` 在 GPU 加速时返回 FALSE。扩展 `dagu-scanout@local` 实机 dump：

- `linux-mainline/scripts/dagu-scanout@local/{extension.js,metadata.json}`
- 板上 `/home/dagu/.local/share/gnome-shell/extensions/dagu-scanout@local/`（ACTIVE）
- `/run/user/1001/dagu-scanout.json`：`shadowfb=false`，`scale=1.25`，`transform=3`

`find_scanout_candidate()` 仍会因 paint-box ≠ view 失败。最大化 Chrome 逻辑框约 `1981×1248+67+32`，view 是 `2048×1280`（顶栏 + CSD）。GNOME 50 已删 `Meta.Window.get_maximized`，旧 `dagu-present-pump@local` 每 8 ms 抛 JS；换 UUID 才重新加载 ESM。

#### 11.2 Normal + scale 1.0 + `--start-fullscreen`

`ApplyMonitorsConfig` transform 0 / scale 1.0，Keep 已点。截图 `1600×2560`：

- `linux-mainline/out/display-stress/passthrough-ab-20260913-081859/06-normal1-chrome-fs.png`
- 工具：`linux-mainline/scripts/dagu-mutter-orientation.py`（`set-normal-1` / `set-daily`）
- `linux-mainline/scripts/dagu-pass-through-ab.py`

DPU **仍只有 plane-0**，fb 仍是 gnome-shell 1600×2560 `QCOM_COMPRESSED`。Chrome 多 subsurface + 未关 `scale-monitor-framebuffer`（feature 不重启 session 不卸）。**几何对齐了也没有第二块 plane。**

`jank-capture-20260913-082244`（`--native-portrait`）：

| 段 | Hz | p99 / max | >50 |
|----|-----|-----------|-----|
| idle1 | 46 | 75 / 92 | 9 |
| slow | 82 | 50 / **102** | **4** |
| fast | 95 | 24 / 109 | 1 |

和 270° / Normal+1.25 一样是 **4 个慢滑洞**。去掉 270° destile 只把 max 从 178 收到 ~102，**互锁还在**。

#### 11.3 隐藏 `dec_use_count` @ `0x167e80`（libmutter-18 50.1）

`meta_wayland_buffer_dec_use_count` **没有 dynsym**（inc 被内联）。反汇编：`use_count` 在 GObject+64，归零时 `wl_resource_post_event` + `cogl_context_get_latest_sync_fd` 写 syncobj。源：

- `linux-mainline/scripts/dagu-mutter-release.c`
- `linux-mainline/scripts/libdagu-mutter-release.so`
- `linux-mainline/scripts/dagu-mutter-release-install.sh`

钩子进过 gnome-shell（`hooks_on`、`inc=7`、`after_paint` 每 8 ms）。**实测更差，已卸：**

| 窗 | 策略 | kick n | p99 / max | >50 |
|----|------|--------|-----------|-----|
| `083204` | 每拍 after_paint 强制 dec | 669 | 91 / **658** | 18 |
| `083315` | GPU idle 时 dec | 590 | 93 / **986** | 20 |

过早 release 让 Chrome 复用 Mutter 还在 destile 的 UBWC buffer，合成回退到几百毫秒。`/usr/bin/gnome-shell` 已从 wrapper 复原为 `gnome-shell.real`（2026-09-13 08:33）。**不要再给日常 session 加这个 LD_PRELOAD。**

`linux-mainline/patches/mutter-50-pending-release-tick.patch` 已按 gitlab `50.1` 的 `apply_state` / `handle_release_points` 写成真 diff（见 §12）。仍须 host 交叉编 `libmutter-18`，不要在板上 `apt-get source`。**禁止**再扫 live buffer 强制 `dec_use_count`。

#### 11.4 日常

270° / scale 1.25 / `experimental-features=['scale-monitor-framebuffer']` / `/usr/local/bin/dagu-chromium` GLES。扩展走 `dagu-scanout@local`（`is_maximized()` + 最大化时只 `schedule_update`）。不要关 GPU raster，不要锁频，不要默认 Vulkan / Overlay。

### 12. 50.1 源码对照与否决实验（2026-09-13 08:42）

gitlab.gnome.org/GNOME/mutter tag **50.1**（板上 `libmutter-18-0` 50.1-0ubuntu2.2）对上了互锁的 C 路径。**乱 dec / 关 syncobj / 只补 sync_fd 都拆不掉 4 个慢滑洞。**

#### 12.1 源码钉死

`src/wayland/meta-wayland-actor-surface.c` `meta_wayland_actor_surface_apply_state`：

```c
if (priv->actor &&
    (!wl_list_empty (&pending->frame_callback_list) || pending->fifo_wait))
  meta_surface_actor_schedule_update (priv->actor);
```

**新 attach / damage 不在这个 if 里。** Chrome 开 `WaylandLinuxDrmSyncobj` 时等的是 release timeline，不是 `wl_surface.frame`。时钟只靠 damage→`meta_surface_actor_update_area`→`queue_redraw_with_clip`。`unobscured_region` 为空会直接 return，整段 damage 丢掉。

`src/wayland/meta-wayland-buffer.c` `handle_release_points`：`cogl_context_get_latest_sync_fd()` 返回 **-1** 就 `return`，**不** `meta_wayland_sync_timeline_set_sync_point`。`use_count` 已经是 0，`wl_buffer.release` 发出了，syncobj 永远不 signal。协议允许「没读就 release」。

`meta_wayland_buffer_dec_use_count` 仍无 dynsym。`cogl_context_get_latest_sync_fd` 在 `libmutter-cogl-18.so` **有** dynsym。

#### 12.2 本轮 A/B

| 窗 | 条件 | 慢滑 Hz | p99 / max | >50 |
|----|------|---------|-----------|-----|
| `074651` | 日常 syncobj + present-pump | **87** | 30 / **178** | **4** |
| `083857` | `DAGU_CHROME_NO_SYNCOBJ=1` | 64 | 58 / **217** | **7** |
| `084038` | syncobj + `libdagu-cogl-syncfd.so` 冷启动 | 57 | 53 / **233** | 5 |
| `084215` | 同上，暖机 18 s（仍有翻译条 + 磁盘框） | 57 | 57 / **109** | **4**（108.8 / 108.6 / 108.5 / 57） |

关 syncobj **更差**（隐式 sync + UBWC）。`libdagu-cogl-syncfd.so` 只在 `-1` 时补已 signal 的 dummy fd，**全程没有 `fallback` 日志**（要么从未 `-1`，要么 gnome-shell 没走到 `handle_release_points`）。4 个洞还在。日常 **已卸** 这个 preload。

`org.gnome.shell disable-user-extensions` 曾被设成 **true**，`dagu-scanout@local` 停在 INITIALIZED。已改回 `false`，扩展 ACTIVE。

截图：

- `linux-mainline/out/display-stress/jank-capture-20260913-083857/{before,after}.png`
- `linux-mainline/out/display-stress/jank-capture-20260913-084038/before.png`
- `linux-mainline/out/display-stress/jank-capture-20260913-084215/before.png`

工具：

- `linux-mainline/scripts/dagu-cogl-syncfd.c`
- `linux-mainline/scripts/libdagu-cogl-syncfd.so`
- `linux-mainline/scripts/dagu-cogl-syncfd-install.sh`（**不要**当日常）
- `linux-mainline/scripts/dagu-chromium-native.sh`（`DAGU_CHROME_NO_SYNCOBJ=1` 仅 A/B；日常仍开 syncobj。已加 `Translate,TranslateUI` 以免翻译条挡首页）

#### 12.3 还没落地的真修复

`linux-mainline/patches/mutter-50-pending-release-tick.patch` 现在是 **50.1 真 diff**：

1. `newly_attached` 也 `meta_surface_actor_schedule_update`（不 1×1）。
2. `get_latest_sync_fd()==-1` 时用已 signal 的 sync_file 写 release timeline。

必须 host 交叉编 `libmutter-18`，另开窗口换 `libmutter-18-0`。板上根分区约 250 MB，不能本机编。换包后再跑 `linux-mainline/scripts/dagu-dpu-jank-capture.py --host`：慢滑 `>50 ms` 归零或 4 洞消失；`chrome://gpu` 仍 Hardware；播片 `venus_irq` 上升。

不要关 GPU raster，不要锁频，不要默认 Vulkan / Overlay / BFS，不要再 `LD_PRELOAD` 强制 `dec_use_count`。

### 13. Ozone `WaitForFrameCallback` 与两条 mutter 补丁否决（2026-09-13 09:06）

official-152 源码把「WaitForSwap」钉成 **Ozone 等 `wl_surface.frame`**，不是 viz 里那个 TRACE 名：

`linux-mainline/out/chromium-v4l2-src/official-152/ui/ozone/platform/wayland/host/wayland_frame_manager.cc` `MaybeProcessPendingFrame()`：上一帧的 `wl_frame_callback` 还在就 `return`（`WaitForFrameCallback`）。`kFrameCallbackTimeoutMs=50` 的 freeze **只在 video capture** 才跳过等待。

50.1 `emit_frame_callbacks_for_stage_view`（板上 `libmutter-18.so.0` **VA `0x167340`**）：

```c
flush = surface->flush_frame_callbacks;   /* GObject 布局 +476 */
if (!flush && !meta_surface_actor_wayland_is_view_primary(actor, view))
  continue;   /* VA 0x1673c8  cbz w0, skip */
```

`update_area`（**VA `0x160f70`**）：`unobscured_region` 为空就 `return`，damage 丢掉。空 region 还会让 `is_view_primary` 为假。270° + 1.25 + `scale-monitor-framebuffer` 会把最大化 Chrome 算成「被挡光」。

`org.gnome.shell disable-user-extensions` 又被设成 **true**，`dagu-scanout@local` 停在 INITIALIZED。已改回 `false`，扩展 ACTIVE。`/var/log/dagu-dpu` 曾占 **363 MB**（根分区 98%），已清；主机仍有 `linux-mainline/out/display-stress/`。

| 窗 | 条件 | 慢滑 Hz | max / >50 | 快滑 >50 |
|----|------|---------|-----------|----------|
| `074651` | 日常泵，无 hook | **87** | **178 / 4** | **0** |
| `085900` / `090107` | NOP `0x1673c8`（非 primary 也发 frame callback） | 53–56 | 208–242 / 8 | 2–5 |
| `090343` | 空 unobscured 改走整窗 `queue_redraw_with_clip` | 54 | **341 / 7** | 2 |
| `090601` | `NewContentForCheckerboardedScrolls` OFF | 52 | 142 / 6 | 1 |

8 ms `schedule_update` 泵 + 强制发 callback = Chrome 每拍都 `PlayBackFrame` = 整窗 270° destile 风暴。空 region 改全 clip 同理。**日常已卸**，`UnsetEnvironment` 再次含 `LD_PRELOAD`。

```text
grep libdagu /proc/$(pgrep -u dagu -x gnome-shell)/maps   # 必须空
```

源（不当日常）：

- `linux-mainline/scripts/dagu-mutter-frame-flush.c` / `libdagu-mutter-frame-flush.so`
- `linux-mainline/scripts/dagu-mutter-frame-flush-install.sh`
- `linux-mainline/scripts/dagu-mutter-damage.c` / `libdagu-mutter-damage.so`

交叉编 `mutter-50-pending-release-tick.patch`（`schedule_update` on attach）比 085119 的 `queue_redraw` 更弱，**不要为这份旧 patch 去编 mutter**。

下一线：Chrome 在封面 decode/raster 间隙仍要交出滚动帧，且 **不能**多打整窗 destile。official-152 `out/dagu/chrome` 可增量编 Ozone/cc（448 MB；根分区现约 550 MB，另开窗口再换包）。不要关 GPU raster，不要锁频，不要默认 Vulkan / Overlay / BFS。

### 14. official-152 令牌式 skip + 滚动 smoothness（编包中，2026-09-13 09:15）

强制 Mutter 发 callback / 空 region 全 clip 已否决（§13）。4 个慢滑洞在 NOP emit 后仍在，因为：

1. Ozone `WaitForFrameCallback` 把下一帧堵在 `pending_frames_`；`kMaxPendingSubmitFrames=1` 让 renderer 不再 Draw。
2. `ProxyImpl::RenewTreePriority` 在 `IsCurrentScrollMainRepainted()` 时进 `NEW_CONTENT_TAKES_PRIORITY`，等封面 raster。关 `NewContentForCheckerboardedScrolls` 拆不掉这条（090601）。

活树改动（说明：`linux-mainline/patches/chromium-152-dagu-scroll-interlock.md`）：

- `wayland_frame_manager.cc`：超时 16 ms 发**一张**令牌，未 release 帧 < 2 才放行一帧。不置 `should_skip_frame_callbacks_`。
- `proxy_impl.cc`：精确滚动时 `SMOOTHNESS_TAKES_PRIORITY`，不再因 main-repaint 进 NEW_CONTENT。

验收必须看 `phase_kickoff.slow`（`linux-mainline/scripts/dagu-dpu-jank-capture.py` 现会写这项），不要看整窗 kickoff。日常 mutter：无 `libdagu*`，`dagu-scanout@local` ACTIVE，1.25 / transform 3。

`jank-capture-20260913-091700`（令牌 16 ms、不合并 pending）：慢滑 **50.7 Hz / max 118 / >50=7**，比 `074651` 更差。超时把排队的封面帧逐张 destile。091858 合并 pending 仍差，且曾被翻译条污染。Ozone skip 已撤回，板上 chrome 只留 `proxy_impl` smoothness。

**不再用 B 站首页。** 验收页：`linux-mainline/scripts/dagu-pipeline-lab.html`，服务 `linux-mainline/scripts/dagu-pipeline-lab.py`（`http://127.0.0.1:8770/`）。HUD 实时 rAF/FPS/GPU/venus，飞片 + 切镜 + 硬解 H.264/HEVC/VP9。采集：`dagu-dpu-jank-capture.py --host` 会先开实验室再滑。

Ozone 现按 **wp_presentation 已呈现** 才放行下一帧（`SkipWaitAfterPresented`），不再死等 `wl_surface.frame`。`jank-capture-20260913-093430`（暖机 probe 页）：慢滑 **29.9 Hz / max 102 / >50=28**。这是 270° 整窗 destile + 多路 60fps 片的地板，不是原来那 4 个空闲互锁洞。目标未过。

### 15. 自研 `dagu-pipeline-tab.html`：互锁根因是 scale-monitor-framebuffer（2026-09-13 10:05）

验收页改名为 `linux-mainline/scripts/dagu-pipeline-tab.html`（`dagu-pipeline-lab.html` 同内容）。片子改存 `/var/lib/dagu-pipeline-lab/`（根分区已扩到 105G，不再用 tmpfs）。

`hole-blame-20260913-095339`（仍开 `scale-monitor-framebuffer`）：kick 37、洞 32、几乎全是 `userspace-no-commit`。洞里 GPU 常为 0，gnome-shell 在 `poll_schedule_timeout`，Viz/gdrv 在 `futex_do_wait`，vblank 照走。**不是内核 fence，是 Chrome 等 callback/presentation、Mutter 把最大化窗算成被挡光后空转。**

24 ms Ozone stuck watchdog（`SkipWaitStuck`）在 presentation 永不来时退化成节拍器：`jank-capture-20260913-095822` 慢滑 **4.1 Hz / max 768 / >50=23**。已从 official-152 撤掉。

**真正拆掉空等的是关掉 `scale-monitor-framebuffer` 并 SIGQUIT gnome-shell 让 Mutter 重读**（以前 `075755` 只改 gsettings、没重启 shell，feature 仍在跑，结论作废）：

| 窗 | 条件 | 慢滑 Hz | max / >50 |
|----|------|---------|-----------|
| `095339` blame | 1.25/270 + framebuffer scale | kick 37 | 32 个洞，GPU 空 |
| `095822` | 同上 + 24 ms watchdog | **4.1** | **768 / 23** |
| `100147` | **无 framebuffer scale** + watchdog | **91.4** | 103 / **3** |
| `100427` | 无 framebuffer scale + 只 SkipWaitAfterPresented + actor `queue_redraw` | **75.9** | **66.6 / 4** |
| `100506` | 同上但泵只 `schedule_update` | 57.4 | 367 / 17 |
| `100547` | 恢复 actor `queue_redraw` | 82.8 | 149 / 5 |

日常改为：`experimental-features=@as []`，仍 **scale 1.25 / transform 3**。`linux-mainline/scripts/rootfs-desktop-setup.sh` 已改。`dagu-scanout@local` 在 `enable()` 里 `compositor.disable_unredirect()`，`_tickClock` 对焦点窗 `queue_redraw`（不要 1×1 destile）。无 `libdagu*`。

`phase_kickoff.slow.gaps_gt_50ms` 还没归零（最好 3–4 个 50–67 ms）。不要把 framebuffer scale 改回去。不要再上 16/24 ms 令牌。下一刀是把剩余 destile 尖峰压到 &lt;50 ms，不是再 NOP emit。

### 16. 实验室页 9.5fps：DPU 泵 ≠ Chrome 出帧（2026-09-13 10:20）

`jank-capture-20260913-102054`（关 framebuffer scale + actor `queue_redraw` + 21 路 `<video>`）：

| 项 | 值 |
|----|----|
| `phase_kickoff.slow` | **115.3 Hz / max 108 / >50=2** |
| 页 HUD rAF | **9.5 fps / p50 100 ms** |
| `gpu_busy` | 25–51%（670 MHz） |
| Chrome `type=gpu-process` | **101% CPU**、**16× `/dev/video14`** |
| `venus` Δ | 2s +929（硬解在走） |
| 面板 vblank | 119 Hz |

kickoff 高是 `dagu-scanout@local` 每 8 ms `queue_redraw` 把**旧** Chrome 缓冲再 destile 一遍，不是页面 120fps。21 个 `<video>` 只对应 5 个片源，把同一路 Venus 开了四次，GPU 进程单核打满，rAF 卡在 ~100 ms。

`transform 0` method 1 A/B：日常已 `set-daily-temp` 回 1.25/270。竖屏重开后 rAF dt≥260 ms，不能当 120fps 交付。

页已改：每个片源 **一路** Venus `<video>` 图层（5 路）。WebGL `texImage2D(video)` **不是** 零拷贝（gpu-process 164% CPU、rAF 4.3），已撤回。HUD 走 `/api/dump`，不要用截图门户 destile 当帧率。

还没到内容 120fps。正路仍是 Mutter identity + Chrome GL 预旋 270°，以及保证 `wp_presentation` / `wl_surface.frame` 每拍到 Chrome。不要 16/24 ms 令牌，不要 `libdagu*`。

`jank-capture-20260913-102725`（5 路唯一 Venus `<video>`）：`phase_kickoff.slow` **104.1 Hz / max 41.6 / >50=0**（慢滑 DPU 洞第一次清零）。页 HUD 仍是 **22–45 fps / p50 16–33 ms**——Chrome 出帧还在 60Hz 默认或 WaitForSwap，不是 120。official-152 `wayland_output.cc` `OnMode` **丢掉了 `refresh`**，没有把 120Hz 交给 Display/vsync。

### 17. 120 Hz 合成钟 + Mutter identity / Chrome GL 预旋（2026-09-13 10:45）

源已接上 `wl_output.refresh` → Display `display_frequency` → `SetDisplayVSyncParameters`。`wp_presentation.refresh` 为 0 或 &gt;9 ms 时钳成 120 Hz。60 Hz 形的 `display_frequency` 也按 120 处理。`BeginFrameArgs::DefaultInterval()` 改为 120 Hz（`linux-mainline/out/chromium-v4l2-src/official-152/components/viz/common/frame_sinks/begin_frame_args.h`），缺 refresh 时合成钟不再落到 16.7 ms。

Linux GLES 是 `OrientationMode::kLogic`，`SetDisplayTransformHint` **不会**旋像素（`SkiaOutputDeviceGL` 还 DCHECK reshape=NONE）。预旋走 aura 根图层：`DAGU_CHROME_PANEL_ROTATE=270` 时 `SetRootTransform`，Skia/GL 把横屏 UI 画进物理 1600×2560 `wl_buffer`。Venus 仍走 `/dev/video14`。

这条路径要求 Mutter **transform 0**（identity destile）。日常仍是 1.25 / transform 3，不要默认开预旋（会叠 270）。实验室：

```text
# 板上
/usr/local/sbin/dagu-lab-identity-120.sh
# 恢复日常
python3 /usr/local/sbin/dagu-mutter-orientation.py set-daily-temp
```

脚本：`linux-mainline/scripts/dagu-lab-identity-120.sh`。包装说明：`linux-mainline/scripts/dagu-chromium-native.sh`。换包：`linux-mainline/scripts/dagu-chrome-120-deploy.sh`（rsync 限速，避免再把 eMMC/sshd 写死）。

实验室页自动滑不再每帧 `window.scrollTo`（会逼主线程排版）。`#feed` 用 `translate3d` 走 GPU 图层。

### 18. 降压策略（2026-09-13 18:59）：OOM/硬挂，不是 panic

上一 boot 无 oops。10:03–10:24 Chromium OOM 6 次，最后一次在 Venus `VIDIOC_REQBUFS` / `iommu_dma_alloc`。10:35 journal 切断后整盘不再写，长按才进 fastboot。5.4 GiB + 512 MiB swap 被 5 路 Venus + 默认 profile（B 站 IndexedDB）+ destile shmem 吃穿。

本 boot 策略：

- **默认 light**：2 路 720p Venus（H.264 + HEVC），3 张 GPU 卡片。`?full=1` 才开 5 路/1080。
- **一个**干净 profile：`/tmp/dagu-lab-profile`。不要并行 `chrome://gpu` / 默认 `~/.config/chromium`。
- 验收只读 **`http://127.0.0.1:8770/api/dump`**。`#dumpbox` 已 `display:none` 且不再每秒 `textContent`（那会 1 Hz 整页重排，见 §19）。
- 额外 **2 GiB** `/swapfile2`（fstab 已加）。挂前探针 `linux-mainline/scripts/dagu-hang-watch.py`：`MemAvailable < 350 MiB` 则 SIGTERM chromium。
- **不要**在测 lab 时开 `dagu-scanout@local`。不要换 448 MB chrome 的同时播片。

第一份 dump（未换 DefaultInterval=120 的包）：

- `linux-mainline/out/hang-20260913/lab-dump-light.json`
- `videos=2`、`video14_open=2`、`venus_irq` 上升、`vblank_fps=120`、`software_decode=false`
- `p50=16.7` 在换上 `DefaultInterval=120` 之后仍在。根因是 Linux `use_preferred_interval_`：60 fps Venus 片把 BeginFrame 钉成 16.7 ms。已在 `root_compositor_frame_sink_impl.cc` 关掉。第一份 dump：`p50=8.3` / `fps=111.3` / `video14_open=2` / `verdict.pass=true`（`linux-mainline/out/hang-20260913/lab-dump-nopref60.json`）。暖机窗口里 HEVC 循环重启仍会打出 `p99>100` 的洞，还不是稳满 120。

### 19. identity 下 cull / frame-flush poke 消不掉洞（2026-09-13 20:12）

实验室现况：scale 1.0 / transform 0、Chrome 全屏 + `DAGU_CHROME_PANEL_ROTATE=270`、scanout off、`experimental-features=@as []`。

`libmutter-18.so.0.0.0` `update_area`（VA `0x160f70`）两条丢 damage 的路都 poke 过，**kickoff 洞还在**：

| 窗 | 条件 | kickoff Hz | max / gt50 |
|----|------|------------|------------|
| `listen-ident-rot-fs-20260913-1959` | identity + 预旋 + Venus | 103 | 122 / 8 |
| `listen-unobscured-poke-20260913-2006` | 空 unobscured → `queue_redraw`（`0x160f78`） | 103.4 | 142 / 8 |
| `listen-isect-poke-20260913-2010` | 再加空 intersection → `queue_redraw`（`0x161010`） | **95.3** | 117 / 10 |
| `listen-frameflush-ident-20260913-2012` | 再 NOP `is_view_primary`（`0x1673c8`） | 102.3 | 117 / 13 |
| `listen-nodumpbox-20260913-2016` | 关 `#dumpbox` 重排 + 内存充足 | 97.4 | 125 / 10 |
| `listen-novid-nodumpbox-20260913-2018` | 同上 + `?novid=1` | 104.4 | **209 / 9** |

vblank 仍约 119 Hz（偶发 33–66 ms，不是每洞都有）。洞里 gnome-shell=`poll_schedule_timeout`，Viz=`futex_do_wait`，GPU busy 常 0–20%。  
结论：**identity 全屏已经不是「空 unobscured / 非 primary」那条 270° 互锁；也不是 Venus loop / dumpbox 1 Hz 重排。** 源码补丁仍留着给日常 1.25/270：

- `linux-mainline/out/mutter-50.1/src/compositor/meta-surface-actor.c`
- `linux-mainline/out/mutter-50.1/src/wayland/meta-wayland-actor-surface.c`
- `linux-mainline/patches/mutter-50-unobscured-damage.patch`
- `linux-mainline/scripts/dagu-mutter-damage.c`（空 region + 空 intersection）

`frame-flush` 已从活进程撤掉（`0x1673c8` 复原）。cull 两条 poke 仍在 gnome-shell pid 1105 内存里，重启 shell 即消失。

板上还看到：重开 Chrome 后 `MemAvailable≈2.4 GiB` 洞仍在；`#dumpbox` 已移出合成路径（`linux-mainline/scripts/dagu-pipeline-tab.html`）。`vblank timeout: 400000` 仍约每 5–15 min 一对，解释不了每 1–2 s 的洞。

下一刀交叉编并换 `libmutter-18.so.0.0.0` 已做，**identity 洞没有消掉**，见 §20。

### 20. 交叉编 `libmutter-18` 换上了，skipped-paint 假说未过（2026-09-13 20:43）

主机 Ubuntu 26.04 x86_64 交叉编 50.1 + Ubuntu clutter vfunc / snapd 补丁。只换 `libmutter-18.so.0.0.0`，clutter/cogl/mtk 仍用发行版。不要在板上 `apt-get source`。

第一次只换未打 Ubuntu `get_global_cursor_type` 的 so：`MetaClutterBackendNative` class size 小于 stock `ClutterBackend`，gnome-shell 起不来。`ldconfig` 还会把同目录里的 `.stock-…` 备份当成更新 SONAME。备份必须放 `/var/backups/dagu-mutter/`。已 `systemctl restart gdm` 救回会话。

打上 `linux-mainline/out/mutter-50.1/` 里全部 ubuntu clutter/window 补丁后再换，gnome-shell pid 稳定映射 4.2 MB so（BuildID `841aa1db…`）。identity + 预旋 + 2 路 Venus：

| 窗 | so | kickoff Hz | max / gt50 | dump fps / p50 / holes |
|----|----|------------|------------|------------------------|
| `listen-ident-rot-fs-20260913-1959` | stock 50.1-0ubuntu2.2 | 103 | 122 / 8 | （当时基线） |
| `listen-mutter-dagu-20260913-2041` | dagu discard | 82.6 | 241 / 11 | 65.5 / 8.4 / 33 |
| `listen-mutter-dagu-warm-20260913-2041` | 同上暖机 | 75.7 | 233 / 11 | 77.4 / 8.4 / 56 |
| `listen-mutter-framecb-20260913-2043` | discard + 强制 `wl_surface.frame` | 74.3 | 233 / 14 | 69.7 / 16.6 / 17 |
| `listen-mutter-framecb-warm-20260913-2043` | 同上暖机 | 80.2 | 158 / 12 | 70.8 / 8.4 / 53 |

vblank 全程 **120.0 Hz / max 8.4 / gt50=0**。`video14_open=2`，`software_decode=false`，`venus_irq` 上升。GPU busy 快照常 0。  
**skipped-paint → discarded + 强制 frame callback 消不掉这批 kickoff 洞。** 板上已恢复 stock `2832288` 字节 so。产物仍留在主机。

源码 / 工具：

- `linux-mainline/out/mutter-50.1/src/wayland/meta-wayland-presentation-time.c`
- `linux-mainline/out/mutter-50.1/src/wayland/meta-wayland.c`（`meta_wayland_compositor_emit_frame_callbacks`）
- `linux-mainline/out/mutter-50.1/src/wayland/meta-wayland-buffer.c`
- `linux-mainline/out/mutter-50.1/src/compositor/meta-surface-actor.c`
- `linux-mainline/patches/mutter-50-skipped-paint-discard.patch`
- `linux-mainline/patches/mutter-50-pending-release-tick.patch`
- `linux-mainline/scripts/dagu-mutter-sysroot.py`
- `linux-mainline/scripts/dagu-mutter-cross.sh`
- `linux-mainline/scripts/dagu-mutter-deploy.sh`
- `linux-mainline/out/libmutter-18.so.0.0.0-dagu`
- `linux-mainline/out/dagu-mutter-aarch64-cross.ini`
- 验收：`linux-mainline/out/display-stress/listen-mutter-*-summary.json` 与板上 `/var/log/dagu-dpu/listen-mutter-*`

恢复：`/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2` → `/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0`（已执行）。  
下一刀不要再假设「只差 skipped-paint」。要反编译活 Chrome Ozone `MaybeProcessPendingFrame` / drm-syncobj wait，对上洞里 Viz `futex_do_wait` 等的是哪把锁。

### 21. 活 Chrome Ozone：洞里不是卡在一把 mutex（2026-09-13 21:05）

板上 `/usr/lib/chromium/chromium` BuildID `858b8197c2ea8f42e85174323b0fa5ee49eeaae1`，与主机  
`linux-mainline/out/chromium-v4l2-src/official-152/out/dagu/chrome` 同一份（未 strip）。  
`WaylandExternalBeginFrameSource` **关**（`linux-mainline/scripts/dagu-chromium-native.sh` 默认）。  
`WaylandLinuxDrmSyncobj` **开**。identity + `DAGU_CHROME_PANEL_ROTATE=270`，stock `libmutter-18-0:arm64 50.1-0ubuntu2.2`。

RX `PT_LOAD` 是 `p_offset=0x2ba0000` / `p_vaddr=0x2bb0000`（差 64 KiB）。maps  
`558dcb0000-559a6bc000 r-xp 02ba0000`。runtime = `maps_start + (elf_va - 0x2bb0000)`。  
按 file offset 去 peek 会读偏 64 KiB，PACIASP 对上是巧合。

`MaybeProcessPendingFrame` 活指令（`/proc/<gpu>/mem` 核对）：

| ELF VA | insn | C |
|--------|------|---|
| `0x3532274` | `0xd503233f` PACIASP | 函数入口 |
| `0x3532314` | `0x36001789` `tbz w9,#0 → 0x3532604` | `!feedback.has_value()` → `WaitForFrameCallback` **return** |
| `0x3532604` | `0x52801489` `mov w9,#0xa4` | TRACE 后落到 epilogue |
| `0x3534348` | `0xd503245f` BTI | `FrameCallbackTimeout`：`video_capture_count_==0` 时 **不** `should_skip` |

`kFrameCallbackTimeoutMs=50` 只在录屏时 skip。日常这条超时是空操作。  
`SkipWaitAfterPresented` 已在板上包里。

`/proc/<tid>/syscall` 的 PC 是 libc `svc`，对不上 Ozone。洞里（kickoff 已停 ≥45 ms）ptrace 走栈：

| 线程 | wchan | 用户态 |
|------|-------|--------|
| `VizCompositorTh` | `futex_do_wait` | `MessagePumpDefault::Run` → `WaitableEvent::TimedWait` → `ConditionVariable::TimedWait` |
| `Chrome_ChildIOT` | `do_epoll_wait` | `MessagePumpEpoll::WaitForEpollEvents`（无 Wayland/mojo 事件） |
| `gnome-shell` | `poll_schedule_timeout` | 合成钟没排下一拍 |

偶发一洞抓到 Viz 在 `SkiaRenderer::FinishDrawingRenderPass` / `EndPaint`（在画，但 DPU 还没 kickoff）。  
**不是** `WaitForFenceAvailable`、**不是** `pthread_mutex`、**不是** 卡在 `MaybeProcessPendingFrame` 里。  
`futex_do_wait` 是合成线程空转等下一档 delayed task；洞长达 100 ms+ 说明 **8.3 ms 的 BeginFrame deadline 根本没排上**，两边钟一起停。

一条 poke：`0x3532314` `tbz` → `NOP`（不呈也 attach）。已核对 opcode，测完写回 `0x36001789`：

| 窗 | kickoff Hz | max / gt50 |
|----|------------|------------|
| 同进程基线 | 97.0 | 133.7 / 7 |
| NOP `tbz` | 93.8 | **233.3 / 5** |

`video14_open=2`，`software_decode=false`。与 §20 的 skipped-paint discard 同类：解开 Ozone 等待但没有 presentation，洞还在，尖峰更差。不要留这条 poke。

工具 / 抓痕：

- `linux-mainline/scripts/dagu-chrome-ozone-stack.py`
- `linux-mainline/out/display-stress/ozone-stack-20260913-205037/report.json`
- `linux-mainline/out/display-stress/dagu-ozone-holewalk.json`
- `linux-mainline/out/display-stress/dagu-ozone-tbz-ab.json`
- 源：`linux-mainline/out/chromium-v4l2-src/official-152/ui/ozone/platform/wayland/host/wayland_frame_manager.cc`
- 源：`linux-mainline/out/chromium-v4l2-src/official-152/ui/ozone/platform/wayland/host/begin_frame_source_wayland.cc`（flag 关，未进活路径）

下一刀不要再 NOP Ozone wait / 16 ms 令牌。要在洞里读 Viz `DisplayScheduler` 的 `pending_swaps_` / 下一档 deadline / `needs_begin_frames`，以及 renderer 是否还在要 BeginFrame。目标是让 8.3 ms 钟在没有 `wl_surface.frame` 时也不停。

### 22. 洞里 `pending_swaps_=2` 打满，gpu-busy 停钟（2026-09-13 21:20）

vtable 扫活 GPU 进程（pid 133908），`DisplayScheduler` 在 `0x1c000bc600`（`next_swap_id` 四万+，主显示）。字段已对指令：

| 字段 | 对象偏移 | 对上的 insn |
|------|----------|-------------|
| `pending_swaps_` | **+604** | `DidSwapBuffers` `ldr w8,[x0,#604]` @ ELF `0xbc4ed60` |
| `next_swap_id_` | +600 | 同上 +600 |
| `observing_begin_frame_source_` | +639 | `OnBeginFrameForScheduling` `ldrb [x0,#639]` |
| `begin_frame_source_` | +200 | `DidSwapBuffers` 里 `SetIsGpuBusy` |
| `BeginFrameSource::is_gpu_busy_` | +16 | `OnTimerTick` `ldrb [x0,#16]` |
| `gpu_busy_response_state_` | +32 | 0=idle 1=再发一拍 2=**停发 BF** |

`max_pending_swaps = GetBufferCount()-1`（`skia_output_device_gl.cc`）。活体 pend 顶在 **2**，所以至少 3 缓冲。`DelayBasedBeginFrameSource::OnTimerTick`：busy 后第二拍 `state=2` 直接 `b` 走 epilogue，8.3 ms 钟还在转但 **不再 IssueBeginFrame**。

10 s 窗（`linux-mainline/out/display-stress/dagu-sched-holes.json`）：kickoff **90.6 Hz / max 222.8 / gt50=10**。全程直方图：

| 字段 | 主状态 |
|------|--------|
| `observing` | 1：3820　0：147 |
| `pending_swaps` | **2：3033**　1：889　0：45 |
| `is_gpu_busy` | **1：3035**　0：932 |
| `gpu_busy_state` | 0：2681　1：991　**2：295** |

洞里（`next_swap_id` 经常整段不动）：

- 多数：`obs=1`、`pend=2`、`busy=1`，大洞 `state=2` 占满（118 ms、112 ms、**222 ms**）
- 109 ms / 222 ms 两洞还出现 `observing=0`（`ShouldDraw()==false` → `StopObservingBeginFrames`）
- `video14_open=2`，`software_decode=false`，`p50=8.3`

结论：日常就顶在 2 个未 ack swap 上跑。ack（`DidReceiveSwapBuffersAck` ← Ozone `OnSubmission`）一停 80–220 ms，gpu-busy 停 BF，Mutter 无新 attach 进 `poll_schedule_timeout`，两边钟一起死。§21 的 `WaitableEvent` 是这个停钟的空转，不是另一把 mutex。

一条 poke：`OnTimerTick` `0xa53f180` `cbz w8, +0x30`（`0x34000188`）→ `b +0x30`（`0x1400000c`），busy 时仍发 BF。已核对、测完写回：

| 窗 | kickoff Hz | max / gt50 |
|----|------------|------------|
| 基线 | 76.2 | 230 / 7 |
| 忽略 gpu-busy | 91.6 | **225 / 9** |

钟能多走，**消不掉洞**：`pending_swaps_>=2` 时 `DrawAndSwap` 照样不跑，没有新 `wl_buffer`。不要留这条 poke。

下一刀是 **`OnSubmission` 为什么 100 ms+ 不来`**：`MaybeProcessSubmittedFrames`（ELF `0x35330a4`）在第一帧之后要等上一帧 `submitted_buffers` 全 release（drm-syncobj / `wl_buffer.release`）。DPU 仍 90 Hz kickoff 时，多半是 Mutter 在扫旧缓冲却没 signal timeline（`cogl_context_get_latest_sync_fd()==-1`）。不要再 NOP Ozone frame-callback wait。

工具 / 抓痕：

- `linux-mainline/out/display-stress/dagu-sched-holes.json`
- `linux-mainline/out/display-stress/dagu-gpubusy-ab.json`
- 源：`linux-mainline/out/chromium-v4l2-src/official-152/components/viz/service/display/display_scheduler.cc`
- 源：`linux-mainline/out/chromium-v4l2-src/official-152/components/viz/common/frame_sinks/begin_frame_source.cc`
- 源：`linux-mainline/out/chromium-v4l2-src/official-152/ui/ozone/platform/wayland/host/wayland_frame_manager.cc`（`MaybeProcessSubmittedFrames`）

### 23. `OnSubmission` 不等 release、关 syncobj，洞都还在（2026-09-13 21:15）

`MaybeProcessSubmittedFrames` 循环里 `submitted_buffers` begin/end 在 frame+512/+520。空才给下一帧 `OnSubmission`。

活指令（GPU pid 133908，runtime `0x558e633294`）：

| ELF VA | insn | C |
|--------|------|---|
| `0x3533288` / `0x353328c` | `ldr` #512 / #520 | `submitted_buffers` 区间 |
| `0x3533290` | `cmp` | `empty()` |
| `0x3533294` | `0x540004a1` `b.ne 0x3533328` | `!empty` → **break**（不再 ack） |

一条 poke：`0x3533294` → `NOP`（`0xd503201f`），ack 不等上一帧 release。`AttachBuffer` 仍看 `released()`。已核对、测完写回：

| 窗 | kickoff Hz | max / gt50 |
|----|------------|------------|
| 同进程基线 | 85.3 | 128 / 7 |
| NOP `b.ne` | 82.2 | **226.7 / 7** |

poke 后快照 `pending_swaps_` 仍是 **2**。`video14_open=2`，`software_decode=false`。提前 ack 没消洞，尖峰更差（未 release 就复用/多 attach）。

再 A/B：`DAGU_CHROME_NO_SYNCOBJ=1` 重开 identity（走 `wl_buffer.release` / implicit，不走 drm-syncobj）。测完已用 `linux-mainline/scripts/dagu-lab-identity-120.sh` 恢复默认 syncobj。

| 窗 | kickoff Hz | max / gt50 | dump p50 |
|----|------------|------------|----------|
| 关 syncobj | 97.9 | **233.6 / 6** | 8.3 |

Venus 仍 2 路。**release/syncobj 不是这批 kickoff 洞的充分条件。** `pending_swaps_=2` 是 3 缓冲管线日常顶满，和洞相关但解开 ack 等不到 120 Hz。

下一刀不要再 NOP Ozone wait / OnSubmission / 关 syncobj。要对 Mutter 合成钟：为什么 fullscreen Chrome + 动画时仍进 `poll_schedule_timeout`（clutter frame clock idle）。洞里 gnome-shell 已经停钟，Chrome 再怎么 ack 也没有 KMS commit。

抓痕：

- `linux-mainline/out/display-stress/dagu-onsubmission-ab.json`
- `linux-mainline/out/display-stress/dagu-nosyncobj-listen.json`

### 24. `pending_swaps_` 顶满时强画会崩 GPU（2026-09-13 21:10）

`DisplayScheduler::AttemptDrawAndSwap` 活指令（official-152，未 strip）：

| ELF VA | insn | C |
|--------|------|---|
| `0xbc4d5f4` | `cbz` +596 | `!needs_draw_` → `StopObservingBeginFrames` |
| `0xbc4d664` | `ldr w21,[x19,#604]` | `pending_swaps_` |
| `0xbc4d678` | `0x54fffeaa` `b.ge` epilogue | `pending >= MaxPendingSwaps` → **不** `DrawAndSwap` |

新 GPU pid 148546，对象 `0x14022b9c00`。6 s 洞里直方图（2562 点）：

| 状态 | 次数 |
|------|------|
| `pend=2 nd=1 obs=1 vis=1` | **1389**（日常顶满仍在要画） |
| `pend=1 nd=1 obs=1` | 417 |
| `pend=2 nd=0 obs=1` | 348 |
| `obs=0` | 10（少） |

`next_swap_id` 26304→26828（6 s / 87 Hz），和 kickoff 87.4 Hz / gt50=6 对齐。钟多数还在转，卡在 **3 缓冲打满**。

一条 poke：`0xbc4d678` → `NOP`，`ShouldDraw` 时无视 pending 上限。核对后立刻崩 GPU（`/proc/148546/mem` 消失）。主进程拉起新 GPU **153727**，insn 回到 `0x54fffeaa`。`/dev/video14` 节点和 `venus_*` 还在，但一度 **0 打开**；已用 `linux-mainline/scripts/dagu-lab-identity-120.sh` 重开 identity。

不要再 poke 这条。3 缓冲没有第 4 槽，强画就是复用 in-flight。`FrameCallbackTimeout` 无视 `video_capture_count_`（`0x353435c` `b.le`→NOP）也已测：87 Hz / max 163 / **gt50=6**（基线 84 / 259 / 4），已写回。

`maybe_reschedule_update`（`libmutter-clutter-18.so` `0x67c00` `cbz x0, +0x3c` / `0xb40001e0`）：无 `pending_reschedule` 且无 `timelines` 就进 deferred / `ret`。一条 poke 改成 `cbz x0, +4`（`0xb4000020`）让 idle 也 `schedule_update`。已核对、测完写回。Venus `video14_open=2`。

| 窗 | kickoff Hz | max / gt50 | dump |
|----|------------|------------|------|
| 基线 | 87.3 | 225 / 7 | — |
| idle 也排钟 | **78.9** | 133 / **9** | fps 61 / p50 **16.6** |

8.3 ms 空转合成更差（destile 风暴、内容帧变稀）。不要留，也不要再上 `dagu-scanout@local`。

抓痕：

- `linux-mainline/out/display-stress/dagu-pendcap-ab.json`
- `linux-mainline/out/display-stress/dagu-framecb-timeout-ab.json`
- `linux-mainline/out/display-stress/dagu-mutter-idlecbz-ab.json`

### 25. `wait_for_all=0`，洞里没有 DPU timeout（2026-09-13 21:15）

重开后 GPU `163203`，对象 `0x24000d4600`。`wait_for_all_surfaces_before_draw_`（+636）全程 **0**。`ScheduleBeginFrameDeadline` 的 `csel → kNone`（ELF `0xbc4eb08` `0x1a801154`）这条活路没走进去。8.3 ms deadline 被 `pending>=2` 打成 `kLate`，不是无限等。

8 s DPU 事件（`video14_open=2`）：kickoff 84.9 Hz / max 199.9 / gt50=8。`dpu_enc_frame_done_timeout` / `pdone_timeout` / `underrun` / `wait_event_timeout` **全 0**。`prepare_kickoff` 与 `kickoff` 次数相同。200 ms 洞里 vblank 也在 ~14 ms 后停；较小洞里 vblank 还在走。硬件没卡死，是 **没有新 atomic commit**。

不要再 poke pending 上限、idle 空转钟、`wait_for_all` csel。

抓痕：`linux-mainline/out/display-stress/dagu-dpu-hole-events.json`

### 26. 大洞里合成钟在 IDLE，强制 triple 更差（2026-09-13 21:20）

活 `ClutterFrameClock` `0x55a4b090d0`（GSource 名 `[mutter] Clutter frame clock`，`refresh_rate=120`）。6 s 与 Chrome `next_swap_id` 对齐：

- 日常：`DISPATCHED_ONE`（等 present），`inhibit=0`
- `next_swap_id` 停 ≥45 ms 的大洞（219 / 221 / 107 ms）：钟在 **IDLE**、`pending_reschedule=0`，Chrome `pending_swaps_=2`
- kickoff **93 Hz / max 225 / gt50=5**，`video14_open=2`

`want_triple_buffering`（`libmutter-clutter-18.so` `0x67128`）在 destile 估计 `< 8.3 ms` 时返回 0，`DISPATCHED_ONE` 只 `pending_reschedule=TRUE` 然后等 present。一条 poke：`0x671a0` `cset w0, le`（`0x1a9fc7e0`）→ `mov w0, #1`，估计再小也 triple。已核对、测完写回。

| 窗 | kickoff Hz | max / gt50 |
|----|------------|------------|
| 基线 | 103.3 | 176 / 3 |
| 强制 triple | **90.6** | 130 / **10** |

不要留。idle 空转钟（§24）和强制 triple 都填不满洞，还会多 destile。

抓痕：

- `linux-mainline/out/display-stress/dagu-clock-holes.json`
- `linux-mainline/out/display-stress/dagu-triple-ab.json`

### 27. 洞里 3 帧堆在 `submitted_frames_`，最老的已 present 仍不 release（2026-09-13 21:25）

浏览器 `WaylandFrameManager` `0x4400b59ee0`（`pending_frames_` +8，`submitted_frames_` +40，`video_capture` +296，`should_skip` +301）。`WaylandFrame`：`wl_frame_callback` +544，`feedback.has_value` +656，`submitted_buffers` begin/end +512。活 ELF 已有 SkipWaitAfterPresented：`0x3532314` `tbz` 看的是 **`submitted.back()`** 的 feedback，不是最老的一帧。`FreezeTimeout` 已被 LTO 丢掉（无符号、无字符串）。

6 s 直方图（`cb,fb,empty` = 有 frame callback / 已 present / buffers 已空）：

| 状态 | 次数 |
|------|------|
| 3 submitted：`(0,1,0),(0,0,0),(1,0,0)`，gpu pend=2 | **491** |
| 2 submitted：最老 present 仍持 buffer | ~700 |
| `pending_frames_=1` 被挡住 | 30（108 ms 洞） |

`next_swap_id` 停住时：最老帧 **已经 present**（`fb=1`）但 `submitted_buffers` 非空；最新帧在等 `wl_surface.frame` 且尚无 feedback。SkipWait 只看 back()，所以即使屏幕上已有帧，下一帧仍等 callback。`kPresentationFlushTimerDuration=160 ms` 只冲 OnPresentation，不 ack swap。

kickoff 100.7 Hz / max 125 / gt50=5，`video14_open=2`。不要再 NOP `0x3532314`（无 present 也 attach，§21 更差）。stock `handle_release_points`（`libmutter-18.so` `0x167d04` `tbnz w0,#31`）：`cogl_context_get_latest_sync_fd()<0` 就 return，timeline 不 signal。NOP 只会拿 fd=-1 去 import，signal 不成。`wl_buffer.release` 在 `use_count==0` 时才会发。§28 对上活 `MetaWaylandBuffer`：最老帧 **`use_count` 已经是 0**，`release_points` 还留着 → Mutter 已 dec，Chrome `kSyncobj` 不听 `wl_buffer.release`。`DAGU_CHROME_NO_SYNCOBJ` 同样有洞，是丢掉 acquire，不是「不该听 release」。

不要单独 poke `0x167d04`。SIGNALED+Transfer 三条组合已测否（§28）。

抓痕：`linux-mainline/out/display-stress/dagu-ozone-ack-holes.json`

### 28. 最老帧 `use_count` 已是 0，卡在 syncobj 不 signal（2026-09-13 21:40）

stock `libmutter-18.so`（`/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0`，50.1-0ubuntu2.2）活指令：

| 字段 / 位点 | 偏移 / VA | 核对 |
|-------------|-----------|------|
| `MetaWaylandBuffer.use_count` | +64 | `0x167e80` `ldr w0,[x0,#64]` |
| `type` | +72 | DMA_BUF=4（有 EGL_STREAM） |
| `release_points` | +152 | `GPtrArray`，`len` 在 +8 |
| `surface->buffer` / `buffer_held` | +104 / +112 | `0x18e694` `cbnz` 才 `dec` |
| `transaction.first_committed` | +440 | `fifo_barrier` +472 |
| `handle_release_points` | `0x167d04` `tbnz w0,#31` | `sync_fd<0` 直接 `ret`，**不**清 `release_points` |
| `set_sync_point` | `0xc4528` | `drmSyncobjCreate` flags 在 `0xc455c` `mov x1,#0`；import 失败 `0xc4584` `cbz` 走 error |

Chrome official-152（主进程 `WaylandFrameManager` 仍 `0x4400b59ee0`，`sync_method=kSyncobj=2`）：

- 3 submitted：`wlid` 75（已 present）/ 58 / 74（等 `wl_surface.frame`）
- 同一 `MetaWaylandBuffer` GType：`75` **`use_count=0` 且 `release_points->len=1`**；`74` 仍 `use_count=2`（当前 + scanout）
- `kSyncobj` **不** `wl_buffer_add_listener`。Mutter `dec` 到 0 时 `wl_buffer.release` 已发出，Chrome 只等 timeline。

一条三条组合 poke（gnome-shell `r-xp` 基址 `0x7f93450000`），identity 重开后再测：

1. `0xc455c` `mov x1,#0` → `#1`（`DRM_SYNCOBJ_CREATE_SIGNALED`）
2. `0xc4584` `cbz` → `b` transfer（import -1 也 transfer）
3. `0x167d04` `tbnz` → `nop`（`fd<0` 仍进 `set_sync_point`）

| 窗 | kickoff Hz | max / gt50 | 备注 |
|----|------------|------------|------|
| 基线（同 identity） | ~90–103 | 125 / 3–9 | Venus `video14_open=2` |
| 三条 poke + 重开 Chrome | **90.7** | 125 / **5** | 6 s 后 lab max 225；进程未崩 |

无效，已全部写回。`libdagu-cogl-syncfd` 假 fd 与「SIGNALED + Transfer」是同一类，在这套 msm 上 Chrome `TIMELINE_WAIT` 醒不过来。不要再 poke 这三处。`DAGU_CHROME_NO_SYNCOBJ` 更差，是因为丢掉 acquire，不是因为不该听 `wl_buffer.release`。

探针：`linux-mainline/scripts/dagu-use-count-hole.py`

抓痕：`linux-mainline/out/display-stress/dagu-syncobj-signaled-ab.json`

### 29. `kSyncobj` 也听 `wl_buffer.release` 填不满洞（2026-09-13 21:45）

official-152 活指令（主机同份 `linux-mainline/out/chromium-v4l2-src/official-152/out/dagu/chrome`）：

| ELF VA | 原 insn | 含义 |
|--------|---------|------|
| `0x350d8b4` | `0xb4000168` `cbz x8 → 0x350d8e0` | 新建 timeline 后**跳过** `wl_proxy_add_listener` |
| `0x350d8cc` | `bl wl_proxy_add_listener` | 只给 implicit / dmafence |
| `0x350d9fc` | `0x54000420` `b.eq → brk` | `OnExplicitRelease` 找不到 callback 就崩 |

板上 `/usr/lib/chromium/chromium` 先杀进程再 `pwrite`（ETXTBSY），再 `dagu-lab-identity-120.sh`。活 maps 已核对两条新 insn。Venus `video14_open=2`。

1. `0x350d9fc` → `0x54000360`（miss 当 `ret`，避免双事件崩）
2. `0x350d8b4` → `0xb40000c8`（`cbz` 改落到 `0x350d8cc` add_listener）

| 窗 | kickoff Hz | max / gt50 |
|----|------------|------------|
| 双听 + 新 Chrome | **89.8** | 133 / **6** |

进程没崩。听 release **拆不掉** identity 洞：要么 OnSubmission 不是唯一锁，要么 clock IDLE / 无新 damage 仍在。已把磁盘两条写回，identity 已用原包重开。不要再改 `0x350d8b4` / `0x350d9fc`。

抓痕：`linux-mainline/out/display-stress/dagu-syncobj-listen-ab.json`

### 30. 洞里 deadline 已停（`inside=0`），NOP `0xbc4eae0` 更差（2026-09-13 21:50）

新 GPU `194705`，`DisplayScheduler` `0x2c000ba680`。活指令仍是 stock：`ScheduleBeginFrameDeadline` ELF `0xbc4eae0` `0x36000f68` `tbz w8,#0 → 0xbc4eccc`（`inside_begin_frame_deadline_interval_` +595 为 0 就不排 deadline）。`wait_for_all` +636 仍 0。`video14_open=2`，`software_decode=false`。

8 s 直方图 ` (inside, nd, obs, pend, busy, gpu_busy_state, dl_class)`，`dl_class` 1=`deadline=0`、3=有 TimeTicks：

| 状态 | 次数 |
|------|------|
| `(0,1,1,2,1,0,1)` 不在区间、要画、pend=2、deadline=0 | **1215** |
| `(0,0,1,2,1,0,1)` | 516 |
| `(1,1,1,2,1,1,3)` 在区间且有 deadline | 502 |
| `(0,1,1,2,1,2,1)` gpu-busy 停发 BF | 218 |

`next_swap_id` 冻 ≥45 ms 的洞几乎全是 **`inside=0` 且 `deadline=0`**。原假说对上了：没有新 BeginFrame 时 8.3 ms deadline 被 `tbz` 停掉。`needs_begin_frames` 在这棵树上就是 `observing_begin_frame_source_`（+639），洞里多数仍是 1。

一条 poke（GPU `/proc/<pid>/mem`，已核对再写）：`0xbc4eae0` → `NOP`，ack/damage 在 `!inside` 时仍排 deadline。测完立刻写回 `0x36000f68`。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 93.5 | 176 / 3 | fps 86 / p50 8.3 / max 233 |
| NOP `tbz` | **69.5** | **200 / 3** | fps 66 / max 249 |

poke 后快照：`inside=1`、`deadline` 有值、`gpu_busy_state=1`，钟能排，**`pending_swaps_` 仍是 2**，没有新 `DrawAndSwap`。DidFinishFrame 在没有匹配 OnBeginFrame 时把管线打乱，kickoff 更稀。不要留。也不要再 NOP pending 上限（§24 崩 GPU）。

下一刀不要再改 `ScheduleBeginFrameDeadline` 的 `inside` 门。要对洞里 Mutter `first_committed` / `buf_sources` / `target_presentation_time_us`（用 Chrome `wlid` + 同一 GObject klass，不要扫 86 MB 假阳性）：newest 已有 `wl_surface.frame` 时合成钟为何仍 IDLE。

抓痕：

- `linux-mainline/out/display-stress/dagu-deadline-inside-ab.json`
- `linux-mainline/out/display-stress/dagu-pendcap-ab.json`
- `linux-mainline/out/display-stress/dagu-framecb-timeout-ab.json`

### 31. 洞里 `first_committed=0`，NOP `apply_state` 空 callback 仍排钟未消洞（2026-09-13 22:00）

Chrome 主进程 `WaylandFrameManager` `0x1c00b4a1a0`（submitted +40：`data/cap/begin/end`）。用 `wlid` + 同一 `MetaWaylandBuffer` klass 找表面，不要扫 86 MB。

洞里（`next_swap_id` 冻 ≥45 ms）：

- 两条 Chrome 表面 **`first_committed=0`、`fifo=0`**：transaction **没卡住**
- 偶发 `first=1` 且 `buf_sources` n=3（acquire 等就绪），不是主态
- submitted 两帧 `wl_frame_callback` +544 当时是 0（可能已经 `done` 被 reset，不代表从没 `wl_surface.frame`）
- DisplayScheduler 仍常见 `inside=0`、`pending_swaps_=2`；有一洞 **pend=0** 仍冻 108 ms（能画却等不到 BeginFrame）

`meta_wayland_actor_surface_apply_state` 活指令（`/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0`）：

| ELF VA | insn | C |
|--------|------|---|
| `0x16515c` | `cbz` | `frame_callback_list` 非空 → `schedule_update` |
| `0x165164` | `0x340001a0` `cbz` | `fifo_wait==0` → **不**排钟 |

一条 poke（gnome-shell `/proc/<pid>/mem`，`r-xp` `0x7f93450000`）：`0x165164` → `NOP`，空 callback 也 `schedule_update`。已核对、测完写回。`video14_open=2`。identity 中途会掉到 rAF p50=16.6。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 重开后基线 | 73.7 | 117 / 3 | fps 62 / p50 **16.6** |
| NOP `0x165164` | 85.6 | 133 / **4** | fps 76 / p50 8.4 |

钟能多走一点，**消不掉洞**。这和 idle 空转钟（§26）不同：只在 apply 时排。已经 apply 过的那帧补不回来。不要留。不要再 NOP `ScheduleBeginFrameDeadline` 的 `inside` 门（§30）。

抓痕：

- `linux-mainline/out/display-stress/dagu-apply-sched-ab.json`
- `linux-mainline/out/display-stress/dagu-apply-sched-ab-dirty.json`

### 32. `!will_attach` 仍建 `wl_surface.frame` 更差（2026-09-13 22:05）

`WaylandSurface::AttachBuffer` 在 `state_.buffer_id == pending` 且 buffer **未** release 时返回 false。`ApplySurfaceConfigure` 活指令：

| ELF VA | insn | C |
|--------|------|---|
| `0x3533d30` | `bl AttachBuffer` | |
| `0x3533dc0` | `0x360000d7` `tbz w23,#0` | `!will_attach` → **不** `wl_surface.frame` |

一条 poke（浏览器主进程 `/proc/<pid>/mem`）：`0x3533dc0` → `NOP`，同 buffer 未 release 也建 frame callback。已核对、测完写回。`video14_open=2`。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 88.3 | 125 / 4 | fps 89 / p50 8.4 |
| NOP `tbz` | **78.2** | **142 / 4** | fps 72 |

没有新 attach 时只多发 callback，Mutter 仍可能不 destile（Chrome 自己的注释：不 attach 新 `wl_buffer` 就收不到 frame ack）。不要留。

洞里 DelayBased **timer 一直 `active_=1`**，`+120=0`。大洞仍是 `pending=2` + `gpu_busy_state=2` + `inside=0`。不要再 NOP `SetActive` / `inside` 门 / 空 callback 排钟。

抓痕：`linux-mainline/out/display-stress/dagu-will-attach-cb-ab.json`

同函数再试一条：`AttachBuffer` `0x3545c30` `b.ne` → `b`（同 `buffer_id` 也 `will_attach=true`）。基线 90.4 Hz / gt50=4，poke 后 **84.6 / 3**。洞没满，已写回 `0x540005e1`。不要留。抓痕：`linux-mainline/out/display-stress/dagu-attach-always-ab.json`。

### 33. GPU `submitted=2` 等 OnSubmission，改 ack 顺序填不满洞（2026-09-13 22:12）

`GbmSurfacelessWayland` 活对象（vtable ELF `0xf60f838`）。`submitted_frames_` deque 在 +80。洞里（`next_swap_id` 冻、`pending_swaps_=2`）：

| GPU 队列 | 洞里主态 |
|----------|----------|
| `unsubmitted` | 1（哨兵） |
| `submitted` 等 OnSubmission | **2** |
| `pending_presentation` | 0–1 |

`DidReceiveSwapBuffersAck` 要等 GPU `OnSubmission`，而它要求 **队首 `frame_id` 对上**（`0x357411c` `b.ne` 直接 ret）。Host `MaybeProcessSubmittedFrames` 只在 **`size==1`** 时强制 ack 队首（`0x353310c` `b.ne` 跳过）。§23 NOP 空 `submitted_buffers` 会 ack **下一帧**，GPU 对不上 id 就丢掉——这解释了当时 pending 仍是 2。

两条都对上、各测一条、已写回。`video14_open=2`。

| 窗 | kickoff Hz | max / gt50 |
|----|------------|------------|
| 基线 | 87.0 | 226 / 4 |
| NOP `0x353310c`（size≠1 也强制 ack 队首） | **78.0** | 122 / 4 |
| 基线 | 96.7 | 125 / 2 |
| NOP `0x357411c`（忽略 frame_id） | 94.6 | **225 / 2** |

ack 顺序不是 kickoff 洞的充分条件。不要再 NOP 这两处，也不要再 NOP 空 buffer 等待（§23）。

抓痕：`linux-mainline/out/display-stress/dagu-onsubmission-order-ab.json`

### 34. §23 的 `0x3533294`  poke 错了 GPU；主进程 NOP 仍更差（2026-09-13 22:20）

`MaybeProcessSubmittedFrames` 只在**浏览器主进程**跑。§23 写的是 GPU pid `133908` / runtime `0x558e633294`，那份 NOP 从未进 Host。洞里主态（identity 重开后 `218673` / GPU `218724`，`WaylandFrameManager` `0x1400ae53e0`）：

| 字段 | 洞里 |
|------|------|
| `pending_frames_` | **0**（`MaybeProcessPendingFrame` 直接 ret） |
| `submitted` | 2–3 |
| 最老 | `ack=1` `fb=1` `empty=0`，`presentation_acked`(+664) 多为 **0**，偶 1 |
| 最新 | `ack=0` `cb=0/1` `fb=0` |
| GPU `pending_swaps_` | **2** |

官方包 `HandlePresentationFeedback`（ELF `0x3534c44`）已经 `bl MaybeProcessSubmittedFrames` + `bl MaybeProcessPendingFrame`（`0x3534e28` / `0x3534e30`）。present 之后会排钟，但 SkipWait 看 `back()`，且 OnSubmission 仍要上一帧 `submitted_buffers` 空。

一条 poke（**主进程** `/proc/218673/mem`，GPU 同址未动）：`0x3533294` `0x540004a1` → `NOP`。已核对、测完写回。`video14_open=2`，`software_decode=false`。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 92.6 | 242 / 5 | fps 90 / p50 8.3 / max 225 |
| 主进程 NOP `!empty` break | **76.3** | 217 / **6** | fps 65 / p50 8.5 / max 217 |

poke 后 `pending_swaps_` 出现过 0/1（2s 直方图 13/255/555），Host 三帧都 `submission_acked=1`，`pending_frames_` 变成 1–2，但 `next_swap_id` 仍冻，最新帧 `cb=1 fb=0` 卡住 PlayBack。提前 ack 让 destile 更挤，kickoff 更稀。不要留。不要再 NOP `0x3533294`（任一进程）。

抓痕：`linux-mainline/out/display-stress/dagu-host-empty-break-ab.json`

### 35. SkipWait 改看 `submitted.front()` 未消洞（2026-09-13 22:25）

`MaybeProcessPendingFrame` 算 `back()`：`0x35322c0` `ldr cap` 起做 `(begin+size-1)%cap`，`0x35322f4` 用 `x9` 取帧。一条 poke：`0x35322c0` `0xf9401a6a` → `0x1400000c` `b 0x35322f0`，`x9` 保持 `begin` = **front()**。已核对、测完写回。`video14_open=2`。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线（当时偏稀） | 79.5 | 225 / 5 | fps 84 / p50 8.3 / max 233 |
| SkipWait 看 oldest | 96.4 | 126 / **7** | fps 97 / p50 8.3 / max 117 |

Hz 回升、尖峰变短，**gt50 更差**。洞里 `pending_frames_` 仍常是 0，改 `back()` 帮不上主态。不要留。不要再 NOP `0x3532314`（§21）。

抓痕：`linux-mainline/out/display-stress/dagu-skipwait-front-ab.json`

### 36. `on_after_update` 已有 `ready_time` 就 return：改成立刻 emit 未消洞（2026-09-13 22:30）

stock `libmutter-18.so.0.0.0`（gnome-shell `128256`，`r-xp` `0x7f93450000`）`on_after_update`：

| ELF VA | insn | C |
|--------|------|---|
| `0x169664` | `bl clutter_frame_get_result` | |
| `0x169668` | `0x34000220` `cbz` | `PENDING_PRESENTED` → 立刻 emit |
| `0x169674` | `bl get_frame_deadline` | 无 deadline → emit |
| `0x169688` | `b.ge` | deadline 已过 → emit |
| `0x169698` | `0x54000161` `b.ne 0x1696c4` | `g_source_get_ready_time()!=-1` → **直接 ret，不 emit** |
| `0x1696ac` | `set_ready_time(-1)` + `bl 0x167340` | `emit_frame_callbacks_for_stage_view` |

一条 poke：`0x169698` → `0x540000a1`（`b.ne 0x1696ac`），已有 deadline 也立刻 emit。已核对、测完写回。`video14_open=2`，`software_decode=false`。`maybe_reschedule` / triple / `0x165164` 仍是 stock。基线窗 lab 一度掉到 p50=16.6。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 82.8 | 133 / 8 | fps 65 / p50 **16.6** |
| 已有 ready_time 也 emit | 82.2 | **225 / 5** | fps 69 / p50 8.4 |

kickoff 几乎不动，尖峰更大。不要留。不要再 NOP idle 空转钟（§24）或强制 triple（§26）。

抓痕：`linux-mainline/out/display-stress/dagu-after-update-ready-ab.json`

### 37. `after_update` 一律立刻 emit、不 defer GSource 未消洞（2026-09-13 22:32）

同一函数再试一条：`0x169668` `cbz` → `0x14000011` `b 0x1696ac`，无论 `result` / deadline 都立刻 `emit_frame_callbacks`。已核对、测完写回。`video14_open=2`。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 84.6 | 125 / 8 | fps 81 / p50 8.4 / max 125 |
| 一律立刻 emit | 92.6 | **225 / 7** | fps 90 / p50 8.3 / max 125 |

Hz 略升，**gt50 仍 7，max 更大**。空更新反馈环（mutter !2823）会多 destile，填不满 kickoff 洞。不要留。不要再改 `0x169668` / `0x169698`。

抓痕：`linux-mainline/out/display-stress/dagu-after-update-always-emit-ab.json`

### 38. `finish_frame` 无 `kms_update` 且 `!needs_flush` 就 IDLE：NOP 未消洞（2026-09-13 22:40）

stock `meta_onscreen_native_finish_frame`（`libmutter-18.so.0.0.0`，gnome-shell `128256`，`r-xp` `0x7f93450000`）：

| ELF VA | insn | C |
|--------|------|---|
| `0x1dcf8c` | `bl has_kms_update` | |
| `0x1dcf90` | `0x35000220` `cbnz` | 有 update → 继续 |
| `0x1dcf98` | `0x34000062` `cbz` | `!needs_flush` → **`set_result(IDLE)` ret，不 atomic** |
| `0x1dcfa0` | `cbz posted_frame` | 空才走 `meta_kms_update_new` + `post_nonprimary` |
| `0x1dcfa4` | `mov w1,#1` + `set_result` | IDLE |

一条 poke：`0x1dcf98` → `NOP`，`!needs_flush` 仍看 `posted_frame`，空则发无 damage 的 atomic。已核对、测完写回。`video14_open=2`，`software_decode=false`。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 80.7 | 125 / 8 | fps 73 / p50 8.4 / max 142 |
| NOP `!needs_flush` | 82.8 | 125 / **8** | fps 76 / p50 8.4 / max 125 |

kickoff 几乎不动。洞里钟在 IDLE（§26）时 `finish_frame` 根本不跑，空 atomic 发不出去。不要留。不要再 NOP `0x1dcf98`，也不要把 `0x1dcfa0` 改成有 `posted_frame` 仍 post（会覆盖 in-flight commit）。不要再 NOP idle 空转钟 / triple / `after_update`。

抓痕：`linux-mainline/out/display-stress/dagu-finish-flush-ab.json`

### 39. `MaxPendingSwaps` 抬到 5：GPU 进程立刻没了（2026-09-13 22:47）

活 GPU `225742`，主显示 `DisplayScheduler` `0x1c000bd780`（`next_swap_id` 4 万+）。`MaxPendingSwaps` ELF `0xbc4e384` 已对指令：

| 字段 | 偏移 | 活值 |
|------|------|------|
| `pending_swaps_` | +604 | **2** |
| `max_pending_swaps` | +608 | **2** |
| `max_pending_swaps_60/90/120hz` optional | +616/+624/+632 `has` | **全 0** |
| `use_platform_preferred_deadlines_` | +638 | **1** |

120Hz optional 为空，回落到 +608=2。`pref=1` 时若 `BeginFrameArgs` 带 `PossibleDeadlines`，还会按 OS deadline 再 `min`。返回点：

| ELF VA | stock | C |
|--------|-------|---|
| `0xbc4e4cc` | `0x2a1503e0` `mov w0,w21` | `return max` |
| `0xbc4d678` | `0x54fffeaa` `b.ge` | `pending>=max` → 不 `DrawAndSwap` |

一条 poke（GPU `/proc/225742/mem`）：`0xbc4e4cc` → `0x528000a0` `mov w0,#5`。写前 insn 已核对。`video14_open=2`，`software_decode=false`。

同进程基线（poke 前 8s）：kickoff **91.7 Hz / max 116.9 / gt50=8**，`pending` 直方图 2:532 / 1:108。poke 后 `find_gpu` 立刻失败，主进程还在、**gpu-process 没了**，`video14_open` 掉到 0。未测 poke 窗。进程内存 poke，新 GPU 起来即 stock（`0x2a1503e0` 已复核）。

这和 §24「NOP `pending>=max` 仍画」同一类：3 缓冲池 `max=GetBufferCount()-1=2`，强行 5 个 in-flight 会把 GBM/Ozone 抽空。不要留。不要再抬 `MaxPendingSwaps` 到 3/5，也不要再 NOP `0xbc4d678`。已用 `linux-mainline/scripts/dagu-lab-identity-120.sh` 重开 identity，Venus 两路拉回。

抓痕：`linux-mainline/out/display-stress/dagu-maxpend5-ab.json`

### 40. `apply_state` 空 callback 改看 `newly_attached`：未消洞（2026-09-13 22:50）

stock `libmutter-18.so.0.0.0`（gnome-shell `128256`，`r-xp` `0x7f93450000`）。`MetaWaylandSurfaceState` 已对 `set_default` / merge：

| 字段 | 偏移 | 对上的 insn |
|------|------|-------------|
| `newly_attached` | **+24** | `0x17fb74` `str wzr,[x0,#24]`；merge `0x17f75c` `ldr` / `0x17f784` `str #1` |
| `buffer` | +32 | 紧跟 `stp` |
| `frame_callback_list` | **+0x78** | `apply_state` `0x16514c` `add` |
| `fifo_wait` | +332 | `0x165160` `ldr w0,[x20,#332]` |

`0x165164` `cbz`：空 `frame_callback_list` 且该字段为 0 就不 `schedule_update`。一条 poke：`0x165160` `0xb9414e80` → `0xb9401e80`（`ldr w0,[x20,#24]`），空 callback 时看 **attach** 不看 fifo。与 §31「空 callback 也排」不同：有新 attach 才排。已核对、测完写回。`video14_open=2`，`software_decode=false`。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 81.6 | 158 / 9 | fps 85 / p50 8.3 / max 125 |
| 看 `newly_attached` | **75.9** | **242 / 8** | fps 87 / p50 8.3 / max 158 |

Hz 更低、尖峰更大。多 `schedule_update` 只会多 destile，填不满洞。不要留。不要再改 `0x165160` / `0x165164`。`linux-mainline/patches/mutter-50-pending-release-tick.patch` 的 `newly_attached` 条款不要上板。

抓痕：`linux-mainline/out/display-stress/dagu-newly-attached-ab.json`

### 41. `OnBeginFrameDeadline` 失败 Draw 改走 missed-retry：未消洞（2026-09-13 22:55）

洞里 8s 直方图（GPU `238943`，`DisplayScheduler` `0x3c000bd780`）：`+637` / `+336` **全程 0**。`AttemptDrawAndSwap` 失败后 `OnBeginFrameDeadline` ELF `0xbc4c9e4` `cbz +637` 直接 `result=4` skip，从不走 `0xbc4c9f0` 保存 `BeginFrameArgs` 再试。

一条 poke：`0xbc4c9e4` `0x34000168` → `0x14000003` `b 0xbc4c9f0`，失败也走 missed-retry。已核对、测完写回。`video14_open=2`。`0xbc4e4cc` 仍是 stock。GPU 没崩。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线（当时偏稀） | 66.7 | 233 / 8 | fps 82 / p50 8.3 / max 233 |
| missed-retry | 92.9 | **265 / 6** | fps 64 / p50 **16.6** / max 133 |

Hz 数字被偏稀基线抬高，**rAF 掉到 16.6、kickoff max 更大**。未满 120、gt50 仍 6。不要留。不要再改 `0xbc4c9e4`。

抓痕：`linux-mainline/out/display-stress/dagu-missed-retry-ab.json`

### 42. `find_candidate` 跳过 paint-box：没有直扫、kickoff 更稀（2026-09-13 22:40）

identity 上 DPU 仍只有 plane-0 mutter UBWC（`XB24` `modifier=0x0500000000000001`）。`disable-direct-scanout` **不在** gnome-shell 环境（`MUTTER_DEBUG_PAINT` 已 Unset）。`dagu-scanout@local` 关。`find_candidate`（`libmutter-18.so.0.0.0`）paint-box vs view：

| ELF VA | stock | C |
|--------|-------|---|
| `0x1e1f14` | `bl get_paint_box` | |
| `0x1e1f1c` | `0xbd402bfc` `ldr s28,[sp,#40]` | 开始四边 `G_APPROX` |
| `0x1e1f44` | 失配 | `return NULL` |
| `0x1e2050` | `blr` vtable+464 | `get_scanout_candidate` |

一条 poke：`0x1e1f1c` → `0x1400004d` `b 0x1e2050`，几何对不上也继续。已核对、测完写回。`video14_open=2`，`software_decode=false`。gnome-shell `128256`，`r-xp` `0x7f93450000`。

| 窗 | kickoff Hz | max / gt50 | lab | plane |
|----|------------|------------|-----|-------|
| 同进程基线 | 80.7 | 249 / 6 | fps 85 / p50 8.4 / max 175 | 仅 plane-0 UBWC |
| 跳过 paint-box | **72.8** | 133 / **7** | fps 111 / p50 8.3 / max 42 | **仍仅 plane-0** |

直扫没上去。后面 `get_scanout_candidate`（identity 两路 video → `n_visible!=1`）或 `try_acquire_scanout`（格式/modifier）仍否。不要留。不要再改 `0x1e1f1c`。不要为测 `n==1` 叠这条（skill 一次一条；本条已更差）。

抓痕：`linux-mainline/out/display-stress/dagu-paintbox-scanout-ab.json`

### 43. `kPresentationFlushTimerDuration` 160→8 ms：kickoff 更稀（2026-09-13 22:48）

`MaybeProcessSubmittedFrames` 把「已 present」当成 released **做不到一条 insn**：`0x353328c` `ldr x14,[x14,#520]` 已经盖掉 frame 指针，`0x3533294` `b.ne` 只看得见 begin≠end。改成看 `+656` 至少还要再读一字节，skill 不允许叠。无条件 NOP `0x3533294` 已否（§23 / §34）。`FreezeTimeout()` 在 official-152 里被 DCE，50 ms `FrameCallbackTimeout` 只置 `frame_callback_freeze_detected_`（`+300`）；`video_capture_count_==0` 时直接 `ret`，不清 `submitted_buffers`。

`UpdatePresentationFlushTimer`（ELF `0x3535034`）`Start()` 延时：

| ELF VA | stock | 含义 |
|--------|-------|------|
| `0x3535160` | `mov w2,#0x7100` | 低 16 位 28928 |
| `0x353516c` | `0x72a00042` `movk w2,#2,lsl#16` | 合成 **160000 µs** |

一条 poke（**主进程** `253395`，runtime = `0x5572f70000+(0x353516c-0x2bb0000)`）：`0x353516c` → `0x5283e802` `mov w2,#8000`（8 ms，盖掉 movk）。已核对、测完写回。`video14_open=2`，`software_decode=false`。DisplayScheduler（vtable `0xfc6f180`）`0x14000b8380`，`max608=2`。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 92.9 | 118 / 9 | fps 79 / p50 8.3 / max 108 |
| 8 ms flush | **76.5** | 123 / 8 | fps 88 / p50 8.4 / max 125 |

只冲 `OnPresentation`，不 ack swap，`pending_swaps_` 仍顶 2。提前冲 presentation 让 destile 更挤。不要留。不要再改 `0x353516c`。

抓痕：`linux-mainline/out/display-stress/dagu-flush8-ab.json`

### 44. 实 FM：已 present 仍 `mapn=1`；NOP `OnWlBufferRelease` buffer* 失配未消洞（2026-09-13 22:50）

`WaylandToplevelWindow` vtable ELF `0xf60e2d8`，活对象 `0x340067a400`，`frame_manager_` 在 **+248** → `0x3400b68a40`（chrome `253395`）。200 ms 内 `frame_id` 21065→21078，是 identity 主窗。`video_capture_count_=0`，`freeze_detected=0`，`should_skip=0`。

洞里 / 日常顶满：

| 帧 | ack | fb | pack | mapn |
|----|-----|----|------|------|
| 最老 | 1 | 1 | 0/1 | **1** |
| 最新 | 0 | 0 | 0 | 1 |

`submitted_buffers` 是 `flat_map`（16 B/条目）。最老帧已经 present，但还有 **1** 个 surface 没从 map 里抹掉 → `MaybeProcessSubmittedFrames` `0x3533294` `b.ne` break → 不给下一帧 `OnSubmission` → GPU `pending_swaps_=2`。`wl_frame_callback` 两边都是 0，不是在等 `wl_surface.frame`。

`OnWlBufferRelease`（ELF `0x3534570`）找到 surface 后还要比 `handle+24`（`buffer()`）和事件里的 `wl_buffer*`：

| ELF VA | stock | C |
|--------|-------|---|
| `0x3534680` | `cmp x10,x21` | `handle->buffer() == wl_buffer*` |
| `0x3534684` | `0x54fffbc1` `b.ne 0x35345fc` | 失配则不 erase |

一条 poke（主进程）：`0x3534684` → `NOP`。已核对、测完写回。`video14_open=2`。poke 后最老帧仍 `fb=1 mapn=1`（release 根本没来，或 surface 没进 find，不是指针对不上）。

| 窗 | kickoff Hz | max / gt50 | lab |
|----|------------|------------|-----|
| 同进程基线 | 93.0 | 134 / 7 | fps 106 / p50 8.3 |
| NOP 失配 | 95.9 | **184 / 6** | fps 104 / p50 8.3 |

Hz 持平、尖峰更大。不要留。不要再改 `0x3534684`。

下一刀不要再 NOP 空 map / release 比指针。要把「`fb=1` 当作 released」写进 `HandlePresentationFeedback`（存完 `+656` 之后、`bl MaybeProcessSubmittedFrames` 之前把 `+520=+512`），这在活指令里是 **两条**（`ldr` begin + `str` end），skill 一次一条做不到；无 `out/dagu/build.ninja` 不能增量编 Chrome。

抓痕：`linux-mainline/out/display-stress/dagu-release-cmp-ab.json`

### 45. 系统层：KMS `sync_fd` 堵住 page-flip（2026-09-14）

identity GTK 孪生页，无 Chrome。stock `libmutter-18.so.0.0.0` md5 `49a6422fcc5f11ba4894fa6dd82116b1`。gnome-shell `128256`。活 so 对指令。

`do_handle_update` `0x1bd9ac` `0x37f802b4` `tbnz w20,#31,0x1bda00`：`sync_fd<0` 才立刻 `update_ready`，否则 `register_fd` 等到 fence。洞里 `posted+next` 都非空，`complete_flip` 准时，`flipped_in_impl` 晚 70–250 ms。

一条 poke（已核对 opcode）：`0x1bd9ac` → `0x14000015` `b 0x1bda00`。写进文件 + 活进程。

| 窗 | kickoff Hz | max / gt50 | 备注 |
|----|------------|------------|------|
| poke 前 native | 103–109 | 115–220 / 5–7 | impl 晚 |
| poke 后 quiet | 106–117 | 仍有 100–220 / **1–3** | impl 已准时，`maybe_post` 晚 |
| `next==NULL` 时 `schedule_update_now` | 107–116 | 66–213 / 1–6 | 更差或持平，已撤 |

不要再 poke `0x1c4388` / `0x1c47d4`。`0x1c4474` peek NULL abort 整窗 0 次，不要改。

安装：`linux-mainline/scripts/dagu-mutter-msm-infence-install.sh apply`  
源码：`linux-mainline/patches/mutter-50-msm-no-explicit-infence.patch`  
恢复：`linux-mainline/scripts/dagu-mutter-msm-infence-install.sh restore`

### 46. Type B：impl 准时，nview 或下一记 kickoff 晚（2026-09-14）

活映射 `/proc/128256/map_files/…`（so 文件已 deleted）。identity GTK，第一刀仍在。

| 窗 | kickoff | gt50 / max | 备注 |
|----|---------|------------|------|
| 第一刀后 quiet | 106–117 | 1–3 / 100–220 | 见 §45 |
| 洞序列（map_files uprobe） | 848–876 / ~109 Hz | 4–7 / 83–233 | 见下 |
| NOP `maybe_post` 不写 IN_FENCE（`0x1c2350`/`0x1c2354`） | 98–109 | **3–10** / 183–245 | **更差，已撤** |

洞序列（相对 kickoff，ms）：

- 83.5：flip/delivered/impl +0.9，**nview +75.7**，mgo +75.8，下一 kick +83.5
- 233.1：impl +4.3，**nview +229.2**，mgo +229.3
- 111.0 / 104.5：impl+nview+mgo 都在 +2–4，**下一 kick +104–111**

`after_update` `0x169668` 仍是 stock `cbz`；delay 路径 0。不要 poke `0x169668`。不要再 NOP `0x1c2350`/`0x1c2354`。

脚本：`linux-mainline/scripts/dagu-typeb-probe.py`（必须打 `map_files`，打 so 路径会 0 命中）
`linux-mainline/scripts/dagu-mutter-no-kms-infence-install.sh` — 已验证无效，保持 restore
`linux-mainline/scripts/dagu-mutter-framecb-now-install.sh` — 未用（delay=0）

抓痕：`linux-mainline/out/display-stress/dagu-typeb-probe-mapfiles.json`

### 47. Type B 续：wakeup + 精化第一刀（2026-09-14）

活 gnome-shell 仍是 `128256`，identity GTK，`dagu_qcb`（`0x1d6e40`）在洞里相对 kickoff **+3–7 ms**，和 impl 同一毫秒。`callback_source_dispatch`（`0x1d5d00`）也常在 +3–6 ms；`nview` 仍可到 +76–241 ms。主线程 ppoll 14 个 fd（GLib 那套）。

GLib 2.88 `g_source_set_ready_time` 在 `ready_time` 已是 0 或 `G_SOURCE_BLOCKED` 时 **不 wakeup**。`meta_thread_queue_callback` 只 `set_ready_time(0)`。cave：`set_ready_time` 后再 `g_main_context_wakeup(source+128)`。

旧第一刀（`0x1bd9ac` 无条件 `b update_ready`）**跳过了** `DISABLE_IMPLICIT_SYNC`。atomic 只在该旗标下挂 **signaled dummy** `IN_FENCE_FD`，Cogl fd 从不进 atomic。跳过 DISABLE 等于把 implicit GEM 留在内核。精化：`0x1bd9ac` 回到 `tbnz`，`0x1bd9d8` `b update_ready`（仍设 DISABLE，不等 fence）。

| 窗 | kickoff Hz | gt50 / max | 备注 |
|----|------------|------------|------|
| 旧第一刀 baseline | 96.7 | 5 / 251.6 | B-main×2 + B-kick + other |
| + wakeup | 111.0 | 3 / 250.4 | B-main 少了，250 ms 还在 |
| + DISABLE-keep | 110.6 | 5 / **116.9** | 250 ms 尖峰没了 |
| deadline 强制开 | 108.7 | 5 / 164.2 | **更差，已撤** |
| 无条件 DISABLE | 107.4 | 4 / 320.5 | **更差，已撤** |
| flush pending（deadline 关） | 106.5 | 6 / 216.8 | **更差，已撤** |

验收（kickoff≈120 且 `gt50=0`）**还没到**。留下 wakeup + DISABLE-keep。

安装：

- `linux-mainline/scripts/dagu-mutter-wakeup-install.sh apply`
- `linux-mainline/scripts/dagu-mutter-msm-infence-install.sh apply`（已是精化版）
- `linux-mainline/scripts/dagu-bmain-probe.py`（必须 `map_files`）

源码：

- `linux-mainline/patches/mutter-50-queue-callback-wakeup.patch`
- `linux-mainline/patches/mutter-50-msm-no-explicit-infence.patch`

不要再开：`dagu-mutter-deadline-install.sh`、`dagu-mutter-flush-pending-install.sh`、无条件 NOP `0x1bd9ac`、`dagu-mutter-nopend-install.sh`。

抓痕：

- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-004455.json` baseline
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-004530.json` wakeup
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-004802.json` DISABLE-keep

### 48. wait_flush 已排除；nopend 已撤（2026-09-14）

活 so 反编译 `update_ready`：`0x1bd7d4` `cbnz w0, 0x1bd82c`（`CrtcFrame.pending_page_flip` @ +28）在 deadline 关时仍走 `queue_update`。`schedule_process` `0x1bce48` deadline==0 只 `g_warning_once`。假设这是 B-kick-atomic-late。

先用已有 trace 打脸「内核 50 ms wait_flush」：

| 窗 | poke | Hz / gt50 / max | 洞内 wait_flush | tail_s |
|----|------|-----------------|-----------------|--------|
| waitflush-8s | wakeup+DISABLE | 113.2 / 2 / 200.8 | 0–6 ms | （当时未采） |
| nopend-8s | + `0x1bd7d4` NOP | 112.8 / 3 / 116.4 | 0–6 ms | — |
| nopend-tail-8s | 同上 | **103.9 / 10 / 120** | 0–6 ms | 洞末 +83–120 |
| post-nopend-restore | 写回 `0x350002c0` | 111.0 / 4 / 250 | 0–6 ms | 洞末，与 atomic 对齐 |

`dpu_enc_wait_event_timeout` 整窗 0。`commit_tail_finish` 在 kickoff 后 +3–5 ms。洞是用户态晚 `drmModeAtomicCommit`，不是 worker 卡在 `wait_for_commit_done`。`STRICT_DEVMEM` 挡 `/dev/mem`。不要刷 `linux-mainline/patches/dpu-vid-commit-done-8ms.patch`。

nopend 第二窗：`atomic` +8 但 `commit_tail_start` +100（未完成 flip 叠提交）。已 `dagu-mutter-nopend-install.sh restore`。

写回后剩余洞几乎全是 **B-main**：`qcb` +2–4 ms，`nview` +65–245 ms。cave 的 `ldr x0,[x19,#128]` 对的是 `MetaThreadCallbackSource.main_context`（`callbacks` @ +136，`needs_flush` @ +144），不是 GSource.context。下一刀盯主线程为何 wakeup 之后仍晚 dispatch `notify_view_crtc_presented`。

抓痕：

- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-005904.json` waitflush
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-010108.json` nopend
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-010142.json` nopend-tail
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-010212.json` restore

### 49. 两条 page-flip 闭包（2026-09-14）

`invoke_page_flip_closure_flipped` @ `0x1b9548`：每帧两次。洞里第一条 +4–6 ms（crtc / KMS context），第二条 +58–113 ms 才到，`nview` 跟第二条。`qcb` 两次都在 +4–6。`add_page_flip_listener` 在 `NULL` 时走 `0x1bbce0` `bl g_main_context_default`。不要改成未注册的 thread-default（`queue_callback` 会 `g_return_if_fail` 丢掉闭包）。

抓痕：`linux-mainline/out/display-stress/dagu-bmain-probe-20260914-010621.json`、`...-20260914-011134.json`（重开 `dagu-lab-identity-native.sh` 后 108.4 Hz / gt50=7）。

### 50. dri_flush 无限节流（2026-09-14）

B-main 的 100 ms 空档里主线程在 `dri_flush` 对 `throttle_fence` 做 `fence_finish(-1)`，不是 GLib ppoll。活指令 `libgallium` `0x1cf740`/`0x1cf74c`。NOP `fence_finish` 后 B-main 变少，洞转成 nview 准时 / `maybe_post` 晚，或 `atomic` 准时 / `commit_tail` 晚。

- `linux-mainline/scripts/dagu-hole-syscall-sample.py`
- `linux-mainline/scripts/dagu-mesa-dri-flush-install.sh`
- `linux-mainline/patches/mesa-26-dri-flush-no-infinite-throttle.patch`
- `linux-mainline/out/display-stress/dagu-hole-syscall-20260914-011722.json`
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-012044.json` timeout=0
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-012145.json` NOP fence_finish
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-012446.json` gl-ready skip REJECTED
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-012511.json` gl-ready restore
- `linux-mainline/scripts/dagu-mutter-gl-ready-install.sh`（保持 restore，不要 apply）
- `linux-mainline/patches/mutter-50-no-wait-gl-ready.patch` REJECTED
- `linux-mainline/scripts/dagu-mutter-atomic-block-install.sh` REJECTED（`0x1b4820` NONBLOCK；两窗 gt50=0 不稳，重开实验室 max 241）
- `linux-mainline/patches/mutter-50-atomic-block.patch` REJECTED
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-012751.json` st_flush NOP
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-013400.json` atomic-block W1 117.4 / gt50=0
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-013418.json` atomic-block W2 118.5 / gt50=0
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-013429.json` atomic-block W3 113.6 / gt50=4
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-013547.json` atomic-block 重开实验室 109.5 / max 241
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-013609.json` 写回 NONBLOCK 112.4 / gt50=3
- `linux-mainline/out/display-stress/dagu-bmain-probe-20260914-014006.json` kworker FIFO15 REJECTED 105.9 / max 225

