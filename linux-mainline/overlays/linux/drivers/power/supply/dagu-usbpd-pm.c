// SPDX-License-Identifier: GPL-2.0-only
/*
 * Xiaomi dagu charge policy.
 *
 * First PD contract stays 5 V (TCPM will not auto-pick 9 V). This driver
 * then either:
 *   - Xiaomi UVDM verified and the programmable object above 5 A:
 *     stop the SMB5 buck, request 9.000 V at the unlocked current,
 *     enable the slave pump then the master. The request voltage does
 *     not climb. Factory 2*VBAT+700 mV is the same 9 V gear; walking it
 *     to 10.5 V faulted the pumps; or
 *   - auth failed, current stayed at 5 A, or the pumps fault: fixed
 *     9 V / 3 A and the buck. No 12/15/20 V contract.
 *
 * Limits come from the stock dagu usbpd_pm node (67 W, 12.4 A pack,
 * 6.2 A bus, 11 V APDO). Before the first PPS request this driver
 * sends the Xiaomi unstructured vendor messages (SVID 0x2717) the
 * way batterysecret does, and asks for source caps again only when
 * the charger digest matches. QC3 is not this path.
 */

#include <linux/delay.h>
#include <linux/string.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/minmax.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/random.h>
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
/*
 * Once the request leads the pump reading by this much, the source is
 * already in current limit. Further steps do not raise current; each one
 * is another PPS contract that can miss PS_RDY and hard-reset the port.
 */
#define DAGU_CC_LEAD_MV		1500
/* Source drops PPS if the sink is silent for 10 s. Refresh before that. */
#define DAGU_PPS_KEEPALIVE_MS	4000
/* Stock BQ_TAPER_HYS_MV / BQ_TAPER_DECREASE_STEP_MA_DAGU. */
#define DAGU_CV_HYS_MV		10
#define DAGU_CV_STEP_MA		300
#define DAGU_CV_FCC_FLOOR_MA	2000
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
	bool pps_failed;
	bool mi_done;
	bool mi_verified;
	int mi_tries;
	int mi_cap_tries;
	bool jeita_block;
	bool no_slave;
	bool qc3;
	int qc_pulses;
	int slave_low_cnt;
	int pump_off_cnt;
	int v_req_mv;
	int i_req_ma;
	int v_sent_mv;
	int i_sent_ma;
	unsigned long pps_alive_jiffies;
	int fcc_ma;
	int taper_fcc_ma;
	int cv_cnt;
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
		int src_ua = 0;

		ret = dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_ONLINE,
				   DAGU_TCPM_PPS);
		if (ret)
			return ret;
		/*
		 * The current computed before this contract was the fixed
		 * 5 V object's 2 A. CURRENT_MAX is the programmable
		 * object's advertised current only after the contract.
		 * Leaving the request at 2 A shows about 18 W on the bank.
		 */
		if (!dagu_psy_get(pm->tcpm, POWER_SUPPLY_PROP_CURRENT_MAX,
				  &src_ua) && src_ua / 1000 > pm->i_req_ma) {
			int by_w = pm->v_req_mv > 0 ?
				(int)(pm->power_max_w * 1000000U / pm->v_req_mv) :
				src_ua / 1000;

			pm->i_req_ma = min_t(int, src_ua / 1000, pm->bus_curr_max_ma);
			pm->i_req_ma = min_t(int, pm->i_req_ma, by_w);
		}
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
	 *
	 * Each of VOLTAGE_NOW and CURRENT_NOW is its own PPS contract and
	 * waits for PS_RDY. On this bank that wait is about 380 ms, and
	 * TCPM hard-resets the port at 500 ms. Rewriting an unchanged
	 * current after every 20 mV step doubled the contracts and dropped
	 * VBUS back to 5 V.
	 */
	{
		int v_mv = pm->v_req_mv - (pm->v_req_mv % DAGU_STEP_MV);
		int i_ma = pm->i_req_ma - (pm->i_req_ma % 50);
		bool refresh = time_after_eq(jiffies, pm->pps_alive_jiffies);

		if (!kick && v_mv == pm->v_sent_mv && i_ma == pm->i_sent_ma &&
		    !refresh)
			return 0;
		if (v_mv != pm->v_sent_mv || refresh) {
			ret = dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_NOW,
					   pm->v_req_mv * 1000);
			if (ret)
				return ret;
			pm->v_sent_mv = v_mv;
			pm->pps_alive_jiffies = jiffies +
				msecs_to_jiffies(DAGU_PPS_KEEPALIVE_MS);
		}
		if (i_ma != pm->i_sent_ma) {
			ret = dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_CURRENT_NOW,
					   pm->i_req_ma * 1000);
			if (ret) {
				dev_info(pm->dev,
					 "pps current %d mA not accepted (%d)\n",
					 pm->i_req_ma, ret);
				return 0;
			}
			dev_info(pm->dev, "pps set %d mV %d mA\n", v_mv, i_ma);
			pm->i_sent_ma = i_ma;
			pm->pps_alive_jiffies = jiffies +
				msecs_to_jiffies(DAGU_PPS_KEEPALIVE_MS);
		}
	}
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
	(void)cap;
	if (mv < DAGU_MIN_VBAT_MV || mv > pm->bat_volt_max_mv)
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
	if (pm->taper_fcc_ma >= DAGU_CV_FCC_FLOOR_MA)
		fcc = min_t(int, fcc, pm->taper_fcc_ma);
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
	pm->pump_off_cnt = 0;
	pm->no_slave = false;
	pm->qc3 = false;
	pm->tried_9v = false;
	pm->v_sent_mv = -1;
	pm->i_sent_ma = -1;
	pm->taper_fcc_ma = pm->bat_curr_max_ma;
	pm->cv_cnt = 0;
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

static u32 dagu_rotr(u32 x, u32 n)
{
	return (x >> n) | (x << (32 - n));
}

static const u32 dagu_sha256_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
	0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
	0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
	0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
	0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
	0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

struct dagu_sha256 {
	u32 h[8];
	u64 nbits;
	u8 buf[64];
	unsigned int n;
};

static u32 dagu_load_be32(const u8 *p)
{
	return ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) | p[3];
}

static void dagu_store_be32(u8 *p, u32 v)
{
	p[0] = v >> 24;
	p[1] = v >> 16;
	p[2] = v >> 8;
	p[3] = v;
}

static void dagu_sha256_block(struct dagu_sha256 *s, const u8 *block)
{
	u32 w[64], a, b, c, d, e, f, g, h;
	int i;

	for (i = 0; i < 16; i++)
		w[i] = dagu_load_be32(block + i * 4);
	for (; i < 64; i++) {
		u32 s0 = dagu_rotr(w[i - 15], 7) ^ dagu_rotr(w[i - 15], 18) ^
			 (w[i - 15] >> 3);
		u32 s1 = dagu_rotr(w[i - 2], 17) ^ dagu_rotr(w[i - 2], 19) ^
			 (w[i - 2] >> 10);

		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	a = s->h[0];
	b = s->h[1];
	c = s->h[2];
	d = s->h[3];
	e = s->h[4];
	f = s->h[5];
	g = s->h[6];
	h = s->h[7];
	for (i = 0; i < 64; i++) {
		u32 s1 = dagu_rotr(e, 6) ^ dagu_rotr(e, 11) ^ dagu_rotr(e, 25);
		u32 ch = (e & f) ^ (~e & g);
		u32 t1 = h + s1 + ch + dagu_sha256_k[i] + w[i];
		u32 s0 = dagu_rotr(a, 2) ^ dagu_rotr(a, 13) ^ dagu_rotr(a, 22);
		u32 maj = (a & b) ^ (a & c) ^ (b & c);
		u32 t2 = s0 + maj;

		h = g;
		g = f;
		f = e;
		e = d + t1;
		d = c;
		c = b;
		b = a;
		a = t1 + t2;
	}
	s->h[0] += a;
	s->h[1] += b;
	s->h[2] += c;
	s->h[3] += d;
	s->h[4] += e;
	s->h[5] += f;
	s->h[6] += g;
	s->h[7] += h;
}

static void dagu_sha256_init(struct dagu_sha256 *s)
{
	s->h[0] = 0x6a09e667;
	s->h[1] = 0xbb67ae85;
	s->h[2] = 0x3c6ef372;
	s->h[3] = 0xa54ff53a;
	s->h[4] = 0x510e527f;
	s->h[5] = 0x9b05688c;
	s->h[6] = 0x1f83d9ab;
	s->h[7] = 0x5be0cd19;
	s->nbits = 0;
	s->n = 0;
}

static void dagu_sha256_update(struct dagu_sha256 *s, const u8 *data,
			       unsigned int len)
{
	s->nbits += (u64)len * 8;
	while (len) {
		unsigned int n = 64 - s->n;

		if (n > len)
			n = len;
		memcpy(s->buf + s->n, data, n);
		s->n += n;
		data += n;
		len -= n;
		if (s->n == 64) {
			dagu_sha256_block(s, s->buf);
			s->n = 0;
		}
	}
}

static void dagu_sha256_final(struct dagu_sha256 *s, u8 out[32])
{
	unsigned int i;
	u8 one = 0x80;

	dagu_sha256_update(s, &one, 1);
	s->nbits -= 8;
	if (s->n > 56) {
		memset(s->buf + s->n, 0, 64 - s->n);
		dagu_sha256_block(s, s->buf);
		s->n = 0;
	}
	memset(s->buf + s->n, 0, 56 - s->n);
	for (i = 0; i < 8; i++)
		s->buf[63 - i] = (s->nbits >> (i * 8)) & 0xff;
	dagu_sha256_block(s, s->buf);
	for (i = 0; i < 8; i++)
		dagu_store_be32(out + i * 4, s->h[i]);
}

/* Same keyed hash batterysecret uses before it writes verified. */
static void dagu_hmac_sha256(const u8 *key, unsigned int klen,
			     const u8 *msg, unsigned int mlen, u8 out[32])
{
	u8 k[64] = { };
	u8 ipad[64], opad[64], inner[32];
	struct dagu_sha256 s;
	unsigned int i;

	if (klen > 64) {
		dagu_sha256_init(&s);
		dagu_sha256_update(&s, key, klen);
		dagu_sha256_final(&s, k);
	} else {
		memcpy(k, key, klen);
	}
	for (i = 0; i < 64; i++) {
		ipad[i] = k[i] ^ 0x36;
		opad[i] = k[i] ^ 0x5c;
	}
	dagu_sha256_init(&s);
	dagu_sha256_update(&s, ipad, 64);
	dagu_sha256_update(&s, msg, mlen);
	dagu_sha256_final(&s, inner);
	dagu_sha256_init(&s);
	dagu_sha256_update(&s, opad, 64);
	dagu_sha256_update(&s, inner, 32);
	dagu_sha256_final(&s, out);
}

/*
 * Session-seed rows and the matching 32-byte keys, copied from this
 * tablet's batterysecret. The kernel byte-swaps each seed word once
 * before it is put on the wire. The authentication words are random
 * and the swap is applied twice, so they go out unchanged.
 */
static const u8 dagu_mi_seed[10][16] = {
	{ 0xd6, 0xe9, 0x77, 0x05, 0x06, 0xc7, 0xf5, 0xf4,
	  0xdf, 0x7a, 0x40, 0x00, 0x8c, 0x74, 0x67, 0xb8 },
	{ 0x09, 0x60, 0x4e, 0xb9, 0xad, 0x37, 0xe1, 0x7b,
	  0xd6, 0xb2, 0xa4, 0xf2, 0xa3, 0x51, 0x59, 0x84 },
	{ 0xf6, 0x29, 0x5c, 0xe3, 0xbd, 0xe8, 0x67, 0x8c,
	  0x9f, 0xfe, 0xab, 0x61, 0x60, 0x98, 0xab, 0xa0 },
	{ 0xae, 0x0c, 0x8e, 0xe9, 0xb0, 0x5b, 0xa2, 0x33,
	  0x79, 0x9b, 0xad, 0xcb, 0x9f, 0xa2, 0x2b, 0x41 },
	{ 0x56, 0xb7, 0x47, 0x0c, 0x9d, 0x6f, 0x22, 0xca,
	  0x00, 0x3e, 0x40, 0x32, 0x6f, 0xa7, 0x7e, 0xb5 },
	{ 0x60, 0x19, 0xb4, 0x57, 0xcd, 0x77, 0xfd, 0x5f,
	  0xed, 0xff, 0xdc, 0x3d, 0x0e, 0xd0, 0x61, 0x06 },
	{ 0x09, 0xe4, 0x7c, 0x32, 0x76, 0x0f, 0xb2, 0xfa,
	  0xcf, 0xc5, 0x84, 0x3d, 0xf0, 0x71, 0x64, 0x65 },
	{ 0xa6, 0x01, 0x93, 0x4c, 0x14, 0x03, 0xbf, 0xd9,
	  0x55, 0xeb, 0xd7, 0x7f, 0x50, 0x9b, 0xa1, 0x7f },
	{ 0x3e, 0x02, 0xb4, 0x4e, 0x19, 0xdc, 0x24, 0xf4,
	  0x38, 0xe6, 0x2f, 0x02, 0x6a, 0xde, 0x4a, 0xa7 },
	{ 0x34, 0x3d, 0x6b, 0x41, 0xb9, 0x00, 0xbe, 0xb4,
	  0xc8, 0xbf, 0x0e, 0x8f, 0xa7, 0xdf, 0x8c, 0x13 },
};

static const u8 dagu_mi_key[10][32] = {
	{ 0x5c, 0x4d, 0x41, 0x79, 0xda, 0x15, 0x01, 0xed,
	  0x11, 0x74, 0x74, 0x92, 0xe2, 0x60, 0x83, 0xd9,
	  0x6b, 0x8f, 0xbc, 0x73, 0xc8, 0x2e, 0x7b, 0xdf,
	  0x5d, 0x32, 0x55, 0xc2, 0xa0, 0x36, 0xa1, 0xdc },
	{ 0x45, 0x54, 0xea, 0x90, 0x7f, 0xc3, 0x25, 0x0d,
	  0x20, 0x78, 0xbd, 0x62, 0x77, 0xd6, 0xcf, 0x0c,
	  0xb8, 0x23, 0xe6, 0x22, 0x58, 0xd0, 0x87, 0x37,
	  0x8a, 0xf2, 0x9c, 0x46, 0x6b, 0x10, 0x10, 0x26 },
	{ 0x83, 0xd3, 0x06, 0x25, 0xcb, 0x0f, 0x7c, 0xe6,
	  0xd4, 0x96, 0x49, 0xff, 0x4c, 0xfc, 0xf9, 0xce,
	  0xbe, 0x62, 0x46, 0x9b, 0x57, 0xe3, 0x1b, 0xa6,
	  0x2d, 0x01, 0xde, 0x28, 0x10, 0xff, 0x62, 0x1a },
	{ 0xa1, 0x44, 0x73, 0x05, 0x16, 0x6b, 0x4a, 0x78,
	  0x6d, 0xf5, 0xdd, 0xd7, 0x07, 0xa8, 0x36, 0x0a,
	  0x73, 0x28, 0xce, 0xd7, 0x03, 0x84, 0x87, 0x60,
	  0x7f, 0xa2, 0x11, 0x28, 0xa1, 0x5d, 0x18, 0x64 },
	{ 0xe4, 0xfb, 0x00, 0xaf, 0xd1, 0x51, 0x86, 0xaf,
	  0x1a, 0x44, 0x50, 0x20, 0x05, 0xd3, 0xd1, 0xb0,
	  0xb1, 0xe9, 0xd1, 0xa6, 0x36, 0xa5, 0x1c, 0x26,
	  0x34, 0x94, 0x22, 0xe7, 0xdb, 0xad, 0xc2, 0x73 },
	{ 0x46, 0xb8, 0xca, 0xe9, 0xa4, 0x6a, 0x32, 0x54,
	  0xee, 0x55, 0x12, 0x82, 0xcf, 0x07, 0xb7, 0xbb,
	  0x6b, 0x2e, 0xf1, 0x2b, 0xf6, 0x15, 0x46, 0x3c,
	  0x23, 0x9b, 0xb6, 0x3b, 0x98, 0x4e, 0x42, 0xa9 },
	{ 0xea, 0xf4, 0x5b, 0x6f, 0xf3, 0xcc, 0xce, 0x76,
	  0x9e, 0x82, 0xbd, 0x0b, 0x00, 0x7b, 0x69, 0xc4,
	  0x06, 0xa6, 0x6b, 0x98, 0xf4, 0x27, 0xa2, 0xbb,
	  0xe4, 0x55, 0xd1, 0xff, 0xcb, 0x1e, 0xcd, 0xcc },
	{ 0xe7, 0x87, 0xdb, 0x56, 0x8b, 0x7d, 0x70, 0x4d,
	  0x29, 0xcc, 0x50, 0xa2, 0xbb, 0x1e, 0x97, 0x1f,
	  0x6f, 0x1f, 0xd7, 0xfe, 0x96, 0x04, 0xde, 0xb4,
	  0xd4, 0xa1, 0xa7, 0xa7, 0x2c, 0x63, 0xff, 0x42 },
	{ 0xb5, 0xf7, 0x04, 0xa7, 0x5d, 0x0d, 0xb5, 0x4a,
	  0x0b, 0x5e, 0x73, 0x17, 0x79, 0x94, 0x9b, 0x32,
	  0x11, 0x05, 0xad, 0xc9, 0xd5, 0xc0, 0x85, 0x8c,
	  0x50, 0xef, 0xc9, 0xbf, 0x92, 0x89, 0x2c, 0xf4 },
	{ 0xdf, 0x47, 0xcc, 0x32, 0x49, 0x83, 0x3b, 0xde,
	  0xfe, 0xb4, 0xa0, 0x4a, 0x25, 0x74, 0x89, 0xfc,
	  0x75, 0x00, 0xd8, 0x27, 0xb2, 0xb6, 0x6b, 0x26,
	  0x89, 0xbd, 0xed, 0x7f, 0xfe, 0x49, 0x46, 0x5e },
};

#define DAGU_MI_SVID		0x2717
#define DAGU_MI_HDR(cmd)	(((DAGU_MI_SVID) << 16) | (1 << 8) | (cmd))

int tcpm_dagu_uvdm(struct power_supply *psy, u32 header, const u32 *data,
		   int cnt, u32 *reply, int *reply_cnt);
int tcpm_dagu_adapter_pid(struct power_supply *psy, u32 *pid);
int tcpm_dagu_get_source_cap(struct power_supply *psy);
int tcpm_dagu_pps_limit(struct power_supply *psy, int *max_mv, int *max_ma);

static int dagu_hex(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return 0;
}

static u32 dagu_bswap32(u32 v)
{
	return ((v & 0xff000000) >> 24) | ((v & 0x00ff0000) >> 8) |
	       ((v & 0x0000ff00) << 8) | ((v & 0x000000ff) << 24);
}

static int dagu_mi_send(struct dagu_pdpm *pm, u8 cmd, const u32 *data, int n,
			u32 *reply, int *reply_n)
{
	u32 local[7];
	int local_n = 0, attempt, ret = -EIO;

	for (attempt = 0; attempt < 2; attempt++) {
		int spin;

		for (spin = 0; spin < 8; spin++) {
			local_n = 0;
			ret = tcpm_dagu_uvdm(pm->tcpm, DAGU_MI_HDR(cmd), data, n,
					     local, &local_n);
			if (ret != -EAGAIN)
				break;
			msleep(40);
		}
		if (ret != -ETIMEDOUT)
			break;
		msleep(30);
	}
	if (!ret && reply && reply_n) {
		memcpy(reply, local, local_n * sizeof(u32));
		*reply_n = local_n;
	}
	dev_info(pm->dev, "xiaomi uvdm cmd %u ret %d objects %d\n",
		 cmd, ret, local_n);
	return ret;
}

/*
 * batterysecret order: version, voltage, temperature, session seed,
 * authentication, verified, reverse, remove-compensation. Verified
 * is 1 only when the charger digest matches the keyed hash of the
 * same random words. Nothing here invents a digest.
 */
static int dagu_mi_handshake(struct dagu_pdpm *pm)
{
	u32 row = get_random_u32_below(ARRAY_SIZE(dagu_mi_seed));
	u32 seed[4], auth[4], reply[7], flag = 0;
	u8 msg[20], mac[32], got[16];
	u32 pid = 0;
	char hex[9];
	int reply_n = 0, i, ret;
	bool ok = false;

	ret = dagu_mi_send(pm, 1, NULL, 0, NULL, NULL);
	if (ret)
		return ret == -EAGAIN ? -EAGAIN : 0;
	ret = dagu_mi_send(pm, 2, NULL, 0, NULL, NULL);
	if (ret)
		return 0;
	ret = dagu_mi_send(pm, 3, NULL, 0, NULL, NULL);
	if (ret)
		return 0;

	for (i = 0; i < 4; i++) {
		const u8 *p = &dagu_mi_seed[row][i * 4];
		u32 le = (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) |
			 ((u32)p[3] << 24);

		seed[i] = dagu_bswap32(le);
	}
	ret = dagu_mi_send(pm, 4, seed, 4, NULL, NULL);
	if (ret)
		return 0;

	get_random_bytes(auth, sizeof(auth));
	for (i = 0; i < 4; i++)
		dagu_store_be32(msg + i * 4, auth[i]);
	tcpm_dagu_adapter_pid(pm->tcpm, &pid);
	snprintf(hex, sizeof(hex), "%08x", pid);
	for (i = 0; i < 4; i++)
		msg[16 + i] = (dagu_hex(hex[i * 2]) << 4) |
			      dagu_hex(hex[i * 2 + 1]);
	dagu_hmac_sha256(dagu_mi_key[row], 32, msg, sizeof(msg), mac);

	ret = dagu_mi_send(pm, 5, auth, 4, reply, &reply_n);
	if (!ret && reply_n >= 5) {
		for (i = 0; i < 4; i++)
			dagu_store_be32(got + i * 4, reply[i + 1]);
		ok = !memcmp(mac, got, sizeof(got));
	}
	pm->mi_verified = ok;
	flag = ok ? 1 : 0;
	dev_info(pm->dev, "xiaomi uvdm row %u pid %04x verified %d\n",
		 row, pid, ok);
	if (ret == -EAGAIN)
		return 0;
	dagu_mi_send(pm, 6, &flag, 1, NULL, NULL);
	{
		u32 rev[4] = { 0x7e550000, 0, 0, 0 };

		dagu_mi_send(pm, 8, rev, 4, NULL, NULL);
	}
	dagu_mi_send(pm, 7, &flag, 1, NULL, NULL);
	return 0;
}

static void dagu_pdpm_work(struct work_struct *work)
{
	struct dagu_pdpm *pm = container_of(work, struct dagu_pdpm, work.work);
	int usb_type = POWER_SUPPLY_USB_TYPE_UNKNOWN;
	int online = 0, vbat = 0, deci = 250, cap = 0;
	int vbus, ibus, ibat = 0;
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
		if (!online) {
			/*
			 * This bank drops CC and advertises the 5 A list
			 * again after any detach. The unlock does not
			 * survive that, so the next 5 V contract must
			 * send the vendor messages again.
			 */
			pm->pps_failed = false;
			pm->mi_done = false;
			pm->mi_verified = false;
			pm->mi_tries = 0;
			pm->mi_cap_tries = 0;
		}
		schedule_delayed_work(&pm->work, msecs_to_jiffies(500));
		return;
	}

	if (usb_type != POWER_SUPPLY_USB_TYPE_PD &&
	    usb_type != POWER_SUPPLY_USB_TYPE_PD_PPS &&
	    dagu_qc3_step(pm, vbat, deci, cap)) {
		schedule_delayed_work(&pm->work, msecs_to_jiffies(200));
		return;
	}

	/*
	 * TCPM sets the supply type to PD_PPS as soon as the source
	 * advertises a programmable object, while the contract is still
	 * the fixed 5 V one (online stays fixed). The Xiaomi messages
	 * have to go out on that 5 V contract. Waiting for type PD
	 * skips them on every PPS bank.
	 */
	if ((usb_type == POWER_SUPPLY_USB_TYPE_PD ||
	     usb_type == POWER_SUPPLY_USB_TYPE_PD_PPS) &&
	    online == DAGU_TCPM_FIXED &&
	    pm->state == DAGU_PM_IDLE && !pm->mi_done &&
	    pm->master && dagu_pack_ok(pm, vbat, deci, cap)) {
		int rc = dagu_mi_handshake(pm);

		if (rc == -EAGAIN && pm->mi_tries < 8) {
			pm->mi_tries++;
			schedule_delayed_work(&pm->work, msecs_to_jiffies(300));
			return;
		}
		if (!pm->mi_verified) {
			pm->mi_done = true;
			dev_info(pm->dev, "xiaomi auth failed, stay on buck\n");
		} else {
			int n, ma = 0, mv = 0;

			/*
			 * The charger updates its programmable object after
			 * the verified message. One immediate query often
			 * still returns the old 5 A list. Ask again until
			 * the object above 5 A shows up, or four times.
			 */
			for (n = 0; n < 4; n++) {
				ma = 0;
				mv = 0;
				rc = tcpm_dagu_get_source_cap(pm->tcpm);
				msleep(500);
				tcpm_dagu_pps_limit(pm->tcpm, &mv, &ma);
				dev_info(pm->dev,
					 "xiaomi caps try %d send %d pps %d mV %d mA\n",
					 n, rc, mv, ma);
				if (ma > 5000)
					break;
			}
			if (ma > 5000) {
				pm->mi_done = true;
				pm->mi_cap_tries = 0;
			} else if (++pm->mi_cap_tries < 3) {
				pm->mi_verified = false;
				pm->mi_tries = 0;
				dev_info(pm->dev,
					 "pps current %d mA, authenticate again\n",
					 ma);
			} else {
				pm->mi_done = true;
				pm->mi_verified = false;
				dev_info(pm->dev,
					 "pps stayed %d mA, stay on buck\n", ma);
			}
			schedule_delayed_work(&pm->work, msecs_to_jiffies(400));
			return;
		}
	}

	/*
	 * Auth failed, or the unlocked current never appeared: fixed 9 V
	 * through the buck. Do not open the pumps on the 5 A object.
	 */
	if (pm->mi_done && !pm->mi_verified) {
		if (pm->state != DAGU_PM_IDLE)
			dagu_leave(pm);
		if ((usb_type == POWER_SUPPLY_USB_TYPE_PD ||
		     usb_type == POWER_SUPPLY_USB_TYPE_PD_PPS) &&
		    online == DAGU_TCPM_FIXED && !pm->tried_9v &&
		    vbat >= DAGU_MIN_VBAT_MV && vbat < pm->bat_volt_max_mv) {
			pm->tried_9v = true;
			dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_MAX,
				     DAGU_FIXED_9V_UV);
		}
		schedule_delayed_work(&pm->work, msecs_to_jiffies(500));
		return;
	}
	if (!pm->mi_verified) {
		schedule_delayed_work(&pm->work, msecs_to_jiffies(500));
		return;
	}

	/*
	 * A pump fault or a failed 9 V contract stays on the buck until
	 * the cable is unplugged. RAMP still runs so the bus steps down.
	 */
	if (pm->pps_failed && pm->state == DAGU_PM_IDLE) {
		if ((usb_type == POWER_SUPPLY_USB_TYPE_PD ||
		     usb_type == POWER_SUPPLY_USB_TYPE_PD_PPS) &&
		    online == DAGU_TCPM_FIXED && !pm->tried_9v &&
		    vbat >= DAGU_MIN_VBAT_MV && vbat < pm->bat_volt_max_mv) {
			pm->tried_9v = true;
			dagu_psy_set(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_MAX,
				     DAGU_FIXED_9V_UV);
		}
		schedule_delayed_work(&pm->work, msecs_to_jiffies(500));
		return;
	}

	if (usb_type != POWER_SUPPLY_USB_TYPE_PD_PPS) {
		if (pm->state != DAGU_PM_IDLE)
			dagu_leave(pm);
		/*
		 * Hard reset comes back as fixed PD. Buck off, then one
		 * 9.000 V programmable request. Never 2*VBAT+700 here:
		 * that walk is what passed the 9.5 V pump alarm.
		 */
		if (usb_type == POWER_SUPPLY_USB_TYPE_PD && !pm->pps_failed &&
		    pm->master && dagu_pack_ok(pm, vbat, deci, cap)) {
			pm->v_req_mv = 9000;
			dagu_ibus_target(pm, vbat);
			dagu_buck(pm, false);
			if (dagu_request_pps(pm, true)) {
				dagu_buck(pm, true);
				if (++pm->tune_tries > 5)
					pm->pps_failed = true;
				schedule_delayed_work(&pm->work,
						      msecs_to_jiffies(500));
				return;
			}
			pm->tune_tries = 0;
			pm->state = DAGU_PM_TUNE;
			schedule_delayed_work(&pm->work, msecs_to_jiffies(200));
			return;
		}
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
		if (pm->pps_failed || !pm->mi_verified || !pm->master ||
		    !dagu_pack_ok(pm, vbat, deci, cap))
			break;
		/*
		 * Factory dagu-sm8250.dtsi is 67 W / 6200 mA. The first
		 * programmable request in pd_policy_manager_dagu.c is
		 * 2*VBAT+700 mV, which is the 9 V contract. Do not walk
		 * that request upward: doing so reached 10.5 V and faulted
		 * the pumps. The Android dumps have no 67 W trace (packs
		 * were off, 5 V / 0.5 A, 99 %).
		 */
		pm->v_req_mv = 9000;
		dagu_ibus_target(pm, vbat);
		pm->tune_tries = 0;
		pm->state = DAGU_PM_ARM;
		delay = 200;
		break;

	case DAGU_PM_ARM:
		/*
		 * The buck has to be off before the bus leaves 5 V.
		 * A 9 V request into an enabled 5 V buck is what made
		 * this bank drop the port after the 6 A unlock.
		 */
		dagu_buck(pm, false);
		if (dagu_request_pps(pm, true)) {
			dagu_buck(pm, true);
			if (++pm->tune_tries > 15) {
				dev_info(pm->dev, "pps request %d mV failed\n",
					 pm->v_req_mv);
				dagu_leave(pm);
			}
			delay = 500;
			break;
		}
		pm->tune_tries = 0;
		pm->state = DAGU_PM_TUNE;
		delay = 200;
		break;

	case DAGU_PM_TUNE:
		pm->v_req_mv = 9000;
		dagu_psy_get(pm->tcpm, POWER_SUPPLY_PROP_VOLTAGE_NOW, &vbus);
		vbus /= 1000;
		if (vbus >= 8600) {
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
		if (++pm->tune_tries > 80) {
			dev_info(pm->dev, "vbus tune failed, stay on buck\n");
			pm->pps_failed = true;
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
				pm->pps_failed = true;
				pm->state = DAGU_PM_RAMP;
				break;
			}
		}
		/*
		 * SC8551 clears its own enable when 9.000 V leaves less than
		 * the factory 650 mV headroom over 2*VBAT. Health stays Good,
		 * so the old path never left RUN, the buck stayed off, and
		 * the pack current sat at 0 with the display frozen.
		 */
		{
			int mon = 1;

			dagu_psy_get(pm->master, POWER_SUPPLY_PROP_ONLINE, &mon);
			if (mon)
				pm->pump_off_cnt = 0;
			else if (++pm->pump_off_cnt >= 5) {
				dev_info(pm->dev, "pumps dropped out, stay on buck\n");
				pm->pps_failed = true;
				pm->pump_off_cnt = 0;
				pm->state = DAGU_PM_RAMP;
				break;
			}
		}
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
		/*
		 * Pump IBAT reads tens of milliamps on this SC8551 and
		 * must not drive the taper. The gauge sum is the pack.
		 */
		dagu_psy_get(pm->bms, POWER_SUPPLY_PROP_CURRENT_NOW, &ibat);
		ibat /= 1000;
		if (ibat < 0)
			ibat = 0;
		if (vbat > pm->cell_max_mv &&
		    pm->taper_fcc_ma > DAGU_CV_FCC_FLOOR_MA)
			pm->taper_fcc_ma -= DAGU_CV_STEP_MA;
		if (vbat > pm->bat_volt_max_mv - DAGU_CV_HYS_MV) {
			if (++pm->cv_cnt >= 5 &&
			    pm->taper_fcc_ma > DAGU_CV_FCC_FLOOR_MA) {
				pm->cv_cnt = 0;
				pm->taper_fcc_ma -= DAGU_CV_STEP_MA;
				dev_info(pm->dev, "cv taper fcc %d mA vbat %d ibat %d\n",
					 pm->taper_fcc_ma, vbat, ibat);
			}
		} else {
			pm->cv_cnt = 0;
		}
		dagu_ibus_target(pm, vbat);
		pm->v_req_mv = 9000;
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
	pm->taper_fcc_ma = pm->bat_curr_max_ma;

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
