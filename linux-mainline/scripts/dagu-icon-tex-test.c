/* Offscreen: upload a 24x24 plus via glTexImage2D, draw 8x into
 * 256x256 LINEAR GBM, mmap and write /tmp/dagu-icon-tex.ppm
 *
 * aarch64-linux-gnu-gcc -O2 -o /tmp/dagu-icon-tex-test \
 *   linux-mainline/scripts/dagu-icon-tex-test.c -lgbm -lEGL -lGLESv2
 */
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#ifndef EGL_PLATFORM_GBM_KHR
#define EGL_PLATFORM_GBM_KHR 0x31D7
#endif
#include <fcntl.h>
#include <gbm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define W 256
#define H 256
#define TW 24
#define TH 24
#define SCALE 8

static const char *vs =
	"attribute vec2 a; attribute vec2 t; varying vec2 v;"
	"void main(){ v=t; gl_Position=vec4(a,0.0,1.0); }";
static const char *fs =
	"precision mediump float; varying vec2 v; uniform sampler2D s;"
	"void main(){ gl_FragColor=texture2D(s,v); }";

static GLuint compile(GLenum type, const char *src)
{
	GLuint sh = glCreateShader(type);
	glShaderSource(sh, 1, &src, NULL);
	glCompileShader(sh);
	return sh;
}

int main(void)
{
	int fd = open("/dev/dri/renderD128", O_RDWR);
	if (fd < 0) {
		perror("renderD128");
		return 2;
	}
	struct gbm_device *dev = gbm_create_device(fd);
	struct gbm_surface *surf = gbm_surface_create(
		dev, W, H, GBM_FORMAT_ARGB8888,
		GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
	if (!surf) {
		fprintf(stderr, "gbm_surface_create failed\n");
		return 2;
	}

	EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, dev, NULL);
	eglInitialize(dpy, NULL, NULL);
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint cfg_a[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
			   EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_NONE };
	EGLConfig cfg;
	EGLint n = 0;
	eglChooseConfig(dpy, cfg_a, &cfg, 1, &n);
	EGLint ctx_a[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_a);
	EGLSurface es = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)surf, NULL);
	if (es == EGL_NO_SURFACE) {
		fprintf(stderr, "eglCreateWindowSurface 0x%x\n", eglGetError());
		return 2;
	}
	eglMakeCurrent(dpy, es, es, ctx);

	unsigned char tex[TW * TH * 4];
	for (int y = 0; y < TH; y++) {
		for (int x = 0; x < TW; x++) {
			unsigned char *p = tex + (y * TW + x) * 4;
			int on = (x >= 10 && x <= 13) || (y >= 10 && y <= 13);
			p[0] = on ? 255 : 20;
			p[1] = on ? 255 : 20;
			p[2] = on ? 255 : 20;
			p[3] = 255;
		}
	}

	GLuint t = 0;
	glGenTextures(1, &t);
	glBindTexture(GL_TEXTURE_2D, t);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, TW, TH, 0, GL_RGBA,
		     GL_UNSIGNED_BYTE, tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

	GLuint prog = glCreateProgram();
	glAttachShader(prog, compile(GL_VERTEX_SHADER, vs));
	glAttachShader(prog, compile(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(prog, 0, "a");
	glBindAttribLocation(prog, 1, "t");
	glLinkProgram(prog);
	glUseProgram(prog);

	float x0 = -0.75f, y0 = -0.75f, x1 = 0.75f, y1 = 0.75f;
	float verts[] = { x0, y0, 0, 1, x1, y0, 1, 1, x0, y1, 0, 0,
			  x1, y1, 1, 0 };
	GLuint vbo = 0;
	glGenBuffers(1, &vbo);
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, 0, 16, (void *)0);
	glEnableVertexAttribArray(1);
	glVertexAttribPointer(1, 2, GL_FLOAT, 0, 16, (void *)8);

	glViewport(0, 0, W, H);
	glClearColor(0.1f, 0.2f, 0.6f, 1.f);
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	eglSwapBuffers(dpy, es);
	glFinish();

	struct gbm_bo *front = gbm_surface_lock_front_buffer(surf);
	uint32_t stride = gbm_bo_get_stride(front);
	void *map_data = NULL;
	void *map = gbm_bo_map(front, 0, 0, W, H, GBM_BO_TRANSFER_READ,
			       &stride, &map_data);
	if (!map) {
		fprintf(stderr, "gbm_bo_map failed\n");
		return 2;
	}

	FILE *ppm = fopen("/tmp/dagu-icon-tex.ppm", "w");
	fprintf(ppm, "P6\n%d %d\n255\n", W, H);
	unsigned white = 0, dark = 0, mid = 0;
	for (int y = 0; y < H; y++) {
		unsigned char *row = (unsigned char *)map + y * stride;
		for (int x = 0; x < W; x++) {
			unsigned char *p = row + x * 4;
			/* GBM is often BGRA */
			unsigned char r = p[2], g = p[1], b = p[0];
			if (ppm)
				fputc(r, ppm), fputc(g, ppm), fputc(b, ppm);
			unsigned s = r + g + b;
			if (s > 600)
				white++;
			else if (s < 120)
				dark++;
			else
				mid++;
		}
	}
	if (ppm)
		fclose(ppm);
	gbm_bo_unmap(front, map_data);
	printf("white=%u dark=%u mid=%u stride=%u\n", white, dark, mid, stride);
	/* A plus on blue: many mid (blue bg) + a band of white. Scattered
	 * destile looks like sparse white (white << expected ~ 24*8*6*2).
	 */
	printf("plus=%s\n", (white > 4000 && white < 30000) ? "likely" : "no");
	return 0;
}
