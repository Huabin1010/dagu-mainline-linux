/*
 * dagu: raise GPU/CPU floors while Himax reports contact.
 *
 * Replaces dagu-touch-boost.py. Does not walk /proc fd tables (that froze
 * mutter). SoftISP pinning lives in dagu_cam.cpp. Do not set
 * governor=performance. Kernel himax-dagu also votes the same floors; double
 * apply is harmless.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define GPU_MIN "/sys/class/devfreq/3d00000.gpu/min_freq"
#define GPU_IDLE "587000000"
#define GPU_HOLD "670000000"
#define HOLD_TAIL_NS 180000000L

static const struct {
	const char *path;
	const char *idle;
	const char *hold;
} cpu[] = {
	{ "/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq", "300000", "1248000" },
	{ "/sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq", "710400", "1766400" },
	{ "/sys/devices/system/cpu/cpufreq/policy7/scaling_min_freq", "844800", "1977600" },
};

static void wr(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);

	if (fd < 0)
		return;
	if (write(fd, val, strlen(val)) < 0) {
		/* ignore */
	}
	close(fd);
}

static void apply(int hold)
{
	wr(GPU_MIN, hold ? GPU_HOLD : GPU_IDLE);
	for (size_t i = 0; i < sizeof(cpu) / sizeof(cpu[0]); i++)
		wr(cpu[i].path, hold ? cpu[i].hold : cpu[i].idle);
}

static int find_himax(char *out, size_t n)
{
	DIR *d = opendir("/sys/class/input");
	struct dirent *ent;

	if (!d)
		return -1;
	while ((ent = readdir(d))) {
		char path[128], name[128];
		int fd, len;

		if (strncmp(ent->d_name, "event", 5) != 0 ||
		    strlen(ent->d_name) > 16)
			continue;
		snprintf(path, sizeof(path),
			 "/sys/class/input/%s/device/name", ent->d_name);
		fd = open(path, O_RDONLY | O_CLOEXEC);
		if (fd < 0)
			continue;
		len = read(fd, name, sizeof(name) - 1);
		close(fd);
		if (len <= 0)
			continue;
		name[len] = 0;
		if (!strstr(name, "Himax") && !strstr(name, "HX83121"))
			continue;
		snprintf(out, n, "/dev/input/%s", ent->d_name);
		closedir(d);
		return 0;
	}
	closedir(d);
	snprintf(out, n, "/dev/input/event3");
	return 0;
}

static long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

int main(void)
{
	char dev[64];
	int fd, contacts = 0, holding = 0;
	long long drop_at = 0;
	struct input_event ev[64];

	find_himax(dev, sizeof(dev));
	for (int i = 0; i < 60; i++) {
		fd = open(dev, O_RDONLY | O_CLOEXEC);
		if (fd >= 0)
			break;
		find_himax(dev, sizeof(dev));
		sleep(1);
	}
	if (fd < 0) {
		fprintf(stderr, "dagu-touch-boost: cannot open %s: %s\n",
			dev, strerror(errno));
		return 1;
	}
	apply(0);
	for (;;) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		int pr = poll(&pfd, 1, 4);
		long long t = now_ns();

		if (pr > 0 && (pfd.revents & POLLIN)) {
			ssize_t n = read(fd, ev, sizeof(ev));
			size_t k, n_ev;

			if (n > 0) {
				n_ev = (size_t)n / sizeof(ev[0]);
				for (k = 0; k < n_ev; k++) {
					if (ev[k].type == EV_ABS &&
					    ev[k].code == ABS_MT_TRACKING_ID) {
						if (ev[k].value >= 0)
							contacts++;
						else if (contacts > 0)
							contacts--;
					} else if (ev[k].type == EV_KEY &&
						   ev[k].code == BTN_TOUCH) {
						contacts = ev[k].value ? 1 : 0;
					}
				}
			}
		}
		if (contacts > 0) {
			drop_at = 0;
			if (!holding) {
				holding = 1;
				apply(1);
			}
		} else if (holding) {
			if (!drop_at)
				drop_at = t + HOLD_TAIL_NS;
			else if (t >= drop_at) {
				holding = 0;
				drop_at = 0;
				apply(0);
			}
		}
	}
}
