// SPDX-License-Identifier: GPL-2.0-only
/*
 * Parade PS5169 USB3/DP redriver (Xiaomi dagu).
 * Init sequence from CAF drivers/usb/pd/ps5169.c — not a 1:1 port.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regmap.h>

#define PS5169_CHIP_ID_L	0xac
#define PS5169_CHIP_ID_H	0xad
#define PS5169_ID_H		0x69
#define PS5169_ID_L		0x87

struct ps5169 {
	struct i2c_client *client;
	struct regmap *regmap;
	struct gpio_desc *enable_gpio;
};

static const struct regmap_config ps5169_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,
};

static const u8 ps5169_init_seq[][2] = {
	{ 0x9d, 0x80 },
	{ 0x9d, 0x00 },
	{ 0x40, 0x80 },
	{ 0x04, 0x44 },
	{ 0xa0, 0x02 },
	{ 0x51, 0x87 },
	{ 0x50, 0x20 },
	{ 0x54, 0x11 },
	{ 0x5d, 0x66 },
	{ 0x52, 0x50 },
	{ 0x55, 0x00 },
	{ 0x56, 0x00 },
	{ 0x57, 0x00 },
	{ 0x58, 0x00 },
	{ 0x59, 0x00 },
	{ 0x5a, 0x00 },
	{ 0x5b, 0x00 },
	{ 0x5e, 0x06 },
	{ 0x5f, 0x00 },
	{ 0x60, 0x00 },
	{ 0x61, 0x03 },
	{ 0x65, 0x40 },
	{ 0x66, 0x00 },
	{ 0x67, 0x03 },
	{ 0x75, 0x0c },
	{ 0x77, 0x00 },
	{ 0x78, 0x7c },
};

static int ps5169_configure(struct ps5169 *chip)
{
	unsigned int id_l, id_h;
	unsigned int i;
	int ret;

	ret = regmap_read(chip->regmap, PS5169_CHIP_ID_L, &id_l);
	if (ret)
		return ret;
	ret = regmap_read(chip->regmap, PS5169_CHIP_ID_H, &id_h);
	if (ret)
		return ret;

	if (id_h != PS5169_ID_H || id_l != PS5169_ID_L) {
		dev_err(&chip->client->dev, "unexpected id %02x%02x\n",
			id_h, id_l);
		return -ENODEV;
	}

	for (i = 0; i < ARRAY_SIZE(ps5169_init_seq); i++) {
		if (ps5169_init_seq[i][0] == 0x9d && ps5169_init_seq[i][1] == 0x80) {
			ret = regmap_write(chip->regmap, 0x9d, 0x80);
			if (ret)
				return ret;
			msleep(10);
			continue;
		}
		ret = regmap_write(chip->regmap, ps5169_init_seq[i][0],
				   ps5169_init_seq[i][1]);
		if (ret)
			return ret;
	}

	dev_info(&chip->client->dev, "configured USB3/DP redriver\n");
	return 0;
}

static int ps5169_probe(struct i2c_client *client)
{
	struct ps5169 *chip;
	int ret;

	chip = devm_kzalloc(&client->dev, sizeof(*chip), GFP_KERNEL);
	if (!chip)
		return -ENOMEM;

	chip->client = client;
	chip->regmap = devm_regmap_init_i2c(client, &ps5169_regmap_config);
	if (IS_ERR(chip->regmap))
		return PTR_ERR(chip->regmap);

	chip->enable_gpio = devm_gpiod_get_optional(&client->dev, "enable",
						    GPIOD_OUT_HIGH);
	if (IS_ERR(chip->enable_gpio))
		return PTR_ERR(chip->enable_gpio);

	msleep(50);
	ret = ps5169_configure(chip);
	if (ret)
		return dev_err_probe(&client->dev, ret, "configure\n");

	i2c_set_clientdata(client, chip);
	// #region agent log
	pr_emerg("{\"sessionId\":\"5c27b9\",\"hypothesisId\":\"B\",\"location\":\"ps5169-dagu.c:ps5169_probe\",\"message\":\"ps5169-probe-ok\",\"data\":{\"dev\":\"%s\"},\"timestamp\":0}\n",
		 dev_name(&client->dev));
	// #endregion
	return 0;
}

static const struct of_device_id ps5169_of_match[] = {
	{ .compatible = "parade,ps5169" },
	{ }
};
MODULE_DEVICE_TABLE(of, ps5169_of_match);

static struct i2c_driver ps5169_driver = {
	.driver = {
		.name = "ps5169-dagu",
		.of_match_table = ps5169_of_match,
	},
	.probe = ps5169_probe,
};
module_i2c_driver(ps5169_driver);

MODULE_DESCRIPTION("Parade PS5169 USB/DP redriver (dagu)");
MODULE_LICENSE("GPL");
