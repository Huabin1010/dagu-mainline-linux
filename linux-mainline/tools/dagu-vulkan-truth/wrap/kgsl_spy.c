/*
 * kgsl_spy — ptrace interceptor for KGSL ioctls.
 *
 * Lives outside the Android linker namespace, so sphal / VNDK isolation
 * cannot hide /dev/kgsl-3d0 from it. Writes the same Freedreno .rd as
 * libkgsl_wrap.so.
 *
 *   WRAP_RD=out.rd WRAP_LOG=spy.log ./kgsl_spy -- ./dagu-vk-probe ...
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <linux/elf.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef __user
#define __user
#endif

#include "msm_kgsl.h"
#include "redump.h"

#define MAX_BUFS 4096
#define MAX_FD 4096
#define MAX_TIDS 128
#define DUMP_CAP (32u * 1024u * 1024u)
#define CHILD_CHUNK (256u * 1024u)

struct buf {
   bool used;
   bool dumped;
   uint32_t id;
   uint64_t gpuaddr;
   uint64_t size;
   uint64_t host;
};

struct tid_st {
   pid_t tid;
   bool in_sys;
   bool used;
   int pending; /* 0 none, 1 ioctl, 2 mmap, 3 openat */
   unsigned long req;
   uint64_t arg;
   int fd;
   uint64_t mmap_off;
   uint64_t mmap_len;
   uint64_t path_ptr;
};

static struct buf bufs[MAX_BUFS];
static bool kgsl_fd[MAX_FD];
static struct tid_st tids[MAX_TIDS];
static int rd_fd = -1;
static FILE *logf;
static bool wrote_gpu_id;
static unsigned ioctl_log_left = 80;
static pid_t root_pid;

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

static int vm_read(pid_t pid, uint64_t addr, void *dst, size_t n)
{
   if (!addr || !n)
      return -1;
   struct iovec local = { .iov_base = dst, .iov_len = n };
   struct iovec remote = { .iov_base = (void *)(uintptr_t)addr, .iov_len = n };
   ssize_t r = process_vm_readv(pid, &local, 1, &remote, 1, 0);
   return (r == (ssize_t)n) ? 0 : -1;
}

static int vm_write(pid_t pid, uint64_t addr, const void *src, size_t n)
{
   if (!addr || !n)
      return -1;
   struct iovec local = { .iov_base = (void *)src, .iov_len = n };
   struct iovec remote = { .iov_base = (void *)(uintptr_t)addr, .iov_len = n };
   ssize_t r = process_vm_writev(pid, &local, 1, &remote, 1, 0);
   return (r == (ssize_t)n) ? 0 : -1;
}

static int getregs(pid_t tid, struct user_regs_struct *r)
{
   struct iovec io = { .iov_base = r, .iov_len = sizeof(*r) };
   return ptrace(PTRACE_GETREGSET, tid, (void *)(uintptr_t)NT_PRSTATUS, &io);
}

static struct tid_st *tid_get(pid_t tid, bool create)
{
   for (int i = 0; i < MAX_TIDS; i++)
      if (tids[i].used && tids[i].tid == tid)
         return &tids[i];
   if (!create)
      return NULL;
   for (int i = 0; i < MAX_TIDS; i++) {
      if (!tids[i].used) {
         memset(&tids[i], 0, sizeof(tids[i]));
         tids[i].used = true;
         tids[i].tid = tid;
         return &tids[i];
      }
   }
   return NULL;
}

static void tid_drop(pid_t tid)
{
   for (int i = 0; i < MAX_TIDS; i++)
      if (tids[i].used && tids[i].tid == tid)
         tids[i].used = false;
}

static void rd_open_once(void)
{
   if (rd_fd >= 0)
      return;
   const char *p = getenv("WRAP_RD");
   if (!p || !p[0])
      p = "/data/local/tmp/dagu-vulkan-truth/spy.rd";
   rd_fd = open(p, O_CREAT | O_TRUNC | O_WRONLY, 0644);
   if (rd_fd < 0)
      wlog("spy: cannot open WRAP_RD %s: %s", p, strerror(errno));
   else
      wlog("spy: writing %s", p);
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

static void hex_ib(uint64_t gpuaddr, const uint32_t *w, uint32_t dwords)
{
   if (!w || !dwords)
      return;
   uint32_t n = dwords > 32 ? 32 : dwords;
   char line[512];
   size_t pos = 0;
   pos += (size_t)snprintf(line + pos, sizeof(line) - pos,
                           "spy: IB HEX gpu=0x%llx ndw=%u:",
                           (unsigned long long)gpuaddr, dwords);
   for (uint32_t i = 0; i < n && pos + 12 < sizeof(line); i++)
      pos += (size_t)snprintf(line + pos, sizeof(line) - pos, " %08x", w[i]);
   wlog("%s", line);
}

static int copy_child(pid_t pid, uint64_t addr, uint64_t n, void **out)
{
   if (!addr || !n || n > DUMP_CAP)
      return -1;
   void *tmp = malloc((size_t)n);
   if (!tmp)
      return -1;
   uint64_t off = 0;
   while (off < n) {
      size_t chunk = (size_t)((n - off) > CHILD_CHUNK ? CHILD_CHUNK : (n - off));
      if (vm_read(pid, addr + off, (uint8_t *)tmp + off, chunk)) {
         free(tmp);
         return -1;
      }
      off += chunk;
   }
   *out = tmp;
   return 0;
}

static void dump_all_bufs(pid_t pid)
{
   if (rd_fd < 0)
      return;
   for (int i = 0; i < MAX_BUFS; i++) {
      struct buf *b = &bufs[i];
      if (!b->used || !b->host || !b->gpuaddr || !b->size || b->dumped)
         continue;
      uint64_t n = b->size > DUMP_CAP ? DUMP_CAP : b->size;
      void *tmp = NULL;
      if (copy_child(pid, b->host, n, &tmp))
         continue;
      uint32_t sect[3] = {(uint32_t)b->gpuaddr, (uint32_t)n,
                          (uint32_t)(b->gpuaddr >> 32)};
      rd_write_section(rd_fd, RD_GPUADDR, sect, sizeof(sect));
      rd_write_section(rd_fd, RD_BUFFER_CONTENTS, tmp, (int)n);
      free(tmp);
      b->dumped = true;
   }
}

static void dump_cmd_ib(pid_t pid, uint64_t gpuaddr, uint64_t size, uint32_t id)
{
   struct buf *b = buf_by_id(id);
   if (!b)
      b = buf_by_gpu(gpuaddr);
   uint32_t dwords = (uint32_t)(size / 4);
   uint64_t host = 0;
   if (b && b->host) {
      if (b->gpuaddr && gpuaddr >= b->gpuaddr)
         host = b->host + (gpuaddr - b->gpuaddr);
      else
         host = b->host;
   }
   if (!host) {
      wlog("spy: IB gpu=0x%llx size=%llu id=%u  NO HOSTPTR",
           (unsigned long long)gpuaddr, (unsigned long long)size, id);
   } else {
      wlog("spy: IB gpu=0x%llx size=%llu id=%u host=0x%llx",
           (unsigned long long)gpuaddr, (unsigned long long)size, id,
           (unsigned long long)host);
      if (dwords && dwords <= 64) {
         uint32_t tmp[64];
         size_t nb = (size_t)dwords * 4;
         if (nb <= sizeof(tmp) && vm_read(pid, host, tmp, nb) == 0)
            hex_ib(gpuaddr, tmp, dwords);
      }
   }
   dump_all_bufs(pid);
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

static void walk_cmd_objects(pid_t pid, uint64_t list, unsigned n, unsigned step,
                             const char *tag)
{
   if (!list || !n)
      return;
   if (!step)
      step = (unsigned)sizeof(struct kgsl_command_object);
   for (unsigned i = 0; i < n && i < 256; i++) {
      struct kgsl_command_object c;
      memset(&c, 0, sizeof(c));
      if (vm_read(pid, list + (uint64_t)i * step, &c, sizeof(c)))
         continue;
      note_cmd_obj(&c);
      wlog("spy: %s[%u] gpu=0x%llx size=%llu id=%u flags=0x%x", tag, i,
           (unsigned long long)c.gpuaddr, (unsigned long long)c.size, c.id,
           c.flags);
      dump_cmd_ib(pid, c.gpuaddr, c.size, c.id);
   }
}

static void on_gpu_command(pid_t pid, uint64_t arg)
{
   struct kgsl_gpu_command p;
   if (vm_read(pid, arg, &p, sizeof(p)))
      return;
   for (int i = 0; i < MAX_BUFS; i++)
      bufs[i].dumped = false;
   wlog("spy: GPU_COMMAND ctx=%u ncmd=%u nobj=%u flags=0x%llx", p.context_id,
        p.numcmds, p.numobjs, (unsigned long long)p.flags);
   walk_cmd_objects(pid, p.cmdlist, p.numcmds, p.cmdsize, "cmd");
   walk_cmd_objects(pid, p.objlist, p.numobjs, p.objsize, "obj");
}

static void ioctl_enter(pid_t pid, int fd, unsigned long req, uint64_t arg)
{
   if (!is_kgsl(fd) || !arg)
      return;
   unsigned nr = _IOC_NR(req);
   if (ioctl_log_left) {
      ioctl_log_left--;
      wlog("spy: ioctl enter nr=0x%x req=0x%lx fd=%d", nr, req, fd);
   }
   if (nr == _IOC_NR(IOCTL_KGSL_GPUOBJ_ALLOC)) {
      struct kgsl_gpuobj_alloc p;
      if (vm_read(pid, arg, &p, sizeof(p)) == 0) {
         p.flags &= ~KGSL_MEMFLAGS_USE_CPU_MAP;
         vm_write(pid, arg, &p, sizeof(p));
      }
   } else if (nr == _IOC_NR(IOCTL_KGSL_GPUMEM_ALLOC_ID)) {
      struct kgsl_gpumem_alloc_id p;
      if (vm_read(pid, arg, &p, sizeof(p)) == 0) {
         p.flags &= ~KGSL_MEMFLAGS_USE_CPU_MAP;
         vm_write(pid, arg, &p, sizeof(p));
      }
   }
}

static void ioctl_leave(pid_t pid, int fd, unsigned long req, uint64_t arg,
                        long ret)
{
   if (!is_kgsl(fd) || ret < 0 || !arg)
      return;
   unsigned nr = _IOC_NR(req);
   if (nr == _IOC_NR(IOCTL_KGSL_GPUOBJ_ALLOC)) {
      struct kgsl_gpuobj_alloc p;
      if (vm_read(pid, arg, &p, sizeof(p)))
         return;
      struct buf *b = buf_alloc();
      if (!b)
         return;
      b->id = p.id;
      b->size = p.size;
      wlog("spy: GPUOBJ_ALLOC id=%u size=%llu", p.id, (unsigned long long)p.size);
   } else if (nr == _IOC_NR(IOCTL_KGSL_GPUOBJ_INFO)) {
      struct kgsl_gpuobj_info p;
      if (vm_read(pid, arg, &p, sizeof(p)))
         return;
      struct buf *b = buf_by_id(p.id);
      if (!b) {
         b = buf_alloc();
         if (b)
            b->id = p.id;
      }
      if (!b)
         return;
      b->gpuaddr = p.gpuaddr;
      if (p.size)
         b->size = p.size;
      if (p.va_addr && !b->host)
         b->host = p.va_addr;
      wlog("spy: GPUOBJ_INFO id=%u gpu=0x%llx size=%llu va=0x%llx", p.id,
           (unsigned long long)p.gpuaddr, (unsigned long long)p.size,
           (unsigned long long)p.va_addr);
   } else if (nr == _IOC_NR(IOCTL_KGSL_GPUOBJ_FREE)) {
      struct kgsl_gpuobj_free p;
      if (vm_read(pid, arg, &p, sizeof(p)) == 0) {
         struct buf *b = buf_by_id(p.id);
         if (b)
            b->used = false;
      }
   } else if (nr == _IOC_NR(IOCTL_KGSL_GPUMEM_ALLOC_ID)) {
      struct kgsl_gpumem_alloc_id p;
      if (vm_read(pid, arg, &p, sizeof(p)))
         return;
      struct buf *b = buf_alloc();
      if (!b)
         return;
      b->id = p.id;
      b->gpuaddr = p.gpuaddr;
      b->size = p.size;
      wlog("spy: GPUMEM_ALLOC_ID id=%u gpu=0x%llx size=%llu", p.id,
           (unsigned long long)p.gpuaddr, (unsigned long long)p.size);
   } else if (nr == _IOC_NR(IOCTL_KGSL_GPUMEM_GET_INFO)) {
      struct kgsl_gpumem_get_info p;
      if (vm_read(pid, arg, &p, sizeof(p)))
         return;
      struct buf *b = buf_by_id(p.id);
      if (!b) {
         b = buf_alloc();
         if (b)
            b->id = p.id;
      }
      if (!b)
         return;
      if (p.gpuaddr)
         b->gpuaddr = p.gpuaddr;
      if (p.size)
         b->size = p.size;
      if (p.useraddr && !b->host)
         b->host = p.useraddr;
      wlog("spy: GPUMEM_GET_INFO id=%u gpu=0x%llx size=%llu va=0x%lx", p.id,
           (unsigned long long)p.gpuaddr, (unsigned long long)p.size,
           p.useraddr);
   } else if (nr == _IOC_NR(IOCTL_KGSL_GPU_COMMAND)) {
      on_gpu_command(pid, arg);
   } else if (nr == _IOC_NR(IOCTL_KGSL_SUBMIT_COMMANDS)) {
      struct kgsl_submit_commands p;
      if (vm_read(pid, arg, &p, sizeof(p)))
         return;
      wlog("spy: SUBMIT_COMMANDS ctx=%u ncmd=%u", p.context_id, p.numcmds);
      for (unsigned i = 0; i < p.numcmds && i < 64; i++) {
         struct kgsl_ibdesc ib;
         if (vm_read(pid, (uint64_t)(uintptr_t)(p.cmdlist + i), &ib, sizeof(ib)))
            continue;
         dump_cmd_ib(pid, ib.gpuaddr, (uint64_t)ib.sizedwords * 4, 0);
      }
   }
}

static void handle_enter(pid_t tid, struct tid_st *st, struct user_regs_struct *r)
{
   (void)tid;
#ifdef __aarch64__
   long nr = (long)r->regs[8];
   uint64_t a0 = r->regs[0], a1 = r->regs[1], a2 = r->regs[2];
   uint64_t a4 = r->regs[4], a5 = r->regs[5];
#else
   (void)tid;
   (void)st;
   (void)r;
   return;
#endif
   st->pending = 0;
   if (nr == __NR_ioctl) {
      st->pending = 1;
      st->fd = (int)a0;
      st->req = (unsigned long)(unsigned int)a1;
      st->arg = a2;
      ioctl_enter(root_pid, st->fd, st->req, st->arg);
   } else if (nr == __NR_mmap) {
      st->pending = 2;
      st->fd = (int)a4;
      st->mmap_off = a5;
      st->mmap_len = a1;
   } else if (nr == __NR_openat) {
      st->pending = 3;
      st->path_ptr = a1;
   }
#ifdef __NR_close
   else if (nr == __NR_close) {
      int fd = (int)a0;
      if (fd >= 0 && fd < MAX_FD)
         kgsl_fd[fd] = false;
   }
#endif
}

static void handle_leave(pid_t tid, struct tid_st *st, struct user_regs_struct *r)
{
   (void)tid;
#ifdef __aarch64__
   long ret = (long)r->regs[0];
#else
   (void)tid;
   (void)st;
   (void)r;
   return;
#endif
   if (st->pending == 1) {
      ioctl_leave(root_pid, st->fd, st->req, st->arg, ret);
   } else if (st->pending == 2 && ret > 0 && is_kgsl(st->fd)) {
      uint32_t id = (uint32_t)(st->mmap_off >> 12);
      struct buf *b = buf_by_id(id);
      if (!b) {
         b = buf_alloc();
         if (b)
            b->id = id;
      }
      if (b) {
         b->host = (uint64_t)ret;
         if (!b->size)
            b->size = st->mmap_len;
         wlog("spy: mmap fd=%d id=%u -> 0x%lx len=%llu", st->fd, id,
              (unsigned long)ret, (unsigned long long)st->mmap_len);
      }
   } else if (st->pending == 3 && ret >= 0 && st->path_ptr) {
      char path[256];
      memset(path, 0, sizeof(path));
      if (vm_read(root_pid, st->path_ptr, path, sizeof(path) - 1) == 0 &&
          (strstr(path, "kgsl-3d0") || strstr(path, "kgsl-3d"))) {
         mark_kgsl((int)ret);
         wlog("spy: kgsl fd=%ld path=%s", ret, path);
         rd_open_once();
         rd_gpu_id();
      }
   }
   st->pending = 0;
}

static void attach_opts(pid_t tid)
{
   ptrace(PTRACE_SETOPTIONS, tid, 0,
          (void *)(uintptr_t)(PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACECLONE |
                              PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK |
                              PTRACE_O_TRACEEXEC | PTRACE_O_EXITKILL));
}

int main(int argc, char **argv)
{
   int argi = 1;
   if (argi < argc && !strcmp(argv[argi], "--"))
      argi++;
   if (argi >= argc) {
      fprintf(stderr, "usage: kgsl_spy -- <command> [args...]\n");
      return 2;
   }

   const char *lp = getenv("WRAP_LOG");
   if (lp && lp[0])
      logf = fopen(lp, "w");
   else
      logf = fopen("/data/local/tmp/dagu-vulkan-truth/spy.log", "w");
   wlog("spy: starting %s", argv[argi]);

   pid_t child = fork();
   if (child < 0) {
      perror("fork");
      return 1;
   }
   if (child == 0) {
      if (ptrace(PTRACE_TRACEME, 0, 0, 0) < 0) {
         perror("PTRACE_TRACEME");
         _exit(127);
      }
      raise(SIGSTOP);
      execvp(argv[argi], &argv[argi]);
      perror("execvp");
      _exit(127);
   }
   root_pid = child;
   int status = 0;
   if (waitpid(child, &status, 0) < 0) {
      perror("waitpid");
      return 1;
   }
   attach_opts(child);
   tid_get(child, true);
   ptrace(PTRACE_SYSCALL, child, 0, 0);

   int exit_code = 0;
   while (1) {
      pid_t tid = waitpid(-1, &status, __WALL);
      if (tid < 0) {
         if (errno == EINTR)
            continue;
         break;
      }
      if (WIFEXITED(status) || WIFSIGNALED(status)) {
         tid_drop(tid);
         if (tid == child) {
            exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
            break;
         }
         continue;
      }
      if (!WIFSTOPPED(status))
         continue;

      int sig = WSTOPSIG(status);
      int ev = status >> 16;
      if (ev == PTRACE_EVENT_CLONE || ev == PTRACE_EVENT_FORK ||
          ev == PTRACE_EVENT_VFORK) {
         unsigned long newtid = 0;
         ptrace(PTRACE_GETEVENTMSG, tid, 0, &newtid);
         if (newtid) {
            tid_get((pid_t)newtid, true);
            attach_opts((pid_t)newtid);
         }
         ptrace(PTRACE_SYSCALL, tid, 0, 0);
         continue;
      }

      struct tid_st *st = tid_get(tid, true);
      if (!st) {
         ptrace(PTRACE_SYSCALL, tid, 0, 0);
         continue;
      }

      if (sig == (SIGTRAP | 0x80)) {
         struct user_regs_struct r;
         if (getregs(tid, &r) == 0) {
            if (!st->in_sys) {
               st->in_sys = true;
               handle_enter(tid, st, &r);
            } else {
               st->in_sys = false;
               handle_leave(tid, st, &r);
            }
         }
         ptrace(PTRACE_SYSCALL, tid, 0, 0);
         continue;
      }

      if (sig == SIGSTOP || sig == SIGTRAP) {
         ptrace(PTRACE_SYSCALL, tid, 0, 0);
         continue;
      }
      ptrace(PTRACE_SYSCALL, tid, 0, (void *)(uintptr_t)sig);
   }

   if (rd_fd >= 0)
      close(rd_fd);
   if (logf)
      fclose(logf);
   return exit_code;
}
