// SPDX-License-Identifier: GPL-2.0-only
/*
 * Sony IMX596 front camera for Xiaomi Pad 5 Pro 12.4 (dagu).
 *
 * CAF dagu-sm8250-camera-sensor-mtp.dtsi qcom,cam-sensor@2:
 *   csiphy4, CCI1 master1, silicon ACKs at 0x10 (CAF dtsi said 0x1a),
 *   reset GPIO109, MCLK GPIO97 / CAM_CC_MCLK3 19.2 MHz,
 *   AVDD GPIO84 2.8 V, VIO pm8150 1.8 V, VDIG ~1.15 V.
 *
 * Register tables from dumps/dagu-android-live/camera/
 * com.qti.sensormodule.dagu_aac_imx596_front.bin (Chromatix V2):
 *   initSettings (364) + 2592x1952 preview (4-lane D-PHY, 0x0114=3).
 * OP PLL 19.2 MHz / 3 * 0xD4 = 1.3568 GHz MIPI DDR clock 678.4 MHz.
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
#define IMX596_REG_SW_RESET		CCI_REG8(0x0103)
#define IMX596_REG_GROUP_HOLD		CCI_REG8(0x0104)

#define IMX596_MCLK_FREQ		(19200 * HZ_PER_KHZ)
#define IMX596_LINK_FREQ		(678400000ULL) /* CamX OP PLL DDR clock */
#define IMX596_DATA_LANES		4
#define IMX596_BITS_PER_SAMPLE		10
#define IMX596_PIXEL_RATE		(IMX596_LINK_FREQ * 2 * IMX596_DATA_LANES / \
					 IMX596_BITS_PER_SAMPLE)
#define IMX596_WIDTH			2592
#define IMX596_HEIGHT			1952
#define IMX596_HTS			0x1224 /* CamX 0x0342/0x0343 */
#define IMX596_VTS			0x189e /* CamX 0x0340/0x0341 */
#define IMX596_VTS_MAX			0xffff
#define IMX596_EXPOSURE_MIN		1
#define IMX596_EXPOSURE_MARGIN		22
/* CamX preview 0x0202/0x0203. Indoor if too bright, drop back toward 0x0400. */
#define IMX596_EXPOSURE_DEFAULT		0x1886
#define IMX596_AGAIN_MIN		0
/* Analog PGA 0..0x7f. Do not expose 12-bit 0x0fff — SoftISP AE saturates it. */
#define IMX596_AGAIN_MAX		0x7f
#define IMX596_AGAIN_DEFAULT		0x20
#define IMX596_REG_EXPOSURE		CCI_REG16(0x0202)
#define IMX596_REG_AGAIN		CCI_REG16(0x0204)
#define IMX596_REG_VTS			CCI_REG16(0x0340)
/* Sony 16-bit BE. CCI_REG16_LE did not latch 0x0600 (STREAMON readback 0). */
#define IMX596_REG_TEST_PATTERN		CCI_REG16(0x0600)
#define IMX596_TEST_PATTERN_DISABLE	0
#define IMX596_TEST_PATTERN_SOLID	1
#define IMX596_TEST_PATTERN_COLOR_BARS	2
#define IMX596_TEST_PATTERN_GREY	3
#define IMX596_TEST_PATTERN_WALKING	256
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
	struct v4l2_ctrl *exposure;
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

	/*
	 * CAF qcom,cam-sensor@2 regulator-names:
	 *   cam_vio, cam_vana, cam_vdig, cam_clk
	 * Enable in that order. VDIG before AVDD left the pixel array at OB
	 * while CCI/MIPI still produced RAW10.
	 */
	ret = imx596_enable_supply(priv, "vddio");
	if (ret)
		return ret;
	usleep_range(1000, 2000);

	ret = imx596_enable_supply(priv, "vdda");
	if (ret)
		goto disable_vddio;
	usleep_range(5000, 6000);

	ret = imx596_enable_supply(priv, "vddd");
	if (ret)
		goto disable_vdda;
	usleep_range(1000, 2000);

	ret = clk_prepare_enable(priv->mclk);
	if (ret)
		goto disable_vddd;

	usleep_range(1000, 2000);
	/* CAF: reset low then high with MCLK running. GPIO is active-low. */
	gpiod_set_value_cansleep(priv->reset_gpio, 1);
	usleep_range(2000, 3000);
	gpiod_set_value_cansleep(priv->reset_gpio, 0);
	usleep_range(50 * USEC_PER_MSEC, 55 * USEC_PER_MSEC);
	return 0;

disable_vddd:
	imx596_disable_supply(priv, "vddd");
disable_vdda:
	imx596_disable_supply(priv, "vdda");
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
	imx596_disable_supply(priv, "vddd");
	imx596_disable_supply(priv, "vdda");
	imx596_disable_supply(priv, "vddio");
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

static int imx596_get_selection(struct v4l2_subdev *sd,
				struct v4l2_subdev_state *sd_state,
				struct v4l2_subdev_selection *sel)
{
	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_NATIVE_SIZE:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = IMX596_WIDTH;
		sel->r.height = IMX596_HEIGHT;
		return 0;
	default:
		return -EINVAL;
	}
}

static const char * const imx596_test_pattern_menu[] = {
	"Disabled",
	"Color Bars",
	"Solid Color",
	"Grey Color Bars",
	"Walking 1s",
};

static const int imx596_test_pattern_val[] = {
	IMX596_TEST_PATTERN_DISABLE,
	IMX596_TEST_PATTERN_COLOR_BARS,
	IMX596_TEST_PATTERN_SOLID,
	IMX596_TEST_PATTERN_GREY,
	IMX596_TEST_PATTERN_WALKING,
};

static int imx596_write_test_pattern(struct imx596 *priv, u32 menu_index)
{
	u16 val = imx596_test_pattern_val[menu_index];
	u64 rb0 = 0, rb1 = 0;
	int ret;

	ret = cci_write(priv->regmap, IMX596_REG_GROUP_HOLD, 0x01, NULL);
	if (ret)
		return ret;
	ret = cci_write(priv->regmap, IMX596_REG_TEST_PATTERN, val, NULL);
	if (ret)
		return ret;
	/* Split 8-bit in case 16-bit BE does not land on this silicon. */
	ret = cci_write(priv->regmap, CCI_REG8(0x0600), val & 0xff, NULL);
	if (ret)
		return ret;
	ret = cci_write(priv->regmap, CCI_REG8(0x0601), (val >> 8) & 0xff, NULL);
	if (ret)
		return ret;
	ret = cci_write(priv->regmap, IMX596_REG_GROUP_HOLD, 0x00, NULL);
	if (ret)
		return ret;

	cci_read(priv->regmap, CCI_REG8(0x0600), &rb0, NULL);
	cci_read(priv->regmap, CCI_REG8(0x0601), &rb1, NULL);
	dev_info(priv->dev, "dagu imx596 tpg wr=0x%x rb=0x%llx/0x%llx\n",
		 val, rb0, rb1);
	return 0;
}

static int imx596_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct imx596 *priv = container_of(ctrl->handler, struct imx596,
					    ctrl_handler);
	s64 exposure_max;
	int ret = 0;

	if (ctrl->id == V4L2_CID_VBLANK && priv->exposure) {
		exposure_max = IMX596_HEIGHT + ctrl->val - IMX596_EXPOSURE_MARGIN;
		__v4l2_ctrl_modify_range(priv->exposure,
					 priv->exposure->minimum, exposure_max,
					 priv->exposure->step,
					 priv->exposure->default_value);
	}

	if (!pm_runtime_get_if_active(priv->dev))
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_ANALOGUE_GAIN:
		ret = cci_write(priv->regmap, IMX596_REG_AGAIN, ctrl->val, NULL);
		break;
	case V4L2_CID_EXPOSURE:
		ret = cci_write(priv->regmap, IMX596_REG_EXPOSURE, ctrl->val, NULL);
		break;
	case V4L2_CID_VBLANK:
		ret = cci_write(priv->regmap, IMX596_REG_VTS,
				ctrl->val + IMX596_HEIGHT, NULL);
		break;
	case V4L2_CID_TEST_PATTERN:
		ret = imx596_write_test_pattern(priv, ctrl->val);
		break;
	default:
		break;
	}

	pm_runtime_put(priv->dev);
	return ret;
}

static const struct v4l2_ctrl_ops imx596_ctrl_ops = {
	.s_ctrl = imx596_s_ctrl,
};

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

static const struct cci_reg_sequence imx596_init[] = {
	{ CCI_REG8(0x0136), 0x13 },
	{ CCI_REG8(0x0137), 0x33 },
	{ CCI_REG8(0x321c), 0x00 },
	{ CCI_REG8(0x33f0), 0x02 },
	{ CCI_REG8(0x33f1), 0x03 },
	{ CCI_REG8(0x0101), 0x00 },
	{ CCI_REG8(0x32c8), 0x01 },
	{ CCI_REG8(0x40a2), 0x01 },
	{ CCI_REG8(0x441f), 0x01 },
	{ CCI_REG8(0x4b20), 0x07 },
	{ CCI_REG8(0x5abe), 0x3a },
	{ CCI_REG8(0x5ac8), 0x3a },
	{ CCI_REG8(0x5ad0), 0x3a },
	{ CCI_REG8(0x5ada), 0x3a },
	{ CCI_REG8(0x5c04), 0x00 },
	{ CCI_REG8(0x5c05), 0x00 },
	{ CCI_REG8(0x5c06), 0x00 },
	{ CCI_REG8(0x5c0b), 0x00 },
	{ CCI_REG8(0x5c0c), 0x00 },
	{ CCI_REG8(0x5c0d), 0x00 },
	{ CCI_REG8(0x5c0e), 0x00 },
	{ CCI_REG8(0x5d55), 0x00 },
	{ CCI_REG8(0x5d56), 0x00 },
	{ CCI_REG8(0x6104), 0x0a },
	{ CCI_REG8(0x6105), 0x0a },
	{ CCI_REG8(0x6107), 0x0a },
	{ CCI_REG8(0x610e), 0x07 },
	{ CCI_REG8(0x610f), 0x07 },
	{ CCI_REG8(0x6110), 0x07 },
	{ CCI_REG8(0x6111), 0x07 },
	{ CCI_REG8(0x6112), 0x07 },
	{ CCI_REG8(0x6113), 0x07 },
	{ CCI_REG8(0x6114), 0x07 },
	{ CCI_REG8(0x6115), 0x07 },
	{ CCI_REG8(0x611c), 0x0b },
	{ CCI_REG8(0x611d), 0x07 },
	{ CCI_REG8(0x611e), 0x09 },
	{ CCI_REG8(0x611f), 0x07 },
	{ CCI_REG8(0x6122), 0x09 },
	{ CCI_REG8(0x612b), 0x07 },
	{ CCI_REG8(0x612d), 0x07 },
	{ CCI_REG8(0x612e), 0x07 },
	{ CCI_REG8(0x612f), 0x07 },
	{ CCI_REG8(0x6131), 0x07 },
	{ CCI_REG8(0x6138), 0x0b },
	{ CCI_REG8(0x6139), 0x07 },
	{ CCI_REG8(0x613a), 0x0b },
	{ CCI_REG8(0x613f), 0x07 },
	{ CCI_REG8(0x6182), 0x01 },
	{ CCI_REG8(0x6183), 0x01 },
	{ CCI_REG8(0x6184), 0x01 },
	{ CCI_REG8(0x6185), 0x01 },
	{ CCI_REG8(0x6186), 0x01 },
	{ CCI_REG8(0x6187), 0x01 },
	{ CCI_REG8(0x6188), 0x01 },
	{ CCI_REG8(0x6189), 0x01 },
	{ CCI_REG8(0x618a), 0x01 },
	{ CCI_REG8(0x618b), 0x01 },
	{ CCI_REG8(0x618c), 0x01 },
	{ CCI_REG8(0x618d), 0x01 },
	{ CCI_REG8(0x618e), 0x01 },
	{ CCI_REG8(0x618f), 0x01 },
	{ CCI_REG8(0x6194), 0x01 },
	{ CCI_REG8(0x6195), 0x01 },
	{ CCI_REG8(0x6197), 0x01 },
	{ CCI_REG8(0x6199), 0x01 },
	{ CCI_REG8(0x619b), 0x01 },
	{ CCI_REG8(0x619d), 0x01 },
	{ CCI_REG8(0x61a2), 0x01 },
	{ CCI_REG8(0x61a3), 0x01 },
	{ CCI_REG8(0x61a5), 0x01 },
	{ CCI_REG8(0x6205), 0x29 },
	{ CCI_REG8(0x6207), 0x29 },
	{ CCI_REG8(0x6209), 0x29 },
	{ CCI_REG8(0x620b), 0x29 },
	{ CCI_REG8(0x620d), 0x29 },
	{ CCI_REG8(0x620f), 0x29 },
	{ CCI_REG8(0x6211), 0x29 },
	{ CCI_REG8(0x6213), 0x29 },
	{ CCI_REG8(0x6215), 0x29 },
	{ CCI_REG8(0x6217), 0x29 },
	{ CCI_REG8(0x6219), 0x29 },
	{ CCI_REG8(0x621b), 0x29 },
	{ CCI_REG8(0x621d), 0x29 },
	{ CCI_REG8(0x621f), 0x29 },
	{ CCI_REG8(0x6221), 0x0a },
	{ CCI_REG8(0x622b), 0x29 },
	{ CCI_REG8(0x622d), 0x29 },
	{ CCI_REG8(0x6231), 0x29 },
	{ CCI_REG8(0x6235), 0x29 },
	{ CCI_REG8(0x6239), 0x29 },
	{ CCI_REG8(0x623d), 0x29 },
	{ CCI_REG8(0x6249), 0x29 },
	{ CCI_REG8(0x624b), 0x29 },
	{ CCI_REG8(0x624f), 0x29 },
	{ CCI_REG8(0x628f), 0x90 },
	{ CCI_REG8(0x6291), 0x90 },
	{ CCI_REG8(0x6293), 0x90 },
	{ CCI_REG8(0x6295), 0x90 },
	{ CCI_REG8(0x6297), 0x90 },
	{ CCI_REG8(0x6299), 0x90 },
	{ CCI_REG8(0x629b), 0x90 },
	{ CCI_REG8(0x629d), 0x90 },
	{ CCI_REG8(0x629f), 0x90 },
	{ CCI_REG8(0x62a1), 0x90 },
	{ CCI_REG8(0x62a3), 0x90 },
	{ CCI_REG8(0x62a5), 0x90 },
	{ CCI_REG8(0x62a7), 0x90 },
	{ CCI_REG8(0x62a9), 0x90 },
	{ CCI_REG8(0x62ab), 0x24 },
	{ CCI_REG8(0x62b5), 0x90 },
	{ CCI_REG8(0x62b7), 0x90 },
	{ CCI_REG8(0x62bb), 0x90 },
	{ CCI_REG8(0x62bf), 0x90 },
	{ CCI_REG8(0x62c3), 0x90 },
	{ CCI_REG8(0x62c7), 0x90 },
	{ CCI_REG8(0x62d3), 0x90 },
	{ CCI_REG8(0x62d5), 0x90 },
	{ CCI_REG8(0x62d9), 0x90 },
	{ CCI_REG8(0x6319), 0x90 },
	{ CCI_REG8(0x631b), 0x90 },
	{ CCI_REG8(0x631f), 0x90 },
	{ CCI_REG8(0x6323), 0x90 },
	{ CCI_REG8(0x636d), 0x28 },
	{ CCI_REG8(0x636e), 0x2a },
	{ CCI_REG8(0x636f), 0x29 },
	{ CCI_REG8(0x6370), 0x29 },
	{ CCI_REG8(0x6371), 0x0e },
	{ CCI_REG8(0x6372), 0x0e },
	{ CCI_REG8(0x6373), 0x28 },
	{ CCI_REG8(0x6374), 0x0f },
	{ CCI_REG8(0x6375), 0x1e },
	{ CCI_REG8(0x6376), 0x0d },
	{ CCI_REG8(0x637d), 0x2a },
	{ CCI_REG8(0x637e), 0x2b },
	{ CCI_REG8(0x637f), 0x2a },
	{ CCI_REG8(0x6380), 0x2a },
	{ CCI_REG8(0x6381), 0x28 },
	{ CCI_REG8(0x6382), 0x29 },
	{ CCI_REG8(0x6383), 0x2a },
	{ CCI_REG8(0x6384), 0x27 },
	{ CCI_REG8(0x6385), 0x1e },
	{ CCI_REG8(0x6386), 0x1e },
	{ CCI_REG8(0x638d), 0x28 },
	{ CCI_REG8(0x638e), 0x32 },
	{ CCI_REG8(0x638f), 0x28 },
	{ CCI_REG8(0x6390), 0x32 },
	{ CCI_REG8(0x6391), 0x29 },
	{ CCI_REG8(0x6392), 0x2a },
	{ CCI_REG8(0x6393), 0x28 },
	{ CCI_REG8(0x6394), 0x29 },
	{ CCI_REG8(0x6395), 0x1d },
	{ CCI_REG8(0x6396), 0x1f },
	{ CCI_REG8(0x639d), 0x28 },
	{ CCI_REG8(0x639e), 0x32 },
	{ CCI_REG8(0x639f), 0x28 },
	{ CCI_REG8(0x63a0), 0x32 },
	{ CCI_REG8(0x63a1), 0x2a },
	{ CCI_REG8(0x63a2), 0x2b },
	{ CCI_REG8(0x63a3), 0x28 },
	{ CCI_REG8(0x63a4), 0x2a },
	{ CCI_REG8(0x63a5), 0x1e },
	{ CCI_REG8(0x63a6), 0x20 },
	{ CCI_REG8(0x63ad), 0x28 },
	{ CCI_REG8(0x63ae), 0x32 },
	{ CCI_REG8(0x63af), 0x28 },
	{ CCI_REG8(0x63b0), 0x1e },
	{ CCI_REG8(0x63b4), 0x28 },
	{ CCI_REG8(0x63b5), 0x32 },
	{ CCI_REG8(0x63b6), 0x28 },
	{ CCI_REG8(0x63b7), 0x1e },
	{ CCI_REG8(0x63c9), 0x01 },
	{ CCI_REG8(0x63da), 0x03 },
	{ CCI_REG8(0x63de), 0x03 },
	{ CCI_REG8(0x63ea), 0x05 },
	{ CCI_REG8(0x63ed), 0x01 },
	{ CCI_REG8(0x63ee), 0x04 },
	{ CCI_REG8(0x63f8), 0x03 },
	{ CCI_REG8(0x63fa), 0x03 },
	{ CCI_REG8(0x63ff), 0x05 },
	{ CCI_REG8(0x6401), 0x04 },
	{ CCI_REG8(0x6403), 0x04 },
	{ CCI_REG8(0x6404), 0x03 },
	{ CCI_REG8(0x6405), 0x04 },
	{ CCI_REG8(0x6406), 0x03 },
	{ CCI_REG8(0x6407), 0x1f },
	{ CCI_REG8(0x6408), 0x0e },
	{ CCI_REG8(0x6409), 0x02 },
	{ CCI_REG8(0x640a), 0x1f },
	{ CCI_REG8(0x640b), 0x0d },
	{ CCI_REG8(0x640c), 0x1f },
	{ CCI_REG8(0x6417), 0x04 },
	{ CCI_REG8(0x6418), 0x03 },
	{ CCI_REG8(0x641a), 0x02 },
	{ CCI_REG8(0x641b), 0x07 },
	{ CCI_REG8(0x641c), 0x0d },
	{ CCI_REG8(0x6427), 0x04 },
	{ CCI_REG8(0x6428), 0x03 },
	{ CCI_REG8(0x642a), 0x03 },
	{ CCI_REG8(0x642b), 0x08 },
	{ CCI_REG8(0x642c), 0x0c },
	{ CCI_REG8(0x6437), 0x01 },
	{ CCI_REG8(0x643a), 0x02 },
	{ CCI_REG8(0x643b), 0x05 },
	{ CCI_REG8(0x643c), 0x07 },
	{ CCI_REG8(0x6446), 0x04 },
	{ CCI_REG8(0x644d), 0x01 },
	{ CCI_REG8(0x6499), 0x01 },
	{ CCI_REG8(0x649a), 0x01 },
	{ CCI_REG8(0x649b), 0x01 },
	{ CCI_REG8(0x649c), 0x01 },
	{ CCI_REG8(0x649d), 0x01 },
	{ CCI_REG8(0x649e), 0x01 },
	{ CCI_REG8(0x649f), 0x01 },
	{ CCI_REG8(0x64a0), 0x01 },
	{ CCI_REG8(0x64a7), 0x01 },
	{ CCI_REG8(0x64a8), 0x01 },
	{ CCI_REG8(0x64a9), 0x01 },
	{ CCI_REG8(0x64aa), 0x01 },
	{ CCI_REG8(0x64ab), 0x01 },
	{ CCI_REG8(0x64ac), 0x01 },
	{ CCI_REG8(0x64ad), 0x01 },
	{ CCI_REG8(0x64ae), 0x01 },
	{ CCI_REG8(0x64b5), 0x01 },
	{ CCI_REG8(0x64b6), 0x01 },
	{ CCI_REG8(0x64b7), 0x01 },
	{ CCI_REG8(0x64b8), 0x01 },
	{ CCI_REG8(0x64b9), 0x01 },
	{ CCI_REG8(0x64ba), 0x01 },
	{ CCI_REG8(0x64bb), 0x01 },
	{ CCI_REG8(0x64bc), 0x01 },
	{ CCI_REG8(0x64c3), 0x01 },
	{ CCI_REG8(0x64c4), 0x01 },
	{ CCI_REG8(0x64c5), 0x01 },
	{ CCI_REG8(0x64c6), 0x01 },
	{ CCI_REG8(0x64c7), 0x01 },
	{ CCI_REG8(0x64c8), 0x01 },
	{ CCI_REG8(0x64c9), 0x01 },
	{ CCI_REG8(0x64ca), 0x01 },
	{ CCI_REG8(0x64d1), 0x01 },
	{ CCI_REG8(0x64d2), 0x01 },
	{ CCI_REG8(0x64d3), 0x01 },
	{ CCI_REG8(0x64d4), 0x01 },
	{ CCI_REG8(0x64d8), 0x01 },
	{ CCI_REG8(0x64d9), 0x01 },
	{ CCI_REG8(0x64da), 0x01 },
	{ CCI_REG8(0x64db), 0x01 },
	{ CCI_REG8(0x651f), 0x1e },
	{ CCI_REG8(0x6520), 0x1e },
	{ CCI_REG8(0x6523), 0x1e },
	{ CCI_REG8(0x6524), 0x1e },
	{ CCI_REG8(0x6526), 0x1e },
	{ CCI_REG8(0x6528), 0x1e },
	{ CCI_REG8(0x6533), 0x1e },
	{ CCI_REG8(0x6534), 0x1e },
	{ CCI_REG8(0x6536), 0x1e },
	{ CCI_REG8(0x6538), 0x1e },
	{ CCI_REG8(0x666f), 0x15 },
	{ CCI_REG8(0x6670), 0x15 },
	{ CCI_REG8(0x6671), 0x15 },
	{ CCI_REG8(0x6672), 0x15 },
	{ CCI_REG8(0x6673), 0x15 },
	{ CCI_REG8(0x6674), 0x15 },
	{ CCI_REG8(0x6675), 0x15 },
	{ CCI_REG8(0x6676), 0x15 },
	{ CCI_REG8(0x6677), 0x15 },
	{ CCI_REG8(0x6678), 0x15 },
	{ CCI_REG8(0x6679), 0x15 },
	{ CCI_REG8(0x667a), 0x15 },
	{ CCI_REG8(0x667b), 0x15 },
	{ CCI_REG8(0x667c), 0x15 },
	{ CCI_REG8(0x6681), 0x15 },
	{ CCI_REG8(0x6682), 0x15 },
	{ CCI_REG8(0x6684), 0x15 },
	{ CCI_REG8(0x6686), 0x15 },
	{ CCI_REG8(0x6688), 0x15 },
	{ CCI_REG8(0x668a), 0x15 },
	{ CCI_REG8(0x668f), 0x15 },
	{ CCI_REG8(0x6690), 0x15 },
	{ CCI_REG8(0x6692), 0x15 },
	{ CCI_REG8(0x66bd), 0x0a },
	{ CCI_REG8(0x66be), 0x0a },
	{ CCI_REG8(0x66ca), 0x0a },
	{ CCI_REG8(0x66cb), 0x0a },
	{ CCI_REG8(0x66d4), 0x0a },
	{ CCI_REG8(0x66d7), 0x0a },
	{ CCI_REG8(0x6a35), 0x36 },
	{ CCI_REG8(0x6a36), 0x0e },
	{ CCI_REG8(0x6a37), 0x36 },
	{ CCI_REG8(0x6a38), 0x36 },
	{ CCI_REG8(0x6a39), 0x36 },
	{ CCI_REG8(0x6a3a), 0x36 },
	{ CCI_REG8(0x6a3b), 0x36 },
	{ CCI_REG8(0x6a3c), 0x0e },
	{ CCI_REG8(0x6a3d), 0x36 },
	{ CCI_REG8(0x6a3e), 0x36 },
	{ CCI_REG8(0x6a3f), 0x36 },
	{ CCI_REG8(0x6a40), 0x36 },
	{ CCI_REG8(0x6a41), 0x36 },
	{ CCI_REG8(0x7910), 0x00 },
	{ CCI_REG8(0x8502), 0x01 },
	{ CCI_REG8(0x8505), 0x00 },
	{ CCI_REG8(0x8605), 0x01 },
	{ CCI_REG8(0x9003), 0x02 },
	{ CCI_REG8(0x9200), 0x86 },
	{ CCI_REG8(0x9201), 0x08 },
	{ CCI_REG8(0x9202), 0x86 },
	{ CCI_REG8(0x9203), 0x09 },
	{ CCI_REG8(0xbc77), 0x4c },
	{ CCI_REG8(0xbc79), 0x7c },
	{ CCI_REG8(0xbc7a), 0x06 },
	{ CCI_REG8(0xbc7b), 0xe8 },
	{ CCI_REG8(0xbc7c), 0x06 },
	{ CCI_REG8(0xbc7d), 0x08 },
	{ CCI_REG8(0xbc7e), 0x0f },
	{ CCI_REG8(0xbc7f), 0x20 },
	{ CCI_REG8(0xbc80), 0x06 },
	{ CCI_REG8(0xbc81), 0xe8 },
	{ CCI_REG8(0xbc82), 0x06 },
	{ CCI_REG8(0xbc83), 0xe8 },
	{ CCI_REG8(0xbc84), 0x06 },
	{ CCI_REG8(0xbc85), 0xe8 },
	{ CCI_REG8(0xbc86), 0x06 },
	{ CCI_REG8(0xbc87), 0xe8 },
	{ CCI_REG8(0xa015), 0x90 },
	{ CCI_REG8(0xa016), 0x90 },
	{ CCI_REG8(0xa017), 0x34 },
	{ CCI_REG8(0xa018), 0xe8 },
	{ CCI_REG8(0xa019), 0x50 },
	{ CCI_REG8(0xa01a), 0x06 },
	{ CCI_REG8(0xa165), 0x10 },
	{ CCI_REG8(0xa16b), 0x10 },
	{ CCI_REG8(0xa171), 0x10 },
	{ CCI_REG8(0xa189), 0xc4 },
	{ CCI_REG8(0xa18f), 0xc4 },
	{ CCI_REG8(0xa195), 0xc4 },
	{ CCI_REG8(0xa19b), 0x0b },
	{ CCI_REG8(0xa1a1), 0x0b },
	{ CCI_REG8(0xa1a7), 0x0b },
	{ CCI_REG8(0xa337), 0x80 },
	{ CCI_REG8(0xa339), 0x80 },
	{ CCI_REG8(0xa33b), 0x80 },
	{ CCI_REG8(0xa51d), 0x10 },
	{ CCI_REG8(0xa520), 0x00 },
	{ CCI_REG8(0xa905), 0x40 },
	{ CCI_REG8(0xa90b), 0x00 },
	{ CCI_REG8(0xaa08), 0xff },
	{ CCI_REG8(0xaa0e), 0xff },
	{ CCI_REG8(0xab11), 0x40 },
	{ CCI_REG8(0xab1d), 0x40 },
	{ CCI_REG8(0xad01), 0x70 },
	{ CCI_REG8(0xad0d), 0x0b },
	{ CCI_REG8(0xad0e), 0x00 },
	{ CCI_REG8(0xad0f), 0x59 },
	{ CCI_REG8(0xad10), 0x00 },
	{ CCI_REG8(0xad11), 0x76 },
	{ CCI_REG8(0xad13), 0x11 },
	{ CCI_REG8(0xad15), 0xaf },
	{ CCI_REG8(0xad17), 0xe7 },
	{ CCI_REG8(0xad19), 0x0f },
	{ CCI_REG8(0xad1a), 0x00 },
	{ CCI_REG8(0xad1b), 0x69 },
	{ CCI_REG8(0xad1c), 0x00 },
	{ CCI_REG8(0xad1d), 0x89 },
};

static const struct cci_reg_sequence imx596_mode_2592x1952[] = {
	{ CCI_REG8(0x0112), 0x0a },
	{ CCI_REG8(0x0113), 0x0a },
	{ CCI_REG8(0x0114), 0x03 },
	{ CCI_REG8(0x0342), 0x12 },
	{ CCI_REG8(0x0343), 0x24 },
	{ CCI_REG8(0x0340), 0x18 },
	{ CCI_REG8(0x0341), 0x9e },
	{ CCI_REG8(0x0344), 0x00 },
	{ CCI_REG8(0x0345), 0x00 },
	{ CCI_REG8(0x0346), 0x00 },
	{ CCI_REG8(0x0347), 0x00 },
	{ CCI_REG8(0x0348), 0x14 },
	{ CCI_REG8(0x0349), 0x3f },
	{ CCI_REG8(0x034a), 0x0f },
	{ CCI_REG8(0x034b), 0x3f },
	{ CCI_REG8(0x0220), 0x62 },
	{ CCI_REG8(0x0221), 0x11 },
	{ CCI_REG8(0x0222), 0x01 },
	{ CCI_REG8(0x0900), 0x01 },
	{ CCI_REG8(0x0901), 0x22 },
	{ CCI_REG8(0x0902), 0x08 },
	{ CCI_REG8(0x30d8), 0x00 },
	{ CCI_REG8(0x3200), 0x41 },
	{ CCI_REG8(0x3201), 0x41 },
	{ CCI_REG8(0x0408), 0x00 },
	{ CCI_REG8(0x0409), 0x00 },
	{ CCI_REG8(0x040a), 0x00 },
	{ CCI_REG8(0x040b), 0x00 },
	{ CCI_REG8(0x040c), 0x0a },
	{ CCI_REG8(0x040d), 0x20 },
	{ CCI_REG8(0x040e), 0x07 },
	{ CCI_REG8(0x040f), 0xa0 },
	{ CCI_REG8(0x034c), 0x0a },
	{ CCI_REG8(0x034d), 0x20 },
	{ CCI_REG8(0x034e), 0x07 },
	{ CCI_REG8(0x034f), 0xa0 },
	{ CCI_REG8(0x0301), 0x05 },
	{ CCI_REG8(0x0303), 0x02 },
	{ CCI_REG8(0x0305), 0x03 },
	{ CCI_REG8(0x0306), 0x01 },
	{ CCI_REG8(0x0307), 0x57 },
	{ CCI_REG8(0x030b), 0x01 },
	{ CCI_REG8(0x030d), 0x03 },
	{ CCI_REG8(0x030e), 0x00 },
	{ CCI_REG8(0x030f), 0xd4 },
	{ CCI_REG8(0x32d3), 0x01 },
	{ CCI_REG8(0x32d5), 0x00 },
	{ CCI_REG8(0x32d6), 0x00 },
	{ CCI_REG8(0x4000), 0x06 },
	{ CCI_REG8(0x4001), 0x04 },
	{ CCI_REG8(0x40a0), 0x03 },
	{ CCI_REG8(0x40a1), 0xc6 },
	{ CCI_REG8(0x40a4), 0x03 },
	{ CCI_REG8(0x40a5), 0xc6 },
	{ CCI_REG8(0x40b8), 0x04 },
	{ CCI_REG8(0x40b9), 0x29 },
	{ CCI_REG8(0x41a4), 0x00 },
	{ CCI_REG8(0x0202), 0x18 },
	{ CCI_REG8(0x0203), 0x86 },
	{ CCI_REG8(0x0224), 0x01 },
	{ CCI_REG8(0x0225), 0xf4 },
	{ CCI_REG8(0x3116), 0x01 },
	{ CCI_REG8(0x3117), 0xf4 },
	{ CCI_REG8(0x0204), 0x00 },
	{ CCI_REG8(0x0205), 0x20 },
	{ CCI_REG8(0x020e), 0x01 },
	{ CCI_REG8(0x020f), 0x00 },
	{ CCI_REG8(0x0216), 0x00 },
	{ CCI_REG8(0x0217), 0x00 },
	{ CCI_REG8(0x0218), 0x01 },
	{ CCI_REG8(0x0219), 0x00 },
	{ CCI_REG8(0x3118), 0x00 },
	{ CCI_REG8(0x3119), 0x00 },
	{ CCI_REG8(0x311a), 0x01 },
	{ CCI_REG8(0x311b), 0x00 },
	{ CCI_REG8(0x3220), 0x01 },
	{ CCI_REG8(0x0b06), 0x01 },
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

	/* Sony SW reset before dumping 364-entry trim into a cold state machine. */
	ret = cci_write(priv->regmap, IMX596_REG_SW_RESET, 0x01, NULL);
	if (ret)
		goto rpm_put;
	usleep_range(10 * USEC_PER_MSEC, 12 * USEC_PER_MSEC);

	ret = cci_multi_reg_write(priv->regmap, imx596_init,
				  ARRAY_SIZE(imx596_init), NULL);
	if (ret)
		goto rpm_put;

	ret = cci_write(priv->regmap, IMX596_REG_GROUP_HOLD, 0x01, NULL);
	if (ret)
		goto rpm_put;

	ret = cci_multi_reg_write(priv->regmap, imx596_mode_2592x1952,
				  ARRAY_SIZE(imx596_mode_2592x1952), NULL);
	if (ret)
		goto rpm_put;

	ret = cci_write(priv->regmap, IMX596_REG_GROUP_HOLD, 0x00, NULL);
	if (ret)
		goto rpm_put;

	/* Group hold must be down before CSI_LANE_MODE sticks. */
	ret = cci_write(priv->regmap, CCI_REG8(0x0114), 0x03, NULL);
	if (ret)
		goto rpm_put;

	ret = cci_write(priv->regmap, IMX596_REG_GROUP_HOLD, 0x01, NULL);
	if (ret)
		goto rpm_put;
	ret = __v4l2_ctrl_handler_setup(priv->sd.ctrl_handler);
	if (ret)
		goto rpm_put;
	ret = cci_write(priv->regmap, IMX596_REG_GROUP_HOLD, 0x00, NULL);
	if (ret)
		goto rpm_put;

	usleep_range(10 * USEC_PER_MSEC, 12 * USEC_PER_MSEC);
	ret = cci_write(priv->regmap, IMX596_REG_MODE_SELECT,
			IMX596_MODE_STREAMING, NULL);
	if (ret)
		goto rpm_put;

	msleep(80);
	{
		u64 fc = 0, mode = 0, lanes = 0, dt = 0;
		u64 pll_op = 0, prediv = 0, vt_mpy = 0;
		u64 exp = 0, again = 0, bin = 0, outw = 0;
		u64 tpg0 = 0, tpg1 = 0, qbc0 = 0, qbc1 = 0;
		u64 analog0 = 0, analog1 = 0, hdr = 0, ob = 0;

		cci_read(priv->regmap, CCI_REG8(0x0005), &fc, NULL);
		cci_read(priv->regmap, IMX596_REG_MODE_SELECT, &mode, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0112), &dt, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0114), &lanes, NULL);
		cci_read(priv->regmap, CCI_REG8(0x030d), &prediv, NULL);
		cci_read(priv->regmap, CCI_REG8(0x030f), &pll_op, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0307), &vt_mpy, NULL);
		cci_read(priv->regmap, IMX596_REG_EXPOSURE, &exp, NULL);
		cci_read(priv->regmap, IMX596_REG_AGAIN, &again, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0901), &bin, NULL);
		cci_read(priv->regmap, CCI_REG16(0x034c), &outw, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0600), &tpg0, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0601), &tpg1, NULL);
		cci_read(priv->regmap, CCI_REG8(0x3200), &qbc0, NULL);
		cci_read(priv->regmap, CCI_REG8(0x3201), &qbc1, NULL);
		cci_read(priv->regmap, CCI_REG8(0x3246), &analog0, NULL);
		cci_read(priv->regmap, CCI_REG8(0x3247), &analog1, NULL);
		cci_read(priv->regmap, CCI_REG8(0x3220), &hdr, NULL);
		cci_read(priv->regmap, CCI_REG8(0x0b06), &ob, NULL);
		dev_info(priv->dev,
			 "dagu imx596 streaming %dx%d fc=0x%llx mode=0x%llx dt=0x%llx lanes=0x%llx prediv=0x%llx op=0x%llx vt=0x%llx exp=0x%llx again=0x%llx bin=0x%llx outw=0x%llx tpg=0x%llx/0x%llx qbc=0x%llx/0x%llx analog=0x%llx/0x%llx hdr=0x%llx ob=0x%llx mclk=%lu\n",
			 IMX596_WIDTH, IMX596_HEIGHT, fc, mode, dt, lanes,
			 prediv, pll_op, vt_mpy, exp, again, bin, outw,
			 tpg0, tpg1, qbc0, qbc1, analog0, analog1, hdr, ob,
			 clk_get_rate(priv->mclk));
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
	.get_selection = imx596_get_selection,
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

	ret = v4l2_ctrl_handler_init(&priv->ctrl_handler, 12);
	if (ret)
		goto entity_cleanup;
	v4l2_ctrl_new_int_menu(&priv->ctrl_handler, NULL, V4L2_CID_LINK_FREQ,
			       0, 0, imx596_link_freq_menu);
	v4l2_ctrl_new_std(&priv->ctrl_handler, &imx596_ctrl_ops,
			  V4L2_CID_PIXEL_RATE, IMX596_PIXEL_RATE,
			  IMX596_PIXEL_RATE, 1, IMX596_PIXEL_RATE);
	{
		struct v4l2_ctrl *hblank;
		struct v4l2_fwnode_device_properties props;
		s64 hblank_val = IMX596_HTS - IMX596_WIDTH;
		s64 vblank_val = IMX596_VTS - IMX596_HEIGHT;
		s64 exposure_max = IMX596_VTS - IMX596_EXPOSURE_MARGIN;

		hblank = v4l2_ctrl_new_std(&priv->ctrl_handler, &imx596_ctrl_ops,
					   V4L2_CID_HBLANK, hblank_val,
					   hblank_val, 1, hblank_val);
		if (hblank)
			hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;
		v4l2_ctrl_new_std(&priv->ctrl_handler, &imx596_ctrl_ops,
				  V4L2_CID_VBLANK, vblank_val,
				  IMX596_VTS_MAX - IMX596_HEIGHT, 1, vblank_val);
		v4l2_ctrl_new_std(&priv->ctrl_handler, &imx596_ctrl_ops,
				  V4L2_CID_ANALOGUE_GAIN, IMX596_AGAIN_MIN,
				  IMX596_AGAIN_MAX, 1, IMX596_AGAIN_DEFAULT);
		priv->exposure = v4l2_ctrl_new_std(&priv->ctrl_handler,
						    &imx596_ctrl_ops,
						    V4L2_CID_EXPOSURE,
						    IMX596_EXPOSURE_MIN,
						    exposure_max, 1,
						    IMX596_EXPOSURE_DEFAULT);
		v4l2_ctrl_new_std_menu_items(&priv->ctrl_handler, &imx596_ctrl_ops,
					    V4L2_CID_TEST_PATTERN,
					    ARRAY_SIZE(imx596_test_pattern_menu) - 1,
					    0, 0, imx596_test_pattern_menu);
		if (!v4l2_fwnode_device_parse(priv->dev, &props))
			v4l2_ctrl_new_fwnode_properties(&priv->ctrl_handler,
						       &imx596_ctrl_ops, &props);
	}
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
		.name = "imx596",
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
