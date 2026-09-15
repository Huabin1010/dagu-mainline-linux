// SPDX-License-Identifier: GPL-2.0-only
/*
 * IDT P9418 wireless charger (dagu). CAF compatible = "idt,p9418".
 * Probe + GPIOs + a wireless power_supply; RX firmware stays in Android.
 */

#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>

struct p9418 {
	struct i2c_client *client;
	struct regmap *regmap;
	struct gpio_desc *enable_gpio;
	struct gpio_desc *det_gpio;
	struct power_supply *psy;
};

static const struct regmap_config p9418_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,
};

static int p9418_get_property(struct power_supply *psy,
			      enum power_supply_property psp,
			      union power_supply_propval *val)
{
	struct p9418 *chip = power_supply_get_drvdata(psy);

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		if (chip->det_gpio)
			val->intval = gpiod_get_value_cansleep(chip->det_gpio);
		else
			val->intval = 0;
		return 0;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "p9418";
		return 0;
	default:
		return -EINVAL;
	}
}

static const enum power_supply_property p9418_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_MODEL_NAME,
};

static const struct power_supply_desc p9418_desc = {
	.name = "p9418-wireless",
	.type = POWER_SUPPLY_TYPE_WIRELESS,
	.properties = p9418_props,
	.num_properties = ARRAY_SIZE(p9418_props),
	.get_property = p9418_get_property,
};

static irqreturn_t p9418_irq(int irq, void *data)
{
	struct p9418 *chip = data;

	power_supply_changed(chip->psy);
	return IRQ_HANDLED;
}

static int p9418_probe(struct i2c_client *client)
{
	struct power_supply_config psy_cfg = {};
	struct p9418 *chip;
	int ret;

	chip = devm_kzalloc(&client->dev, sizeof(*chip), GFP_KERNEL);
	if (!chip)
		return -ENOMEM;

	chip->client = client;
	chip->regmap = devm_regmap_init_i2c(client, &p9418_regmap_config);
	if (IS_ERR(chip->regmap))
		return PTR_ERR(chip->regmap);

	chip->enable_gpio = devm_gpiod_get_optional(&client->dev, "enable",
						    GPIOD_OUT_HIGH);
	if (IS_ERR(chip->enable_gpio))
		return PTR_ERR(chip->enable_gpio);
	chip->det_gpio = devm_gpiod_get_optional(&client->dev, "det", GPIOD_IN);
	if (IS_ERR(chip->det_gpio))
		return PTR_ERR(chip->det_gpio);

	psy_cfg.drv_data = chip;
	psy_cfg.fwnode = dev_fwnode(&client->dev);
	chip->psy = devm_power_supply_register(&client->dev, &p9418_desc, &psy_cfg);
	if (IS_ERR(chip->psy))
		return PTR_ERR(chip->psy);

	if (client->irq) {
		ret = devm_request_threaded_irq(&client->dev, client->irq, NULL,
						p9418_irq, IRQF_ONESHOT | IRQF_TRIGGER_FALLING,
						"p9418", chip);
		if (ret)
			return dev_err_probe(&client->dev, ret, "irq\n");
	}

	i2c_set_clientdata(client, chip);
	dev_info(&client->dev, "P9418 wireless charger\n");
	return 0;
}

static const struct of_device_id p9418_of_match[] = {
	{ .compatible = "idt,p9418" },
	{ }
};
MODULE_DEVICE_TABLE(of, p9418_of_match);

static struct i2c_driver p9418_driver = {
	.driver = {
		.name = "p9418-dagu",
		.of_match_table = p9418_of_match,
	},
	.probe = p9418_probe,
};
module_i2c_driver(p9418_driver);

MODULE_DESCRIPTION("IDT P9418 wireless charger (dagu)");
MODULE_LICENSE("GPL");
