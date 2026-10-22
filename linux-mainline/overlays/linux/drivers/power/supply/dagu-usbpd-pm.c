// SPDX-License-Identifier: GPL-2.0-only
/*
 * Xiaomi dagu charge policy.
 *
 * First PD contract stays 5 V (TCPM will not auto-pick 9 V). This driver
 * then either:
 *   - PPS: request 2 * VBAT + 700 mV, stop the SMB5 buck, tune VBUS,
 *     enable the slave pump then the master, and step 20 mV the way
 *     CAF usbpd_pm_fc2_charge_algo does; or
 *   - fixed PD with a 9 V source PDO: raise the fixed cap to 9 V / 3 A
 *     and leave the buck in charge.
 *
 * Limits come from the stock dagu usbpd_pm node (67 W, 12.4 A pack,
 * 6.2 A bus, 11 V APDO). QC3 is not this path.
 */

#include <linux/delay.h>
#include <linux/string.h>
#include <linux/kernel.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/workqueue.h>

/* Matches TCPM's private tcpm_psy_online_states. */
#define DAGU_TCPM_FIXED		1
#define DAGU_TCPM_PPS		2

#define DAGU_TCPM_PSY		"tcpm-source-psy-c440000.spmi:pmic@2:typec@1500"
#define DAGU_MIN_VBAT_MV	3500
#define DAGU_VBUS_HEADROOM_MV	700
#define DAGU_STEP_MV		20
#define DAGU_TAPER_MA		2200
#define DAGU_TAPER_FFC_MA	2600
#define DAGU_TAPER_VOL_HYS	80
#define DAGU_TAPER_POLLS	50
#define DAGU_HIGH_VBAT_MV	4380
#define DAGU_CRIT_VBAT_MV	4480
#define DAGU_CAP_HIGH		90
#define DAGU_APDO_MAX_MV	11000
/* Request may lead the pump reading by this much. Past it the source is
 * already in current limit; 11 V on the contract does not raise IBUS.
 */
#define DAGU_VBUS_FOLLOW_MV	1000
#define DAGU_THERM_LEVELS	16
#define DAGU_THERM_EXIT		12
#define DAGU_THERM_DUAL		9
#define DAGU_MASTER_FCC_MA	6000
#define DAGU_SLAVE_IBUS_MA	2500
#define DAGU_SLAVE_IBUS_HYS	200
#define DAGU_SLAVE_LOW_CNT	40
#define DAGU_JEITA_COOL		50
#define DAGU_JEITA_COOL_HYS	2
#define DAGU_JEITA_WARM_HYS	21
#define DAGU_JEITA_HOT_FV_UV	4100000
#define DAGU_JEITA_HOT_HYS_UV	5000
#define DAGU_JEITA_RECOVER_UV	4000000

/* Stock qcom,thermal-fcc-pps-bq, microamps. Level >= 12 leaves the pumps. */
static const u32 dagu_pps_fcc_ua[DAGU_THERM_LEVELS] = {
	12400000, 10000000, 8800000, 8000000, 7000000, 6000000, 5600000, 5000000,
	4000000, 3000000, 2500000, 2000000, 1400000, 1000000, 700000, 300000,
};
#define DAGU_FIXED_9V_UV	9000000

enum dagu_pm_state {
	DAGU_PM_IDLE,
	DAGU_PM_ARM,
	DAGU_PM_TUNE,
	DAGU_PM_RUN,
	DAGU_PM_RAMP,
};

struct dagu_pdpm {
	struct device *dev;
	struct delayed_work work;
	struct power_supply *tcpm;
	struct power_supply *buck;
	struct power_supply *master;
	struct power_supply *slave;
	struct power_supply *bms;
	enum dagu_pm_state state;
	bool tried_9v;
	bool jeita_block;
	bool no_slave;
	bool qc3;
	int qc_pulses;
	int slave_low_cnt;
	int v_req_mv;
	int i_req_ma;
	int v_sent_mv;
	int i_sent_ma;
	int fcc_ma;
	int tune_tries;
	int taper_cnt;
	u32 power_max_w;
	u32 bat_volt_max_mv;
	u32 bat_curr_max_ma;
	u32 bus_volt_max_mv;
	u32 bus_curr_max_ma;
	u32 bus_curr_comp_ma;
	u32 non_ffc_mv;
	u32 warm_deci;
	u32 cell_high_mv;
	u32 cell_max_mv;
	u32 high_vol_curr_ma;
	u32 therm_exit;
	u32 qc3_bat_volt_mv;
	u32 qc3_bat_curr_ma;
	u32 qc3_bus_curr_ma;
	u32 pps_fcc_ua[DAGU_THERM_LEVELS];
};

int pm8150b_dagu_qc3_prepare(void);
int pm8150b_dagu_qc_pulse(int dir);
void pm8150b_dagu_qc3_stop(void);

static int dagu_psy_get(struct power_supply *psy, enum power_supply_property psp,
			int *out)
{
	union power_supply_propval val = {};
	int ret;

	if (!psy)
		return -ENODEV;
	ret = power_supply_get_property(psy, psp, &val);
	if (ret)
		return ret;
	*out = val.intval;
	return 0;
}

static int dagu_psy_set(struct power_supply *psy, enum power_supply_property psp,
			int v)
{
	union power_supply_propval val = { .intval = v };

	if (!psy)
		return -ENODEV;
	return power_supply_set_property(psy, psp, &val);
}

static void dagu_find(struct dagu_pdpm *pm)
{
	if (!pm->tcpm)
		pm->tcpm = power_supply_get_by_name(DAGU_TCPM_PSY);
	if (!pm->buck)
		pm->buck = power_supply_get_by_name("pm8150b-charger");
	if (!pm->master)
		pm->master = power_supply_get_by_name("bq2597x-master");
	if (!pm->slave)
		pm->slave = power_supply_get_by_name("bq2597x-slave");
	if (!pm->bms)
		pm->bms = power_supply_get_by_name("bms");
}

static void dagu_pumps(struct dagu_pdpm *pm, bool on)
{
	dagu_psy_set(pm->slave, POWER_SUPPLY_PROP_ONLINE, on);
	if (on)
		msleep(30);
	dagu_psy_set(pm->master, POWER_SUPPLY_PROP_ONLINE, on);
}

static void dagu_buck(struct dagu_pdpm *pm, bool on)
{
	/*
	 * CONSTANT_CHARGE_CURRENT 0 holds SMB5 off. CHARGE_CONTROL_LIMIT
	 * stays the thermal level, the same property stock usbpd_pm reads.
	 */
	dagu_psy_set(pm->buck, POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT,
		     on ? 3000000 : 0);
}

static int dagu_therm_level(struct dagu_pdpm *pm)
{
	int level = 0;

	if (dagu_psy_get(pm->buck, POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT,
			 &level) || level < 0)
		return 0;
	if (level >= DAGU_THERM_LEVELS)
		return DAGU_THERM_LEVELS - 1;
	return level;
}

/* Stock pd_disable_cp_by_jeita_status(), temperatures in 0.1 °C. */
static bool dagu_jeita_blocks(struct dagu_pdpm *pm, int vbat_mv, int deci)
{
	int vbat_uv = vbat_mv * 1000;

	if (!pm->jeita_block) {
		if (deci >= pm->warm_deci &&
		    vbat_uv > DAGU_JEITA_HOT_FV_UV - DAGU_JEITA_HOT_HYS_UV)
			pm->jeita_block = true;
		else if (deci <= DAGU_JEITA_COOL)
			pm->jeita_block = true;
	} else if ((deci <= pm->warm_deci - DAGU_JEITA_WARM_HYS ||
		    vbat_uv <= DAGU_JEITA_RECOVER_UV) &&
		   deci >= DAGU_JEITA_COOL + DAGU_JEITA_COOL_HYS) {
		pm->jeita_block = false;
	}
	return pm->jeita_block;
}

static int dagu_request_pps(struct dagu_pdpm *pm, bool kick)
{
	int ret;

	if (kick) {
		ret = dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_ONLINE,
				   DAGU_TCPM_PPS);
		if (ret)
			return ret;
	}
	{
		int src_ua = 0;

		if (!dagu_psy_get(pm->tcpm, POWER_SUPPLY_PROP_CURRENT_MAX,
				  &src_ua) && src_ua / 1000 > 0 &&
		    pm->i_req_ma > src_ua / 1000)
			pm->i_req_ma = src_ua / 1000;
	}
	/*
	 * Voltage first, at the current contract current (2 A at 5 V is
	 * already above 10 W). A 200 mA CURRENT_NOW is -EINVAL and used
	 * to abort before VOLTAGE_NOW was ever written.
	 */
	/*
	 * PPS steps are 20 mV / 50 mA. Repeating the same point restarts
	 * the contract and the source sags while it transitions.
	 */
	if (!kick &&
	    pm->v_req_mv - (pm->v_req_mv % DAGU_STEP_MV) == pm->v_sent_mv &&
	    pm->i_req_ma - (pm->i_req_ma % 50) == pm->i_sent_ma)
		return 0;
	ret = dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_NOW,
			   pm->v_req_mv * 1000);
	if (ret)
		return ret;
	pm->v_sent_mv = pm->v_req_mv - (pm->v_req_mv % DAGU_STEP_MV);
	ret = dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_CURRENT_NOW,
			   pm->i_req_ma * 1000);
	if (!ret)
		pm->i_sent_ma = pm->i_req_ma - (pm->i_req_ma % 50);
	if (ret)
		dev_info(pm->dev, "pps current %d mA not accepted (%d)\n",
			 pm->i_req_ma, ret);
	return 0;
}

static int dagu_pack_mv(struct dagu_pdpm *pm, int *mv, int *deci, int *cap)
{
	int uv, ret;

	ret = dagu_psy_get(pm->bms, POWER_SUPPLY_PROP_VOLTAGE_NOW, &uv);
	if (ret)
		return ret;
	*mv = uv / 1000;
	if (dagu_psy_get(pm->bms, POWER_SUPPLY_PROP_TEMP, deci))
		*deci = 250;
	if (dagu_psy_get(pm->bms, POWER_SUPPLY_PROP_CAPACITY, cap))
		*cap = 0;
	return 0;
}

static bool dagu_pack_ok(struct dagu_pdpm *pm, int mv, int deci, int cap)
{
	if (mv < DAGU_MIN_VBAT_MV || mv > pm->bat_volt_max_mv)
		return false;
	if (cap >= DAGU_CAP_HIGH)
		return false;
	if (dagu_jeita_blocks(pm, mv, deci))
		return false;
	if (dagu_therm_level(pm) >= pm->therm_exit)
		return false;
	return true;
}

static void dagu_ibus_target(struct dagu_pdpm *pm, int vbat_mv)
{
	int level = dagu_therm_level(pm);
	int fcc = pm->qc3 ? pm->qc3_bat_curr_ma : pm->pps_fcc_ua[level] / 1000;
	int ibus;
	int src_ua = 0;

	fcc = min_t(int, fcc, pm->qc3 ? pm->qc3_bat_curr_ma : pm->bat_curr_max_ma);
	if (pm->no_slave || level >= DAGU_THERM_DUAL)
		fcc = min_t(int, fcc, DAGU_MASTER_FCC_MA);
	if (vbat_mv > pm->cell_high_mv)
		fcc = min_t(int, fcc, pm->high_vol_curr_ma);
	ibus = (fcc / 2) + pm->bus_curr_comp_ma;
	ibus = min_t(int, ibus, pm->qc3 ? pm->qc3_bus_curr_ma : pm->bus_curr_max_ma);
	/*
	 * v_req_mv is millivolts. 67 W at 8128 mV is 8243 mA.
	 * Dividing by mV as if it were volts yielded ~8 mA, which the
	 * 200 mA floor then sent to TCPM. TCPM rejects any point below
	 * op-sink-microwatt (10 W), so the PPS voltage never moved.
	 */
	if (pm->v_req_mv > 0)
		ibus = min_t(int, ibus,
			     (int)(pm->power_max_w * 1000000U / pm->v_req_mv));
	if (!dagu_psy_get(pm->tcpm, POWER_SUPPLY_PROP_CURRENT_MAX, &src_ua) &&
	    src_ua > 0)
		ibus = min_t(int, ibus, src_ua / 1000);
	if (ibus < 200)
		ibus = 200;
	pm->fcc_ma = fcc;
	pm->i_req_ma = ibus;
}

static int dagu_ibus_ma(struct dagu_pdpm *pm)
{
	int a = 0, b = 0;

	dagu_psy_get(pm->master, POWER_SUPPLY_PROP_CURRENT_AVG, &a);
	dagu_psy_get(pm->slave, POWER_SUPPLY_PROP_CURRENT_AVG, &b);
	return (a + b) / 1000;
}

static int dagu_vbus_mv(struct dagu_pdpm *pm)
{
	int uv = 0;

	if (dagu_psy_get(pm->master, POWER_SUPPLY_PROP_VOLTAGE_AVG, &uv))
		return 0;
	return uv / 1000;
}

static void dagu_leave(struct dagu_pdpm *pm)
{
	dagu_pumps(pm, false);
	if (pm->qc3)
		pm8150b_dagu_qc3_stop();
	dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_ONLINE, DAGU_TCPM_FIXED);
	dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_MAX, 5000000);
	dagu_buck(pm, true);
	pm->state = DAGU_PM_IDLE;
	pm->tune_tries = 0;
	pm->taper_cnt = 0;
	pm->slave_low_cnt = 0;
	pm->no_slave = false;
	pm->qc3 = false;
	pm->tried_9v = false;
	pm->v_sent_mv = -1;
	pm->i_sent_ma = -1;
}

/* QC3: one D+ pulse is +200 mV. Stop at 23 pulses (~9.6 V) like stock. */
static bool dagu_qc3_step(struct dagu_pdpm *pm, int vbat, int deci, int cap)
{
	int qc, vbus, expect, target, pulses = pm->qc_pulses;

	qc = pm8150b_dagu_qc3_prepare();
	if (qc == -EAGAIN)
		return true;
	if (qc != 1) {
		if (pm->qc3)
			dagu_leave(pm);
		return false;
	}
	if (!pm->qc3) {
		if (!pm->master || !dagu_pack_ok(pm, vbat, deci, cap))
			return false;
		pm->qc3 = true;
		pm->qc_pulses = 0;
		pm->tune_tries = 0;
		pm->state = DAGU_PM_TUNE;
		dagu_buck(pm, false);
		dagu_ibus_target(pm, vbat);
		return true;
	}
	if (!dagu_pack_ok(pm, vbat, deci, cap))
		pm->state = DAGU_PM_RAMP;

	target = 2 * vbat + DAGU_VBUS_HEADROOM_MV;
	vbus = dagu_vbus_mv(pm);
	expect = 5000 + pm->qc_pulses * 200;
	if (pm->qc_pulses >= 8 &&
	    ((vbus > 0 && vbus <= 5500 && expect >= 6600) || vbus <= 0)) {
		dev_info(pm->dev, "qc3 did not raise vbus (%d mV), stay on buck\n",
			 vbus);
		dagu_leave(pm);
		return true;
	}

	switch (pm->state) {
	case DAGU_PM_TUNE:
		if (vbus > 3000 && vbus < target - 50 && pm->qc_pulses < 23)
			pulses = pm8150b_dagu_qc_pulse(1);
		else if (vbus > target + 200)
			pulses = pm8150b_dagu_qc_pulse(-1);
		else if (vbus > 3000) {
			pm->no_slave = dagu_therm_level(pm) >= DAGU_THERM_DUAL ||
				       cap >= DAGU_CAP_HIGH;
			dagu_pumps(pm, !pm->no_slave);
			if (pm->no_slave)
				dagu_psy_set(pm->master, POWER_SUPPLY_PROP_ONLINE, 1);
			dev_info(pm->dev, "qc3 pumps vbus=%d pulses=%d\n",
				 vbus, pm->qc_pulses);
			pm->state = DAGU_PM_RUN;
			break;
		} else {
			pulses = pm8150b_dagu_qc_pulse(1);
		}
		if (pulses >= 0)
			pm->qc_pulses = pulses;
		else if (pulses == -ERANGE)
			dagu_leave(pm);
		break;
	case DAGU_PM_RUN:
		dagu_ibus_target(pm, vbat);
		if (dagu_ibus_ma(pm) > pm->i_req_ma + 50 || vbat > pm->qc3_bat_volt_mv)
			pulses = pm8150b_dagu_qc_pulse(-1);
		else if (vbus > 3000 && vbus < target - 50)
			pulses = pm8150b_dagu_qc_pulse(1);
		else
			pulses = pm->qc_pulses;
		if (pulses >= 0)
			pm->qc_pulses = pulses;
		if (vbat > pm->qc3_bat_volt_mv - 80 &&
		    dagu_ibus_ma(pm) > 0 && dagu_ibus_ma(pm) < DAGU_TAPER_MA) {
			if (++pm->taper_cnt >= DAGU_TAPER_POLLS)
				pm->state = DAGU_PM_RAMP;
		} else {
			pm->taper_cnt = 0;
		}
		break;
	case DAGU_PM_RAMP:
		dagu_pumps(pm, false);
		pulses = pm8150b_dagu_qc_pulse(-1);
		if (pulses >= 0)
			pm->qc_pulses = pulses;
		if (pm->qc_pulses == 0 || (vbus > 0 && vbus < 5500))
			dagu_leave(pm);
		break;
	default:
		pm->state = DAGU_PM_TUNE;
		break;
	}
	return true;
}

static void dagu_pdpm_work(struct work_struct *work)
{
	struct dagu_pdpm *pm = container_of(work, struct dagu_pdpm, work.work);
	int usb_type = POWER_SUPPLY_USB_TYPE_UNKNOWN;
	int online = 0, vbat = 0, deci = 250, cap = 0;
	int vbus, ibus, ibat = 0, step;
	unsigned int delay = 500;

	dagu_find(pm);
	if (!pm->tcpm || !pm->bms || !pm->buck) {
		schedule_delayed_work(&pm->work, msecs_to_jiffies(1000));
		return;
	}

	dagu_psy_get(pm->tcpm, POWER_SUPPLY_PROP_ONLINE, &online);
	dagu_psy_get(pm->tcpm, POWER_SUPPLY_PROP_USB_TYPE, &usb_type);
	if (!online || dagu_pack_mv(pm, &vbat, &deci, &cap)) {
		if (pm->state != DAGU_PM_IDLE)
			dagu_leave(pm);
		schedule_delayed_work(&pm->work, msecs_to_jiffies(500));
		return;
	}

	if (usb_type != POWER_SUPPLY_USB_TYPE_PD &&
	    usb_type != POWER_SUPPLY_USB_TYPE_PD_PPS &&
	    dagu_qc3_step(pm, vbat, deci, cap)) {
		schedule_delayed_work(&pm->work, msecs_to_jiffies(200));
		return;
	}

	if (usb_type != POWER_SUPPLY_USB_TYPE_PD_PPS) {
		if (pm->state != DAGU_PM_IDLE)
			dagu_leave(pm);
		/*
		 * Non-PPS PD: 9 V / 3 A on the buck when the source
		 * advertises it. The fixed cap stays 5 V until asked.
		 */
		if (usb_type == POWER_SUPPLY_USB_TYPE_PD && !pm->tried_9v &&
		    vbat >= DAGU_MIN_VBAT_MV && vbat < pm->bat_volt_max_mv) {
			pm->tried_9v = true;
			dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_MAX,
				     DAGU_FIXED_9V_UV);
		}
		schedule_delayed_work(&pm->work, msecs_to_jiffies(500));
		return;
	}

	if (!dagu_pack_ok(pm, vbat, deci, cap)) {
		if (pm->state == DAGU_PM_RUN || pm->state == DAGU_PM_TUNE)
			pm->state = DAGU_PM_RAMP;
		else if (pm->state == DAGU_PM_ARM)
			dagu_leave(pm);
	}

	switch (pm->state) {
	case DAGU_PM_IDLE:
		if (!pm->master || !dagu_pack_ok(pm, vbat, deci, cap))
			break;
		pm->v_req_mv = 2 * vbat + DAGU_VBUS_HEADROOM_MV;
		if (pm->v_req_mv > DAGU_APDO_MAX_MV)
			pm->v_req_mv = DAGU_APDO_MAX_MV;
		dagu_ibus_target(pm, vbat);
		pm->tune_tries = 0;
		pm->state = DAGU_PM_ARM;
		delay = 200;
		break;

	case DAGU_PM_ARM:
		if (dagu_request_pps(pm, true)) {
			if (++pm->tune_tries > 15) {
				dev_info(pm->dev, "pps request %d mV failed\n",
					 pm->v_req_mv);
				dagu_leave(pm);
			}
			delay = 500;
			break;
		}
		pm->tune_tries = 0;
		dagu_buck(pm, false);
		pm->state = DAGU_PM_TUNE;
		delay = 200;
		break;

	case DAGU_PM_TUNE:
		/*
		 * Prefer the PD contract. The pump ADC is only used when
		 * it agrees, so a bad scale cannot enable the pumps at 5 V.
		 */
		dagu_psy_get(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_NOW, &vbus);
		vbus /= 1000;
		{
			int pump_mv = dagu_vbus_mv(pm);

			if (pump_mv > 3000 && abs(pump_mv - vbus) < 1500)
				vbus = pump_mv;
		}
		if (vbus < 2 * vbat + DAGU_VBUS_HEADROOM_MV - 50)
			pm->v_req_mv += DAGU_STEP_MV;
		else if (vbus > 2 * vbat + DAGU_VBUS_HEADROOM_MV + 200)
			pm->v_req_mv -= DAGU_STEP_MV;
		else {
			pm->no_slave = dagu_therm_level(pm) >= DAGU_THERM_DUAL ||
				       cap >= DAGU_CAP_HIGH;
			if (pm->no_slave)
				dagu_psy_set(pm->slave, POWER_SUPPLY_PROP_ONLINE, 0);
			dagu_pumps(pm, !pm->no_slave);
			if (pm->no_slave)
				dagu_psy_set(pm->master, POWER_SUPPLY_PROP_ONLINE, 1);
			dev_info(pm->dev, "pumps on vbus=%d vbat=%d ireq=%d slave=%d\n",
				 vbus, vbat, pm->i_req_ma, !pm->no_slave);
			pm->state = DAGU_PM_RUN;
			delay = 200;
			break;
		}
		if (++pm->tune_tries > 80 || pm->v_req_mv > pm->bus_volt_max_mv) {
			dev_info(pm->dev, "vbus tune failed, stay on buck\n");
			dagu_leave(pm);
			break;
		}
		dagu_request_pps(pm, false);
		delay = 200;
		break;

	case DAGU_PM_RUN:
		{
			int hm = 0, hs = 0;

			dagu_psy_get(pm->master, POWER_SUPPLY_PROP_HEALTH, &hm);
			dagu_psy_get(pm->slave, POWER_SUPPLY_PROP_HEALTH, &hs);
			if (hm == POWER_SUPPLY_HEALTH_UNSPEC_FAILURE ||
			    hs == POWER_SUPPLY_HEALTH_UNSPEC_FAILURE) {
				dev_info(pm->dev, "pump fault, exit to buck\n");
				pm->state = DAGU_PM_RAMP;
				break;
			}
		}
		dagu_ibus_target(pm, vbat);
		ibus = dagu_ibus_ma(pm);
		if (!pm->no_slave && ibus <= DAGU_SLAVE_IBUS_MA) {
			if (++pm->slave_low_cnt >= DAGU_SLAVE_LOW_CNT) {
				pm->no_slave = true;
				dagu_psy_set(pm->slave, POWER_SUPPLY_PROP_ONLINE, 0);
			}
		} else if (pm->no_slave && cap < DAGU_CAP_HIGH &&
			   dagu_therm_level(pm) < DAGU_THERM_DUAL &&
			   ibus > DAGU_SLAVE_IBUS_MA + DAGU_SLAVE_IBUS_HYS) {
			pm->no_slave = false;
			pm->slave_low_cnt = 0;
			dagu_psy_set(pm->slave, POWER_SUPPLY_PROP_ONLINE, 1);
		} else if (ibus > DAGU_SLAVE_IBUS_MA) {
			pm->slave_low_cnt = 0;
		}
		dagu_psy_get(pm->master, POWER_SUPPLY_PROP_CURRENT_NOW, &ibat);
		ibat /= 1000;
		/*
		 * Stock fc2_charge_algo: each loop votes +1, 0 or -1, and
		 * the voltage step is the minimum. VBAT regulation backs
		 * off by 3 steps. A bus alarm backs off by 1.
		 */
		{
			int step_vbat = 0, step_ibus = 0, step_ibat = 0;
			int step_reg = 1, step_hw = 1, health = 0;

			if (vbat > pm->bat_volt_max_mv)
				step_vbat = -1;
			else if (vbat < pm->bat_volt_max_mv - 10)
				step_vbat = 1;
			if (ibat < pm->fcc_ma)
				step_ibat = 1;
			else if (ibat > pm->fcc_ma + 50)
				step_ibat = -1;
			if (ibus < pm->i_req_ma + 20)
				step_ibus = 1;
			else if (ibus > pm->i_req_ma + 50)
				step_ibus = -1;
			if (!dagu_psy_get(pm->master, POWER_SUPPLY_PROP_HEALTH,
					 &health)) {
				if (health == POWER_SUPPLY_HEALTH_OVERVOLTAGE)
					step_reg = -3;
				else if (health == POWER_SUPPLY_HEALTH_OVERHEAT)
					step_hw = -1;
			}
			step = min(min(step_vbat, step_ibus), step_ibat);
			step = min(step, min(step_reg, step_hw));
		}
		{
			int meas = dagu_vbus_mv(pm);
			int apdo = DAGU_APDO_MAX_MV;
			int src_uv = 0;

			/*
			 * Pump bus stopped following the request. Keep
			 * stepping down until the contract is within
			 * DAGU_VBUS_FOLLOW_MV of the measured bus.
			 */
			if (meas > 3000 &&
			    pm->v_req_mv > meas + DAGU_VBUS_FOLLOW_MV)
				step = min(step, -1);
			pm->v_req_mv += step * DAGU_STEP_MV;
			if (!dagu_psy_get(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_MAX,
					  &src_uv) && src_uv / 1000 > 5000)
				apdo = min_t(int, apdo, src_uv / 1000);
			if (apdo > DAGU_STEP_MV)
				apdo -= DAGU_STEP_MV;
			if (pm->v_req_mv < 2 * vbat)
				pm->v_req_mv = 2 * vbat;
			if (pm->v_req_mv > apdo)
				pm->v_req_mv = apdo;
		}
		dagu_request_pps(pm, false);
		if (vbat > pm->bat_volt_max_mv - DAGU_TAPER_VOL_HYS &&
		    ibat > 0 && ibat < DAGU_TAPER_FFC_MA) {
			if (++pm->taper_cnt >= DAGU_TAPER_POLLS)
				pm->state = DAGU_PM_RAMP;
		} else {
			pm->taper_cnt = 0;
		}
		if (vbat >= DAGU_CRIT_VBAT_MV && !pm->no_slave)
			delay = 100;
		else if (vbat >= DAGU_HIGH_VBAT_MV)
			delay = 200;
		else
			delay = 500;
		break;

	case DAGU_PM_RAMP:
		dagu_pumps(pm, false);
		pm->v_req_mv -= 500;
		if (pm->v_req_mv < 5500) {
			dev_info(pm->dev, "pps exit to 5 V buck\n");
			dagu_leave(pm);
			break;
		}
		dagu_request_pps(pm, false);
		delay = 500;
		break;
	}

	schedule_delayed_work(&pm->work, msecs_to_jiffies(delay));
}

static int dagu_pdpm_probe(struct platform_device *pdev)
{
	struct dagu_pdpm *pm;
	struct device_node *np = pdev->dev.of_node;

	pm = devm_kzalloc(&pdev->dev, sizeof(*pm), GFP_KERNEL);
	if (!pm)
		return -ENOMEM;
	pm->dev = &pdev->dev;
	pm->power_max_w = 67;
	pm->bat_volt_max_mv = 4480;
	pm->bat_curr_max_ma = 12400;
	pm->bus_volt_max_mv = 12000;
	pm->bus_curr_max_ma = 6200;
	pm->bus_curr_comp_ma = 50;
	pm->non_ffc_mv = 4450;
	pm->warm_deci = 480;
	pm->cell_high_mv = 4450;
	pm->cell_max_mv = 4487;
	pm->high_vol_curr_ma = 7840;
	pm->therm_exit = DAGU_THERM_EXIT;
	pm->qc3_bat_volt_mv = 4420;
	pm->qc3_bat_curr_ma = 3600;
	pm->qc3_bus_curr_ma = 2100;
	memcpy(pm->pps_fcc_ua, dagu_pps_fcc_ua, sizeof(pm->pps_fcc_ua));

	of_property_read_u32(np, "mi,pd-power-max", &pm->power_max_w);
	of_property_read_u32(np, "mi,therm-level-threshold", &pm->therm_exit);
	of_property_read_u32(np, "mi,qc3-bat-volt-max", &pm->qc3_bat_volt_mv);
	of_property_read_u32(np, "mi,qc3-bat-curr-max", &pm->qc3_bat_curr_ma);
	of_property_read_u32(np, "mi,qc3-bus-curr-max", &pm->qc3_bus_curr_ma);
	of_property_read_u32_array(np, "mi,thermal-fcc-pps-bq",
				   pm->pps_fcc_ua, DAGU_THERM_LEVELS);
	of_property_read_u32(np, "mi,pd-bat-volt-max", &pm->bat_volt_max_mv);
	of_property_read_u32(np, "mi,pd-bat-curr-max", &pm->bat_curr_max_ma);
	of_property_read_u32(np, "mi,pd-bus-volt-max", &pm->bus_volt_max_mv);
	of_property_read_u32(np, "mi,pd-bus-curr-max", &pm->bus_curr_max_ma);
	of_property_read_u32(np, "mi,pd-bus-curr-compensate", &pm->bus_curr_comp_ma);
	of_property_read_u32(np, "mi,pd-non-ffc-bat-volt-max", &pm->non_ffc_mv);
	of_property_read_u32(np, "mi,pd-battery-warm-th", &pm->warm_deci);
	of_property_read_u32(np, "mi,cell-vol-high-threshold-mv", &pm->cell_high_mv);
	of_property_read_u32(np, "mi,cell-vol-max-threshold-mv", &pm->cell_max_mv);
	of_property_read_u32(np, "mi,step-charge-high-vol-curr-max",
			     &pm->high_vol_curr_ma);

	INIT_DELAYED_WORK(&pm->work, dagu_pdpm_work);
	platform_set_drvdata(pdev, pm);
	schedule_delayed_work(&pm->work, msecs_to_jiffies(2000));
	dev_info(&pdev->dev, "pps policy %u W bus %u mA pack %u mA\n",
		 pm->power_max_w, pm->bus_curr_max_ma, pm->bat_curr_max_ma);
	return 0;
}

static void dagu_pdpm_remove(struct platform_device *pdev)
{
	struct dagu_pdpm *pm = platform_get_drvdata(pdev);

	cancel_delayed_work_sync(&pm->work);
	dagu_leave(pm);
}

static const struct of_device_id dagu_pdpm_of_match[] = {
	{ .compatible = "xiaomi,dagu-usbpd-pm" },
	{ }
};
MODULE_DEVICE_TABLE(of, dagu_pdpm_of_match);

static struct platform_driver dagu_pdpm_driver = {
	.probe = dagu_pdpm_probe,
	.remove = dagu_pdpm_remove,
	.driver = {
		.name = "dagu-usbpd-pm",
		.of_match_table = dagu_pdpm_of_match,
	},
};
module_platform_driver(dagu_pdpm_driver);

MODULE_DESCRIPTION("Xiaomi dagu 67W PPS / 9V PD charge policy");
MODULE_LICENSE("GPL");
