## 一刀下去的位置：把「事件从 Mutter 内部到 Chrome 内部」这条链在**同一只钟**上打成一条时间线
当前所有探针都是**单点读数**：Mutter 字段值是一张、Chrome 字段值是另一张、ftrace 又是第三张，彼此**没有统一时间戳**。这就是为什么 §7.1 / §7.2 / §7.4 那三个矛盾始终钉不死——每条链路都单独量过，但**没有任何一次观测同时看到「Mutter 发 → wire 到 → Chrome 收 → 事件循环 dispatch → map 擦除 → syncobj timeline signal → Chrome TIMELINE_WAIT 醒」**这条链在洞里的实际经过时刻。
**下一步唯一要做的事，是搭一个 cross‑process 单钟时间戳探针，把洞里 50–250 ms 这段时间内，`wl_buffer.release` 与 syncobj timeline signal 事件的整条生命周期钉在同一条时间轴上。** 一次观测，一次性裁决 §7.1 的三种读法哪一种成立。
### 观察点（按传播阶段分组，不需要改任何指令）
| 阶段 | 观察点 | 钩法 | 判定字段 |
|------|--------|------|----------|
| **A. Mutter 内部** | `meta_wayland_buffer_dec_use_count` → `wl_buffer_send_release` 触发时刻 | `ftrace uprobe` on `libmutter-18.so` 相对偏移（`use_count` 路径入口） | 调用时间、`wlid` |
| **B. libwayland‑server flush** | `wl_client_flush` / `wl_event_source` socket 写出时刻 | `ftrace uprobe` on `libwayland‑server.so` 中的 `wl_client_flush` | 事件是否真正写出，还是在 server 内 buf 里等 |
| **C. wire 到达 Chrome** | Chrome 主进程 wayland fd 的 `read()` / `epoll_wait` 唤醒时刻 | `ftrace raw_syscalls/sys_enter_read` 过滤 wayland fd，或 `uprobe` on `libwayland‑client.so` `wl_display_dispatch` | 数据是否已到用户态 |
| **D. Chrome 事件循环 dispatch** | `wl_display_dispatch_queue` / `wl_display_dispatch_pending` 被调时刻 | `uprobe` on `wl_display_dispatch*` 在 Chrome 主进程 | 事件是否从队列被取出 |
| **E. OnWlBufferRelease 路径** | `OnWlBufferRelease` / `MaybeProcessSubmittedFrames` 入口时刻 | 你已有 `0x3534684` / `0x35330a4` 偏移，直接 uprobe | release 是否被 dispatch 到对应 listener |
| **F. syncobj timeline signal** | `drm_syncobj_timeline_signal` ioctl 是否被 Mutter 发出 | `ftrace sys_ioctl` + filter `DRM_IOCTL_SYNCOBJ_TIMELINE_SIGNAL`，或 `uprobe` on `cogl_context_get_latest_sync_fd` | signal 是否真的从用户态打到内核 |
| **G. Chrome TIMELINE_WAIT 醒来** | `DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT` 完成时刻（Chrome 主进程） | `ftrace sys_ioctl` exit 时刻 | wait 是不是被 F 解除 |
**把 A–G 用 `CLOCK_MONOTONIC` 统一打戳，塞进 `/tmp/dagu-hole-chain.json`，与 `dpu_enc_kickoff` 洞的起始/结束对齐。**
### 按你已有的互锁，这张链会裁决掉三个矛盾
- **§7.1「release 已发出 vs mapn=1」**：如果 **A→B** 间隔 <1 ms 但 **C 始终不来**，则是 libwayland‑server flush 没跑（Mutter 合成钟 IDLE ⇒ 没有下一帧 ⇒ 没有天然 flush 点）。
- **§7.4「kSyncobj 等 timeline vs 关 syncobj 同样有洞」**：如果 **F 始终缺失**但 **E 在跑**，说明 `wl_buffer.release` 到了但 Mutter 根本没 signal timeline point——kSyncobj 等**永远不会被解的锁**；关 syncobj 走 implicit 路径时 map 也不会清，所以两条路都卡住，但根因同一处（timeline signal 没发）。
- **§7.5「8.3 ms 停钟 vs 强行排 deadline 更差」**：如果 **D 不来**（事件循环没 dispatch），则 `pending_swaps_=2` 不是「画不出」而是「下一帧 OnSubmission 永远等不到上一帧 erase」，这是你 §6.6 链条第 2–4 步的同一处咬死。
### 为什么「单点读字段」已经到极限
你已经反复证明：**单独 poke 每一个指令都不会同时满足「事件到/没到」和「map 擦/没擦」**。原因是：
- Chrome 内部字段值（`mapn=1`、`pending_swaps_=2`）**不带时间**——它告诉你洞里值是多少，但不告诉你这个值是「刚刚变成这样的」「还是已经这样卡了 150 ms」。
- Mutter 字段（`use_count=0`、`release_points=1`）同样不带时间——`dec_use_count` 可能发生在洞开始前一帧，也可能在洞中间。
- ftrace 事件有内核时间，但用户态的事件分发没有——所以「server 已写 socket」和「client 已 dispatch」中间那一段是**你所有单点读数都看不见的盲区**。
只有把这条链放进同一只钟，你才能回答一个此前没有任何一次观测能回答的问题：
> **洞里这段时间，事件究竟是「没产生」「没写出」「没到」「没 dispatch」「dispatch 了但没擦」「擦了但 signal 没来」，还是「signal 来了但 Chrome 没醒」？**
### 具体落法（最省事路径）
- 用 `ftrace function_graph + uprobe` 组合，或 `bpftrace`（如果板子 root 已开 BPF）：
  - 内核侧：`tracepoint:syscalls:sys_enter_ioctl` / `sys_exit_ioctl`，filter `SYNCOBJ_TIMELINE_SIGNAL` / `SYNCOBJ_TIMELINE_WAIT`。
  - 用户态侧：`uprobe:/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0:...`（你已有 ELF 偏移，`uprobe` 直接吃 offset）。
  - Chrome 主进程 `uprobe:/usr/lib/chromium/chromium:0x35330a4`（`MaybeProcessSubmittedFrames` 入口）＋ `/lib/aarch64-linux-gnu/libwayland-client.so.0:...`（`wl_display_dispatch` 入口）。
- 把 trace 输出重定向到一个 ring buffer，事件全部带 `CLOCK_MONOTONIC`（`perf` / `ftrace` 天然带）。
- 跑 10 s，事后用 `dpu_enc_kickoff` 洞的起止时刻去**切**同一段 trace，看洞里这条链卡在哪一步。
这张链一旦跑通，§7.1 / §7.2 / §7.4 的三种读法**会被一次性钉死**，你的下一条指令对照（无论 poke 哪里）就有了明确因果，而不是又一条「之后 kickoff 仍 ~90 Hz, gt50 仍在」的孤立数据点。
### 为什么不再加一条单点读字段
你已经证明过至少三次（§28 SIGNALED、§29 listener、§45 present‑as‑released）：**每一张新字段快照都只验证一个端点，不验证传播过程**。问题是传播链，不是端点值。这张 cross‑process trace 是把「链条」本身变成可观测对象，而不是继续在端点上做 A/B。
