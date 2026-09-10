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
install_src drivers/watchdog/qcom-wdt-early-dagu.c
install_src drivers/gpu/drm/msm/msm_fbdev.c

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
