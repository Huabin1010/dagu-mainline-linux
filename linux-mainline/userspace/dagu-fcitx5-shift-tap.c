/*
 * dagu folio: tap Shift toggles fcitx5. Do not EVIOCGRAB.
 *
 * keyd grabbed HID 15d9:00a3 and replayed letters through a uinput keyboard
 * with no MSC_SCAN. Wayland clients ignore EV_REP; they start hold-repeat
 * from a stable key-down. That failed on the first folio key and only
 * started after a second key-down. Bluetooth HID never went through keyd,
 * so it repeated. Letters stay on Xiaomi Keyboard → mutter, like BT.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define TAP_NS 500000000LL
#define NAME "Xiaomi Keyboard"

static long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int find_keyboard(char *out, size_t n)
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
		while (len > 0 && (name[len - 1] == '\n' || name[len - 1] == '\r'))
			name[--len] = 0;
		if (strcmp(name, NAME) != 0)
			continue;
		snprintf(out, n, "/dev/input/%s", ent->d_name);
		closedir(d);
		return 0;
	}
	closedir(d);
	return -1;
}

static void toggle_ime(void)
{
	pid_t pid = fork();

	if (pid == 0) {
		execlp("fcitx5-remote", "fcitx5-remote", "-t", (char *)NULL);
		_exit(127);
	}
	if (pid > 0)
		waitpid(pid, NULL, 0);
}

static int open_keyboard(char *dev, size_t n)
{
	int fd;

	for (;;) {
		if (find_keyboard(dev, n) == 0) {
			fd = open(dev, O_RDONLY | O_CLOEXEC);
			if (fd >= 0)
				return fd;
		}
		sleep(1);
	}
}

int main(void)
{
	char dev[64];
	int fd;
	long long down_at[2] = { 0, 0 };
	int dirty[2] = { 0, 0 };
	struct input_event ev;

	fd = open_keyboard(dev, sizeof(dev));
	for (;;) {
		ssize_t n = read(fd, &ev, sizeof(ev));
		int slot;

		if (n != (ssize_t)sizeof(ev)) {
			close(fd);
			fd = open_keyboard(dev, sizeof(dev));
			memset(down_at, 0, sizeof(down_at));
			memset(dirty, 0, sizeof(dirty));
			continue;
		}
		if (ev.type != EV_KEY || ev.value == 2)
			continue;
		if (ev.code == KEY_LEFTSHIFT)
			slot = 0;
		else if (ev.code == KEY_RIGHTSHIFT)
			slot = 1;
		else {
			if (ev.value == 1) {
				dirty[0] = 1;
				dirty[1] = 1;
			}
			continue;
		}
		if (ev.value == 1) {
			down_at[slot] = now_ns();
			dirty[slot] = 0;
			continue;
		}
		if (ev.value != 0 || !down_at[slot])
			continue;
		if (!dirty[slot] && now_ns() - down_at[slot] <= TAP_NS)
			toggle_ime();
		down_at[slot] = 0;
	}
}
