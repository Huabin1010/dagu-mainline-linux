// SPDX-License-Identifier: GPL-2.0
/*
 * camss-vfe-480.c
 *
 * Qualcomm MSM Camera Subsystem - VFE (Video Front End) Module v480 (SM8250)
 *
 * Copyright (C) 2020-2021 Linaro Ltd.
 * Copyright (C) 2021 Jonathan Marek
 */

#include <linux/cacheflush.h>
#include <linux/debugfs.h>
#include <linux/dma-mapping.h>
#include <linux/hrtimer.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/math64.h>
#include <linux/moduleparam.h>
#include <linux/sizes.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>
#include <media/v4l2-mediabus.h>

#include "camss.h"
#include "camss-vfe.h"
#include "dagu-front-dmi.h"

/*
 * Front EOF→next SOF is ~23 ms of blanking. Rear is ~1 ms and the
 * same EOF dbg1 (0x82d68008) still reaches another epoch. The
 * buf_done 0x41 is ~3 ms before EOF, so on the front it is ~26 ms
 * stale at the next SOF. A second 0x41 16 ms after EOF made that
 * SOF match a continuing rear frame (dbg1=0x10628018 wmd=0x2ea)
 * and then halted before epoch. Reloading crop/epoch there
 * ("dagu front late camif") and skipping the buf_done 0x41
 * ("dagu front blank rup", as3 stayed 0xfe800000) did not reach
 * epoch either. Reloading keep-all skip/period/subsample
 * ("dagu front blank skip") was the same halt. A read 3 ms
 * after the second SOF ("dagu front mid") already showed
 * dbg1=0x10218010 wmd=0x20a, viol=0, irq0=0, irq1=0, bus=0x4.
 * The halt is latched before epoch with no top error. Replaying
 * the WM program in that window ("dagu front blank wm"
 * y=0xfe000000) left as3=0xfe800000, the buffer already queued
 * at init, and the same 3 ms halt. At that halt the WM
 * constraint register was 0 through frame 1 and the halt,
 * and CAMIF cmd was still 0x2000101. Skipping the IPP SOF
 * recrop after frame 1 ("dagu csid ipp sof nocrop") was the
 * same halt. Clock overrides already read back set
 * (0xffffffff/0xff/0x1/0x1, bus 0x3ffffff); forcing them
 * again did not help. Reloading the frame-1 Demux program
 * ("dagu front late demux") was the same halt. Writing the
 * whole Camera ID 1 CDM packet-1 AHB program in that window
 * ("dagu front cdm pkt", #612) still halted at +3 ms:
 * dbg1=0x10218010 wmd=0x20a viol=0 irq0=0 bus=0x4, one
 * 8110080 frame. Do not replay that packet. The 2026-10-24
 * front capture now supplies the DMI bytes at init.
 */
static bool dagu_front_pix;
static bool dagu_front_rup_ready;
static int dagu_front_sof_n;
static struct hrtimer dagu_front_rup_timer;
static struct hrtimer dagu_front_mid_timer;
static struct vfe_device *dagu_front_rup_vfe;
static unsigned int dagu_front_evt_n;
static unsigned int dagu_front_evt_shown;
static int dagu_reload_phase;

/*
 * #621 values. #622 wrote all three Android words at once and the
 * first frame never completed, so each word is a runtime knob.
 * Rear does not read these.
 */
unsigned int dagu_core_cfg0 = 0x78000800;
module_param(dagu_core_cfg0, uint, 0644);
MODULE_PARM_DESC(dagu_core_cfg0, "front VFE_CORE_CFG_0");
unsigned int dagu_ipp_cfg1 = 2;
module_param(dagu_ipp_cfg1, uint, 0644);
MODULE_PARM_DESC(dagu_ipp_cfg1, "front CSID IPP CFG1");
unsigned int dagu_ipp_errrec;
module_param(dagu_ipp_errrec, uint, 0644);
MODULE_PARM_DESC(dagu_ipp_errrec, "front CSID IPP errrec");
static unsigned int dagu_rup_mode;
module_param(dagu_rup_mode, uint, 0644);
MODULE_PARM_DESC(dagu_rup_mode, "front RUP: bit0 buf_done RUP waits for EOF, bit1 no late timer RUP");
static unsigned int dagu_wm5_rearm;
module_param(dagu_wm5_rearm, uint, 0644);
MODULE_PARM_DESC(dagu_wm5_rearm, "front: rewrite chroma WM cfg at CAMIF EOF");
static unsigned int dagu_wm_pattern;
module_param(dagu_wm_pattern, uint, 0644);
MODULE_PARM_DESC(dagu_wm_pattern, "front WM4/5 drop/subsample pattern: 0 = 1, 1 = 0xffffffff");
/*
 * Android Camera ID 1 runs DS4/DS16 with WM6/7 PD10 clients whose
 * addresses rotate every frame. 1 programs that path from the live
 * 2026-10-24 read and feeds WM6/7 an address with every WM4 update.
 */
static unsigned int dagu_ds_mode;
module_param(dagu_ds_mode, uint, 0644);
MODULE_PARM_DESC(dagu_ds_mode, "front: 1 = Android DS4/DS16 + WM6/7");
static bool dagu_in_comp_done;
static bool dagu_rup_pending;
static int dagu_mid_n;

/*
 * Flight recorder. Top debug 0x80..0xc0 is 4 bits per CLC module:
 * bit0 ready, bit1 valid, bit2 idle (from the #624 frame-1 trace:
 * flowing modules toggle 1/3, idle is 5, the front halt leaves 2).
 * CAF top_debug_4..13 sit at 0x9c..0xc0, not 0x90..0xb4. Samples
 * run in a hard hrtimer from pix_go and stop in vfe_wm_stop before
 * the clocks drop; a /dev/mem poller that outlived the rear stream
 * hung the bus on #624.
 */
static const u16 dagu_fr_off[] = {
	0x27f0, 0x27f4,
	0x80, 0x84, 0x88, 0x8c, 0x9c, 0xa0, 0xa4, 0xa8, 0xac, 0xb0,
	0xb4, 0xb8, 0xbc, 0xc0,
	0x54, 0x58, 0xaa28, 0xb07c, 0xb17c, 0xb068, 0xb168,
};
#define DAGU_FR_NREG	ARRAY_SIZE(dagu_fr_off)
#define DAGU_FR_MAX	2048
struct dagu_fr_ent {
	u32 t_us;
	u32 v[DAGU_FR_NREG];
};
static struct dagu_fr_ent dagu_fr_buf[DAGU_FR_MAX];
static unsigned int dagu_fr_n;
static unsigned int dagu_fr_polls;
static bool dagu_fr_on;
static ktime_t dagu_fr_t0;
static struct hrtimer dagu_fr_timer;
static bool dagu_fr_init_done;
static struct vfe_device *dagu_fr_vfe;
static unsigned int dagu_fr_us;
module_param(dagu_fr_us, uint, 0644);
MODULE_PARM_DESC(dagu_fr_us, "flight recorder period in us, 0 = off");
static unsigned int dagu_fr_ms = 2000;
module_param(dagu_fr_ms, uint, 0644);
MODULE_PARM_DESC(dagu_fr_ms, "flight recorder window after pix_go");

static enum hrtimer_restart dagu_fr_fn(struct hrtimer *timer)
{
	struct vfe_device *vfe = dagu_fr_vfe;
	struct dagu_fr_ent *e;
	u32 v[DAGU_FR_NREG];
	s64 us;
	int i;

	if (!dagu_fr_on || !vfe)
		return HRTIMER_NORESTART;
	us = ktime_us_delta(ktime_get(), dagu_fr_t0);
	for (i = 0; i < DAGU_FR_NREG; i++)
		v[i] = readl_relaxed(vfe->base + dagu_fr_off[i]);
	dagu_fr_polls++;
	if (!dagu_fr_n ||
	    memcmp(dagu_fr_buf[dagu_fr_n - 1].v, v, sizeof(v))) {
		if (dagu_fr_n < DAGU_FR_MAX) {
			e = &dagu_fr_buf[dagu_fr_n++];
			e->t_us = us;
			memcpy(e->v, v, sizeof(v));
		}
	}
	if (us > (s64)dagu_fr_ms * 1000 || dagu_fr_n >= DAGU_FR_MAX) {
		dagu_fr_on = false;
		return HRTIMER_NORESTART;
	}
	hrtimer_forward_now(timer, us_to_ktime(dagu_fr_us));
	return HRTIMER_RESTART;
}

static void dagu_fr_start(struct vfe_device *vfe)
{
	if (!dagu_fr_us || vfe->id != 1)
		return;
	if (!dagu_fr_init_done) {
		hrtimer_setup(&dagu_fr_timer, dagu_fr_fn, CLOCK_MONOTONIC,
			      HRTIMER_MODE_REL_HARD);
		dagu_fr_init_done = true;
	}
	hrtimer_cancel(&dagu_fr_timer);
	dagu_fr_vfe = vfe;
	dagu_fr_n = 0;
	dagu_fr_polls = 0;
	dagu_fr_t0 = ktime_get();
	dagu_fr_on = true;
	hrtimer_start(&dagu_fr_timer, 0, HRTIMER_MODE_REL_HARD);
}

/* Call with the block still clocked. Prints only what was recorded. */
static void dagu_fr_stop(struct vfe_device *vfe)
{
	char line[DAGU_FR_NREG * 9 + 1];
	unsigned int i, j;
	int n;

	if (!dagu_fr_init_done || dagu_fr_vfe != vfe)
		return;
	dagu_fr_on = false;
	hrtimer_cancel(&dagu_fr_timer);
	dev_info(vfe->camss->dev,
		 "dagu fr ife%d polls=%u changes=%u period=%uus regs=dbg1,dbg0,td0-13,irq0,irq1,bus0,wmd4,wmd5,as4,as5\n",
		 vfe->id, dagu_fr_polls, dagu_fr_n, dagu_fr_us);
	for (i = 0; i < dagu_fr_n; i++) {
		n = 0;
		for (j = 0; j < DAGU_FR_NREG; j++)
			n += scnprintf(line + n, sizeof(line) - n, " %08x",
				       dagu_fr_buf[i].v[j]);
		dev_info(vfe->camss->dev, "dagu fr %u%s\n",
			 dagu_fr_buf[i].t_us, line);
	}
	dagu_fr_vfe = NULL;
}

/*
 * Runtime register overrides, so a CLC hypothesis is a 15 s test
 * instead of a flash. "phase:off=val,..." with phase init (after the
 * PIX program, before the first RUP), go (pix_go), sof, eof.
 * Only 0x2c and the CLC window 0x2000..0x9ffc are writable; bus,
 * IRQ and RUP registers are refused.
 */
static char dagu_ovr[512];
module_param_string(dagu_ovr, dagu_ovr, sizeof(dagu_ovr), 0644);
MODULE_PARM_DESC(dagu_ovr, "front IFE1 overrides: phase:off=val,... phase=init|go|sof|eof");
enum { DAGU_PH_INIT, DAGU_PH_GO, DAGU_PH_SOF, DAGU_PH_EOF };

static void dagu_ovr_apply(struct vfe_device *vfe, int phase)
{
	static const char * const names[] = { "init", "go", "sof", "eof" };
	char buf[sizeof(dagu_ovr)];
	char *s = buf, *tok;
	bool log = phase <= DAGU_PH_GO;

	if (!dagu_ovr[0] || vfe->id != 1 || !dagu_front_pix)
		return;
	strscpy(buf, dagu_ovr, sizeof(buf));
	while ((tok = strsep(&s, ", \n"))) {
		char *colon = strchr(tok, ':'), *eq;
		u32 off, val;

		if (!colon)
			continue;
		*colon = 0;
		if (strcmp(tok, names[phase]))
			continue;
		eq = strchr(colon + 1, '=');
		if (!eq)
			continue;
		*eq = 0;
		if (kstrtou32(colon + 1, 0, &off) || kstrtou32(eq + 1, 0, &val))
			continue;
		if ((off & 3) || !(off == 0x2c || (off >= 0x2000 && off < 0xa000))) {
			dev_warn(vfe->camss->dev, "dagu ovr refuse 0x%x\n", off);
			continue;
		}
		writel_relaxed(val, vfe->base + off);
		if (log)
			dev_info(vfe->camss->dev,
				 "dagu ovr %s 0x%x=0x%x read=0x%x\n",
				 names[phase], off, val,
				 readl_relaxed(vfe->base + off));
	}
	wmb();
}

/*
 * debugfs IQ program interface (/sys/kernel/debug/dagu_ife1/).
 *
 *   prog_front, prog_rear  text program, applied to IFE1 PIX at init
 *                          (after the driver program, before the first
 *                          RUP) and, for "@sof" lines, at every SOF.
 *   live                   one-shot program applied at the next SOF;
 *                          it latches at the following PIX RUP. 3A uses
 *                          this for gains, matrices and LUTs.
 *   dmird                  "BASE BANK N" reads N DMI words at the next
 *                          SOF; reading the file returns them in hex.
 *
 * Program lines:
 *   [@sof] w OFF VAL               AHB write
 *   [@sof] dmi BASE BANK V0 V1 ... DMI upload: BANK -> BASE+0x08, data
 *                                  -> BASE+0x0c, then 0 -> BASE+0x08
 * Only 0x2c and the CLC window 0x2000..0x9ffc are writable.
 */
#define DAGU_OP_W	0
#define DAGU_PROG_MAX	32768
#define DAGU_LIVE_MAX	8192
struct dagu_op {
	u32 off;
	u32 val;
	u8 sof;
};
struct dagu_prog {
	struct dagu_op *ops;
	unsigned int n, max;
	char *text;
	size_t text_len;
};
static struct dagu_prog dagu_prog_front, dagu_prog_rear, dagu_prog_live;
static bool dagu_live_pending;
static DEFINE_SPINLOCK(dagu_prog_lock);
static u32 dagu_dmird_base, dagu_dmird_bank, dagu_dmird_n;
static bool dagu_dmird_pending;
static u32 *dagu_dmird_buf;
static unsigned int dagu_dmird_got;
static struct dentry *dagu_dbg_dir;

static bool dagu_off_ok(u32 off)
{
	return !(off & 3) && (off == 0x2c || (off >= 0x2000 && off < 0xa000));
}

/* Parse text into ops (process context). Returns op count or -errno. */
static int dagu_prog_parse(char *text, struct dagu_op *ops, unsigned int max)
{
	unsigned int n = 0;
	char *line, *s = text;

	while ((line = strsep(&s, "\n"))) {
		char *tok, *p = line;
		bool sof = false;
		u32 a, b, v;

		tok = strsep(&p, " \t");
		while (tok && !*tok)
			tok = strsep(&p, " \t");
		if (!tok || tok[0] == '#')
			continue;
		if (!strcmp(tok, "@sof")) {
			sof = true;
			tok = strsep(&p, " \t");
		}
		if (!tok)
			continue;
		if (!strcmp(tok, "w")) {
			if (kstrtou32(strsep(&p, " \t") ?: "", 0, &a) ||
			    kstrtou32(strsep(&p, " \t") ?: "", 0, &v) || !dagu_off_ok(a))
				return -EINVAL;
			if (n >= max)
				return -ENOSPC;
			ops[n++] = (struct dagu_op){ a, v, sof };
		} else if (!strcmp(tok, "dmi")) {
			if (kstrtou32(strsep(&p, " \t") ?: "", 0, &a) ||
			    kstrtou32(strsep(&p, " \t") ?: "", 0, &b) ||
			    !dagu_off_ok(a + 8) || !dagu_off_ok(a + 0xc))
				return -EINVAL;
			if (n >= max)
				return -ENOSPC;
			ops[n++] = (struct dagu_op){ a + 8, b, sof };
			while ((tok = strsep(&p, " \t"))) {
				if (!*tok)
					continue;
				if (kstrtou32(tok, 0, &v))
					return -EINVAL;
				if (n >= max)
					return -ENOSPC;
				ops[n++] = (struct dagu_op){ a + 0xc, v, sof };
			}
			if (n >= max)
				return -ENOSPC;
			ops[n++] = (struct dagu_op){ a + 8, 0, sof };
		} else {
			return -EINVAL;
		}
	}
	return n;
}

static void dagu_prog_run(struct vfe_device *vfe, struct dagu_prog *pg, bool sof)
{
	unsigned int i;

	for (i = 0; i < pg->n; i++) {
		if (pg->ops[i].sof != sof)
			continue;
		writel_relaxed(pg->ops[i].val, vfe->base + pg->ops[i].off);
		/* DMI select and data are ordered against each other. */
		if ((pg->ops[i].off & 0xff) == 0x08)
			wmb();
	}
	wmb();
}

/* init: after the driver program. sof: from the CAMIF SOF IRQ. */
static void dagu_prog_apply(struct vfe_device *vfe, bool sof)
{
	struct dagu_prog *pg = dagu_front_pix ? &dagu_prog_front : &dagu_prog_rear;
	unsigned long flags;
	unsigned int i;

	if (vfe->id != 1)
		return;
	spin_lock_irqsave(&dagu_prog_lock, flags);
	if (pg->ops)
		dagu_prog_run(vfe, pg, sof);
	if (sof && dagu_live_pending && dagu_prog_live.ops) {
		/* live lines are one-shot: run them all now */
		for (i = 0; i < dagu_prog_live.n; i++) {
			writel_relaxed(dagu_prog_live.ops[i].val,
				       vfe->base + dagu_prog_live.ops[i].off);
			if ((dagu_prog_live.ops[i].off & 0xff) == 0x08)
				wmb();
		}
		wmb();
		dagu_live_pending = false;
	}
	if (sof && dagu_dmird_pending && dagu_dmird_buf) {
		writel_relaxed(dagu_dmird_bank, vfe->base + dagu_dmird_base + 8);
		wmb();
		for (i = 0; i < dagu_dmird_n; i++)
			dagu_dmird_buf[i] = readl_relaxed(vfe->base +
							  dagu_dmird_base + 0xc);
		writel_relaxed(0, vfe->base + dagu_dmird_base + 8);
		wmb();
		dagu_dmird_got = dagu_dmird_n;
		dagu_dmird_pending = false;
	}
	spin_unlock_irqrestore(&dagu_prog_lock, flags);
}

static ssize_t dagu_prog_write(struct file *f, const char __user *ubuf,
			       size_t len, loff_t *ppos)
{
	struct dagu_prog *pg = file_inode(f)->i_private;
	struct dagu_op *ops, *old_ops;
	char *text, *work, *old_text;
	unsigned long flags;
	int n;

	if (len > SZ_1M)
		return -EFBIG;
	text = kvmalloc(len + 1, GFP_KERNEL);
	work = kvmalloc(len + 1, GFP_KERNEL);
	ops = kvmalloc_array(pg->max, sizeof(*ops), GFP_KERNEL);
	if (!text || !work || !ops) {
		n = -ENOMEM;
		goto err;
	}
	if (copy_from_user(text, ubuf, len)) {
		n = -EFAULT;
		goto err;
	}
	text[len] = 0;
	memcpy(work, text, len + 1);
	n = dagu_prog_parse(work, ops, pg->max);
	kvfree(work);
	work = NULL;
	if (n < 0)
		goto err;
	spin_lock_irqsave(&dagu_prog_lock, flags);
	old_ops = pg->ops;
	old_text = pg->text;
	pg->ops = ops;
	pg->n = n;
	pg->text = text;
	pg->text_len = len;
	if (pg == &dagu_prog_live)
		dagu_live_pending = n > 0;
	spin_unlock_irqrestore(&dagu_prog_lock, flags);
	kvfree(old_ops);
	kvfree(old_text);
	return len;
err:
	kvfree(text);
	kvfree(work);
	kvfree(ops);
	return n;
}

static ssize_t dagu_prog_read(struct file *f, char __user *ubuf, size_t len,
			      loff_t *ppos)
{
	struct dagu_prog *pg = file_inode(f)->i_private;
	char hdr[64];
	int h;

	if (*ppos == 0 && !pg->text) {
		h = scnprintf(hdr, sizeof(hdr), "# empty\n");
		return simple_read_from_buffer(ubuf, len, ppos, hdr, h);
	}
	return simple_read_from_buffer(ubuf, len, ppos, pg->text, pg->text_len);
}

static const struct file_operations dagu_prog_fops = {
	.owner = THIS_MODULE,
	.write = dagu_prog_write,
	.read = dagu_prog_read,
	.llseek = default_llseek,
};

static ssize_t dagu_dmird_write(struct file *f, const char __user *ubuf,
				size_t len, loff_t *ppos)
{
	char buf[64];
	u32 base, bank, n;
	unsigned long flags;

	if (len >= sizeof(buf) || copy_from_user(buf, ubuf, len))
		return -EINVAL;
	buf[len] = 0;
	if (sscanf(buf, "%i %i %i", &base, &bank, &n) != 3 ||
	    !dagu_off_ok(base + 8) || !n || n > 4096)
		return -EINVAL;
	if (!dagu_dmird_buf)
		dagu_dmird_buf = kvcalloc(4096, sizeof(u32), GFP_KERNEL);
	if (!dagu_dmird_buf)
		return -ENOMEM;
	spin_lock_irqsave(&dagu_prog_lock, flags);
	dagu_dmird_base = base;
	dagu_dmird_bank = bank;
	dagu_dmird_n = n;
	dagu_dmird_got = 0;
	dagu_dmird_pending = true;
	spin_unlock_irqrestore(&dagu_prog_lock, flags);
	return len;
}

static ssize_t dagu_dmird_read(struct file *f, char __user *ubuf, size_t len,
			       loff_t *ppos)
{
	unsigned int i, n = dagu_dmird_got;
	ssize_t ret;
	char *out;
	int o = 0;

	out = kvmalloc(n * 9 + 64, GFP_KERNEL);
	if (!out)
		return -ENOMEM;
	o += scnprintf(out + o, 64, "# base=0x%x bank=%u n=%u%s\n",
		       dagu_dmird_base, dagu_dmird_bank, n,
		       dagu_dmird_pending ? " pending" : "");
	for (i = 0; i < n; i++)
		o += scnprintf(out + o, 10, "%08x%c", dagu_dmird_buf[i],
			       (i % 8 == 7) ? '\n' : ' ');
	ret = simple_read_from_buffer(ubuf, len, ppos, out, o);
	kvfree(out);
	return ret;
}

static const struct file_operations dagu_dmird_fops = {
	.owner = THIS_MODULE,
	.write = dagu_dmird_write,
	.read = dagu_dmird_read,
	.llseek = default_llseek,
};

static void dagu_dbg_init(void)
{
	if (dagu_dbg_dir)
		return;
	dagu_prog_front.max = DAGU_PROG_MAX;
	dagu_prog_rear.max = DAGU_PROG_MAX;
	dagu_prog_live.max = DAGU_LIVE_MAX;
	dagu_dbg_dir = debugfs_create_dir("dagu_ife1", NULL);
	debugfs_create_file("prog_front", 0600, dagu_dbg_dir, &dagu_prog_front,
			    &dagu_prog_fops);
	debugfs_create_file("prog_rear", 0600, dagu_dbg_dir, &dagu_prog_rear,
			    &dagu_prog_fops);
	debugfs_create_file("live", 0600, dagu_dbg_dir, &dagu_prog_live,
			    &dagu_prog_fops);
	debugfs_create_file("dmird", 0600, dagu_dbg_dir, NULL, &dagu_dmird_fops);
}

void dagu_csid_trace_report(struct device *dev);

static enum hrtimer_restart dagu_front_rup_fn(struct hrtimer *timer)
{
	struct vfe_device *vfe = dagu_front_rup_vfe;

	(void)timer;

	if (!vfe || !vfe->base)
		return HRTIMER_NORESTART;
	/*
	 * Packet-1 AHB replay logged "dagu front cdm pkt" on #612
	 * and still halted at +3 ms. Do not write that program again.
	 */
	vfe->reg_update |= 0x41;
	wmb();
	writel_relaxed(vfe->reg_update, vfe->base + 0x34);
	dev_info_ratelimited(vfe->camss->dev, "dagu front late rup\n");
	return HRTIMER_NORESTART;
}

#define VFE_GLOBAL_RESET_CMD		(vfe_is_lite(vfe) ? 0x0c : 0x1c)
#define	    GLOBAL_RESET_HW_AND_REG	(vfe_is_lite(vfe) ? BIT(1) : BIT(0))

#define VFE_CORE_CFG_0			0x2c
/* CAF cam_vfe480.h top_common_reg. Linux never programmed it. Dump only. */
#define VFE_CORE_CFG_1			0x30
#define     CORE_CFG_0_INPUTMUX_PP	5
/* CAF cam_vfe480.h operating_mode_shift=11. Online CSID = 1, FE = 2. */
#define     CORE_CFG_0_OPERATING_MODE	11
/*
 * CAF cam_vfe480.h pixel_pattern_shift=24 overlaps dsp_mode_shift=24
 * and CAM_SHIFT_TOP_CORE_CFG_DSP_STREAMING=25. cam_vfe_camif_ver3.c
 * never writes pattern into core_cfg_0. CamX titan480 CAMIF Fill
 * @0x526508 ORs MODULE 0x101 then BFI pattern into bits 24-26
 * (0x526538). GBRG=3 << 24 on CORE_CFG is 0x63000800 and turns
 * DSP streaming on. Bayer for the pixel pipe is CAMIF MODULE
 * plus Demux 0x3070/0x3074. Keep the CORE shift named so persist
 * can reject stuffing pattern there.
 */
#define     CORE_CFG_0_PIXEL_PATTERN	24
#define     CORE_CFG_0_DSP_STREAMING	25
/* CAF cam_vfe_top_ver3.h: (~r2pd & 1) << shift. Default r2pd=0 → set bit. */
#define     CORE_CFG_0_DISP_DS4_R2PD	27
#define     CORE_CFG_0_DISP_DS16_R2PD	28
#define     CORE_CFG_0_VID_DS4_R2PD	29
#define     CORE_CFG_0_VID_DS16_R2PD	30
#define VFE_TOP_DEBUG_CFG		0xdc
#define VFE_TOP_DEBUG_0			0x80
/* CAF cam_vfe_camif_ver3.c: violation_status[5:0] is a module id, not a mask. */
#define     VIOL_ID_MASK		0x3f
#define     VIOL_ID_MNDS_C_DISP		19
#define VFE_CORE_CGC_OVD_1		0x94
#define VFE_VIOLATION_STATUS		0x74
#define CAMIF_DEBUG_1			0x27f0
#define CAMIF_DEBUG_0			0x27f4
#define VFE_CORE_CGC_OVD_0		0x20
#define VFE_AHB_CGC_OVD			0x24
#define VFE_NOC_CGC_OVD			0x28

#define VFE_REG_UPDATE_CMD		(vfe_is_lite(vfe) ? 0x20 : 0x34)
static inline int reg_update_rdi(struct vfe_device *vfe, int n)
{
	return vfe_is_lite(vfe) ? BIT(n) : BIT(1 + (n));
}

#define	    REG_UPDATE_RDI		reg_update_rdi
/* CAF cam_vfe480.h camif_reg_data.reg_update_cmd_data */
#define     REG_UPDATE_PIX		0x41
#define VFE_IRQ_CMD			(vfe_is_lite(vfe) ? 0x24 : 0x38)
#define     IRQ_CMD_GLOBAL_CLEAR	BIT(0)

#define VFE_IRQ_MASK(n)			((vfe_is_lite(vfe) ? 0x28 : 0x3c) + (n) * 4)
#define	    IRQ_MASK_0_RESET_ACK	(vfe_is_lite(vfe) ? BIT(17) : BIT(0))
#define	    IRQ_MASK_0_BUS_TOP_IRQ	(vfe_is_lite(vfe) ? BIT(4) : BIT(7))
/* CAF cam_vfe480.h error_irq_mask0 0x82000200: bit31 PIXEL PIPE OVERFLOW */
#define	    IRQ_MASK_0_PIX_OVERFLOW	BIT(31)
/* CAF subscribe_irq_mask1 0x7: CAMIF SOF / EOF / EPOCH */
#define	    IRQ_MASK_1_CAMIF		0x7
#define VFE_IRQ_CLEAR(n)		((vfe_is_lite(vfe) ? 0x34 : 0x48) + (n) * 4)
#define VFE_IRQ_STATUS(n)		((vfe_is_lite(vfe) ? 0x40 : 0x54) + (n) * 4)
#define VFE_DIAGNOSTIC_HW		0x64

#define BUS_REG_BASE			(vfe_is_lite(vfe) ? 0x1a00 : 0xaa00)

#define VFE_BUS_WM_CGC_OVERRIDE		(BUS_REG_BASE + 0x08)
#define		WM_CGC_OVERRIDE_ALL	(0x3FFFFFF)
/*
 * CAF cam_vfe480.h common_reg.comp_cfg_0/1 = 0xAA0C/0xAA10.
 * cam_vfe_bus_ver3_start_comp_grp writes them ONLY if is_dual:
 *   master: cfg0 bit(grp+14), cfg1 bit(grp)
 *   slave:  cfg0 bit(grp)|bit(grp+14), cfg1 bit(grp)
 * That is Dual-IFE address sync, not a WM4–7 membership mask.
 * HyperOS rear preview is single IFE1; #336 rst→ovf readback 0/0
 * matches CAF leaving them alone. Do not stuff 0xF0 / 0x30
 * (software composite_mask of clients 4–7) into these regs.
 * Client→COMP_GRP is the cam_vfe480.h table (DISP Y/C/DS4/DS16
 * = COMP_GRP_1). SRC_GRP frame headers are independent.
 */
#define VFE_BUS_COMP_CFG_0		(BUS_REG_BASE + 0x0c)
#define VFE_BUS_COMP_CFG_1		(BUS_REG_BASE + 0x10)
#define VFE_BUS_IF_FRAMEHEADER_CFG(n)	(BUS_REG_BASE + 0x34 + (n) * 4)
#define		BUS_FRAMEHEADER_GRPS	6
#define VFE_BUS_OVERFLOW_STATUS_CLEAR	(BUS_REG_BASE + 0x60)
#define VFE_BUS_DEBUG_STATUS_TOP_CFG	(BUS_REG_BASE + 0xd4)
#define VFE_BUS_DEBUG_STATUS_TOP	(BUS_REG_BASE + 0xd8)

#define VFE_BUS_WM_TEST_BUS_CTRL	(BUS_REG_BASE + 0xdc)

#define VFE_BUS_IRQ_MASK(n)		(BUS_REG_BASE + 0x18 + (n) * 4)
static inline int bus_irq_mask_0_rdi_rup(struct vfe_device *vfe, int n)
{
	return vfe_is_lite(vfe) ? BIT(n) : BIT(3 + (n));
}

#define     BUS_IRQ_MASK_0_RDI_RUP	bus_irq_mask_0_rdi_rup
static inline int bus_irq_mask_0_comp_done(struct vfe_device *vfe, int n)
{
	return vfe_is_lite(vfe) ? BIT(4 + (n)) : BIT(6 + (n));
}

#define     BUS_IRQ_MASK_0_COMP_DONE	bus_irq_mask_0_comp_done
#define VFE_BUS_IRQ_CLEAR(n)		(BUS_REG_BASE + 0x20 + (n) * 4)
#define VFE_BUS_IRQ_STATUS(n)		(BUS_REG_BASE + 0x28 + (n) * 4)
#define VFE_BUS_IRQ_CLEAR_GLOBAL	(BUS_REG_BASE + 0x30)
#define VFE_BUS_CCIF_VIOLATION		(BUS_REG_BASE + 0x64)
#define VFE_BUS_OVERFLOW_STATUS		(BUS_REG_BASE + 0x68)
#define VFE_BUS_IMAGE_SIZE_VIOLATION	(BUS_REG_BASE + 0x70)
#define     BUS_IRQ_MASK_0_PIX_RUP	BIT(0)

#define VFE_BUS_WM_CFG(n)		(BUS_REG_BASE + 0x200 + (n) * 0x100)
#define		WM_CFG_EN			(0)
#define		WM_CFG_MODE			(16)
#define			MODE_QCOM_PLAIN	(0)
#define			MODE_MIPI_RAW	(1)
#define VFE_BUS_WM_IMAGE_ADDR(n)	(BUS_REG_BASE + 0x204 + (n) * 0x100)
#define VFE_BUS_WM_FRAME_INCR(n)	(BUS_REG_BASE + 0x208 + (n) * 0x100)
#define VFE_BUS_WM_IMAGE_CFG_0(n)	(BUS_REG_BASE + 0x20c + (n) * 0x100)
#define		WM_IMAGE_CFG_0_DEFAULT_WIDTH	(0xFFFF)
#define VFE_BUS_WM_IMAGE_CFG_1(n)	(BUS_REG_BASE + 0x210 + (n) * 0x100)
#define VFE_BUS_WM_IMAGE_CFG_2(n)	(BUS_REG_BASE + 0x214 + (n) * 0x100)
#define VFE_BUS_WM_PACKER_CFG(n)	(BUS_REG_BASE + 0x218 + (n) * 0x100)
/*
 * CAF get_packer_fmt(NV12)=PLAIN_8_LSB_MSB_10=3 for Y and C.
 * NV21 chroma WM 1/3/5 is the ODD_EVEN twin (=4). Packer 3 was
 * last tried while Crop/MNDS still wrote CLC +0x64 spare, so
 * POST never finished; 4 on the same broken CLC also left
 * as0=0. CLC PIXEL/LINE and 2ppc V now stick — NV12 is 3.
 * 0xB is CamX UBWC overlay; do not write it onto linear NV12.
 * #365: chroma WM PLAIN_8=1 (Y stays 3).
 */
#define		PACKER_PLAIN_8			1
#define		PACKER_PLAIN_8_LSB_MSB_10	3
#define		PACKER_PLAIN_8_LSB_MSB_10_ODD_EVEN 4
#define		PACKER_PLAIN_64			10
#define		PACKER_UBWC_NV12		0xB
#define VFE_BUS_WM_DEBUG_CFG(n)		(VFE_BUS_WM_CFG(n) + 0x78)
/* CAF start_wm: bits[7:0]=status_0 mux, bits[15:8]=status_1.
 * Mux 1 is the packer FSM (dbg 0x20a/0x2ea). Mux 11 is
 * constraint_errors on debug_status_1; cfg=1 left that mux 0
 * so dbg1=0 was telemetry-blind.
 */
#define		WM_DEBUG_STATUS_0_MUX		1
#define		WM_DEBUG_STATUS_1_CONSTRAINT	11
#define VFE_BUS_WM_DEBUG(n)		(VFE_BUS_WM_CFG(n) + 0x7c)
/* CAF print_dimensions: 0=last consumed 1=last frame 2=fifo cnt 3=current. */
#define VFE_BUS_WM_ADDR_STATUS0(n)	(VFE_BUS_WM_CFG(n) + 0x68)
#define VFE_BUS_WM_ADDR_STATUS1(n)	(VFE_BUS_WM_CFG(n) + 0x6c)
#define VFE_BUS_WM_ADDR_STATUS2(n)	(VFE_BUS_WM_CFG(n) + 0x70)
#define VFE_BUS_WM_ADDR_STATUS3(n)	(VFE_BUS_WM_CFG(n) + 0x74)
/* CAF cam_vfe480.h common_reg.ubwc_static_ctrl. COMP_GRP_1 start ORs
 * DT ubwc-static-cfg. dagu is LPDDR5 → second cell 0x1036. This is
 * BUS DDR/UBWC encoder clocking, not "compress the NV12". Live
 * HyperOS preview also sets WM4/5 mode_cfg bit0 (UBWC_NV12); V4L2
 * linear keeps mode_cfg = 0.
 */
#define VFE_BUS_UBWC_STATIC_CTRL	(BUS_REG_BASE + 0x58)
#define		UBWC_STATIC_LPDDR5	0x1036
#define VFE_BUS_PWR_ISO_CFG		(BUS_REG_BASE + 0x5c)
#define VFE_BUS_WM_UBWC_BW_LIMIT(n)	(VFE_BUS_WM_CFG(n) + 0x1c)
#define VFE_BUS_WM_UBWC_META_ADDR(n)	(VFE_BUS_WM_CFG(n) + 0x40)
/*
 * CAF kona-camera.dtsi qcom,cam-cpas@ac40000 cam_camnoc. Linux
 * deleted camss interconnects because BCM rpmh_write_batch hangs
 * this QHEE. cam_cpastop_poweron still programs the NIU AHB LUTs
 * without ICC. IFE_LINEAR is DISP NV12; IFE_UBWC_STATS is WM6/7
 * PD10 in COMP_GRP_1; IFE_RDI_WR is the working RDI port.
 */
#define CAMNOC_PHYS			0x0ac42000UL
#define CAMNOC_SIZE			0x8000
#define CAMNOC_IFE_LINEAR		0xa00
#define CAMNOC_IFE_RDI_WR		0x1400
#define CAMNOC_IFE_UBWC_STATS		0x1a00
#define CAMNOC_NIU_FILL			0x20
#define CAMNOC_NIU_MAXWR		0x08
#define CAMNOC_NIU_PRI_LO		0x30
#define CAMNOC_NIU_PRI_HI		0x34
#define CAMNOC_NIU_URGENCY		0x38
#define CAMNOC_NIU_DANGER		0x40
#define CAMNOC_NIU_SAFE			0x48
#define CAMNOC_ERRVLD			0x7010
/* CAF cpastop_v480_100.h cam_cpas_v480_100_camnoc_specific */
#define CAMNOC_PRI_LO			0x66665433
#define CAMNOC_PRI_HI			0x66666666
#define CAMNOC_URGENCY			0x1030
#define CAMNOC_DANGER			0xffffff00
#define CAMNOC_SAFE			0x000f
#define VFE_BUS_WM_UBWC_META_CFG(n)	(VFE_BUS_WM_CFG(n) + 0x44)
#define VFE_BUS_WM_UBWC_MODE_CFG(n)	(VFE_BUS_WM_CFG(n) + 0x48)
#define VFE_BUS_WM_UBWC_STATS_CTRL(n)	(VFE_BUS_WM_CFG(n) + 0x4c)
#define VFE_BUS_WM_UBWC_CTRL_2(n)	(VFE_BUS_WM_CFG(n) + 0x50)
#define VFE_BUS_WM_DEBUG_1(n)		(VFE_BUS_WM_CFG(n) + 0x80)
/* CAF cam_vfe480.h client 4 frame_header_cfg 0xB028. */
#define VFE_BUS_WM_FRAME_HEADER_CFG(n)	(VFE_BUS_WM_CFG(n) + 0x28)
#define		DISP_META_PAGE		4096

#define VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(n)	(BUS_REG_BASE + 0x230 + (n) * 0x100)
#define VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(n)	(BUS_REG_BASE + 0x234 + (n) * 0x100)
#define VFE_BUS_WM_FRAMEDROP_PERIOD(n)		(BUS_REG_BASE + 0x238 + (n) * 0x100)
#define VFE_BUS_WM_FRAMEDROP_PATTERN(n)		(BUS_REG_BASE + 0x23c + (n) * 0x100)

#define VFE_BUS_WM_SYSTEM_CACHE_CFG(n)	(BUS_REG_BASE + 0x260 + (n) * 0x100)
#define VFE_BUS_WM_BURST_LIMIT(n)	(BUS_REG_BASE + 0x264 + (n) * 0x100)

/* for titan 480, each bus client is hardcoded to a specific path
 * and each bus client is part of a hardcoded "comp group"
 */
#define RDI_WM(n)			((vfe_is_lite(vfe) ? 0 : 23) + (n))
#define RDI_COMP_GROUP(n)		((vfe_is_lite(vfe) ? 0 : 11) + (n))

/* CAF cam_vfe480.h BUS client 4/5 DISP Y/C, COMP_GRP_1 */
#define DISP_Y_WM			4
#define DISP_C_WM			5
#define DISP_DS4_WM			6
#define DISP_DS16_WM			7
#define DISP_COMP_GROUP			1
/*
 * Live HyperOS COMP_GRP_1 mask 0xF0 = WM4–7. WM6/7 are PD10 after
 * DISP R2PD (format 0x24, packer PLAIN_64). Sizes/strides from the
 * 2026-09-16 21:06 start window, not invented.
 */
#define DISP_DS4_W			240
#define DISP_DS4_H			135
#define DISP_DS4_STRIDE			2048
#define DISP_DS4_INCR			327680
#define FRONT_DS4_INCR			720896
#define FRONT_DS4_STRIDE		2816
#define DISP_DS16_W			60
#define DISP_DS16_H			34
#define DISP_DS16_STRIDE		768
#define DISP_DS16_INCR			49152

#define MAX_VFE_OUTPUT_LINES	4

/*
 * Titan 480 CLC from camera.qcom.so CreateCmdList (titan480 HWL),
 * not from MOVZ #0x5600 / stats 0x8c00. module_cfg is base+0x60
 * except Demux13, which packs 7 AHB regs at 0x3090.
 *
 *   CAMIF PP     0x2660 / crop 0x2668  camxifecamifpptitan480.cpp
 *   Demux13      0x3090 x7 compact live 2026-09-17, not identity GBRG map
 *   Demosaic36   0x3860                camxifedemosaic36titan480.cpp
 *   CST12        0x4060 / 0x4068 x12   camxifecst12titan480.cpp
 *   RoundClamp   0x4260 x1 + 0x4270 x6 camxiferoundclamp11titan480.cpp
 *   Crop11 Y/C   0x4460/0x4660 x9      camxifecrop11titan480.cpp
 *   RoundClamp MID Y/C 0x4860/0x4a60   idx 1 between Crop and MNDS
 *   MNDS Disp Y  0x4c60 x9             "Scaler Display(Full) path"
 *   MNDS Disp C  0x4e60 x9
 *   RoundClamp POST Y/C 0x5060/0x5260 + 0x5070/0x5270 x6
 *
 * 0x8c00/0x8e00 are CS/iHist stats. 0x6400 is Video Full MNDS.
 * Do not STREAMON DISP without demux+demosaic+MNDS — empty CLC
 * hangs CAMNOC. POST RoundClamp EN=0 backs up MNDS C at line 1530.
 */
#define CLC_MODULE_CFG			0x60
#define CLC_PREPROCESS			0x2200
/* CamX 0x4e7688 DMI helper: w2=sel w4=offset w5=count. #315 used
 * sel4 offset 0x280 as n. Banks: 1 n=0x100, 2 n=0x100, 3 n=0x80,
 * 4 n=0xa8. Do not pack 0x2268 x46 zeros (reset / ABF class).
 */
#define     BLS_DMI_BANKS		4
#define     BLS_DMI_N1			0x100
#define     BLS_DMI_N2			0x100
#define     BLS_DMI_N3			0x80
#define     BLS_DMI_N4			0xa8
#define CLC_CAMIF			0x2600
#define     CAMIF_EN			BIT(0)
#define     CAMIF_IFE_OUT_EN		BIT(8)
/* CamX 0x526538: BFI pattern, #24, #3 into CAMIF MODULE_CFG. */
#define     CAMIF_PIXEL_PATTERN		24
#define CAMIF_SPARE			0x2664
#define CAMIF_CROP_WIDTH		0x2668
#define CAMIF_CROP_HEIGHT		0x266c
#define CAMIF_LINE_SKIP			0x2670
#define CAMIF_PIXEL_SKIP		0x2674
#define CAMIF_PERIOD			0x2678
#define CAMIF_IRQ_SUBSAMPLE		0x267c
#define CLC_CAMIF_EPOCH			0x2680
/*
 * CamX titan480 IFE PP CreateCmdList between CAMIF and Demux.
 * Same CLC as BLS: EN=0 is a brick wall (violation bit1 on 0x2200).
 */
#define CLC_PDPC11			0x2800
#define CLC_PDPC30			0x2e00
#define     PDPC30_AHB			0x68
#define     PDPC30_AHB_N		16
#define     PDPC30_DMI_N		0x90
#define     PDPC_GAIN_UNITY		0x400
/*
 * Pedestal13 compact CreateCmdList @0x540a30: MODULE_CFG 0x2c60 x1.
 * FULL @0x540198 packs 0x2c68 x5 + DMI 0x2c08 banks 1/2 ×0x208.
 * BLS EN=0 is a brick wall on this CLC; pedestal is the same class
 * of black-level subtract. Identity is a zero LUT (subtract 0),
 * not empty EN. Compact does not pack 0x2c5c / 0x2c68.
 */
#define CLC_PEDESTAL			0x2c00
#define     PEDESTAL_LUT_N		0x208
#define     PEDESTAL_WIN		0x5c
#define     PEDESTAL_AHB		0x68
#define CLC_ABF				0x3200
/*
 * camera.qcom.so has no IFE GIC HWL. Linux called 0x3400 "GIC".
 * Compact ABF bank1 @0x5359d8 is 0x3260 x1. Compact bank2 @0x528688
 * is 0x3460 x1. FULL @0x5275b8 packs 0x3458 x3 + 0x3468 x46 + DMI
 * 0x3408. DumpRegConfig SECTION 0x3458/0x3468 is the IQ object, not
 * CreateCmdList. Do not pack 0x3458/0x3468. PackIQ @0x5279c0: 12-bit
 * last/first at object+36/+40 = 0x3270/0x3274. compact leaves 0x3268
 * at HW reset 0x8000/0x1000100. Do not Crop11 0x3268 / 0x3270.
 */
#define     ABF_REGION			0x70
#define CLC_GIC				0x3400
#define     ABF_BANK2_DMI_N1		0x100
#define     ABF_BANK2_DMI_N3		0x80
#define     ABF_BANK2_DMI_N4		0xa8
#define     ABF_BANK2_LUT_BANK		0x58
#define     ABF_BANK2_AHB		0x68
#define     ABF_BANK2_AHB_N		46
/* Live DumpRegConfig 0x3460, not BIT(0). Compact ABF is 0x3260 only. */
#define     ABF_BANK2_MODULE		0xc101
#define CLC_HDR				0x2400
/* CAF cam_vfe480.h: only CAMIF has debug_0 at 0x27F4. CLC +0x04 is
 * hw_status (CAMIF 0x2604). Crop +0x64 is the spare/status hole.
 */
#define CLC_HW_STATUS			0x04
#define CLC_CAMIF_DEBUG_1		0x1f0
#define CLC_CC				0x3a00
/*
 * camera.qcom.so CC13 CreateCmdList: 1 AHB word MODULE_CFG at 0x3a60
 * then 9 words at 0x3a68 from IQ+0x1c. Compact packs 0x3a60 x1 only.
 * +0x64 is the same spare hole as Crop/CAMIF.
 * EN=1 with a zero 3×3 is not BLS-style pass-through — it multiplies
 * RGB by 0 so POST never presents packer valid (as0=0, viol_id=0).
 * Live DumpRegConfig packs 13-bit pairs (A0=0x80, B1=0x80, C2=0x80),
 * not nine Q10 scalars. Q10 0x400 on the diagonal zeroed B0|B1.
 */
#define     CLC_CC_SPARE		0x64
#define     CLC_CC_MATRIX		0x68
#define     CC_GAIN_UNITY		0x400
/*
 * camera.qcom.so titan480 CreateCmdList between Demosaic/CC and CST.
 * GTM10 0x3658 x15, WB13 0x3c58 x3, Gamma16 0x3e58 x3. Linearization34
 * compact is 0x2a60 x6 after PDPC11. CalculateHWSetting packs DMI
 * n=36 (9 PWL segments × 4 channels) as 14-bit pairs at 0x2a08
 * banks 1/2, then 6 AHB words from MODULE_CFG. Empty EN=1 overflowed
 * line 0. EN=0 was never identity-tested (BLS-class candidate).
 */
#define CLC_LIN				0x2a00
#define     LIN_DMI_N			36
#define CLC_GTM				0x3600
/*
 * 0x3600 is LSC40 (camxifelsc40titan480.cpp @0x5378a8), not GTM10.
 * GTM10 packs 0x3c58/0x3c08. FULL LSC: 0x3658 x3, 0x3668 x11,
 * DMI 0x3608 sel1/2/3 n=0x374 (=17x13x4). Compact only 0x3660 x1.
 * Empty EN=1 overflowed line 0. Identity DMI is Q10 pair unity.
 *
 * #329 EN=1 with 0x3668=0: interpolator window empty, as0=0
 * line=1530. PackIQ @0x537e6c: config0 bits[3:0]/[7:4] = mesh-2
 * (15/11 → 17x13). Live DumpRegConfig Config 0-10 (not a 256×128
 * guess): 0xbf, 0x7f007f, 0x1000000f×2, 0x30004, 0, 0x30000,
 * 0x4000400, 0x40, 0, 0. Identity DMI is Q10 pair unity.
 */
#define     GTM_DMI_N			0x374
#define     LSC_AHB			0x68
#define     LSC_CFG_N			11
#define     LSC_MESH_HM2		15
#define     LSC_MESH_VM2		11
#define CLC_WB				0x3c00
#define CLC_GAMMA			0x3e00
#define     CLC_DMI_CFG			0x08
#define     CLC_DMI_LUT			0x0c
#define     GAMMA_LUT_N			256
#define     WB_LUT_N			512
#define CLC_DEMUX_BASE			0x3000
#define CLC_DEMUX			0x3090
#define     DEMUX_GAIN_UNITY		0x04000400
#define     DEMUX_PERIOD_KEEPALL	0x00010001
/*
 * Compact CreateCmdList @0x52dfbc: 0x3090 x7 from IQ object+0x18.
 * Live DumpRegConfig 2026-09-17 (rear IFE1), not Q10 unity / GBRG map:
 *   +0x18 moduleConfig 0x3c003c01 → 0x3090
 *   +0x1c gainCH0      0x10111011 → 0x3094
 *   +0x20 gainCH12     0x10101010 → 0x3098
 *   +0x24 rightGainCH0 0x10111011 → 0x309c
 *   +0x28 rightGainCH12 0x10101010 → 0x30a0
 *   +0x2c even         0xac       → 0x30a4
 *   +0x30 odd          0xc9       → 0x30a8
 * DEMUX_EVEN_GBRG stays as the 2-bit map name persist needs; compact
 * does not pack that encoding at 0x3090.
 */
#define     DEMUX_COMPACT_CFG		0x3c003c01
#define     DEMUX_COMPACT_GAIN0		0x10111011
#define     DEMUX_COMPACT_GAIN12	0x10101010
#define     DEMUX_COMPACT_EVEN		0xac
#define     DEMUX_COMPACT_ODD		0xc9
#define     DEMOSAIC_COMPACT_CFG	0x4001
/*
 * camera.qcom.so Demux13 CreateCmdList @0x53ef10: 0x3058 x3
 * (ends at MODULE_CFG 0x3060), skip +0x64 spare, 0x3068 x10,
 * 0x30ac x10, DMI 0x3008 banks 1×512 + 2×256. Compact HWL
 * still packs 7 words at 0x3090 from IQ+0x18 (live values above).
 *
 * Live: 0x0FEF0000 at 0x3068 → 0 (not PIXEL). 0x00010001 at
 * 0x3068 → 0x1 (bit16 drops, same class as MNDS 0x103→0x101).
 * Word0 is EN; period keep-all belongs at +0x6c like 0x3094.
 */
#define     DEMUX_WIN			0x68
#define     DEMUX_WIN_N			10
#define     DEMUX_TAIL			0xac
/*
 * CreateCmdList 0x53ef44 packs 0x30ac ×10 from object+0x4c.
 * EN+period at 0x30ac/0x30b0 dropped (spare hole, #Demux-tail).
 * MODULE of a Crop11 block sits at base+0x60, so a Crop11 whose
 * MODULE is 0x30ac has base 0x304c. Reset 0 there is an empty
 * window after Demux period — CLC after Demux never presents
 * packer valid (as0=0, viol_id=0, line=1530).
 */
#define     CLC_DEMUX_TAIL_CROP		0x304c
#define     DEMUX_DMI1_N		0x200
#define     DEMUX_DMI2_N		0x100
/* 2-bit channel map, 0=R 1=GR 2=GB 3=B. GBRG even GB,B odd R,GR. */
#define     DEMUX_EVEN_GBRG		0xeeeeeeee
#define     DEMUX_ODD_GBRG		0x44444444
#define CLC_DEMOSAIC			0x3800
#define CLC_DEMOSAIC_INTERP		0x3878
#define     DEMOSAIC_WB			0x68
#define     DEMOSAIC_WB_N		4
/*
 * CamX compact Demosaic36 is {0x3860, 1} MODULE_CFG only. FULL Fill
 * packs 13-bit pairs into 0x3878/0x387c (mid-scale 0x80 → 0x800080).
 * Writing that over HW reset is the ABF 0x3268 class. Dump interp;
 * do not program it until a CamX compact dump shows those dwords.
 *
 * camxifewb13titan480 CreateCmdList @0x546be8 packs 0x3868 x4, not
 * 0x3c58 (that is GTM10). Reset 0 at the four channel gains after
 * Demosaic EN=1 is a black RGB brick (CAMIF still counts line=1530,
 * packer as0=0). Identity is Q10 0x400 like Demux/CC. Do not touch
 * 0x3878.
 */
#define     DEMOSAIC_INTERP_MID		((0x80 << 16) | 0x80)
#define CLC_CST				0x4000
#define CLC_CST_MATRIX			0x4068
/*
 * CreateCmdList Display: CST → RoundClamp11 PRE 0x4200 → Crop11 Y
 * 0x4400 / C 0x4600 → RoundClamp11 MID 0x4800/0x4a00 → MNDS →
 * RoundClamp11 POST 0x5000/0x5200. Compact {0x4260,10} is MODULE_CFG
 * + spare + PIXEL/LINE + 6 clamp words. FULL packs 0x4260×1 +
 * 0x4270×6, then a second list writes 0x4268×2 / 0x5068×2 /
 * 0x5268×2 (same +0x68/+0x6c keep-all as Crop11). Reset 0 there
 * is an empty window: POST EN=1 still never presents packer valid.
 */
#define CLC_RNDCLAMP			0x4200
/*
 * 0x4400/0x4600 and 0x4800/0x4a00 are the FD (Face Detection) branch:
 * MNDS Y/C and round clamp Y/C feeding bus WM8/9 (CAF cam_vfe480.h
 * VFE_OUT_FD, max 1920x1080). Android Camera ID 1 runs them at
 * 640x480 (H phase 0xc081999a = 2592/640, V 0xc0822222 = 1952/480,
 * clamp 0x1df/0x27f) with WM8 IMAGE_CFG_0 0x01e00280. Linux has no
 * FD port, so these stay off: see vfe_480_fd_off(). The names below
 * are kept for the dump code only.
 */
#define CLC_CROP			0x4400
#define CLC_CROP_C			0x4600
/*
 * Titan 480 CLC +0x64 is the same spare/status hole as CAMIF_SPARE
 * 0x2664. PIXEL at +0x64 bounced 0x0FEF0000 → 0x6d0000 (empty
 * horizontal window, 0 AXI). Width/height sit at +0x68/+0x6c like
 * CAMIF_CROP_WIDTH/HEIGHT.
 */
#define     CROP_SPARE			0x64
#define     CROP_PIXEL			0x68
#define     CROP_LINE			0x6c
/*
 * CamX CreateCmdList packs 9 AHB words from 0x4460. PIXEL/LINE at
 * +0x68/+0x6c stick; +0x64 is the CAMIF spare hole. The remaining
 * five words are the same stripe/pad handshake as Display MNDS
 * (H_STRIPE last in [31:16]). Reset 0 is an empty stripe: POST
 * never presents packer valid (WM4 dbg=0, as0=0, viol_id=0).
 */
#define     CROP_H_STRIPE		0x70
#define     CROP_H_PAD			0x74
#define     CROP_V_SIZE			0x78
#define     CROP_V_PHASE		0x7c
#define     CROP_V_STRIPE		0x80
#define CLC_RNDCLAMP_MID_Y		0x4800
#define CLC_RNDCLAMP_MID_C		0x4a00
#define CLC_MNDS_Y			0x4c00
#define CLC_MNDS_C			0x4e00
#define CLC_RNDCLAMP_POST_Y		0x5000
#define CLC_RNDCLAMP_POST_C		0x5200
/*
 * CamX compact after POST C {0x5260,10}: {0x5504,2} {0x5704,2}
 * {0x5a60,10}. CreateCmdList packs 0x5860×1 + 0x5870×6 and
 * 0x5868×2 / 0x5a68×2 — same RoundClamp11 IP as POST. #316
 * OUT keep-all stuck (outy=0x77f0000/0x4370000) and still
 * as0=0 packer 0x2ea — EN=0 there is not the remaining stall.
 *
 * compact CreateCmdList @0x52e8e0 reads IQ +0x6c:
 *   5 → TAP 0x5408×2 / 0x5504×2 (DS4)
 *   6 → TAP 0x5c08×2 / 0x5d04×2 (DS16 AHB, not DMI LUT)
 *   3 → TAP 0x7408×2 / 0x7504×2
 *   else Display Full: ret, packs nothing. Linear NV12 is
 *   WM4/5; type-5/6 TAP is off.
 * #317: 0x5408 bounced 0 (CLC DMI_CFG auto-clear), 0x540c stuck
 * with LINE — crop encoding stuffed into the DS4 Y LUT.
 * #318: empty Crop EN at 0x5e00 STREAMON EPIPE -32. Do not
 * write TAP crop/DMI or EN 0x5e00. Dump 0x5408/0x5504 as
 * reset. Empty ADDR WM6/7 hung CAMNOC. #425 starts WM6/7
 * with dummy IOVA + live sizes, no 0x5608 CLC EN.
 *
 * IFE DSX10 @0x509548 / @0x5018d4 (DMI 0x5c08 sel 1..13 +
 * 0x5e68×9) has zero BL xrefs. ELF 0x8bba10 live vtable packs
 * BPS 0x6c58, not IFE 0x5e68. LUT bytes still missing.
 * Filling (i<<8)|i or zeros is the LIN/empty-EN class.
 */
#define CLC_DS411_Y_CROP		0x5408
#define CLC_DS411_C_CROP		0x5504
#define CLC_RNDCLAMP_OUT_Y		0x5800
#define CLC_RNDCLAMP_OUT_C		0x5a00
#define     RNDCLAMP_CH0		0x70
#define     RNDCLAMP_MODULE_CFG		0x3c01

/*
 * Display MNDS21: MODULE_CFG at +0x60, then 8 config words from
 * +0x68 (camxifemnds21titan480.cpp + CAMIF spare hole). +0x64 is
 * RO status: H_SIZE 0x077F0FEF bounced to 0x6d0600 while +0x68
 * stuck. Writing phase into the size slot is in_w=1 → packer wait.
 */
#define MNDS_SPARE			0x64
#define MNDS_H_SIZE			0x68
#define MNDS_H_PHASE			0x6c
#define MNDS_H_STRIPE			0x70
#define MNDS_H_PAD			0x74
#define MNDS_V_SIZE			0x78
#define MNDS_V_PHASE			0x7c
#define MNDS_V_STRIPE			0x80
#define MNDS_V_PAD			0x84
#define MNDS_PHASE_Q			21

static void vfe_global_reset(struct vfe_device *vfe)
{
	writel_relaxed(IRQ_MASK_0_RESET_ACK, vfe->base + VFE_IRQ_MASK(0));
	writel_relaxed(GLOBAL_RESET_HW_AND_REG, vfe->base + VFE_GLOBAL_RESET_CMD);
}

static u32 vfe_480_pixel_pattern(u32 code)
{
	switch (code) {
	case MEDIA_BUS_FMT_SRGGB8_1X8:
	case MEDIA_BUS_FMT_SRGGB10_1X10:
	case MEDIA_BUS_FMT_SRGGB12_1X12:
	case MEDIA_BUS_FMT_SRGGB14_1X14:
		return 0;
	case MEDIA_BUS_FMT_SGRBG8_1X8:
	case MEDIA_BUS_FMT_SGRBG10_1X10:
	case MEDIA_BUS_FMT_SGRBG12_1X12:
	case MEDIA_BUS_FMT_SGRBG14_1X14:
		return 1;
	case MEDIA_BUS_FMT_SBGGR8_1X8:
	case MEDIA_BUS_FMT_SBGGR10_1X10:
	case MEDIA_BUS_FMT_SBGGR12_1X12:
	case MEDIA_BUS_FMT_SBGGR14_1X14:
		return 2;
	case MEDIA_BUS_FMT_SGBRG8_1X8:
	case MEDIA_BUS_FMT_SGBRG10_1X10:
	case MEDIA_BUS_FMT_SGBRG12_1X12:
	case MEDIA_BUS_FMT_SGBRG14_1X14:
	default:
		return 3; /* GBRG: s5kjn1 */
	}
}

static void vfe_480_clc_enable(struct vfe_device *vfe, u32 base, u32 val)
{
	writel_relaxed(val, vfe->base + base + CLC_MODULE_CFG);
}

static void vfe_480_pack(struct vfe_device *vfe, u32 addr,
			 const u32 *w, unsigned int n)
{
	unsigned int i;

	for (i = 0; i < n; i++)
		writel_relaxed(w[i], vfe->base + addr + i * 4);
}


/*
 * 2026-10-23 device: per-frame GIC bank flip and per-frame Demux
 * steady (bank / 0x00e24203 / 0x04df04df) both ran from this RUP.
 * Each logged, each left /tmp/pix.nv12 at 8110080, one COMP_DONE,
 * a second CAMIF SOF, then no epoch. Do not put either write back.
 */


/*
 * Live IFE CDM 2026-09-17 (1MB dmabuf, Display Full packet 2):
 * FULL @0x53ef10 packs 0x3058 x3 + 0x3068 x10 + 0x30ac x10 AND
 * compact 0x3090 x7. Reset 0 at 0x30ac is an empty window after
 * Demux — packer as0=0, viol_id=0, line=1530. Do not Crop11-guess
 * last/first onto 0x3068; these 10-word blobs are the CDM.
 */
static void vfe_480_demux(struct vfe_device *vfe, u32 in_w, u32 in_h)
{
	static const u32 live_3090[] = {
		DEMUX_COMPACT_CFG, DEMUX_COMPACT_GAIN0, DEMUX_COMPACT_GAIN12,
		DEMUX_COMPACT_GAIN0, DEMUX_COMPACT_GAIN12,
		DEMUX_COMPACT_EVEN, DEMUX_COMPACT_ODD,
	};
	static const u32 live_3058[] = {
		0x00000001, 0x00000001, 0x00e35203,
	};
	static const u32 live_3068[] = {
		0x000003c0, 0x01001000, 0x00004020, 0x00140014,
		0x00001a5c, 0x00001d4f, 0x000009b6, 0x000008bc,
		0x00020008, 0x0bf40ff0,
	};
	static const u32 live_30ac[] = {
		0x0000443c, 0x000003ff, 0x00000000, 0x00200080,
		0x00000020, 0x000a000a, 0x00000064, 0x00000080,
		0x00000060, 0x00000014,
	};

	/*
	 * live_3068 last word 0x0bf40ff0 is rear 4080×3060. Packing
	 * that onto imx596 2592×1952 leaves Demux after CAMIF with
	 * an empty window (#367 overflow line=976 as0=0). Camera ID 1
	 * heap: last 0x07a00a20, 3058 third word 0xe24203.
	 * 0x3090 even/odd 0xac/0xc9 is GBRG compact (rear). Front
	 * BGGR heap 0x3090 is 0x08c908c9 ×4 + even 0xca odd 0x9c.
	 */
	if (in_w == 4080 && in_h == 3060) {
		vfe_480_pack(vfe, CLC_DEMUX, live_3090, ARRAY_SIZE(live_3090));
		vfe_480_pack(vfe, 0x3058, live_3058, ARRAY_SIZE(live_3058));
		vfe_480_pack(vfe, 0x3068, live_3068, ARRAY_SIZE(live_3068));
		vfe_480_pack(vfe, 0x30ac, live_30ac, ARRAY_SIZE(live_30ac));
	} else if (in_w == 2592 && in_h == 1952) {
		/*
		 * #419 Camera ID 1 live 1MB CDM 2026-09-18 15:24:
		 * 0x3090 compact gain 0x04040404 (not heap 0x08c908c9),
		 * 0x3068 middle 0x20b1/0x17e7/0x7d5/0xab6. Last still
		 * 0x07a00a20. #417/#418 640 MID/OUT dest 0-byte; Demux
		 * blob was still the heap snapshot. One module.
		 * #419 on #436: demux=0x3c003c01/0x4040404 stuck,
		 * /tmp/pix.nv12 0 bytes, viol=0 img=0 bus=0 as0=0,
		 * mid_y=0xe01/0x79f/0xa1f. Same quiet class as #413.
		 * Compact gain is not the identity stall. Keep.
		 * #420 first-list 0x3058 {0,0,0xe24003} @0x1c0 with
		 * that 0x3090/0x3068. Linux still had later-list
		 * {1,1,0xe24203} @0x114a0 (AWB 0x04df04df companion).
		 * One variable: Demux 0x3058 first-list. Do not
		 * 0x04df04df. Do not 640 dest. Do not Dual-IFE.
		 * #420 on #437: /tmp/pix.nv12 0 bytes, viol=0
		 * img=0x0 as0=0 bus=0x0, demux still 0x4040404.
		 * Same quiet class as #419. 0x3058 first-list is
		 * not the identity stall. Keep.
		 */
		static const u32 front_3090[] = {
			0x3c003c01, 0x04040404, 0x04040404, 0x04040404,
			0x04040404, 0x000000ca, 0x0000009c,
		};
		static const u32 front_3058[] = {
			0x00000000, 0x00000000, 0x00e24003,
		};
		static const u32 front_3068[] = {
			0x000003c0, 0x01001000, 0x00004020, 0x00140014,
			0x000020b1, 0x000017e7, 0x000007d5, 0x00000ab6,
			0x00000000, 0x07a00a20,
		};
		static const u32 front_30ac[] = {
			0x0000443c, 0x000003ff, 0x00000000, 0x00200080,
			0x00000020, 0x000a000a, 0x00000064, 0x00000040,
			0x00000060, 0x00000014,
		};

		vfe_480_pack(vfe, CLC_DEMUX, front_3090, ARRAY_SIZE(front_3090));
		vfe_480_pack(vfe, 0x3058, front_3058, ARRAY_SIZE(front_3058));
		vfe_480_pack(vfe, 0x3068, front_3068, ARRAY_SIZE(front_3068));
		vfe_480_pack(vfe, 0x30ac, front_30ac, ARRAY_SIZE(front_30ac));
		/*
		 * ABF both-banks, LSC both-banks on pipe_h=736, and
		 * copying this AHB into Demux bank 1 each logged and
		 * each left 8110080, one COMP_DONE, second SOF
		 * dbg0=0x2e00a20, viol=0. Do not write Demux bank 1
		 * again. Do not leave 0x3058 at 1. Do not write
		 * 0x04df04df. Do not invent the 0x3008 DMI.
		 */
	}
}

/*
 * CC13 FULL CreateCmdList @0x52925c: 0x3a60 x1 from +0x18, 0x3a68 x9
 * from +0x1c. Live IQ 2026-09-17 (rear IFE1), not unpacked Q10:
 *   A0=0x80 A1=0 / B0=0 B1=0x80 / C0=0 C2=0x80, offsets 0, shift 0.
 */
static void vfe_480_cc(struct vfe_device *vfe)
{
	static const u32 live_cc13[9] = {
		0x80, 0,
		0x800000, 0,
		0, 0x80,
		0, 0, 0,
	};
	u32 i;

	/* #362: restore live CC EN; PDPC30 stays MODULE=0. */
	vfe_480_clc_enable(vfe, CLC_CC, BIT(0));
	writel_relaxed(0, vfe->base + CLC_CC + CLC_CC_SPARE);
	for (i = 0; i < 9; i++)
		writel_relaxed(live_cc13[i],
			       vfe->base + CLC_CC + CLC_CC_MATRIX + i * 4);
}

/*
 * Gamma16 CDM DMI_32: DMIAddr 0x3e08, DMISel 1/2/3, 0x100 words.
 * CDM writes sel to DMI_CFG then bursts LUT to DMI_CFG+4. 16-bit
 * identity (i<<8)|i is the pass-through curve, not an empty EN.
 */
static void vfe_480_clc_dmi32(struct vfe_device *vfe, u32 base, u32 sel,
			      const u32 *lut, unsigned int n)
{
	unsigned int i;

	writel_relaxed(sel, vfe->base + base + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < n; i++)
		writel_relaxed(lut[i], vfe->base + base + CLC_DMI_LUT);
	wmb();
}

/*
 * Front provider capture 2026-10-24, frame 0 at IOVA 0xdfdc0000.
 * CDM length is bytes, so each table is that many words, not the
 * old 4× word counts. Android's live IFE1 read on 2026-10-24
 * had gamma=1 and wb=1 while preview was not black. #613 wrote
 * the LUT first and MODULE=1 after, and Y was 0. The captured
 * command writes MODULE, then the LUT. Lens shading and defect
 * correction stay bypassed. Do not replay the packet-1 program.
 */
static void vfe_480_front_live_dmi(struct vfe_device *vfe)
{
	vfe_480_clc_dmi32(vfe, CLC_GIC, 1, dagu_front_abf1,
			  ARRAY_SIZE(dagu_front_abf1));
	vfe_480_clc_dmi32(vfe, CLC_GIC, 3, dagu_front_abf3,
			  ARRAY_SIZE(dagu_front_abf3));
	vfe_480_clc_dmi32(vfe, CLC_GIC, 4, dagu_front_abf4,
			  ARRAY_SIZE(dagu_front_abf4));
	writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_CFG);

	vfe_480_clc_dmi32(vfe, CLC_DEMUX_BASE, 1, dagu_front_dmx1,
			  ARRAY_SIZE(dagu_front_dmx1));
	vfe_480_clc_dmi32(vfe, CLC_DEMUX_BASE, 2, dagu_front_dmx2,
			  ARRAY_SIZE(dagu_front_dmx2));
	writel_relaxed(0, vfe->base + CLC_DEMUX_BASE + CLC_DMI_CFG);

	vfe_480_clc_dmi32(vfe, CLC_PDPC30, 1, dagu_front_pdpc,
			  ARRAY_SIZE(dagu_front_pdpc));
	writel_relaxed(0, vfe->base + CLC_PDPC30 + CLC_DMI_CFG);

	vfe_480_clc_dmi32(vfe, CLC_GTM, 1, dagu_front_lsc1,
			  ARRAY_SIZE(dagu_front_lsc1));
	vfe_480_clc_dmi32(vfe, CLC_GTM, 2, dagu_front_lsc2,
			  ARRAY_SIZE(dagu_front_lsc2));
	vfe_480_clc_dmi32(vfe, CLC_GTM, 3, dagu_front_lsc3,
			  ARRAY_SIZE(dagu_front_lsc3));
	writel_relaxed(0, vfe->base + CLC_GTM + CLC_DMI_CFG);

	writel_relaxed(0, vfe->base + 0x3c58);
	writel_relaxed(0, vfe->base + 0x3c5c);
	writel_relaxed(0, vfe->base + 0x3c60);
	wmb();
	vfe_480_clc_dmi32(vfe, CLC_WB, 1, dagu_front_wb,
			  ARRAY_SIZE(dagu_front_wb));
	writel_relaxed(0, vfe->base + CLC_WB + CLC_DMI_CFG);

	writel_relaxed(0, vfe->base + 0x3e58);
	writel_relaxed(0, vfe->base + 0x3e5c);
	writel_relaxed(0, vfe->base + 0x3e60);
	wmb();
	vfe_480_clc_dmi32(vfe, CLC_GAMMA, 1, dagu_front_g1,
			  ARRAY_SIZE(dagu_front_g1));
	vfe_480_clc_dmi32(vfe, CLC_GAMMA, 2, dagu_front_g2,
			  ARRAY_SIZE(dagu_front_g2));
	vfe_480_clc_dmi32(vfe, CLC_GAMMA, 3, dagu_front_g3,
			  ARRAY_SIZE(dagu_front_g3));
	writel_relaxed(0, vfe->base + CLC_GAMMA + CLC_DMI_CFG);
	wmb();
	dev_info(vfe->camss->dev, "dagu front dmi order gamma=0x%x wb=0x%x\n",
		 readl_relaxed(vfe->base + CLC_GAMMA + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_WB + CLC_MODULE_CFG));
}

static void vfe_480_gamma(struct vfe_device *vfe)
{
	u32 lut[GAMMA_LUT_N];
	unsigned int i, bank;

	for (i = 0; i < GAMMA_LUT_N; i++)
		lut[i] = (i << 8) | i;
	for (bank = 1; bank <= 3; bank++)
		vfe_480_clc_dmi32(vfe, CLC_GAMMA, bank, lut, GAMMA_LUT_N);
	writel_relaxed(0, vfe->base + CLC_GAMMA + CLC_DMI_CFG);
	wmb();
	/*
	 * 0x3e58×3 lands on 0x3e58/0x3e5c/0x3e60. Third word is
	 * MODULE_CFG. #351 packed 0,0,1: MODULE still 1, AXI as0
	 * consumed, NV12 all zero. Identity DMI is not live
	 * 0xdfdcXXXX. #352 MODULE=0 until a real Gamma LUT exists.
	 */
	vfe_480_pack(vfe, 0x3e58, (const u32[]){ 0, 0, 0 }, 3);
}

/*
 * WB13 CDM DMI_32: DMIAddr 0x3c08, DMISel 1, 0x200 words. Gamma
 * identity DMI already proved this protocol (EN=1, line=1530, no
 * line-0 overflow). Q10 pair unity matches Demux. EN=0 between
 * CC and Gamma may still be a hardwired RGB stall.
 */
static void vfe_480_wb(struct vfe_device *vfe)
{
	unsigned int i;

	writel_relaxed(1, vfe->base + CLC_WB + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < WB_LUT_N; i++)
		writel_relaxed(DEMUX_GAIN_UNITY,
			       vfe->base + CLC_WB + CLC_DMI_LUT);
	wmb();
	writel_relaxed(0, vfe->base + CLC_WB + CLC_DMI_CFG);
	wmb();
	/*
	 * Same map as Gamma: 0x3c60 is MODULE. #351 0,0,1 kept EN
	 * and wrote zeros. True bypass is 0,0,0. Comment about
	 * EN=0 RGB stall is the #352 falsifier — keep live Crop.
	 */
	vfe_480_pack(vfe, 0x3c58, (const u32[]){ 0, 0, 0 }, 3);
}

static void vfe_480_gtm(struct vfe_device *vfe, u32 last_x, u32 last_y)
{
	static const u32 live_lsc40[LSC_CFG_N] = {
		LSC_MESH_HM2 | (LSC_MESH_VM2 << 4), /* Config 0 = 0xbf */
		0x007f007f,
		0x1000000f,
		0x1000000f,
		0x00030004,
		0,
		0x00030000,
		0x04000400,
		0x40,
		0,
		0,
	};
	unsigned int i, bank;

	/* AHB is the live 4080×1530 dump, not a 256×128 guess. */
	for (bank = 1; bank <= 3; bank++) {
		writel_relaxed(bank, vfe->base + CLC_GTM + CLC_DMI_CFG);
		wmb();
		for (i = 0; i < GTM_DMI_N; i++)
			writel_relaxed(DEMUX_GAIN_UNITY,
				       vfe->base + CLC_GTM + CLC_DMI_LUT);
		wmb();
	}
	writel_relaxed(0, vfe->base + CLC_GTM + CLC_DMI_CFG);
	wmb();
	/*
	 * #356 rear: live 0x3668 stays; 0x3660 MODULE=0 is true bypass.
	 * #329 EN=1 with 0x3668=0 emptied as0. Do not EN LSC with empty 0x3668.
	 * #442 Camera ID 1 first-list 0x3658 {0,0,0x01002001} then
	 * 0x3668 n=11 (not rear DumpRegConfig 0x7f007f). One
	 * variable: identity LSC AHB pair. Do not retry Crop 640.
	 * Do not Dual-IFE. Do not pack chroma 7.
	 * #442 on #460: gtm=0x1002001 stuck, incr6=0xb0000
	 * wm6=0xf40144 packer6=0xa, /tmp/pix.nv12 0 bytes,
	 * viol=0 img=0xc0 as0 Y=0 C=0xff4d3400 bus=0x80000000
	 * camif irq1 0x1 0xc 0x2 0x1. Same stall as #441.
	 * 0x3658 first-list LSC is not the identity stall. Keep.
	 */
	/*
	 * last_x == 2591 && last_y == 975 is the pre-#388 pipe.
	 * Pointing this enable at live last_y 735 logged
	 * "dagu lsc both banks", gtm=0x1002001, and still left
	 * 8110080 with the second SOF at dbg0=0x2e00a20.
	 * Do not move this branch onto 735. Do not write LSC bank 1 again.
	 */
	if (last_x == 2591 && last_y == 975) {
		static const u32 front_3668[LSC_CFG_N] = {
			0x000000bf, 0x00530053, 0x0c30c014, 0x0c30c014,
			0x00100003, 0x00000000, 0x000c30c0, 0x04000400,
			0x00000040, 0x00000000, 0x00000000,
		};

		for (i = 0; i < LSC_CFG_N; i++)
			writel_relaxed(front_3668[i],
				       vfe->base + CLC_GTM + LSC_AHB + i * 4);
		vfe_480_pack(vfe, 0x3658, (const u32[]){ 0, 0, 0x01002001 }, 3);
	} else {
		for (i = 0; i < LSC_CFG_N; i++)
			writel_relaxed(live_lsc40[i],
				       vfe->base + CLC_GTM + LSC_AHB + i * 4);
		vfe_480_pack(vfe, 0x3658, (const u32[]){ 0, 0, 0 }, 3);
	}
}

/*
 * Live Linearization34 DMI 36 + 16 AHB knees from A-slot preview
 * (dmabuf 212992B off 0x2c8d0, heap type=0x1a n=0x24). #345 wrote
 * MODULE EN=1 and 16 knees from 0x2a64: PIXEL PIPE OVERFLOW line=0,
 * 2a64 readback 0, 2a68 truncated 0x25102e/0x201c. Compact dump is
 * 0x2a60 x6 — 16 FULL knees are not that window. EN=0 is bypass
 * (line=1530). Do not call until CreateCmdList names the AHB dest.
 */
static void __maybe_unused vfe_480_lin(struct vfe_device *vfe)
{
	static const u32 live_dmi[LIN_DMI_N] = {
		0x00000000, 0x00000000, 0x00000000, 0x00000000,
		0x04000000, 0x04000000, 0x04000000, 0x04000000,
		0x040007f7, 0x040007f7, 0x040007f7, 0x040007f7,
		0x04000fee, 0x04000fee, 0x04000fee, 0x04000fee,
		0x040017e5, 0x040017e5, 0x040017e5, 0x040017e5,
		0x04001fdc, 0x04001fdc, 0x04001fdc, 0x04001fdc,
		0x040027d3, 0x040027d3, 0x040027d3, 0x040027d3,
		0x04002fca, 0x04002fca, 0x04002fca, 0x04002fca,
		0x042037c1, 0x0421b7c1, 0x042237c1, 0x0420b7c1,
	};
	static const u32 live_ahb[16] = {
		0x08370040, 0x1825102e, 0x2813201c, 0x3801300a,
		0x083a0043, 0x18281031, 0x2816201f, 0x3804300d,
		0x08380041, 0x1826102f, 0x2814201d, 0x3802300b,
		0x083b0044, 0x18291032, 0x28172020, 0x3805300e,
	};
	unsigned int i, bank;

	for (bank = 1; bank <= 2; bank++) {
		writel_relaxed(bank, vfe->base + CLC_LIN + CLC_DMI_CFG);
		wmb();
		for (i = 0; i < LIN_DMI_N; i++)
			writel_relaxed(live_dmi[i],
				       vfe->base + CLC_LIN + CLC_DMI_LUT);
		wmb();
	}
	writel_relaxed(0, vfe->base + CLC_LIN + CLC_DMI_CFG);
	wmb();
	writel_relaxed(BIT(0), vfe->base + CLC_LIN + CLC_MODULE_CFG);
	/* Heap: MODULE at +0x60, then 16 knees packed at +0x64. */
	for (i = 0; i < 16; i++)
		writel_relaxed(live_ahb[i],
			       vfe->base + CLC_LIN + 0x64 + i * 4);
}

static void vfe_480_pedestal(struct vfe_device *vfe, u32 last_x, u32 last_y)
{
	unsigned int i, bank;

	/* Compact @0x540a30 is 0x2c60 x1. last_x/y are FULL Crop11. */
	(void)last_x;
	(void)last_y;

	for (bank = 1; bank <= 2; bank++) {
		writel_relaxed(bank, vfe->base + CLC_PEDESTAL + CLC_DMI_CFG);
		wmb();
		for (i = 0; i < PEDESTAL_LUT_N; i++)
			writel_relaxed(0, vfe->base + CLC_PEDESTAL + CLC_DMI_LUT);
		wmb();
	}
	/*
	 * Same class as BLS #327 / ABF #337: DMI_CFG leftover eats AHB.
	 * Compact does not pack 0x2c5c or 0x2c68. #332 Crop11 HEIGHT
	 * at 0x2c68 truncated 1529→505. #338 still zeroed those 5
	 * words over HW reset. Do not pack 0x2c5c/0x2c68.
	 */
	writel_relaxed(0, vfe->base + CLC_PEDESTAL + CLC_DMI_CFG);
	wmb();
	/* #353: EN=1 + zero LUT is CST-zero class; MODULE=0 is true bypass. */
	vfe_480_clc_enable(vfe, CLC_PEDESTAL, 0);
}

/*
 * CamX bls12titan480 CreateCmdList DMI 0x2208 four banks then
 * 0x2268 x0x2e from object+0x18. No compact 0x2260 packer. #315
 * wrote sel4 n=0x280 (offset, not count). Identity DMI is
 * subtract-0. PIXEL/LINE at +0x68 bounced 0 (#314 write-only).
 * #326/#327 packed Crop11 keep-all into 0x2268 — same class as
 * ABF #337 0x3270 last=1. CreateCmdList does not pack Crop11.
 * Without live IQ bytes leave 0x2268 at HW reset. Do not zero.
 */
static void vfe_480_bls(struct vfe_device *vfe, u32 last_x, u32 last_y)
{
	static const u32 bls_dmi_n[BLS_DMI_BANKS + 1] = {
		0, BLS_DMI_N1, BLS_DMI_N2, BLS_DMI_N3, BLS_DMI_N4,
	};
	unsigned int i, bank;

	(void)last_x;
	(void)last_y;

	for (bank = 1; bank <= BLS_DMI_BANKS; bank++) {
		writel_relaxed(bank, vfe->base + CLC_PREPROCESS + CLC_DMI_CFG);
		wmb();
		for (i = 0; i < bls_dmi_n[bank]; i++)
			writel_relaxed(0, vfe->base + CLC_PREPROCESS + CLC_DMI_LUT);
		wmb();
	}
	/*
	 * CamX DMI helper returns before packing 0x2268. Close DMI
	 * so MODULE lands on APB. BLS DMI_CFG=0 before AHB. Do not
	 * Crop11 0x2268 / do not zero the 46-word IQ body. #354:
	 * EN=1 + reset 0x2268 is an unknown subtract; MODULE=0 is
	 * true bypass. #352/#353 EN=0 on GTM/Pedestal still DQBUF.
	 */
	writel_relaxed(0, vfe->base + CLC_PREPROCESS + CLC_DMI_CFG);
	wmb();
	vfe_480_clc_enable(vfe, CLC_PREPROCESS, 0);
}

/*
 * CamX BPCPDPC30 FULL @0x5369ac: 0x2e58 x3, 0x2e68 x16, DMI 0x2e08
 * sel1 n=0x90. Compact HWL @0x537048 only writes MODULE_CFG 0x2e60 x1
 * from object+0x20. Empty PDPC11 EN=1 overflowed at line 0 — this is
 * identity DMI (no defects) plus MODULE_CFG BIT(0) so BPC/PDAF stay
 * off. Live CDM packet 2 packs 0x2e58 x3 + 0x2e68 x16 (the 16
 * words #345 put on LIN 0x2a64). Compact is MODULE only.
 * PDPC11 stays EN=0.
 */
static void vfe_480_pdpc30(struct vfe_device *vfe, u32 in_w, u32 in_h)
{
	static const u32 live_2e58[] = {
		0x00000000, 0x00000000, 0x00000000,
	};
	static const u32 live_2e68[] = {
		0x08370040, 0x1825102e, 0x2813201c, 0x3801300a,
		0x083a0043, 0x18281031, 0x2816201f, 0x3804300d,
		0x08380041, 0x1826102f, 0x2814201d, 0x3802300b,
		0x083b0044, 0x18291032, 0x28172020, 0x3805300e,
	};
	/*
	 * #444 Camera ID 1 first-list 0x2e68 n=16 repeating
	 * 0x07bf003f / 0x16bf0f3f. 0x2e58 stays {0,0,0}.
	 * One variable: identity 0x2e68 window. Do not 0x2e58 EN.
	 * Do not {1,1,1}. Do not Dual-IFE. Do not pack chroma 7.
	 * #444 on #462: w2e68=0x7bf003f/0x16bf0f3f en2e58=0x0 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0xc0 as0 Y=0 C=0xff4d3400 bus=0x80000000 camif irq1 0x1 0xc 0x2 0x1. 0x2e68 first-list PDPC is not the identity stall. Keep.
	 */
	static const u32 front_2e68[] = {
		0x07bf003f, 0x16bf0f3f, 0x25bf1e3f, 0x34bf2d3f,
		0x07bf003f, 0x16bf0f3f, 0x25bf1e3f, 0x34bf2d3f,
		0x07bf003f, 0x16bf0f3f, 0x25bf1e3f, 0x34bf2d3f,
		0x07bf003f, 0x16bf0f3f, 0x25bf1e3f, 0x34bf2d3f,
	};
	unsigned int i;

	writel_relaxed(1, vfe->base + CLC_PDPC30 + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < PDPC30_DMI_N; i++)
		writel_relaxed(0, vfe->base + CLC_PDPC30 + CLC_DMI_LUT);
	wmb();
	writel_relaxed(0, vfe->base + CLC_PDPC30 + CLC_DMI_CFG);
	wmb();
	vfe_480_pack(vfe, 0x2e58, live_2e58, ARRAY_SIZE(live_2e58));
	if (in_w == 2592 && in_h == 1952)
		vfe_480_pack(vfe, 0x2e68, front_2e68, ARRAY_SIZE(front_2e68));
	else
		vfe_480_pack(vfe, 0x2e68, live_2e68, ARRAY_SIZE(live_2e68));
}

/*
 * CamX ABF40 PackIQ 12-bit region at object+0x24/+0x28 → 0x3270/0x3274
 * (CreateCmdList FULL 0x3268 x19). Compact @0x5359d8 is 0x3260 x1 only.
 * #337 wrote Crop11 keep-all at 0x3270: readback last=1 (0x10000), a
 * 1-pixel window. Do not pack 0x3270. Leave HW reset like compact.
 * Compact bank2 @0x528688 is 0x3460 x1. FULL @0x5275b8 packs
 * 0x3458 x3 + 0x3468 x46. Live CDM packet 2 has both. #337 Crop11
 * keep-all at 0x3270 is not this 19-word IQ blob.
 */
static void vfe_480_abf_region(struct vfe_device *vfe, u32 last_x, u32 last_y)
{
	static const u32 live_3268[] = {
		0x00008020, 0x01d501a6, 0x000009b6, 0x000008bc,
		0x003c003c, 0x3f591000, 0x02050205, 0x00301408,
		0x00000420, 0x40320007, 0x800c8081, 0x00a00c88,
		0x00030000, 0x00000a10, 0x01410010, 0x01005102,
		0x40020001, 0x007000e1, 0x00700070,
	};

	(void)last_x;
	(void)last_y;
	writel_relaxed(0, vfe->base + CLC_ABF + CLC_DMI_CFG);
	wmb();
	/* #355: live 0x3268 stays; MODULE=0 is true bypass. */
	vfe_480_clc_enable(vfe, CLC_ABF, 0);
	vfe_480_pack(vfe, 0x3268, live_3268, ARRAY_SIZE(live_3268));
}

static void vfe_480_abf_bank2(struct vfe_device *vfe, u32 in_w, u32 in_h)
{
	unsigned int i;

	writel_relaxed(1, vfe->base + CLC_GIC + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < ABF_BANK2_DMI_N1; i++)
		writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_LUT);
	wmb();
	writel_relaxed(3, vfe->base + CLC_GIC + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < ABF_BANK2_DMI_N3; i++)
		writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_LUT);
	wmb();
	writel_relaxed(4, vfe->base + CLC_GIC + CLC_DMI_CFG);
	wmb();
	for (i = 0; i < ABF_BANK2_DMI_N4; i++)
		writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_LUT);
	wmb();
	writel_relaxed(0, vfe->base + CLC_GIC + CLC_DMI_CFG);
	wmb();
	/*
	 * Live CDM packet 2: FULL 0x3458 x3 (MODULE 0xc101 in word 2)
	 * then 0x3468 x46. #357 rear: live 0x3468 stays; 0x3460
	 * MODULE=0 is true bypass. Do not pack {1,1,ABF_BANK2_MODULE}.
	 * #443 Camera ID 1 first-list 0x3458 {0,0,0xc101} then
	 * 0x3468 n=46 starting 0x03000300 (not rear 0x03800380).
	 * One variable: identity GIC AHB pair. Do not retry Crop 640.
	 * Do not Dual-IFE. Do not pack chroma 7. Do not empty DMI EN.
	 * #443 on #461: gic=0xc101 stuck, /tmp/pix.nv12 0 bytes,
	 * viol=0 img=0xc0 as0 Y=0 C=0xff4d3400 bus=0x80000000
	 * camif irq1 0x1 0xc 0x2 0x1. Same stall as #442.
	 * 0x3458 first-list GIC is not the identity stall. Keep.
	 */
	if (in_w == 2592 && in_h == 1952) {
		static const u32 front_3468[] = {
			0x03000300, 0x03000300, 0x00636363, 0x00636363,
			0x00000000, 0x01000100, 0x01000100, 0x00030403,
			0x3c303af0, 0x00282a00, 0x00000329, 0x028f0000,
			0x0a3c05c2, 0x01000100, 0x01000100, 0x00000000,
			0x00000000, 0x00000000, 0x01000100, 0x01000100,
			0x00000000, 0x00000000, 0x01000000, 0x0ccc0200,
			0x00cd00cd, 0x00cd00cd, 0x00000000, 0x00000000,
			0x00000000, 0x00cd00cd, 0x00cd00cd, 0x00000000,
			0x00000000, 0x00000800, 0x00010001, 0x0020c080,
			0x020b007d, 0x017e00ab, 0x00bb015e, 0x20040408,
			0x01000100, 0x01000100, 0x00000000, 0x00000000,
			0x000003c0, 0x0000087f,
		};

		vfe_480_pack(vfe, 0x3458,
			     (const u32[]){ 0, 0, 0x0000c101 }, 3);
		vfe_480_pack(vfe, 0x3468, front_3468, ARRAY_SIZE(front_3468));
		/*
		 * Disabling GIC after this pair logged "gic off" and
		 * still left 8110080, one COMP_DONE, second SOF
		 * dbg0=0x2e00a20. Do not turn front GIC off.
		 *
		 * Writing the zero sels into both 0x3458 banks logged
		 * "dagu abf both banks" and still left 8110080, irq
		 * 0x1 0xc 0x2 0x1, second SOF dbg0=0x2e00a20.
		 * Do not write ABF bank 1 again. Do not leave 0x3458 at 1.
		 *
		 * Front mod_abf40_aec_data (symbol 0x32c) has no
		 * 0x36c AEC entry. The largest blob in that tree is
		 * 96 bytes, so the noise/activity/dark tables are zero.
		 * Do not invent a 65-float curve.
		 */
	} else {
		vfe_480_pack(vfe, 0x3458, (const u32[]){ 0, 0, 0 }, 3);
		{
			static const u32 live_3468[] = {
				0x03800380, 0x03800380, 0x00636363, 0x00636363,
				0x00000000, 0x01000100, 0x01000100, 0x00030403,
				0x3a063808, 0x00633864, 0x0000029a, 0x028f0000,
				0x0a3c05c2, 0x01000100, 0x01000100, 0x00000000,
				0x00000000, 0x00000000, 0x01000100, 0x01000100,
				0x00000000, 0x00000000, 0x01000000, 0x0ccc0200,
				0x004d004d, 0x004d004d, 0x00000000, 0x00000000,
				0x00000000, 0x004d004d, 0x004d004d, 0x00000000,
				0x00000000, 0x00000800, 0x00010001, 0x0020c080,
				0x01a6009b, 0x01d5008c, 0x011d00e6, 0x20040408,
				0x01000100, 0x01000100, 0x00000000, 0x00000000,
				0x000003c0, 0x0000087f,
			};

			vfe_480_pack(vfe, 0x3468, live_3468,
				     ARRAY_SIZE(live_3468));
		}
	}
}

/*
 * Compact CST12 @0x52d178 is 0x4060 x1. FULL @0x52cb7c adds
 * 0x4068 x12 from IQ+0x1c. #344 EN=1 and HW-reset matrix 0
 * zeros RGB (CC-class). Guessed BT.601 was that FULL mix.
 * Live provider object 6f01acfe10 (vtable ELF 0x8bb7d0 =
 * FULL CreateCmdList) type=0xf MODULE=1 + 12 AHB at +0x1c.
 * Live CDM word6/10 is 0x02000000 (512<<16). #364 [9:0]=0x200
 * stuck but Y mean≈0.1 UV=0 — low 10 bits are not origin.
 */
static void vfe_480_cst(struct vfe_device *vfe)
{
	static const u32 live_cst12[] = {
		0x00750259, 0x00000132, 0x00000000, 0x03ff0000,
		0x01fe1eae, 0x00001f54, 0x02000000, 0x03ff0000,
		0x1fad1e55, 0x000001fe, 0x02000000, 0x03ff0000,
	};
	unsigned int i;

	vfe_480_clc_enable(vfe, CLC_CST, 1);
	for (i = 0; i < ARRAY_SIZE(live_cst12); i++)
		writel_relaxed(live_cst12[i],
			       vfe->base + CLC_CST + 0x68 + 4 * i);
}

/*
 * RoundClamp11 PRE + Crop11 sit between CST and MNDS; MID (idx 1)
 * is the Display Full block between Crop and MNDS; POST drains
 * MNDS to DISP WM. EN=0 on POST is a brick wall: viol_id=0 PIXEL
 * PIPE OVERFLOW at chroma last line, 0 NV12. CamX writes MODULE_CFG
 * 0x3c01, PIXEL/LINE keep-all at +0x68/+0x6c, then 6 clamp/round
 * words at +0x70. +0x64 is the same spare hole as Crop.
 */
static void vfe_480_rndclamp(struct vfe_device *vfe, u32 base,
			     u32 last_x, u32 last_y)
{
	u32 pixel = (last_x << 16) | 0;
	u32 line = (last_y << 16) | 0;
	u32 i;

	vfe_480_clc_enable(vfe, base, RNDCLAMP_MODULE_CFG);
	writel_relaxed(0, vfe->base + base + CROP_SPARE);
	writel_relaxed(pixel, vfe->base + base + CROP_PIXEL);
	writel_relaxed(line, vfe->base + base + CROP_LINE);
	for (i = 0; i < 3; i++) {
		writel_relaxed((0x3ff << 16) | 0,
			       vfe->base + base + RNDCLAMP_CH0 + i * 8);
		writel_relaxed(0, vfe->base + base + RNDCLAMP_CH0 + 4 + i * 8);
	}
}

/*
 * Keep the FD branch off. #625 flight recorder: with the FD MNDS and
 * FD clamp enabled and WM8/9 off, two top-debug modules (0xa0 nibbles
 * 2 and 4) never went idle after the front EOF (0x55515155 through
 * the 23 ms blank, Android 0x55555555). At the next SOF they held
 * valid data with ready low, sixteen modules behind them backed up,
 * and CAMIF stopped at dbg1 0x10218000: one frame, no error IRQ.
 * MODULE_CFG=0 on the FD MNDS or on the FD clamp alone gave 90
 * frames, dbg1 0x82d68008, blank state all 5 like Android.
 */
static void vfe_480_fd_off(struct vfe_device *vfe)
{
	writel_relaxed(0, vfe->base + CLC_CROP + CLC_MODULE_CFG);
	writel_relaxed(0, vfe->base + CLC_CROP_C + CLC_MODULE_CFG);
	writel_relaxed(0, vfe->base + CLC_RNDCLAMP_MID_Y + CLC_MODULE_CFG);
	writel_relaxed(0, vfe->base + CLC_RNDCLAMP_MID_C + CLC_MODULE_CFG);
}

static void vfe_480_mnds(struct vfe_device *vfe, u32 base,
			 u32 in_w, u32 in_h, u32 out_w, u32 out_h)
{
	u32 phase_h, phase_v, interp = 0, cfg;

	if (!in_w || !in_h || !out_w || !out_h)
		return;

	phase_h = (u32)div_u64((u64)in_w << MNDS_PHASE_Q, out_w);
	phase_v = (u32)div_u64((u64)in_h << MNDS_PHASE_Q, out_h);

	/*
	 * CamX mndsConfig*.interpReso: more taps when downscale > 2 / 4.
	 * MODULE_CFG bit0 EN, bits 8-9 interp. Display chroma is
	 * 4080×765→1920×540 so H >2× → interp=1 (0x101).
	 */
	if (phase_h > (2u << MNDS_PHASE_Q) || phase_v > (2u << MNDS_PHASE_Q))
		interp = 1;
	if (phase_h > (4u << MNDS_PHASE_Q) || phase_v > (4u << MNDS_PHASE_Q))
		interp = 2;
	/*
	 * CamX Display CreateCmdList ORs MODULE_CFG with 0x3 (EN + bit1)
	 * and inserts interpReso into phase[29:28]. Stripe last is
	 * OUT-1; 0/0 is an empty window and keeps viol_id 19.
	 */
	cfg = BIT(0) | BIT(1) | (interp << 8);

	vfe_480_clc_enable(vfe, base, cfg);
	writel_relaxed(((out_w - 1) << 16) | (in_w - 1),
		       vfe->base + base + MNDS_H_SIZE);
	writel_relaxed(phase_h | (interp << 28),
		       vfe->base + base + MNDS_H_PHASE);
	writel_relaxed((out_w - 1) << 16,
		       vfe->base + base + MNDS_H_STRIPE);
	writel_relaxed(0, vfe->base + base + MNDS_H_PAD);
	writel_relaxed(((out_h - 1) << 16) | (in_h - 1),
		       vfe->base + base + MNDS_V_SIZE);
	writel_relaxed(phase_v | (interp << 28),
		       vfe->base + base + MNDS_V_PHASE);
	writel_relaxed((out_h - 1) << 16,
		       vfe->base + base + MNDS_V_STRIPE);
	writel_relaxed(0, vfe->base + base + MNDS_V_PAD);
}

/*
 * Live IFE CDM Display Full scaler + TAP. MODULE/H_SIZE are not
 * Linux keep-all 2ppc. TAP 0x5408×2 is AHB 0x307/0x9016c7d
 * (DumpRegConfig lumaConfig/filter), not Crop11 and not DMI LUT.
 * #350 dropped RoundClamp overlay: PIXEL PIPE OVERFLOW, 0-byte
 * NV12, as0=0 as3 latched. Live 0x68 is not Linux keep-all, but
 * it is what lets DQBUF complete (#349). Restore it. Skip
 * 0x5608/0x5e08 MODULE — those EN DS4/DS16 without WM6/7.
 *
 * Rear 4080×3060 last 0xfef0bf3 is s5kjn1 pixel-domain 4079×3059.
 * Front imx596 last 0xa1f079f is Camera ID 1 heap 2591×1951
 * (2026-09-17). Do not copy 0xfef0bf3 onto 2592×1952. Display
 * Full stripe on that heap is 1919×1079, not 1440×1080.
 */
static void vfe_480_live_display_cdm(struct vfe_device *vfe,
				     u32 in_w, u32 in_h, u32 out_w, u32 out_h)
{
	u32 dest_w = out_w;
	u32 dest_h = out_h;
	static const u32 rear_mnds_y[] = {
		0x00000001, 0x00000600, 0x0fef0bf3, 0xc043dbcf,
		0x00000000, 0xc043e7db, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 rear_mnds_c[] = {
		0x00000001, 0x00000600, 0x0fef0bf3, 0xc087b79e,
		0x00000000, 0xc087cfb6, 0x00000000, 0x00000000,
		0x00000000,
	};
	/*
	 * Camera ID 1 live 2026-09-17 23:16, Device 1, provider 14720:
	 * CamX Display full path is 2304×1296, Applied [0,7,2592,1458],
	 * MNDS output 2314×1314. IPE then zooms [192,108,1920,1080]
	 * on that 2304 buffer. 1MB CDM is still the 640 list
	 * (0x0a1f079f / 0xc081999a). Heap MODULE=1 last 0x0a1f05bf =
	 * 2592×1472 with Q21 0xc023d82c = 2592/2314 (not the invented
	 * 2592/1920 Q21, not dest last 1920×1080). MODULE 0x101 last
	 * 0x077f0437 is the IPE 1920 object; #378–#380 programmed it
	 * onto IFE MNDS_C and stayed viol 19. 640 CDM packs Crop as
	 * MODULE=1 + scale phase @0x4460/0x4660 and MNDS as same last
	 * + Y unity / C 0xc0400000 @0x4c60/0x4e60. #381 uses that
	 * packing on the live 0x0a1f05bf blobs. #382 MID/POST 0x50f/0x8ff
	 * on 2304 WM wrote the first non-zero front NV12 (Y 91–147,
	 * UV 125–140, 2048 bytes short of 1 frame) then viol_id=0 at
	 * CAMIF last line. #383 Crop dest last 0x08ff050f / 0x047f0287
	 * stuck, still 4476928 bytes, but viol_id=14 and clcstat
	 * crop=1 — dest last on Crop is falsified. #384 WM/V4L2
	 * 2320×1320 pad (16-aligned around CamX MNDS 2314×1314)
	 * stuck on #398 when RC stayed 2304: IMAGE_CFG 0x5280910,
	 * img=0x30, as0=0, 0-byte. #386 RC+WM both 2320 on #400:
	 * mid_y=0x527/0x90f, wm4=0x5280910, img=0x0, as0 consumed,
	 * 4591616 (need 4593600, UV short 1984), Y 87–101 UV~128.
	 * Still viol_id=0 line=976. #384 2320 WM falsified only
	 * when RC stayed 2304 (img=0x30). Do not dest last on
	 * MNDS_C (viol 19). Do not copy 0xfef0bf3.
	 */
	/*
	 * Identity last 0x0a1f079f / 640 0xc081999a / 0xc1033334
	 * stay as unused arrays for persist. Display Full heap
	 * Crop 9-word is front_crop_*_disp (executed).
	 * 0x00000001, 0x00000600, 0x0a1f079f, 0xc081999a
	 * 0x00000001, 0x00000600, 0x0a1f079f, 0xc1033334
	 * H_PAD 0xc0822222 / 0xc1044444
	 */
	/*
	 * MNDS MODULE stays 1. Display Full last 0x0a1f05bf executed
	 * via front_mnds_*_disp. Identity last 0x0a1f079f + unity
	 * stays in front_mnds_y/c (not packed on Display Full dest).
	 * Dest last 0x077f0437 identity (#380) and 2× (#378) both stuck viol 19
	 * with 1920 dest on 640 2×. Do not invent 2592/1920 Q21. Do
	 * not copy 0xfef0bf3. Do not stuff unpacked last into MNDS
	 * V_STRIPE.
	 * #415 CLC chroma 2ppc 2× @0x4e60: hph=0xc0400000 still
	 * 0-byte img=0 bus=0. Keep that pack on MNDS_C. Crop was the gap vs
	 * live 1MB CDM, not MNDS_C H_PHASE. Do not H_SIZE dest.
	 * Do not H_PHASE 0xc047b058. Do not H_STRIPE dest. Do not
	 * Dual-IFE COMP_CFG.
	 * Crop identity unity is not the identity stall.
	 */
	static const u32 front_mnds_y[] = {
		0x00000001, 0x00000600, 0x0a1f079f, 0xc0200000,
		0x00000000, 0xc0200000, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 front_mnds_c[] = {
		0x00000001, 0x00000600, 0x0a1f079f, 0xc0400000,
		0x00000000, 0xc0400000, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 front_mnds_y_disp[] = {
		0x00000001, 0x00000600, 0x0a1f05bf, 0xc0200000,
		0x00000000, 0xc0200000, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 front_mnds_c_disp[] = {
		0x00000001, 0x00000600, 0x0a1f05bf, 0xc0400000,
		0x00000000, 0xc0400000, 0x00000000, 0x00000000,
		0x00000000,
	};
	static const u32 live_tap_ds4[] = { 0x00000307, 0x09016c7d };
	static const u32 live_tap_ds4c[] = { 0x00b404eb, 0x00020781 };
	static const u32 live_tap_ds16[] = { 0x00000f07, 0x09016c7d };
	static const u32 live_tap_ds16c[] = { 0x0000010d, 0x000001df };
	const u32 *mnds_y, *mnds_c;

	if (in_w == 4080 && in_h == 3060) {
		mnds_y = rear_mnds_y;
		mnds_c = rear_mnds_c;
	} else if (in_w == 2592 && in_h == 1952) {
		mnds_y = front_mnds_y_disp;
		mnds_c = front_mnds_c_disp;
		(void)front_mnds_y;
		(void)front_mnds_c;
	} else {
		return;
	}

	vfe_480_pack(vfe, CLC_MNDS_Y + CLC_MODULE_CFG, mnds_y, 9);
	vfe_480_pack(vfe, CLC_MNDS_C + CLC_MODULE_CFG, mnds_c, 9);
	/*
	 * #403 front MNDS_C V_SIZE 0x0293016f after 640 pack
	 * zeros vsz. vfe_480_mnds already wrote
	 * ((660-1)<<16)|((736/2)-1) then pack stomped it. Same
	 * 2ppc chroma in as pipe_h/2, same 660 out as WM5/RC
	 * last 0x293. #418 vsz=0x293016f still 4591616 — not
	 * the chroma gap. Keep. #404 V_STRIPE 0x02930000 =
	 * (660-1)<<16 stuck on #419 vst=0x2930000 still 4591616
	 * UV 659.145 — not the chroma gap. Keep.
	 * #405 V_PHASE (368<<21)/660 = 0x0011d7a9: pack zeros
	 * vph the same way. Same 2ppc in/out as V_SIZE.
	 * #420 vph=0x1117a9 (HW drops phase[15:14]) still
	 * 4591616 UV 659.145 — not the chroma gap. Keep.
	 * #406 H_STRIPE (2320-1)<<16 = 0x090f0000 after pack
	 * zeros hst. Same OUT-1 as vfe_480_mnds.
	 * #421 hst=0x90f0000 still 4591616 UV 659.145 — not
	 * the chroma gap. Keep.
	 * #407 H_SIZE 0x090f0a1f on #422: hsz=0x90f0a1f
	 * stuck, /tmp/pix.nv12 0 bytes, viol=0x13 (19)
	 * MNDS_C, as0 Y consumed C=0, dbg=0x269/0x226,
	 * bus=0x0. Display Full dest in H_SIZE with 640
	 * chroma phase 0xc0400000 is dest last class
	 * (#380 viol 19). CamX Display Full H_SIZE dest
	 * pairs with phase 0xc023d82c (2592/2314), not
	 * 640 2×. Reverted. Pack H_SIZE stays 0x0a1f05bf.
	 * Do not retry H_SIZE as the chroma gap.
	 * #408 H_PHASE 0xc047b058 on #424: hph=0xc047b058
	 * stuck, /tmp/pix.nv12 0 bytes, img=0x20, as0 Y
	 * consumed C=0, bus=0x80000000, viol=0, dbg=0x269/0x206.
	 * Display Full chroma Q21 2592/1157 without matching
	 * dest (H_SIZE still pack 0x0a1f05bf, H_PAD still
	 * 640 2× 0xc0400000) stalls WM5. #407 was dest
	 * without this phase (viol 19). Reverted. Pack
	 * H_PHASE stays 0xc0400000.
	 * Do not retry H_PHASE 0xc047b058 as the chroma gap.
	 * #409 IMAGE_CFG_1 on Camera ID 1 live (53dcc70, no flash):
	 * CAF cam_vfe_bus_ver3_update_wm WM:5 h_init 0x0 every
	 * frame. Linux already writel IMAGE_CFG_1=0. Not the
	 * chroma gap. Do not write non-zero IMAGE_CFG_1.
	 * Live IMAGE_CFG_0 is 0x3D00A20 (2592×976) with WM4
	 * 0x7A00A20 (2592×1952), COMP_GRP_1 status_0=0x80,
	 * WM6/7 EN. That size is IFE identity, not Display
	 * Full 2320. Do not WM-only 2592 (same class as #398
	 * WM vs RC). Do not empty-enable WM6/7. Do not Dual-IFE
	 * COMP_CFG. Do not dest last.
	 * #410 V_PAD 0x0011d7a9 on #426: vpd=0x0 stuck (HW
	 * bounced), still 4591616 UV 659.145. CLC_MNDS_C + MNDS_V_PAD
	 * is not the H_PAD=H_PHASE slot. Reverted.
	 * Do not retry V_PAD as the chroma gap.
	 * #411 H_PAD 0xc047b212 on #427: hpd=0xc047b212 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 C=0
	 * bus=0x0 dbg=0x269/0x2c6. Camera ID 1 Crop C pad on
	 * 640 MNDS_C H_PHASE 0xc0400000 stalls WM write.
	 * Reverted. Pack H_PAD stays 0xc0400000.
	 * Do not retry H_PAD as the chroma gap.
	 * Do not retry front packer 3. Do not retry height 659.
	 * Do not retry FRAME_INCR 1984. Do not retry WM5 2304.
	 * Do not retry V_STRIPE as the chroma gap.
	 * Do not retry V_PHASE as the chroma gap.
	 * Do not retry H_STRIPE as the chroma gap.
	 * #412 identity: WM+RC+MNDS+CSID 2592×1952 together.
	 * Pack 640 leftover dest/phase was the chroma gap.
	 * Y H_SIZE dest=src 0x0a1f0a1f with unity H_PHASE
	 * 0xc0200000 (not #407 dest 0x090f0a1f on 640 2×).
	 * #412 on #429: hsz=0xa1f0a1f stuck, /tmp/pix.nv12 0
	 * bytes, viol=0 img=0x10 as0=0 bus=0x80000000
	 * wm4=0x7a00a20 wm5=0x3d00a20 vcrop=0x79f0000.
	 * Dest/src in H_SIZE overwrites pack last 0x0a1f079f
	 * — same class as #407. Reverted. Pack last stays
	 * 0x0a1f079f. Do not retry H_SIZE dest=src as the chroma gap.
	 * Keep V_SIZE dest 1952 src 2ppc 976.
	 * Display Full MNDS_C 0x0293016f / 0x02930000 /
	 * 0x0011d7a9 / 0x090f0000 stays in comments only.
	 * Do not Dual-IFE COMP_CFG. Do not WM-only 2592.
	 * Do not writel CLC_MNDS_C + MNDS_H_STRIPE dest.
	 * #413 on #430: pack last hsz=0xa1f079f stuck, hst=0 both Y/C,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0=0 bus=0x0.
	 * #414 stripe last OUT-1 0x0a1f0000 after pack zeros
	 * hst. Not dest/src H_SIZE. Not #406 2320 0x090f0000.
	 * #414 on #431: hst=0xa1f0000 stuck, /tmp/pix.nv12 0
	 * bytes, viol=0 img=0x10 as0=0 bus=0x80000000. Same
	 * BUS IRQ class as #412 H_SIZE dest. Reverted. Pack
	 * H_STRIPE stays 0. Do not retry H_STRIPE dest as the chroma gap.
	 * #415 on #432: MNDS_C pack 0xc0400000 stuck, hph=0xc0400000 stuck
	 * hsz=0xa1f079f, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0=0
	 * bus=0x0. Same quiet class as #413. 2× chroma phase is not
	 * the identity stall. Keep the 0x4e60 pack.
	 * Do not retry MNDS_C 2× as the chroma gap.
	 * #416 Crop Y/C 9-word from live 1MB CDM 0x4460/0x4660.
	 * Not MNDS 0x4c60 0xc081999a. Not WM-only. Not Dual-IFE.
	 * #417 Camera ID 1 live 2026-09-18 15:24 in-process dmabuf
	 * (provider 10529, last 0x0a1f079f): Crop 9-word is that
	 * same 640 phase. MID 0x4868 n=2 { 0x000001df, 0x0000027f }
	 * (480×640) / 0x4a68 { 0x000000ef, 0x0000013f } (240×320).
	 * POST 0x5068 stays 0x79f/0xa1f identity. #416 left MID
	 * at identity 2592 against Crop dest 640 — quiet 0-byte.
	 * One variable: live MID dest. Do not WM 640. Do not
	 * Dual-IFE COMP_CFG. Do not H_SIZE dest.
	 * #417 on #434: mid_y=0xe01/0x1df/0x27f mid_c=0xef/0x13f
	 * stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0=0
	 * bus=0x0, camif irq1 0x1 0xc 0x2 0x1. Same quiet class
	 * as #416. Crop dest 640 vs POST/WM 2592 still stalls.
	 * Do not retry MID 480×640 as the identity stall.
	 */
	if (in_w == 2592 && in_h == 1952) {
		/*
		 * #506: MNDS is an MN Down Scaler. Display Full Y
		 * was dest 1320 / src 736 (0x052702df) — V upscale.
		 * CamX Display Full is CSID last 0x05bf → 1472 pixel
		 * lines → 1314, pad 1320. 2ppc pipe_h=736 is the
		 * CAMIF beat count, not the scaler source. First
		 * 8110080 then CAMIF second SOF without epoch is
		 * the upscale leftover. One contract: Y V src=1472
		 * dest=1320. #506 left C at 368→660. #507 pairs
		 * C V src to 736 (1472/2). Do not ALIGN_UP.
		 * Do not retry 736→1320.
		 * Identity 0x079f03cf / 0x03cf01e7 stays in comments.
		 */
		writel_relaxed(0x0527079f,
			       vfe->base + CLC_MNDS_Y + MNDS_V_SIZE);
		writel_relaxed(0x05270000,
			       vfe->base + CLC_MNDS_Y + MNDS_V_STRIPE);
		/*
		 * Phase follows the same src/dest as V_SIZE
		 * (1472<<21)/1320. #467 on #492: vph=0x1117a9 stuck
		 * (0x0011d7a9 = 736/1320) still 4591616 — not the
		 * chroma gap. Do not retry MNDS Y V_PHASE as the chroma gap.
		 * #506 replaces it for V downscale.
		 */
		writel_relaxed(0x002f523a,
			       vfe->base + CLC_MNDS_Y + MNDS_V_PHASE);
		/*
		 * #507: pair C V with Y pixel 1472. #403 KEEP
		 * 0x0293016f (660/368) was not the chroma gap
		 * (vsz=0x293016f still 4591616). After #506 Y
		 * src=1472, C still 368→660 is half of the old
		 * 2ppc 736, not half of 1472. Dest stays 660.
		 * Phase (736<<21)/660. STREAMON #507: vsz=0x29302df
		 * stuck, still 1×8110080, camif irq1 0x1 0xc 0x2 0x1.
		 * Not the second-frame cut. Keep the 736→660 chroma
		 * contract. Do not retry 368→660. Do not retry C V
		 * src as the second-frame cut.
		 */
		writel_relaxed(0x029303cf,
			       vfe->base + CLC_MNDS_C + MNDS_V_SIZE);
		writel_relaxed(0x02930000,
			       vfe->base + CLC_MNDS_C + MNDS_V_STRIPE);
		writel_relaxed(0x002f523a,
			       vfe->base + CLC_MNDS_C + MNDS_V_PHASE);
		/*
		 * #465 MNDS Y H_PHASE 0xc023d82c on #489:
		 * hph=0xc023d82c stuck, /tmp/pix.nv12 0 bytes,
		 * img=0x10 as0 Y=0 bus=0x80000000 viol=0.
		 * Display Full Q21 on MNDS Y without H_SIZE dest
		 * is the same class as #408. Reverted. Pack
		 * H_PHASE stays 0xc0200000.
		 * Do not retry MNDS Y H_PHASE 0xc023d82c as the chroma gap.
		 * Do not H_SIZE dest. Do not Dual-IFE COMP_CFG.
		 * #466 MNDS Y H_STRIPE (2320-1)<<16 = 0x090f0000
		 * after pack zeros hst. Same OUT-1 as vfe_480_mnds
		 * and #406 MNDS_C (KEEP, still 4591616). Not
		 * #414 identity dest 0x0a1f0000. Not H_PHASE.
		 * One variable: Display Full Y stripe dest.
		 * #466 on #491: hst=0x90f0000 stuck, still 4591616
		 * UV 659.145 last_partial=336. Not the chroma gap.
		 * Keep. Do not retry MNDS Y H_STRIPE as the chroma gap.
		 */
		writel_relaxed(0x090f0000,
			       vfe->base + CLC_MNDS_Y + MNDS_H_STRIPE);
		/*
		 * #468 Crop Y V_PHASE 0xc023d909: heap Display Full
		 * 9-word word5 (H_PAD slot). Pack leaves CROP_V_PHASE
		 * (word7 / +0x7c) at 0. Same Q21 family as Crop
		 * H_PHASE 0xc023d82c already live in LINE. Not
		 * PIXEL dest last (#383). Not MNDS H_PHASE (#465).
		 * Not Crop C 0xc047b212 (#411). One variable: Y
		 * vertical phase in the V_PHASE register.
		 * #468 on #493: crop_yvph=0x231909 stuck (HW drops
		 * phase[15:14]), still 4591616 UV 659.145
		 * last_partial=336. Not the chroma gap. Keep.
		 * Do not retry Crop Y V_PHASE as the chroma gap.
		 */
		/*
		 * #469 Crop Y V_STRIPE 0x02df0000: vfe_480_crop
		 * last_y<<16 (pipe_h-1 = 735) before pack zeros
		 * word8 / +0x80. Not PIXEL dest last (#383). Not
		 * Crop Y V_PHASE (#468 KEEP). Not Crop C
		 * 0xc047b212. One variable: Y vertical stripe.
		 * #469 on #494: vst=0x2df0000 stuck, still 4591616
		 * UV 659.145 last_partial=336. Not the chroma gap.
		 * Keep. Do not retry Crop Y V_STRIPE as the chroma gap.
		 */
		/*
		 * #470 Crop C V_STRIPE 0x016f0000: chroma analog of
		 * #469 KEEP (pipe_h/2-1 = 367)<<16. Pack zeros
		 * CLC_CROP_C +0x80. Not PIXEL dest last (#383).
		 * Not Crop C 0xc047b212 (#411). Not Crop Y
		 * V_STRIPE (#469 KEEP). One variable: C vertical
		 * stripe.
		 * #470 on #495: crop_c_vst=0x16f0000 stuck, still
		 * 4591616 UV 659.145 last_partial=336. Not the
		 * chroma gap. Keep.
		 * Do not retry Crop C V_STRIPE as the chroma gap.
		 */
		/*
		 * #471 Crop C V_PHASE 0xc047b212: heap Display Full
		 * chroma 9-word word5 (H_PAD slot) into CROP_V_PHASE
		 * (+0x7c). Analog of #468 Crop Y KEEP. Not MNDS
		 * H_PAD (#411 0-byte). Not PIXEL dest last. Not
		 * Crop C V_STRIPE (#470 KEEP). One variable: C
		 * vertical phase in the V_PHASE register.
		 * #471 on #496: crop_cvph=0x473212 stuck (HW drops
		 * phase[15:14]), still 4591616 UV 659.145
		 * last_partial=336. Not the chroma gap. Keep.
		 * Do not retry Crop C V_PHASE as the chroma gap.
		 */
		/*
		 * #472 Crop C V_SIZE 0x016f0000: chroma analog of
		 * vfe_480_crop line (pipe_h/2-1)<<16 before pack
		 * zeros word6 / +0x78. Same numeric as #470 KEEP
		 * V_STRIPE, different register. Not PIXEL dest
		 * last (#383). Not Crop C V_PHASE (#471 KEEP).
		 * Not Crop C V_STRIPE (#470 KEEP). Not MNDS
		 * H_PAD (#411). One variable: C vertical size
		 * in the V_SIZE register.
		 * #472 on #497: crop_cvsz=0x16f0000 stuck, still
		 * 4591616 UV 659.145 last_partial=336. Not the
		 * chroma gap. Keep.
		 * Do not retry Crop C V_SIZE as the chroma gap.
		 */
		/*
		 * #473 Crop Y V_SIZE 0x02df0000: analog of
		 * vfe_480_crop line (pipe_h-1)<<16 before pack
		 * zeros word6 / +0x78. Same numeric as #469 KEEP
		 * V_STRIPE, different register. Not PIXEL dest
		 * last (#383). Not Crop C V_SIZE (#472 KEEP).
		 * Not Crop Y V_STRIPE (#469 KEEP). One variable:
		 * Y vertical size in the V_SIZE register.
		 * #473 on #498: crop_yvsz=0x2df0000 stuck, still
		 * 4591616 UV 659.145 last_partial=336. Not the
		 * chroma gap. Keep.
		 * Do not retry Crop Y V_SIZE as the chroma gap.
		 */
		/*
		 * #474 Crop C H_STRIPE 0x090f0000: Display Full
		 * dest (2320-1)<<16 after pack zeros word4 / +0x70.
		 * Same OUT-1 as #466 MNDS Y KEEP. Not identity
		 * dest 0x0a1f0000 (#414 0-byte). Not MNDS_C
		 * H_STRIPE dest (comments only). Not PIXEL dest
		 * last. Not Crop C V_SIZE (#472 KEEP). One
		 * variable: C horizontal stripe dest in H_STRIPE.
		 * #474 on #499: crop_chst=0x90f0000 stuck, still
		 * 4591616 UV 659.145 last_partial=336. Not the
		 * chroma gap. Keep.
		 * Do not retry Crop C H_STRIPE as the chroma gap.
		 */
	}

	/*
	 * CamX RoundClamp11 0x68 is unpacked last_y, last_x (front
	 * 1MB CDM 0x4868=0x1df/0x27f = 480×640 dest). Not Linux
	 * keep-all (last<<16)|0 (#350 overflow). Rear 0x4868 is
	 * 14-bit 0x3c01a3. Camera ID 1 live Display Full is
	 * 2304×1296, MNDS 2314×1314. #382 MID 0x50f/0x8ff on 2304
	 * WM wrote 1 truncated NV12. #384 WM 2320 with 2304 dest:
	 * img=0x30 as0=0. #386 RC+WM 2320 on #400: 4591616 short
	 * 1984, img=0x0, still line=976. Keep MID/POST/OUT
	 * 2320×1320 (0x00000527, 0x0000090f, chroma 0x00000293, 0x00000487).
	 * PRE is CSID 2ppc last 735 0x000002df, 0x00000a1f (#388 Display Full).
	 * #412 identity PRE 0x3cf/0xa1f (976 2ppc), MID/POST/OUT
	 * 0x79f/0xa1f, chroma 0x3cf/0x50f. Do not dest last on
	 * Crop. Do not copy 0xfef0bf3. Do not invent Q21.
	 */
	if (in_w == 2592 && in_h == 1952) {
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP, RNDCLAMP_MODULE_CFG);
		vfe_480_pack(vfe, CLC_RNDCLAMP + 0x68,
			     (const u32[]){ 0x000003cf, 0x00000a1f }, 2);
	}
	/*
	 * Live CDM chroma round is odd (0x17 / 7): keep 10-bit for
	 * UBWC. Linear packer 3 takes LSB[7:0] of 10-bit 512 → UV≈0
	 * (#362 green). Y uses even (0x16 / 6) and 8-bit is correct.
	 * #363: even round on C so 512→128 like Y.
	 */

	if (in_w == 2592 && in_h == 1952) {
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_POST_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_Y + 0x68,
			     (const u32[]){ 0x00000527, 0x0000090f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_Y + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_POST_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_C + 0x68,
			     (const u32[]){ 0x00000293, 0x00000487 }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_C + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		/*
		 * Identity dest 0x0000079f, 0x00000a1f / chroma
		 * 0x000003cf, 0x0000050f and PRE 0x000003cf, 0x00000a1f
		 * stay in comments. Display Full RC+WM 2320 together.
		 * Do not retry OUT 488×648 as the identity stall.
		 */
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_OUT_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x68,
			     (const u32[]){ 0x00000527, 0x0000090f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_OUT_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x68,
			     (const u32[]){ 0x00000293, 0x00000487 }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
	} else {
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_POST_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_Y + 0x68,
			     (const u32[]){ 0x00b404eb, 0x00020781 }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_Y + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_POST_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_C + 0x68,
			     (const u32[]){ 0x005a0275, 0x000103c0 }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_POST_C + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);

		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_OUT_Y, 0x0e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x68,
			     (const u32[]){ 0x0000010d, 0x000001df }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
		vfe_480_clc_enable(vfe, CLC_RNDCLAMP_OUT_C, 0x3e01);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x68,
			     (const u32[]){ 0x00000086, 0x000000ef }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 },
			     6);
	}

	if (in_w != 2592 || in_h != 1952)
		vfe_480_pack(vfe, CLC_DS411_Y_CROP, live_tap_ds4,
			     ARRAY_SIZE(live_tap_ds4));
	/*
	 * #421 Camera ID 1 live 0x5504 n=2 { 0x0000079f, 0x00000a1f }
	 * (identity). Linux packed rear 0x00b404eb/0x00020781 onto
	 * 2592×1952. Y 0x5408 already matches live 0x00000307 /
	 * 0x09016c7d. Do not copy 0x5d04 0x1e7/0x287 (OUT 488×648).
	 * Do not empty DS411. Do not WM 640. Do not Dual-IFE.
	 * #421 on #439: /tmp/pix.nv12 0 bytes, viol=0 img=0x0
	 * as0=0 bus=0x0, crop still 0xc1033334. 0x5504 first-list
	 * is not the identity stall. Keep.
	 * #422 Crop unity on #440 still 0-byte. Next first-list
	 * packet after 0x5504 is 0x5704 n=2 { 0x000003cf, 0x00000a1f }
	 * (976×2592, same 2ppc PRE chroma). 0x5608 n=1 0x307 is
	 * DS4 MODULE EN — that hung CAMNOC without WM6/7. One
	 * variable: 0x5704 crop window only. Do not 0x5608. Do
	 * not 0x5e08. Do not empty WM6/7. Do not copy 0x5d04.
	 * #423 on #441: ds4c=0x3cf/0xa1f en5608=0x0 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0=0 bus=0x0
	 * camif irq1 0x1 0xc 0x2 0x1. 0x5704 first-list is not
	 * the identity stall. Keep. Do not 0x5608.
	 * #424 first-list 0x5f04 n=2 { 0x000000f3, 0x00000287 }
	 * after DS16 TAP 0x5c08. 0x5e08 n=1 0xf07 is DS16 MODULE
	 * EN — same CAMNOC hang class as 0x5608 without WM6/7.
	 * One variable: 0x5f04 crop window only. Do not 0x5e08.
	 * Do not empty WM6/7. Do not copy 0x5d04 0x1e7/0x287.
	 * #424 on #442: ds16c=0xf3/0x287 en5e08=0x0 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0=0 bus=0x0
	 * camif irq1 0x1 0xc 0x2 0x1. 0x5f04 first-list is not
	 * the identity stall. Keep. Do not 0x5e08.
	 * #425–#427 WM6/7 dummy + 0x5608/0x5e08: img=0xc0 still
	 * 0-byte. live-cdm-1mb.bin has no DSX10 DMI (0x5c08 is
	 * n=2 AHB TAP). Next first-list packet after 0x5f04 is
	 * 0x6068 n=2 { 0x00000079, 0x000000a1 } (122×162, DS4/2).
	 * 0x6060 n=1 0xe01 is MODULE EN — no DS64 WM. One
	 * variable: 0x6068 crop window only. Do not 0x6060.
	 * #428 on #446: ds64c=0x79/0xa1 en6060=0 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0xc0 as0 Y=0
	 * C=0xffcd3400 bus=0x80000000 camif irq1 0x1 0xc 0x2 0x1.
	 * 0x6068 first-list is not the identity stall. Keep.
	 * #429 Camera ID 1 first-list 0x6268 n=2
	 * { 0x0000003c, 0x00000050 } (61×81, live WM7).
	 * 0x6260 n=1 0x3e01 is MODULE EN. One variable:
	 * 0x6268 crop window only. Do not 0x6060. Do not
	 * 0x6260. Do not empty DSX10 LUT. Do not (i<<8)|i.
	 * #429 on #447: ds64cc=0x3c/0x50 en6260=0 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0xc0 as0 Y=0
	 * C=0xffcd3400 bus=0x80000000 camif irq1 0x1 0xc 0x2 0x1.
	 * 0x6268 first-list is not the identity stall. Keep.
	 * #430 Camera ID 1 first-list 0x6060 n=1 0xe01
	 * (DS64 Y MODULE). Android has no DS64 WM.
	 * One variable: 0x6060 EN. Do not 0x6260. Do not
	 * 0x6070. Do not empty DSX10 LUT. Do not (i<<8)|i.
	 * #430 on #448: en6060=0xe01 stuck, /tmp/pix.nv12
	 * 0 bytes, viol=0 img=0xc0 as0 Y=0 C=0xffcd3400
	 * bus=0x80000000 camif irq1 0x1 0xc 0x2 0x1.
	 * 0x6060 first-list is not the identity stall. Keep.
	 * #431 Camera ID 1 first-list 0x6070 n=6
	 * { 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 } (DS64 Y
	 * clamp, same as POST +0x70). One variable: 0x6070.
	 * Do not 0x6260. Do not 0x6270. Do not empty LUT.
	 * #431 on #449: c6070=0x3ff0000 en6260=0 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0xc0 as0 Y=0
	 * C=0xffcd3400 bus=0x80000000 camif irq1 0x1 0xc 0x2 0x1.
	 * 0x6070 first-list is not the identity stall. Keep.
	 * #432 Camera ID 1 first-list 0x6260 n=1 0x3e01
	 * (DS64 C MODULE). One variable: 0x6260 EN.
	 * Do not 0x6270. Do not empty LUT. Do not Dual-IFE.
	 * #432 on #450: en6260=0x3e01 stuck, /tmp/pix.nv12
	 * 0 bytes, viol=0 img=0xc0 as0 Y=0 C=0xffcd3400
	 * bus=0x80000000 camif irq1 0x1 0xc 0x2 0x1.
	 * 0x6260 first-list is not the identity stall. Keep.
	 * #433 Camera ID 1 first-list 0x6270 n=6
	 * Android { 0x03ff0000, 7, ... } is UBWC 10-bit
	 * chroma. Linux linear packer 3 keeps word 6
	 * (#362 green). One variable: 0x6270. Do not
	 * retry 0x4460 Crop 640. Do not empty LUT.
	 * Do not Dual-IFE. Do not pack chroma 7.
	 * #433 on #451: c6270=0x3ff0000 stuck, /tmp/pix.nv12
	 * 0 bytes, viol=0 img=0xc0 as0 Y=0 C=0xffcd3400
	 * bus=0x80000000 camif irq1 0x1 0xc 0x2 0x1.
	 * 0x6270 first-list is not the identity stall. Keep.
	 * #434 Camera ID 1 skipped TAP 0x5868 n=2
	 * { 0x1e7, 0x287 } (DS16 Y 488×648). One
	 * variable: 0x5868. Do not retry 0x4460 Crop 640.
	 * Do not copy 0x5d04 onto OUT. Do not Dual-IFE.
	 * #434 on #452: /tmp/pix.nv12 0 bytes, viol=0
	 * img=0xc0 as0 Y=0 C=0xffcd3400 bus=0x80000000
	 * camif irq1 0x1 0xc 0x2 0x1. Same stall as
	 * #433. 0x5868 first-list is not the identity stall. Keep.
	 * #435 Camera ID 1 skipped TAP 0x5a68 n=2
	 * { 0xf3, 0x143 } (244×324). One variable:
	 * 0x5a68. Do not retry 0x4460 Crop 640.
	 * Do not Dual-IFE. Do not pack chroma 7.
	 * #435 on #453: w5a68=0xf3/0x143 w5868=0x1e7/0x287
	 * stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0xc0
	 * as0 Y=0 C=0xffcd3400 bus=0x80000000 camif irq1
	 * 0x1 0xc 0x2 0x1. 0x5a68 first-list is not the identity stall. Keep.
	 * #436 Camera ID 1 skipped TAP 0x5860 n=1 0xe01
	 * (DS16 Y MODULE). One variable: 0x5860 EN.
	 * Do not 0x5870. Do not retry Crop 640.
	 * Do not Dual-IFE.
	 * #436 on #454: /tmp/pix.nv12 0 bytes, viol=0
	 * img=0xc0 as0 Y=0 C=0xffcd3400 bus=0x80000000
	 * camif irq1 0x1 0xc 0x2 0x1. Same stall as #435.
	 * 0x5860 first-list is not the identity stall. Keep.
	 * #437 Camera ID 1 skipped TAP 0x5870 n=6
	 * { 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 } linear
	 * clamp. One variable: 0x5870. Do not 0x5a60.
	 * Do not pack chroma 7. Do not retry Crop 640.
	 * Do not Dual-IFE.
	 * #437 on #455: en5860=0xe01 c5870=0x3ff0000 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0xc0
	 * as0 Y=0 C=0xffcd3400 bus=0x80000000
	 * camif irq1 0x1 0xc 0x2 0x1. Same stall as #436.
	 * 0x5870 first-list is not the identity stall. Keep.
	 * #438 Camera ID 1 skipped TAP 0x5a60 n=1 0x3e01
	 * (DS16 C MODULE). One variable: 0x5a60 EN.
	 * Do not 0x5a70. Do not pack chroma 7.
	 * Do not retry Crop 640. Do not Dual-IFE.
	 * #438 on #456: en5a60=0x3e01 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0xc0
	 * as0 Y=0 C=0xffcd3400 bus=0x80000000
	 * camif irq1 0x1 0xc 0x2 0x1. Same stall as #437.
	 * 0x5a60 first-list is not the identity stall. Keep.
	 * #439 Camera ID 1 skipped TAP 0x5a70 n=6
	 * { 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 } linear
	 * clamp. One variable: 0x5a70. Do not copy
	 * UBWC chroma 7. Do not rewrite 0x5d04.
	 * Do not retry Crop 640. Do not Dual-IFE.
	 * #439 on #457: en5a60=0x3e01 c5a70=0x3ff0000 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0xc0
	 * as0 Y=0 C=0xffcd3400 bus=0x80000000
	 * camif irq1 0x1 0xc 0x2 0x1. Same stall as #438.
	 * 0x5a70 first-list is not the identity stall. Keep.
	 * #440 Camera ID 1 first-list TAP 0x5d04 n=2
	 * { 0x1e7, 0x287 } (488×648). One variable:
	 * 0x5d04 identity. Do not copy onto OUT.
	 * Do not retry Crop 640. Do not Dual-IFE.
	 * Do not pack chroma 7.
	 * #440 on #458: w5d04=0x1e7/0x287 stuck,
	 * /tmp/pix.nv12 0 bytes, viol=0 img=0xc0
	 * as0 Y=0 C=0xffcd3400 bus=0x80000000
	 * camif irq1 0x1 0xc 0x2 0x1. Same stall as #439.
	 * 0x5d04 first-list is not the identity stall. Keep.
	 */
	if (0 && in_w == 2592 && in_h == 1952 && dest_w == 2592 && dest_h == 1952) {
		vfe_480_pack(vfe, CLC_DS411_C_CROP,
			     (const u32[]){ 0x0000079f, 0x00000a1f }, 2);
		vfe_480_pack(vfe, 0x5704,
			     (const u32[]){ 0x000003cf, 0x00000a1f }, 2);
		vfe_480_pack(vfe, 0x5f04,
			     (const u32[]){ 0x000000f3, 0x00000287 }, 2);
		vfe_480_pack(vfe, 0x6068,
			     (const u32[]){ 0x00000079, 0x000000a1 }, 2);
		vfe_480_pack(vfe, 0x6268,
			     (const u32[]){ 0x0000003c, 0x00000050 }, 2);
		vfe_480_pack(vfe, 0x6060,
			     (const u32[]){ 0x00000e01 }, 1);
		vfe_480_pack(vfe, 0x6070,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 }, 6);
		vfe_480_pack(vfe, 0x6260,
			     (const u32[]){ 0x00003e01 }, 1);
		vfe_480_pack(vfe, 0x6270,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 }, 6);
		vfe_480_pack(vfe, 0x5868,
			     (const u32[]){ 0x000001e7, 0x00000287 }, 2);
		vfe_480_pack(vfe, 0x5a68,
			     (const u32[]){ 0x000000f3, 0x00000143 }, 2);
		vfe_480_pack(vfe, 0x5860,
			     (const u32[]){ 0x00000e01 }, 1);
		vfe_480_pack(vfe, 0x5870,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 }, 6);
		vfe_480_pack(vfe, 0x5a60,
			     (const u32[]){ 0x00003e01 }, 1);
		vfe_480_pack(vfe, 0x5a70,
			     (const u32[]){ 0x03ff0000, 6, 0x03ff0000, 6, 0, 0 }, 6);
		vfe_480_pack(vfe, 0x5d04,
			     (const u32[]){ 0x000001e7, 0x00000287 }, 2);
	} else if (in_w != 2592 || in_h != 1952)
		vfe_480_pack(vfe, CLC_DS411_C_CROP, live_tap_ds4c,
			     ARRAY_SIZE(live_tap_ds4c));
	if (in_w != 2592 || in_h != 1952)
		vfe_480_pack(vfe, 0x5c08, live_tap_ds16, ARRAY_SIZE(live_tap_ds16));
	if (in_w != 2592 || in_h != 1952)
		vfe_480_pack(vfe, 0x5d04, live_tap_ds16c,
			     ARRAY_SIZE(live_tap_ds16c));
	/*
	 * Display Full dest: identity TAP 0x5868 is CLC_RNDCLAMP_OUT_Y
	 * 488×648, not TAP. #464 STREAMON dest-gate still left
	 * w5868=0x1e7/0x287 vs WM 2320 → AXI 0 bytes. Restore
	 * #386 OUT dest after that list. Do not 0x7e60.
	 */
	if (in_w == 2592 && in_h == 1952) {
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_Y + 0x68,
			     (const u32[]){ 0x00000527, 0x0000090f }, 2);
		vfe_480_pack(vfe, CLC_RNDCLAMP_OUT_C + 0x68,
			     (const u32[]){ 0x00000293, 0x00000487 }, 2);
	}
}

static const char *vfe_480_viol_name(u32 id)
{
	switch (id) {
	case 18:
		return "MNDS_Y";
	case 19:
		return "MNDS_C";
	case 20:
		return "CROP_RND_Y";
	case 21:
		return "CROP_RND_C";
	default:
		return "?";
	}
}

static void __iomem *vfe_480_camnoc;

static void vfe_480_camnoc_dump(struct vfe_device *vfe, const char *when)
{
	void __iomem *cn = vfe_480_camnoc;

	if (!cn)
		return;
	if (when[0] == 'o')
		dev_info_ratelimited(vfe->camss->dev,
				     "dagu ife%d camnoc %s lin=0x%x/urg=0x%x/maxwr=0x%x rdi=0x%x/urg=0x%x/maxwr=0x%x ubwc=0x%x/urg=0x%x err=0x%x pri=0x%x/0x%x\n",
				     vfe->id, when,
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_FILL),
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_URGENCY),
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_MAXWR),
				     readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_FILL),
				     readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_URGENCY),
				     readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_MAXWR),
				     readl_relaxed(cn + CAMNOC_IFE_UBWC_STATS + CAMNOC_NIU_FILL),
				     readl_relaxed(cn + CAMNOC_IFE_UBWC_STATS + CAMNOC_NIU_URGENCY),
				     readl_relaxed(cn + CAMNOC_ERRVLD),
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_PRI_LO),
				     readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_PRI_HI));
	else
		dev_info(vfe->camss->dev,
			 "dagu ife%d camnoc %s lin=0x%x/urg=0x%x/maxwr=0x%x rdi=0x%x/urg=0x%x/maxwr=0x%x ubwc=0x%x/urg=0x%x err=0x%x pri=0x%x/0x%x\n",
			 vfe->id, when,
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_FILL),
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_URGENCY),
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_MAXWR),
			 readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_FILL),
			 readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_URGENCY),
			 readl_relaxed(cn + CAMNOC_IFE_RDI_WR + CAMNOC_NIU_MAXWR),
			 readl_relaxed(cn + CAMNOC_IFE_UBWC_STATS + CAMNOC_NIU_FILL),
			 readl_relaxed(cn + CAMNOC_IFE_UBWC_STATS + CAMNOC_NIU_URGENCY),
			 readl_relaxed(cn + CAMNOC_ERRVLD),
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_PRI_LO),
			 readl_relaxed(cn + CAMNOC_IFE_LINEAR + CAMNOC_NIU_PRI_HI));
}

static void vfe_480_camnoc_niu_qos(void __iomem *niu)
{
	writel_relaxed(CAMNOC_PRI_LO, niu + CAMNOC_NIU_PRI_LO);
	writel_relaxed(CAMNOC_PRI_HI, niu + CAMNOC_NIU_PRI_HI);
	writel_relaxed(CAMNOC_URGENCY, niu + CAMNOC_NIU_URGENCY);
	writel_relaxed(CAMNOC_DANGER, niu + CAMNOC_NIU_DANGER);
	writel_relaxed(CAMNOC_SAFE, niu + CAMNOC_NIU_SAFE);
}

static void vfe_480_camnoc_ife_qos(struct vfe_device *vfe)
{
	if (!vfe_480_camnoc)
		return;
	vfe_480_camnoc_dump(vfe, "rst");
	vfe_480_camnoc_niu_qos(vfe_480_camnoc + CAMNOC_IFE_LINEAR);
	vfe_480_camnoc_niu_qos(vfe_480_camnoc + CAMNOC_IFE_RDI_WR);
	vfe_480_camnoc_niu_qos(vfe_480_camnoc + CAMNOC_IFE_UBWC_STATS);
	wmb();
	vfe_480_camnoc_dump(vfe, "qos");
}

static void vfe_480_bus_dump(struct vfe_device *vfe, const char *tag)
{
	dev_info(vfe->camss->dev,
		 "dagu ife%d bus %s comp=0x%x/0x%x fh0=0x%x top=0x%x/0x%x drop4=0x%x/0x%x irqsub4=0x%x/0x%x cfg0=0x%x stride4=0x%x\n",
		 vfe->id, tag,
		 readl_relaxed(vfe->base + VFE_BUS_COMP_CFG_0),
		 readl_relaxed(vfe->base + VFE_BUS_COMP_CFG_1),
		 readl_relaxed(vfe->base + VFE_BUS_IF_FRAMEHEADER_CFG(0)),
		 readl_relaxed(vfe->base + VFE_BUS_DEBUG_STATUS_TOP_CFG),
		 readl_relaxed(vfe->base + VFE_BUS_DEBUG_STATUS_TOP),
		 readl_relaxed(vfe->base + VFE_BUS_WM_FRAMEDROP_PERIOD(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_FRAMEDROP_PATTERN(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_2(DISP_Y_WM)));
}

/*
 * CAF cam_vfe480.h if_frameheader_cfg[SRC_GRP]. CamX only sets bit2 of
 * en_cfg when it also programs frame_header_addr. A reset leftover on
 * SRC_GRP_0 makes DISP wait for a header beat and never issue AXI
 * (as3 latched, as0=0, CAMNOC fill=0). Linear NV12 has no header.
 */
static void vfe_480_bus_common(struct vfe_device *vfe)
{
	unsigned int i;

	vfe_480_bus_dump(vfe, "rst");
	for (i = 0; i < BUS_FRAMEHEADER_GRPS; i++)
		writel_relaxed(0, vfe->base + VFE_BUS_IF_FRAMEHEADER_CFG(i));
	writel_relaxed(1, vfe->base + VFE_BUS_OVERFLOW_STATUS_CLEAR);
	/*
	 * CAF debug_status_top_cfg: n+1 selects BUS client n.
	 * 1 was VID WM0 (never started) — frozen 0x1f8098 before SOF.
	 * DISP Y is client 4.
	 */
	writel_relaxed(DISP_Y_WM + 1, vfe->base + VFE_BUS_DEBUG_STATUS_TOP_CFG);
	wmb();
	vfe_480_bus_dump(vfe, "clr");
}

static void dagu_front_irq_mask(struct vfe_device *vfe)
{
	if (!dagu_front_pix)
		return;
	writel(0x92800280, vfe->base + VFE_IRQ_MASK(0));
	writel(0xc0047981, vfe->base + VFE_BUS_IRQ_MASK(0));
	dev_info(vfe->camss->dev, "dagu front irq mask core=0x%x bus=0x%x\n",
		 readl_relaxed(vfe->base + VFE_IRQ_MASK(0)),
		 readl_relaxed(vfe->base + VFE_BUS_IRQ_MASK(0)));
}

/*
 * Deterministic DISP program (#628). Every block on the IFE1 PIX path
 * is either written from the stream formats or switched off, so one
 * stream no longer inherits the previous one's registers. Semantics
 * measured on dagu with sensor colour bars / solid levels (see
 * docs/dagu-ife-disp-pipeline.md):
 *
 *  MNDS +0x68 in size, +0x6c H phase, +0x74 V phase (Q21 | 0xc0000000);
 *       chroma phases are twice the luma ones; the other words are 0.
 *  DMI  per module: +0x08 address, +0x0c LUT select, +0x14 data.
 *  Gamma 64 segments over the 12-bit input (idx = in >> 6), stored in
 *       8-bit output units: the LUT value reaches the NV12 luma 1:1.
 *  CST  Y coefficients Q10, Cb/Cr Q12 (13-bit signed); inputs G,B,R.
 *  CC   rows by input channel in G,B,R order, Q7.
 *  Demux gain 0x04 per channel takes the 10-bit sensor to the 12-bit
 *       pipe the gamma indexes; black 64 is already removed there.
 */
static unsigned int dagu_disp_new = 1;
module_param(dagu_disp_new, uint, 0644);
MODULE_PARM_DESC(dagu_disp_new, "1 = deterministic DISP program, 0 = legacy");
/* Bayer order as the IFE sees it; -1 = from the mbus code. Front bars
 * decode as RGGB (pattern 0) while imx596 reports SBGGR10. */
static int dagu_pattern_override = -1;

static const u32 vfe_480_gamma_srgb[64] = {
	0x08800, 0x03c22, 0x03031, 0x0283d, 0x02047, 0x01c4f, 0x01c56, 0x0185d,
	0x01863, 0x01469, 0x0146e, 0x01473, 0x01078, 0x0147c, 0x01081, 0x01085,
	0x01089, 0x0108d, 0x00c91, 0x01094, 0x00c98, 0x00c9b, 0x0109e, 0x00ca2,
	0x00ca5, 0x00ca8, 0x00cab, 0x00cae, 0x008b1, 0x00cb3, 0x00cb6, 0x00cb9,
	0x008bc, 0x00cbe, 0x008c1, 0x00cc3, 0x008c6, 0x008c8, 0x00cca, 0x008cd,
	0x008cf, 0x00cd1, 0x008d4, 0x008d6, 0x008d8, 0x008da, 0x00cdc, 0x008df,
	0x008e1, 0x008e3, 0x008e5, 0x008e7, 0x008e9, 0x008eb, 0x008ed, 0x004ef,
	0x008f0, 0x008f2, 0x008f4, 0x008f6, 0x008f8, 0x004fa, 0x008fb, 0x008fd,
};

/* BT.601 full range (the NV12 node reports full-range 601). */
static const u32 vfe_480_cst_601_full[12] = {
	0x00750259, 0x00000132, 0x00000000, 0x03ff0000,
	0x07fe1ab3, 0x00001d4d, 0x02000000, 0x03ff0000,
	0x1eb3194d, 0x000007fe, 0x02000000, 0x03ff0000,
};

/* CLC blocks that are not on the linear DISP path. */
static const u16 vfe_480_disp_off[] = {
	0x2200, 0x2400, 0x2800, 0x2a00, 0x2c00, 0x2e00, 0x3200,
	0x3600, 0x3c00, 0x4200, 0x4400, 0x4600, 0x4800, 0x4a00, 0x5800,
	0x5a00, 0x6000, 0x6200, 0x7e00, 0x8000, 0x8200, 0x8400, 0x8600,
	0x8800, 0x8a00, 0x8e00, 0x9c00,
};

/*
 * 0x3400 (MODULE 0xc101, three DMI LUTs) removes the sensor black and
 * filters the Bayer noise: with it off a 10-bit code 64 (sensor black)
 * leaves the pipe at sRGB ~70 and every dark pixel sits on that veil;
 * with it on code 64 lands at ~9. Words are the HyperOS live values.
 */
static const u32 vfe_480_bnr_front[46] = {
	0x03000300, 0x03000300, 0x00636363, 0x00636363, 0x00000000, 0x01000100,
	0x01000100, 0x00030403, 0x3c303af0, 0x00282a00, 0x00000329, 0x028f0000,
	0x0a3c05c2, 0x01000100, 0x01000100, 0x00000000, 0x00000000, 0x00000000,
	0x01000100, 0x01000100, 0x00000000, 0x00000000, 0x01000000, 0x0ccc0200,
	0x00cd00cd, 0x00cd00cd, 0x00000000, 0x00000000, 0x00000000, 0x00cd00cd,
	0x00cd00cd, 0x00000000, 0x00000000, 0x00000800, 0x00010001, 0x0020c080,
	0x020b007d, 0x017e00ab, 0x00bb015e, 0x20040408, 0x01000100, 0x01000100,
	0x00000000, 0x00000000, 0x000003c0, 0x0000087f,
};
static const u32 vfe_480_bnr_rear[46] = {
	0x03800380, 0x03800380, 0x00636363, 0x00636363, 0x00000000, 0x01000100,
	0x01000100, 0x00030403, 0x3a063808, 0x00633864, 0x0000029a, 0x028f0000,
	0x0a3c05c2, 0x01000100, 0x01000100, 0x00000000, 0x00000000, 0x00000000,
	0x01000100, 0x01000100, 0x00000000, 0x00000000, 0x01000000, 0x0ccc0200,
	0x004d004d, 0x004d004d, 0x00000000, 0x00000000, 0x00000000, 0x004d004d,
	0x004d004d, 0x00000000, 0x00000000, 0x00000800, 0x00010001, 0x0020c080,
	0x01a6009b, 0x01d5008c, 0x011d00e6, 0x20040408, 0x01000100, 0x01000100,
	0x00000000, 0x00000000, 0x000003c0, 0x0000087f,
};

static void vfe_480_dmi_load(struct vfe_device *vfe, u32 base, u32 sel,
			     const u32 *lut, unsigned int n)
{
	unsigned int i;

	writel_relaxed(sel, vfe->base + base + 0x0c);
	writel_relaxed(0, vfe->base + base + 0x08);
	wmb();
	for (i = 0; i < n; i++)
		writel_relaxed(lut[i], vfe->base + base + 0x14);
	wmb();
	writel_relaxed(0, vfe->base + base + 0x0c);
}

static void vfe_480_disp_mnds(struct vfe_device *vfe, u32 base, u32 in_w,
			      u32 in_h, u32 out_w, u32 out_h)
{
	u32 o;

	writel_relaxed(1, vfe->base + base + 0x60);
	/* Filter config word; 0 here breaks the horizontal resampler. */
	writel_relaxed(0x600, vfe->base + base + 0x64);
	writel_relaxed(((in_w - 1) << 16) | (in_h - 1), vfe->base + base + 0x68);
	writel_relaxed(0xc0000000 | (u32)div_u64((u64)in_w << 21, out_w),
		       vfe->base + base + 0x6c);
	writel_relaxed(0, vfe->base + base + 0x70);
	writel_relaxed(0xc0000000 | (u32)div_u64((u64)in_h << 21, out_h),
		       vfe->base + base + 0x74);
	for (o = 0x78; o <= 0x84; o += 4)
		writel_relaxed(0, vfe->base + base + o);
}

static void vfe_480_disp_clamp(struct vfe_device *vfe, u32 base, u32 cfg,
			       u32 w, u32 h)
{
	writel_relaxed(cfg, vfe->base + base + 0x60);
	writel_relaxed(0, vfe->base + base + 0x64);
	writel_relaxed(h - 1, vfe->base + base + 0x68);
	writel_relaxed(w - 1, vfe->base + base + 0x6c);
	writel_relaxed(0x03ff0000, vfe->base + base + 0x70);
	writel_relaxed(6, vfe->base + base + 0x74);
	writel_relaxed(0x03ff0000, vfe->base + base + 0x78);
	writel_relaxed(6, vfe->base + base + 0x7c);
	writel_relaxed(0, vfe->base + base + 0x80);
	writel_relaxed(0, vfe->base + base + 0x84);
}

static void vfe_480_disp_program(struct vfe_device *vfe, struct vfe_line *line)
{
	struct v4l2_mbus_framefmt *sink = &line->fmt[MSM_VFE_PAD_SINK];
	struct v4l2_pix_format_mplane *pix =
		&line->video_out.active_fmt.fmt.pix_mp;
	u32 in_w = sink->width, in_h = sink->height;
	u32 out_w = pix->width, out_h = pix->height;
	u32 crop_w = in_w, crop_h = in_h, x0 = 0, y0 = 0;
	u32 core, i;
	bool front = in_w == 2592 && in_h == 1952;

	if (!in_w || !in_h || !out_w || !out_h)
		return;
	/* Keep the aspect: centre-crop the sensor frame to the output. */
	if ((u64)in_w * out_h > (u64)in_h * out_w)
		crop_w = (u32)div_u64((u64)in_h * out_w, out_h) & ~3u;
	else
		crop_h = (u32)div_u64((u64)in_w * out_h, out_w) & ~3u;
	x0 = ((in_w - crop_w) / 2) & ~3u;
	y0 = ((in_h - crop_h) / 2) & ~3u;

	dagu_front_pix = front;
	dagu_pattern_override = front ? 0 : -1;
	if (front) {
		dagu_front_evt_n = 0;
		dagu_front_evt_shown = 0;
		dagu_reload_phase = 0;
		dagu_rup_pending = false;
	}

	writel_relaxed(0xffffffff, vfe->base + VFE_CORE_CGC_OVD_0);
	writel_relaxed(0xffffffff, vfe->base + VFE_CORE_CGC_OVD_1);
	writel_relaxed(0xffffffff, vfe->base + VFE_AHB_CGC_OVD);
	writel_relaxed(0xffffffff, vfe->base + VFE_NOC_CGC_OVD);
	writel_relaxed(0, vfe->base + VFE_BUS_PWR_ISO_CFG);
	vfe_480_bus_common(vfe);
	vfe_480_camnoc_ife_qos(vfe);
	core = 1 << CORE_CFG_0_OPERATING_MODE;
	core |= BIT(CORE_CFG_0_VID_DS4_R2PD) | BIT(CORE_CFG_0_VID_DS16_R2PD);
	core |= BIT(CORE_CFG_0_DISP_DS4_R2PD) | BIT(CORE_CFG_0_DISP_DS16_R2PD);
	writel_relaxed(core, vfe->base + VFE_CORE_CFG_0);
	writel_relaxed(1, vfe->base + VFE_TOP_DEBUG_CFG);
	writel_relaxed(1, vfe->base + VFE_DIAGNOSTIC_HW);

	for (i = 0; i < ARRAY_SIZE(vfe_480_disp_off); i++)
		writel_relaxed(0, vfe->base + vfe_480_disp_off[i] + CLC_MODULE_CFG);
	/* DS4 / DS16 Y/C: no WM6/7 on the linear path. */
	writel_relaxed(0, vfe->base + 0x5408);
	writel_relaxed(0, vfe->base + 0x5608);
	writel_relaxed(0, vfe->base + 0x5c08);
	writel_relaxed(0, vfe->base + 0x5e08);

	/* CAMIF window (lines in 2ppc pairs), keep-all skip, epoch mid. */
	writel_relaxed(0, vfe->base + CAMIF_SPARE);
	writel_relaxed(((x0 + crop_w - 1) << 16) | x0,
		       vfe->base + CAMIF_CROP_WIDTH);
	writel_relaxed((((y0 + crop_h) / 2 - 1) << 16) | (y0 / 2),
		       vfe->base + CAMIF_CROP_HEIGHT);
	writel_relaxed(0xffffffff, vfe->base + CAMIF_LINE_SKIP);
	writel_relaxed(0xffffffff, vfe->base + CAMIF_PIXEL_SKIP);
	writel_relaxed(0x00010001, vfe->base + CAMIF_PERIOD);
	writel_relaxed(0xffffffff, vfe->base + CAMIF_IRQ_SUBSAMPLE);
	writel_relaxed((0x14 << 16) | (crop_h / 4), vfe->base + CLC_CAMIF_EPOCH);

	/* Demux: per-sensor live words, then 4x to the 12-bit pipe. */
	vfe_480_demux(vfe, in_w, in_h);
	for (i = 0; i < 4; i++)
		writel_relaxed(0x04040404, vfe->base + 0x3094 + 4 * i);

	/* Black level + Bayer noise filter (0x3400). */
	vfe_480_dmi_load(vfe, 0x3400, 1, dagu_front_abf1, ARRAY_SIZE(dagu_front_abf1));
	vfe_480_dmi_load(vfe, 0x3400, 3, dagu_front_abf3, ARRAY_SIZE(dagu_front_abf3));
	vfe_480_dmi_load(vfe, 0x3400, 4, dagu_front_abf4, ARRAY_SIZE(dagu_front_abf4));
	vfe_480_pack(vfe, 0x3468, front ? vfe_480_bnr_front : vfe_480_bnr_rear, 46);
	writel_relaxed(0, vfe->base + 0x3458);
	writel_relaxed(0, vfe->base + 0x345c);
	vfe_480_clc_enable(vfe, 0x3400, 0xc101);

	/* Demosaic + WB (B<<16|G, R; Q10). AWB rewrites these via live. */
	vfe_480_pack(vfe, CLC_DEMOSAIC + DEMOSAIC_WB,
		     (const u32[]){ (0x600 << 16) | 0x400, 0x600, 0, 0 }, 4);
	vfe_480_clc_enable(vfe, CLC_DEMOSAIC, DEMOSAIC_COMPACT_CFG);
	vfe_480_pack(vfe, CLC_DEMOSAIC_INTERP,
		     (const u32[]){ 0x80, 0x00800066 }, 2);

	/* CC identity (G,B,R rows, Q7). */
	vfe_480_pack(vfe, CLC_CC + CLC_CC_MATRIX,
		     (const u32[]){ 0x80, 0, 0x800000, 0, 0, 0x80, 0, 0, 0 }, 9);
	writel_relaxed(0, vfe->base + CLC_CC + CLC_CC_SPARE);
	vfe_480_clc_enable(vfe, CLC_CC, BIT(0));

	/* Gamma sRGB, the same curve on all three LUTs. */
	for (i = 1; i <= 3; i++)
		vfe_480_dmi_load(vfe, CLC_GAMMA, i, vfe_480_gamma_srgb,
				 ARRAY_SIZE(vfe_480_gamma_srgb));
	writel_relaxed(0, vfe->base + CLC_GAMMA + 0x58);
	writel_relaxed(0, vfe->base + CLC_GAMMA + 0x5c);
	vfe_480_clc_enable(vfe, CLC_GAMMA, 1);

	vfe_480_pack(vfe, CLC_CST + 0x68, vfe_480_cst_601_full,
		     ARRAY_SIZE(vfe_480_cst_601_full));
	vfe_480_clc_enable(vfe, CLC_CST, 1);

	vfe_480_disp_mnds(vfe, CLC_MNDS_Y, crop_w, crop_h, out_w, out_h);
	vfe_480_disp_mnds(vfe, CLC_MNDS_C, crop_w, crop_h, out_w / 2, out_h / 2);
	vfe_480_disp_clamp(vfe, CLC_RNDCLAMP_POST_Y, 0xe01, out_w, out_h);
	vfe_480_disp_clamp(vfe, CLC_RNDCLAMP_POST_C, 0x3e01, out_w / 2, out_h / 2);
	wmb();

	dagu_front_irq_mask(vfe);
	dev_info(vfe->camss->dev,
		 "dagu ife%d disp in %ux%u crop %ux%u@%u,%u out %ux%u pattern=%d\n",
		 vfe->id, in_w, in_h, crop_w, crop_h, x0, y0, out_w, out_h,
		 dagu_pattern_override);
}

static void vfe_480_pix_pipeline(struct vfe_device *vfe, struct vfe_line *line)
{
	struct v4l2_mbus_framefmt *sink = &line->fmt[MSM_VFE_PAD_SINK];
	struct v4l2_pix_format_mplane *pix =
		&line->video_out.active_fmt.fmt.pix_mp;
	u32 in_w = sink->width;
	u32 in_h = sink->height;
	u32 out_w = pix->width;
	u32 out_h = pix->height;
	u32 pipe_h;
	u32 epoch;
	u32 core;

	if (!in_w)
		in_w = out_w;
	if (!in_h)
		in_h = out_h;
	if (!out_w)
		out_w = in_w;
	if (!out_h)
		out_h = in_h;
	/*
	 * Titan 480 CAMIF is 2ppc: overflow/stop debug line sticks at
	 * in_h/2 (4080×3060 → line=1530, pix=4080) for the whole
	 * STREAMON. CAF epoch = pixel_h/4 is mid-frame of that
	 * counter. Crop11 LINE and MNDS V_SIZE are the same line
	 * unit as the debug counter — 3059 never arrives, so POST
	 * never hands WM4 a line (dbg=0, as0=0, viol_id=0).
	 * CAMIF_CROP_HEIGHT stays sensor pixels; CLC V uses pipe_h.
	 */
	pipe_h = in_h / 2;
	if (!pipe_h)
		pipe_h = in_h;
	/*
	 * #387 CSID IPP VCROP last 0x05bf feeds 1472 pixel / 736
	 * 2ppc lines. Overflow moved 976→736. CAMIF/PRE still used
	 * in_h/2=976 (last 975 never arrives). #388 pipe_h is the
	 * CSID window in 2ppc: pipe_h = (0x05bf + 1) / 2 = 736 on
	 * Display Full. #412 identity CSID is full 1951; pipe_h
	 * stays in_h / 2 = 976. Display Full restores 736.
	 * Do not Dual-IFE COMP_CFG.
	 * Do not retry 0x05bf as the chroma gap.
	 */
	if (in_w == 2592 && in_h == 1952)
		pipe_h = (0x079f + 1) / 2;

	/* Ungate CLC / NOC so demux→demosaic→MNDS actually clocks. */
	writel_relaxed(0xffffffff, vfe->base + VFE_CORE_CGC_OVD_0);
	writel_relaxed(0xffffffff, vfe->base + VFE_CORE_CGC_OVD_1);
	writel_relaxed(0xffffffff, vfe->base + VFE_AHB_CGC_OVD);
	writel_relaxed(0xffffffff, vfe->base + VFE_NOC_CGC_OVD);
	/* CAF cam_vfe480.h pwr_iso_cfg. Isolated DISP clients latch as3
	 * and never consume. RDI is a different BUS port.
	 */
	writel_relaxed(0, vfe->base + VFE_BUS_PWR_ISO_CFG);
	vfe_480_bus_common(vfe);
	/* CAF cam_cpastop_poweron IFE write-port LUTs. Not ICC. */
	vfe_480_camnoc_ife_qos(vfe);

	/*
	 * CAF (~r2pd & 1) << shift: bit set = R2PD off. Bits 24-25 are
	 * dsp_mode / DSP_STREAMING — do not put Bayer there (0x63000800
	 * vs Android 0x60000800). Display Full compact does not pack
	 * DSX10 (0x52e8e0 ret). Empty DS411 hung CAMNOC. CAF client
	 * table puts WM4–7 in COMP_GRP_1 for COMP_DONE IRQ; that is
	 * not COMP_CFG_0. R2PD-on without DSX waits for PD10 (#310).
	 * Linear NV12 is WM4/5 only — DISP R2PD off, WM6/7 stay EN=0
	 * until a real DSX10 DMI program.
	 * VID 29-30 stay off. CORE_CFG_1 is dump-only. Bayer is Demux.
	 * #446 Camera ID 1 live CORE_CFG 0x60000800 (DISP R2PD on,
	 * VID off) with WM6/7 format 36 PD10. Linux identity still
	 * 0x78000800 (DISP R2PD off) while dummy WM6/7 EN — PD10
	 * clients with R2PD off. #310 was R2PD-on without dummy WM.
	 * One variable: identity DISP R2PD on. Do not Dual-IFE.
	 * Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #446 on #464: core=0x60000800 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0 camif irq1=0x1. identity DISP R2PD on is not the identity stall. Keep.
	 * #447 Camera ID 1 first-list 0x010c n=1 0x44440001 (only TOP AHB in 1MB, after stats). One variable: identity 0x010c. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #447 on #465: r010c=0x44440001 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0 camif irq1=0x1. 0x010c first-list is not the identity stall. Keep.
	 * #448 Camera ID 1 first-list 0x9c60 n=1 0x02000001 (after MID, before repeating stats). One variable: identity 0x9c60. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #448 on #466: r9c60=0x2000001 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x9c60 first-list is not the identity stall. Keep.
	 * #449 Camera ID 1 first-list 0x9c68 n=2 {0, 0xffffffff} after 0x9c60. One variable: identity 0x9c68. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #449 on #467: r9c68=0x0/0xffffffff stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x9c68 first-list is not the identity stall. Keep.
	 * #450 Camera ID 1 first-list 0x826c n=8 after 0x9c68. One variable: identity 0x826c. Do not 0x8260 EN. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #450 on #468: r826c=0x3f0000/0x23 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x826c first-list is not the identity stall. Keep.
	 * #451 Camera ID 1 first-list 0x8260 n=1 0xffff0001 after 0x826c window. One variable: identity 0x8260. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #451 on #469: r8260=0xffff0001 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8260 first-list is not the identity stall. Keep.
	 * #452 Camera ID 1 first-list 0x846c n=4 after 0x8260 EN (skip 0x8264=0). One variable: identity 0x846c. Do not 0x8460 EN. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #452 on #470: r846c=0x3f0000/0x23 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x846c first-list is not the identity stall. Keep.
	 * #453 Camera ID 1 first-list 0x8480 n=4 after 0x846c window. One variable: identity 0x8480. Do not 0x8460 EN. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #453 on #471: r8480=0x3fff3fff/0x3fff3fff stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8480 first-list is not the identity stall. Keep.
	 * #454 Camera ID 1 first-list 0x8460 n=1 0xffff0001 after 0x8480 window (skip 0x8468=0). One variable: identity 0x8460. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #454 on #472: r8460=0xffff0001 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8460 first-list is not the identity stall. Keep.
	 * #455 Camera ID 1 first-list 0x8060 n=1 0x101 after 0x8460 EN. One variable: identity 0x8060. Do not 0x8068. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #455 on #473: r8060=0x101 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8060 first-list is not the identity stall. Keep.
	 * #456 Camera ID 1 first-list 0x8068 n=2 {0, 0x03cf050f} after 0x8060 EN. One variable: identity 0x8068. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #456 on #474: r8068=0x0/0x3cf050f stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8068 first-list is not the identity stall. Keep.
	 * #457 Camera ID 1 first-list 0x8e60 n=1 0x801 after 0x8068 window. One variable: identity 0x8e60. Do not 0x8e68. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #457 on #475: r8e60=0x801 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8e60 first-list is not the identity stall. Keep.
	 * #458 Camera ID 1 first-list 0x8e68 n=2 {0, 0x036d048d} after 0x8e60 EN. One variable: identity 0x8e68. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #458 on #476: r8e68=0x0/0x36d048d stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8e68 first-list is not the identity stall. Keep.
	 * #459 Camera ID 1 first-list 0x8660 n=1 0x101 after 0x8e68 window. One variable: identity 0x8660. Do not 0x8668. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #459 on #477: r8660=0x101 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8660 first-list is not the identity stall. Keep.
	 * #460 Camera ID 1 first-list 0x8668 n=2 {0, 0x036d048d} after 0x8660 EN. One variable: identity 0x8668. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #460 on #478: r8668=0x0/0x36d048d stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x8668 first-list is not the identity stall. Keep.
	 * #461 Camera ID 1 first-list 0x7e6c n=5 window after 0x8668. One variable: identity 0x7e6c. Do not 0x7e80. Do not 0x7e60 EN. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #461 on #479: r7e6c=0x1f0000/0x4f stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x7e6c first-list is not the identity stall. Keep.
	 * #462 Camera ID 1 first-list 0x7e80 n=4 window after 0x7e6c. One variable: identity 0x7e80. Do not 0x7e60 EN. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 * #462 on #480: r7e80=0x3fff3fff/0x3fff3fff stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0x0 as0 Y=0 C=0xff4d3400 bus=0x0. 0x7e80 first-list is not the identity stall. Keep.
	 * #463 Camera ID 1 first-list 0x7e60 n=1 0xffff0001 after 0x7e80 window (skip 0x7e68=0). One variable: identity 0x7e60. Do not Dual-IFE COMP_CFG. Do not 0x2e58 EN. Do not chroma 7. Do not Crop 640.
	 */
	core = 1 << CORE_CFG_0_OPERATING_MODE;
	core |= BIT(CORE_CFG_0_VID_DS4_R2PD) | BIT(CORE_CFG_0_VID_DS16_R2PD);
	core |= BIT(CORE_CFG_0_DISP_DS4_R2PD) | BIT(CORE_CFG_0_DISP_DS16_R2PD);
	if (0 && in_w == 2592 && in_h == 1952 && out_w == 2592 && out_h == 1952)
		core &= ~(BIT(CORE_CFG_0_DISP_DS4_R2PD) |
			  BIT(CORE_CFG_0_DISP_DS16_R2PD));
	writel_relaxed(core, vfe->base + VFE_CORE_CFG_0);
	if (in_w == 2592 && in_h == 1952) {
		writel_relaxed(dagu_core_cfg0, vfe->base + VFE_CORE_CFG_0);
		dev_info(vfe->camss->dev, "dagu front core cfg0=0x%x\n",
			 readl_relaxed(vfe->base + VFE_CORE_CFG_0));
	}
	if (0 && in_w == 2592 && in_h == 1952 && out_w == 2592 && out_h == 1952) {
		vfe_480_pack(vfe, 0x010c, (const u32[]){ 0x44440001 }, 1);
		vfe_480_pack(vfe, 0x9c60, (const u32[]){ 0x02000001 }, 1);
		vfe_480_pack(vfe, 0x9c68, (const u32[]){ 0, 0xffffffff }, 2);
		vfe_480_pack(vfe, 0x826c,
			     (const u32[]){ 0x003f0000, 0x00000023, 0x002f0000,
					    0x00000023, 0x3fff3fff, 0x3fff3fff,
					    0, 0 }, 8);
		vfe_480_pack(vfe, 0x8260, (const u32[]){ 0xffff0001 }, 1);
		vfe_480_pack(vfe, 0x846c,
			     (const u32[]){ 0x003f0000, 0x00000023, 0x002f0000,
					    0x00000023 }, 4);
		vfe_480_pack(vfe, 0x8480,
			     (const u32[]){ 0x3fff3fff, 0x3fff3fff, 0, 0 }, 4);
		vfe_480_pack(vfe, 0x8460, (const u32[]){ 0xffff0001 }, 1);
		vfe_480_pack(vfe, 0x8060, (const u32[]){ 0x00000101 }, 1);
		vfe_480_pack(vfe, 0x8068, (const u32[]){ 0, 0x03cf050f }, 2);
		vfe_480_pack(vfe, 0x8e60, (const u32[]){ 0x00000801 }, 1);
		vfe_480_pack(vfe, 0x8e68, (const u32[]){ 0, 0x036d048d }, 2);
		vfe_480_pack(vfe, 0x8660, (const u32[]){ 0x00000101 }, 1);
		vfe_480_pack(vfe, 0x8668, (const u32[]){ 0, 0x036d048d }, 2);
		vfe_480_pack(vfe, 0x7e6c,
			     (const u32[]){ 0x001f0000, 0x0000004f, 0x00170000,
					    0x0000004f, 0 }, 5);
		vfe_480_pack(vfe, 0x7e80,
			     (const u32[]){ 0x3fff3fff, 0x3fff3fff, 0, 0 }, 4);
		vfe_480_pack(vfe, 0x7e60, (const u32[]){ 0xffff0001 }, 1);
	}
	/* CAF top_debug_cfg_en = 1 at 0xDC. */
	writel_relaxed(1, vfe->base + VFE_TOP_DEBUG_CFG);

	/*
	 * 0x2200 is BLS12. Overflow-era EN=0 looked like a brick
	 * wall (violation bit1). #352/#353 EN=0 still DQBUF. CamX
	 * DMI 0x2208 four banks then 0x2268 x0x2e IQ. PIXEL/LINE at
	 * +0x68 bounced 0 on #314 (write-only). Crop11 keep-all
	 * there is ABF 0x3270 class — do not pack it. #354 MODULE=0
	 * because 0x2268 stays at HW reset (unknown subtract).
	 */
	vfe_480_bls(vfe, in_w - 1, pipe_h - 1);
	writel_relaxed(1, vfe->base + VFE_DIAGNOSTIC_HW);
	vfe_480_pedestal(vfe, in_w - 1, pipe_h - 1);

	/*
	 * Empty PDPC11 EN=1 overflowed at line 0 — leave 0x2800 off.
	 * PDPC30 at 0x2e00 is identity DMI. CamX ABF40 compact only
	 * writes MODULE_CFG 0x3260; it does not pack 0x3268. EN=1
	 * plus four zeros overwrote HW reset 0x8000/0x1000100 (CC-
	 * class empty kernel). EN=0 is bypass (line=1530, as0=0).
	 * Compact path: EN=1, leave 0x3268 at reset. Compact bank2
	 * @0x528688 is 0x3460 x1: identity DMI then MODULE 0xc101.
	 * Rear: Do not pack FULL 0x3458/0x3468. #443 identity packs
	 * first-list 0x3458/0x3468. Do not pack {1,1,ABF_BANK2_MODULE}.
	 */
	vfe_480_pdpc30(vfe, in_w, in_h);
	vfe_480_demux(vfe, in_w, in_h);
	vfe_480_abf_region(vfe, in_w - 1, pipe_h - 1);
	vfe_480_abf_bank2(vfe, in_w, in_h);
	/* Live CDM packet 2: 0x3868 x4 + 0x3860=0x4001 + 0x3878 x2.
	 * #361: restore Demosaic EN; PDPC30 stays MODULE=0.
	 * Rear 0x07540400/0x697. Front Camera ID 1 1MB CDM 0x3868
	 * is 0x05fa0400/0x82c (later AWB 0x056a0400/0x8aa). Do not
	 * pack rear WB onto 2592×1952.
	 */
	{
		static const u32 rear_3868[] = {
			0x07540400, 0x00000697, 0x00000000, 0x00000000,
		};
		static const u32 front_3868[] = {
			0x05fa0400, 0x0000082c, 0x00000000, 0x00000000,
		};
		const u32 *wb13 = (in_w == 2592 && in_h == 1952) ?
				  front_3868 : rear_3868;

		vfe_480_pack(vfe, CLC_DEMOSAIC + DEMOSAIC_WB, wb13, 4);
		vfe_480_clc_enable(vfe, CLC_DEMOSAIC, DEMOSAIC_COMPACT_CFG);
		vfe_480_pack(vfe, 0x3878, (const u32[]){ 0x80, 0x00800066 }, 2);
	}
	vfe_480_gtm(vfe, in_w - 1, pipe_h - 1);
	vfe_480_cc(vfe);
	vfe_480_wb(vfe);
	vfe_480_gamma(vfe);
	if (in_w == 2592 && in_h == 1952)
		vfe_480_front_live_dmi(vfe);
	vfe_480_cst(vfe);
	vfe_480_rndclamp(vfe, CLC_RNDCLAMP, in_w - 1, pipe_h - 1);
	vfe_480_fd_off(vfe);

	vfe_480_mnds(vfe, CLC_MNDS_Y, in_w, pipe_h, out_w, out_h);
	/* NV12 chroma is 4:2:0 of the 2ppc luma height. */
	vfe_480_mnds(vfe, CLC_MNDS_C, in_w, pipe_h / 2, out_w, out_h / 2);
	vfe_480_rndclamp(vfe, CLC_RNDCLAMP_POST_Y, out_w - 1, out_h - 1);
	if (out_h / 2)
		vfe_480_rndclamp(vfe, CLC_RNDCLAMP_POST_C, out_w - 1,
				 out_h / 2 - 1);
	vfe_480_rndclamp(vfe, CLC_RNDCLAMP_OUT_Y, out_w - 1, out_h - 1);
	if (out_h / 2)
		vfe_480_rndclamp(vfe, CLC_RNDCLAMP_OUT_C, out_w - 1,
				 out_h / 2 - 1);

	/*
	 * Live Display Full CDM packet 1 (1MB dmabuf 2026-09-17).
	 * CreateCmdList packs these 9-word / TAP-2 blobs; Linux
	 * keep-all 2ppc 1529 is a different map. CAMIF HEIGHT stays
	 * pipe_h (in_h/2). Do not EN 0x5e00 / WM6/7.
	 */
	vfe_480_live_display_cdm(vfe, in_w, in_h, out_w, out_h);

	/* CAMIF window: last in [31:16], first in [15:0]. 0/0 is empty. */
	/*
	 * Debug counter max is pix=4080 line=1530 (Titan 480 2ppc).
	 * IPP CFG0 bit2 hbin was the 2040-wide cut; width stays 4080.
	 * HEIGHT in the same units as that counter: last=pipe_h-1.
	 * last=in_h-1 (3059) never arrives — IFE_OUT crop does not
	 * complete, CLC sees no pixels, packer dbg 0x2ea, as0=0.
	 */
	writel_relaxed(0, vfe->base + CAMIF_SPARE);
	writel_relaxed(((in_w - 1) << 16) | 0, vfe->base + CAMIF_CROP_WIDTH);
	/*
	 * #385 CAMIF last 735 with CSID keep-all 1951: overflow still
	 * line=976. #387 CSID last 0x05bf moved overflow to 736.
	 * #388 pipe_h=(0x05bf+1)/2 so last=735 matches that feed.
	 */
	writel_relaxed(((pipe_h - 1) << 16) | 0, vfe->base + CAMIF_CROP_HEIGHT);
	/* Titan 170 keep-all: 1-bits in skip pattern, period 1, IRQ every frame. */
	writel_relaxed(0xffffffff, vfe->base + CAMIF_LINE_SKIP);
	writel_relaxed(0xffffffff, vfe->base + CAMIF_PIXEL_SKIP);
	writel_relaxed(0x00010001, vfe->base + CAMIF_PERIOD);
	writel_relaxed(0xffffffff, vfe->base + CAMIF_IRQ_SUBSAMPLE);
	/*
	 * Camera ID 1 CDM writes skip/period 0. Doing that on the
	 * front logged "dagu camif skip0" and still left 8110080,
	 * one COMP_DONE. Second SOF dbg1=0x10218010 wmd=0x20a.
	 * EOF dbg1=0x82d68008 matches a rear frame that continues.
	 * Do not write skip 0 again. Do not write crop 0.
	 */
	dagu_front_pix = (in_w == 2592 && in_h == 1952);
	if (dagu_front_pix) {
		dagu_front_evt_n = 0;
		dagu_front_evt_shown = 0;
		dagu_reload_phase = 0;
		dagu_rup_pending = false;
	}
	dagu_front_irq_mask(vfe);

	epoch = in_h / 4;
	if (in_w == 2592 && in_h == 1952)
		epoch = 0x1e7;
	/*
	 * CAF epoch = pixel_h/4 mid of the 2ppc debug counter.
	 * in_h/4=488 is 66% of CSID 736 (#387). #389 used the
	 * live Crop last window 1472: epoch=0x140170 stuck on
	 * #403, still viol_id=0 line=736 4591616. Epoch is not
	 * the EOF drain. #390 CSID IPP EARLY_EOF_EN cfg0=0xa02b20e3
	 * stuck on #404, still line=736 4591616 — falsified.
	 * #396 pix_store=0 on #410 still 4591616 with bit29 on.
	 * #397 EARLY_EOF=0 on #411 cfg0=0x802b2063 still 4591616
	 * UV 659.145 — falsified. #398 WM5 width 2304 on #412
	 * img=0x20 as0 C=0 0 bytes — falsified, reverted. #399
	 * burst_limit 0 on #414 burst5=0x0 stuck, still 4591616
	 * — falsified. #400 FRAME_INCR 2320*660-1984 on #415
	 * incr5=0x175580 still 4591616 — falsified, reverted.
	 * #401 height 659 on #416 wm5=0x2930910 img=0x20 still
	 * 4591616 — falsified, reverted. Do not invent Q21.
	 * Do not crop last again.
	 * Do not retry EARLY_EOF bit29. Do not retry WM5 2304.
	 * Do not retry burst as the chroma gap.
	 * Do not retry FRAME_INCR 1984. Do not retry height 659.
	 * #402 packer 3 on #417 UV avg 19.3 — falsified, reverted.
	 * Do not retry front packer 3. #403 MNDS_C V_SIZE 0x0293016f
	 * on #418 vsz=0x293016f still 4591616 — not the chroma gap.
	 * #404 V_STRIPE 0x02930000 on #419 vst=0x2930000 still
	 * 4591616 — not the chroma gap. Keep.
	 * Do not retry V_STRIPE as the chroma gap.
	 * #405 V_PHASE 0x0011d7a9 on #420 vph=0x1117a9 still
	 * 4591616 — not the chroma gap. Keep.
	 * Do not retry V_PHASE as the chroma gap.
	 * #406 H_STRIPE 0x090f0000 on #421 hst=0x90f0000 still
	 * 4591616 — not the chroma gap. Keep.
	 * Do not retry H_STRIPE as the chroma gap.
	 * Display Full epoch = (0x05bf + 1) / 4 = 368. #412 identity
	 * epoch is in_h / 4 = 488. Do not retry epoch 368.
	 * Android's live front read stayed 0x001401e7, one below 488.
	 */
	writel_relaxed((0x14 << 16) | epoch, vfe->base + CLC_CAMIF_EPOCH);
	/*
	 * CAF starts CAMIF last, after CDM IMAGE_ADDR and start_wm EN.
	 * Enabling here (wm_start Y, addr still 0, EN still 0) arms the
	 * 2ppc pipe before DISP has a buffer. First SOF then PIXEL-PIPE-
	 * OVERFLOW with as0=0. Crop/epoch stay programmed; EN waits for
	 * vfe_480_camif_go() after DISP_C IMAGE_ADDR.
	 */

	dev_info(vfe->camss->dev,
		 "dagu ife%d pix clc in %ux%u pipe_h=%u out %ux%u core=0x%x camif=0x%x crop=0x%x/0x%x pdpc=0x%x/0x%x ped=0x%x lin=0x%x gtm=0x%x wb=0x%x gamma=0x%x demux=0x%x/0x%x/0x%x/0x%x abf=0x%x gic=0x%x demosaic=0x%x/0x%x cc=0x%x/0x%x/0x%x/0x%x epoch=0x%x\n",
		 vfe->id, in_w, in_h, pipe_h, out_w, out_h,
		 readl_relaxed(vfe->base + VFE_CORE_CFG_0),
		 readl_relaxed(vfe->base + CLC_CAMIF + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CAMIF_CROP_WIDTH),
		 readl_relaxed(vfe->base + CAMIF_CROP_HEIGHT),
		 readl_relaxed(vfe->base + CLC_PDPC11 + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_PDPC30 + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_PEDESTAL + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_LIN + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_GTM + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_WB + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_GAMMA + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_DEMUX),
		 readl_relaxed(vfe->base + CLC_DEMUX + 0x04),
		 readl_relaxed(vfe->base + CLC_DEMUX + 0x14),
		 readl_relaxed(vfe->base + CLC_DEMUX + 0x18),
		 readl_relaxed(vfe->base + CLC_ABF + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_GIC + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC_INTERP),
		 readl_relaxed(vfe->base + CLC_CC + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_CC + CLC_CC_SPARE),
		 readl_relaxed(vfe->base + CLC_CC + CLC_CC_MATRIX),
		 readl_relaxed(vfe->base + CLC_CC + CLC_CC_MATRIX + 16),
		 readl_relaxed(vfe->base + CLC_CAMIF_EPOCH));
	dev_info(vfe->camss->dev,
		 "dagu ife%d pix bls cfg=0x%x px=0x%x ln=0x%x dmi=0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_PREPROCESS + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_PREPROCESS + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_DMI_CFG));
	dev_info(vfe->camss->dev,
		 "dagu ife%d pix wb13 3868=0x%x/0x%x/0x%x/0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 4),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 8),
		 readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 12));
	dev_info(vfe->camss->dev,
		 "dagu ife%d rndclamp=0x%x/0x%x/0x%x/0x%x crop=0x%x/0x%x/0x%x/0x%x/0x%x/0x%x crop_yvph=0x%x crop_yvsz=0x%x crop_c=0x%x/0x%x/0x%x/0x%x/0x%x/0x%x crop_cvph=0x%x crop_cvsz=0x%x crop_chst=0x%x cfg1=0x%x mid_y=0x%x/0x%x/0x%x mid_c=0x%x/0x%x/0x%x post_y=0x%x/0x%x/0x%x post_c=0x%x/0x%x/0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_RNDCLAMP + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP + RNDCLAMP_CH0),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_CROP + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_SPARE),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_H_STRIPE),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_V_STRIPE),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_V_PHASE),
		 readl_relaxed(vfe->base + CLC_CROP + CROP_V_SIZE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_SPARE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_H_STRIPE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_V_STRIPE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_V_PHASE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_V_SIZE),
		 readl_relaxed(vfe->base + CLC_CROP_C + CROP_H_STRIPE),
		 readl_relaxed(vfe->base + VFE_CORE_CFG_1),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_LINE),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_PIXEL),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_LINE));
	dev_info(vfe->camss->dev,
		 "dagu ife%d pix cst=0x%x offu=0x%x offv=0x%x postc70=0x%x/0x%x midc70=0x%x/0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_CST + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_CST + 0x68 + 24),
		 readl_relaxed(vfe->base + CLC_CST + 0x68 + 40),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + 0x70),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + 0x74),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + 0x70),
		 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + 0x74));
	dev_info(vfe->camss->dev,
		 "dagu ife%d mnds_y cfg=0x%x spr=0x%x hsz=0x%x hph=0x%x hst=0x%x hpd=0x%x vsz=0x%x vph=0x%x vst=0x%x vpd=0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_MNDS_Y + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_SPARE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_H_SIZE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_H_PHASE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_H_STRIPE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_H_PAD),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_V_SIZE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_V_PHASE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_V_STRIPE),
		 readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_V_PAD));
	dev_info(vfe->camss->dev,
		 "dagu ife%d mnds_c cfg=0x%x spr=0x%x hsz=0x%x hph=0x%x hst=0x%x hpd=0x%x vsz=0x%x vph=0x%x vst=0x%x vpd=0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_MNDS_C + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_SPARE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_SIZE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_PHASE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_STRIPE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_PAD),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_SIZE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_PHASE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_STRIPE),
		 readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_PAD));
}

static void *vfe_480_ds4_cpu;
static void *vfe_480_ds16_cpu;
static void *vfe_480_meta_cpu;
static dma_addr_t vfe_480_ds4_dma;
static dma_addr_t vfe_480_ds16_dma;
static dma_addr_t vfe_480_meta_dma;

/*
 * WM4/5 always have ubwc_regs. Live HyperOS update_ubwc_meta_addr
 * binds a mapped IOVA every frame. Linear CAF skips sidecar, but
 * reset meta_addr=0 is not in the VFE SMMU; the client latches
 * IMAGE_ADDR (as3) and never consumes (as0=0). Bind a dummy page.
 * mode_cfg bit0 stays 0 — compressor is not V4L2 NV12.
 * CAF debug_status_cfg=1 makes debug_status_0 valid/ready readable.
 * Leaving it 0 kept dbg=0 through every packer cut — telemetry-blind,
 * not proof the packer had no input. Datapath is start_wm EN, not this.
 */
static void vfe_480_wm_sidecar_linear(struct vfe_device *vfe, u8 wm)
{
	u32 meta = 0;

	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_STATS_CTRL(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_CTRL_2(wm));
	/* CAF skips bw_limit when the CamX value is 0. Writing 0 here
	 * is "limit 0 beats", not unlimited.
	 */
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_META_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_SYSTEM_CACHE_CFG(wm));
	if (vfe_480_meta_cpu) {
		meta = lower_32_bits(vfe_480_meta_dma);
		if (wm == DISP_C_WM)
			meta += DISP_META_PAGE;
	}
	writel_relaxed(meta, vfe->base + VFE_BUS_WM_UBWC_META_ADDR(wm));
}

static void vfe_480_wm_config(struct vfe_device *vfe, u8 wm,
			      u32 width, u32 height, u32 stride, u32 frame_incr,
			      bool plain)
{
	writel_relaxed(WM_CGC_OVERRIDE_ALL, vfe->base + VFE_BUS_WM_CGC_OVERRIDE);
	writel_relaxed(0x0, vfe->base + VFE_BUS_WM_TEST_BUS_CTRL);

	writel_relaxed(frame_incr, vfe->base + VFE_BUS_WM_FRAME_INCR(wm));
	/*
	 * #399 burst_limit 0 on #414 burst5=0x0 stuck, still
	 * 4591616 UV 659.145 last_partial=336 — falsified.
	 * CAF skips burst_limit when CamX value is 0 (HW default,
	 * not "0 beats" — that is UBWC bw_limit). Leave front WM5
	 * at 0; same pixels as 0xf. Do not retry burst as the chroma
	 * gap. Width stays 2320. Do not retry WM5 2304. Do not
	 * retry bit29.
	 */
	if (plain && wm == DISP_C_WM && width == 2320 && height == 660)
		writel_relaxed(0, vfe->base + VFE_BUS_WM_BURST_LIMIT(wm));
	else
		writel_relaxed(0xf, vfe->base + VFE_BUS_WM_BURST_LIMIT(wm));
	if (plain)
		writel_relaxed((height << 16) | width,
			       vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
	else
		writel_relaxed(WM_IMAGE_CFG_0_DEFAULT_WIDTH,
			       vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
	/*
	 * #409 CAF IMAGE_CFG_1 is h_init. Camera ID 1 live
	 * WM:5 h_init 0x0. Keep 0. Do not write non-zero IMAGE_CFG_1.
	 */
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IMAGE_CFG_1(wm));
	writel_relaxed(stride, vfe->base + VFE_BUS_WM_IMAGE_CFG_2(wm));
	if (plain) {
		writel_relaxed(wm == DISP_C_WM ? PACKER_PLAIN_8 :
			       PACKER_PLAIN_8_LSB_MSB_10,
			       vfe->base + VFE_BUS_WM_PACKER_CFG(wm));
		/*
		 * #402 front WM5 packer 3 on #417 packer5=0x3 stuck,
		 * still 4591616, UV avg 19.3 (2-38) — same as #362
		 * green. CamX get_packer_fmt(NV12)=3 is UBWC 10-bit;
		 * linear C stays PLAIN_8. Reverted. Do not retry front packer 3.
		 * Do not retry height 659. Do not retry FRAME_INCR 1984.
		 * Do not retry WM5 2304.
		 */
		writel_relaxed(WM_DEBUG_STATUS_0_MUX |
			       (WM_DEBUG_STATUS_1_CONSTRAINT << 8),
			       vfe->base + VFE_BUS_WM_DEBUG_CFG(wm));
		writel_relaxed(UBWC_STATIC_LPDDR5,
			       vfe->base + VFE_BUS_UBWC_STATIC_CTRL);
		vfe_480_wm_sidecar_linear(vfe, wm);
	} else {
		writel_relaxed(0, vfe->base + VFE_BUS_WM_PACKER_CFG(wm));
	}

	writel_relaxed(0, vfe->base + VFE_BUS_WM_FRAMEDROP_PERIOD(wm));
	writel_relaxed((plain && width == 2320 && !dagu_wm_pattern &&
			(wm == DISP_Y_WM || wm == DISP_C_WM)) ? 1 :
		       plain ? 0xffffffff : 1,
		       vfe->base + VFE_BUS_WM_FRAMEDROP_PATTERN(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(wm));
	writel_relaxed((plain && width == 2320 && !dagu_wm_pattern &&
			(wm == DISP_Y_WM || wm == DISP_C_WM)) ? 1 :
		       plain ? 0xffffffff : 1,
		       vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(wm));

	/*
	 * CAF start_wm enables after CDM has IMAGE_ADDR. Enabling PLAIN
	 * DISP with addr 0 left the client not-ready (dbg valid, img=0).
	 * RDI still enables here: MIPI RAW latches width-default.
	 */
	if (plain)
		writel_relaxed(MODE_QCOM_PLAIN << WM_CFG_MODE,
			       vfe->base + VFE_BUS_WM_CFG(wm));
	else
		writel_relaxed(1 << WM_CFG_EN | MODE_MIPI_RAW << WM_CFG_MODE,
			       vfe->base + VFE_BUS_WM_CFG(wm));
}

static int vfe_480_ds_alloc(struct device *dev)
{
	if (vfe_480_ds4_cpu && vfe_480_ds16_cpu && vfe_480_meta_cpu)
		return 0;

	vfe_480_ds4_cpu = dma_alloc_coherent(dev, FRONT_DS4_INCR,
					     &vfe_480_ds4_dma, GFP_KERNEL);
	vfe_480_ds16_cpu = dma_alloc_coherent(dev, DISP_DS16_INCR,
					      &vfe_480_ds16_dma, GFP_KERNEL);
	vfe_480_meta_cpu = dma_alloc_coherent(dev, DISP_META_PAGE * 2,
					      &vfe_480_meta_dma, GFP_KERNEL);
	if (!vfe_480_ds4_cpu || !vfe_480_ds16_cpu || !vfe_480_meta_cpu) {
		dev_err(dev, "dagu DISP DS/meta dummy alloc failed\n");
		return -ENOMEM;
	}
	return 0;
}

static void vfe_480_ds_config(struct vfe_device *vfe, u8 wm,
			      u32 width, u32 height, u32 stride, u32 frame_incr)
{
	writel_relaxed(frame_incr, vfe->base + VFE_BUS_WM_FRAME_INCR(wm));
	writel_relaxed(0xf, vfe->base + VFE_BUS_WM_BURST_LIMIT(wm));
	writel_relaxed((height << 16) | width,
		       vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IMAGE_CFG_1(wm));
	writel_relaxed(stride, vfe->base + VFE_BUS_WM_IMAGE_CFG_2(wm));
	writel_relaxed(PACKER_PLAIN_64, vfe->base + VFE_BUS_WM_PACKER_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_SYSTEM_CACHE_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_FRAMEDROP_PERIOD(wm));
	writel_relaxed(0xffffffff, vfe->base + VFE_BUS_WM_FRAMEDROP_PATTERN(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(wm));
	writel_relaxed(0xffffffff, vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(wm));
	writel_relaxed(MODE_QCOM_PLAIN << WM_CFG_MODE,
		       vfe->base + VFE_BUS_WM_CFG(wm));
}

static void vfe_480_ds_go(struct vfe_device *vfe)
{
	if (!vfe_480_ds4_cpu || !vfe_480_ds16_cpu)
		return;

	writel_relaxed(lower_32_bits(vfe_480_ds4_dma),
		       vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS4_WM));
	writel_relaxed(lower_32_bits(vfe_480_ds16_dma),
		       vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS16_WM));
	wmb();
	writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
		       vfe->base + VFE_BUS_WM_CFG(DISP_DS4_WM));
	writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
		       vfe->base + VFE_BUS_WM_CFG(DISP_DS16_WM));
}

/* Android Camera ID 1 live 2026-10-24, stable in 12/12 reads. */
static const u32 dagu_android_ds_regs[][2] = {
	{ 0x5408, 0x00000307 }, { 0x540c, 0x09016c7d },
	{ 0x5504, 0x0000079f }, { 0x5508, 0x00000a1f },
	{ 0x5608, 0x00000307 },
	{ 0x5704, 0x000003cf }, { 0x5708, 0x00000a1f },
	{ 0x5868, 0x000001e7 }, { 0x586c, 0x00000287 },
	{ 0x5870, 0x03ff0000 }, { 0x5874, 0x00000006 },
	{ 0x5878, 0x03ff0000 }, { 0x587c, 0x00000006 },
	{ 0x5860, 0x00000e01 },
	{ 0x5a68, 0x000000f3 }, { 0x5a6c, 0x00000143 },
	{ 0x5a70, 0x03ff0000 }, { 0x5a74, 0x00000007 },
	{ 0x5a78, 0x03ff0000 }, { 0x5a7c, 0x00000007 },
	{ 0x5a60, 0x00003e01 },
	{ 0x5c08, 0x00000f07 }, { 0x5c0c, 0x09016c7d },
	{ 0x5d04, 0x000001e7 }, { 0x5d08, 0x00000287 },
	{ 0x5e08, 0x00000f07 },
	{ 0x5f04, 0x000000f3 }, { 0x5f08, 0x00000287 },
	{ 0x6068, 0x00000079 }, { 0x606c, 0x000000a1 },
	{ 0x6070, 0x03ff0000 }, { 0x6074, 0x00000006 },
	{ 0x6078, 0x03ff0000 }, { 0x607c, 0x00000006 },
	{ 0x6060, 0x00000e01 },
	{ 0x6268, 0x0000003c }, { 0x626c, 0x00000050 },
	{ 0x6270, 0x03ff0000 }, { 0x6274, 0x00000007 },
	{ 0x6278, 0x03ff0000 }, { 0x627c, 0x00000007 },
	{ 0x6260, 0x00003e01 },
};

static void dagu_front_ds_wm(struct vfe_device *vfe, u8 wm, u32 cfg0,
			     u32 stride, u32 incr)
{
	writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(wm));
	writel_relaxed(incr, vfe->base + VFE_BUS_WM_FRAME_INCR(wm));
	writel_relaxed(cfg0, vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IMAGE_CFG_1(wm));
	writel_relaxed(stride, vfe->base + VFE_BUS_WM_IMAGE_CFG_2(wm));
	writel_relaxed(PACKER_PLAIN_64, vfe->base + VFE_BUS_WM_PACKER_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_SYSTEM_CACHE_CFG(wm));
	writel_relaxed(3, vfe->base + VFE_BUS_WM_BURST_LIMIT(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_FRAMEDROP_PERIOD(wm));
	writel_relaxed(1, vfe->base + VFE_BUS_WM_FRAMEDROP_PATTERN(wm));
	writel_relaxed(0, vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PERIOD(wm));
	writel_relaxed(1, vfe->base + VFE_BUS_WM_IRQ_SUBSAMPLE_PATTERN(wm));
}

static void dagu_front_ds_program(struct vfe_device *vfe)
{
	unsigned int i;

	if (!vfe_480_ds4_cpu || !vfe_480_ds16_cpu) {
		dev_err(vfe->camss->dev, "dagu front ds: no buffers\n");
		return;
	}
	dagu_front_ds_wm(vfe, DISP_DS4_WM, 0x00f40144, 0xb00, 0xb0000);
	dagu_front_ds_wm(vfe, DISP_DS16_WM, 0x003d0051, 0x300, 0xc000);
	for (i = 0; i < ARRAY_SIZE(dagu_android_ds_regs); i++)
		writel_relaxed(dagu_android_ds_regs[i][1],
			       vfe->base + dagu_android_ds_regs[i][0]);
	wmb();
	dev_info(vfe->camss->dev,
		 "dagu front ds program n=%zu en5608=0x%x en5e08=0x%x c5868=0x%x/0x%x wm6=0x%x/0x%x/0x%x wm7=0x%x/0x%x/0x%x core=0x%x\n",
		 ARRAY_SIZE(dagu_android_ds_regs),
		 readl_relaxed(vfe->base + 0x5608),
		 readl_relaxed(vfe->base + 0x5e08),
		 readl_relaxed(vfe->base + 0x5868),
		 readl_relaxed(vfe->base + 0x586c),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_DS4_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_2(DISP_DS4_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_DS4_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_DS16_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_2(DISP_DS16_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_DS16_WM)),
		 readl_relaxed(vfe->base + VFE_CORE_CFG_0));
}

static void dagu_front_ds_feed(struct vfe_device *vfe)
{
	writel_relaxed(lower_32_bits(vfe_480_ds4_dma),
		       vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS4_WM));
	writel_relaxed(lower_32_bits(vfe_480_ds16_dma),
		       vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS16_WM));
	if (!(readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_DS4_WM)) &
	      (1 << WM_CFG_EN))) {
		wmb();
		writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
			       vfe->base + VFE_BUS_WM_CFG(DISP_DS4_WM));
		writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
			       vfe->base + VFE_BUS_WM_CFG(DISP_DS16_WM));
	}
}

static void vfe_wm_start(struct vfe_device *vfe, u8 wm, struct vfe_line *line)
{
	struct v4l2_pix_format_mplane *pix =
		&line->video_out.active_fmt.fmt.pix_mp;
	u32 bpl = pix->plane_fmt[0].bytesperline;

	if (line->id == VFE_LINE_PIX && !vfe_is_lite(vfe)) {
		/*
		 * CLC first, then DISP WM. BUS DISP alone (no demux /
		 * demosaic / MNDS) hangs CAMNOC on this IFE.
		 */
		if (wm == DISP_Y_WM) {
			if (dagu_disp_new)
				vfe_480_disp_program(vfe, line);
			else
				vfe_480_pix_pipeline(vfe, line);
			if (dagu_ds_mode && dagu_front_pix)
				dagu_front_ds_program(vfe);
			dagu_ovr_apply(vfe, DAGU_PH_INIT);
			dagu_prog_apply(vfe, false);
			/*
			 * #425 Camera ID 1 live BUS WM6 0xF40144
			 * 324×244 / WM7 0x3D0051 81×61, dummy IOVA.
			 * #425 on #443: wm6/7=0x1/0x1 stuck, img=0xc0
			 * (WM6|WM7 size viol) bus=0x80000000 as0 Y=0
			 * C=0xffcd3400, /tmp/pix.nv12 0 bytes, g_serial
			 * held. WM6/7 dummy IOVA is not the identity stall.
			 * Keep. #426 on #444: en5608=0x307 stuck, still
			 * /tmp/pix.nv12 0 bytes img=0xc0 bus=0x80000000
			 * as0 Y=0 C=0xffcd3400 g_serial held.
			 * 0x5608 after dummy go is not the identity stall.
			 * Keep. 0x5e08 after 0x5608 is not the identity stall. Keep.
			 * Dummy stride/incr were width×height
			 * (79056). Camera ID 1 live WM6 frame_inc
			 * 720896, PD10 stride 2048. WM7 frame_inc
			 * 49152 stride 768. One variable: dummy
			 * live BUS incr/stride. Do not Dual-IFE
			 * COMP_CFG. Do not empty ADDR=0. Do not
			 * stuff 0xF0 into COMP_CFG. Do not empty
			 * DSX10 DMI.
			 * #441 on #459: incr6 live 720896 stuck,
			 * /tmp/pix.nv12 0 bytes, viol=0 img=0xc0
			 * as0 Y=0 C=0xff4d3400 bus=0x80000000
			 * camif irq1 0x1 0xc 0x2 0x1. Same stall as #440.
			 * dummy live BUS incr is not the identity stall. Keep.
			 * #445 Camera ID 1 CAM_DBG WM6 before stride 2816
			 * (720896/256), not dummy 2048. WM7 768 already
			 * matches. One variable: dummy WM6 stride.
			 * Do not Dual-IFE COMP_CFG. Do not chroma 7.
			 * Do not 0x2e58 EN. Do not copy UBWC 3584.
			 * #445 on #463: stride6=0xb00 stuck, /tmp/pix.nv12 0 bytes, viol=0 img=0xc0 as0 Y=0 C=0xff4d3400 bus=0x80000000 camif irq1 0x1 0xc 0x2 0x1. dummy live BUS stride 2816 is not the identity stall. Keep.
			 */
			if (pix->width == 2592 && pix->height == 1952) {
				vfe_480_ds_config(vfe, DISP_DS4_WM, 324, 244,
						  FRONT_DS4_STRIDE, FRONT_DS4_INCR);
				vfe_480_ds_config(vfe, DISP_DS16_WM, 81, 61,
						  DISP_DS16_STRIDE, DISP_DS16_INCR);
				vfe_480_ds_go(vfe);
				vfe_480_pack(vfe, 0x5608,
					     (const u32[]){ 0x00000307 }, 1);
				vfe_480_pack(vfe, 0x5e08,
					     (const u32[]){ 0x00000f07 }, 1);
			}
		}

		if (wm == DISP_C_WM) {
			/*
			 * #401 WM5 IMAGE_CFG_0 height 659 on #416:
			 * wm5=0x2930910 incr5=0x175430 stuck, img=0x20,
			 * still 4591616 UV 659.145 last_partial=336.
			 * Chroma height does not stop the 336 leftover
			 * or start frame 2. Reverted. Do not retry
			 * height 659. Do not retry FRAME_INCR 1984.
			 * Do not retry WM5 2304. Width stays 2320.
			 * Burst stays 0 (falsified). Keep errrec=0
			 * pix_store=0 EARLY_EOF=0.
			 */
			vfe_480_wm_config(vfe, wm, pix->width, pix->height / 2,
					  bpl, bpl * (pix->height / 2), true);
		} else
			vfe_480_wm_config(vfe, wm, pix->width, pix->height,
					  bpl, bpl * pix->height, true);
		if (wm == DISP_C_WM)
			dev_info(vfe->camss->dev,
				 "dagu ife%d packer4=0x%x packer5=0x%x dbg=0x%x/0x%x ubwc=0x%x mode4/5=0x%x/0x%x addr4/5=0x%x/0x%x cfg4/5=0x%x/0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_UBWC_STATIC_CTRL),
				 readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_C_WM)));
		return;
	}

	wm = RDI_WM(wm);

	vfe_480_wm_config(vfe, wm, 0, 0, bpl,
			  bpl * pix->height, false);
}

static unsigned int dagu_last_written_row(u8 *base, unsigned int stride,
					    unsigned int active, unsigned int rows,
					    unsigned int off)
{
	unsigned int r, i, last = 0;

	for (r = 0; r < rows; r++) {
		u8 *row = base + off + (r * stride);

		for (i = 0; i < active; i++) {
			if (row[i] != 0xa5) {
				last = r + 1;
				break;
			}
		}
	}
	return last;
}

static void dagu_front_sentinel_one(struct vfe_device *vfe, struct camss_buffer *buf,
				    int idx, unsigned int stride, unsigned int width,
				    unsigned int height)
{
	struct vb2_buffer *vb = &buf->vb.vb2_buf;
	void *vaddr = vb2_plane_vaddr(vb, 0);
	unsigned int bytes = vb2_get_plane_payload(vb, 0);
	unsigned int active = width < stride ? width : stride;
	unsigned int y = 0, c = 0;

	if (!vaddr || !bytes || !stride) {
		dev_info(vfe->camss->dev,
			 "dagu front sentinel i=%d empty bytes=%u\n", idx, bytes);
		return;
	}
	invalidate_kernel_vmap_range(vaddr, bytes);
	y = dagu_last_written_row(vaddr, stride, active, height, 0);
	if (bytes > stride * height)
		c = dagu_last_written_row(vaddr, stride, active, height / 2,
					  stride * height);
	dev_info(vfe->camss->dev,
		 "dagu front sentinel i=%d y=%u/%u c=%u/%u bytes=%u addr=0x%llx\n",
		 idx, y, height, c, height / 2, bytes,
		 (unsigned long long)buf->addr[0]);
}

static void dagu_front_sentinel(struct vfe_device *vfe)
{
	struct vfe_line *line = &vfe->line[VFE_LINE_PIX];
	struct vfe_output *output = &line->output;
	struct v4l2_pix_format_mplane *pix = &line->video_out.active_fmt.fmt.pix_mp;
	struct camss_buffer *held[8];
	struct camss_buffer *pending;
	unsigned int stride = pix->plane_fmt[0].bytesperline;
	unsigned int width = pix->width;
	unsigned int height = pix->height;
	int n = 0, i;

	if (!stride || !width || !height) {
		dev_info(vfe->camss->dev, "dagu front sentinel no format\n");
		return;
	}
	if (output->buf[0])
		held[n++] = output->buf[0];
	if (output->buf[1] && output->buf[1] != output->buf[0])
		held[n++] = output->buf[1];
	list_for_each_entry(pending, &output->pending_bufs, queue) {
		if (n < 8)
			held[n++] = pending;
	}
	if (!n) {
		dev_info(vfe->camss->dev, "dagu front sentinel none\n");
		return;
	}
	for (i = 0; i < n; i++)
		dagu_front_sentinel_one(vfe, held[i], i, stride, width, height);
}

static void vfe_wm_stop(struct vfe_device *vfe, u8 wm)
{
	if (wm == DISP_Y_WM || wm == DISP_C_WM) {
		if (wm == DISP_Y_WM) {
			dagu_fr_stop(vfe);
			dagu_front_sof_n = 0;
			if (dagu_front_pix && vfe->id == 1) {
				dagu_front_sentinel(vfe);
				dagu_csid_trace_report(vfe->camss->dev);
				dev_info(vfe->camss->dev,
					 "dagu front evt total=%u shown=%u\n",
					 dagu_front_evt_n, dagu_front_evt_shown);
			}
			if (dagu_front_rup_ready) {
				hrtimer_cancel(&dagu_front_rup_timer);
				hrtimer_cancel(&dagu_front_mid_timer);
			}
			dev_info(vfe->camss->dev,
				 "dagu ife%d pix stop irq0=0x%x bus=0x%x viol=0x%x img=0x%x ccif=0x%x ovf=0x%x camif=0x%x/0x%x core=0x%x wm4=0x%x/0x%x wm5=0x%x/0x%x burst5=0x%x incr5=0x%x wm5cfg1=0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + VFE_IRQ_STATUS(0)),
				 readl_relaxed(vfe->base + VFE_BUS_IRQ_STATUS(0)),
				 readl_relaxed(vfe->base + VFE_VIOLATION_STATUS),
				 readl_relaxed(vfe->base + VFE_BUS_IMAGE_SIZE_VIOLATION),
				 readl_relaxed(vfe->base + VFE_BUS_CCIF_VIOLATION),
				 readl_relaxed(vfe->base + VFE_BUS_OVERFLOW_STATUS),
				 readl_relaxed(vfe->base + CAMIF_DEBUG_0),
				 readl_relaxed(vfe->base + CAMIF_DEBUG_1),
				 readl_relaxed(vfe->base + VFE_CORE_CFG_0),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_BURST_LIMIT(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_FRAME_INCR(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_1(DISP_C_WM)));
			dev_info(vfe->camss->dev,
				 "dagu ife%d pix stop as0=0x%x/0x%x as1=0x%x/0x%x as2=0x%x/0x%x as3=0x%x/0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_C_WM)));
			/*
			 * #499 last chroma line starts 336 bytes
			 * before a 4K IOVA and stops at that page
			 * (336+1984=2320). #382 2304 is 256+2048.
			 * #501 stride 2560 leftover 512 → 5066752;
			 * stride 4096 (stride×1979 ≡ 0 mod 4096)
			 * completed 8110080, UV~128, last line full.
			 * Tight 2320 is the last-line 4K stop, not
			 * CLC short 1984. Rear 1920 last line also
			 * straddles; #365 still three complete frames.
			 * Do not ALIGN_UP FRAME_INCR. CAMNOC
			 * (Camera Network-on-Chip，相机片上网络)
			 * qos maxwr read 0; dump fill/err at stop.
			 */
			vfe_480_camnoc_dump(vfe, "stop");
			dev_info(vfe->camss->dev,
				 "dagu ife%d pix stop ds wm6=0x%x/0x%x incr6=0x%x packer6=0x%x stride6=0x%x wm7=0x%x/0x%x incr7=0x%x packer7=0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_DS4_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_DS4_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_FRAME_INCR(DISP_DS4_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_DS4_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_2(DISP_DS4_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_DS16_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(DISP_DS16_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_FRAME_INCR(DISP_DS16_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_DS16_WM)));
			dev_info(vfe->camss->dev,
				 "dagu ife%d pix stop pdpc30 en2e58=0x%x w2e68=0x%x/0x%x r010c=0x%x r9c60=0x%x r9c68=0x%x/0x%x r826c=0x%x/0x%x r8260=0x%x r846c=0x%x/0x%x r8480=0x%x/0x%x r8460=0x%x r8060=0x%x r8068=0x%x/0x%x r8e60=0x%x r8e68=0x%x/0x%x r8660=0x%x r8668=0x%x/0x%x r7e6c=0x%x/0x%x r7e80=0x%x/0x%x r7e60=0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + CLC_PDPC30 + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB),
				 readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 4),
				 readl_relaxed(vfe->base + 0x010c),
				 readl_relaxed(vfe->base + 0x9c60),
				 readl_relaxed(vfe->base + 0x9c68),
				 readl_relaxed(vfe->base + 0x9c6c),
				 readl_relaxed(vfe->base + 0x826c),
				 readl_relaxed(vfe->base + 0x8270),
				 readl_relaxed(vfe->base + 0x8260),
				 readl_relaxed(vfe->base + 0x846c),
				 readl_relaxed(vfe->base + 0x8470),
				 readl_relaxed(vfe->base + 0x8480),
				 readl_relaxed(vfe->base + 0x8484),
				 readl_relaxed(vfe->base + 0x8460),
				 readl_relaxed(vfe->base + 0x8060),
				 readl_relaxed(vfe->base + 0x8068),
				 readl_relaxed(vfe->base + 0x806c),
				 readl_relaxed(vfe->base + 0x8e60),
				 readl_relaxed(vfe->base + 0x8e68),
				 readl_relaxed(vfe->base + 0x8e6c),
				 readl_relaxed(vfe->base + 0x8660),
				 readl_relaxed(vfe->base + 0x8668),
				 readl_relaxed(vfe->base + 0x866c),
				 readl_relaxed(vfe->base + 0x7e6c),
				 readl_relaxed(vfe->base + 0x7e70),
				 readl_relaxed(vfe->base + 0x7e80),
				 readl_relaxed(vfe->base + 0x7e84),
				 readl_relaxed(vfe->base + 0x7e60));
			dev_info(vfe->camss->dev,
				 "dagu ife%d pix stop crop_c=0x%x/0x%x/0x%x/0x%x/0x%x/0x%x cfg1=0x%x mid_y=0x%x/0x%x/0x%x mid_c=0x%x/0x%x/0x%x post_y=0x%x/0x%x/0x%x post_c=0x%x/0x%x/0x%x packer4=0x%x packer5=0x%x dbg=0x%x/0x%x ubwc=0x%x mode4/5=0x%x/0x%x ds4c=0x%x/0x%x en5608=0x%x ds16c=0x%x/0x%x en5e08=0x%x ds64c=0x%x/0x%x en6060=0x%x c6070=0x%x ds64cc=0x%x/0x%x en6260=0x%x c6270=0x%x w5868=0x%x/0x%x w5a68=0x%x/0x%x en5860=0x%x c5870=0x%x en5a60=0x%x c5a70=0x%x w5d04=0x%x/0x%x\n",
				 vfe->id,
				 readl_relaxed(vfe->base + CLC_CROP_C + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_SPARE),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_LINE),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_H_STRIPE),
				 readl_relaxed(vfe->base + CLC_CROP_C + CROP_V_STRIPE),
				 readl_relaxed(vfe->base + VFE_CORE_CFG_1),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_LINE),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_LINE),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_LINE),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CLC_MODULE_CFG),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_PIXEL),
				 readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_LINE),
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_UBWC_STATIC_CTRL),
				 readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_C_WM)),
				 readl_relaxed(vfe->base + 0x5704),
				 readl_relaxed(vfe->base + 0x5704 + 4),
				 readl_relaxed(vfe->base + 0x5608),
				 readl_relaxed(vfe->base + 0x5f04),
				 readl_relaxed(vfe->base + 0x5f04 + 4),
				 readl_relaxed(vfe->base + 0x5e08),
				 readl_relaxed(vfe->base + 0x6068),
				 readl_relaxed(vfe->base + 0x6068 + 4),
				 readl_relaxed(vfe->base + 0x6060),
				 readl_relaxed(vfe->base + 0x6070),
				 readl_relaxed(vfe->base + 0x6268),
				 readl_relaxed(vfe->base + 0x6268 + 4),
				 readl_relaxed(vfe->base + 0x6260),
				 readl_relaxed(vfe->base + 0x6270),
				 readl_relaxed(vfe->base + 0x5868),
				 readl_relaxed(vfe->base + 0x5868 + 4),
				 readl_relaxed(vfe->base + 0x5a68),
				 readl_relaxed(vfe->base + 0x5a68 + 4),
				 readl_relaxed(vfe->base + 0x5860),
				 readl_relaxed(vfe->base + 0x5870),
				 readl_relaxed(vfe->base + 0x5a60),
				 readl_relaxed(vfe->base + 0x5a70),
				 readl_relaxed(vfe->base + 0x5d04),
				 readl_relaxed(vfe->base + 0x5d04 + 4));
		}
		writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(wm));
		if (wm == DISP_Y_WM) {
			writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(DISP_DS4_WM));
			writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(DISP_DS16_WM));
			vfe_480_clc_enable(vfe, CLC_CAMIF, 0);
		}
		return;
	}

	wm = RDI_WM(wm);
	writel_relaxed(0, vfe->base + VFE_BUS_WM_CFG(wm));
}

static void vfe_480_camif_go(struct vfe_device *vfe)
{
	u32 pat;
	u32 cfg;

	if (readl_relaxed(vfe->base + CLC_CAMIF + CLC_MODULE_CFG) & CAMIF_EN)
		return;

	/*
	 * CamX 0x52650c: MODULE = 0x101 | (bayer << 24). Pattern in
	 * CORE_CFG_0 bits 24-25 is DSP_STREAMING, not Bayer.
	 */
	pat = vfe_480_pixel_pattern(
		vfe->line[VFE_LINE_PIX].fmt[MSM_VFE_PAD_SINK].code);
	if (dagu_disp_new && dagu_pattern_override >= 0)
		pat = dagu_pattern_override;
	cfg = CAMIF_EN | CAMIF_IFE_OUT_EN | (pat << CAMIF_PIXEL_PATTERN);
	dagu_ovr_apply(vfe, DAGU_PH_GO);
	vfe_480_clc_enable(vfe, CLC_CAMIF, cfg);
	wmb();
	dagu_fr_start(vfe);
	dev_info(vfe->camss->dev,
		 "dagu ife%d camif go camif=0x%x addr4/5=0x%x/0x%x cfg4/5=0x%x/0x%x as0=0x%x/0x%x as1=0x%x/0x%x as2=0x%x/0x%x as3=0x%x/0x%x wm6/7=0x%x/0x%x\n",
		 vfe->id,
		 readl_relaxed(vfe->base + CLC_CAMIF + CLC_MODULE_CFG),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(6)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_CFG(7)));
	vfe_480_bus_dump(vfe, "go");
}

static void vfe_wm_update(struct vfe_device *vfe, u8 wm, u32 addr,
			  struct vfe_line *line)
{
	u32 cfg;

	if (wm != DISP_Y_WM && wm != DISP_C_WM)
		wm = RDI_WM(wm);
	if (wm == DISP_Y_WM && dagu_ds_mode && dagu_front_pix)
		dagu_front_ds_feed(vfe);
	writel_relaxed(addr, vfe->base + VFE_BUS_WM_IMAGE_ADDR(wm));
	if (dagu_front_pix && dagu_reload_phase == 1 &&
	    (wm == DISP_Y_WM || wm == DISP_C_WM))
		dev_info(vfe->camss->dev,
			 "dagu front reload wm=%u wrote=0x%x read=0x%x\n",
			 wm, addr,
			 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(wm)));
	if (wm != DISP_Y_WM && wm != DISP_C_WM)
		return;
	/*
	 * CAF cam_vfe_bus_ver3_update_wm every frame: image_cfg_0,
	 * frame_incr, cfg=en_cfg (0x1). ADDR-only (#501/#504) left
	 * as3 with the next IOVA and as0 on the first 8110080.
	 * First call still does sidecar then EN. Do not ALIGN_UP.
	 * Do not rewrite UBWC sidecar on later frames.
	 */
	cfg = readl_relaxed(vfe->base + VFE_BUS_WM_CFG(wm));
	if (cfg & (1 << WM_CFG_EN)) {
		u32 cfg0 = readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
		u32 incr = readl_relaxed(vfe->base + VFE_BUS_WM_FRAME_INCR(wm));

		writel_relaxed(cfg0, vfe->base + VFE_BUS_WM_IMAGE_CFG_0(wm));
		writel_relaxed(incr, vfe->base + VFE_BUS_WM_FRAME_INCR(wm));
		wmb();
		writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
			       vfe->base + VFE_BUS_WM_CFG(wm));
		dev_info_ratelimited(vfe->camss->dev,
				     "dagu ife%d pix wm_update en-reload wm=%u addr=0x%x cfg0=0x%x incr=0x%x\n",
				     vfe->id, wm, addr, cfg0, incr);
		return;
	}
	vfe_480_wm_sidecar_linear(vfe, wm);
	wmb();
	writel_relaxed(1 << WM_CFG_EN | MODE_QCOM_PLAIN << WM_CFG_MODE,
		       vfe->base + VFE_BUS_WM_CFG(wm));
}

/*
 * 2026-10-24 device: reloading the same front CAMIF crop
 * 0xa1f0000/0x2df0000 plus skip/period on the buf_done RUP logged
 * "camif rearm" and still left /tmp/pix.nv12 at 8110080, one
 * COMP_DONE, camif debug 0x2e00a20. Do not put that reload back.
 * Do not write crop 0. Do not write CAMIF EN.
 * Holding the front buf_done RUP until CAMIF EOF logged
 * "rup-at-eof cmd=0x41" and still left 8110080, one COMP_DONE,
 * second SOF dbg0=0x2e00a20. Do not hold that RUP.
 * Front CDM packet 1 demosaic 0x3868 = 0x06a90400 / 0x820
 * logged "demosaic steady" on the buf_done RUP and still left
 * 8110080, one COMP_DONE, second SOF dbg0=0x2e00a20.
 * Do not put that steady pair back.
 * GIC bank flip with the packet-0 0x3468 blob was falsified.
 * Packet-1 blob (starts 0x07c107c1), bank left at 0, logged
 * "gic steady" and still left 8110080, one COMP_DONE, second
 * SOF dbg0=0x2e00a20. Do not put that blob back.
 * Android writes 0x2660 = 0x02000101 in every CDM packet.
 * Rewriting the live 0x2000101 on the buf_done RUP, without
 * clearing it, logged "camif cmd rewrite" and still left
 * 8110080, one COMP_DONE, second SOF dbg0=0x2e00a20.
 * Do not rewrite that word. Do not write 0. Do not pulse EN.
 *
 * Front CDM packets after the first write 0x34 = 0x41 then 0x34 = 0x4.
 * Pulsing that 0x4 after the PIX 0x41 on the 2592x1952 sink logged
 * "front rup tail 0x4 after 0x41" once, on the only COMP_DONE.
 * /tmp/pix.nv12 stayed 8110080. camif irq1 stayed 0x1 0xc 0x2 0x1.
 * Stop stayed dbg0=0x2e00a20, as3 unconsumed. Do not write 0x4 again.
 * Do not OR it into 0x45.
 */
/*
 * Rewriting front MNDS V, CAMIF crop/epoch and Demux AHB before
 * every PIX 0x41 logged "dagu front shadow refresh" on the init
 * RUPs and on the COMP_DONE RUP. Still one 8110080, no second
 * epoch. Do not refresh that shadow again. Do not write 0x4.
 */
static void vfe_reg_update(struct vfe_device *vfe, enum vfe_line_id line_id)
{
	if (line_id == VFE_LINE_PIX) {
		vfe->reg_update |= REG_UPDATE_PIX;
		if (dagu_front_pix && (dagu_rup_mode & 1) && dagu_in_comp_done) {
			dagu_rup_pending = true;
			return;
		}
		wmb();
		writel_relaxed(vfe->reg_update, vfe->base + VFE_REG_UPDATE_CMD);
		if (dagu_front_pix && dagu_reload_phase == 1) {
			dev_info(vfe->camss->dev,
				 "dagu front reload rup wrote=0x%x read=0x%x\n",
				 vfe->reg_update,
				 readl_relaxed(vfe->base + VFE_REG_UPDATE_CMD));
			dagu_reload_phase = 2;
		}
		return;
	}

	vfe->reg_update |= REG_UPDATE_RDI(vfe, line_id);
	writel_relaxed(vfe->reg_update, vfe->base + VFE_REG_UPDATE_CMD);
}

static inline void vfe_reg_update_clear(struct vfe_device *vfe,
					enum vfe_line_id line_id)
{
	if (line_id == VFE_LINE_PIX)
		vfe->reg_update &= ~REG_UPDATE_PIX;
	else
		vfe->reg_update &= ~REG_UPDATE_RDI(vfe, line_id);
}

static void vfe_enable_irq(struct vfe_device *vfe)
{
	int i;
	u32 bus_irq_mask = 0;

	if (!vfe->stream_count)
		writel(IRQ_MASK_0_RESET_ACK | IRQ_MASK_0_BUS_TOP_IRQ |
		       IRQ_MASK_0_PIX_OVERFLOW,
		       vfe->base + VFE_IRQ_MASK(0));

	if (!vfe_is_lite(vfe))
		writel(IRQ_MASK_1_CAMIF, vfe->base + VFE_IRQ_MASK(1));

	for (i = 0; i < MAX_VFE_OUTPUT_LINES; i++) {
		/* Enable IRQ for newly added lines, but also keep already running lines's IRQ */
		if (vfe->line[i].output.state == VFE_OUTPUT_RESERVED ||
		    vfe->line[i].output.state == VFE_OUTPUT_ON) {
			if (i == VFE_LINE_PIX && !vfe_is_lite(vfe))
				bus_irq_mask |= BUS_IRQ_MASK_0_PIX_RUP |
						BUS_IRQ_MASK_0_COMP_DONE(vfe,
									 DISP_COMP_GROUP);
			else
				bus_irq_mask |= BUS_IRQ_MASK_0_RDI_RUP(vfe, i)
					| BUS_IRQ_MASK_0_COMP_DONE(vfe, RDI_COMP_GROUP(i));
			}
	}

	if (vfe->res->line_num > VFE_LINE_PIX && !vfe_is_lite(vfe))
		bus_irq_mask |= BUS_IRQ_MASK_0_PIX_RUP |
				BUS_IRQ_MASK_0_COMP_DONE(vfe, DISP_COMP_GROUP);

	writel(bus_irq_mask, vfe->base + VFE_BUS_IRQ_MASK(0));
	dagu_front_irq_mask(vfe);
}

static void vfe_isr_reg_update(struct vfe_device *vfe, enum vfe_line_id line_id);

/*
 * vfe_isr - VFE module interrupt handler
 * @irq: Interrupt line
 * @dev: VFE device
 *
 * Return IRQ_HANDLED on success
 */
static enum hrtimer_restart dagu_front_mid_fn(struct hrtimer *timer)
{
	struct vfe_device *vfe = dagu_front_rup_vfe;

	(void)timer;
	if (!vfe || !vfe->base)
		return HRTIMER_NORESTART;
	dev_info(vfe->camss->dev,
		 "dagu front mid n=%d dbg0=0x%x dbg1=0x%x hw=0x%x wmd4=0x%x wmd5=0x%x wmd6=0x%x wmd7=0x%x as2=0x%x/0x%x viol=0x%x img=0x%x irq0=0x%x bus=0x%x cmd=0x%x\n",
		 dagu_mid_n,
		 readl_relaxed(vfe->base + CAMIF_DEBUG_0),
		 readl_relaxed(vfe->base + CLC_CAMIF + CLC_CAMIF_DEBUG_1),
		 readl_relaxed(vfe->base + CLC_CAMIF + CLC_HW_STATUS),
		 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_DS4_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_DS16_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_Y_WM)),
		 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_C_WM)),
		 readl_relaxed(vfe->base + VFE_VIOLATION_STATUS),
		 readl_relaxed(vfe->base + VFE_BUS_IMAGE_SIZE_VIOLATION),
		 readl_relaxed(vfe->base + VFE_IRQ_STATUS(0)),
		 readl_relaxed(vfe->base + VFE_BUS_IRQ_STATUS(0)),
		 readl_relaxed(vfe->base + 0x2660));
	if (++dagu_mid_n == 1) {
		hrtimer_forward_now(timer, ms_to_ktime(2));
		return HRTIMER_RESTART;
	}
	return HRTIMER_NORESTART;
}

static irqreturn_t vfe_isr(int irq, void *dev)
{
	struct vfe_device *vfe = dev;
	u32 status;
	int i;

	status = readl_relaxed(vfe->base + VFE_IRQ_STATUS(0));
	if (dagu_front_pix && vfe->id == 1) {
		u32 status1 = readl_relaxed(vfe->base + VFE_IRQ_STATUS(1));
		u32 bus = readl_relaxed(vfe->base + VFE_BUS_IRQ_STATUS(0));

		dagu_front_evt_n++;
		if (dagu_front_evt_shown < 96) {
			dagu_front_evt_shown++;
			dev_info(vfe->camss->dev,
				 "dagu front evt us=%llu n=%u status0=0x%x status1=0x%x bus=0x%x dbg0=0x%x dbg1=0x%x wm4=0x%x wmd4=0x%x wmd5=0x%x as2=0x%x/0x%x hw=0x%x img=0x%x\n",
				 ktime_get_ns() / 1000, dagu_front_evt_n, status, status1, bus,
				 readl_relaxed(vfe->base + CAMIF_DEBUG_0),
				 readl_relaxed(vfe->base + CAMIF_DEBUG_1),
				 readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_C_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_Y_WM)),
				 readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_C_WM)),
				 readl_relaxed(vfe->base + CLC_CAMIF + CLC_HW_STATUS),
				 readl_relaxed(vfe->base + VFE_BUS_IMAGE_SIZE_VIOLATION));
		}
	}
	if (dagu_front_pix &&
	    (status & (BIT(31) | BIT(29) | BIT(25) | BIT(12) | BIT(11)))) {
		static int top_n;

		if (top_n < 6) {
			top_n++;
			dev_info(vfe->camss->dev, "dagu front top irq0=0x%x\n",
				 status);
		}
	}
	writel_relaxed(status, vfe->base + VFE_IRQ_CLEAR(0));

	if (!vfe_is_lite(vfe)) {
		u32 status1 = readl_relaxed(vfe->base + VFE_IRQ_STATUS(1));

		writel_relaxed(status1, vfe->base + VFE_IRQ_CLEAR(1));
		if (status1 & IRQ_MASK_1_CAMIF)
			dev_info_ratelimited(vfe->camss->dev,
					     "dagu ife%d camif irq1=0x%x dbg0=0x%x dbg1=0x%x hw=0x%x mnds=0x%x wmd=0x%x/0x%x\n",
					     vfe->id, status1,
					     readl_relaxed(vfe->base + CAMIF_DEBUG_0),
					     readl_relaxed(vfe->base + CLC_CAMIF + CLC_CAMIF_DEBUG_1),
					     readl_relaxed(vfe->base + CLC_CAMIF + CLC_HW_STATUS),
					     readl_relaxed(vfe->base + CLC_MNDS_Y + MNDS_SPARE),
					     readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
					     readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_Y_WM)));
		if ((status1 & BIT(1)) && dagu_front_pix && vfe->id == 1)
			dagu_ovr_apply(vfe, DAGU_PH_EOF);
		if ((status1 & BIT(0)) && dagu_front_pix && vfe->id == 1)
			dagu_ovr_apply(vfe, DAGU_PH_SOF);
		if ((status1 & BIT(0)) && vfe->id == 1)
			dagu_prog_apply(vfe, true);
		if ((status1 & BIT(1)) && dagu_front_pix) {
			if (!dagu_front_rup_ready) {
				hrtimer_setup(&dagu_front_rup_timer, dagu_front_rup_fn,
					      CLOCK_MONOTONIC, HRTIMER_MODE_REL);
				hrtimer_setup(&dagu_front_mid_timer, dagu_front_mid_fn,
					      CLOCK_MONOTONIC, HRTIMER_MODE_REL);
				dagu_front_rup_ready = true;
			}
			dagu_front_rup_vfe = vfe;
			if (dagu_rup_pending) {
				dagu_rup_pending = false;
				wmb();
				writel_relaxed(vfe->reg_update,
					       vfe->base + VFE_REG_UPDATE_CMD);
				dev_info(vfe->camss->dev,
					 "dagu front eof rup wrote=0x%x\n",
					 vfe->reg_update);
			}
			if (dagu_wm5_rearm) {
				u32 d0 = readl_relaxed(vfe->base +
						       VFE_BUS_WM_DEBUG(DISP_C_WM));
				u32 cfg0 = readl_relaxed(vfe->base +
							 VFE_BUS_WM_IMAGE_CFG_0(DISP_C_WM));
				u32 incr = readl_relaxed(vfe->base +
							 VFE_BUS_WM_FRAME_INCR(DISP_C_WM));

				writel_relaxed(cfg0, vfe->base +
					       VFE_BUS_WM_IMAGE_CFG_0(DISP_C_WM));
				writel_relaxed(incr, vfe->base +
					       VFE_BUS_WM_FRAME_INCR(DISP_C_WM));
				wmb();
				writel_relaxed(1 << WM_CFG_EN |
					       MODE_QCOM_PLAIN << WM_CFG_MODE,
					       vfe->base + VFE_BUS_WM_CFG(DISP_C_WM));
				dev_info(vfe->camss->dev,
					 "dagu front wm5 rearm dbg 0x%x -> 0x%x\n", d0,
					 readl_relaxed(vfe->base +
						       VFE_BUS_WM_DEBUG(DISP_C_WM)));
			}
			if (!(dagu_rup_mode & 2))
				hrtimer_start(&dagu_front_rup_timer, ms_to_ktime(16),
					      HRTIMER_MODE_REL);
		}
		if ((status1 & BIT(0)) && dagu_front_pix) {
			dagu_front_sof_n++;
			if (dagu_front_sof_n == 2 && dagu_front_rup_ready) {
				dagu_mid_n = 0;
				hrtimer_start(&dagu_front_mid_timer, ms_to_ktime(1),
					      HRTIMER_MODE_REL);
			}
		}
	}

	writel_relaxed(IRQ_CMD_GLOBAL_CLEAR, vfe->base + VFE_IRQ_CMD);

	/*
	 * #391: PIXEL PIPE OVERFLOW latches the Titan 480 pipe.
	 * CAF error_irq_mask0 0x82000200 includes bit31 so they
	 * recover, not halt-and-dump. Clear BUS overflow and run
	 * COMP_DONE before the dump so the last 1984 UV and the
	 * next SOF can finish. #389 epoch and #390 EARLY_EOF
	 * stuck, still line=736 4591616. #391 ovf recover stuck
	 * on #405: irq0=0x80000000 bus=0x0 — PIXEL PIPE is TOP,
	 * not BUS, still 4591616. Do not crop last. Do not retry
	 * EARLY_EOF bit29. Do not treat BUS overflow clear as
	 * TOP recover.
	 */
	if (status & IRQ_MASK_0_PIX_OVERFLOW) {
		u32 bus = readl_relaxed(vfe->base + VFE_BUS_IRQ_STATUS(0));

		writel_relaxed(1, vfe->base + VFE_BUS_OVERFLOW_STATUS_CLEAR);
		wmb();
		/*
		 * #393 overflow buf_done on #407: 9183232 = 2*4591616,
		 * chunk1 Y avg 0.1 UV 0, camif irq1 still 0x1 0xc 0x2,
		 * one PIXEL PIPE OVERFLOW. buf_done retired an empty
		 * pending WM, not a second SOF. #395 CAMIF EOF buf_done
		 * on #409: eof_buf_done irq1=0x2 bus=0x0, still 9183232
		 * chunk1 Y avg 0.1 UV 0.2, irq1 0x1 0xc 0x2 0x1, one
		 * EOF. Same empty pending WM without overflow. Do not
		 * retry overflow buf_done. Do not retry CAMIF EOF
		 * buf_done. Do not retry CAMIF EN pulse. #392 pulse
		 * stuck camif=0x2000101 still 4591616. Do not crop
		 * last. Do not retry EARLY_EOF.
		 */
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d ovf recover irq0=0x%x bus=0x%x\n",
				    vfe->id, status, bus);
	}

	if (status & IRQ_MASK_0_RESET_ACK)
		vfe_isr_reset_ack(vfe);

	if (status & IRQ_MASK_0_BUS_TOP_IRQ) {
		u32 bus = readl_relaxed(vfe->base + VFE_BUS_IRQ_STATUS(0));

		writel_relaxed(bus, vfe->base + VFE_BUS_IRQ_CLEAR(0));
		writel_relaxed(1, vfe->base + VFE_BUS_IRQ_CLEAR_GLOBAL);

		for (i = 0; i < MAX_VFE_OUTPUT_LINES; i++) {
			if (i == VFE_LINE_PIX)
				continue;
			if (bus & BUS_IRQ_MASK_0_RDI_RUP(vfe, i))
				vfe_isr_reg_update(vfe, i);
		}

		if (!vfe_is_lite(vfe) && (bus & BUS_IRQ_MASK_0_PIX_RUP))
			vfe_isr_reg_update(vfe, VFE_LINE_PIX);

		if (!vfe_is_lite(vfe) &&
		    (bus & BUS_IRQ_MASK_0_COMP_DONE(vfe, DISP_COMP_GROUP))) {
			dev_info_ratelimited(vfe->camss->dev,
					     "dagu ife%d pix COMP_DONE bus=0x%x as0=0x%x/0x%x as3=0x%x/0x%x\n",
					     vfe->id, bus,
					     readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_Y_WM)),
					     readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_C_WM)),
					     readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_Y_WM)),
					     readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_C_WM)));
			vfe_isr_reg_update(vfe, VFE_LINE_PIX);
			if (dagu_front_pix && vfe->id == 1 && dagu_reload_phase == 0)
				dagu_reload_phase = 1;
			dagu_in_comp_done = true;
			vfe_buf_done(vfe, DISP_Y_WM);
			dagu_in_comp_done = false;
			if (dagu_front_pix && vfe->id == 1 && dagu_reload_phase == 1) {
				dev_info(vfe->camss->dev, "dagu front reload none\n");
				dagu_reload_phase = 2;
			}
		}

		for (i = 0; i < MSM_VFE_IMAGE_MASTERS_NUM; i++) {
			if (bus & BUS_IRQ_MASK_0_COMP_DONE(vfe, RDI_COMP_GROUP(i)))
				vfe_buf_done(vfe, i);
		}
	}

	if (status & IRQ_MASK_0_PIX_OVERFLOW) {
		u32 viol = readl_relaxed(vfe->base + VFE_VIOLATION_STATUS);
		u32 camif0 = readl_relaxed(vfe->base + CAMIF_DEBUG_0);

		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d PIXEL PIPE OVERFLOW irq0=0x%x viol=0x%x viol_id=%u (%s) camif=0x%x pix=%u line=%u dbg=0x%x/0x%x/0x%x/0x%x mnds_c=0x%x/0x%x/0x%x/0x%x\n",
				    vfe->id, status, viol, viol & VIOL_ID_MASK,
				    vfe_480_viol_name(viol & VIOL_ID_MASK),
				    camif0, camif0 & 0xffff, camif0 >> 16,
				    readl_relaxed(vfe->base + VFE_TOP_DEBUG_0),
				    readl_relaxed(vfe->base + VFE_TOP_DEBUG_0 + 4),
				    readl_relaxed(vfe->base + VFE_TOP_DEBUG_0 + 8),
				    readl_relaxed(vfe->base + VFE_TOP_DEBUG_0 + 12),
				    readl_relaxed(vfe->base + CLC_MNDS_C + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_SIZE),
				    readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_H_PHASE),
				    readl_relaxed(vfe->base + CLC_MNDS_C + MNDS_V_PAD));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow clcstat camif=0x%x bls=0x%x demux=0x%x demo=0x%x crop=0x%x mnds=0x%x post=0x%x hdr=0x%x crop64=0x%x dbg1=0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_CAMIF + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_DEMUX_BASE + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_CROP + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_MNDS_Y + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CLC_HW_STATUS),
				    readl_relaxed(vfe->base + CLC_HDR + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_CROP + CROP_SPARE),
				    readl_relaxed(vfe->base + CLC_CAMIF + CLC_CAMIF_DEBUG_1));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow ped 2c5c=0x%x 2c60=0x%x 2c68=0x%x/0x%x/0x%x/0x%x/0x%x dmi=0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_WIN),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB + 4),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB + 8),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB + 12),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + PEDESTAL_AHB + 16),
				    readl_relaxed(vfe->base + CLC_PEDESTAL + CLC_DMI_CFG));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow pdpc30 2e60=0x%x 2e68=0x%x/0x%x/0x%x 2e7c=0x%x/0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_PDPC30 + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 4),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 8),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 20),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 24),
				    readl_relaxed(vfe->base + CLC_PDPC30 + PDPC30_AHB + 28));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow demuxwin 3058=0x%x 3068=0x%x/0x%x/0x%x 307c=0x%x/0x%x 3090=0x%x 30ac=0x%x/0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + 0x3058),
				    readl_relaxed(vfe->base + 0x3068),
				    readl_relaxed(vfe->base + 0x306c),
				    readl_relaxed(vfe->base + 0x3070),
				    readl_relaxed(vfe->base + 0x307c),
				    readl_relaxed(vfe->base + 0x3080),
				    readl_relaxed(vfe->base + CLC_DEMUX),
				    readl_relaxed(vfe->base + CLC_DEMUX_TAIL_CROP +
						  CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_DEMUX_TAIL_CROP +
						  CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_DEMUX_TAIL_CROP +
						  CROP_LINE));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow lin 2a60=0x%x 2a64=0x%x 2a68=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_LIN + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_LIN + 0x64),
				    readl_relaxed(vfe->base + CLC_LIN + 0x68),
				    readl_relaxed(vfe->base + CLC_LIN + 0x6c));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow rcwin pre=0x%x/0x%x midy=0x%x/0x%x midc=0x%x/0x%x posty=0x%x/0x%x postc=0x%x/0x%x outy=0x%x/0x%x outc=0x%x/0x%x ds411=0x%x/0x%x/0x%x/0x%x bls=0x%x/0x%x/0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_RNDCLAMP + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_Y + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_MID_C + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_Y + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_POST_C + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_OUT_Y + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_OUT_Y + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_OUT_C + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_RNDCLAMP_OUT_C + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_DS411_Y_CROP),
				    readl_relaxed(vfe->base + CLC_DS411_Y_CROP + 4),
				    readl_relaxed(vfe->base + CLC_DS411_C_CROP),
				    readl_relaxed(vfe->base + CLC_DS411_C_CROP + 4),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CROP_PIXEL),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CROP_LINE),
				    readl_relaxed(vfe->base + CLC_PREPROCESS + CLC_DMI_CFG));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow lsc40 3660=0x%x 3668=0x%x/0x%x/0x%x/0x%x/0x%x cst=0x%x/0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_GTM + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB + 4),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB + 8),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB + 12),
				    readl_relaxed(vfe->base + CLC_GTM + LSC_AHB + 16),
				    readl_relaxed(vfe->base + CLC_CST + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_CST_MATRIX),
				    readl_relaxed(vfe->base + CLC_CST_MATRIX + 4));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow wb13 3868=0x%x/0x%x/0x%x/0x%x interp=0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 4),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 8),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC + DEMOSAIC_WB + 12),
				    readl_relaxed(vfe->base + CLC_DEMOSAIC_INTERP));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow abf40 3260=0x%x 3268=0x%x/0x%x 3270=0x%x/0x%x 3460=0x%x 3468=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + CLC_ABF + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_ABF + 0x68),
				    readl_relaxed(vfe->base + CLC_ABF + 0x6c),
				    readl_relaxed(vfe->base + CLC_ABF + ABF_REGION),
				    readl_relaxed(vfe->base + CLC_ABF + ABF_REGION + 4),
				    readl_relaxed(vfe->base + CLC_GIC + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_GIC + 0x68),
				    readl_relaxed(vfe->base + CLC_GIC + 0x6c));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow packer4=0x%x packer5=0x%x dbg=0x%x/0x%x ubwc=0x%x mode4/5=0x%x/0x%x addr4/5=0x%x/0x%x cfg4/5=0x%x/0x%x camif=0x%x wm6/7=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_UBWC_STATIC_CTRL),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_MODE_CFG(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_CFG(DISP_C_WM)),
				    readl_relaxed(vfe->base + CLC_CAMIF + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + VFE_BUS_WM_CFG(6)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_CFG(7)));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow as0=0x%x/0x%x as1=0x%x/0x%x as2=0x%x/0x%x as3=0x%x/0x%x meta4/5=0x%x/0x%x pwr_iso=0x%x cache4=0x%x bwlim4/5=0x%x/0x%x fh4=0x%x dbg1=0x%x/0x%x cc=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS1(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_META_ADDR(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_META_ADDR(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_PWR_ISO_CFG),
				    readl_relaxed(vfe->base + VFE_BUS_WM_SYSTEM_CACHE_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_BW_LIMIT(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_UBWC_BW_LIMIT(DISP_C_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_FRAME_HEADER_CFG(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_C_WM)),
				    readl_relaxed(vfe->base + CLC_CC + CLC_MODULE_CFG),
				    readl_relaxed(vfe->base + CLC_CC + CLC_CC_MATRIX));
		dev_err_ratelimited(vfe->camss->dev,
				    "dagu ife%d overflow ds as0=0x%x/0x%x as2=0x%x/0x%x as3=0x%x/0x%x addr6/7=0x%x/0x%x packer6/7=0x%x/0x%x dbg1=0x%x/0x%x\n",
				    vfe->id,
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS0(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS2(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_ADDR_STATUS3(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_IMAGE_ADDR(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_DS4_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_PACKER_CFG(DISP_DS16_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_Y_WM)),
				    readl_relaxed(vfe->base + VFE_BUS_WM_DEBUG_1(DISP_C_WM)));
		vfe_480_bus_dump(vfe, "ovf");
		vfe_480_camnoc_dump(vfe, "ovf");
	}

	return IRQ_HANDLED;
}

/*
 * vfe_halt - Trigger halt on VFE module and wait to complete
 * @vfe: VFE device
 *
 * Return 0 on success or a negative error code otherwise
 */
static int vfe_halt(struct vfe_device *vfe)
{
	/* rely on vfe_disable_output() to stop the VFE */
	return 0;
}

/*
 * vfe_isr_reg_update - Process reg update interrupt
 * @vfe: VFE Device
 * @line_id: VFE line
 */
static void vfe_isr_reg_update(struct vfe_device *vfe, enum vfe_line_id line_id)
{
	struct vfe_output *output;
	unsigned long flags;

	spin_lock_irqsave(&vfe->output_lock, flags);
	vfe_reg_update_clear(vfe, line_id);

	output = &vfe->line[line_id].output;

	if (output->wait_reg_update) {
		output->wait_reg_update = 0;
		complete(&output->reg_update);
	}

	spin_unlock_irqrestore(&vfe->output_lock, flags);
}

static const struct camss_video_ops vfe_video_ops_480 = {
	.queue_buffer = vfe_queue_buffer_v2,
	.flush_buffers = vfe_flush_buffers,
};

static void vfe_subdev_init(struct device *dev, struct vfe_device *vfe)
{
	vfe->video_ops = vfe_video_ops_480;
	vfe_480_ds_alloc(dev);
	dagu_dbg_init();
	if (!vfe_480_camnoc) {
		vfe_480_camnoc = devm_ioremap(dev, CAMNOC_PHYS, CAMNOC_SIZE);
		if (!vfe_480_camnoc)
			dev_err(dev, "dagu CAMNOC 0x%lx ioremap failed\n",
				(unsigned long)CAMNOC_PHYS);
	}
}

static void vfe_isr_read(struct vfe_device *vfe, u32 *value0, u32 *value1)
{
	/* nop */
}

static void vfe_violation_read(struct vfe_device *vfe)
{
	/* nop */
}

static void vfe_buf_done_480(struct vfe_device *vfe, int port_id)
{
	/* nop */
}

const struct vfe_hw_ops vfe_ops_480 = {
	.enable_irq = vfe_enable_irq,
	.global_reset = vfe_global_reset,
	.hw_version = vfe_hw_version,
	.isr = vfe_isr,
	.isr_read = vfe_isr_read,
	.reg_update = vfe_reg_update,
	.reg_update_clear = vfe_reg_update_clear,
	.pm_domain_off = vfe_pm_domain_off,
	.pm_domain_on = vfe_pm_domain_on,
	.subdev_init = vfe_subdev_init,
	.vfe_disable = vfe_disable,
	.vfe_enable = vfe_enable_v2,
	.vfe_halt = vfe_halt,
	.violation_read = vfe_violation_read,
	.vfe_wm_start = vfe_wm_start,
	.vfe_wm_stop = vfe_wm_stop,
	.vfe_buf_done = vfe_buf_done_480,
	.vfe_wm_update = vfe_wm_update,
	.pix_go = vfe_480_camif_go,
};
