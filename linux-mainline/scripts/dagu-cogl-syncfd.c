/* LD_PRELOAD for gnome-shell + libmutter-cogl-18.
 *
 * Mutter 50.1 meta_wayland_buffer_dec_use_count → handle_release_points
 * calls cogl_context_get_latest_sync_fd() and BAILS when it returns -1
 * ("Invalid Sync Fd returned by COGL"). The wp_linux_drm_syncobj
 * release timeline is then never signaled. Chrome Ozone WaitForSwap
 * sits on that point for 80–180 ms whenever a skipped paint / idle
 * Cogl context has no latest GPU work.
 *
 * Protocol allows releasing a buffer without reading it. A signaled
 * dummy sync_file is the correct out-fence in that case.
 *
 * This does NOT call dec_use_count and does NOT release live dmabufs
 * early (that hook made kickoff max 658–986 ms).
 *
 * Build:
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall \
 *     -o linux-mainline/scripts/libdagu-cogl-syncfd.so \
 *     linux-mainline/scripts/dagu-cogl-syncfd.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#ifndef DRM_IOCTL_BASE
#define DRM_IOCTL_BASE 'd'
#define DRM_IOWR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)
#endif

struct drm_syncobj_create {
	uint32_t handle;
	uint32_t flags;
};

struct drm_syncobj_handle {
	uint32_t handle;
	uint32_t flags;
	int32_t fd;
	uint32_t pad;
};

struct drm_syncobj_destroy {
	uint32_t handle;
	uint32_t pad;
};

#define DRM_SYNCOBJ_CREATE_SIGNALED (1u << 0)
#define DRM_SYNCOBJ_HANDLE_TO_FD_FLAGS_EXPORT_SYNC_FILE (1u << 0)
#define DRM_IOCTL_SYNCOBJ_CREATE DRM_IOWR(0xBF, struct drm_syncobj_create)
#define DRM_IOCTL_SYNCOBJ_DESTROY DRM_IOWR(0xC0, struct drm_syncobj_destroy)
#define DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD DRM_IOWR(0xC1, struct drm_syncobj_handle)

static int (*real_latest)(void *);
static int dummy_fd = -1;
static int last_good = -1;
static int logfd = -1;
static unsigned miss_n, hit_n, dummy_n;

static void log_line(const char *msg)
{
	char b[192];
	int n;

	if (logfd < 0)
		return;
	n = snprintf(b, sizeof(b), "cogl-syncfd %s miss=%u hit=%u dummy=%u last=%d\n",
		     msg, miss_n, hit_n, dummy_n, last_good);
	if (n > 0)
		(void)write(logfd, b, (size_t)n);
}

static int make_signaled_sync_fd(void)
{
	int drm, fd = -1;
	struct drm_syncobj_create cr = { .flags = DRM_SYNCOBJ_CREATE_SIGNALED };
	struct drm_syncobj_handle ex = {
		.flags = DRM_SYNCOBJ_HANDLE_TO_FD_FLAGS_EXPORT_SYNC_FILE,
	};
	struct drm_syncobj_destroy ds;

	drm = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	if (drm < 0)
		drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (drm < 0)
		return -1;
	if (ioctl(drm, DRM_IOCTL_SYNCOBJ_CREATE, &cr) != 0) {
		close(drm);
		return -1;
	}
	ex.handle = cr.handle;
	if (ioctl(drm, DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD, &ex) == 0)
		fd = ex.fd;
	ds.handle = cr.handle;
	ds.pad = 0;
	(void)ioctl(drm, DRM_IOCTL_SYNCOBJ_DESTROY, &ds);
	close(drm);
	return fd;
}

static int dup_or_dummy(int src)
{
	int fd;

	if (src >= 0) {
		fd = dup(src);
		if (fd >= 0)
			return fd;
	}
	if (dummy_fd < 0)
		dummy_fd = make_signaled_sync_fd();
	if (dummy_fd >= 0) {
		fd = dup(dummy_fd);
		if (fd >= 0) {
			dummy_n++;
			return fd;
		}
	}
	return -1;
}

__attribute__((constructor))
static void init(void)
{
	logfd = open("/tmp/dagu-cogl-syncfd.log", O_RDWR | O_CREAT | O_APPEND, 0644);
	real_latest = dlsym(RTLD_NEXT, "cogl_context_get_latest_sync_fd");
	if (!real_latest)
		real_latest = dlsym(RTLD_DEFAULT, "cogl_context_get_latest_sync_fd");
	dummy_fd = make_signaled_sync_fd();
	log_line(real_latest ? "init" : "init_no_real");
}

int
cogl_context_get_latest_sync_fd(void *ctx)
{
	int fd = -1;

	if (real_latest)
		fd = real_latest(ctx);
	if (fd >= 0) {
		if (last_good >= 0)
			close(last_good);
		last_good = dup(fd);
		hit_n++;
		if ((hit_n & 31) == 1)
			log_line("hit");
		return fd;
	}
	miss_n++;
	fd = dup_or_dummy(last_good);
	if ((miss_n & 63) == 1)
		log_line("fallback");
	return fd;
}
