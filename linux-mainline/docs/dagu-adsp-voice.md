# dagu ADSP 语音正路（Fluence / VA / A2DP）

记录日期：**2026-09-17**。  
喇叭播放仍是 Q6 + CS35L41 Halo，本文件只补 **语音 DSP** 和 **蓝牙音频拓扑**。

相关：`dagu-adsp-voice-pipeline-status.md`（图）、`dagu-adaptation-status.md`、`dagu-arm-linux-eval.md`、`dagu-audio-s2idle.md`。

## 硬件正路

```text
免提会议：
  喇叭 MM1 → TERT_TDM_RX_0 → CS35L41 Halo
  麦 AMIC5 → WCD9385 ADC4 INP5 → TX_CODEC_DMA_TX_3 → ADM Fluence SM ECNS（`0x10F71`）
             （AEC（Acoustic Echo Cancellation，声学回声消除）/ NS（Noise Suppression，噪声抑制））
  echo 参考：OPEN_V8 ep2 = TERT_TDM_RX_0（`#383` 1ch S16 @ 48 k；喇叭 TDM 实测 2ch S24）

关键词唤醒前端：
  VA（Voice Activation，语音激活）macro → VA_CODEC_DMA_TX_0 → MM3
  检测本身仍在 ADSP 固件；禁止 CPU KWS（Keyword Spotting，关键词唤醒）

A2DP（Advanced Audio Distribution Profile，蓝牙立体声）：
  MM4 → AFE SLIMBUS_7_RX 0x400e → ADSP → QCA6390 IPC
  不是 uart6 HCI 上的 SBC 软编
```

本 SKU **没有** 3.5 mm，也没有 WSA 耳机 ANC（Active Noise Cancellation，主动降噪）回路。麦克风侧噪声抑制就是 Fluence NS，不要再做一条假的头戴 ANC。

## 内核

- `linux-mainline/scripts/dagu-overlay-adsp-voice.py`（`apply-overlays.sh` 调用）
- mixer：`Fluence AEC NS` = Off / AEC_NS；`TX_CODEC_DMA_TX_3` 走 ADM `OPEN_V8`（`0x0001036A`）
- 板上实测拓扑 **`0x00010F71` SM ECNS**（`0x10F89` V2 OPEN 被 ADSP `EFAILED`）
- echo 参考：`endpoint_id_2 = TERT_TDM_RX_0`（`0x9020`）。`#383` ep2 **1ch / 16 bit / 48 k**（SM 远近端）。喇叭 TDM 实测 **2ch S24**，GROUP 报 4ch——这就是 PCM 卡死的主嫌疑。
- A2DP：虚拟口 `SLIMBUS_7_RX` / `SLIMBUS_7_TX`（id 138/139，偶/奇对齐 CAF slim 通道图）
- DT：`mm3` / `mm4` + `slim7-dai-link` + `linux,spdif-dit` dummy

`#389` 遥测：`open_v8 topo=0x10f71 ep1=0xb037 1ch/16/48000 ep2=0x9020 2ch/24/48000` · `effect=skip copp=9`。回声已对齐正在跑的 TDM 2ch S24；SET_PP 已跳过；仍 **pcm_read I/O error**。VA `hw:0,2` 有字节。A2DP `AFE 0x400e` 已打到 ADSP。图：`dagu-adsp-voice-pipeline-status.md`。

## 用户态

| PCM | 用途 |
|-----|------|
| `hw:0,0` MM1 | 喇叭（已通） |
| `hw:0,1` MM2 | Fluence 麦 |
| `hw:0,2` MM3 | VA 前端 |
| `hw:0,3` MM4 | A2DP offload |

脚本：

- `dagu-mic-route.sh` — 开 Fluence
- `dagu-va-route.sh` — VA mixer
- `dagu-bt-a2dp-route.sh` — SLIMBUS_7 ← MM4
- `dagu-adsp-voice-test.sh` — 板上验收
- `alsa/50-dagu-bt-offload.conf` — 禁止 PipeWire SBC 软编当产品路径

## 验收

```bash
linux-mainline/scripts/dagu-adsp-voice-test.sh   # 板上
# dmesg | grep 'dagu fluence'
# Fluence capture hw:0,1 有字节；VA hw:0,2 有字节；SLIMBUS_7 mixer 存在
```

A2DP 听感还要一副已配对耳机：电台在 uart6，PCM 走 Q6。没有耳机时只验 AFE 拓扑能开。
