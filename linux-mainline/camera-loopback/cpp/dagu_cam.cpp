#define _GNU_SOURCE
#include "dagu_cam.h"

#include <libcamera/libcamera.h>
#include <libcamera/framebuffer_allocator.h>

#include <cstdarg>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <condition_variable>
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
	cpu_set_t set;
	CPU_ZERO(&set);
	for (int i = 0; i < 4; i++)
		CPU_SET(i, &set);
	DIR *d = opendir("/proc/self/task");
	if (!d)
		return;
	while (dirent *e = readdir(d)) {
		if (e->d_name[0] < '0' || e->d_name[0] > '9')
			continue;
		int tid = atoi(e->d_name);
		sched_setaffinity(tid, sizeof(set), &set);
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
	std::mutex mu;
	std::condition_variable cv;
	Request *ready = nullptr;
	bool stop = false;
	std::thread th;
	int loop_fd = -1;
	std::string id, dev;
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

static void yuyv_rot180(uint8_t *f, unsigned w, unsigned h)
{
	const unsigned stride = w * 2;
	std::vector<uint8_t> tmp(stride * h);
	std::memcpy(tmp.data(), f, tmp.size());
	for (unsigned y = 0; y < h; y++) {
		const uint8_t *src_row = tmp.data() + (h - 1 - y) * stride;
		uint8_t *dst_row = f + y * stride;
		for (unsigned x = 0; x < w; x += 2) {
			const uint8_t *s = src_row + (w - 2 - x) * 2;
			uint8_t *d = dst_row + x * 2;
			d[0] = s[2];
			d[1] = s[1];
			d[2] = s[0];
			d[3] = s[3];
		}
	}
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

static void rgb_rows_to_yuyv(const uint8_t *src, unsigned stride, unsigned w,
			     unsigned h, unsigned bpp, int ri, int gi, int bi,
			     uint8_t *dst)
{
	for (unsigned row = 0; row < h; row++) {
		const uint8_t *s = src + row * stride;
		uint8_t *d = dst + row * w * 2;
		for (unsigned col = 0; col < w; col += 2) {
			const uint8_t *p0 = s + col * bpp;
			const uint8_t *p1 = p0 + bpp;
			put_yuyv(d, p0[ri], p0[gi], p0[bi], p1[ri], p1[gi], p1[bi]);
			d += 4;
		}
	}
}

static void pack_yuyv(Pipe *p, FrameBuffer *buf, uint8_t *dst)
{
	const auto &planes = buf->planes();
	auto map_plane = [&](unsigned i) -> const uint8_t * {
		int fd = planes[i].fd.get();
		unsigned off = planes[i].offset == FrameBuffer::Plane::kInvalidOffset
				       ? 0
				       : planes[i].offset;
		void *m = mmap(nullptr, planes[i].length, PROT_READ, MAP_SHARED, fd, 0);
		if (m == MAP_FAILED)
			return nullptr;
		return static_cast<const uint8_t *>(m) + off;
	};
	auto unmap_plane = [&](const uint8_t *base, unsigned i) {
		if (!base)
			return;
		unsigned off = planes[i].offset == FrameBuffer::Plane::kInvalidOffset
				       ? 0
				       : planes[i].offset;
		munmap(const_cast<uint8_t *>(base) - off, planes[i].length);
	};

	if (p->fourcc == formats::NV12.fourcc()) {
		if (planes.size() == 1) {
			const uint8_t *src = map_plane(0);
			if (src)
				nv12_to_yuyv(src, p->stride, src + p->stride * p->h, p->stride,
					     p->w, p->h, dst);
			unmap_plane(src, 0);
			return;
		}
		const uint8_t *y = map_plane(0);
		const uint8_t *uv = planes.size() > 1 ? map_plane(1) : nullptr;
		if (y && uv)
			nv12_to_yuyv(y, p->stride, uv, p->stride, p->w, p->h, dst);
		if (uv)
			unmap_plane(uv, 1);
		if (y)
			unmap_plane(y, 0);
		return;
	}

	const uint8_t *src = map_plane(0);
	if (!src)
		return;
	/* DRM 24-bit little-endian: RG24 stores B,G,R in memory. Treating
	 * that as R,G,B swaps Coke red into blue and cools the whole frame. */
	if (p->fourcc == fcc4('R', 'G', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 3, 2, 1, 0, dst);
	else if (p->fourcc == fcc4('B', 'G', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 3, 0, 1, 2, dst);
	else if (p->fourcc == fcc4('A', 'B', '2', '4') ||
		 p->fourcc == fcc4('X', 'B', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 4, 0, 1, 2, dst);
	else if (p->fourcc == fcc4('A', 'R', '2', '4') ||
		 p->fourcc == fcc4('X', 'R', '2', '4') ||
		 p->fourcc == fcc4('B', 'A', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 4, 2, 1, 0, dst);
	else if (p->fourcc == fcc4('R', 'A', '2', '4'))
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 4, 0, 1, 2, dst);
	else {
		log("unhandled fourcc %.4s, packing as RG24 LE",
		    reinterpret_cast<char *>(&p->fourcc));
		rgb_rows_to_yuyv(src, p->stride, p->w, p->h, 3, 2, 1, 0, dst);
	}
	unmap_plane(src, 0);
}

static void on_complete(Pipe *p, Request *req)
{
	std::lock_guard<std::mutex> g(p->mu);
	if (p->ready)
		p->ready->reuse(Request::ReuseBuffers);
	p->ready = req;
	p->cv.notify_one();
}

static int open_loop(Pipe *p, unsigned w, unsigned h)
{
	p->loop_fd = open(p->dev.c_str(), O_RDWR | O_CLOEXEC);
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
	sc.pixelFormat = formats::NV12;
	sc.size.width = want_w;
	sc.size.height = want_h;
	sc.bufferCount = 4;
	p->config->validate();
	if (p->camera->configure(p->config.get())) {
		log("configure NV12 failed, trying ABGR");
		sc.pixelFormat = formats::ABGR8888;
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
	for (auto &req : p->requests)
		p->camera->queueRequest(req.get());
	dagu_pin_all_threads();
	return 0;
}

static void pipe_thread(Pipe *p)
{
	dagu_pin_cpu_0_3();
	std::vector<uint8_t> yuyv(p->w * p->h * 2);
	unsigned frames = 0;
	while (true) {
		Request *req = nullptr;
		{
			std::unique_lock<std::mutex> lk(p->mu);
			p->cv.wait_for(lk, std::chrono::milliseconds(500),
				       [&] { return p->stop || p->ready; });
			if (p->stop)
				break;
			req = p->ready;
			p->ready = nullptr;
		}
		if (!req)
			continue;
		if (req->status() == Request::RequestComplete) {
			FrameBuffer *buf = req->findBuffer(p->stream);
			if (buf && p->loop_fd >= 0) {
				pack_yuyv(p, buf, yuyv.data());
				if (p->rot180)
					yuyv_rot180(yuyv.data(), p->w, p->h);
				ssize_t n = write(p->loop_fd, yuyv.data(), yuyv.size());
				(void)n;
				frames++;
				if (frames == 1)
					log("first frame %s -> %s", p->id.c_str(), p->dev.c_str());
			}
		}
		req->reuse(Request::ReuseBuffers);
		p->camera->queueRequest(req);
		if ((frames & 31) == 0)
			dagu_pin_all_threads();
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
	p->stop = false;
	p->ready = nullptr;
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
	dagu_pin_cpu_0_3();
	p->id = camera_id;
	p->dev = loopback_dev;
	p->stop = false;
	p->rot180 = (slot == 0); /* imx596: loopback has no V4L2 rotation */
	if (start_camera(p, w, h) < 0) {
		pipe_teardown(p);
		return -1;
	}
	if (open_loop(p, p->w, p->h) < 0) {
		pipe_teardown(p);
		return -1;
	}
	p->th = std::thread(pipe_thread, p);
	log("start slot %d %s -> %s rot180=%d", slot, camera_id, loopback_dev,
	    p->rot180 ? 1 : 0);
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
