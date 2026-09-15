/*
 * Tiny /bin/sh for ramdisk SSH. Supports: -c <cmd>, dmesg, cat, ls, echo, reboot.
 * Used when userdata has no Ubuntu yet; init mounts userdata and switch_root.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>

static int cmd_dmesg(void)
{
	char buf[4096];
	ssize_t n;
	int fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);

	if (fd < 0)
		return 1;
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		if (write(STDOUT_FILENO, buf, n) < 0)
			break;
	close(fd);
	return 0;
}

static int cmd_cat(const char *path)
{
	char buf[4096];
	ssize_t n;
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		dprintf(STDERR_FILENO, "cat: %s\n", path);
		return 1;
	}
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		if (write(STDOUT_FILENO, buf, n) < 0)
			break;
	close(fd);
	return 0;
}

static int cmd_ls(const char *path)
{
	DIR *d = opendir(path ? path : ".");
	struct dirent *e;

	if (!d)
		return 1;
	while ((e = readdir(d)))
		dprintf(STDOUT_FILENO, "%s\n", e->d_name);
	closedir(d);
	return 0;
}

static int run_line(char *line)
{
	char *argv[16];
	int argc = 0;
	char *tok = strtok(line, " \t\n");

	while (tok && argc < 15) {
		argv[argc++] = tok;
		tok = strtok(NULL, " \t\n");
	}
	argv[argc] = NULL;
	if (argc == 0)
		return 0;
	if (!strcmp(argv[0], "dmesg"))
		return cmd_dmesg();
	if (!strcmp(argv[0], "cat") && argc >= 2)
		return cmd_cat(argv[1]);
	if (!strcmp(argv[0], "ls"))
		return cmd_ls(argc >= 2 ? argv[1] : ".");
	if (!strcmp(argv[0], "echo")) {
		for (int i = 1; i < argc; i++)
			dprintf(STDOUT_FILENO, "%s%s", argv[i], i + 1 < argc ? " " : "\n");
		return 0;
	}
	if (!strcmp(argv[0], "reboot")) {
		sync();
		reboot(RB_AUTOBOOT);
		return 1;
	}
	if (!strcmp(argv[0], "uname")) {
		dprintf(STDOUT_FILENO, "dagu-mainline ramdisk\n");
		return 0;
	}
	dprintf(STDERR_FILENO, "minish: unknown: %s\n", argv[0]);
	return 127;
}

int main(int argc, char **argv)
{
	char line[512];

	if (argc >= 3 && !strcmp(argv[1], "-c")) {
		strncpy(line, argv[2], sizeof(line) - 1);
		line[sizeof(line) - 1] = 0;
		return run_line(line);
	}
	dprintf(STDOUT_FILENO, "dagu minish. commands: dmesg cat ls echo reboot\n");
	for (;;) {
		dprintf(STDOUT_FILENO, "# ");
		if (!fgets(line, sizeof(line), stdin))
			break;
		run_line(line);
	}
	return 0;
}
