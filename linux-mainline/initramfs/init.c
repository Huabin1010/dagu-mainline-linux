/*
 * P0 initramfs: stay in ramdisk. Do not mount userdata (Android is still
 * on this tablet). Bring up USB RNDIS at 192.168.7.2 if a UDC appears.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static void kmsg(const char *s)
{
	int fd = open("/dev/kmsg", O_WRONLY);

	if (fd < 0)
		fd = STDERR_FILENO;
	dprintf(fd, "dagu-init: %s\n", s);
	if (fd != STDERR_FILENO)
		close(fd);
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
	int i;

	for (i = 0; i < 80; i++) {
		d = opendir("/sys/class/udc");
		if (d) {
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
		}
		usleep(250000);
	}
	return -1;
}

static void setup_rndis(void)
{
	char udc[64];
	const char *g = "/sys/kernel/config/usb_gadget/dagu";

	mkpath("/sys/kernel/config");
	mount("none", "/sys/kernel/config", "configfs", 0, NULL);

	if (mkdir(g, 0755) && errno != EEXIST)
		return;
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

	if (find_udc(udc, sizeof(udc))) {
		kmsg("no UDC");
		return;
	}
	write_str("/sys/kernel/config/usb_gadget/dagu/UDC", udc);
	kmsg(udc);
	for (int i = 0; i < 40; i++) {
		if (!set_ip("usb0", "192.168.7.2", "255.255.255.0")) {
			kmsg("RNDIS 192.168.7.2");
			return;
		}
		usleep(250000);
	}
	kmsg("usb0 not ready");
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

	kmsg("P0 ramdisk — not mounting userdata");
	setup_rndis();

	if (!access("/bin/dropbear", X_OK)) {
		kmsg("starting dropbear");
		if (!fork()) {
			char *argv[] = { "/bin/dropbear", "-R", "-F", "-E", "-p", "22", NULL };
			execv(argv[0], argv);
			_exit(1);
		}
	}

	for (;;)
		sleep(60);
}
