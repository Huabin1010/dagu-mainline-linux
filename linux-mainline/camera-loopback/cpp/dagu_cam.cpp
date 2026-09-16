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
#include <vector>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

using namespace libcamera;

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

static int set_loop_yuyv(int fd, uint32_t type, unsigned w, unsigned h)
{
	v4l2_format fmt{};
	fmt.type = type;
	fmt.fmt.pix.width = w;
	fmt.fmt.pix.height = h;
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
	/* Previous NV12 keep_format blocks YUYV S_FMT. Drop it first. */
	s_ctrl(fd, 0x0098f900, 0);
	if (set_loop_yuyv(fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, w, h) < 0) {
		close(fd);
		return -1;
	}
	(void)set_loop_yuyv(fd, V4L2_BUF_TYPE_VIDEO_CAPTURE, w, h);
	/* YUYV mid-gray: Y=16 U=128 V=128 → 0x10 0x80 0x10 0x80 */
	std::vector<uint8_t> z(w * h * 2);
	for (size_t i = 0; i + 3 < z.size(); i += 4) {
		z[i] = 0x10;
		z[i + 1] = 0x80;
		z[i + 2] = 0x10;
		z[i + 3] = 0x80;
	}
	if (write(fd, z.data(), z.size()) < 0)
		log("%s dummy write: %m", dev);
	s_ctrl(fd, 0x0098f900, 1); /* keep_format */
	s_ctrl(fd, 0x0098f902, 400); /* timeout ms */
	v4l2_format got{};
	got.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ioctl(fd, VIDIOC_G_FMT, &got) == 0)
		log("%s stamped %ux%u fourcc=%.4s keep=1", dev, got.fmt.pix.width,
		    got.fmt.pix.height, reinterpret_cast<char *>(&got.fmt.pix.pixelformat));
	close(fd);
	return 0;
}

struct Pipe {
	std::shared_ptr<Camera> camera;
	std::unique_ptr<CameraConfiguration> config;
	std::unique_ptr<FrameBufferAllocator> allocator;
	std::vector<std::unique_ptr<Request>> requests;
	Stream *stream = nullptr;
	unsigned w = 0, h = 0, stride = 0;
	uint32_t fourcc = 0;
	bool rot180 = false;
	/* s5kjn1 GBRG Debayer STORE is B,G,R in the same RG24 mmap where
	 * imx596 BGGR is R,G,B. RGB pack makes rear Coke/red go blue. */
	bool bgr = false;
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

static void reverse_yuyv_row(uint8_t *d, unsigned w)
{
	for (unsigned x = 0; x < w / 2; x += 2) {
		unsigned o = (w - 2 - x) * 2;
		unsigned i = x * 2;
		uint8_t y0 = d[i], u = d[i + 1], y1 = d[i + 2], v = d[i + 3];
		d[i] = d[o + 2];
		d[i + 1] = d[o + 1];
		d[i + 2] = d[o];
		d[i + 3] = d[o + 3];
		d[o] = y1;
		d[o + 1] = u;
		d[o + 2] = y0;
		d[o + 3] = v;
	}
}

static void rgb_rows_to_yuyv(const uint8_t *src, unsigned stride, unsigned w,
			     unsigned h, unsigned bpp, int ri, int gi, int bi,
			     uint8_t *dst, bool rot180)
{
	const bool rgb24 = (bpp == 3 && gi == 1 && (ri + bi) == 2);
	for (unsigned row = 0; row < h; row++) {
		unsigned sy = rot180 ? (h - 1 - row) : row;
		const uint8_t *s = src + sy * stride;
		uint8_t *d = dst + row * w * 2;
		if (rgb24) {
			rgb24_row_to_yuyv(s, d, w, ri == 2);
			if (rot180)
				reverse_yuyv_row(d, w);
			continue;
		}
		for (unsigned col = 0; col < w; col += 2) {
			const uint8_t *p0 = s + col * bpp;
			const uint8_t *p1 = p0 + bpp;
			put_yuyv(d + col * 2, p0[ri], p0[gi], p0[bi], p1[ri], p1[gi],
				 p1[bi]);
		}
		if (rot180)
			reverse_yuyv_row(d, w);
	}
}

static void pack_yuyv(Pipe *p, FrameBuffer *buf, uint8_t *dst)
{
	const auto &planes = buf->planes();
	if (p->fourcc == formats::NV12.fourcc()) {
		const uint8_t *y = plane_ptr(p, planes[0]);
		if (planes.size() == 1) {
			if (y)
				nv12_to_yuyv(y, p->stride, y + p->stride * p->h, p->stride,
					     p->w, p->h, dst);
			return;
		}
		const uint8_t *uv = plane_ptr(p, planes[1]);
		if (y && uv)
			nv12_to_yuyv(y, p->stride, uv, p->stride, p->w, p->h, dst);
		return;
	}

	const uint8_t *src = plane_ptr(p, planes[0]);
	if (!src)
		return;
	if (p->fourcc == fcc4('R', 'G', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 3,
				 p->bgr ? 2 : 0, 1, p->bgr ? 0 : 2, dst, p->rot180);
	else if (p->fourcc == fcc4('B', 'G', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 3, 2, 1, 0, dst, p->rot180);
	else if (p->fourcc == fcc4('A', 'B', '2', '4') ||
		 p->fourcc == fcc4('X', 'B', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 4, 0, 1, 2, dst, p->rot180);
	else if (p->fourcc == fcc4('A', 'R', '2', '4') ||
		 p->fourcc == fcc4('X', 'R', '2', '4') ||
		 p->fourcc == fcc4('B', 'A', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 4, 2, 1, 0, dst, p->rot180);
	else if (p->fourcc == fcc4('R', 'A', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 4, 0, 1, 2, dst, p->rot180);
	else
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 3, 0, 1, 2, dst, p->rot180);
}

static void apply_preview_ctrls(Pipe *p, Request *req)
{
	if (!p->camera)
		return;
	const ControlInfoMap &infos = p->camera->controls();
	/* Simple pipeline has no FrameDurationLimits. Uncapped AE was ~11 fps
	 * indoors (long exposure). Pin shutter so skip preview holds 30 fps. */
	if (infos.find(&controls::AeEnable) != infos.end())
		req->controls().set(controls::AeEnable, false);
	if (infos.find(&controls::ExposureTime) != infos.end())
		req->controls().set(controls::ExposureTime, 16000);
	if (infos.find(&controls::AnalogueGain) != infos.end())
		req->controls().set(controls::AnalogueGain, 8.0f);
}

static void on_complete(Pipe *p, Request *req)
{
	std::lock_guard<std::mutex> g(p->mu);
	p->done.push_back(req);
	p->cv.notify_one();
}

static int open_loop(Pipe *p, unsigned w, unsigned h)
{
	p->loop_fd = open(p->dev.c_str(), O_RDWR | O_CLOEXEC | O_NONBLOCK);
	if (p->loop_fd < 0) {
		log("open %s: %m", p->dev.c_str());
		return -1;
	}
	if (set_loop_yuyv(p->loop_fd, V4L2_BUF_TYPE_VIDEO_OUTPUT, w, h) < 0)
		log("S_FMT %s: %m", p->dev.c_str());
	s_ctrl(p->loop_fd, 0x0098f900, 1);
	s_ctrl(p->loop_fd, 0x0098f902, 400);
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
	std::vector<uint8_t> yuyv(p->w * p->h * 2);
	unsigned frames = 0;
	unsigned long pack_us = 0;
	auto t0 = std::chrono::steady_clock::now();
	while (true) {
		Request *req = nullptr;
		{
			std::unique_lock<std::mutex> lk(p->mu);
		p->cv.wait_for(lk, std::chrono::milliseconds(500),
			       [&] { return p->stop || !p->done.empty(); });
			if (p->stop)
				break;
			if (p->done.empty())
				continue;
			req = p->done.front();
			p->done.pop_front();
		}
		if (!req)
			continue;
		if (req->status() == Request::RequestComplete) {
			FrameBuffer *buf = req->findBuffer(p->stream);
			if (buf && p->loop_fd >= 0) {
				auto tp = std::chrono::steady_clock::now();
				pack_yuyv(p, buf, yuyv.data());
				pack_us += (unsigned long)std::chrono::duration_cast<
					std::chrono::microseconds>(
					std::chrono::steady_clock::now() - tp)
					.count();
				ssize_t n = write(p->loop_fd, yuyv.data(), yuyv.size());
				if (n < 0 && errno != EAGAIN && errno != EINTR)
					log("write %s: %m", p->dev.c_str());
				frames++;
				if (frames == 1) {
					log("first frame %s -> %s", p->id.c_str(), p->dev.c_str());
					dagu_pin_all_threads();
				}
				if ((frames % 60) == 0) {
					auto t1 = std::chrono::steady_clock::now();
					double s = std::chrono::duration<double>(t1 - t0).count();
					if (s > 0.2)
						log("%s fps %.1f pack=%.1fms", p->dev.c_str(),
						    60.0 / s, pack_us / 60.0 / 1000.0);
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
	p->rot180 = (slot == 0); /* imx596: loopback has no V4L2 rotation */
	p->bgr = (slot == 1); /* s5kjn1 GBRG: RG24 bytes are B,G,R */
	if (start_camera(p, w, h) < 0) {
		pipe_teardown(p);
		return -1;
	}
	if (open_loop(p, p->w, p->h) < 0) {
		pipe_teardown(p);
		return -1;
	}
	p->th = std::thread(pipe_thread, p);
	log("start slot %d %s -> %s rot180=%d bgr=%d", slot, camera_id,
	    loopback_dev, p->rot180 ? 1 : 0, p->bgr ? 1 : 0);
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
