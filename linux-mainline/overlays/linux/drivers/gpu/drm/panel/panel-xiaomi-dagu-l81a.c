// SPDX-License-Identifier: GPL-2.0-only
/*
 * Xiaomi Pad 5 Pro 12.4 (dagu) L81A dual-DPHY video panel (Himax HX83121A).
 *
 * Init sequence and 800+800 timings from CAF
 * dsi-panel-l81a-42-04-0a-video.dtsi. Dual DSI, 4-lane DPHY.
 * 120 Hz + DSC is the CAF default; 60 Hz is the same porch with E2=0x10.
 *
 * Command TX follows elish nt36523 (mipi_dsi_dual_* helpers). DSC follows
 * CAF dsi_panel_update_pps(): panel-count==2 halves pic_width to 800 for
 * the PPS, sent after ON (0x11/0x29), not before. Do not copy elish
 * NT36523 CPHY / CLOCK_NON_CONTINUOUS onto this Himax panel.
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/gpio/consumer.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_graph.h>
#include <linux/regulator/consumer.h>

#include <drm/display/drm_dsc.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_connector.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>

#include <video/mipi_display.h>

struct l81a_cmd {
	u8 wait_ms;
	u8 len;
	const u8 *data;
};

struct dagu_l81a {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi[2];
	struct gpio_desc *reset_gpio;
	struct gpio_desc *tp_reset_gpio;
	struct gpio_desc *hwen_gpio;
	struct regulator *vddio;
	struct regulator *enp;
	struct regulator *enn;
	struct i2c_client *ktz[2];
	struct drm_dsc_config dsc;
	bool prepared;
	bool dsc_enabled;
	int power_mode_rc;
	u8 power_mode;
};

#define L81A_CMD(_wait, ...) \
	{ .wait_ms = (_wait), .len = sizeof((u8[]){ __VA_ARGS__ }), \
	  .data = (const u8[]){ __VA_ARGS__ } }

#define L81A_HACT		1600
#define L81A_VACT		2560
/*
 * CAF timings are per DSI link (800 + 60/40/60). msm bonded-DSI and DPU
 * split both halve hdisplay/htotal/hsync, so the DRM mode must carry
 * 2× those porches. Using CAF numbers verbatim yields 30/20/30 per
 * link and a black DSC stream.
 */
#define L81A_HFP		120
#define L81A_HSYNC		80
#define L81A_HBP		120
#define L81A_VFP		160
#define L81A_VSYNC		4
#define L81A_VBP		18
#define L81A_HTOTAL		(L81A_HACT + L81A_HFP + L81A_HSYNC + L81A_HBP)
#define L81A_VTOTAL		(L81A_VACT + L81A_VFP + L81A_VSYNC + L81A_VBP)

static const struct l81a_cmd l81a_on_cmds[] = {
	L81A_CMD(0, 0xb9, 0x83, 0x12, 0x1a, 0x55, 0x00),
	L81A_CMD(0, 0xbd, 0x01),
	L81A_CMD(0, 0xe2, 0x46, 0x06, 0x0c, 0xbe, 0x03, 0x3f, 0x0f, 0x57,
		 0x01, 0x45, 0x10, 0x07, 0x18, 0x01, 0x06, 0x00, 0x00, 0x14,
		 0x14, 0x14, 0x14, 0x00, 0x00, 0x00, 0x29, 0x14, 0x14, 0x39,
		 0x4c, 0x1c, 0x00, 0x22, 0xc9, 0x02, 0x02, 0x00, 0x00, 0x93,
		 0x01, 0x0d, 0x49, 0x0e, 0x4a, 0x00, 0x18, 0x45, 0x60, 0x3e,
		 0x00, 0x05, 0x7a, 0x00),
	L81A_CMD(0, 0xbd, 0x00),
	L81A_CMD(0, 0xd1, 0x37),
	L81A_CMD(0, 0xbf, 0xfd, 0x00, 0x80, 0x9c, 0x10, 0x00, 0x80),
	L81A_CMD(0, 0xba, 0x70, 0x03, 0xa8, 0x92, 0x01, 0x10, 0x00, 0x00,
		 0x08, 0x3d, 0x02, 0x77, 0x84),
	L81A_CMD(0, 0xd9, 0x0c, 0x0c),
	/*
	 * CAF XML has "03 02 BD 00" (DCS 0x02). Bank is already BD=0 from
	 * the line above. Sending 0x02 before B2 left Himax without DSC
	 * enable; HyperOS's GCDB parser may not emit this as DCS 0x02.
	 */
	L81A_CMD(0, 0xbd, 0x00),
	/* 3rd byte 0x40 is CAF DSC enable. Himax stays black without it. */
	L81A_CMD(0, 0xb2, 0x00, 0x6a, 0x40, 0x00, 0x00, 0x14, 0x9e, 0x60,
		 0x3c, 0x02, 0x80, 0x21, 0x21, 0x00, 0x00, 0x10, 0x27),
	L81A_CMD(0, 0xb9, 0x83, 0x12, 0x1a, 0x55, 0x00),
	L81A_CMD(0, 0xbd, 0x03),
	L81A_CMD(0, 0xe4, 0x99, 0x99, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee,
		 0xff, 0xff, 0xff, 0x03, 0x99, 0x99, 0x99, 0xff, 0x66, 0x4a,
		 0x99, 0xc6, 0xff, 0x55, 0xfe, 0x03, 0xad, 0xad, 0xad, 0xe5,
		 0x1e, 0x57, 0x8f, 0xc8, 0xff, 0xaa, 0xff, 0x03),
	L81A_CMD(0, 0xbd, 0x01),
	L81A_CMD(0, 0xe4, 0xe1, 0xe1, 0xe1, 0xe1, 0xe1, 0xe1, 0xe1, 0xe1,
		 0xc7, 0xb2, 0xa0, 0x90, 0x81, 0x75, 0x69, 0x5f, 0x55, 0x4c,
		 0x44, 0x3d, 0x36, 0x2f, 0x2a, 0x24, 0x1e, 0x19, 0x14, 0x10,
		 0x0d, 0x0c, 0x0a, 0x54, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
		 0x55),
	L81A_CMD(0, 0xbd, 0x00),
	L81A_CMD(0, 0xb9, 0x00, 0x00, 0x00, 0x00, 0x00),
	L81A_CMD(0, 0x35, 0x00),
	L81A_CMD(0, 0x51, 0x0f, 0xff),
	L81A_CMD(0, 0x53, 0x24),
};

/* CAF dispparam-pen-120hz / 60hz: unlock, E2, lock */
static const struct l81a_cmd l81a_fps_120[] = {
	L81A_CMD(0, 0xb9, 0x83, 0x12, 0x1a, 0x55, 0x00),
	L81A_CMD(0, 0xbd, 0x00),
	L81A_CMD(0, 0xe2, 0x00),
	L81A_CMD(0, 0xd1, 0x37),
	L81A_CMD(0, 0xb9, 0x00, 0x00, 0x00, 0x00, 0x00),
};

static const struct l81a_cmd l81a_fps_60[] = {
	L81A_CMD(0, 0xb9, 0x83, 0x12, 0x1a, 0x55, 0x00),
	L81A_CMD(0, 0xbd, 0x00),
	L81A_CMD(0, 0xe2, 0x10),
	L81A_CMD(0, 0xd1, 0x37),
	L81A_CMD(0, 0xb9, 0x00, 0x00, 0x00, 0x00, 0x00),
};

static inline struct dagu_l81a *to_dagu_l81a(struct drm_panel *panel)
{
	return container_of(panel, struct dagu_l81a, panel);
}

static int l81a_set_fps(struct dagu_l81a *ctx, unsigned int fps);

static int l81a_tx(struct dagu_l81a *ctx, const struct l81a_cmd *cmd)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = NULL };

	/* Same helper elish nt36523 uses: LPM flag → MIPI_DSI_MSG_USE_LPM. */
	mipi_dsi_dual_dcs_write_buffer_multi(&dsi_ctx, ctx->dsi[0], ctx->dsi[1],
					     cmd->data, cmd->len);
	if (cmd->wait_ms)
		mipi_dsi_msleep(&dsi_ctx, cmd->wait_ms);
	return dsi_ctx.accum_err;
}

static int l81a_tx_table(struct dagu_l81a *ctx, const struct l81a_cmd *cmds,
			 unsigned int n)
{
	unsigned int i;
	int ret;

	for (i = 0; i < n; i++) {
		ret = l81a_tx(ctx, &cmds[i]);
		if (ret)
			return ret;
	}
	return 0;
}

static void l81a_hwen_on(struct dagu_l81a *ctx)
{
	/*
	 * Dual KTZ share GPIO 139. I2C is off on this QHEE, so ABL's
	 * programming is the only brightness source. Dropping HWEN
	 * resets the chips and the panel stays black until the next
	 * ABL boot. Keep it high for the whole session.
	 */
	if (ctx->hwen_gpio)
		gpiod_set_value_cansleep(ctx->hwen_gpio, 1);
}

int ktz8866_set_brightness(struct i2c_client *client, unsigned int brightness);

static int l81a_backlight_update(struct backlight_device *bl)
{
	struct dagu_l81a *ctx = bl_get_data(bl);
	int brightness = backlight_get_brightness(bl);
	unsigned int hw;

	/*
	 * Quadratic map: GNOME's linear 0–2047 still looks bright at
	 * 10–20%. Square so the bottom of the slider is actually dim.
	 */
	hw = (unsigned int)(((u64)brightness * (u64)brightness) / 2047);
	if (hw < 32)
		hw = 32;
	ktz8866_set_brightness(ctx->ktz[0], hw);
	ktz8866_set_brightness(ctx->ktz[1], hw);
	return 0;
}

static const struct backlight_ops l81a_backlight_ops = {
	.update_status = l81a_backlight_update,
};

static void l81a_reset(struct dagu_l81a *ctx)
{
	/* CAF: <0 55>, <1 55>, <0 55>, <1 55> with GPIO_ACTIVE_LOW */
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	msleep(55);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	msleep(55);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	msleep(55);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	msleep(55);
}

static int l81a_dsc_compute(struct drm_dsc_config *dsc, u16 pic_width)
{
	int ret;

	dsc->pic_width = pic_width;
	dsc->pic_height = L81A_VACT;
	dsc->simple_422 = 0;
	dsc->convert_rgb = 1;
	dsc->vbr_enable = 0;
	drm_dsc_set_const_params(dsc);
	drm_dsc_set_rc_buf_thresh(dsc);
	ret = drm_dsc_setup_rc_params(dsc, DRM_DSC_1_1_PRE_SCR);
	if (ret)
		return ret;
	dsc->initial_scale_value = drm_dsc_initial_scale_value(dsc);
	dsc->line_buf_depth = dsc->bits_per_component + 1;
	return drm_dsc_compute_rc_parameters(dsc);
}

static int l81a_dsc_enable(struct dagu_l81a *ctx)
{
	struct drm_dsc_config *dsc = &ctx->dsc;
	struct drm_dsc_picture_parameter_set pps;
	int i, ret;

	if (!ctx->dsc_enabled)
		return 0;

	/*
	 * CAF dsi_panel_update_pps(): qcom,mdss-dsi-panel-count==2 does
	 * pic_width >>= 1 before packing. Each DSI link is 800 px / 1 slice.
	 * DPU still needs the full 1600 picture (2 INTF + 2 DSC).
	 *
	 * CAF DSI_CMD_SET_PPS is DSI_CMD_SET_STATE_LP. Do not drop MODE_LPM:
	 * mipi_dsi_device_transfer copies it to MSG_USE_LPM. Himax DSC is
	 * already armed by B2; CAF never sends MIPI_DSI_COMPRESSION_MODE.
	 */
	ret = l81a_dsc_compute(dsc, L81A_HACT / 2);
	if (ret)
		return ret;
	drm_dsc_pps_payload_pack(&pps, dsc);
	ret = l81a_dsc_compute(dsc, L81A_HACT);
	if (ret)
		return ret;

	for (i = 0; i < 2; i++) {
		ret = mipi_dsi_picture_parameter_set(ctx->dsi[i], &pps);
		if (ret)
			return ret;
	}
	return 0;
}

static int l81a_enable_one(struct regulator *reg, const char *name,
			   struct device *dev)
{
	int ret;

	if (!reg)
		return 0;
	ret = regulator_enable(reg);
	if (ret)
		dev_err(dev, "enable %s: %d\n", name, ret);
	else
		/* CAF dsi_panel_pwr_supply_l81a post-on-sleep is 10 ms. */
		msleep(10);
	return ret;
}

static void l81a_disable_one(struct regulator *reg)
{
	if (reg)
		regulator_disable(reg);
}

static int l81a_prepare(struct drm_panel *panel)
{
	struct dagu_l81a *ctx = to_dagu_l81a(panel);
	struct device *dev = panel->dev;
	int ret;

	if (ctx->prepared)
		return 0;

	/* CAF supply order: vddio, enp, enn. TDDI then raises TP RST. */
	ret = l81a_enable_one(ctx->vddio, "vddio", dev);
	if (ret)
		return ret;
	ret = l81a_enable_one(ctx->enp, "enp", dev);
	if (ret)
		goto err_vddio;
	ret = l81a_enable_one(ctx->enn, "enn", dev);
	if (ret)
		goto err_enp;

	/*
	 * CAF dsi_panel_power_on() for panel_id 0x4C38314100420400:
	 * gpio_direction_output(tp_reset_gpio, 1) before LCD reset.
	 * GPIO 100 is the same Himax rst-gpio; leaving it floating keeps
	 * the TDDI in reset → backlight (KTZ) on, pixels black.
	 */
	if (ctx->tp_reset_gpio)
		gpiod_set_value_cansleep(ctx->tp_reset_gpio, 1);

	l81a_reset(ctx);

	ret = l81a_tx_table(ctx, l81a_on_cmds, ARRAY_SIZE(l81a_on_cmds));
	if (ret) {
		dev_err(dev, "L81A init failed: %d\n", ret);
		goto err_enn;
	}

	/* CAF / HyperOS default: E2=0x00 120 Hz. Pixel clock alone does not DFPS. */
	ret = l81a_set_fps(ctx, 120);
	if (ret)
		dev_warn(dev, "L81A 120 Hz E2 failed: %d\n", ret);

	/*
	 * elish nt36523: 0x11/0x29 via dual helpers in prepare.
	 * CAF on-command waits 120 ms then 20 ms (not elish 70/0).
	 */
	{
		struct mipi_dsi_multi_context dsi_ctx = { .dsi = NULL };

		mipi_dsi_dual_dcs_write_seq_multi(&dsi_ctx, ctx->dsi[0],
						  ctx->dsi[1], 0x11);
		mipi_dsi_msleep(&dsi_ctx, 120);
		mipi_dsi_dual_dcs_write_seq_multi(&dsi_ctx, ctx->dsi[0],
						  ctx->dsi[1], 0x29);
		mipi_dsi_msleep(&dsi_ctx, 20);
		ret = dsi_ctx.accum_err;
		if (ret) {
			dev_err(dev, "L81A sleep-out failed: %d\n", ret);
			goto err_enn;
		}
	}

	/*
	 * Read DCS 0x0A after 0x11/0x29, still in LP11, before PPS/video.
	 * Sync-dual-dsi skips DSI_0 writes but not reads — try both hosts.
	 */
	ctx->power_mode = 0;
	ctx->power_mode_rc = mipi_dsi_dcs_get_power_mode(ctx->dsi[0],
							 &ctx->power_mode);
	if (ctx->power_mode_rc < 0 && ctx->dsi[1])
		ctx->power_mode_rc = mipi_dsi_dcs_get_power_mode(ctx->dsi[1],
								 &ctx->power_mode);

	/* CAF: dsi_panel_enable (ON) then dsi_panel_update_pps, then video. */
	ret = l81a_dsc_enable(ctx);
	if (ret) {
		dev_err(dev, "L81A DSC PPS: %d\n", ret);
		goto err_enn;
	}

	ctx->prepared = true;
	return 0;

err_enn:
	if (ctx->tp_reset_gpio)
		gpiod_set_value_cansleep(ctx->tp_reset_gpio, 0);
	l81a_disable_one(ctx->enn);
err_enp:
	l81a_disable_one(ctx->enp);
err_vddio:
	l81a_disable_one(ctx->vddio);
	return ret;
}

static int l81a_set_fps(struct dagu_l81a *ctx, unsigned int fps)
{
	if (fps <= 60)
		return l81a_tx_table(ctx, l81a_fps_60, ARRAY_SIZE(l81a_fps_60));
	return l81a_tx_table(ctx, l81a_fps_120, ARRAY_SIZE(l81a_fps_120));
}

static int l81a_enable(struct drm_panel *panel)
{
	struct dagu_l81a *ctx = to_dagu_l81a(panel);

	/* First prepare() already sent 0x11/0x29. Do not replay 0x51/0x29
	 * on every Mutter DPMS — those DMA waits are ~400 ms and lose
	 * the video link.
	 */
	l81a_hwen_on(ctx);
	return 0;
}

static int l81a_disable(struct drm_panel *panel)
{
	/*
	 * Leave the Himax programmed. DCS 0x28/0x10 and 0x51=0 both
	 * ETIMEDOUT on this video-mode link; a later unblank cannot
	 * replay B9 init (-EINVAL/-ETIMEDOUT) so the tablet stays dark.
	 * Userspace dims with l81a-wled → dual KTZ I2C (i2c-gpio).
	 */
	(void)panel;
	return 0;
}

static int l81a_unprepare(struct drm_panel *panel)
{
	/*
	 * ABL + the first prepare() are the only working init. Mutter
	 * DPMS / a modeset will call this, then prepare() again. Reset
	 * + dropping ENP/ENN/VDDIO kills PWM into the KTZ, and B9
	 * cannot be replayed. Keep supplies and ctx->prepared so the
	 * next prepare() is a no-op and video resumes with the PHY.
	 */
	(void)panel;
	return 0;
}

/* Full 1600 mode; H porches are 2× CAF per-link so split restores 60/40/60. */
static const struct drm_display_mode l81a_mode_120 = {
	.clock = L81A_HTOTAL * L81A_VTOTAL * 120 / 1000,
	.hdisplay = L81A_HACT,
	.hsync_start = L81A_HACT + L81A_HFP,
	.hsync_end = L81A_HACT + L81A_HFP + L81A_HSYNC,
	.htotal = L81A_HTOTAL,
	.vdisplay = L81A_VACT,
	.vsync_start = L81A_VACT + L81A_VFP,
	.vsync_end = L81A_VACT + L81A_VFP + L81A_VSYNC,
	.vtotal = L81A_VTOTAL,
	.width_mm = 166,
	.height_mm = 266,
	.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
};

static const struct drm_display_mode l81a_mode_60 __maybe_unused = {
	.clock = L81A_HTOTAL * L81A_VTOTAL * 60 / 1000,
	.hdisplay = L81A_HACT,
	.hsync_start = L81A_HACT + L81A_HFP,
	.hsync_end = L81A_HACT + L81A_HFP + L81A_HSYNC,
	.htotal = L81A_HTOTAL,
	.vdisplay = L81A_VACT,
	.vsync_start = L81A_VACT + L81A_VFP,
	.vsync_end = L81A_VACT + L81A_VFP + L81A_VSYNC,
	.vtotal = L81A_VTOTAL,
	.width_mm = 166,
	.height_mm = 266,
	.type = DRM_MODE_TYPE_DRIVER,
};

static int l81a_get_modes(struct drm_panel *panel,
			  struct drm_connector *connector)
{
	struct drm_display_mode *mode;

	/*
	 * HyperOS defaultPeak is 120 Hz; 60 Hz is DFPS only. Forcing a 60 Hz
	 * DRM mode (halved pixel clock + E2=0x10) made dual-DSI flicker.
	 */
	mode = drm_mode_duplicate(connector->dev, &l81a_mode_120);
	if (!mode)
		return -ENOMEM;
	drm_mode_set_name(mode);
	drm_mode_probed_add(connector, mode);

	connector->display_info.width_mm = l81a_mode_120.width_mm;
	connector->display_info.height_mm = l81a_mode_120.height_mm;
	connector->display_info.bpc = 8;
	return 1;
}

static const struct drm_panel_funcs l81a_funcs = {
	.prepare = l81a_prepare,
	.enable = l81a_enable,
	.disable = l81a_disable,
	.unprepare = l81a_unprepare,
	.get_modes = l81a_get_modes,
};

static void l81a_init_dsc(struct dagu_l81a *ctx)
{
	struct drm_dsc_config *dsc = &ctx->dsc;

	/*
	 * CAF: dsc 1.1, slice 800x20, slice-per-pkt 1, 8bpc/8bpp.
	 * Dual-DSI bonded: each INTF / DSC encoder is 800 px, so
	 * slice_count is 1 per interface (msm dsi_update_dsc_timing
	 * treats slice_count as slice_per_intf). PPS pic_width is 800;
	 * DPU pic_width is restored to 1600 in l81a_dsc_enable().
	 */
	dsc->dsc_version_major = 1;
	dsc->dsc_version_minor = 1;
	dsc->slice_height = 20;
	dsc->slice_width = 800;
	dsc->slice_count = 1;
	dsc->bits_per_component = 8;
	dsc->bits_per_pixel = 8 << 4;
	dsc->block_pred_enable = true;
	ctx->dsc_enabled = true;
}

static int l81a_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct dagu_l81a *ctx;
	struct device_node *dsi1_node;
	struct device_node *bl_np;
	struct mipi_dsi_host *dsi1_host;
	struct mipi_dsi_device_info info = {
		.type = "L81A",
		.channel = 0,
		.node = NULL,
	};
	int ret, i;

	ctx = devm_kzalloc(dev, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;

	ctx->vddio = devm_regulator_get(dev, "vddio");
	if (IS_ERR(ctx->vddio))
		return dev_err_probe(dev, PTR_ERR(ctx->vddio), "vddio\n");
	ctx->enp = devm_regulator_get(dev, "enp");
	if (IS_ERR(ctx->enp))
		return dev_err_probe(dev, PTR_ERR(ctx->enp), "enp\n");
	ctx->enn = devm_regulator_get(dev, "enn");
	if (IS_ERR(ctx->enn))
		return dev_err_probe(dev, PTR_ERR(ctx->enn), "enn\n");

	/* Logical 0 = deasserted (ACTIVE_LOW pin high). Do not hold reset. */
	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio), "reset GPIO\n");

	/* CAF gpio_direction_output(tp_reset, 1) at panel power_on. */
	ctx->tp_reset_gpio = devm_gpiod_get_optional(dev, "tp-reset",
						     GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->tp_reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->tp_reset_gpio),
				     "tp-reset GPIO\n");

	/* Dual KTZ HWEN (TLMM 139). ABL leaves it high; keep it high so
	 * attach/enable is not racing a forced-off WLED.
	 */
	ctx->hwen_gpio = devm_gpiod_get_optional(dev, "hwen", GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->hwen_gpio)) {
		dev_warn(dev, "hwen GPIO %ld\n", PTR_ERR(ctx->hwen_gpio));
		ctx->hwen_gpio = NULL;
	}

	dsi1_node = of_graph_get_remote_node(dev->of_node, 1, -1);
	if (!dsi1_node)
		return dev_err_probe(dev, -ENODEV, "no secondary DSI node\n");
	dsi1_host = of_find_mipi_dsi_host_by_node(dsi1_node);
	of_node_put(dsi1_node);
	if (!dsi1_host)
		return dev_err_probe(dev, -EPROBE_DEFER, "secondary DSI host\n");

	ctx->dsi[1] = devm_mipi_dsi_device_register_full(dev, dsi1_host, &info);
	if (IS_ERR(ctx->dsi[1]))
		return PTR_ERR(ctx->dsi[1]);

	ctx->dsi[0] = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	l81a_init_dsc(ctx);

	drm_panel_init(&ctx->panel, dev, &l81a_funcs, DRM_MODE_CONNECTOR_DSI);
	ctx->panel.prepare_prev_first = true;

	for (i = 0; i < 2; i++) {
		const char *prop = i ? "backlight-aux" : "backlight";

		bl_np = of_parse_phandle(dev->of_node, prop, 0);
		if (!bl_np)
			continue;
		ctx->ktz[i] = of_find_i2c_device_by_node(bl_np);
		of_node_put(bl_np);
		if (!ctx->ktz[i]) {
			int j;

			for (j = 0; j < i; j++) {
				if (ctx->ktz[j])
					put_device(&ctx->ktz[j]->dev);
				ctx->ktz[j] = NULL;
			}
			return -EPROBE_DEFER;
		}
	}

	if (!ctx->panel.backlight) {
		const struct backlight_properties props = {
			.type = BACKLIGHT_RAW,
			.max_brightness = 2047,
			.brightness = 400,
			.power = BACKLIGHT_POWER_ON,
		};

		ctx->panel.backlight = devm_backlight_device_register(
			dev, "l81a-wled", dev, ctx, &l81a_backlight_ops, &props);
		if (IS_ERR(ctx->panel.backlight)) {
			dev_warn(dev, "l81a-wled register %ld\n",
				 PTR_ERR(ctx->panel.backlight));
			ctx->panel.backlight = NULL;
		} else {
			backlight_update_status(ctx->panel.backlight);
		}
	}

	dev_info(dev, "L81A probe hwen=%d ktz=%d aux=%d bl=%d\n",
		 ctx->hwen_gpio ? 1 : 0, ctx->ktz[0] ? 1 : 0,
		 ctx->ktz[1] ? 1 : 0,
		 ctx->panel.backlight ? 1 : 0);

	drm_panel_add(&ctx->panel);

	for (i = 0; i < 2; i++) {
		ctx->dsi[i]->lanes = 4;
		ctx->dsi[i]->format = MIPI_DSI_FMT_RGB888;
		if (ctx->dsc_enabled)
			ctx->dsi[i]->dsc = &ctx->dsc;
		/* CAF: non_burst_sync_event + bllp HS clock, not elish NON_CONTINUOUS. */
		ctx->dsi[i]->mode_flags = MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_LPM;
		ret = devm_mipi_dsi_attach(dev, ctx->dsi[i]);
		if (ret)
			return dev_err_probe(dev, ret, "attach DSI%d\n", i);
	}

	return 0;
}

static void l81a_remove(struct mipi_dsi_device *dsi)
{
	struct dagu_l81a *ctx = mipi_dsi_get_drvdata(dsi);

	if (ctx->ktz[0])
		put_device(&ctx->ktz[0]->dev);
	if (ctx->ktz[1])
		put_device(&ctx->ktz[1]->dev);
	drm_panel_remove(&ctx->panel);
}

static const struct of_device_id l81a_of_match[] = {
	{ .compatible = "xiaomi,dagu-l81a" },
	{ }
};
MODULE_DEVICE_TABLE(of, l81a_of_match);

static struct mipi_dsi_driver l81a_driver = {
	.probe = l81a_probe,
	.remove = l81a_remove,
	.driver = {
		.name = "panel-xiaomi-dagu-l81a",
		.of_match_table = l81a_of_match,
	},
};
module_mipi_dsi_driver(l81a_driver);

MODULE_AUTHOR("dagu mainline bring-up");
MODULE_DESCRIPTION("Xiaomi Pad 5 Pro 12.4 L81A dual-DPHY panel");
MODULE_LICENSE("GPL");
