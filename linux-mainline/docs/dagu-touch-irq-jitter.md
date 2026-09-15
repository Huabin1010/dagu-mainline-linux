# dagu 触控微跳帧：IRQ 延迟 / SYN 抖动

**2026-09-13 停抓。** 手指离开后 CSS/视频/惯性仍抽帧，输入子系统不是这条线的主因。  
IRQ 193 绑 CPU4、`HIMAX_IRQ_DRAIN=8` 只报最后一帧：留作备忘，不再抓 8.3 ms SYN_REPORT。  
后端输出见 `linux-mainline/docs/dagu-idle-pipeline.md`。

对照体感（旧）：**不断触，滑动中途偶尔卡一帧**。  
探针：`linux-mainline/scripts/dagu-touch-syn-probe.py`（板上 `/usr/local/sbin/dagu-touch-syn-probe.py`）。  
快照：`linux-mainline/out/display-stress/touch-syn-baseline.json`、`linux-mainline/out/display-stress/touch-syn-bound.json`。

不要用 `linux-mainline/scripts/dagu-himax-swipe.py` 测这一项：那是往 `/dev/input/event3` **写入**合成 MT-B，不是 IC 的脉搏。  
`linux-mainline/docs/dagu-scroll-jank.md` 的「Himax 注入没有 >20 ms 缺口」只说明合成器侧跟得上注入点，**不能**排除硬件 SYN 断层。

## 节点（已实机确认）

| 项 | 值 |
|----|----|
| 输入 | `/dev/input/event3` `Himax HX83121` |
| 总线 | **spi-gpio** `spi20.0`（gpio8–11），**不是 I2C** |
| GPIO | TLMM 39 Level Low |
| Linux IRQ | **193**（`msmgpio 39 Level himax-dagu`） |
| GICv3 39 | `arm-smmu-context-fault`，不要当成触摸 |

板上没有 `evtest`，用探针读 evdev 时间戳。

## 1. SYN_REPORT 间隔 — 还缺一次真滑动

空闲 2 s 里 IRQ 193 停在 **3253**，没有手指就没有坐标。  
120 Hz 验收：间隔应稳在 **8.3 ms**；夹 **16 / 24 ms** 才是底层漏报。

平板上按住匀速滑 10–20 s：

```bash
python3 /usr/local/sbin/dagu-touch-syn-probe.py --wait 20 --json
```

主机：

```bash
python3 linux-mainline/scripts/dagu-touch-syn-probe.py --host --wait 20
```

结果写 `linux-mainline/out/display-stress/touch-syn.json`。看 `buckets` 里 `16` / `24` / `>40` 的个数。

## 2. IRQ 亲和 — 已从 CPU0 挪到 CPU4

绑之前（`touch-syn-baseline.json`）：

- `smp_affinity=ff`（允许 0–7）
- `effective_affinity_list=0`，计数 **3253 / 0 / 0 / 0 / 0 / 0 / 0 / 0**
- 触摸硬中断 **100% 打在 CPU0**（LITTLE，`policy0` 最低 300 MHz）

同核还堆着显示通路：`msm`（mdss）、`gpu-irq`、`venus`、`ufshcd`。滑动时 DPU/GPU/触摸抢同一颗效率核，比「小核打盹」更贴。

`irqbalance` 未开。`dagu-touch-boost.service` 在按住时抬 `policy0` 地板到 1248 MHz，**不改 IRQ 亲和**。

2026-09-13 已写入：

```text
echo f0 > /proc/irq/<himax>/smp_affinity
```

绑之后：`smp_affinity=f0`（CPU 4–7），`effective_affinity_list=4`（实际落在 **CPU4** Gold）。重启由 `dagu-himax-irq-affinity.service` 写回，不要靠手敲。

验收（滑的时候看，只有 CPU4 列涨）：

```bash
grep himax /proc/interrupts
```

恢复全核：

```bash
echo ff > /proc/irq/193/smp_affinity
# 或
python3 /usr/local/sbin/dagu-touch-syn-probe.py --bind-all --wait 1
```

## 3. 总线 Runtime PM — I2C 那条对不上

Himax 不在 `/sys/bus/i2c/devices/`。  
`spi20.0` 与 `/sys/devices/platform/spi` 的 `power/control=auto`，但 `runtime_status=unsupported`，`runtime_suspended_time=0`。  
**禁止**对所有 `i2c-*` 写 `power/control=on`：那是功放/传感器，不是触摸，也不是一线。

## 驱动一线嫌疑（比绑大核更贴 SYN 断层）

`linux-mainline/overlays/linux/drivers/input/touchscreen/himax-dagu.c`（活树副本 `linux-mainline/linux/drivers/input/touchscreen/himax-dagu.c`）：

- `IRQF_ONESHOT` 线程 IRQ：bitbang 期间线被 mask。DT 已是 `IRQ_TYPE_LEVEL_LOW`（`linux-mainline/dts/sm8250-xiaomi-dagu.dts`），线仍低会重进，避免当年 EDGE 断触。
- `HIMAX_IRQ_DRAIN=8`：线仍低就连续 `spi_sync` 最多 8 帧，**只 `himax_report` 最后一帧合法包**。spi-gpio @ 4 MHz、每帧 59 字节，若一拍里叠上两帧 IC 采样，evdev 只出一次 SYN → **16 ms 缺口**，坐标还跳一格。这是为挡 OSK 连打（0xff / n=0 毛刺）留下的。

有 16 ms 桶之后，再改成「每个 checksum 合法帧都 report」，不要先改采样率或退回软路径。

## 和滚动掉帧的分工

| 现象 | 更像 |
|------|------|
| SYN 8.3 ms 稳定，画面仍偶停 | Mutter `WaitForSwap` destile（`linux-mainline/docs/dagu-scroll-jank.md`） |
| SYN 夹 16/24 ms | IC 没报，或 `himax_irq` 排空只留最后一帧 |
| 绑 CPU4 后 IRQ 仍在 CPU0 | 亲和没生效 |
| 绑 CPU4 后 SYN 仍断层 | 不是小核唤醒，查 drain/ONESHOT |
