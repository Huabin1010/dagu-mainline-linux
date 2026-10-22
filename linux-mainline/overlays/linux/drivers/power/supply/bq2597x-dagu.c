// SPDX-License-Identifier: GPL-2.0-only
/*
 * TI BQ25970 / Southchip SC8551 switched-cap 2:1 charge pump (dagu dual: master+slave).
 *
 * Provides hardware initialization, ADC telemetry (VBAT, VBUS, IBAT, IBUS, TDIE),
 * safety threshold programming (BAT_OVP, BUS_OVP, BUS_OCP, AC_OVP), and power_supply
 * sysfs attributes for userspace / fast-charge policy orchestration.
 */

#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/i2c.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>
#include <linux/sysfs.h>
#include <linux/types.h>

/* BQ25970 / SC8551 Registers */
#define BQ2597X_REG_00		0x00	/* BAT_OVP */
#define BQ2597X_REG_01		0x01	/* BAT_OVP_ALARM */
#define BQ2597X_REG_02		0x02	/* BAT_OCP */
#define BQ2597X_REG_03		0x03	/* BAT_OCP_ALARM */
#define BQ2597X_REG_04		0x04	/* BAT_UCP_ALARM */
#define BQ2597X_REG_05		0x05	/* AC_OVP */
#define BQ2597X_REG_06		0x06	/* BUS_OVP */
#define BQ2597X_REG_07		0x07	/* BUS_OVP_ALARM */
#define BQ2597X_REG_08		0x08	/* BUS_OCP */
#define BQ2597X_REG_09		0x09	/* BUS_OCP_ALARM */
#define BQ2597X_REG_0A		0x0a	/* CONV_STAT / FAULT */
#define BQ2597X_REG_0B		0x0b	/* WD_CFG / RESET */
#define BQ2597X_REG_0C		0x0c	/* CHG_CTL / MS */
#define BQ2597X_REG_0D		0x0d	/* STAT / INSERT / ADC_DONE */
#define BQ2597X_REG_0E		0x0e	/* ALARM_FLAG */
#define BQ2597X_REG_0F		0x0f	/* ALARM_MASK */
#define BQ2597X_REG_10		0x10	/* FAULT_STAT */
#define BQ2597X_REG_11		0x11	/* FAULT_FLAG */
#define BQ2597X_REG_12		0x12	/* FAULT_MASK */
#define BQ2597X_REG_13		0x13	/* DEVICE_ID */
#define BQ2597X_REG_14		0x14	/* ADC_CTRL */
#define BQ2597X_REG_15		0x15	/* ADC_CHAN_DIS */
#define BQ2597X_REG_ADC_BASE	0x16	/* ADC readings (2 bytes per channel) */

/* Register Bitfields & Threshold Scales */
#define BQ2597X_BAT_OVP_MASK	GENMASK(5, 0)
#define BQ2597X_BAT_OVP_BASE_MV	3475
#define BQ2597X_BAT_OVP_LSB_MV	25

#define BQ2597X_BUS_OVP_MASK	GENMASK(6, 0)
#define BQ2597X_BUS_OVP_BASE_MV	5950
#define BQ2597X_BUS_OVP_LSB_MV	50

#define BQ2597X_BUS_OCP_MASK	GENMASK(3, 0)
#define BQ2597X_BUS_OCP_BASE_MA	1000
#define BQ2597X_BUS_OCP_LSB_MA	250

#define BQ2597X_AC_OVP_MASK	GENMASK(2, 0)
#define BQ2597X_AC_OVP_BASE_V	11

#define BQ2597X_WD_DIS_BIT	BIT(2)

#define BQ2597X_CHG_EN		BIT(7)
#define BQ2597X_MS_MASK		GENMASK(6, 5)
#define BQ2597X_MS_STANDALONE	(0 << 5)
#define BQ2597X_MS_SLAVE	(1 << 5)
#define BQ2597X_MS_MASTER	(2 << 5)

#define BQ2597X_VBUS_INSERT	BIT(2)
#define BQ2597X_VBAT_INSERT	BIT(1)
#define BQ2597X_ADC_DONE	BIT(0)

#define BQ2597X_ADC_EN		BIT(7)
#define BQ2597X_ADC_RATE_CONT	0	/* bit 6 = 0: continuous */
#define BQ2597X_ADC_AVG_EN	BIT(5)

#define BQ25970_DEVICE_ID	0x10
#define SC8551_DEVICE_ID	0x00
#define SC8551A_DEVICE_ID	0x51

enum bq2597x_adc_channel {
	ADC_IBUS = 0,
	ADC_VBUS = 1,
	ADC_VAC  = 2,
	ADC_VOUT = 3,
	ADC_VBAT = 4,
	ADC_IBAT = 5,
	ADC_TBUS = 6,
	ADC_TBAT = 7,
	ADC_TDIE = 8,
	ADC_MAX,
};

struct bq2597x {
	struct i2c_client *client;
	struct device *dev;
	struct regmap *regmap;
	struct power_supply *psy;
	bool master;
	unsigned int chip_id;
	bool is_sc8551;

	u32 bat_ovp_th_mv;
	u32 bus_ovp_th_mv;
	u32 bus_ocp_th_ma;
	u32 ac_ovp_th_v;
};

static const struct regmap_config bq2597x_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,
	.max_register = 0x36,
};

static int bq2597x_read_adc_raw(struct bq2597x *chip, enum bq2597x_adc_channel ch, int *raw)
{
	u8 buf[2];
	int ret;

	if (ch >= ADC_MAX)
		return -EINVAL;

	ret = regmap_bulk_read(chip->regmap, BQ2597X_REG_ADC_BASE + (ch * 2), buf, 2);
	if (ret)
		return ret;

	/*
	 * Same order as the stock driver: SMBus word low byte is the first
	 * register byte, then the two bytes are swapped before the LSB scale.
	 */
	*raw = (s16)(((u16)buf[0] << 8) | buf[1]);
	return 0;
}

static int bq2597x_get_vbus_mv(struct bq2597x *chip, int *mv)
{
	int raw, ret;

	ret = bq2597x_read_adc_raw(chip, ADC_VBUS, &raw);
	if (ret)
		return ret;

	if (chip->is_sc8551)
		*mv = (int)(((s64)raw * 375) / 100);
	else
		*mv = raw;

	return 0;
}

static int bq2597x_get_vbat_mv(struct bq2597x *chip, int *mv)
{
	int raw, ret;

	ret = bq2597x_read_adc_raw(chip, ADC_VBAT, &raw);
	if (ret)
		return ret;

	if (chip->is_sc8551)
		*mv = (int)(((s64)raw * 12575) / 10000);
	else
		*mv = raw;

	return 0;
}

static int bq2597x_get_ibus_ma(struct bq2597x *chip, int *ma)
{
	int raw, ret;

	ret = bq2597x_read_adc_raw(chip, ADC_IBUS, &raw);
	if (ret)
		return ret;

	if (chip->is_sc8551)
		*ma = (int)(((s64)raw * 15625) / 10000);
	else
		*ma = raw;

	return 0;
}

static int bq2597x_get_ibat_ma(struct bq2597x *chip, int *ma)
{
	int raw, ret;

	ret = bq2597x_read_adc_raw(chip, ADC_IBAT, &raw);
	if (ret)
		return ret;

	if (chip->is_sc8551)
		*ma = (int)(((s64)raw * 3125) / 1000);
	else
		*ma = raw;

	return 0;
}

/* Returns die temperature in tenths of a degree Celsius (0.1 °C). */
static int bq2597x_get_tdie_tenth_c(struct bq2597x *chip, int *temp)
{
	int raw, ret;

	ret = bq2597x_read_adc_raw(chip, ADC_TDIE, &raw);
	if (ret)
		return ret;

	if (chip->is_sc8551)
		*temp = raw * 5;
	else
		*temp = raw;
	return 0;
}

static int bq2597x_get_property(struct power_supply *psy,
				enum power_supply_property psp,
				union power_supply_propval *val)
{
	struct bq2597x *chip = power_supply_get_drvdata(psy);
	unsigned int reg;
	int val_int, ret;

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		ret = regmap_read(chip->regmap, BQ2597X_REG_0C, &reg);
		if (ret)
			return ret;
		val->intval = !!(reg & BQ2597X_CHG_EN);
		return 0;

	case POWER_SUPPLY_PROP_PRESENT:
		ret = regmap_read(chip->regmap, BQ2597X_REG_0D, &reg);
		if (ret)
			return ret;
		val->intval = !!(reg & (BQ2597X_VBUS_INSERT | BQ2597X_VBAT_INSERT));
		return 0;

	case POWER_SUPPLY_PROP_STATUS:
		ret = regmap_read(chip->regmap, BQ2597X_REG_0C, &reg);
		if (ret)
			return ret;
		if (reg & BQ2597X_CHG_EN)
			val->intval = POWER_SUPPLY_STATUS_CHARGING;
		else
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;
		return 0;

	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		ret = bq2597x_get_vbat_mv(chip, &val_int);
		if (ret)
			return ret;
		val->intval = val_int * 1000;	/* µV */
		return 0;

	case POWER_SUPPLY_PROP_CURRENT_NOW:
		ret = bq2597x_get_ibat_ma(chip, &val_int);
		if (ret)
			return ret;
		val->intval = val_int * 1000;	/* µA */
		return 0;

	case POWER_SUPPLY_PROP_VOLTAGE_AVG:
		/* Pump ADC VBUS. VOLTAGE_NOW stays the battery side. */
		ret = bq2597x_get_vbus_mv(chip, &val_int);
		if (ret)
			return ret;
		val->intval = val_int * 1000;
		return 0;

	case POWER_SUPPLY_PROP_CURRENT_AVG:
		ret = bq2597x_get_ibus_ma(chip, &val_int);
		if (ret)
			return ret;
		val->intval = val_int * 1000;
		return 0;

	case POWER_SUPPLY_PROP_INPUT_VOLTAGE_LIMIT:
		val->intval = chip->bus_ovp_th_mv * 1000;	/* µV */
		return 0;

	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		val->intval = chip->bus_ocp_th_ma * 1000;	/* µA */
		return 0;

	case POWER_SUPPLY_PROP_TEMP:
		ret = bq2597x_get_tdie_tenth_c(chip, &val_int);
		if (ret)
			return ret;
		val->intval = val_int;		/* 0.1 °C */
		return 0;

	case POWER_SUPPLY_PROP_HEALTH:
		ret = regmap_read(chip->regmap, 0x11, &reg);
		if (!ret && (reg & 0xf7)) {
			val->intval = POWER_SUPPLY_HEALTH_UNSPEC_FAILURE;
			return 0;
		}
		ret = regmap_read(chip->regmap, 0x2c, &reg);
		if (!ret && (reg & 0x08)) {
			val->intval = POWER_SUPPLY_HEALTH_OVERVOLTAGE;
			return 0;
		}
		ret = regmap_read(chip->regmap, 0x0d, &reg);
		if (!ret && (reg & (BIT(5) | BIT(4)))) {
			val->intval = POWER_SUPPLY_HEALTH_OVERHEAT;
			return 0;
		}
		val->intval = POWER_SUPPLY_HEALTH_GOOD;
		return 0;

	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = chip->master ? "bq2597x-master" : "bq2597x-slave";
		return 0;

	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = chip->is_sc8551 ? "southchip" : "ti";
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

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		return regmap_update_bits(chip->regmap, BQ2597X_REG_0C, BQ2597X_CHG_EN,
					  val->intval ? BQ2597X_CHG_EN : 0);

	case POWER_SUPPLY_PROP_INPUT_VOLTAGE_LIMIT: {
		u32 mv = val->intval / 1000;
		u8 reg_val;

		if (mv < BQ2597X_BUS_OVP_BASE_MV)
			mv = BQ2597X_BUS_OVP_BASE_MV;
		reg_val = (mv - BQ2597X_BUS_OVP_BASE_MV) / BQ2597X_BUS_OVP_LSB_MV;
		chip->bus_ovp_th_mv = mv;
		return regmap_update_bits(chip->regmap, BQ2597X_REG_06,
					  BQ2597X_BUS_OVP_MASK, reg_val);
	}

	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT: {
		u32 ma = val->intval / 1000;
		u8 reg_val;

		if (ma < BQ2597X_BUS_OCP_BASE_MA)
			ma = BQ2597X_BUS_OCP_BASE_MA;
		reg_val = (ma - BQ2597X_BUS_OCP_BASE_MA) / BQ2597X_BUS_OCP_LSB_MA;
		chip->bus_ocp_th_ma = ma;
		return regmap_update_bits(chip->regmap, BQ2597X_REG_08,
					  BQ2597X_BUS_OCP_MASK, reg_val);
	}

	default:
		return -EINVAL;
	}
}

static int bq2597x_prop_is_writeable(struct power_supply *psy,
				     enum power_supply_property psp)
{
	return psp == POWER_SUPPLY_PROP_ONLINE ||
	       psp == POWER_SUPPLY_PROP_INPUT_VOLTAGE_LIMIT ||
	       psp == POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT;
}

static const enum power_supply_property bq2597x_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_VOLTAGE_AVG,
	POWER_SUPPLY_PROP_CURRENT_AVG,
	POWER_SUPPLY_PROP_INPUT_VOLTAGE_LIMIT,
	POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,
	POWER_SUPPLY_PROP_TEMP,
	POWER_SUPPLY_PROP_HEALTH,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};

static const struct power_supply_desc bq2597x_desc_master = {
	.name = "bq2597x-master",
	.type = POWER_SUPPLY_TYPE_MAINS,
	.properties = bq2597x_props,
	.num_properties = ARRAY_SIZE(bq2597x_props),
	.get_property = bq2597x_get_property,
	.set_property = bq2597x_set_property,
	.property_is_writeable = bq2597x_prop_is_writeable,
};

static const struct power_supply_desc bq2597x_desc_slave = {
	.name = "bq2597x-slave",
	.type = POWER_SUPPLY_TYPE_MAINS,
	.properties = bq2597x_props,
	.num_properties = ARRAY_SIZE(bq2597x_props),
	.get_property = bq2597x_get_property,
	.set_property = bq2597x_set_property,
	.property_is_writeable = bq2597x_prop_is_writeable,
};

/* Sysfs helper attributes for direct telemetry inspection */
static struct bq2597x *bq2597x_from_psy_dev(struct device *dev)
{
	struct power_supply *psy = dev_get_drvdata(dev);

	return power_supply_get_drvdata(psy);
}

static ssize_t vbus_voltage_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct bq2597x *chip = bq2597x_from_psy_dev(dev);
	int mv = 0;
	int ret = bq2597x_get_vbus_mv(chip, &mv);

	if (ret)
		return ret;
	return sysfs_emit(buf, "%d\n", mv);
}
static DEVICE_ATTR_RO(vbus_voltage);

static ssize_t ibus_current_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct bq2597x *chip = bq2597x_from_psy_dev(dev);
	int ma = 0;
	int ret = bq2597x_get_ibus_ma(chip, &ma);

	if (ret)
		return ret;
	return sysfs_emit(buf, "%d\n", ma);
}
static DEVICE_ATTR_RO(ibus_current);

static ssize_t vbat_voltage_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct bq2597x *chip = bq2597x_from_psy_dev(dev);
	int mv = 0;
	int ret = bq2597x_get_vbat_mv(chip, &mv);

	if (ret)
		return ret;
	return sysfs_emit(buf, "%d\n", mv);
}
static DEVICE_ATTR_RO(vbat_voltage);

static ssize_t ibat_current_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct bq2597x *chip = bq2597x_from_psy_dev(dev);
	int ma = 0;
	int ret = bq2597x_get_ibat_ma(chip, &ma);

	if (ret)
		return ret;
	return sysfs_emit(buf, "%d\n", ma);
}
static DEVICE_ATTR_RO(ibat_current);

static ssize_t die_temperature_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct bq2597x *chip = bq2597x_from_psy_dev(dev);
	int temp = 0;
	int ret = bq2597x_get_tdie_tenth_c(chip, &temp);

	if (ret)
		return ret;
	return sysfs_emit(buf, "%d\n", temp);
}
static DEVICE_ATTR_RO(die_temperature);

static ssize_t reg_dump_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct bq2597x *chip = bq2597x_from_psy_dev(dev);
	ssize_t count = 0;
	unsigned int val;
	u8 reg;

	for (reg = 0x00; reg <= 0x15; reg++) {
		if (regmap_read(chip->regmap, reg, &val) == 0)
			count += sysfs_emit_at(buf, count, "0x%02x: 0x%02x\n", reg, val);
	}
	return count;
}
static DEVICE_ATTR_RO(reg_dump);

static struct attribute *bq2597x_attrs[] = {
	&dev_attr_vbus_voltage.attr,
	&dev_attr_ibus_current.attr,
	&dev_attr_vbat_voltage.attr,
	&dev_attr_ibat_current.attr,
	&dev_attr_die_temperature.attr,
	&dev_attr_reg_dump.attr,
	NULL,
};
ATTRIBUTE_GROUPS(bq2597x);

static int bq2597x_hw_init(struct bq2597x *chip)
{
	struct device_node *node = chip->dev->of_node;
	u8 reg_val;
	int ret;

	/* Parse protective thresholds from device tree */
	if (of_property_read_u32(node, "ti,bq2597x,bat-ovp-threshold", &chip->bat_ovp_th_mv))
		chip->bat_ovp_th_mv = 4550;

	if (of_property_read_u32(node, "ti,bq2597x,bus-ovp-threshold", &chip->bus_ovp_th_mv))
		chip->bus_ovp_th_mv = 12000;

	if (of_property_read_u32(node, "ti,bq2597x,bus-ocp-threshold", &chip->bus_ocp_th_ma))
		chip->bus_ocp_th_ma = 3800;

	if (of_property_read_u32(node, "ti,bq2597x,ac-ovp-threshold", &chip->ac_ovp_th_v))
		chip->ac_ovp_th_v = 14;
	if (chip->is_sc8551)
		of_property_read_u32(node, "sc8551,ac-ovp-threshold", &chip->ac_ovp_th_v);

	/* 1. BAT_OVP */
	if (chip->bat_ovp_th_mv >= BQ2597X_BAT_OVP_BASE_MV) {
		reg_val = (chip->bat_ovp_th_mv - BQ2597X_BAT_OVP_BASE_MV) / BQ2597X_BAT_OVP_LSB_MV;
		regmap_update_bits(chip->regmap, BQ2597X_REG_00, BQ2597X_BAT_OVP_MASK, reg_val);
	}

	/* 2. BUS_OVP */
	if (chip->bus_ovp_th_mv >= BQ2597X_BUS_OVP_BASE_MV) {
		reg_val = (chip->bus_ovp_th_mv - BQ2597X_BUS_OVP_BASE_MV) / BQ2597X_BUS_OVP_LSB_MV;
		regmap_update_bits(chip->regmap, BQ2597X_REG_06, BQ2597X_BUS_OVP_MASK, reg_val);
	}

	/* 3. BUS_OCP */
	if (chip->bus_ocp_th_ma >= BQ2597X_BUS_OCP_BASE_MA) {
		reg_val = (chip->bus_ocp_th_ma - BQ2597X_BUS_OCP_BASE_MA) / BQ2597X_BUS_OCP_LSB_MA;
		regmap_update_bits(chip->regmap, BQ2597X_REG_08, BQ2597X_BUS_OCP_MASK, reg_val);
	}

	/* Stock alarm points: back off before the hard OVP/OCP. */
	{
		u32 ovp_alm = 11000, ocp_alm = chip->master ? 3500 : 3000;

		of_property_read_u32(node, "ti,bq2597x,bus-ovp-alarm-threshold", &ovp_alm);
		of_property_read_u32(node, "ti,bq2597x,bus-ocp-alarm-threshold", &ocp_alm);
		if (ovp_alm >= 6000) {
			reg_val = (ovp_alm - 6000) / 50;
			regmap_update_bits(chip->regmap, 0x07, 0xff, reg_val & 0x7f);
		}
		reg_val = ocp_alm / 50;
		regmap_update_bits(chip->regmap, 0x09, 0xff, reg_val & 0x7f);
	}

	/* 4. AC_OVP. 6.5 V is the reserved code 0x7; otherwise 11 V + 1 V/LSB. */
	if (chip->ac_ovp_th_v == 65)
		reg_val = 0x07;
	else if (chip->ac_ovp_th_v <= BQ2597X_AC_OVP_BASE_V)
		reg_val = 0;
	else
		reg_val = chip->ac_ovp_th_v - BQ2597X_AC_OVP_BASE_V;
	regmap_update_bits(chip->regmap, BQ2597X_REG_05, BQ2597X_AC_OVP_MASK,
			   reg_val & BQ2597X_AC_OVP_MASK);

	/* 5. Disable hardware watchdog to prevent charge interruption in non-petting idle */
	regmap_update_bits(chip->regmap, BQ2597X_REG_0B, BQ2597X_WD_DIS_BIT, BQ2597X_WD_DIS_BIT);

	/* 6. Set Master / Slave role on REG 0x0C */
	reg_val = chip->master ? BQ2597X_MS_MASTER : BQ2597X_MS_SLAVE;
	regmap_update_bits(chip->regmap, BQ2597X_REG_0C, BQ2597X_MS_MASK, reg_val);

	/* Stock init_regulation(): IBAT 200 mA, VBAT 50 mV, regulation on. */
	regmap_update_bits(chip->regmap, 0x2c, 0xf0, 0);
	regmap_update_bits(chip->regmap, 0x2b, 0x10, 0x10);

	if (chip->is_sc8551)
		regmap_write(chip->regmap, 0x34, 0x01);

	/* 7. Enable ADC (continuous mode, averaged samples) */
	ret = regmap_write(chip->regmap, BQ2597X_REG_14, BQ2597X_ADC_EN | BQ2597X_ADC_AVG_EN);
	if (ret)
		dev_warn(chip->dev, "failed to enable ADC: %d\n", ret);

	/* 8. Enable all ADC channels (0x00 means all channels enabled) */
	regmap_write(chip->regmap, BQ2597X_REG_15, 0x00);

	return 0;
}

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
	chip->dev = &client->dev;
	chip->master = of_property_read_bool(client->dev.of_node, "ti,bq2597x,master");

	chip->regmap = devm_regmap_init_i2c(client, &bq2597x_regmap_config);
	if (IS_ERR(chip->regmap))
		return PTR_ERR(chip->regmap);

	ret = regmap_read(chip->regmap, BQ2597X_REG_13, &id);
	if (ret)
		return dev_err_probe(&client->dev, ret, "chip id read failed\n");

	chip->chip_id = id;
	chip->is_sc8551 = (id == SC8551_DEVICE_ID || id == SC8551A_DEVICE_ID);

	if (id != BQ25970_DEVICE_ID && !chip->is_sc8551)
		dev_warn(&client->dev, "unexpected device id 0x%02x\n", id);

	ret = bq2597x_hw_init(chip);
	if (ret)
		dev_warn(&client->dev, "hardware init incomplete: %d\n", ret);

	psy_cfg.drv_data = chip;
	psy_cfg.fwnode = dev_fwnode(&client->dev);
	psy_cfg.attr_grp = bq2597x_groups;
	chip->psy = devm_power_supply_register(&client->dev,
					       chip->master ? &bq2597x_desc_master :
							      &bq2597x_desc_slave,
					       &psy_cfg);
	if (IS_ERR(chip->psy))
		return PTR_ERR(chip->psy);

	i2c_set_clientdata(client, chip);
	dev_info(&client->dev, "%s %s (id=0x%02x) ready\n",
		 chip->is_sc8551 ? "SC8551" : "BQ25970",
		 chip->master ? "master" : "slave", id);
	return 0;
}

static const struct of_device_id bq2597x_of_match[] = {
	{ .compatible = "ti,bq25970" },
	{ .compatible = "ti,bq2597x-master" },
	{ .compatible = "ti,bq2597x-slave" },
	{ .compatible = "sc,sc8551" },
	{ .compatible = "sc,sc8551a" },
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

MODULE_DESCRIPTION("TI BQ25970 / SC8551 charge pump driver (dagu)");
MODULE_LICENSE("GPL");
