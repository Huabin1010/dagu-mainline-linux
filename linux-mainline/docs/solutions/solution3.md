# 一个方向：给「release timeline 点值」做一次对账

你现在所有的快照（use_count=0、mapn=1、fb=1、TIMELINE_WAIT 不醒）都是**状态**，缺一条**事件序**。而 §28 那个关键实验——SIGNALED + Transfer + NOP `0x167d04` 三条一起 poke，Chrome 的 `TIMELINE_WAIT` 居然还是不醒——指向一个你还没排除的可能：

**Mutter signal 的 timeline 点值 ≠ Chrome 等的点值。**（off-by-one 或 committed-point 记账滞后。）如果是这样，那么 §29 听 release、§28 假 signal 全部注定无效——不是「事件没到」，是「信号对了、号码错了，等的人永远等不到自己的号」。这能一次性解释 §7.1 和 §7.4 两条裂缝。

## 具体做法（一刀，只测这一件事）

交叉编一个带日志的 `libmutter-18.so`（你已有交叉编 50.1 的流水线），只在 `meta-wayland-buffer.c` 加打印，不改逻辑：

1. `dec_use_count` 到 0 时：打印 `wl_buffer` 协议 id、`release_points->len` 和**数组里每个点值**、`cogl_context_get_latest_sync_fd()` 的返回值。
2. syncobj commit 路径（surface 提交时 Mutter 记录 acquire/release point 的地方）：打印每个 commit 的 release point 值。
3. 信号路径真正调用 `drmSyncobjTimelineSignal`（或等效）处：打印 **syncobj handle + point 值**。

同时板上用现有 `dagu-hole-peek-46.py` 扩一项：从 Chrome 侧读出最老帧 `WaylandFrame` 等的那个 syncobj timeline 的 **handle + point 值**（`WaylandSyncobjReleaseTimeline` 对象里有，vtable 重扫就能拿到）。

## 判定标准（8 s 窗，一次洞就够）

| 结果 | 结论 |
|------|------|
| Mutter signal 点值 = Chrome 等待点值，且信号确实发出 | 锁不在 release 链，回头查 `TIMELINE_WAIT` 的等待线程本身（这是目前唯一没被排除的分支） |
| Mutter signal 点值 = Chrome 等待点值，但**信号从未发出**（卡在 sync_fd<0 分支） | 坐实 direct-scanout 缓冲没有 GL fence、release point 无人 signal——修 Mutter：scanout 缓冲的 release point 绑到 CRTC out-fence / vblank 完成，而不是 cogl 的 latest sync fd |
| 点值差 1 或错位 | 找到根因：两边 committed point 记账不同步，修记账 |

## 为什么是这个方向而不是别的

- §6.6 那条链的第 4–6 环（release/syncobj）你全是**间接推断**，从没同时拿到过「发的号」和「等的号」两个数字。
- 所有失败的 poke（§29、§28、§44）有一个共同特征：都在**信号传输**上动手。如果根本是**号码对不上**，这些实验的结果（洞还在）完全可预测，也给不出任何新信息——你已经浪费了三刀在同一条假设上。
- Mutter 你能增量编，Chrome 不能。这一刀完全打在能编的那一侧，且 30 行日志以内，一晚上能出结论。
- 如果这一刀排除点值错位，剩下的候选空间收敛到只剩一个（Chrome 等待线程），那时再动 Chrome 侧不迟。

**一句话：别再 poke 信号通不通了，先证明「Mutter 喊的号」和「Chrome 等的号」是同一个号。**