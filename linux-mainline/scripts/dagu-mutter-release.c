/* LD_PRELOAD for gnome-shell + libmutter-18 50.1-0ubuntu2.2.
 *
 * Chrome WaitForSwap waits for linux-drm-syncobj. Mutter only signals
 * that from the hidden meta_wayland_buffer_dec_use_count (VA 0x167e80).
 * A skipped paint never calls it → 80–180 ms holes.
 *
 * inc_use_count is inlined. We patch the three apply_state sites and
 * call dec at 0x167e80 when schedule_update sees an idle GPU / no redraw.
 *
 * Build:
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall \
 *     -o linux-mainline/scripts/libdagu-mutter-release.so \
 *     linux-mainline/scripts/dagu-mutter-release.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

enum { MAX_LIVE = 256 };
#define DEC_VA        0x167e80UL
#define INC1_VA       0x17110cUL
#define INC2_VA       0x1712b4UL
#define INC3_VA       0x18ef44UL
#define INC4_VA       0x185f68UL /* apply_state: buffer in x22 */
#define USE_COUNT_OFF 64

static void (*real_dec)(void *);
static void (*real_schedule)(void *);
static void (*real_after_paint)(void *, void *);
static int (*real_queued)(void *, void *);

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static void *live[MAX_LIVE];
static int nlive;
static int last_queued = 1;
static unsigned long rel_n, skip_n, paint_n, inc_n;
static int logfd = -1;
static uintptr_t mutter_base;

static void log_line(const char *msg)
{
    char b[320];
    struct timespec ts;
    int n;

    if (logfd < 0)
        return;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    n = snprintf(b, sizeof(b),
                 "%ld.%03ld %s rel=%lu skip=%lu paint=%lu inc=%lu live=%d\n",
                 (long)ts.tv_sec, ts.tv_nsec / 1000000, msg,
                 rel_n, skip_n, paint_n, inc_n, nlive);
    if (n > 0) {
        ssize_t ign = write(logfd, b, (size_t)n);
        (void)ign;
    }
}

static void live_add(void *buf)
{
    int i;

    if (!buf)
        return;
    pthread_mutex_lock(&mu);
    for (i = 0; i < nlive; i++) {
        if (live[i] == buf) {
            pthread_mutex_unlock(&mu);
            return;
        }
    }
    if (nlive < MAX_LIVE)
        live[nlive++] = buf;
    pthread_mutex_unlock(&mu);
    inc_n++;
}

static unsigned use_count(void *buf)
{
    if (!buf)
        return 0;
    return *(unsigned *)((char *)buf + USE_COUNT_OFF);
}

static int gpu_busy(void)
{
    char b[16];
    int fd, n;

    fd = open("/sys/class/drm/card0/device/gpu_busy_percent", O_RDONLY);
    if (fd < 0)
        return -1;
    n = (int)read(fd, b, sizeof(b) - 1);
    close(fd);
    if (n <= 0)
        return -1;
    b[n] = 0;
    return atoi(b);
}

static void force_release(const char *why)
{
    void *snapshot[MAX_LIVE];
    int n, i, did = 0;

    if (!real_dec)
        return;
    pthread_mutex_lock(&mu);
    n = nlive;
    memcpy(snapshot, live, (size_t)n * sizeof(void *));
    pthread_mutex_unlock(&mu);
    for (i = 0; i < n; i++) {
        void *buf = snapshot[i];
        unsigned c = use_count(buf);

        if (c == 0 || c > 32)
            continue;
        while (use_count(buf) > 0 && use_count(buf) <= 32)
            real_dec(buf);
        rel_n++;
        did++;
    }
    if (did)
        log_line(why);
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
        if (perm[2] == 'x' && !base)
            base = start - off;
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

/* 16-byte aarch64 absolute jump: LDR X16,#8; BR X16; .quad dest */
static void write_abs_jump(void *at, void *dest)
{
    uint32_t *p = at;
    uint64_t d = (uint64_t)(uintptr_t)dest;

    p[0] = 0x58000050; /* LDR X16, #8 */
    p[1] = 0xD61F0200; /* BR X16 */
    memcpy(p + 2, &d, 8);
    __builtin___clear_cache(at, (char *)at + 16);
}

static uint32_t mov_x0_from(int reg)
{
    /* MOV X0, Xn  — ORR X0, XZR, Xn */
    return 0xAA0003E0u | ((unsigned)reg << 16);
}

static void *make_inc_stub(uint32_t stolen[4], void *resume, int src_reg)
{
    uint8_t *m;
    uint32_t *p;
    uint64_t add_fn, res;

    m = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED)
        return NULL;
    p = (uint32_t *)m;
    /*
     * 0: bti jc
     * 1: stp x0, x30, [sp, #-16]!
     * 2: mov x0, xN
     * 3: ldr x16, 1f
     * 4: blr x16
     * 5: ldp x0, x30, [sp], #16
     * 6-9: stolen
     * 10: ldr x16, 2f
     * 11: br x16
     * 12-13: 1f live_add
     * 14-15: 2f resume
     *
     * p[3] LDR → p[12]: 9 insns = 36, imm=9 → 0x58000130
     * p[10] LDR → p[14]: 4 insns = 16, imm=4 → 0x58000090
     */
    p[0] = 0xD503245F;
    p[1] = 0xA9BF7BE0;
    p[2] = mov_x0_from(src_reg);
    p[3] = 0x58000130;
    p[4] = 0xD63F0200;
    p[5] = 0xA8C17BE0;
    memcpy(p + 6, stolen, 16);
    p[10] = 0x58000090;
    p[11] = 0xD61F0200;
    add_fn = (uint64_t)(uintptr_t)live_add;
    res = (uint64_t)(uintptr_t)resume;
    memcpy(p + 12, &add_fn, 8);
    memcpy(p + 14, &res, 8);
    __builtin___clear_cache(m, m + 96);
    return m;
}

static void patch_inc(uintptr_t va, int src_reg)
{
    uint32_t *src;
    uint32_t stolen[4];
    void *stub;

    src = (uint32_t *)(mutter_base + va);
    memcpy(stolen, src, 16);
    stub = make_inc_stub(stolen, (char *)src + 16, src_reg);
    if (!stub) {
        log_line("stub_fail");
        return;
    }
    if (protect_rwx(src, 16) != 0) {
        log_line("mprotect_fail");
        return;
    }
    write_abs_jump(src, stub);
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
    logfd = open("/tmp/dagu-mutter-release.log", O_RDWR | O_CREAT | O_APPEND, 0644);
    real_schedule = load_next("clutter_stage_schedule_update");
    real_after_paint = load_next("clutter_stage_view_after_paint");
    real_queued = load_next("clutter_stage_is_redraw_queued_on_view");
    mutter_base = find_mutter_base();
    if (mutter_base)
        real_dec = (void (*)(void *))(mutter_base + DEC_VA);
    log_line("init");
    if (!mutter_base || !real_dec) {
        log_line("no_mutter_base");
        return;
    }
    if (access("/tmp/dagu-no-hook", F_OK) == 0) {
        log_line("hooks_disabled");
        return;
    }
    patch_inc(INC1_VA, 0);
    patch_inc(INC2_VA, 0);
    patch_inc(INC3_VA, 0);
    patch_inc(INC4_VA, 22);
    log_line("hooks_on");
}

int
clutter_stage_is_redraw_queued_on_view(void *stage, void *view)
{
    int r = 1;

    if (real_queued)
        r = real_queued(stage, view);
    last_queued = r;
    return r;
}

void
clutter_stage_view_after_paint(void *view, void *frame)
{
    paint_n++;
    if (real_after_paint)
        real_after_paint(view, frame);
}

void
clutter_stage_schedule_update(void *stage)
{
    static unsigned beat;

    if (real_schedule)
        real_schedule(stage);
    beat++;
    if ((beat & 63) == 0)
        log_line("tick");
    /* Hole-blame: GPU busy=0 while Chrome WaitForSwap. Destile in
     * flight has busy>0, so this does not cut a live copy. */
    if (gpu_busy() == 0) {
        skip_n++;
        force_release("skip_idle");
    }
}
