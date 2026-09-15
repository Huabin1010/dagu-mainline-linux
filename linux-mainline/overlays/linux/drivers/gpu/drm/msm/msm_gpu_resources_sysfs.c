// SPDX-License-Identifier: GPL-2.0-only
/*
 * Expose AMD-style GPU sysfs on the MSM DPU drm device so GNOME Resources
 * can read Adreno load / clocks / GEM usage. Resources only scans
 * /sys/class/drm/card?/device/, which is the display controller, not 3d00000.gpu.
 */
#include <linux/device.h>
#include <linux/hwmon.h>
#include <linux/log2.h>
#include <linux/thermal.h>

#include "msm_drv.h"
#include "msm_gpu.h"

static struct msm_gpu *resources_gpu(struct msm_drm_private *priv)
{
	if (priv->gpu)
		return priv->gpu;
	if (priv->gpu_pdev)
		return dev_to_gpu(&priv->gpu_pdev->dev);
	return NULL;
}

static unsigned long resources_gpu_freq(struct msm_gpu *gpu)
{
	struct msm_gpu_devfreq *df = &gpu->devfreq;

	if (df->idle_freq)
		return df->idle_freq;
	if (gpu->funcs->gpu_get_freq)
		return gpu->funcs->gpu_get_freq(gpu);
	if (gpu->core_clk)
		return clk_get_rate(gpu->core_clk);
	if (df->devfreq)
		return df->devfreq->previous_freq;
	return 0;
}

static unsigned long resources_gpu_busy_pct(struct msm_gpu *gpu)
{
	struct devfreq *df;
	unsigned long busy, total;

	if (!gpu || !gpu->devfreq.devfreq)
		return 0;
	df = gpu->devfreq.devfreq;
	busy = df->last_status.busy_time;
	total = df->last_status.total_time;
	if (!total)
		return 0;
	if (busy > total)
		busy = total;
	return busy * 100 / total;
}

static ssize_t gpu_busy_percent_show(struct device *dev,
				     struct device_attribute *attr, char *buf)
{
	struct msm_drm_private *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%lu\n",
			  resources_gpu_busy_pct(resources_gpu(priv)));
}
static DEVICE_ATTR_RO(gpu_busy_percent);

static ssize_t mem_info_vram_used_show(struct device *dev,
				       struct device_attribute *attr, char *buf)
{
	struct msm_drm_private *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%lld\n", (long long)atomic64_read(&priv->total_mem));
}
static DEVICE_ATTR_RO(mem_info_vram_used);

static ssize_t mem_info_vram_total_show(struct device *dev,
					struct device_attribute *attr, char *buf)
{
	struct msm_drm_private *priv = dev_get_drvdata(dev);
	unsigned long long used = atomic64_read(&priv->total_mem);
	unsigned long long total = SZ_1G;

	if (used > total)
		total = roundup_pow_of_two(used);

	return sysfs_emit(buf, "%llu\n", total);
}
static DEVICE_ATTR_RO(mem_info_vram_total);

static int gpu_temp_mC(void)
{
	static const char * const names[] = {
		"gpu-top-thermal",
		"gpuss-0-thermal",
		"gpu-thermal-top",
		"gpu",
	};
	int i, ret, temp;

	for (i = 0; i < ARRAY_SIZE(names); i++) {
		struct thermal_zone_device *tz;

		tz = thermal_zone_get_zone_by_name(names[i]);
		if (IS_ERR(tz))
			continue;
		ret = thermal_zone_get_temp(tz, &temp);
		if (!ret)
			return temp;
	}
	return -ENODATA;
}

static umode_t resources_hwmon_is_visible(const void *data,
					  enum hwmon_sensor_types type,
					  u32 attr, int channel)
{
	if (type == hwmon_temp && attr == hwmon_temp_input)
		return 0444;
	return 0;
}

static int resources_hwmon_read(struct device *dev, enum hwmon_sensor_types type,
				u32 attr, int channel, long *val)
{
	int temp;

	if (type != hwmon_temp || attr != hwmon_temp_input)
		return -EOPNOTSUPP;
	temp = gpu_temp_mC();
	if (temp < 0)
		return temp;
	*val = temp;
	return 0;
}

static const struct hwmon_ops resources_hwmon_ops = {
	.is_visible = resources_hwmon_is_visible,
	.read = resources_hwmon_read,
};

static const struct hwmon_channel_info * const resources_hwmon_info[] = {
	HWMON_CHANNEL_INFO(temp, HWMON_T_INPUT),
	NULL
};

static const struct hwmon_chip_info resources_hwmon_chip = {
	.ops = &resources_hwmon_ops,
	.info = resources_hwmon_info,
};

static ssize_t freq1_input_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct msm_drm_private *priv = dev_get_drvdata(dev);
	struct msm_gpu *gpu = resources_gpu(priv);

	if (!gpu)
		return sysfs_emit(buf, "0\n");
	return sysfs_emit(buf, "%lu\n", resources_gpu_freq(gpu));
}
static DEVICE_ATTR_RO(freq1_input);

/* Adreno has no discrete VRAM clock; report LPDDR5 3200 MT/s DDR clock. */
static ssize_t freq2_input_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "1600000000\n");
}
static DEVICE_ATTR_RO(freq2_input);

/*
 * No GPU power rail sensor. Estimate from busy% and OPP vs 670 MHz / ~7 W
 * (Adreno 650 ballpark) so Resources is not stuck on N/A.
 */
static ssize_t power1_average_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	struct msm_drm_private *priv = dev_get_drvdata(dev);
	struct msm_gpu *gpu = resources_gpu(priv);
	unsigned long busy, freq;
	u64 uw;

	if (!gpu)
		return sysfs_emit(buf, "0\n");
	busy = resources_gpu_busy_pct(gpu);
	freq = resources_gpu_freq(gpu);
	if (!freq)
		freq = 305000000;
	uw = (u64)busy * 70000ULL;
	uw = uw * freq / 670000000ULL;
	return sysfs_emit(buf, "%llu\n", uw);
}
static DEVICE_ATTR_RO(power1_average);

static struct attribute *resources_freq_attrs[] = {
	&dev_attr_freq1_input.attr,
	&dev_attr_freq2_input.attr,
	&dev_attr_power1_average.attr,
	NULL,
};
ATTRIBUTE_GROUPS(resources_freq);

static void resources_remove_files(void *data)
{
	struct device *dev = data;

	device_remove_file(dev, &dev_attr_gpu_busy_percent);
	device_remove_file(dev, &dev_attr_mem_info_vram_used);
	device_remove_file(dev, &dev_attr_mem_info_vram_total);
}

void msm_gpu_resources_sysfs_init(struct device *dev)
{
	int ret;

	ret = device_create_file(dev, &dev_attr_gpu_busy_percent);
	if (ret)
		dev_warn(dev, "gpu_busy_percent sysfs: %d\n", ret);
	ret = device_create_file(dev, &dev_attr_mem_info_vram_used);
	if (ret)
		dev_warn(dev, "mem_info_vram_used sysfs: %d\n", ret);
	ret = device_create_file(dev, &dev_attr_mem_info_vram_total);
	if (ret)
		dev_warn(dev, "mem_info_vram_total sysfs: %d\n", ret);

	devm_add_action_or_reset(dev, resources_remove_files, dev);

	if (IS_REACHABLE(CONFIG_HWMON)) {
		struct device *hwmon;

		hwmon = devm_hwmon_device_register_with_info(dev, "adreno",
				dev_get_drvdata(dev), &resources_hwmon_chip,
				resources_freq_groups);
		if (IS_ERR(hwmon))
			dev_warn(dev, "adreno hwmon: %ld\n", PTR_ERR(hwmon));
	}
}
