// SPDX-License-Identifier: GPL-2.0-only
/*
 * TI BQ25970 / SC8551 switched-cap charge pump (dagu dual: master+slave).
 * Probe + identity + basic power_supply. PPS policy stays in userspace;
 * CAF xiaomi,usbpd-pm is not copied.
 */

#include <linux/bits.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>

#define BQ2597X_REG_0C		0x0c
#define BQ2597X_CHG_EN		BIT(7)
#define BQ2597X_REG_13		0x13

#define BQ25970_DEVICE_ID	0x10
#define SC8551_DEVICE_ID	0x00
#define SC8551A_DEVICE_ID	0x51

struct bq2597x {
	struct i2c_client *client;
	struct regmap *regmap;
	struct power_supply *psy;
	bool master;
	unsigned int chip_id;
};

static const struct regmap_config bq2597x_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,
	.max_register = 0x36,
};

static int bq2597x_get_property(struct power_supply *psy,
				enum power_supply_property psp,
				union power_supply_propval *val)
{
	struct bq2597x *chip = power_supply_get_drvdata(psy);
	unsigned int reg;
	int ret;

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		ret = regmap_read(chip->regmap, BQ2597X_REG_0C, &reg);
		if (ret)
			return ret;
		val->intval = !!(reg & BQ2597X_CHG_EN);
		return 0;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = chip->master ? "bq25970-master" : "bq25970-slave";
		return 0;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "ti";
		return 0;
	default:
		return -EINVAL;
	}
}

static int bq2597x_set_property(struct power_supply *psy,
				enum power_supply_property psp,
				const union power_supply_propval *val)
{
	struct bq2597x *chip = power_supply_get_drvdata(psy);

	if (psp != POWER_SUPPLY_PROP_ONLINE)
		return -EINVAL;

	return regmap_update_bits(chip->regmap, BQ2597X_REG_0C, BQ2597X_CHG_EN,
				  val->intval ? BQ2597X_CHG_EN : 0);
}

static int bq2597x_prop_is_writeable(struct power_supply *psy,
				     enum power_supply_property psp)
{
	return psp == POWER_SUPPLY_PROP_ONLINE;
}

static const enum power_supply_property bq2597x_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};

static const struct power_supply_desc bq2597x_desc_master = {
	.name = "bq25970-master",
	.type = POWER_SUPPLY_TYPE_MAINS,
	.properties = bq2597x_props,
	.num_properties = ARRAY_SIZE(bq2597x_props),
	.get_property = bq2597x_get_property,
	.set_property = bq2597x_set_property,
	.property_is_writeable = bq2597x_prop_is_writeable,
};

static const struct power_supply_desc bq2597x_desc_slave = {
	.name = "bq25970-slave",
	.type = POWER_SUPPLY_TYPE_MAINS,
	.properties = bq2597x_props,
	.num_properties = ARRAY_SIZE(bq2597x_props),
	.get_property = bq2597x_get_property,
	.set_property = bq2597x_set_property,
	.property_is_writeable = bq2597x_prop_is_writeable,
};

static int bq2597x_probe(struct i2c_client *client)
{
	struct power_supply_config psy_cfg = {};
	struct bq2597x *chip;
	unsigned int id;
	int ret;

	chip = devm_kzalloc(&client->dev, sizeof(*chip), GFP_KERNEL);
	if (!chip)
		return -ENOMEM;

	chip->client = client;
	chip->master = of_property_read_bool(client->dev.of_node, "ti,bq2597x,master");
	chip->regmap = devm_regmap_init_i2c(client, &bq2597x_regmap_config);
	if (IS_ERR(chip->regmap))
		return PTR_ERR(chip->regmap);

	ret = regmap_read(chip->regmap, BQ2597X_REG_13, &id);
	if (ret)
		return dev_err_probe(&client->dev, ret, "chip id\n");

	chip->chip_id = id;
	if (id != BQ25970_DEVICE_ID && id != SC8551_DEVICE_ID &&
	    id != SC8551A_DEVICE_ID)
		dev_warn(&client->dev, "unexpected device id 0x%02x\n", id);

	psy_cfg.drv_data = chip;
	psy_cfg.fwnode = dev_fwnode(&client->dev);
	chip->psy = devm_power_supply_register(&client->dev,
					       chip->master ? &bq2597x_desc_master :
							      &bq2597x_desc_slave,
					       &psy_cfg);
	if (IS_ERR(chip->psy))
		return PTR_ERR(chip->psy);

	i2c_set_clientdata(client, chip);
	dev_info(&client->dev, "%s id=0x%02x\n",
		 chip->master ? "master" : "slave", id);
	return 0;
}

static const struct of_device_id bq2597x_of_match[] = {
	{ .compatible = "ti,bq25970" },
	{ }
};
MODULE_DEVICE_TABLE(of, bq2597x_of_match);

static struct i2c_driver bq2597x_driver = {
	.driver = {
		.name = "bq2597x-dagu",
		.of_match_table = bq2597x_of_match,
	},
	.probe = bq2597x_probe,
};
module_i2c_driver(bq2597x_driver);

MODULE_DESCRIPTION("TI BQ25970 charge pump (dagu)");
MODULE_LICENSE("GPL");
