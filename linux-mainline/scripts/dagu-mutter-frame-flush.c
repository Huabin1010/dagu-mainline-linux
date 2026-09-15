/* LD_PRELOAD: NOP the is_view_primary skip in
 * emit_frame_callbacks_for_stage_view (libmutter-18 50.1 VA 0x1673c8).
 *
 * Chrome Ozone waits on wl_surface.frame before PlayBackFrame
 * (WaitForFrameCallback). Mutter 50.1 only emits those callbacks when
 * meta_surface_actor_wayland_is_view_primary() is true. Cull with an
 * empty unobscured_region (270° + 1.25 + scale-monitor-framebuffer)
 * makes Chrome "not primary", so skipped-paint never releases the
 * frame callback. Chrome GPU sits in futex; Mutter goes
 * poll_schedule_timeout — the 80–180 ms kickoff hole.
 *
 * Do not queue_redraw / destile. Do not dec_use_count.
 *
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall \
 *     -o linux-mainline/scripts/libdagu-mutter-frame-flush.so \
 *     linux-mainline/scripts/dagu-mutter-frame-flush.c
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define CBZ_VA 0x1673c8UL
#define CBZ_INSN 0x34000280U /* cbz w0, +0x50 → skip emit */
#define NOP_INSN 0xD503201FU

static int logfd = -1;

static void log_line(const char *msg)
{
	char b[160];
	int n;

	if (logfd < 0)
		return;
	n = snprintf(b, sizeof(b), "frame-flush %s\n", msg);
	if (n > 0)
		(void)write(logfd, b, (size_t)n);
}

static uintptr_t find_mutter_base(void)
{
	FILE *f;
	char line[512];
	uintptr_t base = 0;

	f = fopen("/proc/self/maps", "r");
	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f)) {
		unsigned long start, end, off;
		char perm[8];

		if (!strstr(line, "libmutter-18.so.0"))
			continue;
		if (sscanf(line, "%lx-%lx %7s %lx", &start, &end, perm, &off) != 4)
			continue;
		if (perm[2] == 'x' && off == 0) {
			base = start;
			break;
		}
	}
	fclose(f);
	return base;
}

static int protect_rwx(void *addr, size_t len)
{
	uintptr_t p = (uintptr_t)addr & ~0xfffUL;
	uintptr_t e = ((uintptr_t)addr + len + 0xfffUL) & ~0xfffUL;

	return mprotect((void *)p, e - p, PROT_READ | PROT_WRITE | PROT_EXEC);
}

__attribute__((constructor))
static void init(void)
{
	uintptr_t base;
	uint32_t *src;

	logfd = open("/tmp/dagu-mutter-frame-flush.log",
		     O_RDWR | O_CREAT | O_APPEND, 0644);
	if (access("/tmp/dagu-no-frame-flush", F_OK) == 0) {
		log_line("disabled");
		return;
	}
	base = find_mutter_base();
	if (!base) {
		log_line("no_base");
		return;
	}
	src = (uint32_t *)(base + CBZ_VA);
	if (*src != CBZ_INSN) {
		char b[80];

		snprintf(b, sizeof(b), "mismatch %08x", (unsigned)*src);
		log_line(b);
		return;
	}
	if (protect_rwx(src, 4) != 0) {
		log_line("mprotect_fail");
		return;
	}
	*src = NOP_INSN;
	__builtin___clear_cache(src, (char *)src + 4);
	log_line("hooks_on");
}
