// SPDX-License-Identifier: GPL-2.0-only
/*
 * PM8150B SMB5 charger (Xiaomi dagu).
 *
 * CAF qpnp-smb5-dagu.c is thousands of lines (PD / JEITA / dual-pump policy).
 * This is the 5 V / 9 V buck path only: unsuspend USBIN, enable charge, kick
 * the charger watchdog off, set ICL from TCPM's PD contract (fallback APSD
 * for BC1.2 bricks). Do not touch Type-C @1500 — qcom_pmic_typec owns CC /
 * PD, including crude moisture sensors. Do not copy qcom_smbx (SMB2) scales:
 * PM8150B ICL/FCC is 50 mA/LSB and float is 3.6 V + 10 mV/LSB.
 */

#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/devm-helpers.h>
#include <linux/interrupt.h>
#include <linux/jiffies.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_wakeirq.h>
#include <linux/pm_wakeup.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>
#include <linux/string.h>
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
#define HVDCP_AUTH_ALG_EN_BIT			BIT(6)
#define HVDCP_AUTONOMOUS_MODE_EN_BIT		BIT(5)
#define HVDCP_EN_BIT				BIT(2)

#define CMD_HVDCP_2				(USBIN_BASE + 0x43)
#define FORCE_5V_BIT				BIT(3)
#define SINGLE_DECREMENT_BIT			BIT(1)
#define SINGLE_INCREMENT_BIT			BIT(0)
#define QC3_MAX_PULSES				23

#define QC_3P0_BIT				BIT(6)
#define QC_2P0_BIT				BIT(5)

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
#define FV_TARGET_UV				4480000
#define FCC_UA					3000000
#define THERM_LEVELS				16

/* qcom,thermal-mitigation on stock qpnp-smb5, microamps, level 0..15. */
static const u32 dagu_therm_fcc_ua[THERM_LEVELS] = {
	3000000, 2800000, 2600000, 2400000, 2200000, 2100000, 2000000, 1800000,
	1600000, 1500000, 1400000, 1200000, 1000000, 900000, 800000, 500000,
};
/* qcom,thermal-mitigation-icl. */
static const u32 dagu_therm_icl_ua[THERM_LEVELS] = {
	2800000, 2700000, 2600000, 2400000, 2200000, 2100000, 2000000, 1800000,
	1600000, 1500000, 1400000, 1300000, 1200000, 1100000, 950000, 750000,
};
#define SDP_UA					500000
#define CDP_UA					1500000
#define DCP_UA					2000000
/* USB default while PD negotiates. Type-C Rp-3.0 is not a PD contract. */
#define ICL_USB_DEFAULT_UA			500000
#define ICL_TYPEC_MAX_UA			1500000
/* 5 V wall bricks often APSD as SDP; still allow 2 A (10 W). */
#define ICL_5V_MAX_UA				2000000
/* SMB5 buck PD contract (9 V / 3 A). 67 W PPS stays on BQ25970. */
#define ICL_PD_MAX_UA				3000000
#define TCPM_PSY_PREFIX				"tcpm-source-psy-"
#define ICL_HOLD_MS				800

struct pm8150b_chg {
	struct device *dev;
	struct regmap *regmap;
	struct power_supply *psy;
	struct power_supply *tcpm_psy;
	struct notifier_block psy_nb;
	struct delayed_work status_work;
	int plugin_irq;
	int last_icl;
	int last_uv;
	int last_fcc;
	unsigned long hold_until;
	/* Pump path owns the pack; do not re-enable the buck. */
	bool cp_mode;
	/* Stock CHARGE_CONTROL_LIMIT: index into the thermal FCC/ICL tables. */
	int therm_level;
	u32 therm_fcc_ua[16];
	u32 therm_icl_ua[16];
	int pulse_cnt;
	bool qc3_apsd_once;
	unsigned long qc3_wait_until;
};

static struct pm8150b_chg *dagu_chg;

int pm8150b_dagu_qc3_prepare(void);
int pm8150b_dagu_qc_pulse(int dir);
void pm8150b_dagu_qc3_stop(void);

/*
 * QC3 (Quick Charge 3) rides D+/D-. Only a dedicated charger is allowed
 * to rerun BC1.2; a host on D+/D- is the serial gadget.
 */
int pm8150b_dagu_qc3_prepare(void)
{
	unsigned int result = 0;
	int ret;

	if (!dagu_chg)
		return -ENODEV;
	ret = regmap_read(dagu_chg->regmap, APSD_RESULT_STATUS, &result);
	if (ret)
		return ret;
	result &= APSD_RESULT_STATUS_MASK;
	if (result & QC_3P0_BIT)
		return 1;
	if (result & (SDP_CHARGER_BIT | CDP_CHARGER_BIT))
		return 0;
	if (!(result & DCP_CHARGER_BIT))
		return 0;
	if (!dagu_chg->qc3_apsd_once) {
		dagu_chg->qc3_apsd_once = true;
		dagu_chg->qc3_wait_until = jiffies + 2 * HZ;
		ret = regmap_update_bits(dagu_chg->regmap, USBIN_OPTIONS_1_CFG,
					 HVDCP_AUTH_ALG_EN_BIT |
					 HVDCP_AUTONOMOUS_MODE_EN_BIT |
					 HVDCP_EN_BIT,
					 HVDCP_AUTH_ALG_EN_BIT | HVDCP_EN_BIT);
		if (ret)
			return ret;
		ret = regmap_update_bits(dagu_chg->regmap, CMD_APSD,
					 APSD_RERUN_BIT, APSD_RERUN_BIT);
		if (ret)
			return ret;
		return -EAGAIN;
	}
	if (time_before(jiffies, dagu_chg->qc3_wait_until))
		return -EAGAIN;
	return 0;
}
EXPORT_SYMBOL_GPL(pm8150b_dagu_qc3_prepare);

int pm8150b_dagu_qc_pulse(int dir)
{
	unsigned int bit;
	int ret;

	if (!dagu_chg)
		return -ENODEV;
	if (dir > 0) {
		if (dagu_chg->pulse_cnt >= QC3_MAX_PULSES)
			return -ERANGE;
		bit = SINGLE_INCREMENT_BIT;
	} else if (dir < 0) {
		bit = SINGLE_DECREMENT_BIT;
	} else {
		bit = FORCE_5V_BIT;
	}
	ret = regmap_update_bits(dagu_chg->regmap, CMD_HVDCP_2, bit, bit);
	if (ret)
		return ret;
	if (dir > 0)
		dagu_chg->pulse_cnt++;
	else if (dir < 0 && dagu_chg->pulse_cnt)
		dagu_chg->pulse_cnt--;
	else if (!dir)
		dagu_chg->pulse_cnt = 0;
	return dagu_chg->pulse_cnt;
}
EXPORT_SYMBOL_GPL(pm8150b_dagu_qc_pulse);

void pm8150b_dagu_qc3_stop(void)
{
	if (!dagu_chg)
		return;
	regmap_update_bits(dagu_chg->regmap, CMD_HVDCP_2, FORCE_5V_BIT,
			   FORCE_5V_BIT);
	dagu_chg->pulse_cnt = 0;
	regmap_update_bits(dagu_chg->regmap, USBIN_OPTIONS_1_CFG, HVDCP_EN_BIT, 0);
}
EXPORT_SYMBOL_GPL(pm8150b_dagu_qc3_stop);

static int chg_write_ua(struct pm8150b_chg *chg, unsigned int reg, int ua)
{
	if (ua < 0)
		ua = 0;
	return regmap_write(chg->regmap, reg, ua / CURRENT_STEP_UA);
}

static struct power_supply *chg_tcpm_psy(struct pm8150b_chg *chg)
{
	if (chg->tcpm_psy)
		return chg->tcpm_psy;

	chg->tcpm_psy = power_supply_get_by_name(
		"tcpm-source-psy-c440000.spmi:pmic@2:typec@1500");
	return chg->tcpm_psy;
}

static int chg_tcpm_contract(struct pm8150b_chg *chg, int *ua, int *uv,
			     int *usb_type)
{
	union power_supply_propval online = {}, curr = {}, volt = {}, type = {};
	struct power_supply *psy = chg_tcpm_psy(chg);
	int ret;

	if (!psy)
		return -ENODEV;

	ret = power_supply_get_property(psy, POWER_SUPPLY_PROP_ONLINE, &online);
	if (ret || !online.intval)
		return -ENODATA;
	ret = power_supply_get_property(psy, POWER_SUPPLY_PROP_USB_TYPE, &type);
	if (ret)
		type.intval = POWER_SUPPLY_USB_TYPE_C;
	ret = power_supply_get_property(psy, POWER_SUPPLY_PROP_CURRENT_MAX, &curr);
	if (ret)
		return ret;
	ret = power_supply_get_property(psy, POWER_SUPPLY_PROP_VOLTAGE_NOW, &volt);
	if (ret)
		return ret;
	if (curr.intval <= 0)
		return -ENODATA;
	*ua = curr.intval;
	*uv = volt.intval;
	*usb_type = type.intval;
	return 0;
}

static bool chg_usb_type_pd(int usb_type)
{
	return usb_type == POWER_SUPPLY_USB_TYPE_PD ||
	       usb_type == POWER_SUPPLY_USB_TYPE_PD_PPS;
}

static int chg_typec_icl(struct pm8150b_chg *chg)
{
	if (!chg->hold_until) {
		chg->hold_until = jiffies + msecs_to_jiffies(ICL_HOLD_MS);
		schedule_delayed_work(&chg->status_work,
				      msecs_to_jiffies(ICL_HOLD_MS));
		return ICL_USB_DEFAULT_UA;
	}
	if (time_before(jiffies, chg->hold_until)) {
		schedule_delayed_work(&chg->status_work,
				      chg->hold_until - jiffies);
		return ICL_USB_DEFAULT_UA;
	}
	return ICL_TYPEC_MAX_UA;
}

static int chg_usbin_present(struct pm8150b_chg *chg)
{
	unsigned int stat;
	int ret;

	ret = regmap_read(chg->regmap, USBIN_INT_RT_STS, &stat);
	if (ret)
		return 0;
	if (stat & USBIN_PLUGIN_RT_STS_BIT)
		return 1;

	ret = regmap_read(chg->regmap, POWER_PATH_STATUS, &stat);
	if (ret)
		return 0;
	return !!(stat & VALID_INPUT_POWER_SOURCE_STS_BIT);
}

static int chg_usb_online(struct pm8150b_chg *chg, int *online)
{
	/*
	 * TCPM can still advertise a 5 V / 3 A contract after USBIN has
	 * collapsed (OV+UV). Treating that as online slams ICL and the
	 * power bank never recovers.
	 */
	*online = chg_usbin_present(chg);
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
	unsigned int apsd = 0, result = 0, usbin = 0, path = 0;
	int online = 0, icl = ICL_USB_DEFAULT_UA, ua = 0, uv = 0;
	int usb_type = POWER_SUPPLY_USB_TYPE_UNKNOWN, ret, tries;
	const char *src = "apsd";

	ret = chg_usb_online(chg, &online);
	if (ret || !online) {
		chg->cp_mode = false;
		chg->qc3_apsd_once = false;
		if (chg->last_icl || chg->last_uv) {
			regmap_read(chg->regmap, USBIN_INT_RT_STS, &usbin);
			regmap_read(chg->regmap, POWER_PATH_STATUS, &path);
			dev_info(chg->dev, "input gone usbin=0x%02x path=0x%02x\n",
				 usbin, path);
		}
		chg->last_icl = 0;
		chg->last_uv = 0;
		chg->hold_until = 0;
		chg_set_icl(chg, ICL_USB_DEFAULT_UA);
		power_supply_changed(chg->psy);
		return;
	}

	/*
	 * 67 W PPS holds the buck off. status_work must not turn it
	 * back on while the charge pumps are the battery path.
	 */
	if (chg->cp_mode) {
		regmap_update_bits(chg->regmap, CHARGING_ENABLE_CMD,
				   CHARGING_ENABLE_CMD_BIT, 0);
		power_supply_changed(chg->psy);
		return;
	}

	/*
	 * Limit before unsuspend. Leftover 2 A ICL plus Type-C Rp-3.0
	 * inrush browns a PD bank before Source Caps arrive.
	 */
	if (!chg->last_icl)
		chg_set_icl(chg, ICL_USB_DEFAULT_UA);

	if (chg_enable_path(chg))
		dev_warn(chg->dev, "enable path failed\n");

	/*
	 * PD bricks talk on CC, not D+/D-. Waiting for APSD_DONE spins
	 * forever (ICL stuck at ABL 1 A, USB51) and never applies the
	 * TCPM contract.
	 *
	 * TCPM CURRENT_MAX is 3 A as soon as Rp-3.0 attaches (USB_TYPE
	 * C, not PD). Treating that as a PD contract drew 2 A, then
	 * requested 9 V; tPSTransition dropped VBUS (2.2 V / 2.8 V).
	 * Stay at USB default until USB_TYPE is PD and the current is
	 * above the 500 mA PS_RDY standby. Type-C without PD ramps to
	 * 1.5 A after ICL_HOLD_MS. 5 V PD caps at 2 A; 9 V at 3 A.
	 */
	if (!chg_tcpm_contract(chg, &ua, &uv, &usb_type)) {
		if (chg_usb_type_pd(usb_type) && ua > SDP_UA) {
			src = "pd";
			chg->hold_until = 0;
			if (uv >= 8000000)
				icl = min_t(int, ua, ICL_PD_MAX_UA);
			else
				icl = min_t(int, ua, ICL_5V_MAX_UA);
		} else if (chg->last_uv >= 8000000 && ua <= SDP_UA) {
			src = "pd-hold";
			icl = chg->last_icl;
		} else {
			src = "typec";
			icl = chg_typec_icl(chg);
		}
	} else {
		for (tries = 0; tries < 8; tries++) {
			ret = regmap_read(chg->regmap, APSD_STATUS, &apsd);
			if (ret)
				break;
			if (apsd & APSD_DTC_STATUS_DONE_BIT)
				break;
			msleep(100);
		}

		if (!ret && (apsd & APSD_DTC_STATUS_DONE_BIT)) {
			ret = regmap_read(chg->regmap, APSD_RESULT_STATUS, &result);
			if (!ret)
				result &= APSD_RESULT_STATUS_MASK;
		} else {
			regmap_update_bits(chg->regmap, CMD_APSD, APSD_RERUN_BIT,
					   APSD_RERUN_BIT);
		}
		icl = ICL_5V_MAX_UA;
	}

	if (chg->therm_level < 0)
		chg->therm_level = 0;
	if (chg->therm_level >= THERM_LEVELS)
		chg->therm_level = THERM_LEVELS - 1;
	icl = min_t(int, icl, chg->therm_icl_ua[chg->therm_level]);
	if (chg->therm_fcc_ua[chg->therm_level] != chg->last_fcc) {
		chg_write_ua(chg, CHGR_FAST_CHARGE_CURRENT_CFG,
			     chg->therm_fcc_ua[chg->therm_level]);
		chg->last_fcc = chg->therm_fcc_ua[chg->therm_level];
	}

	if (icl != chg->last_icl || uv != chg->last_uv) {
		chg_set_icl(chg, icl);
		dev_info(chg->dev,
			 "%s type=%d uv=%d ua=%d apsd=0x%02x icl=%d uA\n",
			 src, usb_type, uv, ua, result, icl);
		chg->last_icl = icl;
		chg->last_uv = uv;
		power_supply_changed(chg->psy);
	}
}

static int chg_psy_notifier(struct notifier_block *nb, unsigned long event,
			    void *data)
{
	struct pm8150b_chg *chg = container_of(nb, struct pm8150b_chg, psy_nb);
	struct power_supply *psy = data;

	if (event != PSY_EVENT_PROP_CHANGED || !psy || !psy->desc ||
	    !psy->desc->name)
		return NOTIFY_OK;
	if (strncmp(psy->desc->name, TCPM_PSY_PREFIX, strlen(TCPM_PSY_PREFIX)))
		return NOTIFY_OK;

	schedule_delayed_work(&chg->status_work, msecs_to_jiffies(200));
	return NOTIFY_OK;
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
		{
			int pd_ua, pd_uv, pd_type;

			if (!chg_tcpm_contract(chg, &pd_ua, &pd_uv, &pd_type)) {
				val->intval = chg_usb_type_pd(pd_type) ?
					pd_type : POWER_SUPPLY_USB_TYPE_C;
				return 0;
			}
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
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT:
		val->intval = chg->therm_level;
		return 0;
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT_MAX:
		val->intval = THERM_LEVELS - 1;
		return 0;
	default:
		return -EINVAL;
	}
}

static int chg_set_property(struct power_supply *psy,
			    enum power_supply_property psp,
			    const union power_supply_propval *val)
{
	struct pm8150b_chg *chg = power_supply_get_drvdata(psy);
	int ret = 0;

	switch (psp) {
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT:
		if (val->intval < 0 || val->intval >= THERM_LEVELS)
			return -EINVAL;
		chg->therm_level = val->intval;
		schedule_delayed_work(&chg->status_work, 0);
		break;
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT:
		/* 0 is the pump path. Non-zero hands the pack back to the buck. */
		chg->cp_mode = val->intval <= 0;
		if (chg->cp_mode)
			ret = regmap_update_bits(chg->regmap, CHARGING_ENABLE_CMD,
						 CHARGING_ENABLE_CMD_BIT, 0);
		else
			ret = chg_enable_path(chg);
		break;
	default:
		return -EINVAL;
	}
	return ret;
}

static int chg_prop_writeable(struct power_supply *psy,
			      enum power_supply_property psp)
{
	return psp == POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT ||
	       psp == POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT;
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
	POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT,
	POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT_MAX,
};

static const struct power_supply_desc chg_desc = {
	.name = "pm8150b-charger",
	.type = POWER_SUPPLY_TYPE_USB,
	.usb_types = BIT(POWER_SUPPLY_USB_TYPE_SDP) |
		     BIT(POWER_SUPPLY_USB_TYPE_DCP) |
		     BIT(POWER_SUPPLY_USB_TYPE_CDP) |
		     BIT(POWER_SUPPLY_USB_TYPE_C) |
		     BIT(POWER_SUPPLY_USB_TYPE_PD) |
		     BIT(POWER_SUPPLY_USB_TYPE_PD_PPS) |
		     BIT(POWER_SUPPLY_USB_TYPE_UNKNOWN),
	.properties = chg_props,
	.num_properties = ARRAY_SIZE(chg_props),
	.get_property = chg_get_property,
	.set_property = chg_set_property,
	.property_is_writeable = chg_prop_writeable,
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
	dagu_chg = chg;
	memcpy(chg->therm_fcc_ua, dagu_therm_fcc_ua, sizeof(chg->therm_fcc_ua));
	memcpy(chg->therm_icl_ua, dagu_therm_icl_ua, sizeof(chg->therm_icl_ua));
	of_property_read_u32_array(pdev->dev.of_node, "qcom,thermal-mitigation",
				   chg->therm_fcc_ua, THERM_LEVELS);
	of_property_read_u32_array(pdev->dev.of_node, "qcom,thermal-mitigation-icl",
				   chg->therm_icl_ua, THERM_LEVELS);
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
	chg->psy_nb.notifier_call = chg_psy_notifier;
	ret = power_supply_reg_notifier(&chg->psy_nb);
	if (ret)
		dev_warn(&pdev->dev, "tcpm notifier %d\n", ret);
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
