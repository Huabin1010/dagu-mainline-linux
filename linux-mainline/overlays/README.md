# overlays

板级驱动，不进 torvalds 树。`scripts/apply-overlays.sh` 在编译前拷进 `linux/`。

| 文件 | 作用 |
|------|------|
| `drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c` | L81A dual-DPHY，120Hz+DSC，双 KTZ8866 `backlight-aux` |
| `drivers/input/touchscreen/himax-dagu.c` | HX83121 SPI；完整 CAF hxchipset 在 vendor，不入库 |
| `drivers/usb/misc/ps5169-dagu.c` | PS5169 USB3/DP redriver，CAF 初始化序列 |
| `drivers/input/keyboard/nanosic-dagu.c` | 磁吸键盘 MCU，QUP SE2 I2C（不要开 uart2） |
| `drivers/power/supply/bq2597x-dagu.c` | 双 BQ25970 充电泵，PPS 策略不抄 CAF usbpd-pm |
| `drivers/power/supply/p9418-dagu.c` | P9418 无线充探测 |

CAF 参考：`vendor/android-dagu/src/HuaJI66_kernel/`

传感器走 SLPI：`stage-firmware.sh` 找到 `slpi.mbn` 后再把 `&slpi` 设为 okay。不要在 AP I2C 上猜总线。

相机：`s5kjn1` / `ov02b1b` / `imx596`。主线无这三颗驱动；DTS 已开 CAMSS/CCI，出图要另写 sensor overlay + libcamera。
