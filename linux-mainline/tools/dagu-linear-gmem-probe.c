/*
 * dagu-linear-gmem-probe — 9.4.2 gate.
 *
 * Import a GBM LINEAR 1024x1024 RGBA8 as an FBO, force GMEM
 * (FD_MESA_DEBUG=gmem), draw coord-colored triangles, then mmap the
 * BO. glReadPixels is not used: Mesa can destile on that copy.
 *
 *   DAGU_LINEAR_SYSMEM=0 DAGU_LINEAR_DESTILE=0 FD_MESA_DEBUG=gmem \
 *   LD_LIBRARY_PATH=/usr/local/lib/dagu-mesa ./dagu-linear-gmem-probe
 */
#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <fcntl.h>
#include <gbm.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#ifndef W
#define W 1024
#endif
#ifndef H
#define H 1024
#endif
#ifndef DRAWS
#define DRAWS 128
#endif

static void die(const char *m)
{
   fprintf(stderr, "FAIL: %s\n", m);
   exit(2);
}

static const char *vs_src =
   "attribute vec2 a;\n"
   "void main(){ gl_Position = vec4(a, 0.0, 1.0); }\n";

static const char *fs_src =
   "precision highp float;\n"
   "void main(){\n"
   "  float x = floor(gl_FragCoord.x);\n"
   "  float y = floor(gl_FragCoord.y);\n"
   "  gl_FragColor = vec4(mod(x,256.0)/255.0, mod(y,256.0)/255.0,\n"
   "                      mod(x+y,256.0)/255.0, 1.0);\n"
   "}\n";

static const char *fs_fetch_src =
   "#extension GL_EXT_shader_framebuffer_fetch : require\n"
   "precision highp float;\n"
   "void main(){\n"
   "  vec4 prev = gl_LastFragData[0];\n"
   "  gl_FragColor = vec4(prev.r, prev.g, 1.0 - prev.b, 1.0);\n"
   "}\n";

static GLuint compile(GLenum type, const char *src)
{
   GLuint s = glCreateShader(type);
   glShaderSource(s, 1, &src, NULL);
   glCompileShader(s);
   GLint ok = 0;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[512];
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      fprintf(stderr, "shader: %s\n", log);
      die("compile");
   }
   return s;
}

static void analyze(const uint8_t *px, uint32_t pitch, FILE *rep)
{
   uint64_t ok = 0, bad = 0, n = 0;
   uint32_t fx = 0, fy = 0;
   const uint8_t *p00 = px;
   const uint8_t *p256 = px + 256 * 4;
   fprintf(rep, "raw(0,0)=%02x %02x %02x %02x raw(256,0)=%02x %02x %02x %02x\n",
           p00[0], p00[1], p00[2], p00[3], p256[0], p256[1], p256[2], p256[3]);
   printf("raw(0,0)=%02x %02x %02x %02x raw(256,0)=%02x %02x %02x %02x\n",
          p00[0], p00[1], p00[2], p00[3], p256[0], p256[1], p256[2], p256[3]);
   for (uint32_t y = 0; y < H; y += 4) {
      for (uint32_t x = 0; x < W; x += 4) {
         const uint8_t *p = px + (size_t)y * pitch + (size_t)x * 4;
         uint8_t er = (uint8_t)(x & 255u);
         uint8_t eg = (uint8_t)(y & 255u);
         uint8_t eb = (uint8_t)((x + y) & 255u);
         n++;
         if (p[0] == er && p[1] == eg && p[2] == eb)
            ok++;
         else {
            if (!bad) {
               fx = x;
               fy = y;
            }
            bad++;
         }
      }
   }
   const char *verdict = (bad == 0) ? "TRUE_LINEAR" : "MACROTILE_OR_GARBLED";
   fprintf(rep, "checked=%" PRIu64 " ok=%" PRIu64 " bad=%" PRIu64
                " match=%.4f first_bad=%u,%u verdict=%s\n",
           n, ok, bad, n ? (double)ok / (double)n : 0.0, fx, fy, verdict);
   printf("PIXEL mmap checked=%" PRIu64 " ok=%" PRIu64 " bad=%" PRIu64
          " match=%.4f first_bad=%u,%u verdict=%s\n",
          n, ok, bad, n ? (double)ok / (double)n : 0.0, fx, fy, verdict);
}

int main(void)
{
   printf("env DAGU_LINEAR_SYSMEM=%s DAGU_LINEAR_DESTILE=%s FD_MESA_DEBUG=%s\n",
          getenv("DAGU_LINEAR_SYSMEM") ? getenv("DAGU_LINEAR_SYSMEM") : "",
          getenv("DAGU_LINEAR_DESTILE") ? getenv("DAGU_LINEAR_DESTILE") : "",
          getenv("FD_MESA_DEBUG") ? getenv("FD_MESA_DEBUG") : "");

   const char *nodes[] = { "/dev/dri/renderD128", "/dev/dri/card0", NULL };
   int drm_fd = -1;
   for (int i = 0; nodes[i]; i++) {
      drm_fd = open(nodes[i], O_RDWR | O_CLOEXEC);
      if (drm_fd >= 0) {
         printf("drm %s\n", nodes[i]);
         break;
      }
   }
   if (drm_fd < 0)
      die("open drm");

   struct gbm_device *gbm = gbm_create_device(drm_fd);
   if (!gbm)
      die("gbm_create_device");

   uint32_t flags = GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR;
   struct gbm_bo *bo = gbm_bo_create(gbm, W, H, GBM_FORMAT_ABGR8888, flags);
   if (!bo)
      die("gbm_bo_create LINEAR");
   uint32_t stride = gbm_bo_get_stride(bo);
   uint64_t mod = gbm_bo_get_modifier(bo);
   printf("bo stride=%u modifier=0x%llx handle=%u\n", stride,
          (unsigned long long)mod, gbm_bo_get_handle(bo).u32);
   if (mod != 0)
      fprintf(stderr, "WARN: modifier is not LINEAR 0\n");

   EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
   if (dpy == EGL_NO_DISPLAY)
      dpy = eglGetDisplay((EGLNativeDisplayType)gbm);
   if (dpy == EGL_NO_DISPLAY)
      die("eglGetDisplay");
   if (!eglInitialize(dpy, NULL, NULL))
      die("eglInitialize");
   eglBindAPI(EGL_OPENGL_ES_API);
   const EGLint cfg_attr[] = {
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
      EGL_SURFACE_TYPE, 0,
      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
      EGL_NONE
   };
   EGLConfig cfg;
   EGLint ncfg = 0;
   if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &ncfg) || !ncfg)
      die("eglChooseConfig");
   const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
   if (ctx == EGL_NO_CONTEXT)
      die("eglCreateContext");
   if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
      die("eglMakeCurrent surfaceless");

   PFNEGLCREATEIMAGEKHRPROC create_image =
      (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
   PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target_tex =
      (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress(
         "glEGLImageTargetTexture2DOES");
   if (!create_image || !target_tex)
      die("EGL image procs");

   int bo_fd = gbm_bo_get_fd(bo);
   if (bo_fd < 0)
      die("gbm_bo_get_fd");
   EGLint img_attr[] = {
      EGL_WIDTH, W,
      EGL_HEIGHT, H,
      EGL_LINUX_DRM_FOURCC_EXT, (EGLint)GBM_FORMAT_ABGR8888,
      EGL_DMA_BUF_PLANE0_FD_EXT, bo_fd,
      EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
      EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)stride,
      EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, (EGLint)(mod & 0xffffffffu),
      EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, (EGLint)(mod >> 32),
      EGL_NONE
   };
   EGLImageKHR img =
      create_image(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, img_attr);
   if (img == EGL_NO_IMAGE_KHR)
      die("eglCreateImageKHR");

   GLuint tex = 0, fbo = 0;
   glGenTextures(1, &tex);
   glBindTexture(GL_TEXTURE_2D, tex);
   target_tex(GL_TEXTURE_2D, img);
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                          tex, 0);
   if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
      die("FBO incomplete");

   GLuint vs = compile(GL_VERTEX_SHADER, vs_src);
   GLuint fs = compile(GL_FRAGMENT_SHADER, fs_src);
   GLuint prog = glCreateProgram();
   glAttachShader(prog, vs);
   glAttachShader(prog, fs);
   glBindAttribLocation(prog, 0, "a");
   glLinkProgram(prog);
   GLint lok = 0;
   glGetProgramiv(prog, GL_LINK_STATUS, &lok);
   if (!lok)
      die("link");
   glUseProgram(prog);
   static const float verts[] = { -1, -1, 3, -1, -1, 3 };
   glViewport(0, 0, W, H);
   glDisable(GL_DEPTH_TEST);
   glDisable(GL_BLEND);
   glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, verts);
   glEnableVertexAttribArray(0);
   glClearColor(0, 0, 0, 1);
   glClear(GL_COLOR_BUFFER_BIT);
   for (int i = 0; i < DRAWS; i++)
      glDrawArrays(GL_TRIANGLES, 0, 3);
   glFinish();
   printf("draws=%d glerr=0x%x renderer=%s\n", DRAWS, glGetError(),
          (const char *)glGetString(GL_RENDERER));

   FILE *rep = fopen("/tmp/dagu-linear-gmem-probe.report.txt", "w");
   if (!rep)
      die("report");
   fprintf(rep, "w=%u h=%u draws=%u bo_stride=%u modifier=0x%llx\n",
           W, H, DRAWS, stride, (unsigned long long)mod);
   fprintf(rep, "renderer=%s\n", (const char *)glGetString(GL_RENDERER));

   uint32_t map_stride = 0;
   void *map_data = NULL;
   void *map = gbm_bo_map(bo, 0, 0, W, H, GBM_BO_TRANSFER_READ, &map_stride,
                          &map_data);
   if (!map)
      die("gbm_bo_map");
   printf("PASS1 store map stride=%u\n", map_stride);
   fprintf(rep, "PASS1 store map_stride=%u\n", map_stride);
   analyze(map, map_stride, rep);
   gbm_bo_unmap(bo, map_data);

   /* Second batch: no clear, 8x8 scissor draw. Color must RESTORE
    * from sysmem (Branch A). Uncovered pixels stay the PASS1 pattern
    * only if BLIT_EVENT_LOAD of TILE6_LINEAR is right.
    */
   glEnable(GL_SCISSOR_TEST);
   glScissor(0, 0, 8, 8);
   glDrawArrays(GL_TRIANGLES, 0, 3);
   glDisable(GL_SCISSOR_TEST);
   glFinish();
   printf("PASS2 restore+8x8 draw glerr=0x%x\n", glGetError());
   map = gbm_bo_map(bo, 0, 0, W, H, GBM_BO_TRANSFER_READ, &map_stride,
                    &map_data);
   if (!map) {
      map_stride = stride;
      map = mmap(NULL, (size_t)stride * H, PROT_READ, MAP_SHARED, bo_fd, 0);
      if (map == MAP_FAILED)
         die("mmap restore");
      fprintf(rep, "PASS2 restore mmap_fd stride=%u\n", map_stride);
      analyze(map, map_stride, rep);
      munmap(map, (size_t)stride * H);
   } else {
      fprintf(rep, "PASS2 restore map_stride=%u\n", map_stride);
      analyze(map, map_stride, rep);
      gbm_bo_unmap(bo, map_data);
   }

   /* PASS3: same-batch paint + EXT_shader_framebuffer_fetch (Branch B). */
   const char *exts = (const char *)glGetString(GL_EXTENSIONS);
   int have_fetch = exts && strstr(exts, "GL_EXT_shader_framebuffer_fetch");
   fprintf(rep, "fb_fetch_ext=%d\n", have_fetch);
   printf("fb_fetch_ext=%d\n", have_fetch);
   if (have_fetch) {
      GLuint fsf = compile(GL_FRAGMENT_SHADER, fs_fetch_src);
      GLuint prog_f = glCreateProgram();
      glAttachShader(prog_f, vs);
      glAttachShader(prog_f, fsf);
      glBindAttribLocation(prog_f, 0, "a");
      glLinkProgram(prog_f);
      GLint lokf = 0;
      glGetProgramiv(prog_f, GL_LINK_STATUS, &lokf);
      if (!lokf)
         die("link fetch");
      glUseProgram(prog);
      glClear(GL_COLOR_BUFFER_BIT);
      for (int i = 0; i < DRAWS; i++)
         glDrawArrays(GL_TRIANGLES, 0, 3);
      glUseProgram(prog_f);
      glDrawArrays(GL_TRIANGLES, 0, 3);
      glFinish();
      printf("PASS3 same-batch fetch glerr=0x%x\n", glGetError());
      map = gbm_bo_map(bo, 0, 0, W, H, GBM_BO_TRANSFER_READ, &map_stride,
                       &map_data);
      int used_mmap = 0;
      if (!map) {
         map_stride = stride;
         map = mmap(NULL, (size_t)stride * H, PROT_READ, MAP_SHARED, bo_fd, 0);
         if (map == MAP_FAILED)
            die("mmap fetch");
         used_mmap = 1;
      }
      uint64_t ok = 0, bad = 0, n = 0;
      uint32_t fx = 0, fy = 0;
      const uint8_t *px = (const uint8_t *)map;
      {
         const uint8_t *a = px;
         const uint8_t *b = px + 4 * 4;
         const uint8_t *c = px + 256 * 4;
         const uint8_t *d = px + (size_t)4 * map_stride;
         printf("PASS3 raw(0,0)=%02x %02x %02x %02x (4,0)=%02x %02x %02x %02x "
                "(256,0)=%02x %02x %02x %02x (0,4)=%02x %02x %02x %02x\n",
                a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3],
                c[0], c[1], c[2], c[3], d[0], d[1], d[2], d[3]);
         fprintf(rep,
                 "PASS3 raw(0,0)=%02x %02x %02x %02x (4,0)=%02x %02x %02x %02x "
                 "(256,0)=%02x %02x %02x %02x (0,4)=%02x %02x %02x %02x\n",
                 a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3],
                 c[0], c[1], c[2], c[3], d[0], d[1], d[2], d[3]);
      }
      for (uint32_t y = 0; y < H; y += 4) {
         for (uint32_t x = 0; x < W; x += 4) {
            const uint8_t *p = px + (size_t)y * map_stride + (size_t)x * 4;
            uint8_t er = (uint8_t)(x & 255u);
            uint8_t eg = (uint8_t)(y & 255u);
            uint8_t eb = (uint8_t)(255u - ((x + y) & 255u));
            n++;
            if (p[0] == er && p[1] == eg && p[2] == eb)
               ok++;
            else if (!bad) {
               fx = x;
               fy = y;
               bad++;
            } else
               bad++;
         }
      }
      const char *v = bad ? "FETCH_BAD" : "FETCH_OK";
      printf("PASS3 fetch checked=%" PRIu64 " ok=%" PRIu64 " bad=%" PRIu64
             " match=%.4f first_bad=%u,%u verdict=%s\n",
             n, ok, bad, n ? (double)ok / (double)n : 0.0, fx, fy, v);
      fprintf(rep,
              "PASS3 fetch checked=%" PRIu64 " ok=%" PRIu64 " bad=%" PRIu64
              " match=%.4f first_bad=%u,%u verdict=%s\n",
              n, ok, bad, n ? (double)ok / (double)n : 0.0, fx, fy, v);
      if (used_mmap)
         munmap(map, (size_t)stride * H);
      else
         gbm_bo_unmap(bo, map_data);
   }
   fclose(rep);
   close(bo_fd);
   printf("REPORT /tmp/dagu-linear-gmem-probe.report.txt\n");
   return 0;
}
