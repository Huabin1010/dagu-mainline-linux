# Type B：identity 下 DPU kickoff 周期性空洞

日期：2026-09-14。板子：Xiaomi Pad 5 Pro 12.4（dagu / SM8250 / L81A）。

这不是 Chrome `wl_buffer.release` 那条线（见 `linux-mainline/docs/solutions/solution1.md`）。  
这是 **GTK identity 实验室**里，合成器与客户端互相等对方先动。

流水账在 `linux-mainline/docs/dagu-identity-kickoff-hole-problem.md`。本文只说明问题本身。

---

## 现象

面板 **1600×2560@120**，vblank 稳在 ~120 Hz。屏不黑、不复位，硬件继续扫上一张。

DPU `dpu_enc_kickoff` 却不能稳满 120：大约每 1–2 秒出现一次 **75–220 ms** 空洞。用户看见动画抽一下。

| 项 | 现状 |
|----|------|
| vblank | ~120 Hz，洞里也在扫 |
| kickoff | stock 约 **115 Hz**，`gaps_gt_50ms` **2–4** / 8s |
| 验收 | 同一 8s 窗 **kickoff≈120 且 `gaps_gt_50ms=0`** — **未达到** |

实验室：

```text
python3 linux-mainline/scripts/dagu-native-lab.py --host --measure
```

板上：`GSK_RENDERER=gl`，`linux-mainline/scripts/dagu-lab-identity-native.sh`。Mutter transform 0、scale 1.0。不要开 scanout 泵，不要软解，不要锁频。

---

## 机制（一句话）

**这一帧的 `wl_callback.done` 在 atomic 之后、flip 之前就付清了；flip 到了合成钟进 IDLE；GTK 冻着等下一记 done。双方都认为该对方先动，直到约 100 ms 后才有人醒。**

```
T0−6   mutter after_update：PENDING 立刻 send_done，列表清空，GSource 拆掉
       GTK thaw，画 N+1，再 freeze，等 C_{N+1}
T0     dpu_enc_kickoff（这一帧准时）
T0+1   flip 回执；pending_reschedule=0 → 钟 IDLE
       此后 ~100 ms：没有 after_update，没有下一记 done
T0+109 GTK 才又 thaw / 下一记 kickoff
```

这是 Wayland 合法用法：GTK 等 `frame` 再画；合成器必须让这类客户端跟刷新率。KWin / Firefox / Mutter 都踩过「付完 callback 就停环」。120 Hz 上漏一次握手就是 **~100 ms（12 帧）**；60 Hz 上同一漏只是 16 ms。

mutter 50.1（含 upstream main）仍在 `PENDING_PRESENTED` 立刻 emit，然后 `g_source_set_ready_time(-1)`。源码：`linux-mainline/out/mutter-50.1/src/wayland/meta-wayland.c` 的 `on_after_update()`。

---

## 不是什么

| 已排除 | 依据 |
|--------|------|
| 内核 CTL `wait_flush` 卡 50–100 ms | kprobe `dpu_encoder_wait_for_commit_done` 最长 **8.2 ms** |
| DSC 每帧 rebind | #175 `linux-mainline/patches/dpu-skip-redundant-dsc-prep.patch` |
| Venus / 软解 | 本实验室无 Chrome、无 `/dev/video14` |
| 日常 270° destile | identity 是 transform 0 |
| vblank 停了 | 洞里 vblank 仍 120 |

不要再：GDK 解冻、空 list emit、IDLE 泵、`wakeup(NULL)`、`schedule_update_now(next==NULL)`、推迟 PENDING emit、GSource 里无条件 `schedule_update`。

---

## 已试 mutter 变体（板上已回 stock）

交叉编 `linux-mainline/scripts/dagu-mutter-cross.sh`，部署 `linux-mainline/scripts/dagu-mutter-deploy.sh`。

| | kickoff | gt50 | 备注 |
|--|---------|------|------|
| stock | ~115 | 2–4 | PENDING 立刻 emit |
| v1–v3 推迟 emit | 102 / 104 / **55** | 已否。Weston 不是 defer done |
| v4–v5 GSource | 107–109 | 4–5 | 未过 |
| **v6** keep-alive 12 拍 | **103.73** | 4 | GTK **120–132 Hz、p99 17 ms**（客户端解开了）；过发 done，kickoff 更差 |
| v7 GSource + schedule_update | **91.62** | 2 | destile，已 restore |

**2026-09-14 13:40** restore：

`/var/backups/dagu-mutter/libmutter-18.so.0.0.0.stock-50.1-0ubuntu2.2`  
→ `/usr/lib/aarch64-linux-gnu/libmutter-18.so.0.0.0`

USB 须保持 `0525:a4a7`。活树 `linux-mainline/out/mutter-50.1/` 里的 v7 **不要再部署**。

---

## 还卡在哪

v6 证明：GTK 的 100 ms 冻可以用「付完 done 不要拆 GSource」解开。

剩下的 100 ms 是 **GTK 已经在画，mutter 却不 `dpu_enc_kickoff`**（vblank 仍 120）。过发 callback 会让 GTK 快过 KMS，kickoff 更稀。

下一刀只查：thaw 之后那一记 commit 有没有变成 atomic。不要再改 `on_after_update` 的 emit 时机。

---

## 相关文件

- 专文：`linux-mainline/docs/dagu-identity-kickoff-hole-problem.md`（§109–§110）
- 尝试表：`linux-mainline/out/display-stress/dagu-typeb-mutter-fix-debug-20260914.md`
- 上游对照：`linux-mainline/out/display-stress/dagu-typeb-fix-upstream-20260914.md`
- 安卓管线对照：`linux-mainline/docs/dagu-typeb-android-pipeline.md`（活机 `<android-serial>`，只读）
- 安卓原始落盘：`linux-mainline/out/android-extract/display-pipeline/`
- 验收：`linux-mainline/scripts/dagu-native-lab.py`
- 合钟抓痕：`linux-mainline/scripts/dagu-interlock.bt`
