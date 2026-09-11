// SPDX-License-Identifier: GPL-2.0-only
/*
 * Sony IMX596 front camera for Xiaomi Pad 5 Pro 12.4 (dagu).
 *
 * CAF dagu-sm8250-camera-sensor-mtp.dtsi qcom,cam-sensor@2:
 *   csiphy4, CCI1 master1 @0x1a, reset GPIO109, MCLK GPIO97 / CAM_CC_MCLK3,
 *   AVDD GPIO84 2.8 V, VIO pm8150 1.8 V, VDIG ~1.15 V.
 *
 * Mainline has no IMX596 driver. Preview size / CFA from stock CamX HAL:
 * 2592x1952 BGGR 10-bit, MCLK 19.2 MHz. Stream-on writes EXCK + window +
 * MODE_SELECT; full init table is still in the CamX .bin (object-id packed).
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <linux/string.h>
#include <linux/unaligned.h>
#include <linux/units.h>

#include <media/v4l2-cci.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-fwnode.h>

#define IMX596_REG_CHIP_ID		CCI_REG16(0x0016)
#define IMX596_CHIP_ID			0x0596

#define IMX596_REG_MODE_SELECT		CCI_REG8(0x0100)
#define IMX596_MODE_STANDBY		0x00
#define IMX596_MODE_STREAMING		0x01

#define IMX596_MCLK_FREQ		(19200 * HZ_PER_KHZ)
#define IMX596_LINK_FREQ		(600ULL * HZ_PER_MHZ)
#define IMX596_WIDTH			2592
#define IMX596_HEIGHT			1952
#define IMX596_MBUS_CODE		MEDIA_BUS_FMT_SBGGR10_1X10

#define to_imx596(_sd)			container_of(_sd, struct imx596, sd)

static const char * const imx596_supply_names[] = {
	"vddio",
	"vdda",
	"vddd",
};

static const s64 imx596_link_freq_menu[] = {
	IMX596_LINK_FREQ,
};

struct imx596 {
	struct device *dev;
	struct i2c_client *client;
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct v4l2_ctrl_handler ctrl_handler;
	struct clk *mclk;
	struct gpio_desc *reset_gpio;
	struct regulator_bulk_data supplies[ARRAY_SIZE(imx596_supply_names)];
	struct regmap *regmap;
	struct mutex mutex;
};

static int imx596_enable_supply(struct imx596 *priv, const char *name)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(priv->supplies); i++) {
		if (!strcmp(priv->supplies[i].supply, name))
			return regulator_enable(priv->supplies[i].consumer);
	}

	return -ENODEV;
}

static void imx596_disable_supply(struct imx596 *priv, const char *name)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(priv->supplies); i++) {
		if (!strcmp(priv->supplies[i].supply, name)) {
			regulator_disable(priv->supplies[i].consumer);
			return;
		}
	}
}

static int imx596_power_on(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct imx596 *priv = to_imx596(sd);
	int ret;

	/* CAF regulator-names: cam_vio, cam_vana, cam_vdig. XCLR after MCLK. */
	ret = imx596_enable_supply(priv, "vddio");
	if (ret)
		return ret;
	usleep_range(1000, 2000);

	ret = imx596_enable_supply(priv, "vddd");
	if (ret)
		goto disable_vddio;
	usleep_range(1000, 2000);

	ret = imx596_enable_supply(priv, "vdda");
	if (ret)
		goto disable_vddd;
	usleep_range(1000, 2000);

	ret = clk_prepare_enable(priv->mclk);
	if (ret)
		goto disable_vdda;

	usleep_range(1000, 2000);
	/* CAF: reset low then high with MCLK running. GPIO is active-low. */
	gpiod_set_value_cansleep(priv->reset_gpio, 1);
	usleep_range(2000, 3000);
	gpiod_set_value_cansleep(priv->reset_gpio, 0);
	usleep_range(50 * USEC_PER_MSEC, 55 * USEC_PER_MSEC);
	return 0;

disable_vdda:
	imx596_disable_supply(priv, "vdda");
disable_vddd:
	imx596_disable_supply(priv, "vddd");
disable_vddio:
	imx596_disable_supply(priv, "vddio");
	return ret;
}

static int imx596_power_off(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct imx596 *priv = to_imx596(sd);

	gpiod_set_value_cansleep(priv->reset_gpio, 1);
	clk_disable_unprepare(priv->mclk);
	regulator_bulk_disable(ARRAY_SIZE(priv->supplies), priv->supplies);
	return 0;
}

static int imx596_identify(struct imx596 *priv)
{
	static const u16 addrs[] = { 0x1a, 0x10, 0x1b, 0x20, 0x36 };
	u16 orig = priv->client->addr;
	u64 chip_id;
	unsigned int i;
	int ret = -ENXIO;

	for (i = 0; i < ARRAY_SIZE(addrs); i++) {
		priv->client->addr = addrs[i];
		ret = cci_read(priv->regmap, IMX596_REG_CHIP_ID, &chip_id, NULL);
		if (ret) {
			dev_info(priv->dev, "CCI NACK at 0x%02x (%d)\n",
				 addrs[i], ret);
			continue;
		}

		dev_info(priv->dev, "chip id 0x%04llx at 0x%02x\n",
			 chip_id, addrs[i]);
		if (chip_id == IMX596_CHIP_ID)
			return 0;

		dev_warn(priv->dev, "unexpected chip id 0x%04llx (want 0x%04x)\n",
			 chip_id, IMX596_CHIP_ID);
		ret = -ENXIO;
	}

	priv->client->addr = orig;
	return ret;
}

static int imx596_enum_mbus_code(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *sd_state,
				 struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index)
		return -EINVAL;
	code->code = IMX596_MBUS_CODE;
	return 0;
}

static int imx596_enum_frame_size(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *sd_state,
				  struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index || fse->code != IMX596_MBUS_CODE)
		return -EINVAL;

	fse->min_width = IMX596_WIDTH;
	fse->max_width = IMX596_WIDTH;
	fse->min_height = IMX596_HEIGHT;
	fse->max_height = IMX596_HEIGHT;
	return 0;
}

static int imx596_set_fmt(struct v4l2_subdev *sd,
			  struct v4l2_subdev_state *sd_state,
			  struct v4l2_subdev_format *fmt)
{
	fmt->format.width = IMX596_WIDTH;
	fmt->format.height = IMX596_HEIGHT;
	fmt->format.code = IMX596_MBUS_CODE;
	fmt->format.field = V4L2_FIELD_NONE;
	fmt->format.colorspace = V4L2_COLORSPACE_RAW;
	*v4l2_subdev_state_get_format(sd_state, fmt->pad) = fmt->format;
	return 0;
}

static const struct cci_reg_sequence imx596_mode_2592x1952[] = {
	{ CCI_REG8(0x0100), 0x00 },
	/* CCS/Sony EXCK 8.8: 0x13.33 = 19.2 MHz (stock Android MCLK). */
	{ CCI_REG8(0x0136), 0x13 },
	{ CCI_REG8(0x0137), 0x33 },
	/*
	 * 4-lane MIPI PLL from Sony CCS / IMX258 19.2 MHz 4-lane template.
	 * DT link-frequencies = 600 MHz CSI clock (~1.2 Gbps/lane).
	 */
	{ CCI_REG8(0x0301), 0x05 },
	{ CCI_REG8(0x0303), 0x02 },
	{ CCI_REG8(0x0305), 0x03 },
	{ CCI_REG8(0x0306), 0x00 },
	{ CCI_REG8(0x0307), 0xc6 },
	{ CCI_REG8(0x0309), 0x0a },
	{ CCI_REG8(0x030b), 0x01 },
	{ CCI_REG8(0x030d), 0x02 },
	{ CCI_REG8(0x030e), 0x00 },
	{ CCI_REG8(0x030f), 0xd8 },
	{ CCI_REG8(0x0310), 0x00 },
	{ CCI_REG8(0x0112), 0x0a },
	{ CCI_REG8(0x0113), 0x0a },
	{ CCI_REG8(0x0114), 0x03 },
	/* Requested link bit rate ~1200 Mbps (0x0820 is 16.16). */
	{ CCI_REG8(0x0820), 0x12 },
	{ CCI_REG8(0x0821), 0xc0 },
	{ CCI_REG8(0x0822), 0x00 },
	{ CCI_REG8(0x0823), 0x00 },
	{ CCI_REG16(0x0340), 0x0800 },
	{ CCI_REG16(0x0342), 0x0b40 },
	{ CCI_REG16(0x034c), IMX596_WIDTH },
	{ CCI_REG16(0x034e), IMX596_HEIGHT },
	{ CCI_REG8(0x0108), 0x01 },
	{ CCI_REG8(0x0114), 0x03 },
	/* Solid test pattern (Sony CCS 0x0600) so STREAMON can prove MIPI. */
	{ CCI_REG8(0x0600), 0x00 },
	{ CCI_REG8(0x0601), 0x01 },
};

static int imx596_enable_streams(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *state, u32 pad,
				 u64 streams_mask)
{
	struct imx596 *priv = to_imx596(sd);
	int ret;

	ret = pm_runtime_resume_and_get(priv->dev);
	if (ret < 0)
		return ret;

	ret = cci_multi_reg_write(priv->regmap, imx596_mode_2592x1952,
				  ARRAY_SIZE(imx596_mode_2592x1952), NULL);
	if (ret)
		goto rpm_put;

	usleep_range(10 * USEC_PER_MSEC, 12 * USEC_PER_MSEC);
	ret = cci_write(priv->regmap, IMX596_REG_MODE_SELECT,
			IMX596_MODE_STREAMING, NULL);
	if (ret)
		goto rpm_put;

	msleep(80);
	{
		u64 fc = 0, mode = 0, phy = 0, lanes = 0;

		cci_read(priv->regmap, CCI_REG8(0x0005), &fc, NULL);
		cci_read(priv->regmap, IMX596_REG_MODE_SELECT, &mode, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0108), &phy, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0114), &lanes, NULL);
		dev_info(priv->dev,
			 "dagu imx596 streaming %dx%d fc=0x%llx mode=0x%llx phy=0x%llx lanes=0x%llx\n",
			 IMX596_WIDTH, IMX596_HEIGHT, fc, mode, phy, lanes);
	}
	return 0;

rpm_put:
	pm_runtime_put(priv->dev);
	return ret;
}

static int imx596_disable_streams(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state, u32 pad,
				  u64 streams_mask)
{
	struct imx596 *priv = to_imx596(sd);

	cci_write(priv->regmap, IMX596_REG_MODE_SELECT,
		  IMX596_MODE_STANDBY, NULL);
	pm_runtime_put(priv->dev);
	return 0;
}

static const struct v4l2_subdev_video_ops imx596_video_ops = {
	.s_stream = v4l2_subdev_s_stream_helper,
};

static const struct v4l2_subdev_pad_ops imx596_pad_ops = {
	.enum_mbus_code = imx596_enum_mbus_code,
	.enum_frame_size = imx596_enum_frame_size,
	.get_fmt = v4l2_subdev_get_fmt,
	.set_fmt = imx596_set_fmt,
	.enable_streams = imx596_enable_streams,
	.disable_streams = imx596_disable_streams,
};

static int imx596_init_state(struct v4l2_subdev *sd,
			     struct v4l2_subdev_state *sd_state)
{
	struct v4l2_subdev_format fmt = {
		.which = V4L2_SUBDEV_FORMAT_TRY,
	};

	return imx596_set_fmt(sd, sd_state, &fmt);
}

static const struct v4l2_subdev_internal_ops imx596_internal_ops = {
	.init_state = imx596_init_state,
};

static const struct v4l2_subdev_ops imx596_subdev_ops = {
	.video = &imx596_video_ops,
	.pad = &imx596_pad_ops,
};

static int imx596_parse_hw(struct imx596 *priv)
{
	struct v4l2_fwnode_endpoint vep = {
		.bus_type = V4L2_MBUS_CSI2_DPHY,
	};
	struct fwnode_handle *endpoint;
	unsigned long freq;
	unsigned int i;
	int ret;

	endpoint = fwnode_graph_get_next_endpoint(dev_fwnode(priv->dev), NULL);
	if (!endpoint)
		return dev_err_probe(priv->dev, -EINVAL, "no endpoint\n");

	ret = v4l2_fwnode_endpoint_alloc_parse(endpoint, &vep);
	fwnode_handle_put(endpoint);
	if (ret)
		return dev_err_probe(priv->dev, ret, "failed to parse endpoint\n");

	v4l2_fwnode_endpoint_free(&vep);

	priv->mclk = devm_v4l2_sensor_clk_get(priv->dev, NULL);
	if (IS_ERR(priv->mclk))
		return dev_err_probe(priv->dev, PTR_ERR(priv->mclk),
				     "failed to get MCLK\n");

	freq = clk_get_rate(priv->mclk);
	if (freq && freq != IMX596_MCLK_FREQ)
		dev_warn(priv->dev, "MCLK %lu Hz (CAF uses 19.2 MHz)\n", freq);

	priv->reset_gpio = devm_gpiod_get_optional(priv->dev, "reset",
						   GPIOD_OUT_HIGH);
	if (IS_ERR(priv->reset_gpio))
		return dev_err_probe(priv->dev, PTR_ERR(priv->reset_gpio),
				     "reset GPIO\n");

	for (i = 0; i < ARRAY_SIZE(priv->supplies); i++)
		priv->supplies[i].supply = imx596_supply_names[i];

	ret = devm_regulator_bulk_get(priv->dev, ARRAY_SIZE(priv->supplies),
				      priv->supplies);
	if (ret)
		return dev_err_probe(priv->dev, ret, "regulators\n");

	return 0;
}

static int imx596_probe(struct i2c_client *client)
{
	struct imx596 *priv;
	int ret;

	priv = devm_kzalloc(&client->dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->dev = &client->dev;
	priv->client = client;
	mutex_init(&priv->mutex);

	priv->regmap = devm_cci_regmap_init_i2c(client, 16);
	if (IS_ERR(priv->regmap))
		return PTR_ERR(priv->regmap);

	ret = imx596_parse_hw(priv);
	if (ret)
		return ret;

	v4l2_i2c_subdev_init(&priv->sd, client, &imx596_subdev_ops);
	priv->sd.internal_ops = &imx596_internal_ops;
	priv->sd.state_lock = &priv->mutex;
	priv->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	priv->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	priv->pad.flags = MEDIA_PAD_FL_SOURCE;
	ret = media_entity_pads_init(&priv->sd.entity, 1, &priv->pad);
	if (ret)
		return ret;

	ret = v4l2_ctrl_handler_init(&priv->ctrl_handler, 1);
	if (ret)
		goto entity_cleanup;
	v4l2_ctrl_new_int_menu(&priv->ctrl_handler, NULL, V4L2_CID_LINK_FREQ,
			       0, 0, imx596_link_freq_menu);
	priv->sd.ctrl_handler = &priv->ctrl_handler;
	if (priv->ctrl_handler.error) {
		ret = priv->ctrl_handler.error;
		goto ctrl_free;
	}

	ret = imx596_power_on(priv->dev);
	if (ret)
		goto ctrl_free;

	ret = imx596_identify(priv);
	if (ret)
		dev_warn(priv->dev,
			 "chip id failed (%d); still register so CAMSS can link the rear sensor\n",
			 ret);

	ret = v4l2_subdev_init_finalize(&priv->sd);
	if (ret)
		goto power_off;

	pm_runtime_set_active(priv->dev);
	pm_runtime_enable(priv->dev);

	ret = v4l2_async_register_subdev_sensor(&priv->sd);
	if (ret)
		goto rpm_disable;

	pm_runtime_idle(priv->dev);
	return 0;

rpm_disable:
	v4l2_subdev_cleanup(&priv->sd);
	pm_runtime_disable(priv->dev);
	pm_runtime_set_suspended(priv->dev);
power_off:
	imx596_power_off(priv->dev);
ctrl_free:
	v4l2_ctrl_handler_free(&priv->ctrl_handler);
entity_cleanup:
	media_entity_cleanup(&priv->sd.entity);
	mutex_destroy(&priv->mutex);
	return ret;
}

static void imx596_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct imx596 *priv = to_imx596(sd);

	v4l2_async_unregister_subdev(sd);
	v4l2_subdev_cleanup(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(sd->ctrl_handler);
	pm_runtime_disable(priv->dev);
	if (!pm_runtime_status_suspended(priv->dev)) {
		imx596_power_off(priv->dev);
		pm_runtime_set_suspended(priv->dev);
	}
	mutex_destroy(&priv->mutex);
}

static const struct dev_pm_ops imx596_pm_ops = {
	SET_RUNTIME_PM_OPS(imx596_power_off, imx596_power_on, NULL)
};

static const struct of_device_id imx596_of_match[] = {
	{ .compatible = "sony,imx596" },
	{ }
};
MODULE_DEVICE_TABLE(of, imx596_of_match);

static struct i2c_driver imx596_i2c_driver = {
	.driver = {
		.name = "imx596-dagu",
		.pm = &imx596_pm_ops,
		.of_match_table = imx596_of_match,
	},
	.probe = imx596_probe,
	.remove = imx596_remove,
};
module_i2c_driver(imx596_i2c_driver);

MODULE_AUTHOR("dagu bring-up");
MODULE_DESCRIPTION("Sony IMX596 sensor driver for Xiaomi dagu");
MODULE_LICENSE("GPL");
