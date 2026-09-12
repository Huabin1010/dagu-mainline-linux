#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/*
 * Resources (net.nokyan.Resources) looks at PC-centric sysfs:
 *   GPU: /sys/class/drm/card?/device/gpu_busy_percent + hwmon freq/temp
 * On dagu, card0 is msm_dpu; Adreno is 3d00000.gpu (devfreq + TSENS).
 * Never preload this into gnome-shell.
 */

#define GPU_DEVFREQ "/sys/devices/platform/soc@0/3d00000.gpu/devfreq/3d00000.gpu/"
#define GPU_TEMP "/sys/class/thermal/thermal_zone15/temp"
#define FAKE_HWMON_DIR "/run/dagu/resources-gpu-hwmon"

static int (*real_openat)(int, const char *, int, ...);
static DIR *(*real_opendir)(const char *);
static int (*real_stat)(const char *, struct stat *);
static int (*real_lstat)(const char *, struct stat *);
static int (*real_access)(const char *, int);
static int (*real_fstatat)(int, const char *, struct stat *, int);

static void init_reals(void)
{
	if (!real_openat)
		real_openat = dlsym(RTLD_NEXT, "openat");
	if (!real_opendir)
		real_opendir = dlsym(RTLD_NEXT, "opendir");
	if (!real_stat)
		real_stat = dlsym(RTLD_NEXT, "stat");
	if (!real_lstat)
		real_lstat = dlsym(RTLD_NEXT, "lstat");
	if (!real_access)
		real_access = dlsym(RTLD_NEXT, "access");
	if (!real_fstatat)
		real_fstatat = dlsym(RTLD_NEXT, "fstatat");
}

static unsigned long read_ulong(const char *path, unsigned long fallback)
{
	char buf[64];
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	ssize_t n;
	unsigned long v = fallback;

	if (fd < 0)
		return fallback;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return fallback;
	buf[n] = 0;
	v = strtoul(buf, NULL, 10);
	return v ? v : fallback;
}

static int is_drm_card_device(const char *p)
{
	return p && strstr(p, "/sys/class/drm/card") && strstr(p, "/device");
}

static const char *fake_kind(const char *p)
{
	if (!is_drm_card_device(p))
		return NULL;
	if (strstr(p, "gpu_busy_percent"))
		return "busy";
	if (strstr(p, "/hwmon/hwmon") && strstr(p, "temp1_input"))
		return "temp";
	if (strstr(p, "/hwmon/hwmon") && strstr(p, "freq1_input"))
		return "freq";
	if (strstr(p, "/hwmon/hwmon") && strstr(p, "/name"))
		return "name";
	return NULL;
}

static int memfd_from_str(const char *s)
{
	char tmpl[] = "/tmp/dagu-res-XXXXXX";
	int fd = mkstemp(tmpl);

	if (fd < 0)
		return -1;
	unlink(tmpl);
	if (write(fd, s, strlen(s)) < 0) {
		close(fd);
		return -1;
	}
	lseek(fd, 0, SEEK_SET);
	return fd;
}

static int open_fake(const char *kind)
{
	char buf[64];
	unsigned long min_f, cur_f, max_f, busy;

	min_f = read_ulong(GPU_DEVFREQ "min_freq", 305000000);
	cur_f = read_ulong(GPU_DEVFREQ "cur_freq", min_f);
	max_f = read_ulong(GPU_DEVFREQ "max_freq", 670000000);
	if (max_f <= min_f)
		busy = cur_f > min_f ? 50 : 0;
	else
		busy = (cur_f - min_f) * 100 / (max_f - min_f);

	if (!strcmp(kind, "busy")) {
		snprintf(buf, sizeof(buf), "%lu\n", busy > 100 ? 100 : busy);
		return memfd_from_str(buf);
	}
	if (!strcmp(kind, "freq")) {
		/* hwmon freq1_input is Hz */
		snprintf(buf, sizeof(buf), "%lu\n", cur_f);
		return memfd_from_str(buf);
	}
	if (!strcmp(kind, "temp")) {
		unsigned long t = read_ulong(GPU_TEMP, 40000);

		snprintf(buf, sizeof(buf), "%lu\n", t);
		return memfd_from_str(buf);
	}
	if (!strcmp(kind, "name"))
		return memfd_from_str("adreno\n");
	errno = ENOENT;
	return -1;
}

static void ensure_fake_hwmon(void)
{
	struct stat st;

	if (stat(FAKE_HWMON_DIR "/hwmon0", &st) == 0)
		return;
	mkdir("/run/dagu", 0755);
	mkdir(FAKE_HWMON_DIR, 0755);
	mkdir(FAKE_HWMON_DIR "/hwmon0", 0755);
	/* placeholders so glob/stat see files; open() still synthesizes */
	close(open(FAKE_HWMON_DIR "/hwmon0/temp1_input", O_CREAT | O_WRONLY, 0644));
	close(open(FAKE_HWMON_DIR "/hwmon0/freq1_input", O_CREAT | O_WRONLY, 0644));
	close(open(FAKE_HWMON_DIR "/hwmon0/name", O_CREAT | O_WRONLY, 0644));
}

int openat(int dirfd, const char *pathname, int flags, ...)
{
	mode_t mode = 0;
	const char *kind;
	va_list ap;

	init_reals();
	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	kind = fake_kind(pathname);
	if (kind)
		return open_fake(kind);
	if (flags & O_CREAT)
		return real_openat(dirfd, pathname, flags, mode);
	return real_openat(dirfd, pathname, flags);
}

int open(const char *pathname, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;

	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
		return openat(AT_FDCWD, pathname, flags, mode);
	}
	return openat(AT_FDCWD, pathname, flags);
}

int open64(const char *pathname, int flags, ...)
{
	mode_t mode = 0;
	va_list ap;

	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
		return openat(AT_FDCWD, pathname, flags, mode);
	}
	return openat(AT_FDCWD, pathname, flags);
}

DIR *opendir(const char *name)
{
	init_reals();
	if (name && is_drm_card_device(name) &&
	    strstr(name, "/hwmon") && !strstr(name, "/hwmon/hwmon")) {
		ensure_fake_hwmon();
		return real_opendir(FAKE_HWMON_DIR);
	}
	return real_opendir(name);
}

static int fake_stat(const char *path, struct stat *buf)
{
	const char *kind = fake_kind(path);

	init_reals();
	if (kind) {
		if (real_stat("/dev/null", buf) != 0)
			return -1;
		buf->st_mode = S_IFREG | 0444;
		buf->st_size = 16;
		return 0;
	}
	if (path && is_drm_card_device(path) && strstr(path, "/hwmon") &&
	    !strchr(strrchr(path, '/') ? strrchr(path, '/') : path, '.')) {
		ensure_fake_hwmon();
		if (strstr(path, "hwmon0"))
			return real_stat(FAKE_HWMON_DIR "/hwmon0", buf);
		return real_stat(FAKE_HWMON_DIR, buf);
	}
	return -2;
}

int stat(const char *path, struct stat *buf)
{
	int r = fake_stat(path, buf);

	if (r != -2)
		return r;
	init_reals();
	return real_stat(path, buf);
}

int lstat(const char *path, struct stat *buf)
{
	int r = fake_stat(path, buf);

	if (r != -2)
		return r;
	init_reals();
	return real_lstat(path, buf);
}

int fstatat(int dirfd, const char *path, struct stat *buf, int flags)
{
	int r = fake_stat(path, buf);

	if (r != -2)
		return r;
	init_reals();
	return real_fstatat(dirfd, path, buf, flags);
}

int access(const char *path, int mode)
{
	if (fake_kind(path))
		return 0;
	init_reals();
	return real_access(path, mode);
}

static int (*real_statx)(int, const char *, int, unsigned, struct statx *);

int statx(int dirfd, const char *path, int flags, unsigned mask, struct statx *buf)
{
	init_reals();
	if (!real_statx)
		real_statx = dlsym(RTLD_NEXT, "statx");
	if (fake_kind(path) ||
	    (path && is_drm_card_device(path) && strstr(path, "/hwmon"))) {
		if (real_statx(AT_FDCWD, "/dev/null", 0, mask, buf) != 0)
			return -1;
		buf->stx_mode = S_IFREG | 0444;
		if (path && strstr(path, "/hwmon") && !fake_kind(path))
			buf->stx_mode = S_IFDIR | 0755;
		buf->stx_size = 16;
		return 0;
	}
	return real_statx(dirfd, path, flags, mask, buf);
}
