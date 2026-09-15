/* Offscreen LINEAR GMEM store scorer for a650 destile.
 * Build on tablet: cc -O2 -o /tmp/dagu-linear-destile-test \
 *   dagu-linear-destile-test.c -lgbm -lEGL -lGLESv2
 * Expect a 256x256 GBM LINEAR RGBA checker. Compare mmap vs CPU.
 */
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <gbm.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define W 256
#define H 256
#define CELL 32

static void checker(unsigned char *p, int x, int y)
{
	int on = ((x / CELL) ^ (y / CELL)) & 1;
	p[0] = on ? 0x20 : 0xe0;
	p[1] = on ? 0xc0 : 0x20;
	p[2] = on ? 0x20 : 0x20;
	p[3] = 0xff;
}

int main(void)
{
	int fd = open("/dev/dri/renderD128", O_RDWR);
	if (fd < 0) {
		perror("renderD128");
		return 2;
	}
	struct gbm_device *dev = gbm_create_device(fd);
	struct gbm_bo *bo = gbm_bo_create(dev, W, H, GBM_FORMAT_ARGB8888,
					  GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
	if (!bo) {
		fprintf(stderr, "gbm_bo_create LINEAR failed\n");
		return 2;
	}

	EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, dev, NULL);
	eglInitialize(dpy, NULL, NULL);
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint cfg_a[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
			  EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_NONE};
	EGLConfig cfg;
	EGLint n = 0;
	eglChooseConfig(dpy, cfg_a, &cfg, 1, &n);
	EGLint ctx_a[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_a);

	PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC get_ncb = NULL;
	(void)get_ncb;
	/* Render via gbm surface so Mesa owns the LINEAR color. */
	struct gbm_surface *surf = gbm_surface_create(
		dev, W, H, GBM_FORMAT_ARGB8888,
		GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
	EGLSurface es = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)surf, NULL);
	if (es == EGL_NO_SURFACE) {
		fprintf(stderr, "eglCreateWindowSurface failed 0x%x\n", eglGetError());
		return 2;
	}
	eglMakeCurrent(dpy, es, es, ctx);

	glViewport(0, 0, W, H);
	glClearColor(0.1f, 0.1f, 0.1f, 1.f);
	glClear(GL_COLOR_BUFFER_BIT);
	/* Fullscreen checker via scissored clears — no depth. */
	for (int y = 0; y < H; y += CELL) {
		for (int x = 0; x < W; x += CELL) {
			int on = ((x / CELL) ^ (y / CELL)) & 1;
			glEnable(GL_SCISSOR_TEST);
			glScissor(x, y, CELL, CELL);
			if (on)
				glClearColor(0.125f, 0.75f, 0.125f, 1.f);
			else
				glClearColor(0.875f, 0.125f, 0.125f, 1.f);
			glClear(GL_COLOR_BUFFER_BIT);
		}
	}
	glDisable(GL_SCISSOR_TEST);
	eglSwapBuffers(dpy, es);
	glFinish();

	struct gbm_bo *front = gbm_surface_lock_front_buffer(surf);
	uint32_t stride = gbm_bo_get_stride(front);
	void *map_data = NULL;
	void *map = gbm_bo_map(front, 0, 0, W, H, GBM_BO_TRANSFER_READ, &stride, &map_data);
	if (!map) {
		fprintf(stderr, "gbm_bo_map failed\n");
		return 2;
	}

	unsigned match = 0, n = 0, uniq = 0;
	unsigned char seen[256];
	memset(seen, 0, sizeof(seen));
	unsigned char expect[4];
	for (int y = 0; y < H; y += 2) {
		unsigned char *row = (unsigned char *)map + y * stride;
		for (int x = 0; x < W; x += 2) {
			checker(expect, x, H - 1 - y); /* GL origin is bottom-left */
			unsigned char *p = row + x * 4;
			/* GBM ARGB / BGRA: compare channels loosely */
			int exp_sum = expect[0] + expect[1] + expect[2];
			int got_sum = p[0] + p[1] + p[2];
			int dark = got_sum < 80;
			int on = ((x / CELL) ^ ((H - 1 - y) / CELL)) & 1;
			/* expected on=green-ish, off=red-ish */
			int ok = on ? (p[1] > p[0] && p[1] > p[2]) : (p[2] > p[1] || p[0] > p[1]);
			/* also accept swapped BGRA vs RGBA */
			if (!ok)
				ok = on ? (p[1] > 140) : (p[0] > 140 || p[2] > 140);
			if (ok)
				match++;
			n++;
			seen[p[0] >> 4]++;
			(void)exp_sum;
			(void)dark;
		}
	}
	for (int i = 0; i < 256; i++)
		if (seen[i])
			uniq++;
	gbm_bo_unmap(front, map_data);
	double frac = n ? (double)match / n : 0;
	printf("samples=%u match=%.4f uniq4=%u destile=%s\n", n, frac, uniq,
	       getenv("DAGU_LINEAR_DESTILE") ? "on" : "off");
	printf("pass=%s\n", frac >= 0.95 ? "True" : "False");
	return frac >= 0.95 ? 0 : 1;
}
