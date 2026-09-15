// SPDX-License-Identifier: GPL-2.0-only
/*
 * Combine two BQ27Z561 cells into one BMS, matching CAF xiaomi,dual-FuelGauge
 * math (SoC weighted by charge_full; voltage = max; current / charge = sum).
 * Does not hog fg-*-disable-gpio (CAF charge-path isolation).
 */

#include <linux/err.h>
#include <linux/math64.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>

struct dual_fg {
	struct device *dev;
	struct power_supply *master;
	struct power_supply *slave;
	struct power_supply *bms;
};

static int dual_fg_get(struct power_supply *psy, enum power_supply_property psp,
		       union power_supply_propval *val)
{
	return power_supply_get_property(psy, psp, val);
}

static int dual_fg_sum(struct dual_fg *fg, enum power_supply_property psp, int *out)
{
	union power_supply_propval a = {}, b = {};
	int ra, rb;

	ra = dual_fg_get(fg->master, psp, &a);
	rb = dual_fg_get(fg->slave, psp, &b);
	if (ra || rb)
		return ra ? ra : rb;
	*out = a.intval + b.intval;
	return 0;
}

static int dual_fg_get_property(struct power_supply *psy,
				enum power_supply_property psp,
				union power_supply_propval *val)
{
	struct dual_fg *fg = power_supply_get_drvdata(psy);
	union power_supply_propval m = {}, s = {};
	int fcc_m, fcc_s, tot;
	int ret;

	switch (psp) {
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		ret = dual_fg_get(fg->master, psp, &m);
		if (ret)
			return ret;
		ret = dual_fg_get(fg->slave, psp, &s);
		if (ret)
			return ret;
		val->intval = max(m.intval, s.intval);
		return 0;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
	case POWER_SUPPLY_PROP_CHARGE_FULL:
	case POWER_SUPPLY_PROP_CHARGE_NOW:
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
		return dual_fg_sum(fg, psp, &val->intval);
	case POWER_SUPPLY_PROP_ENERGY_FULL:
	case POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN: {
		enum power_supply_property chg =
			(psp == POWER_SUPPLY_PROP_ENERGY_FULL) ?
			POWER_SUPPLY_PROP_CHARGE_FULL :
			POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN;

		ret = dual_fg_sum(fg, psp, &val->intval);
		if (!ret)
			return 0;
		ret = dual_fg_sum(fg, chg, &val->intval);
		if (ret)
			return ret;
		/* µWh = µAh * 3.87 V (BQ design energy uses ~3.87 V). */
		val->intval = (int)div_u64((u64)val->intval * 3870, 1000);
		return 0;
	}
	case POWER_SUPPLY_PROP_CAPACITY: {
		union power_supply_propval fm = {}, fs = {};

		ret = dual_fg_get(fg->master, POWER_SUPPLY_PROP_CAPACITY, &m);
		if (ret)
			return ret;
		ret = dual_fg_get(fg->slave, POWER_SUPPLY_PROP_CAPACITY, &s);
		if (ret)
			return ret;
		fcc_m = dual_fg_get(fg->master, POWER_SUPPLY_PROP_CHARGE_FULL, &fm) ? 0 : fm.intval;
		fcc_s = dual_fg_get(fg->slave, POWER_SUPPLY_PROP_CHARGE_FULL, &fs) ? 0 : fs.intval;
		tot = fcc_m + fcc_s;
		if (tot <= 0) {
			val->intval = (m.intval + s.intval) / 2;
			return 0;
		}
		/* CAF: weighted by learned FCC, round nearest. */
		val->intval = (fcc_m * m.intval + fcc_s * s.intval + tot / 2) / tot;
		return 0;
	}
	case POWER_SUPPLY_PROP_TEMP:
		ret = dual_fg_get(fg->master, psp, &m);
		if (ret)
			return ret;
		ret = dual_fg_get(fg->slave, psp, &s);
		if (ret)
			return ret;
		val->intval = (m.intval + s.intval) / 2;
		return 0;
	case POWER_SUPPLY_PROP_STATUS:
		ret = dual_fg_get(fg->master, psp, &m);
		if (ret)
			return ret;
		ret = dual_fg_get(fg->slave, psp, &s);
		if (ret)
			return ret;
		if (m.intval == POWER_SUPPLY_STATUS_CHARGING ||
		    s.intval == POWER_SUPPLY_STATUS_CHARGING)
			val->intval = POWER_SUPPLY_STATUS_CHARGING;
		else if (m.intval == POWER_SUPPLY_STATUS_FULL &&
			 s.intval == POWER_SUPPLY_STATUS_FULL)
			val->intval = POWER_SUPPLY_STATUS_FULL;
		else if (m.intval == POWER_SUPPLY_STATUS_DISCHARGING ||
			 s.intval == POWER_SUPPLY_STATUS_DISCHARGING)
			val->intval = POWER_SUPPLY_STATUS_DISCHARGING;
		else
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;
		return 0;
	case POWER_SUPPLY_PROP_PRESENT:
		ret = dual_fg_get(fg->master, psp, &m);
		if (ret)
			return ret;
		ret = dual_fg_get(fg->slave, psp, &s);
		if (ret)
			return ret;
		val->intval = m.intval && s.intval;
		return 0;
	case POWER_SUPPLY_PROP_HEALTH:
		ret = dual_fg_get(fg->master, psp, &m);
		if (ret)
			return ret;
		ret = dual_fg_get(fg->slave, psp, &s);
		if (ret)
			return ret;
		val->intval = (m.intval > s.intval) ? m.intval : s.intval;
		return 0;
	case POWER_SUPPLY_PROP_CYCLE_COUNT:
		ret = dual_fg_get(fg->master, psp, &m);
		if (ret)
			return ret;
		ret = dual_fg_get(fg->slave, psp, &s);
		if (ret)
			return ret;
		val->intval = max(m.intval, s.intval);
		return 0;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		return dual_fg_get(fg->master, psp, val);
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "dagu-dual-bq27z561";
		return 0;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "xiaomi";
		return 0;
	case POWER_SUPPLY_PROP_CAPACITY_LEVEL:
		ret = dual_fg_get_property(psy, POWER_SUPPLY_PROP_CAPACITY, val);
		if (ret)
			return ret;
		if (val->intval >= 100)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_FULL;
		else if (val->intval > 70)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_HIGH;
		else if (val->intval > 30)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_NORMAL;
		else if (val->intval > 10)
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_LOW;
		else
			val->intval = POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
		return 0;
	default:
		return -EINVAL;
	}
}

static const enum power_supply_property dual_fg_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_CAPACITY_LEVEL,
	POWER_SUPPLY_PROP_TEMP,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_CHARGE_FULL,
	POWER_SUPPLY_PROP_CHARGE_NOW,
	POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
	POWER_SUPPLY_PROP_ENERGY_FULL,
	POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN,
	POWER_SUPPLY_PROP_CYCLE_COUNT,
	POWER_SUPPLY_PROP_HEALTH,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};

static const struct power_supply_desc dual_fg_desc = {
	.name = "bms",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = dual_fg_props,
	.num_properties = ARRAY_SIZE(dual_fg_props),
	.get_property = dual_fg_get_property,
};

static struct power_supply *dual_fg_ref(struct device *dev, const char *prop)
{
	struct power_supply *psy;

	psy = devm_power_supply_get_by_reference(dev, prop);
	if (IS_ERR(psy)) {
		if (PTR_ERR(psy) == -ENOENT || PTR_ERR(psy) == -ENODEV)
			return ERR_PTR(-EPROBE_DEFER);
		return psy;
	}
	if (!psy)
		return ERR_PTR(-EPROBE_DEFER);
	return psy;
}

static int dual_fg_probe(struct platform_device *pdev)
{
	struct power_supply_config cfg = {};
	struct dual_fg *fg;

	fg = devm_kzalloc(&pdev->dev, sizeof(*fg), GFP_KERNEL);
	if (!fg)
		return -ENOMEM;

	fg->dev = &pdev->dev;
	fg->master = dual_fg_ref(&pdev->dev, "master-fg");
	if (IS_ERR(fg->master))
		return dev_err_probe(&pdev->dev, PTR_ERR(fg->master), "master-fg\n");
	fg->slave = dual_fg_ref(&pdev->dev, "slave-fg");
	if (IS_ERR(fg->slave))
		return dev_err_probe(&pdev->dev, PTR_ERR(fg->slave), "slave-fg\n");

	cfg.drv_data = fg;
	cfg.fwnode = dev_fwnode(&pdev->dev);
	fg->bms = devm_power_supply_register(&pdev->dev, &dual_fg_desc, &cfg);
	if (IS_ERR(fg->bms))
		return PTR_ERR(fg->bms);

	platform_set_drvdata(pdev, fg);
	dev_info(&pdev->dev, "combined bms from %s + %s\n",
		 fg->master->desc->name, fg->slave->desc->name);
	return 0;
}

static const struct of_device_id dual_fg_of_match[] = {
	{ .compatible = "xiaomi,dual-fuel-gauge" },
	{ .compatible = "xiaomi,dual-FuelGauge" },
	{ }
};
MODULE_DEVICE_TABLE(of, dual_fg_of_match);

static struct platform_driver dual_fg_driver = {
	.driver = {
		.name = "xiaomi-dual-fg",
		.of_match_table = dual_fg_of_match,
	},
	.probe = dual_fg_probe,
};
module_platform_driver(dual_fg_driver);

MODULE_DESCRIPTION("Xiaomi dual BQ27Z561 combiner (dagu)");
MODULE_LICENSE("GPL");
