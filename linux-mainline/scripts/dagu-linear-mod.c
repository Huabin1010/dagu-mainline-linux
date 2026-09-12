#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/*
 * dagu GBM allocation contract. Never LD_PRELOAD into gnome-shell.
 *
 * Chromium Ozone always zwp_linux_buffer_params_v1.add(..., mod=0,0)
 * and still asks GBM for COMPRESSED. Mesa get_best_layout() then picks
 * UBWC/macrotile, so pixels disagree with the LINEAR tag.
 *
 * Force window-sized ARGB/XRGB GBM LINEAR so Ozone's LINEAR wayland tag
 * matches pixels. Skia/ANGLE glyph (R8) and UI atlases stay TILE/UBWC —
 * they never hit DPU scanout. Blind LINEAR on those BOs is the 1-bit
 * icon brick. a6xx GMEM store destiles LINEAR windows per tile in
 * dagu-mesa. Load via LD_LIBRARY_PATH, never into gnome-shell. Keep GPU
 * raster. Do NOT export EGL symbols (ANGLE).
 */


#define GBM_BO_USE_SCANOUT 1u
#define GBM_BO_USE_RENDERING 4u
#define GBM_BO_USE_LINEAR 16u
#define DRM_FORMAT_MOD_LINEAR 0ull
#define DRM_FORMAT_MOD_INVALID 0xffffffffffffffffull
#define GBM_FORMAT_R8 0x20203852u
#define GBM_FORMAT_ARGB8888 0x34325241u
#define GBM_FORMAT_XRGB8888 0x34325258u
#define GBM_FORMAT_ABGR8888 0x34324241u
#define GBM_FORMAT_XBGR8888 0x34324258u
#define DAGU_ATLAS_MAX 1024u

#define EGL_LINUX_DMA_BUF_EXT 0x3270
#define EGL_DMA_BUF_PLANE0_FD_EXT 0x3272
#define EGL_NONE 0x3038
#define ZWP_LINUX_BUFFER_PARAMS_V1_ADD 1u
#define EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT 0x3443
#define EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT 0x3444
#define EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT 0x3448
#define EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT 0x3449
#define EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT 0x344D
#define EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT 0x344E
#define EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT 0x3452
#define EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT 0x3453

typedef int EGLint;
typedef unsigned int EGLBoolean;
typedef void *EGLDisplay;

struct gbm_device;
struct gbm_bo;
struct gbm_surface;

static void *(*real_dlsym)(void *, const char *);
static int (*real_setenv)(const char *, const char *, int);
static int (*real_unsetenv)(const char *);
static int (*real_putenv)(char *);

static void *(*real_mesa_eglGetProcAddress)(const char *);
static EGLBoolean (*real_eglQueryDmaBufModifiersEXT)(EGLDisplay, EGLint, EGLint,
						     uint64_t *, EGLBoolean *,
						     EGLint *);
static void *(*real_eglCreateImageKHR)(EGLDisplay, void *, EGLint, void *,
				       const EGLint *);

struct fd_mod_ent {
	dev_t dev;
	ino_t ino;
	uint64_t mod;
};

static struct fd_mod_ent fd_mods[96];
static unsigned fd_mods_i;

__attribute__((constructor)) static void dagu_linear_init(void)
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
	if (real_dlsym) {
		real_setenv = real_dlsym(RTLD_NEXT, "setenv");
		real_unsetenv = real_dlsym(RTLD_NEXT, "unsetenv");
		real_putenv = real_dlsym(RTLD_NEXT, "putenv");
	}
}

static void *real_libc(const char *name)
{
	if (!real_dlsym)
		dagu_linear_init();
	return real_dlsym ? real_dlsym(RTLD_NEXT, name) : NULL;
}

char *getenv(const char *name)
{
	typedef char *(*fn_t)(const char *);
	static fn_t real;

	if (!real)
		real = real_libc("getenv");
	if (name && !strcmp(name, "FD_MESA_DEBUG")) {
		if (access("/tmp/dagu-pin-sysmem", F_OK) == 0)
			return "sysmem";
		if (real) {
			char *pin = real("DAGU_PIN_SYSMEM");

			if (pin && pin[0] == '1')
				return "sysmem";
		}
	}
	return real ? real(name) : NULL;
}

char *secure_getenv(const char *name)
{
	typedef char *(*fn_t)(const char *);
	static fn_t real;

	if (!real)
		real = real_libc("secure_getenv");
	if (real)
		return real(name);
	return getenv(name);
}

int setenv(const char *name, const char *value, int overwrite)
{
	if (!real_setenv)
		dagu_linear_init();
	return real_setenv ? real_setenv(name, value, overwrite) : -1;
}

int unsetenv(const char *name)
{
	if (!real_unsetenv)
		dagu_linear_init();
	return real_unsetenv ? real_unsetenv(name) : -1;
}

int putenv(char *string)
{
	if (!real_putenv)
		dagu_linear_init();
	return real_putenv ? real_putenv(string) : -1;
}

static void *real_gbm(const char *name)
{
	static void *libgbm;

	if (!real_dlsym)
		dagu_linear_init();
	if (!libgbm) {
		libgbm = dlopen("libgbm.so.1", RTLD_NOW | RTLD_NOLOAD);
		if (!libgbm)
			libgbm = dlopen("libgbm.so.1", RTLD_NOW);
	}
	return (real_dlsym && libgbm) ? real_dlsym(libgbm, name) : NULL;
}

static void dlog_mods(const char *tag, uint32_t w, uint32_t h,
		      const uint64_t *mods, unsigned count)
{
	FILE *log = fopen("/tmp/dagu-linear-mod.log", "a");
	unsigned i;

	if (!log)
		return;
	fprintf(log, "pid=%d %s %ux%u n=%u", (int)getpid(), tag, w, h, count);
	for (i = 0; i < count && i < 8; i++)
		fprintf(log, " 0x%llx", (unsigned long long)mods[i]);
	fprintf(log, "\n");
	fclose(log);
}

static void dlog(const char *fmt, uint32_t w, uint32_t h, unsigned in_n,
		 unsigned out_n, uint32_t flags)
{
	FILE *log = fopen("/tmp/dagu-linear-mod.log", "a");

	if (!log)
		return;
	fprintf(log, "pid=%d %ux%u flags=0x%x mods %u->%u %s\n", (int)getpid(),
		w, h, flags, in_n, out_n, fmt);
	fclose(log);
}

static void remember_mod_fd(int fd, uint64_t mod)
{
	struct stat st;
	unsigned i;

	if (fd < 0 || fstat(fd, &st) != 0)
		return;
	for (i = 0; i < 96; i++) {
		if (fd_mods[i].ino == st.st_ino && fd_mods[i].dev == st.st_dev) {
			fd_mods[i].mod = mod;
			return;
		}
	}
	i = fd_mods_i++ % 96;
	fd_mods[i].dev = st.st_dev;
	fd_mods[i].ino = st.st_ino;
	fd_mods[i].mod = mod;
}

static uint64_t lookup_mod_fd(int fd)
{
	struct stat st;
	unsigned i;

	if (fd < 0 || fstat(fd, &st) != 0)
		return DRM_FORMAT_MOD_INVALID;
	for (i = 0; i < 96; i++) {
		if (fd_mods[i].ino == st.st_ino && fd_mods[i].dev == st.st_dev &&
		    fd_mods[i].ino)
			return fd_mods[i].mod;
	}
	return DRM_FORMAT_MOD_INVALID;
}

struct bo_mod_ent {
	struct gbm_bo *bo;
	uint64_t mod;
};

static struct bo_mod_ent bo_mods[64];
static unsigned bo_mods_i;
static unsigned live_bos;
static unsigned created_bos;
static unsigned destroyed_bos;

static void remember_bo_mod(struct gbm_bo *bo, uint64_t mod)
{
	unsigned i;

	if (!bo)
		return;
	for (i = 0; i < 64; i++) {
		if (bo_mods[i].bo == bo) {
			bo_mods[i].mod = mod;
			return;
		}
	}
	i = bo_mods_i++ % 64;
	bo_mods[i].bo = bo;
	bo_mods[i].mod = mod;
}

static void forget_bo_mod(struct gbm_bo *bo)
{
	unsigned i;

	if (!bo)
		return;
	for (i = 0; i < 64; i++) {
		if (bo_mods[i].bo == bo) {
			bo_mods[i].bo = NULL;
			bo_mods[i].mod = DRM_FORMAT_MOD_INVALID;
			return;
		}
	}
}

static uint64_t lookup_bo_mod(struct gbm_bo *bo)
{
	unsigned i;

	if (!bo)
		return DRM_FORMAT_MOD_INVALID;
	for (i = 0; i < 64; i++) {
		if (bo_mods[i].bo == bo)
			return bo_mods[i].mod;
	}
	return DRM_FORMAT_MOD_INVALID;
}

static uint64_t real_bo_modifier(struct gbm_bo *bo)
{
	typedef uint64_t (*fn_t)(struct gbm_bo *);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_bo_get_modifier");
	return (real && bo) ? real(bo) : DRM_FORMAT_MOD_INVALID;
}

static int is_window_rgba(uint32_t format)
{
	return format == GBM_FORMAT_ARGB8888 || format == GBM_FORMAT_XRGB8888 ||
	       format == GBM_FORMAT_ABGR8888 || format == GBM_FORMAT_XBGR8888;
}

/*
 * Only the Wayland window (near-scanout AR24/XR24) is forced LINEAR.
 * R8 glyph atlases and UI icon atlases (<=1024²) stay TILE/UBWC.
 */
static int should_force_linear(uint32_t width, uint32_t height,
			       uint32_t format, uint32_t flags)
{
	(void)flags;
	if (format == GBM_FORMAT_R8)
		return 0;
	/* Atlas / icon FBO: both sides <=1024. A 1819x89 tab strip is
	 * exported to Wayland as LINEAR — must stay LINEAR pixels.
	 */
	if (width <= DAGU_ATLAS_MAX && height <= DAGU_ATLAS_MAX)
		return 0;
	if (!is_window_rgba(format))
		return 0;
	return 1;
}

static struct gbm_bo *note_created_bo(struct gbm_bo *bo, const char *tag,
				      uint32_t width, uint32_t height)
{
	uint64_t mod;

	if (!bo)
		return NULL;
	mod = real_bo_modifier(bo);
	remember_bo_mod(bo, mod);
	created_bos++;
	live_bos++;
	{
		FILE *log = fopen("/tmp/dagu-linear-mod.log", "a");

		if (log) {
			fprintf(log, "pid=%d %s %ux%u bo=%p mod=0x%llx live=%u created=%u destroyed=%u\n",
				(int)getpid(), tag, width, height, (void *)bo,
				(unsigned long long)mod, live_bos, created_bos,
				destroyed_bos);
			fclose(log);
		}
	}
	return bo;
}

static void rewrite_linux_dmabuf_add(int fd, uint32_t *hi, uint32_t *lo)
{
	uint64_t orig = ((uint64_t)*hi << 32) | *lo;
	uint64_t mod = lookup_mod_fd(fd);
	FILE *log = fopen("/tmp/dagu-linear-mod.log", "a");

	if (mod != DRM_FORMAT_MOD_INVALID) {
		*hi = (uint32_t)(mod >> 32);
		*lo = (uint32_t)mod;
	} else {
		mod = orig;
	}
	if (log) {
		fprintf(log, "pid=%d wayland add fd=%d orig=0x%llx -> 0x%llx\n",
			(int)getpid(), fd, (unsigned long long)orig,
			(unsigned long long)mod);
		fclose(log);
	}
}

static int path_is_bundled_angle(const char *path)
{
	if (!path)
		return 0;
	if (strstr(path, "/opt/Mineradio/"))
		return 1;
	if (strstr(path, "/opt/google/chrome/"))
		return 1;
	return 0;
}

static int path_is_mesa_egl(const char *path)
{
	if (!path || path_is_bundled_angle(path))
		return 0;
	if (strstr(path, "libEGL_mesa"))
		return 1;
	if (strstr(path, "libGLdispatch"))
		return 1;
	if (strstr(path, "libEGL.so"))
		return 1;
	if (strstr(path, "libgallium"))
		return 1;
	return 0;
}

static int object_is_mesa_egl(void *handle, void *sym)
{
	Dl_info info;
	struct link_map *map = NULL;

	if (sym && dladdr(sym, &info) && path_is_mesa_egl(info.dli_fname))
		return 1;
	if (handle && handle != RTLD_DEFAULT && handle != RTLD_NEXT &&
	    dlinfo(handle, RTLD_DI_LINKMAP, &map) == 0 && map)
		return path_is_mesa_egl(map->l_name);
	return 0;
}

static EGLBoolean dagu_eglQueryDmaBufModifiersEXT(EGLDisplay dpy, EGLint format,
					   EGLint max, uint64_t *modifiers,
					   EGLBoolean *external_only,
					   EGLint *count)
{
	EGLBoolean ok;
	EGLint n = 0;

	FILE *log = fopen("/tmp/dagu-linear-mod.log", "a");

	if (log) {
		fprintf(log, "pid=%d CALL eglQueryDmaBufModifiersEXT fmt=0x%x max=%d\n",
			(int)getpid(), format, max);
		fclose(log);
	}
	if (!real_eglQueryDmaBufModifiersEXT && real_mesa_eglGetProcAddress)
		real_eglQueryDmaBufModifiersEXT =
			real_mesa_eglGetProcAddress("eglQueryDmaBufModifiersEXT");
	if (!real_eglQueryDmaBufModifiersEXT)
		return 0;
	ok = real_eglQueryDmaBufModifiersEXT(dpy, format, max, modifiers,
					     external_only, &n);
	if (!ok)
		return ok;
	/* Do not collapse to LINEAR-only. That made ANGLE create every
	 * icon/atlas as LINEAR-only; a650 then destiled those 25x25
	 * BOs into 1-bit bricks. Window pixels stay LINEAR via GBM.
	 */
	if (count)
		*count = n;
	dlog("mesa eglQueryDmaBufModifiersEXT passthrough", (uint32_t)format,
	     (uint32_t)n, (unsigned)n, (unsigned)n, 0);
	return ok;
}

static void *dagu_mesa_eglCreateImageKHR(EGLDisplay dpy, void *ctx, EGLint target,
				  void *buffer, const EGLint *attrib_list)
{
	EGLint copy[96];
	int i, n = 0, changed = 0;

	FILE *log = fopen("/tmp/dagu-linear-mod.log", "a");

	if (log) {
		fprintf(log, "pid=%d CALL eglCreateImageKHR target=0x%x",
			(int)getpid(), target);
		if (attrib_list) {
			int a;

			for (a = 0; attrib_list[a] != EGL_NONE && a < 40; a += 2)
				fprintf(log, " %d=%d", attrib_list[a],
					attrib_list[a + 1]);
		}
		fprintf(log, "\n");
		fclose(log);
	}
	if (!real_eglCreateImageKHR && real_mesa_eglGetProcAddress)
		real_eglCreateImageKHR =
			real_mesa_eglGetProcAddress("eglCreateImageKHR");
	if (!real_eglCreateImageKHR)
		return NULL;
	if (target == (EGLint)EGL_LINUX_DMA_BUF_EXT && attrib_list) {
		int fd = -1;
		uint64_t mod, have_mod = 0;
		uint32_t hi, lo;
		int saw_lo = 0, saw_hi = 0;

		for (i = 0; attrib_list[i] != EGL_NONE && n + 2 < 93; i += 2) {
			EGLint key = attrib_list[i];
			EGLint val = attrib_list[i + 1];

			if (key == (EGLint)EGL_DMA_BUF_PLANE0_FD_EXT)
				fd = val;
			if (key == EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT)
				saw_lo = 1;
			if (key == EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT)
				saw_hi = 1;
			copy[n++] = key;
			copy[n++] = val;
		}
		mod = lookup_mod_fd(fd);
		if (mod == DRM_FORMAT_MOD_INVALID ||
		    mod == DRM_FORMAT_MOD_LINEAR) {
			/* Keep the caller's modifier. Forcing LINEAR here
			 * imported TILED3 glass as linear (right-side snow).
			 */
			return real_eglCreateImageKHR(dpy, ctx, target, buffer,
						      attrib_list);
		}
		have_mod = 1;
		hi = (uint32_t)(mod >> 32);
		lo = (uint32_t)mod;
		if (have_mod) {
			for (i = 0; i + 1 < n; i += 2) {
				if (copy[i] == EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT &&
				    copy[i + 1] != (EGLint)lo) {
					copy[i + 1] = (EGLint)lo;
					changed = 1;
				}
				if (copy[i] == EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT &&
				    copy[i + 1] != (EGLint)hi) {
					copy[i + 1] = (EGLint)hi;
					changed = 1;
				}
			}
			if (!saw_lo) {
				copy[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT;
				copy[n++] = (EGLint)lo;
				changed = 1;
			}
			if (!saw_hi) {
				copy[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT;
				copy[n++] = (EGLint)hi;
				changed = 1;
			}
		}
		copy[n++] = EGL_NONE;
		if (changed) {
			dlog("mesa eglCreateImageKHR modifier->real", lo, hi, 1,
			     1, 0);
			return real_eglCreateImageKHR(dpy, ctx, target, buffer,
						      copy);
		}
	}
	return real_eglCreateImageKHR(dpy, ctx, target, buffer, attrib_list);
}

static void *dagu_mesa_eglGetProcAddress(const char *name)
{
	if (name && !strncmp(name, "egl", 3)) {
		FILE *log = fopen("/tmp/dagu-linear-mod.log", "a");

		if (log) {
			fprintf(log, "pid=%d mesa eglGetProcAddress %s\n",
				(int)getpid(), name);
			fclose(log);
		}
	}
	if (name && !strcmp(name, "eglQueryDmaBufModifiersEXT"))
		return (void *)dagu_eglQueryDmaBufModifiersEXT;
	if (name && (!strcmp(name, "eglCreateImageKHR") ||
		     !strcmp(name, "eglCreateImage")))
		return (void *)dagu_mesa_eglCreateImageKHR;
	if (!real_mesa_eglGetProcAddress)
		return NULL;
	return real_mesa_eglGetProcAddress(name);
}

static void *maybe_wrap_mesa_egl(void *handle, const char *symbol, void *sym)
{
	if (!sym || !symbol)
		return sym;
	if (!object_is_mesa_egl(handle, sym))
		return sym;
	if (!strcmp(symbol, "eglGetProcAddress")) {
		if (!real_mesa_eglGetProcAddress)
			real_mesa_eglGetProcAddress = sym;
		return (void *)dagu_mesa_eglGetProcAddress;
	}
	if (!strcmp(symbol, "eglQueryDmaBufModifiersEXT")) {
		if (!real_eglQueryDmaBufModifiersEXT)
			real_eglQueryDmaBufModifiersEXT = sym;
		return (void *)dagu_eglQueryDmaBufModifiersEXT;
	}
	if (!strcmp(symbol, "eglCreateImageKHR") ||
	    !strcmp(symbol, "eglCreateImage")) {
		if (!real_eglCreateImageKHR)
			real_eglCreateImageKHR = sym;
		return (void *)dagu_mesa_eglCreateImageKHR;
	}
	return sym;
}

struct gbm_bo *gbm_bo_create(struct gbm_device *gbm, uint32_t width,
			     uint32_t height, uint32_t format, uint32_t flags)
{
	typedef struct gbm_bo *(*fn_t)(struct gbm_device *, uint32_t, uint32_t,
				       uint32_t, uint32_t);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_bo_create");
	if (!real)
		return NULL;
	if (should_force_linear(width, height, format, flags)) {
		dlog("gbm_bo_create LINEAR", width, height, 0, 0, flags);
		flags |= GBM_BO_USE_LINEAR;
		return note_created_bo(real(gbm, width, height, format, flags),
				       "gbm_bo_create LINEAR", width, height);
	}
	flags &= ~GBM_BO_USE_LINEAR;
	dlog("gbm_bo_create passthrough", width, height, 0, 0, flags);
	return note_created_bo(real(gbm, width, height, format, flags),
			       "gbm_bo_create passthrough", width, height);
}

struct gbm_surface *gbm_surface_create(struct gbm_device *gbm, uint32_t width,
				       uint32_t height, uint32_t format,
				       uint32_t flags)
{
	typedef struct gbm_surface *(*fn_t)(struct gbm_device *, uint32_t,
					    uint32_t, uint32_t, uint32_t);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_surface_create");
	if (!real)
		return NULL;
	dlog("gbm_surface_create", width, height, 0, 0, flags);
	flags |= GBM_BO_USE_LINEAR;
	return real(gbm, width, height, format, flags);
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

	if (!real)
		real = real_gbm("gbm_bo_create_with_modifiers");
	if (!real)
		return NULL;
	if (!should_force_linear(width, height, format, 0)) {
		dlog_mods("with_modifiers passthrough", width, height,
			  modifiers, count);
		return note_created_bo(real(gbm, width, height, format,
					    modifiers, count),
				       "with_modifiers passthrough", width,
				       height);
	}
	/* Window color: real LINEAR pixels. Ozone tags wayland LINEAR.
	 * TILED3 pixels + LINEAR sample is the full-card glass snow.
	 */
	dlog_mods("with_modifiers -> LINEAR", width, height, modifiers, count);
	return gbm_bo_create(gbm, width, height, format,
			     GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING |
				     GBM_BO_USE_LINEAR);
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

	if (!real)
		real = real_gbm("gbm_bo_create_with_modifiers2");
	if (!real)
		return gbm_bo_create_with_modifiers(gbm, width, height, format,
						    modifiers, count);
	if (!should_force_linear(width, height, format, flags)) {
		flags &= ~GBM_BO_USE_LINEAR;
		dlog_mods("with_modifiers2 passthrough", width, height,
			  modifiers, count);
		return note_created_bo(real(gbm, width, height, format,
					    modifiers, count, flags),
				       "with_modifiers2 passthrough", width,
				       height);
	}
	dlog_mods("with_modifiers2 -> LINEAR", width, height, modifiers, count);
	flags |= GBM_BO_USE_LINEAR;
	return gbm_bo_create(gbm, width, height, format, flags);
}

struct gbm_surface *
gbm_surface_create_with_modifiers(struct gbm_device *gbm, uint32_t width,
				  uint32_t height, uint32_t format,
				  const uint64_t *modifiers,
				  const unsigned int count)
{
	typedef struct gbm_surface *(*fn_t)(struct gbm_device *, uint32_t,
					    uint32_t, uint32_t, const uint64_t *,
					    unsigned int);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_surface_create_with_modifiers");
	if (!real)
		return NULL;
	return gbm_surface_create(gbm, width, height, format,
				  GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING |
					  GBM_BO_USE_LINEAR);
}

struct gbm_surface *
gbm_surface_create_with_modifiers2(struct gbm_device *gbm, uint32_t width,
				   uint32_t height, uint32_t format,
				   const uint64_t *modifiers,
				   const unsigned int count, uint32_t flags)
{
	typedef struct gbm_surface *(*fn_t)(struct gbm_device *, uint32_t,
					    uint32_t, uint32_t, const uint64_t *,
					    unsigned int, uint32_t);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_surface_create_with_modifiers2");
	if (!real)
		return gbm_surface_create_with_modifiers(gbm, width, height,
							 format, modifiers,
							 count);
	flags |= GBM_BO_USE_LINEAR;
	return gbm_surface_create(gbm, width, height, format, flags);
}

uint64_t gbm_bo_get_modifier(struct gbm_bo *bo)
{
	typedef uint64_t (*fn_t)(struct gbm_bo *);
	static fn_t real;
	uint64_t mod;

	if (!real)
		real = real_gbm("gbm_bo_get_modifier");
	if (!real)
		return DRM_FORMAT_MOD_INVALID;
	mod = real(bo);
	{
		uint64_t remembered = lookup_bo_mod(bo);

		if (remembered != DRM_FORMAT_MOD_INVALID)
			mod = remembered;
	}
	return mod;
}

int gbm_bo_get_fd(struct gbm_bo *bo)
{
	typedef int (*fn_t)(struct gbm_bo *);
	static fn_t real;
	typedef uint64_t (*mod_fn_t)(struct gbm_bo *);
	static mod_fn_t real_mod;
	int fd;

	if (!real)
		real = real_gbm("gbm_bo_get_fd");
	if (!real_mod)
		real_mod = real_gbm("gbm_bo_get_modifier");
	if (!real)
		return -1;
	fd = real(bo);
	if (fd >= 0) {
		uint64_t mod = lookup_bo_mod(bo);

		if (mod == DRM_FORMAT_MOD_INVALID && real_mod)
			mod = real_mod(bo);
		if (mod != DRM_FORMAT_MOD_INVALID)
			remember_mod_fd(fd, mod);
	}
	return fd;
}

int gbm_bo_get_fd_for_plane(struct gbm_bo *bo, int plane)
{
	typedef int (*fn_t)(struct gbm_bo *, int);
	static fn_t real;
	typedef uint64_t (*mod_fn_t)(struct gbm_bo *);
	static mod_fn_t real_mod;
	int fd;

	if (!real)
		real = real_gbm("gbm_bo_get_fd_for_plane");
	if (!real_mod)
		real_mod = real_gbm("gbm_bo_get_modifier");
	if (!real)
		return gbm_bo_get_fd(bo);
	fd = real(bo, plane);
	if (fd >= 0) {
		uint64_t mod = lookup_bo_mod(bo);

		if (mod == DRM_FORMAT_MOD_INVALID && real_mod)
			mod = real_mod(bo);
		if (mod != DRM_FORMAT_MOD_INVALID)
			remember_mod_fd(fd, mod);
	}
	return fd;
}

void gbm_bo_destroy(struct gbm_bo *bo)
{
	typedef void (*fn_t)(struct gbm_bo *);
	static fn_t real;

	if (!real)
		real = real_gbm("gbm_bo_destroy");
	forget_bo_mod(bo);
	if (bo) {
		if (live_bos)
			live_bos--;
		destroyed_bos++;
	}
	if (real)
		real(bo);
}

void *dlsym(void *handle, const char *symbol)
{
	void *sym;

	if (handle == RTLD_NEXT) {
		void *next;

		if (!real_dlsym)
			dagu_linear_init();
		next = real_dlsym ? real_dlsym(handle, symbol) : NULL;
		if (symbol && !strncmp(symbol, "egl", 3))
			return maybe_wrap_mesa_egl(handle, symbol, next);
		return next;
	}
	if (!strcmp(symbol, "gbm_bo_create"))
		return (void *)gbm_bo_create;
	if (!strcmp(symbol, "gbm_surface_create"))
		return (void *)gbm_surface_create;
	if (!strcmp(symbol, "gbm_bo_create_with_modifiers"))
		return (void *)gbm_bo_create_with_modifiers;
	if (!strcmp(symbol, "gbm_bo_create_with_modifiers2"))
		return (void *)gbm_bo_create_with_modifiers2;
	if (!strcmp(symbol, "gbm_surface_create_with_modifiers"))
		return (void *)gbm_surface_create_with_modifiers;
	if (!strcmp(symbol, "gbm_surface_create_with_modifiers2"))
		return (void *)gbm_surface_create_with_modifiers2;
	if (!strcmp(symbol, "gbm_bo_get_modifier"))
		return (void *)gbm_bo_get_modifier;
	if (!strcmp(symbol, "gbm_bo_get_fd"))
		return (void *)gbm_bo_get_fd;
	if (!strcmp(symbol, "gbm_bo_get_fd_for_plane"))
		return (void *)gbm_bo_get_fd_for_plane;
	if (!strcmp(symbol, "gbm_bo_destroy"))
		return (void *)gbm_bo_destroy;
	if (!strcmp(symbol, "getenv"))
		return (void *)getenv;
	if (!strcmp(symbol, "secure_getenv"))
		return (void *)secure_getenv;
	if (!strcmp(symbol, "setenv"))
		return (void *)setenv;
	if (!strcmp(symbol, "unsetenv"))
		return (void *)unsetenv;
	if (!strcmp(symbol, "putenv"))
		return (void *)putenv;
	if (!real_dlsym)
		dagu_linear_init();
	sym = real_dlsym ? real_dlsym(handle, symbol) : NULL;
	if (symbol && !strncmp(symbol, "egl", 3)) {
		FILE *log = fopen("/tmp/dagu-linear-mod.log", "a");
		Dl_info info;
		struct link_map *map = NULL;
		const char *hp = "?";
		const char *sp = "?";

		if (handle && handle != RTLD_DEFAULT && handle != RTLD_NEXT &&
		    dlinfo(handle, RTLD_DI_LINKMAP, &map) == 0 && map &&
		    map->l_name)
			hp = map->l_name;
		if (sym && dladdr(sym, &info) && info.dli_fname)
			sp = info.dli_fname;
		if (log) {
			fprintf(log,
				"pid=%d dlsym egl handle=%s sym=%s -> %s wrap=%d\n",
				(int)getpid(), hp, symbol, sp,
				object_is_mesa_egl(handle, sym));
			fclose(log);
		}
	}
	return maybe_wrap_mesa_egl(handle, symbol, sym);
}
