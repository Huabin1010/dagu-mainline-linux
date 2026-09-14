/* LD_PRELOAD: replace meta_wayland_actor_surface_apply_state
 * (libmutter-18 50.1-0ubuntu2.2 VA 0x165124) with a C copy that also
 * wakes the clock + queue_redraws the surface actor on newly_attached.
 *
 * Do not patch mid-function (the 0x165170 trampoline crashed gnome-shell).
 * Do not call dec_use_count.
 *
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall \
 *     -o linux-mainline/scripts/libdagu-mutter-attach.so \
 *     linux-mainline/scripts/dagu-mutter-attach.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define APPLY_VA      0x165124UL
#define QUEUE_CB_VA   0x164f20UL
#define SYNC_VA       0x164fc0UL
#define PRIV_OFF_VA   0x2b51a0UL /* adrp 2b5000 + #416; GType private offset */
#define LIST_OFF      0x78
#define FIFO_OFF      332
#define NEWLY_OFF     24 /* GObject (24) + newly_attached */

static void (*real_queue_redraw)(void *);
static void *(*real_get_stage)(void *);
static void (*real_schedule)(void *);
static void (*queue_frame_cb)(void *, void *);
static void (*sync_actor)(void *);
static uintptr_t mutter_base;
static int logfd = -1;
static unsigned n_apply, n_redraw;

static void log_line(const char *msg)
{
	char b[160];
	int n;

	if (logfd < 0)
		return;
	n = snprintf(b, sizeof(b), "attach %s apply=%u redraw=%u\n",
		     msg, n_apply, n_redraw);
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

static void write_abs_jump(void *at, void *dest)
{
	uint32_t *p = at;
	uint64_t d = (uint64_t)(uintptr_t)dest;

	p[0] = 0x58000050;
	p[1] = 0xD61F0200;
	memcpy(p + 2, &d, 8);
	__builtin___clear_cache(at, (char *)at + 16);
}

static int list_empty(const void *list)
{
	const void *next = *(const void * const *)list;

	return next == list;
}

/* vfunc: x0 = MetaWaylandActorSurface *, x1 = MetaWaylandSurfaceState * */
void
dagu_apply_state(void *role, void *pending)
{
	int32_t priv_off;
	void *actor;

	n_apply++;
	if (!role || !pending || !mutter_base) {
		if (queue_frame_cb)
			queue_frame_cb(role, pending);
		if (sync_actor)
			sync_actor(role);
		return;
	}

	priv_off = *(int32_t *)(mutter_base + PRIV_OFF_VA);
	actor = *(void **)((char *)role + priv_off);
	if (actor) {
		int empty = list_empty((char *)pending + LIST_OFF);
		int fifo = *(int *)((char *)pending + FIFO_OFF);
		int newly = *(int *)((char *)pending + NEWLY_OFF);

		if (!empty || fifo || newly) {
			void *stage = real_get_stage ? real_get_stage(actor) : NULL;

			if (stage && real_schedule)
				real_schedule(stage);
			if (newly && real_queue_redraw) {
				real_queue_redraw(actor);
				n_redraw++;
				if ((n_redraw & 31) == 1)
					log_line("redraw");
			}
		}
	}
	queue_frame_cb(role, pending);
	sync_actor(role);
}

static void *load_next(const char *name)
{
	void *s = dlsym(RTLD_NEXT, name);

	if (!s)
		s = dlsym(RTLD_DEFAULT, name);
	return s;
}

__attribute__((constructor))
static void init(void)
{
	uint32_t *src;

	logfd = open("/tmp/dagu-mutter-attach.log", O_RDWR | O_CREAT | O_APPEND, 0644);
	real_queue_redraw = load_next("clutter_actor_queue_redraw");
	real_get_stage = load_next("clutter_actor_get_stage");
	real_schedule = load_next("clutter_stage_schedule_update");
	mutter_base = find_mutter_base();
	if (mutter_base) {
		queue_frame_cb = (void *)(mutter_base + QUEUE_CB_VA);
		sync_actor = (void *)(mutter_base + SYNC_VA);
	}
	log_line("init");
	if (!mutter_base || !real_queue_redraw || !real_get_stage ||
	    !real_schedule || !queue_frame_cb) {
		log_line("missing_sym");
		return;
	}
	if (access("/tmp/dagu-no-attach-hook", F_OK) == 0) {
		log_line("disabled");
		return;
	}
	src = (uint32_t *)(mutter_base + APPLY_VA);
	if (src[0] != 0xD503233F) { /* paciasp */
		log_line("apply_mismatch");
		return;
	}
	if (protect_rwx(src, 16) != 0) {
		log_line("mprotect_fail");
		return;
	}
	write_abs_jump(src, (void *)dagu_apply_state);
	log_line("hooks_on");
}
