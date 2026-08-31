#!/usr/bin/env bash
# Copy overlay drivers into the kernel tree and register Kconfig/Makefile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

[[ -d "$KERNEL_SRC" ]] || { echo "run setup-kernel.sh" >&2; exit 1; }

install_src() {
	local rel=$1
	local src="$ROOT/overlays/linux/$rel"
	local dst="$KERNEL_SRC/$rel"
	[[ -f "$src" ]] || { echo "missing overlay $src" >&2; exit 1; }
	mkdir -p "$(dirname "$dst")"
	cp -f "$src" "$dst"
}

install_src drivers/gpu/drm/panel/panel-xiaomi-dagu-l81a.c
install_src drivers/input/touchscreen/himax-dagu.c
install_src drivers/usb/misc/ps5169-dagu.c
install_src drivers/input/keyboard/nanosic-dagu.c
install_src drivers/power/supply/bq2597x-dagu.c
install_src drivers/power/supply/p9418-dagu.c
install_src drivers/watchdog/qcom-wdt-early-dagu.c

append_once() {
	local file=$1
	local needle=$2
	local line=$3
	grep -q "$needle" "$file" || echo "$line" >>"$file"
}

append_once "$KERNEL_SRC/drivers/gpu/drm/panel/Makefile" \
	'DRM_PANEL_XIAOMI_DAGU_L81A' \
	'obj-$(CONFIG_DRM_PANEL_XIAOMI_DAGU_L81A) += panel-xiaomi-dagu-l81a.o'

append_once "$KERNEL_SRC/drivers/input/touchscreen/Makefile" \
	'himax-dagu.o' \
	'obj-$(CONFIG_TOUCHSCREEN_HIMAX_DAGU) += himax-dagu.o'

append_once "$KERNEL_SRC/drivers/usb/misc/Makefile" \
	'ps5169-dagu.o' \
	'obj-$(CONFIG_USB_PS5169_DAGU) += ps5169-dagu.o'

append_once "$KERNEL_SRC/drivers/input/keyboard/Makefile" \
	'nanosic-dagu.o' \
	'obj-$(CONFIG_KEYBOARD_NANOSIC_DAGU) += nanosic-dagu.o'

append_once "$KERNEL_SRC/drivers/power/supply/Makefile" \
	'bq2597x-dagu.o' \
	'obj-$(CONFIG_CHARGER_BQ2597X_DAGU) += bq2597x-dagu.o'

append_once "$KERNEL_SRC/drivers/power/supply/Makefile" \
	'p9418-dagu.o' \
	'obj-$(CONFIG_CHARGER_P9418_DAGU) += p9418-dagu.o'

append_once "$KERNEL_SRC/drivers/watchdog/Makefile" \
	'qcom-wdt-early-dagu.o' \
	'obj-$(CONFIG_QCOM_WDT) += qcom-wdt-early-dagu.o'

python3 - "$KERNEL_SRC" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def insert_kconfig(path, needle, block):
    text = path.read_text()
    if block.splitlines()[0] in text:
        return
    if needle not in text:
        raise SystemExit(f"needle {needle!r} missing in {path}")
    path.write_text(text.replace(needle, block + needle, 1))

insert_kconfig(
    root / "drivers/gpu/drm/panel/Kconfig",
    "config DRM_PANEL_NOVATEK_NT36523",
    """config DRM_PANEL_XIAOMI_DAGU_L81A
	tristate "Xiaomi Pad 5 Pro 12.4 L81A dual-DPHY panel"
	depends on OF
	depends on DRM_MIPI_DSI
	depends on BACKLIGHT_CLASS_DEVICE
	help
	  Himax HX83121A dual-DSI DPHY panel used on Xiaomi dagu.
	  Do not enable the elish NT36523 CPHY driver on this device.

""",
)

insert_kconfig(
    root / "drivers/input/touchscreen/Kconfig",
    "config TOUCHSCREEN_HIMAX_HX83112B",
    """config TOUCHSCREEN_HIMAX_DAGU
	tristate "Himax HX83121 SPI touchscreen (Xiaomi dagu)"
	depends on SPI
	help
	  SPI touchscreen on Xiaomi Pad 5 Pro 12.4. Pins: IRQ GPIO39, RST GPIO100.

""",
)

insert_kconfig(
    root / "drivers/usb/misc/Kconfig",
    "config USB_HSIC_USB3503",
    """config USB_PS5169_DAGU
	tristate "Parade PS5169 USB/DP redriver (Xiaomi dagu)"
	depends on I2C
	select REGMAP_I2C
	help
	  USB3/DisplayPort redriver on Xiaomi Pad 5 Pro 12.4 (I2C 0x28).

""",
)

insert_kconfig(
    root / "drivers/input/keyboard/Kconfig",
    "config KEYBOARD_GPIO",
    """config KEYBOARD_NANOSIC_DAGU
	tristate "Nanosic 803 keyboard MCU (Xiaomi dagu)"
	depends on I2C
	help
	  Magnetic keyboard MCU on Xiaomi Pad 5 Pro 12.4. QUP SE2 I2C @0x4c.

""",
)

insert_kconfig(
    root / "drivers/power/supply/Kconfig",
    "config BATTERY_BQ27XXX",
    """config CHARGER_BQ2597X_DAGU
	tristate "TI BQ25970 charge pump (Xiaomi dagu)"
	depends on I2C
	select REGMAP_I2C
	help
	  Dual BQ25970 / SC8551 switched-cap pumps for 67W PPS on dagu.

config CHARGER_P9418_DAGU
	tristate "IDT P9418 wireless charger (Xiaomi dagu)"
	depends on I2C
	select REGMAP_I2C
	help
	  P9418 wireless charger on Xiaomi Pad 5 Pro 12.4.

""",
)

# Do not poke KPSS WDT from primary_entry: MMU is off and that
# physical store SErrors on this ABL map. Pet from early_initcall instead.
PY

echo "==> overlays installed"
