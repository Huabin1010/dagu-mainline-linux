/*
 * dagu: short power key toggles Mutter PowerSaveMode only.
 *
 * DCS 0x51 times out on this video-mode panel. logind lock-sessions races
 * the lock shield. Long press stays HandlePowerKeyLongPress=poweroff.
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

#define LONG_PRESS_NS 1200000000LL
#define DEBOUNCE_NS    350000000LL

static long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int find_pwrkey(char *out, size_t n)
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
		if (!strstr(name, "pm8941_pwrkey"))
			continue;
		snprintf(out, n, "/dev/input/%s", ent->d_name);
		closedir(d);
		return 0;
	}
	closedir(d);
	snprintf(out, n, "/dev/input/event1");
	return 0;
}

static void gnome_env(void)
{
	setenv("XDG_RUNTIME_DIR", "/run/user/1001", 0);
	setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/1001/bus", 0);
}

static int mutter_mode(void)
{
	int pipefd[2];
	pid_t pid;
	char buf[64];
	ssize_t n;

	if (pipe(pipefd) < 0)
		return 0;
	pid = fork();
	if (pid == 0) {
		gnome_env();
		dup2(pipefd[1], 1);
		close(pipefd[0]);
		close(pipefd[1]);
		execlp("busctl", "busctl", "--user", "get-property",
		       "org.gnome.Mutter.DisplayConfig",
		       "/org/gnome/Mutter/DisplayConfig",
		       "org.gnome.Mutter.DisplayConfig",
		       "PowerSaveMode", (char *)NULL);
		_exit(127);
	}
	close(pipefd[1]);
	n = read(pipefd[0], buf, sizeof(buf) - 1);
	close(pipefd[0]);
	waitpid(pid, NULL, 0);
	if (n <= 0)
		return 0;
	buf[n] = 0;
	{
		char *sp = strrchr(buf, ' ');
		return sp ? atoi(sp + 1) : 0;
	}
}

static void set_mutter(int mode)
{
	char m[4];
	pid_t pid;

	snprintf(m, sizeof(m), "%d", mode);
	pid = fork();
	if (pid == 0) {
		gnome_env();
		execlp("busctl", "busctl", "--user", "set-property",
		       "org.gnome.Mutter.DisplayConfig",
		       "/org/gnome/Mutter/DisplayConfig",
		       "org.gnome.Mutter.DisplayConfig",
		       "PowerSaveMode", "i", m, (char *)NULL);
		_exit(127);
	}
	waitpid(pid, NULL, 0);
}

int main(void)
{
	char dev[64];
	int fd;
	long long down_at = 0, last = 0;
	struct input_event ev;

	find_pwrkey(dev, sizeof(dev));
	for (int i = 0; i < 60; i++) {
		fd = open(dev, O_RDONLY | O_CLOEXEC);
		if (fd >= 0)
			break;
		find_pwrkey(dev, sizeof(dev));
		sleep(1);
	}
	if (fd < 0) {
		fprintf(stderr, "dagu-power-button: cannot open %s: %s\n",
			dev, strerror(errno));
		return 1;
	}
	for (;;) {
		ssize_t n = read(fd, &ev, sizeof(ev));
		long long t;

		if (n != (ssize_t)sizeof(ev))
			continue;
		if (ev.type != EV_KEY || ev.code != KEY_POWER)
			continue;
		t = now_ns();
		if (ev.value == 1) {
			down_at = t;
			continue;
		}
		if (ev.value != 0 || !down_at)
			continue;
		if (t - down_at >= LONG_PRESS_NS) {
			down_at = 0;
			continue;
		}
		down_at = 0;
		if (t - last < DEBOUNCE_NS)
			continue;
		last = t;
		if (mutter_mode() != 0)
			set_mutter(0);
		else
			set_mutter(3);
	}
}
