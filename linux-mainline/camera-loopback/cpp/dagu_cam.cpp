#define _GNU_SOURCE
#include "dagu_cam.h"

#include <libcamera/libcamera.h>
#include <libcamera/framebuffer_allocator.h>
#include <libcamera/control_ids.h>

#include <cstdarg>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <array>
#include <vector>
#include <cerrno>
#include <chrono>
#include <unordered_map>
#include <condition_variable>
#include <deque>
#include <dirent.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <mutex>
#include <sched.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <cmath>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

using namespace libcamera;

/* Webcam contract for xcast (wemeet): YUYV fourcc + packed YUYV bytes.
 * yuyv=1 is the only GL first.draw path. RGB24/I420 fourcc stay black.
 * Driver G_FMT sizeimage stays packed W*H*2. QUERYBUF/mmap is packed
 * plus I420 UV at +packed (19:53). W*H*4 mmap completes wrap as
 * 0x15012 and convert reads an empty 0x15009 plane (20:15 is_bokeh).
 * write() copies packed pixels; the driver reports bytesused equal
 * to CONVERT_PAD length. W*H*4 bytesused is the 20:10 smash.
 * Capture DQBUF index stays in 0..3: xcast mmaps 4 slots (21:12
 * rear→front SIGSEGV when index 4..7 leaked leftover as plane).
 * SoftISP stays at skip 2×2 / 4×4; pack center-crops to 16:9 here. */
static constexpr unsigned DAGU_WEBCAM_W = 1280;
static constexpr unsigned DAGU_WEBCAM_H = 720;

static unsigned webcam_write_bytes(unsigned w, unsigned h)
{
	return w * h * 2;
}

static void log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "dagu-camera-loopback: ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

void dagu_pin_cpu_0_3(void)
{
	cpu_set_t set;
	CPU_ZERO(&set);
	for (int i = 0; i < 4; i++)
		CPU_SET(i, &set);
	if (sched_setaffinity(0, sizeof(set), &set) < 0)
		log("sched_setaffinity: %m");
}

void dagu_pin_all_threads(void)
{
	/* DebayerCpu skip 2x2/4x4 needs A77. Little-only was ~11 fps.
	 * Leave CPU 6-7 for mutter SCHED_DEADLINE. */
	cpu_set_t little, big;
	CPU_ZERO(&little);
	CPU_ZERO(&big);
	for (int i = 0; i < 4; i++)
		CPU_SET(i, &little);
	CPU_SET(4, &big);
	CPU_SET(5, &big);
	DIR *d = opendir("/proc/self/task");
	if (!d)
		return;
	while (dirent *e = readdir(d)) {
		if (e->d_name[0] < '0' || e->d_name[0] > '9')
			continue;
		int tid = atoi(e->d_name);
		char path[64];
		snprintf(path, sizeof(path), "/proc/self/task/%d/comm", tid);
		char name[32] = {};
		FILE *f = fopen(path, "r");
		if (f) {
			if (!fgets(name, sizeof(name), f))
				name[0] = 0;
			fclose(f);
		}
		/* SWIspWorker is the DebayerCpu thread. Missing it left
		 * skip-4x4 on A55 at 86ms/frame and starved the session. */
		bool isp = strstr(name, "Camera") || strstr(name, "Debayer") ||
			   strstr(name, "IPA") || strstr(name, "simple") ||
			   strstr(name, "soft") || strstr(name, "SWIsp") ||
			   strstr(name, "Isp");
		sched_setaffinity(tid, sizeof(cpu_set_t), isp ? &big : &little);
	}
	closedir(d);
}

static int s_ctrl(int fd, uint32_t id, int value)
{
	v4l2_control c{};
	c.id = id;
	c.value = value;
	return ioctl(fd, VIDIOC_S_CTRL, &c);
}

/* Mid-gray YUYV. Y=16 is BT.601 black; xcast paints that as a black tile. */
static void fill_gray_yuyv(uint8_t *z, size_t n)
{
	memset(z, 0x80, n);
}

static int write_gray_yuyv(int fd, unsigned w, unsigned h, unsigned copies)
{
	std::vector<uint8_t> z(webcam_write_bytes(w, h));
	fill_gray_yuyv(z.data(), z.size());
	int ok = 0;
	for (unsigned i = 0; i < copies; i++) {
		if (write(fd, z.data(), z.size()) >= 0)
			ok++;
		else
			log("gray write: %m");
	}
	return ok > 0 ? 0 : -1;
}

static int set_loop_xcast(int fd, uint32_t type, unsigned w, unsigned h)
{
	v4l2_format fmt{};
	fmt.type = type;
	fmt.fmt.pix.width = w;
	fmt.fmt.pix.height = h;
	/* YUYV fourcc (yuyv=1). Driver keeps G_FMT sizeimage packed. */
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;
	fmt.fmt.pix.bytesperline = w * 2;
	fmt.fmt.pix.sizeimage = w * h * 2;
	fmt.fmt.pix.colorspace = V4L2_COLORSPACE_SRGB;
	if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
		log("S_FMT type=%u: %m", type);
		return -1;
	}
	return 0;
}

int dagu_stamp_loopback(const char *dev, unsigned w, unsigned h)
{
	int fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -1;
	/* Previous RGB24/I420 keep_format blocks YUYV S_FMT. Drop it first. */
	s_ctrl(fd, 0x0098f900, 0);
	if (set_loop_xcast(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, w, h) < 0) {
		close(fd);
		return -1;
	}
	{
		struct v4l2_streamparm parm = {};

		parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		parm.parm.output.capability = V4L2_CAP_TIMEPERFRAME;
		parm.parm.output.timeperframe.numerator = 1;
		parm.parm.output.timeperframe.denominator = 30;
		if (ioctl(fd, VIDIOC_S_PARM, &parm) < 0)
			log("%s S_PARM 30: %m", dev);
	}
	/* Several copies so xcast can DQBUF before SoftISP takes OUTPUT. */
	if (write_gray_yuyv(fd, w, h, 4) < 0)
		log("%s dummy write: %m", dev);
	s_ctrl(fd, 0x0098f900, 1); /* keep_format */
	/*
	 * timeout=0: timeout_image is vzalloc zeros (BT.601 black).
	 * sustain_framerate re-serves the last gray/live buffer when
	 * this OUTPUT fd closes — xcast must not see an empty queue.
	 */
	s_ctrl(fd, 0x0098f902, 0);
	s_ctrl(fd, 0x0098f901, 1); /* sustain_framerate */
	log("%s stamped %ux%u YUYV hold-fd=%d", dev, w, h, fd);
	return fd;
}

int dagu_clear_cloexec(int fd)
{
	int fl = fcntl(fd, F_GETFD);

	if (fl < 0)
		return -1;
	return fcntl(fd, F_SETFD, fl & ~FD_CLOEXEC);
}

int dagu_set_cloexec(int fd)
{
	int fl = fcntl(fd, F_GETFD);

	if (fl < 0)
		return -1;
	return fcntl(fd, F_SETFD, fl | FD_CLOEXEC);
}

struct Pipe {
	std::shared_ptr<Camera> camera;
	std::unique_ptr<CameraConfiguration> config;
	std::unique_ptr<FrameBufferAllocator> allocator;
	std::vector<std::unique_ptr<Request>> requests;
	Stream *stream = nullptr;
	unsigned w = 0, h = 0, stride = 0;
	unsigned loop_w = DAGU_WEBCAM_W, loop_h = DAGU_WEBCAM_H;
	uint32_t fourcc = 0;
	bool hflip = false;
	bool vflip = false;
	/* s5kjn1 GBRG Debayer STORE is B,G,R in the same RG24 mmap where
	 * imx596 BGGR is R,G,B. RGB pack makes rear Coke/red go blue. */
	bool bgr = false;
	bool rear = false;
	float dg = 1.f;
	float tone_dg = -1.f;
	uint8_t tone[256]{};
	unsigned agc_mean = 0;
	unsigned agc_clip_pm = 0;
	std::mutex mu;
	std::condition_variable cv;
	std::deque<Request *> done;
	bool stop = false;
	std::thread th;
	int loop_fd = -1;
	std::string id, dev;
	struct Map {
		void *ptr = MAP_FAILED;
		size_t len = 0;
	};
	std::unordered_map<int, Map> fdmap;
};

static CameraManager *g_cm;
static Pipe g_pipe[2];

static CameraManager *cm()
{
	if (!g_cm) {
		g_cm = new CameraManager();
		if (g_cm->start())
			log("CameraManager::start failed");
	}
	return g_cm;
}

static const uint8_t *plane_ptr(Pipe *p, const FrameBuffer::Plane &pl)
{
	int fd = pl.fd.get();
	auto it = p->fdmap.find(fd);
	if (it == p->fdmap.end()) {
		void *m = mmap(nullptr, pl.length, PROT_READ, MAP_SHARED, fd, 0);
		if (m == MAP_FAILED)
			return nullptr;
		Pipe::Map mp;
		mp.ptr = m;
		mp.len = pl.length;
		it = p->fdmap.emplace(fd, mp).first;
	}
	unsigned off = pl.offset == FrameBuffer::Plane::kInvalidOffset ? 0 : pl.offset;
	if (off >= it->second.len)
		return nullptr;
	return static_cast<const uint8_t *>(it->second.ptr) + off;
}

static void unmap_all(Pipe *p)
{
	for (auto &kv : p->fdmap) {
		if (kv.second.ptr != MAP_FAILED)
			munmap(kv.second.ptr, kv.second.len);
	}
	p->fdmap.clear();
}

static void nv12_to_yuyv(const uint8_t *y, unsigned y_stride, const uint8_t *uv,
			 unsigned uv_stride, unsigned w, unsigned h, uint8_t *dst)
{
	for (unsigned row = 0; row < h; row++) {
		const uint8_t *ys = y + row * y_stride;
		const uint8_t *us = uv + (row / 2) * uv_stride;
		uint8_t *d = dst + row * w * 2;
		for (unsigned col = 0; col < w; col += 2) {
			d[0] = ys[col];
			d[1] = us[col];
			d[2] = ys[col + 1];
			d[3] = us[col + 1];
			d += 4;
		}
	}
}

static uint32_t fcc4(char a, char b, char c, char d)
{
	return (uint32_t)(uint8_t)a | ((uint32_t)(uint8_t)b << 8) |
	       ((uint32_t)(uint8_t)c << 16) | ((uint32_t)(uint8_t)d << 24);
}

static void put_yuyv(uint8_t *d, int r0, int g0, int b0, int r1, int g1, int b1)
{
	auto sat = [](int v) {
		if (v < 0)
			return 0;
		if (v > 255)
			return 255;
		return v;
	};
	int Y0 = sat(((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16);
	int Y1 = sat(((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16);
	int U = sat(((-38 * r0 - 74 * g0 + 112 * b0 + 128) >> 8) + 128);
	int V = sat(((112 * r0 - 94 * g0 - 18 * b0 + 128) >> 8) + 128);
	d[0] = static_cast<uint8_t>(Y0);
	d[1] = static_cast<uint8_t>(U);
	d[2] = static_cast<uint8_t>(Y1);
	d[3] = static_cast<uint8_t>(V);
}

/* DebayerCpu STORE_PIXEL is named BGR. Front BGGR skip-2×2 lands R,G,B
 * in the RG24 mmap; rear GBRG skip-4×4 lands B,G,R. */
static void rgb24_row_to_yuyv(const uint8_t *s, uint8_t *d, unsigned w, bool bgr)
{
	unsigned x = 0;
#if defined(__aarch64__)
	for (; x + 16 <= w; x += 16) {
		uint8x16x3_t p = vld3q_u8(s + x * 3);
		uint8x16_t r = bgr ? p.val[2] : p.val[0];
		uint8x16_t g = p.val[1];
		uint8x16_t b = bgr ? p.val[0] : p.val[2];
		uint16x8_t rlo = vmovl_u8(vget_low_u8(r));
		uint16x8_t glo = vmovl_u8(vget_low_u8(g));
		uint16x8_t blo = vmovl_u8(vget_low_u8(b));
		uint16x8_t rhi = vmovl_u8(vget_high_u8(r));
		uint16x8_t ghi = vmovl_u8(vget_high_u8(g));
		uint16x8_t bhi = vmovl_u8(vget_high_u8(b));
		uint16x8_t ylo = vaddq_u16(
			vshrq_n_u16(vaddq_u16(vaddq_u16(vmulq_n_u16(rlo, 66), vmulq_n_u16(glo, 129)),
					      vaddq_u16(vmulq_n_u16(blo, 25), vdupq_n_u16(128))),
				    8),
			vdupq_n_u16(16));
		uint16x8_t yhi = vaddq_u16(
			vshrq_n_u16(vaddq_u16(vaddq_u16(vmulq_n_u16(rhi, 66), vmulq_n_u16(ghi, 129)),
					      vaddq_u16(vmulq_n_u16(bhi, 25), vdupq_n_u16(128))),
				    8),
			vdupq_n_u16(16));
		uint8x16_t yy = vcombine_u8(vqmovn_u16(ylo), vqmovn_u16(yhi));
		const uint8x16_t even_idx = { 0, 2, 4, 6, 8, 10, 12, 14,
					      0, 0, 0, 0, 0, 0, 0, 0 };
		uint8x8_t re8 = vget_low_u8(vqtbl1q_u8(r, even_idx));
		uint8x8_t ge8 = vget_low_u8(vqtbl1q_u8(g, even_idx));
		uint8x8_t be8 = vget_low_u8(vqtbl1q_u8(b, even_idx));
		int16x8_t re = vreinterpretq_s16_u16(vmovl_u8(re8));
		int16x8_t ge = vreinterpretq_s16_u16(vmovl_u8(ge8));
		int16x8_t be = vreinterpretq_s16_u16(vmovl_u8(be8));
		int16x8_t u = vaddq_s16(
			vshrq_n_s16(vaddq_s16(vaddq_s16(vmulq_n_s16(re, -38), vmulq_n_s16(ge, -74)),
					      vaddq_s16(vmulq_n_s16(be, 112), vdupq_n_s16(128))),
				    8),
			vdupq_n_s16(128));
		int16x8_t vv = vaddq_s16(
			vshrq_n_s16(vaddq_s16(vaddq_s16(vmulq_n_s16(re, 112), vmulq_n_s16(ge, -94)),
					      vaddq_s16(vmulq_n_s16(be, -18), vdupq_n_s16(128))),
				    8),
			vdupq_n_s16(128));
		uint8x8_t ye = vget_low_u8(vuzp1q_u8(yy, yy));
		uint8x8_t yo = vget_low_u8(vuzp2q_u8(yy, yy));
		uint8x8x4_t out;
		out.val[0] = ye;
		out.val[1] = vqmovun_s16(u);
		out.val[2] = yo;
		out.val[3] = vqmovun_s16(vv);
		vst4_u8(d + x * 2, out);
	}
#endif
	for (; x + 1 < w; x += 2) {
		const uint8_t *p0 = s + x * 3;
		const uint8_t *p1 = p0 + 3;
		if (bgr)
			put_yuyv(d + x * 2, p0[2], p0[1], p0[0], p1[2], p1[1], p1[0]);
		else
			put_yuyv(d + x * 2, p0[0], p0[1], p0[2], p1[0], p1[1], p1[2]);
	}
}

static void refresh_tone(Pipe *p)
{
	/* DebayerCpu Adjust already gamma-encodes. A second sRGB plus a 4×
	 * preamp clipped indoor desks (Y≈207) and stretched skip/ISO grain.
	 * Digital gain is AGC leftover after analog/exposure; the knee
	 * keeps highlights from going pastel-white. */
	float g = p->dg;
	if (g < 0.7f)
		g = 0.7f;
	if (g > 1.6f)
		g = 1.6f;
	g = floorf(g * 20.f + 0.5f) / 20.f;
	if (g == p->tone_dg)
		return;
	p->tone_dg = g;
	for (int i = 0; i < 256; i++) {
		float x = std::min(1.f, (float)i * g / 255.f);
		if (x > 0.78f) {
			float t01 = (x - 0.78f) / 0.22f;
			x = 0.78f + 0.22f * (t01 / (1.f + 1.8f * t01));
		}
		x = 0.42f + 1.12f * (x - 0.42f);
		if (x < 0.f)
			x = 0.f;
		if (x > 1.f)
			x = 1.f;
		p->tone[i] = (uint8_t)(x * 255.f + 0.5f);
	}
}

static void yuyv_to_rgb24(const uint8_t *src, uint8_t *dst, unsigned w,
			  unsigned h)
{
	for (unsigned y = 0; y < h; y++) {
		const uint8_t *s = src + y * w * 2;
		uint8_t *d = dst + y * w * 3;
		for (unsigned x = 0; x < w; x += 2) {
			int y0 = s[0], u = s[1] - 128, y1 = s[2], v = s[3] - 128;
			int r0 = y0 + ((359 * v) >> 8);
			int g0 = y0 - ((88 * u + 183 * v) >> 8);
			int b0 = y0 + ((454 * u) >> 8);
			int r1 = y1 + ((359 * v) >> 8);
			int g1 = y1 - ((88 * u + 183 * v) >> 8);
			int b1 = y1 + ((454 * u) >> 8);
			d[0] = (uint8_t)(r0 < 0 ? 0 : r0 > 255 ? 255 : r0);
			d[1] = (uint8_t)(g0 < 0 ? 0 : g0 > 255 ? 255 : g0);
			d[2] = (uint8_t)(b0 < 0 ? 0 : b0 > 255 ? 255 : b0);
			d[3] = (uint8_t)(r1 < 0 ? 0 : r1 > 255 ? 255 : r1);
			d[4] = (uint8_t)(g1 < 0 ? 0 : g1 > 255 ? 255 : g1);
			d[5] = (uint8_t)(b1 < 0 ? 0 : b1 > 255 ? 255 : b1);
			s += 4;
			d += 6;
		}
	}
}

static void rgb_to_webcam_rgb24(const uint8_t *src, unsigned stride, unsigned sw,
				unsigned sh, unsigned bpp, int ri, int gi, int bi,
				uint8_t *dst, unsigned dw, unsigned dh,
				bool hflip, bool vflip, const uint8_t *lut)
{
	unsigned crop_w, crop_h, x0, y0;
	if (sw * dh >= sh * dw) {
		crop_h = sh;
		crop_w = sh * dw / dh;
		if (crop_w > sw)
			crop_w = sw;
		x0 = (sw - crop_w) / 2;
		y0 = 0;
	} else {
		crop_w = sw;
		crop_h = sw * dh / dw;
		if (crop_h > sh)
			crop_h = sh;
		x0 = 0;
		y0 = (sh - crop_h) / 2;
	}
	crop_w &= ~1u;
	thread_local std::vector<uint8_t> rgbrow;
	thread_local std::vector<unsigned> xmap;
	rgbrow.resize(dw * 3);
	xmap.resize(dw);
	for (unsigned dx = 0; dx < dw; dx++) {
		unsigned sx = x0 + dx * crop_w / dw;
		if (sx >= sw)
			sx = sw - 1;
		if (hflip)
			sx = sw - 1 - sx;
		xmap[dx] = sx;
	}
	for (unsigned dy = 0; dy < dh; dy++) {
		unsigned sy = y0 + dy * crop_h / dh;
		if (sy >= sh)
			sy = sh - 1;
		if (vflip)
			sy = sh - 1 - sy;
		const uint8_t *row = src + sy * stride;
		for (unsigned dx = 0; dx < dw; dx++) {
			const uint8_t *p = row + xmap[dx] * bpp;
			uint8_t *o = rgbrow.data() + dx * 3;
			o[0] = lut[p[ri]];
			o[1] = lut[p[gi]];
			o[2] = lut[p[bi]];
		}
		rgb24_row_to_yuyv(rgbrow.data(), dst + dy * dw * 2, dw, false);
	}
}

static void pack_rgb24(Pipe *p, FrameBuffer *buf, uint8_t *dst)
{
	const auto &planes = buf->planes();
	if (p->fourcc == formats::NV12.fourcc()) {
		thread_local std::vector<uint8_t> native;
		native.resize(p->w * p->h * 2);
		const uint8_t *y = plane_ptr(p, planes[0]);
		if (planes.size() == 1) {
			if (y)
				nv12_to_yuyv(y, p->stride, y + p->stride * p->h, p->stride,
					     p->w, p->h, native.data());
		} else {
			const uint8_t *uv = plane_ptr(p, planes[1]);
			if (y && uv)
				nv12_to_yuyv(y, p->stride, uv, p->stride, p->w, p->h,
					     native.data());
		}
		/* Scale native YUYV macropixels, then emit RGB24. */
		thread_local std::vector<uint8_t> scaled;
		scaled.resize(p->loop_w * p->loop_h * 2);
		for (unsigned dy = 0; dy < p->loop_h; dy++) {
			unsigned sy = dy * p->h / p->loop_h;
			if (p->vflip)
				sy = p->h - 1 - sy;
			const uint8_t *srow = native.data() + sy * p->w * 2;
			uint8_t *drow = scaled.data() + dy * p->loop_w * 2;
			for (unsigned dx = 0; dx < p->loop_w; dx += 2) {
				unsigned sx = (dx * p->w / p->loop_w) & ~1u;
				if (p->hflip)
					sx = (p->w - 2 - sx) & ~1u;
				drow[dx * 2] = srow[sx * 2];
				drow[dx * 2 + 1] = srow[sx * 2 + 1];
				drow[dx * 2 + 2] = srow[sx * 2 + 2];
				drow[dx * 2 + 3] = srow[sx * 2 + 3];
			}
		}
		memcpy(dst, scaled.data(), p->loop_w * p->loop_h * 2);
		return;
	}

	const uint8_t *src = plane_ptr(p, planes[0]);
	if (!src)
		return;
	int ri = 0, gi = 1, bi = 2;
	unsigned bpp = 3;
	if (p->fourcc == fcc4('R', 'G', '2', '4')) {
		ri = p->bgr ? 2 : 0;
		bi = p->bgr ? 0 : 2;
	} else if (p->fourcc == fcc4('B', 'G', '2', '4')) {
		ri = 2;
		bi = 0;
	} else if (p->fourcc == fcc4('A', 'B', '2', '4') ||
		   p->fourcc == fcc4('X', 'B', '2', '4')) {
		bpp = 4;
	} else if (p->fourcc == fcc4('A', 'R', '2', '4') ||
		   p->fourcc == fcc4('X', 'R', '2', '4') ||
		   p->fourcc == fcc4('B', 'A', '2', '4')) {
		bpp = 4;
		ri = 2;
		bi = 0;
	} else if (p->fourcc == fcc4('R', 'A', '2', '4')) {
		bpp = 4;
	}
	refresh_tone(p);
	rgb_to_webcam_rgb24(src, p->stride, p->w, p->h, bpp, ri, gi, bi, dst,
			    p->loop_w, p->loop_h, p->hflip, p->vflip, p->tone);
}

static void yuyv_soften(uint8_t *img, unsigned w, unsigned h)
{
	/* Skip 2×2/4×4 keeps one Bayer quad; 1-2-1 is that reconstruction. */
	for (unsigned y = 0; y < h; y++) {
		uint8_t *row = img + (size_t)y * w * 2;
		uint8_t y0 = row[0];
		for (unsigned x = 2; x + 2 < w * 2; x += 2) {
			uint8_t y1 = row[x];
			uint8_t y2 = row[x + 2];
			row[x] = (uint8_t)((y0 + 2 * y1 + y2) >> 2);
			y0 = y1;
		}
		uint8_t u0 = row[1], v0 = row[3];
		for (unsigned x = 4; x + 4 < w * 2; x += 4) {
			uint8_t u1 = row[x + 1], v1 = row[x + 3];
			uint8_t u2 = row[x + 5], v2 = row[x + 7];
			row[x + 1] = (uint8_t)((u0 + 2 * u1 + u2) >> 2);
			row[x + 3] = (uint8_t)((v0 + 2 * v1 + v2) >> 2);
			u0 = u1;
			v0 = v1;
		}
	}
}

static void meter_and_agc(Pipe *p, const uint8_t *yuyv)
{
	unsigned w = p->loop_w, h = p->loop_h;
	unsigned long sum = 0;
	unsigned n = 0, clip = 0;
	for (unsigned y = 0; y < h; y += 8) {
		const uint8_t *row = yuyv + (size_t)y * w * 2;
		for (unsigned x = 0; x < w; x += 8) {
			unsigned v = row[x * 2];
			sum += v;
			n++;
			if (v > 240)
				clip++;
		}
	}
	if (!n)
		return;
	unsigned mean = (unsigned)(sum / n);
	p->agc_mean = mean;
	p->agc_clip_pm = clip * 1000u / n;
	float dg = p->dg;
	if (p->agc_clip_pm > 40 || mean > 128)
		dg = std::max(0.85f, dg * 0.96f);
	else if (mean < 88)
		dg = std::min(1.2f, dg * 1.03f);
	p->dg = dg;
}

static void apply_preview_ctrls(Pipe *p, Request *req)
{
	if (!p->camera)
		return;
	const ControlInfoMap &infos = p->camera->controls();
	/* IPA Agc owns analog/exposure. Gray-world AWB stays off. */
	if (infos.find(&controls::AwbEnable) != infos.end())
		req->controls().set(controls::AwbEnable, false);
}

static void on_complete(Pipe *p, Request *req)
{
	std::lock_guard<std::mutex> g(p->mu);
	p->done.push_back(req);
	p->cv.notify_one();
}

static int adopt_loop_fd(Pipe *p, unsigned w, unsigned h)
{
	const char *e = getenv("DAGU_LOOP_FD");
	char *end = nullptr;
	int fd, fl;
	v4l2_format cap{};

	if (!e || !*e)
		return 0;
	fd = (int)strtol(e, &end, 10);
	if (!end || *end || fd < 0 || fcntl(fd, F_GETFD) < 0) {
		log("DAGU_LOOP_FD=%s invalid: %m", e ? e : "");
		return -1;
	}
	/* Dup so pipe_teardown close() cannot drop watch's OUTPUT. */
	p->loop_fd = dup(fd);
	if (p->loop_fd < 0) {
		log("dup DAGU_LOOP_FD: %m");
		return -1;
	}
	fcntl(p->loop_fd, F_SETFD, FD_CLOEXEC);
	fl = fcntl(p->loop_fd, F_GETFL, 0);
	if (fl >= 0)
		fcntl(p->loop_fd, F_SETFL, fl | O_NONBLOCK);
	p->loop_w = w;
	p->loop_h = h;
	cap.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ioctl(p->loop_fd, VIDIOC_G_FMT, &cap) == 0 &&
	    cap.fmt.pix.width >= 2 && cap.fmt.pix.height >= 2 &&
	    cap.fmt.pix.pixelformat == V4L2_PIX_FMT_YUYV) {
		p->loop_w = cap.fmt.pix.width;
		p->loop_h = cap.fmt.pix.height;
	}
	s_ctrl(p->loop_fd, 0x0098f900, 1);
	s_ctrl(p->loop_fd, 0x0098f902, 0);
	s_ctrl(p->loop_fd, 0x0098f901, 1);
	log("adopt OUTPUT fd %d -> %d %s %ux%u (no second open)", fd,
	    p->loop_fd, p->dev.c_str(), p->loop_w, p->loop_h);
	return 1;
}

static int open_loop(Pipe *p, unsigned w, unsigned h)
{
	int adopted = adopt_loop_fd(p, w, h);

	if (adopted > 0)
		return 0;
	if (adopted < 0)
		return -1;
	/* Blocking write: O_NONBLOCK dropped frames and xcast saw
	 * EAGAIN-silent holes as a stuck black preview. */
	p->loop_fd = open(p->dev.c_str(), O_RDWR | O_CLOEXEC);
	if (p->loop_fd < 0) {
		log("open %s: %m", p->dev.c_str());
		return -1;
	}
	p->loop_w = w;
	p->loop_h = h;
	v4l2_format cap{};
	cap.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	bool have_xcast = ioctl(p->loop_fd, VIDIOC_G_FMT, &cap) == 0 &&
			  cap.fmt.pix.width >= 2 && cap.fmt.pix.height >= 2 &&
			  cap.fmt.pix.pixelformat == V4L2_PIX_FMT_YUYV;
	if (have_xcast) {
		p->loop_w = cap.fmt.pix.width;
		p->loop_h = cap.fmt.pix.height;
	} else if (set_loop_xcast(p->loop_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, w, h) < 0) {
		log("S_FMT %s: %m", p->dev.c_str());
		return -1;
	}
	/* Never S_FMT while xcast already mmap'd CAPTURE: that tears
	 * RGB24 and logs fail.create.frame. */
	s_ctrl(p->loop_fd, 0x0098f900, 1);
	/* Do not arm timeout=400: timeout_image is zeros, xcast goes black
	 * during libcamera STREAMON. Write gray now; live frames follow. */
	s_ctrl(p->loop_fd, 0x0098f902, 0);
	s_ctrl(p->loop_fd, 0x0098f901, 1);
	if (write_gray_yuyv(p->loop_fd, p->loop_w, p->loop_h, 4) < 0)
		log("open_loop gray %s: %m", p->dev.c_str());
	/* After the seed frames: never block in write() if xcast stops
	 * DQBUF. That D-state plus the /proc walk wedged sshd. */
	int fl = fcntl(p->loop_fd, F_GETFL, 0);
	if (fl >= 0)
		fcntl(p->loop_fd, F_SETFL, fl | O_NONBLOCK);
	return 0;
}

static int start_camera(Pipe *p, unsigned want_w, unsigned want_h)
{
	p->camera = cm()->get(p->id);
	if (!p->camera) {
		log("no camera %s", p->id.c_str());
		return -1;
	}
	if (p->camera->acquire()) {
		log("acquire %s failed", p->id.c_str());
		p->camera.reset();
		return -1;
	}
	p->config = p->camera->generateConfiguration({ StreamRole::Viewfinder });
	if (!p->config || p->config->empty()) {
		log("no viewfinder config");
		p->camera->release();
		p->camera.reset();
		return -1;
	}
	StreamConfiguration &sc = p->config->at(0);
	sc.pixelFormat = formats::RGB888;
	sc.size.width = want_w;
	sc.size.height = want_h;
	sc.bufferCount = 6;
	p->config->validate();
	if (p->camera->configure(p->config.get())) {
		log("configure RGB888 failed, trying NV12");
		sc.pixelFormat = formats::NV12;
		sc.size.width = want_w;
		sc.size.height = want_h;
		p->config->validate();
		if (p->camera->configure(p->config.get())) {
			log("configure failed");
			p->camera->release();
			p->camera.reset();
			return -1;
		}
	}
	p->stream = sc.stream();
	p->w = sc.size.width;
	p->h = sc.size.height;
	p->stride = sc.stride;
	p->fourcc = sc.pixelFormat.fourcc();
	log("cam %s %ux%u stride=%u fourcc=%c%c%c%c", p->id.c_str(), p->w, p->h,
	    p->stride, p->fourcc & 0xff, (p->fourcc >> 8) & 0xff,
	    (p->fourcc >> 16) & 0xff, (p->fourcc >> 24) & 0xff);

	p->allocator = std::make_unique<FrameBufferAllocator>(p->camera);
	if (p->allocator->allocate(p->stream) < 0) {
		log("allocate failed");
		return -1;
	}
	p->camera->requestCompleted.connect(p, [p](Request *req) { on_complete(p, req); });
	const auto &bufs = p->allocator->buffers(p->stream);
	for (const auto &buf : bufs) {
		auto req = p->camera->createRequest();
		if (!req || req->addBuffer(p->stream, buf.get())) {
			log("addBuffer failed");
			return -1;
		}
		p->requests.push_back(std::move(req));
	}
	if (p->camera->start()) {
		log("camera start failed");
		return -1;
	}
	for (auto &req : p->requests) {
		apply_preview_ctrls(p, req.get());
		p->camera->queueRequest(req.get());
	}
	dagu_pin_all_threads();
	return 0;
}

static void pipe_thread(Pipe *p)
{
	dagu_pin_cpu_0_3();
	std::vector<uint8_t> yuyv(webcam_write_bytes(p->loop_w, p->loop_h));
	unsigned frames = 0;
	unsigned long pack_us = 0;
	auto t0 = std::chrono::steady_clock::now();
	while (true) {
		Request *req = nullptr;
		{
			std::unique_lock<std::mutex> lk(p->mu);
		p->cv.wait_for(lk, std::chrono::milliseconds(33),
			       [&] { return p->stop || !p->done.empty(); });
			if (p->stop)
				break;
			if (p->done.empty()) {
				/* libcamera STREAMON still running; keep
				 * RGB24 flowing so xcast DQBUF never empties. */
				if (p->loop_fd >= 0)
					write_gray_yuyv(p->loop_fd, p->loop_w, p->loop_h, 1);
				continue;
			}
			req = p->done.front();
			p->done.pop_front();
		}
		if (!req)
			continue;
		if (req->status() == Request::RequestComplete) {
			FrameBuffer *buf = req->findBuffer(p->stream);
			if (buf && p->loop_fd >= 0) {
				auto tp = std::chrono::steady_clock::now();
				pack_rgb24(p, buf, yuyv.data());
				/* Rear skip 4×4 already reconstructs; the 1-2-1
				 * pass on 1280×720 ate A55 while Snapshot's
				 * gtk converted YUY2, pack spiked to 70ms. */
				if (!p->rear)
					yuyv_soften(yuyv.data(), p->loop_w, p->loop_h);
				meter_and_agc(p, yuyv.data());
				pack_us += (unsigned long)std::chrono::duration_cast<
					std::chrono::microseconds>(
					std::chrono::steady_clock::now() - tp)
					.count();
				ssize_t n = write(p->loop_fd, yuyv.data(), yuyv.size());
				if (n < 0 && errno != EAGAIN && errno != EINTR)
					log("write %s: %m", p->dev.c_str());
				frames++;
				if (frames == 1) {
					log("first frame %s -> %s %ux%u", p->id.c_str(),
					    p->dev.c_str(), p->loop_w, p->loop_h);
					dagu_pin_all_threads();
				}
				if ((frames % 60) == 0) {
					auto t1 = std::chrono::steady_clock::now();
					double s = std::chrono::duration<double>(t1 - t0).count();
					if (s > 0.2)
						log("%s fps %.1f pack=%.1fms meanY=%u clip=%u dg=%.2f",
						    p->dev.c_str(), 60.0 / s,
						    pack_us / 60.0 / 1000.0,
						    p->agc_mean, p->agc_clip_pm, p->dg);
					t0 = t1;
					pack_us = 0;
				}
			}
		}
		req->reuse(Request::ReuseBuffers);
		apply_preview_ctrls(p, req);
		p->camera->queueRequest(req);
	}
}

static void pipe_teardown(Pipe *p)
{
	p->stop = true;
	p->cv.notify_all();
	if (p->th.joinable())
		p->th.join();
	if (p->camera) {
		p->camera->stop();
		p->camera->requestCompleted.disconnect(p);
		p->requests.clear();
		p->allocator.reset();
		p->config.reset();
		p->camera->release();
		p->camera.reset();
	}
	if (p->loop_fd >= 0) {
		close(p->loop_fd);
		p->loop_fd = -1;
	}
	unmap_all(p);
	p->stop = false;
	p->done.clear();
	p->stream = nullptr;
}

int dagu_pipe_start(int slot, const char *camera_id, const char *loopback_dev,
		    unsigned w, unsigned h)
{
	if (slot < 0 || slot > 1)
		return -1;
	Pipe *p = &g_pipe[slot];
	if (p->th.joinable())
		return 0;
	p->id = camera_id;
	p->dev = loopback_dev;
	p->stop = false;
	/*
	 * Sensors sit 180° on the glass. HV-flip (rot180) makes the frame
	 * upright but mirrors left/right. V-only (front pack, rear already
	 * V in 0x0101) keeps handwriting readable.
	 */
	p->vflip = (slot == 0); /* imx596 0x0101=0; pack V only, not HV */
	p->hflip = (slot == 1); /* s5kjn1 silicon H+V; pack H leaves V */
	p->bgr = (slot == 1); /* s5kjn1 GBRG: RG24 bytes are B,G,R */
	p->rear = (slot == 1);
	p->dg = 1.f;
	p->tone_dg = -1.f;
	p->agc_mean = 0;
	p->agc_clip_pm = 0;
	/* Take OUTPUT, start the gray pump, then libcamera STREAMON. */
	if (open_loop(p, DAGU_WEBCAM_W, DAGU_WEBCAM_H) < 0) {
		pipe_teardown(p);
		return -1;
	}
	p->th = std::thread(pipe_thread, p);
	if (start_camera(p, w, h) < 0) {
		pipe_teardown(p);
		return -1;
	}
	log("start slot %d %s -> %s hflip=%d vflip=%d bgr=%d", slot, camera_id,
	    loopback_dev, p->hflip ? 1 : 0, p->vflip ? 1 : 0, p->bgr ? 1 : 0);
	return 0;
}

void dagu_pipe_stop(int slot)
{
	if (slot < 0 || slot > 1)
		return;
	Pipe *p = &g_pipe[slot];
	if (!p->th.joinable() && !p->camera)
		return;
	log("stop slot %d", slot);
	pipe_teardown(p);
}

int dagu_pipe_running(int slot)
{
	if (slot < 0 || slot > 1)
		return 0;
	return g_pipe[slot].th.joinable() ? 1 : 0;
}
