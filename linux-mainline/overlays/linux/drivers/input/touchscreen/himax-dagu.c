// SPDX-License-Identifier: GPL-2.0-only
/*
 * Himax HX83121 SPI touch for Xiaomi Pad 5 Pro 12.4 (dagu).
 *
 * Pins from live FDT / CAF: SPI @ 0x990000 (spi4), CPHA, 4 MHz,
 * IRQ GPIO39, RST GPIO100, 1600×2560.
 *
 * CAF hxchipset is 19k lines of Android 4.19 code; this is the mainline
 * overlay driver. Firmware (optional) from dumps via stage-firmware.sh.
 */

#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/spi/spi.h>

#define HIMAX_MAX_FINGERS	10

struct himax_dagu {
	struct spi_device *spi;
	struct input_dev *input;
	struct gpio_desc *reset_gpio;
	u32 max_x;
	u32 max_y;
};

static void himax_reset(struct himax_dagu *ts)
{
	if (!ts->reset_gpio)
		return;
	gpiod_set_value_cansleep(ts->reset_gpio, 1);
	msleep(20);
	gpiod_set_value_cansleep(ts->reset_gpio, 0);
	msleep(50);
	gpiod_set_value_cansleep(ts->reset_gpio, 1);
	msleep(50);
}

static irqreturn_t himax_irq(int irq, void *data)
{
	struct himax_dagu *ts = data;
	u8 buf[56];
	int ret, i;

	ret = spi_read(ts->spi, buf, sizeof(buf));
	if (ret)
		return IRQ_HANDLED;

	for (i = 0; i < HIMAX_MAX_FINGERS; i++) {
		u8 *p = &buf[i * 4];
		u8 event = p[0] >> 6;
		u16 x, y;
		bool down;

		if (event == 0x3)
			continue;
		x = ((p[0] & 0x3f) << 8) | p[1];
		y = (p[2] << 8) | p[3];
		down = x <= ts->max_x && y <= ts->max_y;
		input_mt_slot(ts->input, i);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, down);
		if (!down)
			continue;
		input_report_abs(ts->input, ABS_MT_POSITION_X, x);
		input_report_abs(ts->input, ABS_MT_POSITION_Y, y);
	}
	input_mt_sync_frame(ts->input);
	input_sync(ts->input);
	return IRQ_HANDLED;
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
	spi->mode |= SPI_CPHA;
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	if (ret)
		return ret;

	of_property_read_u32(spi->dev.of_node, "touchscreen-size-x", &coords[1]);
	of_property_read_u32(spi->dev.of_node, "touchscreen-size-y", &coords[3]);
	device_property_read_u32_array(&spi->dev, "himax,display-coords", coords, 4);
	ts->max_x = coords[1];
	ts->max_y = coords[3];

	ts->reset_gpio = devm_gpiod_get_optional(&spi->dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ts->reset_gpio))
		return PTR_ERR(ts->reset_gpio);

	himax_reset(ts);

	input = devm_input_allocate_device(&spi->dev);
	if (!input)
		return -ENOMEM;
	ts->input = input;
	input->name = "Himax HX83121";
	input->phys = "himax/spi";
	input_set_abs_params(input, ABS_MT_POSITION_X, 0, ts->max_x, 0, 0);
	input_set_abs_params(input, ABS_MT_POSITION_Y, 0, ts->max_y, 0, 0);
	ret = input_mt_init_slots(input, HIMAX_MAX_FINGERS, INPUT_MT_DIRECT);
	if (ret)
		return ret;

	irq = spi->irq;
	if (irq <= 0)
		return dev_err_probe(&spi->dev, -EINVAL, "no IRQ\n");

	ret = devm_request_threaded_irq(&spi->dev, irq, NULL, himax_irq,
					IRQF_ONESHOT | IRQF_TRIGGER_FALLING,
					"himax-dagu", ts);
	if (ret)
		return ret;

	ret = input_register_device(input);
	if (ret)
		return ret;

	spi_set_drvdata(spi, ts);
	dev_info(&spi->dev, "HX83121 %ux%u irq %d\n", ts->max_x, ts->max_y, irq);
	return 0;
}

static const struct of_device_id himax_of_match[] = {
	{ .compatible = "himax,hx83121-dagu" },
	{ .compatible = "himax,hxcommon" },
	{ }
};
MODULE_DEVICE_TABLE(of, himax_of_match);

static const struct spi_device_id himax_id[] = {
	{ "hx83121-dagu", 0 },
	{ }
};
MODULE_DEVICE_TABLE(spi, himax_id);

static struct spi_driver himax_driver = {
	.probe = himax_probe,
	.id_table = himax_id,
	.driver = {
		.name = "himax-dagu",
		.of_match_table = himax_of_match,
	},
};
module_spi_driver(himax_driver);

MODULE_DESCRIPTION("Himax HX83121 SPI touchscreen (dagu)");
MODULE_LICENSE("GPL");
