// SPDX-License-Identifier: GPL-2.0-only
/*
 * Nanosic 803 keyboard MCU on Xiaomi dagu (I2C @ 0x4c).
 *
 * Hardware: QUP SE2 pads gpio115/116 (SDA/SCL). Do not enable GENI &i2c2 —
 * the same 0x988000 SE as uart2, and geni_se_init hangs this QHEE.
 * Power/IRQ from live Android DT: vdd GPIO127, reset GPIO141, sleep GPIO155,
 * data IRQ GPIO83 falling, wakeup GPIO46 rising.
 *
 * The MCU speaks a 68-byte I2C envelope (dummy write of the 7-bit address,
 * then payload starting 0x57). HID report IDs 0x05/0x02/0x19/0x06 are
 * injected into four virtual HID devices. Descriptors are the live Android
 * dump (VID 15d9), not the CAF 11" 2879×1799 touchpad map.
 */

#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/hid.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/pm.h>
#include <linux/pm_wakeup.h>
#include <linux/slab.h>

#define NANOSIC_WRITE_LEN	66
#define NANOSIC_READ_LEN	68

#define NANOSIC_PKT_SYNC	0x57
#define NANOSIC_TYPE_MOUSE	0x02
#define NANOSIC_TYPE_KEYBOARD	0x05
#define NANOSIC_TYPE_CONSUMER	0x06
#define NANOSIC_TYPE_TOUCH	0x19
#define NANOSIC_TYPE_VENDOR16	0x22
#define NANOSIC_TYPE_VENDOR32	0x23
#define NANOSIC_TYPE_VENDOR24	0x24
#define NANOSIC_TYPE_VENDOR26	0x26

#define NANOSIC_FIELD_HOST	0x80
#define NANOSIC_FIELD_803X	0x18
#define NANOSIC_FIELD_176X	0x38

#define NANOSIC_HID_KEYBOARD	0
#define NANOSIC_HID_MOUSE	1
#define NANOSIC_HID_TOUCH	2
#define NANOSIC_HID_CONSUMER	3
#define NANOSIC_HID_N		4

struct nanosic_hid_desc {
	const char *name;
	u16 product;
	const u8 *rd;
	unsigned int rd_size;
};

struct nanosic_kb {
	struct i2c_client *client;
	struct mutex xfer_lock;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *status_gpio;
	struct gpio_desc *vdd_gpio;
	struct gpio_desc *sleep_gpio;
	struct input_dev *wakeup;
	struct hid_device *hdev[NANOSIC_HID_N];
	int wakeup_irq;
	/* HID report ID 5 LED byte; bit 1 is Caps Lock (keyboard lamp). */
	u8 led_state;
};

/*
 * Live Android /sys/bus/hid/devices/0006:15D9:00A3.0001/report_descriptor
 * (boot-protocol keyboard, report ID 5).
 */
static const u8 nanosic_rd_keyboard[] = {
	0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x85, 0x05, 0x05, 0x07, 0x19, 0xe0,
	0x29, 0xe7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
	0x81, 0x03, 0x95, 0x05, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
	0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00,
	0x26, 0xa4, 0x00, 0x05, 0x07, 0x19, 0x00, 0x2a, 0xa4, 0x00, 0x81, 0x00,
	0xc0,
};

/* 0006:15D9:00A2.0002 — relative mouse, report ID 2. */
static const u8 nanosic_rd_mouse[] = {
	0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xa1, 0x00,
	0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05,
	0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x03, 0x81, 0x01, 0x05, 0x01,
	0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x16, 0x00, 0x80, 0x26, 0xff, 0x7f,
	0x75, 0x10, 0x95, 0x03, 0x81, 0x06, 0xc0, 0xc0,
};

/*
 * 0006:15D9:00A1.0003 — digitizer touchpad, report ID 0x19.
 * Logical max 2560×1600 (dagu landscape). CAF source still has 2879×1799.
 */
static const u8 nanosic_rd_touch[] = {
	0x05, 0x0d, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x19, 0x15, 0x00, 0x25, 0x01,
	0x35, 0x00, 0x45, 0x01, 0x75, 0x01, 0x95, 0x02, 0x05, 0x09, 0x09, 0x01,
	0x09, 0x02, 0x81, 0x02, 0x95, 0x06, 0x81, 0x01, 0x05, 0x0d, 0x09, 0x22,
	0xa1, 0x02, 0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01,
	0x81, 0x02, 0x09, 0x32, 0x81, 0x02, 0x09, 0x47, 0x81, 0x02, 0x95, 0x05,
	0x81, 0x03, 0x75, 0x08, 0x09, 0x51, 0x95, 0x01, 0x81, 0x02, 0x05, 0x01,
	0x15, 0x00, 0x26, 0x00, 0x0a, 0x75, 0x10, 0x55, 0x0d, 0x65, 0x13, 0x09,
	0x30, 0x35, 0x00, 0x46, 0x00, 0x0a, 0x81, 0x02, 0x09, 0x31, 0x26, 0x40,
	0x06, 0x46, 0x40, 0x06, 0x81, 0x02, 0xc0, 0xa1, 0x02, 0x05, 0x0d, 0x09,
	0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02, 0x09,
	0x32, 0x81, 0x02, 0x09, 0x47, 0x81, 0x02, 0x95, 0x05, 0x81, 0x03, 0x75,
	0x08, 0x09, 0x51, 0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x15, 0x00, 0x26,
	0x00, 0x0a, 0x75, 0x10, 0x55, 0x0d, 0x65, 0x13, 0x09, 0x30, 0x35, 0x00,
	0x46, 0x00, 0x0a, 0x81, 0x02, 0x09, 0x31, 0x26, 0x40, 0x06, 0x46, 0x40,
	0x06, 0x81, 0x02, 0xc0, 0xa1, 0x02, 0x05, 0x0d, 0x09, 0x42, 0x15, 0x00,
	0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02, 0x09, 0x32, 0x81, 0x02,
	0x09, 0x47, 0x81, 0x02, 0x95, 0x05, 0x81, 0x03, 0x75, 0x08, 0x09, 0x51,
	0x95, 0x01, 0x81, 0x02, 0x05, 0x01, 0x15, 0x00, 0x26, 0x00, 0x0a, 0x75,
	0x10, 0x55, 0x0d, 0x65, 0x13, 0x09, 0x30, 0x35, 0x00, 0x46, 0x00, 0x0a,
	0x81, 0x02, 0x09, 0x31, 0x26, 0x40, 0x06, 0x46, 0x40, 0x06, 0x81, 0x02,
	0xc0, 0x05, 0x0d, 0x09, 0x54, 0x95, 0x01, 0x75, 0x08, 0x15, 0x00, 0x25,
	0x08, 0x81, 0x02, 0x09, 0x55, 0xb1, 0x02, 0xc0,
};

/* 0006:15D9:00A4.0004 — consumer control, report ID 6. */
static const u8 nanosic_rd_consumer[] = {
	0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x85, 0x06, 0x15, 0x00, 0x26, 0x80,
	0x03, 0x19, 0x00, 0x2a, 0x80, 0x03, 0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
	0xc0,
};

static const struct nanosic_hid_desc nanosic_hid_table[NANOSIC_HID_N] = {
	[NANOSIC_HID_KEYBOARD] = {
		.name = "Xiaomi Keyboard",
		.product = 0x00a3,
		.rd = nanosic_rd_keyboard,
		.rd_size = sizeof(nanosic_rd_keyboard),
	},
	[NANOSIC_HID_MOUSE] = {
		.name = "Xiaomi Mouse",
		.product = 0x00a2,
		.rd = nanosic_rd_mouse,
		.rd_size = sizeof(nanosic_rd_mouse),
	},
	[NANOSIC_HID_TOUCH] = {
		.name = "Xiaomi Touch",
		.product = 0x00a1,
		.rd = nanosic_rd_touch,
		.rd_size = sizeof(nanosic_rd_touch),
	},
	[NANOSIC_HID_CONSUMER] = {
		.name = "Xiaomi Consumer",
		.product = 0x00a4,
		.rd = nanosic_rd_consumer,
		.rd_size = sizeof(nanosic_rd_consumer),
	},
};

static const struct nanosic_hid_desc *nanosic_hid_desc_for(struct hid_device *hdev)
{
	unsigned int i;

	for (i = 0; i < NANOSIC_HID_N; i++) {
		if (nanosic_hid_table[i].product == hdev->product)
			return &nanosic_hid_table[i];
	}
	return NULL;
}

static struct nanosic_kb *nanosic_kb_from_hid(struct hid_device *hdev)
{
	return hdev->driver_data;
}

static int nanosic_hid_parse(struct hid_device *hdev)
{
	const struct nanosic_hid_desc *desc = nanosic_hid_desc_for(hdev);

	if (!desc)
		return -ENODEV;
	return hid_parse_report(hdev, (u8 *)desc->rd, desc->rd_size);
}

static int nanosic_hid_start(struct hid_device *hdev)
{
	return 0;
}

static void nanosic_hid_stop(struct hid_device *hdev)
{
	hdev->claimed = 0;
}

static int nanosic_hid_open(struct hid_device *hdev)
{
	return 0;
}

static void nanosic_hid_close(struct hid_device *hdev)
{
}

static int nanosic_hid_apply_leds(struct hid_device *hdev, unsigned char reportnum,
				  const u8 *buf, size_t len);

static int nanosic_hid_output_report(struct hid_device *hdev, __u8 *buf, size_t len)
{
	return nanosic_hid_apply_leds(hdev, buf && len ? buf[0] : 0, buf, len);
}

static int nanosic_hid_raw_request(struct hid_device *hdev, unsigned char reportnum,
				   __u8 *buf, size_t len, unsigned char rtype,
				   int reqtype)
{
	if (rtype == HID_OUTPUT_REPORT && reqtype == HID_REQ_SET_REPORT)
		return nanosic_hid_apply_leds(hdev, reportnum, buf, len);
	return 0;
}

static struct hid_ll_driver nanosic_hid_ll = {
	.parse = nanosic_hid_parse,
	.start = nanosic_hid_start,
	.stop = nanosic_hid_stop,
	.open = nanosic_hid_open,
	.close = nanosic_hid_close,
	.raw_request = nanosic_hid_raw_request,
	.output_report = nanosic_hid_output_report,
};

static void nanosic_hid_release(void *data)
{
	hid_destroy_device(data);
}

static int nanosic_hid_register(struct nanosic_kb *kb, unsigned int idx)
{
	const struct nanosic_hid_desc *desc = &nanosic_hid_table[idx];
	struct hid_device *hdev;
	int ret;

	hdev = hid_allocate_device();
	if (IS_ERR(hdev))
		return PTR_ERR(hdev);

	strscpy(hdev->name, desc->name, sizeof(hdev->name));
	hdev->ll_driver = &nanosic_hid_ll;
	hdev->bus = BUS_VIRTUAL;
	hdev->vendor = 0x15d9;
	hdev->product = desc->product;
	hdev->driver_data = kb;
	hdev->dev.parent = &kb->client->dev;

	ret = hid_add_device(hdev);
	if (ret) {
		hid_destroy_device(hdev);
		return ret;
	}

	ret = devm_add_action_or_reset(&kb->client->dev, nanosic_hid_release, hdev);
	if (ret)
		return ret;

	kb->hdev[idx] = hdev;
	return 0;
}

static int nanosic_read(struct nanosic_kb *kb, u8 *buf, size_t len)
{
	u8 dummy = kb->client->addr;
	struct i2c_msg msgs[2] = {
		{
			.addr = kb->client->addr,
			.flags = 0,
			.len = 1,
			.buf = &dummy,
		},
		{
			.addr = kb->client->addr,
			.flags = I2C_M_RD,
			.len = len,
			.buf = buf,
		},
	};
	int ret;

	mutex_lock(&kb->xfer_lock);
	ret = i2c_transfer(kb->client->adapter, msgs, 2);
	mutex_unlock(&kb->xfer_lock);
	if (ret == 2)
		return 0;
	return ret < 0 ? ret : -EIO;
}

static int nanosic_write(struct nanosic_kb *kb, const u8 *buf, size_t len)
{
	u8 tmp[1 + NANOSIC_WRITE_LEN];
	struct i2c_msg msg = {
		.addr = kb->client->addr,
		.flags = 0,
		.len = 1 + NANOSIC_WRITE_LEN,
		.buf = tmp,
	};
	int ret;

	if (len > NANOSIC_WRITE_LEN)
		return -EINVAL;

	tmp[0] = kb->client->addr;
	memcpy(tmp + 1, buf, len);
	if (len < NANOSIC_WRITE_LEN)
		memset(tmp + 1 + len, 0, NANOSIC_WRITE_LEN - len);

	mutex_lock(&kb->xfer_lock);
	ret = i2c_transfer(kb->client->adapter, &msg, 1);
	mutex_unlock(&kb->xfer_lock);
	if (ret == 1)
		return 0;
	return ret < 0 ? ret : -EIO;
}

static void nanosic_inject(struct nanosic_kb *kb, unsigned int idx, u8 *data, size_t len)
{
	if (!kb->hdev[idx] || !data || !len)
		return;
	hid_input_report(kb->hdev[idx], HID_INPUT_REPORT, data, len, 1);
}

static void nanosic_parse_vendor(struct nanosic_kb *kb, u8 *p, size_t len)
{
	u8 source, object, command;

	if (len < 5)
		return;
	source = p[2];
	object = p[3];
	command = p[4];
	if (command == 0x01 && source == NANOSIC_FIELD_803X &&
	    object == NANOSIC_FIELD_HOST && len >= 25)
		dev_info(&kb->client->dev, "803 version %.20s\n", p + 6);
}

static int nanosic_parse(struct nanosic_kb *kb, u8 *data, size_t len)
{
	u8 *p = data;
	size_t left = len;
	u8 first, third, type;

	if (left < 4)
		return -EINVAL;

	first = *p++;
	left--;
	if (first != NANOSIC_PKT_SYNC)
		return -EINVAL;

	p++; /* sequence */
	left--;

	third = *p++;
	left--;
	if (!third)
		return 0;
	if (third != 0x39 && third != 0x4a && third != 0x5b && third != 0x6c)
		return -EINVAL;

	while (left) {
		type = p[0];
		switch (type) {
		case NANOSIC_TYPE_KEYBOARD:
			if (left < 9)
				return 0;
			nanosic_inject(kb, NANOSIC_HID_KEYBOARD, p, 9);
			p += 9;
			left -= 9;
			break;
		case NANOSIC_TYPE_CONSUMER:
			if (left < 5)
				return 0;
			nanosic_inject(kb, NANOSIC_HID_CONSUMER, p, 5);
			p += 5;
			left -= 5;
			break;
		case NANOSIC_TYPE_MOUSE:
			if (left < 8)
				return 0;
			nanosic_inject(kb, NANOSIC_HID_MOUSE, p, 8);
			p += 8;
			left -= 8;
			break;
		case NANOSIC_TYPE_TOUCH:
			if (left < 21)
				return 0;
			nanosic_inject(kb, NANOSIC_HID_TOUCH, p, 21);
			p += 21;
			left -= 21;
			break;
		case NANOSIC_TYPE_VENDOR16:
			if (left < 16)
				return 0;
			nanosic_parse_vendor(kb, p, 16);
			p += 16;
			left -= 16;
			break;
		case NANOSIC_TYPE_VENDOR32:
			if (left < 32)
				return 0;
			nanosic_parse_vendor(kb, p, 32);
			p += 32;
			left -= 32;
			break;
		case NANOSIC_TYPE_VENDOR24:
		case NANOSIC_TYPE_VENDOR26:
			nanosic_parse_vendor(kb, p, left);
			return 0;
		default:
			return 0;
		}
	}
	return 0;
}

static void nanosic_checksum9(u8 *cmd)
{
	unsigned int i;

	cmd[9] = 0;
	for (i = 2; i < 9; i++)
		cmd[9] += cmd[i];
}

static int nanosic_write_retry(struct nanosic_kb *kb, const u8 *cmd, const char *what)
{
	int ret = -EIO;
	unsigned int attempt;

	for (attempt = 0; attempt < 5; attempt++) {
		ret = nanosic_write(kb, cmd, NANOSIC_WRITE_LEN);
		if (!ret)
			return 0;
		dev_err(&kb->client->dev, "%s write failed: %d (try %u)\n",
			what, ret, attempt + 1);
		msleep(100);
	}
	return ret;
}

/* Android nanodev resume: 0x4E 0x31 host→176x, checksum at byte 9. */
static int nanosic_cmd_176x(struct nanosic_kb *kb, u8 op, u8 a, u8 b, const char *what)
{
	u8 cmd[NANOSIC_WRITE_LEN] = {
		0x32, 0x00, 0x4e, 0x31, NANOSIC_FIELD_HOST, NANOSIC_FIELD_176X,
		op, a, b,
	};

	nanosic_checksum9(cmd);
	return nanosic_write_retry(kb, cmd, what);
}

/*
 * LineageOS Nanosic_set_caps_led: host→176x opcode 0x26, 0x01, on/off.
 * Same 9-byte frame as probe enable-0x26 (that one sends off).
 * HID report ID 5 LED byte: bit0 NumLock, bit1 Caps Lock, bit2 ScrollLock.
 */
static int nanosic_set_caps_led(struct nanosic_kb *kb, bool on)
{
	return nanosic_cmd_176x(kb, 0x26, 0x01, on ? 1 : 0, "caps-led");
}

static int nanosic_hid_apply_leds(struct hid_device *hdev, unsigned char reportnum,
				  const u8 *buf, size_t len)
{
	struct nanosic_kb *kb = nanosic_kb_from_hid(hdev);
	u8 leds;
	int ret;

	if (!kb || !buf || !len)
		return -EINVAL;
	if (len >= 2 && buf[0] == NANOSIC_TYPE_KEYBOARD)
		leds = buf[1];
	else if (reportnum == NANOSIC_TYPE_KEYBOARD)
		leds = buf[0];
	else
		return 0;

	kb->led_state = leds;
	ret = nanosic_set_caps_led(kb, !!(leds & BIT(1)));
	if (ret) {
		dev_err_ratelimited(&kb->client->dev, "caps-led write failed: %d\n",
				    ret);
		return ret;
	}
	return len;
}

static int nanosic_screen_on(struct nanosic_kb *kb)
{
	return nanosic_cmd_176x(kb, 0x25, 0x01, 0x01, "screen-on");
}

static int nanosic_read_version(struct nanosic_kb *kb)
{
	/* CAF Nanosic_i2c_read_version: 0x4F 0x30 host→803x. */
	u8 cmd[NANOSIC_WRITE_LEN] = {
		0x32, 0x00, 0x4f, 0x30, NANOSIC_FIELD_HOST, NANOSIC_FIELD_803X,
		0x01, 0x00, 0x18,
	};
	u8 rsp[NANOSIC_READ_LEN] = { 0 };
	int ret;
	unsigned int attempt;

	for (attempt = 0; attempt < 5; attempt++) {
		ret = nanosic_write(kb, cmd, sizeof(cmd));
		if (ret) {
			dev_err(&kb->client->dev, "version query write failed: %d (try %u)\n",
				ret, attempt + 1);
			msleep(100);
			continue;
		}
		msleep(2);
		ret = nanosic_read(kb, rsp, sizeof(rsp));
		if (ret) {
			dev_err(&kb->client->dev, "version query read failed: %d (try %u)\n",
				ret, attempt + 1);
			msleep(100);
			continue;
		}
		nanosic_parse(kb, rsp, sizeof(rsp));
		dev_info(&kb->client->dev, "version rsp %16ph\n", rsp);
		return 0;
	}
	return ret;
}

static int nanosic_init_mcu(struct nanosic_kb *kb)
{
	int ret;

	ret = nanosic_cmd_176x(kb, 0x26, 0x01, 0x00, "enable-0x26");
	if (ret)
		return ret;
	ret = nanosic_cmd_176x(kb, 0x23, 0x01, 0x00, "enable-0x23");
	if (ret)
		return ret;
	ret = nanosic_screen_on(kb);
	if (ret)
		return ret;
	ret = nanosic_read_version(kb);
	if (ret)
		return ret;
	return 0;
}

static void nanosic_power_on(struct nanosic_kb *kb)
{
	gpiod_set_value_cansleep(kb->reset_gpio, 0);
	gpiod_set_value_cansleep(kb->sleep_gpio, 0);
	if (kb->vdd_gpio)
		gpiod_set_value_cansleep(kb->vdd_gpio, 1);
	msleep(2);
	gpiod_set_value_cansleep(kb->reset_gpio, 1);
	gpiod_set_value_cansleep(kb->sleep_gpio, 1);
	/* CAF Nanosic_GPIO_reset waits 500ms after release for I2C. */
	msleep(100);
}

static irqreturn_t nanosic_irq(int irq, void *data)
{
	struct nanosic_kb *kb = data;
	u8 buf[NANOSIC_READ_LEN] = { 0 };
	int ret;

	ret = nanosic_read(kb, buf, sizeof(buf));
	if (ret) {
		dev_err_ratelimited(&kb->client->dev, "i2c read failed: %d\n", ret);
		return IRQ_HANDLED;
	}
	nanosic_parse(kb, buf, sizeof(buf));
	return IRQ_HANDLED;
}

static irqreturn_t nanosic_wakeup_irq(int irq, void *data)
{
	struct nanosic_kb *kb = data;

	pm_wakeup_event(&kb->client->dev, 1000);
	if (kb->wakeup) {
		input_report_key(kb->wakeup, KEY_WAKEUP, 1);
		input_sync(kb->wakeup);
		input_report_key(kb->wakeup, KEY_WAKEUP, 0);
		input_sync(kb->wakeup);
	}
	return IRQ_HANDLED;
}

static int nanosic_suspend(struct device *dev)
{
	struct nanosic_kb *kb = dev_get_drvdata(dev);

	if (!device_may_wakeup(dev))
		return 0;
	enable_irq_wake(kb->client->irq);
	if (kb->wakeup_irq > 0)
		enable_irq_wake(kb->wakeup_irq);
	return 0;
}

static int nanosic_resume(struct device *dev)
{
	struct nanosic_kb *kb = dev_get_drvdata(dev);

	if (!device_may_wakeup(dev))
		return 0;
	disable_irq_wake(kb->client->irq);
	if (kb->wakeup_irq > 0)
		disable_irq_wake(kb->wakeup_irq);
	gpiod_set_value_cansleep(kb->sleep_gpio, 1);
	if (nanosic_init_mcu(kb)) {
		dev_err(dev, "mcu re-init after resume failed\n");
		return 0;
	}
	if ((kb->led_state & BIT(1)) && nanosic_set_caps_led(kb, true))
		dev_err(dev, "caps-led restore after resume failed\n");
	return 0;
}

static DEFINE_SIMPLE_DEV_PM_OPS(nanosic_pm_ops, nanosic_suspend, nanosic_resume);

static int nanosic_probe(struct i2c_client *client)
{
	struct nanosic_kb *kb;
	unsigned int i;
	int irq, ret;

	if (!client->irq)
		return dev_err_probe(&client->dev, -EINVAL, "missing data irq\n");

	kb = devm_kzalloc(&client->dev, sizeof(*kb), GFP_KERNEL);
	if (!kb)
		return -ENOMEM;

	kb->client = client;
	mutex_init(&kb->xfer_lock);
	i2c_set_clientdata(client, kb);

	kb->vdd_gpio = devm_gpiod_get_optional(&client->dev, "vdd", GPIOD_OUT_LOW);
	if (IS_ERR(kb->vdd_gpio))
		return PTR_ERR(kb->vdd_gpio);
	kb->reset_gpio = devm_gpiod_get(&client->dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(kb->reset_gpio))
		return PTR_ERR(kb->reset_gpio);
	kb->sleep_gpio = devm_gpiod_get(&client->dev, "sleep", GPIOD_OUT_LOW);
	if (IS_ERR(kb->sleep_gpio))
		return PTR_ERR(kb->sleep_gpio);
	kb->status_gpio = devm_gpiod_get_optional(&client->dev, "status", GPIOD_IN);
	if (IS_ERR(kb->status_gpio))
		return PTR_ERR(kb->status_gpio);

	nanosic_power_on(kb);
	ret = nanosic_init_mcu(kb);
	if (ret)
		return dev_err_probe(&client->dev, ret, "mcu i2c init\n");

	for (i = 0; i < NANOSIC_HID_N; i++) {
		ret = nanosic_hid_register(kb, i);
		if (ret)
			return dev_err_probe(&client->dev, ret, "hid %s\n",
					     nanosic_hid_table[i].name);
	}

	kb->wakeup = devm_input_allocate_device(&client->dev);
	if (!kb->wakeup)
		return -ENOMEM;
	kb->wakeup->name = "xiaomi keyboard WakeUp";
	kb->wakeup->id.bustype = BUS_HOST;
	kb->wakeup->id.vendor = 0x0827;
	kb->wakeup->id.product = 0x0094;
	input_set_capability(kb->wakeup, EV_KEY, KEY_WAKEUP);
	ret = input_register_device(kb->wakeup);
	if (ret)
		return ret;

	irq = client->irq;
	ret = devm_request_threaded_irq(&client->dev, irq, NULL, nanosic_irq,
					IRQF_ONESHOT, "nanosic-803", kb);
	if (ret)
		return dev_err_probe(&client->dev, ret, "data irq\n");

	if (kb->status_gpio) {
		kb->wakeup_irq = gpiod_to_irq(kb->status_gpio);
		if (kb->wakeup_irq > 0) {
			ret = devm_request_threaded_irq(&client->dev, kb->wakeup_irq,
							NULL, nanosic_wakeup_irq,
							IRQF_ONESHOT | IRQF_TRIGGER_RISING,
							"nanosic-wakeup", kb);
			if (ret)
				return dev_err_probe(&client->dev, ret, "wakeup irq\n");
		}
	}

	device_init_wakeup(&client->dev, true);
	dev_info(&client->dev, "nanosic 803 keyboard MCU\n");
	return 0;
}

static const struct of_device_id nanosic_of_match[] = {
	{ .compatible = "nanosic,803" },
	{ }
};
MODULE_DEVICE_TABLE(of, nanosic_of_match);

static struct i2c_driver nanosic_driver = {
	.driver = {
		.name = "nanosic-803-dagu",
		.of_match_table = nanosic_of_match,
		.pm = pm_sleep_ptr(&nanosic_pm_ops),
	},
	.probe = nanosic_probe,
};
module_i2c_driver(nanosic_driver);

MODULE_DESCRIPTION("Nanosic 803 keyboard MCU (dagu)");
MODULE_LICENSE("GPL");
