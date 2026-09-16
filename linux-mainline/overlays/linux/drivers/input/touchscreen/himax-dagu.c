// SPDX-License-Identifier: GPL-2.0-only
/*
 * Himax HX83121 SPI touch for Xiaomi Pad 5 Pro 12.4 (dagu).
 *
 * Pins from CAF &qupv3_se4_spi: gpio8–11 = QUP L0–L3
 *   L0/gpio8=MISO L1/gpio9=MOSI L2/gpio10=SCLK L3/gpio11=CS,
 * IRQ GPIO39, RST GPIO100 (owned by the panel), 1600×2560.
 *
 * Bus is QUP0 SE4 GENI SPI FIFO: per-SE IRAM + skip-wrapper, never
 * wrapper CSR / GPI DMA / SE DMA. GPIO100 is panel tp-reset — do not bind.
 *
 * Protocol from CAF hxchipset himax_platform.c / himax_ic_HX83121.c:
 *   spi->mode = SPI_MODE_3 (DT spi-cpha is overridden in the factory probe)
 *   read  cmd 0x30 via [0xF3, cmd, 0x00] + payload
 *   10 fingers × 4 bytes; HX_TOUCH_INFO_POINT_CNT = 52 for HX_MAX_PT=10.
 *
 * LEVEL_LOW + a still-low IRQ must not emit a lift then a new tracking
 * ID — GNOME OSK then types one letter per checksum-fail / 0xff / n=0.
 */

#include <linux/cpufreq.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/input/touchscreen.h>
#include <linux/interrupt.h>
#include <linux/irq.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_qos.h>
#include <linux/spi/spi.h>
#include <linux/workqueue.h>

#define HIMAX_MAX_FINGERS	10
#define HIMAX_EVENT_LEN		56
/* CAF himax_mcu_calcTouchDataSize: HX_MAX_PT=10 → 10*4 + 3*4 = 52 */
#define HIMAX_POINT_CNT		52
#define HIMAX_BUS_R_HLEN	3
#define HIMAX_EVENT_CMD		0x30
/* CAF FIX_HX_TOUCHSCREEN_RATIO: FW reports 8× display coords. */
#define HIMAX_TOUCHSCREEN_RATIO	8
#define HIMAX_IRQ_DRAIN		8
#define HIMAX_LIFT_MS		80
#define HIMAX_BOOST_MS		180
#define HIMAX_CPU_SILVER_HOLD	1248000
#define HIMAX_CPU_GOLD_HOLD	1766400
#define HIMAX_CPU_PRIME_HOLD	1977600
#define HIMAX_GPU_HOLD_KHZ	670000

struct himax_dagu {
	struct spi_device *spi;
	struct input_dev *input;
	struct delayed_work irq_work;
	struct delayed_work lift_work;
	struct delayed_work boost_work;
	struct mutex lock;
	struct freq_qos_request qos_silver;
	struct freq_qos_request qos_gold;
	struct freq_qos_request qos_prime;
	struct dev_pm_qos_request qos_gpu;
	struct device *gpu;
	u32 max_x;
	u32 max_y;
	u8 xfer[HIMAX_BUS_R_HLEN + HIMAX_EVENT_LEN];
	u8 empty_streak;
	bool fingers_down;
	bool boost_on;
	bool qos_ready;
	unsigned long lift_deadline;
};

static int himax_qos_add_cpu(struct freq_qos_request *req, unsigned int cpu,
			     unsigned int khz)
{
	struct cpufreq_policy *policy;
	int ret;

	policy = cpufreq_cpu_get(cpu);
	if (!policy)
		return -ENODEV;
	ret = freq_qos_add_request(&policy->constraints, req, FREQ_QOS_MIN, khz);
	cpufreq_cpu_put(policy);
	return ret;
}

static void himax_qos_init(struct himax_dagu *ts)
{
	ts->gpu = bus_find_device_by_name(&platform_bus_type, NULL,
					  "3d00000.gpu");
	if (ts->gpu &&
	    dev_pm_qos_add_request(ts->gpu, &ts->qos_gpu,
				   DEV_PM_QOS_MIN_FREQUENCY, 0)) {
		put_device(ts->gpu);
		ts->gpu = NULL;
	}
	/* Extra vote of 0 until a finger is down — do not pin idle floors. */
	if (himax_qos_add_cpu(&ts->qos_silver, 0, 0))
		return;
	himax_qos_add_cpu(&ts->qos_gold, 4, 0);
	himax_qos_add_cpu(&ts->qos_prime, 7, 0);
	ts->qos_ready = true;
}

static void himax_boost_apply(struct himax_dagu *ts, bool on)
{
	if (!ts->qos_ready || on == ts->boost_on)
		return;
	ts->boost_on = on;
	if (freq_qos_request_active(&ts->qos_silver))
		freq_qos_update_request(&ts->qos_silver,
					on ? HIMAX_CPU_SILVER_HOLD : 0);
	if (freq_qos_request_active(&ts->qos_gold))
		freq_qos_update_request(&ts->qos_gold,
					on ? HIMAX_CPU_GOLD_HOLD : 0);
	if (freq_qos_request_active(&ts->qos_prime))
		freq_qos_update_request(&ts->qos_prime,
					on ? HIMAX_CPU_PRIME_HOLD : 0);
	if (ts->gpu)
		dev_pm_qos_update_request(&ts->qos_gpu,
					  on ? HIMAX_GPU_HOLD_KHZ : 0);
}

static void himax_boost_workfn(struct work_struct *work)
{
	struct himax_dagu *ts = container_of(to_delayed_work(work),
					     struct himax_dagu, boost_work);

	himax_boost_apply(ts, false);
}

static void himax_boost_touch(struct himax_dagu *ts, bool down)
{
	if (down) {
		cancel_delayed_work(&ts->boost_work);
		himax_boost_apply(ts, true);
	} else {
		mod_delayed_work(system_wq, &ts->boost_work,
				 msecs_to_jiffies(HIMAX_BOOST_MS));
	}
}

static int himax_bus_read(struct himax_dagu *ts, u8 cmd, u8 *buf, u32 len)
{
	struct spi_transfer t = { };
	struct spi_message m;
	int ret;

	if (len > HIMAX_EVENT_LEN)
		return -EINVAL;

	mutex_lock(&ts->lock);
	memset(ts->xfer, 0, HIMAX_BUS_R_HLEN + len);
	ts->xfer[0] = 0xF3;
	ts->xfer[1] = cmd;
	ts->xfer[2] = 0x00;
	t.tx_buf = ts->xfer;
	t.rx_buf = ts->xfer;
	t.len = HIMAX_BUS_R_HLEN + len;
	spi_message_init(&m);
	spi_message_add_tail(&t, &m);
	ret = spi_sync(ts->spi, &m);
	if (!ret)
		memcpy(buf, ts->xfer + HIMAX_BUS_R_HLEN, len);
	mutex_unlock(&ts->lock);
	return ret;
}

static bool himax_event_valid(const u8 *buf)
{
	int i;

	for (i = 0; i < HIMAX_EVENT_LEN; i++) {
		if (buf[i] != 0xff)
			return true;
	}
	return false;
}

/* CAF / mainline hx83112b: sum of the 56-byte event must be 0 mod 256. */
static bool himax_checksum_ok(const u8 *buf)
{
	u16 sum = 0;
	int i;

	for (i = 0; i < HIMAX_EVENT_LEN; i++)
		sum += buf[i];
	return (sum & 0xff) == 0;
}

static bool himax_irq_line_low(int irq)
{
	bool level = true;

	if (irq_get_irqchip_state(irq, IRQCHIP_STATE_LINE_LEVEL, &level))
		return false;
	return !level;
}

static int himax_point_count(const u8 *buf)
{
	int n = buf[HIMAX_POINT_CNT];

	if (n == 0xff)
		return 0;
	n &= 0x0f;
	if (n > HIMAX_MAX_FINGERS)
		n = HIMAX_MAX_FINGERS;
	return n;
}

static void himax_lift_unlocked(struct himax_dagu *ts)
{
	int i;

	if (!ts->fingers_down)
		return;
	for (i = 0; i < HIMAX_MAX_FINGERS; i++) {
		input_mt_slot(ts->input, i);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, false);
	}
	input_mt_sync_frame(ts->input);
	input_sync(ts->input);
	ts->fingers_down = false;
	ts->empty_streak = 0;
}

static void himax_lift_workfn(struct work_struct *work)
{
	struct himax_dagu *ts = container_of(to_delayed_work(work),
					     struct himax_dagu, lift_work);

	mutex_lock(&ts->lock);
	if (ts->fingers_down && time_before(jiffies, ts->lift_deadline)) {
		unsigned long left = ts->lift_deadline - jiffies;

		mutex_unlock(&ts->lock);
		mod_delayed_work(system_wq, &ts->lift_work, left);
		return;
	}
	himax_lift_unlocked(ts);
	mutex_unlock(&ts->lock);
	himax_boost_touch(ts, false);
}

static void himax_report(struct himax_dagu *ts, const u8 *buf)
{
	int i, n, active = 0;

	n = himax_point_count(buf);

	mutex_lock(&ts->lock);
	if (n == 0) {
		if (ts->fingers_down && ts->empty_streak < 1) {
			ts->empty_streak++;
			ts->lift_deadline = jiffies + msecs_to_jiffies(HIMAX_LIFT_MS);
			mod_delayed_work(system_wq, &ts->lift_work,
					 msecs_to_jiffies(HIMAX_LIFT_MS));
			mutex_unlock(&ts->lock);
			return;
		}
		cancel_delayed_work(&ts->lift_work);
		himax_lift_unlocked(ts);
		mutex_unlock(&ts->lock);
		himax_boost_touch(ts, false);
		return;
	}

	ts->empty_streak = 0;
	for (i = 0; i < HIMAX_MAX_FINGERS && active < n; i++) {
		u16 raw_x = (buf[i * 4] << 8) | buf[i * 4 + 1];
		u16 raw_y = (buf[i * 4 + 2] << 8) | buf[i * 4 + 3];
		u16 x = raw_x / HIMAX_TOUCHSCREEN_RATIO;
		u16 y = raw_y / HIMAX_TOUCHSCREEN_RATIO;

		if (raw_x == 0xffff || raw_y == 0xffff)
			continue;
		if (x > ts->max_x || y > ts->max_y)
			continue;

		input_mt_slot(ts->input, i);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, true);
		input_report_abs(ts->input, ABS_MT_POSITION_X, x);
		input_report_abs(ts->input, ABS_MT_POSITION_Y, y);
		active++;
	}

	input_mt_sync_frame(ts->input);
	input_sync(ts->input);
	ts->fingers_down = active > 0;
	if (ts->fingers_down) {
		ts->lift_deadline = jiffies + msecs_to_jiffies(HIMAX_LIFT_MS);
		mod_delayed_work(system_wq, &ts->lift_work,
				 msecs_to_jiffies(HIMAX_LIFT_MS));
	} else {
		cancel_delayed_work(&ts->lift_work);
	}
	mutex_unlock(&ts->lock);
	himax_boost_touch(ts, ts->fingers_down);
}

static irqreturn_t himax_irq(int irq, void *data)
{
	struct himax_dagu *ts = data;
	u8 buf[HIMAX_EVENT_LEN];
	u8 last[HIMAX_EVENT_LEN];
	bool have = false;
	int ret, loops = 0;

	/*
	 * spi-gpio + ONESHOT already stretches the masked window. Never
	 * printk on this path (cmdline has ignore_loglevel; console/fbcon
	 * stalls the thread and the next falling edge is lost → 断触).
	 * Drain while the line is still low and keep the last checksum-ok
	 * frame so a mid-burst 0xff/n=0 glitch cannot cycle tracking IDs.
	 */
	do {
		ret = himax_bus_read(ts, HIMAX_EVENT_CMD, buf, sizeof(buf));
		if (ret)
			break;
		if (himax_event_valid(buf) && himax_checksum_ok(buf)) {
			memcpy(last, buf, sizeof(last));
			have = true;
		}
	} while (++loops < HIMAX_IRQ_DRAIN && himax_irq_line_low(irq));

	if (have)
		himax_report(ts, last);
	return IRQ_HANDLED;
}

static void himax_enable_irq(struct work_struct *work)
{
	struct himax_dagu *ts = container_of(to_delayed_work(work),
					     struct himax_dagu, irq_work);

	enable_irq(ts->spi->irq);
	dev_info(&ts->spi->dev, "HX83121 IRQ enabled\n");
}

static int himax_probe(struct spi_device *spi)
{
	struct himax_dagu *ts;
	struct input_dev *input;
	u32 coords[4] = { 0, 1600, 0, 2560 };
	int irq, ret;

	ts = devm_kzalloc(&spi->dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;
	ts->spi = spi;
	mutex_init(&ts->lock);
	INIT_DELAYED_WORK(&ts->irq_work, himax_enable_irq);
	INIT_DELAYED_WORK(&ts->lift_work, himax_lift_workfn);
	INIT_DELAYED_WORK(&ts->boost_work, himax_boost_workfn);
	himax_qos_init(ts);
	/* CAF himax_chip_common_probe: spi->mode = SPI_MODE_3, not DT CPHA. */
	spi->mode = SPI_MODE_3;
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	if (ret)
		return ret;

	of_property_read_u32(spi->dev.of_node, "touchscreen-size-x", &coords[1]);
	of_property_read_u32(spi->dev.of_node, "touchscreen-size-y", &coords[3]);
	device_property_read_u32_array(&spi->dev, "himax,display-coords", coords, 4);
	ts->max_x = coords[1];
	ts->max_y = coords[3];

	input = devm_input_allocate_device(&spi->dev);
	if (!input)
		return -ENOMEM;
	ts->input = input;
	input->name = "Himax HX83121";
	input->phys = "himax/spi";
	input_set_abs_params(input, ABS_MT_POSITION_X, 0, ts->max_x, 0, 0);
	input_set_abs_params(input, ABS_MT_POSITION_Y, 0, ts->max_y, 0, 0);
	ret = input_mt_init_slots(input, HIMAX_MAX_FINGERS,
				  INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED);
	if (ret)
		return ret;
	touchscreen_parse_properties(input, true, NULL);

	irq = spi->irq;
	if (irq <= 0)
		return dev_err_probe(&spi->dev, -EINVAL, "no IRQ\n");

	ret = input_register_device(input);
	if (ret)
		return ret;

	/*
	 * Delay IRQ until USB serial is up. A stuck SPI xfer on a line
	 * held by the in-cell FW must not bite the watchdog first.
	 * Trigger type comes from DT (LEVEL_LOW): EDGE+ONESHOT misses
	 * pulses while spi-gpio is still in the thread.
	 */
	ret = devm_request_threaded_irq(&spi->dev, irq, NULL, himax_irq,
					IRQF_ONESHOT | IRQF_NO_AUTOEN,
					"himax-dagu", ts);
	if (ret)
		return ret;

	spi_set_drvdata(spi, ts);

	{
		u8 dump[HIMAX_EVENT_LEN];
		int i, dump_ret;

		msleep(20);
		dump_ret = himax_bus_read(ts, HIMAX_EVENT_CMD, dump, sizeof(dump));
		if (dump_ret) {
			dev_err(&spi->dev, "HX83121 event30 probe read failed: %d\n",
				dump_ret);
		} else {
			dev_info(&spi->dev,
				 "HX83121 hdr %02x %02x %02x  n52=%02x xy=%02x%02x %02x%02x\n",
				 ts->xfer[0], ts->xfer[1], ts->xfer[2],
				 dump[HIMAX_POINT_CNT], dump[0], dump[1],
				 dump[2], dump[3]);
			for (i = 0; i < HIMAX_EVENT_LEN && dump[i] == 0xff; i++)
				;
			if (i == HIMAX_EVENT_LEN)
				dev_err(&spi->dev,
					"HX83121 all 0xff — MOSI/MISO/CLK/CS order or CS polarity\n");
		}
	}

	schedule_delayed_work(&ts->irq_work, HZ * 2);
	dev_info(&spi->dev, "HX83121 %ux%u irq %d\n", ts->max_x, ts->max_y, irq);
	return 0;
}

static void himax_remove(struct spi_device *spi)
{
	struct himax_dagu *ts = spi_get_drvdata(spi);

	if (!ts)
		return;
	cancel_delayed_work_sync(&ts->irq_work);
	cancel_delayed_work_sync(&ts->lift_work);
	cancel_delayed_work_sync(&ts->boost_work);
	himax_boost_apply(ts, false);
	if (freq_qos_request_active(&ts->qos_silver))
		freq_qos_remove_request(&ts->qos_silver);
	if (freq_qos_request_active(&ts->qos_gold))
		freq_qos_remove_request(&ts->qos_gold);
	if (freq_qos_request_active(&ts->qos_prime))
		freq_qos_remove_request(&ts->qos_prime);
	if (ts->gpu) {
		dev_pm_qos_remove_request(&ts->qos_gpu);
		put_device(ts->gpu);
		ts->gpu = NULL;
	}
}

static const struct of_device_id himax_of_match[] = {
	{ .compatible = "himax,hx83121-dagu" },
	{ .compatible = "himax,hxcommon" },
	{ }
};
MODULE_DEVICE_TABLE(of, himax_of_match);

static const struct spi_device_id himax_id[] = {
	{ "hx83121-dagu", 0 },
	{ "hxcommon", 0 },
	{ }
};
MODULE_DEVICE_TABLE(spi, himax_id);

static struct spi_driver himax_driver = {
	.probe = himax_probe,
	.remove = himax_remove,
	.id_table = himax_id,
	.driver = {
		.name = "himax-dagu",
		.of_match_table = himax_of_match,
	},
};
module_spi_driver(himax_driver);

MODULE_DESCRIPTION("Himax HX83121 SPI touchscreen (dagu)");
MODULE_LICENSE("GPL");
