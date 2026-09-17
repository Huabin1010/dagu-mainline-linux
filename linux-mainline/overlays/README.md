# overlays

板级驱动，不进 torvalds 树。`scripts/apply-overlays.sh` 在编译前拷进 `linux/`。

| 文件 | 作用 |
|------|------|
| `drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c` | L81A dual-DPHY，120Hz+DSC，双 KTZ8866 `backlight-aux` |
| `drivers/gpu/drm/msm/msm_gpu_resources_sysfs.c` | 在 DPU `card0/device` 上暴露 `gpu_busy_percent` / VRAM / hwmon，给 GNOME Resources 读 Adreno |
| `drivers/input/touchscreen/himax-dagu.c` | HX83121 SPI；完整 CAF hxchipset 在 vendor，不入库 |
| `drivers/usb/misc/ps5169-dagu.c` | PS5169 USB3/DP redriver，CAF 初始化序列 |
| `drivers/input/keyboard/nanosic-dagu.c` | 磁吸键盘 MCU，QUP0 SE2 GENI I2C gpio115/116（uart2 保持关） |
| `drivers/power/supply/bq2597x-dagu.c` | 双 BQ25970 充电泵，GENI I2C SE15/SE16（PPS 策略不抄 CAF usbpd-pm） |
| `drivers/power/supply/pm8150b-charger-dagu.c` | PM8150B SMB5 5 V/9 V 充电；不抄 CAF qpnp-smb5，不写 Type-C |
| `drivers/power/supply/p9418-dagu.c` | P9418 Smart Pen 侧吸 TX（不是平板 Qi） |
| `drivers/power/supply/xiaomi-dual-fg.c` | 双 BQ27Z561 合成 `bms`（CAF 加权 SoC） |

CAF 参考：`vendor/android-dagu/src/HuaJI66_kernel/`

相机：后摄 `s5kjn1` 用主线 `drivers/media/i2c/s5kjn1.c` + overlay `s5kjn1-dagu-regs.h`（CamX 4080×3060 作物 + 安卓预览 4-lane D-PHY `0x0114=0x0300`，live CSIPHY `0x0800=0x02`）。STREAMON 先写 0x4000 传感器/PLL，MCU page `0x2400` 按 10/20/50/100 ms 扫描，NACK 不判失败。前摄 `imx596` 用 overlay `imx596-dagu.c`（CamX init + 2592×1952 4-lane D-PHY，group hold 后再写 `0x0114=3`）。CAMSS CSIPHY 接 `vreg_l5a_0p88` / `vreg_l9a_1p2`。后摄 `/dev/video0` `pGAA`，前摄 `/dev/video3` `pBAA`。App 层：`CONFIG_UDMABUF` + libcamera SoftISP NV12（Viewfinder Bayer skip：后置 /4 → 1020×764 对齐安卓 IFE 1920×1080，前置 /2 → 1296×976；禁止开机双路 12MP demosaic）。PipeWire **禁止** `monitor.libcamera`；`v4l2loopback` `/dev/video20/21` 按需给 Snapshot/Chromium。传感器走 SLPI：本机签名 `slpi.mbn` + `dagu-ssc` SEE 客户端。CDSP 走本机 `cdsp.mbn` + FastRPC。不要在 AP I2C 上猜 IMU/ALS，不要开 WebNN。
