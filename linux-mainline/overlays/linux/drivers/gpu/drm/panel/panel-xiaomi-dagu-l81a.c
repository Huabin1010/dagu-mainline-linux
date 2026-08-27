// SPDX-License-Identifier: GPL-2.0-only
/*
 * Xiaomi Pad 5 Pro 12.4 (dagu) L81A dual-DPHY video panel (Himax HX83121A).
 *
 * Init sequence and 800+800 timings from CAF
 * dsi-panel-l81a-42-04-0a-video.dtsi. Dual DSI, 4-lane DPHY.
 * 120 Hz + DSC is the CAF default; 60 Hz is the same porch with E2=0x10.
 * Do not use the elish NT36523 CPHY sequence on this panel.
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
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
	struct regulator *vddio;
	struct backlight_device *backlight_aux;
	struct drm_dsc_config dsc;
	bool prepared;
	bool dsc_enabled;
};

#define L81A_CMD(_wait, ...) \
	{ .wait_ms = (_wait), .len = sizeof((u8[]){ __VA_ARGS__ }), \
	  .data = (const u8[]){ __VA_ARGS__ } }

#define L81A_HACT		1600
#define L81A_VACT		2560
#define L81A_HFP		60
#define L81A_HSYNC		40
#define L81A_HBP		60
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

static int l81a_tx_one(struct mipi_dsi_device *dsi, const struct l81a_cmd *cmd)
{
	const struct mipi_dsi_host_ops *ops;
	struct mipi_dsi_msg msg = {
		.channel = dsi->channel,
		.type = MIPI_DSI_DCS_LONG_WRITE,
		.tx_buf = cmd->data,
		.tx_len = cmd->len,
	};
	ssize_t ret;

	if (cmd->len == 1)
		msg.type = MIPI_DSI_DCS_SHORT_WRITE;
	else if (cmd->len == 2)
		msg.type = MIPI_DSI_DCS_SHORT_WRITE_PARAM;

	ops = dsi->host->ops;
	if (!ops || !ops->transfer)
		return -ENOSYS;
	ret = ops->transfer(dsi->host, &msg);
	return ret < 0 ? ret : 0;
}

static int l81a_tx(struct dagu_l81a *ctx, const struct l81a_cmd *cmd)
{
	int ret, i;

	for (i = 0; i < 2; i++) {
		if (!ctx->dsi[i])
			continue;
		ret = l81a_tx_one(ctx->dsi[i], cmd);
		if (ret)
			return ret;
	}
	if (cmd->wait_ms)
		msleep(cmd->wait_ms);
	return 0;
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

static void l81a_sync_aux_bl(struct dagu_l81a *ctx)
{
	struct backlight_device *pri = ctx->panel.backlight;

	if (!ctx->backlight_aux || !pri)
		return;

	ctx->backlight_aux->props.brightness = pri->props.brightness;
	ctx->backlight_aux->props.power = pri->props.power;
	ctx->backlight_aux->props.state = pri->props.state;
	backlight_update_status(ctx->backlight_aux);
}

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

static int l81a_dsc_enable(struct dagu_l81a *ctx)
{
	struct drm_dsc_picture_parameter_set pps;
	int i, ret;

	if (!ctx->dsc_enabled)
		return 0;

	drm_dsc_pps_payload_pack(&pps, &ctx->dsc);

	for (i = 0; i < 2; i++) {
		if (!ctx->dsi[i])
			continue;
		ret = mipi_dsi_picture_parameter_set(ctx->dsi[i], &pps);
		if (ret)
			return ret;
		ret = mipi_dsi_compression_mode(ctx->dsi[i], true);
		if (ret)
			return ret;
	}
	return 0;
}

static int l81a_prepare(struct drm_panel *panel)
{
	struct dagu_l81a *ctx = to_dagu_l81a(panel);
	int ret;

	if (ctx->prepared)
		return 0;

	if (ctx->vddio) {
		ret = regulator_enable(ctx->vddio);
		if (ret)
			return ret;
	}

	l81a_reset(ctx);

	ret = l81a_tx_table(ctx, l81a_on_cmds, ARRAY_SIZE(l81a_on_cmds));
	if (ret) {
		dev_err(panel->dev, "L81A init failed: %d\n", ret);
		if (ctx->vddio)
			regulator_disable(ctx->vddio);
		return ret;
	}

	ctx->prepared = true;
	return 0;
}

static const struct l81a_cmd l81a_enable_cmds[] = {
	L81A_CMD(120, 0x11),
	L81A_CMD(20, 0x29),
};

static const struct l81a_cmd l81a_off_cmds[] = {
	L81A_CMD(0, 0x28),
	L81A_CMD(70, 0x10),
};

static int l81a_set_fps(struct dagu_l81a *ctx, unsigned int fps)
{
	if (fps <= 60)
		return l81a_tx_table(ctx, l81a_fps_60, ARRAY_SIZE(l81a_fps_60));
	return l81a_tx_table(ctx, l81a_fps_120, ARRAY_SIZE(l81a_fps_120));
}

static int l81a_enable(struct drm_panel *panel)
{
	struct dagu_l81a *ctx = to_dagu_l81a(panel);
	int ret;

	/* CAF default timing@0 is 120 Hz. 60 Hz is DFPS via E2=0x10. */
	ret = l81a_set_fps(ctx, 120);
	if (ret)
		return ret;

	ret = l81a_tx_table(ctx, l81a_enable_cmds, ARRAY_SIZE(l81a_enable_cmds));
	if (ret)
		return ret;

	ret = l81a_dsc_enable(ctx);
	if (ret)
		dev_warn(panel->dev, "DSC enable failed: %d (60 Hz uncompressed still possible)\n",
			 ret);

	l81a_sync_aux_bl(ctx);
	return 0;
}

static int l81a_disable(struct drm_panel *panel)
{
	struct dagu_l81a *ctx = to_dagu_l81a(panel);

	l81a_tx_table(ctx, l81a_off_cmds, ARRAY_SIZE(l81a_off_cmds));
	return 0;
}

static int l81a_unprepare(struct drm_panel *panel)
{
	struct dagu_l81a *ctx = to_dagu_l81a(panel);

	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	if (ctx->vddio)
		regulator_disable(ctx->vddio);
	ctx->prepared = false;
	return 0;
}

/* Same porches as CAF; do not double them when merging dual-DSI 800+800. */
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

static const struct drm_display_mode l81a_mode_60 = {
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
	static const struct drm_display_mode *modes[] = {
		&l81a_mode_120,
		&l81a_mode_60,
	};
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(modes); i++) {
		struct drm_display_mode *mode;

		mode = drm_mode_duplicate(connector->dev, modes[i]);
		if (!mode)
			return -ENOMEM;
		drm_mode_set_name(mode);
		drm_mode_probed_add(connector, mode);
	}

	connector->display_info.width_mm = l81a_mode_120.width_mm;
	connector->display_info.height_mm = l81a_mode_120.height_mm;
	connector->display_info.bpc = 8;
	return ARRAY_SIZE(modes);
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

	/* CAF: dsc 1.1, slice 800x20, 8bpc/8bpp, block prediction. */
	dsc->dsc_version_major = 1;
	dsc->dsc_version_minor = 1;
	dsc->slice_height = 20;
	dsc->slice_width = 800;
	dsc->slice_count = 2;
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

	ctx->vddio = devm_regulator_get_optional(dev, "vddio");
	if (IS_ERR(ctx->vddio)) {
		if (PTR_ERR(ctx->vddio) != -ENODEV)
			return PTR_ERR(ctx->vddio);
		ctx->vddio = NULL;
	}

	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio), "reset GPIO\n");

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
	ret = drm_panel_of_backlight(&ctx->panel);
	if (ret)
		return ret;

	bl_np = of_parse_phandle(dev->of_node, "backlight-aux", 0);
	if (bl_np) {
		ctx->backlight_aux = of_find_backlight_by_node(bl_np);
		of_node_put(bl_np);
		if (!ctx->backlight_aux)
			return -EPROBE_DEFER;
	}

	drm_panel_add(&ctx->panel);

	for (i = 0; i < 2; i++) {
		ctx->dsi[i]->lanes = 4;
		ctx->dsi[i]->format = MIPI_DSI_FMT_RGB888;
		ctx->dsi[i]->dsc = &ctx->dsc;
		/* CAF: non_burst_sync_event, 4-lane DPHY */
		ctx->dsi[i]->mode_flags = MIPI_DSI_MODE_VIDEO |
					  MIPI_DSI_MODE_LPM;
		ret = devm_mipi_dsi_attach(dev, ctx->dsi[i]);
		if (ret)
			return dev_err_probe(dev, ret, "attach DSI%d\n", i);
	}

	return 0;
}

static void l81a_remove(struct mipi_dsi_device *dsi)
{
	struct dagu_l81a *ctx = mipi_dsi_get_drvdata(dsi);

	if (ctx->backlight_aux)
		put_device(&ctx->backlight_aux->dev);
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
