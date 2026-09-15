# dagu Chrome 滚动掉帧（普通页）

探针：`linux-mainline/scripts/dagu-scroll-jank.py`  
页：`linux-mainline/scripts/dagu-scroll-jank.html`  
数据：`linux-mainline/out/display-stress/scroll-jank.json`、`linux-mainline/out/display-stress/scroll-jank-idle.json`

不改 CPU/GPU 栅格。本地页只有色块文字，无图片、无站点 JS。

## 对照（Himax `--axis x --hold 6`，DPR 1.25）

| 指标 | 空闲只刷 HUD | 按住来回拖 |
|------|----------------|------------|
| rAF 中位 | 8.3 ms（120 Hz） | 8.3 ms |
| rAF p99 | **8.5 ms** | **16.7 ms** |
| rAF 最长 | 125 ms | **200 ms** |
| rAF >14 ms | 0.6% | **3.0%** |
| `BeginImplFrame` | — | 8.3 ms，97.8% 落在 8 ms 档，120.7 Hz |
| `Display::DrawAndSwap` | — | 中位 8.4 ms，**4.5% >14 ms**，最长 63 ms |
| GPU busy 平均 / 峰 | 0.6% / 28 | 9.6% / 50 |
| DPU `vblank fps` | 120 | 119–120 |

## 根因（按住向上滑：手走了，画面偶发没跟上）

单向按住滑（页在中间，`start_y=10929`，`doc_h=22963`）：

| 环节 | 结果 |
|------|------|
| Himax 注入 | 575 点，中位 8.6 ms，最长 13.7 ms，**没有 >20 ms 缺口** |
| Chrome 收到触摸 | `OnTouchEvent` 578，与注入 1:1 |
| 合成器跟手计算 | `ScrollUpdate` 445，`DidOverscroll` 0（这次不是橡皮筋） |
| 真正上屏 | `DrawAndSwap` 449 = `WaitForSwap` 449（**每一帧都在等 Mutter 换缓冲**） |
| 上屏迟到 | 4.5% 的呈现 >14 ms，最长 **51 ms** |
| 页面 `scrollY` | 中段有一次 **125 ms 完全不动**；开头还有 758 ms 在等点按聚焦/锁滚动（注入脚本先 tap） |
| Chrome 自己 | `ScrollJankV4` 886 次，自带掉帧计数在响 |

对应你的体感：

1. **刚开始很跟手**：合成器已经在 impl 线程按手指算位移，触摸没有丢。
2. **偶尔手上去了屏幕没跟上**：位移已经算完，但这一帧卡在 `WaitForSwap`。Mutter 仍是 `disable-direct-scanout`，必须把整窗 LINEAR 转 270° 再写进 UBWC。它晚到的那几十到两百毫秒，你看见的还是上一帧的滚动位置，手指已经走了。
3. **不是** 触控丢事件，**不是** 锁 60 Hz，**不是** 还在走 CPU 栅格。

静置仍抽帧的锁频对照（GPU 无 `performance` governor、地板已是 587 MHz、dmesg 有 `vblank timeout: 400000`）见 `linux-mainline/docs/dagu-idle-pipeline.md`。

下一步只能缩短「算完 → 出现在屏上」：损伤矩形 / 降低 Mutter 整窗旋转成本。不要开关 GPU raster。不要 `governor=performance`。  
**不要**默认开 DPU 直扫或 `WaylandOverlayDelegation`（LINEAR Chrome + overlay 花屏）。  
GNOME Shell 50.1 已广告 `wp_linux_drm_syncobj_manager_v1`；Chrome `dagu-chromium.sh` 已 ENABLE `WaylandLinuxDrmSyncobj`。`WaitForSwap` 不是「缺 explicit sync 协议」。

首页慢滑的 80–180 ms 洞是 **Chrome `WaitForSwap` vs Mutter frame clock 休眠** 互锁，不是 destile 算力。三条路 A/B：`linux-mainline/docs/dagu-idle-pipeline.md` §8。`--max-pending-swaps` 不存在；不要 `--double-buffer-compositing`；不要开 `WaylandExternalBeginFrameSource`。  
Mutter `orientation=normal` 基线（§9，`jank-capture-20260913-080558`）慢滑仍 4 个洞、max 125 ms，没有第二块 DPU plane。单靠去掉 270° 拆不掉协议互锁。
