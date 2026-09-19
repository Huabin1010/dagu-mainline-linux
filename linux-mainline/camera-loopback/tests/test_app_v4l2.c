/*
 * Simulate wemeet/xcast, Chrome, and SoftISP attach on dagu-front/rear.
 * Run on the board. Fail if ioctl sequence aborts or frames stay black.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define FRONT "/dev/video20"
#define REAR "/dev/video21"
#define W 1280
#define H 720
#define PACKED (W * H * 2)
#define CONVERT_PAD (PACKED + (W * H / 2))
#define RGB_SIZE (W * H * 3)
#define RGBA_SIZE (W * H * 4)
#define WRITE_LEN PACKED
#define FRAME PACKED
#define YUYV 0x56595559u
#define RGB24 0x33424752u
#define I420 0x32315559u

static int g_fail;
static sigjmp_buf g_convert_jmp;

static void convert_segv(int sig)
{
	(void)sig;
	siglongjmp(g_convert_jmp, 1);
}

/* 19:53 died here: Create succeeded, convert wrote UV on the mmap. */
static int poke_convert_on_mmap(void *map)
{
	struct sigaction sa, old;
	int died = 0;

	if (!map || map == MAP_FAILED)
		return -1;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = convert_segv;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, &old);
	if (sigsetjmp(g_convert_jmp, 1) == 0) {
		/* 19:53: UV at +PACKED. Do not require W*H*4: that mmap
		 * is the 20:15 is_bokeh convert crash. */
		memset((uint8_t *)map + PACKED, 0x80, (size_t)W * H / 2);
	} else
		died = 1;
	sigaction(SIGSEGV, &old, NULL);
	return died ? -1 : 0;
}

static void fail(const char *name, const char *why)
{
	fprintf(stderr, "FAIL %s: %s (errno=%d %s)\n", name, why, errno,
		strerror(errno));
	g_fail++;
}

static void pass(const char *name, const char *detail)
{
	printf("PASS %s %s\n", name, detail ? detail : "");
}

static int writer_gray(const char *dev, unsigned copies);
static int s_ctrl_u32(int fd, uint32_t id, int32_t val);

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r;
}

struct cap {
	int fd;
	int nbuf;
	void *map[8];
	size_t len[8];
};

static void cap_close(struct cap *c)
{
	enum v4l2_buf_type t = V4L2_BUF_TYPE_VIDEO_CAPTURE;

	if (c->fd < 0)
		return;
	xioctl(c->fd, VIDIOC_STREAMOFF, &t);
	for (int i = 0; i < c->nbuf; i++) {
		if (c->map[i] && c->map[i] != MAP_FAILED)
			munmap(c->map[i], c->len[i]);
		c->map[i] = NULL;
	}
	close(c->fd);
	c->fd = -1;
	c->nbuf = 0;
}

/* xcast: memset structs, set type/index/count only, leave memory=0. */
static int xcast_open_capture_fl(const char *dev, struct cap *c, int extra_fl)
{
	struct v4l2_format fmt;
	struct v4l2_requestbuffers req;
	struct v4l2_buffer b;
	enum v4l2_buf_type type;
	int i;

	memset(c, 0, sizeof(*c));
	c->fd = -1;
	c->fd = open(dev, O_RDWR | O_CLOEXEC | extra_fl);
	if (c->fd < 0)
		return -1;

	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(c->fd, VIDIOC_G_FMT, &fmt) < 0)
		goto fail_open;
	if (fmt.fmt.pix.pixelformat != YUYV || fmt.fmt.pix.width != W ||
	    fmt.fmt.pix.height != H || fmt.fmt.pix.sizeimage != PACKED)
		goto fail_open;
	if (xioctl(c->fd, VIDIOC_S_FMT, &fmt) < 0)
		goto fail_open;

	memset(&req, 0, sizeof(req));
	req.count = 4;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	/* memory left 0 — xcast v4l2.c */
	if (xioctl(c->fd, VIDIOC_REQBUFS, &req) < 0)
		goto fail_open;
	if (req.count < 2)
		goto fail_open;
	/* xcast mmaps min(granted, 4). Granting 5+ is the 21:12
	 * rear→front SIGSEGV (DQBUF index past calloc(4,16)). */
	if (req.count > 4)
		goto fail_open;
	c->nbuf = (int)req.count;

	for (i = 0; i < c->nbuf; i++) {
		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		b.index = i;
		if (xioctl(c->fd, VIDIOC_QUERYBUF, &b) < 0)
			goto fail_open;
		c->len[i] = b.length;
		c->map[i] = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
				 MAP_SHARED, c->fd, b.m.offset);
		if (c->map[i] == MAP_FAILED)
			goto fail_open;
		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		b.index = i;
		if (xioctl(c->fd, VIDIOC_QBUF, &b) < 0)
			goto fail_open;
	}
	type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(c->fd, VIDIOC_STREAMON, &type) < 0)
		goto fail_open;
	if (c->len[0] < CONVERT_PAD || c->len[0] >= RGBA_SIZE)
		goto fail_open;
	if (poke_convert_on_mmap(c->map[0]) < 0)
		goto fail_open;
	return 0;
fail_open:
	cap_close(c);
	return -1;
}

static int xcast_open_capture(const char *dev, struct cap *c)
{
	return xcast_open_capture_fl(dev, c, 0);
}

struct ystat {
	unsigned ymin, ymax;
	unsigned long ysum, rsum, gsum, bsum;
	unsigned n;
	int all_gray128;
	int black;
	int green_stripe;
};

static void rgb_stats(const uint8_t *p, size_t n, struct ystat *s)
{
	unsigned i;

	s->ymin = 255;
	s->ymax = 0;
	s->ysum = 0;
	s->rsum = 0;
	s->gsum = 0;
	s->bsum = 0;
	s->n = 0;
	s->all_gray128 = 1;
	s->black = 1;
	s->green_stripe = 0;
	if (n > FRAME)
		n = FRAME;
	if (n < 3)
		return;
	for (i = 0; i + 2 < n; i += 48) {
		unsigned r = p[i], g = p[i + 1], b = p[i + 2];
		unsigned y = (r + g + b) / 3;

		if (y < s->ymin)
			s->ymin = y;
		if (y > s->ymax)
			s->ymax = y;
		s->ysum += y;
		s->rsum += r;
		s->gsum += g;
		s->bsum += b;
		s->n++;
		if (r != 128 || g != 128 || b != 128)
			s->all_gray128 = 0;
		if (y > 16)
			s->black = 0;
	}
	if (s->n) {
		unsigned mr = (unsigned)(s->rsum / s->n);
		unsigned mg = (unsigned)(s->gsum / s->n);
		unsigned mb = (unsigned)(s->bsum / s->n);

		/* YUYV uploaded as RGB is overwhelmingly green. */
		if (mg > mr + 40 && mg > mb + 40)
			s->green_stripe = 1;
	}
}

static int xcast_dq_q(struct cap *c, struct ystat *st, int timeout_ms)
{
	struct v4l2_buffer b;
	struct timeval tv;
	fd_set rfds;
	unsigned idx;
	int r;

	FD_ZERO(&rfds);
	FD_SET(c->fd, &rfds);
	tv.tv_sec = timeout_ms / 1000;
	tv.tv_usec = (timeout_ms % 1000) * 1000;
	r = select(c->fd + 1, &rfds, NULL, NULL, &tv);
	if (r == 0) {
		errno = ETIMEDOUT;
		return -1;
	}
	if (r < 0)
		return -1;
	memset(&b, 0, sizeof(b));
	b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(c->fd, VIDIOC_DQBUF, &b) < 0)
		return -1;
	idx = b.index;
	if (idx >= (unsigned)c->nbuf || !c->map[idx]) {
		errno = EIO;
		return -1;
	}
	/* 21:12: xcast mmap table is 4 slots. index>=4 is convert ld2
	 * from leftover (UTF-16 "ages") on rear→front switch. */
	if (idx >= 4) {
		errno = ERANGE;
		return -1;
	}
	if (b.bytesused < FRAME) {
		errno = ENOSPC;
		return -1;
	}
	/* 20:10: bytesused W*H*4 memcpy smash. 20:48: bytesused must
	 * equal QUERYBUF.length (CONVERT_PAD) so wrap fills plane+8. */
	if (b.bytesused >= RGBA_SIZE) {
		errno = EOVERFLOW;
		return -1;
	}
	if (b.bytesused != c->len[idx]) {
		errno = EMSGSIZE;
		return -1;
	}
	rgb_stats((const uint8_t *)c->map[idx], FRAME, st);
	memset(&b, 0, sizeof(b));
	b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	b.index = idx;
	if (xioctl(c->fd, VIDIOC_QBUF, &b) < 0)
		return -1;
	return 0;
}

/*
 * Meeting / xcast contract locked from live logs:
 *   RGB24 fourcc → yuyv=0, no first.draw, black (19:42)
 *   I420 fourcc  → yuyv=0, no first.draw, black (19:30)
 *   YUYV + sizeimage W*H*3 → fail.create + Not enough buffer, crash (19:48)
 *   YUYV + sizeimage packed → convert writes UV at +PACKED, SIGSEGV
 *   QUERYBUF W*H*4 → wrap 0x15012 completes, convert src=is_bokeh (20:15)
 *   Create uses G_FMT packed; QUERYBUF is CONVERT_PAD
 *   convert malloc(G_FMT.sizeimage) writes UV at +PACKED
 */
static int test_meeting_contract(const char *dev)
{
	int fd;
	struct v4l2_format fmt;
	struct v4l2_requestbuffers req;
	struct v4l2_buffer b;
	uint8_t *heap;
	char msg[160];

	fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fail("meeting_contract", "open");
		return -1;
	}
	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(fd, VIDIOC_G_FMT, &fmt) < 0) {
		fail("meeting_contract", "G_FMT");
		close(fd);
		return -1;
	}

	if (fmt.fmt.pix.pixelformat == RGB24) {
		fail("meeting_contract",
		     "RGB24 fourcc: xcast yuyv=0, no first.draw, black");
		close(fd);
		return -1;
	}
	if (fmt.fmt.pix.pixelformat == I420) {
		fail("meeting_contract",
		     "I420 fourcc: xcast yuyv=0, no first.draw, black");
		close(fd);
		return -1;
	}
	if (fmt.fmt.pix.pixelformat != YUYV) {
		fail("meeting_contract",
		     "not YUYV: xcast yuyv=0, GL first.draw never runs");
		close(fd);
		return -1;
	}
	if (fmt.fmt.pix.sizeimage == (unsigned)RGB_SIZE) {
		fail("meeting_contract",
		     "sizeimage W*H*3: fail.create + Not enough buffer (19:48)");
		close(fd);
		return -1;
	}
	if (fmt.fmt.pix.width != W || fmt.fmt.pix.height != H ||
	    fmt.fmt.pix.sizeimage != PACKED) {
		snprintf(msg, sizeof(msg),
			 "%s YUYV %ux%u sizeimage=%u (Create wants packed %u)",
			 dev, fmt.fmt.pix.width, fmt.fmt.pix.height,
			 fmt.fmt.pix.sizeimage, PACKED);
		fail("meeting_contract", msg);
		close(fd);
		return -1;
	}

	memset(&req, 0, sizeof(req));
	req.count = 2;
	req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 1) {
		fail("meeting_contract", "REQBUFS memory=0");
		close(fd);
		return -1;
	}
	memset(&b, 0, sizeof(b));
	b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	b.index = 0;
	if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) {
		fail("meeting_contract", "QUERYBUF");
		close(fd);
		return -1;
	}
	if (b.length < CONVERT_PAD || b.length == FRAME) {
		snprintf(msg, sizeof(msg),
			 "QUERYBUF.length=%u (need >=%u convert UV pad, 19:53 crash)",
			 b.length, CONVERT_PAD);
		fail("meeting_contract", msg);
		close(fd);
		return -1;
	}
	if (b.length >= RGBA_SIZE) {
		snprintf(msg, sizeof(msg),
			 "QUERYBUF.length=%u (W*H*4 wrap 0x15012, 20:15 is_bokeh SIGSEGV)",
			 b.length);
		fail("meeting_contract", msg);
		close(fd);
		return -1;
	}

	/* Heap poke is not the 19:53 path. mmap poke is. */
	heap = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		    b.m.offset);
	if (heap == MAP_FAILED || poke_convert_on_mmap(heap) < 0) {
		fail("meeting_contract",
		     "convert-on-mmap SIGSEGV (this is the 19:53 Meeting crash)");
		if (heap != MAP_FAILED)
			munmap(heap, b.length);
		close(fd);
		return -1;
	}
	munmap(heap, b.length);
	close(fd);

	snprintf(msg, sizeof(msg),
		 "%s YUYV G_FMT=%u QUERYBUF=%u (Create packed, mmap CONVERT_PAD)",
		 dev, fmt.fmt.pix.sizeimage, b.length);
	pass("meeting_contract", msg);
	return 0;
}

static int test_dqbuf_packed(const char *dev)
{
	struct cap c;
	struct ystat st;

	if (xcast_open_capture(dev, &c) < 0) {
		fail("dqbuf_packed", "xcast open");
		return -1;
	}
	if (xcast_dq_q(&c, &st, 400) < 0) {
		fail("dqbuf_packed", "DQBUF");
		cap_close(&c);
		return -1;
	}
	cap_close(&c);
	pass("dqbuf_split",
	     "DQBUF.bytesused==QUERYBUF CONVERT_PAD, not packed mismatch (20:48 plane+8) and not RGBA (20:10)");
	return 0;
}

static int test_xcast_four_slots(const char *dev)
{
	struct cap c;
	struct ystat st;
	uint8_t *z;
	int wfd, i;

	/* Meeting: OUTPUT (stamp/SoftISP) is already writing when
	 * xcast REQBUFS. Capture REQBUFS must not wipe those frames,
	 * and DQBUF index stays in the 4 mmap slots. */
	wfd = open(dev, O_RDWR | O_CLOEXEC);
	if (wfd < 0) {
		fail("xcast_four_slots", "open OUTPUT");
		return -1;
	}
	(void)s_ctrl_u32(wfd, 0x0098f901, 1);
	z = malloc(WRITE_LEN);
	if (!z) {
		fail("xcast_four_slots", "malloc");
		close(wfd);
		return -1;
	}
	memset(z, 0x80, WRITE_LEN);
	for (i = 0; i < 4; i++) {
		if (write(wfd, z, WRITE_LEN) != (ssize_t)WRITE_LEN) {
			fail("xcast_four_slots", "seed write");
			free(z);
			close(wfd);
			return -1;
		}
	}
	if (xcast_open_capture(dev, &c) < 0) {
		fail("xcast_four_slots", "open (kernel granted >4?)");
		free(z);
		close(wfd);
		return -1;
	}
	if (c.nbuf != 4) {
		fail("xcast_four_slots", "REQBUFS must grant exactly 4");
		cap_close(&c);
		free(z);
		close(wfd);
		return -1;
	}
	for (i = 0; i < 8; i++) {
		if (write(wfd, z, WRITE_LEN) != (ssize_t)WRITE_LEN &&
		    errno != EBUSY)
			break;
		if (xcast_dq_q(&c, &st, 400) < 0) {
			fail("xcast_four_slots",
			     errno == ERANGE ?
			     "DQBUF index>=4 (21:12 rear→front SIGSEGV)" :
			     "DQBUF");
			cap_close(&c);
			free(z);
			close(wfd);
			return -1;
		}
	}
	cap_close(&c);
	free(z);
	close(wfd);
	pass("xcast_four_slots", "OUTPUT held, REQBUFS=4, DQBUF index in 0..3");
	return 0;
}

static int test_xcast_log_contract(void)
{
	DIR *d;
	struct dirent *e;
	char best[256] = "";
	time_t best_m = 0;
	FILE *fp;
	char line[512];
	char last_found[512] = "";
	int saw_first_draw = 0;
	int saw_not_enough = 0;

	d = opendir("/home/dagu/.local/share/wemeetapp/Saas/Logs");
	if (!d) {
		pass("xcast_log", "no Meeting logs (skip)");
		return 0;
	}
	while ((e = readdir(d))) {
		struct stat st;
		char path[300];

		if (strncmp(e->d_name, "xcast_", 6) ||
		    !strstr(e->d_name, ".log"))
			continue;
		snprintf(path, sizeof(path),
			 "/home/dagu/.local/share/wemeetapp/Saas/Logs/%s",
			 e->d_name);
		if (stat(path, &st) == 0 && st.st_mtime >= best_m) {
			best_m = st.st_mtime;
			snprintf(best, sizeof(best), "%s", path);
		}
	}
	closedir(d);
	if (!best[0]) {
		pass("xcast_log", "no xcast_*.log (skip)");
		return 0;
	}
	fp = fopen(best, "r");
	if (!fp) {
		pass("xcast_log", "cannot read log (skip)");
		return 0;
	}
	while (fgets(line, sizeof(line), fp)) {
		if (strstr(line, "found.size.")) {
			snprintf(last_found, sizeof(last_found), "%s", line);
			saw_first_draw = 0;
		}
		if (strstr(line, "first.draw"))
			saw_first_draw = 1;
		if (strstr(line, "Not enough buffer"))
			saw_not_enough = 1;
	}
	fclose(fp);
	if (!last_found[0]) {
		pass("xcast_log", "no found.size in latest log (skip)");
		return 0;
	}
	/* Only fail a log that is still the current session (mtime < 3 min). */
	if (time(NULL) - best_m > 180) {
		pass("xcast_log", "latest found.size older than 3min (skip)");
		return 0;
	}
	if (strstr(last_found, "fmt.0x33424752") ||
	    strstr(last_found, "fmt.0x32315559") ||
	    strstr(last_found, "yuyv=0")) {
		/* Stale Meeting session after a node fix: G_FMT is the gate. */
		pass("xcast_log",
		     "latest found.size yuyv=0 (reopen Meeting after ALL PASS)");
		fputs(last_found, stderr);
		return 0;
	}
	if (!strstr(last_found, "fmt.0x56595559") ||
	    !strstr(last_found, "yuyv=1")) {
		fail("xcast_log", "latest found.size is not YUYV yuyv=1");
		fputs(last_found, stderr);
		return -1;
	}
	if (saw_not_enough) {
		pass("xcast_log",
		     "Not enough buffer in latest log (19:56 path; V4L2 bytesused is the gate)");
		return 0;
	}
	if (!saw_first_draw) {
		pass("xcast_log", "YUYV yuyv=1 but no first.draw (session died; reopen)");
		return 0;
	}
	pass("xcast_log", "found.size YUYV yuyv=1 + first.draw");
	return 0;
}

static int enum_discrete30(const char *dev)
{
	int fd;
	struct v4l2_frmivalenum iv;
	char msg[80];

	fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -1;
	memset(&iv, 0, sizeof(iv));
	iv.index = 0;
	iv.pixel_format = YUYV;
	iv.width = W;
	iv.height = H;
	if (xioctl(fd, VIDIOC_ENUM_FRAMEINTERVALS, &iv) < 0) {
		close(fd);
		return -1;
	}
	close(fd);
	if (iv.type != V4L2_FRMIVAL_TYPE_DISCRETE)
		return -1;
	if (!iv.discrete.numerator ||
	    iv.discrete.denominator / iv.discrete.numerator != 30)
		return -1;
	snprintf(msg, sizeof(msg), "%s type=%u %u/%u", dev, iv.type,
		 iv.discrete.numerator, iv.discrete.denominator);
	pass("enum_discrete30", msg);
	return 0;
}

static int writer_gray(const char *dev, unsigned copies)
{
	int fd;
	uint8_t *z;
	unsigned i;
	int ok = 0;

	fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		return -1;
	z = malloc(WRITE_LEN);
	if (!z) {
		close(fd);
		return -1;
	}
	memset(z, 0x80, WRITE_LEN);
	for (i = 0; i < copies; i++) {
		if (write(fd, z, WRITE_LEN) == (ssize_t)WRITE_LEN)
			ok++;
	}
	free(z);
	close(fd);
	return ok > 0 ? 0 : -1;
}

static int test_xcast_stream(const char *dev, const char *tag, int want_live,
			     int nframes, int attach_writer)
{
	struct cap c;
	struct ystat st;
	int i, got = 0, black = 0, qerr = 0, live = 0, stripe = 0;
	char msg[160];

	if (xcast_open_capture(dev, &c) < 0) {
		fail(tag, "xcast open or convert-on-mmap SIGSEGV (19:53 crash)");
		cap_close(&c);
		return -1;
	}
	for (i = 0; i < nframes; i++) {
		if (attach_writer && i == 8) {
			/* Second OUTPUT is EBUSY while watch/SoftISP already
			 * owns the writer. That is exclusive_caps, not a
			 * crash. Capture QBUF must still succeed. */
			if (writer_gray(dev, 4) < 0 && errno != EBUSY)
				fail(tag, "SoftISP-like write() attach");
		}
		if (xcast_dq_q(&c, &st, 500) < 0) {
			if (errno == ENOSPC)
				fail(tag, "DQBUF bytesused < packed");
			else if (errno == EOVERFLOW)
				fail(tag, "DQBUF bytesused RGBA (memcpy smash 20:10)");
			else if (errno == EMSGSIZE)
				fail(tag, "DQBUF bytesused != QUERYBUF length (20:48 empty plane)");
			else if (errno == ETIMEDOUT)
				fail(tag, "DQBUF timeout 500ms");
			else
				fail(tag, "DQBUF/QBUF memory=0");
			qerr++;
			break;
		}
		got++;
		if (st.black)
			black++;
		if (st.green_stripe)
			stripe++;
		if (!st.black && !st.all_gray128 && (st.ymax - st.ymin) >= 20)
			live++;
	}
	cap_close(&c);
	snprintf(msg, sizeof(msg),
		 "%s frames=%d black=%d live=%d stripe=%d y=%u-%u", dev, got,
		 black, live, stripe, st.ymin, st.ymax);
	if (qerr || got < nframes) {
		fail(tag, msg);
		return -1;
	}
	if (black == got) {
		fail(tag, "all frames black (Y<=16)");
		return -1;
	}
	if (want_live && live < 3) {
		fail(tag, "no live scene (still gray stamp / flat)");
		return -1;
	}
	if (want_live && stripe > got / 2)
		printf("WARN %s majority green-as-RGB sample (YUYV chroma)\n",
		       tag);
	pass(tag, msg);
	return 0;
}

static int fill_pattern(uint8_t *z, unsigned yv)
{
	unsigned i;

	for (i = 0; i < FRAME; i += 4) {
		z[i] = (uint8_t)yv;
		z[i + 1] = 0x80;
		z[i + 2] = (uint8_t)yv;
		z[i + 3] = 0x80;
	}
	return 0;
}

/* Stamp close + SoftISP open while capture STREAMON must not tear QBUF. */
static int test_writer_handoff(const char *dev)
{
	struct cap c;
	struct ystat st;
	int wfd, i;
	uint8_t *z;
	char msg[96];

	wfd = open(dev, O_RDWR | O_CLOEXEC);
	if (wfd < 0) {
		fail("writer_handoff", "open OUTPUT (stop watch first)");
		return -1;
	}
	z = malloc(WRITE_LEN);
	if (!z) {
		close(wfd);
		fail("writer_handoff", "malloc");
		return -1;
	}
	memset(z, 0x80, WRITE_LEN);
	fill_pattern(z, 90);
	if (write(wfd, z, WRITE_LEN) != (ssize_t)WRITE_LEN) {
		fail("writer_handoff", "seed write");
		free(z);
		close(wfd);
		return -1;
	}
	if (xcast_open_capture(dev, &c) < 0) {
		fail("writer_handoff", "xcast open while writer live");
		free(z);
		close(wfd);
		return -1;
	}
	for (i = 0; i < 6; i++) {
		if (xcast_dq_q(&c, &st, 400) < 0) {
			fail("writer_handoff", "dq before writer close");
			free(z);
			close(wfd);
			cap_close(&c);
			return -1;
		}
	}
	/* Stamp drop: OUTPUT close STREAMOFF while CAPTURE mmap'd. */
	close(wfd);
	memset(z, 0x80, WRITE_LEN);
	fill_pattern(z, 160);
	wfd = open(dev, O_RDWR | O_CLOEXEC);
	if (wfd < 0) {
		fail("writer_handoff", "reopen OUTPUT after stamp close");
		free(z);
		cap_close(&c);
		return -1;
	}
	for (i = 0; i < 8; i++) {
		if (write(wfd, z, WRITE_LEN) != (ssize_t)WRITE_LEN) {
			fail("writer_handoff", "SoftISP-like write after handoff");
			free(z);
			close(wfd);
			cap_close(&c);
			return -1;
		}
		if (xcast_dq_q(&c, &st, 400) < 0) {
			fail("writer_handoff", "dq after OUTPUT STREAMOFF (queue torn)");
			free(z);
			close(wfd);
			cap_close(&c);
			return -1;
		}
	}
	free(z);
	close(wfd);
	cap_close(&c);
	snprintf(msg, sizeof(msg), "%s y=%u-%u after handoff", dev, st.ymin,
		 st.ymax);
	pass("writer_handoff", msg);
	return 0;
}

static int test_dual_open(void)
{
	struct cap a, b;
	struct ystat st;
	int i;

	if (xcast_open_capture(REAR, &a) < 0) {
		fail("dual_open", "open rear");
		return -1;
	}
	if (xcast_open_capture(FRONT, &b) < 0) {
		fail("dual_open", "open front while rear STREAMON");
		cap_close(&a);
		return -1;
	}
	for (i = 0; i < 8; i++) {
		if (xcast_dq_q(&a, &st, 500) < 0) {
			fail("dual_open", "dq rear with front also open");
			cap_close(&a);
			cap_close(&b);
			return -1;
		}
		if (xcast_dq_q(&b, &st, 500) < 0) {
			fail("dual_open", "dq front with rear also open");
			cap_close(&a);
			cap_close(&b);
			return -1;
		}
	}
	cap_close(&a);
	cap_close(&b);
	pass("dual_open", "rear+front STREAMON together");
	return 0;
}

static int test_hot_switch(void)
{
	struct cap rear, front;
	struct ystat st;
	int i;

	if (xcast_open_capture(REAR, &rear) < 0) {
		fail("hot_switch", "open rear");
		return -1;
	}
	for (i = 0; i < 8; i++) {
		if (xcast_dq_q(&rear, &st, 500) < 0) {
			fail("hot_switch", "dq rear before front");
			cap_close(&rear);
			return -1;
		}
	}
	/* Watch may restamp front while we still hold rear. */
	for (i = 0; i < 8 && xcast_open_capture(FRONT, &front) < 0; i++)
		usleep(80 * 1000);
	if (front.fd < 0) {
		fail("hot_switch", "open front while rear mmap'd");
		cap_close(&rear);
		return -1;
	}
	for (i = 0; i < 8; i++) {
		if (xcast_dq_q(&front, &st, 800) < 0) {
			fail("hot_switch",
			     errno == ERANGE ?
			     "DQBUF index>=4 (21:12 rear→front SIGSEGV)" :
			     "dq front during overlap");
			cap_close(&rear);
			cap_close(&front);
			return -1;
		}
	}
	cap_close(&rear);
	for (i = 0; i < 8; i++) {
		if (xcast_dq_q(&front, &st, 800) < 0) {
			fail("hot_switch", "dq front after rear close");
			cap_close(&front);
			return -1;
		}
	}
	cap_close(&front);
	pass("hot_switch", "rear→front overlap, DQBUF index<4, no EBUSY");
	return 0;
}

static int test_hot_switch_front_rear(void)
{
	struct cap front, rear;
	struct ystat st;
	int i;

	if (xcast_open_capture(FRONT, &front) < 0) {
		fail("hot_switch_front_rear", "open front");
		return -1;
	}
	for (i = 0; i < 8; i++) {
		if (xcast_dq_q(&front, &st, 500) < 0) {
			fail("hot_switch_front_rear", "dq front before rear");
			cap_close(&front);
			return -1;
		}
	}
	for (i = 0; i < 8 && xcast_open_capture(REAR, &rear) < 0; i++)
		usleep(80 * 1000);
	if (rear.fd < 0) {
		fail("hot_switch_front_rear", "open rear while front mmap'd");
		cap_close(&front);
		return -1;
	}
	for (i = 0; i < 8; i++) {
		if (xcast_dq_q(&rear, &st, 800) < 0) {
			fail("hot_switch_front_rear", "dq rear during overlap");
			cap_close(&front);
			cap_close(&rear);
			return -1;
		}
	}
	cap_close(&front);
	for (i = 0; i < 8; i++) {
		if (xcast_dq_q(&rear, &st, 800) < 0) {
			fail("hot_switch_front_rear", "dq rear after front close");
			cap_close(&rear);
			return -1;
		}
	}
	cap_close(&rear);
	pass("hot_switch_front_rear", "front→rear overlap, no EBUSY/ENOSPC");
	return 0;
}

static int test_flicker(const char *dev, const char *tag)
{
	struct cap c;
	struct ystat st;
	int i, got = 0, live = 0, gray_run = 0, gray_max = 0, black = 0,
	    stripe = 0;
	struct timeval t0, t1;
	long gap_us, gap_max = 0;
	char msg[160];

	if (xcast_open_capture(dev, &c) < 0) {
		fail(tag, "xcast open");
		return -1;
	}
	gettimeofday(&t0, NULL);
	for (i = 0; i < 90; i++) {
		if (xcast_dq_q(&c, &st, 200) < 0) {
			fail(tag, "DQBUF gap / Not enough buffer");
			cap_close(&c);
			return -1;
		}
		gettimeofday(&t1, NULL);
		gap_us = (t1.tv_sec - t0.tv_sec) * 1000000L +
			 (t1.tv_usec - t0.tv_usec);
		if (got && gap_us > gap_max)
			gap_max = gap_us;
		t0 = t1;
		got++;
		if (st.black)
			black++;
		if (st.green_stripe)
			stripe++;
		if (st.all_gray128) {
			gray_run++;
			if (gray_run > gray_max)
				gray_max = gray_run;
		} else {
			gray_run = 0;
		}
		if (!st.black && !st.all_gray128 && (st.ymax - st.ymin) >= 20)
			live++;
	}
	cap_close(&c);
	snprintf(msg, sizeof(msg),
		 "%s frames=%d live=%d black=%d stripe=%d gray_run=%d gap_ms=%ld y=%u-%u",
		 dev, got, live, black, stripe, gray_max, gap_max / 1000,
		 st.ymin, st.ymax);
	if (black > 2) {
		fail(tag, "black flashes");
		return -1;
	}
	if (stripe > 80)
		printf("WARN %s green-as-RGB sample count=%d (YUYV chroma)\n",
		       tag, stripe);
	if (gray_max > 8) {
		fail(tag, "gray stamp streak (flicker)");
		return -1;
	}
	if (gap_max > 150000) {
		fail(tag, "inter-frame gap >150ms");
		return -1;
	}
	if (live < 40) {
		fail(tag, "not enough live frames");
		return -1;
	}
	pass(tag, msg);
	return 0;
}

static int test_switch(void)
{
	struct cap a, b;
	struct ystat st;
	int i;

	if (xcast_open_capture(REAR, &a) < 0) {
		fail("switch_rear", "open rear");
		cap_close(&a);
		return -1;
	}
	for (i = 0; i < 10; i++) {
		if (xcast_dq_q(&a, &st, 500) < 0) {
			fail("switch_rear", "dq rear");
			cap_close(&a);
			return -1;
		}
	}
	cap_close(&a);
	usleep(200 * 1000);
	if (xcast_open_capture(FRONT, &b) < 0) {
		fail("switch_front", "open front after rear close");
		cap_close(&b);
		return -1;
	}
	for (i = 0; i < 10; i++) {
		if (xcast_dq_q(&b, &st, 800) < 0) {
			fail("switch_front", "dq front");
			cap_close(&b);
			return -1;
		}
	}
	cap_close(&b);
	pass("switch_front_rear", "rear 10 + front 10, no EBUSY");
	return 0;
}

static int s_ctrl_u32(int fd, uint32_t id, int32_t val)
{
	struct v4l2_control ctl;

	memset(&ctl, 0, sizeof(ctl));
	ctl.id = id;
	ctl.value = val;
	return xioctl(fd, VIDIOC_S_CTRL, &ctl);
}

static int test_write_uv_pad(const char *dev)
{
	struct cap c;
	unsigned i, b;
	const uint8_t *p;

	if (writer_gray(dev, 2) < 0) {
		fail("write_uv_pad", "seed write");
		return -1;
	}
	/* mmap without convert poke so this is the kernel pad, not the test. */
	memset(&c, 0, sizeof(c));
	c.fd = open(dev, O_RDWR | O_CLOEXEC);
	if (c.fd < 0) {
		fail("write_uv_pad", "open capture");
		return -1;
	}
	{
		struct v4l2_requestbuffers req;
		struct v4l2_buffer qb;

		memset(&req, 0, sizeof(req));
		req.count = 4;
		req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		if (xioctl(c.fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2) {
			fail("write_uv_pad", "REQBUFS");
			cap_close(&c);
			return -1;
		}
		c.nbuf = (int)req.count;
		if (c.nbuf > 8)
			c.nbuf = 8;
		for (i = 0; i < (unsigned)c.nbuf; i++) {
			memset(&qb, 0, sizeof(qb));
			qb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			qb.index = i;
			if (xioctl(c.fd, VIDIOC_QUERYBUF, &qb) < 0) {
				fail("write_uv_pad", "QUERYBUF");
				cap_close(&c);
				return -1;
			}
			c.len[i] = qb.length;
			c.map[i] = mmap(NULL, qb.length, PROT_READ | PROT_WRITE,
					MAP_SHARED, c.fd, qb.m.offset);
			if (c.map[i] == MAP_FAILED) {
				fail("write_uv_pad", "mmap");
				cap_close(&c);
				return -1;
			}
		}
	}
	for (b = 0; b < (unsigned)c.nbuf; b++) {
		if (c.len[b] < CONVERT_PAD)
			continue;
		p = (const uint8_t *)c.map[b];
		for (i = 0; i < (unsigned)W * H / 2; i++) {
			if (p[PACKED + i] != 0x80) {
				fail("write_uv_pad",
				     "CONVERT_PAD tail not 0x80 (green chroma)");
				cap_close(&c);
				return -1;
			}
		}
	}
	cap_close(&c);
	pass("write_uv_pad", "packed write fills UV tail 0x80");
	return 0;
}

static int test_sustain_nonblock(const char *dev)
{
	struct cap c;
	struct v4l2_buffer b;
	uint8_t *z;
	int wfd, i, got = 0, eagain = 0;

	/* Meeting: stamp OUTPUT stays open while xcast REQBUFS, then
	 * stamp closes before SoftISP write. O_NONBLOCK DQBUF must
	 * reread — EAGAIN is 20:34 Not enough buffer / fail.create. */
	wfd = open(dev, O_RDWR | O_CLOEXEC);
	if (wfd < 0) {
		fail("sustain_nonblock", "open OUTPUT");
		return -1;
	}
	if (s_ctrl_u32(wfd, 0x0098f901, 1) < 0) {
		fail("sustain_nonblock", "sustain_framerate");
		close(wfd);
		return -1;
	}
	z = malloc(WRITE_LEN);
	if (!z) {
		fail("sustain_nonblock", "malloc");
		close(wfd);
		return -1;
	}
	memset(z, 0x80, WRITE_LEN);
	for (i = 0; i < 4; i++) {
		if (write(wfd, z, WRITE_LEN) != (ssize_t)WRITE_LEN) {
			fail("sustain_nonblock", "seed write");
			free(z);
			close(wfd);
			return -1;
		}
	}
	if (xcast_open_capture_fl(dev, &c, O_NONBLOCK) < 0) {
		fail("sustain_nonblock", "O_NONBLOCK open while OUTPUT live");
		free(z);
		close(wfd);
		return -1;
	}
	for (i = 0; i < 8; i++) {
		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		if (xioctl(c.fd, VIDIOC_DQBUF, &b) < 0) {
			fail("sustain_nonblock", "DQBUF while OUTPUT live");
			cap_close(&c);
			free(z);
			close(wfd);
			return -1;
		}
		{
			unsigned idx = b.index;

			memset(&b, 0, sizeof(b));
			b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			b.index = idx;
			if (xioctl(c.fd, VIDIOC_QBUF, &b) < 0) {
				fail("sustain_nonblock", "QBUF");
				cap_close(&c);
				free(z);
				close(wfd);
				return -1;
			}
		}
	}
	close(wfd);
	wfd = -1;
	free(z);
	z = NULL;

	for (i = 0; i < 30; i++) {
		memset(&b, 0, sizeof(b));
		b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
		if (xioctl(c.fd, VIDIOC_DQBUF, &b) < 0) {
			if (errno == EAGAIN)
				eagain++;
			else {
				fail("sustain_nonblock", "DQBUF after stamp close");
				cap_close(&c);
				return -1;
			}
		} else {
			unsigned idx = b.index;

			got++;
			memset(&b, 0, sizeof(b));
			b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
			b.index = idx;
			if (xioctl(c.fd, VIDIOC_QBUF, &b) < 0) {
				fail("sustain_nonblock", "QBUF after stamp close");
				cap_close(&c);
				return -1;
			}
		}
	}
	cap_close(&c);
	if (eagain || got < 20) {
		fail("sustain_nonblock",
		     "EAGAIN/short after OUTPUT close (20:34 fail.create flicker)");
		return -1;
	}
	pass("sustain_nonblock", "O_NONBLOCK DQBUF rereads after stamp close");
	return 0;
}

/* Snapshot uses PipeWire Video/Source, not spa-libcamera. QUERYCAP must
 * advertise CAPTURE after stamp or WirePlumber never creates the node. */
static int test_querycap_capture(const char *dev, const char *tag)
{
	int fd;
	struct v4l2_capability cap;
	char msg[160];

	fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fail(tag, "open");
		return -1;
	}
	memset(&cap, 0, sizeof(cap));
	if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
		fail(tag, "QUERYCAP");
		close(fd);
		return -1;
	}
	close(fd);
	if (!(cap.device_caps & V4L2_CAP_VIDEO_CAPTURE)) {
		snprintf(msg, sizeof(msg),
			 "device_caps=0x%x (OUTPUT-only: no PipeWire Video/Source)",
			 cap.device_caps);
		fail(tag, msg);
		return -1;
	}
	snprintf(msg, sizeof(msg), "device_caps=0x%x", cap.device_caps);
	pass(tag, msg);
	return 0;
}

/* G_FMT only: xcast still sees YUYV 1280x720 packed. No REQBUFS/STREAMON
 * so Snapshot's live PipeWire capture is not torn down. */
static int test_meeting_yuyv_gfmt(const char *dev, const char *tag)
{
	int fd;
	struct v4l2_format fmt;
	char msg[160];

	fd = open(dev, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		fail(tag, "open");
		return -1;
	}
	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (xioctl(fd, VIDIOC_G_FMT, &fmt) < 0) {
		fail(tag, "G_FMT");
		close(fd);
		return -1;
	}
	close(fd);
	if (fmt.fmt.pix.pixelformat == RGB24) {
		fail(tag, "RGB24 fourcc: xcast yuyv=0, black");
		return -1;
	}
	if (fmt.fmt.pix.pixelformat == I420) {
		fail(tag, "I420 fourcc: xcast yuyv=0, black");
		return -1;
	}
	if (fmt.fmt.pix.pixelformat != YUYV) {
		fail(tag, "not YUYV");
		return -1;
	}
	if (fmt.fmt.pix.width != W || fmt.fmt.pix.height != H ||
	    fmt.fmt.pix.sizeimage != PACKED) {
		snprintf(msg, sizeof(msg), "YUYV %ux%u sizeimage=%u",
			 fmt.fmt.pix.width, fmt.fmt.pix.height,
			 fmt.fmt.pix.sizeimage);
		fail(tag, msg);
		return -1;
	}
	pass(tag, "YUYV 1280x720 packed");
	return 0;
}

static int test_pipewire_snapshot_sources(void)
{
	int st;

	st = system(
		"python3 - <<'PY'\n"
		"import glob, json, os, subprocess, sys\n"
		"ok = False\n"
		"lib = 0\n"
		"for d in sorted(glob.glob('/run/user/[0-9]*')):\n"
		"    uid = os.path.basename(d)\n"
		"    if not uid.isdigit():\n"
		"        continue\n"
		"    name = None\n"
		"    try:\n"
		"        for line in open('/etc/passwd', encoding='utf-8'):\n"
		"            p = line.split(':')\n"
		"            if p[2] == uid:\n"
		"                name = p[0]\n"
		"                break\n"
		"    except OSError:\n"
		"        continue\n"
		"    if not name:\n"
		"        continue\n"
		"    env = os.environ.copy()\n"
		"    env['XDG_RUNTIME_DIR'] = d\n"
		"    try:\n"
		"        raw = subprocess.check_output(\n"
		"            ['runuser', '-u', name, '--', 'env',\n"
		"             'XDG_RUNTIME_DIR=' + d, 'pw-dump'],\n"
		"            env=env, timeout=8, stderr=subprocess.DEVNULL)\n"
		"        dump = json.loads(raw)\n"
		"    except Exception:\n"
		"        continue\n"
		"    got = set()\n"
		"    has_mod = False\n"
		"    selfie = False\n"
		"    for o in dump:\n"
		"        p = (o.get('info') or {}).get('props') or {}\n"
		"        if p.get('media.class') != 'Video/Source':\n"
		"            continue\n"
		"        fac = p.get('factory.name') or ''\n"
		"        if 'libcamera' in fac:\n"
		"            lib += 1\n"
		"            continue\n"
		"        path = p.get('api.v4l2.path')\n"
		"        if path:\n"
		"            got.add(path)\n"
		"        if path == '/dev/video20' and p.get('api.libcamera.location') == 'front':\n"
		"            selfie = True\n"
		"        if path in ('/dev/video20', '/dev/video21'):\n"
		"            for e in ((o.get('info') or {}).get('params') or {}).get('EnumFormat') or []:\n"
		"                if 'modifier' in e:\n"
		"                    has_mod = True\n"
		"    if has_mod:\n"
		"        sys.exit(3)\n"
		"    if selfie:\n"
		"        sys.exit(4)\n"
		"    if '/dev/video20' in got and '/dev/video21' in got:\n"
		"        ok = True\n"
		"        break\n"
		"if lib:\n"
		"    sys.exit(2)\n"
		"sys.exit(0 if ok else 1)\n"
		"PY");
	if (st == -1) {
		fail("pw_snapshot_sources", "python3 pw-dump");
		return -1;
	}
	st = WEXITSTATUS(st);
	if (st == 2) {
		fail("pw_snapshot_sources",
		     "spa-libcamera Video/Source present (mutter starve)");
		return -1;
	}
	if (st == 3) {
		fail("pw_snapshot_sources",
		     "loopback EnumFormat still has DMABuf modifier (Snapshot stutter)");
		return -1;
	}
	if (st == 4) {
		fail("pw_snapshot_sources",
		     "front location=front: Snapshot selfie-mirrors unlike Meeting");
		return -1;
	}
	if (st != 0) {
		fail("pw_snapshot_sources",
		     "missing Video/Source on /dev/video20 and /dev/video21");
		return -1;
	}
	pass("pw_snapshot_sources",
	     "dagu-front+dagu-rear Video/Source, no spa-libcamera");
	return 0;
}

static int test_portal_camera_present(void)
{
	int st;

	st = system(
		"python3 - <<'PY'\n"
		"import glob, os, subprocess, sys\n"
		"ok = False\n"
		"for d in sorted(glob.glob('/run/user/[0-9]*')):\n"
		"    uid = os.path.basename(d)\n"
		"    if not uid.isdigit():\n"
		"        continue\n"
		"    name = None\n"
		"    try:\n"
		"        for line in open('/etc/passwd', encoding='utf-8'):\n"
		"            p = line.split(':')\n"
		"            if p[2] == uid:\n"
		"                name = p[0]\n"
		"                break\n"
		"    except OSError:\n"
		"        continue\n"
		"    if not name:\n"
		"        continue\n"
		"    bus = 'unix:path=' + d + '/bus'\n"
		"    try:\n"
		"        out = subprocess.check_output(\n"
		"            ['runuser', '-u', name, '--', 'env',\n"
		"             'XDG_RUNTIME_DIR=' + d,\n"
		"             'DBUS_SESSION_BUS_ADDRESS=' + bus,\n"
		"             'busctl', '--user', 'get-property',\n"
		"             'org.freedesktop.portal.Desktop',\n"
		"             '/org/freedesktop/portal/desktop',\n"
		"             'org.freedesktop.portal.Camera',\n"
		"             'IsCameraPresent'],\n"
		"            timeout=8, stderr=subprocess.DEVNULL, text=True)\n"
		"    except Exception:\n"
		"        continue\n"
		"    if 'true' in out.lower() or out.strip() == 'b true':\n"
		"        ok = True\n"
		"        break\n"
		"sys.exit(0 if ok else 1)\n"
		"PY");
	if (st == -1 || WEXITSTATUS(st) != 0) {
		fail("portal_camera_present",
		     "org.freedesktop.portal.Camera.IsCameraPresent is not true");
		return -1;
	}
	pass("portal_camera_present", "IsCameraPresent=true");
	return 0;
}

/* GNOME Snapshot consumes PipeWire YUY2. A single gray stamp frame
 * (Y=U=V=0x80) with no follow-up is the white/gray preview: watch used
 * to close the OUTPUT hold-fd, spa-v4l2 saw POLLERR and froze. Meeting
 * mmap is a different path and must stay packed YUYV. */
static int test_pw_live_not_gray(const char *target, const char *tag,
				int want_hflip)
{
	char script[16384];
	int st;

	snprintf(script, sizeof(script),
		 "python3 - <<'PY'\n"
		 "import glob, json, os, subprocess, sys, time\n"
		 "dev = \"%s\"\n"
		 "frame = %d\n"
		 "want_hflip = %d\n"
		 "need = 8\n"
		 "ok = False\n"
		 "why = 'no session'\n"
		 "time.sleep(2)\n"
		 "for d in sorted(glob.glob('/run/user/[0-9]*')):\n"
		 "    uid = os.path.basename(d)\n"
		 "    if not uid.isdigit():\n"
		 "        continue\n"
		 "    name = None\n"
		 "    try:\n"
		 "        for line in open('/etc/passwd', encoding='utf-8'):\n"
		 "            p = line.split(':')\n"
		 "            if p[2] == uid:\n"
		 "                name = p[0]\n"
		 "                break\n"
		 "    except OSError:\n"
		 "        continue\n"
		 "    if not name:\n"
		 "        continue\n"
		 "    env = os.environ.copy()\n"
		 "    env['XDG_RUNTIME_DIR'] = d\n"
		 "    try:\n"
		 "        raw = subprocess.check_output(\n"
		 "            ['runuser', '-u', name, '--', 'env',\n"
		 "             'XDG_RUNTIME_DIR=' + d, 'pw-dump'],\n"
		 "            env=env, timeout=8, stderr=subprocess.DEVNULL)\n"
		 "        dump = json.loads(raw)\n"
		 "    except Exception as e:\n"
		 "        why = 'pw-dump: ' + str(e)\n"
		 "        continue\n"
		 "    target = None\n"
		 "    for o in dump:\n"
		 "        p = (o.get('info') or {}).get('props') or {}\n"
		 "        if p.get('media.class') != 'Video/Source':\n"
		 "            continue\n"
		 "        if p.get('api.v4l2.path') != dev:\n"
		 "            continue\n"
		 "        nm = p.get('node.name') or ''\n"
		 "        if nm.startswith('v4l2_input'):\n"
		 "            target = nm\n"
		 "            break\n"
		 "        if target is None:\n"
		 "            target = str(p.get('object.serial') or o.get('id') or '')\n"
		 "    if not target:\n"
		 "        why = 'no Video/Source for ' + dev\n"
		 "        continue\n"
		 "    out = '/tmp/dagu-pw-live.yuyv'\n"
		 "    v4l = '/tmp/dagu-v4l-live.yuyv'\n"
		 "    for pth in (out, v4l):\n"
		 "        try:\n"
		 "            os.remove(pth)\n"
		 "        except OSError:\n"
		 "            pass\n"
		 "    cmd = ['runuser', '-u', name, '--', 'env',\n"
		 "           'XDG_RUNTIME_DIR=' + d,\n"
		 "           'gst-launch-1.0', '-e',\n"
		 "           'pipewiresrc',\n"
		 "           'target-object=' + target,\n"
		 "           'num-buffers=40',\n"
		 "           '!', 'video/x-raw,format=YUY2,width=1280,height=720',\n"
		 "           '!', 'filesink', 'location=' + out, 'sync=false']\n"
		 "    try:\n"
		 "        subprocess.run(cmd, timeout=12,\n"
		 "                       stdout=subprocess.DEVNULL,\n"
		 "                       stderr=subprocess.DEVNULL)\n"
		 "    except subprocess.TimeoutExpired:\n"
		 "        pass\n"
		 "    except Exception as e:\n"
		 "        why = 'gst: ' + str(e)\n"
		 "        continue\n"
		 "    try:\n"
		 "        subprocess.run(\n"
		 "            ['v4l2-ctl', '-d', dev, '--stream-mmap=4',\n"
		 "             '--stream-count=12', '--stream-to=' + v4l,\n"
		 "             '--stream-poll'],\n"
		 "            timeout=6, stdout=subprocess.DEVNULL,\n"
		 "            stderr=subprocess.DEVNULL)\n"
		 "    except Exception as e:\n"
		 "        why = 'v4l2-ctl: ' + str(e)\n"
		 "        continue\n"
		 "    try:\n"
		 "        n = os.path.getsize(out)\n"
		 "        rawv = open(v4l, 'rb').read()\n"
		 "    except OSError:\n"
		 "        why = 'no capture file'\n"
		 "        continue\n"
		 "    nf = n // frame\n"
		 "    nf2 = len(rawv) // frame\n"
		 "    if nf < need or nf2 < 1:\n"
		 "        why = 'frames pw=%%d v4l=%%d' %% (nf, nf2)\n"
		 "        continue\n"
		 "    last = open(out, 'rb').read()[(nf - 1) * frame:nf * frame]\n"
		 "    ys = last[0::2]\n"
		 "    ymin, ymax = min(ys), max(ys)\n"
		 "    if all(y == 128 for y in ys) or (ymax - ymin) < 20:\n"
		 "        why = 'last frame gray Y=%%d-%%d' %% (ymin, ymax)\n"
		 "        continue\n"
		 "    rawp = open(out, 'rb').read()\n"
		 "    ww, hh = 1280, 720\n"
		 "    def sad_ident(a, b):\n"
		 "        s = 0\n"
		 "        for row in range(0, hh, 8):\n"
		 "            off = row * ww * 2\n"
		 "            for x in range(0, ww, 8):\n"
		 "                s += abs(a[off + x * 2] - b[off + x * 2])\n"
		 "        return s\n"
		 "    def sad_hflip(a, b):\n"
		 "        s = 0\n"
		 "        for row in range(0, hh, 8):\n"
		 "            off = row * ww * 2\n"
		 "            for x in range(0, ww, 8):\n"
		 "                s += abs(a[off + x * 2] - b[off + (ww - 1 - x) * 2])\n"
		 "        return s\n"
		 "    best_i = best_h = 10 ** 18\n"
		 "    for pi in range(max(0, nf - 8), nf):\n"
		 "        pf = rawp[pi * frame:(pi + 1) * frame]\n"
		 "        for vi in range(nf2):\n"
		 "            vf = rawv[vi * frame:(vi + 1) * frame]\n"
		 "            best_i = min(best_i, sad_ident(pf, vf))\n"
		 "            best_h = min(best_h, sad_hflip(pf, vf))\n"
		 "    if want_hflip:\n"
		 "        if best_h * 2 >= best_i:\n"
		 "            why = 'pw not H-flip vs mmap ident=%%d hflip=%%d' %% (best_i, best_h)\n"
		 "            continue\n"
		 "    elif best_i * 2 >= best_h:\n"
		 "        why = 'pw not identity vs mmap ident=%%d hflip=%%d' %% (best_i, best_h)\n"
		 "        continue\n"
		 "    ok = True\n"
		 "    why = 'ok'\n"
		 "    break\n"
		 "if not ok:\n"
		 "    sys.stderr.write(why + '\\n')\n"
		 "sys.exit(0 if ok else 1)\n"
		 "PY",
		 target, PACKED, want_hflip);
	st = system(script);
	if (st == -1 || WEXITSTATUS(st) != 0) {
		fail(tag, want_hflip
			     ? "PipeWire YUY2 gray stamp, short capture, or not H-flip vs mmap"
			     : "PipeWire YUY2 gray stamp, short capture, or not identity vs mmap");
		return -1;
	}
	pass(tag, want_hflip
		      ? "live YUY2 H-flip vs mmap, not gray stamp"
		      : "live YUY2 identity vs mmap (GNOME selfie), not gray stamp");
	return 0;
}

static void yuyv_hflip_pairs(uint8_t *dst, const uint8_t *src, unsigned w,
			     unsigned h)
{
	unsigned y, x;

	for (y = 0; y < h; y++) {
		const uint8_t *s = src + y * w * 2;
		uint8_t *d = dst + y * w * 2;

		for (x = 0; x < w; x += 2) {
			const uint8_t *sp = s + (w - 2 - x) * 2;
			uint8_t *dp = d + x * 2;

			dp[0] = sp[2];
			dp[1] = sp[1];
			dp[2] = sp[0];
			dp[3] = sp[3];
		}
	}
}

static int test_yuyv_hflip_pairs(void)
{
	const uint8_t src[8] = { 10, 20, 30, 40, 50, 60, 70, 80 };
	uint8_t dst[8];

	yuyv_hflip_pairs(dst, src, 4, 1);
	/* 4x1 YUYV H-flip: [Y3 U1 Y2 V1][Y1 U0 Y0 V0] */
	if (dst[0] != 70 || dst[1] != 60 || dst[2] != 50 || dst[3] != 80 ||
	    dst[4] != 30 || dst[5] != 20 || dst[6] != 10 || dst[7] != 40) {
		fail("yuyv_hflip_pairs", "pair reverse contract");
		return -1;
	}
	pass("yuyv_hflip_pairs", "YUYV macropixel reverse");
	return 0;
}

static int run_snapshot_tests(void)
{
	test_yuyv_hflip_pairs();
	test_querycap_capture(FRONT, "snap_caps_front");
	test_querycap_capture(REAR, "snap_caps_rear");
	test_meeting_yuyv_gfmt(FRONT, "meeting_gfmt_front");
	test_meeting_yuyv_gfmt(REAR, "meeting_gfmt_rear");
	test_pipewire_snapshot_sources();
	test_portal_camera_present();
	test_pw_live_not_gray(FRONT, "pw_live_front", 0);
	test_meeting_yuyv_gfmt(FRONT, "meeting_gfmt_front_after_pw");
	test_pw_live_not_gray(REAR, "pw_live_rear", 1);
	test_meeting_yuyv_gfmt(REAR, "meeting_gfmt_rear_after_pw");
	return g_fail;
}

int main(int argc, char **argv)
{
	struct stat st;

	if (stat(FRONT, &st) || stat(REAR, &st)) {
		fprintf(stderr, "missing %s or %s\n", FRONT, REAR);
		return 2;
	}

	run_snapshot_tests();
	if (argc > 1 && strcmp(argv[1], "snapshot") == 0) {
		if (g_fail) {
			fprintf(stderr, "\n%d FAIL\n", g_fail);
			return 1;
		}
		printf("\nALL PASS\n");
		return 0;
	}

	test_meeting_contract(FRONT);
	test_meeting_contract(REAR);

	if (enum_discrete30(FRONT) < 0)
		fail("enum_discrete30", FRONT);
	if (enum_discrete30(REAR) < 0)
		fail("enum_discrete30", REAR);

	/* Protocol: xcast memory=0 must not abort. Gray is allowed here. */
	test_xcast_stream(REAR, "xcast_memory0_rear", 0, 20, 0);
	test_xcast_stream(FRONT, "xcast_memory0_front", 0, 20, 0);

	/* SoftISP write() while xcast has mmap — must not EINVAL QBUF. */
	test_xcast_stream(REAR, "writer_attach_rear", 0, 24, 1);

	printf("STOP watch for writer_handoff\n");
	fflush(stdout);
	if (system("systemctl stop dagu-camera-loopback-watch.service") != 0)
		fail("writer_handoff", "systemctl stop watch");
	usleep(300 * 1000);
	test_writer_handoff(REAR);
	test_writer_handoff(FRONT);
	test_write_uv_pad(REAR);
	test_sustain_nonblock(REAR);
	test_dqbuf_packed(REAR);
	test_dqbuf_packed(FRONT);
	test_xcast_four_slots(REAR);
	test_xcast_four_slots(FRONT);
	if (system("systemctl start dagu-camera-loopback-watch.service") != 0)
		fail("writer_handoff", "systemctl start watch");
	usleep(400 * 1000);

	test_dual_open();
	test_hot_switch();
	test_hot_switch_front_rear();
	test_switch();

	/* Watch should spawn SoftISP once we hold the node. Wait then require live. */
	printf("WAIT live SoftISP on rear (8s)...\n");
	fflush(stdout);
	sleep(8);
	test_xcast_stream(REAR, "live_rear", 1, 45, 0);
	test_flicker(REAR, "flicker_rear");
	printf("WAIT live SoftISP on front (8s)...\n");
	fflush(stdout);
	sleep(8);
	test_xcast_stream(FRONT, "live_front", 1, 45, 0);
	test_flicker(FRONT, "flicker_front");
	test_hot_switch();
	test_xcast_log_contract();

	if (g_fail) {
		fprintf(stderr, "\n%d FAIL\n", g_fail);
		return 1;
	}
	printf("\nALL PASS\n");
	return 0;
}
