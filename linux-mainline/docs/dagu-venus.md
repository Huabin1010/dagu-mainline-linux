# dagu Venus 硬件编解码探底

记录日期：**2026-09-12**。  
设备：小米平板 5 Pro 12.4（`dagu` / SM8250）。  
相关总表：`linux-mainline/docs/dagu-adaptation-status.md`。

图形栈 LINEAR GMEM / UBWC 已落袋（`4ebb9ee`）。本页只写 **Venus 现状**，还没开驱动。

---

## 1. 一句话

硬解 **还没通**。活内核没编 `qcom-venus`，DT `&venus` 是 `disabled`，`/dev/video*` 全是 CAMSS VFE。  
dagu 签名的固件已经从 `modem_a` 只读拷出来了。下一步是 **ICC stub + 打开驱动**，**禁止**开 `CONFIG_INTERCONNECT_QCOM_SM8250`。

Turnip / Vulkan 是 3D，**不是**视频引擎。Mesa 26.0.8 没有 Freedreno VA-API 后端，`vainfo` / `mpv --hwdec=vaapi` 这条路现在不存在。硬解应走 **V4L2 mem2mem（qcom-venus）** + GStreamer `v4l2sl*` / `v4l2codecs`，不是 rusticl。

---

## 2. 实机核对（2026-09-12）

| 项 | 结果 |
|----|------|
| `dmesg \| grep -i venus` | 空 |
| `CONFIG_VIDEO_QCOM_VENUS` | **is not set**（`linux-mainline/config/dagu-display.fragment` 盖掉了 `dagu.fragment` 的 `=y`） |
| `CONFIG_INTERCONNECT_QCOM_SM8250` | **is not set**（铁律，开了会 `rpmh_write_batch` 超时） |
| `CONFIG_INTERCONNECT` | `=y`（其它 SoC 的 ICC 仍在，就是没有 SM8250 provider） |
| DT `/soc@0/video-codec@aa00000` | `compatible = qcom,sm8250-venus`，`status = disabled`，`firmware-name = qcom/sm8250/xiaomi/dagu/venus.mbn` |
| `/dev/video0`…`video13` | 全是 `qcom-camss` 的 `msm_vfe*_video*` |
| `vainfo` / `mpv` | 未装 |
| Mesa VA `.so` | `d3d12` / `nouveau` / `r600` / `radeonsi` / `virtio_gpu`，**没有 freedreno** |
| `vulkaninfo --summary` | GPU0 `Turnip Adreno (TM) 650`，Mesa 26.0.8-1ubuntu0.3，与 DPU 无冲突 |
| GStreamer | 只有普通 `v4l2src` / `v4l2sink`，没有 `v4l2slh264dec` 一类 |

---

## 3. 固件（已落盘，未开驱动）

Android `modem_a`（`sde5`，vfat，只读挂过）里有本机签名的 MDT：

```text
/mnt/modem_a/image/venus.mdt
/mnt/modem_a/image/venus.b00 … b10、b19
```

已复制到：

- 平板 `/lib/firmware/qcom/sm8250/xiaomi/dagu/venus.mdt`（以及同目录 `.b*`，`venus.mbn` 是 `.mdt` 的副本）
- 主机 `linux-mainline/firmware/dagu/lib/firmware/qcom/sm8250/xiaomi/dagu/`
- 备份 `linux-mainline/out/gpu-checkpoint-20260912/venus/dagu-venus-full.tar.gz`

**禁止**用 `vendor/xiaomi-elish-firmware/sm8250/venus.mbn`（elish 签名，secure boot 会拒）。

---

## 4. 为什么还不能只改 DT 就开机

`linux-mainline/linux/drivers/media/platform/qcom/venus/core.c` 在 probe 里：

```c
core->video_path = devm_of_icc_get(dev, "video-mem");
core->cpucfg_path = devm_of_icc_get(dev, "cpu-cfg");
```

活内核有 `CONFIG_INTERCONNECT=y`，但 **没有** SM8250 provider。`of_icc_get` 会 `-EPROBE_DEFER`，Venus 会一直 defer，或者拖死启动（缺固件时 DTS 注释写过约 60s stall）。

铁律：**不要**开 `CONFIG_INTERCONNECT_QCOM_SM8250`。CPU 已经靠删 `interconnects` + EPSS LUT 活下来。Venus 要自己吞掉 ICC（NULL path + `icc_set_bw` 空操作），或只给 Venus 做局部 stub。

另外 `&cdsp` 也是 disabled。先只开 Venus，不要顺手开 CDSP / SLPI。

---

## 5. 下一步（还没做，不要刷）

1. 在 `venus/core.c` 把 ICC 失败当成可选（和「禁止 SM8250 ICC」一起验收）
2. `linux-mainline/config/dagu-display.fragment` 改成 `CONFIG_VIDEO_QCOM_VENUS=y`（以及需要的 `VIDEOBUF2_DMA_*`）
3. `linux-mainline/dts/sm8250-xiaomi-dagu.dts` 的 `&venus` 改 `okay`（固件名已经写对）
4. 只刷 B 槽；确认 `g_serial` `0525:a4a7` >30s
5. 出现 `/dev/video*` 且 `driver` 是 `qcom-venus` 之后，再用 GStreamer V4L2 硬解，不要先装 VA-API 幻想

验收命令（驱动起来之后）：

```bash
dmesg | grep -i venus
for n in /sys/class/video4linux/video*/name; do echo "$n=$(cat $n)"; done
gst-inspect-1.0 | grep -i v4l2sl
```

---

## 6. 和 Turnip 的边界

| 组件 | 做什么 |
|------|--------|
| Turnip / `freedreno_icd.json` | Vulkan 3D，已经通 |
| dagu-mesa Freedreno GL | Chrome LINEAR GMEM，已经通 |
| Venus / `qcom-venus` | H.264 / HEVC / VP9 编解码，**未开** |

不要把 `vulkaninfo` 看成硬解证据。
