# official-152：破 Chrome WaitForSwap ↔ Mutter frame clock

落地在活树：

- `linux-mainline/out/chromium-v4l2-src/official-152/ui/ozone/platform/wayland/host/wayland_frame_manager.cc`
- `linux-mainline/out/chromium-v4l2-src/official-152/ui/ozone/platform/wayland/host/wayland_output.cc`
- `linux-mainline/out/chromium-v4l2-src/official-152/ui/ozone/platform/wayland/host/wayland_screen.cc`
- `linux-mainline/out/chromium-v4l2-src/official-152/ui/views/widget/desktop_aura/desktop_window_tree_host_linux.cc`
- `linux-mainline/out/chromium-v4l2-src/official-152/cc/trees/proxy_impl.cc`

## Ozone（板上包）

`OnMode` 原先丢掉 `wl_output.refresh`（mHz）。现写入 Display `display_frequency`，并在 `DesktopWindowTreeHostLinux` 里 `SetDisplayVSyncParameters`。`wp_presentation.refresh==0` 或 &gt;9 ms、以及 60 Hz 形的 `display_frequency`，都按 120 Hz 填 interval。`BeginFrameArgs::DefaultInterval()` 从 60 Hz 改成 **120 Hz**，viz 合成钟不再在缺 refresh 时落到 16.7 ms。

`DAGU_CHROME_PANEL_ROTATE=270`：aura `SetRootTransform` 把横屏 UI GPU 旋进物理 1600×2560 buffer。Linux GLES 忽略 `SetDisplayTransformHint`（`kLogic`）。必须配合 Mutter transform 0，见 `linux-mainline/scripts/dagu-lab-identity-120.sh`。

Linux 无多刷新率硬件路径时，viz 会 `use_preferred_interval_=true`，60 fps 片的 `SetPreferredFrameInterval(16.7ms)` 把合成钟钉死。dagu 关掉这个，BeginFrame 跟面板 120 Hz。`linux-mainline/out/chromium-v4l2-src/official-152/components/viz/service/frame_sinks/root_compositor_frame_sink_impl.cc`。

`kSyncobj` 也 `wl_buffer_add_listener`（ELF `0x350d8b4`）identity 实机 **89.8 Hz / gt50=6**，已写回。见 `linux-mainline/docs/dagu-idle-pipeline.md` §29。不要再试。

`MaybeProcessPendingFrame()` 原先在上一帧 `wl_frame_callback` 未 ack 时直接 `return`（TRACE `WaitForFrameCallback`）。

现：上一帧 `wp_presentation` 已有 `feedback`（`SkipWaitAfterPresented`）则丢掉旧 pending、只播最新一帧。`HandlePresentationFeedback` 末尾再调 `MaybeProcessPendingFrame()`。

**不要** 16/24 ms 令牌 / `SkipWaitStuck`。presentation 不来时那就是节拍器 destile 风暴（095822：4.1 Hz）。

## cc

`ProxyImpl::RenewTreePriority`：精确滚动时 `SMOOTHNESS_TAKES_PRIORITY`。

## Mutter 日常（比 Ozone 更关键）

270° + 1.25 + `scale-monitor-framebuffer` 把最大化 Chrome 的 `unobscured_region` 算空 → damage 丢掉 → 不 destile、不发 callback/presentation → Ozone 空等。

日常：`gsettings` `experimental-features=@as []`，**必须 SIGQUIT gnome-shell（或重登）** 才生效。DisplayConfig 仍 1.25 / transform 3。

扩展 `linux-mainline/scripts/dagu-scanout@local/extension.js`：`disable_unredirect` + 焦点窗 `queue_redraw`。不要 1×1，不要 `libdagu*`。

## 编 / 换包

```text
ninja -C linux-mainline/out/chromium-v4l2-src/official-152/out/dagu chrome
# 只覆盖 /usr/lib/chromium/chromium，不要用 deploy.sh 覆盖 dagu-chromium 包装
```

验收：`dagu-dpu-jank-capture.py` 的 `phase_kickoff.slow.gaps_gt_50ms == 0`。页：`http://127.0.0.1:8770/dagu-pipeline-tab.html`。
