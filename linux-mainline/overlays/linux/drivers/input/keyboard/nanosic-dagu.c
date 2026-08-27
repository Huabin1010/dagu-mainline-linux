// SPDX-License-Identifier: GPL-2.0-only
/*
 * Nanosic 803 keyboard MCU on Xiaomi dagu (I2C @ 0x4c).
 * GPIO power/reset from CAF nanosic_driver. HID path is a slim overlay,
 * not a copy of the 4.19 netlink/chardev stack.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/of.h>

#define NANOSIC_PKT_LEN	64

struct nanosic_kb {
	struct i2c_client *client;
	struct input_dev *input;
	struct gpio_desc *reset_gpio;
	struct gpio_desc *status_gpio;
	struct gpio_desc *vdd_gpio;
	struct gpio_desc *sleep_gpio;
};

static void nanosic_power_on(struct nanosic_kb *kb)
{
	if (kb->vdd_gpio)
		gpiod_set_value_cansleep(kb->vdd_gpio, 1);
	msleep(10);
	if (kb->sleep_gpio)
		gpiod_set_value_cansleep(kb->sleep_gpio, 1);
	if (kb->reset_gpio) {
		gpiod_set_value_cansleep(kb->reset_gpio, 0);
		msleep(20);
		gpiod_set_value_cansleep(kb->reset_gpio, 1);
		msleep(50);
	}
}

static irqreturn_t nanosic_irq(int irq, void *data)
{
	struct nanosic_kb *kb = data;
	u8 buf[NANOSIC_PKT_LEN] = { 0 };
	struct i2c_msg msg = {
		.addr = kb->client->addr,
		.flags = I2C_M_RD,
		.len = sizeof(buf),
		.buf = buf,
	};
	int ret, i;

	ret = i2c_transfer(kb->client->adapter, &msg, 1);
	if (ret < 0)
		return IRQ_HANDLED;

	/* CAF HID-like keyboard report is injected via virtual HID.
	 * Boot-protocol keyboard: modifiers at [2], keys at [4..].
	 */
	if (buf[0] == 0x01 || buf[1] == 0x01) {
		input_report_key(kb->input, KEY_LEFTCTRL, buf[2] & BIT(0));
		input_report_key(kb->input, KEY_LEFTSHIFT, buf[2] & BIT(1));
		input_report_key(kb->input, KEY_LEFTALT, buf[2] & BIT(2));
		input_report_key(kb->input, KEY_LEFTMETA, buf[2] & BIT(3));
		for (i = 4; i < 10; i++) {
			if (buf[i])
				input_event(kb->input, EV_MSC, MSC_SCAN, buf[i]);
		}
	}

	input_report_key(kb->input, KEY_WAKEUP, 1);
	input_sync(kb->input);
	input_report_key(kb->input, KEY_WAKEUP, 0);
	input_sync(kb->input);
	return IRQ_HANDLED;
}

static int nanosic_probe(struct i2c_client *client)
{
	struct nanosic_kb *kb;
	int irq, ret;

	kb = devm_kzalloc(&client->dev, sizeof(*kb), GFP_KERNEL);
	if (!kb)
		return -ENOMEM;

	kb->client = client;
	kb->vdd_gpio = devm_gpiod_get_optional(&client->dev, "vdd", GPIOD_OUT_HIGH);
	if (IS_ERR(kb->vdd_gpio))
		return PTR_ERR(kb->vdd_gpio);
	kb->reset_gpio = devm_gpiod_get_optional(&client->dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(kb->reset_gpio))
		return PTR_ERR(kb->reset_gpio);
	kb->status_gpio = devm_gpiod_get_optional(&client->dev, "status", GPIOD_IN);
	if (IS_ERR(kb->status_gpio))
		return PTR_ERR(kb->status_gpio);
	kb->sleep_gpio = devm_gpiod_get_optional(&client->dev, "sleep", GPIOD_OUT_HIGH);
	if (IS_ERR(kb->sleep_gpio))
		return PTR_ERR(kb->sleep_gpio);

	nanosic_power_on(kb);

	kb->input = devm_input_allocate_device(&client->dev);
	if (!kb->input)
		return -ENOMEM;
	kb->input->name = "Xiaomi Keyboard";
	kb->input->id.bustype = BUS_I2C;
	kb->input->id.vendor = 0x15d9;
	kb->input->id.product = 0xa3;
	input_set_capability(kb->input, EV_KEY, KEY_WAKEUP);
	input_set_capability(kb->input, EV_KEY, KEY_LEFTCTRL);
	input_set_capability(kb->input, EV_KEY, KEY_LEFTSHIFT);
	input_set_capability(kb->input, EV_KEY, KEY_LEFTALT);
	input_set_capability(kb->input, EV_KEY, KEY_LEFTMETA);
	input_set_capability(kb->input, EV_MSC, MSC_SCAN);
	ret = input_register_device(kb->input);
	if (ret)
		return ret;

	irq = client->irq;
	if (irq) {
		ret = devm_request_threaded_irq(&client->dev, irq, NULL, nanosic_irq,
						IRQF_ONESHOT | IRQF_TRIGGER_FALLING,
						"nanosic-803", kb);
		if (ret)
			return dev_err_probe(&client->dev, ret, "irq\n");
	}

	i2c_set_clientdata(client, kb);
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
	},
	.probe = nanosic_probe,
};
module_i2c_driver(nanosic_driver);

MODULE_DESCRIPTION("Nanosic 803 keyboard MCU (dagu)");
MODULE_LICENSE("GPL");
