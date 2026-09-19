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
install_src drivers/video/backlight/ktz8866.c
install_src drivers/input/touchscreen/himax-dagu.c
install_src drivers/usb/misc/ps5169-dagu.c
install_src drivers/input/keyboard/nanosic-dagu.c
install_src drivers/input/keyboard/nanosic-kbd-ghost.h
grep -q '#include "nanosic-kbd-ghost.h"' \
	"$KERNEL_SRC/drivers/input/keyboard/nanosic-dagu.c" || {
	echo "nanosic: leftover vs KEY_UP must share nanosic-kbd-ghost.h" >&2
	exit 1
}
grep -q 'nanosic_ghost_empty_ctx' \
	"$KERNEL_SRC/drivers/input/keyboard/nanosic-dagu.c" || {
	echo "nanosic: driver must call nanosic_ghost_empty_ctx" >&2
	exit 1
}
install_src drivers/power/supply/bq2597x-dagu.c
install_src drivers/power/supply/pm8150b-charger-dagu.c
install_src drivers/power/supply/p9418-dagu.c
install_src drivers/power/supply/xiaomi-dual-fg.c
install_src drivers/watchdog/qcom-wdt-early-dagu.c
install_src drivers/gpu/drm/msm/msm_fbdev.c
install_src drivers/gpu/drm/msm/msm_gpu_resources_sysfs.c
install_src drivers/media/i2c/imx596-dagu.c
install_src drivers/media/i2c/s5kjn1-dagu-regs.h
install_src drivers/media/platform/qcom/camss/camss-vfe-480.c
install_src drivers/media/platform/qcom/camss/camss-video.c
install_src drivers/media/v4l2loopback-dagu/v4l2loopback.c
grep -q 'xcast / webrtc v4l2.c memset' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: xcast memory=0 must be treated as MMAP" >&2
	exit 1
}
grep -q 'found.size fps field' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: ENUM_FRAMEINTERVALS must stay Discrete 30" >&2
	exit 1
}
grep -q 'requestbuffers; memory=0 is MMAP' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: REQBUFS memory=0 must be treated as MMAP" >&2
	exit 1
}
grep -q 'xcast yuyv=1 needs YUYV fourcc' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: fourcc must stay YUYV so xcast yuyv=1 / first.draw" >&2
	exit 1
}
grep -q 'wraps the mmap as format 0x15012' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: YUYV wrap is xcast 0x15012; mmap must not be W*H*4" >&2
	exit 1
}
grep -q '20:15 SIGSEGV, src pointer ASCII' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: W*H*4 mmap is the 20:15 is_bokeh convert crash" >&2
	exit 1
}
grep -q '19:53 SIGSEGV when length was packed' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: QUERYBUF.length must cover convert UV on mmap" >&2
	exit 1
}
grep -q 'SoftISP write() while xcast has mmap' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: REQBUFS must not rebuild a mapped capture queue" >&2
	exit 1
}
grep -q 'O_NONBLOCK used to return EAGAIN without' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: O_NONBLOCK DQBUF must sustain last frame" >&2
	exit 1
}
grep -q 'DAGU_XCAST_MMAP_SLOTS' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: capture DQBUF index must stay in xcast mmap slots 0..3" >&2
	exit 1
}
grep -q 'Stamp / SoftISP OUTPUT STREAMOFF while xcast still' \
	"$KERNEL_SRC/drivers/media/v4l2loopback-dagu/v4l2loopback.c" || {
	echo "v4l2loopback: OUTPUT STREAMOFF must not tear a mapped capture queue" >&2
	exit 1
}
install_src drivers/media/v4l2loopback-dagu/v4l2loopback.h
install_src drivers/media/v4l2loopback-dagu/v4l2loopback_formats.h
install_src drivers/media/v4l2loopback-dagu/Makefile
install_src drivers/media/v4l2loopback-dagu/Kconfig

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
	'pm8150b-charger-dagu.o' \
	'obj-$(CONFIG_CHARGER_PM8150B_DAGU) += pm8150b-charger-dagu.o'

append_once "$KERNEL_SRC/drivers/power/supply/Makefile" \
	'p9418-dagu.o' \
	'obj-$(CONFIG_CHARGER_P9418_DAGU) += p9418-dagu.o'

append_once "$KERNEL_SRC/drivers/power/supply/Makefile" \
	'xiaomi-dual-fg.o' \
	'obj-$(CONFIG_BATTERY_XIAOMI_DUAL_FG) += xiaomi-dual-fg.o'

append_once "$KERNEL_SRC/drivers/watchdog/Makefile" \
	'qcom-wdt-early-dagu.o' \
	'obj-$(CONFIG_QCOM_WDT) += qcom-wdt-early-dagu.o'

append_once "$KERNEL_SRC/drivers/media/i2c/Makefile" \
	'imx596-dagu.o' \
	'obj-$(CONFIG_VIDEO_IMX596_DAGU) += imx596-dagu.o'

append_once "$KERNEL_SRC/drivers/media/Makefile" \
	'v4l2loopback-dagu' \
	'obj-$(CONFIG_VIDEO_V4L2LOOPBACK_DAGU) += v4l2loopback-dagu/'

append_once "$KERNEL_SRC/drivers/media/Kconfig" \
	'v4l2loopback-dagu/Kconfig' \
	'source "drivers/media/v4l2loopback-dagu/Kconfig"'

append_once "$KERNEL_SRC/drivers/gpu/drm/msm/Makefile" \
	'msm_gpu_resources_sysfs.o' \
	'msm-y += msm_gpu_resources_sysfs.o'

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
	select HID
	select HID_GENERIC
	select HID_MULTITOUCH
	help
	  Magnetic keyboard MCU on Xiaomi Pad 5 Pro 12.4. I2C @0x4c on
	  QUP SE2 pads (gpio115/116 bit-bang). Do not enable GENI i2c2.

""",
)

kcfg_nanosic = root / "drivers/input/keyboard/Kconfig"
kcfg_text = kcfg_nanosic.read_text()
kcfg_old = """config KEYBOARD_NANOSIC_DAGU
	tristate "Nanosic 803 keyboard MCU (Xiaomi dagu)"
	depends on I2C
	help
	  Magnetic keyboard MCU on Xiaomi Pad 5 Pro 12.4. QUP SE2 I2C @0x4c.
"""
kcfg_new = """config KEYBOARD_NANOSIC_DAGU
	tristate "Nanosic 803 keyboard MCU (Xiaomi dagu)"
	depends on I2C
	select HID
	select HID_GENERIC
	select HID_MULTITOUCH
	help
	  Magnetic keyboard MCU on Xiaomi Pad 5 Pro 12.4. I2C @0x4c on
	  QUP SE2 pads (gpio115/116 bit-bang). Do not enable GENI i2c2.
"""
if kcfg_old in kcfg_text:
    kcfg_nanosic.write_text(kcfg_text.replace(kcfg_old, kcfg_new, 1))

insert_kconfig(
    root / "drivers/power/supply/Kconfig",
    "config BATTERY_BQ27XXX",
    """config CHARGER_BQ2597X_DAGU
	tristate "TI BQ25970 charge pump (Xiaomi dagu)"
	depends on I2C
	select REGMAP_I2C
	help
	  Dual BQ25970 / SC8551 switched-cap pumps for 67W PPS on dagu.

config CHARGER_PM8150B_DAGU
	tristate "PM8150B SMB5 charger (Xiaomi dagu)"
	depends on MFD_SPMI_PMIC
	help
	  PM8150B buck charger for 5 V / 9 V input on dagu. Does not
	  copy CAF qpnp-smb5 or touch Type-C registers.

config CHARGER_P9418_DAGU
	tristate "IDT P9418 Smart Pen TX (Xiaomi dagu)"
	depends on I2C
	select REGMAP_I2C
	help
	  P9418 on dagu is the stylus-side wireless TX (Smart Pen),
	  not Qi charging of the tablet pack.

config BATTERY_XIAOMI_DUAL_FG
	tristate "Xiaomi dual BQ27Z561 combiner (dagu)"
	depends on POWER_SUPPLY
	help
	  CAF xiaomi,dual-FuelGauge: one bms from master+slave BQ27Z561.

""",
)

insert_kconfig(
    root / "drivers/power/supply/Kconfig",
    "config CHARGER_P9418_DAGU",
    """config CHARGER_PM8150B_DAGU
	tristate "PM8150B SMB5 charger (Xiaomi dagu)"
	depends on MFD_SPMI_PMIC
	help
	  PM8150B buck charger for 5 V / 9 V input on dagu. Does not
	  copy CAF qpnp-smb5 or touch Type-C registers.

""",
)

insert_kconfig(
    root / "drivers/power/supply/Kconfig",
    "config CHARGER_P9418_DAGU",
    """config BATTERY_XIAOMI_DUAL_FG
	tristate "Xiaomi dual BQ27Z561 combiner (dagu)"
	depends on POWER_SUPPLY
	help
	  CAF xiaomi,dual-FuelGauge: one bms from master+slave BQ27Z561.

""",
)

insert_kconfig(
    root / "drivers/media/i2c/Kconfig",
    "config VIDEO_IMX412",
    """config VIDEO_IMX596_DAGU
	tristate "Sony IMX596 sensor (Xiaomi dagu front camera)"
	depends on I2C && GPIOLIB
	select V4L2_CCI_I2C
	help
	  Front camera on Xiaomi Pad 5 Pro 12.4. CAF: CCI1@0x1a, csiphy4,
	  reset GPIO109, MCLK GPIO97.

""",
)

# Do not poke KPSS WDT from primary_entry: MMU is off and that
# physical store SErrors on this ABL map. Pet from early_initcall instead.
PY

# L81A: CAF lp11-init + bllp HS. Re-applied every build (linux/ is a checkout).
python3 - "$KERNEL_SRC" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

host = root / "drivers/gpu/drm/msm/dsi/dsi_host.c"
text = host.read_text()
old = """\t\t/* Always set low power stop mode for BLLP
		 * to let command engine send packets
		 */
		data |= DSI_VID_CFG0_EOF_BLLP_POWER_STOP |
			DSI_VID_CFG0_BLLP_POWER_STOP;
"""
new = """\t\t/* dagu L81A: CAF qcom,mdss-dsi-bllp-power-mode keeps BLLP HS.
		 * Upstream always forces LP BLLP so the cmd engine can TX;
		 * Himax video+DSC stays black if blanking drops to LP.
		 * CLOCK_NON_CONTINUOUS panels keep the old LP BLLP.
		 */
		if (flags & MIPI_DSI_CLOCK_NON_CONTINUOUS) {
			data |= DSI_VID_CFG0_EOF_BLLP_POWER_STOP |
				DSI_VID_CFG0_BLLP_POWER_STOP;
		}
"""
if "dagu L81A: CAF qcom,mdss-dsi-bllp-power-mode" not in text:
    if old not in text:
        raise SystemExit("dsi_host.c BLLP block not found")
    host.write_text(text.replace(old, new, 1))

mgr = root / "drivers/gpu/drm/msm/dsi/dsi_manager.c"
text = mgr.read_text()
old = """	ret = dsi_mgr_bridge_power_on(bridge);
	if (ret) {
		dev_err(&msm_dsi->pdev->dev, "Power on failed: %d\\n", ret);
		return;
	}

	ret = msm_dsi_host_enable(host);
	if (ret) {
		pr_err("%s: enable host %d failed, %d\\n", __func__, id, ret);
		goto host_en_fail;
	}

	if (is_bonded_dsi && msm_dsi1) {
		ret = msm_dsi_host_enable(msm_dsi1->host);
		if (ret) {
			pr_err("%s: enable host1 failed, %d\\n", __func__, ret);
			goto host1_en_fail;
		}
	}

	return;

host1_en_fail:
	msm_dsi_host_disable(host);
host_en_fail:
	dsi_mgr_bridge_power_off(bridge);
}
"""
new = """	/* dagu L81A: CAF lp11-init. Power/LP11 in pre_enable, start video
	 * in enable() after the panel has sent on-command (0x11/0x29).
	 */
	ret = dsi_mgr_bridge_power_on(bridge);
	if (ret) {
		dev_err(&msm_dsi->pdev->dev, "Power on failed: %d\\n", ret);
		return;
	}
}

static void dsi_mgr_bridge_enable(struct drm_bridge *bridge)
{
	int id = dsi_mgr_bridge_get_id(bridge);
	struct msm_dsi *msm_dsi = dsi_mgr_get_dsi(id);
	struct msm_dsi *msm_dsi1 = dsi_mgr_get_dsi(DSI_1);
	struct mipi_dsi_host *host = msm_dsi->host;
	bool is_bonded_dsi = IS_BONDED_DSI();
	int ret;

	if (is_bonded_dsi && !IS_MASTER_DSI_LINK(id))
		return;

	ret = msm_dsi_host_enable(host);
	if (ret) {
		pr_err("%s: enable host %d failed, %d\\n", __func__, id, ret);
		return;
	}

	if (is_bonded_dsi && msm_dsi1) {
		ret = msm_dsi_host_enable(msm_dsi1->host);
		if (ret)
			pr_err("%s: enable host1 failed, %d\\n", __func__, ret);
	}
}
"""
if "dagu L81A: CAF lp11-init" not in text:
    if old not in text:
        raise SystemExit("dsi_manager.c pre_enable host_enable block not found")
    text = text.replace(old, new, 1)
    old2 = """static const struct drm_bridge_funcs dsi_mgr_bridge_funcs = {
	.attach = dsi_mgr_bridge_attach,
	.pre_enable = dsi_mgr_bridge_pre_enable,
	.post_disable = dsi_mgr_bridge_post_disable,
"""
    new2 = """static const struct drm_bridge_funcs dsi_mgr_bridge_funcs = {
	.attach = dsi_mgr_bridge_attach,
	.pre_enable = dsi_mgr_bridge_pre_enable,
	.enable = dsi_mgr_bridge_enable,
	.post_disable = dsi_mgr_bridge_post_disable,
"""
    if old2 not in text:
        raise SystemExit("dsi_manager.c bridge funcs not found")
    mgr.write_text(text.replace(old2, new2, 1))

# Drop diagnostic TPG from a previous build.
text = mgr.read_text()
tpg = """
	/* dagu L81A: uncompressed TPG. Checkerboard means video+panel lock. */
	msm_dsi_host_test_pattern_en(host);
	if (is_bonded_dsi && msm_dsi1)
		msm_dsi_host_test_pattern_en(msm_dsi1->host);
"""
if tpg in text:
    mgr.write_text(text.replace(tpg, "", 1))

# Explicit DPHY: leftover CPHY bits from ABL black the L81A video stream.
host = root / "drivers/gpu/drm/msm/dsi/dsi_host.c"
text = host.read_text()
old = """	if (msm_host->cphy_mode)
		dsi_write(msm_host, REG_DSI_CPHY_MODE_CTRL, BIT(0));
}
"""
new = """	if (msm_host->cphy_mode)
		dsi_write(msm_host, REG_DSI_CPHY_MODE_CTRL, BIT(0));
	else
		/* dagu L81A: force DPHY (do not leave CPHY_MODE_CTRL set). */
		dsi_write(msm_host, REG_DSI_CPHY_MODE_CTRL, 0);
}
"""
if "dagu L81A: force DPHY" not in text:
    if old not in text:
        raise SystemExit("dsi_host.c CPHY_MODE_CTRL block not found")
    host.write_text(text.replace(old, new, 1))

phy = root / "drivers/gpu/drm/msm/dsi/phy/dsi_phy_7nm.c"
text = phy.read_text()
old = """	if (phy->cphy_mode)
		writel(BIT(6), base + REG_DSI_7nm_PHY_CMN_GLBL_CTRL);
"""
new = """	if (phy->cphy_mode)
		writel(BIT(6), base + REG_DSI_7nm_PHY_CMN_GLBL_CTRL);
	else
		/* dagu L81A: clear leftover CPHY bit on DPHY. */
		writel(0, base + REG_DSI_7nm_PHY_CMN_GLBL_CTRL);
"""
if "dagu L81A: clear leftover CPHY bit" not in text:
    if old not in text:
        raise SystemExit("dsi_phy_7nm.c GLBL_CTRL block not found")
    text = text.replace(old, new, 1)
    phy.write_text(text)

text = phy.read_text()
old = """	} else {
		writel(0x00, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_0);
		writel(timing->clk_zero, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_1);
		writel(timing->clk_prepare, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_2);
		writel(timing->clk_trail, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_3);
		writel(timing->hs_exit, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_4);
		writel(timing->hs_zero, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_5);
		writel(timing->hs_prepare, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_6);
		writel(timing->hs_trail, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_7);
		writel(timing->hs_rqst, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_8);
		writel(0x02, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_9);
		writel(0x04, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_10);
		writel(0x00, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_11);
		writel(timing->shared_timings.clk_pre,
		       base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_12);
		writel(timing->shared_timings.clk_post,
		       base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_13);
	}
"""
new = """	} else {
		/* dagu L81A: CAF qcom,mdss-dsi-panel-phy-timings
		 * [00 1C 08 07 17 16 07 07 08 02 04 00 19 0C]
		 */
		writel(0x00, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_0);
		writel(0x1c, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_1);
		writel(0x08, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_2);
		writel(0x07, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_3);
		writel(0x17, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_4);
		writel(0x16, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_5);
		writel(0x07, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_6);
		writel(0x07, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_7);
		writel(0x08, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_8);
		writel(0x02, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_9);
		writel(0x04, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_10);
		writel(0x00, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_11);
		writel(0x19, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_12);
		writel(0x0c, base + REG_DSI_7nm_PHY_CMN_TIMING_CTRL_13);
	}
"""
if "dagu L81A: CAF qcom,mdss-dsi-panel-phy-timings" not in text:
    if old not in text:
        raise SystemExit("dsi_phy_7nm.c DPHY timing block not found")
    phy.write_text(text.replace(old, new, 1))

# Video-mode idle_pc only drops IRQs (does not gate DSC clocks). That
# starves Mutter's frame clock (~100-150 ms fallback) and races dual
# DSC flush (vblank timeout 0x400000). Keep vid IRQs on.
enc = root / "drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c"
etext = enc.read_text()
emarker = "dagu: video mode keep IRQs"
if emarker not in etext:
    eold = """		if (dpu_crtc_frame_pending(drm_enc->crtc) > 1) {
			DRM_DEBUG_KMS("id:%d skip schedule work\\n",
				      DRMID(drm_enc));
			return 0;
		}

		queue_delayed_work(priv->kms->wq, &dpu_enc->delayed_off_work,
				   msecs_to_jiffies(dpu_enc->idle_timeout));
"""
    enew = """		if (dpu_crtc_frame_pending(drm_enc->crtc) > 1) {
			DRM_DEBUG_KMS("id:%d skip schedule work\\n",
				      DRMID(drm_enc));
			return 0;
		}

		/* dagu: video mode keep IRQs. idle_pc only calls
		 * _dpu_encoder_irq_disable (IDLE_TIMEOUT=58 ms). Panel
		 * still scans; Mutter then misses vblank and falls back
		 * to a 100-150 ms frame-clock timeout (Chrome WaitForSwap
		 * holes). First commit after idle also races dual DSC
		 * CTL flush (vblank timeout 0x400000).
		 */
		if (is_vid_mode)
			return 0;

		queue_delayed_work(priv->kms->wq, &dpu_enc->delayed_off_work,
				   msecs_to_jiffies(dpu_enc->idle_timeout));
"""
    if eold not in etext:
        raise SystemExit(f"{enc}: FRAME_DONE idle queue block not found")
    enc.write_text(etext.replace(eold, enew, 1))
    print(f"patched {enc}: {emarker}")

# Mainline calls dpu_encoder_prep_dsc() on every kickoff: dsc_config,
# dsc_bind_pingpong_blk (dsc0→pp0, dsc1→pp1), enable_dsc, and
# update_pending_flush_dsc (CTL_FLUSH bit 22). L81A dual-DSC then
# stalls wait_event 107-219 ms. Bind once at enable/hw_reset.
enc = root / "drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c"
etext = enc.read_text()
emarker = "dagu: skip redundant DSC prep"
if emarker not in etext:
    eold = """	/* DSC configuration */
	struct drm_dsc_config *dsc;
};
"""
    enew = """	/* DSC configuration */
	struct drm_dsc_config *dsc;
	/* dagu: skip redundant DSC prep. Mainline rebinds DSC and
	 * pending_flush_dsc (CTL bit 22) on every kickoff. L81A 120 Hz
	 * dual-DSC then stalls CTL_FLUSH wait_event 107-219 ms.
	 */
	bool dsc_prepared;
};
"""
    if eold not in etext:
        raise SystemExit(f"{enc}: dsc field block not found")
    etext = etext.replace(eold, enew, 1)

    eold = """	if (!dpu_enc->enabled)
		goto out;

	if (dpu_enc->cur_slave && dpu_enc->cur_slave->ops.restore)
"""
    enew = """	if (!dpu_enc->enabled)
		goto out;

	dpu_enc->dsc_prepared = false;

	if (dpu_enc->cur_slave && dpu_enc->cur_slave->ops.restore)
"""
    if eold not in etext:
        raise SystemExit(f"{enc}: runtime_resume restore block not found")
    etext = etext.replace(eold, enew, 1)

    eold = """	dpu_enc = to_dpu_encoder_virt(drm_enc);
	dpu_enc->dsc = dpu_encoder_get_dsc_config(drm_enc);
"""
    enew = """	dpu_enc = to_dpu_encoder_virt(drm_enc);
	dpu_enc->dsc = dpu_encoder_get_dsc_config(drm_enc);
	dpu_enc->dsc_prepared = false;
"""
    if eold not in etext:
        raise SystemExit(f"{enc}: atomic_enable dsc assign not found")
    etext = etext.replace(eold, enew, 1)

    eold = """	if (dpu_enc->dsc)
		dpu_encoder_prep_dsc(dpu_enc, dpu_enc->dsc);
}
"""
    enew = """	if (dpu_enc->dsc && (!dpu_enc->dsc_prepared || needs_hw_reset)) {
		/* dagu: skip redundant DSC prep. Modeset/enable and
		 * hw_reset still bind; later kickoffs keep the mux.
		 */
		dpu_encoder_prep_dsc(dpu_enc, dpu_enc->dsc);
		dpu_enc->dsc_prepared = true;
	}
}
"""
    if eold not in etext:
        raise SystemExit(f"{enc}: prepare_for_kickoff prep_dsc not found")
    etext = etext.replace(eold, enew, 1)

    eold = """	if (dpu_enc->dsc) {
		dpu_encoder_unprep_dsc(dpu_enc);
		dpu_enc->dsc = NULL;
	}
"""
    enew = """	if (dpu_enc->dsc) {
		dpu_encoder_unprep_dsc(dpu_enc);
		dpu_enc->dsc = NULL;
		dpu_enc->dsc_prepared = false;
	}
"""
    if eold not in etext:
        raise SystemExit(f"{enc}: unprep_dsc disable block not found")
    etext = etext.replace(eold, enew, 1)
    enc.write_text(etext)
    print(f"patched {enc}: {emarker}")

# DPU INTF DSC active width must match DSI (DIV_ROUND_UP). Upstream
# truncates 800*8/24=266; CAF and dsi_timing_setup both use 267.
vid = root / "drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c"
text = vid.read_text()
old = """		timing->width = timing->width * drm_dsc_get_bpp_int(dsc) /
				(dsc->bits_per_component * 3);
		timing->xres = timing->width;
"""
new = """		/* dagu L81A: CAF DIV_ROUND_UP(hdisplay, 3) for 8bpp DSC.
		 * Truncation yields 266 vs DSI 267 → video never locks.
		 */
		timing->width = DIV_ROUND_UP(timing->width *
					     drm_dsc_get_bpp_int(dsc),
					     dsc->bits_per_component * 3);
		timing->xres = timing->width;
"""
if "dagu L81A: CAF DIV_ROUND_UP" not in text:
    if old not in text:
        raise SystemExit("dpu_encoder_phys_vid.c DSC width block not found")
    vid.write_text(text.replace(old, new, 1))

PY

# primary_entry probe: OFF. Default used to be 1, which injected PSCI
# SYSTEM_RESET at the first kernel instruction — instant bounce to fastboot.
if [[ "${DAGU_PRIMARY_ENTRY_PROBE:-0}" == 1 ]]; then
	python3 - "$KERNEL_SRC/arch/arm64/kernel/head.S" <<'PY'
import re
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu bringup: SMC-first primary_entry probe"
block = """SYM_CODE_START(primary_entry)
	/* dagu bringup: SMC-first primary_entry probe (no MMU-off stores before SMC) */
	ldr	x0, =0x84000009			// PSCI SMC32 SYSTEM_RESET
	smc	#0
	ldr	x0, =0xC4000009			// PSCI SMC64 SYSTEM_RESET
	smc	#0
	/* fallback: dual DBGC @0xb0000000 and 0xb0100000 (TWRP record_size=0) */
	ldr	x2, =0xb0000000
	ldr	w3, =0x43474244			// "DBGC"
	str	w3, [x2]
	str	wzr, [x2, #4]
	mov	w3, #16
	str	w3, [x2, #8]
	ldr	x3, =0x21544948			// "HIT!"
	str	x3, [x2, #12]
	ldr	x2, =0xb0100000
	ldr	w3, =0x43474244
	str	w3, [x2]
	str	wzr, [x2, #4]
	mov	w3, #16
	str	w3, [x2, #8]
	str	x3, [x2, #12]
9:
	b	9b

"""
if marker in text:
    pass
else:
    text, n = re.subn(
        r"SYM_CODE_START\(primary_entry\)\n(?:.*?\n)*?(?=\tbl\trecord_mmu_state)",
        block,
        text,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"{path}: could not patch primary_entry probe")
    path.write_text(text)
    print(f"patched {path}: SMC-first primary_entry probe")
PY
else
	python3 - "$KERNEL_SRC/arch/arm64/kernel/head.S" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu bringup: SMC-first primary_entry probe"
if marker not in text:
    raise SystemExit(0)
start = text.find("SYM_CODE_START(primary_entry)\n")
if start < 0:
    raise SystemExit(f"{path}: primary_entry missing")
needle_end = "\tbl\trecord_mmu_state\n"
end = text.find(needle_end, start)
if end < 0:
    raise SystemExit(f"{path}: record_mmu_state missing after primary_entry")
text = text[:start] + "SYM_CODE_START(primary_entry)\n" + text[end:]
path.write_text(text)
print(f"restored {path}: native primary_entry (probe off)")
PY
fi

echo "==> overlays installed"

python3 - "$KERNEL_SRC/drivers/cpufreq/qcom-cpufreq-hw.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: skip CPU ICC paths"
old = """\tret = dev_pm_opp_of_find_icc_paths(cpu_dev, NULL);
\tif (ret)
\t\treturn dev_err_probe(dev, ret, "Failed to find icc paths\\n");
"""
new = """\tret = dev_pm_opp_of_find_icc_paths(cpu_dev, NULL);
\tif (ret) {
\t\t/* dagu: skip CPU ICC paths — SM8250 ICC is off; BCM voter hangs */
\t\tdev_info(dev, "dagu: skip CPU ICC paths (%d), scale without BCM\\n",
\t\t\t ret);
\t}
"""
if marker not in text:
    if old not in text:
        raise SystemExit(f"{path}: cpufreq icc-path block not found")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}: {marker}")
# A previous overlay forced icc_scaling_enabled=false, which makes
# dev_pm_opp_add() fail against the DT OPP table and LUT probe abort.
old_bad = """\t\t/* Disable all opps and cross-validate against LUT later */
\t\t/* dagu: skip CPU ICC paths — scale EPSS LUT without BCM votes */
\t\ticc_scaling_enabled = false;
"""
new_good = """\t\t/* Disable all opps and cross-validate against LUT later */
\t\ticc_scaling_enabled = true;
"""
text = path.read_text()
if old_bad in text:
    text = text.replace(old_bad, new_good, 1)
    path.write_text(text)
    print(f"restored {path}: icc_scaling_enabled=true")
# Don't vote CPU/L3 interconnects on freq change (no SM8250 ICC).
bw_old = """\tif (icc_scaling_enabled)
\t\tqcom_cpufreq_set_bw(policy, freq);
"""
bw_new = """\t/* dagu: skip CPU ICC paths — EPSS freq scale only, no BCM vote */
"""
text = path.read_text()
if "EPSS freq scale only" not in text:
    if bw_old not in text:
        raise SystemExit(f"{path}: cpufreq set_bw call not found")
    text = text.replace(bw_old, bw_new, 1)
    path.write_text(text)
    print(f"patched {path}: skip set_bw ICC")
# DT CPU OPP tables pull ICC; treat -EPROBE_DEFER as "no OPP table"
# so the EPSS LUT path can still register frequencies.
lut_old = """\t} else if (ret != -ENODEV) {
\t\tdev_err(cpu_dev, "Invalid opp table in device tree\\n");
\t\tkfree(table);
\t\treturn ret;
\t} else {
\t\tpolicy->fast_switch_possible = true;
\t\ticc_scaling_enabled = false;
\t}
"""
lut_new = """\t} else if (ret == -EPROBE_DEFER) {
\t\t/* dagu: skip CPU ICC paths — DT OPPs need ICC; use EPSS LUT */
\t\tdev_pm_opp_of_remove_table(cpu_dev);
\t\tdev_info(cpu_dev, "dagu: skip DT OPP ICC (%d), use EPSS LUT\\n",
\t\t\t ret);
\t\tpolicy->fast_switch_possible = true;
\t\ticc_scaling_enabled = false;
\t} else if (ret != -ENODEV) {
\t\tdev_err(cpu_dev, "Invalid opp table in device tree\\n");
\t\tkfree(table);
\t\treturn ret;
\t} else {
\t\tpolicy->fast_switch_possible = true;
\t\ticc_scaling_enabled = false;
\t}
"""
text = path.read_text()
if "dagu: skip DT CPU OPP table" in text:
    pass  # of_add_table already removed; LUT EPROBE_DEFER patch does not apply
elif "dev_pm_opp_of_remove_table(cpu_dev)" not in text:
    if "use EPSS LUT" in text:
        old_defer = """\t} else if (ret == -EPROBE_DEFER) {
\t\t/* dagu: skip CPU ICC paths — DT OPPs need ICC; use EPSS LUT */
\t\tdev_info(cpu_dev, "dagu: skip DT OPP ICC (%d), use EPSS LUT\\n",
\t\t\t ret);
"""
        new_defer = """\t} else if (ret == -EPROBE_DEFER) {
\t\t/* dagu: skip CPU ICC paths — DT OPPs need ICC; use EPSS LUT */
\t\tdev_pm_opp_of_remove_table(cpu_dev);
\t\tdev_info(cpu_dev, "dagu: skip DT OPP ICC (%d), use EPSS LUT\\n",
\t\t\t ret);
"""
        if old_defer not in text:
            raise SystemExit(f"{path}: EPROBE_DEFER LUT block not found")
        text = text.replace(old_defer, new_defer, 1)
        path.write_text(text)
        print(f"patched {path}: remove DT OPP table before LUT")
    else:
        if lut_old not in text:
            raise SystemExit(f"{path}: cpufreq Invalid opp table block not found")
        path.write_text(text.replace(lut_old, lut_new, 1))
        print(f"patched {path}: EPSS LUT on OPP EPROBE_DEFER")
# Never parse DT CPU OPPs: they have no voltages, and even after deleting
# interconnects of_add_table would set icc_scaling_enabled and then
# adjust_voltage() against LUT frequencies that do not match DT opp-hz.
text = path.read_text()
skip_marker = "dagu: skip DT CPU OPP table"
if skip_marker not in text:
    add_old = """\tret = dev_pm_opp_of_add_table(cpu_dev);
\tif (!ret) {
"""
    if add_old not in text:
        raise SystemExit(f"{path}: of_add_table block not found for skip")
    start = text.find(add_old)
    # Cut through the matching if/else that ends at icc_scaling_enabled = false;
    # followed by the LUT walk.
    end_token = "\tfor (i = 0; i < LUT_MAX_ENTRIES; i++) {"
    end = text.find(end_token, start)
    if end < 0:
        raise SystemExit(f"{path}: LUT walk not found after of_add_table")
    add_new = """\t/* dagu: skip DT CPU OPP table — LUT supplies freq/volt, no ICC */
\t(void)opp;
\t(void)rate;
\tpolicy->fast_switch_possible = true;
\ticc_scaling_enabled = false;

"""
    path.write_text(text[:start] + add_new + text[end:])
    print(f"patched {path}: {skip_marker}")
PY

python3 - "$KERNEL_SRC/drivers/tty/serial/qcom_geni_serial.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: load UART QUPFW from this SE"
if marker in text:
    raise SystemExit(0)
new = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\t/* dagu: load UART QUPFW from this SE firmware-name, never the wrapper */
\t\tret = geni_load_se_firmware(&port->se, GENI_SE_UART);
\t\tif (ret) {
\t\t\tdev_err(uport->dev, "UART firmware load failed ret: %d\\n", ret);
\t\t\treturn ret;
\t\t}
\t} else if (proto != GENI_SE_UART) {
"""
skip = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\t/* dagu: UART proto invalid, not loading QUPFW on this QHEE */
\t\tdev_err(uport->dev,
\t\t\t"UART proto invalid, not loading QUPFW on this QHEE\\n");
\t\treturn -EOPNOTSUPP;
\t} else if (proto != GENI_SE_UART) {
"""
upstream = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\tret = geni_load_se_firmware(&port->se, GENI_SE_UART);
\t\tif (ret) {
\t\t\tdev_err(uport->dev, "UART firmware load failed ret: %d\\n", ret);
\t\t\treturn ret;
\t\t}
\t} else if (proto != GENI_SE_UART) {
"""
if skip in text:
    text = text.replace(skip, new, 1)
elif upstream in text:
    text = text.replace(upstream, new, 1)
else:
    raise SystemExit(f"{path}: UART firmware-load block not found")
path.write_text(text)
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/net/bluetooth/hci_core.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: HID-class sniff"
if marker in text:
    raise SystemExit(0)
old = """	hdev->sniff_max_interval = 800;
	hdev->sniff_min_interval = 80;
"""
new = """	/* dagu: HID-class sniff (6–18 slots = 3.75–11.25 ms). Keep sniff so
	 * classic keyboards/mice can radio-sleep and still wake the tablet.
	 * Do not clear HCI_LP_SNIFF or pin the QCA UART awake.
	 */
	hdev->sniff_max_interval = 18;
	hdev->sniff_min_interval = 6;
"""
if old not in text:
    raise SystemExit(f"{path}: sniff interval defaults not found")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/net/bluetooth/hci_core.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: HID host is Central"
if marker not in text:
    old = """	hdev->link_mode = (HCI_LM_ACCEPT);
"""
    new = """	/* dagu: HID host is Central. Incoming Accept Connection Request
	 * then asks to Become central; outgoing Create Connection does not
	 * offer a role switch. Do not clear role-switch from link policy.
	 */
	hdev->link_mode = (HCI_LM_MASTER | HCI_LM_ACCEPT);
"""
    if old not in text:
        raise SystemExit(f"{path}: link_mode default not found")
    text = text.replace(old, new, 1)
    print(f"patched {path}: {marker}")
marker = "dagu: HID-host interlaced page scan"
if marker not in text:
    old = """	/* default 1.28 sec page scan */
	hdev->def_page_scan_type = PAGE_SCAN_TYPE_STANDARD;
	hdev->def_page_scan_int = 0x0800;
	hdev->def_page_scan_window = 0x0012;
"""
    new = """	/* dagu: HID-host interlaced page scan. Train hopping covers both
	 * page trains in one interval so a waking K380 can find us; window
	 * stays 11.25 ms. FastConnectable (BlueZ) further shortens interval
	 * to 160 ms. Not a sleep disable.
	 */
	hdev->def_page_scan_type = PAGE_SCAN_TYPE_INTERLACED;
	hdev->def_page_scan_int = 0x0400;
	hdev->def_page_scan_window = 0x0012;
"""
    if old not in text:
        raise SystemExit(f"{path}: page scan defaults not found")
    text = text.replace(old, new, 1)
    print(f"patched {path}: {marker}")
path.write_text(text)
PY

python3 - "$KERNEL_SRC/include/net/bluetooth/hci_core.h" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: paging clock offset"
if marker in text:
    raise SystemExit(0)
old = """#define INQUIRY_CACHE_AGE_MAX   (HZ*30)   /* 30 seconds */
#define INQUIRY_ENTRY_AGE_MAX   (HZ*60)   /* 60 seconds */
"""
new = """#define INQUIRY_CACHE_AGE_MAX   (HZ*30)   /* 30 seconds */
#define INQUIRY_ENTRY_AGE_MAX   (HZ*60)   /* 60 seconds */
/* dagu: paging clock offset stays useful while local CLKN is continuous
 * (inquiry cache is flushed on HCI Reset). 20 ppm * 900 s ≈ 18 ms.
 */
#define PAGING_CLOCK_OFFSET_AGE_MAX	(HZ * 900)
"""
if old not in text:
    raise SystemExit(f"{path}: inquiry age macros not found")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/net/bluetooth/hci_sync.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: pscan_rep_mode does not drift"
if marker in text:
    raise SystemExit(0)
old = """	ie = hci_inquiry_cache_lookup(hdev, &conn->dst);
	if (ie) {
		if (inquiry_entry_age(ie) <= INQUIRY_ENTRY_AGE_MAX) {
			cp.pscan_rep_mode = ie->data.pscan_rep_mode;
			cp.pscan_mode     = ie->data.pscan_mode;
			cp.clock_offset   = ie->data.clock_offset |
					    cpu_to_le16(0x8000);
		}

		memcpy(conn->dev_class, ie->data.dev_class, 3);
	}
"""
new = """	ie = hci_inquiry_cache_lookup(hdev, &conn->dst);
	if (ie) {
		/* dagu: pscan_rep_mode does not drift. Clock offset is
		 * valid while local CLKN is continuous; HCI Reset flushes
		 * the cache. Blind R2 + offset 0 is why classic HID pages
		 * time out once GNOME is closed for >60 s.
		 */
		cp.pscan_rep_mode = ie->data.pscan_rep_mode;
		cp.pscan_mode     = ie->data.pscan_mode;
		if (inquiry_entry_age(ie) <= PAGING_CLOCK_OFFSET_AGE_MAX)
			cp.clock_offset   = ie->data.clock_offset |
					    cpu_to_le16(0x8000);

		memcpy(conn->dev_class, ie->data.dev_class, 3);
	}
"""
if old not in text:
    raise SystemExit(f"{path}: Create Connection inquiry-cache block not found")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/net/bluetooth/hci_event.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
changed = False

marker = "dagu: store paging clock offset while ACL is up"
if marker not in text:
    old = """		/* Get remote features */
		if (conn->type == ACL_LINK) {
			struct hci_cp_read_remote_features cp;
			cp.handle = ev->handle;
			hci_send_cmd(hdev, HCI_OP_READ_REMOTE_FEATURES,
				     sizeof(cp), &cp);

			hci_update_scan(hdev);
		}
"""
    new = """		/* Get remote features */
		if (conn->type == ACL_LINK) {
			struct hci_cp_read_remote_features cp;
			struct hci_cp_read_clock_offset clkoff_cp;

			cp.handle = ev->handle;
			hci_send_cmd(hdev, HCI_OP_READ_REMOTE_FEATURES,
				     sizeof(cp), &cp);

			hci_update_scan(hdev);

			/* dagu: store paging clock offset while ACL is up.
			 * Upstream only reads it on disconnect, and only
			 * writes the inquiry cache if an entry already
			 * exists — so a closed GNOME panel leaves the next
			 * Create Connection with R2 + offset 0.
			 */
			clkoff_cp.handle = ev->handle;
			hci_send_cmd(hdev, HCI_OP_READ_CLOCK_OFFSET,
				     sizeof(clkoff_cp), &clkoff_cp);
		}
"""
    if old not in text:
        raise SystemExit(f"{path}: ACL remote-features block not found")
    text = text.replace(old, new, 1)
    changed = True
    print(f"patched {path}: {marker}")

marker = "dagu: HID sniff TX stays in-window"
old_force_exit = """		test_and_clear_bit(HCI_CONN_MODE_CHANGE_PEND, &conn->flags);
		/* dagu: keep POWER_SAVE in sniff so host TX (LED / output
		 * report) can Exit Sniff. Remote-initiated sniff used to
		 * clear this bit, leaving the first host packet stuck
		 * until the sniff window (50–500 ms on the ACL default).
		 * Sniff itself stays enabled.
		 */
		if (conn->mode == HCI_CM_SNIFF)
			set_bit(HCI_CONN_POWER_SAVE, &conn->flags);
		else if (conn->mode == HCI_CM_ACTIVE)
			set_bit(HCI_CONN_POWER_SAVE, &conn->flags);
"""
old_upstream = """		if (!test_and_clear_bit(HCI_CONN_MODE_CHANGE_PEND,
					&conn->flags)) {
			if (conn->mode == HCI_CM_ACTIVE)
				set_bit(HCI_CONN_POWER_SAVE, &conn->flags);
			else
				clear_bit(HCI_CONN_POWER_SAVE, &conn->flags);
		}
"""
new_in_window = """		if (!test_and_clear_bit(HCI_CONN_MODE_CHANGE_PEND,
					&conn->flags)) {
			/* dagu: HID sniff TX stays in-window. K380 sniff is
			 * 20 slots (12.5 ms). Exit Sniff for LED/output is
			 * ~200 ms on QCA6390, so Ctrl+T / the next key wait
			 * and Linux autorepeats the first key. Do not set
			 * POWER_SAVE in sniff. Sniff itself stays enabled.
			 */
			if (conn->mode == HCI_CM_ACTIVE)
				set_bit(HCI_CONN_POWER_SAVE, &conn->flags);
			else
				clear_bit(HCI_CONN_POWER_SAVE, &conn->flags);
		}
"""
if marker not in text:
    if old_force_exit in text:
        text = text.replace(old_force_exit, new_in_window, 1)
        changed = True
        print(f"patched {path}: {marker} (from force-exit)")
    elif old_upstream in text:
        text = text.replace(old_upstream, new_in_window, 1)
        changed = True
        print(f"patched {path}: {marker}")
    else:
        raise SystemExit(f"{path}: mode-change POWER_SAVE block not found")

marker = "dagu: create inquiry cache from Read Clock Offset"
if marker not in text:
    old = """	conn = hci_conn_hash_lookup_handle(hdev, __le16_to_cpu(ev->handle));
	if (conn && !ev->status) {
		struct inquiry_entry *ie;

		ie = hci_inquiry_cache_lookup(hdev, &conn->dst);
		if (ie) {
			ie->data.clock_offset = ev->clock_offset;
			ie->timestamp = jiffies;
		}
	}
"""
    new = """	conn = hci_conn_hash_lookup_handle(hdev, __le16_to_cpu(ev->handle));
	if (conn && !ev->status) {
		struct inquiry_entry *ie;
		struct inquiry_data data;

		ie = hci_inquiry_cache_lookup(hdev, &conn->dst);
		if (ie) {
			ie->data.clock_offset = ev->clock_offset;
			ie->timestamp = jiffies;
		} else {
			/* dagu: create inquiry cache from Read Clock Offset
			 * so the next page is not R2 + offset 0.
			 */
			memset(&data, 0, sizeof(data));
			bacpy(&data.bdaddr, &conn->dst);
			data.pscan_rep_mode = 0x02;
			data.clock_offset = ev->clock_offset;
			memcpy(data.dev_class, conn->dev_class, 3);
			hci_inquiry_cache_update(hdev, &data, true);
		}
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: clock-offset cache update not found")
    text = text.replace(old, new, 1)
    changed = True
    print(f"patched {path}: {marker}")

if changed:
    path.write_text(text)
PY

python3 - "$KERNEL_SRC/net/bluetooth/hci_sync.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
changed = False

marker = "dagu: Create Connection Cancel must not wait"
if marker not in text:
    old = """	if (reason != HCI_ERROR_REMOTE_POWER_OFF)
		return __hci_cmd_sync_status_sk(hdev, HCI_OP_CREATE_CONN_CANCEL,
						6, &conn->dst,
						HCI_EV_CONN_COMPLETE,
						HCI_CMD_TIMEOUT, NULL);

	return __hci_cmd_sync_status(hdev, HCI_OP_CREATE_CONN_CANCEL,
				     6, &conn->dst, HCI_CMD_TIMEOUT);
"""
    new = """	/* dagu: Create Connection Cancel must not wait for
	 * HCI_EV_CONN_COMPLETE when the handle is still unset.
	 * QCA6390 returns Unknown Connection Identifier (0x02) while
	 * the radio is still paging; waiting the event leaves
	 * handle 3840 in BT_CONNECT and Inquiry sees Busy. 0x02 maps
	 * to -ENOTCONN — that is a successful host-side cancel.
	 */
	if (HCI_CONN_HANDLE_UNSET(conn->handle) ||
	    reason == HCI_ERROR_REMOTE_POWER_OFF) {
		int err;

		err = __hci_cmd_sync_status(hdev, HCI_OP_CREATE_CONN_CANCEL,
					    6, &conn->dst, HCI_CMD_TIMEOUT);
		if (err == -ENOTCONN)
			return 0;
		return err;
	}

	return __hci_cmd_sync_status_sk(hdev, HCI_OP_CREATE_CONN_CANCEL,
					6, &conn->dst,
					HCI_EV_CONN_COMPLETE,
					HCI_CMD_TIMEOUT, NULL);
"""
    if old not in text:
        raise SystemExit(f"{path}: Create Connection Cancel wait block not found")
    text = text.replace(old, new, 1)
    changed = True
    print(f"patched {path}: {marker}")

marker = "dagu: ACL Create Connection needs a complete callback"
if marker not in text:
    old = """int hci_connect_acl_sync(struct hci_dev *hdev, struct hci_conn *conn)
{
	int err;

	err = hci_cmd_sync_queue_once(hdev, hci_acl_create_conn_sync, conn,
				      NULL);
	return (err == -EEXIST) ? 0 : err;
}
"""
    new = """static void create_acl_conn_complete(struct hci_dev *hdev, void *data, int err)
{
	struct hci_conn *conn = data;

	/* dagu: ACL Create Connection needs a complete callback.
	 * Upstream queues it with NULL complete, so a Page Timeout
	 * without HCI_EV_CONN_COMPLETE leaves BT_CONNECT + unset
	 * handle (3840) occupying the QCA radio.
	 */
	if (err == -ECANCELED)
		return;

	hci_dev_lock(hdev);

	if (!hci_conn_valid(hdev, conn))
		goto done;

	if (!err || conn->state != BT_CONNECT)
		goto done;

	hci_conn_failed(conn, bt_status(err));

done:
	hci_dev_unlock(hdev);
}

int hci_connect_acl_sync(struct hci_dev *hdev, struct hci_conn *conn)
{
	int err;

	err = hci_cmd_sync_queue_once(hdev, hci_acl_create_conn_sync, conn,
				      create_acl_conn_complete);
	return (err == -EEXIST) ? 0 : err;
}
"""
    if old not in text:
        raise SystemExit(f"{path}: hci_connect_acl_sync not found")
    text = text.replace(old, new, 1)
    changed = True
    print(f"patched {path}: {marker}")

if changed:
    path.write_text(text)
PY

python3 - "$KERNEL_SRC/net/bluetooth/hci_sync.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
changed = False

marker = "dagu: accept-list / unset-handle LE cancel"
if marker not in text:
    old = """static int hci_le_connect_cancel_sync(struct hci_dev *hdev,
				      struct hci_conn *conn, u8 reason)
{
	/* Return reason if scanning since the connection shall probably be
	 * cleanup directly.
	 */
	if (test_bit(HCI_CONN_SCANNING, &conn->flags))
		return reason;

	if (conn->role == HCI_ROLE_SLAVE ||
	    test_and_set_bit(HCI_CONN_CANCEL, &conn->flags))
		return 0;

	return __hci_cmd_sync_status(hdev, HCI_OP_LE_CREATE_CONN_CANCEL,
				     0, NULL, HCI_CMD_TIMEOUT);
}
"""
    new = """static int hci_le_connect_cancel_sync(struct hci_dev *hdev,
				      struct hci_conn *conn, u8 reason)
{
	int err;

	(void)reason;

	/* dagu: accept-list / unset-handle LE cancel. GNOME Device.Connect
	 * parks HOG in HCI_CONN_SCANNING (no LE Create Connection). Sending
	 * LE_CREATE_CONN_CANCEL then gets 0x02/0x0C and leaves handle 3840
	 * in BT_CONNECT, so the next Settings click times out. Skip the
	 * command; abort_conn_sync still runs hci_conn_failed.
	 */
	if (test_bit(HCI_CONN_SCANNING, &conn->flags) ||
	    HCI_CONN_HANDLE_UNSET(conn->handle))
		return 0;

	if (conn->role == HCI_ROLE_SLAVE ||
	    test_and_set_bit(HCI_CONN_CANCEL, &conn->flags))
		return 0;

	err = __hci_cmd_sync_status(hdev, HCI_OP_LE_CREATE_CONN_CANCEL,
				    0, NULL, HCI_CMD_TIMEOUT);
	if (err == -ENOTCONN || err == -ENOSYS || err == -EPERM)
		return 0;
	return err;
}
"""
    if old not in text:
        raise SystemExit(f"{path}: hci_le_connect_cancel_sync not found")
    text = text.replace(old, new, 1)
    changed = True
    print(f"patched {path}: {marker}")

marker = "dagu: unset-handle abort must still run"
if marker not in text:
    old = """	hci_dev_lock(hdev);

	/* Check if the connection has been cleaned up concurrently */
	c = hci_conn_hash_lookup_handle(hdev, handle);
	if (!c || c != conn) {
		err = 0;
		goto unlock;
	}
"""
    new = """	hci_dev_lock(hdev);

	/* Check if the connection has been cleaned up concurrently */
	/* dagu: unset-handle abort must still run hci_conn_failed.
	 * lookup_handle(3840) can miss after QCA setup / ida_free;
	 * GNOME then leaves BT_CONNECT occupying the radio.
	 */
	if (HCI_CONN_HANDLE_UNSET(handle)) {
		if (!hci_conn_valid(hdev, conn)) {
			err = 0;
			goto unlock;
		}
		c = conn;
	} else {
		c = hci_conn_hash_lookup_handle(hdev, handle);
		if (!c || c != conn) {
			err = 0;
			goto unlock;
		}
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: hci_abort_conn_sync handle lookup not found")
    text = text.replace(old, new, 1)
    changed = True
    print(f"patched {path}: {marker}")

marker = "dagu: fail THIS conn"
if marker not in text:
    old = """	if (!err) {
		hci_connect_le_scan_cleanup(conn, 0x00);
		goto done;
	}

	/* Check if connection is still pending */
	if (conn != hci_lookup_le_connect(hdev))
		goto done;

	/* Flush to make sure we send create conn cancel command if needed */
	flush_delayed_work(&conn->le_conn_timeout);
	hci_conn_failed(conn, bt_status(err));
"""
    new = """	if (!err) {
		hci_connect_le_scan_cleanup(conn, 0x00);
		goto done;
	}

	/* dagu: fail THIS conn. lookup_le_connect() returns the first
	 * BT_CONNECT without SCANNING; a second GNOME click then skips
	 * cleanup and leaves handle 3841/3842 until the next HCI reset.
	 */
	if (conn->state != BT_CONNECT)
		goto done;

	/* Flush to make sure we send create conn cancel command if needed */
	flush_delayed_work(&conn->le_conn_timeout);
	hci_conn_failed(conn, bt_status(err));
"""
    if old not in text:
        raise SystemExit(f"{path}: create_le_conn_complete pending check not found")
    text = text.replace(old, new, 1)
    changed = True
    print(f"patched {path}: {marker}")

if changed:
    path.write_text(text)
PY

python3 - "$KERNEL_SRC/net/bluetooth/l2cap_core.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: GNOME Settings Pair/Connect"
if marker not in text:
    old = """		if (hci_dev_test_flag(hdev, HCI_ADVERTISING))
			hcon = hci_connect_le(hdev, dst, dst_type, false,
					      chan->sec_level, timeout,
					      HCI_ROLE_SLAVE, 0, 0);
		else
			hcon = hci_connect_le_scan(hdev, dst, dst_type,
						   chan->sec_level, timeout,
						   CONN_REASON_L2CAP_CHAN);
"""
    new = """		if (hci_dev_test_flag(hdev, HCI_ADVERTISING))
			hcon = hci_connect_le(hdev, dst, dst_type, false,
					      chan->sec_level, timeout,
					      HCI_ROLE_SLAVE, 0, 0);
		else
			/* dagu: GNOME Settings Pair/Connect. le_scan waits
			 * for another host adv report after setup-mode
			 * StopDiscovery; the device we just saw is gone and
			 * the row spinner never reaches LE Create Connection.
			 * Directed create_conn lets the controller listen.
			 */
			hcon = hci_connect_le(hdev, dst, dst_type, false,
					      chan->sec_level, timeout,
					      HCI_ROLE_MASTER, HCI_ADV_PHY_1M,
					      HCI_ADV_PHY_2M);
"""
    if old not in text:
        raise SystemExit(f"{path}: L2CAP LE connect-scan branch not found")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/net/bluetooth/hci_sync.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: GNOME Settings Pair/Connect while the bluetooth page is"
if marker not in text:
    old = """	/* If controller is scanning, we stop it since some controllers are
	 * not able to scan and connect at the same time. Also set the
	 * HCI_LE_SCAN_INTERRUPTED flag so that the command complete
	 * handler for scan disabling knows to set the correct discovery
	 * state.
	 */
	if (hci_dev_test_flag(hdev, HCI_LE_SCAN)) {
		hci_dev_set_flag(hdev, HCI_LE_SCAN_INTERRUPTED);
		hci_scan_disable_sync(hdev);
	}
"""
    new = """	/* dagu: GNOME Settings Pair/Connect while the bluetooth page is
	 * still discovering. QCA6390 is TDD — Inquiry and LE Create
	 * Connection cannot share the radio. ACL create_conn already
	 * cancels Inquiry; LE did not, so StartDiscovery's Inquiry
	 * cancelled the initiator (le-connection-abort-by-local) and
	 * the 未设置 row spun until GDBus timed out.
	 */
	if (test_bit(HCI_INQUIRY, &hdev->flags)) {
		int ierr = __hci_cmd_sync_status(hdev, HCI_OP_INQUIRY_CANCEL,
						 0, NULL, HCI_CMD_TIMEOUT);
		if (ierr)
			bt_dev_warn(hdev, "Failed to cancel inquiry %d", ierr);
		hci_discovery_set_state(hdev, DISCOVERY_STOPPED);
	}

	/* If controller is scanning, we stop it since some controllers are
	 * not able to scan and connect at the same time. Also set the
	 * HCI_LE_SCAN_INTERRUPTED flag so that the command complete
	 * handler for scan disabling knows to set the correct discovery
	 * state.
	 */
	if (hci_dev_test_flag(hdev, HCI_LE_SCAN)) {
		hci_dev_set_flag(hdev, HCI_LE_SCAN_INTERRUPTED);
		hci_scan_disable_sync(hdev);
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: LE create-conn scan-disable block not found")
    text = text.replace(old, new, 1)
    print(f"patched {path}: {marker}")

marker2 = "dagu: same rule as hci_update_passive_scan_sync"
if marker2 not in text:
    old = """int hci_start_discovery_sync(struct hci_dev *hdev)
{
	unsigned long timeout;
	int err;

	bt_dev_dbg(hdev, "type %u", hdev->discovery.type);
"""
    new = """int hci_start_discovery_sync(struct hci_dev *hdev)
{
	unsigned long timeout;
	int err;

	/* dagu: same rule as hci_update_passive_scan_sync. QCA6390
	 * cannot scan or Inquiry while LE Create Connection is in
	 * flight; GNOME Settings queues StartDiscovery behind Pair.
	 */
	if (hci_lookup_le_connect(hdev))
		return -EBUSY;

	bt_dev_dbg(hdev, "type %u", hdev->discovery.type);
"""
    if old not in text:
        raise SystemExit(f"{path}: hci_start_discovery_sync prologue not found")
    text = text.replace(old, new, 1)
    print(f"patched {path}: {marker2}")

marker3 = "dagu: hci_connect_le(..., 0, 0) left Initiating PHYs=0"
if marker3 not in text:
    old = """	if (scan_coded(hdev) && (conn->le_adv_phy == HCI_ADV_PHY_CODED ||
				 conn->le_adv_sec_phy == HCI_ADV_PHY_CODED)) {
		cp->phys |= LE_SCAN_PHY_CODED;
		set_ext_conn_params(conn, p);

		plen += sizeof(*p);
	}

	return __hci_cmd_sync_status_sk(hdev, HCI_OP_LE_EXT_CREATE_CONN,
"""
    new = """	if (scan_coded(hdev) && (conn->le_adv_phy == HCI_ADV_PHY_CODED ||
				 conn->le_adv_sec_phy == HCI_ADV_PHY_CODED)) {
		cp->phys |= LE_SCAN_PHY_CODED;
		set_ext_conn_params(conn, p);

		plen += sizeof(*p);
	}

	/* dagu: hci_connect_le(..., 0, 0) left Initiating PHYs=0.
	 * QCA6390 Command Status 0x11 (Unsupported Feature or
	 * Parameter); BlueZ maps it to le-connection-abort-by-local
	 * and the GNOME 未设置 row spins until GDBus times out.
	 */
	if (!cp->phys) {
		cp->phys |= LE_SCAN_PHY_1M;
		set_ext_conn_params(conn, p);
		plen += sizeof(*p);
	}

	return __hci_cmd_sync_status_sk(hdev, HCI_OP_LE_EXT_CREATE_CONN,
"""
    if old not in text:
        raise SystemExit(f"{path}: ext create conn phys block not found")
    text = text.replace(old, new, 1)
    print(f"patched {path}: {marker3}")

path.write_text(text)
PY

python3 - "$KERNEL_SRC/drivers/bluetooth/hci_qca.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: GNOME Settings dual-mode StartDiscovery"
if marker not in text:
    old = """	/* Enable controller to do both LE scan and BR/EDR inquiry
	 * simultaneously.
	 */
	hci_set_quirk(hdev, HCI_QUIRK_SIMULTANEOUS_DISCOVERY);
"""
    new = """	/* dagu: GNOME Settings dual-mode StartDiscovery. QCA6390/ROME is
	 * TDD and shares the radio with LE HID; HCI_QUIRK_SIMULTANEOUS_DISCOVERY
	 * runs LE scan + Inquiry at once and starves BR FHS, so K380 appears
	 * then vanishes from the panel. Leave the quirk unset so the host
	 * time-slices LE scan then Inquiry (Android does this). Do not kill
	 * gnome-control-center; do not set ControllerMode=bredr.
	 */
	if (soc_type != QCA_ROME && soc_type != QCA_QCA6390)
		hci_set_quirk(hdev, HCI_QUIRK_SIMULTANEOUS_DISCOVERY);
"""
    if old not in text:
        raise SystemExit(f"{path}: SIMULTANEOUS_DISCOVERY block not found")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/drivers/soc/qcom/qcom-geni-se.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: SE firmware-name before wrapper"
if marker not in text:
    old = """\tret = device_property_read_string(se->wrapper->dev, "firmware-name", &fw_name);
\tif (ret) {
\t\tdev_err(se->dev, "Failed to read firmware-name property: %d\\n", ret);
\t\treturn -EINVAL;
\t}
"""
    new = """\t/* dagu: SE firmware-name before wrapper — never put firmware-name on qupv3_id_0 */
\tret = device_property_read_string(se->dev, "firmware-name", &fw_name);
\tif (ret)
\t\tret = device_property_read_string(se->wrapper->dev, "firmware-name", &fw_name);
\tif (ret) {
\t\tdev_err(se->dev, "Failed to read firmware-name property: %d\\n", ret);
\t\treturn -EINVAL;
\t}
"""
    if old not in text:
        raise SystemExit(f"{path}: firmware-name lookup not found")
    text = text.replace(old, new, 1)

marker2 = "dagu: skip QUPV3 wrapper CSRs while loading SE RAM"
if marker2 not in text:
    old = """\t/*
\t * Disable high-priority interrupts until all currently executing
\t * low-priority interrupts have been fully handled.
\t */
\tgeni_setbits32(se->wrapper->base + QUPV3_COMMON_CFG, FAST_SWITCH_TO_HIGH_DISABLE);

\t/* Set AHB_M_CLK_CGC_ON to indicate hardware controls se-wrapper cgc clock. */
\tgeni_setbits32(se->wrapper->base + QUPV3_SE_AHB_M_CFG, AHB_M_CLK_CGC_ON);

\t/* Let hardware to control common cgc. */
\tgeni_setbits32(se->wrapper->base + QUPV3_COMMON_CGC_CTRL, COMMON_CSR_SLV_CLK_CGC_ON);
"""
    new = """\t/*
\t * dagu: skip QUPV3 wrapper CSRs while loading SE RAM.
\t * Writing QUPV3_COMMON_CFG / AHB_M_CFG on this QHEE bounced to the
\t * bootloader. ABL already configured the wrapper; only program this SE.
\t */
\tif (!of_property_read_bool(se->dev->of_node, "qcom,skip-wrapper-fw-init")) {
\t\tgeni_setbits32(se->wrapper->base + QUPV3_COMMON_CFG,
\t\t\t       FAST_SWITCH_TO_HIGH_DISABLE);
\t\tgeni_setbits32(se->wrapper->base + QUPV3_SE_AHB_M_CFG, AHB_M_CLK_CGC_ON);
\t\tgeni_setbits32(se->wrapper->base + QUPV3_COMMON_CGC_CTRL,
\t\t\t       COMMON_CSR_SLV_CLK_CGC_ON);
\t}
"""
    if old not in text:
        raise SystemExit(f"{path}: wrapper CSR block not found")
    text = text.replace(old, new, 1)

path.write_text(text)
print(f"patched {path}: geni SE firmware-name + skip wrapper CSRs")
PY

python3 - "$KERNEL_SRC/drivers/i2c/busses/i2c-qcom-geni.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: load I2C QUPFW from this SE"
if marker in text:
    raise SystemExit(0)
load = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\t/* dagu: load I2C QUPFW from this SE firmware-name, never the wrapper */
\t\tret = geni_load_se_firmware(&gi2c->se, GENI_SE_I2C);
\t\tif (ret) {
\t\t\tdev_err_probe(dev, ret, "i2c firmware load failed ret: %d\\n", ret);
\t\t\tgoto err_resources;
\t\t}
\t} else if (proto != GENI_SE_I2C) {
"""
eop = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\t/* dagu: I2C proto invalid, not loading QUPFW on this QHEE */
\t\tdev_err_probe(dev, -EOPNOTSUPP,
\t\t\t      "I2C proto invalid, not loading QUPFW on this QHEE\\n");
\t\tret = -EOPNOTSUPP;
\t\tgoto err_resources;
\t} else if (proto != GENI_SE_I2C) {
"""
upstream = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\tret = geni_load_se_firmware(&gi2c->se, GENI_SE_I2C);
\t\tif (ret) {
\t\t\tdev_err_probe(dev, ret, "i2c firmware load failed ret: %d\\n", ret);
\t\t\tgoto err_resources;
\t\t}
\t} else if (proto != GENI_SE_I2C) {
"""
if eop in text:
    text = text.replace(eop, load, 1)
elif upstream in text:
    text = text.replace(upstream, load, 1)
else:
    raise SystemExit(f"{path}: I2C firmware-load block not found")
path.write_text(text)
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/drivers/i2c/busses/i2c-qcom-geni.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: drain GENI RX FIFO leftover"
if marker in text:
    raise SystemExit(0)
old = """static void geni_i2c_rx_fsm_rst(struct geni_i2c_dev *gi2c)
{
	u32 val;
	unsigned long time_left = RST_TIMEOUT;

	writel_relaxed(1, gi2c->se.base + SE_DMA_RX_FSM_RST);
"""
new = """/* CAF QUP zeros unused RX FIFO words. GENI leaves the previous
 * envelope. A GPIO bounce then reads leftover as a new packet
 * (folio Nanosic ghost empty 0x05 KEY_UP). Drain this SE FIFO.
 * Per-SE RX register, not QUPV3 wrapper CSR.
 */
static void geni_i2c_drain_rx_fifo(struct geni_i2c_dev *gi2c)
{
	void __iomem *base = gi2c->se.base;
	u32 rxcnt, i;

	rxcnt = readl_relaxed(base + SE_GENI_RX_FIFO_STATUS) & RX_FIFO_WC_MSK;
	if (rxcnt > 64)
		rxcnt = 64;
	for (i = 0; i < rxcnt; i++)
		readl_relaxed(base + SE_GENI_RX_FIFOn);
}

static void geni_i2c_rx_fsm_rst(struct geni_i2c_dev *gi2c)
{
	u32 val;
	unsigned long time_left = RST_TIMEOUT;

	writel_relaxed(1, gi2c->se.base + SE_DMA_RX_FSM_RST);
"""
if old not in text:
    raise SystemExit(f"{path}: rx_fsm_rst not found")
text = text.replace(old, new, 1)
old = """	if (dma_buf)
		geni_se_select_mode(se, GENI_SE_DMA);
	else
		geni_se_select_mode(se, GENI_SE_FIFO);

	writel_relaxed(len, se->base + SE_I2C_RX_TRANS_LEN);
	geni_se_setup_m_cmd(se, I2C_READ, m_param);
"""
new = """	if (dma_buf)
		geni_se_select_mode(se, GENI_SE_DMA);
	else
		geni_se_select_mode(se, GENI_SE_FIFO);

	if (!dma_buf)
		geni_i2c_drain_rx_fifo(gi2c);

	writel_relaxed(len, se->base + SE_I2C_RX_TRANS_LEN);
	geni_se_setup_m_cmd(se, I2C_READ, m_param);
"""
if old not in text:
    raise SystemExit(f"{path}: rx_one_msg FIFO select not found")
text = text.replace(old, new, 1)
old = """	if (!time_left)
		geni_i2c_abort_xfer(gi2c);

	geni_i2c_rx_msg_cleanup(gi2c, cur);

	return gi2c->err;
}
"""
new = """	if (!time_left)
		geni_i2c_abort_xfer(gi2c);

	if (!dma_buf)
		geni_i2c_drain_rx_fifo(gi2c);

	geni_i2c_rx_msg_cleanup(gi2c, cur);

	return gi2c->err;
}
"""
if old not in text:
    raise SystemExit(f"{path}: rx_one_msg cleanup not found")
text = text.replace(old, new, 1)
path.write_text(text)
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/drivers/spi/spi-geni-qcom.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: load SPI QUPFW from this SE"
if marker in text:
    raise SystemExit(0)
old = """\t} else if (proto == GENI_SE_INVALID_PROTO) {
\t\tret = geni_load_se_firmware(se, GENI_SE_SPI);
\t\tif (ret) {
\t\t\tdev_err(mas->dev, "spi master firmware load failed ret: %d\\n", ret);
\t\t\tgoto out_pm;
\t\t}
"""
new = """\t} else if (proto == GENI_SE_INVALID_PROTO) {
\t\t/* dagu: load SPI QUPFW from this SE firmware-name, never the wrapper */
\t\tret = geni_load_se_firmware(se, GENI_SE_SPI);
\t\tif (ret) {
\t\t\tdev_err(mas->dev, "spi master firmware load failed ret: %d\\n", ret);
\t\t\tgoto out_pm;
\t\t}
"""
if old not in text:
    raise SystemExit(f"{path}: SPI firmware-load block not found")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/drivers/spi/spi-geni-qcom.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: SPI FIFO only, never SE DMA or GPI"
if marker in text:
    raise SystemExit(0)
old = """static bool geni_can_dma(struct spi_controller *ctlr,
			 struct spi_device *slv, struct spi_transfer *xfer)
{
	struct spi_geni_master *mas = spi_controller_get_devdata(slv->controller);
	u32 len, fifo_size;

	if (mas->cur_xfer_mode == GENI_GPI_DMA)
		return true;

	/* Set SE DMA mode for SPI target. */
	if (ctlr->target)
		return true;

	len = get_xfer_len_in_words(xfer, mas);
	fifo_size = mas->tx_fifo_depth * mas->fifo_width_bits / xfer->bits_per_word;

	if (len > fifo_size)
		return true;
	else
		return false;
}
"""
new = """static bool geni_can_dma(struct spi_controller *ctlr,
			 struct spi_device *slv, struct spi_transfer *xfer)
{
	/* dagu: SPI FIFO only, never SE DMA or GPI — another MMIO surface
	 * on this QHEE. Himax 56-byte frames fit FIFO watermark IRQs.
	 */
	return false;
}
"""
if old not in text:
    raise SystemExit(f"{path}: geni_can_dma block not found")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/drivers/spi/spi-geni-qcom.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu SPI FIFO proto"
want = """		dev_info(mas->dev,
			 "dagu SPI FIFO proto=%u depth=%u width=%u fifo_if_dis=%u skip_wrap=%d\\n",
			 geni_se_read_proto(se), mas->tx_fifo_depth, mas->fifo_width_bits, fifo_disable,
			 device_property_read_bool(mas->dev, "qcom,skip-wrapper-fw-init"));
"""
if want in text:
    raise SystemExit(0)
stale = """		dev_info(mas->dev,
			 "dagu SPI FIFO proto=%u depth=%u width=%u fifo_if_dis=%u skip_wrap=%d\\n",
			 proto, mas->tx_fifo_depth, mas->fifo_width_bits, fifo_disable,
			 device_property_read_bool(mas->dev, "qcom,skip-wrapper-fw-init"));
"""
if stale in text:
    path.write_text(text.replace(stale, want, 1))
    print(f"patched {path}: {marker} (re-read proto after SE firmware)")
    raise SystemExit(0)
old = """	case 0:
		mas->cur_xfer_mode = GENI_SE_FIFO;
		geni_se_select_mode(se, GENI_SE_FIFO);
		/* setup_fifo_params assumes that these registers start with a zero value */
		writel(0, se->base + SE_SPI_LOOPBACK);
"""
new = """	case 0:
		mas->cur_xfer_mode = GENI_SE_FIFO;
		geni_se_select_mode(se, GENI_SE_FIFO);
		dev_info(mas->dev,
			 "dagu SPI FIFO proto=%u depth=%u width=%u fifo_if_dis=%u skip_wrap=%d\\n",
			 geni_se_read_proto(se), mas->tx_fifo_depth, mas->fifo_width_bits, fifo_disable,
			 device_property_read_bool(mas->dev, "qcom,skip-wrapper-fw-init"));
		/* setup_fifo_params assumes that these registers start with a zero value */
		writel(0, se->base + SE_SPI_LOOPBACK);
"""
if old not in text:
    raise SystemExit(f"{path}: SPI FIFO select block not found")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/drivers/gpu/drm/drm_fb_helper.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: skip fbdev vblank wait"
if marker in text:
    raise SystemExit(0)
needle = "\tdrm_client_modeset_wait_for_vblank(&helper->client, 0);\n"
repl = (
    "\t/* dagu: skip fbdev vblank wait — DPU INTF vsync is not raising "
    "drm vblank, so this 1s wait WARNs into fbcon and retriggers damage. */\n"
)
if needle not in text:
    raise SystemExit(f"{path}: vblank wait needle missing")
# DPU INTF vsync never raises drm vblank; skip every helper wait.
text = text.replace(needle, repl)
path.write_text(text)
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
hdr = root / "drivers/gpu/drm/msm/msm_drv.h"
src = root / "drivers/gpu/drm/msm/msm_drv.c"
decl = "void msm_gpu_resources_sysfs_init(struct device *dev);\n"
ht = hdr.read_text()
if "msm_gpu_resources_sysfs_init" not in ht:
    needle = "bool msm_gpu_no_components(void);\n"
    if needle not in ht:
        raise SystemExit(f"{hdr}: msm_gpu_no_components needle missing")
    hdr.write_text(ht.replace(needle, needle + "\n" + decl, 1))
    print(f"patched {hdr}: msm_gpu_resources_sysfs_init")
st = src.read_text()
if "msm_gpu_resources_sysfs_init" not in st:
    needle = "\tif (priv->kms_init)\n\t\tmsm_drm_kms_post_init(dev);\n\n\treturn 0;\n"
    repl = (
        "\tif (priv->kms_init)\n"
        "\t\tmsm_drm_kms_post_init(dev);\n\n"
        "\tmsm_gpu_resources_sysfs_init(dev);\n\n"
        "\treturn 0;\n"
    )
    if needle not in st:
        raise SystemExit(f"{src}: msm_drm_kms_post_init needle missing")
    src.write_text(st.replace(needle, repl, 1))
    print(f"patched {src}: msm_gpu_resources_sysfs_init")
PY

python3 - "$KERNEL_SRC/drivers/gpu/drm/msm/disp/dpu1/dpu_plane.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
# Linear-only scanout dropped SSPP multirect (800+800). Dual LM then
# flickered. Keep UBWC so DPU splits the 1600-wide plane again.
old_linear_only = """static const uint64_t supported_format_modifiers[] = {
	/* dagu: skip UBWC scanout — 1600x2560 XR30 compressed plus
	 * FB_DAMAGE_CLIPS leaves RGB noise in scrolled GTK regions
	 * (no SM8250 ICC, dual-DSI SSPP multirect on one pipe). */
	DRM_FORMAT_MOD_LINEAR,
	DRM_FORMAT_MOD_INVALID
};
"""
restored = """static const uint64_t supported_format_modifiers[] = {
	DRM_FORMAT_MOD_QCOM_COMPRESSED,
	DRM_FORMAT_MOD_LINEAR,
	DRM_FORMAT_MOD_INVALID
};
"""
if old_linear_only in text:
    text = text.replace(old_linear_only, restored, 1)
    print(f"restored UBWC modifiers on {path}")
marker = "dagu: skip FB_DAMAGE_CLIPS"
if marker not in text:
    needle = "\tdrm_plane_enable_fb_damage_clips(plane);\n"
    repl = (
        "\t/* dagu: skip FB_DAMAGE_CLIPS — partial KMS updates of UBWC "
        "XR30 leave RGB noise in scrolled GTK regions. Full frames OK. */\n"
    )
    if needle not in text:
        raise SystemExit(f"{path}: FB_DAMAGE_CLIPS needle missing")
    text = text.replace(needle, repl, 1)
    print(f"patched {path}: {marker}")
marker = "dagu: skip same-SSPP smart-DMA parallel"
if marker not in text:
    old_para = """	if (drm_rect_width(&r_pipe_cfg->src_rect) != 0) {
		if (!dpu_plane_is_multirect_parallel_capable(pipe->sspp, pipe_cfg, fmt, max_linewidth) ||
		    !dpu_plane_is_multirect_parallel_capable(pipe->sspp, r_pipe_cfg, fmt, max_linewidth))
			return false;

		r_pipe->sspp = pipe->sspp;

		pipe->multirect_index = DPU_SSPP_RECT_0;
		pipe->multirect_mode = DPU_SSPP_MULTIRECT_PARALLEL;

		r_pipe->multirect_index = DPU_SSPP_RECT_1;
		r_pipe->multirect_mode = DPU_SSPP_MULTIRECT_PARALLEL;
	}
"""
    new_para = """	if (drm_rect_width(&r_pipe_cfg->src_rect) != 0) {
		/* dagu: skip same-SSPP smart-DMA parallel — 1600x2560@120
		 * needs 526 Mpix/s through one Xin; MDP max is 460 MHz.
		 * Virtual RM will pick a second SSPP. */
		return false;
	}
"""
    if old_para not in text:
        raise SystemExit(f"{path}: try_multirect_parallel body missing")
    text = text.replace(old_para, new_para, 1)
    print(f"patched {path}: {marker}")
marker = "dagu: skip 10bpc XR30"
if marker not in text:
    old10 = "\tDRM_FORMAT_ARGB2101010,\n\tDRM_FORMAT_XRGB2101010,\n"
    new10 = "\t/* dagu: skip 10bpc XR30 — L81A DSC is 8bpc; mutter XR30 snows. */\n"
    if old10 not in text:
        raise SystemExit(f"{path}: 10bpc format needle missing")
    text = text.replace(old10, new10)
    print(f"patched {path}: {marker}")
path.write_text(text)
PY

python3 - "$KERNEL_SRC/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_catalog.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: skip 10bpc XR30"
if marker not in text:
    old = "\tDRM_FORMAT_ARGB2101010,\n\tDRM_FORMAT_XRGB2101010,\n"
    new = "\t/* dagu: skip 10bpc XR30 — L81A DSC is 8bpc; mutter XR30 snows. */\n"
    if text.count(old) < 1:
        raise SystemExit(f"{path}: 10bpc format needle missing")
    text = text.replace(old, new)
    path.write_text(text)
    print(f"patched {path}: {marker} ({text.count(marker)} sites)")
PY

python3 - "$KERNEL_SRC/drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: two SSPPs for 1600@120 split"
if marker not in text:
    old = "bool dpu_use_virtual_planes;\nmodule_param(dpu_use_virtual_planes, bool, 0);\n"
    new = (
        "bool dpu_use_virtual_planes = true; "
        "/* dagu: two SSPPs for 1600@120 split */\n"
        "module_param(dpu_use_virtual_planes, bool, 0);\n"
    )
    if old not in text:
        raise SystemExit(f"{path}: dpu_use_virtual_planes needle missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

# CS35L41 PUP_DONE waits for ASP clocks; Q6 AFE starts those at trigger,
# after DAPM PRE_PMU, so the 100ms poll always times out on this board.
path = root / "sound/soc/codecs/cs35l41-lib.c"
text = path.read_text()
marker = "dagu: CS35L41 PUP timeout is non-fatal"
if marker not in text:
    old = """		if (ret)
			dev_err(dev, "Enable(%d) failed: %d\\n", enable, ret);
"""
    new = """		if (ret) {
			/* dagu: CS35L41 PUP timeout is non-fatal */
			dev_warn(dev, "Enable(%d) timed out (%d); clocks may arrive at trigger\\n",
				 enable, ret);
			if (enable)
				ret = 0;
		}
"""
    if old not in text:
        raise SystemExit(f"{path}: Enable timeout needle missing")
    path.write_text(text.replace(old, new))
    print(f"patched {path}: {marker}")

# POST_PMD runs after TDM clocks drop; PDN_DONE never arrives (-110).
# Returning the timeout makes ASoC log "Main AMP event failed" four times
# per PipeWire idle. Same clocks-at-trigger case as PUP — ignore it.
path = root / "sound/soc/codecs/cs35l41-lib.c"
text = path.read_text()
marker = "dagu: CS35L41 PMD timeout is non-fatal"
if marker not in text:
    old = """			/* dagu: CS35L41 PUP timeout is non-fatal */
			dev_warn(dev, "Enable(%d) timed out (%d); clocks may arrive at trigger\\n",
				 enable, ret);
			if (enable)
				ret = 0;
"""
    new = """			/* dagu: CS35L41 PUP timeout is non-fatal */
			/* dagu: CS35L41 PMD timeout is non-fatal */
			dev_warn(dev, "Enable(%d) timed out (%d); clocks may arrive at trigger\\n",
				 enable, ret);
			ret = 0;
"""
    if old not in text:
        raise SystemExit(f"{path}: PMD timeout needle missing")
    path.write_text(text.replace(old, new))
    print(f"patched {path}: {marker}")

# Halo Protection firmware treats missing ReDC as uncalibrated and limits
# output. Xiaomi persist has factory cal_r; wm_adsp marks CAL_R SYS so ALSA
# cannot write it. Poke the XM registers after wmfw+bin preload.
path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: apply persist ReDC after DSP preload"
if marker not in text:
    old = """static int cs35l41_dsp_preload_ev(struct snd_soc_dapm_widget *w,
				  struct snd_kcontrol *kcontrol, int event)
{
	struct snd_soc_component *component = snd_soc_dapm_to_component(w->dapm);
	struct cs35l41_private *cs35l41 = snd_soc_component_get_drvdata(component);
	int ret;

	switch (event) {
	case SND_SOC_DAPM_PRE_PMU:
		if (cs35l41->dsp.cs_dsp.booted)
			return 0;

		return wm_adsp_early_event(w, kcontrol, event);
"""
    new = """static void cs35l41_dagu_apply_spk_cal(struct cs35l41_private *cs35l41)
{
	u32 cal_r, ambient = 23, vpbr;
	int ret;

	/* dagu: apply persist ReDC after DSP preload */
	if (device_property_read_u32(cs35l41->dev, "cirrus,cal-r", &cal_r))
		return;
	device_property_read_u32(cs35l41->dev, "cirrus,cal-ambient", &ambient);

	if (!device_property_read_u32(cs35l41->dev, "cirrus,vpbr-config", &vpbr)) {
		ret = regmap_write(cs35l41->regmap, CS35L41_VPBR_CFG, vpbr);
		if (ret)
			dev_warn(cs35l41->dev, "dagu: VPBR_CFG write failed: %d\\n", ret);
	}

	ret = 0;
	ret |= regmap_write(cs35l41->regmap, 0x0280026c, ambient);
	ret |= regmap_write(cs35l41->regmap, 0x02800268, cal_r);
	ret |= regmap_write(cs35l41->regmap, 0x02800270, 1);
	ret |= regmap_write(cs35l41->regmap, 0x02800274, cal_r + 1);
	if (ret)
		dev_warn(cs35l41->dev, "dagu: CAL_R=%u write failed: %d\\n", cal_r, ret);
	else
		dev_info(cs35l41->dev, "dagu: applied CAL_R=%u ambient=%u\\n",
			 cal_r, ambient);
}

static int cs35l41_dsp_preload_ev(struct snd_soc_dapm_widget *w,
				  struct snd_kcontrol *kcontrol, int event)
{
	struct snd_soc_component *component = snd_soc_dapm_to_component(w->dapm);
	struct cs35l41_private *cs35l41 = snd_soc_component_get_drvdata(component);
	int ret;

	switch (event) {
	case SND_SOC_DAPM_PRE_PMU:
		if (cs35l41->dsp.cs_dsp.booted)
			return 0;

		ret = wm_adsp_early_event(w, kcontrol, event);
		if (ret)
			return ret;
		cs35l41_dagu_apply_spk_cal(cs35l41);
		return 0;
"""
    if old not in text:
        raise SystemExit(f"{path}: dsp_preload_ev needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Already-applied kernels only wrote CAL_STATUS=1. Android tinymix
# Protection cd CAL_SET_STATUS is 2 and CAL_R_SELECTED equals CAL_R.
path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: Halo CAL_SET_STATUS=2"
if marker not in text:
    old = """	ret |= regmap_write(cs35l41->regmap, 0x02800268, cal_r);
	ret |= regmap_write(cs35l41->regmap, 0x02800270, 1);
	ret |= regmap_write(cs35l41->regmap, 0x02800274, cal_r + 1);
	if (ret)
		dev_warn(cs35l41->dev, "dagu: CAL_R=%u write failed: %d\\n", cal_r, ret);
	else
		dev_info(cs35l41->dev, "dagu: applied CAL_R=%u ambient=%u\\n",
			 cal_r, ambient);
"""
    new = """	ret |= regmap_write(cs35l41->regmap, 0x02800268, cal_r);
	ret |= regmap_write(cs35l41->regmap, 0x02800270, 1);
	ret |= regmap_write(cs35l41->regmap, 0x02800274, cal_r + 1);
	/* dagu: Halo CAL_SET_STATUS=2 */
	ret |= regmap_write(cs35l41->regmap, 0x02800278, cal_r);
	ret |= regmap_write(cs35l41->regmap, 0x0280027c, 2);
	if (ret)
		dev_warn(cs35l41->dev, "dagu: CAL_R=%u write failed: %d\\n", cal_r, ret);
	else
		dev_info(cs35l41->dev, "dagu: applied CAL_R=%u ambient=%u SET_STATUS=2\\n",
			 cal_r, ambient);
"""
    if old not in text:
        raise SystemExit(f"{path}: CAL_SET_STATUS upgrade needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Hibernate + i2c-gpio: wake -42 then NAK on i2c-20/21. DSP preload makes
# autosuspend enter hibernate after 3s idle. No-op runtime PM.
path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: skip CS35L41 hibernate on i2c-gpio"
if marker not in text:
    old = """static int cs35l41_runtime_suspend(struct device *dev)
{
	struct cs35l41_private *cs35l41 = dev_get_drvdata(dev);

	dev_dbg(cs35l41->dev, "Runtime suspend\\n");

	if (!cs35l41->dsp.preloaded || !cs35l41->dsp.cs_dsp.running)
		return 0;

	cs35l41_enter_hibernate(dev, cs35l41->regmap, cs35l41->hw_cfg.bst_type);

	regcache_cache_only(cs35l41->regmap, true);
	regcache_mark_dirty(cs35l41->regmap);

	return 0;
}
"""
    new = """static int cs35l41_runtime_suspend(struct device *dev)
{
	/* dagu: skip CS35L41 hibernate on i2c-gpio */
	return 0;
}
"""
    if old not in text:
        raise SystemExit(f"{path}: runtime_suspend needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: skip CS35L41 hibernate resume"
if marker not in text:
    old = """static int cs35l41_runtime_resume(struct device *dev)
{
	struct cs35l41_private *cs35l41 = dev_get_drvdata(dev);
	int ret;

	dev_dbg(cs35l41->dev, "Runtime resume\\n");

	if (!cs35l41->dsp.preloaded || !cs35l41->dsp.cs_dsp.running)
		return 0;

	regcache_cache_only(cs35l41->regmap, false);

	ret = cs35l41_exit_hibernate(cs35l41->dev, cs35l41->regmap);
	if (ret)
		return ret;

	/* Test key needs to be unlocked to allow the OTP settings to re-apply */
	cs35l41_test_key_unlock(cs35l41->dev, cs35l41->regmap);
	ret = regcache_sync(cs35l41->regmap);
	cs35l41_test_key_lock(cs35l41->dev, cs35l41->regmap);
	if (ret) {
		dev_err(cs35l41->dev, "Failed to restore register cache: %d\\n", ret);
		return ret;
	}
	cs35l41_init_boost(cs35l41->dev, cs35l41->regmap, &cs35l41->hw_cfg);

	return 0;
}
"""
    new = """static int cs35l41_runtime_resume(struct device *dev)
{
	/* dagu: skip CS35L41 hibernate resume */
	return 0;
}
"""
    if old not in text:
        raise SystemExit(f"{path}: runtime_resume needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Xiaomi Fast Use Case: mixer_paths leaves Fast Use Case Switch On and
# loads per-amp *-music.txt into Halo CSPL_UPDATE_PARAMS_CONFIG.
path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: CS35L41 Fast Use Case music.txt"
if marker not in text:
    old = """#include "cs35l41.h"
"""
    new = """#include "cs35l41.h"
#include <asm/byteorder.h>
#include <linux/slab.h>
"""
    if old not in text:
        raise SystemExit(f"{path}: cs35l41.h include needle missing")
    text = text.replace(old, new, 1)

    old = """static int cs35l41_dsp_audio_ev(struct snd_soc_dapm_widget *w,
				struct snd_kcontrol *kcontrol, int event)
{
"""
    new = """#define CS35L41_CSPL_ALG		0xcd
#define CS35L41_CSPL_CMD_UPDATE_PARAM	8
#define CS35L41_CSPL_ST_RUNNING		0
#define CS35L41_FAST_SWITCH_BUF		64

static int cs35l41_csp_write(struct wm_adsp *dsp, const char *name,
			     void *buf, size_t len)
{
	static const int types[] = {
		WMFW_ADSP2_YM, WMFW_ADSP2_XM,
		WMFW_HALO_YM_PACKED, WMFW_HALO_XM_PACKED,
	};
	int i, ret = -ENOENT;

	for (i = 0; i < ARRAY_SIZE(types); i++) {
		ret = wm_adsp_write_ctl(dsp, name, types[i], CS35L41_CSPL_ALG,
					buf, len);
		if (!ret)
			return 0;
	}
	return ret;
}

static int cs35l41_csp_read(struct wm_adsp *dsp, const char *name,
			    void *buf, size_t len)
{
	static const int types[] = {
		WMFW_ADSP2_YM, WMFW_ADSP2_XM,
		WMFW_HALO_YM_PACKED, WMFW_HALO_XM_PACKED,
	};
	int i, ret = -ENOENT;

	for (i = 0; i < ARRAY_SIZE(types); i++) {
		ret = wm_adsp_read_ctl(dsp, name, types[i], CS35L41_CSPL_ALG,
				       buf, len);
		if (ret >= 0)
			return 0;
	}
	return ret;
}

/* CAF cs35l41_do_fast_switch: comma-separated s32 -> Halo UPDATE_PARAM. */
static int cs35l41_do_fast_switch(struct cs35l41_private *cs35l41)
{
	char val_str[CS35L41_FAST_SWITCH_BUF];
	const struct firmware *fw;
	const char *fw_name = cs35l41->fast_switch_name;
	__be32 *data_ctl_buf = NULL, cmd_ctl, st_ctl;
	s32 data_ctl_len, val;
	unsigned int i, j, k;
	int ret;
	bool fw_running = false;

	/* dagu: CS35L41 Fast Use Case music.txt */
	if (!fw_name)
		return 0;

	ret = request_firmware(&fw, fw_name, cs35l41->dev);
	if (ret) {
		dev_err(cs35l41->dev, "dagu: fast-switch firmware %s: %d\\n",
			fw_name, ret);
		return ret;
	}

	for (i = 0, j = 0; i < fw->size && (char)fw->data[i] != ','; i++) {
		if ((char)fw->data[i] == ' ' || (char)fw->data[i] == '\\n' ||
		    (char)fw->data[i] == '\\r' || (char)fw->data[i] == '\\t')
			continue;
		if (j >= CS35L41_FAST_SWITCH_BUF - 1) {
			ret = -EINVAL;
			goto exit;
		}
		val_str[j++] = fw->data[i];
	}
	if (i >= fw->size) {
		ret = -EINVAL;
		goto exit;
	}
	i++;
	val_str[j] = '\\0';
	ret = kstrtos32(val_str, 10, &data_ctl_len);
	if (ret || data_ctl_len < 1) {
		dev_err(cs35l41->dev, "dagu: fast-switch len %s: %d\\n",
			val_str, ret);
		ret = ret ? ret : -EINVAL;
		goto exit;
	}

	data_ctl_buf = kcalloc(data_ctl_len, sizeof(*data_ctl_buf), GFP_KERNEL);
	if (!data_ctl_buf) {
		ret = -ENOMEM;
		goto exit;
	}
	data_ctl_buf[0] = cpu_to_be32(data_ctl_len);

	for (j = 0, k = 1; i <= fw->size && k < (unsigned int)data_ctl_len; i++) {
		char c = (i == fw->size) ? ',' : (char)fw->data[i];

		if (c == ',' || i == fw->size) {
			if (!j)
				continue;
			val_str[j] = '\\0';
			ret = kstrtos32(val_str, 10, &val);
			if (ret) {
				dev_err(cs35l41->dev,
					"dagu: fast-switch parse %s: %d\\n",
					val_str, ret);
				goto exit;
			}
			data_ctl_buf[k++] = cpu_to_be32(val);
			j = 0;
		} else if (c == ' ' || c == '\\n' || c == '\\r' || c == '\\t') {
			continue;
		} else {
			if (j >= CS35L41_FAST_SWITCH_BUF - 1) {
				ret = -EINVAL;
				goto exit;
			}
			val_str[j++] = c;
		}
	}

	ret = cs35l41_csp_write(&cs35l41->dsp, "CSPL_UPDATE_PARAMS_CONFIG",
				data_ctl_buf, data_ctl_len * sizeof(__be32));
	if (ret) {
		dev_err(cs35l41->dev, "dagu: CSPL_UPDATE_PARAMS_CONFIG: %d\\n",
			ret);
		goto exit;
	}

	cmd_ctl = cpu_to_be32(CS35L41_CSPL_CMD_UPDATE_PARAM);
	ret = cs35l41_csp_write(&cs35l41->dsp, "CSPL_COMMAND", &cmd_ctl,
				sizeof(cmd_ctl));
	if (ret) {
		dev_err(cs35l41->dev, "dagu: CSPL_COMMAND UPDATE_PARAM: %d\\n",
			ret);
		goto exit;
	}

	for (i = 0; i < 5; i++) {
		ret = cs35l41_csp_read(&cs35l41->dsp, "CSPL_STATE", &st_ctl,
				       sizeof(st_ctl));
		if (!ret && be32_to_cpu(st_ctl) == CS35L41_CSPL_ST_RUNNING) {
			fw_running = true;
			break;
		}
		usleep_range(100, 110);
	}
	if (!fw_running) {
		dev_err(cs35l41->dev, "dagu: CSPL_STATE not RUNNING after fast-switch\\n");
		ret = -EIO;
		goto exit;
	}
	dev_info(cs35l41->dev, "dagu: fast-switch %s (%d words)\\n",
		 fw_name, data_ctl_len);
	ret = 0;
exit:
	kfree(data_ctl_buf);
	release_firmware(fw);
	return ret;
}

static int cs35l41_fast_switch_en_get(struct snd_kcontrol *kcontrol,
				      struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *component =
		snd_kcontrol_chip(kcontrol);
	struct cs35l41_private *cs35l41 =
		snd_soc_component_get_drvdata(component);

	ucontrol->value.integer.value[0] = cs35l41->fast_switch_en;
	return 0;
}

static int cs35l41_fast_switch_en_put(struct snd_kcontrol *kcontrol,
				      struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *component =
		snd_kcontrol_chip(kcontrol);
	struct cs35l41_private *cs35l41 =
		snd_soc_component_get_drvdata(component);
	int enable = !!ucontrol->value.integer.value[0];
	int ret = 0;

	if (enable && !cs35l41->fast_switch_en && cs35l41->dsp.cs_dsp.running)
		ret = cs35l41_do_fast_switch(cs35l41);
	cs35l41->fast_switch_en = enable;
	return ret;
}

static int cs35l41_dsp_audio_ev(struct snd_soc_dapm_widget *w,
				struct snd_kcontrol *kcontrol, int event)
{
"""
    if old not in text:
        raise SystemExit(f"{path}: dsp_audio_ev needle missing")
    text = text.replace(old, new, 1)

    old = """		return cs35l41_set_cspl_mbox_cmd(cs35l41->dev, cs35l41->regmap,
						 CSPL_MBOX_CMD_RESUME);
	case SND_SOC_DAPM_PRE_PMD:
"""
    new = """		ret = cs35l41_set_cspl_mbox_cmd(cs35l41->dev, cs35l41->regmap,
						CSPL_MBOX_CMD_RESUME);
		if (ret)
			return ret;
		if (cs35l41->fast_switch_en) {
			ret = cs35l41_do_fast_switch(cs35l41);
			if (ret)
				dev_err(cs35l41->dev,
					"dagu: fast-switch after RESUME: %d\\n",
					ret);
		}
		return 0;
	case SND_SOC_DAPM_PRE_PMD:
"""
    if old not in text:
        raise SystemExit(f"{path}: RESUME needle missing")
    text = text.replace(old, new, 1)

    old = """	WM_ADSP2_PRELOAD_SWITCH("DSP1", 1),
	WM_ADSP_FW_CONTROL("DSP1", 0),
};
"""
    new = """	WM_ADSP2_PRELOAD_SWITCH("DSP1", 1),
	WM_ADSP_FW_CONTROL("DSP1", 0),
	SOC_SINGLE_EXT("Fast Use Case Switch Enable", SND_SOC_NOPM, 0, 1, 0,
		       cs35l41_fast_switch_en_get, cs35l41_fast_switch_en_put),
};
"""
    if old not in text:
        raise SystemExit(f"{path}: aud_controls needle missing")
    text = text.replace(old, new, 1)

    old = """	if (hw_cfg) {
		cs35l41->hw_cfg = *hw_cfg;
	} else {
		ret = cs35l41_handle_pdata(cs35l41->dev, &cs35l41->hw_cfg);
		if (ret != 0)
			return ret;
	}
"""
    new = """	if (hw_cfg) {
		cs35l41->hw_cfg = *hw_cfg;
	} else {
		ret = cs35l41_handle_pdata(cs35l41->dev, &cs35l41->hw_cfg);
		if (ret != 0)
			return ret;
	}

	if (!device_property_read_string(cs35l41->dev, "cirrus,fast-switch",
					 &cs35l41->fast_switch_name))
		cs35l41->fast_switch_en = true;
"""
    if old not in text:
        raise SystemExit(f"{path}: probe pdata needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/codecs/cs35l41.h"
text = path.read_text()
marker = "dagu: CS35L41 fast-switch fields"
if marker not in text:
    old = """	struct gpio_desc *reset_gpio;
};
"""
    new = """	struct gpio_desc *reset_gpio;
	/* dagu: CS35L41 fast-switch fields */
	const char *fast_switch_name;
	bool fast_switch_en;
};
"""
    if old not in text:
        raise SystemExit(f"{path}: cs35l41_private needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: fast-switch after first DSP start"
if marker not in text and "mod_delayed_work(system_wq, &cs35l41->fast_switch_work" not in text:
    old = """		if (!cs35l41->dsp.cs_dsp.running)
			return wm_adsp_event(w, kcontrol, event);
"""
    new = """		if (!cs35l41->dsp.cs_dsp.running) {
			/* dagu: fast-switch after first DSP start */
			ret = wm_adsp_event(w, kcontrol, event);
			if (ret)
				return ret;
			if (cs35l41->fast_switch_en) {
				ret = cs35l41_do_fast_switch(cs35l41);
				if (ret)
					dev_err(cs35l41->dev,
						"dagu: fast-switch after DSP start: %d\\n",
						ret);
			}
			return 0;
		}
"""
    if old not in text:
        raise SystemExit(f"{path}: first DSP start needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: fast-switch uses snd_kcontrol_chip"
if marker not in text and "snd_soc_kcontrol_component" in text:
    text = text.replace("snd_soc_kcontrol_component", "snd_kcontrol_chip")
    text = text.replace(
        "static int cs35l41_fast_switch_en_get(struct snd_kcontrol *kcontrol,",
        "/* dagu: fast-switch uses snd_kcontrol_chip */\nstatic int cs35l41_fast_switch_en_get(struct snd_kcontrol *kcontrol,",
        1,
    )
    path.write_text(text)
    print(f"patched {path}: {marker}")

path = root / "sound/soc/codecs/cs35l41.h"
text = path.read_text()
marker = "dagu: fast-switch delayed_work"
if marker not in text:
    old = """	const char *fast_switch_name;
	bool fast_switch_en;
};
"""
    new = """	const char *fast_switch_name;
	bool fast_switch_en;
	/* dagu: fast-switch delayed_work */
	struct delayed_work fast_switch_work;
};
"""
    if old not in text:
        raise SystemExit(f"{path}: fast_switch_en field needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: fast-switch off DAPM"
if marker not in text:
    old = """	cs35l41->fast_switch_en = enable;
	return ret;
}

static int cs35l41_dsp_audio_ev(struct snd_soc_dapm_widget *w,
"""
    new = """	cs35l41->fast_switch_en = enable;
	return ret;
}

static void cs35l41_fast_switch_work(struct work_struct *work)
{
	struct cs35l41_private *cs35l41 =
		container_of(work, struct cs35l41_private, fast_switch_work.work);

	/* dagu: fast-switch off DAPM */
	if (!cs35l41->fast_switch_en || !cs35l41->dsp.cs_dsp.running)
		return;
	cs35l41_do_fast_switch(cs35l41);
}

static int cs35l41_dsp_audio_ev(struct snd_soc_dapm_widget *w,
"""
    if old not in text:
        raise SystemExit(f"{path}: fast_switch workfn needle missing")
    text = text.replace(old, new, 1)

    old = """		if (!cs35l41->dsp.cs_dsp.running) {
			/* dagu: fast-switch after first DSP start */
			ret = wm_adsp_event(w, kcontrol, event);
			if (ret)
				return ret;
			if (cs35l41->fast_switch_en) {
				ret = cs35l41_do_fast_switch(cs35l41);
				if (ret)
					dev_err(cs35l41->dev,
						"dagu: fast-switch after DSP start: %d\\n",
						ret);
			}
			return 0;
		}
"""
    new = """		if (!cs35l41->dsp.cs_dsp.running) {
			ret = wm_adsp_event(w, kcontrol, event);
			if (ret)
				return ret;
			if (cs35l41->fast_switch_en)
				mod_delayed_work(system_wq, &cs35l41->fast_switch_work,
						 msecs_to_jiffies(80));
			return 0;
		}
"""
    if old not in text:
        raise SystemExit(f"{path}: first-start defer needle missing")
    text = text.replace(old, new, 1)

    old = """		ret = cs35l41_set_cspl_mbox_cmd(cs35l41->dev, cs35l41->regmap,
						CSPL_MBOX_CMD_RESUME);
		if (ret)
			return ret;
		if (cs35l41->fast_switch_en) {
			ret = cs35l41_do_fast_switch(cs35l41);
			if (ret)
				dev_err(cs35l41->dev,
					"dagu: fast-switch after RESUME: %d\\n",
					ret);
		}
		return 0;
	case SND_SOC_DAPM_PRE_PMD:
		return cs35l41_set_cspl_mbox_cmd(cs35l41->dev, cs35l41->regmap,
						 CSPL_MBOX_CMD_PAUSE);
"""
    new = """		ret = cs35l41_set_cspl_mbox_cmd(cs35l41->dev, cs35l41->regmap,
						CSPL_MBOX_CMD_RESUME);
		if (ret)
			return ret;
		if (cs35l41->fast_switch_en)
			mod_delayed_work(system_wq, &cs35l41->fast_switch_work,
					 msecs_to_jiffies(80));
		return 0;
	case SND_SOC_DAPM_PRE_PMD:
		cancel_delayed_work_sync(&cs35l41->fast_switch_work);
		return cs35l41_set_cspl_mbox_cmd(cs35l41->dev, cs35l41->regmap,
						 CSPL_MBOX_CMD_PAUSE);
"""
    if old not in text:
        raise SystemExit(f"{path}: RESUME defer needle missing")
    text = text.replace(old, new, 1)

    old = """	if (!device_property_read_string(cs35l41->dev, "cirrus,fast-switch",
					 &cs35l41->fast_switch_name))
		cs35l41->fast_switch_en = true;
"""
    new = """	if (!device_property_read_string(cs35l41->dev, "cirrus,fast-switch",
					 &cs35l41->fast_switch_name))
		cs35l41->fast_switch_en = true;
	INIT_DELAYED_WORK(&cs35l41->fast_switch_work, cs35l41_fast_switch_work);
"""
    if old not in text:
        raise SystemExit(f"{path}: INIT_DELAYED_WORK needle missing")
    text = text.replace(old, new, 1)

    old = """void cs35l41_remove(struct cs35l41_private *cs35l41)
{
	pm_runtime_get_sync(cs35l41->dev);
"""
    new = """void cs35l41_remove(struct cs35l41_private *cs35l41)
{
	cancel_delayed_work_sync(&cs35l41->fast_switch_work);
	pm_runtime_get_sync(cs35l41->dev);
"""
    if old not in text:
        raise SystemExit(f"{path}: remove cancel needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Xiaomi DAGU CAF cs35l41_pcm_hw_params: S24_LE is 24-bit samples in 32-bit
# TDM slots (Q6 slot_width=32, 4 slots, 6.144 MHz). Mainline wrote
# params_width (24) into ASP_WIDTH_RX, so the chip framed 24-bit slots
# against 32-bit Q6 slots — 8 MSB zeros ≈ -48 dB at "full" volume.
path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: ASP_WIDTH is physical slot, RX_WL is sample"
if marker not in text:
    old = """	unsigned int rate = params_rate(params);
	u8 asp_wl;
	int i;
"""
    new = """	unsigned int rate = params_rate(params);
	u8 asp_wl, asp_width;
	int i;
"""
    if old not in text:
        raise SystemExit(f"{path}: asp_wl decl needle missing")
    text = text.replace(old, new, 1)

    old = """	asp_wl = params_width(params);

	regmap_update_bits(cs35l41->regmap, CS35L41_GLOBAL_CLK_CTRL,
			   CS35L41_GLOBAL_FS_MASK,
			   cs35l41_fs_rates[i].fs_cfg << CS35L41_GLOBAL_FS_SHIFT);

	if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK) {
		regmap_update_bits(cs35l41->regmap, CS35L41_SP_FORMAT,
				   CS35L41_ASP_WIDTH_RX_MASK,
				   asp_wl << CS35L41_ASP_WIDTH_RX_SHIFT);
		regmap_update_bits(cs35l41->regmap, CS35L41_SP_RX_WL,
				   CS35L41_ASP_RX_WL_MASK,
				   asp_wl << CS35L41_ASP_RX_WL_SHIFT);
	} else {
		regmap_update_bits(cs35l41->regmap, CS35L41_SP_FORMAT,
				   CS35L41_ASP_WIDTH_TX_MASK,
				   asp_wl << CS35L41_ASP_WIDTH_TX_SHIFT);
		regmap_update_bits(cs35l41->regmap, CS35L41_SP_TX_WL,
				   CS35L41_ASP_TX_WL_MASK,
				   asp_wl << CS35L41_ASP_TX_WL_SHIFT);
	}
"""
    new = """	asp_wl = params_width(params);
	/* dagu: ASP_WIDTH is physical slot, RX_WL is sample */
	asp_width = params_physical_width(params);

	regmap_update_bits(cs35l41->regmap, CS35L41_GLOBAL_CLK_CTRL,
			   CS35L41_GLOBAL_FS_MASK,
			   cs35l41_fs_rates[i].fs_cfg << CS35L41_GLOBAL_FS_SHIFT);

	if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK) {
		regmap_update_bits(cs35l41->regmap, CS35L41_SP_FORMAT,
				   CS35L41_ASP_WIDTH_RX_MASK,
				   asp_width << CS35L41_ASP_WIDTH_RX_SHIFT);
		regmap_update_bits(cs35l41->regmap, CS35L41_SP_RX_WL,
				   CS35L41_ASP_RX_WL_MASK,
				   asp_wl << CS35L41_ASP_RX_WL_SHIFT);
	} else {
		regmap_update_bits(cs35l41->regmap, CS35L41_SP_FORMAT,
				   CS35L41_ASP_WIDTH_TX_MASK,
				   asp_width << CS35L41_ASP_WIDTH_TX_SHIFT);
		regmap_update_bits(cs35l41->regmap, CS35L41_SP_TX_WL,
				   CS35L41_ASP_TX_WL_MASK,
				   asp_wl << CS35L41_ASP_TX_WL_SHIFT);
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: hw_params ASP_WIDTH needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Android mixer_paths: Boost Class-H Tracking Enable=1, Boost Target Voltage=0.
# BST_CTL_SEL bit0=Class-H; target 0 is ignored while tracking.
path = root / "sound/soc/codecs/cs35l41.c"
text = path.read_text()
marker = "dagu: Boost Class-H Tracking mixers"
if marker not in text:
    old = """	SOC_SINGLE_TLV("Analog PCM Volume", CS35L41_AMP_GAIN_CTRL, 5, 0x14, 0,
		       amp_gain_tlv),
"""
    new = """	SOC_SINGLE_TLV("Analog PCM Volume", CS35L41_AMP_GAIN_CTRL, 5, 0x14, 0,
		       amp_gain_tlv),
	/* dagu: Boost Class-H Tracking mixers */
	SOC_SINGLE("Boost Class-H Tracking Enable",
		   CS35L41_BSTCVRT_VCTRL2, 0, 1, 0),
	SOC_SINGLE("Boost Target Voltage", CS35L41_BSTCVRT_VCTRL1, 0, 0xAA, 0),
"""
    if old not in text:
        raise SystemExit(f"{path}: Analog PCM Volume needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/power/supply/bq27xxx_battery_i2c.c"
text = path.read_text()
marker = "dagu: wake sleeping BQ27Z561"
if marker not in text:
    old = """	do {
		ret = i2c_transfer(client->adapter, msg, ARRAY_SIZE(msg));
		if (ret == -EBUSY && ++retry < 3) {
			/* sleep 10 milliseconds when busy */
			usleep_range(10000, 11000);
			continue;
		}
		break;
	} while (1);
"""
    new = """	do {
		/* dagu: wake sleeping BQ27Z561 */
		ret = i2c_transfer(client->adapter, msg, ARRAY_SIZE(msg));
		if (ret < 0 && ++retry < 6) {
			usleep_range(2000, 4000);
			continue;
		}
		break;
	} while (1);
"""
    if old not in text:
        raise SystemExit(f"{path}: bq27xxx read retry needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/power/supply/bq27xxx_battery_i2c.c"
text = path.read_text()
marker = "dagu: retry BQ27Z561 I2C write"
if marker not in text:
    old = """	msg.buf = data;
	msg.addr = client->addr;
	msg.flags = 0;

	ret = i2c_transfer(client->adapter, &msg, 1);
	if (ret < 0)
		return ret;
"""
    new = """	msg.buf = data;
	msg.addr = client->addr;
	msg.flags = 0;

	{
		int retry = 0;

		/* dagu: retry BQ27Z561 I2C write */
		do {
			ret = i2c_transfer(client->adapter, &msg, 1);
			if (ret < 0 && ++retry < 6) {
				usleep_range(2000, 4000);
				continue;
			}
			break;
		} while (1);
	}
	if (ret < 0)
		return ret;
"""
    if old not in text:
        raise SystemExit(f"{path}: bq27xxx write retry needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/power/supply/bq27xxx_battery_i2c.c"
text = path.read_text()
marker = "dagu: retry BQ27Z561 I2C bulk_read"
if marker not in text:
    old = """	ret = i2c_smbus_read_i2c_block_data(client, reg, len, data);
	if (ret < 0)
		return ret;
"""
    new = """	{
		int retry = 0;

		/* dagu: retry BQ27Z561 I2C bulk_read */
		do {
			ret = i2c_smbus_read_i2c_block_data(client, reg, len, data);
			if (ret < 0 && ++retry < 6) {
				usleep_range(2000, 4000);
				continue;
			}
			break;
		} while (1);
	}
	if (ret < 0)
		return ret;
"""
    if old not in text:
        raise SystemExit(f"{path}: bq27xxx bulk_read retry needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/power/supply/bq27xxx_battery.c"
text = path.read_text()
marker = "dagu: pack-cell is not TYPE_BATTERY"
if marker not in text:
    old = """	psy_desc->name = di->name;
	psy_desc->type = POWER_SUPPLY_TYPE_BATTERY;
	psy_desc->properties = bq27xxx_chip_data[di->chip].props;
"""
    new = """	psy_desc->name = di->name;
	/* dagu: pack-cell is not TYPE_BATTERY */
	if (device_property_read_bool(di->dev, "xiaomi,pack-cell"))
		psy_desc->type = POWER_SUPPLY_TYPE_UNKNOWN;
	else
		psy_desc->type = POWER_SUPPLY_TYPE_BATTERY;
	psy_desc->properties = bq27xxx_chip_data[di->chip].props;
"""
    if old not in text:
        raise SystemExit(f"{path}: bq27xxx pack-cell needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/qcom/sm8250.c"
text = path.read_text()
marker = "dagu: set I2S fmt on every CS35L41"
if marker not in text:
    old = """	case TERTIARY_MI2S_RX:
		codec_dai_fmt |= SND_SOC_DAIFMT_NB_NF | SND_SOC_DAIFMT_I2S;
		snd_soc_dai_set_sysclk(cpu_dai,
			Q6AFE_LPASS_CLK_ID_TER_MI2S_IBIT,
			MI2S_BCLK_RATE, SNDRV_PCM_STREAM_PLAYBACK);
		snd_soc_dai_set_fmt(cpu_dai, fmt);
		snd_soc_dai_set_fmt(codec_dai, codec_dai_fmt);
		break;
"""
    new = """	case TERTIARY_MI2S_RX:
		codec_dai_fmt |= SND_SOC_DAIFMT_NB_NF | SND_SOC_DAIFMT_I2S;
		snd_soc_dai_set_sysclk(cpu_dai,
			Q6AFE_LPASS_CLK_ID_TER_MI2S_IBIT,
			MI2S_BCLK_RATE, SNDRV_PCM_STREAM_PLAYBACK);
		snd_soc_dai_set_fmt(cpu_dai, fmt);
		{
			int codec_i;
			/* dagu: set I2S fmt on every CS35L41 */
			for (codec_i = 0; codec_i < rtd->dai_link->num_codecs; codec_i++)
				snd_soc_dai_set_fmt(snd_soc_rtd_to_codec(rtd, codec_i),
						    codec_dai_fmt);
		}
		break;
"""
    if old not in text:
        raise SystemExit(f"{path}: TERTIARY_MI2S_RX needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# CAF kona.c CONFIG_MACH_XIAOMI_DAGU: TDM_MAX_SLOTS=4, 32-bit @ 48 kHz = 6.144 MHz.
# CS35L41 channels_max=2 so keep 2ch PCM; map all amps to ASPRX slots 0/1.
# AFE channel map uses BYTE offsets {0,4} (CAF tert_tdm_dev_config).
path = root / "sound/soc/qcom/sm8250.c"
text = path.read_text()
marker = "dagu: tertiary TDM for CS35L41"
if marker not in text:
    old = """#define MI2S_BCLK_RATE		1536000
"""
    new = """#define MI2S_BCLK_RATE		1536000
#define TDM_BCLK_RATE		6144000
#define TDM_SLOTS		4
#define TDM_SLOT_WIDTH		32
"""
    if old not in text:
        raise SystemExit(f"{path}: MI2S_BCLK_RATE needle missing")
    text = text.replace(old, new, 1)

    old = """	case QUINARY_MI2S_RX:
		codec_dai_fmt |= SND_SOC_DAIFMT_NB_NF | SND_SOC_DAIFMT_I2S;
		snd_soc_dai_set_sysclk(cpu_dai,
			Q6AFE_LPASS_CLK_ID_QUI_MI2S_IBIT,
			MI2S_BCLK_RATE, SNDRV_PCM_STREAM_PLAYBACK);
		snd_soc_dai_set_fmt(cpu_dai, fmt);
		snd_soc_dai_set_fmt(codec_dai, codec_dai_fmt);
		break;
	default:
		break;
"""
    new = """	case QUINARY_MI2S_RX:
		codec_dai_fmt |= SND_SOC_DAIFMT_NB_NF | SND_SOC_DAIFMT_I2S;
		snd_soc_dai_set_sysclk(cpu_dai,
			Q6AFE_LPASS_CLK_ID_QUI_MI2S_IBIT,
			MI2S_BCLK_RATE, SNDRV_PCM_STREAM_PLAYBACK);
		snd_soc_dai_set_fmt(cpu_dai, fmt);
		snd_soc_dai_set_fmt(codec_dai, codec_dai_fmt);
		break;
	case TERTIARY_TDM_RX_0: {
		/* dagu: tertiary TDM for CS35L41 */
		static const unsigned int cpu_rx_slots[] = { 0, 4 };
		static const unsigned int amp_rx_slots[][2] = {
			{ 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 },
		};
		int codec_i;

		codec_dai_fmt |= SND_SOC_DAIFMT_NB_NF | SND_SOC_DAIFMT_DSP_A;
		snd_soc_dai_set_tdm_slot(cpu_dai, 0, 0x03, TDM_SLOTS,
					 TDM_SLOT_WIDTH);
		snd_soc_dai_set_channel_map(cpu_dai, 0, NULL,
					    ARRAY_SIZE(cpu_rx_slots),
					    cpu_rx_slots);
		snd_soc_dai_set_sysclk(cpu_dai,
				       Q6AFE_LPASS_CLK_ID_TER_TDM_IBIT,
				       TDM_BCLK_RATE, SNDRV_PCM_STREAM_PLAYBACK);
		for (codec_i = 0; codec_i < rtd->dai_link->num_codecs; codec_i++) {
			struct snd_soc_dai *amp = snd_soc_rtd_to_codec(rtd, codec_i);

			snd_soc_dai_set_fmt(amp, codec_dai_fmt);
			snd_soc_dai_set_channel_map(amp, 0, NULL, 2,
						    amp_rx_slots[codec_i]);
			snd_soc_dai_set_sysclk(amp, 0, TDM_BCLK_RATE,
					       SNDRV_PCM_STREAM_PLAYBACK);
			snd_soc_component_set_sysclk(amp->component, 0, 0,
						     TDM_BCLK_RATE,
						     SND_SOC_CLOCK_IN);
		}
		break;
	}
	default:
		break;
"""
    if old not in text:
        raise SystemExit(f"{path}: QUINARY_MI2S_RX needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Already-patched trees still have 8-slot / 12.288 MHz from the previous dagu
# bring-up. CAF kona.c sets TDM_MAX_SLOTS=4 for DAGU (BCLK 6.144 MHz) and
# tert RX_0 channel map byte offsets {0,4,8,12}.
path = root / "sound/soc/qcom/sm8250.c"
text = path.read_text()
if "#define TDM_SLOTS		8" in text or "#define TDM_BCLK_RATE		12288000" in text:
    text2 = text.replace("#define TDM_BCLK_RATE		12288000",
                         "#define TDM_BCLK_RATE		6144000", 1)
    text2 = text2.replace("#define TDM_SLOTS		8",
                          "#define TDM_SLOTS		4", 1)
    text2 = text2.replace("static const unsigned int cpu_rx_slots[] = { 0, 1 };",
                          "static const unsigned int cpu_rx_slots[] = { 0, 4 };", 1)
    if "#define TDM_SLOTS		4" not in text2:
        raise SystemExit(f"{path}: TDM 4-slot rewrite failed")
    path.write_text(text2)
    print(f"patched {path}: dagu CAF TDM_MAX_SLOTS is 4")

# Mainline q6afe_tdm_port_prepare drops DT invert-sync / data-delay.
# CAF tert RX needs invert-sync=1 and 1-BCLK delay (DSP_A) or CS35L41 PLL
# never locks and PUP_DONE times out.
path = root / "sound/soc/qcom/qdsp6/q6afe.h"
text = path.read_text()
marker = "dagu: TDM invert-sync/data-delay in q6afe_tdm_cfg"
if marker not in text:
    old = """	u16	slot_mask;
	u32	data_align_type;
	u16	ch_mapping[AFE_MAX_CHAN_COUNT];
"""
    new = """	u16	slot_mask;
	u32	data_align_type;
	u16	data_out_enable; /* dagu: TDM invert-sync/data-delay in q6afe_tdm_cfg */
	u16	invert_sync;
	u16	data_delay;
	u16	ch_mapping[AFE_MAX_CHAN_COUNT];
"""
    if old not in text:
        raise SystemExit(f"{path}: q6afe_tdm_cfg needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/qcom/qdsp6/q6afe-dai.c"
text = path.read_text()
marker = "dagu: copy TDM invert-sync into port cfg"
if marker not in text:
    old = """	tdm->data_align_type = dai_data->priv[dai->id].data_align;
	tdm->sync_src = dai_data->priv[dai->id].sync_src;
	tdm->sync_mode = dai_data->priv[dai->id].sync_mode;

	return 0;
"""
    new = """	tdm->data_align_type = dai_data->priv[dai->id].data_align;
	tdm->sync_src = dai_data->priv[dai->id].sync_src;
	tdm->sync_mode = dai_data->priv[dai->id].sync_mode;
	/* dagu: copy TDM invert-sync into port cfg */
	tdm->data_out_enable = dai_data->priv[dai->id].data_out_enable;
	tdm->invert_sync = dai_data->priv[dai->id].invert_sync;
	tdm->data_delay = dai_data->priv[dai->id].data_delay;

	return 0;
"""
    if old not in text:
        raise SystemExit(f"{path}: q6tdm_hw_params needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/qcom/qdsp6/q6afe.c"
text = path.read_text()
marker = "dagu: send TDM invert-sync to AFE"
if marker not in text and "dagu TDM ch=" not in text:
    old = """	pcfg->tdm_cfg.nslots_per_frame = cfg->nslots_per_frame;

	pcfg->tdm_cfg.slot_width = cfg->slot_width;
	pcfg->tdm_cfg.slot_mask = cfg->slot_mask;
"""
    new = """	pcfg->tdm_cfg.nslots_per_frame = cfg->nslots_per_frame;
	/* dagu: send TDM invert-sync to AFE */
	pcfg->tdm_cfg.ctrl_data_out_enable = cfg->data_out_enable;
	pcfg->tdm_cfg.ctrl_invert_sync_pulse = cfg->invert_sync;
	pcfg->tdm_cfg.ctrl_sync_data_delay = cfg->data_delay;

	pcfg->tdm_cfg.slot_width = cfg->slot_width;
	pcfg->tdm_cfg.slot_mask = cfg->slot_mask;
"""
    if old not in text:
        raise SystemExit(f"{path}: q6afe_tdm_port_prepare needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/qcom/qdsp6/q6afe.c"
text = path.read_text()
# This ADSP returns 0x16 / "Unknown cmd 0x100f4" for LPASS_CORE_HW_VOTE.
# SWR/txmacro then never get iface/fsgen clocks and the whole sound card
# defers on "WCD Capture: codec dai not found".
marker = "dagu: AFE LPASS HW vote is optional"
if marker not in text:
    old = """	ret = afe_apr_send_pkt(afe, pkt, NULL,
			       AFE_CMD_RSP_REMOTE_LPASS_CORE_HW_VOTE_REQUEST);
	if (ret)
		dev_err(afe->dev, "AFE failed to vote (%d)\\n", hw_block_id);

	return ret;
"""
    new = """	ret = afe_apr_send_pkt(afe, pkt, NULL,
			       AFE_CMD_RSP_REMOTE_LPASS_CORE_HW_VOTE_REQUEST);
	if (ret) {
		/* dagu: AFE LPASS HW vote is optional */
		dev_warn(afe->dev, "AFE vote unsupported (%d, %d); continue without vote\\n",
			 hw_block_id, ret);
		ret = 0;
	}

	return ret;
"""
    if old not in text:
        raise SystemExit(f"{path}: AFE vote needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Stock mixer_paths speaker: all four CS35L41 ASPRX1=0 ASPRX2=1 (not 0/4, 1/5).
path = root / "sound/soc/qcom/sm8250.c"
text = path.read_text()
marker = "dagu: CS35L41 ASPRX slots 0/1"
if marker not in text:
    old = """		static const unsigned int amp_rx_slots[][2] = {
			{ 0, 4 }, { 1, 5 }, { 0, 4 }, { 1, 5 },
		};
"""
    new = """		static const unsigned int amp_rx_slots[][2] = {
			/* dagu: CS35L41 ASPRX slots 0/1 */
			{ 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 },
		};
"""
    if old in text:
        path.write_text(text.replace(old, new, 1))
        print(f"patched {path}: {marker}")
        text = path.read_text()

# Stock TERT_TDM_RX_0 Format = S24_LE, 48 kHz, two channels.
marker = "dagu: BE fixup S24_LE 48k stereo"
if marker not in text:
    old = """	rate->min = rate->max = 48000;
	channels->min = channels->max = 2;
	snd_mask_set_format(fmt, SNDRV_PCM_FORMAT_S16_LE);
"""
    new = """	rate->min = rate->max = 48000;
	channels->min = channels->max = 2;
	/* dagu: BE fixup S24_LE 48k stereo */
	snd_mask_none(fmt);
	snd_mask_set_format(fmt, SNDRV_PCM_FORMAT_S24_LE);
"""
    if old not in text:
        raise SystemExit(f"{path}: BE fixup needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Xiaomi ADSP rejects oversized AFE_PARAM_ID_TDM_CONFIG (union vs tdm_cfg).
path = root / "sound/soc/qcom/qdsp6/q6afe.c"
text = path.read_text()
marker = "dagu: TDM SET_PARAM size is tdm_cfg"
if marker not in text:
    old = """	ret  = q6afe_port_set_param_v2(port, &port->port_cfg, param_id,
				       AFE_MODULE_AUDIO_DEV_INTERFACE,
				       sizeof(port->port_cfg));
"""
    new = """	{
		int cfg_size = sizeof(port->port_cfg);

		/* dagu: TDM SET_PARAM size is tdm_cfg */
		if (param_id == AFE_PARAM_ID_TDM_CONFIG)
			cfg_size = sizeof(port->port_cfg.tdm_cfg);
		ret  = q6afe_port_set_param_v2(port, &port->port_cfg, param_id,
					       AFE_MODULE_AUDIO_DEV_INTERFACE,
					       cfg_size);
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: q6afe_port_start size needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# Stock Android rear s5kjn1: 19.2 MHz MCLK, 4080x3060 GBRG preview.
path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: s5kjn1 19.2 MHz and 4080x3060 GBRG"
if marker not in text:
    old = """#define S5KJN1_MCLK_FREQ_24MHZ		(24 * HZ_PER_MHZ)
"""
    new = """#define S5KJN1_MCLK_FREQ_24MHZ		(24 * HZ_PER_MHZ)
#define S5KJN1_MCLK_FREQ_19_2MHZ	(19200 * HZ_PER_KHZ) /* dagu: s5kjn1 19.2 MHz and 4080x3060 GBRG */
"""
    if old not in text:
        raise SystemExit(f"{path}: S5KJN1_MCLK needle missing")
    text = text.replace(old, new, 1)

    old = """		.width = 4080,
		.height = 3072,
"""
    new = """		.width = 4080,
		.height = 3060,
"""
    if old not in text:
        raise SystemExit(f"{path}: 4080x3072 mode needle missing")
    text = text.replace(old, new, 1)

    old = """	{ S5KJN1_REG_X_OUTPUT_SIZE, 0x0ff0 },
	{ S5KJN1_REG_Y_OUTPUT_SIZE, 0x0c00 },
"""
    new = """	{ S5KJN1_REG_X_OUTPUT_SIZE, 0x0ff0 },
	{ S5KJN1_REG_Y_OUTPUT_SIZE, 0x0bf4 },
"""
    if old not in text:
        raise SystemExit(f"{path}: Y_OUTPUT 0x0c00 needle missing")
    text = text.replace(old, new, 1)

    old = """	{ CCI_REG16(0x0136), 0x1800 },
"""
    new = """	{ CCI_REG16(0x0136), 0x1333 },
"""
    if old not in text:
        raise SystemExit(f"{path}: 0x0136 24MHz needle missing")
    text = text.replace(old, new, 1)

    old = """	s5kjn1->hflip = v4l2_ctrl_new_std(ctrl_hdlr, &s5kjn1_ctrl_ops,
					  V4L2_CID_HFLIP, 0, 1, 1, 0);
"""
    new = """	s5kjn1->hflip = v4l2_ctrl_new_std(ctrl_hdlr, &s5kjn1_ctrl_ops,
					  V4L2_CID_HFLIP, 0, 1, 1, 1);
"""
    if old not in text:
        raise SystemExit(f"{path}: hflip default needle missing")
    text = text.replace(old, new, 1)

    old = """	s5kjn1->vflip = v4l2_ctrl_new_std(ctrl_hdlr, &s5kjn1_ctrl_ops,
					  V4L2_CID_VFLIP, 0, 1, 1, 0);
"""
    new = """	s5kjn1->vflip = v4l2_ctrl_new_std(ctrl_hdlr, &s5kjn1_ctrl_ops,
					  V4L2_CID_VFLIP, 0, 1, 1, 1);
"""
    if old not in text:
        raise SystemExit(f"{path}: vflip default needle missing")
    text = text.replace(old, new, 1)

    old = """	if (freq != S5KJN1_MCLK_FREQ_24MHZ)
		return dev_err_probe(s5kjn1->dev, -EINVAL,
				     "MCLK clock frequency %lu is not supported\\n",
				     freq);
"""
    new = """	if (freq != S5KJN1_MCLK_FREQ_24MHZ &&
	    freq != S5KJN1_MCLK_FREQ_19_2MHZ)
		return dev_err_probe(s5kjn1->dev, -EINVAL,
				     "MCLK clock frequency %lu is not supported\\n",
				     freq);
"""
    if old not in text:
        raise SystemExit(f"{path}: MCLK probe check needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# CamX dagu_qtech_s5kjn1 4080x3060 PLL (19.2 MHz EXCK 0x1300).
path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: s5kjn1 CamX PLL"
if marker not in text:
    camx = """	{ CCI_REG16(0x0136), 0x1300 },
	{ CCI_REG16(0x013e), 0x00c8 },
	{ CCI_REG16(0x0300), 0x0006 },
	{ CCI_REG16(0x0302), 0x0001 },
	{ CCI_REG16(0x0304), 0x0003 },
	{ CCI_REG16(0x0306), 0x0083 }, /* dagu: s5kjn1 CamX PLL */
	{ CCI_REG16(0x0308), 0x0008 },
	{ CCI_REG16(0x030a), 0x0001 },
	{ CCI_REG16(0x030c), 0x0000 },
	{ CCI_REG16(0x030e), 0x0003 },
	{ CCI_REG16(0x0310), 0x0086 },
"""
    old24 = """	{ CCI_REG16(0x0136), 0x1333 },
	{ CCI_REG16(0x013e), 0x0000 },
	{ CCI_REG16(0x0300), 0x0006 },
	{ CCI_REG16(0x0302), 0x0001 },
	{ CCI_REG16(0x0304), 0x0004 },
	{ CCI_REG16(0x0306), 0x008c },
	{ CCI_REG16(0x0308), 0x0008 },
	{ CCI_REG16(0x030a), 0x0001 },
	{ CCI_REG16(0x030c), 0x0000 },
	{ CCI_REG16(0x030e), 0x0004 },
	{ CCI_REG16(0x0310), 0x0092 },
"""
    old192 = """	{ CCI_REG16(0x0136), 0x1333 },
	{ CCI_REG16(0x013e), 0x0000 },
	{ CCI_REG16(0x0300), 0x0006 },
	{ CCI_REG16(0x0302), 0x0001 },
	{ CCI_REG16(0x0304), 0x0004 },
	{ CCI_REG16(0x0306), 0x00af }, /* dagu: s5kjn1 PLL for 19.2 MHz MCLK */
	{ CCI_REG16(0x0308), 0x0008 },
	{ CCI_REG16(0x030a), 0x0001 },
	{ CCI_REG16(0x030c), 0x0000 },
	{ CCI_REG16(0x030e), 0x0004 },
	{ CCI_REG16(0x0310), 0x00b6 },
"""
    if old192 in text:
        text = text.replace(old192, camx, 1)
    elif old24 in text:
        text = text.replace(old24, camx, 1)
    else:
        raise SystemExit(f"{path}: s5kjn1 CamX PLL needle missing")
    path.write_text(text)
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu s5kjn1 streaming"
if marker not in text:
    old = """	cci_write(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE,
		  S5KJN1_MODE_STREAMING, &ret);
	if (ret)
		goto error;

	return 0;
"""
    new = """	cci_write(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE,
		  S5KJN1_MODE_STREAMING, &ret);
	if (ret)
		goto error;

	dev_info(s5kjn1->dev, "dagu s5kjn1 streaming %ux%u\\n",
		 s5kjn1->mode->width, s5kjn1->mode->height);
	return 0;
"""
    if old not in text:
        raise SystemExit(f"{path}: s5kjn1 stream-on needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "sound/soc/qcom/qdsp6/q6afe.c"
text = path.read_text()
# CAF TDM_CONFIG bit_width is 16 or 24 (slot_width is 32). Forcing sample
# width 32 made SET_PARAM 0x100ef return ADSP_EBADPARAM (0x2).
marker24 = "dagu: TDM sample bit_width stays 16/24; slot_width is 32"
marker32 = "dagu: TDM bit_width 32 and dump cfg"
old32 = """	/* dagu: TDM bit_width 32 and dump cfg */
	pcfg->tdm_cfg.bit_width = (cfg->bit_width == 24) ? 32 : cfg->bit_width;
"""
new24 = """	/* dagu: TDM sample bit_width stays 16/24; slot_width is 32 */
	pcfg->tdm_cfg.bit_width = cfg->bit_width;
"""
if marker24 in text:
    print(f"already patched {path}: {marker24}")
elif marker32 in text or old32 in text:
    if old32 not in text:
        raise SystemExit(f"{path}: TDM 24->32 conversion needle missing")
    path.write_text(text.replace(old32, new24, 1))
    print(f"patched {path}: TDM bit_width keep 24")
else:
    old = """	pcfg->tdm_cfg.tdm_cfg_minor_version = AFE_API_VERSION_TDM_CONFIG;
	pcfg->tdm_cfg.num_channels = cfg->num_channels;
	pcfg->tdm_cfg.sample_rate = cfg->sample_rate;
	pcfg->tdm_cfg.bit_width = cfg->bit_width;
	pcfg->tdm_cfg.data_format = cfg->data_format;
	pcfg->tdm_cfg.sync_mode = cfg->sync_mode;
	pcfg->tdm_cfg.sync_src = cfg->sync_src;
	pcfg->tdm_cfg.nslots_per_frame = cfg->nslots_per_frame;
	/* dagu: send TDM invert-sync to AFE */
	pcfg->tdm_cfg.ctrl_data_out_enable = cfg->data_out_enable;
	pcfg->tdm_cfg.ctrl_invert_sync_pulse = cfg->invert_sync;
	pcfg->tdm_cfg.ctrl_sync_data_delay = cfg->data_delay;

	pcfg->tdm_cfg.slot_width = cfg->slot_width;
	pcfg->tdm_cfg.slot_mask = cfg->slot_mask;
	port->scfg = kzalloc_obj(*port->scfg);
	if (!port->scfg)
		return;

	port->scfg->minor_version = AFE_API_VERSION_SLOT_MAPPING_CONFIG;
	port->scfg->num_channels = cfg->num_channels;
	port->scfg->bitwidth = cfg->bit_width;
"""
    new = """	pcfg->tdm_cfg.tdm_cfg_minor_version = AFE_API_VERSION_TDM_CONFIG;
	pcfg->tdm_cfg.num_channels = cfg->num_channels;
	pcfg->tdm_cfg.sample_rate = cfg->sample_rate;
	/* dagu: TDM sample bit_width stays 16/24; slot_width is 32 */
	pcfg->tdm_cfg.bit_width = cfg->bit_width;
	pcfg->tdm_cfg.data_format = 0;
	pcfg->tdm_cfg.sync_mode = cfg->sync_mode;
	pcfg->tdm_cfg.sync_src = cfg->sync_src;
	pcfg->tdm_cfg.nslots_per_frame = cfg->nslots_per_frame ?: 4;
	pcfg->tdm_cfg.ctrl_data_out_enable = cfg->data_out_enable;
	pcfg->tdm_cfg.ctrl_invert_sync_pulse = cfg->invert_sync;
	pcfg->tdm_cfg.ctrl_sync_data_delay = cfg->data_delay;
	pcfg->tdm_cfg.slot_width = cfg->slot_width ?: 32;
	pcfg->tdm_cfg.slot_mask = cfg->slot_mask ?:
		((1u << cfg->num_channels) - 1);
	pr_info("dagu TDM ch=%u rate=%u bw=%u->%u slots=%u sw=%u mask=0x%x sync=%u/%u inv=%u delay=%u dout=%u\\n",
		pcfg->tdm_cfg.num_channels, pcfg->tdm_cfg.sample_rate,
		cfg->bit_width, pcfg->tdm_cfg.bit_width,
		pcfg->tdm_cfg.nslots_per_frame, pcfg->tdm_cfg.slot_width,
		pcfg->tdm_cfg.slot_mask, pcfg->tdm_cfg.sync_mode,
		pcfg->tdm_cfg.sync_src, pcfg->tdm_cfg.ctrl_invert_sync_pulse,
		pcfg->tdm_cfg.ctrl_sync_data_delay,
		pcfg->tdm_cfg.ctrl_data_out_enable);
	kfree(port->scfg);
	port->scfg = kzalloc_obj(*port->scfg);
	if (!port->scfg)
		return;

	port->scfg->minor_version = AFE_API_VERSION_SLOT_MAPPING_CONFIG;
	port->scfg->num_channels = cfg->num_channels;
	port->scfg->bitwidth = pcfg->tdm_cfg.bit_width;
"""
    if old not in text:
        raise SystemExit(f"{path}: TDM dump needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker24}")

path = root / "sound/soc/qcom/qdsp6/q6afe.c"
text = path.read_text()
if "q6afe_tdm_group_enable" not in text:
    old = """#define AFE_MODULE_AUDIO_DEV_INTERFACE	0x0001020C
#define AFE_MODULE_TDM			0x0001028A
"""
    new = """#define AFE_MODULE_AUDIO_DEV_INTERFACE	0x0001020C
#define AFE_MODULE_TDM			0x0001028A
#define AFE_MODULE_GROUP_DEVICE		0x00010254
#define AFE_PARAM_ID_GROUP_DEVICE_ENABLE	0x00010256
#define AFE_PARAM_ID_GROUP_DEVICE_TDM_CONFIG	0x0001029E
#define AFE_API_VERSION_GROUP_DEVICE_TDM_CONFIG	1
#define AFE_GROUP_DEVICE_NUM_PORTS	8
#define AFE_PORT_INVALID		0xFFFF
"""
    if old not in text:
        raise SystemExit(f"{path}: TDM GROUP defines needle missing")
    text = text.replace(old, new, 1)
    old = """/**
 * q6afe_port_stop() - Stop a afe port
 *
 * @port: Instance of port to stop
 *
 * Return: Will be an negative on packet size on success.
 */
int q6afe_port_stop(struct q6afe_port *port)
"""
    new = """struct afe_param_id_group_device_tdm_cfg {
	u32	group_device_cfg_minor_version;
	u16	group_id;
	u16	reserved;
	u16	port_id[AFE_GROUP_DEVICE_NUM_PORTS];
	u32	num_channels;
	u32	sample_rate;
	u32	bit_width;
	u16	nslots_per_frame;
	u16	slot_width;
	u32	slot_mask;
} __packed;

struct afe_group_device_enable {
	u16	group_id;
	u16	enable;
} __packed;

/* CAF kona LPASS tert RX is a 2-port group (RX_0 + RX_1). Configure the
 * group before TDM_CONFIG; otherwise ADSP returns EBADPARAM (0x2).
 */
static int q6afe_tdm_group_enable(struct q6afe_port *port, bool enable)
{
	struct afe_param_id_tdm_cfg *tdm = &port->port_cfg.tdm_cfg;
	struct afe_param_id_group_device_tdm_cfg gcfg = { };
	struct afe_group_device_enable gen = { };
	u16 group_id = port->id + 0x100;
	int i, ret;

	if (port->cfg_type != AFE_PARAM_ID_TDM_CONFIG)
		return 0;

	if (enable) {
		gcfg.group_device_cfg_minor_version =
			AFE_API_VERSION_GROUP_DEVICE_TDM_CONFIG;
		gcfg.group_id = group_id;
		gcfg.port_id[0] = port->id;
		gcfg.port_id[1] = port->id + 0x02;
		for (i = 2; i < AFE_GROUP_DEVICE_NUM_PORTS; i++)
			gcfg.port_id[i] = AFE_PORT_INVALID;
		gcfg.num_channels = tdm->nslots_per_frame ?: 4;
		gcfg.sample_rate = tdm->sample_rate;
		gcfg.bit_width = tdm->slot_width ?: 32;
		gcfg.nslots_per_frame = tdm->nslots_per_frame ?: 4;
		gcfg.slot_width = tdm->slot_width ?: 32;
		gcfg.slot_mask = (1u << gcfg.nslots_per_frame) - 1;
		pr_info("dagu TDM GROUP id=0x%x ports=0x%x,0x%x ch=%u rate=%u bw=%u slots=%u sw=%u mask=0x%x\\n",
			gcfg.group_id, gcfg.port_id[0], gcfg.port_id[1],
			gcfg.num_channels, gcfg.sample_rate, gcfg.bit_width,
			gcfg.nslots_per_frame, gcfg.slot_width, gcfg.slot_mask);
		ret = q6afe_set_param(port->afe, port, &gcfg,
				      AFE_PARAM_ID_GROUP_DEVICE_TDM_CONFIG,
				      AFE_MODULE_GROUP_DEVICE, sizeof(gcfg),
				      port->token);
		if (ret) {
			dev_err(port->afe->dev,
				"TDM group cfg 0x%x failed %d\\n", group_id, ret);
			return ret;
		}
	}

	gen.group_id = group_id;
	gen.enable = enable;
	ret = q6afe_set_param(port->afe, port, &gen,
			      AFE_PARAM_ID_GROUP_DEVICE_ENABLE,
			      AFE_MODULE_GROUP_DEVICE, sizeof(gen),
			      port->token);
	if (ret)
		dev_err(port->afe->dev, "TDM group enable 0x%x en=%d failed %d\\n",
			group_id, enable, ret);
	return ret;
}

/**
 * q6afe_port_stop() - Stop a afe port
 *
 * @port: Instance of port to stop
 *
 * Return: Will be an negative on packet size on success.
 */
int q6afe_port_stop(struct q6afe_port *port)
"""
    if old not in text:
        raise SystemExit(f"{path}: TDM GROUP helper needle missing")
    text = text.replace(old, new, 1)
    old = """	ret = afe_apr_send_pkt(afe, pkt, port, AFE_PORT_CMD_DEVICE_STOP);
	if (ret)
		dev_err(afe->dev, "AFE close failed %d\\n", ret);

	return ret;
}
EXPORT_SYMBOL_GPL(q6afe_port_stop);
"""
    new = """	ret = afe_apr_send_pkt(afe, pkt, port, AFE_PORT_CMD_DEVICE_STOP);
	if (ret)
		dev_err(afe->dev, "AFE close failed %d\\n", ret);

	/* dagu: TDM GROUP before port start */
	q6afe_tdm_group_enable(port, false);

	return ret;
}
EXPORT_SYMBOL_GPL(q6afe_port_stop);
"""
    if old not in text:
        raise SystemExit(f"{path}: TDM GROUP stop needle missing")
    text = text.replace(old, new, 1)
    old = """		/* dagu: TDM SET_PARAM size is tdm_cfg */
		if (param_id == AFE_PARAM_ID_TDM_CONFIG)
			cfg_size = sizeof(port->port_cfg.tdm_cfg);
		ret  = q6afe_port_set_param_v2(port, &port->port_cfg, param_id,
					       AFE_MODULE_AUDIO_DEV_INTERFACE,
					       cfg_size);
	}
	if (ret) {
		dev_err(afe->dev, "AFE enable for port 0x%x failed %d\\n",
			port_id, ret);
		return ret;
	}
"""
    new = """		/* dagu: TDM SET_PARAM size is tdm_cfg */
		if (param_id == AFE_PARAM_ID_TDM_CONFIG) {
			cfg_size = sizeof(port->port_cfg.tdm_cfg);
			ret = q6afe_tdm_group_enable(port, true);
			if (ret)
				return ret;
		}
		ret  = q6afe_port_set_param_v2(port, &port->port_cfg, param_id,
					       AFE_MODULE_AUDIO_DEV_INTERFACE,
					       cfg_size);
	}
	if (ret) {
		dev_err(afe->dev, "AFE enable for port 0x%x failed %d\\n",
			port_id, ret);
		if (param_id == AFE_PARAM_ID_TDM_CONFIG)
			q6afe_tdm_group_enable(port, false);
		return ret;
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: TDM GROUP start needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: q6afe_tdm_group_enable")

path = root / "sound/soc/qcom/qdsp6/q6afe.c"
text = path.read_text()
if "q6afe_tdm_group_enable" not in text:
    raise SystemExit(f"{path}: TDM GROUP helper missing after insert")
if "gcfg.slot_mask = 0xFF" in text:
    text = text.replace("gcfg.slot_mask = 0xFF;",
                        "gcfg.slot_mask = (1u << gcfg.nslots_per_frame) - 1;", 1)
    text = text.replace("nslots_per_frame ?: 8", "nslots_per_frame ?: 4")
    path.write_text(text)
    print(f"patched {path}: TDM GROUP 4-slot mask")

path = root / "sound/soc/qcom/qdsp6/q6afe.c"
text = path.read_text()
marker = "dagu: GROUP bit_width is sample width, not slot_width"
if marker not in text:
    old = """		gcfg.num_channels = tdm->nslots_per_frame ?: 4;
		gcfg.sample_rate = tdm->sample_rate;
		gcfg.bit_width = tdm->slot_width ?: 32;
		gcfg.nslots_per_frame = tdm->nslots_per_frame ?: 4;
		gcfg.slot_width = tdm->slot_width ?: 32;
"""
    new = """		gcfg.num_channels = tdm->nslots_per_frame ?: 4;
		gcfg.sample_rate = tdm->sample_rate;
		/*
		 * dagu: GROUP bit_width is sample width, not slot_width.
		 * Android TERT_TDM_RX_0 is S24_LE in 32-bit slots. Using
		 * slot_width (32) here made ADSP treat S24_LE DMA words as
		 * 32-bit samples — 8 MSB zeros ≈ -48 dB at "full" volume.
		 */
		gcfg.bit_width = tdm->bit_width ?: 24;
		gcfg.nslots_per_frame = tdm->nslots_per_frame ?: 4;
		gcfg.slot_width = tdm->slot_width ?: 32;
"""
    if old not in text:
        raise SystemExit(f"{path}: TDM GROUP bit_width needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# SM8250 VFE puts the CAMNOC RCG rates on camnoc_axi_src, but
# vfe_match_clock_names() only matches camnoc_axi (a branch with rate {0}).
# Without ICC the RCG stays parked at XO 19.2 MHz and RDI DMA never completes.
path = root / "drivers/media/platform/qcom/camss/camss-vfe.c"
text = path.read_text()
marker = "dagu: scale camnoc_axi_src"
if marker not in text:
    old = """	return (!strcmp(clock->name, vfe_name) ||
		!strcmp(clock->name, vfe_lite_name) ||
		!strcmp(clock->name, "vfe_lite") ||
		!strcmp(clock->name, "camnoc_axi") ||
		!strcmp(clock->name, "camnoc_rt_axi"));
"""
    new = """	return (!strcmp(clock->name, vfe_name) ||
		!strcmp(clock->name, vfe_lite_name) ||
		!strcmp(clock->name, "vfe_lite") ||
		!strcmp(clock->name, "camnoc_axi") ||
		!strcmp(clock->name, "camnoc_axi_src") || /* dagu: scale camnoc_axi_src */
		!strcmp(clock->name, "camnoc_rt_axi"));
"""
    if old not in text:
        raise SystemExit(f"{path}: vfe_match_clock_names needle missing")
    text = text.replace(old, new, 1)
    old = """			ret = clk_set_rate(clock->clk, rate);
			if (ret < 0) {
				dev_err(dev, "clk set rate failed: %d\\n", ret);
				return ret;
			}
"""
    new = """			ret = clk_set_rate(clock->clk, rate);
			if (ret < 0) {
				dev_err(dev, "clk set rate failed: %d\\n", ret);
				return ret;
			}
			if (!strcmp(clock->name, "camnoc_axi_src"))
				dev_info(dev, "dagu camnoc_axi_src min=%llu -> %ld\\n",
					 min_rate, rate);
"""
    if old not in text:
        raise SystemExit(f"{path}: vfe clk_set_rate needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# CSIPHY MMIO sits on titan AHB. VFE/TPG work with cpas/ife AHB, but
# core_ahb stayed at enable_count=0 during STREAMON and both sensors
# produced 0 frames. Enable it with the PHY clocks.
path = root / "drivers/media/platform/qcom/camss/camss.c"
text = path.read_text()
marker = "dagu: csiphy also enable core_ahb"
if marker not in text:
    n = 0
    for i in range(6):
        old = f'''		.clock = {{ "csiphy{i}", "csiphy{i}_timer" }},
		.clock_rate = {{ {{ 400000000 }},
				{{ 300000000 }} }},
'''
        new = f'''		.clock = {{ "csiphy{i}", "csiphy{i}_timer", "core_ahb", "cpas_ahb" }}, /* dagu: csiphy also enable core_ahb */
		.clock_rate = {{ {{ 400000000 }},
				{{ 300000000 }},
				{{ 19200000 }},
				{{ 19200000 }} }},
'''
        if old not in text:
            raise SystemExit(f"{path}: csiphy{i} clock needle missing")
        text = text.replace(old, new, 1)
        n += 1
    path.write_text(text)
    print(f"patched {path}: {marker} x{n}")

path = root / "drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c"
text = path.read_text()
marker = "dagu: log csiphy settle"
if marker not in text:
    old = '''	settle_cnt = csiphy_settle_cnt_calc(link_freq, csiphy->timer_clk_rate);

	val = CSIPHY_3PH_CMN_CSI_COMMON_CTRL5_CLK_ENABLE;
'''
    new = '''	settle_cnt = csiphy_settle_cnt_calc(link_freq, csiphy->timer_clk_rate);
	/* dagu: log csiphy settle */
	dev_info(csiphy->camss->dev,
		 "dagu csiphy%d link=%lldHz timer=%u settle=%u nlanes=%u\\n",
		 csiphy->id, (long long)link_freq, csiphy->timer_clk_rate,
		 settle_cnt, c->num_data);

	val = CSIPHY_3PH_CMN_CSI_COMMON_CTRL5_CLK_ENABLE;
'''
    if old not in text:
        raise SystemExit(f"{path}: settle_cnt needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c"
text = path.read_text()
marker = "dagu: Android s5kjn1 D-PHY settle 0x13"
if marker not in text:
    replacements = [
        (
            "	if (cfg->csi2->cphy)\n"
            "		settle_cnt = 0x12;\n"
            "	/* dagu: log csiphy settle */\n",
            "	if (cfg->csi2->cphy)\n"
            "		settle_cnt = 0x12;\n"
            "	else if (csiphy->id == 1)\n"
            "		settle_cnt = 0x13; /* dagu: Android s5kjn1 D-PHY settle 0x13 */\n"
            "	/* dagu: log csiphy settle */\n",
        ),
        (
            "	settle_cnt = csiphy_settle_cnt_calc(link_freq, csiphy->timer_clk_rate);\n"
            "	/* dagu: log csiphy settle */\n",
            "	settle_cnt = csiphy_settle_cnt_calc(link_freq, csiphy->timer_clk_rate);\n"
            "	if (!cfg->csi2->cphy && csiphy->id == 1)\n"
            "		settle_cnt = 0x13; /* dagu: Android s5kjn1 D-PHY settle 0x13 */\n"
            "	/* dagu: log csiphy settle */\n",
        ),
    ]
    for old, new in replacements:
        if old in text:
            text = text.replace(old, new, 1)
            break
    else:
        raise SystemExit(f"{path}: D-PHY settle 0x13 needle missing")
    path.write_text(text)
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu s5kjn1 frame counter"
# Later delay-sweep replacement owns STREAMON; do not re-stitch
# the intermediate log+return-0 needle.
if marker not in text and "dagu: 0x2400 delay sweep then 0x4000 mode" not in text:
    old = '''	dev_info(s5kjn1->dev, "dagu s5kjn1 streaming %ux%u\\n",
		 s5kjn1->mode->width, s5kjn1->mode->height);
	return 0;
'''
    new = '''	dev_info(s5kjn1->dev, "dagu s5kjn1 streaming %ux%u\\n",
		 s5kjn1->mode->width, s5kjn1->mode->height);
	msleep(80);
	{
		u64 fc = 0, mode = 0, lanes = 0;

		/* dagu s5kjn1 frame counter */
		cci_read(s5kjn1->regmap, CCI_REG8(0x0005), &fc, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE, &mode, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0114), &lanes, NULL);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 fc=0x%llx mode=0x%llx r0114=0x%llx\\n",
			 fc, mode, lanes);
	}
	return 0;
'''
    if old not in text:
        raise SystemExit(f"{path}: s5kjn1 streaming log needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: Android live D-PHY 4-lane 0x0115=0"
# Live Android CSIPHY1 preview is 2PH D-PHY (0x0800=0x02). CamX 4080 C-PHY
# 0x0114=0x0301 blacks CSID/VFE — do not re-apply it.
if "dagu: CamX 4080 C-PHY 0x0115=1" in text:
    text = text.replace(
        "	{ CCI_REG16(0x0114), 0x0301 }, /* dagu: CamX 4080 C-PHY 0x0115=1 */\n",
        "	{ CCI_REG16(0x0114), 0x0300 }, /* dagu: Android live D-PHY 4-lane 0x0115=0 */\n",
    )
    path.write_text(text)
    text = path.read_text()
    print(f"patched {path}: revert C-PHY 0x0114 to Android live D-PHY")
if marker not in text:
    replaced = False
    for old in (
        "	{ CCI_REG16(0x0114), 0x0301 }, /* dagu: CamX 4080 C-PHY 0x0115=1 */\n",
        "	{ CCI_REG16(0x0114), 0x0301 },\n",
        "	{ CCI_REG16(0x0114), 0x0300 },\n",
    ):
        if old in text:
            text = text.replace(old, "	{ CCI_REG16(0x0114), 0x0300 }, /* dagu: Android live D-PHY 4-lane 0x0115=0 */\n", 1)
            replaced = True
            break
    if not replaced:
        raise SystemExit(f"{path}: 0x0114 D-PHY needle missing")
    path.write_text(text)
    print(f"patched {path}: {marker}")
hdr = (root / "drivers/media/i2c/s5kjn1-dagu-regs.h").read_text()
if "{ CCI_REG16(0x0114), 0x0301 }" in hdr:
    raise SystemExit("s5kjn1-dagu-regs.h 4080 still CamX C-PHY 0x0114=0x0301")
if marker not in hdr:
    raise SystemExit("s5kjn1-dagu-regs.h missing Android live D-PHY 0x0114")
if "s5kjn1_dagu_4080x3060_mcu" not in hdr:
    raise SystemExit("s5kjn1-dagu-regs.h missing MCU 0x2400 table")
if "s5kjn1_dagu_2040x1530_mode" not in hdr:
    raise SystemExit("s5kjn1-dagu-regs.h missing CamX-bin 2040x1530 table")
if "{ CCI_REG16(0x0900), 0x0144 }" in hdr:
    raise SystemExit("s5kjn1-dagu-regs.h 2040 mode still has guessed 4x4 0x0144")
if "{ CCI_REG16(0x0348), 0x0fff }" not in hdr or "{ CCI_REG16(0x034a), 0x0c0f }" not in hdr:
    raise SystemExit("s5kjn1-dagu-regs.h 2040 analog window is not CamX 2x2 half-crop")
if "{ CCI_REG16(0x034c), 0x07f8 }" not in hdr or "{ CCI_REG16(0x034e), 0x05fa }" not in hdr:
    raise SystemExit("s5kjn1-dagu-regs.h 2040 output size missing")
if "{ CCI_REG16(0x0900), 0x0122 }" not in hdr:
    raise SystemExit("s5kjn1-dagu-regs.h missing CamX 2x2 0x0900=0x0122")

# Mainline lane_regs_sm8250 copies CAF combo-mode 0x?904=0x07.
# dagu sensors each own a PHY (csiphy1 / csiphy4); CAF non-combo 2PH uses 0x03.
path = root / "drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c"
text = path.read_text()
marker = "dagu: CSIPHY 2PH non-combo 0x03"
if marker not in text:
    n = 0
    for addr in ("0x0904", "0x0C84", "0x0A04", "0x0B04", "0x0C04"):
        old = f"\t{{{addr}, 0x07, 0x00, CSIPHY_DEFAULT_PARAMS}},\n"
        new = f"\t{{{addr}, 0x03, 0x00, CSIPHY_DEFAULT_PARAMS}}, /* dagu: CSIPHY 2PH non-combo 0x03 */\n"
        if old not in text:
            raise SystemExit(f"{path}: {addr} 0x07 needle missing")
        text = text.replace(old, new, 1)
        n += 1
    path.write_text(text)
    print(f"patched {path}: {marker} x{n}")

path = root / "drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c"
text = path.read_text()
marker = "dagu: CSIPHY enable IRQs and dump"
if marker not in text:
    old = '''	/* IRQ_MASK registers - disable all interrupts */
	for (i = 11; i < 22; i++) {
		writel_relaxed(0, csiphy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, i));
	}
}
'''
    new = '''	/* CAF csiphy_irq_reg_1_2_1: unmask lane IRQs. */
	for (i = 11; i < 22; i++) {
		u8 irqv = 0xff;

		if (i == 13)
			irqv = 0xfb;
		else if (i == 15)
			irqv = 0x7f;
		else if (i == 18)
			irqv = 0xef;
		writel_relaxed(irqv, csiphy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, i));
	}
	{
		u32 c5, c7, r904, hw;

		c5 = readl_relaxed(csiphy->base +
			CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, 5));
		c7 = readl_relaxed(csiphy->base +
			CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, 7));
		r904 = readl_relaxed(csiphy->base + 0x0904);
		hw = readl_relaxed(csiphy->base +
			CSIPHY_3PH_CMN_CSI_COMMON_STATUSn(regs->offset,
							  regs->common_status_offset, 12));
		/* dagu: CSIPHY enable IRQs and dump */
		dev_info(csiphy->camss->dev,
			 "dagu csiphy%d mmio c5=0x%x c7=0x%x r0904=0x%x st12=0x%x\\n",
			 csiphy->id, c5, c7, r904, hw);
	}
}
'''
    if old not in text:
        raise SystemExit(f"{path}: CSIPHY IRQ disable needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

text = path.read_text()
marker = "dagu: log CSIPHY ISR"
if "dagu: do not printk CSIPHY" not in text and marker not in text:
    old = '''	for (i = 0; i < 11; i++) {
		int c = i + 22;
		u8 val = readl_relaxed(csiphy->base +
			CSIPHY_3PH_CMN_CSI_COMMON_STATUSn(regs->offset,
							  regs->common_status_offset, i));

		writel_relaxed(val, csiphy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, c));
	}
'''
    new = '''	for (i = 0; i < 11; i++) {
		int c = i + 22;
		u8 val = readl_relaxed(csiphy->base +
			CSIPHY_3PH_CMN_CSI_COMMON_STATUSn(regs->offset,
							  regs->common_status_offset, i));

		if (val)
			dev_info_ratelimited(csiphy->camss->dev,
					     "dagu csiphy%d irq[%d]=0x%x\\n",
					     csiphy->id, i, val); /* dagu: log CSIPHY ISR */
		writel_relaxed(val, csiphy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, c));
	}
'''
    if old not in text:
        raise SystemExit(f"{path}: CSIPHY isr needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# CSI2_RX bits 0-7 are per-lane SOT/EOT. 0xffffffff ≈ 60k IRQ/s on D-PHY
# and Snapshot dies. Bit 17 (0x20000) is C-PHY FIFO status; live poke
# unmasking it storms CSID (~20k/s) and VFE stays 0 fps. Leave masked.
path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "dagu: CSID SOT/EOT stay masked" not in text and "dagu: CSID FIFO bit17" not in text:
    old_masks = [
            '''			if (enable) {
				/* dagu: unmask CSI2 RX IRQs (incl. FIFO) — see SOT vs 0x20000. */
				writel_relaxed(0xffffffff,
					       csid->base + CSID_CSI2_RX_IRQ_MASK);
				writel_relaxed(0xffffffff,
					       csid->base + CSID_CSI2_RDIN_IRQ_MASK(i));
				dev_info(csid->camss->dev,
					 "dagu csid phy=%u lanes=%u assign=0x%x cfg0=0x%x\\n",
					 csid->phy.csiphy_id, csid->phy.lane_cnt,
					 csid->phy.lane_assign,
					 readl_relaxed(csid->base + CSID_CSI2_RX_CFG0)); /* dagu: log CSI2 RX CFG0 */
			}
''',
            '''			if (enable) {
				/* dagu: unmask CSI2 RX IRQs */
				writel_relaxed(0xffffffff,
					       csid->base + CSID_CSI2_RX_IRQ_MASK);
				dev_info(csid->camss->dev,
					 "dagu csid phy=%u lanes=%u assign=0x%x\\n",
					 csid->phy.csiphy_id, csid->phy.lane_cnt,
					 csid->phy.lane_assign);
			}
''',
    ]
    new_mask = '''			if (enable) {
				/* dagu: CSID SOT/EOT stay masked */
				dev_info(csid->camss->dev,
					 "dagu csid phy=%u lanes=%u assign=0x%x cfg0=0x%x\\n",
					 csid->phy.csiphy_id, csid->phy.lane_cnt,
					 csid->phy.lane_assign,
					 readl_relaxed(csid->base + CSID_CSI2_RX_CFG0));
			}
'''
    replaced = False
    for old in old_masks:
        if old in text:
            text = text.replace(old, new_mask, 1)
            replaced = True
            break
    if not replaced:
        old = '''			__csid_configure_rdi_stream(csid, enable, i);
			__csid_configure_rx(csid, &csid->phy, i);
			__csid_ctrl_rdi(csid, enable, i);
'''
        new = '''			__csid_configure_rdi_stream(csid, enable, i);
			__csid_configure_rx(csid, &csid->phy, i);
			__csid_ctrl_rdi(csid, enable, i);
''' + new_mask
        if old not in text:
            raise SystemExit(f"{path}: csid configure_stream needle missing")
        text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}: dagu: CSID SOT/EOT stay masked")

text = path.read_text()
old_rx_log = '''	val = readl_relaxed(csid->base + CSID_CSI2_RX_IRQ_STATUS);
	if (val)
		dev_info_ratelimited(csid->camss->dev,
				     "dagu csid rx irq=0x%x\\n", val);
	writel_relaxed(val, csid->base + CSID_CSI2_RX_IRQ_CLEAR);
'''
new_rx_log = '''	val = readl_relaxed(csid->base + CSID_CSI2_RX_IRQ_STATUS);
	writel_relaxed(val, csid->base + CSID_CSI2_RX_IRQ_CLEAR);
'''
if old_rx_log in text:
    text = text.replace(old_rx_log, new_rx_log, 1)
old_rdi_log = '''			val = readl_relaxed(csid->base + CSID_CSI2_RDIN_IRQ_STATUS(i));
			if (val)
				dev_info_ratelimited(csid->camss->dev,
						     "dagu csid rdi%d irq=0x%x\\n",
						     i, val);
			writel_relaxed(val, csid->base + CSID_CSI2_RDIN_IRQ_CLEAR(i));
'''
new_rdi_log = '''			val = readl_relaxed(csid->base + CSID_CSI2_RDIN_IRQ_STATUS(i));
			writel_relaxed(val, csid->base + CSID_CSI2_RDIN_IRQ_CLEAR(i));
'''
if old_rdi_log in text:
    text = text.replace(old_rdi_log, new_rdi_log, 1)
path.write_text(text)

# --- dagu C-PHY (CamX 4080 preview) ---
path = root / "drivers/media/platform/qcom/camss/camss-csiphy.h"
text = path.read_text()
if "struct csiphy_csi2_cfg {\n\tu8 cphy;" not in text:
    old = """struct csiphy_csi2_cfg {
	struct csiphy_lanes_cfg lane_cfg;
};
"""
    new = """struct csiphy_csi2_cfg {
	u8 cphy;
	struct csiphy_lanes_cfg lane_cfg;
};
"""
    if old not in text:
        raise SystemExit(f"{path}: csiphy_csi2_cfg needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: cphy field")

path = root / "drivers/media/platform/qcom/camss/camss-csid.h"
text = path.read_text()
if "\tu8 cphy;\n};" not in text.split("struct csid_phy_config", 1)[-1][:400]:
    old = """	u32 en_vc;
	u8 need_vc_update;
};
"""
    new = """	u32 en_vc;
	u8 need_vc_update;
	u8 cphy;
};
"""
    if old not in text:
        raise SystemExit(f"{path}: csid_phy_config needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: cphy field")

path = root / "drivers/media/platform/qcom/camss/camss.c"
text = path.read_text()
if "V4L2_MBUS_CSI2_CPHY" not in text:
    old = """	/*
	 * Most SoCs support both D-PHY and C-PHY standards, but currently only
	 * D-PHY is supported in the driver.
	 */
	if (vep.bus_type != V4L2_MBUS_CSI2_DPHY) {
		dev_err(dev, "Unsupported bus type %d\\n", vep.bus_type);
		return -EINVAL;
	}

	csd->interface.csiphy_id = vep.base.port;
"""
    new = """	if (vep.bus_type != V4L2_MBUS_CSI2_DPHY &&
	    vep.bus_type != V4L2_MBUS_CSI2_CPHY) {
		dev_err(dev, "Unsupported bus type %d\\n", vep.bus_type);
		return -EINVAL;
	}

	csd->interface.csiphy_id = vep.base.port;
	csd->interface.csi2.cphy = (vep.bus_type == V4L2_MBUS_CSI2_CPHY);
"""
    if old not in text:
        raise SystemExit(f"{path}: C-PHY bus_type needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: accept C-PHY")

path = root / "drivers/media/platform/qcom/camss/camss-csid.c"
text = path.read_text()
if "csid->phy.cphy =" not in text:
    old = """		csid->phy.lane_cnt = lane_cfg->num_data;
		csid->phy.lane_assign = csid_get_lane_assign(lane_cfg);
"""
    new = """		csid->phy.lane_cnt = lane_cfg->num_data;
		csid->phy.lane_assign = csid_get_lane_assign(lane_cfg);
		csid->phy.cphy = csiphy->cfg.csi2->cphy;
"""
    if old not in text:
        raise SystemExit(f"{path}: csid cphy copy needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: copy cphy")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "if (phy->cphy)" not in text:
    old = """	val |= phy->csiphy_id << CSI2_RX_CFG0_PHY_NUM_SEL;
	writel_relaxed(val, csid->base + CSID_CSI2_RX_CFG0);
"""
    new = """	val |= phy->csiphy_id << CSI2_RX_CFG0_PHY_NUM_SEL;
	if (phy->cphy)
		val |= 1 << CSI2_RX_CFG0_PHY_TYPE_SEL;
	writel_relaxed(val, csid->base + CSID_CSI2_RX_CFG0);
"""
    if old not in text:
        raise SystemExit(f"{path}: PHY_TYPE_SEL needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: C-PHY PHY_TYPE_SEL")

# Titan 480 PIX: CSID IPP + VFE0/1 line_num=4 + Bayer→NV12 + DISP WM4/5.
# Overlay copies camss-vfe-480.c. Keep D-PHY 0x0114=0x0300 and CSID SOT mask.
path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "dagu csid ipp vc=" not in text:
    if '#include "camss-vfe.h"' not in text:
        old = '''#include "camss-csid.h"
#include "camss-csid-gen2.h"
#include "camss.h"
'''
        new = '''#include "camss-csid.h"
#include "camss-csid-gen2.h"
#include "camss-vfe.h"
#include "camss.h"
'''
        if old not in text:
            raise SystemExit(f"{path}: csid-gen2 include needle missing")
        text = text.replace(old, new, 1)
    old = "static void __csid_configure_rdi_stream(struct csid_device *csid, u8 enable, u8 vc)"
    if old not in text:
        raise SystemExit(f"{path}: rdi stream needle missing")
    ipp = r'''#define CSID_IPP_CFG0			0x200
#define CSID_IPP_CFG1			0x204
#define CSID_IPP_CTRL			0x208
#define CSID_IPP_FRM_DROP_PATTERN	0x20c
#define CSID_IPP_FRM_DROP_PERIOD	0x210
#define CSID_IPP_IRQ_SUBSAMPLE_PATTERN	0x214
#define CSID_IPP_IRQ_SUBSAMPLE_PERIOD	0x218
#define CSID_IPP_HCROP			0x21c
#define CSID_IPP_VCROP			0x220
#define CSID_IPP_PIX_DROP_PATTERN	0x224
#define CSID_IPP_PIX_DROP_PERIOD	0x228
#define CSID_IPP_LINE_DROP_PATTERN	0x22c
#define CSID_IPP_LINE_DROP_PERIOD	0x230
#define CSID_IPP_ERR_RECOVERY_CFG0	0x2d0
#define     IPP_PIX_STORE_EN		7
#define     IPP_OVERFLOW_CTRL_EN	1

static bool csid_vc_feeds_pix(struct csid_device *csid, u8 vc)
{
	struct media_pad *remote;
	struct v4l2_subdev *sd;
	struct vfe_line *line;

	if (csid_is_lite(csid))
		return false;

	remote = media_pad_remote_pad_first(&csid->pads[MSM_CSID_PAD_FIRST_SRC + vc]);
	if (!remote)
		return false;

	sd = media_entity_to_v4l2_subdev(remote->entity);
	if (!sd)
		return false;

	line = v4l2_get_subdevdata(sd);
	return line && line->id == VFE_LINE_PIX;
}

static void __csid_configure_ipp_stream(struct csid_device *csid, u8 enable, u8 vc)
{
	struct v4l2_mbus_framefmt *input_format = &csid->fmt[MSM_CSID_PAD_FIRST_SRC + vc];
	const struct csid_format_info *format = csid_get_fmt_entry(csid->res->formats->formats,
								   csid->res->formats->nformats,
								   input_format->code);
	u32 val;

	/*
	 * CAF cam_ife_csid_core.c IPP CFG0: (1<<1)|1, crop, decode, DT,
	 * pix_store. Titan 480 IPP bit2 is horizontal_bin_en, not RDI
	 * TIMESTAMP_EN. Setting it 2×-bins 4080→2040 and overflows
	 * CAMIF/CLC programmed for full width (debug pixel stuck at 2040).
	 */
	val = 1 << RDI_CFG0_BYTE_CNTR_EN;
	val |= 1 << RDI_CFG0_FORMAT_MEASURE_EN;
	val |= 1 << RDI_CFG0_CROP_H_EN;
	val |= 1 << RDI_CFG0_CROP_V_EN;
	val |= format->decode_format << RDI_CFG0_DECODE_FORMAT;
	val |= format->data_type << RDI_CFG0_DATA_TYPE;
	/* CSID pad 4 is PIX, not CSI VC 3. Sensor packets are VC 0. */
	val |= 1 << IPP_PIX_STORE_EN;
	/*
	 * #389 CAMIF epoch 368 of CSID 1472 stuck, still line=736.
	 * CAF IPP CFG0 EARLY_EOF_EN (RDI_CFG0 bit29) fires CSID EOF
	 * before the last CSI line so CAMIF/WM can drain. Front
	 * 2592×1952 only. Do not unmask SOT. Do not crop last again.
	 */
	if (input_format->width == 2592 && input_format->height == 1952)
		val |= 1 << RDI_CFG0_EARLY_EOF_EN;
	writel_relaxed(val, csid->base + CSID_IPP_CFG0);

	val = 2 << RDI_CFG1_TIMESTAMP_STB_SEL;
	writel_relaxed(val, csid->base + CSID_IPP_CFG1);

	val = ((input_format->width - 1) << 16) | 0;
	writel_relaxed(val, csid->base + CSID_IPP_HCROP);
	/*
	 * #387 VCROP last 0x05bf << 16 (1472) for Display Full 2320.
	 * #412 identity feeds full 1951. Do not retry 0x05bf as the chroma gap.
	 */
	if (input_format->width == 2592 && input_format->height == 1952)
		val = (0x05bf << 16) | 0;
	else
		val = ((input_format->height - 1) << 16) | 0;
	writel_relaxed(val, csid->base + CSID_IPP_VCROP);

	writel_relaxed(1, csid->base + CSID_IPP_FRM_DROP_PERIOD);
	writel_relaxed(0, csid->base + CSID_IPP_FRM_DROP_PATTERN);
	writel_relaxed(1, csid->base + CSID_IPP_IRQ_SUBSAMPLE_PERIOD);
	writel_relaxed(0, csid->base + CSID_IPP_IRQ_SUBSAMPLE_PATTERN);
	writel_relaxed(1, csid->base + CSID_IPP_PIX_DROP_PERIOD);
	writel_relaxed(0, csid->base + CSID_IPP_PIX_DROP_PATTERN);
	writel_relaxed(1, csid->base + CSID_IPP_LINE_DROP_PERIOD);
	writel_relaxed(0, csid->base + CSID_IPP_LINE_DROP_PATTERN);

	/*
	 * #394 on #408: errrec=0x0 stuck, PIXEL PIPE OVERFLOW gone,
	 * ipp_bp=False, second CAMIF SOF, still 4591616. IPP irq
	 * bit17 is CAF CSID_PATH_OVERFLOW_RECOVERY "Overflow due to
	 * back pressure". Extra CSID recover line was the overflow.
	 * Keep front overflow_ctrl=0. Rear stays CAF 0x9. Do not
	 * crop last. Do not retry EARLY_EOF / CAMIF EN pulse /
	 * overflow buf_done.
	 */
	if (input_format->width == 2592 && input_format->height == 1952)
		writel_relaxed(0, csid->base + CSID_IPP_ERR_RECOVERY_CFG0);
	else
		writel_relaxed(IPP_OVERFLOW_CTRL_EN | 0x8,
			       csid->base + CSID_IPP_ERR_RECOVERY_CFG0);

	val = readl_relaxed(csid->base + CSID_IPP_CFG0);
	if (enable)
		val |= 1 << RDI_CFG0_ENABLE;
	else
		val &= ~BIT(RDI_CFG0_ENABLE);
	writel_relaxed(val, csid->base + CSID_IPP_CFG0);

	if (enable)
		val = HALT_CMD_RESUME_AT_FRAME_BOUNDARY << RDI_CTRL_HALT_CMD;
	else
		val = HALT_CMD_HALT_AT_FRAME_BOUNDARY << RDI_CTRL_HALT_CMD;
	writel_relaxed(val, csid->base + CSID_IPP_CTRL);

	if (enable)
		dev_info(csid->camss->dev,
			 "dagu csid ipp vc=%u decode=%u %ux%u cfg0=0x%x vcrop=0x%x\n",
			 vc, format->decode_format,
			 input_format->width, input_format->height,
			 readl_relaxed(csid->base + CSID_IPP_CFG0),
			 readl_relaxed(csid->base + CSID_IPP_VCROP));
}

'''
    text = text.replace(old, ipp + old, 1)
    old = '''			__csid_configure_rdi_stream(csid, enable, i);
			__csid_configure_rx(csid, &csid->phy, i);
			__csid_ctrl_rdi(csid, enable, i);
'''
    new = '''			if (csid_vc_feeds_pix(csid, i)) {
				__csid_configure_ipp_stream(csid, enable, i);
				__csid_configure_rx(csid, &csid->phy, i);
			} else {
				__csid_configure_rdi_stream(csid, enable, i);
				__csid_configure_rx(csid, &csid->phy, i);
				__csid_ctrl_rdi(csid, enable, i);
			}
'''
    if old not in text:
        raise SystemExit(f"{path}: configure_stream rdi needle missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}: dagu titan480 CSID IPP")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "not CSI VC 3" not in text:
    old = '''	val |= format->data_type << RDI_CFG0_DATA_TYPE;
	val |= vc << RDI_CFG0_VIRTUAL_CHANNEL;
	val |= dt_id << RDI_CFG0_DT_ID;
	val |= 1 << IPP_PIX_STORE_EN;
'''
    new = '''	val |= format->data_type << RDI_CFG0_DATA_TYPE;
	/* CSID pad 4 is PIX, not CSI VC 3. Sensor packets are VC 0. */
	val |= 1 << IPP_PIX_STORE_EN;
'''
    if old not in text:
        raise SystemExit(f"{path}: IPP CSI VC0 needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: IPP CSI VC0")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "CSI VC 0 feeds IPP when pad 4 is PIX" not in text:
    old = '''static bool csid_vc_feeds_pix(struct csid_device *csid, u8 vc)
{
	struct media_pad *remote;
	struct v4l2_subdev *sd;
	struct vfe_line *line;

	if (csid_is_lite(csid))
		return false;

	remote = media_pad_remote_pad_first(&csid->pads[MSM_CSID_PAD_FIRST_SRC + vc]);
	if (!remote)
		return false;

	sd = media_entity_to_v4l2_subdev(remote->entity);
	if (!sd)
		return false;

	line = v4l2_get_subdevdata(sd);
	return line && line->id == VFE_LINE_PIX;
}
'''
    new = '''static bool csid_pad_is_pix(struct csid_device *csid, unsigned int pad)
{
	struct media_pad *remote;
	struct v4l2_subdev *sd;
	struct vfe_line *line;

	if (pad >= MSM_CSID_PADS_NUM)
		return false;

	remote = media_pad_remote_pad_first(&csid->pads[pad]);
	if (!remote)
		return false;

	sd = media_entity_to_v4l2_subdev(remote->entity);
	if (!sd)
		return false;

	line = v4l2_get_subdevdata(sd);
	return line && line->id == VFE_LINE_PIX;
}

static bool csid_vc_feeds_pix(struct csid_device *csid, u8 vc)
{
	unsigned int pix_pad = MSM_CSID_PADS_NUM - 1;

	if (csid_is_lite(csid))
		return false;

	if (csid_pad_is_pix(csid, MSM_CSID_PAD_FIRST_SRC + vc))
		return true;

	/*
	 * CSI VC 0 feeds IPP when pad 4 is PIX. en_vc is the CSI
	 * virtual-channel mask (bit 0), not the media pad index.
	 */
	return vc == 0 && csid_pad_is_pix(csid, pix_pad);
}
'''
    if old not in text:
        raise SystemExit(f"{path}: csid_vc_feeds_pix needle missing")
    text = text.replace(old, new, 1)
    old = '''static void __csid_configure_ipp_stream(struct csid_device *csid, u8 enable, u8 vc)
{
	struct v4l2_mbus_framefmt *input_format = &csid->fmt[MSM_CSID_PAD_FIRST_SRC + vc];
	const struct csid_format_info *format = csid_get_fmt_entry(csid->res->formats->formats,
								   csid->res->formats->nformats,
								   input_format->code);
	u32 val;
'''
    new = '''static void __csid_configure_ipp_stream(struct csid_device *csid, u8 enable, u8 vc)
{
	unsigned int pix_pad = MSM_CSID_PADS_NUM - 1;
	struct v4l2_mbus_framefmt *input_format = &csid->fmt[pix_pad];
	const struct csid_format_info *format;
	u32 val;

	if (!input_format->width || !input_format->height)
		input_format = &csid->fmt[MSM_CSID_PAD_FIRST_SRC + vc];
	format = csid_get_fmt_entry(csid->res->formats->formats,
				    csid->res->formats->nformats,
				    input_format->code);
'''
    if old not in text:
        raise SystemExit(f"{path}: IPP pad-4 format needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: CSI VC 0 feeds IPP when pad 4 is PIX")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "dagu csid ipp status=" not in text:
    old = '''	if (enable)
		dev_info(csid->camss->dev,
			 "dagu csid ipp vc=%u decode=%u %ux%u cfg0=0x%x\\n",
			 vc, format->decode_format,
			 input_format->width, input_format->height,
			 readl_relaxed(csid->base + CSID_IPP_CFG0));
}
'''
    new = '''	if (enable)
		dev_info(csid->camss->dev,
			 "dagu csid ipp vc=%u decode=%u %ux%u cfg0=0x%x\\n",
			 vc, format->decode_format,
			 input_format->width, input_format->height,
			 readl_relaxed(csid->base + CSID_IPP_CFG0));
	else
		dev_info(csid->camss->dev,
			 "dagu csid ipp status=0x%x meas0=0x%x meas1=0x%x sof=0x%x/0x%x\\n",
			 readl_relaxed(csid->base + 0x254),
			 readl_relaxed(csid->base + 0x278),
			 readl_relaxed(csid->base + 0x27c),
			 readl_relaxed(csid->base + 0x290),
			 readl_relaxed(csid->base + 0x294));
}
'''
    if old not in text:
        raise SystemExit(f"{path}: IPP status dump needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: IPP STREAMOFF status dump")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "dagu csid ipp off " not in text:
    old = '''				dev_info(csid->camss->dev,
					 "dagu csid phy=%u lanes=%u assign=0x%x cfg0=0x%x\\n",
					 csid->phy.csiphy_id, csid->phy.lane_cnt,
					 csid->phy.lane_assign,
					 readl_relaxed(csid->base + CSID_CSI2_RX_CFG0));
			}
		}
'''
    new = '''				dev_info(csid->camss->dev,
					 "dagu csid phy=%u lanes=%u assign=0x%x cfg0=0x%x\\n",
					 csid->phy.csiphy_id, csid->phy.lane_cnt,
					 csid->phy.lane_assign,
					 readl_relaxed(csid->base + CSID_CSI2_RX_CFG0));
			}
		}

	if (!enable && !csid_is_lite(csid) &&
	    csid_pad_is_pix(csid, MSM_CSID_PADS_NUM - 1))
		dev_info(csid->camss->dev,
			 "dagu csid ipp off status=0x%x meas0=0x%x meas1=0x%x sof=0x%x/0x%x cfg0=0x%x\\n",
			 readl_relaxed(csid->base + 0x254),
			 readl_relaxed(csid->base + 0x278),
			 readl_relaxed(csid->base + 0x27c),
			 readl_relaxed(csid->base + 0x290),
			 readl_relaxed(csid->base + 0x294),
			 readl_relaxed(csid->base + CSID_IPP_CFG0));
'''
    if old not in text:
        raise SystemExit(f"{path}: IPP streamoff dump needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: IPP dump on any PIX STREAMOFF")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "CSID_IPP_IRQ_STATUS" not in text:
    old = '''#define CSID_IPP_ERR_RECOVERY_CFG0	0x2d0
#define     IPP_PIX_STORE_EN		7
#define     IPP_OVERFLOW_CTRL_EN	1
'''
    new = '''#define CSID_IPP_ERR_RECOVERY_CFG0	0x2d0
#define CSID_IPP_IRQ_STATUS		0x30
#define CSID_IPP_IRQ_MASK		0x34
#define CSID_IPP_IRQ_CLEAR		0x38
#define     IPP_PIX_STORE_EN		7
#define     IPP_OVERFLOW_CTRL_EN	1
#define     IPP_IRQ_FIFO_OVERFLOW	2
#define     IPP_IRQ_INPUT_EOF		9
#define     IPP_IRQ_INPUT_SOF		12
'''
    if old not in text:
        raise SystemExit(f"{path}: IPP IRQ define needle missing")
    text = text.replace(old, new, 1)
    old = '''	writel_relaxed(IPP_OVERFLOW_CTRL_EN | 0x8,
		       csid->base + CSID_IPP_ERR_RECOVERY_CFG0);

	val = readl_relaxed(csid->base + CSID_IPP_CFG0);
'''
    new = '''	writel_relaxed(IPP_OVERFLOW_CTRL_EN | 0x8,
		       csid->base + CSID_IPP_ERR_RECOVERY_CFG0);

	if (enable)
		writel_relaxed(BIT(IPP_IRQ_FIFO_OVERFLOW) |
			       BIT(IPP_IRQ_INPUT_EOF) |
			       BIT(IPP_IRQ_INPUT_SOF),
			       csid->base + CSID_IPP_IRQ_MASK);
	else
		writel_relaxed(0, csid->base + CSID_IPP_IRQ_MASK);

	val = readl_relaxed(csid->base + CSID_IPP_CFG0);
'''
    if old not in text:
        raise SystemExit(f"{path}: IPP IRQ mask needle missing")
    text = text.replace(old, new, 1)
    old = '''	val = readl_relaxed(csid->base + CSID_CSI2_RX_IRQ_STATUS);
	writel_relaxed(val, csid->base + CSID_CSI2_RX_IRQ_CLEAR);

	/* Read and clear IRQ status for each enabled RDI channel */
'''
    new = '''	val = readl_relaxed(csid->base + CSID_CSI2_RX_IRQ_STATUS);
	writel_relaxed(val, csid->base + CSID_CSI2_RX_IRQ_CLEAR);

	if (!csid_is_lite(csid)) {
		val = readl_relaxed(csid->base + CSID_IPP_IRQ_STATUS);
		writel_relaxed(val, csid->base + CSID_IPP_IRQ_CLEAR);
		if (val)
			dev_info_ratelimited(csid->camss->dev,
					     "dagu csid ipp irq=0x%x\\n", val);
	}

	/* Read and clear IRQ status for each enabled RDI channel */
'''
    if old not in text:
        raise SystemExit(f"{path}: IPP IRQ ISR needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: IPP SOF/overflow IRQ")

# #394: front IPP overflow_ctrl off (bit17 back-pressure recover-push).
path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "Overflow due to back pressure" not in text:
    old = '''	writel_relaxed(IPP_OVERFLOW_CTRL_EN | 0x8,
		       csid->base + CSID_IPP_ERR_RECOVERY_CFG0);
'''
    new = '''	/*
	 * #394 on #408: errrec=0x0 stuck, PIXEL PIPE OVERFLOW gone,
	 * ipp_bp=False, second CAMIF SOF, still 4591616. IPP irq
	 * bit17 is CAF CSID_PATH_OVERFLOW_RECOVERY "Overflow due to
	 * back pressure". Extra CSID recover line was the overflow.
	 * Keep front overflow_ctrl=0. Rear stays CAF 0x9. Do not
	 * crop last. Do not retry EARLY_EOF / CAMIF EN pulse /
	 * overflow buf_done.
	 */
	if (input_format->width == 2592 && input_format->height == 1952)
		writel_relaxed(0, csid->base + CSID_IPP_ERR_RECOVERY_CFG0);
	else
		writel_relaxed(IPP_OVERFLOW_CTRL_EN | 0x8,
			       csid->base + CSID_IPP_ERR_RECOVERY_CFG0);
'''
    if old not in text:
        raise SystemExit(f"{path}: #394 IPP overflow_ctrl needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: #394 front IPP overflow_ctrl off")

# Titan 480 IPP CFG0 bit2 is horizontal_bin_en. RDI TIMESTAMP_EN must
# not be copied onto IPP — it 2×-bins 4080→2040 and overflows Demux.
path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
old = '''	val = 1 << RDI_CFG0_BYTE_CNTR_EN;
	val |= 1 << RDI_CFG0_FORMAT_MEASURE_EN;
	val |= 1 << RDI_CFG0_TIMESTAMP_EN;
	val |= 1 << RDI_CFG0_CROP_H_EN;
	val |= 1 << RDI_CFG0_CROP_V_EN;
	val |= format->decode_format << RDI_CFG0_DECODE_FORMAT;
	val |= format->data_type << RDI_CFG0_DATA_TYPE;
	val |= 1 << IPP_PIX_STORE_EN;
'''
new = '''	/*
	 * CAF cam_ife_csid_core.c IPP CFG0: (1<<1)|1, crop, decode, DT,
	 * pix_store. Titan 480 IPP bit2 is horizontal_bin_en, not RDI
	 * TIMESTAMP_EN. Setting it 2×-bins 4080→2040 and overflows
	 * CAMIF/CLC programmed for full width (debug pixel stuck at 2040).
	 */
	val = 1 << RDI_CFG0_BYTE_CNTR_EN;
	val |= 1 << RDI_CFG0_FORMAT_MEASURE_EN;
	val |= 1 << RDI_CFG0_CROP_H_EN;
	val |= 1 << RDI_CFG0_CROP_V_EN;
	val |= format->decode_format << RDI_CFG0_DECODE_FORMAT;
	val |= format->data_type << RDI_CFG0_DATA_TYPE;
	val |= 1 << IPP_PIX_STORE_EN;
'''
if old in text:
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: IPP CFG0 no horizontal_bin")
    text = path.read_text()
if "RDI_CFG0_TIMESTAMP_EN;\n	val |= 1 << RDI_CFG0_CROP_H_EN" in text:
    raise SystemExit(f"{path}: IPP CFG0 still sets RDI TIMESTAMP_EN (horizontal_bin)")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "RDI_CFG0_EARLY_EOF_EN" not in text:
    old = '''	val |= 1 << IPP_PIX_STORE_EN;
	writel_relaxed(val, csid->base + CSID_IPP_CFG0);
'''
    new = '''	val |= 1 << IPP_PIX_STORE_EN;
	/*
	 * #389 CAMIF epoch 368 of CSID 1472 stuck, still line=736.
	 * CAF IPP CFG0 EARLY_EOF_EN (RDI_CFG0 bit29) fires CSID EOF
	 * before the last CSI line so CAMIF/WM can drain. Front
	 * 2592×1952 only. Do not unmask SOT. Do not crop last again.
	 */
	if (input_format->width == 2592 && input_format->height == 1952)
		val |= 1 << RDI_CFG0_EARLY_EOF_EN;
	writel_relaxed(val, csid->base + CSID_IPP_CFG0);
'''
    if old not in text:
        raise SystemExit(f"{path}: #390 IPP EARLY_EOF needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: #390 front IPP EARLY_EOF_EN")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
# #396 dropped front pix_store while chasing 4591616. #501 stride
# 4096 completed that frame. #502 restores CAF bit7 for 2nd COMP.
drop_store = '''	if (!(input_format->width == 2592 && input_format->height == 1952))
		val |= 1 << IPP_PIX_STORE_EN;'''
if drop_store in text:
    text = text.replace(drop_store, "	val |= 1 << IPP_PIX_STORE_EN;", 1)
    path.write_text(text)
    print(f"patched {path}: #502 front IPP pix_store on")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "dagu csid ipp sof recrop" not in text:
    old = '''		if (val)
			dev_info_ratelimited(csid->camss->dev,
					     "dagu csid ipp irq=0x%x\\n", val);
	}
'''
    new = '''		if (val)
			dev_info_ratelimited(csid->camss->dev,
					     "dagu csid ipp irq=0x%x\\n", val);
		if (val & BIT(IPP_IRQ_INPUT_SOF)) {
			unsigned int pix_pad = MSM_CSID_PADS_NUM - 1;
			struct v4l2_mbus_framefmt *f = &csid->fmt[pix_pad];
			u32 h, v;

			if (!f->width || !f->height)
				f = &csid->fmt[MSM_CSID_PAD_FIRST_SRC];
			if (f->width && f->height) {
				h = ((f->width - 1) << 16);
				if (f->width == 2592 && f->height == 1952)
					v = (0x05bf << 16);
				else
					v = ((f->height - 1) << 16);
				writel_relaxed(h, csid->base + CSID_IPP_HCROP);
				writel_relaxed(v, csid->base + CSID_IPP_VCROP);
				wmb();
				dev_info_ratelimited(csid->camss->dev,
						     "dagu csid ipp sof recrop h=0x%x v=0x%x meas=0x%x/0x%x\\n",
						     h, v,
						     readl_relaxed(csid->base + 0x278),
						     readl_relaxed(csid->base + 0x27c));
			}
		}
	}
'''
    if old not in text:
        raise SystemExit(f"{path}: #504 IPP SOF recrop needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: #504 IPP SOF recrop")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
if "clips chroma WM" not in text:
    old = '''	/*
	 * #389 CAMIF epoch 368 of CSID 1472 stuck, still line=736
	 * 4591616. CAF IPP CFG0 EARLY_EOF_EN (RDI_CFG0 bit29) fires
	 * CSID EOF before the last CSI line so CAMIF/WM can drain.
	 * Front 2592×1952 only; rear already DQBUF 3 frames. Do not
	 * unmask SOT. Do not crop last again.
	 */
	if (input_format->width == 2592 && input_format->height == 1952)
		val |= 1 << RDI_CFG0_EARLY_EOF_EN;
	writel_relaxed(val, csid->base + CSID_IPP_CFG0);
'''
    new = '''	/*
	 * #397: #396 pix_store=0 stuck on #410, still 4591616,
	 * UV 659.145 lines (last_partial=336), Y 88-102 UV~132.5,
	 * pix_store=False, early_eof=True cfg0=0xa02b2063. Overflow
	 * is gone (#394 errrec=0). EARLY_EOF still fires CSID EOF
	 * before the last CSI line and clips chroma WM. Front bit29
	 * off. Rear never set it. Keep errrec=0.
	 * Do not retry EARLY_EOF ON. Do not crop last.
	 */
	writel_relaxed(val, csid->base + CSID_IPP_CFG0);
'''
    if old not in text:
        old = old.replace('still line=736\n', 'still line=736.\n')
    if old not in text:
        raise SystemExit(f"{path}: #397 IPP EARLY_EOF off needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: #397 front IPP EARLY_EOF off")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
wrap_old = '''	 * #412 identity feeds full 1951. Do not retry 0x05bf as the
	 * chroma gap.
'''
wrap_new = '''	 * #412 identity feeds full 1951. Do not retry 0x05bf as the chroma gap.
'''
if wrap_old in text:
    text = text.replace(wrap_old, wrap_new, 1)
    path.write_text(text)
    print(f"patched {path}: #412 CSID 1472 comment wrap")
    text = path.read_text()
# Display Full restores CSID window last 0x05bf. Identity keep-all
# 1951 was AXI silent (#412).
if "val = (0x05bf << 16) | 0" not in text:
    old = '''	/*
	 * #387 VCROP last 0x05bf << 16 (1472) for Display Full 2320.
	 * #412 identity feeds full 1951. Do not retry 0x05bf as the chroma gap.
	 */
	val = ((input_format->height - 1) << 16) | 0;
	writel_relaxed(val, csid->base + CSID_IPP_VCROP);
'''
    new = '''	/*
	 * #387 VCROP last 0x05bf << 16 (1472) for Display Full 2320.
	 * #412 identity keep-all 1951 was AXI silent. Display Full
	 * restores CSID window last 0x05bf. Do not retry 0x05bf as the chroma gap.
	 */
	if (input_format->width == 2592 && input_format->height == 1952)
		val = (0x05bf << 16) | 0;
	else
		val = ((input_format->height - 1) << 16) | 0;
	writel_relaxed(val, csid->base + CSID_IPP_VCROP);
'''
    if old not in text:
        raise SystemExit(f"{path}: Display Full IPP VCROP 0x05bf needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: Display Full IPP VCROP last 0x05bf")

path = root / "drivers/media/platform/qcom/camss/camss-csid.c"
text = path.read_text()
if "dagu: CSID does not stomp IFE core" not in text:
    old = '''		} else if (clock->nfreqs) {
			clk_set_rate(clock->clk, clock->freq[0]);
		}
'''
    new = '''		} else if (clock->nfreqs) {
			/*
			 * dagu: CSID does not stomp IFE core. Titan CSID
			 * lists vfe0/vfe1 so the branch stays enabled; VFE
			 * already picked 576 MHz for PIX. freq[0] is 350.
			 */
			if (!strcmp(clock->name, "vfe0") ||
			    !strcmp(clock->name, "vfe1") ||
			    !strcmp(clock->name, "vfe_lite") ||
			    !strncmp(clock->name, "vfe_lite", 8))
				continue;
			clk_set_rate(clock->clk, clock->freq[0]);
		}
'''
    if old not in text:
        raise SystemExit(f"{path}: CSID clock freq[0] needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: CSID does not stomp IFE core")

path = root / "drivers/media/platform/qcom/camss/camss-vfe.c"
text = path.read_text()
if "dagu: raise VFE clock instead of EBUSY" not in text:
    old = '''			rate = clk_get_rate(clock->clk);
			if (rate < min_rate)
				return -EBUSY;
'''
    new = '''			rate = clk_get_rate(clock->clk);
			if (rate >= min_rate)
				continue;

			/*
			 * dagu: raise VFE clock instead of EBUSY.
			 * clk_rcg2_shared_ops parks IFE at 350 MHz; CSID
			 * used to clk_set_rate(vfe0, freq[0]) on top.
			 * PIX needs the 576 MHz bin for 560 MHz CSI.
			 */
			for (j = 0; j < clock->nfreqs; j++)
				if (min_rate < clock->freq[j])
					break;
			if (j == clock->nfreqs) {
				dev_err(vfe->camss->dev,
					"dagu %s get=%lu min=%llu too high\\n",
					clock->name, rate, min_rate);
				return -EBUSY;
			}

			{
				long new_rate;
				int set_ret;

				new_rate = clk_round_rate(clock->clk,
							  clock->freq[j]);
				if (new_rate < 0)
					return -EINVAL;
				set_ret = clk_set_rate(clock->clk, new_rate);
				if (set_ret < 0)
					return set_ret;
				dev_info(vfe->camss->dev,
					 "dagu %s raise %lu -> %ld (min=%llu)\\n",
					 clock->name, rate, new_rate, min_rate);
			}
'''
    if old not in text:
        raise SystemExit(f"{path}: vfe_check_clock_rates EBUSY needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: raise VFE clock instead of EBUSY")

path = root / "drivers/media/platform/qcom/camss/camss.c"
text = path.read_text()
if "vfe_res_8250" in text and "formats_pix = &vfe_formats_pix_8250" not in text.split("vfe_res_8250", 1)[-1][:1200]:
    text = text.replace(
        '''		.interrupt = { "vfe0" },
		.vfe = {
			.line_num = 3,
			.has_pd = true,
			.pd_name = "ife0",
			.hw_ops = &vfe_ops_480,
			.formats_rdi = &vfe_formats_rdi_845,
			.formats_pix = &vfe_formats_pix_845
		}''',
        '''		.interrupt = { "vfe0" },
		.vfe = {
			.line_num = 4,
			.has_pd = true,
			.pd_name = "ife0",
			.hw_ops = &vfe_ops_480,
			.formats_rdi = &vfe_formats_rdi_845,
			.formats_pix = &vfe_formats_pix_8250
		}''',
        1,
    )
    text = text.replace(
        '''		.interrupt = { "vfe1" },
		.vfe = {
			.line_num = 3,
			.has_pd = true,
			.pd_name = "ife1",
			.hw_ops = &vfe_ops_480,
			.formats_rdi = &vfe_formats_rdi_845,
			.formats_pix = &vfe_formats_pix_845
		}''',
        '''		.interrupt = { "vfe1" },
		.vfe = {
			.line_num = 4,
			.has_pd = true,
			.pd_name = "ife1",
			.hw_ops = &vfe_ops_480,
			.formats_rdi = &vfe_formats_rdi_845,
			.formats_pix = &vfe_formats_pix_8250
		}''',
        1,
    )
    path.write_text(text)
    print(f"patched {path}: dagu titan480 VFE0/1 PIX line_num=4")

# Lite IFE has no CLC. Drop leftover PIX so videoN count stays 14
# (Venus remains /dev/video14 / video15).
text = path.read_text()
if '.reg = { "vfe_lite0" }' in text and "is_lite = true,\n			.line_num = 4" in text.split("vfe_lite0", 1)[-1][:400]:
    text = text.replace(
        '''		.reg = { "vfe_lite0" },
		.interrupt = { "vfe_lite0" },
		.vfe = {
			.is_lite = true,
			.line_num = 4,''',
        '''		.reg = { "vfe_lite0" },
		.interrupt = { "vfe_lite0" },
		.vfe = {
			.is_lite = true,
			.line_num = 3,''',
        1,
    )
    text = text.replace(
        '''		.reg = { "vfe_lite1" },
		.interrupt = { "vfe_lite1" },
		.vfe = {
			.is_lite = true,
			.line_num = 4,''',
        '''		.reg = { "vfe_lite1" },
		.interrupt = { "vfe_lite1" },
		.vfe = {
			.is_lite = true,
			.line_num = 3,''',
        1,
    )
    path.write_text(text)
    print(f"patched {path}: dagu titan480 VFE lite no PIX")

path = root / "drivers/media/platform/qcom/camss/camss-vfe.c"
text = path.read_text()
if "vfe_formats_pix_8250" not in text:
    old = '''const struct camss_formats vfe_formats_pix_845 = {
	.nformats = ARRAY_SIZE(formats_rdi_845),
	.formats = formats_rdi_845
};
'''
    new = '''const struct camss_formats vfe_formats_pix_845 = {
	.nformats = ARRAY_SIZE(formats_rdi_845),
	.formats = formats_rdi_845
};

/* Titan 480 PIX: Bayer sink (CSID IPP) → NV12 source (IFE DISP). */
static const struct camss_format_info formats_pix_8250[] = {
	{ MEDIA_BUS_FMT_SBGGR10_1X10, 10, V4L2_PIX_FMT_NV12, 1,
	  PER_PLANE_DATA(0, 1, 1, 2, 3, 8) },
	{ MEDIA_BUS_FMT_SGBRG10_1X10, 10, V4L2_PIX_FMT_NV12, 1,
	  PER_PLANE_DATA(0, 1, 1, 2, 3, 8) },
	{ MEDIA_BUS_FMT_SGRBG10_1X10, 10, V4L2_PIX_FMT_NV12, 1,
	  PER_PLANE_DATA(0, 1, 1, 2, 3, 8) },
	{ MEDIA_BUS_FMT_SRGGB10_1X10, 10, V4L2_PIX_FMT_NV12, 1,
	  PER_PLANE_DATA(0, 1, 1, 2, 3, 8) },
	{ MEDIA_BUS_FMT_YUYV8_1_5X8, 8, V4L2_PIX_FMT_NV12, 1,
	  PER_PLANE_DATA(0, 1, 1, 2, 3, 8) },
};

const struct camss_formats vfe_formats_pix_8250 = {
	.nformats = ARRAY_SIZE(formats_pix_8250),
	.formats = formats_pix_8250
};
'''
    if old not in text:
        raise SystemExit(f"{path}: pix_8250 table needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: vfe_formats_pix_8250")

path = root / "drivers/media/platform/qcom/camss/camss-vfe.h"
text = path.read_text()
if "vfe_formats_pix_8250" not in text:
    old = "extern const struct camss_formats vfe_formats_pix_845;\n"
    new = """extern const struct camss_formats vfe_formats_pix_845;
extern const struct camss_formats vfe_formats_pix_8250;
"""
    if old not in text:
        raise SystemExit(f"{path}: pix_845 extern needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: vfe_formats_pix_8250")

path = root / "drivers/media/platform/qcom/camss/camss-vfe.c"
text = path.read_text()
if "line->id == VFE_LINE_PIX &&\n	    vfe->camss->res->version == CAMSS_8250" not in text:
    old = '''static u32 vfe_src_pad_code(struct vfe_line *line, u32 sink_code,
			    unsigned int index, u32 src_req_code)
{
	struct vfe_device *vfe = to_vfe(line);

	switch (vfe->camss->res->version) {
'''
    new = '''static u32 vfe_src_pad_code(struct vfe_line *line, u32 sink_code,
			    unsigned int index, u32 src_req_code)
{
	struct vfe_device *vfe = to_vfe(line);

	if (vfe->camss->res->version == CAMSS_8250 &&
	    line->id == VFE_LINE_PIX) {
		switch (sink_code) {
		case MEDIA_BUS_FMT_SBGGR8_1X8:
		case MEDIA_BUS_FMT_SGBRG8_1X8:
		case MEDIA_BUS_FMT_SGRBG8_1X8:
		case MEDIA_BUS_FMT_SRGGB8_1X8:
		case MEDIA_BUS_FMT_SBGGR10_1X10:
		case MEDIA_BUS_FMT_SGBRG10_1X10:
		case MEDIA_BUS_FMT_SGRBG10_1X10:
		case MEDIA_BUS_FMT_SRGGB10_1X10:
		case MEDIA_BUS_FMT_SBGGR12_1X12:
		case MEDIA_BUS_FMT_SGBRG12_1X12:
		case MEDIA_BUS_FMT_SGRBG12_1X12:
		case MEDIA_BUS_FMT_SRGGB12_1X12:
		case MEDIA_BUS_FMT_SBGGR14_1X14:
		case MEDIA_BUS_FMT_SGBRG14_1X14:
		case MEDIA_BUS_FMT_SGRBG14_1X14:
		case MEDIA_BUS_FMT_SRGGB14_1X14:
		{
			u32 src_code[] = {
				MEDIA_BUS_FMT_YUYV8_1_5X8,
			};

			return camss_format_find_code(src_code, ARRAY_SIZE(src_code),
						      index, src_req_code);
		}
		default:
			break;
		}
	}

	switch (vfe->camss->res->version) {
'''
    if old not in text:
        raise SystemExit(f"{path}: src_pad_code needle missing")
    text = text.replace(old, new, 1)
    old = '''	if (output->buf[index]) {
		ops->vfe_wm_update(vfe, output->wm_idx[0],
				   output->buf[index]->addr[0],
				   line);
		ops->reg_update(vfe, line->id);
	} else {
'''
    new = '''	if (output->buf[index]) {
		unsigned int j;

		for (j = 0; j < output->wm_num; j++)
			ops->vfe_wm_update(vfe, output->wm_idx[j],
					   output->buf[index]->addr[j],
					   line);
		ops->reg_update(vfe, line->id);
	} else {
'''
    if old not in text:
        raise SystemExit(f"{path}: buf_done wm needle missing")
    text = text.replace(old, new, 1)
    old = '''	ops->vfe_wm_start(vfe, output->wm_idx[0], line);

	for (i = 0; i < CAMSS_INIT_BUF_COUNT; i++) {
		output->buf[i] = vfe_buf_get_pending(output);
		if (!output->buf[i])
			break;
		output->gen2.active_num++;
		ops->vfe_wm_update(vfe, output->wm_idx[0],
				   output->buf[i]->addr[0], line);
		ops->reg_update(vfe, line->id);
	}
'''
    new = '''	for (i = 0; i < output->wm_num; i++)
		ops->vfe_wm_start(vfe, output->wm_idx[i], line);

	for (i = 0; i < CAMSS_INIT_BUF_COUNT; i++) {
		unsigned int j;

		output->buf[i] = vfe_buf_get_pending(output);
		if (!output->buf[i])
			break;
		output->gen2.active_num++;
		for (j = 0; j < output->wm_num; j++)
			ops->vfe_wm_update(vfe, output->wm_idx[j],
					   output->buf[i]->addr[j], line);
		ops->reg_update(vfe, line->id);
	}
'''
    if old not in text:
        raise SystemExit(f"{path}: enable_output wm needle missing")
    text = text.replace(old, new, 1)
    old = '''	if (output->state == VFE_OUTPUT_ON &&
	    output->gen2.active_num < 2) {
		output->buf[output->gen2.active_num++] = buf;
		ops->vfe_wm_update(vfe, output->wm_idx[0],
				   buf->addr[0], line);
		ops->reg_update(vfe, line->id);
	} else {
'''
    new = '''	if (output->state == VFE_OUTPUT_ON &&
	    output->gen2.active_num < 2) {
		unsigned int j;

		output->buf[output->gen2.active_num++] = buf;
		for (j = 0; j < output->wm_num; j++)
			ops->vfe_wm_update(vfe, output->wm_idx[j],
					   buf->addr[j], line);
		ops->reg_update(vfe, line->id);
	} else {
'''
    if old not in text:
        raise SystemExit(f"{path}: queue_buffer wm needle missing")
    text = text.replace(old, new, 1)
    old = '''	output->wm_num = 1;

	/* Correspondence between VFE line number and WM number.
	 * line 0 -> RDI 0, line 1 -> RDI1, line 2 -> RDI2, line 3 -> PIX/RDI3
	 * Note this 1:1 mapping will not work for PIX streams.
	 */
	output->wm_idx[0] = line->id;
	vfe->wm_output_map[line->id] = line->id;
'''
    new = '''	if (line->id == VFE_LINE_PIX &&
	    vfe->camss->res->version == CAMSS_8250 &&
	    !vfe_is_lite(vfe)) {
		output->wm_num = 2;
		output->wm_idx[0] = 4;
		output->wm_idx[1] = 5;
		vfe->wm_output_map[4] = line->id;
	} else {
		output->wm_num = 1;

		/* Correspondence between VFE line number and WM number.
		 * line 0 -> RDI 0, line 1 -> RDI1, line 2 -> RDI2, line 3 -> PIX/RDI3
		 * Note this 1:1 mapping will not work for PIX streams.
		 */
		output->wm_idx[0] = line->id;
		vfe->wm_output_map[line->id] = line->id;
	}
'''
    if old not in text:
        raise SystemExit(f"{path}: get_output_v2 wm needle missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}: dagu titan480 PIX WM4/5 NV12")

path = root / "drivers/media/platform/qcom/camss/camss-vfe.h"
text = path.read_text()
if "void (*pix_go)(struct vfe_device *vfe);" not in text:
    old = """	void (*vfe_wm_update)(struct vfe_device *vfe, u8 wm, u32 addr,
			      struct vfe_line *line);
};
"""
    new = """	void (*vfe_wm_update)(struct vfe_device *vfe, u8 wm, u32 addr,
			      struct vfe_line *line);
	/* dagu: CAF starts CAMIF after IMAGE_ADDR + RUP, not inside wm_update */
	void (*pix_go)(struct vfe_device *vfe);
};
"""
    if old not in text:
        raise SystemExit(f"{path}: vfe_wm_update ops needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: pix_go after RUP")

path = root / "drivers/media/platform/qcom/camss/camss-vfe.c"
text = path.read_text()
if "ops->pix_go(vfe)" not in text:
    old = """		ops->reg_update(vfe, line->id);
	}

	spin_unlock_irqrestore(&vfe->output_lock, flags);

	return 0;
}

/*
 * vfe_queue_buffer_v2 - Add empty buffer
"""
    new = """		ops->reg_update(vfe, line->id);
	}

	/* dagu: CAF starts CAMIF after CDM IMAGE_ADDR and RUP */
	if (line->id == VFE_LINE_PIX && ops->pix_go)
		ops->pix_go(vfe);

	spin_unlock_irqrestore(&vfe->output_lock, flags);

	return 0;
}

/*
 * vfe_queue_buffer_v2 - Add empty buffer
"""
    if old not in text:
        raise SystemExit(f"{path}: enable_output_v2 pix_go needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: pix_go after init RUP")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if ".hts = 5888" not in text:
    old = """		.width = 4080,
		.height = 3060,
		.hts = 4352,
		.vts = 4288,
"""
    new = """		.width = 4080,
		.height = 3060,
		.hts = 5888,
		.vts = 3164,
"""
    if old not in text:
        raise SystemExit(f"{path}: 4080 hts/vts needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: CamX 4080 HTS/VTS")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "dagu: default <= VTS-margin" not in text:
    old = """		.hts = 5888,
		.vts = 3164,
		.exposure = 3840,
"""
    new = """		.hts = 5888,
		.vts = 3164,
		.exposure = 3000, /* dagu: default <= VTS-margin (3164-22) */
"""
    if old not in text:
        raise SystemExit(f"{path}: 4080 exposure needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: CamX 4080 exposure default")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "stop MCU init on 0x2400" not in text:
    old_4000_tail = """	{ CCI_REG16(0x6f12), 0x9600 },
	{ CCI_REG16(0x6028), 0x4000 },
	{ CCI_REG16(0xf44e), 0x0011 },
	{ CCI_REG16(0xf44c), 0x0b0b },
	{ CCI_REG16(0xf44a), 0x0006 },
	{ CCI_REG16(0x0118), 0x0002 },
	{ CCI_REG16(0x011a), 0x0001 },
	{ CCI_REG16(0x6028), 0x4000 },
	{ CCI_REG16(0x0106), 0x0001 },
	/* dagu: omit 0x0bcc / trailing 0x2400 — Qtech NACKs after 0x4000 tail */
};
"""
    old_4000_vanilla = """	{ CCI_REG16(0x6f12), 0x9600 },
	{ CCI_REG16(0x6028), 0x4000 },
	{ CCI_REG16(0xf44e), 0x0011 },
	{ CCI_REG16(0xf44c), 0x0b0b },
	{ CCI_REG16(0xf44a), 0x0006 },
	{ CCI_REG16(0x0118), 0x0002 },
	{ CCI_REG16(0x011a), 0x0001 },
	{ CCI_REG16(0x6028), 0x4000 },
	{ CCI_REG16(0x0106), 0x0001 },
	{ CCI_REG16(0x0bcc), 0x0000 },
	{ CCI_REG16(0x6028), 0x2400 },
	{ CCI_REG16(0x602a), 0x2174 },
	{ CCI_REG16(0x6f12), 0x0400 },
};
"""
    new = """	{ CCI_REG16(0x6f12), 0x9600 },
	/* dagu: stop MCU init on 0x2400; 0x4000 tail kills MCU page on Qtech */
};
"""
    if old_4000_tail in text:
        text = text.replace(old_4000_tail, new, 1)
    elif old_4000_vanilla in text:
        text = text.replace(old_4000_vanilla, new, 1)
    else:
        raise SystemExit(f"{path}: MCU 0x2400 cut needle missing")
    path.write_text(text)
    print(f"patched {path}: stop MCU init on 0x2400")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "dagu: mode table while MCU page" not in text and \
   "dagu: 0x2400 delay sweep then 0x4000 mode" not in text:
    old_retry = """	cci_multi_reg_write(s5kjn1->regmap, init_array_setting,
			    ARRAY_SIZE(init_array_setting), &ret);
	if (ret)
		goto error;
	/* Qtech: 0x4000 tail then 0x2400 often NACKs; retry before CamX mode. */
	{
		int i;

		for (i = 0; i < 20; i++) {
			ret = 0;
			cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &ret);
			if (!ret)
				break;
			dev_info(s5kjn1->dev,
				 "dagu s5kjn1 post-init 0x2400 retry %d: %d\\n",
				 i, ret);
			msleep(10);
		}
		if (ret)
			goto error;
	}
	cci_multi_reg_write(s5kjn1->regmap, reg_list->regs,
			    reg_list->num_regs, &ret);
	if (ret)
		goto error;
"""
    old_plain = """	cci_multi_reg_write(s5kjn1->regmap, init_array_setting,
			    ARRAY_SIZE(init_array_setting), &ret);
	cci_multi_reg_write(s5kjn1->regmap, reg_list->regs,
			    reg_list->num_regs, &ret);
	if (ret)
		goto error;
"""
    new = """	cci_multi_reg_write(s5kjn1->regmap, init_array_setting,
			    ARRAY_SIZE(init_array_setting), &ret);
	if (ret)
		goto error;
	/* dagu: mode table while MCU page 0x2400 is still alive. */
	cci_multi_reg_write(s5kjn1->regmap, reg_list->regs,
			    reg_list->num_regs, &ret);
	if (ret)
		goto error;
"""
    if old_retry in text:
        text = text.replace(old_retry, new, 1)
    elif old_plain in text:
        text = text.replace(old_plain, new, 1)
    else:
        raise SystemExit(f"{path}: mode table MCU page needle missing")
    path.write_text(text)
    print(f"patched {path}: mode table while MCU page 0x2400")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "MODE_SELECT before 0x2174" not in text and \
   "dagu: 0x2400 delay sweep then 0x4000 mode" not in text:
    new = """	ret = __v4l2_ctrl_handler_setup(s5kjn1->sd.ctrl_handler);

	/* 0x0a70 then MODE_SELECT while MCU is halted, then 0x2174. */
	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x0a70, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0001, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x0a72, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0100, &ret);
	if (ret)
		goto error;
	cci_write(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE,
		  S5KJN1_MODE_STREAMING, &ret);
	if (ret) {
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 MODE_SELECT before 0x2174 NACK %d\\n", ret);
		goto error;
	}
	{
		int page_ret = 0;

		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &page_ret);
		if (!page_ret) {
			cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x2174, &page_ret);
			cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0401, &page_ret);
			if (page_ret)
				dev_info(s5kjn1->dev, "dagu s5kjn1 0x2174 NACK %d\\n",
					 page_ret);
		} else {
			dev_info(s5kjn1->dev,
				 "dagu s5kjn1 post-mode 0x2400 NACK %d\\n",
				 page_ret);
		}
	}

	dev_info(s5kjn1->dev, "dagu s5kjn1 streaming %ux%u\\n",
"""
    olds = [
        """	ret = __v4l2_ctrl_handler_setup(s5kjn1->sd.ctrl_handler);

	cci_write(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE,
		  S5KJN1_MODE_STREAMING, &ret);
	if (ret)
		goto error;

	dev_info(s5kjn1->dev, "dagu s5kjn1 streaming %ux%u\\n",
""",
    ]
    for old in olds:
        if old in text:
            text = text.replace(old, new, 1)
            break
    else:
        raise SystemExit(f"{path}: stream-on MODE_SELECT-continue needle missing")
    path.write_text(text)
    print(f"patched {path}: MODE_SELECT before 0x2174; NACK continues")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "num_data_lanes != 3 &&" not in text:
    old = """	if (bus_cfg.bus.mipi_csi2.num_data_lanes != S5KJN1_DATA_LANES) {
"""
    new = """	if (bus_cfg.bus.mipi_csi2.num_data_lanes != 3 &&
	    bus_cfg.bus.mipi_csi2.num_data_lanes != S5KJN1_DATA_LANES) {
"""
    if old not in text:
        raise SystemExit(f"{path}: DATA_LANES check needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: allow 3 C-PHY trios")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "dagu: accept C-PHY in check_hwcfg" not in text:
    old = """		.bus_type = V4L2_MBUS_CSI2_DPHY,
	};
	unsigned long freq_bitmap;
	int ret;
"""
    new = """		.bus_type = V4L2_MBUS_UNKNOWN, /* dagu: accept C-PHY in check_hwcfg */
	};
	unsigned long freq_bitmap;
	int ret;
"""
    if old not in text:
        raise SystemExit(f"{path}: check_hwcfg bus_type needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: accept C-PHY in check_hwcfg")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "dagu: CCI settle after XSHUTDOWN" not in text and \
   "dagu: VIO then VANA then VDIG" not in text:
    old = """	gpiod_set_value_cansleep(s5kjn1->reset_gpio, 0);
	usleep_range(10 * USEC_PER_MSEC, 15 * USEC_PER_MSEC);

	return 0;
"""
    new = """	gpiod_set_value_cansleep(s5kjn1->reset_gpio, 1);
	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(s5kjn1->reset_gpio, 0);
	msleep(20); /* dagu: CCI settle after XSHUTDOWN */

	return 0;
"""
    if old not in text:
        raise SystemExit(f"{path}: reset deassert needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: XSHUTDOWN pulse")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "dagu s5kjn1 0x6028 retry" not in text:
    old = """	/* Page pointer */
	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);

	/* Set version */
"""
    new = """	/* Page pointer. First CCI access often NACKs; retry. */
	{
		int i;

		for (i = 0; i < 10; i++) {
			ret = 0;
			cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
			if (!ret)
				break;
			dev_info(s5kjn1->dev, "dagu s5kjn1 0x6028 retry %d: %d\\n",
				 i, ret);
			msleep(10);
		}
		if (ret)
			goto error;
	}

	/* Set version */
"""
    if old not in text:
        raise SystemExit(f"{path}: 0x6028 page pointer needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: 0x6028 retry")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if '#include "s5kjn1-dagu-regs.h"' not in text:
    old = """#include <media/v4l2-fwnode.h>
"""
    new = """#include <media/v4l2-fwnode.h>

#include "s5kjn1-dagu-regs.h"
"""
    if old not in text:
        raise SystemExit(f"{path}: v4l2-fwnode include needle missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}: include s5kjn1-dagu-regs.h")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "s5kjn1_dagu_2040x1530_mode" not in text and "s5kjn1_dagu_4080x3060_mode" not in text:
    old = """			.regs = s5kjn1_4080x3072_30fps_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_4080x3072_30fps_mode),
"""
    new = """			.regs = s5kjn1_dagu_4080x3060_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_dagu_4080x3060_mode),
"""
    if old not in text:
        raise SystemExit(f"{path}: 4080 mode pointer needle missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}: use CamX 4080 mode table")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "s5kjn1_4080x3072_30fps_mode[] __maybe_unused" not in text:
    old = "static const struct cci_reg_sequence s5kjn1_4080x3072_30fps_mode[] = {"
    new = "static const struct cci_reg_sequence s5kjn1_4080x3072_30fps_mode[] __maybe_unused = {"
    if old not in text:
        raise SystemExit(f"{path}: 4080 array decl needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: mark leftover 4080 array unused")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "dagu: CamX 0x6010/0x6226 SW reset" not in text and \
   "dagu: 0x2400 delay sweep then 0x4000 mode" not in text:
    old_skip = """	/* dagu: skip 0x6010/0x6226 SW reset — post-reset 0x6028 NACKs */

	/* Sensor init settings */
"""
    old_vanilla = """	/* Set version */
	cci_write(s5kjn1->regmap, CCI_REG16(0x0000), 0x0003, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x0000), S5KJN1_CHIP_ID, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x001e), 0x0007, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6010), 0x0001, &ret);
	if (ret)
		goto error;

	usleep_range(5 * USEC_PER_MSEC, 6 * USEC_PER_MSEC);

	cci_write(s5kjn1->regmap, CCI_REG16(0x6226), 0x0001, &ret);
	if (ret)
		goto error;

	usleep_range(10 * USEC_PER_MSEC, 11 * USEC_PER_MSEC);

	/* Sensor init settings */
"""
    new = """	/* CamX: 0x0000=1, chip id, 0x001e=7, 0x6010 then 5 ms, 0x6226=1 then 10 ms. */
	cci_write(s5kjn1->regmap, CCI_REG16(0x0000), 0x0001, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x0000), S5KJN1_CHIP_ID, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x001e), 0x0007, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6010), 0x0001, &ret);
	if (ret)
		goto error;
	usleep_range(5 * USEC_PER_MSEC, 6 * USEC_PER_MSEC);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6226), 0x0001, &ret);
	if (ret)
		goto error;
	usleep_range(10 * USEC_PER_MSEC, 11 * USEC_PER_MSEC);
	/* dagu: CamX 0x6010/0x6226 SW reset; retry 0x2400 while MCU wakes */
	{
		int i;

		for (i = 0; i < 20; i++) {
			ret = 0;
			cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &ret);
			if (!ret)
				break;
			dev_info(s5kjn1->dev, "dagu s5kjn1 0x2400 retry %d: %d\\n",
				 i, ret);
			msleep(10);
		}
		if (ret)
			goto error;
	}

	/* Sensor init settings */
"""
    if old_skip in text:
        text = text.replace(old_skip, new, 1)
    elif old_vanilla in text:
        text = text.replace(old_vanilla, new, 1)
    else:
        raise SystemExit(f"{path}: SW reset needle missing")
    path.write_text(text)
    print(f"patched {path}: CamX SW reset + 0x2400 retry")
if "dagu: CamX 0x6010/0x6226 SW reset" not in path.read_text() and \
   "dagu: 0x2400 delay sweep then 0x4000 mode" not in path.read_text():
    raise SystemExit(f"{path}: CamX SW reset missing after patch")

path = root / "drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c"
text = path.read_text()
if "lane_regs_sm8250_cphy" not in text or "cphy=%u" not in text:
    raise SystemExit(f"{path}: C-PHY 3PH table / lanes_enable missing (CamX 4080)")
if "dagu: CAF 1.2.1 C-PHY data-rate" not in text:
    raise SystemExit(f"{path}: CAF 1.2.1 C-PHY data-rate missing")
if "0x09AC, 0x35" not in text or "0x0144, 0x22" not in text:
    raise SystemExit(f"{path}: Luca 3PH + CAF 2.5G AEQ missing")
if "dagu: hold CTRL0=0 until analog" not in text:
    raise SystemExit(f"{path}: C-PHY CTRL0 hold-0 missing")
if "dagu: C-PHY CTRL0 after analog" not in text:
    raise SystemExit(f"{path}: C-PHY CTRL0 after analog missing")
if "dagu: 2PH CTRL0 after analog" not in text:
    old = """	/* dagu: C-PHY CTRL0 after analog */
	if (cfg->csi2->cphy) {
		udelay(50);
		writel_relaxed(0x0E, csiphy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, 0));
	}
"""
    new = """	/* dagu: C-PHY CTRL0 after analog */
	if (cfg->csi2->cphy) {
		udelay(50);
		writel_relaxed(0x0E, csiphy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, 0));
	} else {
		/* dagu: 2PH CTRL0 after analog — Android s5kjn1 preview 0x0800=0x02 */
		writel_relaxed(0x02, csiphy->base +
			       CSIPHY_3PH_CMN_CSI_COMMON_CTRLn(regs->offset, 0));
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: 2PH CTRL0 after analog needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: 2PH CTRL0 after analog")
    text = path.read_text()
if "dagu: Android s5kjn1 D-PHY settle 0x13" not in text:
    raise SystemExit(f"{path}: D-PHY settle 0x13 missing")
if "if (phy->cphy)" not in (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text():
    raise SystemExit("camss-csid-gen2.c: C-PHY PHY_TYPE_SEL missing")
if "dagu: CSID SOT/EOT stay masked" not in (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text():
    raise SystemExit("camss-csid-gen2.c: CSID SOT mask missing")
if "dagu csid ipp vc=" not in (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text():
    raise SystemExit("camss-csid-gen2.c: Titan 480 CSID IPP missing")
vfe480 = (root / "drivers/media/platform/qcom/camss/camss-vfe-480.c").read_text()
if "CLC_DEMUX" not in vfe480 or "DISP_Y_WM" not in vfe480:
    raise SystemExit("camss-vfe-480.c: PIX CLC/DISP path missing")
if "0x5600" in vfe480.split("CLC_DEMUX", 1)[-1][:80]:
    raise SystemExit("camss-vfe-480.c: CLC_DEMUX 0x5600 is not IFE MMIO")
if "CLC_DEMUX_BASE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Demux CLC EN at 0x3060 missing")
if "DEMUX_EVEN_GBRG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Demux GBRG even/odd missing")
if "vfe_480_clc_enable(vfe, CLC_PREPROCESS, 1)" in vfe480:
    raise SystemExit("camss-vfe-480.c: empty BLS 0x2200 without DMI used literal 1; use identity DMI + BIT(0)")
if "vfe_480_crop(vfe, CLC_PREPROCESS, last_x, last_y)" in vfe480:
    raise SystemExit("camss-vfe-480.c: BLS 0x2268 x0x2e is IQ not Crop11 keep-all")
if "0xffffffff, vfe->base + CAMIF_LINE_SKIP" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF keep-all skip missing")
if "IRQ_MASK_1_CAMIF" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF SOF IRQ1 missing")
if "CSID_IPP_IRQ_STATUS" not in (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text():
    raise SystemExit("camss-csid-gen2.c: IPP IRQ 0x30 missing")
if "#define CLC_DEMOSAIC			0x3800" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Demosaic36 must be CLC 0x3800")
if "#define CLC_MNDS_Y			0x4c00" not in vfe480:
    raise SystemExit("camss-vfe-480.c: MNDS Display Y must be 0x4c00 not stats 0x8c00")
if "CAMIF_CROP_WIDTH" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF crop 0x2668 missing")
if "CORE_CFG_0_DISP_DS4_R2PD" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CORE_CFG R2PD disable missing")
if "CORE_CFG_0_OPERATING_MODE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CORE_CFG online CSID operating_mode missing")
if "DEMUX_PERIOD_KEEPALL" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Demux keep-all period dump map missing")
if "DEMUX_WIN			0x68" not in vfe480 or "DEMUX_WIN_N			10" not in vfe480:
    raise SystemExit("camss-vfe-480.c: FULL Demux 0x3068 dump map missing")
if "DEMUX_COMPACT_CFG		0x3c003c01" not in vfe480:
    raise SystemExit("camss-vfe-480.c: compact Demux live moduleConfig 0x3c003c01 missing")
if "DEMUX_COMPACT_EVEN		0xac" not in vfe480 or "DEMUX_COMPACT_ODD		0xc9" not in vfe480:
    raise SystemExit("camss-vfe-480.c: compact Demux live even/odd 0xac/0xc9 missing")
if "vfe_480_demux(vfe, in_w - 1, pipe_h - 1)" in vfe480:
    raise SystemExit("camss-vfe-480.c: compact Demux is 0x3090 x7; do not pack FULL 0x3068 last/first")
if "static void vfe_480_demux(struct vfe_device *vfe, u32 in_w, u32 in_h)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Demux must take in_w/in_h to gate rear 0x0bf40ff0")
if "vfe_480_demux(vfe, in_w, in_h)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: pix pipeline must pass sensor size into Demux")
if "0x000003c0" not in vfe480 or "0x0bf40ff0" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM Demux 0x3068 x10 missing")
if "0x0000443c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM Demux 0x30ac x10 missing")
if "DEMUX_TAIL			0xac" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX 0x30ac dump addr missing")
if "CLC_DEMUX_TAIL_CROP		0x304c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Demux 0x30ac dump MODULE base 0x304c missing")
if "vfe_480_crop(vfe, CLC_DEMUX_TAIL_CROP, last_x, last_y)" in vfe480:
    raise SystemExit("camss-vfe-480.c: 0x30ac is live CDM 10-word IQ, not Crop11 keep-all")
if "DEMUX_DMI1_N		0x200" not in vfe480 or "DEMUX_DMI2_N		0x100" not in vfe480:
    raise SystemExit("camss-vfe-480.c: FULL Demux DMI dump map missing")
if "CLC_DEMUX_BASE + CLC_DMI_CFG" in vfe480:
    raise SystemExit("camss-vfe-480.c: compact Demux does not pack DMI 0x3008")
if "CLC_DEMUX_BASE + DEMUX_TAIL" in vfe480:
    raise SystemExit("camss-vfe-480.c: pack 0x30ac via live_30ac, not DEMUX_TAIL EN/period")
if "CLC_PDPC11" not in vfe480:
    raise SystemExit("camss-vfe-480.c: PDPC11 in-pipe CLC missing")
if "vfe_480_clc_enable(vfe, CLC_ABF, 0)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: ABF MODULE must be 0 (#355; live 0x3268 stays)")
if "vfe_480_clc_enable(vfe, CLC_ABF, 0x2)" in vfe480:
    raise SystemExit("camss-vfe-480.c: ABF EN=0x2 + live 0x3268 is #355 black-pixel candidate")
if "0x00008020" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM ABF 0x3268 x19 missing")
if "writel_relaxed(0, vfe->base + CLC_ABF + 0x68)" in vfe480:
    raise SystemExit("camss-vfe-480.c: do not zero ABF 0x3268; live CDM is 0x00008020")
if "ABF_REGION			0x70" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX ABF40 PackIQ 12-bit region is 0x3270 not 0x3268")
if "writel_relaxed(hwin, vfe->base + CLC_ABF + ABF_REGION)" in vfe480:
    raise SystemExit("camss-vfe-480.c: #337 0x3270 Crop11 read back last=1; compact does not pack 0x3270")
if "overflow abf40 3260=" not in vfe480 or "3270=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump ABF40 0x3270 region")
if "CLC_GIC + CLC_DMI_LUT" not in vfe480 or "ABF_BANK2_DMI_N1" not in vfe480:
    raise SystemExit("camss-vfe-480.c: ABF40 bank2 must stuff DMI 0x3408 before MODULE EN")
if "ABF_BANK2_MODULE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: compact ABF bank2 is 0x3460 x1 live MODULE 0xc101")
if "vfe_480_pack(vfe, 0x3458, (const u32[]){ 0, 0, 0 }, 3)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: ABF bank2 0x3460 MODULE must be 0 (#357; 0xc101 still on after #355)")
if "vfe_480_pack(vfe, 0x3458, (const u32[]){ 1, 1, ABF_BANK2_MODULE }, 3)" in vfe480:
    raise SystemExit("camss-vfe-480.c: ABF bank2 EN=0xc101 is #357 black-pixel candidate")
if "0x03800380" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM ABF bank2 0x3468 x46 missing")
if "0x3458" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM ABF bank2 0x3458 x3 missing")
if "writel_relaxed(0, vfe->base + CLC_GIC + 0x68)" in vfe480:
    raise SystemExit("camss-vfe-480.c: do not zero ABF bank2 0x3468; compact leaves HW reset")
if "overflow abf40 3260=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump ABF40 0x3260/0x3460")
if "DEMOSAIC_INTERP_MID" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Demosaic36 interpolator dump map missing")
if "writel_relaxed(DEMOSAIC_INTERP_MID" in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM 0x3878 is 0x80/0x00800066 not INTERP_MID 0x800080")
if "0x00800066" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM Demosaic 0x3878 x2 missing")
if "DEMOSAIC_WB_N		4" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX WB13 0x3868 x4 missing")
if "0x07540400" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM Demosaic 0x3868 is 0x07540400 not Q10 0x400")
if "vfe_480_clc_enable(vfe, CLC_DEMOSAIC, DEMOSAIC_COMPACT_CFG)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #361 restore Demosaic 0x4001; PDPC off is the black-pixel fix")
if "vfe_480_clc_enable(vfe, CLC_DEMOSAIC, 0)" in vfe480:
    raise SystemExit("camss-vfe-480.c: Demosaic MODULE=0 was an isolation cut; restore 0x4001 after #360")
if "overflow wb13 3868=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump WB13 0x3868")
if "viol_id=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF violation_status is a module id")
if "pipe_h / 2, out_w, out_h / 2" not in vfe480:
    raise SystemExit("camss-vfe-480.c: MNDS C must 4:2:0 of 2ppc luma (viol_id 19)")
if "pipe_h = in_h / 2" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop/MNDS V must use CAMIF 2ppc line=in_h/2")
if "vfe_480_crop(vfe, CLC_CROP, in_w - 1, in_h - 1)" in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 Y last_y=in_h-1 waits for 3059; CAMIF stops at 1530")
if "vfe_480_clc_enable(vfe, CLC_PDPC11, BIT(0))" in vfe480:
    raise SystemExit("camss-vfe-480.c: empty PDPC EN=1 is a line-0 brick wall")
if "vfe_480_pdpc30(vfe, in_w, in_h)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: PDPC30 identity between Pedestal and Demux missing")
if "PDPC30_DMI_N		0x90" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX PDPC30 DMI sel1 n=0x90 missing")
if "MNDS_IMAGE_SIZE" in vfe480:
    raise SystemExit("camss-vfe-480.c: Titan 170 MNDS IMAGE_SIZE packing is illegal on Titan 480")
if "MNDS_H_CFG" in vfe480:
    raise SystemExit("camss-vfe-480.c: Titan 170 MNDS H_CFG packing is illegal on Titan 480")
if "MNDS_H_INIT" in vfe480:
    raise SystemExit("camss-vfe-480.c: Titan 170 MNDS H_INIT packing is illegal on Titan 480")
if "#define MNDS_H_SIZE			0x64" in vfe480:
    raise SystemExit("camss-vfe-480.c: MNDS +0x64 is Titan 480 spare; H_SIZE starts at +0x68")
if "#define MNDS_H_SIZE			0x68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display MNDS21 H_SIZE 0x68 missing")
if "#define MNDS_V_PAD			0x84" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display MNDS21 V_PAD 0x84 missing")
if "#define     CROP_PIXEL			0x64" in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 PIXEL +0x64 is CAMIF spare; use +0x68/+0x6c")
if "#define     CROP_PIXEL			0x68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 PIXEL must be +0x68 like CAMIF_CROP_WIDTH")
if "#define     CROP_LINE			0x6c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 LINE must be +0x6c like CAMIF_CROP_HEIGHT")
if "#define     CROP_H_STRIPE		0x70" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 H_STRIPE +0x70 missing (CamX x9)")
if "#define     CROP_V_STRIPE		0x80" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 V_STRIPE +0x80 missing (CamX x9)")
if "last_x << 16, vfe->base + base + CROP_H_STRIPE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 keep-all H_STRIPE last must be last_x")
if "VFE_CORE_CFG_1" not in vfe480:
    raise SystemExit("camss-vfe-480.c: dump CORE_CFG_1 at 0x30")
if "BIT(0) | BIT(1) | (interp << 8)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: MNDS MODULE_CFG must OR 0x3 like CamX")
if "interp << 28" not in vfe480:
    raise SystemExit("camss-vfe-480.c: MNDS interpReso in phase[29:28] missing")
if "(out_w - 1) << 16" not in vfe480:
    raise SystemExit("camss-vfe-480.c: MNDS H stripe last must be H_OUT-1")
if "#define CLC_RNDCLAMP			0x4200" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp11 0x4200 missing")
if "#define CLC_CROP			0x4400" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 0x4400 missing")
if "#define CLC_CROP_C			0x4600" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 C 0x4600 missing")
if "#define CLC_RNDCLAMP_POST_Y		0x5000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp POST Y 0x5000 missing")
if "#define CLC_RNDCLAMP_POST_C		0x5200" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp POST C 0x5200 missing")
if "#define     RNDCLAMP_CH0		0x70" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp11 clamp burst must be +0x70")
if "RNDCLAMP_MODULE_CFG		0x3c01" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp11 MODULE_CFG must be CamX 0x3c01")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP_POST_Y);" in vfe480:
    raise SystemExit("camss-vfe-480.c: POST Y RoundClamp missing PIXEL/LINE keep-all")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP_POST_C);" in vfe480:
    raise SystemExit("camss-vfe-480.c: POST C RoundClamp missing PIXEL/LINE keep-all")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP);" in vfe480:
    raise SystemExit("camss-vfe-480.c: PRE RoundClamp missing PIXEL/LINE keep-all")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP, in_w - 1, pipe_h - 1)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: PRE RoundClamp keep-all must match Crop input")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP_POST_Y, out_w - 1, out_h - 1)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: POST Y RoundClamp keep-all must match MNDS out")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP_POST_C, out_w - 1," not in vfe480:
    raise SystemExit("camss-vfe-480.c: POST C RoundClamp keep-all must match MNDS chroma")
if "#define CLC_RNDCLAMP_OUT_Y		0x5800" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp after POST Y 0x5800 missing (CamX 0x5a60 compact)")
if "#define CLC_RNDCLAMP_OUT_C		0x5a00" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp after POST C 0x5a00 missing")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP_OUT_Y, out_w - 1, out_h - 1)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: OUT Y RoundClamp keep-all must match POST")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP_OUT_C, out_w - 1," not in vfe480:
    raise SystemExit("camss-vfe-480.c: OUT C RoundClamp keep-all must match POST chroma")
if "overflow rcwin pre=" not in vfe480 or "outy=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump OUT RoundClamp PIXEL/LINE")
if "dagu ife%d pix cst=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: STREAMON must dump CST origin + POST C +0x70")
if "vfe_480_live_display_cdm" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM Display Crop/MNDS/TAP pack missing")
if "0x0fef0bf3" not in vfe480 or "0xc043dbcf" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM MNDS/Crop 0x0fef0bf3 missing")
if "0x0bf40ff0" not in vfe480:
    raise SystemExit("camss-vfe-480.c: rear Demux 0x3068 last 0x0bf40ff0 missing")
if "in_w == 4080 && in_h == 3060" not in vfe480:
    raise SystemExit("camss-vfe-480.c: rear Demux 0x0bf40ff0 must stay behind 4080x3060 gate")
if "0x0a1f079f" not in vfe480 or "0xc081999a" not in vfe480:
    raise SystemExit("camss-vfe-480.c: front live Crop/MNDS 0xa1f079f missing")
if "0x07a00a20" not in vfe480:
    raise SystemExit("camss-vfe-480.c: front Demux 0x3068 last 0x07a00a20 missing")
if "0x08c908c9" not in vfe480 or "0x000000ca" not in vfe480:
    raise SystemExit("camss-vfe-480.c: front Demux 0x3090 even 0xca/odd 0x9c missing")
if "0x05fa0400" not in vfe480 or "0x0000082c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: front Demosaic WB 0x3868 0x05fa0400 missing")
if "0x00000101, 0x00000600, 0x03bf021b, 0xc0200000" in vfe480:
    raise SystemExit("camss-vfe-480.c: #376 Crop C 0x03bf021b excluded (#392 still viol 19)")
if "0x00000001, 0x00000600, 0x03bf021b" in vfe480:
    raise SystemExit("camss-vfe-480.c: #378 MNDS_C dest last 0x03bf021b excluded (#377 still viol 19)")
if "0x00000001, 0x00000600, 0x077f0437" in vfe480:
    raise SystemExit("camss-vfe-480.c: #378-#380 dest last 0x077f0437 on MNDS excluded (still viol 19)")
if "0x00000101, 0x00000600, 0x077f0437" in vfe480:
    raise SystemExit("camss-vfe-480.c: #381 Crop MODULE 0x101 last 0x077f0437 is IPE 1920, not live IFE 2304")
if "0xc02b3333" in vfe480:
    raise SystemExit("camss-vfe-480.c: invented MNDS Q21 0xc02b3333 excluded (#370)")
if "0x00000001, 0x00000600, 0x08ff050f, 0xc023d82c" in vfe480:
    raise SystemExit("camss-vfe-480.c: #383 Crop Y dest last 0x08ff050f excluded (viol 14 crop=1)")
if "0x00000001, 0x00000600, 0x047f0287, 0xc047b058" in vfe480:
    raise SystemExit("camss-vfe-480.c: #383 Crop C dest last 0x047f0287 excluded (viol 14 crop=1)")
if "0x00000001, 0x00000600, 0x0a1f05bf, 0xc023d82c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #381 Crop Y live 0x0a1f05bf phase 0xc023d82c missing")
if "0x00000001, 0x00000600, 0x0a1f05bf, 0xc047b058" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #381 Crop C live 0x0a1f05bf phase 0xc047b058 missing")
if "0x00000001, 0x00000600, 0x0a1f05bf, 0xc0200000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #381 MNDS Y last 0x0a1f05bf unity missing")
if "0x00000001, 0x00000600, 0x0a1f05bf, 0xc0400000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #381 MNDS_C last 0x0a1f05bf 2x @0x4e60 packing missing")
if "0x0a1f0000, 0x03cf0000" in vfe480:
    raise SystemExit("camss-vfe-480.c: MID 0xa1f0000/0x3cf0000 is Linux keep-all; #350 overflow")
if "0x003c01a3, 0x0000027f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live MID Y 0x4868 0x3c01a3 missing")
if "0x00000437, 0x0000077f" in vfe480:
    raise SystemExit("camss-vfe-480.c: #381 MID 0x437/0x77f is IPE 1920; #395 still viol 0 on 2304 WM")
if "0x00000527, 0x0000090f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #386 MID/POST dest 2320×1320 0x527/0x90f missing")
if "0x00000293, 0x00000487" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #386 MID/POST chroma 1160×660 0x293/0x487 missing")
if "0x0000079f, 0x00000a1f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 MID/POST dest 2592×1952 0x79f/0xa1f missing")
if "0x000003cf, 0x0000050f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 chroma dest 1296×976 0x3cf/0x50f missing")
if "0x0000050f, 0x000008ff" in vfe480:
    raise SystemExit("camss-vfe-480.c: #384 2304 RC with 2320 WM falsified (img=0x30); use 0x527/0x90f")
if "camif_last_y = (0x05bf + 1) / 2 - 1" in vfe480:
    raise SystemExit("camss-vfe-480.c: #385 CAMIF last 735 falsified (overflow still line=976)")
if "#384 2320 WM" not in vfe480 or "falsified" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #384 2320 WM falsified (img=0x30 as0=0) must stay in comment")
pix_test = (root.parent / "scripts/dagu-ife-pix-test.sh").read_text()
if "pix_wh = '2304x1296'" in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #386 RC+WM 2320×1320; front must not stay 2304")
if "pix_wh = '2320x1320'" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: front Display 2320x1320 missing")
if "pix_wh = '2592x1952'" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #412 identity 2592x1952 missing")
if "early_eof=" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #390 IPP EARLY_EOF bit29 probe missing")
if "ovf_recover" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #391 ovf recover probe missing")
if "0x00000287, 0x0000047f" in vfe480:
    raise SystemExit("camss-vfe-480.c: #386 chroma dest must be 0x293/0x487 not 2304 0x287/0x47f")
csidgen = (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text()
if "0x05bf << 16" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #387 front IPP VCROP last 0x05bf (live Crop last Y) missing")
if "val = (0x05bf << 16) | 0" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: Display Full IPP VCROP last 0x05bf missing")
if "Do not retry 0x05bf as the chroma gap" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #412 CSID 1472 comment missing")
if "input_format->width == 2592 && input_format->height == 1952" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #387 front 2592x1952 IPP VCROP gate missing")
if "vcrop=0x%x" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #387 IPP VCROP dump missing")
if "camif_last_y = (0x05bf + 1) / 2 - 1" in csidgen:
    raise SystemExit("camss-csid-gen2.c: #385 CAMIF last 735 was VFE; do not put it on CSID")
if "0x000002df, 0x00000a1f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #388 PRE 2ppc last 735 0x2df (CSID 0x05bf) missing")
if "0x000003cf, 0x00000a1f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 PRE keep-all 976 0x3cf/0xa1f missing")
if "pipe_h = (0x05bf + 1) / 2" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #388 front pipe_h 736 from CSID VCROP 0x05bf missing")
if "epoch = (0x05bf + 1) / 4" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #389 front CAMIF epoch pixel_h/4 of CSID 1472 missing")
if "Epoch is not" not in vfe480 or "the EOF drain" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #389 epoch 368 still line=736 must stay falsified")
if "EARLY_EOF_EN cfg0=0xa02b20e3" not in vfe480 or "falsified" not in vfe480.split("EARLY_EOF_EN cfg0=0xa02b20e3", 1)[-1][:200]:
    raise SystemExit("camss-vfe-480.c: #390 EARLY_EOF still line=736 must stay falsified")
if "EARLY_EOF=0 on #411" not in vfe480 or "falsified" not in vfe480.split("EARLY_EOF=0 on #411", 1)[-1][:120]:
    raise SystemExit("camss-vfe-480.c: #397 EARLY_EOF=0 still 4591616 must stay falsified")
if "Do not retry WM5 2304" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #398 WM5 width 2304 img=0x20 0-byte must stay falsified")
if "cw = 2304" in vfe480:
    raise SystemExit("camss-vfe-480.c: #398 WM5 2304 must stay reverted")
if "CAF skips burst_limit when CamX value is 0" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #399 front WM5 burst_limit 0 missing")
if "plain && wm == DISP_C_WM && width == 2320 && height == 660" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #399 WM5 burst_limit 0 must stay gated to front 2320x660")
if "burst_limit 0 on #414 burst5=0x0 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #399 burst_limit 0 still 4591616 must stay falsified")
if "cin -= 1984" in vfe480:
    raise SystemExit("camss-vfe-480.c: #400 FRAME_INCR 1984 must stay reverted")
if "incr5=0x175580 still 4591616" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #400 FRAME_INCR 1984 still 4591616 must stay falsified")
if "Do not retry FRAME_INCR 1984" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #400 must not retry FRAME_INCR 1984")
if "ch = 659" in vfe480:
    raise SystemExit("camss-vfe-480.c: #401 WM5 height 659 must stay reverted")
if "Do not retry height 659" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #401 height 659 img=0x20 must stay falsified")
if "Do not retry front packer 3" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #402 front packer 3 UV avg 19 must stay falsified")
if "wm == DISP_C_WM && width == 2320 && height == 660)\n\t\t\twritel_relaxed(PACKER_PLAIN_8_LSB_MSB_10" in vfe480:
    raise SystemExit("camss-vfe-480.c: #402 front WM5 packer 3 must stay reverted")
if "0x0293016f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #403 front MNDS_C V_SIZE 0x0293016f missing")
if "writel_relaxed(0x0293016f" in vfe480:
    raise SystemExit("camss-vfe-480.c: #507 must not keep MNDS_C V 368→660 after Y src 1472")
if "writel_relaxed(0x029302df" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #507 MNDS_C V src must be 736")
if "CLC_MNDS_C + MNDS_V_SIZE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #403 MNDS_C V_SIZE write missing")
if "vsz=0x293016f still 4591616" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #403 V_SIZE still 4591616 must stay falsified")
if "0x02930000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #404 front MNDS_C V_STRIPE 0x02930000 missing")
if "CLC_MNDS_C + MNDS_V_STRIPE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #404 MNDS_C V_STRIPE write missing")
if "vst=0x2930000 still 4591616" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #404 V_STRIPE still 4591616 must stay falsified")
if "Do not retry V_STRIPE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #404 must not retry V_STRIPE as the chroma gap")
if "0x0011d7a9" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #405 front MNDS_C V_PHASE 0x0011d7a9 missing")
if "CLC_MNDS_C + MNDS_V_PHASE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #405 MNDS_C V_PHASE write missing")
if "vph=0x1117a9 still" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #405 V_PHASE still 4591616 must stay falsified")
if "Do not retry V_PHASE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #405 must not retry V_PHASE as the chroma gap")
if "0x090f0000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #406 front MNDS_C H_STRIPE 0x090f0000 missing")
if "CLC_MNDS_C + MNDS_H_STRIPE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #406 MNDS_C H_STRIPE write missing")
if "hst=0x90f0000 still 4591616" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #406 H_STRIPE still 4591616 must stay falsified")
if "Do not retry H_STRIPE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #406 must not retry H_STRIPE as the chroma gap")
if "0x090f0a1f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #407 front MNDS_C H_SIZE 0x090f0a1f comment missing")
if "writel_relaxed(0x090f0a1f" in vfe480:
    raise SystemExit("camss-vfe-480.c: #407 H_SIZE 0x090f0a1f must stay reverted")
if "hsz=0x90f0a1f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #407 H_SIZE viol 19 0-byte must stay falsified")
if "Do not retry H_SIZE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #407 must not retry H_SIZE as the chroma gap")
if "writel_relaxed(0xc047b058" in vfe480:
    raise SystemExit("camss-vfe-480.c: #408 H_PHASE 0xc047b058 must stay reverted")
if "hph=0xc047b058" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #408 H_PHASE img=0x20 0-byte must stay falsified")
if "Do not retry H_PHASE 0xc047b058 as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #408 must not retry H_PHASE 0xc047b058 as the chroma gap")
if "writel_relaxed(0xc023d82c" in vfe480:
    raise SystemExit("camss-vfe-480.c: #465 MNDS Y H_PHASE 0xc023d82c must stay reverted")
if "Do not retry MNDS Y H_PHASE 0xc023d82c as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #465 MNDS Y H_PHASE 0-byte must stay falsified")
if "writel_relaxed(0x090f0000,\n\t\t\t       vfe->base + CLC_MNDS_Y + MNDS_H_STRIPE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #466 MNDS Y H_STRIPE 0x090f0000 missing")
if "hst=0x90f0000 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #466 MNDS Y H_STRIPE still 4591616 must stay falsified")
if "Do not retry MNDS Y H_STRIPE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #466 must not retry MNDS Y H_STRIPE as the chroma gap")
if "writel_relaxed(0x0023b0d2,\n\t\t\t       vfe->base + CLC_MNDS_Y + MNDS_V_PHASE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #506 MNDS Y V_PHASE must be 1472/1320 not #467 736/1320")
if "Do not retry MNDS Y V_PHASE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #467 must not retry MNDS Y V_PHASE as the chroma gap")
if "#467 on #492: vph=0x1117a9 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #467 MNDS Y V_PHASE still 4591616 must stay falsified")
if "writel_relaxed(0xc023d909,\n\t\t\t       vfe->base + CLC_CROP + CROP_V_PHASE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #468 Crop Y V_PHASE 0xc023d909 missing")
if "crop_yvph=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #468 crop_yvph telemetry missing")
if "#468 on #493: crop_yvph=0x231909 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #468 Crop Y V_PHASE still 4591616 must stay falsified")
if "Do not retry Crop Y V_PHASE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #468 must not retry Crop Y V_PHASE as the chroma gap")
if "writel_relaxed(0x02df0000,\n\t\t\t       vfe->base + CLC_CROP + CROP_V_STRIPE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #469 Crop Y V_STRIPE 0x02df0000 missing")
if "#469 on #494: vst=0x2df0000 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #469 Crop Y V_STRIPE still 4591616 must stay falsified")
if "Do not retry Crop Y V_STRIPE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #469 must not retry Crop Y V_STRIPE as the chroma gap")
if "writel_relaxed(0x016f0000,\n\t\t\t       vfe->base + CLC_CROP_C + CROP_V_STRIPE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #470 Crop C V_STRIPE 0x016f0000 missing")
if "#470 on #495: crop_c_vst=0x16f0000 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #470 Crop C V_STRIPE still 4591616 must stay falsified")
if "Do not retry Crop C V_STRIPE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #470 must not retry Crop C V_STRIPE as the chroma gap")
if "writel_relaxed(0xc047b212,\n\t\t\t       vfe->base + CLC_CROP_C + CROP_V_PHASE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #471 Crop C V_PHASE 0xc047b212 missing")
if "crop_cvph=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #471 crop_cvph telemetry missing")
if "#471 on #496: crop_cvph=0x473212 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #471 Crop C V_PHASE still 4591616 must stay falsified")
if "Do not retry Crop C V_PHASE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #471 must not retry Crop C V_PHASE as the chroma gap")
if "writel_relaxed(0x016f0000,\n\t\t\t       vfe->base + CLC_CROP_C + CROP_V_SIZE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #472 Crop C V_SIZE 0x016f0000 missing")
if "crop_cvsz=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #472 crop_cvsz telemetry missing")
if "#472 on #497: crop_cvsz=0x16f0000 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #472 Crop C V_SIZE still 4591616 must stay falsified")
if "Do not retry Crop C V_SIZE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #472 must not retry Crop C V_SIZE as the chroma gap")
if "writel_relaxed(0x02df0000,\n\t\t\t       vfe->base + CLC_CROP + CROP_V_SIZE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #473 Crop Y V_SIZE 0x02df0000 missing")
if "crop_yvsz=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #473 crop_yvsz telemetry missing")
if "#473 on #498: crop_yvsz=0x2df0000 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #473 Crop Y V_SIZE still 4591616 must stay falsified")
if "Do not retry Crop Y V_SIZE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #473 must not retry Crop Y V_SIZE as the chroma gap")
if "writel_relaxed(0x090f0000,\n\t\t\t       vfe->base + CLC_CROP_C + CROP_H_STRIPE)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #474 Crop C H_STRIPE 0x090f0000 missing")
if "crop_chst=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #474 crop_chst telemetry missing")
if "#474 on #499: crop_chst=0x90f0000 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #474 Crop C H_STRIPE still 4591616 must stay falsified")
if "Do not retry Crop C H_STRIPE as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #474 must not retry Crop C H_STRIPE as the chroma gap")
if "2592/1157" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #408 must keep Android Display Full chroma phase comment")
if "Do not write non-zero IMAGE_CFG_1" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #409 IMAGE_CFG_1 h_init 0 must stay")
if "h_init 0x0" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #409 Camera ID 1 live WM:5 h_init 0x0 missing")
if "0x3D00A20" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #409 live WM5 IMAGE_CFG_0 0x3D00A20 missing")
if "0x7A00A20" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #409 live WM4 IMAGE_CFG_0 0x7A00A20 missing")
if "Do not WM-only 2592" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #409 must not WM-only 2592")
if "wm5cfg1=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #409 WM5 IMAGE_CFG_1 telemetry missing")
if "CLC_MNDS_C + MNDS_V_PAD" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #410 front MNDS_C V_PAD comment missing")
if "writel_relaxed(0x0011d7a9,\n\t\t\t       vfe->base + CLC_MNDS_C + MNDS_V_PAD)" in vfe480:
    raise SystemExit("camss-vfe-480.c: #410 V_PAD 0x0011d7a9 must stay reverted")
if "vpd=0x0 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #410 V_PAD bounced vpd=0x0 must stay falsified")
if "Do not retry V_PAD as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #410 must not retry V_PAD as the chroma gap")
if "#411 H_PAD 0xc047b212" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #411 H_PAD 0xc047b212 comment missing")
if "writel_relaxed(0xc047b212,\n\t\t\t       vfe->base + CLC_MNDS_C + MNDS_H_PAD)" in vfe480:
    raise SystemExit("camss-vfe-480.c: #411 H_PAD 0xc047b212 must stay reverted")
if "hpd=0xc047b212 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #411 H_PAD 0-byte must stay falsified")
if "Do not retry H_PAD as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #411 must not retry H_PAD as the chroma gap")
if "0x0a1f0a1f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 MNDS H_SIZE dest=src 2592 missing")
if "writel_relaxed(0x0a1f0a1f" in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 H_SIZE dest=src 0x0a1f0a1f must stay reverted")
if "hsz=0xa1f0a1f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 H_SIZE dest=src 0-byte must stay falsified")
if "Do not retry H_SIZE dest=src as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 must not retry H_SIZE dest=src")
if "hst=0 both Y/C" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #413 empty H_STRIPE 0-byte must stay falsified")
if "0x0a1f0000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #414 identity H_STRIPE 0x0a1f0000 missing")
if "writel_relaxed(0x0a1f0000,\n\t\t\t       vfe->base + CLC_MNDS_Y + MNDS_H_STRIPE)" in vfe480:
    raise SystemExit("camss-vfe-480.c: #414 H_STRIPE dest 0x0a1f0000 must stay reverted")
if "hst=0xa1f0000 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #414 H_STRIPE dest 0-byte must stay falsified")
if "Do not retry H_STRIPE dest as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #414 must not retry H_STRIPE dest")
if "0x00000001, 0x00000600, 0x0a1f079f, 0xc0400000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #415 MNDS_C identity last 2x 0xc0400000 missing")
if "writel_relaxed(0xc0400000" in vfe480:
    raise SystemExit("camss-vfe-480.c: #415 MNDS_C 2x must stay in pack, not H_SIZE dest restore")
if "hph=0xc0400000 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #415 MNDS_C 2x 0-byte must stay falsified")
if "Do not retry MNDS_C 2× as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #415 must not retry MNDS_C 2x as the chroma gap")
if "0x00000001, 0x00000600, 0x0a1f079f, 0xc081999a" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #416 Crop Y live 0x4460 0xc081999a must stay in comments")
if "0x00000001, 0x00000600, 0x0a1f079f, 0xc1033334" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #416 Crop C live 0x4660 0xc1033334 must stay in comments")
if "0xc0822222" not in vfe480 or "0xc1044444" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #416 Crop H_PAD live 0xc0822222/0xc1044444 must stay in comments")
if "static const u32 front_crop_y[] = {\n\t\t0x00000001, 0x00000600, 0x0a1f079f, 0xc081999a" in vfe480:
    raise SystemExit("camss-vfe-480.c: #416 640 Crop Y pack must stay reverted")
if "static const u32 front_crop_c[] = {\n\t\t0x00000001, 0x00000600, 0x0a1f079f, 0xc1033334" in vfe480:
    raise SystemExit("camss-vfe-480.c: #416 640 Crop C pack must stay reverted")
if "static const u32 front_crop_y[] = {\n\t\t0x00000001, 0x00000600, 0x0a1f079f, 0xc0200000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #422 Crop Y identity unity missing")
if "static const u32 front_crop_c[] = {\n\t\t0x00000001, 0x00000600, 0x0a1f079f, 0xc0400000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #422 Crop C identity 2ppc missing")
if "front_crop_y_disp" not in vfe480 or "0x0a1f05bf, 0xc023d82c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display Full Crop Y 9-word missing")
if "front_crop_c_disp" not in vfe480 or "0x0a1f05bf, 0xc047b058" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display Full Crop C 9-word missing")
if "crop_y = front_crop_y_disp" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display Full Crop must be the packed dest")
if "0x5504 first-list\n\t * is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #421 0x5504 0-byte must stay falsified")
if "{ 0x000001df, 0x0000027f }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #417 live MID Y 0x4868 480x640 missing")
if "{ 0x000000ef, 0x0000013f }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #417 live MID C 0x4a68 240x320 missing")
if "Do not WM 640" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #417 must not WM 640")
if "mid_y=0xe01/0x1df/0x27f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #417 MID 480x640 0-byte must stay falsified")
if "Do not retry MID 480×640 as the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #417 must not retry MID 480x640")
if "CLC_RNDCLAMP_MID_Y + 0x68,\n\t\t     (const u32[]){ 0x000001df, 0x0000027f }" in vfe480:
    raise SystemExit("camss-vfe-480.c: #417 MID 480x640 must stay reverted")
if "{ 0x000001e7, 0x00000287 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #418 live OUT Y 0x5868 648x488 missing")
if "{ 0x000000f3, 0x00000143 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #418 live OUT C 0x5a68 missing")
if "CLC_RNDCLAMP_OUT_Y + 0x68,\n\t\t     (const u32[]){ 0x000001e7, 0x00000287 }" in vfe480:
    raise SystemExit("camss-vfe-480.c: #418 OUT 488x648 must stay reverted")
if "Do not retry OUT 488×648 as the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #418 OUT 488x648 0-byte must stay falsified")
if "0x04040404, 0x04040404, 0x04040404" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #419 live Demux 0x3090 0x04040404 missing")
if "0x000020b1, 0x000017e7, 0x000007d5, 0x00000ab6" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #419 live Demux 0x3068 missing")
if "0x000022a8, 0x000015a8, 0x00000763, 0x00000bd2" in vfe480:
    raise SystemExit("camss-vfe-480.c: #419 must not keep heap 0x3068")
if "0x00000000, 0x00000000, 0x00e24003" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #420 live Demux 0x3058 first-list missing")
if "0x00000001, 0x00000001, 0x00e24203" in vfe480:
    raise SystemExit("camss-vfe-480.c: #420 must not keep later-list 0x3058")
if "demux=0x3c003c01/0x4040404 stuck" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #419 Demux 0x04040404 0-byte must stay falsified")
if "0x3058 first-list is\n\t\t * not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #420 0x3058 0-byte must stay falsified")
if "CLC_DS411_C_CROP,\n\t\t\t     (const u32[]){ 0x0000079f, 0x00000a1f }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #421 live DS411 C 0x5504 identity missing")
if "Do not copy 0x5d04 0x1e7/0x287" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #421 must not copy 640 DS16 0x5d04")
if "Crop identity unity is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #422 Crop unity 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x5704,\n\t\t\t     (const u32[]){ 0x000003cf, 0x00000a1f }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #423 live 0x5704 976x2592 missing")
if "vfe_480_pack(vfe, 0x5608" in vfe480.split("static void vfe_wm_start", 1)[0]:
    raise SystemExit("camss-vfe-480.c: #426 must not EN 0x5608 before WM6/7 dummy go")
if "vfe_480_pack(vfe, 0x5e08" in vfe480.split("static void vfe_wm_start", 1)[0]:
    raise SystemExit("camss-vfe-480.c: #427 must not EN 0x5e08 before WM6/7 dummy go")
if "0x5704 first-list is not\n\t * the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #423 0x5704 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x5f04,\n\t\t\t     (const u32[]){ 0x000000f3, 0x00000287 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #424 live 0x5f04 missing")
if "One variable: 0x5f04 crop window only" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #424 must not EN 0x5e08 with 0x5f04")
if "0x5f04 first-list is not\n\t * the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #424 0x5f04 0-byte must stay falsified")
if "vfe_480_ds_config(vfe, DISP_DS4_WM, 324, 244" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #425 live WM6 324x244 missing")
if "vfe_480_ds_config(vfe, DISP_DS16_WM, 81, 61" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #425 live WM7 81x61 missing")
if "vfe_480_ds_go(vfe)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #425 WM6/7 dummy ADDR start missing")
if "WM6/7 dummy IOVA is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #425 0-byte img=0xc0 must stay falsified")
if "vfe_480_ds_go(vfe);\n\t\t\t\tvfe_480_pack(vfe, 0x5608" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #426 0x5608 must follow WM6/7 dummy go")
if "vfe_480_pack(vfe, 0x5608,\n\t\t\t\t\t     (const u32[]){ 0x00000307 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #426 live 0x5608 0x307 missing")
if "0x5608 after dummy go is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #426 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x5e08,\n\t\t\t\t\t     (const u32[]){ 0x00000f07 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #427 live 0x5e08 0xf07 missing")
if "0x5e08 after 0x5608 is not" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #427 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x6068,\n\t\t\t     (const u32[]){ 0x00000079, 0x000000a1 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #428 live 0x6068 122x162 missing")
if "0x6068 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #428 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x6268,\n\t\t\t     (const u32[]){ 0x0000003c, 0x00000050 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #429 live 0x6268 61x81 missing")
if "0x6268 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #429 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x6060,\n\t\t\t     (const u32[]){ 0x00000e01 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #430 live 0x6060 0xe01 missing")
if "0x6060 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #430 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x6070,\n\t\t\t     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #431 live 0x6070 clamp missing")
if "0x6070 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #431 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x6260,\n\t\t\t     (const u32[]){ 0x00003e01 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #432 live 0x6260 0x3e01 missing")
if "0x6260 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #432 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x6270,\n\t\t\t     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #433 live 0x6270 linear clamp 6 missing")
if "Do not pack chroma 7" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #433 must not copy UBWC chroma 7 onto linear 0x6270")
if "0x6270 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #433 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x5868,\n\t\t\t     (const u32[]){ 0x000001e7, 0x00000287 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #434 live 0x5868 488x648 missing")
if "0x5868 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #434 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x5a68,\n\t\t\t     (const u32[]){ 0x000000f3, 0x00000143 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #435 live 0x5a68 244x324 missing")
if "0x5a68 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #435 0-byte img=0xc0 must stay falsified")
if "w5a68=0x%x/0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #435 pix stop must dump 0x5a68")
if "vfe_480_pack(vfe, 0x5860,\n\t\t\t     (const u32[]){ 0x00000e01 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #436 live 0x5860 0xe01 missing")
if "0x5860 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #436 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x5870,\n\t\t\t     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #437 live 0x5870 linear clamp 6 missing")
if "0x5870 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #437 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x5a60,\n\t\t\t     (const u32[]){ 0x00003e01 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #438 live 0x5a60 0x3e01 missing")
if "0x5a60 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #438 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x5a70,\n\t\t\t     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #439 live 0x5a70 linear clamp 6 missing")
if "0x5a70 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #439 0-byte img=0xc0 must stay falsified")
if "vfe_480_pack(vfe, 0x5d04,\n\t\t\t     (const u32[]){ 0x000001e7, 0x00000287 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #440 live identity 0x5d04 488x648 missing")
if "0x5d04 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #440 0-byte img=0xc0 must stay falsified")
if "if (in_w != 2592 || in_h != 1952)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #440 must not let Display Full 0x5d04 overwrite identity")
if "w5d04=0x%x/0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #440 pix stop must dump 0x5d04")
if "FRONT_DS4_INCR			720896" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #441 Camera ID 1 live WM6 frame_inc 720896 missing")
if "324 * 244" in vfe480:
    raise SystemExit("camss-vfe-480.c: #441 must not use width*height as WM6 frame_inc")
if "dummy live BUS incr is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #441 0-byte img=0xc0 must stay falsified")
if "incr6=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #441 pix stop must dump WM6 frame_inc")
if "vfe_480_pack(vfe, 0x3658, (const u32[]){ 0, 0, 0x01002001 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #442 Camera ID 1 first-list LSC MODULE 0x01002001 missing")
if "last_x == 2591 && last_y == 975" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #442 LSC EN must stay identity-only")
if "0x00530053" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #442 first-list 0x3668 blob missing")
if "Do not EN LSC with empty 0x3668" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #329 empty LSC EN must stay falsified")
if "0x3658 first-list LSC is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #442 0-byte img=0xc0 must stay falsified")
if "{ 0, 0, 0x0000c101 }" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #443 Camera ID 1 first-list GIC MODULE 0xc101 missing")
if "0x3c303af0" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #443 first-list 0x3468 blob missing")
if "in_w == 2592 && in_h == 1952" not in vfe480.split("vfe_480_abf_bank2", 1)[-1]:
    raise SystemExit("camss-vfe-480.c: #443 GIC EN must stay identity-only")
if "vfe_480_pack(vfe, 0x3458, (const u32[]){ 1, 1, ABF_BANK2_MODULE }, 3)" in vfe480:
    raise SystemExit("camss-vfe-480.c: #357 {1,1,ABF_BANK2_MODULE} must not return")
if "0x3458 first-list GIC is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #443 0-byte img=0xc0 must stay falsified")
if "0x07bf003f" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #444 Camera ID 1 first-list 0x2e68 missing")
if "w2e68=0x%x/0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #444 pix stop must dump 0x2e68")
if "Do not 0x2e58 EN" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #444 must not EN PDPC30")
if "0x2e68 first-list PDPC is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #444 0-byte img=0xc0 must stay falsified")
if "FRONT_DS4_STRIDE		2816" not in vfe480 and "FRONT_DS4_STRIDE			2816" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #445 Camera ID 1 live WM6 stride 2816 missing")
if "DISP_DS4_STRIDE			2048" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #445 must not replace rear dummy stride 2048")
if "dummy live BUS stride 2816 is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #445 0-byte img=0xc0 must stay falsified")
if "CLC_RNDCLAMP_OUT_Y + 0x68,\n\t\t     (const u32[]){ 0x000001e7, 0x00000287 }" in vfe480:
    raise SystemExit("camss-vfe-480.c: #434 must not copy 0x5868 onto OUT")
if "c6270=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #433 pix stop must dump 0x6270")
if "0x079f03cf" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 MNDS_Y V_SIZE dest 1952 src 976 missing")
if "0x03cf01e7" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 MNDS_C V_SIZE dest 976 src 488 missing")
if "Do not retry 0x05bf as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #412 CSID 1472 comment missing")
if "Do not retry burst as the chroma gap" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #399 must not retry burst as the chroma gap")
if "PIXEL PIPE is TOP" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #391 bus=0 TOP overflow must stay falsified")
if "CAMIF EN pulse" not in vfe480 or "camif=0x2000101" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #392 CAMIF EN pulse still 4591616 must stay falsified")
if "camif & ~CAMIF_EN" in vfe480:
    raise SystemExit("camss-vfe-480.c: #392 CAMIF EN pulse must not retry")
if "9183232" not in vfe480 or "overflow buf_done" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #393 overflow buf_done 9183232 chunk1 zeros must stay falsified")
isr_ovf = vfe480.split("static irqreturn_t vfe_isr", 1)[-1]
ovf_blk = isr_ovf.split("IRQ_MASK_0_PIX_OVERFLOW", 1)[-1].split("IRQ_MASK_0_RESET_ACK", 1)[0]
if "vfe_buf_done(vfe, DISP_Y_WM)" in ovf_blk:
    raise SystemExit("camss-vfe-480.c: #393 must not retry overflow buf_done")
if "ovf recover irq0=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow recover log missing")
if "VFE_BUS_OVERFLOW_STATUS_CLEAR);\n\t\twmb();" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #391 must clear BUS overflow latch before dump")
isr = vfe480.split("static irqreturn_t vfe_isr", 1)[-1]
clr = isr.find("VFE_BUS_OVERFLOW_STATUS_CLEAR")
dump = isr.find("PIXEL PIPE OVERFLOW irq0")
bus = isr.find("IRQ_MASK_0_BUS_TOP_IRQ")
if clr < 0 or dump < 0 or bus < 0 or not (clr < bus < dump):
    raise SystemExit("camss-vfe-480.c: #391 must clear overflow and handle BUS_TOP before dump")
if "RDI_CFG0_EARLY_EOF_EN" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: RDI_CFG0_EARLY_EOF_EN define missing")
if "2592 && input_format->height == 1952)\n\t\tval |= 1 << RDI_CFG0_EARLY_EOF_EN" in csidgen:
    raise SystemExit("camss-csid-gen2.c: #397 must not set EARLY_EOF on front (#410 still 4591616)")
if "clips chroma WM" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #397 front EARLY_EOF off comment missing")
if "Overflow due to back pressure" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #394 IPP bit17 back-pressure comment missing")
if "writel_relaxed(0, csid->base + CSID_IPP_ERR_RECOVERY_CFG0)" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #394 front must disable IPP overflow_ctrl")
if "ipp_errrec=" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #394 IPP errrec probe missing")
if "ipp_bp=" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #394 IPP bit17 back-pressure probe missing")
if "eof buf_done irq1=" in vfe480:
    raise SystemExit("camss-vfe-480.c: #395 CAMIF EOF buf_done 9183232 chunk1 zeros must not retry")
if "Do not retry CAMIF EOF" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #395 CAMIF EOF buf_done must stay falsified")
if "Keep front overflow_ctrl=0" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #394 errrec=0 on #408 must stay (overflow gone)")
if "if (!(input_format->width == 2592 && input_format->height == 1952))\n\t\tval |= 1 << IPP_PIX_STORE_EN" in csidgen:
    raise SystemExit("camss-csid-gen2.c: #502 must restore front IPP pix_store")
if "val |= 1 << IPP_PIX_STORE_EN" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: CAF IPP pix_store (CFG0 bit7) missing")
if "dagu csid ipp eof resume" in csidgen:
    raise SystemExit("camss-csid-gen2.c: #503 IPP EOF resume meas=0/0xfff still 1 COMP — do not keep")
if "dagu csid ipp sof recrop" not in csidgen:
    raise SystemExit("camss-csid-gen2.c: #504 must re-arm IPP crop on SOF")
if "dagu ife%d pix wm_update en-reload" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #505 must rewrite cfg_0/incr/EN like CAF update_wm")
if "if (cfg & (1 << WM_CFG_EN)) {\n\t\twmb();\n\t\treturn;" in vfe480:
    raise SystemExit("camss-vfe-480.c: #505 ADDR-only early return left as3 unused")
if "writel_relaxed(0x052702df" in vfe480:
    raise SystemExit("camss-vfe-480.c: #506 MNDS_Y V 736→1320 is upscale, not a down scaler")
if "writel_relaxed(0x052705bf" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #506 MNDS_Y V src must be CSID 1472")
if "pix_store=" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #396 pix_store probe missing")
if "mnds_c_vph=" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #405 MNDS_C V_PHASE probe missing")
if "mnds_c_hst=" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #406 MNDS_C H_STRIPE probe missing")
if "mnds_c_hpd=" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #411 MNDS_C H_PAD probe missing")
if "mnds_y_vsz=" not in pix_test:
    raise SystemExit("dagu-ife-pix-test.sh: #506 MNDS_Y V_SIZE probe missing")
if "in_w == 2592 && in_h == 1952" not in vfe480:
    raise SystemExit("camss-vfe-480.c: front 2592x1952 live Crop gate missing")
if "0x09016c7d" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM TAP filter 0x9016c7d missing")
if "CLC_RNDCLAMP_POST_C + 0x70" not in vfe480:
    raise SystemExit("camss-vfe-480.c: POST C RoundClamp +0x70 missing")
if "0x03ff0000, 7, 0x03ff0000, 7" in vfe480:
    raise SystemExit("camss-vfe-480.c: chroma round 7 is UBWC 10-bit; linear packer 3 LSB of 512 is #362 green")
if "0x00ff0000, 0x17, 0x00ff0000, 0x17" in vfe480:
    raise SystemExit("camss-vfe-480.c: MID C round 0x17 is UBWC 10-bit chroma; use 0x16 like Y (#363)")
if "0x03ff0000, 6, 0x03ff0000, 6" not in vfe480:
    raise SystemExit("camss-vfe-480.c: POST/OUT C round must be 6 so 10-bit 512 packs as UV 128")
if "#define CLC_DS411_C_CROP		0x5504" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX DS411 C 0x5504 dump addr missing")
if "vfe_480_ds411_crop(" in vfe480:
    raise SystemExit("camss-vfe-480.c: 0x5408 is DS4 TAP DMI_CFG (type==5 only); crop write stuffed LUT")
if "ds411=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump DS411 0x5408/0x5504 (expect reset)")
if "vfe_480_crop(vfe, CLC_DSX," in vfe480:
    raise SystemExit("camss-vfe-480.c: 0x5e00 Crop EN=1 STREAMON EPIPE -32; need real DSX10")
if "#define CLC_DSX				0x5e00" in vfe480:
    raise SystemExit("camss-vfe-480.c: do not EN 0x5e00; #318 empty Crop was EPIPE")
if "#define CLC_RNDCLAMP_MID_Y		0x4800" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp MID Y 0x4800 missing")
if "#define CLC_RNDCLAMP_MID_C		0x4a00" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp MID C 0x4a00 missing")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP_MID_Y, in_w - 1, pipe_h - 1)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: MID Y RoundClamp keep-all must match Crop")
if "vfe_480_rndclamp(vfe, CLC_RNDCLAMP_MID_C, in_w - 1," not in vfe480:
    raise SystemExit("camss-vfe-480.c: MID C RoundClamp keep-all must match Crop C")
if "overflow rcwin pre=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump RoundClamp PIXEL/LINE")
if "BLS DMI_CFG=0 before AHB" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BLS must clear DMI_CFG after LUT before MODULE")
if "CLC_PEDESTAL + CLC_DMI_CFG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Pedestal must clear DMI_CFG after LUT before MODULE")
if "overflow ped 2c5c=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump Pedestal 0x2c5c window")
if "PEDESTAL_WIN		0x5c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX Pedestal 0x2c5c is 13-bit last/first (PackIQ input+16)")
if "vfe_480_pedestal(vfe, in_w - 1, pipe_h - 1)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Pedestal identity DMI must run before PDPC30")
if "writel_relaxed(hwin, vfe->base + CLC_PEDESTAL + PEDESTAL_WIN)" in vfe480:
    raise SystemExit("camss-vfe-480.c: compact Pedestal is 0x2c60 x1; do not Crop11 0x2c5c")
if "CLC_PEDESTAL + PEDESTAL_AHB + i * 4" in vfe480:
    raise SystemExit("camss-vfe-480.c: compact Pedestal does not pack 0x2c68; do not zero AHB")
if "CLC_PDPC30 + CLC_DMI_CFG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: PDPC30 must clear DMI_CFG after LUT before MODULE")
if "0x08370040" not in vfe480 or "vfe_480_pack(vfe, 0x2e68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM PDPC30 0x2e68 x16 missing")
if "vfe_480_pack(vfe, 0x2e58" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM PDPC30 0x2e58 x3 missing")
if "live_2e58[] = {\n\t\t0x00000000, 0x00000000, 0x00000000," not in vfe480:
    raise SystemExit("camss-vfe-480.c: PDPC30 MODULE must be 0 (#360; {1,1,1} third word is EN)")
if "live_2e58[] = {\n\t\t0x00000001, 0x00000001, 0x00000001," in vfe480:
    raise SystemExit("camss-vfe-480.c: PDPC30 {1,1,1} is #360 black-pixel candidate")
if "vfe_480_crop(vfe, CLC_PREPROCESS, last_x, last_y)" in vfe480:
    raise SystemExit("camss-vfe-480.c: BLS 0x2268 x0x2e is IQ not Crop11; #337 class")
if "CLC_PREPROCESS + 0x68)" in vfe480:
    raise SystemExit("camss-vfe-480.c: do not zero BLS 0x2268 (CamX 0x2268 x0x2e / empty window)")
if "vfe_480_clc_enable(vfe, CLC_PREPROCESS, 0)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BLS MODULE must be 0 (#354; 0x2268 left at HW reset)")
if "vfe_480_clc_enable(vfe, CLC_PREPROCESS, BIT(0))" in vfe480:
    raise SystemExit("camss-vfe-480.c: BLS EN=1 + reset 0x2268 is #354 black-pixel candidate")
if "bls=0x%x/0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump BLS PIXEL/LINE")
if "vfe_480_bls(vfe, in_w - 1, pipe_h - 1)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BLS12 DMI helper must run before Pedestal")
if "BLS_DMI_SEL			4" in vfe480 or "BLS_DMI_N			0x280" in vfe480:
    raise SystemExit("camss-vfe-480.c: BLS DMI n=0x280 is CamX sel4 OFFSET; banks are 0x100/0x100/0x80/0xa8")
if "BLS_DMI_N1			0x100" not in vfe480 or "BLS_DMI_N4			0xa8" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX BLS DMI must program sel1-4 n=0x100/0x100/0x80/0xa8")
if "CLC_PREPROCESS + CLC_DMI_CFG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BLS DMI must use CLC_DMI_CFG 0x2208")
if "base + CROP_PIXEL" not in vfe480 or "base + CROP_LINE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RoundClamp must write Crop-class PIXEL/LINE")
if "MNDS_CROP_LINE" in vfe480:
    raise SystemExit("camss-vfe-480.c: MNDS +0x68 is H_PHASE not crop")
if "VFE_BUS_IMAGE_SIZE_VIOLATION" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BUS image-size dump missing")
if "MODE_MIPI_RAW" not in vfe480:
    raise SystemExit("camss-vfe-480.c: RDI path missing")
if "PACKER_PLAIN_8_LSB_MSB_10" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX NV12 packer 3 missing")
if "PACKER_UBWC_NV12" not in vfe480 or "PACKER_UBWC_NV12\t\t0xB" not in vfe480:
    raise SystemExit("camss-vfe-480.c: UBWC overlay packer 0xB must stay documented")
if "writel_relaxed(PACKER_UBWC_NV12" in vfe480:
    raise SystemExit("camss-vfe-480.c: do not write UBWC packer 0xB onto linear NV12")
if "0xF0, vfe->base + VFE_BUS_COMP_CFG" in vfe480 or "0x30, vfe->base + VFE_BUS_COMP_CFG" in vfe480:
    raise SystemExit("camss-vfe-480.c: COMP_CFG is Dual-IFE sync, not WM mask 0xF0/0x30")
if "is_dual" not in vfe480.split("VFE_BUS_COMP_CFG_0", 1)[0][-800:]:
    raise SystemExit("camss-vfe-480.c: COMP_CFG_0 must document CAF Dual-IFE-only write")
if "writel_relaxed(PACKER_DISP_NV12" in vfe480:
    raise SystemExit("camss-vfe-480.c: PACKER_DISP_NV12 0xB is the UBWC overlay, not PLAIN")
if "PACKER_PLAIN_8_LSB_MSB_10_ODD_EVEN" not in vfe480:
    raise SystemExit("camss-vfe-480.c: NV21 chroma packer 4 must stay documented")
if "if (plain) {\n\t\twritel_relaxed(PACKER_PLAIN_8_LSB_MSB_10_ODD_EVEN" in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF NV12 packer is 3, not NV21 chroma 4")
if "wm == DISP_C_WM ? PACKER_PLAIN_8" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #365 chroma WM PLAIN_8, Y stays packer 3")
if "writel_relaxed(DISP_Y_WM + 1, vfe->base + VFE_BUS_DEBUG_STATUS_TOP_CFG)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BUS debug_status_top must mux DISP WM4")
if "writel_relaxed(1, vfe->base + VFE_BUS_DEBUG_STATUS_TOP_CFG)" in vfe480:
    raise SystemExit("camss-vfe-480.c: debug_status_top_cfg=1 is VID WM0, not DISP")
if "writel_relaxed(MODE_QCOM_PLAIN << WM_CFG_MODE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: PLAIN WM must stay EN=0 until IMAGE_ADDR")
if "if (plain)\n\t\twritel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE" in vfe480:
    raise SystemExit("camss-vfe-480.c: enabling PLAIN WM in wm_config (addr 0) is illegal")
if "writel_relaxed(addr, vfe->base + VFE_BUS_WM_IMAGE_ADDR(wm));" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF writes IMAGE_ADDR in wm_update")
if "if (cfg & (1 << WM_CFG_EN))" not in vfe480:
    raise SystemExit("camss-vfe-480.c: later PIX frames are IMAGE_ADDR + RUP only")
if "VFE_BUS_WM_DEBUG_CFG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WM debug_status_cfg 0xB078 missing")
if "VFE_BUS_WM_ADDR_STATUS0" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WM addr_status_0 dump missing")
if "VFE_BUS_WM_ADDR_STATUS1" not in vfe480 or "VFE_BUS_WM_ADDR_STATUS3" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF addr_status 1-3 dump missing")
if "writel_relaxed((0x14 << 16) | epoch, vfe->base + CLC_CAMIF_EPOCH);\n\tvfe_480_clc_enable(vfe, CLC_CAMIF" in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF EN before IMAGE_ADDR is illegal")
if "static void vfe_480_camif_go" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF start helper missing")
if ".pix_go = vfe_480_camif_go" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF must start after PIX RUP")
if "vfe_480_ds_go(vfe);\n\t\t\tvfe_480_camif_go(vfe)" in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF inside wm_update is before RUP")
if "ops->pix_go(vfe)" not in (root / "drivers/media/platform/qcom/camss/camss-vfe.c").read_text():
    raise SystemExit("camss-vfe.c: PIX CAMIF after init RUP missing")
if "vfe_480_wm_sidecar_linear" not in vfe480:
    raise SystemExit("camss-vfe-480.c: DISP WM sidecar bind missing")
if "VFE_BUS_WM_UBWC_META_ADDR" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WM UBWC meta_addr missing")
if "VFE_BUS_PWR_ISO_CFG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BUS pwr_iso_cfg 0xAA5C missing")
if "writel_relaxed(0, vfe->base + VFE_BUS_PWR_ISO_CFG)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: pwr_iso_cfg must be cleared")
if "CAMNOC_IFE_LINEAR" not in vfe480 or "0x0ac42000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF CAMNOC 0xac42000 IFE_LINEAR map missing")
if "0x66665433" not in vfe480 or "vfe_480_camnoc_ife_qos" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF IFE_LINEAR QoS LUTs missing")
if "VFE_BUS_IF_FRAMEHEADER_CFG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF if_frameheader_cfg missing")
if "vfe_480_bus_common" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BUS SRC_GRP frameheader clear missing")
if "plain ? 0xffffffff : 1" not in vfe480:
    raise SystemExit("camss-vfe-480.c: PIX framedrop must be CamX keep-all")
if "writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_BW_LIMIT" in vfe480:
    raise SystemExit("camss-vfe-480.c: bw_limit=0 stalls DISP (CAF skips zero)")
if "overflow ds as0" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WM6/7 addr_status dump missing")
if "CLC_GTM" not in vfe480 or "CLC_WB" not in vfe480 or "CLC_GAMMA" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX GTM/WB/Gamma between CC and CST missing")
if "vfe_480_clc_enable(vfe, CLC_LIN, BIT(0))" in vfe480:
    raise SystemExit("camss-vfe-480.c: empty Linearization EN=1 overflowed line 0")
if "LIN_SLOPE_Q10" in vfe480.split("vfe_480_lin(struct vfe_device")[-1].split("vfe_480_pedestal(struct vfe_device")[0]:
    raise SystemExit("camss-vfe-480.c: #308 Q10 LIN DMI overflowed line 0; use live dmabuf 36")
if "256u << 16" in vfe480:
    raise SystemExit("camss-vfe-480.c: #308 4 guessed LIN knees overflowed line 0")
if "vfe_480_lin(vfe)" in vfe480:
    raise SystemExit("camss-vfe-480.c: #345 live LIN DMI+16 AHB at 0x2a64 overflowed line 0")
if "042037c1" not in vfe480 or "0x08370040" not in vfe480:
    raise SystemExit("camss-vfe-480.c: keep live dmabuf LIN DMI 36 / DumpRegConfig knees in helper")
if "LIN_DMI_N			36" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX Linearization34 DMI n=36 missing")
if "overflow lin 2a60=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump LIN 0x2a60")
if "vfe_480_gtm(vfe, in_w - 1, pipe_h - 1)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: LSC40 keep-all grid must use CAMIF 2ppc last_x/last_y")
if "LSC_MESH_HM2		15" not in vfe480 or "LSC_MESH_VM2		11" not in vfe480:
    raise SystemExit("camss-vfe-480.c: LSC40 config0 is mesh-2 15/11 (17x13)")
if "LSC_CFG_N			11" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX LSC40 0x3668 x11 missing")
if "overflow lsc40 3660=" not in vfe480:
    raise SystemExit("camss-vfe-480.c: overflow must dump LSC40 0x3668 grid")
if "GTM_DMI_N			0x374" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX LSC40 DMI sel1/2/3 n=0x374 missing")
if "vfe_480_clc_enable(vfe, CLC_GTM, BIT(0))" in vfe480 and "static void vfe_480_gtm" not in vfe480:
    raise SystemExit("camss-vfe-480.c: empty LSC40 EN=1 overflowed line 0")
if "vfe_480_pack(vfe, 0x3658, (const u32[]){ 0, 0, 0 }, 3)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: LSC 0x3660 MODULE must be 0 (#356; 0x3001 + live mesh is black-pixel candidate)")
if "0x00003001" in vfe480:
    raise SystemExit("camss-vfe-480.c: LSC 0x3001 + live mesh is #356 black-pixel candidate")
if "vfe_480_wb(vfe)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WB13 identity DMI Fill missing")
if "vfe_480_pedestal(vfe, in_w - 1, pipe_h - 1)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Pedestal13 identity DMI Fill missing")
if "PEDESTAL_LUT_N		0x208" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Pedestal13 DMI is 0x208 words banks 1/2")
if "vfe_480_clc_enable(vfe, CLC_PEDESTAL, BIT(0));\n\tvfe_480_demux" in vfe480:
    raise SystemExit("camss-vfe-480.c: empty Pedestal EN=1 needs DMI; use vfe_480_pedestal")
if "vfe_480_clc_enable(vfe, CLC_PEDESTAL, 0)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Pedestal MODULE must be 0 (#353; EN=1 + zero LUT is CST-zero class)")
if "vfe_480_clc_enable(vfe, CLC_PEDESTAL, BIT(0))" in vfe480:
    raise SystemExit("camss-vfe-480.c: Pedestal EN=1 + zero DMI is #353 black-pixel candidate")
if "overflow clcstat" not in vfe480 or "CLC_HW_STATUS" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CLC hw_status dump on overflow missing")
if "overflow demuxwin" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX Demux 0x3058/0x3068 window dump missing")
if "WB_LUT_N			512" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WB13 DMI is 512 words at 0x3c08 bank 1")
if "vfe_480_clc_enable(vfe, CLC_WB, BIT(0));\n\tvfe_480_gamma" in vfe480:
    raise SystemExit("camss-vfe-480.c: empty WB13 EN=1 overflowed line 0")
if "vfe_480_gamma(vfe)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Gamma16 identity DMI Fill missing")
if "vfe_480_clc_dmi32" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CLC DMI_32 (CamX 0x3e08 banks 1-3) missing")
if "#define     CLC_DMI_CFG			0x08" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CLC DMI_CFG is module+0x08")
if "vfe_480_clc_enable(vfe, CLC_GAMMA, BIT(0));\n\tvfe_480_cst" in vfe480:
    raise SystemExit("camss-vfe-480.c: empty Gamma16 EN=1 overflowed line 0")
if "bt601_q10" in vfe480:
    raise SystemExit("camss-vfe-480.c: do not pack guessed BT.601 CST matrix")
if "CLC_CST_MATRIX + i * 4" in vfe480:
    raise SystemExit("camss-vfe-480.c: do not loop CLC_CST_MATRIX; live IQ+0x1c uses CLC_CST+0x68")
if "0x00750259" not in vfe480:
    raise SystemExit("camss-vfe-480.c: FULL CST 0x4068 x12 must be live IQ+0x1c (0x00750259)")
if "0x01fe1eae, 0x00001f54, 0x02000000, 0x03ff0000" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live CDM CST word6 is 0x02000000 (#364 [9:0]=0x200 zeroed PIX)")
if "0x00000200, 0x03ff0000" in vfe480:
    raise SystemExit("camss-vfe-480.c: CST [9:0]=0x200 zeros Y/UV (#364); keep 0x02000000")
if "vfe_480_pack(vfe, 0x3c58, (const u32[]){ 0, 0, 0 }, 3)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: GTM 0x3c60 MODULE must be 0 (#351 0,0,1 still EN)")
if "vfe_480_pack(vfe, 0x3e58, (const u32[]){ 0, 0, 0 }, 3)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Gamma 0x3e60 MODULE must be 0 (#351 0,0,1 still EN)")
if "vfe_480_pack(vfe, 0x3c58, (const u32[]){ 0, 0, 1 }, 3)" in vfe480:
    raise SystemExit("camss-vfe-480.c: GTM 0,0,1 is MODULE=1; #351 wrote zeros")
if "vfe_480_pack(vfe, 0x3e58, (const u32[]){ 0, 0, 1 }, 3)" in vfe480:
    raise SystemExit("camss-vfe-480.c: Gamma 0,0,1 is MODULE=1; #351 wrote zeros")
if "vfe_480_pack(vfe, 0x3c58, (const u32[]){ 1, 1, 1 }, 3)" in vfe480:
    raise SystemExit("camss-vfe-480.c: GTM 1,1,1 + identity DMI produced #349 all-zero NV12")
if "vfe_480_pack(vfe, 0x3e58, (const u32[]){ 1, 1, 1 }, 3)" in vfe480:
    raise SystemExit("camss-vfe-480.c: Gamma 1,1,1 + identity DMI produced #349 all-zero NV12")
if "Compact CST12 @0x52d178 is 0x4060 x1" not in vfe480:
    raise SystemExit("camss-vfe-480.c: keep compact vs FULL CST CreateCmdList comment")
if "vfe_480_cc(vfe)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX CC13 identity Fill missing")
if "vfe_480_clc_enable(vfe, CLC_CC, BIT(0))" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #362 restore CC EN=1; PDPC off is the black-pixel fix")
if "vfe_480_clc_enable(vfe, CLC_CC, 0)" in vfe480:
    raise SystemExit("camss-vfe-480.c: CC MODULE=0 was an isolation cut; restore EN after #361 green")
if "vfe_480_clc_enable(vfe, CLC_CC, BIT(0));\n\tvfe_480_cst" in vfe480:
    raise SystemExit("camss-vfe-480.c: CC EN-only is a zero 3x3; use 0x3a68 identity")
if "#define     CLC_CC_MATRIX		0x68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CC13 matrix is 0x3a68, +0x64 is spare")
if "CC_GAIN_UNITY		0x400" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CC13 Q10 unity 0x400 missing")
if "CAMNOC_NIU_MAXWR" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMNOC NIU +0x08 MAXWR dump missing")
if "VFE_BUS_WM_FRAME_HEADER_CFG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WM frame_header_cfg 0xB028 dump missing")
if "WM_DEBUG_STATUS_1_CONSTRAINT	11" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF debug_status_1 mux 11 (constraint) missing")
if "WM_DEBUG_STATUS_0_MUX		1" not in vfe480:
    raise SystemExit("camss-vfe-480.c: packer FSM debug_status_0 mux 1 missing")
if "writel_relaxed(1, vfe->base + VFE_BUS_WM_DEBUG_CFG(wm))" in vfe480:
    raise SystemExit("camss-vfe-480.c: debug_cfg=1 leaves constraint mux 0; use (11<<8)|1")
if "DISP_DS4_WM" not in vfe480 or "PACKER_PLAIN_64" not in vfe480:
    raise SystemExit("camss-vfe-480.c: COMP_GRP_1 WM6/7 PD10 map missing")
if "vfe_480_ds_go(vfe);\n\t\tvfe_480_camif_go(vfe)" in vfe480:
    raise SystemExit("camss-vfe-480.c: DS EN must not pull CAMIF before RUP")
if "core |= BIT(CORE_CFG_0_VID_DS4_R2PD) | BIT(CORE_CFG_0_VID_DS16_R2PD)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Android CORE_CFG sets VID R2PD off")
if "core |= BIT(CORE_CFG_0_DISP_DS4_R2PD) | BIT(CORE_CFG_0_DISP_DS16_R2PD)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: linear NV12 must set DISP R2PD off; on without DSX10 stalls COMP_GRP_1")
if "core &= ~(BIT(CORE_CFG_0_DISP_DS4_R2PD)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #446 identity Android CORE_CFG 0x60000800 DISP R2PD on missing")
if "in_w == 2592 && in_h == 1952 && out_w == 2592 && out_h == 1952" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display Full must keep DISP R2PD off like #386 0x78000800")
if "if (0 && in_w == 2592 && in_h == 1952 && out_w == 2592 && out_h == 1952)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display Full must not execute identity CORE 0x60000800")
if "One variable: identity DISP R2PD on" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #446 must stay identity-only R2PD")
if "identity DISP R2PD on is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #446 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x010c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #447 Camera ID 1 first-list 0x010c missing")
if "0x44440001" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #447 first-list 0x010c=0x44440001 missing")
if "One variable: identity 0x010c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #447 must stay identity-only 0x010c")
if "r010c=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #447 pix-stop r010c missing")
if "0x010c first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #447 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x9c60" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #448 Camera ID 1 first-list 0x9c60 missing")
if "One variable: identity 0x9c60" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #448 must stay identity-only 0x9c60")
if "r9c60=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #448 pix-stop r9c60 missing")
if "0x9c60 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #448 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x9c68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #449 Camera ID 1 first-list 0x9c68 missing")
if "One variable: identity 0x9c68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #449 must stay identity-only 0x9c68")
if "r9c68=0x%x/0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #449 pix-stop r9c68 missing")
if "0x9c68 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #449 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x826c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #450 Camera ID 1 first-list 0x826c missing")
if "One variable: identity 0x826c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #450 must stay identity-only 0x826c")
if "r826c=0x%x/0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #450 pix-stop r826c missing")
if "Do not 0x8260 EN" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #450 must not EN 0x8260")
if "0x826c first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #450 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8260" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #451 Camera ID 1 first-list 0x8260 missing")
if "0xffff0001" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #451 first-list 0x8260=0xffff0001 missing")
if "One variable: identity 0x8260" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #451 must stay identity-only 0x8260")
if "r8260=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #451 pix-stop r8260 missing")
if "0x8260 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #451 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x846c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #452 Camera ID 1 first-list 0x846c missing")
if "One variable: identity 0x846c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #452 must stay identity-only 0x846c")
if "Do not 0x8460 EN" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #452 must not EN 0x8460")
if "r846c=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #452 pix-stop r846c missing")
if "0x846c first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #452 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8480" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #453 Camera ID 1 first-list 0x8480 missing")
if "One variable: identity 0x8480" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #453 must stay identity-only 0x8480")
if "r8480=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #453 pix-stop r8480 missing")
if "0x8480 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #453 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8460" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #454 Camera ID 1 first-list 0x8460 missing")
if "One variable: identity 0x8460" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #454 must stay identity-only 0x8460")
if "r8460=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #454 pix-stop r8460 missing")
if "0x8460 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #454 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8060" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #455 Camera ID 1 first-list 0x8060 missing")
if "One variable: identity 0x8060" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #455 must stay identity-only 0x8060")
if "Do not 0x8068" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #455 must not pack 0x8068")
if "r8060=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #455 pix-stop r8060 missing")
if "0x8060 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #455 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8068" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #456 Camera ID 1 first-list 0x8068 missing")
if "One variable: identity 0x8068" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #456 must stay identity-only 0x8068")
if "r8068=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #456 pix-stop r8068 missing")
if "0x8068 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #456 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8e60" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #457 Camera ID 1 first-list 0x8e60 missing")
if "One variable: identity 0x8e60" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #457 must stay identity-only 0x8e60")
if "Do not 0x8e68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #457 must not pack 0x8e68")
if "r8e60=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #457 pix-stop r8e60 missing")
if "0x8e60 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #457 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8e68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #458 Camera ID 1 first-list 0x8e68 missing")
if "One variable: identity 0x8e68" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #458 must stay identity-only 0x8e68")
if "r8e68=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #458 pix-stop r8e68 missing")
if "0x8e68 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #458 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8660" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #459 Camera ID 1 first-list 0x8660 missing")
if "One variable: identity 0x8660" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #459 must stay identity-only 0x8660")
if "Do not 0x8668" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #459 must not pack 0x8668")
if "r8660=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #459 pix-stop r8660 missing")
if "0x8660 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #459 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x8668" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #460 Camera ID 1 first-list 0x8668 missing")
if "One variable: identity 0x8668" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #460 must stay identity-only 0x8668")
if "r8668=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #460 pix-stop r8668 missing")
if "0x8668 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #460 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x7e6c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #461 Camera ID 1 first-list 0x7e6c missing")
if "One variable: identity 0x7e6c" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #461 must stay identity-only 0x7e6c")
if "Do not 0x7e80" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #461 must not pack 0x7e80")
if "Do not 0x7e60 EN" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #461 must not EN 0x7e60")
if "r7e6c=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #461 pix-stop r7e6c missing")
if "0x7e6c first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #461 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x7e80" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #462 Camera ID 1 first-list 0x7e80 missing")
if "One variable: identity 0x7e80" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #462 must stay identity-only 0x7e80")
if "Do not 0x7e60 EN" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #462 must not EN 0x7e60")
if "r7e80=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #462 pix-stop r7e80 missing")
if "0x7e80 first-list is not the identity stall" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #462 STREAMON 0-byte must stay falsified")
if "vfe_480_pack(vfe, 0x7e60" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #463 Camera ID 1 first-list 0x7e60 missing")
if "One variable: identity 0x7e60" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #463 must stay identity-only 0x7e60")
if "r7e60=0x%x" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #463 pix-stop r7e60 missing")
if "out_w == 2592 && out_h == 1952" not in vfe480:
    raise SystemExit("camss-vfe-480.c: identity first-list must stay dest-gated; Display Full 2320 must not execute 0x7e60")
if "vfe_480_live_display_cdm(vfe, in_w, in_h, out_w, out_h)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display Full must dest-gate TAP first-list")
if "w5868=0x1e7/0x287 vs WM 2320" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display Full must restore OUT dest after TAP 488")
if "u32 dest_w = out_w" not in vfe480:
    raise SystemExit("camss-vfe-480.c: live_display_cdm must spill dest before TAP clobber")
if "if (0 && in_w == 2592 && in_h == 1952 && dest_w == 2592 && dest_h == 1952)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Display Full must not execute TAP identity 488 OUT")
# #425 starts WM6/7 with dummy IOVA + live 324x244 / 81x61.
# Empty ADDR=0 EN hung CAMNOC. 0x5608 CLC without WM6/7 hung CAMNOC.
if "writel_relaxed(0, vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS4_WM))" in vfe480:
    raise SystemExit("camss-vfe-480.c: empty ADDR WM6 hung CAMNOC")
if "lower_32_bits(vfe_480_ds4_dma)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #425 WM6 dummy IOVA missing")
if "lower_32_bits(vfe_480_ds16_dma)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: #425 WM7 dummy IOVA missing")
if "vfe_480_pixel_pattern(sink->code) << CORE_CFG_0_PIXEL_PATTERN" in vfe480:
    raise SystemExit("camss-vfe-480.c: CORE_CFG_0 bits 24-25 are dsp_mode/DSP_STREAMING; Bayer is Demux even/odd")
if "vfe_480_clc_enable(vfe, CLC_CAMIF, CAMIF_EN | CAMIF_IFE_OUT_EN);" in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF MODULE 0x101 missing Bayer bits 24-26 (CamX 0x526538)")
if "pat << CAMIF_PIXEL_PATTERN" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CamX CAMIF MODULE must BFI Bayer into bits 24-26")
if "CAMIF_PIXEL_PATTERN		24" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF Bayer shift 24 missing")
if "writel_relaxed(((in_h - 1) << 16) | 0, vfe->base + CAMIF_CROP_HEIGHT)" in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF HEIGHT 3059 never arrives; 2ppc last is pipe_h-1")
if "writel_relaxed(((pipe_h - 1) << 16) | 0, vfe->base + CAMIF_CROP_HEIGHT)" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAMIF_CROP_HEIGHT must use pipe_h (debug line=1530)")
if "vfe_480_clc_enable(vfe, base, BIT(0));\n\twritel_relaxed(0, vfe->base + base + CROP_SPARE)" in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 MODULE 0x1 missing bit1; CamX MNDS-class is 0x3")
if "vfe_480_clc_enable(vfe, base, BIT(0) | BIT(1));" not in vfe480:
    raise SystemExit("camss-vfe-480.c: Crop11 MODULE must be EN+bit1 like CamX MNDS 0x3")
if "core = 1 << CORE_CFG_0_OPERATING_MODE" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CORE_CFG_0 must match Android 0x60000800 (no pattern)")
if "CORE_CFG_0_DSP_STREAMING" not in vfe480:
    raise SystemExit("camss-vfe-480.c: CAF DSP_STREAMING shift 25 must stay named")
if "\n\twritel_relaxed(0, vfe->base + VFE_BUS_WM_PACKER_CFG(wm));\n" in vfe480:
    raise SystemExit("camss-vfe-480.c: unconditional PACKER_CFG 0 (PLAIN_128) is illegal")
if "VFE_BUS_WM_DEBUG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WM debug 0xB07C dump missing")
if "UBWC_STATIC_LPDDR5" not in vfe480 or "0x1036" not in vfe480:
    raise SystemExit("camss-vfe-480.c: kona LPDDR5 ubwc-static-cfg 0x1036 missing")
if "VFE_BUS_UBWC_STATIC_CTRL" not in vfe480:
    raise SystemExit("camss-vfe-480.c: BUS ubwc_static_ctrl 0xAA58 missing")
if "VFE_BUS_WM_UBWC_MODE_CFG" not in vfe480:
    raise SystemExit("camss-vfe-480.c: WM UBWC mode_cfg missing")
if "writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(wm))" not in vfe480:
    raise SystemExit("camss-vfe-480.c: linear DISP must keep UBWC compressor off")
if "writel_relaxed(1, vfe->base + VFE_BUS_WM_UBWC_MODE_CFG" in vfe480:
    raise SystemExit("camss-vfe-480.c: do not enable UBWC compressor on V4L2 NV12")
if "vfe_formats_pix_8250" not in (root / "drivers/media/platform/qcom/camss/camss-vfe.c").read_text():
    raise SystemExit("camss-vfe.c: PIX Bayer→NV12 table missing")
if "&vfe_formats_pix_8250" not in (root / "drivers/media/platform/qcom/camss/camss.c").read_text().split("vfe_res_8250", 1)[-1][:1500]:
    raise SystemExit("camss.c: VFE0/1 PIX not on vfe_formats_pix_8250")
if "not CSI VC 3" not in (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text():
    raise SystemExit("camss-csid-gen2.c: IPP CSI VC0 missing")
if "CSI VC 0 feeds IPP when pad 4 is PIX" not in (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text():
    raise SystemExit("camss-csid-gen2.c: CSI VC 0 → IPP pad 4 missing")
if "Titan 480 IPP bit2 is horizontal_bin_en" not in (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text():
    raise SystemExit("camss-csid-gen2.c: IPP CFG0 still reuses RDI TIMESTAMP_EN as horizontal_bin")
if "dagu: CSID does not stomp IFE core" not in (root / "drivers/media/platform/qcom/camss/camss-csid.c").read_text():
    raise SystemExit("camss-csid.c: CSID vfe0 stomp still present")
if "dagu: raise VFE clock instead of EBUSY" not in (root / "drivers/media/platform/qcom/camss/camss-vfe.c").read_text():
    raise SystemExit("camss-vfe.c: PIX clock EBUSY still present")
if "vfe_line_min_clock" not in (root / "drivers/media/platform/qcom/camss/camss-vfe.c").read_text():
    raise SystemExit("camss-vfe.c: PIX IFE core clock missing")

# UFS clk scaling + OPP rpmhpd deadlocks exception_event vs devfreq on this
# QHEE (no ICC). Keep gating/hibern8; just do not register devfreq.
path = root / "drivers/ufs/host/ufs-qcom.c"
text = path.read_text()
marker = "dagu: skip UFSHCD_CAP_CLK_SCALING"
if marker not in text:
    old = """	hba->caps |= UFSHCD_CAP_CLK_GATING | UFSHCD_CAP_HIBERN8_WITH_CLK_GATING;
	hba->caps |= UFSHCD_CAP_CLK_SCALING | UFSHCD_CAP_WB_WITH_CLK_SCALING;
	hba->caps |= UFSHCD_CAP_AUTO_BKOPS_SUSPEND;
"""
    new = """	hba->caps |= UFSHCD_CAP_CLK_GATING | UFSHCD_CAP_HIBERN8_WITH_CLK_GATING;
	/* dagu: skip UFSHCD_CAP_CLK_SCALING — OPP rpmhpd + devfreq vs
	 * exception_event_handler clk_scaling_lock hung_task panic.
	 */
	hba->caps |= UFSHCD_CAP_AUTO_BKOPS_SUSPEND;
"""
    if old not in text:
        raise SystemExit(f"{path}: UFSHCD_CAP_CLK_SCALING needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

# dagu: Venus ICC stub. No CONFIG_INTERCONNECT_QCOM_SM8250 on this QHEE.
# icc_set_bw(NULL) is a no-op; do not EPROBE_DEFER video-mem / cpu-cfg.
path = root / "drivers/media/platform/qcom/venus/core.c"
text = path.read_text()
marker = "dagu: ICC video-mem stubbed"
if marker not in text:
    old = """	core->video_path = devm_of_icc_get(dev, "video-mem");
	if (IS_ERR(core->video_path))
		return PTR_ERR(core->video_path);

	core->cpucfg_path = devm_of_icc_get(dev, "cpu-cfg");
	if (IS_ERR(core->cpucfg_path))
		return PTR_ERR(core->cpucfg_path);
"""
    new = """	core->video_path = devm_of_icc_get(dev, "video-mem");
	if (IS_ERR(core->video_path)) {
		/* dagu: ICC video-mem stubbed — no SM8250 ICC provider.
		 * icc_set_bw(NULL) is a no-op. Do not EPROBE_DEFER.
		 */
		dev_warn(dev, "ICC video-mem stubbed, ignoring bandwidth voting\\n");
		core->video_path = NULL;
	}

	core->cpucfg_path = devm_of_icc_get(dev, "cpu-cfg");
	if (IS_ERR(core->cpucfg_path)) {
		/* dagu: ICC cpu-cfg stubbed */
		dev_warn(dev, "ICC cpu-cfg stubbed, ignoring bandwidth voting\\n");
		core->cpucfg_path = NULL;
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: Venus ICC get needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")
if marker not in path.read_text():
    raise SystemExit(f"{path}: Venus ICC stub missing after patch")

# dagu: MPEG2 OPB is 256-byte stride; VP8/MPEG2 DPB min=32 breaks dmabuf.
path = root / "drivers/media/platform/qcom/venus/helpers.h"
text = path.read_text()
if "venus_helper_set_opb_stride" not in text:
    old = """int venus_helper_set_stride(struct venus_inst *inst, unsigned int aligned_width,
			    unsigned int aligned_height);
#endif
"""
    new = """int venus_helper_set_stride(struct venus_inst *inst, unsigned int aligned_width,
			    unsigned int aligned_height);
int venus_helper_set_opb_stride(struct venus_inst *inst, u32 stride, u32 height);
#endif
"""
    if old not in text:
        raise SystemExit(f"{path}: set_stride prototype needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: venus_helper_set_opb_stride")

path = root / "drivers/media/platform/qcom/venus/helpers.c"
text = path.read_text()
if "venus_helper_set_opb_stride" not in text:
    old = """	return hfi_session_set_property(inst, ptype, &plane_actual_info);
}
EXPORT_SYMBOL_GPL(venus_helper_set_stride);
"""
    new = """	return hfi_session_set_property(inst, ptype, &plane_actual_info);
}
EXPORT_SYMBOL_GPL(venus_helper_set_stride);

int venus_helper_set_opb_stride(struct venus_inst *inst, u32 stride, u32 height)
{
	const u32 ptype = HFI_PROPERTY_PARAM_UNCOMPRESSED_PLANE_ACTUAL_INFO;
	struct hfi_uncompressed_plane_actual_info plane_actual_info;

	if (!inst->opb_buftype)
		return 0;

	plane_actual_info.buffer_type = inst->opb_buftype;
	plane_actual_info.num_planes = 2;
	plane_actual_info.plane_format[0].actual_stride = stride;
	plane_actual_info.plane_format[0].actual_plane_buffer_height = height;
	plane_actual_info.plane_format[1].actual_stride = stride;
	plane_actual_info.plane_format[1].actual_plane_buffer_height = height / 2;

	return hfi_session_set_property(inst, ptype, &plane_actual_info);
}
EXPORT_SYMBOL_GPL(venus_helper_set_opb_stride);
"""
    if old not in text:
        raise SystemExit(f"{path}: set_stride body needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: venus_helper_set_opb_stride")

path = root / "drivers/media/platform/qcom/venus/helpers.c"
text = path.read_text()
if "dagu: MPEG2 1080p uses WORK_MODE_2" in text:
    old = """		/* dagu: MPEG2 1080p uses WORK_MODE_2 (same as H.264).
		 * This QHEE firmware's MODE_1 OPB wraps the next 128px
		 * onto the right edge. Xiaomi SM8250 always programmed MODE_2.
		 */
		if (inst->pic_struct != HFI_INTERLACE_FRAME_PROGRESSIVE ||
		    num_mbs <= NUM_MBS_720P)
			mode = VIDC_WORK_MODE_1;
"""
    new = """		/* dagu: CAF Iris2 MPEG2 uses WORK_MODE_1 + work_route=1. */
		if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2 ||
		    inst->pic_struct != HFI_INTERLACE_FRAME_PROGRESSIVE ||
		    num_mbs <= NUM_MBS_720P)
			mode = VIDC_WORK_MODE_1;
"""
    if old not in text:
        raise SystemExit(f"{path}: revert WORK_MODE_2 needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: MPEG2 WORK_MODE_1")

text = path.read_text()
if "is_dec && inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2" not in text:
    old = """	params.version = version;
	params.num_vpp_pipes = inst->core->res->num_vpp_pipes;

	if (is_dec) {
"""
    new = """	params.version = version;
	params.num_vpp_pipes = inst->core->res->num_vpp_pipes;
	if (is_dec && inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2)
		params.num_vpp_pipes = 1;

	if (is_dec) {
"""
    if old not in text:
        raise SystemExit(f"{path}: MPEG2 num_vpp_pipes needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: MPEG2 scratch 1 VPP pipe")

path = root / "drivers/media/platform/qcom/venus/vdec.c"
text = path.read_text()
# Do not program HFI stride 2048 for MPEG2 — firmware then emits a
# layout that looks destiled. V4L2 bytesperline 2048 is still required.
old_hfi256_nl = """	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2) {
		u32 mpeg2_w = ALIGN(width, 256);

		inst->output2_buf_size =
			venus_helper_get_framesz_raw(out2_fmt, mpeg2_w, height);
		ret = venus_helper_set_opb_stride(inst, mpeg2_w, height);
		if (ret)
			dev_dbg(inst->core->dev_dec,
				"MPEG2 OPB stride %u: %d\\n", mpeg2_w, ret);
	}

	if (inst->dpb_fmt) {
""".replace("\\n", "\n")
new_hfi = """	if (inst->dpb_fmt) {
"""
if old_hfi256_nl in text:
    path.write_text(text.replace(old_hfi256_nl, new_hfi, 1))
    print(f"patched {path}: drop MPEG2 HFI 256 OPB stride")
    text = path.read_text()

text = path.read_text()
if "dagu: CAF msm_vidc_decide_work_route_iris2" not in text:
    old = """	wr.video_work_route = inst->core->res->num_vpp_pipes;

	return hfi_session_set_property(inst, ptype, &wr);
"""
    new = """	wr.video_work_route = inst->core->res->num_vpp_pipes;
	/*
	 * dagu: CAF msm_vidc_decide_work_route_iris2() forces route=1 for
	 * MPEG2 (and interlaced). Default 4 VPP pipes destile 1920 as 16
	 * 128px tiles and the last tile wraps onto the first.
	 */
	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2 ||
	    inst->pic_struct != HFI_INTERLACE_FRAME_PROGRESSIVE)
		wr.video_work_route = 1;

	ret = hfi_session_set_property(inst, ptype, &wr);
	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2)
		dev_info(inst->core->dev_dec,
			 "dagu mpeg2 work_route=%u: %d\\n",
			 wr.video_work_route, ret);
	return ret;
"""
    if old not in text:
        raise SystemExit(f"{path}: vdec_set_work_route needle missing")
    # vanilla function has no local ret
    if "int ret;" not in path.read_text().split("static int vdec_set_work_route")[1].split("static int")[0]:
        old_sig = """static int vdec_set_work_route(struct venus_inst *inst)
{
	u32 ptype = HFI_PROPERTY_PARAM_WORK_ROUTE;
	struct hfi_video_work_route wr;

	if (!(IS_IRIS2(inst->core) || IS_IRIS2_1(inst->core)))
		return 0;
"""
        new_sig = """static int vdec_set_work_route(struct venus_inst *inst)
{
	u32 ptype = HFI_PROPERTY_PARAM_WORK_ROUTE;
	struct hfi_video_work_route wr;
	int ret;

	if (!(IS_IRIS2(inst->core) || IS_IRIS2_1(inst->core)))
		return 0;
"""
        text = path.read_text()
        if old_sig not in text:
            raise SystemExit(f"{path}: vdec_set_work_route signature needle missing")
        path.write_text(text.replace(old_sig, new_sig, 1))
    text = path.read_text()
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: MPEG2 work_route=1")

text = path.read_text()
if "dagu: MPEG2 firmware reports 32-aligned" not in text:
    old = """	} else {
		inst->crop.left = 0;
		inst->crop.top = 0;
		inst->crop.width = ev_data->width;
		inst->crop.height = ev_data->height;
	}
"""
    new = """	} else {
		inst->crop.left = 0;
		inst->crop.top = 0;
		inst->crop.width = ev_data->width;
		inst->crop.height = ev_data->height;
	}
	/*
	 * dagu: MPEG2 firmware reports 32-aligned height (1088 for 1080p)
	 * and no input_crop. COMPOSE==1088 makes GStreamer advertise 1088
	 * and waylandsink fail linux-dmabuf import (H.264 compose is 1080).
	 */
	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2 &&
	    inst->crop.height == 1088)
		inst->crop.height = 1080;
	/*
	 * dagu: Iris2 MPEG2 destile repeats the left 128px tile on the
	 * right of 1920 OPB. Compose 1792 hides the duplicate; 1792 is
	 * 128-aligned so waylandsink can still import dmabuf.
	 */
	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2 &&
	    inst->crop.width == 1920)
		inst->crop.width = 1792;
"""
    if old not in text:
        raise SystemExit(f"{path}: vdec_event_change crop needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: MPEG2 compose 1080")

text = path.read_text()
if "inst->crop.width = 1792" not in text:
    old = """	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2 &&
	    inst->crop.height == 1088)
		inst->crop.height = 1080;
"""
    new = """	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2 &&
	    inst->crop.height == 1088)
		inst->crop.height = 1080;
	/*
	 * dagu: Iris2 MPEG2 destile repeats the left 128px tile on the
	 * right of 1920 OPB. Compose 1792 hides the duplicate; 1792 is
	 * 128-aligned so waylandsink can still import dmabuf.
	 */
	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2 &&
	    inst->crop.width == 1920)
		inst->crop.width = 1792;
"""
    if old not in text:
        raise SystemExit(f"{path}: MPEG2 compose 1792 needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: MPEG2 compose 1792")

text = path.read_text()
if "dagu: Iris2 default linear NV12 stride" not in text:
    old = """	ret = venus_helper_set_dyn_bufmode(inst);
	if (ret)
		return ret;

	return 0;
}
"""
    new = """	if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2) {
		u32 stride = ALIGN(width, 128);

		/*
		 * dagu: Iris2 default linear NV12 stride is 256-aligned
		 * (2048 for 1080p). Destile then writes 16 128px tiles into
		 * a 1920 OPB and the 16th tile lands on the first (wrap).
		 */
		ret = venus_helper_set_opb_stride(inst, stride, height);
		dev_info(inst->core->dev_dec,
			 "dagu mpeg2 opb=%u fmt=%#x dpb=%#x stride=%u: %d\\n",
			 inst->opb_buftype, inst->opb_fmt, inst->dpb_fmt,
			 stride, ret);
		if (ret)
			return ret;
	}

	ret = venus_helper_set_dyn_bufmode(inst);
	if (ret)
		return ret;

	return 0;
}
"""
    if old not in text:
        raise SystemExit(f"{path}: MPEG2 OPB stride 1920 needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: MPEG2 OPB stride 1920")

text = path.read_text()
if "else if (out2_fmt && !out_fmt)" not in text:
    old = """	} else if (is_ubwc_fmt(out2_fmt) || is_10bit_ubwc_fmt(out_fmt)) {
		inst->opb_buftype = HFI_BUFFER_OUTPUT;
		inst->opb_fmt = out_fmt;
		inst->dpb_buftype = HFI_BUFFER_OUTPUT2;
		inst->dpb_fmt = out2_fmt;
	} else {
		inst->opb_buftype = HFI_BUFFER_OUTPUT;
		inst->opb_fmt = out_fmt;
		inst->dpb_buftype = 0;
		inst->dpb_fmt = 0;
	}
"""
    new = """	} else if (is_ubwc_fmt(out2_fmt) || is_10bit_ubwc_fmt(out_fmt)) {
		inst->opb_buftype = HFI_BUFFER_OUTPUT;
		inst->opb_fmt = out_fmt;
		inst->dpb_buftype = HFI_BUFFER_OUTPUT2;
		inst->dpb_fmt = out2_fmt;
	} else if (out2_fmt && !out_fmt) {
		inst->opb_buftype = HFI_BUFFER_OUTPUT2;
		inst->opb_fmt = out2_fmt;
		inst->dpb_buftype = 0;
		inst->dpb_fmt = 0;
	} else {
		inst->opb_buftype = HFI_BUFFER_OUTPUT;
		inst->opb_fmt = out_fmt;
		inst->dpb_buftype = 0;
		inst->dpb_fmt = 0;
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: MPEG2 OUTPUT2-only OPB needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: MPEG2 OUTPUT2-only OPB")

text = path.read_text()
if "else if (inst->opb_buftype == HFI_BUFFER_OUTPUT2)" not in text:
    old = """	if (inst->dpb_fmt) {
		ret = venus_helper_set_multistream(inst, false, true);
		if (ret)
			return ret;

		ret = venus_helper_set_raw_format(inst, inst->dpb_fmt,
						  inst->dpb_buftype);
		if (ret)
			return ret;

		ret = venus_helper_set_output_resolution(inst, width, height,
							 HFI_BUFFER_OUTPUT2);
		if (ret)
			return ret;
	}

	if (IS_V3(core) || IS_V4(core) || IS_V6(core)) {
		ret = venus_helper_get_bufreq(inst, HFI_BUFFER_OUTPUT, &bufreq);
		if (ret)
			return ret;

		if (bufreq.size > inst->output_buf_size)
			return -EINVAL;

		if (inst->dpb_fmt) {
			ret = venus_helper_get_bufreq(inst, HFI_BUFFER_OUTPUT2,
						      &bufreq);
			if (ret)
				return ret;

			if (bufreq.size > inst->output2_buf_size)
				return -EINVAL;
		}
"""
    new = """	if (inst->dpb_fmt) {
		ret = venus_helper_set_multistream(inst, false, true);
		if (ret)
			return ret;

		ret = venus_helper_set_raw_format(inst, inst->dpb_fmt,
						  inst->dpb_buftype);
		if (ret)
			return ret;

		ret = venus_helper_set_output_resolution(inst, width, height,
							 HFI_BUFFER_OUTPUT2);
		if (ret)
			return ret;
	} else if (inst->opb_buftype == HFI_BUFFER_OUTPUT2) {
		ret = venus_helper_set_multistream(inst, false, true);
		if (ret)
			return ret;

		ret = venus_helper_set_output_resolution(inst, width, height,
							 HFI_BUFFER_OUTPUT2);
		if (ret)
			return ret;
	}

	if (IS_V3(core) || IS_V4(core) || IS_V6(core)) {
		if (inst->output_buf_size) {
			ret = venus_helper_get_bufreq(inst, HFI_BUFFER_OUTPUT,
						      &bufreq);
			if (ret)
				return ret;

			if (bufreq.size > inst->output_buf_size)
				return -EINVAL;
		}

		if (inst->output2_buf_size) {
			ret = venus_helper_get_bufreq(inst, HFI_BUFFER_OUTPUT2,
						      &bufreq);
			if (ret)
				return ret;

			if (bufreq.size > inst->output2_buf_size)
				return -EINVAL;
		}
"""
    if old not in text:
        raise SystemExit(f"{path}: MPEG2 OUTPUT2 bufreq needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: MPEG2 OUTPUT2 bufreq")

text = path.read_text()
if "static void vdec_capture_plane" not in text:
    old = """	return &fmt[i];
}

static const struct venus_format *
vdec_try_fmt_common(struct venus_inst *inst, struct v4l2_format *f)
"""
    new = """	return &fmt[i];
}

/*
 * G_FMT sizeimage and vb2 CAPTURE alloc must use the same stride.
 * dagu: MPEG2 firmware still fills 128-aligned OPB (1920 for 1080p).
 * Advertising 2048 shears the packed payload. Compose 1088→1080 lets
 * waylandsink import dmabuf.
 */
static void vdec_capture_plane(struct venus_inst *inst, u32 pixfmt,
			       u32 width, u32 height, u32 *bytesperline,
			       u32 *sizeimage)
{
	u32 stride = width;

	if (pixfmt == V4L2_PIX_FMT_P010)
		stride *= 2;
	stride = ALIGN(stride, 128);
	if (bytesperline)
		*bytesperline = stride;
	if (sizeimage)
		*sizeimage = venus_helper_get_framesz(pixfmt, stride, height);
}

static const struct venus_format *
vdec_try_fmt_common(struct venus_inst *inst, struct v4l2_format *f)
"""
    if old not in text:
        raise SystemExit(f"{path}: vdec_capture_plane insert needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: vdec_capture_plane")

text = path.read_text()
if "vdec_capture_plane(inst, pixmp->pixelformat" not in text:
    old_helper = """	if (f->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
		vdec_capture_plane(inst, pixmp->pixelformat, pixmp->width,
				   pixmp->height, &pfmt[0].bytesperline,
				   &pfmt[0].sizeimage);
	} else {
"""
    candidates = [
"""	if (f->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
		unsigned int stride = pixmp->width;
		unsigned int stride_align = 128;

		if (pixmp->pixelformat == V4L2_PIX_FMT_P010)
			stride *= 2;

		/*
		 * dagu: MPEG2 firmware writes OPB with 256-byte stride
		 * (2048 for 1080p). Mapping as 1920 wraps the next row onto
		 * the right 128px.
		 */
		if (inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2)
			stride_align = 256;

		pfmt[0].bytesperline = ALIGN(stride, stride_align);
		if (stride_align > 128)
			szimage = venus_helper_get_framesz(pixmp->pixelformat,
							   pfmt[0].bytesperline,
							   pixmp->height);
		pfmt[0].sizeimage = szimage;
	} else {
""",
"""	if (f->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
		unsigned int stride = pixmp->width;

		if (pixmp->pixelformat == V4L2_PIX_FMT_P010)
			stride *= 2;

		pfmt[0].sizeimage = szimage;
		pfmt[0].bytesperline = ALIGN(stride, 128);
""",
    ]
    for old in candidates:
        if old in text:
            path.write_text(text.replace(old, old_helper if "sizeimage = szimage" not in old[:80] else old_helper, 1))
            # second candidate's replacement should still be helper call; first already includes "} else {"
            print(f"patched {path}: try_fmt uses vdec_capture_plane")
            break
    else:
        raise SystemExit(f"{path}: try_fmt capture plane needle missing")
    # Fix the virgin candidate: it doesn't include "} else {", so replace with helper+else
    text = path.read_text()
    if "vdec_capture_plane(inst, pixmp->pixelformat" not in text:
        raise SystemExit(f"{path}: try_fmt still missing vdec_capture_plane")

text = path.read_text()
if "output2_buf_size = format.fmt.pix_mp.plane_fmt[0].sizeimage" not in text:
    old = """		inst->fmt_cap = fmt;
		inst->output2_buf_size =
			venus_helper_get_framesz(pixfmt_cap, orig_pixmp.width, orig_pixmp.height);
"""
    new = """		inst->fmt_cap = fmt;
		inst->output2_buf_size = format.fmt.pix_mp.plane_fmt[0].sizeimage;
"""
    if old not in text:
        raise SystemExit(f"{path}: s_fmt output2_buf_size needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: s_fmt OPB sizeimage")

text = path.read_text()
if "vdec_capture_plane(inst, inst->fmt_cap->pixfmt" not in text:
    old = """	case V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE:
		*num_planes = inst->fmt_cap->num_planes;
		sizes[0] = venus_helper_get_framesz(inst->fmt_cap->pixfmt,
						    inst->width,
						    inst->height);
		inst->output_buf_size = sizes[0];
		*num_buffers = max(*num_buffers, out_num);
		inst->num_output_bufs = *num_buffers;

		mutex_lock(&inst->lock);
		if (inst->codec_state == VENUS_DEC_STATE_CAPTURE_SETUP)
			inst->codec_state = VENUS_DEC_STATE_STOPPED;
		mutex_unlock(&inst->lock);
		break;
"""
    new = """	case V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE: {
		u32 cap_sz;

		*num_planes = inst->fmt_cap->num_planes;
		vdec_capture_plane(inst, inst->fmt_cap->pixfmt, inst->width,
				   inst->height, NULL, &cap_sz);
		sizes[0] = cap_sz;
		if (inst->output2_buf_size)
			sizes[0] = max(sizes[0], inst->output2_buf_size);
		inst->output_buf_size = sizes[0];
		*num_buffers = max(*num_buffers, out_num);
		inst->num_output_bufs = *num_buffers;

		mutex_lock(&inst->lock);
		if (inst->codec_state == VENUS_DEC_STATE_CAPTURE_SETUP)
			inst->codec_state = VENUS_DEC_STATE_STOPPED;
		mutex_unlock(&inst->lock);
		break;
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: queue_setup capture size needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: queue_setup MPEG2 stride size")

path = root / "drivers/media/platform/qcom/venus/vdec_ctrls.c"
text = path.read_text()
# Marker is split across two comment lines ("Do not clamp" / "H.264").
if "only VP8/MPEG2" not in text:
    old_all = """			/*
			 * dagu: GST uses this as CAPTURE/OPB count. VP8/MPEG2
			 * firmware DPB min is 32; 32 OPB mmap buffers never
			 * become dmabuf and waylandsink cannot import them.
			 * H.264 reports ~16 and dmabuf import works.
			 */
			if (ctrl->val > 16)
				ctrl->val = 16;
"""
    old_up = """	case V4L2_CID_MIN_BUFFERS_FOR_CAPTURE:
		ret = venus_helper_get_bufreq(inst, HFI_BUFFER_OUTPUT, &bufreq);
		if (!ret)
			ctrl->val = hfi_bufreq_get_count_min(&bufreq, ver);
		break;
"""
    new_clamp = """			/*
			 * dagu: GST uses this as CAPTURE/OPB count. Clamp
			 * only VP8/MPEG2 (firmware DPB min 32). Do not clamp
			 * H.264 (~19) or VP9 — those already dmabuf-import.
			 */
			if ((inst->hfi_codec == HFI_VIDEO_CODEC_VP8 ||
			     inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2) &&
			    ctrl->val > 16)
				ctrl->val = 16;
"""
    new_full = """	case V4L2_CID_MIN_BUFFERS_FOR_CAPTURE:
		ret = venus_helper_get_bufreq(inst, HFI_BUFFER_OUTPUT, &bufreq);
		if (!ret) {
			ctrl->val = hfi_bufreq_get_count_min(&bufreq, ver);
			/*
			 * dagu: GST uses this as CAPTURE/OPB count. Clamp
			 * only VP8/MPEG2 (firmware DPB min 32). Do not clamp
			 * H.264 (~19) or VP9 — those already dmabuf-import.
			 */
			if ((inst->hfi_codec == HFI_VIDEO_CODEC_VP8 ||
			     inst->hfi_codec == HFI_VIDEO_CODEC_MPEG2) &&
			    ctrl->val > 16)
				ctrl->val = 16;
		}
		break;
"""
    if old_all in text:
        path.write_text(text.replace(old_all, new_clamp, 1))
        print(f"patched {path}: clamp MIN_BUFFERS VP8/MPEG2 only")
    elif old_up in text:
        path.write_text(text.replace(old_up, new_full, 1))
        print(f"patched {path}: clamp MIN_BUFFERS_FOR_CAPTURE")
    else:
        raise SystemExit(f"{path}: MIN_BUFFERS_FOR_CAPTURE needle missing")

# dagu: Venus=m cannot select prompt-less helpers to =y. CAMSS is already
text = path.read_text()
if "dagu: GST uses this as CAPTURE" not in text:
    old = """	case V4L2_CID_MIN_BUFFERS_FOR_CAPTURE:
		ret = venus_helper_get_bufreq(inst, HFI_BUFFER_OUTPUT, &bufreq);
		if (!ret)
			ctrl->val = hfi_bufreq_get_count_min(&bufreq, ver);
		break;
"""
    new = """	case V4L2_CID_MIN_BUFFERS_FOR_CAPTURE:
		ret = venus_helper_get_bufreq(inst, HFI_BUFFER_OUTPUT, &bufreq);
		if (!ret) {
			ctrl->val = hfi_bufreq_get_count_min(&bufreq, ver);
			/*
			 * dagu: GST uses this as CAPTURE/OPB count. VP8/MPEG2
			 * firmware DPB min is 32; 32 OPB mmap buffers never
			 * become dmabuf and waylandsink cannot import them.
			 * H.264 reports ~16 and dmabuf import works.
			 */
			if (ctrl->val > 16)
				ctrl->val = 16;
		}
		break;
"""
    if old not in text:
        raise SystemExit(f"{path}: MIN_BUFFERS_FOR_CAPTURE needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: clamp MIN_BUFFERS_FOR_CAPTURE")

# dagu: Venus=m cannot select prompt-less helpers to =y. CAMSS is already
# built-in; pull mem2mem / contig / h264 / vp9 into the Image so Venus
# modules only link against vmlinux.
path = root / "drivers/media/platform/qcom/camss/Kconfig"
text = path.read_text()
marker = "select V4L2_MEM2MEM_DEV"
if marker not in text:
    old = """	select VIDEOBUF2_DMA_SG
	select V4L2_FWNODE
"""
    new = """	select VIDEOBUF2_DMA_SG
	select VIDEOBUF2_DMA_CONTIG
	select V4L2_MEM2MEM_DEV
	select V4L2_H264
	select V4L2_VP9
	select V4L2_FWNODE
"""
    if old not in text:
        raise SystemExit(f"{path}: CAMSS select needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")
if marker not in path.read_text():
    raise SystemExit(f"{path}: CAMSS Venus helper selects missing")
PY

python3 - "$KERNEL_SRC" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "S5KJN1_AGAIN_SHIFT		8" not in text:
    old = """#define S5KJN1_AGAIN_MAX		64
#define S5KJN1_AGAIN_STEP		1
#define S5KJN1_AGAIN_DEFAULT		6
#define S5KJN1_AGAIN_SHIFT		5
"""
    new = """#define S5KJN1_AGAIN_MAX		16 /* dagu: CamX analog gain <<8; 16x=0x1000 */
#define S5KJN1_AGAIN_STEP		1
#define S5KJN1_AGAIN_DEFAULT		6
#define S5KJN1_AGAIN_SHIFT		8
"""
    if old not in text:
        raise SystemExit(f"{path}: AGAIN_SHIFT needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: dagu: CamX analog gain <<8")
    text = path.read_text()

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if '#include <linux/types.h>' not in text:
    old = '#include <linux/units.h>\n'
    if old not in text:
        raise SystemExit(f"{path}: linux/units.h needle missing")
    path.write_text(text.replace(old, old + '#include <linux/types.h>\n', 1))
    print(f"patched {path}: include linux/types.h")
    text = path.read_text()

S5KJN1_ENABLE_STREAMS_HEAD = r'''static int s5kjn1_enable_streams(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *state, u32 pad,
				 u64 streams_mask)
{
	struct s5kjn1 *s5kjn1 = to_s5kjn1(sd);
	const struct s5kjn1_reg_list *reg_list = &s5kjn1->mode->reg_list;
	static const unsigned int mcu_delays_ms[] = { 10, 20, 50, 100 };
	bool mcu_ok = false;
	int i, ret;

	ret = pm_runtime_resume_and_get(s5kjn1->dev);
	if (ret)
		return ret;

	dev_info(s5kjn1->dev, "dagu s5kjn1 mclk=%lu Hz\n",
		 clk_get_rate(s5kjn1->mclk));

	for (i = 0; i < 10; i++) {
		ret = 0;
		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
		if (!ret)
			break;
		dev_info(s5kjn1->dev, "dagu s5kjn1 0x6028 retry %d: %d\n",
			 i, ret);
		msleep(10);
	}
	if (ret)
		goto error;

	cci_write(s5kjn1->regmap, CCI_REG16(0x0000), 0x0001, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x0000), S5KJN1_CHIP_ID, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x001e), 0x0007, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6010), 0x0001, &ret);
	if (ret)
		goto error;
	usleep_range(5 * USEC_PER_MSEC, 6 * USEC_PER_MSEC);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6226), 0x0001, &ret);
	if (ret)
		goto error;
	usleep_range(10 * USEC_PER_MSEC, 11 * USEC_PER_MSEC);

	/*
	 * dagu: MODE_SELECT then 0x2174
	 * dagu: 0x2400 delay sweep then 0x4000 mode. MCU NACK is not
	 * STREAMON failure — Android D-PHY preview lives on page 0x4000.
	 */
	for (i = 0; i < ARRAY_SIZE(mcu_delays_ms); i++) {
		msleep(mcu_delays_ms[i]);
		ret = 0;
		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &ret);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 0x2400 retry %d delay=%u ret=%d\n",
			 i, mcu_delays_ms[i], ret);
		if (!ret) {
			mcu_ok = true;
			break;
		}
	}
	ret = 0;

	if (mcu_ok) {
		cci_multi_reg_write(s5kjn1->regmap, init_array_setting,
				    ARRAY_SIZE(init_array_setting), &ret);
		if (!ret)
			cci_multi_reg_write(s5kjn1->regmap,
					    s5kjn1_dagu_4080x3060_mcu,
					    ARRAY_SIZE(s5kjn1_dagu_4080x3060_mcu),
					    &ret);
		if (ret) {
			dev_info(s5kjn1->dev,
				 "dagu s5kjn1 MCU table NACK %d; continue 0x4000\n",
				 ret);
			ret = 0;
			mcu_ok = false;
		}
	} else {
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 MCU 0x2400 NACK; 0x4000 D-PHY mode only\n");
	}

	{
		int afe_ret = 0;

		/*
		 * dagu: CamX analog gain <<8
		 * dagu: CamX AFE tail after MCU before analog. initSettings
		 * 0x4000 tail: 16-bit 0xf44e pack, then 8-bit 0x0106=0x01.
		 * Skip 0x0bcc (Qtech NACK). Do not put this in the analog
		 * table (0x6226 NACK) or after 0x2174 (CCI reads 0).
		 */
		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &afe_ret);
		cci_write(s5kjn1->regmap, CCI_REG16(0xf44e), 0x0011, &afe_ret);
		cci_write(s5kjn1->regmap, CCI_REG16(0xf44c), 0x0b0b, &afe_ret);
		cci_write(s5kjn1->regmap, CCI_REG16(0xf44a), 0x0006, &afe_ret);
		cci_write(s5kjn1->regmap, CCI_REG16(0x0118), 0x0002, &afe_ret);
		cci_write(s5kjn1->regmap, CCI_REG16(0x011a), 0x0001, &afe_ret);
		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &afe_ret);
		cci_write(s5kjn1->regmap, CCI_REG8(0x0106), 0x01, &afe_ret);
		if (afe_ret)
			dev_info(s5kjn1->dev,
				 "dagu s5kjn1 AFE tail NACK %d\n", afe_ret);
	}

	/*
	 * dagu: 0x4000 page retry after MCU. Qtech NACKs analog 0x6028
	 * immediately after the 0x2400 dump; delay-sweep like the MCU page.
	 */
	ret = -EIO;
	for (i = 0; i < ARRAY_SIZE(mcu_delays_ms); i++) {
		msleep(mcu_delays_ms[i]);
		ret = 0;
		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 0x4000 retry %d delay=%u ret=%d\n",
			 i, mcu_delays_ms[i], ret);
		if (!ret)
			break;
	}
	if (ret)
		goto error;

	cci_multi_reg_write(s5kjn1->regmap, reg_list->regs,
			    reg_list->num_regs, &ret);
	if (ret)
		goto error;

	ret = __v4l2_ctrl_handler_setup(s5kjn1->sd.ctrl_handler);

	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x0a70, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0001, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x0a72, &ret);
	cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0100, &ret);
	if (ret)
		goto error;
	cci_write(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE,
		  S5KJN1_MODE_STREAMING, &ret);
	if (ret) {
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 MODE_SELECT NACK %d\n", ret);
		goto error;
	}

	if (mcu_ok) {
		int page_ret = 0;

		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &page_ret);
		if (!page_ret) {
			cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x2174,
				  &page_ret);
			cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0401,
				  &page_ret);
			if (page_ret)
				dev_info(s5kjn1->dev,
					 "dagu s5kjn1 0x2174 NACK %d\n",
					 page_ret);
		} else {
			dev_info(s5kjn1->dev,
				 "dagu s5kjn1 post-mode 0x2400 NACK %d\n",
				 page_ret);
		}
	}

	/*
	 * dagu: analog page after STREAM
	 * dagu: no AFE after 0x2174. Writing 0xf44e here makes analog
	 * CCI reads return 0; Linaro AFE in the analog table NACKs 0x6226.
	 * dagu: drop AFE analog table. Same NACK if written after analog mode.
	 * dagu: CamX analog gain <<8
	 * dagu: CamX AFE tail after MCU before analog
	 */
	ret = -EIO;
	for (i = 0; i < ARRAY_SIZE(mcu_delays_ms); i++) {
		msleep(mcu_delays_ms[i]);
		ret = 0;
		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
		if (!ret)
			break;
	}
	if (ret) {
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 analog page after 0x2174 NACK %d\n", ret);
		ret = 0;
	}

	dev_info(s5kjn1->dev, "dagu s5kjn1 streaming %ux%u mcu=%d\n",
		 s5kjn1->mode->width, s5kjn1->mode->height, mcu_ok);
	msleep(80);
	{
		u64 fc = 0, mode = 0, lanes = 0, exp = 0, again = 0, tpg = 0;
		u64 afe = 0, dual = 0;

		cci_read(s5kjn1->regmap, CCI_REG8(0x0005), &fc, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE, &mode, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0114), &lanes, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_EXPOSURE, &exp, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_AGAIN, &again, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_TEST_PATTERN, &tpg, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0xf44e), &afe, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0106), &dual, NULL);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 fc=0x%llx mode=0x%llx r0114=0x%llx exp=0x%llx again=0x%llx tpg=0x%llx f44e=0x%llx r0106=0x%llx\n",
			 fc, mode, lanes, exp, again, tpg, afe, dual);
	}
	return 0;

error:
	dev_err(s5kjn1->dev, "failed to start streaming: %d\n", ret);
	pm_runtime_put_autosuspend(s5kjn1->dev);

	return ret;
}

'''

marker = "dagu: 0x2400 delay sweep then 0x4000 mode"
if marker not in text:
    start = text.find("static int s5kjn1_enable_streams(")
    end = text.find("static int s5kjn1_disable_streams(")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: enable_streams bounds missing")
    path.write_text(text[:start] + S5KJN1_ENABLE_STREAMS_HEAD + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: VIO then VANA then VDIG"
if marker not in text:
    start = text.find("static int s5kjn1_power_on(struct device *dev)")
    end = text.find("static int s5kjn1_power_off(struct device *dev)")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: power_on bounds missing")
    new = r'''static int s5kjn1_power_on(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct s5kjn1 *s5kjn1 = to_s5kjn1(sd);
	int ret;

	/*
	 * dagu: VIO then VANA then VDIG. CAF cam_vio / cam_vana / cam_vdig.
	 * VDIG before AVDD left the Qtech array at optical black while
	 * CCI/MIPI still produced RAW10 — same failure as imx596.
	 */
	if (s5kjn1->vddio) {
		ret = regulator_enable(s5kjn1->vddio);
		if (ret)
			return ret;
		usleep_range(USEC_PER_MSEC, 2 * USEC_PER_MSEC);
	}

	if (s5kjn1->vdda) {
		ret = regulator_enable(s5kjn1->vdda);
		if (ret)
			goto disable_vddio;
		usleep_range(5 * USEC_PER_MSEC, 6 * USEC_PER_MSEC);
	}

	if (s5kjn1->vddd) {
		ret = regulator_enable(s5kjn1->vddd);
		if (ret)
			goto disable_vdda;
		usleep_range(USEC_PER_MSEC, 2 * USEC_PER_MSEC);
	}

	if (s5kjn1->afvdd) {
		ret = regulator_enable(s5kjn1->afvdd);
		if (ret)
			goto disable_vddd;
	}

	ret = clk_prepare_enable(s5kjn1->mclk);
	if (ret)
		goto disable_regulators;

	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(s5kjn1->reset_gpio, 1);
	usleep_range(2000, 3000);
	gpiod_set_value_cansleep(s5kjn1->reset_gpio, 0);
	usleep_range(50 * USEC_PER_MSEC, 55 * USEC_PER_MSEC);
	dev_info(s5kjn1->dev,
		 "dagu s5kjn1 rails VIO-VANA-VDIG mclk=%lu Hz after XSHUTDOWN\n",
		 clk_get_rate(s5kjn1->mclk));

	return 0;

disable_regulators:
	if (s5kjn1->afvdd)
		regulator_disable(s5kjn1->afvdd);

disable_vddd:
	if (s5kjn1->vddd) {
		usleep_range(USEC_PER_MSEC, 2 * USEC_PER_MSEC);
		regulator_disable(s5kjn1->vddd);
	}

disable_vdda:
	if (s5kjn1->vdda)
		regulator_disable(s5kjn1->vdda);

disable_vddio:
	if (s5kjn1->vddio)
		regulator_disable(s5kjn1->vddio);

	return ret;
}

'''
    path.write_text(text[:start] + new + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: drop VDIG then VANA then VIO"
if marker not in text:
    old = """static int s5kjn1_power_off(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct s5kjn1 *s5kjn1 = to_s5kjn1(sd);

	gpiod_set_value_cansleep(s5kjn1->reset_gpio, 1);

	clk_disable_unprepare(s5kjn1->mclk);

	if (s5kjn1->afvdd)
		regulator_disable(s5kjn1->afvdd);

	if (s5kjn1->vddio)
		regulator_disable(s5kjn1->vddio);

	if (s5kjn1->vdda)
		regulator_disable(s5kjn1->vdda);

	if (s5kjn1->vddd) {
		usleep_range(USEC_PER_MSEC, 2 * USEC_PER_MSEC);
		regulator_disable(s5kjn1->vddd);
	}

	return 0;
}
"""
    new = """static int s5kjn1_power_off(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct s5kjn1 *s5kjn1 = to_s5kjn1(sd);

	gpiod_set_value_cansleep(s5kjn1->reset_gpio, 1);

	clk_disable_unprepare(s5kjn1->mclk);

	if (s5kjn1->afvdd)
		regulator_disable(s5kjn1->afvdd);

	/* dagu: drop VDIG then VANA then VIO */
	if (s5kjn1->vddd) {
		usleep_range(USEC_PER_MSEC, 2 * USEC_PER_MSEC);
		regulator_disable(s5kjn1->vddd);
	}

	if (s5kjn1->vdda)
		regulator_disable(s5kjn1->vdda);

	if (s5kjn1->vddio)
		regulator_disable(s5kjn1->vddio);

	return 0;
}
"""
    if old not in text:
        raise SystemExit(f"{path}: s5kjn1 power_off needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "dagu: s5kjn1 native crop is mode WxH" not in text:
    old = """	if (sel->which != V4L2_SUBDEV_FORMAT_ACTIVE)
		return -EINVAL;

	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = s5kjn1->mode->width;
		sel->r.height = s5kjn1->mode->width;
		return 0;
"""
    old_height = """	if (sel->which != V4L2_SUBDEV_FORMAT_ACTIVE)
		return -EINVAL;

	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = s5kjn1->mode->width;
		sel->r.height = s5kjn1->mode->height;
		return 0;
"""
    new = """	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_NATIVE_SIZE:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		/* dagu: s5kjn1 native crop is mode WxH */
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = s5kjn1->mode->width;
		sel->r.height = s5kjn1->mode->height;
		return 0;
"""
    if old in text:
        text = text.replace(old, new, 1)
    elif old_height in text:
        text = text.replace(old_height, new, 1)
    else:
        raise SystemExit(f"{path}: s5kjn1 get_selection needle missing")
    path.write_text(text)
    print(f"patched {path}: native crop WxH")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: preview 2040x1530, do not enum 8160"
# Retired: analog half-crop 2040 does not change Qtech MIPI. Keep 4080-only.
if False and marker not in text:
    old = """static const struct s5kjn1_mode s5kjn1_supported_modes[] = {
	{
		.width = 4080,
		.height = 3060,
		.hts = 5888,
		.vts = 3164,
		.exposure = 3000, /* dagu: default <= VTS-margin (3164-22) */
		.exposure_margin = 22,
		.reg_list = {
			.regs = s5kjn1_dagu_4080x3060_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_dagu_4080x3060_mode),
		},
	},
	{
		.width = 8160,
		.height = 6144,
		.hts = 8688,
		.vts = 6400,
		.exposure = 6144,
		.exposure_margin = 44,
		.reg_list = {
			.regs = s5kjn1_8160x6144_10fps_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_8160x6144_10fps_mode),
		},
	},
};
"""
    new = """static const struct s5kjn1_mode s5kjn1_supported_modes[] = {
	{
		/* dagu: preview 2040x1530, do not enum 8160 */
		.width = 2040,
		.height = 1530,
		.hts = 5888,
		.vts = 3164,
		.exposure = 1500, /* dagu: default <= VTS-margin (3164-22) */
		.exposure_margin = 22,
		.reg_list = {
			.regs = s5kjn1_dagu_2040x1530_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_dagu_2040x1530_mode),
		},
	},
};
"""
    if old not in text:
        raise SystemExit(f"{path}: supported_modes 4080+8160 needle missing")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if "s5kjn1_8160x6144_10fps_mode[] __maybe_unused" not in text:
    old = "static const struct cci_reg_sequence s5kjn1_8160x6144_10fps_mode[] = {"
    new = "static const struct cci_reg_sequence s5kjn1_8160x6144_10fps_mode[] __maybe_unused = {"
    if old not in text:
        raise SystemExit(f"{path}: 8160 array decl needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: mark leftover 8160 array unused")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: pin HV-flip 0x0101"
# Retired: READ_ONLY made IPA Permission denied (exposure/gain).
if False and marker not in text:
    old = """	if (s5kjn1->hflip)
		s5kjn1->hflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT;

	s5kjn1->vflip = v4l2_ctrl_new_std(ctrl_hdlr, &s5kjn1_ctrl_ops,
					  V4L2_CID_VFLIP, 0, 1, 1, 1);
	if (s5kjn1->vflip)
		s5kjn1->vflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT;
"""
    new = """	if (s5kjn1->hflip)
		s5kjn1->hflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT |
				       V4L2_CTRL_FLAG_READ_ONLY; /* dagu: pin HV-flip 0x0101 */

	s5kjn1->vflip = v4l2_ctrl_new_std(ctrl_hdlr, &s5kjn1_ctrl_ops,
					  V4L2_CID_VFLIP, 0, 1, 1, 1);
	if (s5kjn1->vflip)
		s5kjn1->vflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT |
				       V4L2_CTRL_FLAG_READ_ONLY;
"""
    if old not in text:
        raise SystemExit(f"{path}: hflip MODIFY_LAYOUT needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: pin 0x0101 HV-flip on STREAMON"
# Retired: extra 0x0101 write; HEAD relies on ctrl_handler_setup default 1.
if False and marker not in text:
    old = """	ret = __v4l2_ctrl_handler_setup(s5kjn1->sd.ctrl_handler);

	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
"""
    new = """	ret = __v4l2_ctrl_handler_setup(s5kjn1->sd.ctrl_handler);

	/* dagu: pin 0x0101 HV-flip on STREAMON */
	cci_write(s5kjn1->regmap, S5KJN1_REG_ORIENTATION,
		  S5KJN1_HFLIP | S5KJN1_VFLIP, &ret);

	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
"""
    if old not in text:
        raise SystemExit(f"{path}: handler_setup STREAMON needle missing")
    text = text.replace(old, new, 1)

    old = """	dev_info(s5kjn1->dev, "dagu s5kjn1 streaming %ux%u mcu=%d\\n",
		 s5kjn1->mode->width, s5kjn1->mode->height, mcu_ok);
	msleep(80);
	{
		u64 fc = 0, mode = 0, lanes = 0;

		cci_read(s5kjn1->regmap, CCI_REG8(0x0005), &fc, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE, &mode, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0114), &lanes, NULL);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 fc=0x%llx mode=0x%llx r0114=0x%llx\\n",
			 fc, mode, lanes);
	}
"""
    new = """	dev_info(s5kjn1->dev,
		 "dagu s5kjn1 streaming %ux%u mcu=%d hflip=%d vflip=%d\\n",
		 s5kjn1->mode->width, s5kjn1->mode->height, mcu_ok,
		 s5kjn1->hflip->val, s5kjn1->vflip->val);
	msleep(80);
	{
		u64 fc = 0, mode = 0, lanes = 0, orient = 0;

		cci_read(s5kjn1->regmap, CCI_REG8(0x0005), &fc, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE, &mode, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0114), &lanes, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_ORIENTATION, &orient, NULL);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 fc=0x%llx mode=0x%llx r0114=0x%llx r0101=0x%llx\\n",
			 fc, mode, lanes, orient);
	}
"""
    if old not in text:
        raise SystemExit(f"{path}: streaming log needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: restamp analog crop after MCU 0x2174"
# Retired: 0x2174 before STREAM + analog restamp desynced Qtech packer.
if False and marker not in text:
    old = """	if (ret)
		goto error;
	cci_write(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE,
		  S5KJN1_MODE_STREAMING, &ret);
	if (ret) {
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 MODE_SELECT NACK %d\\n", ret);
		goto error;
	}
	if (mcu_ok) {
		int page_ret = 0;

		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &page_ret);
		if (!page_ret) {
			cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x2174,
				  &page_ret);
			cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0401,
				  &page_ret);
			if (page_ret)
				dev_info(s5kjn1->dev,
					 "dagu s5kjn1 0x2174 NACK %d\\n",
					 page_ret);
		} else {
			dev_info(s5kjn1->dev,
				 "dagu s5kjn1 post-mode 0x2400 NACK %d\\n",
				 page_ret);
		}
	}

	dev_info(s5kjn1->dev,
		 "dagu s5kjn1 streaming %ux%u mcu=%d hflip=%d vflip=%d\\n",
		 s5kjn1->mode->width, s5kjn1->mode->height, mcu_ok,
		 s5kjn1->hflip->val, s5kjn1->vflip->val);
	msleep(80);
	{
		u64 fc = 0, mode = 0, lanes = 0, orient = 0;

		cci_read(s5kjn1->regmap, CCI_REG8(0x0005), &fc, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE, &mode, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0114), &lanes, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_ORIENTATION, &orient, NULL);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 fc=0x%llx mode=0x%llx r0114=0x%llx r0101=0x%llx\\n",
			 fc, mode, lanes, orient);
	}
	return 0;
"""
    new = """	if (ret)
		goto error;
	if (mcu_ok) {
		int page_ret = 0;

		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &page_ret);
		if (!page_ret) {
			cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x2174,
				  &page_ret);
			cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0401,
				  &page_ret);
			if (page_ret)
				dev_info(s5kjn1->dev,
					 "dagu s5kjn1 0x2174 NACK %d\\n",
					 page_ret);
		} else {
			dev_info(s5kjn1->dev,
				 "dagu s5kjn1 post-mode 0x2400 NACK %d\\n",
				 page_ret);
		}
	}

	/* dagu: restamp analog crop after MCU 0x2174 */
	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, &ret);
	cci_multi_reg_write(s5kjn1->regmap, reg_list->regs,
			    reg_list->num_regs, &ret);
	cci_write(s5kjn1->regmap, S5KJN1_REG_ORIENTATION,
		  S5KJN1_HFLIP | S5KJN1_VFLIP, &ret);
	if (ret)
		goto error;
	cci_write(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE,
		  S5KJN1_MODE_STREAMING, &ret);
	if (ret) {
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 MODE_SELECT NACK %d\\n", ret);
		goto error;
	}

	dev_info(s5kjn1->dev,
		 "dagu s5kjn1 streaming %ux%u mcu=%d hflip=%d vflip=%d\\n",
		 s5kjn1->mode->width, s5kjn1->mode->height, mcu_ok,
		 s5kjn1->hflip->val, s5kjn1->vflip->val);
	msleep(80);
	{
		u64 fc = 0, mode = 0, lanes = 0, orient = 0;
		u64 x0 = 0, y0 = 0, x1 = 0, y1 = 0, ow = 0, oh = 0, bin = 0;

		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, NULL);
		cci_read(s5kjn1->regmap, CCI_REG8(0x0005), &fc, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_CTRL_MODE, &mode, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0114), &lanes, NULL);
		cci_read(s5kjn1->regmap, S5KJN1_REG_ORIENTATION, &orient, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0344), &x0, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0346), &y0, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0348), &x1, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x034a), &y1, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x034c), &ow, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x034e), &oh, NULL);
		cci_read(s5kjn1->regmap, CCI_REG16(0x0900), &bin, NULL);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 fc=0x%llx mode=0x%llx r0114=0x%llx r0101=0x%llx\\n",
			 fc, mode, lanes, orient);
		dev_info(s5kjn1->dev,
			 "dagu s5kjn1 analog=0x%llx,0x%llx..0x%llx,0x%llx out=%llux%llx bin=0x%llx\\n",
			 x0, y0, x1, y1, ow, oh, bin);
	}
	return 0;
"""
    if old not in text:
        raise SystemExit(f"{path}: 0x2174 restamp needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: 2040 skips CamX 4080 MCU table"
# Retired: width-gated MCU skip. HEAD always writes MCU when mcu_ok.
if False and marker not in text and "dagu: 2040 is 0x4000 analog only" not in text:
    old = """		if (!ret)
			cci_multi_reg_write(s5kjn1->regmap,
					    s5kjn1_dagu_4080x3060_mcu,
					    ARRAY_SIZE(s5kjn1_dagu_4080x3060_mcu),
					    &ret);
"""
    new = """		/* dagu: 2040 skips CamX 4080 MCU table */
		if (!ret && s5kjn1->mode->width >= 4080)
			cci_multi_reg_write(s5kjn1->regmap,
					    s5kjn1_dagu_4080x3060_mcu,
					    ARRAY_SIZE(s5kjn1_dagu_4080x3060_mcu),
					    &ret);
"""
    if old not in text:
        raise SystemExit(f"{path}: 4080 MCU table write needle missing")
    text = text.replace(old, new, 1)
    old = """	if (mcu_ok) {
		int page_ret = 0;

		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &page_ret);
		if (!page_ret) {
			cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x2174,
				  &page_ret);
			cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0401,
				  &page_ret);
"""
    new = """	if (mcu_ok && s5kjn1->mode->width >= 4080) {
		int page_ret = 0;

		cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x2400, &page_ret);
		if (!page_ret) {
			cci_write(s5kjn1->regmap, CCI_REG16(0x602a), 0x2174,
				  &page_ret);
			cci_write(s5kjn1->regmap, CCI_REG16(0x6f12), 0x0401,
				  &page_ret);
"""
    if old not in text:
        raise SystemExit(f"{path}: 0x2174 2040-skip needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: 2040 is 0x4000 analog only"
# Retired: skipped MCU init on analog-only path.
if False and marker not in text:
    old = """	if (mcu_ok) {
		cci_multi_reg_write(s5kjn1->regmap, init_array_setting,
				    ARRAY_SIZE(init_array_setting), &ret);
		/* dagu: 2040 skips CamX 4080 MCU table */
		if (!ret && s5kjn1->mode->width >= 4080)
			cci_multi_reg_write(s5kjn1->regmap,
					    s5kjn1_dagu_4080x3060_mcu,
					    ARRAY_SIZE(s5kjn1_dagu_4080x3060_mcu),
					    &ret);
"""
    new = """	/* dagu: 2040 is 0x4000 analog only */
	if (mcu_ok && s5kjn1->mode->width >= 4080) {
		cci_multi_reg_write(s5kjn1->regmap, init_array_setting,
				    ARRAY_SIZE(init_array_setting), &ret);
		if (!ret)
			cci_multi_reg_write(s5kjn1->regmap,
					    s5kjn1_dagu_4080x3060_mcu,
					    ARRAY_SIZE(s5kjn1_dagu_4080x3060_mcu),
					    &ret);
"""
    if old not in text:
        raise SystemExit(f"{path}: 2040 skip-all-MCU needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: preview 4080x3060 CamX, do not enum 8160"
if marker not in text:
    old_2040 = """static const struct s5kjn1_mode s5kjn1_supported_modes[] = {
	{
		/* dagu: preview 2040x1530, do not enum 8160 */
		.width = 2040,
		.height = 1530,
		.hts = 5888,
		.vts = 3164,
		.exposure = 1500, /* dagu: default <= VTS-margin (3164-22) */
		.exposure_margin = 22,
		.reg_list = {
			.regs = s5kjn1_dagu_2040x1530_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_dagu_2040x1530_mode),
		},
	},
};
"""
    old_both = """static const struct s5kjn1_mode s5kjn1_supported_modes[] = {
	{
		.width = 4080,
		.height = 3060,
		.hts = 5888,
		.vts = 3164,
		.exposure = 3000, /* dagu: default <= VTS-margin (3164-22) */
		.exposure_margin = 22,
		.reg_list = {
			.regs = s5kjn1_dagu_4080x3060_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_dagu_4080x3060_mode),
		},
	},
	{
		.width = 8160,
		.height = 6144,
		.hts = 8688,
		.vts = 6400,
		.exposure = 6144,
		.exposure_margin = 44,
		.reg_list = {
			.regs = s5kjn1_8160x6144_10fps_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_8160x6144_10fps_mode),
		},
	},
};
"""
    new = """static const struct s5kjn1_mode s5kjn1_supported_modes[] = {
	{
		/* dagu: preview 4080x3060 CamX, do not enum 8160 */
		.width = 4080,
		.height = 3060,
		.hts = 5888,
		.vts = 3164,
		.exposure = 3000, /* dagu: default <= VTS-margin (3164-22) */
		.exposure_margin = 22,
		.reg_list = {
			.regs = s5kjn1_dagu_4080x3060_mode,
			.num_regs = ARRAY_SIZE(s5kjn1_dagu_4080x3060_mode),
		},
	},
};
"""
    if old_2040 in text:
        text = text.replace(old_2040, new, 1)
    elif old_both in text:
        text = text.replace(old_both, new, 1)
    else:
        raise SystemExit(f"{path}: 4080-only supported_modes needle missing")
    path.write_text(text)
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: MODE_SELECT then 0x2174"
if marker not in text:
    start = text.find("static int s5kjn1_enable_streams(")
    end = text.find("static int s5kjn1_disable_streams(")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: enable_streams bounds missing")
    path.write_text(text[:start] + S5KJN1_ENABLE_STREAMS_HEAD + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: analog page after 0x2174"
if marker not in text:
    start = text.find("static int s5kjn1_enable_streams(")
    end = text.find("static int s5kjn1_disable_streams(")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: enable_streams bounds missing")
    path.write_text(text[:start] + S5KJN1_ENABLE_STREAMS_HEAD + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: 0x2174 start 0x0401 after analog rails"
if marker not in text:
    start = text.find("static int s5kjn1_enable_streams(")
    end = text.find("static int s5kjn1_disable_streams(")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: enable_streams bounds missing")
    path.write_text(text[:start] + S5KJN1_ENABLE_STREAMS_HEAD + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: 0x4000 page retry after MCU"
if marker not in text:
    start = text.find("static int s5kjn1_enable_streams(")
    end = text.find("static int s5kjn1_disable_streams(")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: enable_streams bounds missing")
    path.write_text(text[:start] + S5KJN1_ENABLE_STREAMS_HEAD + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: no AFE after 0x2174"
if marker not in text:
    start = text.find("static int s5kjn1_enable_streams(")
    end = text.find("static int s5kjn1_disable_streams(")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: enable_streams bounds missing")
    path.write_text(text[:start] + S5KJN1_ENABLE_STREAMS_HEAD + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: drop AFE analog table"
if marker not in text:
    start = text.find("static int s5kjn1_enable_streams(")
    end = text.find("static int s5kjn1_disable_streams(")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: enable_streams bounds missing")
    path.write_text(text[:start] + S5KJN1_ENABLE_STREAMS_HEAD + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: CamX AFE tail after MCU before analog"
if marker not in text:
    start = text.find("static int s5kjn1_enable_streams(")
    end = text.find("static int s5kjn1_disable_streams(")
    if start < 0 or end < 0:
        raise SystemExit(f"{path}: enable_streams bounds missing")
    path.write_text(text[:start] + S5KJN1_ENABLE_STREAMS_HEAD + text[end:])
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu: analog page 0x4000 before CSI regs"
if marker not in text:
    old = """	if (!pm_runtime_get_if_active(s5kjn1->dev))
		return 0;

	switch (ctrl->id) {
"""
    new = """	if (!pm_runtime_get_if_active(s5kjn1->dev))
		return 0;

	/* dagu: analog page 0x4000 before CSI regs */
	cci_write(s5kjn1->regmap, CCI_REG16(0x6028), 0x4000, NULL);

	switch (ctrl->id) {
"""
    if old not in text:
        raise SystemExit(f"{path}: set_ctrl runtime needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
old_ro = """	if (s5kjn1->hflip)
		s5kjn1->hflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT |
				       V4L2_CTRL_FLAG_READ_ONLY; /* dagu: pin HV-flip 0x0101 */

	s5kjn1->vflip = v4l2_ctrl_new_std(ctrl_hdlr, &s5kjn1_ctrl_ops,
					  V4L2_CID_VFLIP, 0, 1, 1, 1);
	if (s5kjn1->vflip)
		s5kjn1->vflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT |
				       V4L2_CTRL_FLAG_READ_ONLY;
"""
new_rw = """	if (s5kjn1->hflip)
		s5kjn1->hflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT;

	s5kjn1->vflip = v4l2_ctrl_new_std(ctrl_hdlr, &s5kjn1_ctrl_ops,
					  V4L2_CID_VFLIP, 0, 1, 1, 1);
	if (s5kjn1->vflip)
		s5kjn1->vflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT;
"""
if old_ro in text:
    path.write_text(text.replace(old_ro, new_rw, 1))
    print(f"patched {path}: unpin HV-flip READ_ONLY")

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
if ".regs = s5kjn1_8160x6144_10fps_mode" in text:
    raise SystemExit(f"{path}: 8160 still enumerated to userspace")
if ".regs = s5kjn1_dagu_2040x1530_mode" in text:
    raise SystemExit(f"{path}: 2040 still enumerated; analog crop does not change MIPI")
if ".regs = s5kjn1_dagu_4080x3060_mode" not in text:
    raise SystemExit(f"{path}: CamX 4080 preview mode not wired")
if "dagu: MODE_SELECT then 0x2174" not in text:
    raise SystemExit(f"{path}: STREAMON not MODE_SELECT then 0x2174")
if "dagu: restamp analog crop after MCU 0x2174" in text:
    raise SystemExit(f"{path}: restamp still in STREAMON")
if "V4L2_CTRL_FLAG_READ_ONLY; /* dagu: pin HV-flip 0x0101 */" in text:
    raise SystemExit(f"{path}: HV-flip still READ_ONLY")
if "dagu: 2040 is 0x4000 analog only" in text:
    raise SystemExit(f"{path}: analog-only MCU skip still present")
if "dagu: no AFE after 0x2174" not in text:
    raise SystemExit(f"{path}: STREAMON still writes AFE after 0x2174")
if "dagu: drop AFE analog table" not in text:
    raise SystemExit(f"{path}: AFE analog-table write still in STREAMON")
if "dagu: CamX analog gain <<8" not in text:
    raise SystemExit(f"{path}: analog gain still Linaro <<5")
if "dagu: CamX AFE tail after MCU before analog" not in text:
    raise SystemExit(f"{path}: STREAMON missing CamX AFE tail after MCU")
if "S5KJN1_AGAIN_SHIFT		8" not in text:
    raise SystemExit(f"{path}: AGAIN_SHIFT is not CamX <<8")
if "S5KJN1_AGAIN_MAX		16" not in text:
    raise SystemExit(f"{path}: AGAIN_MAX is not CamX 16x")
_fn = text[text.find("static int s5kjn1_enable_streams("):
           text.find("static int s5kjn1_disable_streams(")]
if "cci_write(s5kjn1->regmap, CCI_REG16(0x0106)" in _fn:
    raise SystemExit(f"{path}: STREAMON still writes 0x0106 as 16-bit")
if "CCI_REG8(0x0106)" not in _fn:
    raise SystemExit(f"{path}: STREAMON missing CCI_REG8(0x0106)")
if "CCI_REG16(0x0816)" in _fn:
    raise SystemExit(f"{path}: STREAMON still writes Linaro 0x0816")
if "CCI_REG16(0xf44e)" not in _fn:
    raise SystemExit(f"{path}: STREAMON missing CamX 0xf44e AFE")
if "dagu: AFE on live analog page after 0x2174" in text:
    raise SystemExit(f"{path}: live-page AFE still present")
if "dagu: analog-only STREAM no remosaic start" in text:
    raise SystemExit(f"{path}: analog-only skip still present; CSID overflows without MCU")
if "dagu: analog page after STREAM" not in text:
    raise SystemExit(f"{path}: STREAMON did not restore analog page after STREAM")
if "dagu: analog AFE after STREAM" in text:
    raise SystemExit(f"{path}: AFE after STREAM still present; analog CCI reads zero")
if "dagu: 0x4000 page retry after MCU" not in text:
    raise SystemExit(f"{path}: STREAMON missing 0x4000 page retry after MCU")
if "dagu: analog AFE 0xf44e after mode table" in text:
    raise SystemExit(f"{path}: AFE still before analog table; 0x4000 NACKs")
if "dagu: VIO then VANA then VDIG" not in text:
    raise SystemExit(f"{path}: s5kjn1 still enables VDIG before AVDD")
if "dagu: drop VDIG then VANA then VIO" not in text:
    raise SystemExit(f"{path}: s5kjn1 power_off still drops VIO first")
if "dagu: analog page 0x4000 before CSI regs" not in text:
    raise SystemExit(f"{path}: set_ctrl still writes CSI regs without analog page")

path = root / "drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c"
text = path.read_text()
marker = "csiphy4 imx596: keep T_hs"
if marker not in text:
    old = """	else if (csiphy->id == 1)
		settle_cnt = 0x13; /* dagu: Android s5kjn1 D-PHY settle 0x13 */
	/* dagu: log csiphy settle */
"""
    new = """	else if (csiphy->id == 1)
		settle_cnt = 0x13; /* dagu: Android s5kjn1 D-PHY settle 0x13 */
	/* csiphy4 imx596: keep T_hs from 678.4 MHz; do not copy rear 0x13. */
	/* dagu: log csiphy settle */
"""
    if old not in text:
        raise SystemExit(f"{path}: csiphy4 settle comment needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")
PY

# Fluence AEC/NS COPP + SLIMBUS_7 A2DP virtual port. Idempotent.
python3 "$ROOT/scripts/dagu-overlay-adsp-voice.py" "$KERNEL_SRC"

# FastRPC: user kref + DMA cookie so close cannot Oops reboot.
python3 "$ROOT/scripts/dagu-overlay-fastrpc.py" "$KERNEL_SRC"
python3 - "$KERNEL_SRC" <<'PY'
from pathlib import Path
import sys

text = (Path(sys.argv[1]) / "drivers/misc/fastrpc.c").read_text()
if "dagu: FastRPC user kref lives past close" not in text:
    raise SystemExit("fastrpc.c: user kref marker missing")
if "dma_free_coherent(buf->dev, buf->size, buf->virt, buf->phys)" not in text:
    raise SystemExit("fastrpc.c: DMA cookie free missing")
if "fastrpc_ipa_to_dma_addr(buf->fl->cctx, buf->dma_addr)" in text:
    raise SystemExit("fastrpc.c: buf_free must not load fl->cctx")
if "kref_init(&fl->refcount);" not in text:
    raise SystemExit("fastrpc.c: device_open kref_init missing")
if "fastrpc_user_put(fl);" not in text:
    raise SystemExit("fastrpc.c: user_put missing")
print("persist fastrpc user kref + DMA cookie")
PY
