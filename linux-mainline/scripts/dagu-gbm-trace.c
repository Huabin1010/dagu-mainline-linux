#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/*
 * Client-only tracer. Never LD_PRELOAD into gnome-shell.
 * Logs GBM allocs and dumps dmabuf pixels after ANGLE has had time to draw.
 */

struct gbm_device;
struct gbm_bo;
struct gbm_surface;
struct wl_proxy;
struct wl_interface;
union wl_argument {
	int32_t i;
	uint32_t u;
	int32_t f;
	const char *s;
	struct wl_object *o;
	uint32_t n;
	struct wl_array *a;
	int32_t h;
};

static void *(*real_dlsym)(void *, const char *);
static FILE *logfp;

static void dlog(const char *fmt, ...)
{
	va_list ap;

	if (!logfp) {
		logfp = fopen("/tmp/dagu-gbm-trace.log", "a");
		if (logfp)
			setvbuf(logfp, NULL, _IOLBF, 0);
	}
	if (!logfp)
		return;
	fprintf(logfp, "[%d] ", (int)getpid());
	va_start(ap, fmt);
	vfprintf(logfp, fmt, ap);
	va_end(ap);
}

__attribute__((constructor)) static void dagu_trace_init(void)
{
	void *libc = dlopen("libc.so.6", RTLD_NOW | RTLD_NOLOAD);

	if (!libc)
		libc = dlopen("libc.so.6", RTLD_NOW);
	if (libc) {
		real_dlsym = dlvsym(libc, "dlsym", "GLIBC_2.34");
		if (!real_dlsym)
			real_dlsym = dlvsym(libc, "dlsym", "GLIBC_2.17");
		if (!real_dlsym)
			real_dlsym = dlvsym(libc, "dlsym", "GLIBC_2.2.5");
	}
	dlog("trace loaded\n");
}

static void *real_gbm(const char *name)
{
	static void *libgbm;

	if (!real_dlsym)
		dagu_trace_init();
	if (!libgbm) {
		libgbm = dlopen("libgbm.so.1", RTLD_NOW | RTLD_NOLOAD);
		if (!libgbm)
			libgbm = dlopen("libgbm.so.1", RTLD_NOW);
	}
	return (real_dlsym && libgbm) ? real_dlsym(libgbm, name) : NULL;
}

static void *real_wl(const char *name)
{
	static void *libwl;

	if (!real_dlsym)
		dagu_trace_init();
	if (!libwl) {
		libwl = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_NOLOAD);
		if (!libwl)
			libwl = dlopen("libwayland-client.so.0", RTLD_NOW);
	}
	return (real_dlsym && libwl) ? real_dlsym(libwl, name) : NULL;
}

static const char *wl_class(struct wl_proxy *proxy)
{
	typedef const char *(*fn_t)(struct wl_proxy *);
	static fn_t real;

	if (!real)
		real = real_wl("wl_proxy_get_class");
	return (real && proxy) ? real(proxy) : "?";
}

static uint64_t bo_mod(struct gbm_bo *bo)
{
	typedef uint64_t (*fn_t)(struct gbm_bo *);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_bo_get_modifier");
	return real ? real(bo) : 0xffffffffffffffffULL;
}

static uint32_t bo_stride(struct gbm_bo *bo)
{
	typedef uint32_t (*fn_t)(struct gbm_bo *);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_bo_get_stride");
	return real ? real(bo) : 0;
}

static int bo_fd(struct gbm_bo *bo)
{
	typedef int (*fn_t)(struct gbm_bo *);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_bo_get_fd");
	return real ? real(bo) : -1;
}

struct dump_job {
	int fd;
	uint32_t width;
	uint32_t height;
	uint32_t stride;
	uint32_t format;
};

static void *dump_thread(void *arg)
{
	struct dump_job *job = arg;
	struct dma_buf_sync sync;
	size_t len;
	void *map;
	char path[128];
	FILE *ppm;
	uint32_t y, x;
	static int n;

	sleep(3);
	len = (size_t)job->stride * job->height;
	sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
	ioctl(job->fd, DMA_BUF_IOCTL_SYNC, &sync);
	map = mmap(NULL, len, PROT_READ, MAP_SHARED, job->fd, 0);
	if (map == MAP_FAILED) {
		dlog("dump mmap fail fd=%d errno=%d %ux%u\n", job->fd, errno,
		     job->width, job->height);
		close(job->fd);
		free(job);
		return NULL;
	}
	snprintf(path, sizeof(path), "/tmp/dagu-bo-%u-%ux%u-%d.ppm",
		 job->format, job->width, job->height, n++);
	ppm = fopen(path, "w");
	if (ppm) {
		fprintf(ppm, "P6\n%u %u\n255\n", job->width, job->height);
		for (y = 0; y < job->height; y++) {
			unsigned char *row = (unsigned char *)map + (size_t)y * job->stride;

			for (x = 0; x < job->width; x++) {
				unsigned char b = row[x * 4 + 0];
				unsigned char g = row[x * 4 + 1];
				unsigned char r = row[x * 4 + 2];

				fputc(r, ppm);
				fputc(g, ppm);
				fputc(b, ppm);
			}
		}
		fclose(ppm);
		dlog("dumped %s\n", path);
	}
	sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
	ioctl(job->fd, DMA_BUF_IOCTL_SYNC, &sync);
	munmap(map, len);
	close(job->fd);
	free(job);
	return NULL;
}

static void schedule_dump(struct gbm_bo *bo, uint32_t width, uint32_t height,
			  uint32_t format)
{
	struct dump_job *job;
	pthread_t th;
	int fd;
	static int queued;

	if (queued >= 4 || !bo)
		return;
	fd = bo_fd(bo);
	if (fd < 0)
		return;
	job = calloc(1, sizeof(*job));
	if (!job) {
		close(fd);
		return;
	}
	job->fd = fd;
	job->width = width;
	job->height = height;
	job->stride = bo_stride(bo);
	job->format = format;
	queued++;
	if (pthread_create(&th, NULL, dump_thread, job) == 0)
		pthread_detach(th);
	else {
		close(fd);
		free(job);
		queued--;
	}
}

static void dump_mods(const char *tag, const uint64_t *mods, unsigned count)
{
	unsigned i;

	dlog("%s count=%u", tag, count);
	for (i = 0; i < count && i < 8; i++)
		dlog(" [%u]=0x%llx", i, (unsigned long long)mods[i]);
	dlog("\n");
}

struct gbm_bo *gbm_bo_create(struct gbm_device *gbm, uint32_t width,
			     uint32_t height, uint32_t format, uint32_t flags)
{
	typedef struct gbm_bo *(*fn_t)(struct gbm_device *, uint32_t, uint32_t,
				       uint32_t, uint32_t);
	static fn_t real;
	struct gbm_bo *bo;

	if (!real)
		real = real_gbm("gbm_bo_create");
	if (!real)
		return NULL;
	bo = real(gbm, width, height, format, flags);
	dlog("gbm_bo_create %ux%u fmt=0x%x flags=0x%x -> bo=%p mod=0x%llx stride=%u\n",
	     width, height, format, flags, bo,
	     (unsigned long long)(bo ? bo_mod(bo) : 0),
	     bo ? bo_stride(bo) : 0);
	if (bo && width >= 256 && height >= 256)
		schedule_dump(bo, width, height, format);
	return bo;
}

struct gbm_bo *gbm_bo_create_with_modifiers(struct gbm_device *gbm,
					    uint32_t width, uint32_t height,
					    uint32_t format,
					    const uint64_t *modifiers,
					    const unsigned int count)
{
	typedef struct gbm_bo *(*fn_t)(struct gbm_device *, uint32_t, uint32_t,
				       uint32_t, const uint64_t *, unsigned int);
	static fn_t real;
	struct gbm_bo *bo;

	if (!real)
		real = real_gbm("gbm_bo_create_with_modifiers");
	if (!real)
		return NULL;
	dump_mods("gbm_bo_create_with_modifiers in", modifiers, count);
	bo = real(gbm, width, height, format, modifiers, count);
	dlog("gbm_bo_create_with_modifiers %ux%u fmt=0x%x -> bo=%p mod=0x%llx stride=%u\n",
	     width, height, format, bo,
	     (unsigned long long)(bo ? bo_mod(bo) : 0),
	     bo ? bo_stride(bo) : 0);
	return bo;
}

struct gbm_bo *gbm_bo_create_with_modifiers2(struct gbm_device *gbm,
					     uint32_t width, uint32_t height,
					     uint32_t format,
					     const uint64_t *modifiers,
					     const unsigned int count,
					     uint32_t flags)
{
	typedef struct gbm_bo *(*fn_t)(struct gbm_device *, uint32_t, uint32_t,
				       uint32_t, const uint64_t *, unsigned int,
				       uint32_t);
	static fn_t real;
	struct gbm_bo *bo;

	if (!real)
		real = real_gbm("gbm_bo_create_with_modifiers2");
	if (!real)
		return NULL;
	dump_mods("gbm_bo_create_with_modifiers2 in", modifiers, count);
	bo = real(gbm, width, height, format, modifiers, count, flags);
	dlog("gbm_bo_create_with_modifiers2 %ux%u fmt=0x%x flags=0x%x -> bo=%p mod=0x%llx stride=%u\n",
	     width, height, format, flags, bo,
	     (unsigned long long)(bo ? bo_mod(bo) : 0),
	     bo ? bo_stride(bo) : 0);
	return bo;
}

uint64_t gbm_bo_get_modifier(struct gbm_bo *bo)
{
	uint64_t m = bo_mod(bo);

	dlog("gbm_bo_get_modifier bo=%p -> 0x%llx\n", bo, (unsigned long long)m);
	return m;
}

static void log_params_add(struct wl_proxy *proxy, uint32_t opcode,
			   union wl_argument *args)
{
	const char *cls = wl_class(proxy);

	if (!cls || strcmp(cls, "zwp_linux_buffer_params_v1"))
		return;
	if (opcode != 1 || !args)
		return;
	dlog("wl params.add fd=%d plane=%u off=%u stride=%u mod=0x%x%08x class=%s\n",
	     args[0].h, args[1].u, args[2].u, args[3].u, args[4].u, args[5].u,
	     cls);
}

struct wl_proxy *wl_proxy_marshal_array_flags(struct wl_proxy *proxy,
					      uint32_t opcode,
					      const struct wl_interface *iface,
					      uint32_t version, uint32_t flags,
					      union wl_argument *args)
{
	typedef struct wl_proxy *(*fn_t)(struct wl_proxy *, uint32_t,
					 const struct wl_interface *, uint32_t,
					 uint32_t, union wl_argument *);
	static fn_t real;

	if (!real)
		real = real_wl("wl_proxy_marshal_array_flags");
	log_params_add(proxy, opcode, args);
	if (!real)
		return NULL;
	return real(proxy, opcode, iface, version, flags, args);
}

void *dlsym(void *handle, const char *symbol)
{
	if (handle == RTLD_NEXT) {
		if (!real_dlsym)
			dagu_trace_init();
		return real_dlsym ? real_dlsym(handle, symbol) : NULL;
	}
	if (!strcmp(symbol, "gbm_bo_create"))
		return (void *)gbm_bo_create;
	if (!strcmp(symbol, "gbm_bo_create_with_modifiers"))
		return (void *)gbm_bo_create_with_modifiers;
	if (!strcmp(symbol, "gbm_bo_create_with_modifiers2"))
		return (void *)gbm_bo_create_with_modifiers2;
	if (!strcmp(symbol, "gbm_bo_get_modifier"))
		return (void *)gbm_bo_get_modifier;
	if (!strcmp(symbol, "wl_proxy_marshal_array_flags"))
		return (void *)wl_proxy_marshal_array_flags;
	if (!real_dlsym)
		dagu_trace_init();
	return real_dlsym ? real_dlsym(handle, symbol) : NULL;
}
