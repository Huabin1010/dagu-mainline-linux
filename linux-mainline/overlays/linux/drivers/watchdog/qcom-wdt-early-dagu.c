// SPDX-License-Identifier: GPL-2.0-only
/*
 * HyperOS ABL leaves the KPSS watchdog armed. The platform driver
 * probes too late (after the leftover ~6s bite) and ABL returns to
 * fastboot. Pet and stretch the timer before device_initcall.
 *
 * SM8250: watchdog@17c10000, compatible qcom,kpss-wdt, 32764 Hz sleep_clk.
 *
 * Do not poke TLMM/MDSS from here: those ioremaps can hang before PID1
 * while the Logo stays frozen (QHEE). WDT only.
 */
#include <linux/init.h>
#include <linux/io.h>
#include <linux/sizes.h>

#define DAGU_KPSS_WDT		0x17c10000
#define WDT_RST			0x04
#define WDT_EN			0x08
#define WDT_BARK_TIME		0x10
#define WDT_BITE_TIME		0x14
#define SLEEP_HZ		32764
/* BITE_TIME is 20 bits (0xfffff), so anything past 32 s wraps to a short bite. */
#define BITE_SEC		30

static int __init dagu_kick_abl_wdt(void)
{
	void __iomem *base = ioremap(DAGU_KPSS_WDT, SZ_4K);
	u32 ticks;

	if (!base)
		return 0;

	ticks = SLEEP_HZ * BITE_SEC;
	writel(0, base + WDT_EN);
	writel(1, base + WDT_RST);
	writel(ticks - SLEEP_HZ, base + WDT_BARK_TIME);
	writel(ticks, base + WDT_BITE_TIME);
	writel(1, base + WDT_RST);
	/* Leave armed. HANDLE_BOOT_ENABLED=n, so PID1 must open /dev/watchdog. */
	writel(1, base + WDT_EN);

	iounmap(base);
	return 0;
}
early_initcall(dagu_kick_abl_wdt);
