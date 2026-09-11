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
install_src drivers/power/supply/bq2597x-dagu.c
install_src drivers/power/supply/p9418-dagu.c
install_src drivers/power/supply/xiaomi-dual-fg.c
install_src drivers/watchdog/qcom-wdt-early-dagu.c
install_src drivers/gpu/drm/msm/msm_fbdev.c
install_src drivers/media/i2c/imx596-dagu.c

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

append_once "$KERNEL_SRC/drivers/power/supply/Makefile" \
	'xiaomi-dual-fg.o' \
	'obj-$(CONFIG_BATTERY_XIAOMI_DUAL_FG) += xiaomi-dual-fg.o'

append_once "$KERNEL_SRC/drivers/watchdog/Makefile" \
	'qcom-wdt-early-dagu.o' \
	'obj-$(CONFIG_QCOM_WDT) += qcom-wdt-early-dagu.o'

append_once "$KERNEL_SRC/drivers/media/i2c/Makefile" \
	'imx596-dagu.o' \
	'obj-$(CONFIG_VIDEO_IMX596_DAGU) += imx596-dagu.o'

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
marker = "dagu: UART proto invalid, not loading QUPFW"
if marker in text:
    raise SystemExit(0)
old = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\tret = geni_load_se_firmware(&port->se, GENI_SE_UART);
\t\tif (ret) {
\t\t\tdev_err(uport->dev, "UART firmware load failed ret: %d\\n", ret);
\t\t\treturn ret;
\t\t}
\t} else if (proto != GENI_SE_UART) {
"""
new = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\t/* dagu: UART proto invalid, not loading QUPFW on this QHEE */
\t\tdev_err(uport->dev,
\t\t\t"UART proto invalid, not loading QUPFW on this QHEE\\n");
\t\treturn -EOPNOTSUPP;
\t} else if (proto != GENI_SE_UART) {
"""
if old not in text:
    raise SystemExit(f"{path}: UART firmware-load block not found")
path.write_text(text.replace(old, new, 1))
print(f"patched {path}: {marker}")
PY

python3 - "$KERNEL_SRC/drivers/i2c/busses/i2c-qcom-geni.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "dagu: I2C proto invalid, not loading QUPFW"
if marker in text:
    raise SystemExit(0)
old = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\tret = geni_load_se_firmware(&gi2c->se, GENI_SE_I2C);
\t\tif (ret) {
\t\t\tdev_err_probe(dev, ret, "i2c firmware load failed ret: %d\\n", ret);
\t\t\tgoto err_resources;
\t\t}
\t} else if (proto != GENI_SE_I2C) {
"""
new = """\tif (proto == GENI_SE_INVALID_PROTO) {
\t\t/* dagu: I2C proto invalid, not loading QUPFW on this QHEE */
\t\tdev_err_probe(dev, -EOPNOTSUPP,
\t\t\t      "I2C proto invalid, not loading QUPFW on this QHEE\\n");
\t\tret = -EOPNOTSUPP;
\t\tgoto err_resources;
\t} else if (proto != GENI_SE_I2C) {
"""
if old not in text:
    raise SystemExit(f"{path}: I2C firmware-load block not found")
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
path.write_text(text)
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
    raise SystemExit(f"{path}: TDM GROUP helper missing; do not re-extract linux/ without GROUP/V3")
if "gcfg.slot_mask = 0xFF" in text:
    text = text.replace("gcfg.slot_mask = 0xFF;",
                        "gcfg.slot_mask = (1u << gcfg.nslots_per_frame) - 1;", 1)
    text = text.replace("nslots_per_frame ?: 8", "nslots_per_frame ?: 4")
    path.write_text(text)
    print(f"patched {path}: TDM GROUP 4-slot mask")

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

path = root / "drivers/media/i2c/s5kjn1.c"
text = path.read_text()
marker = "dagu s5kjn1 frame counter"
if marker not in text:
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
marker = "dagu: CamX 4080 C-PHY 0x0115=1"
if marker not in text:
    replaced = False
    for old in (
        "	{ CCI_REG16(0x0114), 0x0300 }, /* dagu: s5kjn1 4-lane D-PHY 0x0115=0 */\n",
        "	{ CCI_REG16(0x0114), 0x0301 },\n",
    ):
        if old in text:
            text = text.replace(old, "	{ CCI_REG16(0x0114), 0x0301 }, /* dagu: CamX 4080 C-PHY 0x0115=1 */\n", 1)
            replaced = True
            break
    if not replaced:
        raise SystemExit(f"{path}: 0x0114 C-PHY needle missing")
    path.write_text(text)
    print(f"patched {path}: {marker}")

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
if marker not in text:
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

# Unmask CSI2 RX IRQs so missing/corrupt packets are visible.
path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
marker = "dagu: unmask CSI2 RX IRQs"
if marker not in text:
    old = '''			__csid_configure_rdi_stream(csid, enable, i);
			__csid_configure_rx(csid, &csid->phy, i);
			__csid_ctrl_rdi(csid, enable, i);
'''
    new = '''			__csid_configure_rdi_stream(csid, enable, i);
			__csid_configure_rx(csid, &csid->phy, i);
			__csid_ctrl_rdi(csid, enable, i);
			if (enable) {
				/* dagu: unmask CSI2 RX IRQs */
				writel_relaxed(0xffffffff,
					       csid->base + CSID_CSI2_RX_IRQ_MASK);
				dev_info(csid->camss->dev,
					 "dagu csid phy=%u lanes=%u assign=0x%x\\n",
					 csid->phy.csiphy_id, csid->phy.lane_cnt,
					 csid->phy.lane_assign);
			}
'''
    if old not in text:
        raise SystemExit(f"{path}: csid configure_stream needle missing")
    text = text.replace(old, new, 1)
    old = '''	val = readl_relaxed(csid->base + CSID_CSI2_RX_IRQ_STATUS);
	writel_relaxed(val, csid->base + CSID_CSI2_RX_IRQ_CLEAR);
'''
    new = '''	val = readl_relaxed(csid->base + CSID_CSI2_RX_IRQ_STATUS);
	if (val)
		dev_info_ratelimited(csid->camss->dev,
				     "dagu csid rx irq=0x%x\\n", val);
	writel_relaxed(val, csid->base + CSID_CSI2_RX_IRQ_CLEAR);
'''
    if old not in text:
        raise SystemExit(f"{path}: csid rx irq status needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

path = root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c"
text = path.read_text()
marker = "dagu: log CSI2 RX CFG0"
if marker not in text:
    old = '''				dev_info(csid->camss->dev,
					 "dagu csid phy=%u lanes=%u assign=0x%x\\n",
					 csid->phy.csiphy_id, csid->phy.lane_cnt,
					 csid->phy.lane_assign);
'''
    new = '''				dev_info(csid->camss->dev,
					 "dagu csid phy=%u lanes=%u assign=0x%x cfg0=0x%x\\n",
					 csid->phy.csiphy_id, csid->phy.lane_cnt,
					 csid->phy.lane_assign,
					 readl_relaxed(csid->base + CSID_CSI2_RX_CFG0)); /* dagu: log CSI2 RX CFG0 */
'''
    if old not in text:
        raise SystemExit(f"{path}: csid phy log needle missing")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")

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
if "dagu: omit 0x0bcc" not in text:
    old8 = """	{ CCI_REG16(0x0106), 0x0001 },
	/* 0x0bcc 16-bit NACKs on dagu Qtech JN1 (C-PHY); CamX uses 8-bit. */
	{ CCI_REG8(0x0bcc), 0x00 }, /* dagu: skip 16-bit 0x0bcc NACK */
	{ CCI_REG16(0x6028), 0x2400 },
"""
    old16 = """	{ CCI_REG16(0x0106), 0x0001 },
	{ CCI_REG16(0x0bcc), 0x0000 },
	{ CCI_REG16(0x6028), 0x2400 },
"""
    new = """	{ CCI_REG16(0x0106), 0x0001 },
	/* dagu: omit 0x0bcc — 8/16-bit writes NACK on Qtech JN1 */
	{ CCI_REG16(0x6028), 0x2400 },
"""
    if old8 in text:
        text = text.replace(old8, new, 1)
    elif old16 in text:
        text = text.replace(old16, new, 1)
    else:
        raise SystemExit(f"{path}: 0x0bcc init_array needle missing")
    path.write_text(text)
    print(f"patched {path}: omit 0x0bcc")

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
if "dagu: CCI settle after XSHUTDOWN" not in text:
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
if "dagu: skip 0x6010/0x6226 SW reset" not in text:
    raise SystemExit(f"{path}: skip 0x6010/0x6226 SW reset missing")

path = root / "drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c"
text = path.read_text()
if "lane_regs_sm8250_cphy" not in text or "cphy=%u" not in text:
    raise SystemExit(f"{path}: C-PHY 3PH table / lanes_enable missing (CamX 4080)")
if "if (phy->cphy)" not in (root / "drivers/media/platform/qcom/camss/camss-csid-gen2.c").read_text():
    raise SystemExit("camss-csid-gen2.c: C-PHY PHY_TYPE_SEL missing")
PY
