/*
 * Mount Ubuntu on userdata and switch_root. Android is not kept.
 * Stay on ramdisk. USB debug is built-in g_serial (ttyGS0 / 0525:a4a7).
 * Do not bind configfs RNDIS — it steals the UDC.
 *
 * DAGU_PID1_PING: 1 = sleep 3s then reboot bootloader (did we reach PID1?).
 * Keep 0 while hung-task/pstore is the experiment.
 */
#ifndef DAGU_PID1_PING
#define DAGU_PID1_PING 0
#endif
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
#include <sys/time.h>
#include <sys/utsname.h>
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
	wdt_fd = open("/dev/watchdog", O_WRONLY | O_CLOEXEC);
	if (wdt_fd < 0)
		wdt_fd = open("/dev/watchdog0", O_WRONLY | O_CLOEXEC);
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

/* Closing /dev/watchdog without 'V' leaves the KPSS WDT armed and stops the
 * kernel from pinging it. switch_root's execl did that, then ABL bounced us
 * ~30s into Ubuntu. Magic-close so Ubuntu isn't sitting on a ticking bomb.
 */
static void wdt_magic_close(void)
{
	if (wdt_fd < 0)
		return;
	if (write(wdt_fd, "V", 1) < 0)
		kmsg("watchdog magic close write failed");
	close(wdt_fd);
	wdt_fd = -1;
	kmsg("watchdog magic close");
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

static void mkdir_p(const char *path)
{
	char tmp[256];
	size_t n;
	char *p;

	n = strlen(path);
	if (n == 0 || n >= sizeof(tmp))
		return;
	memcpy(tmp, path, n + 1);
	for (p = tmp + 1; *p; p++) {
		if (*p == '/') {
			*p = '\0';
			mkdir(tmp, 0755);
			*p = '/';
		}
	}
	mkdir(tmp, 0755);
}

static int copy_file(const char *src, const char *dst)
{
	char buf[4096];
	ssize_t n, w;
	int in, out;

	in = open(src, O_RDONLY);
	if (in < 0)
		return -1;
	out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out < 0) {
		close(in);
		return -1;
	}
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		char *q = buf;
		ssize_t left = n;

		while (left > 0) {
			w = write(out, q, (size_t)left);
			if (w < 0) {
				close(in);
				close(out);
				return -1;
			}
			q += w;
			left -= w;
		}
	}
	close(in);
	close(out);
	return n < 0 ? -1 : 0;
}

/* Pair venus-*.ko with this Image. Userdata extra/ outlives flash and
 * otherwise keeps an older struct module (ABI reject, no /dev/video14).
 */
static void install_venus_kos(void)
{
	struct utsname u;
	char extra[192], dst[256], msg[256], src[64];
	static const char *const names[] = {
		"venus-core.ko", "venus-dec.ko", "venus-enc.ko"
	};
	unsigned i;

	if (access("/venus-ko/venus-core.ko", R_OK))
		return;
	if (uname(&u))
		return;
	snprintf(extra, sizeof(extra), "/newroot/lib/modules/%s/extra", u.release);
	mkdir_p(extra);
	mkdir_p("/newroot/root/venus-ko");
	for (i = 0; i < 3; i++) {
		snprintf(src, sizeof(src), "/venus-ko/%s", names[i]);
		snprintf(dst, sizeof(dst), "%s/%s", extra, names[i]);
		if (copy_file(src, dst)) {
		snprintf(msg, sizeof(msg), "venus copy %s failed", names[i]);
		kmsg(msg);
		continue;
	}
	snprintf(dst, sizeof(dst), "/newroot/root/venus-ko/%s", names[i]);
	if (copy_file(src, dst)) {
		snprintf(msg, sizeof(msg), "venus copy %s (root) failed", names[i]);
		kmsg(msg);
	}
	}
	kmsg("installed matching venus.ko onto userdata");
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

static int path_ok(const char *p)
{
	return !access(p, F_OK);
}

static int dir_count(const char *path)
{
	DIR *d = opendir(path);
	struct dirent *e;
	int n = 0;

	if (!d)
		return -1;
	while ((e = readdir(d))) {
		if (e->d_name[0] != '.')
			n++;
	}
	closedir(d);
	return n;
}

static int dir_has_substr(const char *path, const char *sub)
{
	DIR *d = opendir(path);
	struct dirent *e;
	int hit = 0;

	if (!d)
		return 0;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		if (strstr(e->d_name, sub)) {
			hit = 1;
			break;
		}
	}
	closedir(d);
	return hit;
}

static int file_has_substr(const char *path, const char *sub)
{
	char buf[2048];
	int fd = open(path, O_RDONLY);
	ssize_t n;
	int hit = 0;

	if (fd < 0)
		return -1;
	while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
		buf[n] = '\0';
		if (strstr(buf, sub)) {
			hit = 1;
			break;
		}
	}
	close(fd);
	return hit;
}

static long long dbg_now_ms(void)
{
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* Compact USB iSerial: host watcher copies this into debug-5c27b9.log */
static char g_dbg_serial[96];
static char g_dbg_json[512];

static void kmsg_scan(int *probe, int *en, int *gpiofail, int *ktz)
{
	char buf[1024];
	int fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
	ssize_t n;

	*probe = *en = *gpiofail = *ktz = 0;
	if (fd < 0) {
		*probe = -1;
		return;
	}
	while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
		buf[n] = '\0';
		if (strstr(buf, "probe-enter"))
			*probe = 1;
		if (strstr(buf, "enable-blinks"))
			*en = 1;
		if (strstr(buf, "Failed to get GPIO"))
			*gpiofail = 1;
		if (strstr(buf, "ktz8866"))
			*ktz = 1;
	}
	close(fd);
}

static void dbg_collect(void)
{
	int dt_led, leds, hwen, bl, drm, plat, gpio139, udc;
	int kmsg_probe, kmsg_en, kmsg_gpiofail, kmsg_ktz;

	mkpath("/sys/kernel/debug");
	mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL);

	dt_led = path_ok("/proc/device-tree/ktz_hwen_led");
	leds = dir_count("/sys/class/leds");
	hwen = dir_has_substr("/sys/class/leds", "hwen") ||
	       dir_has_substr("/sys/class/leds", "ktz");
	bl = dir_count("/sys/class/backlight");
	drm = path_ok("/sys/class/drm/card0");
	plat = dir_has_substr("/sys/bus/platform/devices", "ktz_hwen");
	gpio139 = file_has_substr("/sys/kernel/debug/gpio", "gpio-139");
	udc = dir_count("/sys/class/udc");
	kmsg_scan(&kmsg_probe, &kmsg_en, &kmsg_gpiofail, &kmsg_ktz);

	snprintf(g_dbg_serial, sizeof(g_dbg_serial),
		 "dt%dled%dhw%dbl%ddrm%dpl%dgp%dpe%den%dudc%d",
		 dt_led, leds < 0 ? 9 : leds, hwen, bl < 0 ? 9 : bl, drm, plat,
		 gpio139 < 0 ? 9 : gpio139, kmsg_probe < 0 ? 9 : kmsg_probe,
		 kmsg_en < 0 ? 9 : kmsg_en, udc < 0 ? 9 : udc);
	snprintf(g_dbg_json, sizeof(g_dbg_json),
		 "{\"sessionId\":\"5c27b9\",\"hypothesisId\":\"A\",\"location\":\"init.c:dbg_collect\",\"message\":\"pid1-scan\",\"data\":{\"dt_led\":%d,\"leds\":%d,\"hwen\":%d,\"bl\":%d,\"drm\":%d,\"plat\":%d,\"gpio139\":%d,\"probe\":%d,\"enable\":%d,\"gpiofail\":%d,\"ktz\":%d,\"udc\":%d},\"timestamp\":%lld}",
		 dt_led, leds, hwen, bl, drm, plat, gpio139, kmsg_probe,
		 kmsg_en, kmsg_gpiofail, kmsg_ktz, udc, dbg_now_ms());
	kmsg(g_dbg_serial);
	kmsg(g_dbg_json);
}

static void dbg_post_host(void)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in sa;
	struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
	char hdr[768];
	int blen, n;

	if (fd < 0)
		return;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons(7303);
	inet_pton(AF_INET, "192.168.7.1", &sa.sin_addr);
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		close(fd);
		return;
	}
	blen = (int)strlen(g_dbg_json);
	n = snprintf(hdr, sizeof(hdr),
		     "POST /ingest/f312a966-1073-4ed2-b639-6c4c77bc891d HTTP/1.1\r\n"
		     "Host: 192.168.7.1\r\n"
		     "Content-Type: application/json\r\n"
		     "X-Debug-Session-Id: 5c27b9\r\n"
		     "Content-Length: %d\r\n\r\n%s",
		     blen, g_dbg_json);
	if (n > 0 && n < (int)sizeof(hdr))
		write(fd, hdr, (size_t)n);
	close(fd);
	kmsg("dbg post tried");
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

	kmsg("reboot bootloader");
	sync();
	/* RESTART2 first — sysrq-b is a warm reboot into the same slot. */
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, "bootloader");
	write_str("/proc/sys/kernel/sysrq", "1");
	write_str("/proc/sysrq-trigger", "b");
	reboot(RB_AUTOBOOT);
	fd = open("/dev/watchdog", O_WRONLY);
	if (fd >= 0) {
		write(fd, "V", 1);
		close(fd);
	}
	for (;;)
		pause();
}

/*
 * Built-in g_serial (0525:a4a7) owns the UDC. Do not bind configfs RNDIS/ACM
 * — that steals UDC and ttyGS0 never carries printk (gemini lesson).
 * Keep poking Type-C role so DWC3 actually enumerates as gadget.
 */
static int setup_usb_console(void)
{
	char udc[64];
	int attempt;
	const int udc_wait_max = 160; /* 160 * 250ms = 40s */
	pid_t pid;

	if (kernel_is_4_19()) {
		kmsg("skip USB gadget on 4.19");
		return 0;
	}

	for (attempt = 0; attempt < udc_wait_max; attempt++) {
		wdt_pet();
		force_usb_device_role();
		if (find_udc(udc, sizeof(udc))) {
			if (attempt == 0 || attempt % 20 == 0)
				kmsg("waiting UDC for g_serial");
			usleep(250000);
			continue;
		}
		kmsg(udc);
		break;
	}
	/* kpss-wdt tops out at 0xfffff / 32764 Hz = 32 s; asking for more is -EINVAL. */
	wdt_stretch(30);
	wdt_pet();
	dbg_collect();
	if (attempt >= udc_wait_max)
		kmsg("no UDC after 40s — still waiting ttyGS0");

	pid = fork();
	if (pid != 0)
		return 0;

	/* Don't hold the watchdog fd in the kmsg-relay child. */
	if (wdt_fd >= 0) {
		close(wdt_fd);
		wdt_fd = -1;
	}

	for (;;) {
		int gs = open("/dev/ttyGS0", O_RDWR | O_NOCTTY);
		int kfd;
		char buf[512];
		ssize_t n;

		if (gs < 0) {
			usleep(100000);
			continue;
		}
		write(gs, "\r\ninitramfs: USB console on ttyGS0 (g_serial)\r\n",
		      strlen("\r\ninitramfs: USB console on ttyGS0 (g_serial)\r\n"));
		kfd = open("/dev/kmsg", O_RDONLY);
		for (;;) {
			if (kfd >= 0) {
				n = read(kfd, buf, sizeof(buf));
				if (n > 0)
					write(gs, buf, (size_t)n);
			}
			usleep(50000);
		}
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
		wdt_pet();
		if (i == 0 || i % 20 == 0)
			kmsg("waiting userdata");
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

static int run_tool(const char *path, const char *arg1, const char *arg2)
{
	char *argv[4];
	char buf[160];
	pid_t pid;
	int status;

	if (access(path, X_OK) != 0)
		return -ENOENT;

	argv[0] = (char *)path;
	argv[1] = arg1 ? (char *)arg1 : NULL;
	argv[2] = arg2 ? (char *)arg2 : NULL;
	argv[3] = NULL;

	snprintf(buf, sizeof(buf), "exec %s %s %s", path,
		 arg1 ? arg1 : "", arg2 ? arg2 : "");
	kmsg(buf);

	pid = fork();
	if (pid < 0) {
		kmsg("fork failed");
		return -1;
	}
	if (pid == 0) {
		int fd = open("/dev/kmsg", O_WRONLY);

		if (fd >= 0) {
			dup2(fd, STDOUT_FILENO);
			dup2(fd, STDERR_FILENO);
			if (fd > STDERR_FILENO)
				close(fd);
		}
		execv(path, argv);
		_exit(127);
	}

	for (;;) {
		wdt_pet();
		if (waitpid(pid, &status, WNOHANG) == pid)
			break;
		usleep(250000);
	}
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	if (WIFSIGNALED(status)) {
		snprintf(buf, sizeof(buf), "%s killed signal %d", path,
			 WTERMSIG(status));
		kmsg(buf);
	}
	return -1;
}

/* Repair + grow userdata while it is still unmounted. The 8G image is
 * flashed onto a ~106G partition; noload mounts leave EXT4_ERROR_FS so
 * userspace resize2fs is refused.
 */
static void grow_userdata(const char *dev)
{
	const char *e2fsck = NULL;
	const char *resize = NULL;
	char buf[96];
	int rc;

	if (!access("/sbin/e2fsck", X_OK))
		e2fsck = "/sbin/e2fsck";
	else if (!access("/usr/sbin/e2fsck", X_OK))
		e2fsck = "/usr/sbin/e2fsck";
	if (!access("/sbin/resize2fs", X_OK))
		resize = "/sbin/resize2fs";
	else if (!access("/usr/sbin/resize2fs", X_OK))
		resize = "/usr/sbin/resize2fs";
	if (!e2fsck || !resize) {
		kmsg("no e2fsck/resize2fs in ramdisk");
		return;
	}

	wdt_stretch(180);
	rc = run_tool(e2fsck, "-fy", dev);
	snprintf(buf, sizeof(buf), "e2fsck rc=%d", rc);
	kmsg(buf);
	if (rc > 2) {
		kmsg("e2fsck failed, skip resize");
		wdt_stretch(30);
		return;
	}
	rc = run_tool(resize, dev, NULL);
	snprintf(buf, sizeof(buf), "resize2fs rc=%d", rc);
	kmsg(buf);
	wdt_stretch(30);
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
	grow_userdata(rootdev);
	mkpath("/newroot");
	if (mount(rootdev, "/newroot", "ext4", 0, NULL)) {
		/*
		 * fastboot -S turns host file holes into don't-care. The ext4
		 * journal often sits past the copied files, so ABL leaves old
		 * userdata there and jbd2 rejects it. noload skips replay.
		 */
		kmsg("ext4 journal bad, retry noload");
		if (mount(rootdev, "/newroot", "ext4", 0, "noload")) {
			kmsg("userdata not ext4 (flash Ubuntu first)");
			return -1;
		}
	}
	if (access("/newroot/sbin/init", X_OK)) {
		kmsg("no /sbin/init on userdata");
		umount("/newroot");
		return -1;
	}

	install_venus_kos();
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
	wdt_magic_close();
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

#if DAGU_PID1_PING
	/* Zero-USB test: if PID1 runs, we bounce to ABL ~3s later. */
	kmsg("PID1 ping — sleep 3 then reboot bootloader");
	sleep(3);
	reboot_bootloader();
#endif

	mkpath("/dev/pts");
	mount("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
	mkpath("/tmp");
	mount("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");

	kmsg("P0 ramdisk — g_serial ttyGS0, skip configfs RNDIS");
	/* Early KPSS WDT is 30s (20-bit BITE_TIME ceiling); pet during UDC wait. */
	wdt_takeover(30);
	if (setup_usb_console())
		kmsg("USB console setup failed");

	if (try_switch_root())
		kmsg("stay on ramdisk");

	for (;;) {
		wdt_pet();
		kmsg("ramdisk idle");
		sleep(5);
	}
}
