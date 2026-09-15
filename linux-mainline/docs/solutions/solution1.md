一针见血的方向：**停止继续在 DPU / 合成钟 / BeginFrame / pending_swaps 上扩线，改做一次“`wl_buffer.release` 端到端对账”。**

当前所有事实都收束到同一个未闭合点：

> Mutter 侧最老张已经 `use_count=0`，按源码已经该发 `wl_buffer.release`；  
> Chrome 主进程 `WaylandFrameManager` 里最老帧却仍然 `submitted_buffers mapn=1`；  
> 因为 map 不空，`MaybeProcessSubmittedFrames` 不给下一帧 `OnSubmission`；  
> GPU `pending_swaps_` 就顶在 2；  
> 没有新 GPU 帧 → 没有新 KMS commit → 没有 `dpu_enc_kickoff`。

所以下一步只盯一件事：

**同一个 `wl_buffer` 协议 id（例如 60/58/57，不是 Chrome handle.id），从 Mutter 发出 release，到 Chrome 主进程擦掉 `submitted_buffers`，中间到底断在哪。**

具体做法：

1. 在 identity 实验室同一个 8 s 窗里，同时抓：
   - Mutter：`wl_buffer_send_release` 是否发出，协议 id、时间；
   - Chrome 主进程：`WAYLAND_DEBUG=1` 或 uprobe 打点，是否收到 `wl_buffer@xx.release`；
   - Chrome 主进程：`WaylandFrameManager::OnWlBufferRelease` 是否进入，入参 `wl_buffer*`，map 查找是否命中，`submitted_buffers` mapn 是否从 1 变 0；
   - GPU 进程：`DidReceiveSwapBuffersAck` / `OnSubmission` / `pending_swaps_` 是否随之下调；
   - DPU：同一窗 `dpu_enc_kickoff` 洞。

2. 只看洞前 0–250 ms，按协议 id 对齐。判定只有四类：

| 观察 | 结论方向 |
|---|---|
| Mutter 发了，Chrome 主进程没收到 `release` | 断在 Wayland 事件投递 / kSyncobj 监听路径 |
| Chrome 收到，但 `submitted_buffers mapn` 不降 | 断在 `OnWlBufferRelease` 匹配或 erase 条件 |
| mapn 降了，但 `OnSubmission` 仍不发生 | 断在 `MaybeProcessSubmittedFrames` 的其他门，或 Host→GPU ack |
| mapn 降后立刻又升回 1 | 断在提交节奏 / 三缓冲池 / `max_pending_swaps=2` 的再咬合 |

这一步做完，当前 §7.1 的矛盾就会被钉死：  
**到底是 release 没到 Chrome，还是到了 Chrome 但 Chrome 没擦 map，还是擦完立刻被回填。**

在没拿到这条同时间轴之前，继续看 vblank、合成钟 IDLE、`pending_swaps_=2`、`inside_begin_frame_deadline_interval_=0` 都只是伴随现象。  
一针见血就是：**用协议 wlid 做端到端 release 对账，先判“事件到没到、map 擦没擦”，其他分支自动归位。**