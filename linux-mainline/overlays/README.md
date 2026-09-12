# overlays

板级驱动，不进 torvalds 树。`scripts/apply-overlays.sh` 在编译前拷进 `linux/`。

| 文件 | 作用 |
|------|------|
| `drivers/gpu/drm/msm/msm_gpu_resources_sysfs.c` | 在 DPU `card0/device` 上暴露 `gpu_busy_percent` / VRAM / hwmon，给 GNOME Resources 读 Adreno |
| `drivers/input/touchscreen/himax-dagu.c` | HX83121 SPI；完整 CAF hxchipset 在 vendor，不入库 |
| `drivers/usb/misc/ps5169-dagu.c` | PS5169 USB3/DP redriver，CAF 初始化序列 |
| `drivers/input/keyboard/nanosic-dagu.c` | 磁吸键盘 MCU，QUP SE2 I2C（不要开 uart2） |
| `drivers/power/supply/bq2597x-dagu.c` | 双 BQ25970 充电泵，PPS 策略不抄 CAF usbpd-pm |
| `drivers/power/supply/pm8150b-charger-dagu.c` | PM8150B SMB5 5 V/9 V 充电；不抄 CAF qpnp-smb5，不写 Type-C |
| `drivers/power/supply/p9418-dagu.c` | P9418 无线充探测 |
| `drivers/power/supply/xiaomi-dual-fg.c` | 双 BQ27Z561 合成 `bms`（CAF 加权 SoC） |

CAF 参考：`vendor/android-dagu/src/HuaJI66_kernel/`

相机：后摄 `s5kjn1` 用主线 `drivers/media/i2c/s5kjn1.c`（overlay 改成 19.2 MHz / 4080×3060 GBRG，PLL 倍额按 24→19.2）；前摄 `imx596` 用 overlay `linux-mainline/overlays/linux/drivers/media/i2c/imx596-dagu.c`（2592×1952 BGGR，`enable_streams`）。CAMSS CSIPHY 接 `vreg_l5a_0p88` / `vreg_l9a_1p2`。后摄抓帧走 `/dev/video0` fourcc `pGAA`，前摄 `/dev/video3` `pBAA`。传感器走 SLPI：`stage-firmware.sh` 找到 `slpi.mbn` 后再把 `&slpi` 设为 okay。不要在 AP I2C 上猜总线。
