/* LD_PRELOAD: when unobscured_region is empty, do not drop Chrome damage.
 *
 * meta_surface_actor_update_area (libmutter-18 50.1 @ 0x160f74):
 *   if (mtk_region_is_empty(unobscured_region)) return;
 *
 * 270° + scale 1.25 + scale-monitor-framebuffer can leave that region
 * empty even for a maximized Chrome window. Damage is discarded,
 * paint is skipped, is_view_primary is false, wl_surface.frame is
 * not emitted, Chrome Ozone WaitForFrameCallback sits 80–180 ms.
 *
 * Patch the empty-return into the "no cull" path
 * (clutter_actor_queue_redraw_with_clip of the full clip).
 * Only runs when Chrome already sent damage — not every attach,
 * not skipped-paint flood (that destile storm was 090107).
 *
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall \
 *     -o linux-mainline/scripts/libdagu-mutter-damage.so \
 *     linux-mainline/scripts/dagu-mutter-damage.c
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define EMPTY_RET_VA 0x160f78UL
#define EMPTY_RET_INSN 0xA9465BF5U /* ldp x21, x22, [sp, #96] */
#define B_NO_CULL 0x14000027U      /* b 0x161014 (full-clip redraw) */
/* empty intersection fallthrough: b 160f80 → b 161014 */
#define EMPTY_ISECT_VA 0x161010UL
#define EMPTY_ISECT_INSN 0x17FFFFDCU
#define B_NO_CULL_FROM_ISECT 0x14000001U

static int logfd = -1;

static void log_line(const char *msg)
{
	char b[160];
	int n;

	if (logfd < 0)
		return;
	n = snprintf(b, sizeof(b), "damage %s\n", msg);
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

	logfd = open("/tmp/dagu-mutter-damage.log",
		     O_RDWR | O_CREAT | O_APPEND, 0644);
	if (access("/tmp/dagu-no-damage-hook", F_OK) == 0) {
		log_line("disabled");
		return;
	}
	base = find_mutter_base();
	if (!base) {
		log_line("no_base");
		return;
	}
	src = (uint32_t *)(base + EMPTY_RET_VA);
	if (*src != EMPTY_RET_INSN && *src != B_NO_CULL) {
		char b[80];

		snprintf(b, sizeof(b), "mismatch %08x", (unsigned)*src);
		log_line(b);
		return;
	}
	if (protect_rwx(src, 8) != 0) {
		log_line("mprotect_fail");
		return;
	}
	if (*src == EMPTY_RET_INSN)
		*src = B_NO_CULL;
	__builtin___clear_cache(src, (char *)src + 4);

	src = (uint32_t *)(base + EMPTY_ISECT_VA);
	if (*src == EMPTY_ISECT_INSN) {
		if (protect_rwx(src, 4) != 0) {
			log_line("isect_mprotect_fail");
			return;
		}
		*src = B_NO_CULL_FROM_ISECT;
		__builtin___clear_cache(src, (char *)src + 4);
		log_line("hooks_on_isect");
	} else if (*src == B_NO_CULL_FROM_ISECT) {
		log_line("hooks_on_isect_already");
	} else {
		char b[80];

		snprintf(b, sizeof(b), "isect_mismatch %08x", (unsigned)*src);
		log_line(b);
	}
}
