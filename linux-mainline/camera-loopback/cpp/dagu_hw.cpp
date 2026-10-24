// SPDX-License-Identifier: GPL-2.0-only
/*
 * dagu hardware camera path: sensor -> CSIPHY -> CSID1 IPP -> IFE1 PIX
 * (Titan 480 demosaic, CCM, gamma, CSC, MNDS) -> linear NV12 -> YUYV
 * loopback. No CPU demosaic. 3A runs here on the hardware NV12:
 *
 *   AE   centre-weighted luma, 50 Hz flicker-safe exposure, then
 *        analogue gain, then IFE digital gain (WB gains are Q10).
 *   AWB  grey-world on linearised RGB with saturation/clip rejection,
 *        clamped to a daylight..tungsten range, damped.
 *
 * IQ is programmed through /sys/kernel/debug/dagu_ife1/{prog_*,live}
 * (see camss-vfe-480.c): prog_* at stream start, live per 3A update.
 */
#define _GNU_SOURCE
#include "dagu_cam.h"
#include "dagu_lsc_imx596.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <linux/media.h>
#include <linux/v4l2-subdev.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <pthread.h>
#include <string>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace {

void hlog(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "dagu-camera-hw: ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

/* ---------------------------------------------------------------- media */

struct Ent {
	uint32_t id;
	std::string name;
	uint32_t major, minor;
	uint16_t pads, links;
};

struct Media {
	int fd = -1;
	std::vector<Ent> ents;

	bool open_dev(const char *path)
	{
		fd = ::open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			return false;
		media_entity_desc d{};
		for (d.id = MEDIA_ENT_ID_FLAG_NEXT;
		     xioctl(fd, MEDIA_IOC_ENUM_ENTITIES, &d) == 0;
		     d.id |= MEDIA_ENT_ID_FLAG_NEXT) {
			ents.push_back({ d.id, d.name, d.dev.major, d.dev.minor,
					 d.pads, d.links });
		}
		return !ents.empty();
	}
	const Ent *find(const std::string &prefix) const
	{
		for (auto &e : ents)
			if (e.name.compare(0, prefix.size(), prefix) == 0)
				return &e;
		return nullptr;
	}
	static std::string devnode(const Ent *e)
	{
		char p[96], buf[256];
		snprintf(p, sizeof(p), "/sys/dev/char/%u:%u/uevent", e->major, e->minor);
		FILE *f = fopen(p, "r");
		if (!f)
			return "";
		std::string out;
		while (fgets(buf, sizeof(buf), f)) {
			if (!strncmp(buf, "DEVNAME=", 8)) {
				out = std::string("/dev/") + (buf + 8);
				while (!out.empty() && (out.back() == '\n'))
					out.pop_back();
			}
		}
		fclose(f);
		return out;
	}
	/* media-ctl -r: disable every mutable enabled link. */
	void reset()
	{
		for (auto &e : ents) {
			std::vector<media_pad_desc> pads(e.pads);
			std::vector<media_link_desc> links(e.links);
			media_links_enum le{};
			le.entity = e.id;
			le.pads = pads.data();
			le.links = links.data();
			if (xioctl(fd, MEDIA_IOC_ENUM_LINKS, &le) < 0)
				continue;
			for (auto &l : links) {
				if (l.source.entity != e.id)
					continue;
				if ((l.flags & MEDIA_LNK_FL_IMMUTABLE) ||
				    !(l.flags & MEDIA_LNK_FL_ENABLED))
					continue;
				l.flags &= ~MEDIA_LNK_FL_ENABLED;
				xioctl(fd, MEDIA_IOC_SETUP_LINK, &l);
			}
		}
	}
	bool link(const Ent *src, unsigned sp, const Ent *sink, unsigned kp)
	{
		media_link_desc l{};
		l.source.entity = src->id;
		l.source.index = sp;
		l.sink.entity = sink->id;
		l.sink.index = kp;
		l.flags = MEDIA_LNK_FL_ENABLED;
		if (xioctl(fd, MEDIA_IOC_SETUP_LINK, &l) < 0) {
			hlog("link %s:%u -> %s:%u: %m", src->name.c_str(), sp,
			     sink->name.c_str(), kp);
			return false;
		}
		return true;
	}
};

bool subdev_fmt(const std::string &node, unsigned pad, uint32_t code,
		unsigned w, unsigned h)
{
	int fd = ::open(node.c_str(), O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return false;
	v4l2_subdev_format f{};
	f.which = V4L2_SUBDEV_FORMAT_ACTIVE;
	f.pad = pad;
	f.format.code = code;
	f.format.width = w;
	f.format.height = h;
	f.format.field = V4L2_FIELD_NONE;
	f.format.colorspace = V4L2_COLORSPACE_SRGB;
	bool ok = xioctl(fd, VIDIOC_SUBDEV_S_FMT, &f) == 0;
	if (!ok)
		hlog("S_FMT %s pad %u: %m", node.c_str(), pad);
	::close(fd);
	return ok;
}

bool subdev_compose(const std::string &node, unsigned w, unsigned h)
{
	int fd = ::open(node.c_str(), O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return false;
	v4l2_subdev_selection s{};
	s.which = V4L2_SUBDEV_FORMAT_ACTIVE;
	s.pad = 0;
	s.target = V4L2_SEL_TGT_COMPOSE;
	s.r.width = w;
	s.r.height = h;
	bool ok = xioctl(fd, VIDIOC_SUBDEV_S_SELECTION, &s) == 0;
	if (!ok)
		hlog("compose %s: %m", node.c_str());
	::close(fd);
	return ok;
}

bool subdev_get(const std::string &node, uint32_t *code, unsigned *w, unsigned *h)
{
	int fd = ::open(node.c_str(), O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return false;
	v4l2_subdev_format f{};
	f.which = V4L2_SUBDEV_FORMAT_ACTIVE;
	bool ok = xioctl(fd, VIDIOC_SUBDEV_G_FMT, &f) == 0;
	::close(fd);
	if (ok) {
		*code = f.format.code;
		*w = f.format.width;
		*h = f.format.height;
	}
	return ok;
}

/* ------------------------------------------------------------- tuning */

struct Cam {
	bool rear;
	const char *sensor, *phy;
	unsigned out_w, out_h;      /* IFE NV12 (sensor aspect, no crop) */
	unsigned loop_w, loop_h;
	bool hflip, vflip;
	double line_us;             /* line time */
	int exp_min, exp_margin;    /* lines */
	int frame_lines;            /* VTS at 30 fps */
	double again_max;
	double wb_r0, wb_b0;        /* start gains */
	double ccm[9];
};

/* Moderate sensor->sRGB matrices (rows sum to 1). Without a chart the
 * IFE identity CC looks washed out; these restore typical saturation. */
const Cam kFront = {
	false, "imx596", "msm_csiphy4", 1280, 960, 1280, 720, false, true,
	5.29, 1, 22, 6302, 16.0, 1.8, 1.7,
	{ 1.55, -0.40, -0.15, -0.25, 1.45, -0.20, -0.05, -0.55, 1.60 },
};
const Cam kRear = {
	true, "s5kjn1", "msm_csiphy1", 1280, 960, 1280, 720, true, false,
	10.53, 8, 22, 3164, 16.0, 1.8, 1.7,
	{ 1.60, -0.45, -0.15, -0.28, 1.50, -0.22, -0.05, -0.55, 1.60 },
};

std::string prog_common(const Cam &c)
{
	std::string s;
	char b[96];
	auto w = [&](unsigned off, unsigned val) {
		snprintf(b, sizeof(b), "w 0x%x 0x%x\n", off, val);
		s += b;
	};
	/* CCM: HW rows by input channel in G,B,R order, Q7 12-bit. */
	auto q7 = [](double x) { return (unsigned)((int)lround(x * 128) & 0xfff); };
	auto M = [&](int o, int i) { return c.ccm[3 * o + i]; };
	const int in_order[3] = { 1, 2, 0 };
	for (int row = 0; row < 3; row++) {
		int i = in_order[row];
		w(0x3a68 + 8 * row, q7(M(1, i)) | (q7(M(2, i)) << 16));
		w(0x3a6c + 8 * row, q7(M(0, i)));
	}
	/* CST BT.601 limited range for the YUYV webcam contract: Y path is
	 * in 8-bit units after gamma, chroma coefficients Q12. */
	const double ky = 219.0 / 255.0, kc = 224.0 / 255.0;
	struct { double r, g, b; int q, off; } rows[3] = {
		{ 0.299 * ky, 0.587 * ky, 0.114 * ky, 1024, 16 },
		{ -0.168736 * kc, -0.331264 * kc, 0.5 * kc, 4096, 512 },
		{ 0.5 * kc, -0.418688 * kc, -0.081312 * kc, 4096, 512 },
	};
	for (int n = 0; n < 3; n++) {
		auto f = [&](double x) { return (unsigned)((int)lround(x * rows[n].q) & 0x1fff); };
		unsigned base = 0x4068 + 0x10 * n;
		w(base, f(rows[n].g) | (f(rows[n].b) << 16));
		w(base + 4, f(rows[n].r));
		w(base + 8, (unsigned)rows[n].off << 16);
		w(base + 12, 0x03ff0000);
	}
	/* Tone curve: sRGB with a small black clamp and a mild S, stored
	 * in 8-bit output units over 64 segments of the 12-bit input. */
	{
		const double blk = 0.004, k = 0.18;
		unsigned base[65];
		for (int i = 0; i <= 64; i++) {
			double x = std::min(1.0, i * 64 / 4095.0);
			x = std::max(0.0, (x - blk) / (1.0 - blk));
			double y = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055;
			y = y + k * y * (1 - y) * (2 * y - 1) * 2;
			y = std::max(0.0, std::min(1.0, y));
			base[i] = (unsigned)lround(y * 255);
		}
		for (int sel = 1; sel <= 3; sel++) {
			w(0x3e0c, sel);
			w(0x3e08, 0);
			for (int i = 0; i < 64; i++) {
				unsigned d = base[i + 1] > base[i] ? base[i + 1] - base[i] : 0;
				w(0x3e14, (d << 10) | base[i]);
			}
		}
		w(0x3e0c, 0);
		w(0x3e60, 1);
	}
	/* MNDS filter config word the hardware needs on the DISP scaler. */
	w(0x4c64, 0x600);
	w(0x4e64, 0x600);
	if (!c.rear && !getenv("DAGU_HW_NOLSC")) {
		/* LSC40 with the imx596 mesh (LUT 1, 2). */
		/* Entry = G (hi 13 bits) | R-or-B (lo 13 bits), Q10. CamX
		 * calibrated with the BGGR order; the IFE runs this sensor as
		 * RGGB, so R and B swap tables (the G halves are identical). */
		bool swap = !getenv("DAGU_HW_LSC_NOSWAP");
		/* Default: luminance shading only (the G mesh on every channel).
		 * The R/B colour-shading halves left a magenta rim / green
		 * centre on this crop; keep them behind DAGU_HW_LSC_COLOR. */
		bool lum = !getenv("DAGU_HW_LSC_COLOR");
		for (int sel = 1; sel <= 2; sel++) {
			const uint32_t *t = sel == 1 ? dagu_imx596_lsc1 : dagu_imx596_lsc2;
			const uint32_t *o = sel == 1 ? dagu_imx596_lsc2 : dagu_imx596_lsc1;
			w(0x360c, sel);
			w(0x3608, 0);
			for (int i = 0; i < 221; i++)
				w(0x3614, lum ? ((t[i] & ~0x1fffu) | ((t[i] >> 13) & 0x1fff)) :
					   swap ? ((t[i] & ~0x1fffu) | (o[i] & 0x1fff)) : t[i]);
		}
		w(0x360c, 0);
		for (int i = 0; i < 11; i++)
			w(0x3668 + 4 * i, dagu_imx596_lsc_cfg[i]);
		w(0x3658, 0);
		w(0x365c, 0);
		w(0x3660, 0x01002001);
	}
	return s;
}

/* -------------------------------------------------------------- 3A */

struct Ae {
	double exp_us = 20000, again = 1.0, dgain = 1.0;
};

double srgb_to_lin(double v)
{
	return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

struct Hw {
	Cam c;
	int slot;
	std::string loop_dev;
	Media mc;
	std::string sensor_node, video_node;
	int vfd = -1, sfd = -1, live_fd = -1;
	struct Buf { void *p; size_t len; };
	std::vector<Buf> bufs;
	unsigned stride = 0;
	Ae ae;
	double gr = 1.8, gb = 1.7;  /* AWB gains, G = 1 */
	int cur_exp = -1, cur_again = -1;
	float lin8[256];
	unsigned frames = 0;
	std::vector<uint8_t> yuyv;
	pthread_t th{};
};

int again_code(const Hw &h, double g)
{
	if (h.c.rear)
		return std::max(1, std::min(16, (int)floor(g + 1e-6)));
	/* Sony: gain = 1024 / (1024 - code) */
	int code = (int)lround(1024.0 - 1024.0 / g);
	return std::max(0, std::min(960, code));
}

double again_value(const Hw &h, int code)
{
	if (h.c.rear)
		return code;
	return 1024.0 / (1024 - code);
}

void set_ctrl(int fd, uint32_t id, int v)
{
	v4l2_control c{};
	c.id = id;
	c.value = v;
	if (xioctl(fd, VIDIOC_S_CTRL, &c) < 0)
		hlog("S_CTRL 0x%x=%d: %m", id, v);
}

void write_live(Hw &h, const std::string &s)
{
	if (h.live_fd < 0)
		return;
	if (pwrite(h.live_fd, s.data(), s.size(), 0) < 0)
		hlog("live write: %m");
}

/* Distribute a total exposure (us * gain) over shutter, analogue, digital. */
void ae_apply(Hw &h, double total)
{
	const double flicker = 10000.0; /* 50 Hz mains: 10 ms steps */
	double frame_us = (h.c.frame_lines - h.c.exp_margin) * h.c.line_us;
	double min_us = h.c.exp_min * h.c.line_us;
	double exp = std::min(total, frame_us);
	if (exp >= flicker)
		exp = std::max(flicker, floor(exp / flicker) * flicker);
	exp = std::max(exp, min_us);
	double g = total / exp;
	double ag = std::min(std::max(g, 1.0), h.c.again_max);
	int code = again_code(h, ag);
	double agv = again_value(h, code);
	double dg = std::min(std::max(total / (exp * agv), 1.0), 4.0);
	int lines = std::max(h.c.exp_min, (int)lround(exp / h.c.line_us));
	if (lines != h.cur_exp) {
		set_ctrl(h.sfd, V4L2_CID_EXPOSURE, lines);
		h.cur_exp = lines;
	}
	if (code != h.cur_again) {
		set_ctrl(h.sfd, V4L2_CID_ANALOGUE_GAIN, code);
		h.cur_again = code;
	}
	h.ae.exp_us = lines * h.c.line_us;
	h.ae.again = agv;
	h.ae.dgain = dg;
}

void wb_write(Hw &h)
{
	auto q10 = [](double x) {
		return (unsigned)std::max(0L, std::min(0xffffL, lround(x * 1024)));
	};
	double d = h.ae.dgain;
	char b[128];
	snprintf(b, sizeof(b), "w 0x3868 0x%x\nw 0x386c 0x%x\n",
		 (q10(d * h.gb) << 16) | q10(d), q10(d * h.gr));
	write_live(h, b);
}

void run_3a(Hw &h, const uint8_t *y, const uint8_t *uv)
{
	const unsigned W = h.c.out_w, H = h.c.out_h, S = h.stride;
	/* Visible window: the loopback keeps the centre 16:9 band. */
	unsigned y0 = (H - (W * h.c.loop_h / h.c.loop_w)) / 2;
	unsigned y1 = H - y0;
	double sum = 0, wsum = 0, clip = 0, n = 0;
	double R = 0, G = 0, B = 0, an = 0;
	for (unsigned r = y0; r < y1; r += 8) {
		double dy = ((double)r - H / 2.0) / (H / 2.0);
		for (unsigned x = 0; x < W; x += 8) {
			double dx = ((double)x - W / 2.0) / (W / 2.0);
			double wt = 1.0 + 2.0 * std::max(0.0, 1.0 - (dx * dx + dy * dy));
			unsigned Y = y[r * S + x];
			sum += wt * Y;
			wsum += wt;
			n++;
			if (Y >= 235)
				clip++;
			/* limited range YCbCr -> RGB */
			const uint8_t *c = uv + (r / 2) * S + (x & ~1u);
			double yy = (Y - 16) * 255.0 / 219.0;
			double cb = (c[0] - 128) * 255.0 / 224.0;
			double cr = (c[1] - 128) * 255.0 / 224.0;
			double rr = yy + 1.402 * cr, gg = yy - 0.344136 * cb - 0.714136 * cr,
			       bb = yy + 1.772 * cb;
			if (rr < 8 || gg < 8 || bb < 8 || rr > 235 || gg > 235 || bb > 235)
				continue;
			double lr = h.lin8[(int)rr], lg = h.lin8[(int)gg], lb = h.lin8[(int)bb];
			double mx = std::max(lr, std::max(lg, lb)), mn = std::min(lr, std::min(lg, lb));
			if (mx > 4.0 * mn)  /* strongly coloured: not grey evidence */
				continue;
			R += lr;
			G += lg;
			B += lb;
			an++;
		}
	}
	if (!n)
		return;
	double mean = sum / wsum;
	double clip_frac = clip / n;
	/* AE: luma target in the (limited-range, sRGB) output domain. */
	double target = clip_frac > 0.05 ? 95.0 : 110.0;
	double lm = srgb_to_lin(std::max(1.0, mean - 16) / 219.0);
	double lt = srgb_to_lin((target - 16) / 219.0);
	double ratio = lt / std::max(lm, 1e-4);
	ratio = std::max(0.5, std::min(2.0, ratio));
	double total = h.ae.exp_us * h.ae.again * h.ae.dgain;
	/* damped in log domain; settle band avoids hunting */
	if (fabs(log(ratio)) > 0.04)
		total *= pow(ratio, 0.6);
	double tmax = (h.c.frame_lines - h.c.exp_margin) * h.c.line_us * h.c.again_max * 4.0;
	total = std::max(h.c.exp_min * h.c.line_us, std::min(total, tmax));
	ae_apply(h, total);
	/* AWB: grey world on the linear means, damped and clamped. */
	if (an > 200 && G > 0) {
		double tr = h.gr * G / std::max(R, 1e-6);
		double tb = h.gb * G / std::max(B, 1e-6);
		tr = std::max(1.0, std::min(3.2, tr));
		tb = std::max(1.0, std::min(3.2, tb));
		h.gr += 0.25 * (tr - h.gr);
		h.gb += 0.25 * (tb - h.gb);
	}
	wb_write(h);
	if ((h.frames % 90) == 0)
		hlog("%s 3A mean=%.0f clip=%.2f exp=%.1fms again=%.2f dgain=%.2f wb r=%.2f b=%.2f",
		     h.c.sensor, mean, clip_frac, h.ae.exp_us / 1000, h.ae.again,
		     h.ae.dgain, h.gr, h.gb);
}

/* NV12 (out_w x out_h, centre band) -> YUYV loop_w x loop_h with flips. */
void pack(Hw &h, const uint8_t *y, const uint8_t *uv, uint8_t *dst)
{
	const unsigned W = h.c.loop_w, LH = h.c.loop_h, S = h.stride;
	const unsigned y0 = (h.c.out_h - LH) / 2;
	for (unsigned r = 0; r < LH; r++) {
		unsigned sr = y0 + (h.c.vflip ? (LH - 1 - r) : r);
		const uint8_t *ys = y + sr * S;
		const uint8_t *cs = uv + (sr / 2) * S;
		uint8_t *d = dst + r * W * 2;
		if (!h.c.hflip) {
			for (unsigned x = 0; x < W; x += 2) {
				d[0] = ys[x];
				d[1] = cs[x];
				d[2] = ys[x + 1];
				d[3] = cs[x + 1];
				d += 4;
			}
		} else {
			for (unsigned x = 0; x < W; x += 2) {
				unsigned sx = W - 2 - x;
				d[0] = ys[sx + 1];
				d[1] = cs[sx];
				d[2] = ys[sx];
				d[3] = cs[sx + 1];
				d += 4;
			}
		}
	}
}

bool setup(Hw &h)
{
	if (!h.mc.open_dev("/dev/media0"))
		return false;
	const Ent *sen = h.mc.find(h.c.sensor), *phy = h.mc.find(h.c.phy),
		  *csid = h.mc.find("msm_csid1"), *pix = h.mc.find("msm_vfe1_pix"),
		  *vid = h.mc.find("msm_vfe1_video3");
	if (!sen || !phy || !csid || !pix || !vid) {
		hlog("media entities missing");
		return false;
	}
	h.sensor_node = Media::devnode(sen);
	h.video_node = Media::devnode(vid);
	uint32_t code;
	unsigned sw, shh;
	if (!subdev_get(h.sensor_node, &code, &sw, &shh))
		return false;
	h.mc.reset();
	if (!h.mc.link(phy, 1, csid, 0) || !h.mc.link(csid, 4, pix, 0))
		return false;
	std::string pn = Media::devnode(phy), cn = Media::devnode(csid),
		    xn = Media::devnode(pix);
	if (!subdev_fmt(h.sensor_node, 0, code, sw, shh) ||
	    !subdev_fmt(pn, 0, code, sw, shh) || !subdev_fmt(pn, 1, code, sw, shh) ||
	    !subdev_fmt(cn, 0, code, sw, shh) || !subdev_fmt(cn, 4, code, sw, shh) ||
	    !subdev_fmt(xn, 0, code, sw, shh) ||
	    !subdev_compose(xn, h.c.out_w, h.c.out_h) ||
	    !subdev_fmt(xn, 1, MEDIA_BUS_FMT_YUYV8_1_5X8, h.c.out_w, h.c.out_h))
		return false;
	h.sfd = ::open(h.sensor_node.c_str(), O_RDWR | O_CLOEXEC);
	/* IQ program: loaded before STREAMON, applied at the IFE init. */
	{
		std::string path = std::string("/sys/kernel/debug/dagu_ife1/prog_") +
				   (h.c.rear ? "rear" : "front");
		std::string prog = prog_common(h.c);
		int fd = ::open(path.c_str(), O_WRONLY | O_CLOEXEC);
		if (fd < 0 || write(fd, prog.data(), prog.size()) < 0)
			hlog("IQ program %s: %m (driver defaults stay)", path.c_str());
		if (fd >= 0)
			::close(fd);
		h.live_fd = ::open("/sys/kernel/debug/dagu_ife1/live", O_WRONLY | O_CLOEXEC);
	}
	h.vfd = ::open(h.video_node.c_str(), O_RDWR | O_CLOEXEC);
	if (h.vfd < 0)
		return false;
	v4l2_format f{};
	f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	f.fmt.pix_mp.width = h.c.out_w;
	f.fmt.pix_mp.height = h.c.out_h;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.plane_fmt[0].bytesperline = h.c.out_w;
	if (xioctl(h.vfd, VIDIOC_S_FMT, &f) < 0) {
		hlog("S_FMT NV12: %m");
		return false;
	}
	h.stride = f.fmt.pix_mp.plane_fmt[0].bytesperline;
	v4l2_requestbuffers rb{};
	rb.count = 4;
	rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	rb.memory = V4L2_MEMORY_MMAP;
	if (xioctl(h.vfd, VIDIOC_REQBUFS, &rb) < 0 || rb.count < 2)
		return false;
	for (unsigned i = 0; i < rb.count; i++) {
		v4l2_buffer b{};
		v4l2_plane pl{};
		b.type = rb.type;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		b.length = 1;
		b.m.planes = &pl;
		if (xioctl(h.vfd, VIDIOC_QUERYBUF, &b) < 0)
			return false;
		void *p = mmap(nullptr, pl.length, PROT_READ | PROT_WRITE, MAP_SHARED,
			       h.vfd, pl.m.mem_offset);
		if (p == MAP_FAILED)
			return false;
		h.bufs.push_back({ p, pl.length });
		if (xioctl(h.vfd, VIDIOC_QBUF, &b) < 0)
			return false;
	}
	/* Initial 3A state */
	h.gr = h.c.wb_r0;
	h.gb = h.c.wb_b0;
	ae_apply(h, 20000.0 * 2.0);
	wb_write(h);
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	if (xioctl(h.vfd, VIDIOC_STREAMON, &type) < 0) {
		hlog("STREAMON: %m");
		return false;
	}
	hlog("%s streaming IFE1 PIX NV12 %ux%u stride %u -> %s YUYV %ux%u",
	     h.c.sensor, h.c.out_w, h.c.out_h, h.stride, h.loop_dev.c_str(),
	     h.c.loop_w, h.c.loop_h);
	return true;
}

void *loop_thread(void *arg)
{
	Hw &h = *static_cast<Hw *>(arg);
	int loop_fd = dagu_loop_fd(h.slot);
	unsigned misses = 0;
	h.yuyv.resize((size_t)h.c.loop_w * h.c.loop_h * 2);
	while (true) {
		pollfd pf{ h.vfd, POLLIN, 0 };
		int pr = poll(&pf, 1, 1000);
		if (pr <= 0) {
			if (++misses >= 3) {
				hlog("%s: no frames for 3 s, exiting", h.c.sensor);
				_exit(3);
			}
			continue;
		}
		misses = 0;
		v4l2_buffer b{};
		v4l2_plane pl{};
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		b.memory = V4L2_MEMORY_MMAP;
		b.length = 1;
		b.m.planes = &pl;
		if (xioctl(h.vfd, VIDIOC_DQBUF, &b) < 0)
			continue;
		const uint8_t *y = static_cast<const uint8_t *>(h.bufs[b.index].p);
		const uint8_t *uv = y + (size_t)h.stride * h.c.out_h;
		h.frames++;
		if ((h.frames % 2) == 0)
			run_3a(h, y, uv);
		pack(h, y, uv, h.yuyv.data());
		xioctl(h.vfd, VIDIOC_QBUF, &b);
		if (loop_fd >= 0) {
			ssize_t n = write(loop_fd, h.yuyv.data(), h.yuyv.size());
			if (n < 0 && errno != EAGAIN && errno != EINTR)
				hlog("write loopback: %m");
		}
		if (h.frames == 1)
			hlog("%s first hardware frame -> %s", h.c.sensor, h.loop_dev.c_str());
	}
	return nullptr;
}

Hw g_hw[2];

} // namespace

extern "C" int dagu_hw_start(int slot, const char *loopback_dev)
{
	if (slot < 0 || slot > 1)
		return -1;
	if (getenv("DAGU_CAMERA_SOFTISP"))
		return -1;
	Hw &h = g_hw[slot];
	h.c = slot == 0 ? kFront : kRear;
	h.slot = slot;
	h.loop_dev = loopback_dev;
	for (int i = 0; i < 256; i++)
		h.lin8[i] = (float)srgb_to_lin(i / 255.0);
	if (dagu_loop_open(slot, loopback_dev, h.c.loop_w, h.c.loop_h) < 0)
		return -1;
	if (!setup(h)) {
		hlog("%s hardware path setup failed", h.c.sensor);
		return -1;
	}
	if (pthread_create(&h.th, nullptr, loop_thread, &h)) {
		hlog("pthread_create: %m");
		return -1;
	}
	return 0;
}
