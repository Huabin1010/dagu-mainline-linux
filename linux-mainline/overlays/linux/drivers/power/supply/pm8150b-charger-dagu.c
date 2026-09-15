// SPDX-License-Identifier: GPL-2.0-only
/*
 * PM8150B SMB5 charger (Xiaomi dagu).
 *
 * CAF qpnp-smb5-dagu.c is thousands of lines (PD / JEITA / dual-pump policy).
 * This is the 5 V / 9 V buck path only: unsuspend USBIN, enable charge, kick
 * the charger watchdog off, set ICL from APSD. Do not touch Type-C @1500 —
 * qcom_pmic_typec owns CC / PD. Do not copy qcom_smbx (SMB2) scales: PM8150B
 * ICL/FCC is 50 mA/LSB and float is 3.6 V + 10 mV/LSB.
 */

#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/devm-helpers.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_wakeirq.h>
#include <linux/pm_wakeup.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>
#include <linux/workqueue.h>

#define CHGR_BASE				0x1000
#define DCDC_BASE				0x1100
#define USBIN_BASE				0x1300
#define MISC_BASE				0x1600

#define BATTERY_CHARGER_STATUS_1		(CHGR_BASE + 0x06)
#define BATTERY_CHARGER_STATUS_MASK		GENMASK(2, 0)
#define INHIBIT_CHARGE				0
#define TRICKLE_CHARGE				1
#define PRE_CHARGE				2
#define FULLON_CHARGE				3
#define TAPER_CHARGE				4
#define TERMINATE_CHARGE			5
#define PAUSE_CHARGE				6
#define DISABLE_CHARGE				7

#define CHARGING_ENABLE_CMD			(CHGR_BASE + 0x42)
#define CHARGING_ENABLE_CMD_BIT			BIT(0)

#define CHGR_FAST_CHARGE_CURRENT_CFG		(CHGR_BASE + 0x61)
#define CHGR_FLOAT_VOLTAGE_CFG			(CHGR_BASE + 0x70)

#define POWER_PATH_STATUS			(DCDC_BASE + 0x0B)
#define USBIN_SUSPEND_STS_BIT			BIT(6)
#define VALID_INPUT_POWER_SOURCE_STS_BIT	BIT(0)

#define APSD_STATUS				(USBIN_BASE + 0x07)
#define APSD_DTC_STATUS_DONE_BIT		BIT(0)

#define APSD_RESULT_STATUS			(USBIN_BASE + 0x08)
#define APSD_RESULT_STATUS_MASK			GENMASK(6, 0)
#define QC_3P0_BIT				BIT(6)
#define QC_2P0_BIT				BIT(5)
#define FLOAT_CHARGER_BIT			BIT(4)
#define DCP_CHARGER_BIT				BIT(3)
#define CDP_CHARGER_BIT				BIT(2)
#define OCP_CHARGER_BIT				BIT(1)
#define SDP_CHARGER_BIT				BIT(0)

#define USBIN_INT_RT_STS			(USBIN_BASE + 0x10)
#define USBIN_PLUGIN_RT_STS_BIT			BIT(4)

#define USBIN_CMD_IL				(USBIN_BASE + 0x40)
#define USBIN_SUSPEND_BIT			BIT(0)

#define CMD_APSD				(USBIN_BASE + 0x41)
#define APSD_RERUN_BIT				BIT(0)

#define CMD_ICL_OVERRIDE			(USBIN_BASE + 0x42)
#define ICL_OVERRIDE_BIT			BIT(0)

#define USBIN_ADAPTER_ALLOW_CFG			(USBIN_BASE + 0x60)
#define USBIN_ADAPTER_ALLOW_MASK		GENMASK(3, 0)
#define USBIN_ADAPTER_ALLOW_5V_TO_12V		0x0c

#define USBIN_OPTIONS_1_CFG			(USBIN_BASE + 0x62)
#define HVDCP_EN_BIT				BIT(2)

#define USBIN_ICL_OPTIONS			(USBIN_BASE + 0x66)
#define USB51_MODE_BIT				BIT(1)
#define USBIN_MODE_CHG_BIT			BIT(0)

#define USBIN_CURRENT_LIMIT_CFG			(USBIN_BASE + 0x70)

#define USBIN_AICL_OPTIONS_CFG			(USBIN_BASE + 0x80)
#define SUSPEND_ON_COLLAPSE_USBIN_BIT		BIT(7)
#define USBIN_AICL_EN_BIT			BIT(2)

#define BARK_BITE_WDOG_PET			(MISC_BASE + 0x43)
#define BARK_BITE_WDOG_PET_BIT			BIT(0)

#define WD_CFG					(MISC_BASE + 0x51)
#define WATCHDOG_TRIGGER_AFP_EN_BIT		BIT(7)
#define BARK_WDOG_INT_EN_BIT			BIT(6)
#define WDOG_TIMER_EN_ON_PLUGIN_BIT		BIT(1)
#define WDOG_TIMER_EN_BIT			BIT(0)

#define SNARL_BARK_BITE_WD_CFG			(MISC_BASE + 0x53)

#define CURRENT_STEP_UA				50000
#define FV_MIN_UV				3600000
#define FV_STEP_UV				10000
#define FV_TARGET_UV				4450000
#define FCC_UA					3000000
#define SDP_UA					500000
#define CDP_UA					1500000
#define DCP_UA					2000000
/* 5 V wall bricks often APSD as SDP; still allow 2 A (10 W). */
#define ICL_5V_MAX_UA				2000000

struct pm8150b_chg {
	struct device *dev;
	struct regmap *regmap;
	struct power_supply *psy;
	struct delayed_work status_work;
	int plugin_irq;
};

static int chg_write_ua(struct pm8150b_chg *chg, unsigned int reg, int ua)
{
	if (ua < 0)
		ua = 0;
	return regmap_write(chg->regmap, reg, ua / CURRENT_STEP_UA);
}

static int chg_usb_online(struct pm8150b_chg *chg, int *online)
{
	unsigned int stat;
	int ret;

	ret = regmap_read(chg->regmap, USBIN_INT_RT_STS, &stat);
	if (ret)
		return ret;
	if (stat & USBIN_PLUGIN_RT_STS_BIT) {
		*online = 1;
		return 0;
	}

	ret = regmap_read(chg->regmap, POWER_PATH_STATUS, &stat);
	if (ret)
		return ret;
	*online = !!(stat & VALID_INPUT_POWER_SOURCE_STS_BIT);
	return 0;
}

static int chg_set_icl(struct pm8150b_chg *chg, int ua)
{
	unsigned int icl_opt = USBIN_MODE_CHG_BIT;
	int ret;

	if (ua <= SDP_UA)
		icl_opt = USB51_MODE_BIT;

	ret = regmap_update_bits(chg->regmap, USBIN_ICL_OPTIONS,
				 USB51_MODE_BIT | USBIN_MODE_CHG_BIT, icl_opt);
	if (ret)
		return ret;

	ret = chg_write_ua(chg, USBIN_CURRENT_LIMIT_CFG, ua);
	if (ret)
		return ret;

	return regmap_update_bits(chg->regmap, CMD_ICL_OVERRIDE,
				  ICL_OVERRIDE_BIT, ICL_OVERRIDE_BIT);
}

static int chg_enable_path(struct pm8150b_chg *chg)
{
	int ret;

	ret = regmap_update_bits(chg->regmap, USBIN_CMD_IL, USBIN_SUSPEND_BIT, 0);
	if (ret)
		return ret;

	return regmap_update_bits(chg->regmap, CHARGING_ENABLE_CMD,
				  CHARGING_ENABLE_CMD_BIT,
				  CHARGING_ENABLE_CMD_BIT);
}

static void chg_status_work(struct work_struct *work)
{
	struct pm8150b_chg *chg = container_of(work, struct pm8150b_chg,
					       status_work.work);
	unsigned int apsd, result;
	int online = 0, icl = ICL_5V_MAX_UA, ret, tries;

	ret = chg_usb_online(chg, &online);
	if (ret || !online) {
		power_supply_changed(chg->psy);
		return;
	}

	if (chg_enable_path(chg))
		dev_warn(chg->dev, "enable path failed\n");

	for (tries = 0; tries < 8; tries++) {
		ret = regmap_read(chg->regmap, APSD_STATUS, &apsd);
		if (ret)
			break;
		if (apsd & APSD_DTC_STATUS_DONE_BIT)
			break;
		msleep(100);
	}

	if (ret || !(apsd & APSD_DTC_STATUS_DONE_BIT)) {
		regmap_update_bits(chg->regmap, CMD_APSD, APSD_RERUN_BIT,
				   APSD_RERUN_BIT);
		schedule_delayed_work(&chg->status_work, msecs_to_jiffies(1000));
		return;
	}

	ret = regmap_read(chg->regmap, APSD_RESULT_STATUS, &result);
	if (ret)
		return;
	result &= APSD_RESULT_STATUS_MASK;

	/*
	 * 5 V path: ICL 2 A. USB51 (500 mA) mode would cap even DCP bricks
	 * that APSD as SDP. AICL can still fold if the cable collapses.
	 */
	icl = ICL_5V_MAX_UA;

	chg_set_icl(chg, icl);
	dev_info(chg->dev, "apsd=0x%02x icl=%d uA\n", result, icl);
	power_supply_changed(chg->psy);
}

static irqreturn_t chg_plugin_irq(int irq, void *data)
{
	struct pm8150b_chg *chg = data;

	schedule_delayed_work(&chg->status_work, msecs_to_jiffies(200));
	return IRQ_HANDLED;
}

static irqreturn_t chg_wdog_irq(int irq, void *data)
{
	struct pm8150b_chg *chg = data;

	regmap_write(chg->regmap, BARK_BITE_WDOG_PET, BARK_BITE_WDOG_PET_BIT);
	return IRQ_HANDLED;
}

static int chg_get_property(struct power_supply *psy,
			    enum power_supply_property psp,
			    union power_supply_propval *val)
{
	struct pm8150b_chg *chg = power_supply_get_drvdata(psy);
	unsigned int stat;
	int ret, online;

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		return chg_usb_online(chg, &val->intval);
	case POWER_SUPPLY_PROP_STATUS:
		ret = chg_usb_online(chg, &online);
		if (ret)
			return ret;
		if (!online) {
			val->intval = POWER_SUPPLY_STATUS_DISCHARGING;
			return 0;
		}
		ret = regmap_read(chg->regmap, BATTERY_CHARGER_STATUS_1, &stat);
		if (ret)
			return ret;
		switch (stat & BATTERY_CHARGER_STATUS_MASK) {
		case TRICKLE_CHARGE:
		case PRE_CHARGE:
		case FULLON_CHARGE:
		case TAPER_CHARGE:
			val->intval = POWER_SUPPLY_STATUS_CHARGING;
			break;
		case TERMINATE_CHARGE:
		case INHIBIT_CHARGE:
			val->intval = POWER_SUPPLY_STATUS_FULL;
			break;
		default:
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;
			break;
		}
		return 0;
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT:
		ret = regmap_read(chg->regmap, CHGR_FAST_CHARGE_CURRENT_CFG, &stat);
		if (ret)
			return ret;
		val->intval = stat * CURRENT_STEP_UA;
		return 0;
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		ret = regmap_read(chg->regmap, USBIN_CURRENT_LIMIT_CFG, &stat);
		if (ret)
			return ret;
		val->intval = stat * CURRENT_STEP_UA;
		return 0;
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE:
		ret = regmap_read(chg->regmap, CHGR_FLOAT_VOLTAGE_CFG, &stat);
		if (ret)
			return ret;
		val->intval = FV_MIN_UV + stat * FV_STEP_UV;
		return 0;
	case POWER_SUPPLY_PROP_USB_TYPE:
		ret = chg_usb_online(chg, &online);
		if (ret || !online) {
			val->intval = POWER_SUPPLY_USB_TYPE_UNKNOWN;
			return 0;
		}
		ret = regmap_read(chg->regmap, APSD_RESULT_STATUS, &stat);
		if (ret)
			return ret;
		stat &= APSD_RESULT_STATUS_MASK;
		if (stat & CDP_CHARGER_BIT)
			val->intval = POWER_SUPPLY_USB_TYPE_CDP;
		else if (stat & SDP_CHARGER_BIT)
			val->intval = POWER_SUPPLY_USB_TYPE_SDP;
		else if (stat)
			val->intval = POWER_SUPPLY_USB_TYPE_DCP;
		else
			val->intval = POWER_SUPPLY_USB_TYPE_UNKNOWN;
		return 0;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "pm8150b-smb5";
		return 0;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "qualcomm";
		return 0;
	default:
		return -EINVAL;
	}
}

static const enum power_supply_property chg_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT,
	POWER_SUPPLY_PROP_CONSTANT_CHARGE_VOLTAGE,
	POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,
	POWER_SUPPLY_PROP_USB_TYPE,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};

static const struct power_supply_desc chg_desc = {
	.name = "pm8150b-charger",
	.type = POWER_SUPPLY_TYPE_USB,
	.usb_types = BIT(POWER_SUPPLY_USB_TYPE_SDP) |
		     BIT(POWER_SUPPLY_USB_TYPE_DCP) |
		     BIT(POWER_SUPPLY_USB_TYPE_CDP) |
		     BIT(POWER_SUPPLY_USB_TYPE_UNKNOWN),
	.properties = chg_props,
	.num_properties = ARRAY_SIZE(chg_props),
	.get_property = chg_get_property,
};

static int chg_hw_init(struct pm8150b_chg *chg)
{
	int ret;
	unsigned int fv;

	ret = regmap_write(chg->regmap, SNARL_BARK_BITE_WD_CFG, 0);
	if (ret)
		return ret;
	ret = regmap_update_bits(chg->regmap, WD_CFG,
				 WATCHDOG_TRIGGER_AFP_EN_BIT |
				 BARK_WDOG_INT_EN_BIT |
				 WDOG_TIMER_EN_ON_PLUGIN_BIT |
				 WDOG_TIMER_EN_BIT, 0);
	if (ret)
		return ret;

	ret = regmap_update_bits(chg->regmap, USBIN_OPTIONS_1_CFG,
				 HVDCP_EN_BIT, 0);
	if (ret)
		return ret;

	ret = regmap_update_bits(chg->regmap, USBIN_ADAPTER_ALLOW_CFG,
				 USBIN_ADAPTER_ALLOW_MASK,
				 USBIN_ADAPTER_ALLOW_5V_TO_12V);
	if (ret)
		return ret;

	ret = regmap_update_bits(chg->regmap, USBIN_AICL_OPTIONS_CFG,
				 SUSPEND_ON_COLLAPSE_USBIN_BIT |
				 USBIN_AICL_EN_BIT,
				 USBIN_AICL_EN_BIT);
	if (ret)
		return ret;

	fv = (FV_TARGET_UV - FV_MIN_UV) / FV_STEP_UV;
	ret = regmap_write(chg->regmap, CHGR_FLOAT_VOLTAGE_CFG, fv);
	if (ret)
		return ret;

	ret = chg_write_ua(chg, CHGR_FAST_CHARGE_CURRENT_CFG, FCC_UA);
	if (ret)
		return ret;

	return chg_enable_path(chg);
}

static int chg_probe(struct platform_device *pdev)
{
	struct power_supply_config psy_cfg = {};
	struct pm8150b_chg *chg;
	int irq, ret;

	chg = devm_kzalloc(&pdev->dev, sizeof(*chg), GFP_KERNEL);
	if (!chg)
		return -ENOMEM;

	chg->dev = &pdev->dev;
	chg->regmap = dev_get_regmap(pdev->dev.parent, NULL);
	if (!chg->regmap)
		return dev_err_probe(&pdev->dev, -ENODEV, "regmap\n");

	ret = chg_hw_init(chg);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "hw init\n");

	ret = devm_delayed_work_autocancel(&pdev->dev, &chg->status_work,
					   chg_status_work);
	if (ret)
		return ret;

	psy_cfg.drv_data = chg;
	psy_cfg.fwnode = dev_fwnode(&pdev->dev);
	chg->psy = devm_power_supply_register(&pdev->dev, &chg_desc, &psy_cfg);
	if (IS_ERR(chg->psy))
		return PTR_ERR(chg->psy);

	irq = platform_get_irq_byname_optional(pdev, "usb-plugin");
	if (irq > 0) {
		ret = devm_request_threaded_irq(&pdev->dev, irq, NULL,
						chg_plugin_irq, IRQF_ONESHOT,
						"usb-plugin", chg);
		if (ret)
			return dev_err_probe(&pdev->dev, ret, "usb-plugin irq\n");
		chg->plugin_irq = irq;
		devm_device_init_wakeup(&pdev->dev);
		dev_pm_set_wake_irq(&pdev->dev, irq);
	}

	irq = platform_get_irq_byname_optional(pdev, "wdog-bark");
	if (irq > 0) {
		ret = devm_request_threaded_irq(&pdev->dev, irq, NULL,
						chg_wdog_irq, IRQF_ONESHOT,
						"wdog-bark", chg);
		if (ret)
			dev_warn(&pdev->dev, "wdog-bark irq %d\n", ret);
	}

	platform_set_drvdata(pdev, chg);
	schedule_delayed_work(&chg->status_work, msecs_to_jiffies(500));
	dev_info(&pdev->dev, "SMB5 enabled (FV %u mV, FCC %u mA)\n",
		 FV_TARGET_UV / 1000, FCC_UA / 1000);
	return 0;
}

static const struct of_device_id chg_of_match[] = {
	{ .compatible = "qcom,pm8150b-charger-dagu" },
	{ }
};
MODULE_DEVICE_TABLE(of, chg_of_match);

static struct platform_driver chg_driver = {
	.driver = {
		.name = "pm8150b-charger-dagu",
		.of_match_table = chg_of_match,
	},
	.probe = chg_probe,
};
module_platform_driver(chg_driver);

MODULE_DESCRIPTION("PM8150B SMB5 charger (dagu)");
MODULE_LICENSE("GPL");
