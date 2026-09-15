# Type B：安卓显示管线对照（dagu `<android-serial>`）

日期：2026-09-14。活机：同型号 Pad 5 Pro 12.4，`adb` 序列号 **`<android-serial>`**，HyperOS `OS2.0.10.0.ULZCNXM`，Magisk `su`。**只读提取，未刷机。**  
`miui_refresh_rate` 采样后已恢复为 **60**。

问题本身仍是 `linux-mainline/docs/dagu-typeb-kickoff-hole.md`：identity 下 `dpu_enc_kickoff` 每 1–2 秒出现 75–220 ms 空洞，vblank 仍约 120 Hz。  
本文只把**原厂安卓此刻的显示管线参数**落到盘上，用来对照「原厂怎样让合成钟别在 120 Hz 上睡死」，**不是**把 Android 属性抄进 Linux 当交付。

原始落盘：`linux-mainline/out/android-extract/display-pipeline/`。  
复跑：`linux-mainline/scripts/dagu-android-display-pipeline.sh`（默认 serial=`<android-serial>`）。

---

## 对 Type B 有用的结论（先看这个）

Video 模式两边一样：**硬件扫屏（vblank）和软件 kickoff 不是同一只钟**。安卓空闲 `sde-crtc-0/measured_fps≈1.4`，滑动瞬间约 **55**；强制 120 Hz 后 `hw_vsync_info` 仍是 **120.1–120.24 Hz / 8.33 ms**。Linux 实验室也是 vblank 满、kickoff 稀。所以 Type B **不是**「安卓每帧都在踢、Linux 硬件踢不动」。

安卓填满 120 Hz 动画靠的是 **SurfaceFlinger 自己的 VsyncDispatch**，不是客户端 frame callback：

| 安卓（活机） | Linux Type B（mutter 50.1 stock） |
|--------------|-----------------------------------|
| `TimerDispatch` 按预测 VSYNC 一直排 `sf` 回调；多数 app 连接是 `VSyncRequest::None` | `on_after_update` 在 PENDING 立刻 `send_done`，列表空了就拆 GSource |
| 合成钟与客户端 vsync **分开** | GTK 的 `wl_callback.done` 和合成钟绑在一起 |
| `KernelIdleTimer=false`，用户态 `IdleTimer=1100 ms` 才考虑降到 60 | flip 后 `pending_reschedule=0` → 钟 **IDLE**，约 100 ms 没人醒 |
| 120 Hz：SF phase **−4.0 ms**（提前踢），`advancedSfOffsetPercentage=48` | 没有这套 phase offset；callback 在 flip **之前**就付清 |
| 三缓冲 + `latch_unsignaled=1` + `disable_backpressure=1` | GTK 等下一记 done 才 thaw；漏一次就是 12 帧 |

v6 keep-alive 12 拍之所以 kickoff 更差：那是**过发 done 给 GTK**，客户端快过 KMS。安卓的做法是 **只保活合成器自己的 `sf` 回调**，不给没订阅的客户端发 vsync。对照 Type B 下一刀（thaw 之后那记 commit 有没有变成 atomic），不要再改 `on_after_update` 的 emit 时机。

---

## 1. 面板 / DSI（活 DT + sysfs）

节点：`qcom,mdss_dsi_l81a_42_04_0a_dual_dphy_video`。  
sysfs：`1600x2560x120x281000vid` / `1600x2560x60x281000vid`，`panel_mode=dsi_video`。

CAF 时序是**单路 800**（双 DSI 拼成 1600）。Linux `panel-xiaomi-dagu-l81a.c` 已把 H porch ×2，和这份 DT 对齐。

| 项 | 安卓 DT（单路） | Linux DRM mode（整幅） |
|----|-----------------|------------------------|
| 分辨率 | 800 × 2560 | 1600 × 2560 |
| fps | 120；DFPS 列表 120 / 60 | 120（preferred） |
| HFP / HSW / HBP | 60 / 40 / 60 | 120 / 80 / 120 |
| VFP / VSW / VBP | 160 / 4 / 18 | 同 |
| DSC | 1.1，slice 800×20，1 pkt，8bpc/8bpp | 同 |
| topology | `<2 2 2>` 双路 | bonded-DSI + 双 DSC |
| traffic | `non_burst_sync_event` | video |
| mdp-trigger | `none` | KMS atomic kickoff |
| dma-trigger | `trigger_sw` | — |
| DFPS | `dfps_immediate_porch_mode_vfp` | 主线常驻 120，不走这套 VFP 切 60 |
| phy-timings | `00 1c 08 07 17 16 07 07 08 02 04 00 19 0c` | overlay 已抄 CAF |
| `adjust-timer-wakeup-ms` | 1 | 无对等 SF 属性 |

`qcom,sde-has-idle-pc` 在安卓 DT 上是空属性（布尔真）。主线 SM8250 catalog 同样 `has_idle_pc=true`，`IDLE_TIMEOUT=58 ms`。Type B 已排除这条（洞里 `ENTER_IDLE=0`，vblank 仍 120）。

---

## 2. SurfaceFlinger / HWC（120 Hz 当场 `dumpsys`）

文件：`linux-mainline/out/android-extract/display-pipeline/sample/sf-scheduler-120.txt`。

```text
NUM_FRAMEBUFFER_SURFACE_BUFFERS=3
PRESENT_TIME_OFFSET=0
PresentFences=true
KernelIdleTimer=false
ContentDetection=false
touchTimer=3000 ms          # dumpsys；prop 里 ro.surface_flinger.set_touch_timer_ms=200
VSYNC period=8333333 ns
app phase=+1000000 ns
SF  phase=-3999999 ns
app duration=11666667 ns    # 1.40× 周期（三缓冲）
SF  duration=12333332 ns    # 1.48× 周期
present offset=0
hwVsyncState=Disabled       # SF 用 VsyncReactor 预测，不靠内核 hw vsync 排钟
mMinVsyncDistance=3.00 ms
mTimerSlack=0.50 ms
```

`VsyncDispatch` 在 120 Hz 当场仍在排：

- `sf`：`workDuration=12.33 ms`，`readyDuration=0`，deadline 在下一记 vsync 附近  
- `app`：`workDuration=11.67 ms`，`readyDuration=12.33 ms`  
- 多数 Connection 是 `VSyncRequest::None` —— **没订阅的客户端不会被每帧叫醒**

属性（活 `getprop`）：

| 属性 | 值 | 含义 |
|------|----|------|
| `debug.sf.set_idle_timer_ms` | **1100** | 无内容 1.1 s 才考虑降刷新 |
| `debug.sf.enable_advanced_sf_phase_offset` | 1 | 走 `advanced_sf_offsets.xml` |
| `debug.sf.high_fps_late_sf_phase_offset_ns` | **−4000000** | 120 Hz SF 提前 4 ms |
| `debug.sf.high_fps_early_phase_offset_ns` | −4000000 | 同上 |
| `debug.sf.high_fps_late_app_phase_offset_ns` | +1000000 | app 相位 +1 ms |
| `debug.sf.latch_unsignaled` | 1 | 未 signal 的 fence 也 latch |
| `debug.sf.disable_backpressure` | 1 | 合成落后不堵客户端 |
| `debug.sf.enable_gl_backpressure` | 1 | 只对 GL 合成开反压 |
| `vendor.display.disable_dynamic_sf_idle` | 1 | HWC 不动态闲置 SF |
| `vendor.display.disable_idle_time_video` | 1 | 视频层不加 idle 降频 |
| `vendor.display.disable_idle_time_hdr` | 1 | HDR 同上 |
| `vendor.display.enable_posted_start_dyn` | 1 | posted start：vsync 前开始取像素 |
| `vendor.display.enable_optimize_refresh` | 1 | 内容不变可少踢（video 模式旧帧继续扫） |
| `vendor.display.enable_async_powermode` | 1 | 异步电源模式 |
| `vendor.display.enable_allow_idle_fallback` | 1 | 允许 idle fallback |
| `ro.surface_flinger.max_frame_buffer_acquired_buffers` | 3 | 三缓冲 |
| `ro.vendor.display.default_fps` | 60 | 空闲地板 |
| `persist.vendor.display.miui.composer_boost` | **4-7** | composer / SF 钉大核 |
| `service.sf.present_timestamp` | 1 | present timestamp |

`/vendor/etc/display/advanced_sf_offsets.xml`：120 Hz `advancedSfOffsetPercentage=**48**` → 0.48 × 8.33 ms ≈ **4.0 ms**，和 `SF phase=-4 ms` 对上。

---

## 3. 线程 / IRQ（活 `/proc`）

| 进程 | CPU | 备注 |
|------|-----|------|
| `surfaceflinger` 主线程、`RenderEngine` | **4–7** | `composer_boost` |
| SF `TimerDispatch` / `app` / `appSf` / `TouchTimer` | **0–3** | 合成钟在小核 |
| SF `IdleTimer` | 0–7 | 1100 ms 那只用户态钟 |
| `vendor.qti.hardware.display.composer-service`、`SDM_EventThread` | **4–7** | HWC |
| `disp_rsc` IRQ | 几乎全在 CPU0/1 | 对齐 DT `qcom,sde-qos-cpu-mask=<0x03>`，latency **300 µs** |
| `dsi_ctrl` IRQ | CPU0–3 | 从 `sde` domain |

Linux Type B 不必先抄这份 affinity；它解释不了「GTK 已 thaw、mutter 不 atomic」。调度只是背景。

---

## 4. SDE QoS / 时钟（安卓 DT vs 主线 catalog）

`linux-mainline/linux/drivers/gpu/drm/msm/disp/dpu1/catalog/dpu_6_0_sm8250.h` 的 `sm8250_perf_data` **已经和安卓 DT 一致**：

| 项 | 安卓 DT | 主线 SM8250 catalog |
|----|---------|---------------------|
| max_bw_low / high | 13.7 / 16.6 GB/s | 同 |
| min_core_ib | 4.8 GB/s | 同 |
| min_dram_ib | 0.8 GB/s | 同 |
| qos-lut-macrotile | `0x0011223344556677` | `sc7180_qos_macrotile` 同 |
| core_clk | 300 MHz，max 460 MHz | RPMH / opp，不是这份 DT cell |
| UBWC | version `0x400`，bank bit 3 | catalog 另有 UBWC 字段 |

唯一明显 LUT 差：安卓 `qcom,sde-danger-lut = <0xff 0xffff 0 0 0xffff>`，主线 `{0xf, 0xffff, 0x0}`。这是 underflow/QoS 水位，**不是** Type B 的 100 ms 合成洞（洞里屏继续扫上一张，没有 DSC `400000` timeout）。

`qcom,sde-uidle-off = 0x80000`（SDE uidle 块）主线这条路径基本不用。

---

## 5. 120 Hz 滑动采样（仪器，不是验收）

强制 `miui_refresh_rate=120` 后 `input swipe`（不是 GTK 120 fps 动画）。已 restore。

| 项 | 值 |
|----|----|
| `hw_vsync_info` | 120.1 → 120.24 Hz，周期 8.33 ms，`dsi_video` |
| `dynamic_fps` | 120 |
| 滑动瞬间 `measured_fps` | **55.5**（1 s 窗 56 次 kickoff） |
| 松手后 `measured_fps` | 1.4 |
| `panel_kickoff` 跨整段 host 51 s | +211（含空闲轮询，平均 Hz 无意义） |

`sde-crtc-0/vsync_event` **不阻塞**，板上 900 次 `cat` 会严重欠采样，**不要**拿 poll.txt 的 `gt50` 当安卓也有 Type B 洞。有效证据是 `hw_vsync` 稳 120 + `measured_fps` 随内容在 1.4～55 之间变。

---

## 6. 不要用这份对照去做的事

- 不要把 `debug.sf.*` 写进 Linux cmdline 当 mutter 开关。  
- 不要再推迟 / 过发 `wl_callback.done`（v1–v7 已否，板上已回 stock）。  
- 不要用安卓的 1100 ms idle 去改 DPU `IDLE_TIMEOUT`：Type B 洞里内核 RC 仍是 ON。  
- 不要把 danger LUT 差异当成这一刀的根因。

还卡住的那一刀仍是：GTK thaw 之后那记 commit 有没有变成 KMS atomic。安卓说明合成器必须有**独立于客户端 callback 的排程**（SF 的 `sf` VsyncDispatch），而不是把「付完 done」当成这一帧的终点。

---

## 相关文件

- 问题：`linux-mainline/docs/dagu-typeb-kickoff-hole.md`
- 原始 dump：`linux-mainline/out/android-extract/display-pipeline/`
- 抽取脚本：`linux-mainline/scripts/dagu-android-display-pipeline.sh`
- 板上脚本：`linux-mainline/scripts/dagu-android-display-pipeline-ondevice.sh`
- 120 Hz 采样：`linux-mainline/scripts/dagu-android-display-pipeline-sample.py`
- 活 DT 摘录：`dumps/dagu-20260826-210700-root/dt/fdt.dts`（mdp @21928，L81A @30251）
