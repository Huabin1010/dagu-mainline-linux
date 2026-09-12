/*
 * libkgsl_wrap.so — LD_PRELOAD interceptor for /dev/kgsl-3d0.
 * Writes a Freedreno .rd file that cffdump / rd_scan.py can decode.
 *
 * Also tries to yank vulkan.adreno.so out of the sphal namespace by
 * interposing android_load_sphal_library / android_dlopen_ext / dlopen.
 *
 *   DAGU_VULKAN_SO=/data/local/tmp/dagu-vulkan-truth/vulkan.adreno.so \
 *   WRAP_RD=/path/out.rd LD_PRELOAD=./libkgsl_wrap.so ./dagu-vk-probe
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef __user
#define __user
#endif

#include "msm_kgsl.h"
#include "redump.h"

#define MAX_BUFS 4096
#define MAX_FD 4096
#define DUMP_CAP (32u * 1024u * 1024u)

struct buf {
   bool used;
   bool dumped;
   uint32_t id;
   uint64_t gpuaddr;
   uint64_t size;
   void *host;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct buf bufs[MAX_BUFS];
static bool kgsl_fd[MAX_FD];
static int rd_fd = -1;
static FILE *logf;
static bool wrote_gpu_id;
static unsigned ioctl_log_left = 64;

static int (*real_openat)(int, const char *, int, ...);
static int (*real_ioctl)(int, int, ...);
static void *(*real_mmap)(void *, size_t, int, int, int, off_t);
static void *(*real_mmap64)(void *, size_t, int, int, int, off_t);
static int (*real_close)(int);
static long (*real_syscall)(long, ...);
static void *(*real_dlopen)(const char *, int);
static void *(*real_android_dlopen_ext)(const char *, int, const void *);
static void *(*real_android_load_sphal_library)(const char *, int);

static void wlog(const char *fmt, ...)
{
   va_list ap;
   va_start(ap, fmt);
   if (logf) {
      va_list ap2;
      va_copy(ap2, ap);
      vfprintf(logf, fmt, ap2);
      fputc('\n', logf);
      fflush(logf);
      va_end(ap2);
   }
   vfprintf(stderr, fmt, ap);
   fputc('\n', stderr);
   va_end(ap);
}

static const char *sandbox_vulkan(void)
{
   const char *p = getenv("DAGU_VULKAN_SO");
   if (p && p[0])
      return p;
   return "/data/local/tmp/dagu-vulkan-truth/vulkan.adreno.so";
}

static bool name_is_adreno_hal(const char *name)
{
   if (!name)
      return false;
   if (strstr(name, "vulkan.adreno"))
      return true;
   if (strstr(name, "vulkan.qti"))
      return true;
   return false;
}

static void *try_sandbox_dlopen(const char *orig, int flags)
{
   const char *alt = sandbox_vulkan();
   if (!alt[0])
      return NULL;
   if (orig && strcmp(orig, alt) == 0)
      return NULL;
   void *h = real_dlopen ? real_dlopen(alt, flags ? flags : RTLD_NOW) : dlopen(alt, flags ? flags : RTLD_NOW);
   if (h)
      wlog("wrap: redirected %s -> %s (default ns)", orig ? orig : "(null)", alt);
   else
      wlog("wrap: redirect FAIL %s -> %s: %s", orig ? orig : "(null)", alt,
           dlerror());
   return h;
}

static void ensure_syms(void)
{
   if (!real_openat)
      real_openat = dlsym(RTLD_NEXT, "openat");
   if (!real_ioctl)
      real_ioctl = dlsym(RTLD_NEXT, "ioctl");
   if (!real_mmap)
      real_mmap = dlsym(RTLD_NEXT, "mmap");
   if (!real_mmap64)
      real_mmap64 = dlsym(RTLD_NEXT, "mmap64");
   if (!real_close)
      real_close = dlsym(RTLD_NEXT, "close");
   if (!real_syscall)
      real_syscall = dlsym(RTLD_NEXT, "syscall");
   if (!real_dlopen)
      real_dlopen = dlsym(RTLD_NEXT, "dlopen");
   if (!real_android_dlopen_ext)
      real_android_dlopen_ext = dlsym(RTLD_NEXT, "android_dlopen_ext");
   if (!real_android_load_sphal_library)
      real_android_load_sphal_library =
         dlsym(RTLD_NEXT, "android_load_sphal_library");
}

static void rd_open_once(void)
{
   if (rd_fd >= 0)
      return;
   const char *p = getenv("WRAP_RD");
   if (!p || !p[0])
      p = "/data/local/tmp/dagu-vulkan-truth/capture.rd";
   rd_fd = open(p, O_CREAT | O_TRUNC | O_WRONLY, 0644);
   if (rd_fd < 0)
      wlog("wrap: cannot open WRAP_RD %s: %s", p, strerror(errno));
   else
      wlog("wrap: writing %s", p);
}

static void rd_gpu_id(void)
{
   if (wrote_gpu_id || rd_fd < 0)
      return;
   uint32_t id = 650;
   rd_write_section(rd_fd, RD_GPU_ID, &id, sizeof(id));
   uint64_t chip = 0x06050000ull;
   rd_write_section(rd_fd, RD_CHIP_ID, &chip, sizeof(chip));
   wrote_gpu_id = true;
}

static struct buf *buf_alloc(void)
{
   for (int i = 0; i < MAX_BUFS; i++) {
      if (!bufs[i].used) {
         memset(&bufs[i], 0, sizeof(bufs[i]));
         bufs[i].used = true;
         return &bufs[i];
      }
   }
   return NULL;
}

static struct buf *buf_by_id(uint32_t id)
{
   for (int i = 0; i < MAX_BUFS; i++)
      if (bufs[i].used && bufs[i].id == id)
         return &bufs[i];
   return NULL;
}

static struct buf *buf_by_gpu(uint64_t gpu)
{
   if (!gpu)
      return NULL;
   for (int i = 0; i < MAX_BUFS; i++) {
      if (!bufs[i].used || !bufs[i].gpuaddr)
         continue;
      if (gpu >= bufs[i].gpuaddr && gpu < bufs[i].gpuaddr + bufs[i].size)
         return &bufs[i];
   }
   return NULL;
}

static void mark_kgsl(int fd)
{
   if (fd >= 0 && fd < MAX_FD)
      kgsl_fd[fd] = true;
}

static bool is_kgsl(int fd)
{
   return fd >= 0 && fd < MAX_FD && kgsl_fd[fd];
}

static void maybe_note_path(int fd, const char *path)
{
   if (!path)
      return;
   if (strstr(path, "kgsl-3d0") || strstr(path, "kgsl-3d")) {
      mark_kgsl(fd);
      wlog("wrap: kgsl fd=%d path=%s", fd, path);
      rd_open_once();
      rd_gpu_id();
   }
}

static void hex_ib(uint64_t gpuaddr, const uint32_t *w, uint32_t dwords)
{
   if (!w || !dwords)
      return;
   uint32_t n = dwords > 32 ? 32 : dwords;
   char line[512];
   size_t pos = 0;
   pos += (size_t)snprintf(line + pos, sizeof(line) - pos,
                           "wrap: IB HEX gpu=0x%llx ndw=%u:",
                           (unsigned long long)gpuaddr, dwords);
   for (uint32_t i = 0; i < n && pos + 12 < sizeof(line); i++)
      pos += (size_t)snprintf(line + pos, sizeof(line) - pos, " %08x", w[i]);
   if (dwords > n && pos + 4 < sizeof(line))
      snprintf(line + pos, sizeof(line) - pos, " ...");
   wlog("%s", line);
}

static void dump_all_bufs(void)
{
   if (rd_fd < 0)
      return;
   for (int i = 0; i < MAX_BUFS; i++) {
      struct buf *b = &bufs[i];
      if (!b->used || !b->host || !b->gpuaddr || !b->size || b->dumped)
         continue;
      uint32_t n = (uint32_t)(b->size > DUMP_CAP ? DUMP_CAP : b->size);
      uint32_t sect[3] = {(uint32_t)b->gpuaddr, n, (uint32_t)(b->gpuaddr >> 32)};
      rd_write_section(rd_fd, RD_GPUADDR, sect, sizeof(sect));
      rd_write_section(rd_fd, RD_BUFFER_CONTENTS, b->host, (int)n);
      b->dumped = true;
   }
}

static void *host_at(struct buf *b, uint64_t gpuaddr)
{
   if (!b || !b->host)
      return NULL;
   if (b->gpuaddr && gpuaddr >= b->gpuaddr)
      return (uint8_t *)b->host + (size_t)(gpuaddr - b->gpuaddr);
   return b->host;
}

static void dump_cmd_ib(uint64_t gpuaddr, uint64_t size, uint32_t id)
{
   struct buf *b = buf_by_id(id);
   if (!b)
      b = buf_by_gpu(gpuaddr);
   uint32_t dwords = (uint32_t)(size / 4);
   void *host = host_at(b, gpuaddr);
   if (!host) {
      wlog("wrap: IB gpu=0x%llx size=%llu id=%u  NO HOSTPTR",
           (unsigned long long)gpuaddr, (unsigned long long)size, id);
   } else {
      wlog("wrap: IB gpu=0x%llx size=%llu id=%u host=%p",
           (unsigned long long)gpuaddr, (unsigned long long)size, id, host);
      if (dwords && dwords <= 64)
         hex_ib(gpuaddr, host, dwords);
   }
   dump_all_bufs();
   if (rd_fd >= 0 && gpuaddr && dwords) {
      uint32_t sect[3] = {(uint32_t)gpuaddr, dwords,
                          (uint32_t)(gpuaddr >> 32)};
      rd_write_section(rd_fd, RD_CMDSTREAM_ADDR, sect, sizeof(sect));
   }
}

static void note_cmd_obj(struct kgsl_command_object *c)
{
   if (!c || !c->id)
      return;
   struct buf *b = buf_by_id(c->id);
   if (!b) {
      b = buf_alloc();
      if (b)
         b->id = c->id;
   }
   if (!b)
      return;
   if (c->gpuaddr)
      b->gpuaddr = c->gpuaddr;
   if (c->size && c->size > b->size)
      b->size = c->size;
}

static void on_gpuobj_alloc_pre(struct kgsl_gpuobj_alloc *p)
{
   p->flags &= ~KGSL_MEMFLAGS_USE_CPU_MAP;
}

static void on_gpuobj_alloc_post(struct kgsl_gpuobj_alloc *p)
{
   struct buf *b = buf_alloc();
   if (!b)
      return;
   b->id = p->id;
   b->size = p->size;
   wlog("wrap: GPUOBJ_ALLOC id=%u size=%llu flags=0x%llx", p->id,
        (unsigned long long)p->size, (unsigned long long)p->flags);
}

static void on_gpuobj_info_post(struct kgsl_gpuobj_info *p)
{
   struct buf *b = buf_by_id(p->id);
   if (!b) {
      b = buf_alloc();
      if (b)
         b->id = p->id;
   }
   if (!b)
      return;
   b->gpuaddr = p->gpuaddr;
   if (p->size)
      b->size = p->size;
   if (p->va_addr && !b->host)
      b->host = (void *)(uintptr_t)p->va_addr;
   wlog("wrap: GPUOBJ_INFO id=%u gpu=0x%llx size=%llu va=0x%llx", p->id,
        (unsigned long long)p->gpuaddr, (unsigned long long)p->size,
        (unsigned long long)p->va_addr);
}

static void on_gpuobj_free(uint32_t id)
{
   struct buf *b = buf_by_id(id);
   if (b)
      b->used = false;
}

static void on_gpumem_alloc_id_pre(struct kgsl_gpumem_alloc_id *p)
{
   p->flags &= ~KGSL_MEMFLAGS_USE_CPU_MAP;
}

static void on_gpumem_alloc_id_post(struct kgsl_gpumem_alloc_id *p)
{
   struct buf *b = buf_alloc();
   if (!b)
      return;
   b->id = p->id;
   b->gpuaddr = p->gpuaddr;
   b->size = p->size;
   wlog("wrap: GPUMEM_ALLOC_ID id=%u gpu=0x%llx size=%llu", p->id,
        (unsigned long long)p->gpuaddr, (unsigned long long)p->size);
}

static void on_gpumem_get_info_post(struct kgsl_gpumem_get_info *p)
{
   struct buf *b = buf_by_id(p->id);
   if (!b) {
      b = buf_alloc();
      if (b)
         b->id = p->id;
   }
   if (!b)
      return;
   if (p->gpuaddr)
      b->gpuaddr = p->gpuaddr;
   if (p->size)
      b->size = p->size;
   if (p->mmapsize && !b->size)
      b->size = p->mmapsize;
   wlog("wrap: GPUMEM_GET_INFO id=%u gpu=0x%llx size=%llu", p->id,
        (unsigned long long)p->gpuaddr, (unsigned long long)p->size);
}

static void walk_cmd_objects(uint64_t list, unsigned n, unsigned step, const char *tag)
{
   if (!list || !n)
      return;
   if (!step)
      step = (unsigned)sizeof(struct kgsl_command_object);
   struct kgsl_command_object *base = (struct kgsl_command_object *)(uintptr_t)list;
   for (unsigned i = 0; i < n && i < 256; i++) {
      struct kgsl_command_object *c =
         (struct kgsl_command_object *)((uint8_t *)base + (size_t)i * step);
      note_cmd_obj(c);
      wlog("wrap: %s[%u] gpu=0x%llx size=%llu id=%u flags=0x%x", tag, i,
           (unsigned long long)c->gpuaddr, (unsigned long long)c->size, c->id,
           c->flags);
      dump_cmd_ib(c->gpuaddr, c->size, c->id);
   }
}

static void on_gpu_command(struct kgsl_gpu_command *p)
{
   for (int i = 0; i < MAX_BUFS; i++)
      bufs[i].dumped = false;
   wlog("wrap: GPU_COMMAND ctx=%u ncmd=%u nobj=%u flags=0x%llx",
        p->context_id, p->numcmds, p->numobjs, (unsigned long long)p->flags);
   walk_cmd_objects(p->cmdlist, p->numcmds, p->cmdsize, "cmd");
   walk_cmd_objects(p->objlist, p->numobjs, p->objsize, "obj");
}

static void on_submit_commands(struct kgsl_submit_commands *p)
{
   for (int i = 0; i < MAX_BUFS; i++)
      bufs[i].dumped = false;
   wlog("wrap: SUBMIT_COMMANDS ctx=%u ncmd=%u", p->context_id, p->numcmds);
   if (!p->cmdlist)
      return;
   for (unsigned i = 0; i < p->numcmds && i < 256; i++) {
      struct kgsl_ibdesc *ib = &p->cmdlist[i];
      wlog("wrap: ibdesc[%u] gpu=0x%lx dw=%zu ctrl=0x%x", i, ib->gpuaddr,
           ib->sizedwords, ib->ctrl);
      dump_cmd_ib(ib->gpuaddr, (uint64_t)ib->sizedwords * 4, 0);
   }
}

static void ioctl_pre(int fd, unsigned long req, void *ptr)
{
   (void)fd;
   unsigned nr = _IOC_NR(req);
   if (ioctl_log_left) {
      ioctl_log_left--;
      wlog("wrap: ioctl nr=0x%x req=0x%lx ptr=%p", nr, req, ptr);
   }
   if (nr == _IOC_NR(IOCTL_KGSL_GPUOBJ_ALLOC) && ptr)
      on_gpuobj_alloc_pre(ptr);
   else if (nr == _IOC_NR(IOCTL_KGSL_GPUMEM_ALLOC_ID) && ptr)
      on_gpumem_alloc_id_pre(ptr);
}

static void ioctl_post(int fd, unsigned long req, void *ptr, int ret)
{
   (void)fd;
   if (ret < 0 || !ptr)
      return;
   unsigned nr = _IOC_NR(req);
   if (nr == _IOC_NR(IOCTL_KGSL_GPUOBJ_ALLOC))
      on_gpuobj_alloc_post(ptr);
   else if (nr == _IOC_NR(IOCTL_KGSL_GPUOBJ_INFO))
      on_gpuobj_info_post(ptr);
   else if (nr == _IOC_NR(IOCTL_KGSL_GPUOBJ_FREE))
      on_gpuobj_free(((struct kgsl_gpuobj_free *)ptr)->id);
   else if (nr == _IOC_NR(IOCTL_KGSL_GPUMEM_ALLOC_ID))
      on_gpumem_alloc_id_post(ptr);
   else if (nr == _IOC_NR(IOCTL_KGSL_GPUMEM_FREE_ID))
      on_gpuobj_free(((struct kgsl_gpumem_free_id *)ptr)->id);
   else if (nr == _IOC_NR(IOCTL_KGSL_GPUMEM_GET_INFO))
      on_gpumem_get_info_post(ptr);
   else if (nr == _IOC_NR(IOCTL_KGSL_GPU_COMMAND))
      on_gpu_command(ptr);
   else if (nr == _IOC_NR(IOCTL_KGSL_SUBMIT_COMMANDS))
      on_submit_commands(ptr);
}

int openat(int dirfd, const char *path, int flags, ...)
{
   ensure_syms();
   mode_t mode = 0;
   if (flags & O_CREAT) {
      va_list ap;
      va_start(ap, flags);
      mode = va_arg(ap, int);
      va_end(ap);
   }
   int fd = real_openat(dirfd, path, flags, mode);
   if (fd >= 0 && path) {
      pthread_mutex_lock(&lock);
      maybe_note_path(fd, path);
      pthread_mutex_unlock(&lock);
   }
   return fd;
}

int open(const char *path, int flags, ...)
{
   mode_t mode = 0;
   if (flags & O_CREAT) {
      va_list ap;
      va_start(ap, flags);
      mode = va_arg(ap, int);
      va_end(ap);
   }
   return openat(AT_FDCWD, path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
   mode_t mode = 0;
   if (flags & O_CREAT) {
      va_list ap;
      va_start(ap, flags);
      mode = va_arg(ap, int);
      va_end(ap);
   }
   return openat(AT_FDCWD, path, flags, mode);
}

int ioctl(int fd, int request, ...)
{
   ensure_syms();
   va_list ap;
   va_start(ap, request);
   void *ptr = va_arg(ap, void *);
   va_end(ap);
   unsigned long req = (unsigned long)(unsigned int)request;
   pthread_mutex_lock(&lock);
   bool ours = is_kgsl(fd);
   if (ours)
      ioctl_pre(fd, req, ptr);
   pthread_mutex_unlock(&lock);
   int ret = real_ioctl(fd, request, ptr);
   pthread_mutex_lock(&lock);
   if (ours)
      ioctl_post(fd, req, ptr, ret);
   pthread_mutex_unlock(&lock);
   return ret;
}

long syscall(long number, ...)
{
   long a = 0, b = 0, c = 0, d = 0, e = 0, f = 0;
   va_list ap;
   va_start(ap, number);
   a = va_arg(ap, long);
   b = va_arg(ap, long);
   c = va_arg(ap, long);
   d = va_arg(ap, long);
   e = va_arg(ap, long);
   f = va_arg(ap, long);
   va_end(ap);
   ensure_syms();
#ifdef __NR_ioctl
   if (number == __NR_ioctl)
      return ioctl((int)a, (int)b, (void *)(uintptr_t)c);
#endif
#ifdef __NR_openat
   if (number == __NR_openat)
      return openat((int)a, (const char *)(uintptr_t)b, (int)c, (int)d);
#endif
#ifdef __NR_close
   if (number == __NR_close)
      return close((int)a);
#endif
#ifdef __NR_mmap
   if (number == __NR_mmap)
      return (long)mmap((void *)(uintptr_t)a, (size_t)b, (int)c, (int)d,
                        (int)e, (off_t)f);
#endif
   if (!real_syscall)
      return -1;
   return real_syscall(number, a, b, c, d, e, f);
}

static void note_mmap(int fd, off_t off, void *addr, size_t len)
{
   if (!is_kgsl(fd) || addr == MAP_FAILED || !addr)
      return;
   uint32_t id = (uint32_t)(off >> 12);
   struct buf *b = buf_by_id(id);
   if (!b) {
      b = buf_alloc();
      if (b)
         b->id = id;
   }
   if (!b)
      return;
   b->host = addr;
   if (!b->size)
      b->size = len;
   wlog("wrap: mmap fd=%d id=%u -> %p len=%zu", fd, id, addr, len);
}

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset)
{
   ensure_syms();
   void *ret = real_mmap(addr, length, prot, flags, fd, offset);
   pthread_mutex_lock(&lock);
   note_mmap(fd, offset, ret, length);
   pthread_mutex_unlock(&lock);
   return ret;
}

void *mmap64(void *addr, size_t length, int prot, int flags, int fd, off_t offset)
{
   ensure_syms();
   void *(*fn)(void *, size_t, int, int, int, off_t) =
      real_mmap64 ? real_mmap64 : real_mmap;
   void *ret = fn(addr, length, prot, flags, fd, offset);
   pthread_mutex_lock(&lock);
   note_mmap(fd, offset, ret, length);
   pthread_mutex_unlock(&lock);
   return ret;
}

int close(int fd)
{
   ensure_syms();
   pthread_mutex_lock(&lock);
   if (fd >= 0 && fd < MAX_FD)
      kgsl_fd[fd] = false;
   pthread_mutex_unlock(&lock);
   return real_close(fd);
}

void *dlopen(const char *filename, int flags)
{
   ensure_syms();
   if (name_is_adreno_hal(filename)) {
      void *h = try_sandbox_dlopen(filename, flags);
      if (h)
         return h;
   }
   return real_dlopen(filename, flags);
}

void *android_dlopen_ext(const char *filename, int flags, const void *info)
{
   ensure_syms();
   if (name_is_adreno_hal(filename)) {
      void *h = try_sandbox_dlopen(filename, flags);
      if (h)
         return h;
      wlog("wrap: android_dlopen_ext passthrough %s (sandbox failed)",
           filename ? filename : "(null)");
   }
   if (!real_android_dlopen_ext)
      return real_dlopen ? real_dlopen(filename, flags) : NULL;
   return real_android_dlopen_ext(filename, flags, info);
}

void *android_load_sphal_library(const char *filename, int flag)
{
   ensure_syms();
   wlog("wrap: android_load_sphal_library %s flag=%d",
        filename ? filename : "(null)", flag);
   if (name_is_adreno_hal(filename) || (filename && strstr(filename, "vulkan"))) {
      void *h = try_sandbox_dlopen(filename, flag);
      if (h)
         return h;
   }
   if (!real_android_load_sphal_library) {
      wlog("wrap: no real android_load_sphal_library");
      return real_dlopen ? real_dlopen(filename, flag ? flag : RTLD_NOW) : NULL;
   }
   return real_android_load_sphal_library(filename, flag);
}

__attribute__((constructor)) static void wrap_ctor(void)
{
   ensure_syms();
   const char *lp = getenv("WRAP_LOG");
   if (lp && lp[0]) {
      logf = fopen(lp, "w");
   } else {
      logf = fopen("/data/local/tmp/dagu-vulkan-truth/wrap.log", "w");
   }
   wlog("wrap: loaded (heist, sphal-hook=%p dlopen_ext=%p)",
        (void *)real_android_load_sphal_library,
        (void *)real_android_dlopen_ext);
}

__attribute__((destructor)) static void wrap_dtor(void)
{
   if (rd_fd >= 0)
      close(rd_fd);
   if (logf)
      fclose(logf);
}
