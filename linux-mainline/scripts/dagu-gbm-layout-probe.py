#!/usr/bin/env python3
"""Probe whether Freedreno GPU writes match the GBM modifier.

Creates a GBM+EGL surface, clears it red, mmaps the front buffer, and
prints modifier / first pixels. Tiled-into-LINEAR shows as non-red noise.
"""
from __future__ import annotations

import ctypes
import os
import sys
from ctypes import (
    POINTER,
    c_char_p,
    c_int,
    c_uint,
    c_uint64,
    c_void_p,
    byref,
)

W, H = 256, 256
for arg in sys.argv:
    if arg.startswith("--size="):
        parts = arg.split("=", 1)[1].split("x")
        W, H = int(parts[0]), int(parts[1])
GBM_BO_USE_SCANOUT = 1
GBM_BO_USE_RENDERING = 4
GBM_BO_USE_LINEAR = 16
GBM_FORMAT_ARGB8888 = int.from_bytes(b"AR24", "little")
EGL_PLATFORM_GBM_KHR = 0x31D7
EGL_SURFACE_TYPE = 0x3033
EGL_WINDOW_BIT = 0x0004
EGL_RED_SIZE = 0x3024
EGL_GREEN_SIZE = 0x3023
EGL_BLUE_SIZE = 0x3022
EGL_ALPHA_SIZE = 0x3021
EGL_RENDERABLE_TYPE = 0x3040
EGL_OPENGL_ES2_BIT = 0x0004
EGL_NONE = 0x3038
EGL_CONTEXT_CLIENT_VERSION = 0x3098
EGL_DEFAULT_DISPLAY = 0
EGL_NO_CONTEXT = 0
EGL_OPENGL_ES_API = 0x30A0
GL_COLOR_BUFFER_BIT = 0x00004000
GBM_BO_TRANSFER_READ = 1


def load():
    gbm = ctypes.CDLL("libgbm.so.1")
    egl = ctypes.CDLL("libEGL.so.1")
    gles = ctypes.CDLL("libGLESv2.so.2")
    return gbm, egl, gles


def setup_gbm(gbm):
    gbm.gbm_create_device.argtypes = [c_int]
    gbm.gbm_create_device.restype = c_void_p
    gbm.gbm_surface_create.argtypes = [c_void_p, c_uint, c_uint, c_uint, c_uint]
    gbm.gbm_surface_create.restype = c_void_p
    gbm.gbm_surface_lock_front_buffer.argtypes = [c_void_p]
    gbm.gbm_surface_lock_front_buffer.restype = c_void_p
    gbm.gbm_bo_get_stride.argtypes = [c_void_p]
    gbm.gbm_bo_get_stride.restype = c_uint
    gbm.gbm_bo_get_modifier.argtypes = [c_void_p]
    gbm.gbm_bo_get_modifier.restype = c_uint64
    gbm.gbm_bo_get_plane_count.argtypes = [c_void_p]
    gbm.gbm_bo_get_plane_count.restype = c_int
    gbm.gbm_bo_get_width.argtypes = [c_void_p]
    gbm.gbm_bo_get_width.restype = c_uint
    gbm.gbm_bo_get_height.argtypes = [c_void_p]
    gbm.gbm_bo_get_height.restype = c_uint
    gbm.gbm_bo_map.argtypes = [
        c_void_p, c_uint, c_uint, c_uint, c_uint, c_uint,
        POINTER(c_uint), POINTER(c_void_p),
    ]
    gbm.gbm_bo_map.restype = c_void_p


def setup_egl(egl, gles):
    egl.eglGetProcAddress.argtypes = [c_char_p]
    egl.eglGetProcAddress.restype = c_void_p
    get_plat = egl.eglGetProcAddress(b"eglGetPlatformDisplayEXT")
    if not get_plat:
        raise SystemExit("no eglGetPlatformDisplayEXT")
    eglGetPlatformDisplayEXT = ctypes.CFUNCTYPE(c_void_p, c_uint, c_void_p, POINTER(c_int))(get_plat)
    egl.eglInitialize.argtypes = [c_void_p, POINTER(c_int), POINTER(c_int)]
    egl.eglInitialize.restype = c_uint
    egl.eglBindAPI.argtypes = [c_uint]
    egl.eglBindAPI.restype = c_uint
    egl.eglChooseConfig.argtypes = [c_void_p, POINTER(c_int), POINTER(c_void_p), c_int, POINTER(c_int)]
    egl.eglChooseConfig.restype = c_uint
    egl.eglCreateContext.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_int)]
    egl.eglCreateContext.restype = c_void_p
    egl.eglCreateWindowSurface.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_int)]
    egl.eglCreateWindowSurface.restype = c_void_p
    egl.eglMakeCurrent.argtypes = [c_void_p, c_void_p, c_void_p, c_void_p]
    egl.eglMakeCurrent.restype = c_uint
    egl.eglSwapBuffers.argtypes = [c_void_p, c_void_p]
    egl.eglSwapBuffers.restype = c_uint
    egl.eglGetError.restype = c_int
    gles.glClearColor.argtypes = [ctypes.c_float, ctypes.c_float, ctypes.c_float, ctypes.c_float]
    gles.glClear.argtypes = [c_uint]
    gles.glFinish.argtypes = []
    return eglGetPlatformDisplayEXT


def iattrs(vals):
    arr = (c_int * len(vals))(*vals)
    return arr


def probe(flags: int) -> None:
    gbm, egl, gles = load()
    setup_gbm(gbm)
    eglGetPlatformDisplayEXT = setup_egl(egl, gles)

    fd = os.open("/dev/dri/renderD128", os.O_RDWR)
    dev = gbm.gbm_create_device(fd)
    surf = gbm.gbm_surface_create(dev, W, H, GBM_FORMAT_ARGB8888, flags)
    if not surf:
        print("gbm_surface_create failed flags", flags)
        return

    dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_GBM_KHR, ctypes.c_void_p(dev), None)
    maj = c_int(); minv = c_int()
    if not egl.eglInitialize(dpy, byref(maj), byref(minv)):
        print("eglInitialize failed", hex(egl.eglGetError()))
        return
    egl.eglBindAPI(EGL_OPENGL_ES_API)
    attribs = iattrs([
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE,
    ])
    cfg = c_void_p()
    n = c_int()
    if not egl.eglChooseConfig(dpy, attribs, byref(cfg), 1, byref(n)) or n.value < 1:
        print("eglChooseConfig failed", hex(egl.eglGetError()))
        return
    ctx_attr = iattrs([EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE])
    ctx = egl.eglCreateContext(dpy, cfg, None, ctx_attr)
    win = egl.eglCreateWindowSurface(dpy, cfg, ctypes.c_void_p(surf), None)
    if not ctx or not win:
        print("context/surface failed", hex(egl.eglGetError()), ctx, win)
        return
    if not egl.eglMakeCurrent(dpy, win, win, ctx):
        print("eglMakeCurrent failed", hex(egl.eglGetError()))
        return
    gles.glClearColor(1.0, 0.0, 0.0, 1.0)
    gles.glClear(GL_COLOR_BUFFER_BIT)
    gles.glFinish()
    if not egl.eglSwapBuffers(dpy, win):
        print("swap failed", hex(egl.eglGetError()))
        return

    bo = gbm.gbm_surface_lock_front_buffer(surf)
    if not bo:
        print("lock_front_buffer failed")
        return
    stride = gbm.gbm_bo_get_stride(bo)
    mod = gbm.gbm_bo_get_modifier(bo)
    planes = gbm.gbm_bo_get_plane_count(bo)
    map_stride = c_uint()
    map_handle = c_void_p()
    ptr = gbm.gbm_bo_map(
        bo, 0, 0, W, H, GBM_BO_TRANSFER_READ, byref(map_stride), byref(map_handle)
    )
    print(
        f"FD_MESA_DEBUG={os.environ.get('FD_MESA_DEBUG')!r} flags={flags:#x} "
        f"mod={mod:#x} planes={planes} stride={stride} map_stride={map_stride.value} ptr={ptr}"
    )
    if not ptr:
        print("map failed")
        return
    buf = ctypes.string_at(ptr, map_stride.value * 4)
    pix = list(buf[:16])
    print("first 4 px BGRA/ARGB bytes:", pix)
    # Count how many of the first 64 pixels look like opaque red in ARGB8888 or ABGR.
    raw = ctypes.string_at(ptr, map_stride.value * min(H, 8))
    redish = 0
    noise = 0
    for y in range(8):
        row = raw[y * map_stride.value : y * map_stride.value + 4 * 32]
        for i in range(0, len(row), 4):
            b, g, r, a = row[i : i + 4]
            if (r > 200 and g < 40 and b < 40) or (b > 200 and g < 40 and r < 40):
                redish += 1
            else:
                noise += 1
    print(f"sample 8x32: redish={redish} other={noise}")


EGL_LINUX_DMA_BUF_EXT = 0x3270
EGL_LINUX_DRM_FOURCC_EXT = 0x3271
EGL_DMA_BUF_PLANE0_FD_EXT = 0x3272
EGL_DMA_BUF_PLANE0_OFFSET_EXT = 0x3273
EGL_DMA_BUF_PLANE0_PITCH_EXT = 0x3274
EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT = 0x3443
EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT = 0x3444
EGL_WIDTH = 0x3057
EGL_HEIGHT = 0x3056
GL_TEXTURE_2D = 0x0DE1
GL_FRAMEBUFFER = 0x8D40
GL_COLOR_ATTACHMENT0 = 0x8CE0
GL_FRAMEBUFFER_BINDING = 0x8CA6
GL_RGBA = 0x1908
GL_UNSIGNED_BYTE = 0x1401


def count_red(raw: bytes, stride: int, rows: int = 8, cols: int = 32) -> tuple[int, int]:
    redish = 0
    noise = 0
    for y in range(min(rows, max(1, len(raw) // max(stride, 1)))):
        row = raw[y * stride : y * stride + 4 * cols]
        for i in range(0, len(row), 4):
            b, g, r, a = row[i : i + 4]
            if (r > 200 and g < 40 and b < 40) or (b > 200 and g < 40 and r < 40):
                redish += 1
            else:
                noise += 1
    return redish, noise


def probe_bo(flags: int) -> None:
    """Chromium Ozone path: gbm_bo_create + EGL image FBO, then raw dma-buf mmap.

    gbm_bo_map() can detile into a bounce buffer and hide the GPU layout.
    """
    gbm, egl, gles = load()
    gbm.gbm_create_device.argtypes = [c_int]
    gbm.gbm_create_device.restype = c_void_p
    gbm.gbm_bo_create.argtypes = [c_void_p, c_uint, c_uint, c_uint, c_uint]
    gbm.gbm_bo_create.restype = c_void_p
    gbm.gbm_bo_get_stride.argtypes = [c_void_p]
    gbm.gbm_bo_get_stride.restype = c_uint
    gbm.gbm_bo_get_modifier.argtypes = [c_void_p]
    gbm.gbm_bo_get_modifier.restype = c_uint64
    gbm.gbm_bo_get_fd.argtypes = [c_void_p]
    gbm.gbm_bo_get_fd.restype = c_int
    eglGetPlatformDisplayEXT = setup_egl(egl, gles)
    create_image = egl.eglGetProcAddress(b"eglCreateImageKHR")
    target_tex = egl.eglGetProcAddress(b"glEGLImageTargetTexture2DOES")
    if not create_image or not target_tex:
        print("missing EGL image procs")
        return
    eglCreateImageKHR = ctypes.CFUNCTYPE(
        c_void_p, c_void_p, c_void_p, c_uint, c_void_p, POINTER(c_int)
    )(create_image)
    glEGLImageTargetTexture2DOES = ctypes.CFUNCTYPE(None, c_uint, c_void_p)(target_tex)
    gles.glGenTextures.argtypes = [c_int, POINTER(c_uint)]
    gles.glBindTexture.argtypes = [c_uint, c_uint]
    gles.glGenFramebuffers.argtypes = [c_int, POINTER(c_uint)]
    gles.glBindFramebuffer.argtypes = [c_uint, c_uint]
    gles.glFramebufferTexture2D.argtypes = [c_uint, c_uint, c_uint, c_uint, c_int]
    gles.glReadPixels.argtypes = [c_int, c_int, c_int, c_int, c_uint, c_uint, c_void_p]
    gles.glViewport.argtypes = [c_int, c_int, c_int, c_int]

    fd = os.open("/dev/dri/renderD128", os.O_RDWR)
    dev = gbm.gbm_create_device(fd)
    bo = gbm.gbm_bo_create(dev, W, H, GBM_FORMAT_ARGB8888, flags)
    if not bo:
        print("gbm_bo_create failed flags", hex(flags))
        return
    stride = gbm.gbm_bo_get_stride(bo)
    mod = gbm.gbm_bo_get_modifier(bo)
    bo_fd = gbm.gbm_bo_get_fd(bo)
    dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_GBM_KHR, ctypes.c_void_p(dev), None)
    maj = c_int()
    minv = c_int()
    egl.eglInitialize(dpy, byref(maj), byref(minv))
    egl.eglBindAPI(EGL_OPENGL_ES_API)
    attribs = iattrs([
        EGL_SURFACE_TYPE, 0x0001,  # EGL_PBUFFER_BIT, context without window
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_NONE,
    ])
    cfg = c_void_p()
    n = c_int()
    if not egl.eglChooseConfig(dpy, attribs, byref(cfg), 1, byref(n)) or n.value < 1:
        attribs = iattrs([
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_NONE,
        ])
        egl.eglChooseConfig(dpy, attribs, byref(cfg), 1, byref(n))
    ctx = egl.eglCreateContext(dpy, cfg, None, iattrs([EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE]))
    if not egl.eglMakeCurrent(dpy, None, None, ctx) and not egl.eglMakeCurrent(dpy, 0, 0, ctx):
        print("surfaceless make current failed", hex(egl.eglGetError()))
        # try a tiny pbuffer-less GBM window as last resort
    img_attrs = iattrs([
        EGL_WIDTH, W,
        EGL_HEIGHT, H,
        EGL_LINUX_DRM_FOURCC_EXT, GBM_FORMAT_ARGB8888,
        EGL_DMA_BUF_PLANE0_FD_EXT, bo_fd,
        EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
        EGL_DMA_BUF_PLANE0_PITCH_EXT, stride,
        EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, int(mod & 0xFFFFFFFF),
        EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, int(mod >> 32),
        EGL_NONE,
    ])
    image = eglCreateImageKHR(dpy, None, EGL_LINUX_DMA_BUF_EXT, None, img_attrs)
    if not image:
        print("eglCreateImageKHR failed", hex(egl.eglGetError()), "mod", hex(mod), "stride", stride)
        return
    tex = c_uint()
    fbo = c_uint()
    gles.glGenTextures(1, byref(tex))
    gles.glBindTexture(GL_TEXTURE_2D, tex)
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, ctypes.c_void_p(image))
    gles.glGenFramebuffers(1, byref(fbo))
    gles.glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    gles.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0)
    gles.glViewport(0, 0, W, H)
    gles.glClearColor(1.0, 0.0, 0.0, 1.0)
    gles.glClear(GL_COLOR_BUFFER_BIT)
    gles.glFinish()
    pixels = (ctypes.c_ubyte * (4 * 32))()
    gles.glReadPixels(0, 0, 8, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
    import mmap as mmapmod

    length = stride * 8
    try:
        size = os.lseek(bo_fd, 0, os.SEEK_END)
        os.lseek(bo_fd, 0, os.SEEK_SET)
    except OSError:
        size = -1
    mm = mmapmod.mmap(bo_fd, length, mmapmod.MAP_SHARED, mmapmod.PROT_READ)
    raw = bytes(mm[:length])
    redish, noise = count_red(raw, stride)
    print(
        f"BO path FD_MESA_DEBUG={os.environ.get('FD_MESA_DEBUG')!r} flags={flags:#x} "
        f"mod={mod:#x} stride={stride} fdsize={size} "
        f"raw_mmap 8x32 redish={redish} other={noise} first16={list(raw[:16])} "
        f"glReadPixels={list(pixels[:16])}"
    )
    mm.close()


def probe_texexport() -> None:
    """WebGL analog: glTexStorage FBO, export dma-buf, print modifier."""
    gbm, egl, gles = load()
    eglGetPlatformDisplayEXT = setup_egl(egl, gles)
    create_image = egl.eglGetProcAddress(b"eglCreateImageKHR")
    qexp = egl.eglGetProcAddress(b"eglExportDMABUFImageQueryMESA")
    exp = egl.eglGetProcAddress(b"eglExportDMABUFImageMESA")
    print("procs", bool(create_image), bool(qexp), bool(exp))
    if not create_image or not qexp:
        return
    eglCreateImageKHR = ctypes.CFUNCTYPE(
        c_void_p, c_void_p, c_void_p, c_uint, c_void_p, POINTER(c_int)
    )(create_image)
    eglExportDMABUFImageQueryMESA = ctypes.CFUNCTYPE(
        c_uint, c_void_p, c_void_p, POINTER(c_int), POINTER(c_int), POINTER(c_uint64)
    )(qexp)
    gles.glGenTextures.argtypes = [c_int, POINTER(c_uint)]
    gles.glBindTexture.argtypes = [c_uint, c_uint]
    gles.glTexStorage2D.argtypes = [c_uint, c_int, c_uint, c_int, c_int]
    gles.glGenFramebuffers.argtypes = [c_int, POINTER(c_uint)]
    gles.glBindFramebuffer.argtypes = [c_uint, c_uint]
    gles.glFramebufferTexture2D.argtypes = [c_uint, c_uint, c_uint, c_uint, c_int]
    gles.glViewport.argtypes = [c_int, c_int, c_int, c_int]
    GL_RGBA8 = 0x8058
    EGL_GL_TEXTURE_2D_KHR = 0x30B1

    fd = os.open("/dev/dri/renderD128", os.O_RDWR)
    gbm.gbm_create_device.argtypes = [c_int]
    gbm.gbm_create_device.restype = c_void_p
    dev = gbm.gbm_create_device(fd)
    dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_GBM_KHR, ctypes.c_void_p(dev), None)
    maj = c_int(); minv = c_int()
    egl.eglInitialize(dpy, byref(maj), byref(minv))
    egl.eglBindAPI(EGL_OPENGL_ES_API)
    attribs = iattrs([
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    ])
    cfg = c_void_p(); n = c_int()
    egl.eglChooseConfig(dpy, attribs, byref(cfg), 1, byref(n))
    ctx = egl.eglCreateContext(dpy, cfg, None, iattrs([EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE]))
    ok = egl.eglMakeCurrent(dpy, None, None, ctx)
    print("make_current", bool(ok), "err", hex(egl.eglGetError()), "ctx", ctx)
    if not ok:
        return
    tex = c_uint(); fbo = c_uint()
    gles.glGenTextures(1, byref(tex))
    gles.glBindTexture(GL_TEXTURE_2D, tex)
    gles.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H)
    gles.glGenFramebuffers(1, byref(fbo))
    gles.glBindFramebuffer(GL_FRAMEBUFFER, fbo)
    gles.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0)
    gles.glViewport(0, 0, W, H)
    gles.glClearColor(1.0, 0.0, 0.0, 1.0)
    gles.glClear(GL_COLOR_BUFFER_BIT)
    gles.glFinish()
    image = eglCreateImageKHR(dpy, ctx, EGL_GL_TEXTURE_2D_KHR, ctypes.c_void_p(tex.value), None)
    print("gl image", image, "err", hex(egl.eglGetError()))
    if not image:
        return
    fourcc = c_int(); nplanes = c_int(); mods = (c_uint64 * 4)()
    ok = eglExportDMABUFImageQueryMESA(dpy, image, byref(fourcc), byref(nplanes), mods)
    print(
        f"texexport FD_MESA_DEBUG={os.environ.get('FD_MESA_DEBUG')!r} "
        f"ok={ok} fourcc={fourcc.value:#x} nplanes={nplanes.value} "
        f"mod={mods[0]:#x}"
    )


def main():
    flags = GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR
    if "--scanout" in sys.argv:
        flags |= GBM_BO_USE_SCANOUT
    if "--nolinearflag" in sys.argv:
        flags &= ~GBM_BO_USE_LINEAR
    if "--texexport" in sys.argv:
        probe_texexport()
        return
    if "--bo" in sys.argv:
        probe_bo(flags)
        return
    probe(flags)


if __name__ == "__main__":
    main()
