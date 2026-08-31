/*
 * Mount Ubuntu on userdata and switch_root. Android is not kept.
 * If userdata is missing or not ext4 Ubuntu, stay on ramdisk with RNDIS.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <linux/reboot.h>
#include <linux/watchdog.h>
#include <unistd.h>

static int wdt_fd = -1;

static void kmsg(const char *s)
{
	int fd = open("/dev/kmsg", O_WRONLY);

	if (fd < 0)
		fd = STDERR_FILENO;
	dprintf(fd, "dagu-init: %s\n", s);
	if (fd != STDERR_FILENO)
		close(fd);
}

static void wdt_takeover(int t)
{
	if (wdt_fd >= 0)
		return;
	wdt_fd = open("/dev/watchdog", O_WRONLY);
	if (wdt_fd < 0)
		wdt_fd = open("/dev/watchdog0", O_WRONLY);
	if (wdt_fd < 0) {
		kmsg("watchdog open failed");
		return;
	}
	if (ioctl(wdt_fd, WDIOC_SETTIMEOUT, &t) < 0)
		kmsg("watchdog timeout ioctl failed");
	kmsg("watchdog takeover");
}

static void wdt_stretch(int t)
{
	if (wdt_fd < 0)
		return;
	if (ioctl(wdt_fd, WDIOC_SETTIMEOUT, &t) < 0)
		kmsg("watchdog stretch ioctl failed");
}

static void wdt_pet(void)
{
	if (wdt_fd >= 0 && write(wdt_fd, "\0", 1) < 0)
		kmsg("watchdog pet failed");
}

static void die(const char *s)
{
	kmsg(s);
	/* PID 1 must not exit — that panics the kernel and ABL returns to fastboot. */
	for (;;)
		pause();
}

static void mkpath(const char *path)
{
	mkdir(path, 0755);
}

static int write_str(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (fd < 0)
		return -1;
	if (write(fd, val, strlen(val)) < 0) {
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

static int set_ip(const char *iface, const char *ip, const char *mask)
{
	struct ifreq ifr;
	struct sockaddr_in *sin;
	int fd = socket(AF_INET, SOCK_DGRAM, 0);

	if (fd < 0)
		return -1;
	memset(&ifr, 0, sizeof(ifr));
	snprintf(ifr.ifr_name, IFNAMSIZ, "%s", iface);
	sin = (struct sockaddr_in *)&ifr.ifr_addr;
	sin->sin_family = AF_INET;
	inet_pton(AF_INET, ip, &sin->sin_addr);
	if (ioctl(fd, SIOCSIFADDR, &ifr) < 0) {
		close(fd);
		return -1;
	}
	inet_pton(AF_INET, mask, &sin->sin_addr);
	if (ioctl(fd, SIOCSIFNETMASK, &ifr) < 0) {
		close(fd);
		return -1;
	}
	if (ioctl(fd, SIOCGIFFLAGS, &ifr) < 0) {
		close(fd);
		return -1;
	}
	ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
	ioctl(fd, SIOCSIFFLAGS, &ifr);
	close(fd);
	return 0;
}

static int find_udc(char *out, size_t n)
{
	DIR *d;
	struct dirent *e;

	d = opendir("/sys/class/udc");
	if (!d)
		return -1;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		if (strlen(e->d_name) >= n)
			continue;
		memcpy(out, e->d_name, strlen(e->d_name) + 1);
		closedir(d);
		return 0;
	}
	closedir(d);
	return -1;
}

static int kernel_is_4_19(void)
{
	char buf[256];
	int fd = open("/proc/version", O_RDONLY);
	ssize_t n;

	if (fd < 0)
		return 0;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return 0;
	buf[n] = '\0';
	return strstr(buf, "Linux version 4.") != NULL;
}

static void force_usb_device_role(void)
{
	DIR *d;
	struct dirent *e;
	char path[256];

	d = opendir("/sys/class/usb_role");
	if (!d)
		return;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path),
			 "/sys/class/usb_role/%s/role", e->d_name);
		if (!write_str(path, "device"))
			kmsg("usb role device");
	}
	closedir(d);
}

static void reboot_bootloader(void)
{
	int fd;

	kmsg("RNDIS failed — sysrq reboot");
	sync();
	write_str("/proc/sys/kernel/sysrq", "1");
	write_str("/proc/sysrq-trigger", "b");
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, "bootloader");
	reboot(RB_AUTOBOOT);
	fd = open("/dev/watchdog", O_WRONLY);
	if (fd >= 0) {
		write(fd, "b", 1);
		close(fd);
	}
	for (;;)
		pause();
}

static int setup_rndis(void)
{
	char udc[64];
	const char *g = "/sys/kernel/config/usb_gadget/dagu";
	int attempt;
	const int udc_wait_max = 80; /* 80 * 250ms ≈ 20s */

	/* Stock 4.19 panics if we poke configfs gadget; ABL then returns to fastboot. */
	if (kernel_is_4_19()) {
		kmsg("skip RNDIS on 4.19");
		return 0;
	}

	mkpath("/sys/kernel/config");
	mount("none", "/sys/kernel/config", "configfs", 0, NULL);

	/*
	 * Wait ~20s for DWC3 UDC. Do not wdt_takeover(15s) here: that races
	 * the diagnostic reboot and used to look like "kernel never started".
	 * If PID1 is alive and UDC never appears, reboot_bootloader() is the
	 * host-visible signal (~20–25s back to 18d1:d00d).
	 */
	for (attempt = 0; attempt < udc_wait_max; attempt++) {
		wdt_pet();
		force_usb_device_role();
		if (find_udc(udc, sizeof(udc))) {
			if (attempt == 0 || attempt % 20 == 0)
				kmsg("waiting UDC");
			usleep(250000);
			continue;
		}
		break;
	}
	if (attempt >= udc_wait_max) {
		kmsg("no UDC after 20s");
		reboot_bootloader();
		return -1;
	}

	wdt_stretch(60);
	wdt_pet();

	if (mkdir(g, 0755) && errno != EEXIST)
		return -1;
	write_str("/sys/kernel/config/usb_gadget/dagu/idVendor", "0x1d6b");
	write_str("/sys/kernel/config/usb_gadget/dagu/idProduct", "0x0104");
	mkdir("/sys/kernel/config/usb_gadget/dagu/strings/0x409", 0755);
	write_str("/sys/kernel/config/usb_gadget/dagu/strings/0x409/serialnumber",
		  "dagu-mainline");
	write_str("/sys/kernel/config/usb_gadget/dagu/strings/0x409/manufacturer",
		  "xiaomi-pad870-win11-arm");
	write_str("/sys/kernel/config/usb_gadget/dagu/strings/0x409/product",
		  "dagu USB RNDIS");
	mkdir("/sys/kernel/config/usb_gadget/dagu/configs/c.1", 0755);
	mkdir("/sys/kernel/config/usb_gadget/dagu/configs/c.1/strings/0x409", 0755);
	write_str("/sys/kernel/config/usb_gadget/dagu/configs/c.1/strings/0x409/configuration",
		  "RNDIS");
	mkdir("/sys/kernel/config/usb_gadget/dagu/functions/rndis.usb0", 0755);
	write_str("/sys/kernel/config/usb_gadget/dagu/functions/rndis.usb0/host_addr",
		  "02:00:00:00:07:01");
	write_str("/sys/kernel/config/usb_gadget/dagu/functions/rndis.usb0/dev_addr",
		  "02:00:00:00:07:02");
	if (symlink("/sys/kernel/config/usb_gadget/dagu/functions/rndis.usb0",
		    "/sys/kernel/config/usb_gadget/dagu/configs/c.1/rndis.usb0") &&
	    errno != EEXIST)
		kmsg("rndis symlink failed");

	write_str("/sys/kernel/config/usb_gadget/dagu/UDC", udc);
	kmsg(udc);
	for (;;) {
		wdt_pet();
		if (!set_ip("usb0", "192.168.7.2", "255.255.255.0")) {
			kmsg("RNDIS 192.168.7.2");
			return 0;
		}
		usleep(250000);
	}
}

static void trigger_block_uevents(void)
{
	DIR *dir = opendir("/sys/class/block");
	struct dirent *ent;

	if (!dir)
		return;
	while ((ent = readdir(dir))) {
		char path[256];
		int fd;

		if (ent->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), "/sys/class/block/%s/uevent",
			 ent->d_name);
		fd = open(path, O_WRONLY);
		if (fd < 0)
			continue;
		if (write(fd, "add\n", 4) < 0) {
			/* ignore */
		}
		close(fd);
	}
	closedir(dir);
}

static int partname_equals(const char *blk, const char *want)
{
	char path[128], buf[512];
	char *p, *nl;
	ssize_t n;
	int fd;

	snprintf(path, sizeof(path), "/sys/class/block/%s/uevent", blk);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return 0;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return 0;
	buf[n] = '\0';
	p = strstr(buf, "PARTNAME=");
	if (!p)
		return 0;
	p += 9;
	nl = strchr(p, '\n');
	if (nl)
		*nl = '\0';
	return strcmp(p, want) == 0;
}

static const char *find_userdata(void)
{
	static char dev[64];
	DIR *d;
	struct dirent *e;
	int i;

	for (i = 0; i < 240; i++) {
		trigger_block_uevents();
		d = opendir("/sys/class/block");
		if (d) {
			while ((e = readdir(d))) {
				if (e->d_name[0] == '.')
					continue;
				if (!partname_equals(e->d_name, "userdata"))
					continue;
				snprintf(dev, sizeof(dev), "/dev/%s", e->d_name);
				closedir(d);
				if (!access(dev, F_OK))
					return dev;
			}
			closedir(d);
		}
		if (!access("/dev/sda34", F_OK))
			return "/dev/sda34";
		usleep(250000);
	}
	return NULL;
}

/* Returns 0 if switch_root succeeded (never returns on success). */
static int try_switch_root(void)
{
	const char *rootdev = find_userdata();

	if (!rootdev) {
		kmsg("userdata partition not found");
		return -1;
	}
	kmsg(rootdev);
	mkpath("/newroot");
	if (mount(rootdev, "/newroot", "ext4", 0, NULL)) {
		kmsg("userdata not ext4 (flash Ubuntu first)");
		return -1;
	}
	if (access("/newroot/sbin/init", X_OK)) {
		kmsg("no /sbin/init on userdata");
		umount("/newroot");
		return -1;
	}

	kmsg("switch_root userdata");
	mkpath("/newroot/proc");
	mkpath("/newroot/sys");
	mkpath("/newroot/dev");
	if (mount("/proc", "/newroot/proc", NULL, MS_MOVE, NULL))
		die("move proc failed");
	if (mount("/sys", "/newroot/sys", NULL, MS_MOVE, NULL))
		die("move sys failed");
	if (mount("/dev", "/newroot/dev", NULL, MS_MOVE, NULL))
		die("move dev failed");
	if (chdir("/newroot"))
		die("chdir /newroot failed");
	if (mount(".", "/", NULL, MS_MOVE, NULL))
		die("move root failed");
	if (chroot("."))
		die("chroot failed");
	if (chdir("/"))
		die("chdir / failed");
	execl("/sbin/init", "init", NULL);
	die("exec /sbin/init failed");
	return -1;
}

int main(void)
{
	mkpath("/proc");
	mkpath("/sys");
	mkpath("/dev");
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mkpath("/dev/pts");
	mount("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
	mkpath("/tmp");
	mount("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");

	kmsg("P0 ramdisk — skip userdata, bring up RNDIS+SSH");
	/* Early KPSS WDT is 40s; pet during UDC wait. No UDC → reboot. */
	wdt_takeover(40);
	if (setup_rndis())
		kmsg("RNDIS failed");

	if (!access("/bin/dropbear", X_OK)) {
		kmsg("starting dropbear");
		if (!fork()) {
			char *argv[] = { "/bin/dropbear", "-R", "-F", "-E", "-p", "22", NULL };
			execv(argv[0], argv);
			_exit(1);
		}
	}

	for (;;) {
		wdt_pet();
		sleep(5);
	}
}
